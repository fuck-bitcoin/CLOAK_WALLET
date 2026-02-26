import 'dart:async';
import 'dart:math';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:get_it/get_it.dart';
import 'package:mobx/mobx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'appsettings.dart';
import 'cloak/cloak_types.dart';
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

// Pool migration classes removed — CLOAK uses single shielded pool

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

// initSyncListener removed — CLOAK uses CloakSync, not ReceivePort
void initSyncListener() {
  // No-op for CLOAK — sync progress handled by CloakSync.onProgress callback
}

Timer? syncTimer;

Future<void> startAutoSync() async {
  if (syncTimer == null) {
    // Don't start sync if there's no account yet
    if (aa.id == 0) {
      // No account - skipping initial sync
      // Still set up the timer for when an account is created
      syncTimer = Timer.periodic(Duration(seconds: 1), (timer) {
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
    syncTimer = Timer.periodic(Duration(seconds: 1), (timer) {
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
  // then continue with the normal 1s cadence.
  syncTimer = Timer(delay, () {
    // Skip if sync is in progress
    if (syncStatus2.syncing) {
      // Rescheduled tick skipped - sync in progress
      _rescheduleAutoSyncAfter(Duration(seconds: 2));
      return;
    }
    syncStatus2.sync(false, auto: true);
    syncTimer = Timer.periodic(Duration(seconds: 1), (timer) {
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
    _rescheduleAutoSyncAfter(Duration(seconds: 2));
    return;
  }
  // Manual action explicitly unpauses sync if it had been auto-paused
  if (syncStatus2.paused) syncStatus2.setPause(false);
  await syncStatus2.sync(false);
  // Resume auto-sync 2s after manual completes
  _rescheduleAutoSyncAfter(Duration(seconds: 2));
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

  // True when Hyperion has failed 3+ times in incremental sync this session.
  // Once set, Hyperion is skipped for the rest of the session.
  @observable
  bool sessionSlowMode = false;

  // True when the current sync cycle is using block-direct (slow mode active)
  @observable
  bool isSlowMode = false;

  // Leaf count gap between chain and wallet — drives catch-up banner
  @observable
  int leafGap = 0;

  // True while a full sync (restore) is still pending — keeps banner visible
  // between retry attempts even when syncing toggles false briefly
  @observable
  bool fullSyncPending = false;

  @computed
  int get changed => Object.hashAll([connected, syncedHeight, latestHeight, syncing, paused, syncStep, isSlowMode, leafGap, fullSyncPending]);

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
    fullSyncPending = false;
    syncingCoin = null;
    syncedHeight = 0;
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

      syncing = true;
      syncingCoin = aa.coin;
      if (needsFullSync) {
        isRescan = true;
        fullSyncPending = true;  // Sticky — only cleared on genuine success
      }

      // Initialize step-based progress so the banner shows 0% immediately
      // instead of staying blank until the first onProgress callback fires.
      // Without this, latestHeight=null fails the condition in sync_status.dart
      // and _actualProgress stays 0.0.
      if (latestHeight == null || latestHeight == 0) {
        syncedHeight = 0;
        latestHeight = 100;
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
        CloakSync.onSlowModeChanged = (slow) {
          runInAction(() {
            isSlowMode = slow;
            if (slow) sessionSlowMode = true;
          });
        };
        CloakSync.onLeafGapChanged = (gap) {
          runInAction(() { leafGap = gap; });
        };

        // Sync returns true if this was a full sync
        final wasFullSync = await CloakSync.sync();

        // Check if full sync is genuinely done (wallet has all the data)
        final stillPending = await CloakSync.needsFullSync();

        if (wasFullSync && !stillPending) {
          // Full sync genuinely completed — show completion banner
          syncJustCompleted = true;
          fullSyncPending = false;
          isRescan = false;
          // Only update heights to real values when sync is genuinely done —
          // otherwise isSynced flips true and the banner blinks hide/show
          syncedHeight = CloakSync.syncedHeight;
          latestHeight = CloakSync.latestHeight;
        } else if (!fullSyncPending) {
          // Normal incremental sync — safe to update heights
          syncedHeight = CloakSync.syncedHeight;
          latestHeight = CloakSync.latestHeight;
        }
        // When fullSyncPending: keep heights at progress values so isSynced stays
        // false and the banner remains visible between retry attempts.

        // Always call aa.update() for CLOAK — the FFI call is fast (~1ms) and
        // the eager wallet update after zsign may have added outgoing notes
        // that need to appear in the TX list even before on-chain confirmation.
        aa.update(CloakSync.syncedHeight);

        // Force Observer rebuild — aa.update() mutates @observable fields which
        // SHOULD trigger MobX, but the mutations happen after an async boundary
        // (await CloakSync.sync()) which can break MobX action batching.
        // aaSequence.seqno is the guaranteed rebuild trigger the Observer tracks.
        aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
      } catch (e) {
        logger.d('[SYNC] CLOAK sync error: $e');
      } finally {
        syncing = false;
        syncingCoin = null;
        // fullSyncPending and isRescan are only cleared in the success path
        // above — they stay true here to keep the banner stable between retries
        syncStep = null;
        CloakSync.onProgress = null;
        CloakSync.onStepChanged = null;
        CloakSync.onSlowModeChanged = null;
        CloakSync.onLeafGapChanged = null;
      }
      return;
    }
    // Only CLOAK sync is supported
  }

  @action
  Future<void> rescan(int height) async {
    syncedHeight = 0;
    paused = false;
    await sync(true);
  }

  @action
  void setPause(bool v) {
    paused = v;
  }

  // Explicit trigger to display the banner after an account restore
  @action
  void triggerBannerForRestore() {
    showSyncBanner = true;
    isRescan = true;
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
  ObservableList<CloakContact> contacts = ObservableList<CloakContact>.of([]);

  // Fast lookup used by messaging UI: counterparty address -> contact display name
  Map<String, String> addressToName = {};

  @action
  void fetchContacts() {
    _fetchCloakContacts();
  }

  Future<void> _fetchCloakContacts() async {
    try {
      final rows = await CloakDb.getContacts();
      contacts.clear();
      final Map<String, String> nextMap = {};
      for (final row in rows) {
        final id = row['id'] as int;
        final name = row['name'] as String;
        final address = row['address'] as String;
        contacts.add(CloakContact(id: id, name: name, address: address));
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
  void add(CloakContact c) {
    _addCloakContact(c);
  }

  Future<void> _addCloakContact(CloakContact c) async {
    try {
      await CloakDb.addContact(name: c.name ?? '', address: c.address ?? '');
      fetchContacts();
    } catch (e) {
      print('ContactStore: Error adding CLOAK contact: $e');
    }
  }

  @action
  void remove(CloakContact c) {
    _removeCloakContact(c);
  }

  Future<void> _removeCloakContact(CloakContact c) async {
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

// SwapAmount kept for widgets.dart compatibility (SwapAmountWidget)
@freezed
class SwapAmount with _$SwapAmount {
  const factory SwapAmount({
    required String amount,
    required String currency,
  }) = _SwapAmount;
}

// Zcash swap/election/vote classes removed — not used by CLOAK
