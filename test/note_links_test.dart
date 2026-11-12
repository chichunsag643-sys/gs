import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs_note/ui/note_links.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

String? linkAt(Document doc, int index) =>
    doc.collectStyle(index, 1).attributes[Attribute.link.key]?.value
        as String?;

void main() {
  tapTests();
  test('finds http, https and www addresses, without trailing punctuation', () {
    final links = findLinks('보기: https://naver.com, www.daum.net. 그리고 http://a.b/c?d=1)');
    expect(links.map((l) => l.$3),
        ['https://naver.com', 'www.daum.net', 'http://a.b/c?d=1']);
  });

  test('ignores plain words and bare schemes', () {
    expect(findLinks('메모 www. https:// 그냥 글'), isEmpty);
  });

  test('www addresses open as https', () {
    expect(linkUri('www.naver.com').toString(), 'https://www.naver.com');
    expect(linkUri('http://x.com').toString(), 'http://x.com');
    expect(linkUri('javascript:alert(1)'), isNull);
  });

  test('linkifyDocument turns addresses into links once', () {
    final doc = Document()..insert(0, '회의 자료 www.naver.com 확인');
    expect(linkifyDocument(doc), isTrue);
    expect(linkAt(doc, 6), 'www.naver.com');
    expect(linkAt(doc, 18), 'www.naver.com');
    expect(linkAt(doc, 0), isNull);
    expect(linkifyDocument(doc), isFalse);
  });

  test('a partly linked address is relinked as a whole', () {
    final doc = Document()..insert(0, 'www.nav');
    linkifyDocument(doc);
    doc.insert(7, 'er.com');
    expect(linkifyDocument(doc), isTrue);
    expect(linkAt(doc, 0), 'www.naver.com');
    expect(linkAt(doc, 10), 'www.naver.com');
  });

  test('only link attributes get a tap recognizer', () {
    final doc = Document()..insert(0, 'x');
    final leaf = doc.root.first as dynamic;
    expect(tapToOpenLink(Attribute.bold, leaf.first as Leaf), isNull);
    expect(tapToOpenLink(LinkAttribute('https://a.com'), leaf.first as Leaf),
        isNotNull);
  });
}

class _FakeLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

void tapTests() {
  testWidgets('one tap on a link in the editable editor opens the browser',
      (tester) async {
    final fake = _FakeLauncher();
    UrlLauncherPlatform.instance = fake;
    final doc = Document()..insert(0, 'www.naver.com');
    linkifyDocument(doc);
    final controller = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [FlutterQuillLocalizations.delegate],
      home: Scaffold(
        body: QuillEditor.basic(
          controller: controller,
          config: const QuillEditorConfig(
            customRecognizerBuilder: tapToOpenLink,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getTopLeft(find.byType(QuillEditor)) +
        const Offset(20, 10));
    await tester.pumpAndSettle();
    expect(fake.launched, ['https://www.naver.com']);
  });
}
