import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr/qr.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'widgets.dart';

import '../../accounts.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../generated/intl/messages.dart';
import 'main/qr_address.dart';
import 'utils.dart';
import '../../store2.dart';
import '../../appsettings.dart';
import '../../theme/zashi_tokens.dart';

enum _RequestStage { amount, memo, qr }

class RequestPage extends StatefulWidget {
  final int? initialAddressMode; // 0 main UA, 4 diversified UA (rotating), 1 transparent, etc.
  final Map<String, dynamic>? threadContext; // Thread context when launched from chat
  const RequestPage({super.key, this.initialAddressMode, this.threadContext});

  @override
  State<RequestPage> createState() => _RequestPageState();
}

class _RequestPageState extends State<RequestPage> {
  _RequestStage _stage = _RequestStage.amount;
  bool _forceTransparent = false; // true when initialAddressMode indicates t-addr flow
  bool _slideForwards = true; // controls AnimatedSwitcher slide direction
  final GlobalKey _qrBoundaryKey = GlobalKey();
  Uint8List? _cachedQrPng;

  // Amount entry state
  String _amountStr = '0';
  bool _isFiat = false; // false = ZEC, true = Fiat (e.g., USD)

  // Memo entry
  final TextEditingController _memoCtrl = TextEditingController();
  // Snapshot of amount (in ZEC) to display on memo page
  String? _memoAmountZec;

  // Computed request
  late String _requestAddress;
  String? _requestUri;
  // FX sync state for USD freshness gating
  bool _syncingFx = false;
  bool _prevFxFresh = false;
  Timer? _fxFreshTimer;
  
  // Thread context (when launched from chat)
  bool _fromThread = false;
  int? _threadIndex;
  String? _threadCid;
  String? _threadAddress;
  String? _threadDisplayName;

  @override
  void initState() {
    super.initState();
    _forceTransparent = (widget.initialAddressMode == 1);
    _requestAddress = _resolveAddress(widget.initialAddressMode);
    _prevFxFresh = _isFxFreshNow();
    _fxFreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkFxFreshTransition());
    
    // Initialize thread context if present
    if (widget.threadContext != null) {
      _fromThread = widget.threadContext!['fromThread'] == true;
      _threadIndex = widget.threadContext!['threadIndex'] as int?;
      _threadCid = widget.threadContext!['threadCid'] as String?;
      _threadAddress = widget.threadContext!['threadAddress'] as String?;
      _threadDisplayName = widget.threadContext!['threadDisplayName'] as String?;
    }
  }

  String _resolveAddress(int? mode) {
    // CLOAK: always use the stable default address
    if (CloakWalletManager.isCloak(aa.coin)) {
      return aa.diversifiedAddress.isNotEmpty
          ? aa.diversifiedAddress
          : (CloakWalletManager.getDefaultAddress() ?? '');
    }
    // Non-CLOAK address modes no longer supported
    if (aa.id == 0) return '';
    return aa.diversifiedAddress;
  }

  bool _isTransparentAddress(String addr) {
    // CLOAK addresses are always shielded
    return false;
  }

  @override
  void dispose() {
    _fxFreshTimer?.cancel();
    super.dispose();
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

  Future<Uint8List> _generateQrPngBytesManual(String data) async {
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
    return byteData!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return WillPopScope(
      onWillPop: () async {
        if (_stage == _RequestStage.amount) return true;
        setState(() {
          _slideForwards = false;
          if (_stage == _RequestStage.qr) {
            // From QR: go back to amount for transparent, memo otherwise
            _stage = _isTransparentAddress(_requestAddress) ? _RequestStage.amount : _RequestStage.memo;
          } else {
            _stage = _RequestStage.amount;
          }
        });
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Builder(builder: (context) {
            final t = Theme.of(context);
            final base = t.appBarTheme.titleTextStyle ??
                t.textTheme.titleLarge ??
                t.textTheme.titleMedium ??
                t.textTheme.bodyMedium;
            final reduced = (base?.fontSize != null)
                ? base!.copyWith(fontSize: base.fontSize! * 0.75)
                : base;
            return Text(
              'REQUEST',
              style: reduced,
            );
          }),
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (_stage == _RequestStage.amount) {
                GoRouter.of(context).pop();
              } else {
                setState(() {
                  _slideForwards = false;
                  if (_stage == _RequestStage.qr) {
                    _stage = _isTransparentAddress(_requestAddress) ? _RequestStage.amount : _RequestStage.memo;
                  } else {
                    _stage = _RequestStage.amount;
                  }
                });
              }
            },
          ),
        ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            switchInCurve: Curves.easeInOutCubic,
            switchOutCurve: Curves.easeInOutCubic,
            layoutBuilder: (currentChild, previousChildren) {
              // Always draw previous below and current on top to prevent any flash/blink.
              final children = <Widget>[];
              children.addAll(previousChildren);
              if (currentChild != null) children.add(currentChild);
              return Stack(alignment: Alignment.topLeft, children: children);
            },
            transitionBuilder: (child, anim) {
              // Pure cross-fade for both incoming and outgoing children
              return FadeTransition(opacity: anim, child: child);
            },
            child: _buildStage(context, key: ValueKey(_stage.name)),
          ),
        ),
      ),
    );
  }

  Widget _buildStage(BuildContext context, {Key? key}) {
    switch (_stage) {
      case _RequestStage.amount:
        return _AmountStage(
          key: key,
          amountText: _amountStr,
          isFiat: _isFiat,
          onDigit: _onDigit,
          onDot: _onDot,
          onDelete: _onDelete,
          onSwitchCurrency: _switchCurrency,
          isFxFresh: _isFxFreshNow(),
          isSyncing: _syncingFx,
          onSync: _triggerSyncFx,
          onNext: _onAmountNext,
        );
      case _RequestStage.memo:
        return _MemoStage(
          key: key,
          memoCtrl: _memoCtrl,
          amountZecStr: _memoAmountZec ?? '0',
          showMemo: !(_forceTransparent || _isTransparentAddress(_requestAddress)),
          onBack: () => setState(() => _stage = _RequestStage.amount),
          onRequest: _onMemoDone,
        );
      case _RequestStage.qr:
        return _QrStage(
          key: key,
          address: _requestAddress,
          requestUri: _requestUri ?? '',
          amountZecStr: _memoAmountZec ?? '0',
          qrBoundaryKey: _qrBoundaryKey,
          onShare: () => _shareQrLikeShowQr(context, _requestUri ?? _requestAddress, 'Payment Request'),
          onClose: () => GoRouter.of(context).pop(),
        );
    }
  }

  bool _isFxFreshNow() {
    final ts = marketPrice.timestamp;
    return ts != null && marketPrice.price != null && DateTime.now().difference(ts).inSeconds <= 120;
  }

  Future<void> _triggerSyncFx() async {
    if (_syncingFx) return;
    setState(() => _syncingFx = true);
    try {
      await marketPrice.update().timeout(const Duration(seconds: 8));
    } catch (_) {
      // ignore; UI will continue to show refresh icon until fresh
    } finally {
      if (mounted) setState(() => _syncingFx = false);
    }
  }

  void _checkFxFreshTransition() {
    final fresh = _isFxFreshNow();
    // Only handle stale fiat during the amount entry stage
    if (_stage != _RequestStage.amount) {
      _prevFxFresh = fresh;
      if (mounted) setState(() {});
      return;
    }
    if (_prevFxFresh && !fresh && _isFiat) {
      setState(() {
        _isFiat = false;
        _amountStr = '0';
      });
      _showStaleDialog();
    }
    _prevFxFresh = fresh;
    if (mounted) setState(() {});
  }

  void _showStaleDialog() {
    if (!mounted) return;
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final titleBase = t.textTheme.titleLarge ?? const TextStyle();
    final bodyBase = t.textTheme.bodyMedium ?? const TextStyle();
    final titleStyle = titleBase.copyWith(
      color: balanceTextColor,
      fontFamily: balanceFontFamily,
      fontWeight: FontWeight.w400,
    );
    final bodyStyle = bodyBase.copyWith(
      color: balanceTextColor,
      fontFamily: balanceFontFamily,
      fontWeight: FontWeight.w400,
    );

    // Leading icon removed per design for this modal

    final Color primaryFill = balanceTextColor;
    final BorderRadius radius = BorderRadius.circular(14);
    Widget primaryButton({required String label, required VoidCallback onTap}) {
      return SizedBox(
        width: double.infinity,
        height: 48,
        child: Material(
          color: primaryFill,
          shape: RoundedRectangleBorder(borderRadius: radius),
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Center(
              child: Text(
                S.of(context).ok,
                style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                  fontFamily: balanceFontFamily,
                  fontWeight: FontWeight.w600,
                  color: t.colorScheme.background,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final String coinTicker = CloakWalletManager.isCloak(aa.coin) ? 'CLOAK' : 'ZEC';
    final String title = 'Stale fiat price!';
    final String body = '$coinTicker to fiat pricing is stale. Tap on the refresh icon to get the latest fiat pricing.';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: titleStyle),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body, style: bodyStyle),
            const SizedBox(height: 16),
            primaryButton(label: S.of(context).ok, onTap: () => GoRouter.of(ctx).pop(true)),
          ],
        ),
        actions: const [],
      ),
    );
  }

  void _onDigit(int d) {
    setState(() {
      if (_amountStr == '0') {
        _amountStr = d.toString();
      } else {
        _amountStr += d.toString();
      }
      _amountStr = _sanitizeAmount(_amountStr);
    });
  }

  void _onDot() {
    setState(() {
      if (!_amountStr.contains('.')) {
        _amountStr += '.';
      }
      _amountStr = _sanitizeAmount(_amountStr);
    });
  }

  void _onDelete() {
    setState(() {
      if (_amountStr.length <= 1) {
        _amountStr = '0';
      } else {
        _amountStr = _amountStr.substring(0, _amountStr.length - 1);
      }
      if (_amountStr == '' || _amountStr == '.') _amountStr = '0';
    });
  }

  void _switchCurrency() => setState(() => _isFiat = !_isFiat);

  String _sanitizeAmount(String input) {
    // Limit decimals: ZEC 8, Fiat 2
    if (!input.contains('.')) return input;
    final maxDecimals = _isFiat ? 2 : 8;
    final parts = input.split('.');
    final decimals = parts[1];
    if (decimals.length > maxDecimals) {
      return parts[0] + '.' + decimals.substring(0, maxDecimals);
    }
    return input;
  }

  void _onAmountNext() {
    // Skip memo stage for transparent addresses; memos are not valid on t-addrs
    // Snapshot the amount in ZEC for display on memo page
    String formatZec(double z) {
      final double floored = (z * 1e8).floor() / 1e8;
      String s = floored.toStringAsFixed(8);
      s = s.replaceFirst(RegExp(r'0+$'), '');
      s = s.replaceFirst(RegExp(r'\.$'), '');
      if (s.isEmpty) s = '0';
      return s;
    }
    final double fx = marketPrice.price ?? 0.0;
    final double raw = double.tryParse(_amountStr) ?? 0.0;
    final bool fxOk = fx > 0.0;
    final double zecVal = _isFiat ? (fxOk ? (raw / fx) : 0.0) : raw;
    _memoAmountZec = formatZec(zecVal);
    final bool isTransparent = _forceTransparent || _isTransparentAddress(_requestAddress);
    if (isTransparent) {
      // Transparent flow: if no amount, prefer plain address; else ZIP-321 URI without memo
      final String zecStr = _isFiat ? _fiatToZec(_amountStr) : _amountStr;
      final int zats = _zecStringToZats(zecStr);
      final String addr = _requestAddress;
      if (addr.isEmpty) {
        showSnackBar('No address available');
        return;
      }
      try {
        final String scheme = CloakWalletManager.isCloak(aa.coin) ? 'cloak' : 'zcash';
        final String uri = (zats == 0)
            ? addr
            : '$scheme:' + addr + '?amount=' + zecStr;
        setState(() {
          _requestUri = uri;
          _slideForwards = true;
          _stage = _RequestStage.qr;
        });
      } catch (e) {
        showSnackBar('Failed to build request');
      }
    } else {
      setState(() {
        _slideForwards = true;
        _stage = _RequestStage.memo;
      });
    }
  }

  void _onMemoDone() {
    final String zecStr = _isFiat ? _fiatToZec(_amountStr) : _amountStr;
    final int zats = _zecStringToZats(zecStr);
    final bool isT = _isTransparentAddress(_requestAddress);
    final String memo = isT ? '' : _memoCtrl.text.trim();
    final String addr = _requestAddress;
    if (addr.isEmpty) {
      showSnackBar('No address available');
      return;
    }
    
    // If launched from thread, send request transaction instead of showing QR
    if (_fromThread && _threadCid != null && _threadAddress != null) {
      _sendRequestToThread(zats, memo);
      return;
    }
    
    // Normal flow: show QR code
    try {
      String uri;
      // CLOAK: simple URI (no ZIP-321)
      uri = (zats == 0 && memo.isEmpty) ? addr : 'cloak:$addr?amount=$zecStr${memo.isNotEmpty ? '&memo=${Uri.encodeComponent(memo)}' : ''}';
      setState(() {
        _requestUri = uri;
        _slideForwards = true;
        _stage = _RequestStage.qr;
      });
    } catch (e) {
      showSnackBar('Failed to build request');
    }
  }

  Future<void> _sendRequestToThread(int zats, String memoText) async {
    // Thread-based payment requests use CLOAK's own transaction flow
    // TODO: Implement CLOAK memo-based messaging when needed
    showSnackBar('Payment requests via thread not yet supported for CLOAK');
  }

  String _fiatToZec(String fiatStr) {
    final double? fx = marketPrice.price;
    final double parsed = double.tryParse(fiatStr) ?? 0.0;
    if (fx == null || fx <= 0) return '0';
    final double zec = parsed / fx;
    return _formatZec(zec);
  }

  String _formatZec(double zec) {
    // Floor to 8 decimals for ZIP-321
    final double floored = (zec * 1e8).floor() / 1e8;
    return floored.toStringAsFixed(8).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  int _zecStringToZats(String zec) {
    final parts = zec.split('.');
    final whole = int.tryParse(parts[0]) ?? 0;
    final frac = parts.length > 1 ? parts[1] : '';
    final fracPadded = (frac + '00000000').substring(0, 8);
    final zatsWhole = whole * 100000000;
    final zatsFrac = int.tryParse(fracPadded) ?? 0;
    return zatsWhole + zatsFrac;
  }

  Future<void> _shareQrLikeShowQr(BuildContext originContext, String data, String title) async {
    try {
      // Mirror ShowQR: ensure a stable PNG snapshot (repaint or generated) with simple caching
      final Uint8List bytes = await _ensureQrPng(data);
      await shareQrImage(originContext, data: data, title: title, pngBytes: bytes);
    } catch (_) {
      await showSnackBar('Unable to share QR');
    }
  }
}

class _MemoAmountLine extends StatelessWidget {
  final String zec;
  const _MemoAmountLine({required this.zec});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final appBarStyle = t.appBarTheme.titleTextStyle ?? t.textTheme.titleLarge ?? t.textTheme.titleMedium ?? t.textTheme.bodyMedium ?? const TextStyle();
    final String? appBarFamily = appBarStyle.fontFamily;
    final TextStyle baseSize = (t.textTheme.displaySmall ?? const TextStyle()).copyWith(fontWeight: FontWeight.w500);
    final TextStyle headStyle = appBarFamily != null ? baseSize.copyWith(fontFamily: appBarFamily) : baseSize;
    final String coinTicker = CloakWalletManager.isCloak(aa.coin) ? 'CLOAK' : 'ZEC';

    Widget primaryText(TextStyle style) => RichText(
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          maxLines: 1,
          text: TextSpan(
            style: style,
            children: [
              TextSpan(text: zec, style: style.copyWith(color: Colors.white)),
              const TextSpan(text: ' '),
              TextSpan(text: coinTicker),
            ],
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        FittedBox(fit: BoxFit.scaleDown, child: primaryText(headStyle)),
      ],
    );
  }
}

class _AmountStage extends StatelessWidget {
  final String amountText;
  final bool isFiat;
  final void Function(int) onDigit;
  final VoidCallback onDot;
  final VoidCallback onDelete;
  final VoidCallback onSwitchCurrency;
  final bool isFxFresh;
  final bool isSyncing;
  final VoidCallback onSync;
  final VoidCallback onNext;

  const _AmountStage({
    super.key,
    required this.amountText,
    required this.isFiat,
    required this.onDigit,
    required this.onDot,
    required this.onDelete,
    required this.onSwitchCurrency,
    required this.isFxFresh,
    required this.isSyncing,
    required this.onSync,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Gap(8),
          Builder(builder: (context) {
            final t = Theme.of(context);
            final appBarStyle = t.appBarTheme.titleTextStyle ??
                t.textTheme.titleLarge ??
                t.textTheme.titleMedium ??
                t.textTheme.bodyMedium ??
                const TextStyle();
            final String? appBarFamily = appBarStyle.fontFamily;
            final TextStyle baseSize = (t.textTheme.displaySmall ?? const TextStyle()).copyWith(fontWeight: FontWeight.w500);
            final TextStyle headStyle = appBarFamily != null ? baseSize.copyWith(fontFamily: appBarFamily) : baseSize;
            final TextStyle baseSmall = (t.textTheme.bodySmall ?? const TextStyle()).copyWith(fontWeight: FontWeight.w500);
            final TextStyle secondaryStyle = appBarFamily != null ? baseSmall.copyWith(fontFamily: appBarFamily) : baseSmall;
            final double secBaseSize = secondaryStyle.fontSize ?? (t.textTheme.bodySmall?.fontSize ?? 14);
            final TextStyle secondaryLargeStyle = secondaryStyle.copyWith(fontSize: secBaseSize * 1.3 * 1.3);

            String formatZec(double z) {
              final double floored = (z * 1e8).floor() / 1e8;
              String s = floored.toStringAsFixed(8);
              s = s.replaceFirst(RegExp(r'0+$'), '');
              s = s.replaceFirst(RegExp(r'\.$'), '');
              if (s.isEmpty) s = '0';
              return s;
            }

            String formatFiat(double f) {
              final abs = f.abs();
              if (abs == 0 || abs >= 0.01) {
                final double rounded = (f * 100).round() / 100.0;
                return rounded.toStringAsFixed(2);
              }
              // Dynamic precision for tiny values (e.g. CLOAK)
              int digits = 2;
              double threshold = 0.01;
              while (threshold > abs && digits < 8) { digits++; threshold /= 10; }
              digits++;
              if (digits > 8) digits = 8;
              final scale = math.pow(10, digits);
              final rounded = (f * scale).round() / scale;
              return rounded.toStringAsFixed(digits);
            }

            final double fx = marketPrice.price ?? 0.0;
            final double raw = double.tryParse(amountText) ?? 0.0;
            final bool fxOk = fx > 0.0;
            final double zecVal = isFiat ? (fxOk ? (raw / fx) : 0.0) : raw;
            final double fiatVal = isFiat ? raw : (fxOk ? (raw * fx) : 0.0);

            final String zecStr = formatZec(zecVal);
            final String fiatStr = formatFiat(fiatVal);
            final String ccy = appSettings.currency;

            // Primary (big) amount on top, secondary (small) amount next to the chip below.
            const addressFillColor = Color(0xFF2E2C2C);
            final chipBgColor = Color.lerp(addressFillColor, Colors.black, 0.06) ?? addressFillColor;
            final chipBorderColor = (t.extension<ZashiThemeExt>()?.quickBorderColor) ?? t.dividerColor.withOpacity(0.20);
            final String coinTicker = CloakWalletManager.isCloak(aa.coin) ? 'CLOAK' : 'ZEC';

            Widget coinText(TextStyle style) => RichText(
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  maxLines: 1,
                  text: TextSpan(
                    style: style,
                    children: [
                      TextSpan(text: zecStr, style: style.copyWith(color: Colors.white)),
                      const TextSpan(text: ' '),
                      TextSpan(text: coinTicker),
                    ],
                  ),
                );

            // Secondary USD (bottom): show $ + number with 2 decimals
            Widget fiatSecondaryText(TextStyle style) => RichText(
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  maxLines: 1,
                  text: TextSpan(
                    style: style,
                    children: [
                      const TextSpan(text: '\$ '),
                      TextSpan(text: fiatStr, style: style.copyWith(color: Colors.white)),
                    ],
                  ),
                );

            // Primary coin amount (top): reflect typed input immediately (preserve trailing dot)
            Widget coinPrimaryText(TextStyle style) => RichText(
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  maxLines: 1,
                  text: TextSpan(
                    style: style,
                    children: [
                      TextSpan(text: amountText, style: style.copyWith(color: Colors.white)),
                      const TextSpan(text: ' '),
                      TextSpan(text: coinTicker),
                    ],
                  ),
                );

            // Primary USD (top): show $ + typed amount (no forced decimals), preserve trailing dot
            Widget fiatPrimaryText(TextStyle style) => RichText(
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  maxLines: 1,
                  text: TextSpan(
                    style: style,
                    children: [
                      const TextSpan(text: '\$'),
                      TextSpan(text: amountText, style: style.copyWith(color: Colors.white)),
                    ],
                  ),
                );

            final Widget primary = isFiat ? fiatPrimaryText(headStyle) : coinPrimaryText(headStyle);
            final Widget secondary = isFiat ? coinText(secondaryLargeStyle) : fiatSecondaryText(secondaryLargeStyle);
            final Widget primaryLine = FittedBox(fit: BoxFit.scaleDown, child: primary);
            final Widget secondaryScaled = FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: secondary);

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                primaryLine,
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.max,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isFxFresh) Flexible(child: secondaryScaled),
                    if (isFxFresh) const SizedBox(width: 8),
                    _MiniArrowChip(
                      onTap: isFxFresh ? onSwitchCurrency : onSync,
                      backgroundColor: chipBgColor,
                      borderColor: chipBorderColor,
                      stale: !isFxFresh,
                      spinning: isSyncing,
                    ),
                  ],
                ),
              ],
            );
          }),
          const Gap(12),
          const Gap(16),
          Expanded(
            child: _Keypad(
              onDigit: onDigit,
              onDot: onDot,
              onDelete: onDelete,
            ),
          ),
          const Gap(8),
          SizedBox(
            height: 48,
            child: Builder(builder: (context) {
              final t2 = Theme.of(context);
              final String? balanceFontFamily = t2.textTheme.displaySmall?.fontFamily;
              final Color balanceCursorColor =
                  t2.extension<ZashiThemeExt>()?.balanceAmountColor ?? const Color(0xFFBDBDBD);
              bool isZero() {
                final v = double.tryParse(amountText) ?? 0.0;
                return v == 0.0;
              }
              final bool disabled = isZero();
              return Material(
                color: disabled ? t2.colorScheme.surfaceVariant : balanceCursorColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: disabled ? null : onNext,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Next',
                          style: (t2.textTheme.titleSmall ?? const TextStyle()).copyWith(
                            fontFamily: balanceFontFamily,
                            fontWeight: FontWeight.w600,
                            color: disabled ? t2.colorScheme.onSurface.withOpacity(0.4) : t2.colorScheme.background,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _MemoStage extends StatelessWidget {
  final TextEditingController memoCtrl;
  final String amountZecStr;
  final VoidCallback onBack;
  final VoidCallback onRequest;
  final bool showMemo;

  const _MemoStage({super.key, required this.memoCtrl, required this.amountZecStr, required this.onBack, required this.onRequest, required this.showMemo});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Gap(8),
          // Coin circle centered with spacing
          Builder(builder: (context) {
            final isCloak = CloakWalletManager.isCloak(aa.coin);
            return Center(
              child: SizedBox(
                width: 49,
                height: 49,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isCloak ? const Color(0xFF0D1B2A) : const Color(0xFFF4B728),
                  ),
                  alignment: Alignment.center,
                  child: SvgPicture.asset(
                    isCloak ? 'assets/icons/cloak_glyph.svg' : 'assets/icons/cloak_glyph.svg',
                    width: 28,
                    height: 28,
                    fit: BoxFit.contain,
                    colorFilter: ColorFilter.mode(isCloak ? Colors.white : Colors.black, BlendMode.srcIn),
                  ),
                ),
              ),
            );
          }),
          const Gap(20),
          Center(child: _PrivatePill()),
          const Gap(20),
          // Match REQUEST app bar style (font family and reduced size)
          Builder(builder: (context) {
            final t2 = Theme.of(context);
            final base = t2.appBarTheme.titleTextStyle ?? t2.textTheme.titleLarge ?? t2.textTheme.titleMedium ?? t2.textTheme.bodyMedium;
            final reduced = (base?.fontSize != null) ? base!.copyWith(fontSize: base.fontSize! * 0.75) : base;
            return Text('Payment Request', style: reduced, textAlign: TextAlign.center);
          }),
          const Gap(6),
          // Static amount pulled from previous step (ZEC primary, optional USD secondary when available)
          _MemoAmountLine(zec: amountZecStr),
          const Gap(12),
          // Replace plain TextField with SEND's memo widget styling
          if (showMemo)
            InputMemo(
              MemoData(false, '', memoCtrl.text),
              hintText: "What's this for?",
              onChanged: (m) {
                memoCtrl.text = m?.memo ?? '';
              },
            ),
          const Spacer(),
          SizedBox(
            height: 48,
            child: Builder(builder: (context) {
              final t2 = Theme.of(context);
              final String? balanceFontFamily = t2.textTheme.displaySmall?.fontFamily;
              final Color balanceCursorColor =
                  t2.extension<ZashiThemeExt>()?.balanceAmountColor ?? const Color(0xFFBDBDBD);
              return Material(
                color: balanceCursorColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: onRequest,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Request',
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
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _PrivatePill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isCloak = CloakWalletManager.isCloak(aa.coin);
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

class _CoinOverlay extends StatelessWidget {
  final double size;
  final double iconSize;
  const _CoinOverlay({required this.size, required this.iconSize});

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

class _QrStage extends StatelessWidget {
  final String address;
  final String requestUri;
  final String amountZecStr;
  final GlobalKey qrBoundaryKey;
  final VoidCallback onShare;
  final VoidCallback onClose;

  const _QrStage({super.key, required this.address, required this.requestUri, required this.amountZecStr, required this.qrBoundaryKey, required this.onShare, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final qrSize = MediaQuery.of(context).size.width * 0.66;
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
                  // Match memo page spacing: Private pill at top, amount below, then QR
                  const Gap(8),
                  _PrivatePill(),
                  const Gap(20),
                  _MemoAmountLine(zec: amountZecStr),
                  const Gap(20),
                  GestureDetector(
                    onTap: () => _showFullscreenQr(context, requestUri),
                    child: RepaintBoundary(
                      key: qrBoundaryKey,
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
                                data: requestUri,
                                size: qrSize * 0.7,
                                backgroundColor: Colors.white,
                              ),
                              _CoinOverlay(size: 48, iconSize: 28),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Gap(12),
                  // Intentionally omit the title and address lines for Request QR stage
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
                            onTap: onShare,
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
                Center(
                  child: TextButton(
                    onPressed: onClose,
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    child: const Text('Close', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showFullscreenQr(BuildContext context, String data) async {
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
                    _CoinOverlay(size: 64, iconSize: 36),
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

class _Keypad extends StatelessWidget {
  final void Function(int) onDigit;
  final VoidCallback onDot;
  final VoidCallback onDelete;
  const _Keypad({super.key, required this.onDigit, required this.onDot, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final TextStyle? appTitle = t.appBarTheme.titleTextStyle ?? t.textTheme.titleLarge ?? t.textTheme.titleMedium ?? t.textTheme.bodyMedium;
    final String? keypadFontFamily = appTitle?.fontFamily;
    final Color keypadColor = appTitle?.color ?? (t.textTheme.titleLarge?.color ?? t.colorScheme.onSurface);
    final TextStyle keypadTextStyle = (t.textTheme.bodyLarge ?? const TextStyle()).copyWith(
      fontFamily: keypadFontFamily,
      color: keypadColor,
      fontSize: 22,
    );

    final Color baseBg = t.colorScheme.surface;
    final ButtonStyle keypadButtonStyle = ElevatedButton.styleFrom().copyWith(
      overlayColor: MaterialStateProperty.resolveWith((states) {
        if (states.contains(MaterialState.hovered)) {
          return Color.lerp(baseBg, Colors.white, 0.12);
        }
        if (states.contains(MaterialState.pressed)) {
          return Color.lerp(baseBg, Colors.white, 0.18);
        }
        if (states.contains(MaterialState.focused)) {
          return Color.lerp(baseBg, Colors.white, 0.10);
        }
        return null;
      }),
    );
    final List<Widget> rows = [
      _row([
        _btn('1', () => onDigit(1), keypadTextStyle, keypadButtonStyle),
        _btn('2', () => onDigit(2), keypadTextStyle, keypadButtonStyle),
        _btn('3', () => onDigit(3), keypadTextStyle, keypadButtonStyle),
      ]),
      _row([
        _btn('4', () => onDigit(4), keypadTextStyle, keypadButtonStyle),
        _btn('5', () => onDigit(5), keypadTextStyle, keypadButtonStyle),
        _btn('6', () => onDigit(6), keypadTextStyle, keypadButtonStyle),
      ]),
      _row([
        _btn('7', () => onDigit(7), keypadTextStyle, keypadButtonStyle),
        _btn('8', () => onDigit(8), keypadTextStyle, keypadButtonStyle),
        _btn('9', () => onDigit(9), keypadTextStyle, keypadButtonStyle),
      ]),
      _row([
        _btn('.', onDot, keypadTextStyle, keypadButtonStyle),
        _btn('0', () => onDigit(0), keypadTextStyle, keypadButtonStyle),
        _btnIcon(Icons.backspace_outlined, onDelete, keypadColor, keypadButtonStyle),
      ]),
    ];
    return Column(children: rows.map((e) => Expanded(child: e)).toList());
  }

  Widget _row(List<Widget> children) => Row(children: children.map((e) => Expanded(child: e)).toList());

  Widget _btn(String label, VoidCallback onTap, TextStyle textStyle, ButtonStyle style) => Padding(
        padding: const EdgeInsets.all(6),
        child: ElevatedButton(
          style: style,
          onPressed: onTap,
          child: Text(label, style: textStyle),
        ),
      );

  Widget _btnIcon(IconData icon, VoidCallback onTap, Color iconColor, ButtonStyle style) => Padding(
        padding: const EdgeInsets.all(6),
        child: ElevatedButton(
          style: style,
          onPressed: onTap,
          child: Icon(icon, color: iconColor),
        ),
      );
}


class _MiniArrowChip extends StatelessWidget {
  final VoidCallback onTap;
  final Color backgroundColor;
  final Color borderColor;
  final bool stale;
  final bool spinning;
  const _MiniArrowChip({super.key, required this.onTap, required this.backgroundColor, required this.borderColor, this.stale = false, this.spinning = false});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    return Material(
      color: backgroundColor,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: borderColor)),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Center(
            child: stale
                ? _RefreshGlyph(spinning: spinning)
                : const _MiniArrowGlyph(),
          ),
        ),
      ),
    );
  }
}

class _MiniArrowGlyph extends StatelessWidget {
  const _MiniArrowGlyph();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Transform.scale(
        scaleX: 0.9,
        scaleY: 1.35,
        child: const Icon(Icons.swap_vert, size: 22.5),
      ),
    );
  }
}

class _RefreshGlyph extends StatefulWidget {
  final bool spinning;
  const _RefreshGlyph({required this.spinning});
  @override
  State<_RefreshGlyph> createState() => _RefreshGlyphState();
}

class _RefreshGlyphState extends State<_RefreshGlyph> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;
  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    if (widget.spinning) _ctl.repeat();
  }

  @override
  void didUpdateWidget(covariant _RefreshGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spinning && !_ctl.isAnimating) {
      _ctl.repeat();
    } else if (!widget.spinning && _ctl.isAnimating) {
      _ctl.stop();
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = const Icon(Icons.refresh, size: 22.5);
    if (!widget.spinning) return icon;
    return RotationTransition(turns: _ctl, child: icon);
  }
}


