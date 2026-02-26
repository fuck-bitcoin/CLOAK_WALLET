// CLOAK Sync Manager
// Syncs CLOAK wallet by fetching EOSIO blocks and processing them

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'package:flutter/foundation.dart';
import 'package:cloak_api/cloak_api.dart';

import 'cloak_wallet_manager.dart';
import 'cloak_db.dart';
import 'eosio_client.dart';
import 'ffi_isolate.dart';
import '../coin/coins.dart';

// ============== Top-level functions for Isolate.run() ==============
// These must be top-level (not static methods) to be passed to compute/Isolate.run.

/// Convert Zeos256 to 32-byte hex string.
/// Zeos256 contains 4 uint64 words (w0-w3) in little-endian order.
String _zeos256ToHexIsolate(List<String> words) {
  final bytes = <int>[];
  for (final word in words) {
    final n = BigInt.parse(word);
    for (int i = 0; i < 8; i++) {
      bytes.add(((n >> (i * 8)) & BigInt.from(0xFF)).toInt());
    }
  }
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Parameters for merkle-to-hex conversion in a background isolate.
class _MerkleHexParams {
  final List<Map<String, dynamic>> entriesJson;
  final int treeDepth;
  final int skip;
  _MerkleHexParams(this.entriesJson, this.treeDepth, this.skip);
}

/// Runs entirely in a background isolate: filters leaves, sorts, converts to hex.
String _convertMerkleEntriesToHexInIsolate(_MerkleHexParams params) {
  final leafOffset = (1 << params.treeDepth) - 1;

  // Reconstruct lightweight leaf data from serializable maps
  final leaves = <Map<String, dynamic>>[];
  for (final e in params.entriesJson) {
    if ((e['idx'] as int) >= leafOffset) leaves.add(e);
  }
  leaves.sort((a, b) => (a['idx'] as int).compareTo(b['idx'] as int));

  final newLeaves = params.skip > 0 ? leaves.skip(params.skip).toList() : leaves;

  final buffer = StringBuffer();
  for (final entry in newLeaves) {
    final val = entry['val'] as Map<String, dynamic>;
    buffer.write(_zeos256ToHexIsolate([
      val['w0'] as String,
      val['w1'] as String,
      val['w2'] as String,
      val['w3'] as String,
    ]));
  }
  return buffer.toString();
}

/// Parameters for nullifier hex conversion.
class _NullifierHexParams {
  final List<Map<String, dynamic>> nullifiersJson;
  _NullifierHexParams(this.nullifiersJson);
}

/// Runs entirely in a background isolate: converts nullifiers to hex string.
String _convertNullifiersToHexInIsolate(_NullifierHexParams params) {
  final buffer = StringBuffer();
  for (final nf in params.nullifiersJson) {
    final val = nf['val'] as Map<String, dynamic>;
    buffer.write(_zeos256ToHexIsolate([
      val['w0'] as String,
      val['w1'] as String,
      val['w2'] as String,
      val['w3'] as String,
    ]));
  }
  return buffer.toString();
}

class CloakSync {
  static EosioClient? _client;
  static bool _syncing = false;
  static int _syncedHeight = 0;
  static int _latestHeight = 0;

  /// Lock to prevent sync from running during wallet operations (e.g., ZKP generation).
  /// Prevents data races between sync FFI calls and transactPacked FFI calls on the
  /// same Wallet pointer from different isolates.
  static bool _walletLocked = false;
  static void lockWallet() { _walletLocked = true; print('[CloakSync] Wallet LOCKED for transaction'); }
  static void unlockWallet() { _walletLocked = false; print('[CloakSync] Wallet UNLOCKED'); }

  /// Notifier for the initial sync after app startup.
  /// Value is true while the first syncFromTables() call is running,
  /// false once it completes (or on error). Subsequent periodic syncs
  /// do NOT set this to true again.
  static final ValueNotifier<bool> initialSyncNotifier = ValueNotifier<bool>(false);
  static bool _initialSyncDone = false;

  // ZEOS protocol deployment block on Telos mainnet
  // This is the earliest block where ZEOS transactions can exist
  // TODO: Get actual deployment block from ZEOS team
  static const int ZEOS_GENESIS_BLOCK = 170000000; // ~Jan 2024 estimate

  // Progress callback for UI updates (step-based: current/total where total=100)
  static void Function(int current, int total)? onProgress;

  // Step description callback for banner text (e.g., "Fetching merkle tree...")
  static void Function(String step)? onStepChanged;

  // Track if this is a fresh account (no sync needed) vs restore (full sync)
  static bool _isNewAccount = false;
  // Prevent auto-heal from firing more than once per app session
  static bool _autoHealAttempted = false;
  static bool _vaultsReimported = false;
  static bool _vaultDiscoveryDone = false;

  // Cached global state for "nothing changed" fast path
  static int _lastLeafCount = -1;
  static int _lastAuthCount = -1;

  // Consecutive sync failures — skip every other tick to avoid hammering a dead API
  static int _consecutiveFailures = 0;

  /// Check if this is a new account that was just created (not restored)
  static bool get isNewAccount => _isNewAccount;

  /// Mark account as new (created fresh, starts at latest block)
  static void markAsNewAccount() {
    _isNewAccount = true;
  }

  /// Mark account as restored (from seed, needs full sync from genesis)
  static void markAsRestored() {
    _isNewAccount = false;
  }

  /// Clear cached counters to force full sync on next cycle.
  /// Called during chain state reset to ensure fresh data fetch.
  static void clearCachedCounters() {
    _lastLeafCount = -1;
    _lastAuthCount = -1;
    _autoHealAttempted = false;
    _vaultsReimported = false;
    _vaultDiscoveryDone = false;
    _consecutiveFailures = 0;
  }

  /// Full reset of all static sync state. Called when the last account is
  /// deleted so a subsequent create/restore starts completely fresh.
  static void resetAll() {
    _lastLeafCount = -1;
    _lastAuthCount = -1;
    _autoHealAttempted = false;
    _vaultsReimported = false;
    _vaultDiscoveryDone = false;
    _isNewAccount = false;
    _initialSyncDone = false;
    _syncing = false;
    _syncedHeight = 0;
    _latestHeight = 0;
    _cachedGlobal = null;
    _cachedMerkleEntries = null;
    _cachedNullifiers = null;
    initialSyncNotifier.value = false;
    print('[CloakSync] Full reset of all sync state');
  }

  /// Initialize the EOSIO client with the configured endpoint
  static Future<void> init() async {
    if (_client != null) return;

    // Get endpoint from coin settings
    final endpoint = cloak.lwd.isNotEmpty ? cloak.lwd.first.url : 'https://telos.eosusa.io';
    _client = EosioClient(endpoint);

    // Load persisted synced height from database
    await _loadSyncedHeight();
  }

  /// Get current sync status
  static bool get isSyncing => _syncing;
  static int get syncedHeight => _syncedHeight;
  static int get latestHeight => _latestHeight;

  /// Load synced height from database
  static Future<void> _loadSyncedHeight() async {
    final stored = await CloakDb.getProperty('synced_height');
    if (stored != null) {
      _syncedHeight = int.tryParse(stored) ?? 0;
    }
  }

  /// Persist synced height to database
  static Future<void> _saveSyncedHeight(int height) async {
    await CloakDb.setProperty('synced_height', height.toString());
  }

  /// Update the latest block height from the chain
  static Future<void> updateLatestHeight() async {
    if (_client == null) await init();

    try {
      final info = await _client!.getInfo();
      _latestHeight = info.lastIrreversibleBlockNum;
    } catch (e) {
    }
  }

  /// Get the current block number from the wallet (Rust side)
  static int getWalletBlockNum() {
    final wallet = CloakWalletManager.wallet;
    if (wallet == null) return 0;
    return CloakApi.getBlockNum(wallet) ?? 0;
  }

  /// Get the persisted synced height (database side)
  static Future<int> getPersistedHeight() async {
    final stored = await CloakDb.getProperty('synced_height');
    return stored != null ? (int.tryParse(stored) ?? 0) : 0;
  }

  /// Check if this is a first-time sync (needs full restore banner)
  static Future<bool> needsFullSync() async {
    if (_isNewAccount) return false; // New accounts start synced
    // Once a full sync has completed, never show the banner again
    if (await CloakDb.getProperty('full_sync_done') == 'true') return false;
    final height = await getPersistedHeight();
    return height < ZEOS_GENESIS_BLOCK;
  }

  /// Set initial sync height for new accounts (skip to latest)
  static Future<void> setInitialHeightForNewAccount() async {
    await init();
    await updateLatestHeight();
    _syncedHeight = _latestHeight;
    await _saveSyncedHeight(_latestHeight);
    _isNewAccount = true;
  }
  
  /// Main sync function - fetches blocks and processes them
  /// NOTE: Full block sync is currently disabled due to Rust panic issues.
  /// For now, we just update the chain status without processing blocks.
  /// TODO: Implement proper ZEOS block filtering (only process blocks with ZEOS txs)
  ///
  /// Returns true if this is a "full sync" (restore scenario), false for normal sync
  static Future<bool> sync({bool force = false}) async {
    if (_walletLocked) return false;
    if (_syncing && !force) return false;
    if (!CloakWalletManager.isLoaded) return false;

    // Back off on consecutive failures: skip N ticks (capped at 10 = ~30s)
    if (_consecutiveFailures > 0) {
      _consecutiveFailures--;
      return false;
    }

    _syncing = true;
    bool isFullSync = false;

    try {
      if (_client == null) await init();

      // Get persisted synced height from database (survives app restarts)
      final persistedHeight = await getPersistedHeight();
      _syncedHeight = persistedHeight;

      // Auto-heal: detect wallets stuck with high synced_height but never
      // actually synced. This happens when restoreWallet() called createWallet()
      // which set synced_height to latest block (~450M), but table sync never ran.
      // Only attempt once per app session to avoid repeated banner/sync loops.
      if (!_autoHealAttempted &&
          _syncedHeight >= ZEOS_GENESIS_BLOCK &&
          !_isNewAccount &&
          await CloakDb.getProperty('full_sync_done') != 'true') {
        _autoHealAttempted = true;
        print('CloakSync: Auto-heal — synced_height=$_syncedHeight but full_sync_done not set, resetting to 0');
        _syncedHeight = 0;
        await _saveSyncedHeight(0);
        _isNewAccount = false;
      }

      // Determine if this is a full sync (restore) or normal sync
      // Full sync = synced height is 0 or below genesis AND not a new account
      isFullSync = (_syncedHeight < ZEOS_GENESIS_BLOCK) && !_isNewAccount;

      // Only show the sync banner for full syncs (seed import/restore),
      // NOT on every normal cold start.
      if (isFullSync && !_initialSyncDone) {
        initialSyncNotifier.value = true;
      }

      if (isFullSync) {
        _syncedHeight = ZEOS_GENESIS_BLOCK;
      } else if (_isNewAccount) {
        await updateLatestHeight();
        if (_syncedHeight < _latestHeight) {
          // Just update the height, don't fetch tables (no transactions possible yet)
          _syncedHeight = _latestHeight;
          await _saveSyncedHeight(_latestHeight);
        }
        _syncing = false;
        _initialSyncDone = true;
        return false;
      }

      // Get latest block from chain
      await updateLatestHeight();

      if (_syncedHeight >= _latestHeight) {
        _syncing = false;
        return false;
      }

      // Perform table-based sync
      final result = await syncFromTables();

      if (result.success) {
        _consecutiveFailures = 0;
        final global = result.global!;
        _syncedHeight = global.blockNum;
        _latestHeight = global.blockNum;
        await _saveSyncedHeight(global.blockNum);
        // Don't call onProgress(100, 100) here — it makes isSynced=true which
        // hides the banner before syncJustCompleted is set. The completion flow
        // in store2.dart handles the 100% transition via syncJustCompleted.

        // Mark full sync as done so auto-heal and banner don't re-trigger
        if (isFullSync) {
          await CloakDb.setProperty('full_sync_done', 'true');
        }

        // Preload ZK params in background so first send is instant
        // This runs after sync completes, user won't notice the load time
        CloakWalletManager.ensureZkParamsLoaded();

        return isFullSync;
      } else {
        print('CloakSync: Table sync failed: ${result.error}');
        // Don't mark as synced — let the timer retry after a backoff
        _consecutiveFailures = (_consecutiveFailures + 2).clamp(0, 10);
        return false;
      }

    } catch (e) {
      print('CloakSync: Sync failed: $e');
      _consecutiveFailures = (_consecutiveFailures + 2).clamp(0, 10);
      return false;
    } finally {
      _syncing = false;
      _initialSyncDone = true;
    }
  }

  /// Light sync - just check for new blocks without full processing
  static Future<bool> hasNewBlocks() async {
    if (_client == null) await init();

    try {
      await updateLatestHeight();
      final walletBlock = getWalletBlockNum();
      return _latestHeight > walletBlock;
    } catch (e) {
      return false;
    }
  }

  // ============== TABLE-BASED SYNC (Much faster!) ==============

  /// Sync using ZEOS contract table queries instead of block-by-block
  /// This is MUCH faster because:
  /// - Only ~60 merkle tree entries vs 280M+ blocks
  /// - Direct table access vs processing every block
  /// - Returns exactly the data we need
  static Future<ZeosSyncResult> syncFromTables() async {
    if (_client == null) await init();

    try {
      // 1. Get global state (leaf count, block number, etc.)
      // This is 1 cheap HTTP call — used for "nothing changed" fast path
      final global = await _client!.getZeosGlobal();
      if (global == null) {
        print('CloakSync: Failed to get ZEOS global state');
        return ZeosSyncResult(success: false, error: 'Failed to get global state');
      }
      // Seed the fast-path cache from the wallet on first sync after launch.
      // Without this, _lastLeafCount starts at -1 and the first sync always
      // does a full table fetch even when nothing changed on-chain.
      if (_lastLeafCount < 0) {
        final wallet = CloakWalletManager.wallet;
        if (wallet != null) {
          final walletLeaves = CloakApi.getLeafCount(wallet) ?? 0;
          final walletAuth = CloakApi.getAuthCount(wallet) ?? 0;
          if (walletLeaves > 0) {
            _lastLeafCount = walletLeaves;
            _lastAuthCount = walletAuth;
          }
        }
      }

      // FAST PATH: If leafCount and authCount haven't changed, no new data exists.
      // Skip ALL expensive HTTP calls, FFI processing, and disk I/O.
      // This reduces 99% of sync cycles to 1 lightweight HTTP call.
      if (_lastLeafCount == global.leafCount && _lastAuthCount == global.authCount && _lastLeafCount >= 0) {
        // Update block height but skip everything else
        _syncedHeight = global.blockNum;
        _latestHeight = global.blockNum;
        _cachedGlobal = global;
        return ZeosSyncResult(success: true, global: global, merkleEntries: _cachedMerkleEntries, nullifiers: _cachedNullifiers);
      }

      // 2. Get all merkle tree entries (note commitments)
      onStepChanged?.call('Fetching merkle tree...');
      onProgress?.call(10, 100);
      final merkleEntries = await _client!.getZeosMerkleTree();

      // 3. Get all nullifiers (spent notes)
      onStepChanged?.call('Fetching nullifiers...');
      onProgress?.call(25, 100);
      final nullifiers = await _client!.getZeosNullifiers();

      // 4. Get action history to extract encrypted notes
      onStepChanged?.call('Fetching transaction history...');
      onProgress?.call(40, 100);
      final actions = await _client!.getZeosActions();

      // 5. Pass data to Rust wallet for trial decryption
      var wallet = CloakWalletManager.wallet;
      if (wallet != null) {
        // 5a-pre. Sync auth_count from on-chain global to wallet
        // This is CRITICAL: the ZK proof computes auth_hash = Blake2s(auth_count || packed_actions)
        // If wallet auth_count doesn't match on-chain, authenticate proofs will be invalid
        final walletAuthCount = CloakApi.getAuthCount(wallet) ?? 0;
        final chainAuthCount = global.authCount;
        if (walletAuthCount != chainAuthCount) {
          print('CloakSync: auth_count mismatch! wallet=$walletAuthCount chain=$chainAuthCount — updating wallet');
          CloakApi.setAuthCount(wallet, chainAuthCount);
        }

        // 5a. Add only NEW merkle tree leaves (skip ones wallet already has)
        final walletLeafCount = CloakApi.getLeafCount(wallet) ?? 0;
        final onChainLeafCount = global.leafCount;

        // Pre-serialize merkle entries to maps (once) for background isolate use
        final merkleEntriesMaps = merkleEntries.map((e) => {
          'idx': e.idx,
          'val': e.val.toJson(),
        }).toList();

        onStepChanged?.call('Processing merkle leaves...');
        onProgress?.call(55, 100);
        if (walletLeafCount < onChainLeafCount) {
          final leavesHex = await compute(
            _convertMerkleEntriesToHexInIsolate,
            _MerkleHexParams(merkleEntriesMaps, global.treeDepth, walletLeafCount),
          );
          if (leavesHex.isNotEmpty) {
            await FfiIsolate.addLeaves(wallet: wallet!, leavesHex: leavesHex);
          }
        } else if (walletLeafCount > onChainLeafCount) {
          // Wallet has more leaves than the chain — this is NORMAL after a send.
          // The eager wallet update in wallet_transact_packed inserts output
          // commitment leaves immediately so add_notes() can track change notes.
          // These extra leaves will match the chain once the TX confirms.
          // Only auto-repair if the overshoot is large (>20 leaves = real corruption).
          final overshoot = walletLeafCount - onChainLeafCount;
          if (overshoot > 20) {
            // Skip auto-repair for IVK (view-only) wallets — they can't send
            // transactions so the "eager wallet update" overshoot can't happen.
            // Also, recreating from seed without isIvk flag would corrupt the wallet.
            final _repairViewOnly = CloakApi.isViewOnly(wallet!) ?? false;
            if (_repairViewOnly) {
              print('CloakSync: WARNING — IVK wallet has $overshoot extra leaves, skipping auto-repair (view-only)');
            } else {
              print('CloakSync: Auto-repairing — wallet has $overshoot extra leaves, recreating from seed');
              final account = await CloakDb.getFirstAccount();
              if (account != null && account['seed'] != null) {
                final seed = account['seed'] as String;
                final name = account['name'] as String;
                await CloakWalletManager.createWallet(name, seed);
                await CloakWalletManager.loadWallet();
                wallet = CloakWalletManager.wallet;
                if (wallet != null) {
                  final leavesHex = await compute(
                    _convertMerkleEntriesToHexInIsolate,
                    _MerkleHexParams(merkleEntriesMaps, global.treeDepth, 0),
                  );
                  if (leavesHex.isNotEmpty) {
                    await FfiIsolate.addLeaves(wallet: wallet!, leavesHex: leavesHex);
                  }
                }
              }
            }
          }
        }

        // 5b. Extract and add encrypted notes from actions (per-action with timestamps)
        // MUST happen BEFORE nullifier sync so spent notes exist to be marked
        // All addNotes FFI calls run in a background isolate — no main-thread blocking.
        int totalNotes = 0;
        int totalFts = 0;
        int totalNfts = 0;
        int totalAts = 0;

        // Build the batch of note actions
        final noteActions = <Map<String, dynamic>>[];
        for (final action in actions) {
          if (action.noteCiphertexts.isEmpty) continue;
          totalNotes += action.noteCiphertexts.length;
          int blockTsMs = 0;
          if (action.blockTime.isNotEmpty) {
            // EOSIO/Telos block times are always UTC. Hyperion may omit the
            // 'Z' suffix, causing DateTime.tryParse to treat it as local time
            // and shift the timestamp by the user's timezone offset.
            String ts = action.blockTime;
            if (!ts.endsWith('Z') && !ts.contains('+') && !RegExp(r'T.+[-]').hasMatch(ts)) {
              ts += 'Z';
            }
            final dt = DateTime.tryParse(ts);
            if (dt != null) blockTsMs = dt.millisecondsSinceEpoch;
          }
          noteActions.add({
            'notesJson': jsonEncode(action.noteCiphertexts),
            'blockNum': action.blockNum,
            'blockTsMs': blockTsMs,
          });
        }

        // Run ALL addNotes calls in a background isolate (no main thread blocking)
        onStepChanged?.call('Decrypting notes...');
        onProgress?.call(70, 100);
        if (noteActions.isNotEmpty) {
          final counts = await FfiIsolate.addNotesAll(
            wallet: wallet!,
            noteActions: noteActions,
          );
          totalFts = counts['fts'] ?? 0;
          totalNfts = counts['nfts'] ?? 0;
          totalAts = counts['ats'] ?? 0;
        }
        // 5c. Sync nullifiers — mark spent notes
        // MUST happen AFTER notes are added so there are notes to mark as spent
        // On a fresh wallet, if this runs before add_notes, it finds 0 notes → all notes stay unspent
        onStepChanged?.call('Syncing nullifiers...');
        onProgress?.call(85, 100);
        int spentCount = 0;
        if (nullifiers.isNotEmpty) {
          final nullifierMaps = nullifiers.map((nf) => {'val': nf.val.toJson()}).toList();
          final nullifierHex = await compute(
            _convertNullifiersToHexInIsolate,
            _NullifierHexParams(nullifierMaps),
          );
          spentCount = await FfiIsolate.addNullifiers(wallet: wallet!, nullifiersHex: nullifierHex);
        }

        // 5d. Save wallet state (only if data changed — new leaves, notes, or nullifiers marked spent)
        onStepChanged?.call('Saving wallet...');
        onProgress?.call(95, 100);
        final dataChanged = (totalFts + totalNfts + totalAts) > 0 ||
            walletLeafCount < onChainLeafCount ||
            walletAuthCount != chainAuthCount ||
            spentCount > 0;
        if (dataChanged) {
          await CloakWalletManager.saveWallet();
        }

        // 5e. Re-import vault auth tokens from DB into Rust wallet (once per session)
        // Skip for IVK (view-only) wallets — they cannot hold auth tokens
        final _isViewOnly = CloakApi.isViewOnly(wallet!) ?? false;
        if (!_vaultsReimported && !_isViewOnly) {
          await _reimportVaultsFromDb(wallet!);
          _vaultsReimported = true;
        }

        // 5f. Vault discovery — only during restore/resync, not every 5s sync
        // Scans deterministic vault indices to find on-chain vaults from this seed.
        // Skip for IVK (view-only) wallets — they have no spending key to derive vault seeds.
        if (!_vaultDiscoveryDone && !_isNewAccount && !_isViewOnly) {
          _vaultDiscoveryDone = true;
          onStepChanged?.call('Discovering vaults...');
          try {
            await CloakWalletManager.discoverVaults();
          } catch (e) {
            print('CloakSync: Vault discovery failed (non-fatal): $e');
          }
        }

        // 6. Extract messages from transaction history (only if new notes were added)
        if ((totalFts + totalNfts + totalAts) > 0) {
          await _extractMessagesFromHistory();
        }
      }

      // 7. Update sync state and cached counters
      _syncedHeight = global.blockNum;
      _latestHeight = global.blockNum;
      await _saveSyncedHeight(global.blockNum);
      _lastLeafCount = global.leafCount;
      _lastAuthCount = global.authCount;

      // Cache the data
      _cachedGlobal = global;
      _cachedMerkleEntries = merkleEntries;
      _cachedNullifiers = nullifiers;

      return ZeosSyncResult(
        success: true,
        global: global,
        merkleEntries: merkleEntries,
        nullifiers: nullifiers,
      );
    } catch (e) {
      print('CloakSync: Table sync failed: $e');
      return ZeosSyncResult(success: false, error: e.toString());
    }
  }

  /// Re-import vault auth tokens from the SQLite vaults table into the Rust wallet.
  /// This ensures vault auth tokens survive wallet file deletion/recreation.
  /// Each vault in the DB has a seed and contract; we call createUnpublishedAuthNote()
  /// to recreate the auth token in the Rust wallet, then addUnpublishedNotes() to
  /// inject it into the wallet's unpublished notes list.
  static Future<void> _reimportVaultsFromDb(Pointer<Void> wallet) async {
    try {
      final vaults = await CloakDb.getAllVaults();
      if (vaults.isEmpty) return;
      int imported = 0;

      // Use default address (stable, deterministic) — must match the address
      // used at vault creation time for correct commitment hash.
      final address = CloakWalletManager.getDefaultAddress();
      if (address == null) return;

      for (final vault in vaults) {
        final status = vault['status'] as String? ?? '';
        if (status == 'burned') continue;
        final seed = vault['seed'] as String?;
        if (seed == null || seed.isEmpty) continue;

        // Yield to let UI breathe between synchronous FFI calls
        await Future.delayed(Duration.zero);

        // Use the actual contract from DB (e.g. 'thezeostoken') — the
        // commitment hash depends on the contract u64 value.
        final dbContract = vault['contract'] as String? ?? 'thezeostoken';
        final contractU64 = eosioNameToU64(dbContract);

        final notesJson = CloakApi.createUnpublishedAuthNote(
          wallet, seed, contractU64, address,
        );
        if (notesJson == null) continue;

        // Yield again before next FFI call
        await Future.delayed(Duration.zero);

        if (CloakApi.addUnpublishedNotes(wallet, notesJson)) {
          imported++;
        }
      }

      if (imported > 0) {
        await Future.delayed(Duration.zero); // yield before wallet serialization
        await CloakWalletManager.saveWallet();
      }
    } catch (e) {
      print('CloakSync: Error re-importing vaults from DB: $e');
    }
  }

  // Cached ZEOS data from table sync
  static ZeosGlobal? _cachedGlobal;
  static List<ZeosMerkleEntry>? _cachedMerkleEntries;
  static List<ZeosNullifier>? _cachedNullifiers;

  static ZeosGlobal? get cachedGlobal => _cachedGlobal;
  static List<ZeosMerkleEntry>? get cachedMerkleEntries => _cachedMerkleEntries;
  static List<ZeosNullifier>? get cachedNullifiers => _cachedNullifiers;

  /// Close the client
  static void close() {
    _client?.close();
    _client = null;
  }

  // ============== MESSAGE EXTRACTION ==============

  /// Extract messages from transaction history memos
  ///
  /// Message format can be:
  /// 1. v1 header format: "v1; type=TYPE; conversation_id=CID; ..." followed by message body
  /// 2. Legacy format: "🛡MSG\n<sender>\n<subject>\n<body>"
  ///
  /// The FULL memo is stored in the body field for proper header parsing by the UI
  static Future<void> _extractMessagesFromHistory() async {
    try {
      final wallet = CloakWalletManager.wallet;
      if (wallet == null) return;
      final historyJson = await FfiIsolate.getTransactionHistoryJson(
        wallet: wallet,
        pretty: true,
      );
      if (historyJson == null || historyJson.isEmpty) return;

      final history = jsonDecode(historyJson);
      if (history is! List) return;
      final accountId = CloakWalletManager.accountId;
      final myAddress = CloakWalletManager.getDefaultAddress() ?? '';

      for (final tx in history) {
        if (tx is! Map) continue;

        // Extract memo from transaction
        final memo = tx['memo'] as String? ?? '';
        if (memo.isEmpty) continue;

        // Check if this is a message - either v1 format or legacy 🛡MSG format
        final isV1Message = memo.trim().startsWith('v1;');
        final isLegacyMessage = memo.startsWith('\u{1F6E1}MSG');
        if (!isV1Message && !isLegacyMessage) continue;

        // Get transaction details
        final idTx = tx['id_tx'] as int? ?? tx['id'] as int? ?? 0;
        final timestamp = tx['timestamp'] as int? ?? tx['block_ts'] as int? ??
            (DateTime.now().millisecondsSinceEpoch ~/ 1000);
        final blockNum = tx['block_num'] as int? ?? tx['block_ts'] as int? ?? _syncedHeight;
        final incoming = tx['incoming'] as bool? ?? true;
        final txAddress = tx['address'] as String? ?? '';

        // Skip if we already have this message (dedupe by body content)
        if (await CloakDb.messageExistsByBody(accountId, memo)) {
          continue;
        }

        // Parse header to extract sender info
        String sender = '';
        String subject = '';
        String recipient = incoming ? myAddress : txAddress;

        if (isV1Message) {
          // v1 format: parse header line
          final firstLine = memo.split('\n').first.trim();
          final parts = firstLine.split(';');
          for (final raw in parts) {
            final t = raw.trim();
            if (t.isEmpty) continue;
            final i = t.indexOf('=');
            if (i > 0) {
              final k = t.substring(0, i).trim();
              final v = t.substring(i + 1).trim();
              if (k == 'reply_to_ua' && incoming) sender = v;
            }
          }
          // Subject is typically empty for v1 messages, body contains full memo
        } else if (isLegacyMessage) {
          // Legacy format: 🛡MSG\n<sender>\n<subject>\n<body>
          final lines = memo.split('\n');
          if (lines.length > 1) sender = lines[1];
          if (lines.length > 2) subject = lines[2];
        }

        // Store the message - body contains FULL memo for UI to parse headers
        await CloakDb.storeMessage(
          account: accountId,
          idTx: idTx,
          incoming: incoming,
          sender: incoming ? sender : null,
          recipient: recipient,
          subject: subject,
          body: memo,  // Store full memo so UI can parse v1 headers
          timestamp: timestamp,
          height: blockNum,
          read: false,
        );
      }

    } catch (e) {
      print('CloakSync: Error extracting messages: $e');
    }
  }

  /// Force re-extract all messages (useful after restore)
  static Future<int> extractAllMessages() async {
    await _extractMessagesFromHistory();
    final count = await CloakDb.getUnreadMessageCount(CloakWalletManager.accountId);
    return count;
  }
}

/// Result of table-based sync
class ZeosSyncResult {
  final bool success;
  final String? error;
  final ZeosGlobal? global;
  final List<ZeosMerkleEntry>? merkleEntries;
  final List<ZeosNullifier>? nullifiers;

  ZeosSyncResult({
    required this.success,
    this.error,
    this.global,
    this.merkleEntries,
    this.nullifiers,
  });
}
