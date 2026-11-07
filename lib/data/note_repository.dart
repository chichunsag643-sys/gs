import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import 'hlc.dart';
import 'models.dart';
import 'settings_store.dart';

/// All notes and folders, kept in memory and written through to the
/// encrypted database on every change.
class NoteRepository extends ChangeNotifier {
  NoteRepository._(this._db, this._settings, this._clock);

  final Database _db;
  final SettingsStore _settings;
  final HlcClock _clock;
  final _uuid = const Uuid();

  final Map<String, Note> _notes = {};
  final Map<String, Folder> _folders = {};

  static Future<NoteRepository> load(
    Database db,
    SettingsStore settings, {
    int Function()? wallClock,
  }) async {
    final last = settings.lastHlc;
    final clock = HlcClock(
      settings.deviceId,
      last: last == null ? null : Hlc.parse(last),
      wallClock: wallClock,
    );
    final repo = NoteRepository._(db, settings, clock);
    for (final row in await db.query('notes', where: 'deleted = 0')) {
      final n = Note.fromRow(row);
      repo._notes[n.id] = n;
    }
    for (final row in await db.query('folders', where: 'deleted = 0')) {
      final f = Folder.fromRow(row);
      repo._folders[f.id] = f;
    }
    return repo;
  }

  // ---- Reads ---------------------------------------------------------------

  List<Folder> get folders => _folders.values.toList()
    ..sort((a, b) {
      final c = a.sortOrder.compareTo(b.sortOrder);
      return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
    });

  Folder? folder(String id) => _folders[id];

  Note? note(String id) => _notes[id];

  /// Notes, pinned first then most recently edited.
  ///
  /// [folderId] filters to one folder; [unfiledOnly] to notes in no folder.
  List<Note> notes({String? folderId, bool unfiledOnly = false, String query = ''}) {
    final q = query.trim().toLowerCase();
    final list = _notes.values.where((n) {
      if (unfiledOnly && n.folderId != null) return false;
      if (folderId != null && n.folderId != folderId) return false;
      if (q.isNotEmpty &&
          !n.title.toLowerCase().contains(q) &&
          !n.plainText.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    return list;
  }

  int noteCount(String folderId) =>
      _notes.values.where((n) => n.folderId == folderId).length;

  // ---- Notes ---------------------------------------------------------------

  Future<Note> createNote({String? folderId}) async {
    final now = DateTime.now();
    final note = Note(
      id: _uuid.v4(),
      folderId: folderId,
      title: '',
      content: '',
      plainText: '',
      pinned: false,
      createdAt: now,
      updatedAt: now,
      hlc: (await _stamp()).toString(),
      deviceId: _settings.deviceId,
    );
    await _writeNote(note);
    return note;
  }

  /// Saves edited fields of a note. No-op if nothing changed.
  Future<Note?> updateNote(
    String id, {
    String? title,
    String? content,
    String? plainText,
    Object? folderId = _keep,
    bool? pinned,
  }) async {
    final old = _notes[id];
    if (old == null) return null;
    final changed = (title != null && title != old.title) ||
        (content != null && content != old.content) ||
        (plainText != null && plainText != old.plainText) ||
        (!identical(folderId, _keep) && folderId != old.folderId) ||
        (pinned != null && pinned != old.pinned);
    if (!changed) return old;
    final note = old.copyWith(
      title: title,
      content: content,
      plainText: plainText,
      folderId: folderId,
      pinned: pinned,
      updatedAt: DateTime.now(),
      hlc: (await _stamp()).toString(),
      deviceId: _settings.deviceId,
    );
    await _writeNote(note);
    return note;
  }

  /// Marks a note deleted (tombstone, so the delete can sync later).
  Future<void> deleteNote(String id) async {
    final old = _notes[id];
    if (old == null) return;
    final note = old.copyWith(
      deleted: true,
      updatedAt: DateTime.now(),
      hlc: (await _stamp()).toString(),
      deviceId: _settings.deviceId,
    );
    await _writeNote(note);
  }

  Future<void> _writeNote(Note note) async {
    await _db.insert('notes', note.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    if (note.deleted) {
      _notes.remove(note.id);
    } else {
      _notes[note.id] = note;
    }
    notifyListeners();
  }

  // ---- Folders -------------------------------------------------------------

  Future<Folder> createFolder(String name) async {
    final now = DateTime.now();
    final nextOrder = _folders.values.fold<int>(
            -1, (m, f) => f.sortOrder > m ? f.sortOrder : m) +
        1;
    final folder = Folder(
      id: _uuid.v4(),
      name: name.trim(),
      sortOrder: nextOrder,
      createdAt: now,
      updatedAt: now,
      hlc: (await _stamp()).toString(),
      deviceId: _settings.deviceId,
    );
    await _writeFolder(folder);
    return folder;
  }

  Future<void> renameFolder(String id, String name) async {
    final old = _folders[id];
    if (old == null || old.name == name.trim()) return;
    await _writeFolder(old.copyWith(
      name: name.trim(),
      updatedAt: DateTime.now(),
      hlc: (await _stamp()).toString(),
      deviceId: _settings.deviceId,
    ));
  }

  /// Deletes a folder. Its notes are kept and become unfiled.
  Future<void> deleteFolder(String id) async {
    final old = _folders[id];
    if (old == null) return;
    for (final n in notes(folderId: id)) {
      await updateNote(n.id, folderId: null);
    }
    await _writeFolder(old.copyWith(
      deleted: true,
      updatedAt: DateTime.now(),
      hlc: (await _stamp()).toString(),
      deviceId: _settings.deviceId,
    ));
  }

  Future<void> _writeFolder(Folder folder) async {
    await _db.insert('folders', folder.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    if (folder.deleted) {
      _folders.remove(folder.id);
    } else {
      _folders[folder.id] = folder;
    }
    notifyListeners();
  }

  Future<Hlc> _stamp() async {
    final hlc = _clock.now();
    await _settings.setLastHlc(hlc.toString());
    return hlc;
  }
}

const Object _keep = Object();
