import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs_note/app.dart';
import 'package:gs_note/app_scope.dart';
import 'package:gs_note/audio/transcriber.dart';
import 'package:gs_note/data/attachment_repository.dart';
import 'package:gs_note/data/note_repository.dart';
import 'package:gs_note/data/schema.dart';
import 'package:gs_note/data/settings_store.dart';
import 'package:gs_note/import/import_channel.dart';
import 'package:gs_note/security/app_lock.dart';
import 'package:gs_note/sync/sync_service.dart';
import 'package:gs_note/sync/sync_store.dart';
import 'package:gs_note/ui/ink_canvas.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  testWidgets('create a note, open editor, switch library off', (tester) async {
    late SettingsStore settings;
    late NoteRepository repo;
    late AttachmentRepository attachments;
    late Database db;
    late Directory dir;
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
      dir = await Directory.systemTemp.createTemp('gs_note_app_test');
      attachments = await AttachmentRepository.load(db, settings, repo, dir);
      final folder = await repo.createFolder('업무');
      final note = await repo.createNote(folderId: folder.id);
      await repo.updateNote(note.id, title: '회의 메모', plainText: '10시');
    });

    await tester.pumpWidget(AppScope(
      repo: repo,
      settings: settings,
      lock: AppLock(settings),
      sync: SyncService(
          store: SyncStore(db, settings.deviceId),
          settings: settings,
          repo: repo),
      attachments: attachments,
      voice: Transcriber(),
      importer: ImportChannel(),
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
    expect(find.byTooltip('음성 메모 녹음'), findsOneWidget);
    expect(find.text('크기'), findsOneWidget);

    // A single S Pen tap on the text opens the input (focuses the editor).
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(tester.getCenter(find.byType(QuillEditor)));
    await pen.up();
    await tester.pumpAndSettle();
    expect(
        tester.widget<QuillEditor>(find.byType(QuillEditor)).focusNode.hasFocus,
        isTrue);

    // Switch to the S Pen handwriting page and back.
    await tester.tap(find.byTooltip('S펜 손글씨'));
    await tester.pumpAndSettle();
    expect(find.byType(InkCanvas), findsOneWidget);
    expect(find.byTooltip('형광펜'), findsOneWidget);
    await tester.tap(find.byTooltip('키보드로 쓰기'));
    await tester.pumpAndSettle();
    expect(find.byType(QuillEditor), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // Turn the library off: drawer disappears, notes remain.
    await tester.tap(find.byTooltip('설정'));
    await tester.pumpAndSettle();
    expect(find.text('글자만 동기화'), findsOneWidget);
    await tester.runAsync(() => settings.setLibraryEnabled(false));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.menu), findsNothing);
    expect(find.text('메모'), findsWidgets);
    expect(find.text('회의 메모'), findsOneWidget);

    await tester.runAsync(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
  });
}
