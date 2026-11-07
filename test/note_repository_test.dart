import 'package:flutter_test/flutter_test.dart';
import 'package:gs_note/data/hlc.dart';
import 'package:gs_note/data/note_repository.dart';
import 'package:gs_note/data/schema.dart';
import 'package:gs_note/data/settings_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: createSchema,
        singleInstance: false,
      ),
    );
  });
  tearDown(() => db.close());

  Future<(SettingsStore, NoteRepository)> load() async {
    final settings = await SettingsStore.load(db);
    return (settings, await NoteRepository.load(db, settings));
  }

  test('notes persist across reloads', () async {
    var (_, repo) = await load();
    final note = await repo.createNote();
    await repo.updateNote(note.id,
        title: '장보기', content: '[{"insert":"우유\\n"}]', plainText: '우유');

    (_, repo) = await load();
    final loaded = repo.note(note.id)!;
    expect(loaded.title, '장보기');
    expect(loaded.plainText, '우유');
  });

  test('every change gets a newer HLC stamp from this device', () async {
    final (settings, repo) = await load();
    final note = await repo.createNote();
    final updated = (await repo.updateNote(note.id, title: 'x'))!;
    expect(Hlc.parse(updated.hlc) > Hlc.parse(note.hlc), isTrue);
    expect(updated.deviceId, settings.deviceId);
    expect(settings.lastHlc, updated.hlc);
  });

  test('unchanged update does not bump the stamp', () async {
    final (_, repo) = await load();
    final note = await repo.createNote();
    final same = await repo.updateNote(note.id, title: '');
    expect(same!.hlc, note.hlc);
  });

  test('delete leaves a tombstone row for later sync', () async {
    var (_, repo) = await load();
    final note = await repo.createNote();
    await repo.deleteNote(note.id);
    expect(repo.note(note.id), isNull);

    final rows = await db.query('notes', where: 'id = ?', whereArgs: [note.id]);
    expect(rows.single['deleted'], 1);
    (_, repo) = await load();
    expect(repo.notes(), isEmpty);
  });

  test('folders filter notes; deleting a folder keeps its notes', () async {
    final (_, repo) = await load();
    final work = await repo.createFolder('업무');
    final a = await repo.createNote(folderId: work.id);
    final b = await repo.createNote();
    await repo.updateNote(a.id, plainText: 'a');
    await repo.updateNote(b.id, plainText: 'b');

    expect(repo.notes(folderId: work.id).map((n) => n.id), [a.id]);
    expect(repo.notes(unfiledOnly: true).map((n) => n.id), [b.id]);

    await repo.deleteFolder(work.id);
    expect(repo.folders, isEmpty);
    expect(repo.note(a.id)!.folderId, isNull);
    expect(repo.notes().length, 2);
  });

  test('pinned notes come first; search matches title and body', () async {
    final (_, repo) = await load();
    final a = await repo.createNote();
    await repo.updateNote(a.id, title: '회의', plainText: '내일 10시');
    final b = await repo.createNote();
    await repo.updateNote(b.id, title: '일기', plainText: '맑음');
    await repo.updateNote(a.id, pinned: true);

    expect(repo.notes().first.id, a.id);
    expect(repo.notes(query: '맑').map((n) => n.id), [b.id]);
    expect(repo.notes(query: '회의').map((n) => n.id), [a.id]);
  });

  test('settings: library on by default, can be switched off', () async {
    var (settings, _) = await load();
    expect(settings.libraryEnabled, isTrue);
    expect(settings.lockEnabled, isFalse);
    final id = settings.deviceId;
    await settings.setLibraryEnabled(false);

    (settings, _) = await load();
    expect(settings.libraryEnabled, isFalse);
    expect(settings.deviceId, id);
  });
}
