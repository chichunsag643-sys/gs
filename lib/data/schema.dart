import 'package:sqflite_common/sqlite_api.dart';

const int schemaVersion = 4;

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
  await _addSyncTables(db);
}

/// Tables that sync between devices. Each gets a local `seq` (see
/// [addSyncTracking]). A table added later calls [addSyncTracking] in its
/// own migration.
const syncedTables = ['folders', 'notes', 'devices', 'attachments'];

/// Adds a local change counter to [table].
///
/// Every insert or update stamps the row with a new, strictly increasing
/// `seq` from `sync_counter`, including rows merged in from another device.
/// A peer then asks "send me your rows with seq > N", which is reliable even
/// though merged rows keep their original (possibly older) HLC.
/// `seq` is local to this device and never sent as data.
Future<void> addSyncTracking(DatabaseExecutor db, String table) async {
  await db.execute(
      'ALTER TABLE $table ADD COLUMN seq INTEGER NOT NULL DEFAULT 0');
  await db.execute('CREATE INDEX idx_${table}_seq ON $table(seq)');
  // Recursive triggers are off by default in SQLite, so the UPDATE inside
  // these triggers does not fire them again.
  for (final event in ['INSERT', 'UPDATE']) {
    await db.execute('''
      CREATE TRIGGER trg_${table}_seq_${event.toLowerCase()}
      AFTER $event ON $table
      BEGIN
        UPDATE sync_counter SET value = value + 1;
        UPDATE $table SET seq = (SELECT value FROM sync_counter)
          WHERE rowid = NEW.rowid;
      END''');
  }
  // Rows written before tracking existed still need to reach new peers:
  // touching them fires the trigger, which gives each a fresh seq.
  await db.execute('UPDATE $table SET seq = 0');
}

/// Schema v4: device-to-device sync.
Future<void> _addSyncTables(DatabaseExecutor db) async {
  await db.execute(
      'CREATE TABLE sync_counter (value INTEGER NOT NULL)');
  await db.execute('INSERT INTO sync_counter (value) VALUES (0)');
  // `devices` becomes a synced record table, so adding a device on one
  // phone tells every other device about it.
  await db.execute("ALTER TABLE devices ADD COLUMN addresses TEXT NOT NULL DEFAULT '[]'");
  await db.execute('ALTER TABLE devices ADD COLUMN port INTEGER NOT NULL DEFAULT 0');
  await db.execute("ALTER TABLE devices ADD COLUMN platform TEXT NOT NULL DEFAULT ''");
  await db.execute("ALTER TABLE devices ADD COLUMN hlc TEXT NOT NULL DEFAULT ''");
  await db.execute("ALTER TABLE devices ADD COLUMN device_id TEXT NOT NULL DEFAULT ''");
  await db.execute('ALTER TABLE devices ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
  for (final t in syncedTables) {
    await addSyncTracking(db, t);
  }
  // Local-only progress per peer (never synced).
  await db.execute('''
    CREATE TABLE peer_state (
      device_id TEXT PRIMARY KEY,
      recv_cursor INTEGER NOT NULL DEFAULT 0,
      sent_ack INTEGER NOT NULL DEFAULT 0,
      last_address TEXT,
      manual_address TEXT,
      last_sync_at INTEGER,
      last_error TEXT
    )''');
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
  // One `if (oldVersion < N && newVersion >= N)` block per version.
  if (oldVersion < 2) {
    // S Pen handwriting, stored as JSON strokes (see data/ink.dart).
    await db.execute("ALTER TABLE notes ADD COLUMN ink TEXT NOT NULL DEFAULT ''");
  }
  if (oldVersion < 3 && newVersion >= 3) {
    // Voice memos.
    final batch = db.batch();
    _createAttachments(batch);
    await batch.commit(noResult: true);
  }
  if (oldVersion < 4 && newVersion >= 4) {
    // Device-to-device sync.
    await _addSyncTables(db);
  }
}
