/// Handwriting (S Pen) data for a note.
///
/// Stored as JSON in `notes.ink`. Built to sync well later:
/// * every stroke has its own UUID and never changes once drawn, so devices
///   can merge drawings as a set of strokes (union of added ids, minus erased
///   ids) instead of overwriting each other's whole drawing;
/// * coordinates are in a fixed page width of [InkDrawing.pageWidth] units,
///   not screen pixels, so a drawing made on a phone lines up the same way on
///   a tablet or a Mac.
library;

import 'dart:convert';
import 'dart:math' as math;

enum InkTool { pen, highlighter }

class InkPoint {
  const InkPoint(this.x, this.y, this.pressure);

  /// Page units (see [InkDrawing.pageWidth]).
  final double x;
  final double y;

  /// 0..1. Fingers and pens without pressure use 0.5.
  final double pressure;
}

class InkStroke {
  const InkStroke({
    required this.id,
    required this.tool,
    required this.color,
    required this.width,
    required this.points,
  });

  final String id;
  final InkTool tool;

  /// ARGB colour value.
  final int color;

  /// Base width in page units.
  final double width;
  final List<InkPoint> points;

  double get maxY => points.fold(0, (m, p) => math.max(m, p.y));

  /// Whether the stroke passes within [radius] of ([x], [y]).
  bool hits(double x, double y, double radius) {
    final r = radius + width / 2;
    if (points.length == 1) {
      return _dist2(x, y, points.first.x, points.first.y) <= r * r;
    }
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      if (_segDist2(x, y, a.x, a.y, b.x, b.y) <= r * r) return true;
    }
    return false;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    't': tool == InkTool.highlighter ? 'h' : 'p',
    'c': color,
    'w': _round(width),
    // Flat [x, y, pressure, x, y, pressure, ...] keeps the JSON small.
    'pts': [
      for (final p in points) ...[_round(p.x), _round(p.y), _round(p.pressure)],
    ],
  };

  factory InkStroke.fromJson(Map<String, dynamic> json) {
    final flat = (json['pts'] as List).cast<num>();
    return InkStroke(
      id: json['id'] as String,
      tool: json['t'] == 'h' ? InkTool.highlighter : InkTool.pen,
      color: (json['c'] as num).toInt(),
      width: (json['w'] as num).toDouble(),
      points: [
        for (var i = 0; i + 2 < flat.length; i += 3)
          InkPoint(
            flat[i].toDouble(),
            flat[i + 1].toDouble(),
            flat[i + 2].toDouble(),
          ),
      ],
    );
  }
}

class InkDrawing {
  const InkDrawing(this.strokes);

  static const empty = InkDrawing([]);

  /// Width of the page in stored units, whatever the screen size.
  static const double pageWidth = 1000;

  final List<InkStroke> strokes;

  bool get isEmpty => strokes.isEmpty;

  /// Lowest point drawn, in page units.
  double get bottom => strokes.fold(0, (m, s) => math.max(m, s.maxY));

  /// '' for an empty drawing, so notes without handwriting stay small.
  String encode() => strokes.isEmpty
      ? ''
      : jsonEncode({
          'v': 1,
          'w': pageWidth,
          's': [for (final s in strokes) s.toJson()],
        });

  static InkDrawing decode(String source) {
    if (source.isEmpty) return empty;
    try {
      final json = jsonDecode(source) as Map<String, dynamic>;
      final scale = pageWidth / ((json['w'] as num?)?.toDouble() ?? pageWidth);
      final strokes = [
        for (final s in json['s'] as List)
          InkStroke.fromJson(s as Map<String, dynamic>),
      ];
      if (scale == 1) return InkDrawing(strokes);
      return InkDrawing([
        for (final s in strokes)
          InkStroke(
            id: s.id,
            tool: s.tool,
            color: s.color,
            width: s.width * scale,
            points: [
              for (final p in s.points)
                InkPoint(p.x * scale, p.y * scale, p.pressure),
            ],
          ),
      ]);
    } catch (_) {
      return empty;
    }
  }
}

double _round(double v) => (v * 10).roundToDouble() / 10;

double _dist2(double ax, double ay, double bx, double by) {
  final dx = ax - bx, dy = ay - by;
  return dx * dx + dy * dy;
}

double _segDist2(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0) return _dist2(px, py, ax, ay);
  final t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
  return _dist2(px, py, ax + t * dx, ay + t * dy);
}
