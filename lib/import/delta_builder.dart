import 'dart:convert';

/// Builds a Quill Delta (the editor's rich text format) line by line.
///
/// Inline attributes (bold, colour, …) go on the text; block attributes
/// (header, list, …) go on the newline that ends the line, as Quill expects.
class DeltaBuilder {
  final List<Map<String, Object?>> _ops = [];
  final StringBuffer _plain = StringBuffer();

  /// Whether the current line has no text yet.
  bool _lineEmpty = true;

  bool get lineEmpty => _lineEmpty;

  void text(String text, [Map<String, Object?> attrs = const {}]) {
    if (text.isEmpty) return;
    // Newlines inside text would carry inline attributes; split them out.
    final parts = text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) newline();
      final part = parts[i];
      if (part.isEmpty) continue;
      _insert(part, attrs);
      _plain.write(part);
      _lineEmpty = false;
    }
  }

  /// Ends the current line, with optional block attributes for it.
  void newline([Map<String, Object?> block = const {}]) {
    _insert('\n', block);
    _plain.write('\n');
    _lineEmpty = true;
  }

  void _insert(String text, Map<String, Object?> attrs) {
    final clean = {
      for (final e in attrs.entries)
        if (e.value != null && e.value != false) e.key: e.value,
    };
    if (_ops.isNotEmpty && text != '\n') {
      final last = _ops.last;
      final lastText = last['insert'] as String;
      if (!lastText.endsWith('\n') &&
          _sameAttrs(last['attributes'] as Map<String, Object?>?, clean)) {
        last['insert'] = lastText + text;
        return;
      }
    }
    _ops.add({
      'insert': text,
      if (clean.isNotEmpty) 'attributes': clean,
    });
  }

  static bool _sameAttrs(Map<String, Object?>? a, Map<String, Object?> b) {
    final aa = a ?? const {};
    if (aa.length != b.length) return false;
    for (final e in b.entries) {
      if (aa[e.key] != e.value) return false;
    }
    return true;
  }

  String get plainText => _plain.toString().trim();

  /// The note's `content`: Delta JSON, or '' if there is no text (the same
  /// convention the editor uses when saving).
  String toContent() {
    if (plainText.isEmpty) return '';
    final ops = [for (final o in _ops) Map<String, Object?>.of(o)];
    // Drop trailing blank lines, keep one final newline.
    while (ops.isNotEmpty &&
        ops.last['insert'] == '\n' &&
        ops.last['attributes'] == null &&
        ops.length > 1 &&
        (ops[ops.length - 2]['insert'] as String).endsWith('\n')) {
      ops.removeLast();
    }
    // Leading blank lines too.
    while (ops.length > 1 &&
        ops.first['insert'] == '\n' &&
        ops.first['attributes'] == null) {
      ops.removeAt(0);
    }
    final last = ops.isEmpty ? null : ops.last['insert'] as String;
    if (last == null || !last.endsWith('\n')) {
      ops.add({'insert': '\n'});
    }
    return jsonEncode(ops);
  }

  /// A plain-text note body.
  static DeltaBuilder plain(String text) =>
      DeltaBuilder()..text(text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
}
