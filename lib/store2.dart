import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:get_it/get_it.dart';
import 'package:mobx/mobx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import 'appsettings.dart';
import 'cloak/cloak_wallet_manager.dart';
import 'cloak/cloak_sync.dart';
import 'cloak/cloak_db.dart';
import 'pages/utils.dart';
import 'accounts.dart';
import 'coin/coins.dart';
import 'generated/intl/messages.dart';

part 'store2.g.dart';
part 'store2.freezed.dart';

var appStore = AppStore();
// Global optimistic echo messages to render pending chat items in lists
final optimisticEchoes = ObservableList<ZMessage>.of([]);

/// Tracks pending pool migrations (self-transfers between pools).
/// When a pool transfer is initiated, we record it here so the UI can show
/// the correct balance (unchanged minus fee) instead of a reduced balance.
class PendingMigration {
  final int fromPool; // 1=transparent, 2=sapling, 4=orchard
  final int toPool;
  final int amount; // in zats
  final int fee; // estimated fee in zats
  final DateTime timestamp;
  final String? txId; // transaction ID once broadcast

  PendingMigration({
    required this.fromPool,
    required this.toPool,
    required this.amount,
    required this.fee,
    this.txId,
  }) : timestamp = DateTime.now();

  /// Check if this migration has likely confirmed (older than ~2 minutes)
  bool get isLikelyConfirmed =>
      DateTime.now().difference(timestamp).inSeconds > 120;
}

class PendingMigrationStore = _PendingMigrationStore with _$PendingMigrationStore;

abstract class _PendingMigrationStore with Store {
  @observable
  ObservableList<PendingMigration> pending = ObservableList<PendingMigration>();

  @action
  void addMigration(PendingMigration m) {
    pending.add(m);
  }

  @action
  void clearConfirmed() {
    pending.removeWhere((m) => m.isLikelyConfirmed);
  }

  @action
  void clear() {
    pending.clear();
  }

  /// Get the total amount pending to arrive in each pool
  int pendingToPool(int pool) {
    return pending
        .where((m) => m.toPool == pool && !m.isLikelyConfirmed)
        .fold(0, (sum, m) => sum + m.amount - m.fee);
  }

  /// Get total pending outgoing from each pool (already deducted from balance)
  int pendingFromPool(int pool) {
    return pending
        .where((m) => m.fromPool == pool && !m.isLikelyConfirmed)
        .fold(0, (sum, m) => sum + m.amount);
  }

  /// Check if there are any pending migrations
  bool get hasPending => pending.any((m) => !m.isLikelyConfirmed);

  /// Get total amount in transit (for display purposes)
  int get totalInTransit => pending
      .where((m) => !m.isLikelyConfirmed)
      .fold(0, (sum, m) => sum + m.amount - m.fee);
}

final pendingMigrations = PendingMigrationStore();

/// Migration state for the voting flow
enum MigrationState {
  none,        // No migration needed or not started
  migrating,   // Currently migrating
  ready,       // All funds in Orchard, ready to vote
}

/// Pool-level migration state
enum PoolMigrationState { pending, migrating, migrated }

class MigrationStateStore = _MigrationStateStore with _$MigrationStateStore;

abstract class _MigrationStateStore with Store {
  @observable
  MigrationState state = MigrationState.none;

  @observable
  String statusMessage = '';

  @observable
  PoolMigrationState transparentState = PoolMigrationState.pending;

  @observable
  PoolMigrationState saplingState = PoolMigrationState.pending;

  @observable
  String? error;

  // Track if migration is actively running (async operation in progress)
  bool _isRunning = false;

  @action
  void setMigrating(String message) {
    state = MigrationState.migrating;
    statusMessage = message;
  }

  @action
  void setReady() {
    state = MigrationState.ready;
    statusMessage = 'Ready for voting!';
    _isRunning = false;
  }

  @action
  void reset() {
    state = MigrationState.none;
    statusMessage = '';
    transparentState = PoolMigrationState.pending;
    saplingState = PoolMigrationState.pending;
    error = null;
    _isRunning = false;
  }

  /// Start migration - runs independently of any UI
  Future<void> startMigration() async {
    if (_isRunning) return; // Already running
    _isRunning = true;
    error = null;
    
    setMigrating('Preparing...');

    try {
      // Ensure prover is ready
      try {
        final spend = await rootBundle.load('assets/sapling-spend.params');
        final output = await rootBundle.load('assets/sapling-output.params');
        WarpApi.initProver(spend.buffer.asUint8List(), output.buffer.asUint8List());
        appStore.proverReady = true;
      } catch (_) {}

      // Get fresh balances
      aa.updatePoolBalances();
      var pools = aa.poolBalances;

      // Migrate transparent first if needed
      if (pools.transparent > 0) {
        _setTransparentMigrating();
        await _migratePool(1, pools.transparent);
        _setTransparentMigrated();
      }

      // Refresh balances before sapling migration
      aa.updatePoolBalances();
      pools = aa.poolBalances;

      // Migrate sapling if needed
      if (pools.sapling > 0) {
        _setSaplingMigrating();
        await _migratePool(2, pools.sapling);
        _setSaplingMigrated();
      }

      // Done!
      setReady();
    } catch (e) {
      runInAction(() {
        error = e.toString();
        state = MigrationState.none;
        statusMessage = '';
        _isRunning = false;
      });
    }
  }

  @action
  void _setTransparentMigrating() {
    transparentState = PoolMigrationState.migrating;
    statusMessage = 'Migrating transparent to Orchard...';
  }

  @action
  void _setTransparentMigrated() {
    transparentState = PoolMigrationState.migrated;
    statusMessage = 'Transparent migration broadcast.';
  }

  @action
  void _setSaplingMigrating() {
    saplingState = PoolMigrationState.migrating;
    statusMessage = 'Migrating sapling to Orchard...';
  }

  @action
  void _setSaplingMigrated() {
    saplingState = PoolMigrationState.migrated;
    statusMessage = 'Sapling migration broadcast.';
  }

  Future<void> _migratePool(int fromPool, int amount) async {
    // Create the transfer plan
    final plan = await WarpApi.transferPools(
      aa.coin, aa.id, fromPool, 4, amount, true, '', 0,
      0, coinSettings.feeT,
    );

    // Sign the transaction
    runInAction(() => statusMessage = fromPool == 1 ? 'Signing transparent transfer...' : 'Signing sapling transfer...');
    final signedTx = await WarpApi.signOnly(aa.coin, aa.id, plan);

    // Broadcast
    runInAction(() => statusMessage = 'Broadcasting...');
    WarpApi.broadcast(aa.coin, signedTx);

    // Register pending migration
    final report = WarpApi.transactionReport(aa.coin, plan);
    pendingMigrations.addMigration(PendingMigration(
      fromPool: fromPool, toPool: 4, amount: amount, fee: report.fee,
    ));

    // Trigger sync to pick up the transaction
    try {
      await triggerManualSync();
      aa.updatePoolBalances();
    } catch (_) {}
  }
}

final migrationState = MigrationStateStore();

class AppStore = _AppStore with _$AppStore;

abstract class _AppStore with Store {
  bool initialized = false;
  String dbPassword = '';

  @observable
  bool flat = false;

  @observable
  bool proverReady = false;

  @observable
  bool hideBalances = false;

  /// CLOAK wallet validation errors detected at startup
  /// If non-empty, the wallet has configuration issues that will cause transactions to fail
  @observable
  List<String> cloakWalletValidationErrors = [];

  /// Check if there are any CLOAK wallet validation errors
  @computed
  bool get hasCloakWalletErrors => cloakWalletValidationErrors.isNotEmpty;

  @action
  Future<void> setHideBalances(bool value) async {
    hideBalances = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('hide_balances', value);
    } catch (_) {}
  }
}

final syncProgressPort2 = ReceivePort();
final syncProgressStream = syncProgressPort2.asBroadcastStream();

// Context for async sync completion handling
AccountBalanceSnapshot? _syncPreBalance;

void initSyncListener() {
  syncProgressStream.listen((e) {
    if (e is List<int>) {
      final progress = Progress(e);
      if (progress.height == 0xFFFFFFFF) {
        final resultCode = progress.timestamp;
        logger.d('Sync completed with code: $resultCode');
        syncStatus2._handleSyncCompletion(resultCode);
        return;
      }
      syncStatus2.setProgress(progress);
      // Don't update poolBalances from progress events - this causes UI flicker
      // as it reports intermediate balances during sync. The final balance
      // is updated by aa.update() after sync completes.
      logger.d(progress.balances);
    }
  });
}

Timer? syncTimer;

Future<void> startAutoSync() async {
  if (syncTimer == null) {
    // Don't start sync if there's no account yet
    if (aa.id == 0) {
      // No account - skipping initial sync
      // Still set up the timer for when an account is created
      syncTimer = Timer.periodic(Duration(seconds: 5), (timer) {
        if (aa.id == 0) return; // No account yet
        if (syncStatus2.syncing) {
          return;
        }
        syncStatus2.sync(false, auto: true);
        aa.updateDivisified();
      });
      return;
    }
    await syncStatus2.update();
    await syncStatus2.sync(false, auto: true);
    syncTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (aa.id == 0) return; // No account
      // IMPORTANT: Skip FFI calls while sync is in progress to avoid blocking UI
      if (syncStatus2.syncing) {
        return;
      }
      syncStatus2.sync(false, auto: true);
      aa.updateDivisified();
    });
  }
}

void _cancelAutoSyncTimer() {
  syncTimer?.cancel();
  syncTimer = null;
}

void _rescheduleAutoSyncAfter(Duration delay) {
  _cancelAutoSyncTimer();
  // Schedule the next auto-sync tick after the specified delay,
  // then continue with the normal 5s cadence.
  syncTimer = Timer(delay, () {
    // Skip if sync is in progress
    if (syncStatus2.syncing) {
      // Rescheduled tick skipped - sync in progress
      _rescheduleAutoSyncAfter(Duration(seconds: 5));
      return;
    }
    syncStatus2.sync(false, auto: true);
    syncTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      // IMPORTANT: Skip FFI calls while sync is in progress to avoid blocking UI
      if (syncStatus2.syncing) {
        return;
      }
      syncStatus2.sync(false, auto: true);
      aa.updateDivisified();
    });
  });
}

Future<void> triggerManualSync() async {
  // Ensure there is no overlapping auto tick while a manual sync runs
  _cancelAutoSyncTimer();
  // If already syncing, just reschedule auto-sync and exit
  if (syncStatus2.syncing) {
    _rescheduleAutoSyncAfter(Duration(seconds: 5));
    return;
  }
  // Manual action explicitly unpauses sync if it had been auto-paused
  if (syncStatus2.paused) syncStatus2.setPause(false);
  await syncStatus2.sync(false);
  // Resume auto-sync 5s after manual completes
  _rescheduleAutoSyncAfter(Duration(seconds: 5));
}

var syncStatus2 = SyncStatus2();

class SyncStatus2 = _SyncStatus2 with _$SyncStatus2;

abstract class _SyncStatus2 with Store {
  int startSyncedHeight = 0;

  @observable
  bool isRescan = false;

  // Step description for CLOAK table-based sync (e.g., "Fetching merkle tree...")
  @observable
  String? syncStep;

  // Track which coin is currently syncing (null if not syncing)
  // This allows the UI to show sync progress only for the active coin
  @observable
  int? syncingCoin;

  // Flag to signal sync just completed - widget uses this to trigger fade-out
  // Widget should call clearSyncCompleted() after fade animation finishes
  @observable
  bool syncJustCompleted = false;

  ETA eta = ETA();

  @observable
  bool connected = true;

  @observable
  int syncedHeight = 0;

  @observable
  int? latestHeight;

  @observable
  DateTime? timestamp;

  @observable
  bool syncing = false;

  @observable
  bool paused = false;

  @observable
  int downloadedSize = 0;

  @observable
  int trialDecryptionCount = 0;

  // Whether to show the app-bar sync percentage banner for the current session
  // Gated by: (1) restore trigger, or (2) behind by ~1 month of blocks
  @observable
  bool showSyncBanner = false;

  @computed
  int get changed => Object.hashAll([connected, syncedHeight, latestHeight, syncing, paused, syncStep]);

  bool get isSynced {
    final sh = syncedHeight;
    final lh = latestHeight;
    return lh != null && sh >= lh;
  }

  // Approximate number of blocks in one month (30 days * 24h * 60m * 4/5 blocks/min)
  int get oneMonthBlockThreshold => 30 * 24 * 60 * 4 ~/ 5;

  @computed
  int? get bannerPercent {
    // Depend on ETA checkpoints to ensure reactivity during sync
    final end = eta.endHeight;
    final start = eta.start?.height ?? startSyncedHeight;
    final current = eta.current?.height ?? syncedHeight;
    final total = end - start;
    if (total <= 0) return 0;
    if (current >= end) return 100;
    final advanced = current - start;
    if (advanced <= 0) return 0;
    final pct = (advanced * 100.0) / total;
    final floorPct = pct.floor();
    final clamped = floorPct == 0 ? 1 : floorPct.clamp(1, 99);
    return clamped;
  }

  int? get confirmHeight {
    final lh = latestHeight;
    if (lh == null) return null;
    final ch = lh - appSettings.anchorOffset;
    return max(ch, 0);
  }

  @action
  void reset() {
    isRescan = false;
    syncJustCompleted = false;
    syncingCoin = null;
    syncedHeight = WarpApi.getDbHeight(aa.coin).height;
    syncing = false;
    paused = false;
    showSyncBanner = false;
  }
  
  // Called by SyncStatusWidget after fade-out animation completes
  @action
  void clearSyncCompleted() {
    syncJustCompleted = false;
    isRescan = false;
  }

  @action
  Future<void> update() async {
    // CLOAK uses EOSIO API, not lightwalletd
    if (CloakWalletManager.isCloak(aa.coin)) {
      // CLOAK coin - checking EOSIO chain status
      try {
        await CloakSync.init();
        await CloakSync.updateLatestHeight();
        syncedHeight = CloakSync.getWalletBlockNum();
        latestHeight = CloakSync.latestHeight;
        connected = true;
        aa.updatePoolBalances();
      } catch (e) {
        logger.d('[UPDATE] CLOAK error: $e');
        connected = false;
      }
      return;
    }
    
    try {
      // Ensure Lightwalletd URL is configured for the active coin before querying heights
      try {
        final c = coins[aa.coin];
        final settings = CoinSettingsExtension.load(aa.coin);
        String url = '';
        final idx = settings.lwd.index;
        final custom = settings.lwd.customURL.trim();
        if (idx >= 0 && idx < c.lwd.length) {
          url = c.lwd[idx].url;
        } else if (custom.isNotEmpty) {
          url = custom;
        } else if (c.lwd.isNotEmpty) {
          settings.lwd.index = 0;
          settings.save(aa.coin);
          url = c.lwd.first.url;
        }
        if (url.isNotEmpty) {
          WarpApi.updateLWD(aa.coin, url);
        }
      } catch (_) {}
      final lh = latestHeight;
      latestHeight = await WarpApi.getLatestHeight(aa.coin);
      if (lh == null && latestHeight != null) aa.update(latestHeight);
      connected = true;
    } on String catch (e) {
      logger.d(e);
      connected = false;
    }
    syncedHeight = WarpApi.getDbHeight(aa.coin).height;
  }

  @action
  Future<void> sync(bool rescan, {bool auto = false}) async {
    logger.d('R/A/P/S $rescan $auto $paused $syncing');
    if (paused) return;
    if (syncing) return;

    // Don't sync if there's no account
    if (aa.id == 0) {
      return;
    }
    
    // CLOAK uses EOSIO sync, not lightwalletd
    if (CloakWalletManager.isCloak(aa.coin)) {
      if (CloakSync.isNewAccount) {
        // Just update the height silently without showing sync icon
        await CloakSync.init();
        await CloakSync.updateLatestHeight();
        return;
      }

      // Check if this is a full sync (restore) or normal sync
      final needsFullSync = await CloakSync.needsFullSync();

      if (needsFullSync) {
        syncing = true;
        syncingCoin = aa.coin;  // Track which coin is syncing
        isRescan = true;
      } else {
        syncing = true;
        syncingCoin = aa.coin;  // Track which coin is syncing
        isRescan = false;
      }

      try {
        // Set up progress callbacks for UI updates
        CloakSync.onProgress = (current, total) {
          syncedHeight = current;
          latestHeight = total;
        };
        CloakSync.onStepChanged = (step) {
          syncStep = step;
        };

        // Sync returns true if this was a full sync
        final heightBefore = CloakSync.syncedHeight;
        final wasFullSync = await CloakSync.sync();
        final heightAfter = CloakSync.syncedHeight;

        // Set completion BEFORE updating real heights — prevents banner
        // disappearing between isSynced=true and syncJustCompleted=true
        if (wasFullSync) {
          syncJustCompleted = true;
        }

        // Now safe to update real heights (banner stays visible via syncJustCompleted)
        syncedHeight = CloakSync.syncedHeight;
        latestHeight = CloakSync.latestHeight;

        // Always call aa.update() for CLOAK — the FFI call is fast (~1ms) and
        // the eager wallet update after zsign may have added outgoing notes
        // that need to appear in the TX list even before on-chain confirmation.
        print('[SYNC_DEBUG] Calling aa.update(${CloakSync.syncedHeight}) — txs.items.length=${aa.txs.items.length}');
        aa.update(CloakSync.syncedHeight);
        print('[SYNC_DEBUG] After aa.update — txs.items.length=${aa.txs.items.length}');
      } catch (e) {
        logger.d('[SYNC] CLOAK sync error: $e');
      } finally {
        syncing = false;
        syncingCoin = null;  // Clear syncing coin
        isRescan = false;
        syncStep = null;
        CloakSync.onProgress = null;
        CloakSync.onStepChanged = null;
      }
      return;
    }
    
    // Set syncing immediately to prevent re-entry, before any async work
    syncing = true;
    syncingCoin = aa.coin;  // Track which coin is syncing
    isRescan = rescan;
    
    try {
      // For manual/rescan syncs, skip the blocking update() call.
      // Rust will get the latest height internally.
      // Only do the lightweight check for auto-sync to avoid unnecessary work.
      if (auto) {
        // Quick check if we need to sync - but don't block on network call
        final lh = latestHeight; // Use cached value
        if (lh != null) {
          final gap = lh - syncedHeight;
          if (gap > oneMonthBlockThreshold) {
            paused = true;
            syncing = false;
            return;
          }
          if (syncedHeight >= lh) {
            // Already synced, just do transparent sync in background
            syncing = false;
            try {
              await WarpApi.transparentSync(aa.coin, aa.id, lh);
              aa.updatePoolBalances();
            } catch (_) {}
            return;
          }
        }
      }
      
      _updateSyncedHeight();
      // Capture the session start height for progress calculation
      startSyncedHeight = syncedHeight;
      // Re-initialize ETA from this session start so progress reflects this run
      // Use a large estimated height if we don't have latestHeight yet
      final estimatedEnd = latestHeight ?? (syncedHeight + 100000);
      eta.begin(estimatedEnd);
      eta.checkpoint(syncedHeight, DateTime.now());

      // Store pre-balance for completion handler
      _syncPreBalance = AccountBalanceSnapshot(
          coin: aa.coin, id: aa.id, balance: aa.poolBalances.total);
      
      // Fire-and-forget: returns immediately, completion handled via port
      WarpApi.warpSyncAsync(
          aa.coin,
          aa.id,
          !appSettings.nogetTx,
          appSettings.anchorOffset,
          coinSettings.spamFilter ? 50 : 1000000,
          syncProgressPort2.sendPort.nativePort);
      // UI is now free! Sync runs in background thread.
    } on String catch (e) {
      logger.d(e);
      // Don't show database constraint errors to user - they're internal sync issues
      if (!e.toLowerCase().contains('unique constraint')) {
        showSnackBar(e);
      }
      // Clean up on error
      _syncPreBalance = null;
      syncing = false;
      syncingCoin = null;  // Clear syncing coin on error
    }
  }

  /// Called when sync completes (via progress port with height=0xFFFFFFFF)
  @action
  Future<void> _handleSyncCompletion(int resultCode) async {
    print('[SYNC COMPLETE] === SYNC COMPLETION HANDLER ===');
    print('[SYNC COMPLETE] Result code: $resultCode (0=success, 1=reorg, 2=busy, 255=error)');
    print('[SYNC COMPLETE] Current syncedHeight: $syncedHeight, latestHeight: $latestHeight');
    
    try {
      // Handle result codes: 0=success, 1=reorg, 2=busy, 255=error
      if (resultCode == 1) {
        logger.d('Sync detected reorg');
        print('[SYNC COMPLETE] REORG detected');
      } else if (resultCode == 2) {
        logger.d('Sync busy');
        print('[SYNC COMPLETE] BUSY - sync already in progress');
      } else if (resultCode == 255) {
        logger.d('Sync error');
        print('[SYNC COMPLETE] ERROR during sync');
      }

      // Get balances BEFORE update
      final preT = aa.poolBalances.transparent;
      final preS = aa.poolBalances.sapling;
      final preO = aa.poolBalances.orchard;
      print('[SYNC COMPLETE] Pre-update balances: T=$preT, S=$preS, O=$preO');

      // Also sync transparent UTXOs
      try {
        if (latestHeight != null) {
          print('[SYNC COMPLETE] Running transparent sync to height $latestHeight...');
          await WarpApi.transparentSync(aa.coin, aa.id, latestHeight!);
          print('[SYNC COMPLETE] Transparent sync complete');
        }
      } catch (e) {
        print('[SYNC COMPLETE] Transparent sync error: $e');
      }

      print('[SYNC COMPLETE] Calling aa.update($latestHeight)...');
      aa.update(latestHeight);
      
      // Get balances AFTER update
      final postT = aa.poolBalances.transparent;
      final postS = aa.poolBalances.sapling;
      final postO = aa.poolBalances.orchard;
      print('[SYNC COMPLETE] Post-update balances: T=$postT, S=$postS, O=$postO');
      print('[SYNC COMPLETE] Total balance: ${aa.poolBalances.total}');
      print('[SYNC COMPLETE] hasAnyFunds check: T>0=${postT > 0}, S>0=${postS > 0}, O>0=${postO > 0}, any=${postT > 0 || postS > 0 || postO > 0}');
      
      contacts.fetchContacts();
      marketPrice.update();

      // Refresh vault balance if in vault mode (picks up external deposits)
      if (isVaultMode) {
        refreshActiveVaultBalance();
      }

      // Check for balance change notifications
      final preBalance = _syncPreBalance;
      if (preBalance != null) {
        final postBalance = AccountBalanceSnapshot(
            coin: aa.coin, id: aa.id, balance: aa.poolBalances.total);
        if (preBalance.sameAccount(postBalance) &&
            preBalance.balance != postBalance.balance) {
          try {
            if (GetIt.I.isRegistered<S>()) {
              S s = GetIt.I.get<S>();
              final ticker = coins[aa.coin].ticker;
              if (preBalance.balance < postBalance.balance) {
                final amount =
                    amountToString2(postBalance.balance - preBalance.balance);
                showLocalNotification(
                  id: latestHeight!,
                  title: s.incomingFunds,
                  body: s.received(amount, ticker),
                );
              } else {
                final amount =
                    amountToString2(preBalance.balance - postBalance.balance);
                showLocalNotification(
                  id: latestHeight!,
                  title: s.paymentMade,
                  body: s.spent(amount, ticker),
                );
              }
            }
          } catch (e) {
            logger.d('Notification error: $e');
          }
        }
      }
    } finally {
      _syncPreBalance = null;
      syncing = false;
      syncingCoin = null;  // Clear syncing coin on completion
      // If this session was a rescan/rewind and we've reached latest, signal completion
      // Don't clear isRescan yet - widget will do that after fade-out animation
      if (isRescan && isSynced) {
        syncJustCompleted = true;
        // isRescan stays true until widget calls clearSyncCompleted() after fade
      }
      eta.end();
    }
  }

  @action
  Future<void> rescan(int height) async {
    print('[RESCAN] === STARTING RESCAN === from height $height');
    print('[RESCAN] Calling WarpApi.rescanFrom(${aa.coin}, $height)...');
    WarpApi.rescanFrom(aa.coin, height);
    _updateSyncedHeight();
    print('[RESCAN] After rescanFrom, syncedHeight=$syncedHeight');
    paused = false;
    print('[RESCAN] Starting sync(true)...');
    await sync(true);
    print('[RESCAN] sync(true) returned');
  }

  @action
  void setPause(bool v) {
    paused = v;
  }

  @action
  void setProgress(Progress progress) {
    trialDecryptionCount = progress.trialDecryptions;
    syncedHeight = progress.height;
    downloadedSize = progress.downloaded;
    if (progress.timestamp > 0)
      timestamp =
          DateTime.fromMillisecondsSinceEpoch(progress.timestamp * 1000);
    eta.checkpoint(syncedHeight, DateTime.now());
    // Compute completion based on latest height vs current db height
    int? percent;
    final lh = latestHeight;
    if (lh != null) {
      final start = startSyncedHeight;
      final total = lh - start;
      if (total > 0) {
        if (syncedHeight >= lh) {
          percent = 100;
        } else {
          final advanced = syncedHeight - start;
          if (advanced > 0) {
            final pct = (advanced * 100.0) / total;
            final pf = pct.floor();
            percent = pf == 0 ? 1 : pf.clamp(1, 99);
          } else {
            percent = 0;
          }
        }
      } else {
        percent = 0;
      }
    }
    if (percent != null && percent >= 100) {
      showSyncBanner = false;
    }
  }

  // Explicit trigger to display the banner after an account restore
  @action
  void triggerBannerForRestore() {
    showSyncBanner = true;
    isRescan = true;  // This controls banner visibility in SyncStatusWidget
  }

  void _updateSyncedHeight() {
    final h = WarpApi.getDbHeight(aa.coin);
    syncedHeight = h.height;
    timestamp = (h.timestamp != 0)
        ? DateTime.fromMillisecondsSinceEpoch(h.timestamp * 1000)
        : null;
    // Initialize ETA checkpoints if missing so progress can advance from 0%
    if (!eta.running && latestHeight != null) {
      eta.begin(latestHeight!);
      eta.checkpoint(syncedHeight, DateTime.now());
    }
  }
}

class ETA = _ETA with _$ETA;

abstract class _ETA with Store {
  @observable
  int endHeight = 0;
  @observable
  ETACheckpoint? start;
  @observable
  ETACheckpoint? prev;
  @observable
  ETACheckpoint? current;

  @action
  void begin(int height) {
    end();
    endHeight = height;
  }

  @action
  void end() {
    start = null;
    prev = null;
    current = null;
  }

  @action
  void checkpoint(int height, DateTime timestamp) {
    prev = current;
    current = ETACheckpoint(height, timestamp);
    if (start == null) start = current;
  }

  @computed
  int? get remaining {
    return current?.let((c) => endHeight - c.height);
  }

  @computed
  String get timeRemaining {
    final defaultMsg = "Calculating ETA";
    final p = prev;
    final c = current;
    if (p == null || c == null) return defaultMsg;
    if (c.timestamp.millisecondsSinceEpoch ==
        p.timestamp.millisecondsSinceEpoch) return defaultMsg;
    final speed = (c.height - p.height) /
        (c.timestamp.millisecondsSinceEpoch -
            p.timestamp.millisecondsSinceEpoch);
    if (speed == 0) return defaultMsg;
    final eta = (endHeight - c.height) / speed;
    if (eta <= 0) return defaultMsg;
    final duration =
        Duration(milliseconds: eta.floor()).toString().split('.')[0];
    return "ETA: $duration";
  }

  @computed
  bool get running => start != null;

  @computed
  int? get progress {
    if (!running) return null;
    final sh = start!.height;
    final ch = current!.height;
    final total = endHeight - sh;
    if (total <= 0) return 0;
    if (ch >= endHeight) return 100;
    final advanced = ch - sh;
    if (advanced <= 0) return 0;
    final pct = (advanced * 100.0) / total;
    // Show at least 1% once progress has advanced
    final percent = pct.floor();
    return percent == 0 ? 1 : percent.clamp(1, 99);
  }
}

class ETACheckpoint {
  int height;
  DateTime timestamp;

  ETACheckpoint(this.height, this.timestamp);
}

var marketPrice = MarketPrice();

class MarketPrice = _MarketPrice with _$MarketPrice;

abstract class _MarketPrice with Store {
  @observable
  double? price;
  @observable
  DateTime? timestamp;

  String _prefsKeyPrice(String coin, String fiat) => 'fx_price_v1_'+coin+'_'+fiat.toUpperCase();
  String _prefsKeyTs(String coin, String fiat) => 'fx_price_ts_v1_'+coin+'_'+fiat.toUpperCase();

  @action
  Future<void> loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final c = coins[aa.coin];
      final fiat = appSettings.currency;
      final pk = _prefsKeyPrice(c.currency, fiat);
      final tk = _prefsKeyTs(c.currency, fiat);
      final cached = prefs.getDouble(pk);
      final tsMillis = prefs.getInt(tk);
      if (cached != null) {
        price = cached;
        if (tsMillis != null && tsMillis > 0) {
          timestamp = DateTime.fromMillisecondsSinceEpoch(tsMillis);
        }
      }
    } catch (_) {}
  }

  @action
  Future<void> update() async {
    final c = coins[aa.coin];
    final fetched = await getFxRate(c.currency, appSettings.currency);
    // Preserve last known price when fetch fails to avoid flicker/hide
    if (fetched != null) {
      price = fetched;
      timestamp = DateTime.now();
      try {
        final prefs = await SharedPreferences.getInstance();
        final pk = _prefsKeyPrice(c.currency, appSettings.currency);
        final tk = _prefsKeyTs(c.currency, appSettings.currency);
        await prefs.setDouble(pk, fetched);
        await prefs.setInt(tk, timestamp!.millisecondsSinceEpoch);
      } catch (_) {}
    }
  }

  int? lastChartUpdateTime;
}

var contacts = ContactStore();

class ContactStore = _ContactStore with _$ContactStore;

abstract class _ContactStore with Store {
  @observable
  ObservableList<Contact> contacts = ObservableList<Contact>.of([]);

  // Fast lookup used by messaging UI: counterparty address -> contact display name
  // Rebuilt whenever contacts are fetched/updated.
  Map<String, String> addressToName = {};

  @action
  void fetchContacts() {
    // CLOAK uses CloakDb for contacts
    if (CloakWalletManager.isCloak(aa.coin)) {
      _fetchCloakContacts();
      return;
    }

    final fetched = WarpApi.getContacts(aa.coin);
    contacts.clear();
    contacts.addAll(fetched);
    // Rebuild the address -> name map for O(1) title lookups
    final Map<String, String> nextMap = {};
    for (final c in fetched) {
      try {
        final t = c.unpack();
        final addr = (t.address ?? '').trim();
        final name = (t.name ?? '').trim();
        if (addr.isNotEmpty && name.isNotEmpty) {
          nextMap[addr] = name;
        }
      } catch (_) {}
    }
    addressToName = nextMap;
  }

  /// Fetch CLOAK contacts from CloakDb
  Future<void> _fetchCloakContacts() async {
    try {
      final rows = await CloakDb.getContacts();
      contacts.clear();
      final Map<String, String> nextMap = {};
      for (final row in rows) {
        final id = row['id'] as int;
        final name = row['name'] as String;
        final address = row['address'] as String;
        // Create a ContactObjectBuilder and pack it to Contact for compatibility
        final builder = ContactObjectBuilder(id: id, name: name, address: address);
        contacts.add(Contact(builder.toBytes()));
        if (address.isNotEmpty && name.isNotEmpty) {
          nextMap[address] = name;
        }
      }
      addressToName = nextMap;
    } catch (e) {
      print('ContactStore: Error fetching CLOAK contacts: $e');
      contacts.clear();
      addressToName = {};
    }
  }

  @action
  void add(Contact c) {
    if (CloakWalletManager.isCloak(aa.coin)) {
      _addCloakContact(c);
      return;
    }
    WarpApi.storeContact(aa.coin, c.id, c.name!, c.address!, true);
    markContactsSaved(aa.coin, false);
    fetchContacts();
  }

  /// Add CLOAK contact to CloakDb
  Future<void> _addCloakContact(Contact c) async {
    try {
      final ct = c.unpack();
      await CloakDb.addContact(name: ct.name ?? '', address: ct.address ?? '');
      fetchContacts();
    } catch (e) {
      print('ContactStore: Error adding CLOAK contact: $e');
    }
  }

  @action
  void remove(Contact c) {
    if (CloakWalletManager.isCloak(aa.coin)) {
      _removeCloakContact(c);
      return;
    }
    contacts.removeWhere((contact) => contact.id == c.id);
    // Helpers with simple retries to avoid transient "database is locked"
    Future<void> retry(int attempts, Future<void> Function() op) async {
      int i = 0; int delayMs = 120;
      while (true) {
        try { await op(); return; } catch (_) {
          if (++i >= attempts) rethrow;
          await Future.delayed(Duration(milliseconds: delayMs));
          delayMs = (delayMs * 2).clamp(120, 1000);
        }
      }
    }
    // Mark UA and CID blocked to prevent auto-recreation via handshake
    final ua = (c.address ?? '').trim();
    if (ua.isNotEmpty) {
      // ignore errors; best-effort
      // using retry for sqlite busy
      () async { await retry(5, () async { WarpApi.setProperty(aa.coin, 'contact_block_' + ua, '1'); }); }();
    }
    try {
      final cid = WarpApi.getProperty(aa.coin, 'contact_cid_' + c.id.toString()).trim();
      if (cid.isNotEmpty) {
        () async { await retry(5, () async { WarpApi.setProperty(aa.coin, 'cid_block_' + cid, '1'); }); }();
        // Best-effort hygiene: clear cached cid metadata so stale names or mappings don't linger
        () async { await retry(5, () async { WarpApi.setProperty(aa.coin, 'cid_name_' + cid, ''); }); }();
        () async { await retry(5, () async { WarpApi.setProperty(aa.coin, 'cid_invite_name_' + cid, ''); }); }();
        () async { await retry(5, () async { WarpApi.setProperty(aa.coin, 'cid_inviter_contact_id_' + cid, ''); }); }();
        () async { await retry(5, () async { WarpApi.setProperty(aa.coin, 'cid_map_' + cid, ''); }); }();
      }
    } catch (_) {}
    // Clear linkage so future compose treats it as a new conversation
    () async { await retry(5, () async { WarpApi.setProperty(aa.coin, 'contact_cid_' + c.id.toString(), ''); }); }();
    () async { await retry(5, () async { WarpApi.storeContact(aa.coin, c.id, c.name!, "", true); }); }();
    markContactsSaved(aa.coin, false);
    fetchContacts();
  }

  /// Remove CLOAK contact from CloakDb
  Future<void> _removeCloakContact(Contact c) async {
    try {
      contacts.removeWhere((contact) => contact.id == c.id);
      await CloakDb.deleteContact(c.id);
      fetchContacts();
    } catch (e) {
      print('ContactStore: Error removing CLOAK contact: $e');
    }
  }

  @action
  markContactsSaved(int coin, bool v) {
    coinSettings.contactsSaved = true;
    coinSettings.save(coin);
  }
}

class AccountBalanceSnapshot {
  final int coin;
  final int id;
  final int balance;
  AccountBalanceSnapshot({
    required this.coin,
    required this.id,
    required this.balance,
  });

  bool sameAccount(AccountBalanceSnapshot other) =>
      coin == other.coin && id == other.id;

  @override
  String toString() => '($coin, $id, $balance)';
}

@freezed
class SeedInfo with _$SeedInfo {
  const factory SeedInfo({
    required String seed,
    required int index,
  }) = _SeedInfo;
}

@freezed
class TxMemo with _$TxMemo {
  const factory TxMemo({
    required String address,
    required String memo,
  }) = _TxMemo;
}

@freezed
class SwapAmount with _$SwapAmount {
  const factory SwapAmount({
    required String amount,
    required String currency,
  }) = _SwapAmount;
}

@freezed
class SwapQuote with _$SwapQuote {
  const factory SwapQuote({
    required String estimated_amount,
    required String rate_id,
    required String valid_until,
  }) = _SwapQuote;

  factory SwapQuote.fromJson(Map<String, dynamic> json) =>
      _$SwapQuoteFromJson(json);
}

@freezed
class SwapRequest with _$SwapRequest {
  const factory SwapRequest({
    required bool fixed,
    required String rate_id,
    required String currency_from,
    required String currency_to,
    required double amount_from,
    required String address_to,
  }) = _SwapRequest;

  factory SwapRequest.fromJson(Map<String, dynamic> json) =>
      _$SwapRequestFromJson(json);
}

@freezed
class SwapLeg with _$SwapLeg {
  const factory SwapLeg({
    required String symbol,
    required String name,
    required String image,
    required String validation_address,
    required String address_explorer,
    required String tx_explorer,
  }) = _SwapLeg;

  factory SwapLeg.fromJson(Map<String, dynamic> json) =>
      _$SwapLegFromJson(json);
}

@freezed
class SwapResponse with _$SwapResponse {
  const factory SwapResponse({
    required String id,
    required String timestamp,
    required String currency_from,
    required String currency_to,
    required String amount_from,
    required String amount_to,
    required String address_from,
    required String address_to,
  }) = _SwapResponse;

  factory SwapResponse.fromJson(Map<String, dynamic> json) =>
      _$SwapResponseFromJson(json);
}

@freezed
class Election with _$Election {
  const factory Election({
    required int id,
    required String name,
    required int start_height,
    required int end_height,
    required int close_height,
    required String submit_url,
    required String question,
    required List<String> candidates,
    required String status,
  }) = _Election;

  factory Election.fromJson(Map<String, dynamic> json) =>
      _$ElectionFromJson(json);
}

@freezed
class Vote with _$Vote {
  const factory Vote({
    required Election election,
    required List<VoteNoteT> notes,
    int? candidate,
  }) = _Vote;
}
