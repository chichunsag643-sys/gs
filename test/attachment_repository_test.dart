import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs_note/data/attachment_repository.dart';
import 'package:gs_note/data/hlc.dart';
import 'package:gs_note/data/note_repository.dart';
import 'package:gs_note/data/schema.dart';
import 'package:gs_note/data/settings_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Directory dir;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: createSchema,
        singleInstance: false,
      ),
    );
    dir = await Directory.systemTemp.createTemp('gs_note_attachments');
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<(SettingsStore, NoteRepository, AttachmentRepository)> load() async {
    final settings = await SettingsStore.load(db);
    final notes = await NoteRepository.load(db, settings);
    final audio = await AttachmentRepository.load(
        db, settings, notes, Directory(p.join(dir.path, 'attachments')));
    return (settings, notes, audio);
  }

  Future<String> fakeRecording(List<int> bytes) async {
    final f = File(p.join(dir.path, 'attachments',
        'recording-${DateTime.now().microsecondsSinceEpoch}.m4a'));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('a recording is moved into storage with size and checksum', () async {
    final (settings, notes, audio) = await load();
    final note = await notes.createNote();
    final bytes = List<int>.generate(2048, (i) => i % 251);
    final src = await fakeRecording(bytes);

    final a = await audio.addRecording(note.id, src,
        duration: const Duration(seconds: 3));

    expect(File(src).existsSync(), isFalse);
    expect(audio.isLocal(a.id), isTrue);
    expect(await File(audio.audioPath(a.id)).readAsBytes(), bytes);
    expect(a.sizeBytes, 2048);
    expect(a.sha256, sha256.convert(bytes).toString());
    expect(a.durationMs, 3000);
    expect(a.deviceId, settings.deviceId);
    // Ordered with notes on the same clock.
    expect(Hlc.parse(a.hlc) > Hlc.parse(note.hlc), isTrue);
    expect(audio.forNote(note.id).single.id, a.id);
    expect(audio.localBytes, 2048);

    // Survives a reload.
    final (_, _, again) = await load();
    expect(again.forNote(note.id).single.sha256, a.sha256);
    expect(again.isLocal(a.id), isTrue);
  });

  test('delete leaves a tombstone and removes the audio file', () async {
    final (_, notes, audio) = await load();
    final note = await notes.createNote();
    final a = await audio.addRecording(note.id, await fakeRecording([1, 2, 3]),
        duration: const Duration(seconds: 1));

    await audio.delete(a.id);

    expect(audio.forNote(note.id), isEmpty);
    expect(File(audio.audioPath(a.id)).existsSync(), isFalse);
    final rows = await db.query('attachments', where: 'id = ?', whereArgs: [a.id]);
    expect(rows.single['deleted'], 1);
    expect(Hlc.parse(rows.single['hlc'] as String) > Hlc.parse(a.hlc), isTrue);
  });

  test('text-only devices do not want other devices\' audio', () async {
    final (settings, _, audio) = await load();
    expect(settings.audioSync, SettingsStore.audioSyncTextOnly);
    expect(audio.wantsBlobs, isFalse);
    await settings.setAudioSync(SettingsStore.audioSyncAll);
    expect(audio.wantsBlobs, isTrue);
  });

  test('audio from another device is only stored if the checksum matches',
      () async {
    final (_, notes, audio) = await load();
    final note = await notes.createNote();
    // Metadata arrives first (as sync would write it), audio is missing.
    final remote = await audio.addRecording(
        note.id, await fakeRecording([9, 9, 9]),
        duration: const Duration(seconds: 1));
    await File(audio.audioPath(remote.id)).delete();
    await audio.reload();
    expect(audio.isLocal(remote.id), isFalse);
    expect(await audio.blobFile(remote.id), isNull);

    await expectLater(
        audio.importBlob(remote.id, [1, 1, 1], remote.sha256), throwsStateError);
    expect(await audio.hasBlob(remote.id), isFalse);

    await audio.importBlob(remote.id, [9, 9, 9], remote.sha256);
    expect(audio.isLocal(remote.id), isTrue);
    expect(await (await audio.blobFile(remote.id))!.readAsBytes(), [9, 9, 9]);
  });

  test('leftover unfinished recordings are cleaned up on load', () async {
    final stale = await fakeRecording([1]);
    await load();
    expect(File(stale).existsSync(), isFalse);
  });

  test('upgrading a v2 database adds the attachments table', () async {
    final path = p.join(dir.path, 'old.db');
    var old = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, v) async {
            await createSchema(db, v);
            await db.execute('DROP TABLE attachments');
          },
        ));
    await old.close();
    old = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: schemaVersion, onUpgrade: upgradeSchema));
    final tables = await old.query('sqlite_master',
        where: "type = 'table' AND name = 'attachments'");
    expect(tables, hasLength(1));
    await old.close();
  });
}
