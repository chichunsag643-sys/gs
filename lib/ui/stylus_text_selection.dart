import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// Makes the S Pen work in the Quill editor like a finger does.
///
/// * A single pen tap on the text opens the keyboard at that spot (it used
///   to take a double tap).
/// * Holding the pen selects a word (flutter_quill only listens for finger
///   long presses); keep holding and move to select more.
class StylusTextSelection extends StatelessWidget {
  const StylusTextSelection({
    super.key,
    required this.editorKey,
    required this.focusNode,
    required this.child,
  });

  final GlobalKey<EditorState> editorKey;
  final FocusNode focusNode;
  final Widget child;

  static const stylusKinds = {
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
  };

  @override
  Widget build(BuildContext context) {
    Offset? start;
    return Listener(
      onPointerDown: (e) {
        if (stylusKinds.contains(e.kind)) _openInput();
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: {
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  debugOwner: this,
                  supportedDevices: stylusKinds,
                ),
                (r) => r
                  ..onLongPressStart = (d) {
                    final editor = editorKey.currentState;
                    if (editor == null) return;
                    start = d.globalPosition;
                    if (!focusNode.hasFocus) focusNode.requestFocus();
                    editor.renderEditor.selectWordsInRange(
                      d.globalPosition,
                      null,
                      SelectionChangedCause.longPress,
                    );
                    HapticFeedback.selectionClick();
                  }
                  ..onLongPressMoveUpdate = (d) {
                    final editor = editorKey.currentState;
                    if (editor == null || start == null) return;
                    editor.renderEditor.selectWordsInRange(
                      start!,
                      d.globalPosition,
                      SelectionChangedCause.longPress,
                    );
                  }
                  ..onLongPressEnd = (_) {
                    final editor = editorKey.currentState;
                    start = null;
                    if (editor == null) return;
                    editor.renderEditor.onSelectionCompleted();
                    editor.showToolbar();
                  },
              ),
        },
        child: child,
      ),
    );
  }

  /// Opens the keyboard on the first pen touch. Before this the pen only
  /// brought up the keyboard on a double tap.
  void _openInput() {
    final editor = editorKey.currentState;
    if (editor == null || !editor.mounted) return;
    if (!focusNode.hasFocus) focusNode.requestFocus();
    editor.requestKeyboard();
  }
}

/// Quill drops focus when a pen taps outside the editor (it only keeps focus
/// for fingers), so tapping a toolbar button such as bold with the S Pen
/// closed the keyboard. Treat pens like fingers; a mouse still unfocuses.
void keepFocusForPenOnTapOutside(PointerDownEvent event, FocusNode focusNode) {
  if (event.kind == PointerDeviceKind.mouse) focusNode.unfocus();
}
