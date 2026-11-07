import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'delta_builder.dart';
import 'html.dart';
import 'markdown.dart';

/// A note read from a file, ready to be saved.
class ImportedNote {
  ImportedNote({
    required this.title,
    required DeltaBuilder body,
    this.pinned = false,
    this.createdAt,
    this.updatedAt,
    this.label,
  })  : content = body.toContent(),
        plainText = body.plainText;

  final String title;

  /// Quill Delta JSON ('' if empty), as stored in `Note.content`.
  final String content;
  final String plainText;
  final bool pinned;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Label / notebook from the source app, used as the folder.
  final String? label;

  bool get isEmpty => title.trim().isEmpty && plainText.isEmpty;
}

class ImportResult {
  final notes = <ImportedNote>[];

  /// Files that could not be read, with the reason.
  final skipped = <String>[];
}

/// Decodes text that is not UTF-8 (e.g. Korean Windows "ANSI" = CP949).
typedef LegacyDecoder = Future<String> Function(Uint8List bytes);

/// Reads notes from files: plain text, Markdown, HTML, Google Keep (Takeout
/// JSON/HTML, or the whole .zip), Evernote (.enex), Word (.docx, e.g. a
/// Samsung Notes export) and .zip archives of any of these.
///
/// Everything runs on the device; nothing is uploaded.
class NoteImporter {
  NoteImporter({this.legacyDecode});

  final LegacyDecoder? legacyDecode;

  static const textExtensions = {'.txt', '.text', '.log', '.csv', '.tsv'};
  static const markdownExtensions = {'.md', '.markdown', '.mdown', '.mkd'};
  static const htmlExtensions = {'.html', '.htm', '.xhtml'};
  static const otherExtensions = {'.json', '.enex', '.docx', '.zip'};

  static const audioExtensions = {
    '.m4a', '.mp3', '.wav', '.aac', '.ogg', '.oga', '.opus', '.flac',
    '.amr', '.3gp', '.3gpp', '.mp4', '.webm', '.wma', '.mka',
  };

  static bool isAudio(String name, [String? mime]) {
    if (mime != null && mime.startsWith('audio/')) return true;
    return audioExtensions.contains(p.extension(name).toLowerCase());
  }

  static bool isSupported(String name) {
    final ext = p.extension(name).toLowerCase();
    return textExtensions.contains(ext) ||
        markdownExtensions.contains(ext) ||
        htmlExtensions.contains(ext) ||
        otherExtensions.contains(ext);
  }

  /// Reads the file [name] with contents [bytes] into [into].
  Future<ImportResult> importFile(String name, Uint8List bytes,
      {ImportResult? into}) async {
    final result = into ?? ImportResult();
    try {
      await _file(name, bytes, result, nested: false);
    } catch (e) {
      result.skipped.add('$name (읽을 수 없는 파일)');
    }
    return result;
  }

  /// A note from text shared by another app (e.g. Samsung Notes → 공유 →
  /// 텍스트).
  static ImportedNote fromSharedText(String text, {String? subject}) {
    final clean = text.replaceAll('\r\n', '\n').trim();
    var title = subject?.trim() ?? '';
    var body = clean;
    if (title.isNotEmpty && body.startsWith(title)) {
      body = body.substring(title.length).trimLeft();
    }
    return ImportedNote(title: title, body: DeltaBuilder.plain(body));
  }

  Future<void> _file(String name, Uint8List bytes, ImportResult r,
      {required bool nested}) async {
    final ext = p.extension(name).toLowerCase();
    final base = p.basenameWithoutExtension(name);
    if (textExtensions.contains(ext)) {
      final text = await decodeText(bytes);
      r.notes.add(ImportedNote(title: base, body: DeltaBuilder.plain(text)));
    } else if (markdownExtensions.contains(ext)) {
      final md = MarkdownToDelta.convert(await decodeText(bytes));
      r.notes.add(ImportedNote(title: md.title ?? base, body: md.body));
    } else if (htmlExtensions.contains(ext)) {
      final html = await decodeText(bytes);
      final keepTitle = _keepHtmlTitle(html);
      if (keepTitle != null) {
        r.notes.add(ImportedNote(
          title: keepTitle,
          body: HtmlToDelta.convert(html, skipSelector: '.title, .heading, .labels, .meta-icons'),
        ));
      } else {
        r.notes.add(ImportedNote(
          title: HtmlToDelta.title(html) ?? base,
          body: HtmlToDelta.convert(html),
        ));
      }
    } else if (ext == '.json') {
      final note = keepJson(await decodeText(bytes));
      if (note == null) {
        if (!nested) r.skipped.add('$name (지원하지 않는 JSON 형식)');
      } else if (note != _trashed) {
        r.notes.add(note);
      }
    } else if (ext == '.enex') {
      r.notes.addAll(evernote(await decodeText(bytes)));
    } else if (ext == '.docx') {
      r.notes.add(ImportedNote(title: base, body: docx(bytes)));
    } else if (ext == '.zip' && !nested) {
      await _zip(name, bytes, r);
    } else if (!nested) {
      r.skipped.add('$name (지원하지 않는 형식)');
    }
  }

  Future<void> _zip(String name, Uint8List bytes, ImportResult r) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = archive.files.where((f) => f.isFile).toList();
    // Google Keep Takeout has both note.json and note.html: use the JSON.
    final jsonNames = {
      for (final f in files)
        if (f.name.toLowerCase().endsWith('.json'))
          p.withoutExtension(f.name).toLowerCase(),
    };
    final before = r.notes.length;
    for (final f in files) {
      final entry = f.name;
      final lower = entry.toLowerCase();
      final baseName = p.basename(lower);
      if (baseName.startsWith('.') || lower.contains('__macosx/')) continue;
      if (lower.endsWith('.html') &&
          jsonNames.contains(p.withoutExtension(lower))) {
        continue;
      }
      // Keep's list of label names, not a note.
      if (baseName == 'labels.txt' && lower.contains('keep/')) continue;
      if (!isSupported(entry)) continue;
      try {
        await _file(entry, f.content, r, nested: true);
      } catch (_) {
        r.skipped.add('$name: ${p.basename(entry)}');
      }
    }
    if (r.notes.length == before) {
      r.skipped.add('$name (안에 불러올 메모가 없음)');
    }
  }

  // ---- Text decoding ------------------------------------------------------

  /// UTF-8 (with or without BOM), UTF-16 with BOM, or else the phone's
  /// legacy decoder (CP949 for Korean Windows text files).
  Future<String> decodeText(Uint8List bytes) async {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2) {
      final le = bytes[0] == 0xFF && bytes[1] == 0xFE;
      final be = bytes[0] == 0xFE && bytes[1] == 0xFF;
      if (le || be) {
        final units = <int>[];
        for (var i = 2; i + 1 < bytes.length; i += 2) {
          units.add(le
              ? bytes[i] | (bytes[i + 1] << 8)
              : (bytes[i] << 8) | bytes[i + 1]);
        }
        return String.fromCharCodes(units);
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      final legacy = legacyDecode;
      if (legacy != null) {
        try {
          return await legacy(bytes);
        } catch (_) {
          // Fall through.
        }
      }
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  // ---- Google Keep --------------------------------------------------------

  static final _trashed = ImportedNote(title: '', body: DeltaBuilder());

  /// A Google Keep Takeout note (`*.json`). Returns null if [source] is not
  /// one, and a sentinel for notes that were in Keep's trash.
  static ImportedNote? keepJson(String source) {
    final Object? data;
    try {
      data = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (data is! Map<String, dynamic>) return null;
    if (!data.containsKey('textContent') && !data.containsKey('listContent')) {
      return null;
    }
    if (data['isTrashed'] == true) return _trashed;
    final b = DeltaBuilder();
    final list = data['listContent'];
    if (list is List && list.isNotEmpty) {
      for (final item in list) {
        if (item is! Map) continue;
        b.text('${item['text'] ?? ''}');
        b.newline({'list': item['isChecked'] == true ? 'checked' : 'unchecked'});
      }
    } else {
      final html = data['textContentHtml'];
      if (html is String && html.trim().isNotEmpty) {
        final rich = HtmlToDelta.convert(html);
        if (rich.plainText.isNotEmpty) {
          return _keepNote(data, rich);
        }
      }
      b.text('${data['textContent'] ?? ''}'.replaceAll('\r\n', '\n'));
    }
    return _keepNote(data, b);
  }

  static ImportedNote _keepNote(Map<String, dynamic> data, DeltaBuilder b) {
    DateTime? usec(Object? v) =>
        v is int && v > 0 ? DateTime.fromMicrosecondsSinceEpoch(v) : null;
    final labels = data['labels'];
    String? label;
    if (labels is List && labels.isNotEmpty && labels.first is Map) {
      label = '${(labels.first as Map)['name'] ?? ''}'.trim();
      if (label.isEmpty) label = null;
    }
    return ImportedNote(
      title: '${data['title'] ?? ''}'.trim(),
      body: b,
      pinned: data['isPinned'] == true,
      createdAt: usec(data['createdTimestampUsec']),
      updatedAt: usec(data['userEditedTimestampUsec']),
      label: label,
    );
  }

  /// The title of a Google Keep Takeout HTML note, or null if [html] is not
  /// one.
  static String? _keepHtmlTitle(String html) {
    if (!html.contains('class="note')) return null;
    final m = RegExp(r'<div class="title">(.*?)</div>', dotAll: true)
        .firstMatch(html);
    if (m == null) return '';
    return HtmlToDelta.convert(m.group(1)!).plainText;
  }

  // ---- Evernote -----------------------------------------------------------

  static List<ImportedNote> evernote(String enex) {
    final notes = <ImportedNote>[];
    for (final m in RegExp(r'<note>(.*?)</note>', dotAll: true).allMatches(enex)) {
      final note = m.group(1)!;
      String? tag(String name) => RegExp('<$name>(.*?)</$name>', dotAll: true)
          .firstMatch(note)
          ?.group(1);
      var content = tag('content') ?? '';
      final cdata = RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true)
          .firstMatch(content);
      content = cdata != null ? cdata.group(1)! : _xmlUnescape(content);
      content = content
          .replaceAll(RegExp(r'<\?xml.*?\?>', dotAll: true), '')
          .replaceAll(RegExp(r'<!DOCTYPE.*?>', dotAll: true), '')
          .replaceAllMapped(
              RegExp(r'<en-todo([^>]*)/?>(</en-todo>)?'),
              (t) => t.group(1)!.contains('checked="true"') ? '☑ ' : '☐ ')
          .replaceAll(RegExp(r'<en-media[^>]*/?>(</en-media>)?'), '')
          .replaceAll(RegExp(r'<en-crypt.*?</en-crypt>', dotAll: true), '[암호화된 내용]');
      notes.add(ImportedNote(
        title: _xmlUnescape(tag('title') ?? '').trim(),
        body: HtmlToDelta.convert(content),
        createdAt: _enexDate(tag('created')),
        updatedAt: _enexDate(tag('updated')),
      ));
    }
    return notes;
  }

  /// `20240131T235959Z`.
  static DateTime? _enexDate(String? s) {
    final m = RegExp(r'^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z$')
        .firstMatch(s?.trim() ?? '');
    if (m == null) return null;
    int g(int i) => int.parse(m.group(i)!);
    return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6)).toLocal();
  }

  // ---- Word (.docx) -------------------------------------------------------

  /// Text of a Word document with bold, italic, underline, strike, colours,
  /// headings and lists.
  static DeltaBuilder docx(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final doc = archive.findFile('word/document.xml');
    if (doc == null) throw const FormatException('not a docx');
    final xml = utf8.decode(doc.content, allowMalformed: true);
    final b = DeltaBuilder();
    final para = RegExp(r'<w:p[ >].*?</w:p>|<w:p/>', dotAll: true);
    final run = RegExp(r'<w:r[ >].*?</w:r>', dotAll: true);
    final piece = RegExp(r'<w:t(?: [^>]*)?>(.*?)</w:t>|<w:tab/>|<w:br[^>]*/>|<w:cr/>',
        dotAll: true);
    bool on(String props, String tag) {
      final m = RegExp('<w:$tag(?: w:val="([^"]*)")?\\s*/>').firstMatch(props);
      if (m == null) return false;
      final v = m.group(1);
      return v == null || !(v == '0' || v == 'false' || v == 'none');
    }

    String? val(String props, String tag) =>
        RegExp('<w:$tag [^>]*w:val="([^"]*)"').firstMatch(props)?.group(1);

    const highlights = {
      'yellow': '#ffff00', 'green': '#00ff00', 'cyan': '#00ffff',
      'magenta': '#ff00ff', 'blue': '#0000ff', 'red': '#ff0000',
      'lightGray': '#d3d3d3', 'darkGray': '#a9a9a9',
    };

    for (final pm in para.allMatches(xml)) {
      final p0 = pm.group(0)!;
      final pPr = RegExp(r'<w:pPr>.*?</w:pPr>', dotAll: true)
              .firstMatch(p0)
              ?.group(0) ??
          '';
      for (final rm in run.allMatches(p0)) {
        final r0 = rm.group(0)!;
        final rPr = RegExp(r'<w:rPr>.*?</w:rPr>', dotAll: true)
                .firstMatch(r0)
                ?.group(0) ??
            '';
        final attrs = <String, Object?>{
          if (on(rPr, 'b')) 'bold': true,
          if (on(rPr, 'i')) 'italic': true,
          if (on(rPr, 'u')) 'underline': true,
          if (on(rPr, 'strike') || on(rPr, 'dstrike')) 'strike': true,
        };
        final color = val(rPr, 'color');
        if (color != null && RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(color) &&
            color.toLowerCase() != '000000') {
          attrs['color'] = '#${color.toLowerCase()}';
        }
        final hl = val(rPr, 'highlight');
        if (hl != null && highlights.containsKey(hl)) {
          attrs['background'] = highlights[hl];
        }
        final shd = RegExp(r'<w:shd [^>]*w:fill="([0-9A-Fa-f]{6})"').firstMatch(rPr);
        if (shd != null && shd.group(1)!.toLowerCase() != 'ffffff') {
          attrs['background'] = '#${shd.group(1)!.toLowerCase()}';
        }
        for (final t in piece.allMatches(r0)) {
          final s = t.group(0)!;
          if (s.startsWith('<w:tab')) {
            b.text('\t', attrs);
          } else if (s.startsWith('<w:br') || s.startsWith('<w:cr')) {
            b.newline();
          } else {
            b.text(_xmlUnescape(t.group(1)!), attrs);
          }
        }
      }
      final block = <String, Object?>{};
      final style = val(pPr, 'pStyle')?.toLowerCase() ?? '';
      final heading = RegExp(r'^(heading|제목)\s*([1-9])$').firstMatch(style);
      if (heading != null) {
        final level = int.parse(heading.group(2)!);
        block['header'] = level > 3 ? 3 : level;
      } else if (style == 'title') {
        block['header'] = 1;
      } else if (pPr.contains('<w:numPr>')) {
        block['list'] = 'bullet';
      }
      b.newline(block);
    }
    return b;
  }

  static String _xmlUnescape(String s) => s
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
      .replaceAllMapped(
          RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)))
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}
