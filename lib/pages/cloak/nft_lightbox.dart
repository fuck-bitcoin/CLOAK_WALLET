// NFT Lightbox — full-screen overlay with swipeable PageView gallery,
// flip-to-info card animation, and Send/Withdraw action bar.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../accounts.dart';
import '../../theme/zashi_tokens.dart';
import '../../widgets/nft_image_widget.dart';
import '../accounts/send.dart';
import '../utils.dart';
import 'nft_card_info.dart';

/// Lightweight data class representing one NFT in the lightbox gallery.
class NftLightboxItem {
  final String nftId;
  final String contract;
  final String? name;
  final String? collectionName;
  final String? imageUrl;
  final String? schemaName;
  final String? templateId;
  final Map<String, dynamic>? rawData;

  const NftLightboxItem({
    required this.nftId,
    required this.contract,
    this.name,
    this.collectionName,
    this.imageUrl,
    this.schemaName,
    this.templateId,
    this.rawData,
  });
}

/// Opens the NFT lightbox overlay.
///
/// [nfts] — the full list of NFTs available in the gallery.
/// [initialIndex] — which NFT to show first.
/// [isVault] — when true the action button reads "Withdraw"; otherwise "Send".
void showNftLightbox(
  BuildContext context, {
  required List<NftLightboxItem> nfts,
  required int initialIndex,
  required bool isVault,
}) {
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'NFT Lightbox',
    barrierColor: Colors.black.withOpacity(0.85),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (dialogCtx, anim, secAnim) {
      return _NftLightboxOverlay(
        nfts: nfts,
        initialIndex: initialIndex,
        isVault: isVault,
      );
    },
    transitionBuilder: (ctx, anim, secAnim, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Overlay widget
// ---------------------------------------------------------------------------

class _NftLightboxOverlay extends StatefulWidget {
  final List<NftLightboxItem> nfts;
  final int initialIndex;
  final bool isVault;

  const _NftLightboxOverlay({
    required this.nfts,
    required this.initialIndex,
    required this.isVault,
  });

  @override
  State<_NftLightboxOverlay> createState() => _NftLightboxOverlayState();
}

class _NftLightboxOverlayState extends State<_NftLightboxOverlay> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
  }

  void _goTo(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final zashi = Theme.of(context).extension<ZashiThemeExt>();
    final gradTop = zashi?.quickGradTop ?? const Color(0xFF3A3737);
    final gradBottom = zashi?.quickGradBottom ?? const Color(0xFF232121);
    final screenSize = MediaQuery.of(context).size;
    final cardWidth = screenSize.width * 0.82;
    final cardHeight = cardWidth * 1.25; // 4:5 aspect ratio

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // --- Close button (top-right) ---
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 12,
            child: _CircleIconButton(
              icon: Icons.close,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),

          // --- Card gallery ---
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: screenSize.width,
                  height: cardHeight,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // PageView
                      PageView.builder(
                        controller: _pageController,
                        itemCount: widget.nfts.length,
                        onPageChanged: _onPageChanged,
                        physics: const BouncingScrollPhysics(),
                        itemBuilder: (context, index) {
                          return Center(
                            child: SizedBox(
                              width: cardWidth,
                              height: cardHeight,
                              child: _NftCard(
                                nft: widget.nfts[index],
                                width: cardWidth,
                                height: cardHeight,
                              ),
                            ),
                          );
                        },
                      ),

                      // Left arrow
                      if (_currentIndex > 0)
                        Positioned(
                          left: (screenSize.width - cardWidth) / 2 - 4,
                          child: _CircleIconButton(
                            icon: Icons.chevron_left,
                            size: 36,
                            onTap: () => _goTo(_currentIndex - 1),
                          ),
                        ),

                      // Right arrow
                      if (_currentIndex < widget.nfts.length - 1)
                        Positioned(
                          right: (screenSize.width - cardWidth) / 2 - 4,
                          child: _CircleIconButton(
                            icon: Icons.chevron_right,
                            size: 36,
                            onTap: () => _goTo(_currentIndex + 1),
                          ),
                        ),
                    ],
                  ),
                ),

                // --- Dot indicators ---
                if (widget.nfts.length > 1) ...[
                  const SizedBox(height: 16),
                  _DotIndicators(
                    count: widget.nfts.length,
                    activeIndex: _currentIndex,
                  ),
                ],
              ],
            ),
          ),

          // --- Bottom action bar ---
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Close text button (left)
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: Colors.white.withOpacity(0.12),
                          border: Border.all(color: Colors.white.withOpacity(0.2)),
                        ),
                        child: const Text(
                          'Close',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),

                    // Send / Withdraw button (right)
                    GestureDetector(
                      onTap: () {
                        final nft = widget.nfts[_currentIndex];
                        Navigator.of(context).pop();
                        // Navigate to send page with NFT pre-selected
                        final sc = SendContext(
                          '', // address — user will fill in
                          7,
                          Amount(1, false), // NFT sends always amount=1
                          null,
                          null, // fx
                          null, // display
                          false, // fromThread
                          null, // threadIndex
                          null, // threadCid
                          null, // tokenSymbol
                          null, // tokenContract
                          null, // tokenPrecision
                          widget.isVault ? activeVaultHash : null,
                          nft.nftId,
                          nft.contract,
                          nft.imageUrl,
                        );
                        GoRouter.of(context).push(
                          '/account/quick_send',
                          extra: sc,
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 12,
                        ),
                        decoration: ShapeDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [gradTop, gradBottom],
                          ),
                          shape: const StadiumBorder(),
                        ),
                        child: Text(
                          widget.isVault ? 'Withdraw' : 'Send',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// NFT Card with flip-to-info
// ---------------------------------------------------------------------------

class _NftCard extends StatefulWidget {
  final NftLightboxItem nft;
  final double width;
  final double height;

  const _NftCard({
    required this.nft,
    required this.width,
    required this.height,
  });

  @override
  State<_NftCard> createState() => _NftCardState();
}

class _NftCardState extends State<_NftCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _showBack = false;
  bool _flipping = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _flip() {
    if (_flipping) return;
    _flipping = true;
    if (_showBack) {
      _controller.reverse().then((_) {
        setState(() { _showBack = false; _flipping = false; });
      });
      // Swap face at midpoint
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted) setState(() => _showBack = false);
      });
    } else {
      _controller.forward().then((_) {
        _flipping = false;
      });
      // Swap face at midpoint
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted) setState(() => _showBack = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // 0→1: front rotates 0→90°, then back rotates 90°→0°
        final value = _controller.value;

        // Custom curve: fast snap through the middle, gentle ease at ends
        final curved = _customFlipCurve(value);

        // Rotation: 0→π (front 0→π/2, then back π/2→0 mirrored)
        final angle = curved * math.pi;

        // Scale dip: shrinks to 0.94 at midpoint (edge-on), back to 1.0 at rest
        final scale = 1.0 - 0.06 * math.sin(curved * math.pi);

        // Shadow shifts during flip: moves laterally as card rotates
        final shadowX = 12.0 * math.sin(curved * math.pi);
        final shadowBlur = 24.0 + 8.0 * math.sin(curved * math.pi);

        return GestureDetector(
          onTap: _flip,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0015) // perspective
              ..rotateY(angle)
              ..scale(scale),
            child: Container(
              width: widget.width,
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _showBack
                    ? Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.rotationY(math.pi),
                        child: _buildBackContent(),
                      )
                    : _buildFrontContent(),
              ),
            ),
          ),
        );
      },
    );
  }

  // Custom curve: starts slow, snaps fast through the middle, eases out
  // Feels like a physical card with momentum
  double _customFlipCurve(double t) {
    // Piecewise: ease-in for first 40%, fast linear middle 20%, ease-out last 40%
    if (t < 0.4) {
      // Slow start (quadratic ease-in, maps 0-0.4 → 0-0.35)
      final n = t / 0.4;
      return 0.35 * n * n;
    } else if (t < 0.6) {
      // Fast snap through middle (linear, maps 0.4-0.6 → 0.35-0.65)
      return 0.35 + (t - 0.4) / 0.2 * 0.3;
    } else {
      // Gentle ease-out (quadratic, maps 0.6-1.0 → 0.65-1.0)
      final n = (t - 0.6) / 0.4;
      return 0.65 + 0.35 * (1.0 - (1.0 - n) * (1.0 - n));
    }
  }

  Widget _buildFrontContent() {
    return Container(
      color: const Color(0xFF1C1C1E),
      child: Stack(
        fit: StackFit.expand,
        children: [
          NftImageWidget(
            imageUrl: widget.nft.imageUrl,
            assetId: widget.nft.nftId,
            size: widget.width,
          ),
          // Bottom gradient with name + collection
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 32, 16, 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black.withOpacity(0.75)],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.nft.name != null)
                    Text(
                      widget.nft.name!,
                      style: const TextStyle(
                        color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                  if (widget.nft.collectionName != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.nft.collectionName!,
                      style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Info icon
          Positioned(
            right: 10, bottom: 10,
            child: _CircleIconButton(
              icon: Icons.info_outline, size: 32, onTap: _flip,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackContent() {
    return Container(
      color: const Color(0xFF1C1C1E),
      child: NftCardInfo(
        nftId: widget.nft.nftId,
        contract: widget.nft.contract,
        name: widget.nft.name,
        collectionName: widget.nft.collectionName,
        imageUrl: widget.nft.imageUrl,
        schemaName: widget.nft.schemaName,
        templateId: widget.nft.templateId,
        rawData: widget.nft.rawData,
        onFlipBack: _flip,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dot indicators
// ---------------------------------------------------------------------------

class _DotIndicators extends StatelessWidget {
  final int count;
  final int activeIndex;

  const _DotIndicators({required this.count, required this.activeIndex});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(count, (i) {
        final isActive = i == activeIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: isActive ? 8 : 6,
          height: isActive ? 8 : 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive ? Colors.white : Colors.white.withOpacity(0.3),
          ),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Reusable semi-transparent circle icon button
// ---------------------------------------------------------------------------

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _CircleIconButton({
    required this.icon,
    required this.onTap,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withOpacity(0.7),
          border: Border.all(color: Colors.white.withOpacity(0.3)),
        ),
        child: Icon(
          icon,
          color: Colors.white,
          size: size * 0.55,
        ),
      ),
    );
  }
}
