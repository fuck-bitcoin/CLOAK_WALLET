import 'package:flutter/material.dart';

/// A reusable widget for displaying NFT images from IPFS, local assets, or
/// a diamond-icon fallback. Handles loading, error, and loaded states with
/// smooth transitions. Clipping is handled by the parent widget.
class NftImageWidget extends StatefulWidget {
  /// Full HTTPS URL (e.g. IPFS gateway), `asset:path` for local bundled
  /// images, or null for the placeholder fallback.
  final String? imageUrl;

  /// Asset ID used for the fallback display text.
  final String assetId;

  /// Optional explicit size for cacheWidth/cacheHeight (memory efficiency).
  final double? size;

  /// Image alignment within the box when using BoxFit.cover.
  /// Defaults to center. Use Alignment.topCenter to show the top of the image.
  final Alignment alignment;

  const NftImageWidget({
    required this.imageUrl,
    required this.assetId,
    this.size,
    this.alignment = Alignment.center,
    super.key,
  });

  @override
  State<NftImageWidget> createState() => _NftImageWidgetState();
}

class _NftImageWidgetState extends State<NftImageWidget> {
  // Removed SingleTickerProviderStateMixin and _pulseController — the
  // continuously-running animation (60fps) forced constant GPU recompositing
  // which caused black screen flicker on Intel UHD 620. Static placeholder
  // is sufficient for the brief loading period.

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final url = widget.imageUrl;

    if (url == null) {
      return _placeholder(onSurface);
    }

    if (url.startsWith('asset:')) {
      return _buildAssetImage(url.substring(6), onSurface);
    }

    return _buildNetworkImage(url, onSurface);
  }

  Widget _buildAssetImage(String assetPath, Color onSurface) {
    return Image.asset(
      assetPath,
      fit: BoxFit.cover,
      alignment: widget.alignment,
      frameBuilder: _fadeFrameBuilder,
      errorBuilder: (_, __, ___) => _placeholder(onSurface),
    );
  }

  Widget _buildNetworkImage(String url, Color onSurface) {
    final cacheSize = widget.size != null ? (widget.size! * 2).toInt() : null;

    return Image.network(
      url,
      fit: BoxFit.cover,
      alignment: widget.alignment,
      cacheWidth: cacheSize,
      cacheHeight: cacheSize,
      frameBuilder: _fadeFrameBuilder,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return _loadingPlaceholder(onSurface);
      },
      errorBuilder: (_, __, ___) => _placeholder(onSurface),
    );
  }

  Widget _fadeFrameBuilder(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSynchronouslyLoaded,
  ) {
    // Approach #14: removed AnimatedOpacity to eliminate saveLayer() calls
    // that caused black screen on first NFT tab render (10+ simultaneous
    // saveLayer ops overwhelmed Intel UHD 620 GPU compositor).
    if (wasSynchronouslyLoaded || frame != null) return child;
    return const SizedBox.shrink(); // brief placeholder until first frame decoded
  }

  Widget _loadingPlaceholder(Color onSurface) {
    return Container(
      color: onSurface.withOpacity(0.05),
      child: Center(
        child: Icon(
          Icons.diamond_outlined,
          size: 32,
          color: onSurface.withOpacity(0.5),
        ),
      ),
    );
  }

  Widget _placeholder(Color onSurface) {
    return Center(
      child: Icon(
        Icons.diamond_outlined,
        size: 40,
        color: onSurface.withOpacity(0.3),
      ),
    );
  }
}
