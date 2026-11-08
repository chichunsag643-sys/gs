import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../data/ink.dart';

/// Drawing state for the handwriting page: strokes, current tool and
/// undo/redo history.
class InkController extends ChangeNotifier {
  InkController(InkDrawing drawing) : _strokes = List.of(drawing.strokes);

  static const _uuid = Uuid();
  static const _maxHistory = 100;

  List<InkStroke> _strokes;
  final List<List<InkStroke>> _undo = [];
  final List<List<InkStroke>> _redo = [];

  InkTool tool = InkTool.pen;
  bool eraser = false;
  Color color = penColors.first;

  /// Base width in page units (page is [InkDrawing.pageWidth] wide).
  double width = 5;

  /// Off: only the S Pen draws and fingers scroll the page.
  bool fingerDraws = false;

  static const penColors = [
    Color(0xFF1F1F1F),
    Color(0xFF1565C0),
    Color(0xFFD32F2F),
    Color(0xFF2E7D32),
    Color(0xFFF9A825),
    Color(0xFF6A1B9A),
  ];
  static const penWidths = [3.0, 5.0, 9.0];

  InkDrawing get drawing => InkDrawing(List.unmodifiable(_strokes));
  List<InkStroke> get strokes => _strokes;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Bumped on every change to the committed strokes, so the painter only
  /// redraws them when they actually change.
  int revision = 0;

  /// Replaces the drawing with one edited on another device. Undo history
  /// is dropped, since it refers to strokes that may no longer exist.
  void replaceDrawing(InkDrawing drawing) {
    _strokes = List.of(drawing.strokes);
    _undo.clear();
    _redo.clear();
    revision++;
    notifyListeners();
  }

  void _commit(List<InkStroke> next) {
    _undo.add(_strokes);
    if (_undo.length > _maxHistory) _undo.removeAt(0);
    _redo.clear();
    _strokes = next;
    revision++;
    notifyListeners();
  }

  void addStroke(List<InkPoint> points, {required double strokeWidth}) {
    if (points.isEmpty) return;
    final highlighter = tool == InkTool.highlighter;
    _commit([
      ..._strokes,
      InkStroke(
        id: _uuid.v4(),
        tool: tool,
        color: highlighter
            ? color.withAlpha(0x66).toARGB32()
            : color.toARGB32(),
        width: strokeWidth,
        points: List.unmodifiable(points),
      ),
    ]);
  }

  /// Removes every stroke touching ([x], [y]). Returns whether any was hit.
  bool eraseAt(double x, double y, double radius) {
    final kept = _strokes.where((s) => !s.hits(x, y, radius)).toList();
    if (kept.length == _strokes.length) return false;
    _commit(kept);
    return true;
  }

  void clear() {
    if (_strokes.isEmpty) return;
    _commit([]);
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_strokes);
    _strokes = _undo.removeLast();
    revision++;
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_strokes);
    _strokes = _redo.removeLast();
    revision++;
    notifyListeners();
  }

  void setTool(InkTool t) {
    tool = t;
    eraser = false;
    if (t == InkTool.highlighter && width < 8) width = 16;
    if (t == InkTool.pen && width > 9) width = 5;
    notifyListeners();
  }

  void setEraser(bool on) {
    eraser = on;
    notifyListeners();
  }

  void setColor(Color c) {
    color = c;
    eraser = false;
    notifyListeners();
  }

  void setWidth(double w) {
    width = w;
    notifyListeners();
  }

  void setFingerDraws(bool on) {
    fingerDraws = on;
    notifyListeners();
  }
}

/// A scrolling handwriting page.
///
/// * S Pen draws with pressure; fingers scroll (unless "손가락으로 그리기").
/// * Holding the S Pen side button (or using a pen's eraser end) erases.
/// * The page grows as you write near the bottom.
class InkCanvas extends StatefulWidget {
  const InkCanvas({super.key, required this.controller});
  final InkController controller;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

class _InkCanvasState extends State<InkCanvas> {
  final _scroll = ScrollController();

  /// The stroke being drawn, in page units.
  final _live = ValueNotifier<List<InkPoint>>(const []);
  int? _pointer;
  bool _erasing = false;
  double _liveWidth = 4;
  Offset? _hover;
  bool _hoverErases = false;

  InkController get _c => widget.controller;

  @override
  void dispose() {
    _scroll.dispose();
    _live.dispose();
    super.dispose();
  }

  bool _draws(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus ||
      e.kind == PointerDeviceKind.mouse ||
      (_c.fingerDraws && e.kind == PointerDeviceKind.touch);

  /// S Pen side button held, or the eraser end of a pen.
  bool _wantsEraser(PointerEvent e) =>
      _c.eraser ||
      e.kind == PointerDeviceKind.invertedStylus ||
      (e.kind == PointerDeviceKind.stylus &&
          (e.buttons & kPrimaryStylusButton) != 0);

  double _pressure(PointerEvent e) {
    if (e.kind != PointerDeviceKind.stylus &&
        e.kind != PointerDeviceKind.invertedStylus) {
      return 0.5;
    }
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return 0.5;
    return ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
  }

  InkPoint _toPage(PointerEvent e, double scale) => InkPoint(
    e.localPosition.dx / scale,
    e.localPosition.dy / scale,
    _pressure(e),
  );

  void _down(PointerDownEvent e, double scale) {
    if (_pointer != null || !_draws(e)) return;
    _pointer = e.pointer;
    _erasing = _wantsEraser(e);
    _liveWidth = _c.width;
    if (_erasing) {
      _erase(e, scale);
    } else {
      _live.value = [_toPage(e, scale)];
    }
  }

  void _move(PointerMoveEvent e, double scale) {
    if (e.pointer != _pointer) return;
    if (_erasing) {
      _erase(e, scale);
      return;
    }
    final p = _toPage(e, scale);
    final last = _live.value.last;
    // Skip points closer than half a unit; keeps saved notes small.
    if ((p.x - last.x).abs() + (p.y - last.y).abs() < 0.5) return;
    _live.value = [..._live.value, p];
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (!_erasing && e is! PointerCancelEvent) {
      _c.addStroke(_live.value, strokeWidth: _liveWidth);
    }
    _erasing = false;
    _live.value = const [];
  }

  void _erase(PointerEvent e, double scale) {
    final p = _toPage(e, scale);
    _c.eraseAt(p.x, p.y, 12);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final scale = box.maxWidth / InkDrawing.pageWidth;
        return ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            // Always leave most of a screen of blank paper below the writing.
            final contentBottom = InkDrawing(_c.strokes).bottom * scale;
            final height = math.max(
              box.maxHeight,
              contentBottom + box.maxHeight * 0.75,
            );
            final drawingWithFinger = _c.fingerDraws;
            return ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                // The pen never scrolls; it writes. Fingers scroll unless they
                // are set to draw.
                dragDevices: drawingWithFinger
                    ? const <PointerDeviceKind>{PointerDeviceKind.trackpad}
                    : const {
                        PointerDeviceKind.touch,
                        PointerDeviceKind.trackpad,
                      },
              ),
              child: SingleChildScrollView(
                controller: _scroll,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _down(e, scale),
                  onPointerMove: (e) => _move(e, scale),
                  onPointerUp: _up,
                  onPointerCancel: _up,
                  onPointerHover: (e) => setState(() {
                    _hover = e.localPosition;
                    _hoverErases = _wantsEraser(e);
                  }),
                  child: MouseRegion(
                    onExit: (_) => setState(() => _hover = null),
                    child: SizedBox(
                      width: box.maxWidth,
                      height: height,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: _PaperPainter(
                                  strokes: _c.strokes,
                                  revision: _c.revision,
                                  scale: scale,
                                  lineColor: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant
                                      .withAlpha(90),
                                  dark: Theme.of(context).brightness ==
                                      Brightness.dark,
                                ),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: ValueListenableBuilder(
                                valueListenable: _live,
                                builder: (context, points, _) => CustomPaint(
                                  painter: _LivePainter(
                                    points: points,
                                    tool: _c.tool,
                                    color: inkOnScreen(
                                      _c.tool == InkTool.highlighter
                                          ? _c.color.withAlpha(0x66)
                                          : _c.color,
                                      Theme.of(context).brightness ==
                                          Brightness.dark,
                                    ),
                                    width: _liveWidth,
                                    scale: scale,
                                    hover: _hover,
                                    hoverErases: _hoverErases || _c.eraser,
                                    hoverColor: inkOnScreen(
                                      _c.color,
                                      Theme.of(context).brightness ==
                                          Brightness.dark,
                                    ),
                                    hoverWidth: _c.width,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Paints ruled paper and all committed strokes.
class _PaperPainter extends CustomPainter {
  _PaperPainter({
    required this.strokes,
    required this.revision,
    required this.scale,
    required this.lineColor,
    required this.dark,
  });

  final List<InkStroke> strokes;
  final int revision;
  final double scale;
  final Color lineColor;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    final gap = 64 * scale;
    for (var y = gap; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    for (final s in strokes) {
      paintStroke(canvas, s.points, s.tool, inkOnScreen(Color(s.color), dark),
          s.width, scale);
    }
  }

  @override
  bool shouldRepaint(_PaperPainter old) =>
      old.revision != revision ||
      old.scale != scale ||
      old.lineColor != lineColor ||
      old.dark != dark ||
      !identical(old.strokes, strokes);
}

/// Paints the stroke in progress and the S Pen hover cursor.
class _LivePainter extends CustomPainter {
  _LivePainter({
    required this.points,
    required this.tool,
    required this.color,
    required this.width,
    required this.scale,
    required this.hover,
    required this.hoverErases,
    required this.hoverColor,
    required this.hoverWidth,
  });

  final List<InkPoint> points;
  final InkTool tool;
  final Color color;
  final double width;
  final double scale;
  final Offset? hover;
  final bool hoverErases;
  final Color hoverColor;
  final double hoverWidth;

  @override
  void paint(Canvas canvas, Size size) {
    paintStroke(canvas, points, tool, color, width, scale);
    if (hover != null && points.isEmpty) {
      if (hoverErases) {
        canvas.drawCircle(
          hover!,
          12 * scale + 4,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.grey,
        );
      } else {
        canvas.drawCircle(
          hover!,
          math.max(2, hoverWidth * scale / 2),
          Paint()..color = hoverColor.withAlpha(140),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}

/// Draws one stroke. Pen strokes get thicker with pen pressure; highlighter
/// strokes are flat and see-through.
void paintStroke(
  Canvas canvas,
  List<InkPoint> points,
  InkTool tool,
  Color color,
  double width,
  double scale,
) {
  if (points.isEmpty) return;
  final paint = Paint()
    ..color = color
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true;

  Offset at(InkPoint p) => Offset(p.x * scale, p.y * scale);

  if (tool == InkTool.highlighter) {
    paint.strokeWidth = width * scale;
    if (points.length == 1) {
      canvas.drawCircle(
        at(points.first),
        width * scale / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }
    final path = Path()..moveTo(at(points.first).dx, at(points.first).dy);
    for (final p in points.skip(1)) {
      path.lineTo(at(p).dx, at(p).dy);
    }
    canvas.drawPath(path, paint);
    return;
  }

  // Minimum 1.5 px so a light touch is still visible.
  double w(InkPoint p) =>
      math.max(1.5, width * scale * (0.6 + 0.9 * p.pressure));
  if (points.length == 1) {
    canvas.drawCircle(
      at(points.first),
      w(points.first) / 2,
      paint..style = PaintingStyle.fill,
    );
    return;
  }
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1], b = points[i];
    paint.strokeWidth = (w(a) + w(b)) / 2;
    canvas.drawLine(at(a), at(b), paint);
  }
}

/// Pen, highlighter, eraser, colours, thickness, undo/redo.
class InkToolbar extends StatelessWidget {
  const InkToolbar({super.key, required this.controller});
  final InkController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        Widget toolButton({
          required IconData icon,
          required String tip,
          required bool selected,
          required VoidCallback onTap,
        }) => IconButton(
          tooltip: tip,
          isSelected: selected,
          style: selected
              ? IconButton.styleFrom(backgroundColor: scheme.secondaryContainer)
              : null,
          icon: Icon(icon),
          onPressed: onTap,
        );
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              toolButton(
                icon: Icons.edit,
                tip: '펜',
                selected: !c.eraser && c.tool == InkTool.pen,
                onTap: () => c.setTool(InkTool.pen),
              ),
              toolButton(
                icon: Icons.border_color,
                tip: '형광펜',
                selected: !c.eraser && c.tool == InkTool.highlighter,
                onTap: () => c.setTool(InkTool.highlighter),
              ),
              toolButton(
                icon: Icons.auto_fix_normal,
                tip: '지우개 (S펜 버튼을 누른 채로 써도 지워져요)',
                selected: c.eraser,
                onTap: () => c.setEraser(!c.eraser),
              ),
              const SizedBox(width: 4),
              for (final color in InkController.penColors)
                _ColorDot(
                  color: color,
                  selected: !c.eraser && c.color == color,
                  onTap: () => c.setColor(color),
                ),
              const SizedBox(width: 4),
              for (final w
                  in c.tool == InkTool.highlighter
                      ? const [12.0, 16.0, 24.0]
                      : InkController.penWidths)
                _WidthDot(
                  width: w,
                  selected: c.width == w,
                  onTap: () => c.setWidth(w),
                ),
              IconButton(
                tooltip: '실행 취소',
                icon: const Icon(Icons.undo),
                onPressed: c.canUndo ? c.undo : null,
              ),
              IconButton(
                tooltip: '다시 실행',
                icon: const Icon(Icons.redo),
                onPressed: c.canRedo ? c.redo : null,
              ),
              toolButton(
                icon: Icons.pan_tool_alt_outlined,
                tip: c.fingerDraws ? '손가락으로 그리기 끄기' : '손가락으로도 그리기',
                selected: c.fingerDraws,
                onTap: () => c.setFingerDraws(!c.fingerDraws),
              ),
              IconButton(
                tooltip: '모두 지우기',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: c.strokes.isEmpty ? null : c.clear,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 20,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: inkOnScreen(
              color,
              Theme.of(context).brightness == Brightness.dark,
            ),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 3,
            ),
          ),
        ),
      ),
    );
  }
}

class _WidthDot extends StatelessWidget {
  const _WidthDot({
    required this.width,
    required this.selected,
    required this.onTap,
  });
  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: onTap,
      radius: 20,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? scheme.secondaryContainer : null,
        ),
        child: Container(
          width: math.min(22, 4 + width * 1.2),
          height: math.min(22, 4 + width * 1.2),
          decoration: BoxDecoration(
            color: scheme.onSurface,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// The default black pen would be invisible on the dark theme, so it is
/// shown in a light colour there (like Samsung Notes). The stored colour
/// stays black, so the same note looks right on a light-themed device.
Color inkOnScreen(Color c, bool dark) {
  if (!dark) return c;
  if ((c.toARGB32() & 0xFFFFFF) == (InkController.penColors.first.toARGB32() & 0xFFFFFF)) {
    return Color(0xFFECECEC).withAlpha((c.a * 255).round());
  }
  return c;
}
