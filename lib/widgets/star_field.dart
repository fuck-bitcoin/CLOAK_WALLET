import 'dart:math';
import 'package:flutter/material.dart';

/// Twinkling star field background using CustomPainter.
/// Uses seeded Random(42) for consistent star positions across pages.
class StarField extends StatefulWidget {
  const StarField({super.key});

  @override
  State<StarField> createState() => _StarFieldState();
}

class _StarFieldState extends State<StarField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: _StarPainter(_controller.value),
          size: Size.infinite,
        );
      },
    );
  }
}

class _Star {
  final double x; // 0..1
  final double y; // 0..1
  final double radius; // 0.3..1.5
  final double phase; // 0..2pi — offsets twinkle cycle

  const _Star(this.x, this.y, this.radius, this.phase);
}

class _StarPainter extends CustomPainter {
  _StarPainter(this.time);

  final double time;

  // Immutable star data — computed once, shared across all frames.
  static final List<_Star> _stars = _generateStars();

  static List<_Star> _generateStars() {
    final rng = Random(42);
    return List.generate(120, (_) {
      return _Star(
        rng.nextDouble(),
        rng.nextDouble(),
        0.3 + rng.nextDouble() * 1.2,
        rng.nextDouble() * 2 * pi,
      );
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    // time goes 0→1 over 10s, so full twinkle cycle = ~6s per star
    final t = time * 2 * pi;

    for (final star in _stars) {
      // Sinusoidal twinkle: base 0.15 + range 0.85
      final brightness = 0.15 + 0.85 * ((sin(t * 0.6 + star.phase) + 1) / 2);
      paint.color = Colors.white.withOpacity(brightness * 0.7);
      canvas.drawCircle(
        Offset(star.x * size.width, star.y * size.height),
        star.radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StarPainter old) => old.time != time;
}
