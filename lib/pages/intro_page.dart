import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router.dart' show postIntroDestination;
import '../widgets/star_field.dart';
import '../widgets/cloak_orb.dart';

/// Cinematic intro: 3D orb fades in from black, then "ANINO WALLET" and
/// "WE BUILD IN THE DARK" appear. Plays every launch. After 4s auto-fades
/// to black, then navigates to balance page or Create/Restore splash.
/// Tap anywhere to skip (with quick fade).
class IntroPage extends StatefulWidget {
  const IntroPage({super.key});

  @override
  State<IntroPage> createState() => _IntroPageState();
}

class _IntroPageState extends State<IntroPage>
    with TickerProviderStateMixin {
  late final AnimationController _reveal;
  late final AnimationController _fadeOut;
  late final Animation<double> _orbReveal;
  late final Animation<double> _textOpacity;
  late final Animation<double> _subtitleOpacity;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();

    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    );

    _fadeOut = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    // Orb reveals over 0→3.5s (interval 0.0→0.875)
    _orbReveal = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _reveal,
        curve: const Interval(0.0, 0.875),
      ),
    );

    // "ANINO WALLET" fades in 2→3s (interval 0.5→0.75)
    _textOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _reveal,
        curve: const Interval(0.5, 0.75, curve: Curves.easeIn),
      ),
    );

    // "WE BUILD IN THE DARK" fades in 2.5→3.5s (interval 0.625→0.875)
    _subtitleOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _reveal,
        curve: const Interval(0.625, 0.875, curve: Curves.easeIn),
      ),
    );

    _reveal.forward();
    _reveal.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _beginFadeOut();
      }
    });
  }

  /// After reveal completes, fade everything to black then navigate.
  void _beginFadeOut() {
    if (_navigated || !mounted) return;
    _navigated = true;
    _fadeOut.forward().then((_) {
      if (mounted) GoRouter.of(context).go(postIntroDestination);
    });
  }

  /// Tap to skip — quick 300ms fade then navigate.
  void _skip() {
    if (_navigated || !mounted) return;
    _navigated = true;
    _reveal.stop();
    _fadeOut.duration = const Duration(milliseconds: 300);
    _fadeOut.forward().then((_) {
      if (mounted) GoRouter.of(context).go(postIntroDestination);
    });
  }

  @override
  void dispose() {
    _reveal.dispose();
    _fadeOut.dispose();
    super.dispose();
  }

  static const _josefin = 'JosefinSans';

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _skip,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: AnimatedBuilder(
          animation: Listenable.merge([_reveal, _fadeOut]),
          builder: (context, _) {
            final fadeOutOpacity = 1.0 - _fadeOut.value;
            final time = _reveal.value * 4.0;
            return Opacity(
              opacity: fadeOutOpacity,
              child: Stack(
                children: [
                  const Positioned.fill(child: StarField()),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CloakOrb(
                          size: 420,
                          reveal: _orbReveal.value,
                          time: time,
                        ),
                        const SizedBox(height: 24),
                        Opacity(
                          opacity: _textOpacity.value,
                          child: const Text(
                            'ANINO WALLET',
                            style: TextStyle(
                              fontFamily: _josefin,
                              fontWeight: FontWeight.w100,
                              fontSize: 28,
                              color: Colors.white,
                              letterSpacing: 6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Opacity(
                          opacity: _subtitleOpacity.value,
                          child: Text(
                            'WE BUILD IN THE DARK',
                            style: TextStyle(
                              fontFamily: _josefin,
                              fontWeight: FontWeight.w200,
                              fontSize: 13,
                              color: Colors.white.withOpacity(0.5),
                              letterSpacing: 6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
