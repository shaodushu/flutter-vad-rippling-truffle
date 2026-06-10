import 'dart:math';
import 'package:flutter/material.dart';

class WaveformView extends StatelessWidget {
  /// Audio level 0.0 - 1.0 from LiveKit participant.
  final double level;

  /// Animation phase 0.0 - 1.0, advances each frame to create movement.
  final double phase;

  final Color color;

  const WaveformView({
    super.key,
    this.level = 0.0,
    this.phase = 0.0,
    this.color = Colors.blue,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 48),
      painter: _WaveformPainter(level: level, phase: phase, color: color),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final double level;
  final double phase;
  final Color color;

  _WaveformPainter({
    required this.level,
    required this.phase,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final paint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeCap = StrokeCap.round;

    const barCount = 40;
    const spacing = 2.0;
    final barWidth = (size.width - (barCount - 1) * spacing) / barCount;
    final centerY = size.height / 2;
    final baseLevel = level.clamp(0.0, 1.0);
    final phaseRad = phase * 2 * pi;

    for (int i = 0; i < barCount; i++) {
      double barHeight;

      if (baseLevel < 0.005) {
        // Idle: all bars the same low height
        barHeight = 4.0;
      } else {
        // Active: bell-shaped envelope with travelling wave
        // Bars at the edges are shorter (bell curve), middle bars are taller
        final envelope = sin(i * pi / barCount);
        // Each bar oscillates to create a travelling wave effect
        final wave = 0.5 + 0.5 * sin(i * 0.5 - phaseRad * 2);
        barHeight = max(2.0, baseLevel * envelope * wave * size.height * 0.9);
      }

      final x = i * (barWidth + spacing);

      paint.strokeWidth = barWidth;
      canvas.drawLine(
        Offset(x, centerY - barHeight / 2),
        Offset(x, centerY + barHeight / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.level != level || oldDelegate.phase != phase;
}
