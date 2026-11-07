import 'package:sqflite_common/sqlite_api.dart';

const int schemaVersion = 3;

/// Creates or upgrades the schema. Kept free of plugin imports so tests can
/// run it against an in-memory database.
Future<void> createSchema(Database db, int version) async {
  final batch = db.batch();
  batch.execute('''
    CREATE TABLE folders (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      hlc TEXT NOT NULL,
      device_id TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0
    )''');
  batch.execute('''
    CREATE TABLE notes (
      id TEXT PRIMARY KEY,
      folder_id TEXT,
      title TEXT NOT NULL DEFAULT '',
      content TEXT NOT NULL DEFAULT '',
      plain_text TEXT NOT NULL DEFAULT '',
      ink TEXT NOT NULL DEFAULT '',
      pinned INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      hlc TEXT NOT NULL,
      device_id TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0
    )''');
  // Changes are found by HLC when syncing: "send me everything after X".
  batch.execute('CREATE INDEX idx_notes_hlc ON notes(hlc)');
  batch.execute('CREATE INDEX idx_folders_hlc ON folders(hlc)');
  batch.execute('CREATE INDEX idx_notes_folder ON notes(folder_id)');
  // Paired devices (filled in by the QR pairing step later).
  batch.execute('''
    CREATE TABLE devices (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      public_key TEXT,
      last_seen_hlc TEXT,
      added_at INTEGER NOT NULL
    )''');
  // Local-only key/value settings (never synced).
  batch.execute('''
    CREATE TABLE meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )''');
  _createAttachments(batch);
  await batch.commit(noResult: true);
}

/// Voice recordings attached to notes. Only metadata lives here; the audio
/// itself is a file named `<id>.m4a` in the attachments folder, so each
/// device can choose whether to keep other devices' audio (`audio_sync`).
void _createAttachments(Batch batch) {
  batch.execute('''
    CREATE TABLE attachments (
      id TEXT PRIMARY KEY,
      note_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      mime TEXT NOT NULL,
      duration_ms INTEGER NOT NULL DEFAULT 0,
      size_bytes INTEGER NOT NULL DEFAULT 0,
      sha256 TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      hlc TEXT NOT NULL,
      device_id TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0
    )''');
  batch.execute('CREATE INDEX idx_attachments_hlc ON attachments(hlc)');
  batch.execute('CREATE INDEX idx_attachments_note ON attachments(note_id)');
}

Future<void> upgradeSchema(Database db, int oldVersion, int newVersion) async {
  // One `if (oldVersion < N)` block per version.
  if (oldVersion < 2) {
    // S Pen handwriting, stored as JSON strokes (see data/ink.dart).
    await db.execute("ALTER TABLE notes ADD COLUMN ink TEXT NOT NULL DEFAULT ''");
  }
  if (oldVersion < 3) {
    // Voice memos.
    final batch = db.batch();
    _createAttachments(batch);
    await batch.commit(noResult: true);
  }
}
