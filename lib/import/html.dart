import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'delta_builder.dart';

/// Converts HTML (Google Keep, Evernote, web clippings, …) to the editor's
/// rich text, keeping bold, italic, underline, strike, links, text and
/// background colours, headings, lists and checkboxes.
class HtmlToDelta {
  HtmlToDelta._();

  static const _blocks = {
    'p', 'div', 'section', 'article', 'header', 'footer', 'main', 'aside',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'blockquote', 'pre', 'tr',
    'ul', 'ol', 'table', 'dl', 'dt', 'dd', 'hr', 'figure', 'en-note',
  };
  static const _skip = {'script', 'style', 'head', 'title', 'noscript'};

  final _b = DeltaBuilder();
  final _lists = <String>[]; // 'bullet' / 'ordered' per open list

  static String? title(String html) {
    final doc = html_parser.parse(html);
    final t = doc.querySelector('title')?.text.trim() ??
        doc.querySelector('.title')?.text.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// Converts [html]. Elements matching [skipSelector] (e.g. a title that
  /// is imported separately) are left out.
  static DeltaBuilder convert(String html, {String? skipSelector}) {
    final doc = html_parser.parse(html);
    if (skipSelector != null) {
      for (final e in doc.querySelectorAll(skipSelector)) {
        e.remove();
      }
    }
    final c = HtmlToDelta._();
    final root = doc.body ?? doc.documentElement;
    if (root != null) c._children(root, const {}, false);
    return c._b;
  }

  void _children(dom.Node node, Map<String, Object?> attrs, bool pre) {
    for (final child in node.nodes) {
      _node(child, attrs, pre);
    }
  }

  void _node(dom.Node node, Map<String, Object?> attrs, bool pre) {
    if (node is dom.Text) {
      var text = node.text;
      if (!pre) {
        text = text.replaceAll(RegExp(r'\s+'), ' ');
        if (_b.lineEmpty) text = text.trimLeft();
      }
      _b.text(text, attrs);
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName ?? '';
    if (_skip.contains(tag)) return;

    final a = {...attrs, ..._inlineAttrs(node)};
    switch (tag) {
      case 'br':
        _b.newline();
        return;
      case 'hr':
        _endLine();
        _b.text('────────');
        _b.newline();
        return;
      case 'img':
        final alt = node.attributes['alt'];
        if (alt != null && alt.trim().isNotEmpty) _b.text('[${alt.trim()}]', a);
        return;
      case 'input':
        if (node.attributes['type'] == 'checkbox') {
          _b.text(node.attributes.containsKey('checked') ? '☑ ' : '☐ ', a);
        }
        return;
      case 'ul':
      case 'ol':
        _endLine();
        _lists.add(tag == 'ol' ? 'ordered' : 'bullet');
        _children(node, a, pre);
        _lists.removeLast();
        return;
    }

    if (!_blocks.contains(tag)) {
      _children(node, a, pre);
      return;
    }

    _endLine();
    _children(node, a, pre || tag == 'pre');
    final block = <String, Object?>{};
    if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
      final level = int.parse(tag.substring(1));
      block['header'] = level > 3 ? 3 : level;
    } else if (tag == 'blockquote') {
      block['blockquote'] = true;
    } else if (tag == 'pre') {
      block['code-block'] = true;
    } else if (tag == 'li' && _lists.isNotEmpty) {
      block['list'] = _lists.last;
      if (_lists.length > 1) block['indent'] = _lists.length - 1;
    }
    if (!_b.lineEmpty || block.isNotEmpty) _b.newline(block);
  }

  /// Starts a new line unless already at the start of one.
  void _endLine() {
    if (!_b.lineEmpty) _b.newline();
  }

  static Map<String, Object?> _inlineAttrs(dom.Element e) {
    final a = <String, Object?>{};
    switch (e.localName) {
      case 'b' || 'strong':
        a['bold'] = true;
      case 'i' || 'em':
        a['italic'] = true;
      case 'u' || 'ins':
        a['underline'] = true;
      case 's' || 'strike' || 'del':
        a['strike'] = true;
      case 'code':
        a['code'] = true;
      case 'mark':
        a['background'] = '#fff59d';
      case 'a':
        final href = e.attributes['href'];
        if (href != null && href.isNotEmpty && !href.startsWith('#')) {
          a['link'] = href;
        }
      case 'font':
        final c = cssColor(e.attributes['color']);
        if (c != null) a['color'] = c;
    }
    final style = e.attributes['style'];
    if (style != null) {
      for (final decl in style.split(';')) {
        final i = decl.indexOf(':');
        if (i < 0) continue;
        final prop = decl.substring(0, i).trim().toLowerCase();
        final value = decl.substring(i + 1).trim().toLowerCase();
        switch (prop) {
          case 'font-weight':
            final n = int.tryParse(value);
            if (value == 'bold' || value == 'bolder' || (n != null && n >= 600)) {
              a['bold'] = true;
            }
          case 'font-style':
            if (value == 'italic') a['italic'] = true;
          case 'text-decoration' || 'text-decoration-line':
            if (value.contains('underline')) a['underline'] = true;
            if (value.contains('line-through')) a['strike'] = true;
          case 'color':
            final c = cssColor(value);
            if (c != null) a['color'] = c;
          case 'background-color' || 'background':
            final c = cssColor(value);
            if (c != null) a['background'] = c;
        }
      }
    }
    return a;
  }

  static const _named = {
    'black': '#000000', 'white': '#ffffff', 'red': '#ff0000',
    'green': '#008000', 'blue': '#0000ff', 'yellow': '#ffff00',
    'orange': '#ffa500', 'purple': '#800080', 'gray': '#808080',
    'grey': '#808080', 'pink': '#ffc0cb', 'brown': '#a52a2a',
  };

  /// `#rgb`, `#rrggbb`, `rgb(…)` or a common colour name as `#rrggbb`.
  static String? cssColor(String? value) {
    if (value == null) return null;
    final v = value.trim().toLowerCase();
    if (_named.containsKey(v)) return _named[v];
    final hex = RegExp(r'^#([0-9a-f]{3}|[0-9a-f]{6})$').firstMatch(v);
    if (hex != null) {
      final h = hex.group(1)!;
      return h.length == 3 ? '#${h.split('').map((c) => '$c$c').join()}' : '#$h';
    }
    final rgb = RegExp(r'^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$')
        .firstMatch(v);
    if (rgb != null) {
      // Fully transparent backgrounds are "no colour".
      if (rgb.group(4) != null && double.tryParse(rgb.group(4)!) == 0) {
        return null;
      }
      String two(String s) =>
          int.parse(s).clamp(0, 255).toRadixString(16).padLeft(2, '0');
      return '#${two(rgb.group(1)!)}${two(rgb.group(2)!)}${two(rgb.group(3)!)}';
    }
    return null;
  }
}
