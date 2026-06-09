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
    final paint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final barCount = 40;
    final barWidth = (size.width - (barCount - 1) * 2) / barCount;
    final centerY = size.height / 2;
    final idleDeadzone = 0.005; // below this, show static idle pattern

    final isIdle = level <= idleDeadzone;

    for (int i = 0; i < barCount; i++) {
      double barHeight;

      if (isIdle) {
        // Static low bars — slight random-looking variation based on index
        final idleFactor =
            0.08 + 0.06 * sin(i * 0.3) + 0.04 * sin(i * 0.7 + 1.2);
        barHeight = max(2.0, idleFactor * size.height * 0.9);
      } else {
        final normalizedLevel =
            level * (0.3 + 0.7 * sin(i * pi / barCount));
        barHeight = max(2.0, normalizedLevel * size.height * 0.9);
      }

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
