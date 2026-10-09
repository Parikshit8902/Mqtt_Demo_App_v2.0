import 'package:flutter/material.dart';

import '../services/metrics/timeline.dart';

/// Draws a [Timeline]: one row per phone, a bar per image (grey = download,
/// black = inference), seconds along the bottom.
class TimelineChart extends StatelessWidget {
  final Timeline timeline;
  final double rowHeight;
  final double labelWidth;

  const TimelineChart(this.timeline, {super.key, this.rowHeight = 22, this.labelWidth = 76});

  static const double _axisHeight = 18;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: timeline.rows.length * rowHeight + _axisHeight,
      width: double.infinity,
      child: CustomPaint(painter: _TimelinePainter(timeline, rowH: rowHeight, labelW: labelWidth)),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  final Timeline tl;
  final double rowH, labelW;

  _TimelinePainter(this.tl, {required this.rowH, required this.labelW});

  @override
  void paint(Canvas canvas, Size size) {
    final plotW = size.width - labelW;
    if (plotW <= 0 || tl.spanMs <= 0) return;
    final scale = plotW / tl.spanMs;
    final download = Paint()..color = Colors.grey.shade400;
    final infer = Paint()..color = Colors.black;
    final grid = Paint()
      ..color = Colors.grey.shade200
      ..strokeWidth = 1;

    void text(String s, Offset at, {double size = 10, Color color = Colors.black87, bool right = false}) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: right ? labelW - 6 : 60);
      tp.paint(canvas, right ? Offset(at.dx - tp.width, at.dy - tp.height / 2) : Offset(at.dx - tp.width / 2, at.dy));
    }

    // Ticks at an even step that gives at most about six labels.
    final spanS = tl.spanMs / 1000;
    final step = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600].firstWhere((s) => spanS / s <= 6, orElse: () => 1200);
    final plotBottom = tl.rows.length * rowH;
    for (var s = 0; s * 1000 <= tl.spanMs; s += step) {
      final x = labelW + s * 1000 * scale;
      canvas.drawLine(Offset(x, 0), Offset(x, plotBottom), grid);
      text('${s}s', Offset(x, plotBottom + 3), color: Colors.grey.shade600);
    }

    for (var i = 0; i < tl.rows.length; i++) {
      final row = tl.rows[i];
      final y = i * rowH;
      text(row.name, Offset(labelW - 6, y + rowH / 2), size: 11, right: true);
      for (final b in row.bars) {
        final top = y + 4, h = rowH - 8;
        final x0 = labelW + b.startMs * scale;
        final x1 = labelW + b.inferStartMs * scale;
        final x2 = labelW + b.endMs * scale;
        // At least a hairline, so a very short image is still visible.
        canvas.drawRect(Rect.fromLTWH(x0, top, (x1 - x0).clamp(0.0, double.infinity), h), download);
        canvas.drawRect(Rect.fromLTWH(x1, top, (x2 - x1).clamp(0.6, double.infinity), h), infer);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) => old.tl != tl;
}
