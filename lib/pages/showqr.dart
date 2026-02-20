import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../generated/intl/messages.dart';
import 'utils.dart';
import '../accounts.dart';
import '../coin/coins.dart';
import '../cloak/cloak_wallet_manager.dart';
import '../theme/zashi_tokens.dart';

class ShowQRPage extends StatefulWidget {
  final String title;
  final String text;
  ShowQRPage({required this.title, required this.text});

  @override
  State<ShowQRPage> createState() => _ShowQRPageState();
}

class _ShowQRPageState extends State<ShowQRPage> {
  bool _expanded = false;
  final GlobalKey _qrBoundaryKey = GlobalKey();
  Uint8List? _cachedQrPng;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureQrPng(widget.text);
    });
  }

  @override
  void didUpdateWidget(covariant ShowQRPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _cachedQrPng = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureQrPng(widget.text);
      });
    }
  }

  Future<Uint8List> _ensureQrPng(String data) async {
    if (_cachedQrPng != null) return _cachedQrPng!;
    // Snapshot only: wait inside _captureQrPngFromBoundary until ready, then return
    final captured = await _captureQrPngFromBoundary();
    _cachedQrPng = captured;
    return captured;
  }

  Future<Uint8List> _captureQrPngFromBoundary() async {
    final boundary = _qrBoundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      throw Exception('QR boundary not ready');
    }
    // Wait up to ~3 seconds for a stable first paint (AnimatedSwitcher fade-in, glyph load, etc.)
    for (int i = 0; i < 60; i++) {
      if (!boundary.debugNeedsPaint) break;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final image = await boundary.toImage(pixelRatio: dpr.clamp(1.0, 3.0));
    final ByteData? byteData = await image.toByteData(format: ImageByteFormat.png);
    if (byteData == null) {
      throw Exception('Failed to encode QR snapshot');
    }
    return byteData.buffer.asUint8List();
  }

  Future<void> _waitForStableFile(File file) async {
    int last = -1;
    for (int i = 0; i < 10; i++) {
      try {
        final len = await file.length();
        if (len > 0 && len == last) return;
        last = len;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final address = widget.text;
    final qrSize = MediaQuery.of(context).size.width * 0.66;
    // Vertical centering via LayoutBuilder (no manual shift)
    // Center glyph colorized (replacing embedded asset)

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
        title: null,
        centerTitle: false,
      ),
      bottomNavigationBar: null,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: () => _showFullscreenQr(address),
                          child: RepaintBoundary(
                            key: _qrBoundaryKey,
                            child: Container(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              padding: const EdgeInsets.all(16),
                              child: Center(
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Container(
                                      width: qrSize * 0.7 * 1.35,
                                      height: qrSize * 0.7 * 1.35,
                                      decoration: BoxDecoration(
                                        color: Colors.transparent,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: Colors.white.withOpacity(0.2), width: 1.0),
                                      ),
                                    ),
                                    QrImage(
                                      data: address,
                                      size: qrSize * 0.7,
                                      backgroundColor: Colors.white,
                                    ),
                                    _QrCoinOverlay(size: 48, iconSize: 28),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const Gap(16),
                        _ShieldedBadge(),
                        const Gap(12),
                        Text(
                          widget.title,
                          style: (theme.textTheme.titleLarge ?? const TextStyle()).copyWith(
                            fontFamily: theme.textTheme.displaySmall?.fontFamily,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const Gap(8),
                        GestureDetector(
                          onTap: () => setState(() => _expanded = !_expanded),
                          onLongPress: () {
                            Clipboard.setData(ClipboardData(text: address));
                            showSnackBar(s.textCopiedToClipboard(widget.title));
                          },
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: AnimatedSize(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeInOut,
                              child: Text(
                                address,
                                maxLines: _expanded ? null : 2,
                                overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                                textAlign: TextAlign.start,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Builder(builder: (context) {
                        final t2 = Theme.of(context);
                        final String? balanceFontFamily = t2.textTheme.displaySmall?.fontFamily;
                        final Color balanceCursorColor =
                            t2.extension<ZashiThemeExt>()?.balanceAmountColor ?? const Color(0xFFBDBDBD);
                        return Align(
                          alignment: Alignment.center,
                          child: FractionallySizedBox(
                            widthFactor: 0.96,
                            child: SizedBox(
                              height: 48,
                              child: Material(
                                color: balanceCursorColor,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () => _shareQr(address, widget.title, context),
                                  child: Center(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.share, color: Colors.black),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Share QR Code',
                                          style: (t2.textTheme.titleSmall ?? const TextStyle()).copyWith(
                                            fontFamily: balanceFontFamily,
                                            fontWeight: FontWeight.w600,
                                            color: t2.colorScheme.background,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                      const Gap(8),
                      Align(
                        alignment: Alignment.center,
                        child: FractionallySizedBox(
                          widthFactor: 0.96,
                          child: SizedBox(
                            height: 48,
                            child: TextButton.icon(
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: address));
                                showSnackBar(s.textCopiedToClipboard(widget.title));
                              },
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
                              ),
                              icon: SvgPicture.string(
                                _COPY_GLYPH,
                                width: 20,
                                height: 20,
                                colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                              ),
                              label: const Text('Copy Address', style: TextStyle(color: Colors.white)),
                            ),
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
    );
  }

  Future<void> _shareQr(String data, String title, BuildContext originContext) async {
    final Uint8List bytes = await _ensureQrPng(data);
    await shareQrImage(originContext, data: data, title: title, pngBytes: bytes);
  }

  Future<void> _showFullscreenQr(String data) async {
    final size = MediaQuery.of(context).size.width - 44;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 64),
        backgroundColor: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: const SizedBox.shrink(),
              ),
            ),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(6),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    QrImage(
                      data: data,
                      size: size,
                      backgroundColor: Colors.white,
                    ),
                    _QrCoinOverlay(size: 64, iconSize: 36),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrCoinOverlay extends StatelessWidget {
  final double size;
  final double iconSize;
  const _QrCoinOverlay({required this.size, required this.iconSize});

  @override
  Widget build(BuildContext context) {
    final isCloak = CloakWalletManager.isCloak(aa.coin);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isCloak ? const Color(0xFF0D1B2A) : const Color(0xFFF4B728),
      ),
      alignment: Alignment.center,
      child: SvgPicture.asset(
        isCloak ? 'assets/icons/cloak_glyph.svg' : 'assets/icons/cloak_glyph.svg',
        width: iconSize,
        height: iconSize,
        theme: const SvgTheme(currentColor: Colors.white),
      ),
    );
  }
}

class _ShieldedBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isCloak = CloakWalletManager.isCloak(aa.coin);

    // CLOAK: deep navy pill; Zcash: warm orange pill
    const Color cloakAccent = Color(0xFF1A3A5C);
    const Color shieldedAccent = Color(0xFFC99111);
    final Color accent = isCloak ? cloakAccent : shieldedAccent;
    final Color fill = Color.lerp(Colors.white, accent, 0.70)!;
    final Color content = Colors.white;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(50),
        border: Border.all(color: accent),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.gpp_good, size: 18, color: content),
          const Gap(8),
          Text('Private', style: t.textTheme.labelMedium?.copyWith(color: content)),
        ],
      ),
    );
  }
}

Future<void> saveQRImage(String data, String title) async {
  final code = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.L);
  code.make();

  const int pixelsPerModule = 10;
  const int margin = 32;
  final int modules = code.moduleCount;
  final int imageSize = modules * pixelsPerModule + margin * 2;

  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);

  final Paint whitePaint = Paint()
    ..color = Colors.white
    ..style = PaintingStyle.fill;
  final Paint blackPaint = Paint()
    ..color = Colors.black
    ..style = PaintingStyle.fill;

  canvas.drawRect(Rect.fromLTWH(0, 0, imageSize.toDouble(), imageSize.toDouble()), whitePaint);
  canvas.translate(margin.toDouble(), margin.toDouble());

  for (int y = 0; y < modules; y++) {
    for (int x = 0; x < modules; x++) {
      if (code.isDark(x, y)) {
        canvas.drawRect(
          Rect.fromLTWH(
            (x * pixelsPerModule).toDouble(),
            (y * pixelsPerModule).toDouble(),
            pixelsPerModule.toDouble(),
            pixelsPerModule.toDouble(),
          ),
          blackPaint,
        );
      }
    }
  }

  final image = await recorder.endRecording().toImage(imageSize, imageSize);
  final ByteData? byteData = await image.toByteData(format: ImageByteFormat.png);
  final Uint8List pngBytes = byteData!.buffer.asUint8List();
  await saveFileBinary(pngBytes, 'qr.png', title);
}

Future<Uint8List> _generateQrPngBytes(String data) async {
  final painter = QrPainter(
    data: data,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.L,
    gapless: true,
    color: Colors.black,
    emptyColor: Colors.white,
  );
  final ByteData? imageData = await painter.toImageData(512, format: ImageByteFormat.png);
  return imageData!.buffer.asUint8List();
}

// Rounded-corner copy glyph (matches Receive card, tight viewBox)
const String _COPY_GLYPH =
    '<svg viewBox="0.5 0.5 17.5 17.5" xmlns="http://www.w3.org/2000/svg">\n'
    '  <g transform="translate(1.8,1.8)">\n'
    '    <path d="M4.167 10C3.545 10 3.235 10 2.99 9.898C2.663 9.763 2.404 9.503 2.268 9.177C2.167 8.932 2.167 8.621 2.167 8V3.466C2.167 2.72 2.167 2.346 2.312 2.061C2.44 1.81 2.644 1.606 2.895 1.478C3.18 1.333 3.553 1.333 4.3 1.333H8.833C9.455 1.333 9.765 1.333 10.01 1.434C10.337 1.57 10.597 1.829 10.732 2.156C10.833 2.401 10.833 2.712 10.833 3.333M8.967 14.666H13.367C14.113 14.666 14.487 14.666 14.772 14.521C15.023 14.393 15.227 14.189 15.355 13.938C15.5 13.653 15.5 13.28 15.5 12.533V8.133C15.5 7.386 15.5 7.013 15.355 6.728C15.227 6.477 15.023 6.273 14.772 6.145C14.487 6 14.113 6 13.367 6H8.967C8.22 6 7.847 6 7.561 6.145C7.311 6.273 7.107 6.477 6.979 6.728C6.833 7.013 6.833 7.386 6.833 8.133V12.533C6.833 13.28 6.833 13.653 6.979 13.938C7.107 14.189 7.311 14.393 7.561 14.521C7.847 14.666 8.22 14.666 8.967 14.666Z" stroke="#231F20" stroke-width="1.33333" stroke-linecap="round" stroke-linejoin="round" fill="none"/>\n'
    '  </g>\n'
    '</svg>';

