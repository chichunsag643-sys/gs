import 'package:flutter/gestures.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:url_launcher/url_launcher.dart';

/// Web addresses written in a note: `http(s)://…` or `www.…`.
final _urlPattern = RegExp(
  r'''(?:https?://|www\.)[^\s<>"'`]+''',
  caseSensitive: false,
);

/// Characters that usually end a sentence rather than belong to the URL.
const _trailing = '.,;:!?)]}>\'"';

/// Ranges of web addresses in [text], as (start, length, url).
List<(int, int, String)> findLinks(String text) {
  final found = <(int, int, String)>[];
  for (final m in _urlPattern.allMatches(text)) {
    var url = m.group(0)!;
    while (url.isNotEmpty && _trailing.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (url.length <= 'www.'.length || url.toLowerCase() == 'http://' ||
        url.toLowerCase() == 'https://') {
      continue;
    }
    found.add((m.start, url.length, url));
  }
  return found;
}

/// `www.example.com` → `https://www.example.com`.
Uri? linkUri(String url) {
  final trimmed = url.trim();
  final withScheme = RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false)
          .hasMatch(trimmed)
      ? trimmed
      : 'https://$trimmed';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  return uri;
}

/// Marks every web address in the document as a link, so it shows underlined
/// and can be tapped. Addresses that already are links are left alone.
/// Returns true if anything changed.
bool linkifyDocument(Document document) {
  final text = document.toPlainText();
  var changed = false;
  for (final (start, length, url) in findLinks(text)) {
    if (_isLinkedAs(document.toDelta().toList(), start, length, url)) continue;
    document.format(start, length, LinkAttribute(url));
    changed = true;
  }
  return changed;
}

/// Whether every character in [start, start+length) already links to [url].
/// (A link typed in two goes, e.g. "www.nav" then "er.com", is only partly
/// linked and gets redone over the whole address.)
bool _isLinkedAs(List<dynamic> ops, int start, int length, String url) {
  final end = start + length;
  var pos = 0;
  for (final op in ops) {
    final opLen = op.length as int;
    final opEnd = pos + opLen;
    if (opEnd > start && pos < end) {
      final attrs = op.attributes as Map<String, dynamic>?;
      if (attrs?[Attribute.link.key] != url) return false;
    }
    if (opEnd >= end) break;
    pos = opEnd;
  }
  return true;
}

/// Opens [url] in the phone's browser app.
Future<bool> openLink(String url) async {
  final uri = linkUri(url);
  if (uri == null) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Makes a single tap on a link open it. (Quill's default on phones is a
/// long-press menu, which is easy to miss.)
GestureRecognizer? tapToOpenLink(Attribute attribute, Leaf leaf) {
  if (attribute.key != Attribute.link.key) return null;
  final url = attribute.value;
  if (url is! String || url.isEmpty) return null;
  return TapGestureRecognizer()..onTap = () => openLink(url);
}
