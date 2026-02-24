import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:intl/intl.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../accounts.dart';
import '../../cloak/cloak_wallet_manager.dart';
import '../../generated/intl/messages.dart';
import '../../store2.dart';
import '../../theme/zashi_tokens.dart';
import '../utils.dart';

// Shared palette — must stay in sync with receive_qr.dart _AddressPanel
const _cloakNavy = Color(0xFF0D1B2A);
const _cloakGold = Color(0xFF3D2E0A);
const _orangeBase = Color(0xFFC99111);
const _orangeDark = Color(0xFFA1740D);
const _orangeLight = Color(0xFFECAB14);

class SyncStatusWidget extends StatefulWidget {
  SyncStatusState createState() => SyncStatusState();
}

class SyncStatusState extends State<SyncStatusWidget> with SingleTickerProviderStateMixin {
  var display = 0;

  // Smooth animation system - runs on UI thread, independent of Rust FFI
  late Ticker _ticker;
  double _displayedProgress = 0.0;  // What we show (0.0 - 1.0)
  double _targetProgress = 0.0;     // Where we're animating toward
  double _actualProgress = 0.0;     // Real progress from sync

  // Fade-out animation when sync completes
  double _opacity = 1.0;
  bool _completedAndFading = false;
  DateTime? _fadeStartTime;

  // Slide-in animation when banner appears
  double _slideOffset = 1.0;  // 1.0 = fully off-screen (above), 0.0 = fully visible
  bool _wasVisible = false;
  DateTime? _slideStartTime;

  // Minimum display time - ensures fast syncs still show the banner gracefully
  // Banner will stay visible for at least this duration even if sync completes instantly
  static const _minDisplayDuration = Duration(milliseconds: 1500);
  DateTime? _bannerShowTime;  // When banner became visible
  bool _holdingForMinDisplay = false;  // True if sync done but still within min display time

  // Estimation system
  DateTime? _syncStartTime;
  int? _startHeight;
  int? _targetHeight;
  Duration _estimatedTotalDuration = const Duration(minutes: 30); // Conservative default

  // Blocks per second estimate (conservative for slow hardware)
  // Zcash processes roughly 100-500 blocks/sec depending on hardware and tx density
  static const double _conservativeBlocksPerSecond = 50.0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    Future(() async {
      // Let the first UI frame render before starting sync.
      // Without this delay, synchronous FFI calls in syncFromTables() block
      // the main thread before the account page has painted, causing a
      // visible ~15 second freeze on startup.
      await Future.delayed(const Duration(milliseconds: 100));
      await syncStatus2.update();
      await startAutoSync();
    });
  }
  
  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
  
  void _onTick(Duration elapsed) {
    if (!mounted) return;

    // Check if we're still within minimum display time
    if (_holdingForMinDisplay && _bannerShowTime != null) {
      final elapsed = DateTime.now().difference(_bannerShowTime!);
      if (elapsed >= _minDisplayDuration) {
        // Minimum time elapsed, now we can start fade-out
        _holdingForMinDisplay = false;
        if (!_completedAndFading && syncStatus2.syncJustCompleted) {
          _completedAndFading = true;
          _fadeStartTime = DateTime.now();
          _displayedProgress = 1.0;
          _targetProgress = 1.0;
          _opacity = 1.0;
        }
      }
    }

    // Determine if banner should be visible
    // Show ONLY for: rescan/restore in progress, sync just completed, fading out, holding for min display
    // Periodic syncs use the rotating icon in the app bar (router.dart), NOT this banner
    final shouldBeVisible = (syncStatus2.isRescan && !syncStatus2.isSynced) ||
                            syncStatus2.syncJustCompleted ||
                            _completedAndFading ||
                            _holdingForMinDisplay;

    // Handle slide-in animation when banner appears
    if (shouldBeVisible && !_wasVisible) {
      // Banner just became visible - start slide-in
      _wasVisible = true;
      _slideStartTime = DateTime.now();
      _bannerShowTime = DateTime.now();  // Track when banner appeared for min display
      _slideOffset = 1.0;
    } else if (!shouldBeVisible && _wasVisible && !_completedAndFading && !_holdingForMinDisplay) {
      // Banner hidden - reset for next time
      _wasVisible = false;
      _slideOffset = 1.0;
      _slideStartTime = null;
      _bannerShowTime = null;
    }
    
    // Animate slide-in
    if (_slideStartTime != null && _slideOffset > 0.0) {
      final slideElapsed = DateTime.now().difference(_slideStartTime!).inMilliseconds;
      const slideDuration = 400; // 400ms slide-in
      if (slideElapsed < slideDuration) {
        final progress = slideElapsed / slideDuration;
        // Use easeOutCubic for smooth deceleration
        final easedProgress = 1.0 - (1.0 - progress) * (1.0 - progress) * (1.0 - progress);
        final newOffset = 1.0 - easedProgress;
        if ((newOffset * 100).round() != (_slideOffset * 100).round()) {
          setState(() {
            _slideOffset = newOffset.clamp(0.0, 1.0);
          });
        }
      } else {
        if (_slideOffset != 0.0) {
          setState(() {
            _slideOffset = 0.0;
          });
        }
      }
    }
    
    // Get actual progress from sync system
    // CLOAK uses step-based progress (syncedHeight/latestHeight set to step/100)
    // Zcash uses ETA block-height tracking
    final isCloak = CloakWalletManager.isCloak(aa.coin);
    if (isCloak && syncStatus2.latestHeight != null && syncStatus2.latestHeight! > 0 && syncStatus2.latestHeight! <= 100) {
      // Step-based progress from CLOAK table sync (values 0-100)
      _actualProgress = (syncStatus2.syncedHeight / syncStatus2.latestHeight!).clamp(0.0, 1.0);
    } else {
      final rawActual = syncStatus2.eta.progress?.toDouble() ?? 0.0;
      _actualProgress = rawActual / 100.0;
    }

    // Initialize estimation when sync starts
    if (syncStatus2.syncing && _syncStartTime == null) {
      _syncStartTime = DateTime.now();
      _startHeight = syncStatus2.startSyncedHeight;
      _targetHeight = syncStatus2.latestHeight;

      // Calculate estimated duration based on block gap
      if (!isCloak && _startHeight != null && _targetHeight != null) {
        final blockGap = _targetHeight! - _startHeight!;
        final estimatedSeconds = blockGap / _conservativeBlocksPerSecond;
        _estimatedTotalDuration = Duration(seconds: estimatedSeconds.round().clamp(60, 86400)); // 1 min to 24 hours
      } else if (isCloak) {
        // CLOAK table sync typically takes 5-15 seconds
        _estimatedTotalDuration = const Duration(seconds: 12);
      }
    }
    
    // Handle completion: syncJustCompleted is set by store when sync finishes
    // We show 100%, fade out, THEN tell store to clear isRescan
    // BUT respect minimum display time first
    if (syncStatus2.syncJustCompleted && !_completedAndFading && !_holdingForMinDisplay) {
      // Sync just completed - check if we need to wait for minimum display time
      _displayedProgress = 1.0;
      _targetProgress = 1.0;

      if (_bannerShowTime != null) {
        final elapsed = DateTime.now().difference(_bannerShowTime!);
        if (elapsed < _minDisplayDuration) {
          // Need to hold for minimum display time before fading
          _holdingForMinDisplay = true;
          setState(() {});
          return;
        }
      }

      // Minimum time satisfied, start fade immediately
      _completedAndFading = true;
      _fadeStartTime = DateTime.now();
      _opacity = 1.0;
      setState(() {});
      return;
    }
    
    if (_completedAndFading) {
      // Fade out over 1.5 seconds
      final fadeElapsed = DateTime.now().difference(_fadeStartTime!).inMilliseconds;
      final fadeDuration = 1500;
      if (fadeElapsed < fadeDuration) {
        final newOpacity = 1.0 - (fadeElapsed / fadeDuration);
        if ((newOpacity * 100).round() != (_opacity * 100).round()) {
          setState(() {
            _opacity = newOpacity.clamp(0.0, 1.0);
          });
        }
        return;
      }
      // Fade complete - now tell store to clear isRescan so vote banner can appear
      _completedAndFading = false;
      _fadeStartTime = null;
      _holdingForMinDisplay = false;
      _bannerShowTime = null;
      _opacity = 1.0;
      _syncStartTime = null;
      _startHeight = null;
      _targetHeight = null;
      _displayedProgress = 0.0;
      _targetProgress = 0.0;
      syncStatus2.clearSyncCompleted();  // This clears syncJustCompleted AND isRescan
      return;
    }
    
    // If not syncing and not in fade mode, nothing to do
    if (!syncStatus2.syncing && !syncStatus2.isRescan) {
      _syncStartTime = null;
      _startHeight = null;
      _targetHeight = null;
      _displayedProgress = 0.0;
      _targetProgress = 0.0;
      return;
    }
    
    // Calculate estimated progress based on elapsed time
    double estimatedProgress = 0.0;
    if (_syncStartTime != null) {
      final elapsed = DateTime.now().difference(_syncStartTime!);
      final rawEstimate = elapsed.inMilliseconds / _estimatedTotalDuration.inMilliseconds;
      
      // Apply asymptotic slowdown as we approach the cap
      // This naturally slows down and creeps into 98.x% territory
      // Formula: progress = cap * (1 - e^(-rate * rawEstimate))
      // Simplified: we slow down as we get closer to 99%
      const softCap = 0.99;
      final remainingRoom = softCap - estimatedProgress;
      if (rawEstimate < 1.0) {
        estimatedProgress = rawEstimate * 0.70; // Linear up to 70%
      } else {
        // Past estimated time - creep slowly toward cap
        final overtime = rawEstimate - 1.0;
        estimatedProgress = 0.70 + (softCap - 0.70) * (1 - 1 / (1 + overtime * 0.5));
      }
      estimatedProgress = estimatedProgress.clamp(0.0, softCap);
    }
    
    // Target is whichever is higher: our estimate or actual
    // But if actual hits 100%, we use that (sync complete)
    if (_actualProgress >= 0.999) {
      _targetProgress = 1.0; // Sync complete - go to 100%
    } else {
      _targetProgress = _actualProgress > estimatedProgress ? _actualProgress : estimatedProgress;
    }
    
    // Smooth easing toward target
    // This runs at 60fps on UI thread - completely independent of Rust
    final diff = _targetProgress - _displayedProgress;
    if (diff.abs() > 0.0001) {
      // Ease faster when catching up to actual, slower when estimating
      final easeSpeed = diff > 0.05 ? 0.08 : 0.02;
      final newProgress = _displayedProgress + diff * easeSpeed;
      
      // Only rebuild if visible change (reduces unnecessary rebuilds)
      if ((newProgress * 1000).round() != (_displayedProgress * 1000).round()) {
        setState(() {
          _displayedProgress = newProgress;
        });
      }
    }
  }

  String getSyncText(int syncedHeight) {
    final s = S.of(context);
    if (!syncStatus2.connected) return s.connectionError;
    final latestHeight = syncStatus2.latestHeight;
    if (latestHeight == null) return '';

    if (syncStatus2.paused) return s.syncPaused;

    // CLOAK uses table-based sync — show step descriptions
    if (CloakWalletManager.isCloak(aa.coin)) {
      if (!syncStatus2.syncing) return 'Synced';
      final step = syncStatus2.syncStep;
      if (step != null) return step;
      if (syncStatus2.isRescan) return 'Starting sync...';
      return 'Checking for updates...';
    }

    if (!syncStatus2.syncing) return syncedHeight.toString();

    final timestamp = syncStatus2.timestamp?.let(timeago.format) ?? s.na;
    final downloadedSize = syncStatus2.downloadedSize;
    final trialDecryptionCount = syncStatus2.trialDecryptionCount;

    final remaining = syncStatus2.eta.remaining;
    final percent = syncStatus2.eta.progress;
    final downloadedSize2 = NumberFormat.compact().format(downloadedSize);
    final trialDecryptionCount2 =
        NumberFormat.compact().format(trialDecryptionCount);

    switch (display) {
      case 0:
        return '$syncedHeight / $latestHeight';
      case 1:
        final m = syncStatus2.isRescan ? s.rescan : s.catchup;
        return '$m $percent %';
      case 2:
        return remaining != null ? '$remaining...' : '';
      case 3:
        return timestamp;
      case 4:
        return '${syncStatus2.eta.timeRemaining}';
      case 5:
        return '\u{2193} $downloadedSize2';
      case 6:
        return '\u{2192} $trialDecryptionCount2';
    }
    throw Exception('Unreachable');
  }

  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      final isCloak = CloakWalletManager.isCloak(aa.coin);

      // Hide if a DIFFERENT coin is syncing in background
      // This prevents Zcash sync from showing when user is on CLOAK and vice versa
      if (syncStatus2.syncingCoin != null && syncStatus2.syncingCoin != aa.coin) {
        return const SizedBox.shrink();
      }

      final t = Theme.of(context);
      final zashi = t.extension<ZashiThemeExt>();
      final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

      // Depend on MobX observables so this widget rebuilds during sync/rewind
      final _ = syncStatus2.changed;
      final __ = syncStatus2.syncJustCompleted;  // Also observe this for fade trigger
      final ___ = syncStatus2.syncingCoin;  // Observe syncingCoin for coin-aware display

      // Show ONLY during rescan/restore sessions, completion signal, or fade-out animation
      // Periodic syncs use the rotating icon in the app bar (router.dart), NOT this banner
      final showPill = (syncStatus2.isRescan && !syncStatus2.isSynced) ||
                       syncStatus2.syncJustCompleted ||
                       _completedAndFading ||
                       _holdingForMinDisplay;
      if (!showPill) return const SizedBox.shrink();

      final syncedHeight = syncStatus2.syncedHeight;
      final text = getSyncText(syncedHeight);
      
      // Use our smooth animated progress instead of raw actual
      final displayPercent = (_displayedProgress * 100).toStringAsFixed(
        _displayedProgress > 0.95 ? 1 : 0  // Show decimal only when creeping near end
      );

      // Gradient colors matching Shielded card on Receive page
      final gradientColors = isCloak
          ? const [_cloakNavy, _cloakGold]
          : const [_orangeBase, _orangeDark];
      final borderColor = isCloak
          ? const Color(0xFFD4A843).withOpacity(0.3)
          : _orangeLight.withOpacity(0.3);

      final syncStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
        color: Colors.white,
        fontFamily: balanceFontFamily,
        fontWeight: FontWeight.w500,
      );

      return Transform.translate(
        offset: Offset(0, -72 * _slideOffset),  // Slide from above (72 = height + margin)
        child: Opacity(
          opacity: _opacity * (1.0 - _slideOffset * 0.3),  // Slight fade during slide
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
          height: 56,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradientColors,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: borderColor,
            width: 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _onSync,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      // Animated sync icon
                      _AnimatedSyncIcon(),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          text,
                          style: syncStyle,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$displayPercent%',
                          style: syncStyle.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _InfoIcon(onTap: _showWhyModal),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Smooth animated progress bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Container(
                      height: 4,
                      width: double.infinity,
                      color: Colors.white.withOpacity(0.2),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: _displayedProgress.clamp(0.0, 1.0),
                        heightFactor: 1.0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
              ),  // Close Container
              const SizedBox(height: 8),  // Gap between sync bar and next element
            ],
          ),  // Close Column
        ),  // Close Opacity
      );  // Close Transform.translate
    });
  }

  _onSync() {
    if (syncStatus2.syncing) {
      setState(() {
        display = (display + 1) % 7;
      });
    } else {
      if (syncStatus2.paused) syncStatus2.setPause(false);
      syncStatus2.sync(false);  // Don't defer - prevents losing sync if app locks
    }
  }

  void _showWhyModal() {
    final ctx = context;
    showMessageBox2(
      ctx,
      'Why isn\'t my sync status updating?',
      'If your wallet appears stuck at a certain block height, it is still syncing as long as the pulsing cycle icon is visible in the top right. Older wallets may take up to 24 hours to finish syncing. If you do not want to wait, you can create a new wallet here and transfer your ZEC balance to it.',
      label: 'OK',
      dismissable: true,
    );
  }
}

/// Animated sync icon that spins smoothly - runs on its own ticker
class _AnimatedSyncIcon extends StatefulWidget {
  @override
  State<_AnimatedSyncIcon> createState() => _AnimatedSyncIconState();
}

class _AnimatedSyncIconState extends State<_AnimatedSyncIcon> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
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
      builder: (context, child) => Transform.rotate(
        angle: _controller.value * 2 * 3.14159,
        child: child,
      ),
      child: const Icon(Icons.sync, color: Colors.white, size: 16),
    );
  }
}

class _InfoIcon extends StatelessWidget {
  final VoidCallback onTap;
  const _InfoIcon({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.2),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: const Text(
          'i',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
