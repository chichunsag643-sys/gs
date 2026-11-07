import 'delta_builder.dart';

/// Converts Markdown (Obsidian, Bear, Notion exports, …) to the editor's rich
/// text. Covers what notes commonly use: headings, bold, italic, strike,
/// inline code, links, bullet/numbered/check lists, quotes and code blocks.
/// Anything else stays as plain text, so nothing is lost.
class MarkdownToDelta {
  static final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
  static final _check = RegExp(r'^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$');
  static final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
  static final _ordered = RegExp(r'^(\s*)\d{1,9}[.)]\s+(.*)$');
  static final _quote = RegExp(r'^\s*>\s?(.*)$');
  static final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
  static final _fence = RegExp(r'^\s*(```|~~~)');

  /// Converts [source]. If it starts with a level-1 heading, that heading is
  /// returned as the title and left out of the body.
  static ({String? title, DeltaBuilder body}) convert(String source) {
    final lines =
        source.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    var start = 0;
    // YAML front matter (Obsidian, Jekyll).
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      final end = lines.indexWhere((l) => l.trim() == '---', 1);
      if (end > 0) start = end + 1;
    }
    while (start < lines.length && lines[start].trim().isEmpty) {
      start++;
    }
    String? title;
    if (start < lines.length) {
      final m = _heading.firstMatch(lines[start]);
      if (m != null && m.group(1)!.length == 1) {
        title = _stripInline(m.group(2)!);
        start++;
      }
    }

    final b = DeltaBuilder();
    var inCode = false;
    for (var i = start; i < lines.length; i++) {
      final line = lines[i];
      if (_fence.hasMatch(line)) {
        inCode = !inCode;
        continue;
      }
      if (inCode) {
        b.text(line);
        b.newline({'code-block': true});
        continue;
      }
      RegExpMatch? m;
      if ((m = _heading.firstMatch(line)) != null) {
        final level = m!.group(1)!.length;
        inline(b, m.group(2)!);
        b.newline({'header': level > 3 ? 3 : level});
      } else if (_rule.hasMatch(line)) {
        b.text('────────');
        b.newline();
      } else if ((m = _check.firstMatch(line)) != null) {
        inline(b, m!.group(3)!);
        b.newline({
          'list': m.group(2) == ' ' ? 'unchecked' : 'checked',
          ..._indent(m.group(1)!),
        });
      } else if ((m = _bullet.firstMatch(line)) != null) {
        inline(b, m!.group(2)!);
        b.newline({'list': 'bullet', ..._indent(m.group(1)!)});
      } else if ((m = _ordered.firstMatch(line)) != null) {
        inline(b, m!.group(2)!);
        b.newline({'list': 'ordered', ..._indent(m.group(1)!)});
      } else if ((m = _quote.firstMatch(line)) != null) {
        inline(b, m!.group(1)!);
        b.newline({'blockquote': true});
      } else {
        // Markdown's hard line break: two trailing spaces or a backslash.
        var text = line.replaceFirst(RegExp(r'(\s{2,}|\\)$'), '');
        inline(b, text);
        b.newline();
      }
    }
    return (title: title, body: b);
  }

  static Map<String, Object?> _indent(String lead) {
    final width = lead.replaceAll('\t', '    ').length;
    final level = (width / 2).floor().clamp(0, 5);
    return level == 0 ? const {} : {'indent': level};
  }

  // ---- Inline -------------------------------------------------------------

  static final _inline = RegExp(
    r'\\([\\`*_{}\[\]()#+\-.!~>|=])' // 1: escaped character
    r'|`([^`]+)`' // 2: code
    r'|!\[([^\]]*)\]\([^)]*\)' // 3: image -> alt text
    r'|\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)' // 4,5: link
    r'|\*\*(.+?)\*\*' // 6: bold
    r'|__(.+?)__' // 7: bold
    r'|~~(.+?)~~' // 8: strike
    r'|==(.+?)==' // 9: highlight
    r'|\*(?!\s)(.+?)(?<!\s)\*' // 10: italic
    r'|(?<![\w])_(?!\s)(.+?)(?<!\s)_(?![\w])', // 11: italic
  );

  /// Appends [text] with its inline Markdown turned into attributes.
  static void inline(DeltaBuilder b, String text,
      [Map<String, Object?> attrs = const {}]) {
    var pos = 0;
    for (final m in _inline.allMatches(text)) {
      if (m.start > pos) b.text(text.substring(pos, m.start), attrs);
      pos = m.end;
      if (m.group(1) != null) {
        b.text(m.group(1)!, attrs);
      } else if (m.group(2) != null) {
        b.text(m.group(2)!, {...attrs, 'code': true});
      } else if (m.group(3) != null) {
        if (m.group(3)!.isNotEmpty) b.text(m.group(3)!, attrs);
      } else if (m.group(4) != null) {
        inline(b, m.group(4)!, {...attrs, 'link': m.group(5)});
      } else if (m.group(6) != null || m.group(7) != null) {
        inline(b, m.group(6) ?? m.group(7)!, {...attrs, 'bold': true});
      } else if (m.group(8) != null) {
        inline(b, m.group(8)!, {...attrs, 'strike': true});
      } else if (m.group(9) != null) {
        inline(b, m.group(9)!, {...attrs, 'background': '#fff59d'});
      } else {
        inline(b, m.group(10) ?? m.group(11)!, {...attrs, 'italic': true});
      }
    }
    if (pos < text.length) b.text(text.substring(pos), attrs);
  }

  /// [text] without inline Markdown, for titles.
  static String _stripInline(String text) {
    final b = DeltaBuilder();
    inline(b, text);
    return b.plainText;
  }
}
