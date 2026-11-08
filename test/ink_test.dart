import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs_note/data/ink.dart';
import 'package:gs_note/data/note_repository.dart';
import 'package:gs_note/data/schema.dart';
import 'package:gs_note/data/settings_store.dart';
import 'package:gs_note/ui/ink_canvas.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

InkStroke stroke(String id, List<List<double>> pts) => InkStroke(
  id: id,
  tool: InkTool.pen,
  color: 0xFF000000,
  width: 4,
  points: [for (final p in pts) InkPoint(p[0], p[1], 0.5)],
);

void main() {
  sqfliteFfiInit();

  test('drawing round-trips through JSON; empty encodes to ""', () {
    expect(InkDrawing.empty.encode(), '');
    expect(InkDrawing.decode('').isEmpty, isTrue);
    expect(InkDrawing.decode('not json').isEmpty, isTrue);

    final d = InkDrawing([
      stroke('a', [
        [10, 20],
        [30.04, 40],
      ]),
    ]);
    final back = InkDrawing.decode(d.encode());
    expect(back.strokes.single.id, 'a');
    expect(back.strokes.single.points.last.x, 30.0);
    expect(back.bottom, 40);
  });

  test('drawings from another page width are rescaled', () {
    const src =
        '{"v":1,"w":500,"s":[{"id":"a","t":"p","c":0,"w":2,"pts":[100,50,1]}]}';
    final s = InkDrawing.decode(src).strokes.single;
    expect(s.points.single.x, 200);
    expect(s.width, 4);
  });

  test('eraser removes only strokes it touches; undo brings them back', () {
    final c = InkController(
      InkDrawing([
        stroke('a', [
          [0, 0],
          [100, 0],
        ]),
        stroke('b', [
          [0, 500],
          [100, 500],
        ]),
      ]),
    );
    expect(c.eraseAt(50, 3, 4), isTrue);
    expect(c.strokes.map((s) => s.id), ['b']);
    expect(c.eraseAt(50, 300, 4), isFalse);
    c.undo();
    expect(c.strokes.length, 2);
    c.redo();
    expect(c.strokes.length, 1);
  });

  test(
    'handwriting is saved with the note and keeps it from being empty',
    () async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: schemaVersion,
          onCreate: createSchema,
          singleInstance: false,
        ),
      );
      final settings = await SettingsStore.load(db);
      var repo = await NoteRepository.load(db, settings);
      final note = await repo.createNote();
      final ink = InkDrawing([
        stroke('a', [
          [1, 2],
        ]),
      ]).encode();
      await repo.updateNote(note.id, ink: ink);
      repo = await NoteRepository.load(db, settings);
      expect(repo.note(note.id)!.ink, ink);
      expect(repo.note(note.id)!.isEmpty, isFalse);
      await db.close();
    },
  );

  test('upgrading a version 1 database adds the ink column', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    // Version 1 notes table, as shipped before handwriting.
    await db.execute('''CREATE TABLE notes (id TEXT PRIMARY KEY, folder_id TEXT,
      title TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '',
      plain_text TEXT NOT NULL DEFAULT '', pinned INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      hlc TEXT NOT NULL, device_id TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0)''');
    await db.insert('notes', {
      'id': 'n',
      'created_at': 0,
      'updated_at': 0,
      'hlc': 'x',
      'device_id': 'd',
    });
    await upgradeSchema(db, 1, 2);
    final row = (await db.query('notes')).single;
    expect(row['ink'], '');
    await db.close();
  });

  testWidgets('S Pen draws with pressure; finger scrolls instead', (
    tester,
  ) async {
    final c = InkController(InkDrawing.empty);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InkCanvas(controller: c)),
      ),
    );
    final center = tester.getCenter(find.byType(InkCanvas));

    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(center);
    await pen.moveBy(const Offset(40, 10));
    await pen.moveBy(const Offset(40, 10));
    await pen.up();
    await tester.pump();
    expect(c.strokes.length, 1);
    expect(c.strokes.single.points.length, 3);

    // S Pen side button held: erases instead of drawing.
    final eraser = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
      buttons: kPrimaryStylusButton,
    );
    await eraser.down(center + const Offset(40, 10));
    await eraser.up();
    await tester.pump();
    expect(c.strokes, isEmpty);

    final finger = await tester.createGesture(kind: PointerDeviceKind.touch);
    await finger.down(center);
    await finger.moveBy(const Offset(0, -40));
    await finger.up();
    await tester.pump();
    expect(c.strokes, isEmpty);
  });

  test('black pen shows light on the dark theme, other colours unchanged',
      () {
    final black = InkController.penColors.first;
    expect(inkOnScreen(black, false), black);
    expect(inkOnScreen(black, true).computeLuminance(), greaterThan(0.7));
    final blue = InkController.penColors[1];
    expect(inkOnScreen(blue, true), blue);
  });
}
