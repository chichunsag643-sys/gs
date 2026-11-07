import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../sync/blob_store.dart';
import 'models.dart';
import 'note_repository.dart';
import 'settings_store.dart';

/// Voice memo recordings.
///
/// The metadata rows follow the same sync rules as notes (UUID, HLC,
/// tombstones). The audio is a file `<id>.m4a` in [dir], kept out of the
/// database so that a device can sync only the text (`audio_sync =
/// text_only`) and never download other devices' audio.
class AttachmentRepository extends ChangeNotifier implements SyncBlobStore {
  AttachmentRepository._(this._db, this._settings, this._notes, this.dir);

  final Database _db;
  final SettingsStore _settings;
  final NoteRepository _notes;

  /// Folder holding the audio files. App-private storage.
  final Directory dir;
  final _uuid = const Uuid();
  final Map<String, Attachment> _items = {};

  /// Ids whose audio file exists on this device (checked at load and kept
  /// up to date on every write, so the UI never touches the disk).
  final Set<String> _local = {};

  static Future<AttachmentRepository> load(
    Database db,
    SettingsStore settings,
    NoteRepository notes,
    Directory dir,
  ) async {
    await dir.create(recursive: true);
    final repo = AttachmentRepository._(db, settings, notes, dir);
    // Recordings interrupted before they were attached (app killed).
    await for (final f in dir.list()) {
      final name = p.basename(f.path);
      if (f is File &&
          (name.startsWith('recording-') || name.endsWith('.part'))) {
        await f.delete();
      }
    }
    for (final row in await db.query('attachments', where: 'deleted = 0')) {
      final a = Attachment.fromRow(row);
      repo._items[a.id] = a;
      if (await File(repo._path(a.id)).exists()) repo._local.add(a.id);
    }
    return repo;
  }

  // ---- Reads ---------------------------------------------------------------

  /// Recordings of a note, oldest first.
  List<Attachment> forNote(String noteId) =>
      _items.values.where((a) => a.noteId == noteId).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  bool hasAny(String noteId) => _items.values.any((a) => a.noteId == noteId);

  Attachment? attachment(String id) => _items[id];

  /// Whether the audio of [id] is stored on this device.
  bool isLocal(String id) => _local.contains(id);

  /// Path of the audio file for [id] (it may not exist; see [isLocal]).
  String audioPath(String id) => _path(id);

  /// Bytes of audio stored on this device.
  int get localBytes => _items.values
      .where((a) => _local.contains(a.id))
      .fold(0, (sum, a) => sum + a.sizeBytes);

  int get localCount => _items.keys.where(_local.contains).length;

  String _path(String id) => p.join(dir.path, '$id.m4a');

  // ---- Sync hooks (SyncBlobStore) -----------------------------------------

  /// Whether this device downloads audio recorded on other devices.
  @override
  bool get wantsBlobs => _settings.audioSync == SettingsStore.audioSyncAll;

  @override
  Future<bool> hasBlob(String id) async => File(_path(id)).exists();

  @override
  Future<File?> blobFile(String id) async {
    final f = File(_path(id));
    return await f.exists() ? f : null;
  }

  /// Stores audio received from another device. Rejected if [sha256] does
  /// not match the bytes.
  @override
  Future<void> importBlob(String id, List<int> bytes, String sha256) async {
    final actual = crypto.sha256.convert(bytes).toString();
    if (actual != sha256) {
      throw StateError('Audio checksum mismatch for $id');
    }
    final tmp = File('${_path(id)}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(_path(id));
    _local.add(id);
    notifyListeners();
  }

  /// Re-reads the table, e.g. after the sync engine wrote rows directly.
  Future<void> reload() async {
    _items.clear();
    _local.clear();
    for (final row in await _db.query('attachments', where: 'deleted = 0')) {
      final a = Attachment.fromRow(row);
      _items[a.id] = a;
      if (await File(_path(a.id)).exists()) _local.add(a.id);
    }
    notifyListeners();
  }

  // ---- Writes --------------------------------------------------------------

  /// Takes a finished recording at [recordedPath] (moved into [dir]) and
  /// attaches it to [noteId].
  Future<Attachment> addRecording(
    String noteId,
    String recordedPath, {
    required Duration duration,
  }) async {
    final id = _uuid.v4();
    final src = File(recordedPath);
    final dest = File(_path(id));
    try {
      await src.rename(dest.path);
    } on FileSystemException {
      // Different file system (e.g. cache dir): copy instead.
      await src.copy(dest.path);
      await src.delete();
    }
    final bytes = await dest.readAsBytes();
    final now = DateTime.now();
    final a = Attachment(
      id: id,
      noteId: noteId,
      durationMs: duration.inMilliseconds,
      sizeBytes: bytes.length,
      sha256: crypto.sha256.convert(bytes).toString(),
      createdAt: now,
      updatedAt: now,
      hlc: await _notes.newStamp(),
      deviceId: _settings.deviceId,
    );
    _local.add(id);
    await _write(a);
    return a;
  }

  /// Deletes a recording everywhere (tombstone) and its audio on this device.
  Future<void> delete(String id) async {
    final old = _items[id];
    if (old == null) return;
    await _write(old.copyWith(
      deleted: true,
      updatedAt: DateTime.now(),
      hlc: await _notes.newStamp(),
      deviceId: _settings.deviceId,
    ));
    final f = File(_path(id));
    if (await f.exists()) await f.delete();
    _local.remove(id);
    notifyListeners();
  }

  /// Deletes all recordings of a note (when the note itself is deleted).
  Future<void> deleteForNote(String noteId) async {
    for (final a in forNote(noteId)) {
      await delete(a.id);
    }
  }

  Future<void> _write(Attachment a) async {
    await _db.insert('attachments', a.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    if (a.deleted) {
      _items.remove(a.id);
    } else {
      _items[a.id] = a;
    }
    notifyListeners();
  }
}
