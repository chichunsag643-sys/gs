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

  /// Saves a note brought in from a file or another app. Keeps the original
  /// dates when known; the sync stamp is always new, so the note syncs.
  Future<Note> importNote({
    required String title,
    required String content,
    required String plainText,
    String? folderId,
    bool pinned = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) async {
    final now = DateTime.now();
    final created = createdAt ?? updatedAt ?? now;
    final note = Note(
      id: _uuid.v4(),
      folderId: folderId,
      title: title,
      content: content,
      plainText: plainText,
      pinned: pinned,
      createdAt: created,
      updatedAt: updatedAt ?? created,
      hlc: (await _stamp()).toString(),
      deviceId: _settings.deviceId,
    );
    await _writeNote(note);
    return note;
  }

  /// The folder named [name], created if there is none.
  Future<Folder> folderNamed(String name) async {
    final n = name.trim();
    for (final f in _folders.values) {
      if (f.name == n) return f;
    }
    return createFolder(n);
  }

  /// Saves edited fields of a note. No-op if nothing changed.
  Future<Note?> updateNote(
    String id, {
    String? title,
    String? content,
    String? plainText,
    String? ink,
    Object? folderId = _keep,
    bool? pinned,
  }) async {
    final old = _notes[id];
    if (old == null) return null;
    final changed = (title != null && title != old.title) ||
        (content != null && content != old.content) ||
        (plainText != null && plainText != old.plainText) ||
        (ink != null && ink != old.ink) ||
        (!identical(folderId, _keep) && folderId != old.folderId) ||
        (pinned != null && pinned != old.pinned);
    if (!changed) return old;
    final note = old.copyWith(
      title: title,
      content: content,
      plainText: plainText,
      ink: ink,
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

  // ---- Sync ----------------------------------------------------------------

  /// A new HLC stamp for a record written outside this repository (e.g. the
  /// device list kept by sync).
  Future<String> newStamp() async => (await _stamp()).toString();

  /// Records that were merged in from another device. The database already
  /// holds them; this refreshes the in-memory copy and moves our clock past
  /// the remote stamps so later local edits order after them.
  Future<void> applyRemote({
    Iterable<Note> notes = const [],
    Iterable<Folder> folders = const [],
  }) async {
    Hlc? newest;
    void observe(String hlc) {
      try {
        final h = Hlc.parse(hlc);
        if (newest == null || h > newest!) newest = h;
      } on FormatException {
        // A malformed stamp only loses ordering hints; the row still merged.
      }
    }

    for (final n in notes) {
      observe(n.hlc);
      if (n.deleted) {
        _notes.remove(n.id);
      } else {
        _notes[n.id] = n;
      }
    }
    for (final f in folders) {
      observe(f.hlc);
      if (f.deleted) {
        _folders.remove(f.id);
      } else {
        _folders[f.id] = f;
      }
    }
    if (newest != null) {
      final h = _clock.receive(newest!);
      await _settings.setLastHlc(h.toString());
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
