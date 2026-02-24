import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Renders the CLOAK orb using a GLSL fragment shader that replicates
/// the Three.js logo animation from index.html (raymarched sphere + torus
/// ring with bloom glow and ACES Filmic tonemapping).
class CloakOrb extends StatefulWidget {
  final double size;
  final double reveal; // 0→1 fade-in progress
  final double time; // elapsed seconds, drives subtle animation

  const CloakOrb({
    super.key,
    required this.size,
    required this.reveal,
    required this.time,
  });

  @override
  State<CloakOrb> createState() => _CloakOrbState();
}

class _CloakOrbState extends State<CloakOrb> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  Future<void> _loadShader() async {
    final program = await ui.FragmentProgram.fromAsset('shaders/orb.frag');
    if (mounted) {
      setState(() => _shader = program.fragmentShader());
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: _shader == null
          ? const SizedBox.shrink() // black frame while shader loads (<100ms)
          : CustomPaint(
              painter: _OrbPainter(
                shader: _shader!,
                reveal: widget.reveal,
                time: widget.time,
              ),
            ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final ui.FragmentShader shader;
  final double reveal;
  final double time;

  _OrbPainter({
    required this.shader,
    required this.reveal,
    required this.time,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Set uniforms: uSize (vec2), uTime (float), uReveal (float)
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, time);
    shader.setFloat(3, reveal);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.reveal != reveal || old.time != time;
}
