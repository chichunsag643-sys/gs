import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs_note/import/note_import.dart';

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// Ops of a note's content.
List<Map<String, dynamic>> _ops(ImportedNote n) =>
    (jsonDecode(n.content) as List).cast<Map<String, dynamic>>();

/// The content must load in the editor exactly as the app loads it.
Document _doc(ImportedNote n) =>
    Document.fromJson(jsonDecode(n.content) as List<dynamic>);

/// An op equal to [m] is in the list.
Matcher has(Map<String, Object?> m) => contains(equals(m));

Uint8List _zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((name, text) {
    final bytes = utf8.encode(text);
    a.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  final importer = NoteImporter();

  test('a text file becomes a note titled with the file name', () async {
    final r = await importer.importFile(
        '장보기.txt', _utf8('우유\r\n계란\r\n\r\n빵\n'));
    expect(r.skipped, isEmpty);
    final n = r.notes.single;
    expect(n.title, '장보기');
    expect(n.plainText, '우유\n계란\n\n빵');
    expect(_doc(n).toPlainText(), '우유\n계란\n\n빵\n');
  });

  test('UTF-8 BOM and UTF-16 text files are read', () async {
    final bom = await importer.importFile(
        'a.txt', Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('한글')]));
    expect(bom.notes.single.plainText, '한글');
    final units = '메모'.codeUnits;
    final le = <int>[0xFF, 0xFE];
    for (final u in units) {
      le..add(u & 0xff)..add(u >> 8);
    }
    final r = await importer.importFile('b.txt', Uint8List.fromList(le));
    expect(r.notes.single.plainText, '메모');
  });

  test('non-UTF-8 text goes to the legacy (CP949) decoder', () async {
    final legacy = NoteImporter(legacyDecode: (b) async => '변환됨');
    final r = await legacy.importFile(
        'old.txt', Uint8List.fromList([0xC7, 0xD1, 0xB1, 0xDB]));
    expect(r.notes.single.plainText, '변환됨');
  });

  test('Markdown keeps headings, bold, lists and checkboxes', () async {
    final r = await importer.importFile('note.md', _utf8('''
---
tags: [a]
---
# 회의록

## 안건
**중요** 내용과 *기울임*, ~~취소~~, `코드`, [링크](https://example.com)
- 하나
  - 둘
1. 첫째
- [ ] 할 일
- [x] 한 일
> 인용
'''));
    final n = r.notes.single;
    expect(n.title, '회의록');
    final ops = _ops(n);
    expect(ops, has({'insert': '안건'}));
    expect(ops, has({'insert': '\n', 'attributes': {'header': 2}}));
    expect(ops, has({'insert': '중요', 'attributes': {'bold': true}}));
    expect(ops, has({'insert': '기울임', 'attributes': {'italic': true}}));
    expect(ops, has({'insert': '취소', 'attributes': {'strike': true}}));
    expect(ops, has({'insert': '코드', 'attributes': {'code': true}}));
    expect(ops,
        has({'insert': '링크', 'attributes': {'link': 'https://example.com'}}));
    expect(ops, has({'insert': '\n', 'attributes': {'list': 'bullet'}}));
    expect(ops,
        has({'insert': '\n', 'attributes': {'list': 'bullet', 'indent': 1}}));
    expect(ops, has({'insert': '\n', 'attributes': {'list': 'ordered'}}));
    expect(ops, has({'insert': '\n', 'attributes': {'list': 'unchecked'}}));
    expect(ops, has({'insert': '\n', 'attributes': {'list': 'checked'}}));
    expect(ops, has({'insert': '\n', 'attributes': {'blockquote': true}}));
    expect(n.plainText, isNot(contains('**')));
    expect(n.plainText, isNot(contains('tags')));
    _doc(n); // loads
  });

  test('HTML keeps colours and formatting', () async {
    final r = await importer.importFile('page.html', _utf8('''
<html><head><title>웹 메모</title></head><body>
<p>보통 <b>굵게</b> <span style="color: rgb(255, 0, 0)">빨강</span>
<span style="background-color:#ff0">노랑 배경</span></p>
<ul><li>항목</li></ul>
</body></html>'''));
    final n = r.notes.single;
    expect(n.title, '웹 메모');
    final ops = _ops(n);
    expect(ops, has({'insert': '굵게', 'attributes': {'bold': true}}));
    expect(ops, has({'insert': '빨강', 'attributes': {'color': '#ff0000'}}));
    expect(ops,
        has({'insert': '노랑 배경', 'attributes': {'background': '#ffff00'}}));
    expect(ops, has({'insert': '\n', 'attributes': {'list': 'bullet'}}));
    _doc(n);
  });

  test('Google Keep Takeout zip: JSON notes, lists, labels, trash skipped',
      () async {
    final zip = _zip({
      'Takeout/Keep/장보기.json': jsonEncode({
        'title': '장보기',
        'isPinned': true,
        'isTrashed': false,
        'listContent': [
          {'text': '우유', 'isChecked': false},
          {'text': '계란', 'isChecked': true},
        ],
        'labels': [
          {'name': '집'}
        ],
        'createdTimestampUsec': 1700000000000000,
        'userEditedTimestampUsec': 1700000100000000,
      }),
      'Takeout/Keep/장보기.html': '<div class="note">duplicate</div>',
      'Takeout/Keep/아이디어.json': jsonEncode({
        'title': '아이디어',
        'textContent': '첫 줄\n둘째 줄',
        'isTrashed': false,
      }),
      'Takeout/Keep/버림.json':
          jsonEncode({'title': 'x', 'textContent': 'y', 'isTrashed': true}),
      'Takeout/Keep/Labels.txt': '집\n',
      'Takeout/Keep/사진.png': 'binary',
    });
    final r = await importer.importFile('takeout.zip', zip);
    expect(r.skipped, isEmpty);
    expect(r.notes.map((n) => n.title), unorderedEquals(['장보기', '아이디어']));
    final list = r.notes.firstWhere((n) => n.title == '장보기');
    expect(list.pinned, isTrue);
    expect(list.label, '집');
    expect(list.updatedAt,
        DateTime.fromMicrosecondsSinceEpoch(1700000100000000));
    expect(_ops(list),
        has({'insert': '\n', 'attributes': {'list': 'checked'}}));
    expect(r.notes.firstWhere((n) => n.title == '아이디어').plainText,
        '첫 줄\n둘째 줄');
  });

  test('Evernote .enex notes with checkboxes', () async {
    final r = await importer.importFile('export.enex', _utf8('''
<?xml version="1.0" encoding="UTF-8"?>
<en-export><note><title>할 일 &amp; 메모</title>
<content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "x"><en-note><div><en-todo checked="true"/>끝남</div><div><b>굵게</b></div></en-note>]]></content>
<created>20240131T120000Z</created></note>
<note><title>둘째</title><content><![CDATA[<en-note>본문</en-note>]]></content></note>
</en-export>'''));
    expect(r.notes.length, 2);
    final n = r.notes.first;
    expect(n.title, '할 일 & 메모');
    expect(n.plainText, '☑ 끝남\n굵게');
    expect(n.createdAt, DateTime.utc(2024, 1, 31, 12).toLocal());
    expect(_ops(n), has({'insert': '굵게', 'attributes': {'bold': true}}));
  });

  test('Word .docx (e.g. Samsung Notes export)', () async {
    const xml = '<?xml version="1.0"?><w:document><w:body>'
        '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>제목</w:t></w:r></w:p>'
        '<w:p><w:r><w:rPr><w:b/><w:color w:val="FF0000"/></w:rPr><w:t>빨간 굵게</w:t></w:r>'
        '<w:r><w:t xml:space="preserve"> 보통 &amp; 끝</w:t></w:r></w:p>'
        '</w:body></w:document>';
    final r = await importer.importFile(
        '삼성노트.docx', _zip({'word/document.xml': xml}));
    final n = r.notes.single;
    expect(n.title, '삼성노트');
    expect(n.plainText, '제목\n빨간 굵게 보통 & 끝');
    final ops = _ops(n);
    expect(ops, has({'insert': '\n', 'attributes': {'header': 1}}));
    expect(ops, has({
      'insert': '빨간 굵게',
      'attributes': {'bold': true, 'color': '#ff0000'}
    }));
    _doc(n);
  });

  test('unsupported files are reported, not imported', () async {
    final r = await importer.importFile('photo.jpg', _utf8('x'));
    expect(r.notes, isEmpty);
    expect(r.skipped.single, contains('photo.jpg'));
    final bad = await importer.importFile('broken.docx', _utf8('not a zip'));
    expect(bad.notes, isEmpty);
    expect(bad.skipped, isNotEmpty);
  });

  test('shared text keeps the subject as title', () {
    final n = NoteImporter.fromSharedText('회의\n내용입니다', subject: '회의');
    expect(n.title, '회의');
    expect(n.plainText, '내용입니다');
  });

  test('audio files are recognised by extension or MIME type', () {
    expect(NoteImporter.isAudio('녹음.m4a'), isTrue);
    expect(NoteImporter.isAudio('voice.MP3'), isTrue);
    expect(NoteImporter.isAudio('x.bin', 'audio/wav'), isTrue);
    expect(NoteImporter.isAudio('memo.txt', 'text/plain'), isFalse);
  });
}
