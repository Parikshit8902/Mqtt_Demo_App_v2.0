// Custom painter for drawing bounding boxes with scaling and labels
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class BoundingBoxPainter extends CustomPainter {
  final List<dynamic> detections;
  final Size? imageSize; // original image size in pixels
  final Color color; // default color for bounding boxes
  final bool showLabels; // flag to show/hide labels
  final Map<String, Color> _classColors = {}; // cache for random colors per class

  BoundingBoxPainter(this.detections, this.imageSize, {this.color = Colors.red, this.showLabels = true});

  Color _getRandomColor(String className) {
    if (!_classColors.containsKey(className)) {
      final random = Random(className.hashCode); // seed with className for consistency
      _classColors[className] = Color.fromRGBO(
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        1.0,
      );
    }
    return _classColors[className]!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize == null || detections.isEmpty) return;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    // Compute scale and offset to fit the image into the available size while preserving aspect ratio
    final imageAspect = imageSize!.width / imageSize!.height;
    final boxAspect = size.width / size.height;

    double scale;
    double offsetX = 0;
    double offsetY = 0;

    if (imageAspect > boxAspect) {
      // fit by width
      scale = size.width / imageSize!.width;
      offsetY = (size.height - imageSize!.height * scale) / 2;
    } else {
      // fit by height
      scale = size.height / imageSize!.height;
      offsetX = (size.width - imageSize!.width * scale) / 2;
    }

    for (final d in detections) {
      try {
        final x1 = (d['x1'] as num).toDouble() * scale + offsetX;
        final y1 = (d['y1'] as num).toDouble() * scale + offsetY;
        final x2 = (d['x2'] as num).toDouble() * scale + offsetX;
        final y2 = (d['y2'] as num).toDouble() * scale + offsetY;

        final className = (d['className'] ?? d['label'] ?? 'obj').toString();
        final classColor = _getRandomColor(className);

        final paint = Paint()
          ..color = classColor
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;

        final rect = Rect.fromLTRB(x1, y1, x2, y2);
        final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4.0));
        canvas.drawRRect(rrect, paint);

        if (showLabels) {
          final confidence = d.containsKey('confidence') ? (d['confidence'] as num).toDouble() : null;
          final label = confidence != null ? '$className ${(confidence * 100).toStringAsFixed(1)}%' : className;

          textPainter.text = TextSpan(
            text: label,
            style: GoogleFonts.plusJakartaSans(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              backgroundColor: classColor.withAlpha((0.8 * 255).toInt()),
            ),
          );
          textPainter.layout();
          textPainter.paint(canvas, Offset(x1, (y1 - textPainter.height).clamp(0.0, size.height - textPainter.height)));
        }
      } catch (_) {
        // ignore malformed detection entry
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
