import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// Only the formatting the app needs: font, size, bold, text colour and
/// background colour (plus undo/redo and clear formatting).
class RichTextToolbar extends StatelessWidget {
  const RichTextToolbar({super.key, required this.controller});
  final QuillController controller;

  /// System fonts available on Android (Samsung maps these to its Korean
  /// fonts). Values are stored in the note, so other devices can map them
  /// to their own equivalents later.
  static const fonts = {
    '고딕': 'sans-serif',
    '명조': 'serif',
    '고정폭': 'monospace',
    '기본': 'Clear',
  };

  static const sizes = {
    '작게': '13',
    '보통': '16',
    '크게': '20',
    '아주 크게': '28',
    '기본': '0',
  };

  @override
  Widget build(BuildContext context) {
    return QuillSimpleToolbar(
      controller: controller,
      config: const QuillSimpleToolbarConfig(
        multiRowsDisplay: false,
        showDividers: false,
        showFontFamily: true,
        showFontSize: true,
        showBoldButton: true,
        showColorButton: true,
        showBackgroundColorButton: true,
        showClearFormat: true,
        showUndo: true,
        showRedo: true,
        showItalicButton: false,
        showSmallButton: false,
        showUnderLineButton: false,
        showLineHeightButton: false,
        showStrikeThrough: false,
        showInlineCode: false,
        showAlignmentButtons: false,
        showHeaderStyle: false,
        showListNumbers: false,
        showListBullets: false,
        showListCheck: false,
        showCodeBlock: false,
        showQuote: false,
        showIndent: false,
        showLink: false,
        showDirection: false,
        showSearchButton: false,
        showSubscript: false,
        showSuperscript: false,
        buttonOptions: QuillSimpleToolbarButtonOptions(
          fontFamily: QuillToolbarFontFamilyButtonOptions(
            items: fonts,
            defaultDisplayText: '글꼴',
            defaultItemColor: Colors.grey,
          ),
          fontSize: QuillToolbarFontSizeButtonOptions(
            items: sizes,
            defaultDisplayText: '크기',
            defaultItemColor: Colors.grey,
          ),
        ),
      ),
    );
  }
}
