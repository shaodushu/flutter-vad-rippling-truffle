import 'dart:math';
import 'package:flutter/material.dart';

class WaveformView extends StatelessWidget {
  final double level;
  final Color color;

  const WaveformView({
    super.key,
    this.level = 0.0,
    this.color = Colors.blue,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 48),
      painter: _WaveformPainter(level: level, color: color),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final double level;
  final Color color;

  _WaveformPainter({required this.level, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (level <= 0) return;

    final paint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final barCount = 40;
    final barWidth = (size.width - (barCount - 1) * 2) / barCount;
    final centerY = size.height / 2;

    for (int i = 0; i < barCount; i++) {
      final normalizedLevel = level * (0.3 + 0.7 * sin(i * pi / barCount));
      final barHeight = max(2.0, normalizedLevel * size.height * 0.9);
      final x = i * (barWidth + 2);

      canvas.drawLine(
        Offset(x, centerY - barHeight / 2),
        Offset(x, centerY + barHeight / 2),
        paint..strokeWidth = barWidth,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.level != level;
}
