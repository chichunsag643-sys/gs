import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs_note/app.dart';
import 'package:gs_note/app_scope.dart';
import 'package:gs_note/data/note_repository.dart';
import 'package:gs_note/data/schema.dart';
import 'package:gs_note/data/settings_store.dart';
import 'package:gs_note/security/app_lock.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  testWidgets('create a note, open editor, switch library off', (tester) async {
    late SettingsStore settings;
    late NoteRepository repo;
    late Database db;
    await tester.runAsync(() async {
      db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: schemaVersion,
          onCreate: createSchema,
          singleInstance: false,
        ),
      );
      settings = await SettingsStore.load(db);
      repo = await NoteRepository.load(db, settings);
      final folder = await repo.createFolder('업무');
      final note = await repo.createNote(folderId: folder.id);
      await repo.updateNote(note.id, title: '회의 메모', plainText: '10시');
    });

    await tester.pumpWidget(AppScope(
      repo: repo,
      settings: settings,
      lock: AppLock(settings),
      child: const NoteApp(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('모든 메모'), findsOneWidget);
    expect(find.text('회의 메모'), findsOneWidget);
    expect(find.text('메모가 잠겨 있습니다'), findsNothing);

    // Library drawer lists the folder.
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('업무'), findsOneWidget);
    await tester.tap(find.text('업무'));
    await tester.pumpAndSettle();

    // Open the editor; the restricted toolbar is shown.
    await tester.tap(find.text('회의 메모'));
    await tester.pumpAndSettle();
    expect(find.text('글꼴'), findsOneWidget);
    expect(find.text('크기'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // Turn the library off: drawer disappears, notes remain.
    await tester.tap(find.byTooltip('설정'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => settings.setLibraryEnabled(false));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.menu), findsNothing);
    expect(find.text('메모'), findsWidgets);
    expect(find.text('회의 메모'), findsOneWidget);

    await tester.runAsync(() => db.close());
  });
}
