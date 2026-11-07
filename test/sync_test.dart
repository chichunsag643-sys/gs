import 'package:flutter_test/flutter_test.dart';
import 'package:gs_note/data/note_repository.dart';
import 'package:gs_note/data/schema.dart';
import 'package:gs_note/data/settings_store.dart';
import 'package:gs_note/sync/pairing.dart';
import 'package:gs_note/sync/sync_service.dart';
import 'package:gs_note/sync/sync_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class Device {
  Device(this.db, this.settings, this.repo, this.sync);
  final Database db;
  final SettingsStore settings;
  final NoteRepository repo;
  final SyncService sync;

  Future<void> close() async {
    await sync.dispose();
    await db.close();
  }
}

var _nextPort = 48700;

Future<Database> _openDb() => databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: createSchema,
        singleInstance: false,
      ),
    );

Future<Device> _device(String name) async {
  final db = await _openDb();
  final settings = await SettingsStore.load(db);
  await settings.setDeviceName(name);
  final repo = await NoteRepository.load(db, settings);
  final sync = SyncService(
    store: SyncStore(db, settings.deviceId),
    settings: settings,
    repo: repo,
    port: _nextPort++,
    enableBeacon: false,
  );
  await sync.start();
  return Device(db, settings, repo, sync);
}

/// The invite as a scan would see it, pointed at localhost.
Future<PairingInvite> _invite(Device host) async {
  final i = await host.sync.startPairing();
  return PairingInvite(
    deviceId: i.deviceId,
    name: i.name,
    addresses: const ['127.0.0.1'],
    port: i.port,
    token: i.token,
  );
}

Future<void> _settle(List<Device> devices) async {
  for (var i = 0; i < 3; i++) {
    for (final d in devices) {
      await d.sync.syncAll();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('SyncStore', () {
    late Database db;
    setUp(() async => db = await _openDb());
    tearDown(() => db.close());

    test('every write gets a new seq, including merged rows', () async {
      final settings = await SettingsStore.load(db);
      final repo = await NoteRepository.load(db, settings);
      final store = SyncStore(db, settings.deviceId);
      final a = await repo.createNote();
      final s1 = await store.currentSeq();
      await repo.updateNote(a.id, title: 'x');
      expect(await store.currentSeq(), greaterThan(s1));
      final batch = await store.changesSince(s1);
      expect(batch.rows.single['id'], a.id);
      expect(batch.rows.single.containsKey('seq'), isFalse);
    });

    test('merge keeps the newer HLC and ignores repeats', () async {
      final settings = await SettingsStore.load(db);
      final store = SyncStore(db, settings.deviceId);
      Map<String, Object?> row(String hlc, String title) => {
            '_t': 'notes',
            'id': 'n1',
            'folder_id': null,
            'title': title,
            'content': '',
            'plain_text': '',
            'ink': '',
            'pinned': 0,
            'created_at': 0,
            'updated_at': 0,
            'hlc': hlc,
            'device_id': 'other',
            'deleted': 0,
            'unknown_future_column': 1,
          };
      var r = await store.merge([row('000000000000002-0000-b', 'new')]);
      expect(r.notes.single.title, 'new');
      r = await store.merge([row('000000000000001-0000-b', 'old')]);
      expect(r.isEmpty, isTrue);
      final seq = await store.currentSeq();
      r = await store.merge([row('000000000000002-0000-b', 'new')]);
      expect(r.isEmpty, isTrue);
      expect(await store.currentSeq(), seq, reason: 'no echo loops');
    });

    test('upgrading a version 2 database (pre-sync) keeps rows syncable', () async {
      final old = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      // The version 2 tables, as shipped before sync.
      await old.execute('''CREATE TABLE folders (id TEXT PRIMARY KEY,
        name TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        hlc TEXT NOT NULL, device_id TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0)''');
      await old.execute('''CREATE TABLE notes (id TEXT PRIMARY KEY,
        folder_id TEXT, title TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT '', plain_text TEXT NOT NULL DEFAULT '',
        ink TEXT NOT NULL DEFAULT '', pinned INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        hlc TEXT NOT NULL, device_id TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0)''');
      await old.execute('''CREATE TABLE devices (id TEXT PRIMARY KEY,
        name TEXT NOT NULL, public_key TEXT, last_seen_hlc TEXT,
        added_at INTEGER NOT NULL)''');
      await old.execute(
          'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      await old.insert('notes', {
        'id': 'n',
        'created_at': 0,
        'updated_at': 0,
        'hlc': '000000000000001-0000-a',
        'device_id': 'a',
      });
      await upgradeSchema(old, 2, schemaVersion);
      final store = SyncStore(old, 'a');
      final batch = await store.changesSince(0);
      expect(batch.rows.single['id'], 'n');
      await old.close();
    });
  });

  group('two devices', () {
    final devices = <Device>[];
    tearDown(() async {
      for (final d in devices) {
        await d.close();
      }
      devices.clear();
    });

    test('QR pairing, then edits flow both ways', () async {
      final phone = await _device('갤럭시');
      final mac = await _device('맥북');
      devices.addAll([phone, mac]);

      final note = await phone.repo.createNote();
      await phone.repo.updateNote(note.id, title: '장보기', plainText: '우유');

      expect(await mac.sync.join(await _invite(phone)), '갤럭시');
      phone.sync.stopPairing();
      await _settle(devices);

      expect(mac.repo.note(note.id)?.title, '장보기');
      expect(phone.sync.peers.single.name, '맥북');
      expect(mac.sync.peers.single.name, '갤럭시');

      await mac.repo.updateNote(note.id, title: '장보기 (수정)');
      await _settle(devices);
      expect(phone.repo.note(note.id)?.title, '장보기 (수정)');

      await phone.repo.deleteNote(note.id);
      await _settle(devices);
      expect(mac.repo.note(note.id), isNull);
    });

    test('an edit reaches the other device by itself within seconds',
        () async {
      final a = await _device('A');
      final b = await _device('B');
      devices.addAll([a, b]);
      await b.sync.join(await _invite(a));
      a.sync.stopPairing();
      await _settle(devices);

      final n = await a.repo.createNote();
      await a.repo.updateNote(n.id, title: '바로 보여야 함');
      for (var i = 0; i < 50 && b.repo.note(n.id)?.title != '바로 보여야 함'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(b.repo.note(n.id)?.title, '바로 보여야 함');
    });

    test('offline edits on both sides merge, newest edit wins', () async {
      final a = await _device('A');
      final b = await _device('B');
      devices.addAll([a, b]);
      await b.sync.join(await _invite(a));
      a.sync.stopPairing();
      await _settle(devices);

      // "Offline": edit without syncing.
      await a.settings.setSyncEnabled(false);
      await b.settings.setSyncEnabled(false);
      final na = await a.repo.createNote();
      await a.repo.updateNote(na.id, title: 'A에서 쓴 메모');
      final nb = await b.repo.createNote();
      await b.repo.updateNote(nb.id, title: 'B에서 쓴 메모');
      final shared = await a.repo.createNote();
      await a.repo.updateNote(shared.id, title: '먼저');
      await b.repo.applyRemote(notes: [a.repo.note(shared.id)!]);
      await b.db.insert('notes', a.repo.note(shared.id)!.toRow());
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await b.repo.updateNote(shared.id, title: '나중');

      // Back online.
      await a.settings.setSyncEnabled(true);
      await b.settings.setSyncEnabled(true);
      await _settle(devices);

      for (final d in devices) {
        expect(d.repo.note(na.id)?.title, 'A에서 쓴 메모');
        expect(d.repo.note(nb.id)?.title, 'B에서 쓴 메모');
        expect(d.repo.note(shared.id)?.title, '나중');
      }
    });

    test('a third device added on one device is known to all', () async {
      final a = await _device('A');
      final b = await _device('B');
      final c = await _device('C');
      devices.addAll([a, b, c]);
      await b.sync.join(await _invite(a));
      a.sync.stopPairing();
      await c.sync.join(await _invite(b));
      b.sync.stopPairing();
      await _settle(devices);

      expect({for (final p in a.sync.peers) p.name}, {'B', 'C'});
      expect({for (final p in c.sync.peers) p.name}, {'A', 'B'});

      // Removing C from A reaches C, which leaves the group.
      await a.sync.removePeer(c.settings.deviceId);
      await _settle(devices);
      expect(c.sync.paired, isFalse);
      expect({for (final p in b.sync.peers) p.name}, {'A'});
    });

    test('an expired QR code cannot be used', () async {
      final a = await _device('A');
      final b = await _device('B');
      devices.addAll([a, b]);
      final invite = await _invite(a);
      a.sync.stopPairing();
      await expectLater(b.sync.join(invite), throwsA(isA<PairingException>()));
      expect(b.sync.paired, isFalse);
    });
  });
}
