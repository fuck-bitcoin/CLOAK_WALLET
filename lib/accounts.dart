import 'dart:convert';
import 'dart:math';

import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tuple/tuple.dart';
import 'package:warp_api/data_fb_generated.dart' hide Quote;
import 'appsettings.dart';
import 'cloak/cloak_wallet_manager.dart';
import 'cloak/cloak_db.dart';
import 'coin/coins.dart';
import 'package:mobx/mobx.dart';
import 'package:warp_api/warp_api.dart';

import 'pages/utils.dart';

part 'accounts.g.dart';

final ActiveAccount2 nullAccount =
    ActiveAccount2(0, 0, "", null, false, false, false);

ActiveAccount2 aa = nullAccount;

AASequence aaSequence = AASequence();
class AASequence = _AASequence with _$AASequence;

abstract class _AASequence with Store {
  @observable
  int seqno = 0;

  @observable
  int settingsSeqno = 0;
}

// ── Vault-as-Account state ──────────────────────────────────────
bool _isVaultMode = false;
String? _activeVaultHash;
String? _activeVaultLabel;
Map<String, dynamic>? _activeVaultData;
VaultTokensResult? _activeVaultTokens;

/// Whether the current view is a vault rather than a wallet account
bool get isVaultMode => _isVaultMode;
/// The selected vault's commitment hash (64 hex chars)
String? get activeVaultHash => _activeVaultHash;
/// Display name for the selected vault
String? get activeVaultLabel => _activeVaultLabel;
/// Full vault DB record
Map<String, dynamic>? get activeVaultData => _activeVaultData;
/// Cached vault token data (FTs + NFTs) from last query
VaultTokensResult? get activeVaultTokens => _activeVaultTokens;

/// Switch active view to a vault
void setActiveVault(String commitmentHash, {String? label, Map<String, dynamic>? vaultData}) {
  _isVaultMode = true;
  _activeVaultHash = commitmentHash;
  _activeVaultLabel = label ?? 'Vault';
  _activeVaultData = vaultData;
  _activeVaultTokens = null;

  // Ensure CLOAK account is active (vaults are always CLOAK)
  coinSettings = CoinSettingsExtension.load(CLOAK_COIN);
  aa = ActiveAccount2.fromId(CLOAK_COIN, 1);

  // Start with zero balance — will be updated async
  aa.poolBalances = PoolBalanceT();

  // Trigger UI rebuild
  aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;

  // Fetch vault balance asynchronously
  CloakWalletManager.clearVaultTokensCache();
  _fetchActiveVaultBalance(commitmentHash);
}

/// Refresh vault balance (call on pull-to-refresh or after withdrawal).
/// Returns a Future so callers can await the on-chain query.
Future<void> refreshActiveVaultBalance() async {
  if (!_isVaultMode || _activeVaultHash == null) return;
  CloakWalletManager.clearVaultTokensCache();
  await _fetchActiveVaultBalance(_activeVaultHash!);
}

/// Fetch on-chain vault balance and update poolBalances + token data.
/// Uses runInAction for proper MobX batching so Observers are notified.
Future<void> _fetchActiveVaultBalance(String commitmentHash) async {
  try {
    print('[_fetchActiveVaultBalance] querying chain for ${commitmentHash.substring(0, 16)}...');
    final result = await CloakWalletManager.queryVaultTokens(commitmentHash);
    print('[_fetchActiveVaultBalance] chain returned cloakUnits=${result.cloakUnits}');
    if (_isVaultMode && _activeVaultHash == commitmentHash) {
      final oldBalance = aa.poolBalances.sapling;
      _activeVaultTokens = result;
      if (result.cloakUnits != oldBalance) {
        print('[_fetchActiveVaultBalance] Balance CHANGED $oldBalance → ${result.cloakUnits} — updating');
        runInAction(() {
          final balance = PoolBalanceT();
          balance.sapling = result.cloakUnits;
          aa.poolBalances = balance;
          aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
        });
      }
    }
  } catch (e) {
    print('[_fetchActiveVaultBalance] Error: $e');
  }
}

void setActiveAccount(int coin, int id) {
  // Clear vault mode
  _isVaultMode = false;
  _activeVaultHash = null;
  _activeVaultLabel = null;
  _activeVaultData = null;
  _activeVaultTokens = null;

  coinSettings = CoinSettingsExtension.load(coin);
  aa = ActiveAccount2.fromId(coin, id);
  coinSettings.account = id;
  coinSettings.save(coin);
  aa.updateDivisified();
  aa.update(null);
  aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
}

class ActiveAccount2 extends _ActiveAccount2 with _$ActiveAccount2 {
  ActiveAccount2(super.coin, super.id, super.name, super.seed, super.canPay,
      super.external, super.saved);

  static ActiveAccount2? fromPrefs(SharedPreferences prefs) {
    final coin = prefs.getInt('coin') ?? 0;
    var id = prefs.getInt('account') ?? 0;
    
    // Handle CLOAK separately
    if (CloakWalletManager.isCloak(coin)) {
      // CLOAK always has account ID 1 if wallet exists
      if (CloakWalletManager.isLoaded || CloakWalletManager.walletExistsSync()) {
        return ActiveAccount2.fromId(coin, 1);
      }
    } else if (WarpApi.checkAccount(coin, id)) {
      return ActiveAccount2.fromId(coin, id);
    }
    
    for (var c in coins) {
      if (CloakWalletManager.isCloak(c.coin)) {
        // Check if CLOAK wallet exists
        if (CloakWalletManager.walletExistsSync()) {
          return ActiveAccount2.fromId(c.coin, 1);
        }
      } else {
        final id = WarpApi.getFirstAccount(c.coin);
        if (id > 0) return ActiveAccount2.fromId(c.coin, id);
      }
    }
    return null;
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setInt('coin', coin);
    await prefs.setInt('account', id);
  }

  factory ActiveAccount2.fromId(int coin, int id) {
    if (id == 0) return nullAccount;
    
    // Handle CLOAK separately
    if (CloakWalletManager.isCloak(coin)) {
      // For CLOAK, we don't have a backup in the same format
      // Use the account name from CloakWalletManager
      final isViewOnly = CloakWalletManager.isViewOnly() ?? false;
      final name = CloakWalletManager.accountName;
      return ActiveAccount2(
          coin, 1, name, null, !isViewOnly, false, true);
    }
    
    final backup = WarpApi.getBackup(coin, id);
    final canPay = backup.sk != null;
    return ActiveAccount2(
        coin, id, backup.name!, backup.seed, canPay, false, backup.saved);
  }

  bool get hasUA => coins[coin].supportsUA;
}

abstract class _ActiveAccount2 with Store {
  final int coin;
  final int id;
  final String name;
  final String? seed;
  final bool canPay;
  final bool external;
  final bool saved;

  _ActiveAccount2(this.coin, this.id, this.name, this.seed, this.canPay,
      this.external, this.saved)
      : notes = Notes(coin, id),
        txs = Txs(coin, id),
        messages = Messages(coin, id);

  @observable
  String diversifiedAddress = '';

  @observable
  int height = 0;

  @observable
  String currency = '';

  @observable
  PoolBalanceT poolBalances = PoolBalanceT();
  Notes notes;
  Txs txs;
  Messages messages;

  List<Spending> spendings = [];
  List<TimeSeriesPoint<double>> accountBalances = [];

  @action
  void reset(int resetHeight) {
    poolBalances = PoolBalanceT();
    notes.clear();
    txs.clear();
    messages.clear();
    spendings = [];
    accountBalances = [];
    height = resetHeight;
  }

  @action
  void updatePoolBalances() {
    print('[BALANCE] updatePoolBalances called for coin=$coin, id=$id');

    // In vault mode, balance is managed by _fetchActiveVaultBalance — don't overwrite
    if (isVaultMode) {
      print('[BALANCE] Skipping — vault mode active');
      return;
    }

    // Handle CLOAK differently - uses JSON balances from ZEOS
    if (CloakWalletManager.isCloak(coin)) {
      final newBalances = _getCloakPoolBalances();
      print('[BALANCE] CLOAK getBalancesJson returned: S=${newBalances.sapling}');
      poolBalances = newBalances;
      print('[BALANCE] CLOAK poolBalances updated');
      return;
    }
    
    final newBalances = WarpApi.getPoolBalances(coin, id, 0, true).unpack();
    print('[BALANCE] getPoolBalances returned: T=${newBalances.transparent}, S=${newBalances.sapling}, O=${newBalances.orchard}');
    poolBalances = newBalances;
    print('[BALANCE] poolBalances updated');
  }
  
  // Parse CLOAK/ZEOS balances into PoolBalanceT format
  // ZEOS is all shielded, so we put everything in the "sapling" pool
  //
  // Balance JSON format is array of ExtendedAsset strings:
  // ["1.0000 CLOAK@thezeostoken", "5.0000 TLOS@eosio.token", ...]
  PoolBalanceT _getCloakPoolBalances() {
    final balance = PoolBalanceT();

    if (!CloakWalletManager.isLoaded) {
      print('[BALANCE] CLOAK wallet not loaded');
      return balance;
    }

    final json = CloakWalletManager.getBalancesJson();
    if (json == null || json.isEmpty) {
      print('[BALANCE] CLOAK balances JSON is null/empty');
      return balance;
    }

    try {
      // JSON is array of ExtendedAsset strings: ["1.0000 CLOAK@thezeostoken", ...]
      final List<dynamic> balances = jsonDecode(json);
      int cloakSmallestUnits = 0;

      for (final b in balances) {
        if (b is String) {
          // Parse ExtendedAsset string: "1.0000 CLOAK@thezeostoken"
          // Split on @ to get "1.0000 CLOAK" and "thezeostoken"
          final parts = b.split('@');
          if (parts.length == 2) {
            final assetPart = parts[0].trim(); // "1.0000 CLOAK"
            final contract = parts[1].trim();   // "thezeostoken"

            // Check if this is CLOAK
            if (assetPart.endsWith('CLOAK') && contract == 'thezeostoken') {
              // Parse amount: "1.0000 CLOAK" -> 1.0000
              final amountStr = assetPart.replaceAll('CLOAK', '').trim();
              final amount = double.tryParse(amountStr) ?? 0.0;
              // CLOAK has 4 decimal precision, so multiply by 10000
              cloakSmallestUnits = (amount * 10000).round();
              print('[BALANCE] Parsed CLOAK balance: $amount -> $cloakSmallestUnits smallest units');
              break;
            }
          }
        }
      }

      // CLOAK is all shielded - put in sapling pool
      balance.sapling = cloakSmallestUnits;
      balance.transparent = 0;
      balance.orchard = 0;

    } catch (e) {
      print('[BALANCE] Error parsing CLOAK balances: $e');
    }

    return balance;
  }

  @action
  void updateDivisified() {
    if (id == 0) return;
    try {
      // CLOAK uses stable default address — only Receive page should derive new ones
      if (CloakWalletManager.isCloak(coin)) {
        diversifiedAddress = CloakWalletManager.getDefaultAddress() ?? '';
        return;
      }
      diversifiedAddress = WarpApi.getDiversifiedAddress(coin, id,
          coinSettings.uaType, DateTime.now().millisecondsSinceEpoch ~/ 1000);
    } catch (e) {}
  }

  @action
  void update(int? newHeight) {
    if (id == 0) return;
    updateDivisified();
    updatePoolBalances();

    notes.read(newHeight);
    txs.read(newHeight);
    messages.read(newHeight);

    currency = appSettings.currency;

    // CLOAK doesn't use WarpApi for spendings/trades
    if (CloakWalletManager.isCloak(coin)) {
      spendings = [];
      accountBalances = [];
      return;
    }

    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    final start =
        today.add(Duration(days: -365)).millisecondsSinceEpoch ~/ 1000;
    final end = today.millisecondsSinceEpoch ~/ 1000;
    spendings = WarpApi.getSpendings(coin, id, start);

    final trades = WarpApi.getPnLTxs(coin, id, start);
    List<AccountBalance> abs = [];
    var b = poolBalances.orchard + poolBalances.sapling;
    abs.add(AccountBalance(DateTime.now(), b / ZECUNIT));
    for (var trade in trades) {
      final timestamp =
          DateTime.fromMillisecondsSinceEpoch(trade.timestamp * 1000);
      final value = trade.value;
      final ab = AccountBalance(timestamp, b / ZECUNIT);
      abs.add(ab);
      b -= value;
    }
    abs.add(AccountBalance(
        DateTime.fromMillisecondsSinceEpoch(start * 1000), b / ZECUNIT));
    accountBalances = sampleDaily<AccountBalance, double, double>(
        abs.reversed,
        start,
        end,
        (AccountBalance ab) => ab.time.millisecondsSinceEpoch ~/ DAY_MS,
        (AccountBalance ab) => ab.balance,
        (acc, v) => v,
        0.0);

    if (newHeight != null) height = newHeight;
  }
}

class Notes extends _Notes with _$Notes {
  Notes(super.coin, super.id);
}

abstract class _Notes with Store {
  final int coin;
  final int id;
  _Notes(this.coin, this.id);

  @observable
  List<Note> items = [];
  SortConfig2? order;

  @action
  void read(int? height) {
    // CLOAK doesn't use WarpApi for notes
    if (CloakWalletManager.isCloak(coin)) {
      // TODO: Parse notes from CloakApi.getUnspentNotesJson() if needed
      items = [];
      return;
    }
    final shieledNotes = WarpApi.getNotesSync(coin, id);
    items = shieledNotes.map((n) {
      final timestamp = DateTime.fromMillisecondsSinceEpoch(n.timestamp * 1000);
      return Note.from(height, n.id, n.height, timestamp, n.value / ZECUNIT,
          n.orchard, n.excluded, false);
    }).toList();
  }

  @action
  void clear() {
    items.clear();
  }

  @action
  void invert() {
    if (CloakWalletManager.isCloak(coin)) return; // CLOAK doesn't support this
    WarpApi.invertExcluded(coin, id);
    items = items.map((n) => n.invertExcluded).toList();
  }

  @action
  void exclude(Note note) {
    if (CloakWalletManager.isCloak(coin)) return; // CLOAK doesn't support this
    WarpApi.updateExcluded(coin, note.id, note.excluded);
    items = List.of(items);
  }

  @action
  void setSortOrder(String field) {
    final r = _sort(field, order, items);
    order = r.item1;
    items = r.item2;
  }
}

class Txs extends _Txs with _$Txs {
  Txs(super.coin, super.id);
}

abstract class _Txs with Store {
  final int coin;
  final int id;
  _Txs(this.coin, this.id);

  @observable
  List<Tx> items = [];
  @observable
  int version = 0;
  SortConfig2? order;
  final Map<int, int> _idToIndex = {};

  void _rebuildIndex() {
    _idToIndex.clear();
    for (int i = 0; i < items.length; i++) {
      _idToIndex[items[i].id] = i;
    }
  }

  int indexOfTxId(int txId) => _idToIndex[txId] ?? -1;

  @action
  void read(int? height) {
    // CLOAK doesn't use WarpApi for transactions
    if (CloakWalletManager.isCloak(coin)) {
      final historyJson = CloakWalletManager.getTransactionHistoryJson();
      print('[TXS_DEBUG] txs.read() called, historyJson length=${historyJson?.length ?? 0}');
      if (historyJson == null || historyJson.isEmpty) {
        items = [];
        _rebuildIndex();
        return;
      }
      final history = jsonDecode(historyJson) as List;
      print('[TXS_DEBUG] Parsed ${history.length} transactions from Rust');
      items = [];
      int idx = 0;
      for (final tx in history) {
        final txType = tx['tx_type'] as String? ?? 'Received';
        // Use millisecond-precision timestamp from Rust for correct ordering
        final tsMs = tx['timestamp_ms'] as int? ?? 0;
        DateTime timestamp;
        if (tsMs > 0) {
          timestamp = DateTime.fromMillisecondsSinceEpoch(tsMs);
        } else {
          final dateStr = tx['date_time'] as String? ?? '';
          timestamp = DateTime.tryParse(dateStr) ?? DateTime.now();
          if (timestamp.year < 2000) timestamp = DateTime.now();
        }
        final entries = tx['account_asset_memo'] as List? ?? [];

        for (final entry in entries) {
          final account = entry[0] as String? ?? '';
          final assetStr = entry[1] as String? ?? '';
          final memo = entry[2] as String? ?? '';

          // Skip auth token entries — these are vault "smart keys" (0 value notes)
          // shown as hex commitment hashes, not real transactions
          if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(assetStr)) continue;

          final parsed = _parseCloakAsset(assetStr);
          // Skip zero-amount entries — internal protocol artifacts
          if (parsed.amount == 0) continue;
          // Fee entries from Rust have pre-negated amounts (e.g. "-0.5000 CLOAK").
          // Detect by checking if the asset string starts with "-" to avoid double-negation.
          final alreadyNegative = assetStr.trimLeft().startsWith('-');
          final value = alreadyNegative
              ? parsed.amount
              : (txType == 'Sent' ? -parsed.amount : parsed.amount);

          final displayAccount = account;

          items.add(Tx(
            idx++,
            0,
            null,
            timestamp,
            '',
            '',
            value,
            displayAccount,
            null,
            memo,
            [],
            symbol: parsed.ticker,
          ));
        }
      }

      // Backup labeling: use Dart-recorded burn events to relabel
      // "Publish Vault" → "Burn Vault" for entries where Rust labeling missed.
      // This is essential after resync: the table-based sync doesn't process
      // authenticate/burn actions, so Rust labels everything "Publish Vault".
      // The burn_events table persists across resyncs with wall-clock timestamps
      // from when the user pressed the burn button.
      // Tolerance: 5s covers TX round-trip (~1-3s on Telos) without
      // false-positiving on rapid create+burn sequences.
      final burnTs = CloakDb.burnTimestampsSync;
      if (burnTs.isNotEmpty) {
        print('[TX_RELABEL] burnTimestampsSync has ${burnTs.length} entries: $burnTs');
        for (final tx in items) {
          if (tx.address == 'Publish Vault') {
            final txMs = tx.timestamp.millisecondsSinceEpoch;
            final isBurn = burnTs.any((burnMs) => (txMs - burnMs).abs() < 5000);
            if (isBurn) {
              tx.address = 'Burn Vault';
              print('[TX_RELABEL] Relabeled fee at $txMs → Burn Vault');
            } else {
              print('[TX_RELABEL] No match for fee at $txMs (closest: ${burnTs.map((b) => (txMs - b).abs()).reduce((a, b) => a < b ? a : b)}ms)');
            }
          }
        }
      }

      _rebuildIndex();
      version++;
      return;
    }
    final shieldedTxs = WarpApi.getTxsSync(coin, id);
    items = shieldedTxs.map((tx) {
      final timestamp =
          DateTime.fromMillisecondsSinceEpoch(tx.timestamp * 1000);
      return Tx.from(
          height,
          tx.id,
          tx.height,
          timestamp,
          tx.shortTxId!,
          tx.txId!,
          tx.value / ZECUNIT,
          tx.address,
          tx.name,
          tx.memo,
          tx.messages?.memos ?? []);
    }).toList();
    _rebuildIndex();
  }

  @action
  void clear() {
    items.clear();
  }

  @action
  void setSortOrder(String field) {
    final r = _sort(field, order, items);
    order = r.item1;
    items = r.item2;
    _rebuildIndex();
  }
}

class Messages extends _Messages with _$Messages {
  Messages(super.coin, super.id);
}

abstract class _Messages with Store {
  final int coin;
  final int id;
  _Messages(this.coin, this.id);

  @observable
  List<ZMessage> items = [];
  SortConfig2? order;

  @action
  void read(int? height) {
    // CLOAK uses CloakDb for messages
    if (CloakWalletManager.isCloak(coin)) {
      _readCloakMessages();
      return;
    }
    final ms = WarpApi.getMessagesSync(coin, id);
    items = ms
        .map((m) => ZMessage(
            m.idMsg,
            m.idTx,
            m.incoming,
            m.sender,
            m.from,
            m.to!,
            m.subject!,
            m.body!,
            DateTime.fromMillisecondsSinceEpoch(m.timestamp * 1000),
            m.height,
            m.read))
        .toList();
  }

  /// Fetch CLOAK messages from CloakDb
  Future<void> _readCloakMessages() async {
    try {
      final rows = await CloakDb.getMessages(id);
      items = rows.map((row) => ZMessage(
        row['id'] as int,
        (row['id_tx'] as int?) ?? 0,
        (row['incoming'] as int) == 1,
        row['sender'] as String?,
        row['sender'] as String?, // from = sender for display
        row['recipient'] as String,
        row['subject'] as String,
        row['body'] as String,
        DateTime.fromMillisecondsSinceEpoch((row['timestamp'] as int) * 1000),
        row['height'] as int,
        (row['read'] as int) == 1,
      )).toList();
    } catch (e) {
      print('Messages: Error reading CLOAK messages: $e');
      items = [];
    }
  }

  @action
  void clear() {
    items.clear();
  }

  @action
  void setSortOrder(String field) {
    final r = _sort(field, order, items);
    order = r.item1;
    items = r.item2;
  }
}

Tuple2<SortConfig2?, List<T>> _sort<T extends HasHeight>(
    String field, SortConfig2? order, List<T> items) {
  if (order == null)
    order = SortConfig2(field, 1);
  else
    order = order.next(field);

  final o = order;
  if (o == null)
    items.sort((a, b) => b.height.compareTo(a.height));
  else {
    items.sort((a, b) {
      final ra = reflector.reflect(a);
      final va = ra.invokeGetter(field)! as dynamic;
      final rb = reflector.reflect(b);
      final vb = rb.invokeGetter(field)! as dynamic;
      return va.compareTo(vb) * o.orderBy;
    });
  }
  return Tuple2(o, items);
}

class SortConfig2 {
  String field;
  int orderBy; // 1: asc, -1: desc
  SortConfig2(this.field, this.orderBy);

  SortConfig2? next(String newField) {
    if (newField == field) {
      if (orderBy > 0) return SortConfig2(field, -orderBy);
      return null;
    }
    return SortConfig2(newField, 1);
  }

  String indicator(String field) {
    if (this.field != field) return '';
    if (orderBy > 0) return ' \u2191';
    return ' \u2193';
  }
}

List<PnL> getPNL(
    int start, int end, Iterable<TxTimeValue> tvs, Iterable<Quote> quotes) {
  final trades = tvs.map((tv) {
    final dt = DateTime.fromMillisecondsSinceEpoch(tv.timestamp * 1000);
    final qty = tv.value / ZECUNIT;
    return Trade(dt, qty);
  });

  final portfolioTimeSeries = sampleDaily<Trade, Trade, double>(
      trades,
      start,
      end,
      (t) => t.dt.millisecondsSinceEpoch ~/ DAY_MS,
      (t) => t,
      (acc, t) => acc + t.qty,
      0.0);

  var prevBalance = 0.0;
  var cash = 0.0;
  var realized = 0.0;
  final len = min(quotes.length, portfolioTimeSeries.length);

  final z = ZipStream.zip2<Quote, TimeSeriesPoint<double>,
      Tuple2<Quote, TimeSeriesPoint<double>>>(
    Stream.fromIterable(quotes),
    Stream.fromIterable(portfolioTimeSeries),
    (a, b) => Tuple2(a, b),
  ).take(len);

  List<PnL> pnls = [];
  z.listen((qv) {
    final dt = qv.item1.dt;
    final price = qv.item1.price;
    final balance = qv.item2.value;
    final qty = balance - prevBalance;

    final closeQty =
        qty * balance < 0 ? min(qty.abs(), prevBalance.abs()) * qty.sign : 0.0;
    final openQty = qty - closeQty;
    final avgPrice = prevBalance != 0 ? cash / prevBalance : 0.0;

    cash += openQty * price + closeQty * avgPrice;
    realized += closeQty * (avgPrice - price);
    final unrealized = price * balance - cash;

    final pnl = PnL(dt, price, balance, realized, unrealized);
    pnls.add(pnl);

    prevBalance = balance;
  });
  return pnls;
}

class _CloakAsset {
  final double amount;
  final String ticker;
  _CloakAsset(this.amount, this.ticker);
}

/// Parse CLOAK asset strings like "25.0000 CLOAK@thezeostoken" or
/// "25.0000 CLOAK@thezeostoken (@za1...)"
_CloakAsset _parseCloakAsset(String assetStr) {
  // Remove trailing shielded address suffix like " (@za1...)"
  var s = assetStr.replaceAll(RegExp(r'\s+\(@za1[^\)]*\)$'), '');

  // Expected format: "25.0000 CLOAK@thezeostoken"
  final parts = s.split(' ');
  if (parts.length < 2) return _CloakAsset(0, 'CLOAK');

  final amount = double.tryParse(parts[0]) ?? 0;
  // Ticker part: "CLOAK@thezeostoken" -> extract "CLOAK"
  final tokenPart = parts[1];
  final atIdx = tokenPart.indexOf('@');
  final ticker = atIdx >= 0 ? tokenPart.substring(0, atIdx) : tokenPart;

  return _CloakAsset(amount, ticker);
}
