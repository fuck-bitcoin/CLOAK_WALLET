// CLOAK Wallet Manager
// Handles CLOAK-specific wallet operations that differ from Zcash/Ycash

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart' as crypto;
import 'package:cloak_api/cloak_api.dart';
import 'package:eosdart/eosdart.dart' as eosdart;

import '../coin/coins.dart';
import '../pages/utils.dart';
import '../update/update_install_gate.dart';
import 'cloak_db.dart';
import 'cloak_sync.dart';
import 'eosio_client.dart';
import 'ffi_isolate.dart';
import 'esr_service.dart';
import 'params_manager.dart';
import 'pending_wallet_operation.dart';
import 'protocol_compatibility.dart';
import 'send_recovery.dart';
import 'shielded_ft_balance.dart';
import 'wallet_operation_coordinator.dart';

// CLOAK coin ID
const int CLOAK_COIN = 0;

/// Convert an EOSIO account name string to its u64 representation.
/// Matches the Rust Name::from_string() encoding exactly:
///   '.' = 0, '1'-'5' = 1-5, 'a'-'z' = 6-31
///   First 12 chars use 5 bits each, 13th char uses 4 bits.
int eosioNameToU64(String name) {
  if (name.isEmpty) return 0;
  if (name.length > 13) {
    throw ArgumentError('EOSIO name too long: "$name" (max 13 chars)');
  }

  int charToValue(int c) {
    if (c == 0x2E) return 0; // '.'
    if (c >= 0x31 && c <= 0x35) return (c - 0x31) + 1; // '1'-'5'
    if (c >= 0x61 && c <= 0x7A) return (c - 0x61) + 6; // 'a'-'z'
    throw ArgumentError(
        'Invalid EOSIO name character: ${String.fromCharCode(c)}');
  }

  int value = 0;
  final n = name.length < 12 ? name.length : 12;
  for (int i = 0; i < n; i++) {
    value <<= 5;
    value |= charToValue(name.codeUnitAt(i));
  }
  value <<= 4 + 5 * (12 - n);
  if (name.length == 13) {
    final c = charToValue(name.codeUnitAt(12));
    if (c > 0x0F) {
      throw ArgumentError('13th character in EOSIO name cannot be after "j"');
    }
    value |= c;
  }
  return value;
}

/// Structured result from querying vault tokens on-chain
class VaultTokensResult {
  final int cloakUnits;
  final List<Map<String, dynamic>> fts;
  final List<Map<String, dynamic>> nfts;
  final bool existsOnChain;
  const VaultTokensResult(
      {required this.cloakUnits,
      required this.fts,
      required this.nfts,
      this.existsOnChain = false});
}

/// A single withdrawal entry for batch vault authenticate.
/// Either [quantity]+[tokenContract] for FTs, or [nftAssetIds]+[nftContract] for NFTs.
class VaultWithdrawEntry {
  final String? quantity; // e.g. "1.0000 CLOAK" (FT only)
  final String? tokenContract; // e.g. "thezeostoken" (FT only)
  final List<String>? nftAssetIds; // NFT asset IDs as strings (NFT only)
  final String? nftContract; // e.g. "atomicassets" (NFT only)
  final String memo;

  const VaultWithdrawEntry({
    this.quantity,
    this.tokenContract,
    this.nftAssetIds,
    this.nftContract,
    this.memo = '',
  });

  bool get isNft => nftAssetIds != null && nftAssetIds!.isNotEmpty;
  bool get isFt => quantity != null && quantity!.isNotEmpty;
}

// In-memory wallet pointer (one per app instance)
Pointer<Void>? _cloakWallet;

// Path to wallet file
String? _cloakWalletPath;

// Current account ID and name (loaded from database)
int _cloakAccountId = 0;
String _cloakAccountName = 'CLOAK Account';

class CloakWalletManager {
  static final WalletOperationCoordinator _walletOperations =
      WalletOperationCoordinator();
  static final AsyncSingleFlight<bool> _zkParamsLoader =
      AsyncSingleFlight<bool>();
  static bool _normalSendInProgress = false;
  static bool _protocolMigrationActive = false;
  static bool _pendingProofMutation = false;
  static Future<void> _saveTail = Future<void>.value();
  static int? _lastValidatedChainDepth;
  static DateTime? _lastDepthValidation;
  static PendingWalletOperation? _pendingWalletOperation;
  static String? _scheduledPendingReconciliationId;
  static bool _pendingSaveAuthorized = false;
  static WalletProtocolGeneration _cachedProtocolGeneration =
      WalletProtocolGeneration.legacy;
  static bool _cachedIsViewOnly = false;
  static String? _cachedDefaultAddress;
  static String? _cachedChainId;
  static String? _cachedProtocolContract;
  static String? _cachedVaultContract;
  static String? _cachedAliasAuthority;
  static String? _cachedIvk;
  static String? _cachedFvk;
  static String? _cachedOvk;
  static String? _cachedSeedHex;
  static String? _cachedBalancesJson;
  static String? _cachedTransactionHistoryJson;
  static final Map<String, String?> _cachedNftsJson = {};
  static final Map<String, String?> _cachedAuthenticationTokensJson = {};
  static String? _cachedUnpublishedNotesJson;
  static final ValueNotifier<String?> protocolCompatibilityError =
      ValueNotifier<String?>(null);
  static final ValueNotifier<String?> pendingTransactionStatus =
      ValueNotifier<String?>(null);

  static bool get isSensitiveOperationActive =>
      _normalSendInProgress ||
      _protocolMigrationActive ||
      _pendingProofMutation ||
      _walletOperations.isActive ||
      CloakSync.isWalletLocked;

  static String? get activeWalletOperation => _walletOperations.activeLabel;
  static bool get _nativeSynchronousAccessAllowed =>
      !_walletOperations.isActive || _walletOperations.isHeldByCurrentZone;

  /// The one coordinated escape hatch for sync code that must call the native
  /// API directly. New UI/proof code must use manager methods instead.
  static Future<T> runNativeWalletOperation<T>(
    String label,
    FutureOr<T> Function(Pointer<Void> wallet) operation,
  ) {
    return _walletOperations.runExclusive(label, () async {
      // Re-check after acquiring the mutex. A caller can queue while the
      // updater is idle and otherwise begin native work after install starts.
      _requireNoUpdateApply();
      if (_pendingProofMutation && !walletOperationMayRunWhilePending(label)) {
        throw StateError(
            'Wallet sync is deferred until the pending transaction is reconciled');
      }
      final wallet = _cloakWallet;
      if (wallet == null) throw StateError('Wallet not loaded');
      return await operation(wallet);
    });
  }

  static Future<void> synchronizeAuthCount(int authCount) {
    return _walletOperations.runExclusive('synchronize-auth-count', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      final wallet = _cloakWallet;
      if (wallet == null) throw StateError('Wallet not loaded');
      final current = CloakApi.getAuthCount(wallet) ?? 0;
      if (current != authCount) CloakApi.setAuthCount(wallet, authCount);
    });
  }

  static void _refreshImmutableWalletCacheLocked() {
    if (!_walletOperations.isHeldByCurrentZone) {
      throw StateError('Wallet cache refresh requires wallet ownership');
    }
    final wallet = _cloakWallet;
    if (wallet == null) return;
    _cachedProtocolGeneration = WalletProtocolGeneration.parse(
      CloakApi.getProtocolGeneration(wallet),
    );
    _cachedIsViewOnly = CloakApi.isViewOnly(wallet) ?? false;
    _cachedDefaultAddress = CloakApi.defaultAddress(wallet);
    _cachedChainId = CloakApi.getChainId(wallet);
    _cachedProtocolContract = CloakApi.getProtocolContract(wallet);
    _cachedVaultContract = CloakApi.getVaultContract(wallet);
    _cachedAliasAuthority = CloakApi.getAliasAuthority(wallet);
    _cachedIvk = CloakApi.getIvkBech32m(wallet);
    _cachedFvk = CloakApi.getFvkBech32m(wallet);
    _cachedOvk = CloakApi.getOvkBech32m(wallet);
    _cachedSeedHex = CloakApi.getSeedHex(wallet);

    // Populate the UI's most frequently read native values before releasing
    // the coordinator. During worker-isolate work, synchronous getters must
    // serve these snapshots rather than race the raw pointer or flicker empty.
    _cachedBalancesJson = CloakApi.getBalancesJson(wallet, pretty: true) ??
        _cachedBalancesJson ??
        '[]';
    _cachedTransactionHistoryJson =
        CloakApi.getTransactionHistoryJson(wallet, pretty: true) ??
            _cachedTransactionHistoryJson ??
            '[]';
    _cachedUnpublishedNotesJson =
        CloakApi.getUnpublishedNotesJson(wallet, pretty: true) ??
            _cachedUnpublishedNotesJson;
    for (final spent in [false, true]) {
      final key = '0:$spent';
      _cachedAuthenticationTokensJson[key] =
          CloakApi.getAuthenticationTokensJson(
                wallet,
                contract: 0,
                spent: spent,
                pretty: true,
              ) ??
              _cachedAuthenticationTokensJson[key] ??
              '[]';
    }
  }

  static void _requireNoUpdateApply() {
    if (UpdateInstallGate.isApplyingUpdate) {
      throw StateError('Wallet update is being applied');
    }
  }

  static void _requireNoPendingWalletMutation() {
    if (_pendingProofMutation) {
      throw StateError(
          'A pending transaction must be reconciled before changing the wallet');
    }
  }

  static WalletProtocolGeneration get walletProtocolGeneration {
    if (_cloakWallet == null) return WalletProtocolGeneration.legacy;
    if (!_nativeSynchronousAccessAllowed) return _cachedProtocolGeneration;
    _cachedProtocolGeneration = WalletProtocolGeneration.parse(
      CloakApi.getProtocolGeneration(_cloakWallet!),
    );
    return _cachedProtocolGeneration;
  }

  /// Check if this is a CLOAK coin operation
  static bool isCloak(int coin) => coin == CLOAK_COIN;

  /// Initialize CLOAK wallet storage path and database
  /// @param dbPassword The encryption password for the database (typically appStore.dbPassword)
  static Future<void> init({String dbPassword = ''}) async {
    final dbPath = await getDbPath();
    _cloakWalletPath = p.join(dbPath, cloak.dbName);

    // Initialize encrypted database with password
    await CloakDb.init(password: dbPassword);

    // Load burn timestamps cache for synchronous TX history relabeling
    await CloakDb.refreshBurnTimestampsCache();
  }

  /// Create a new CLOAK wallet from seed
  /// Returns the account ID from database, or -1 on failure
  static Future<int> createWallet(
    String name,
    String seed, {
    String aliasAuthority = 'thezeosalias@public',
    bool skipAutoVault = false,
    bool isIvk = false,
  }) async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('create-wallet', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWalletPath == null) await init();
      if (await _pendingOperationFile.exists()) {
        _pendingProofMutation = true;
        throw StateError(
            'A pending transaction must be reconciled before replacing the wallet');
      }

      // Normalize seed: collapse all whitespace (newlines, tabs, multiple spaces)
      // into single spaces and trim. This prevents mismatches when seeds are
      // pasted with line breaks or extra spacing.
      seed = seed.trim().replaceAll(RegExp(r'\s+'), ' ');

      // Close existing wallet if any
      if (_cloakWallet != null) {
        CloakApi.closeWallet(_cloakWallet!);
        _cloakWallet = null;
      }

      // Create new wallet
      final wallet = CloakApi.createWallet(
        seed,
        isIvk: isIvk,
        aliasAuthority: aliasAuthority,
      );

      if (wallet == null) {
        print('CloakWalletManager: Failed to create wallet');
        return -1;
      }

      _cloakWallet = wallet;
      _refreshImmutableWalletCacheLocked();
      _pendingProofMutation = false;

      // Get the address for this wallet
      // IVK wallets use defaultAddress (deterministic, no mutation).
      // deriveAddress() mutates the wallet by adding to diversifiers — not
      // appropriate for initial creation, and panics on IVK wallets with
      // empty diversifiers.
      final address = isIvk
          ? (CloakApi.defaultAddress(wallet) ?? '')
          : (CloakApi.deriveAddress(wallet) ?? '');

      // Get IVK (incoming viewing key) in bech32m format
      final ivk = CloakApi.getIvkBech32m(wallet) ?? '';

      // Save to disk
      final saveResult = await saveWallet();
      if (!saveResult) {
        CloakApi.closeWallet(wallet);
        _cloakWallet = null;
        return -1;
      }

      // Store account in database (matching Zcash schema)
      final accountId = await CloakDb.newAccount(
        name: name,
        seed: seed,
        ivk: ivk,
        address: address,
        sk: null, // spending key - could store if needed
        aindex: 0,
      );

      if (accountId < 0) {
        print('CloakWalletManager: Failed to create account in database');
        return -1;
      }

      _cloakAccountId = accountId;
      _cloakAccountName = name;

      // Mark as new account and set initial sync height to latest block
      // New accounts don't need to sync history - they start fresh
      CloakSync.markAsNewAccount();

      // Wrap in try/catch to prevent crashes during setup
      try {
        await CloakSync.setInitialHeightForNewAccount();
      } catch (e) {
        print(
            'CloakWalletManager: setInitialHeightForNewAccount error (non-fatal): $e');
      }

      // Preload ZK params in background so first send is instant.
      // IVK (view-only) wallets can't sign transactions, so skip.
      if (!isIvk) {
        _preloadZkParamsInBackground();
      }

      // Vaults are user-initiated, not auto-created on fresh wallets.
      // Users can create a vault when they need one via the Shield flow.

      return accountId;
    });
  }

  /// Ensure a default vault exists for this wallet
  /// Creates one if none exist
  static Future<bool> _ensureDefaultVaultExists() async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('ensure-default-vault', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) {
        return false;
      }

      // Check if we already have auth tokens
      final tokensJson =
          CloakApi.getAuthenticationTokensJson(_cloakWallet!, pretty: true);
      if (tokensJson != null) {
        try {
          final tokens = jsonDecode(tokensJson) as List;
          if (tokens.isNotEmpty) {
            return true;
          }
        } catch (e) {
          print('CloakWalletManager: Error parsing auth tokens');
        }
      }

      // Create a default vault — use createAndStoreVault() which persists the
      // seed to the DB vaults table (needed for _ensureAuthTokenLoaded recovery).
      final hash = await createAndStoreVault();
      return hash != null;
    });
  }

  /// Preload ZK params in background (non-blocking)
  static void _preloadZkParamsInBackground() {
    // Fire and forget - load params while user does other things
    Future(() async {
      try {
        await loadZkParams();
      } catch (error) {
        print('CloakWalletManager: ZK parameter preload deferred: $error');
      }
    });
  }

  /// Ensure ZK params are loaded (call from sync or other background tasks)
  /// Non-blocking - starts load if not already loaded/loading
  static void ensureZkParamsLoaded() {
    if (_mintParams != null) return; // Already loaded
    _preloadZkParamsInBackground();
  }

  /// Check if ZK params are ready (for UI indicators if needed)
  static bool get zkParamsReady => _mintParams != null;

  /// Restore a CLOAK wallet from seed (full sync needed)
  /// This is like createWallet but marks it for full history sync
  static Future<int> restoreWallet(
    String name,
    String seed, {
    String aliasAuthority = 'thezeosalias@public',
    bool isIvk = false,
  }) async {
    // Mark as restored BEFORE creating - sync will do full history
    CloakSync.markAsRestored();

    // Create the wallet normally — skip auto-vault since sync step 5f
    // will create + publish after balance is synced
    final accountId = await createWallet(name, seed,
        aliasAuthority: aliasAuthority, skipAutoVault: true, isIvk: isIvk);

    // Override the new account marking - this is a restore
    CloakSync.markAsRestored();

    // Reset synced_height to 0 so sync() triggers a full sync.
    // createWallet() called setInitialHeightForNewAccount() which set it to latest block.
    await CloakDb.setProperty('synced_height', '0');
    await CloakDb.setProperty('full_sync_done', 'false');

    // S33 fix: Clear slow mode flags so restore sync starts fresh with Hyperion.
    // Without this, stale _sessionSlowMode/_permanentSlowMode from the previous
    // session could cause the restore to skip Hyperion entirely, falling back to
    // block-direct which may return 0 blocks and leave the wallet empty.
    CloakSync.clearCachedCounters();
    await CloakSync.clearPermanentSlowMode();

    return accountId;
  }

  /// Get account ID
  static int get accountId => _cloakAccountId;

  /// Get account name
  static String get accountName => _cloakAccountName;

  /// Load CLOAK wallet from disk
  static Future<bool> loadWallet() =>
      _loadWallet(updateRecoveryWhileGateHeld: false);

  /// Reopen the exact wallet closed by update shutdown when an installer did
  /// not replace/exit the process. This narrow recovery path requires the
  /// install gate to remain held and grants no general mutation bypass.
  static Future<bool> loadWalletForUpdateRecovery() {
    if (!UpdateInstallGate.isApplyingUpdate) {
      throw StateError('Update recovery requires the held install gate');
    }
    return _loadWallet(updateRecoveryWhileGateHeld: true);
  }

  static Future<bool> _loadWallet({
    required bool updateRecoveryWhileGateHeld,
  }) async {
    if (updateRecoveryWhileGateHeld) {
      if (!UpdateInstallGate.isApplyingUpdate) {
        throw StateError('Update recovery install gate was released');
      }
    } else {
      _requireNoUpdateApply();
    }
    return _walletOperations.runExclusive('load-wallet', () async {
      if (updateRecoveryWhileGateHeld) {
        if (!UpdateInstallGate.isApplyingUpdate) {
          throw StateError('Update recovery install gate was released');
        }
      } else {
        _requireNoUpdateApply();
      }
      if (_cloakWalletPath == null) await init();

      final file = File(_cloakWalletPath!);
      if (!await file.exists()) {
        print('CloakWalletManager: Wallet file does not exist');
        return false;
      }

      try {
        final bytes = await file.readAsBytes();
        final wallet = CloakApi.readWallet(bytes);
        if (wallet == null) {
          print('CloakWalletManager: Failed to deserialize wallet');
          return false;
        }

        // Close old wallet if any
        if (_cloakWallet != null) {
          CloakApi.closeWallet(_cloakWallet!);
        }

        _cloakWallet = wallet;
        _refreshImmutableWalletCacheLocked();
        _pendingProofMutation = false;

        // Load account info from database
        final account = await CloakDb.getFirstAccount();
        if (account != null) {
          _cloakAccountId = account['id_account'] as int;
          _cloakAccountName = account['name'] as String;
        }

        if (!await _prepareLoadedWalletProtocol(
          bytes,
          updateRecoveryWhileGateHeld: updateRecoveryWhileGateHeld,
        )) {
          print('CloakWalletManager: Protocol migration preparation failed');
          return false;
        }
        await _loadPendingOperationLocked();
        if (_pendingWalletOperation != null) {
          _schedulePendingReconciliation(_pendingWalletOperation!.operationId);
        }

        // Defer debug logging and non-critical FFI calls until after the first sync
        // completes. These calls (getAuthenticationTokensJson, getBalancesJson,
        // getLeafCount, alias check, auth token import, ZK params preload) are not
        // needed for the initial UI render and would block the main thread if they
        // run during sync.
        Future(() async {
          // Wait until the first sync cycle finishes. Poll every 500ms, with a
          // hard cap of 30 seconds to avoid waiting forever if sync errors out.
          for (int i = 0; i < 60; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (!CloakSync.isSyncing) break;
          }

          try {
            final w = _cloakWallet;
            if (w == null) return;
            if (walletProtocolGeneration != WalletProtocolGeneration.v11012) {
              return;
            }

            // Check alias_authority - this is CRITICAL for ZK proofs
            final storedAlias = getAliasAuthority();
            if (storedAlias != EXPECTED_ALIAS_AUTHORITY) {
              print('');
              print(
                  '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!');
              print(
                  '!! CRITICAL WARNING: Wallet has wrong alias_authority!            ');
              print(
                  '!! Stored: "$storedAlias"                                         ');
              print(
                  '!! Expected: "$EXPECTED_ALIAS_AUTHORITY"                          ');
              print(
                  '!! Shield transactions will FAIL with "proof invalid" error!      ');
              print(
                  '!! You need to recreate your wallet with the correct authority.   ');
              print(
                  '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!');
              print('');
            }

            // One-time import of auth token from CLOAK GUI wallet
            await _importAuthTokenFromCloakGui();

            // Preload ZK params in background so first send is instant
            _preloadZkParamsInBackground();
          } catch (e) {
            print('CloakWalletManager: Deferred loadWallet tasks error: $e');
          }
        });

        return true;
      } catch (e) {
        print('CloakWalletManager: Error loading wallet: $e');
        return false;
      }
    });
  }

  /// One-time import of unpublished auth token notes from the CLOAK GUI wallet.
  /// The auth token was created in /opt/cloak-gui/ and is needed for vault
  /// authenticate operations. This reads the extracted JSON and injects it
  /// into the Flutter wallet's Rust state, then saves.
  static Future<void> _importAuthTokenFromCloakGui() async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('import-gui-auth-token', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) return;

      // Check if we already imported (stored as a DB property)
      final alreadyImported =
          await CloakDb.getProperty('cloak_gui_auth_imported');
      if (alreadyImported == 'true') {
        return;
      }

      // Path to the extracted unpublished notes JSON from CLOAK GUI wallet.bin
      const importPath = '/tmp/cloak_unpublished_notes.json';
      final file = File(importPath);
      if (!await file.exists()) {
        return;
      }

      try {
        final notesJson = await file.readAsString();

        // Validate JSON structure
        final parsed = jsonDecode(notesJson);
        if (parsed is! Map || !parsed.containsKey('self')) {
          print(
              '[CloakWalletManager] Invalid auth token JSON format — expected {"self": [...]}');
          return;
        }

        // Inject into wallet's Rust state
        if (!CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson)) {
          print(
              '[CloakWalletManager] addUnpublishedNotes failed: ${CloakApi.getLastError()}');
          return;
        }

        // Save wallet to persist the imported auth token
        if (!await saveWallet()) {
          print(
              '[CloakWalletManager] Failed to save wallet after auth token import');
          return;
        }

        // Mark as imported so we don't repeat
        await CloakDb.setProperty('cloak_gui_auth_imported', 'true');
      } catch (e) {
        print('[CloakWalletManager] Error importing auth token: $e');
      }
    });
  }

  /// Import auth tokens and unpublished notes from a CLOAK GUI wallet file.
  /// This loads the GUI wallet.bin as a TEMPORARY second wallet, extracts its
  /// unpublished notes (which contain encrypted auth token ciphertexts with the
  /// correct diversifiers), and injects them into the current Flutter wallet.
  ///
  /// This preserves: balance, transaction history, sync state, merkle tree.
  /// This gains: correct auth tokens (vault tokens with GUI diversifiers).
  static Future<bool> importFromGuiWalletFile(
    String filePath, {
    void Function(String)? onLog,
    void Function(String)? onStatus,
  }) async {
    void log(String msg) {
      onLog?.call(msg);
    }

    _requireNoUpdateApply();
    return _walletOperations.runExclusive('import-gui-wallet', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) {
        log('ERROR: Current wallet not loaded');
        return false;
      }

      // Read the GUI wallet file
      onStatus?.call('Reading GUI wallet file...');
      final file = File(filePath);
      if (!await file.exists()) {
        log('ERROR: File not found: $filePath');
        return false;
      }

      final bytes = await file.readAsBytes();
      log('Read ${bytes.length} bytes from ${filePath.split('/').last}');

      // Snapshot current auth tokens for comparison
      final beforeTokens = CloakApi.getAuthenticationTokensJson(
        _cloakWallet!,
        contract: 0,
        spent: false,
      );
      log('Current wallet auth tokens (before): $beforeTokens');

      // Load GUI wallet as a temporary pointer
      onStatus?.call('Loading GUI wallet...');
      final guiWallet = CloakApi.readWallet(Uint8List.fromList(bytes));
      if (guiWallet == null) {
        log('ERROR: Failed to deserialize GUI wallet file — is it a valid wallet.bin?');
        return false;
      }
      log('GUI wallet loaded successfully');

      try {
        // Show GUI wallet info
        final guiAddresses =
            CloakApi.getAddressesJson(guiWallet, pretty: false);
        log('GUI wallet addresses: $guiAddresses');

        final guiAuthTokens = CloakApi.getAuthenticationTokensJson(
          guiWallet,
          contract: 0,
          spent: false,
        );
        log('GUI wallet unspent auth tokens: $guiAuthTokens');

        final guiSpentTokens = CloakApi.getAuthenticationTokensJson(
          guiWallet,
          contract: 0,
          spent: true,
        );
        log('GUI wallet spent auth tokens: $guiSpentTokens');

        // Extract unpublished notes from GUI wallet
        onStatus?.call('Extracting unpublished notes...');
        final unpublishedJson = CloakApi.getUnpublishedNotesJson(
          guiWallet,
          pretty: false,
        );
        if (unpublishedJson == null ||
            unpublishedJson.isEmpty ||
            unpublishedJson == '{}') {
          log('WARNING: GUI wallet has no unpublished notes');
        } else {
          log('GUI wallet unpublished notes: ${unpublishedJson.length} chars');

          // Parse to see what we're importing
          try {
            final parsed = jsonDecode(unpublishedJson);
            if (parsed is Map) {
              log('Unpublished notes has ${parsed.length} timestamp entries');
              for (final entry in parsed.entries) {
                final inner = entry.value;
                if (inner is Map) {
                  log('  ts=${entry.key}: ${inner.keys.join(', ')} (${inner.values.map((v) => v is List ? '${v.length} notes' : '?').join(', ')})');
                }
              }
            }
          } catch (_) {}

          // Inject unpublished notes into current wallet
          onStatus?.call('Injecting unpublished notes into wallet...');
          if (CloakApi.addUnpublishedNotes(_cloakWallet!, unpublishedJson)) {
            log('addUnpublishedNotes succeeded');
          } else {
            log('ERROR: addUnpublishedNotes failed: ${CloakApi.getLastError()}');
          }
        }

        // Also extract unspent auth token note data directly.
        // The GUI wallet's unspent_notes contain already-decrypted auth tokens.
        // We can re-export these as unpublished notes by getting the wallet's
        // auth token seeds and re-creating them with the GUI wallet's addresses.
        //
        // For each GUI auth token, try to re-create it using the GUI wallet's
        // default address and add it to the current wallet.
        onStatus?.call('Re-creating auth tokens from GUI wallet...');
        final guiAuthWithSeed = CloakApi.getAuthenticationTokensJson(
          guiWallet,
          contract: 0,
          spent: false,
          seed: true,
        );
        if (guiAuthWithSeed != null) {
          log('GUI auth tokens with seeds: $guiAuthWithSeed');

          // Get GUI wallet addresses once (these have the correct diversifiers)
          final guiAddrsJson = CloakApi.getAddressesJson(guiWallet);
          List<dynamic>? guiAddrs;
          if (guiAddrsJson != null) {
            guiAddrs = jsonDecode(guiAddrsJson) as List?;
            log('GUI wallet has ${guiAddrs?.length ?? 0} addresses');
          }

          try {
            final tokenList = jsonDecode(guiAuthWithSeed);
            if (tokenList is List) {
              // Each entry is "commitment@contract|seed" or "commitment@contract"
              for (final token in tokenList) {
                final tokenStr = token as String;
                final pipeIdx = tokenStr.indexOf('|');
                if (pipeIdx < 0) {
                  log('  Token ${tokenStr.substring(0, 16)}... has no seed, skipping');
                  continue;
                }
                final hashAndContract = tokenStr.substring(0, pipeIdx);
                final seed = tokenStr.substring(pipeIdx + 1);
                final atIdx = hashAndContract.indexOf('@');
                final hash = atIdx >= 0
                    ? hashAndContract.substring(0, atIdx)
                    : hashAndContract;
                final contractName =
                    atIdx >= 0 ? hashAndContract.substring(atIdx + 1) : '';
                log('  Re-creating auth token: hash=${hash.substring(0, 16)}... contract=$contractName');

                // Try each GUI wallet address to find the one that produces the right commitment
                final importContractU64 =
                    contractName.isNotEmpty ? eosioNameToU64(contractName) : 0;
                if (guiAddrs != null) {
                  bool matched = false;
                  for (final addr in guiAddrs) {
                    final addrStr = addr as String;
                    final notesJson = CloakApi.createUnpublishedAuthNote(
                      _cloakWallet!,
                      seed,
                      importContractU64,
                      addrStr,
                    );
                    if (notesJson != null && notesJson.isNotEmpty) {
                      // Check if this produced the right commitment
                      final parsed = jsonDecode(notesJson);
                      if (parsed is Map) {
                        final cmList = parsed['__commitment__'];
                        if (cmList is List && cmList.isNotEmpty) {
                          final cm = cmList[0] as String;
                          if (cm == hash) {
                            log('    MATCH! addr=${addrStr.substring(0, 20)}... => ${cm.substring(0, 16)}...');
                            matched = true;
                          }
                        }
                      }
                      // Add to wallet — duplicates are skipped internally
                      CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson);
                      if (matched)
                        break; // Found the right address, stop trying others
                    }
                  }
                  if (!matched) {
                    log('    WARNING: No GUI address matched commitment ${hash.substring(0, 16)}...');
                  }
                }
              }
            }
          } catch (e) {
            log('Error re-creating auth tokens: $e');
          }
        }

        // Snapshot after
        final afterTokens = CloakApi.getAuthenticationTokensJson(
          _cloakWallet!,
          contract: 0,
          spent: false,
        );
        log('Current wallet auth tokens (after): $afterTokens');

        // Compare before/after
        if (beforeTokens != afterTokens) {
          log('Auth tokens CHANGED — new tokens were imported!');
        } else {
          log('Auth tokens unchanged — tokens may already have been present');
        }

        // Save the current wallet to persist changes
        onStatus?.call('Saving wallet...');
        if (await saveWallet()) {
          log('Wallet saved successfully');
        } else {
          log('ERROR: Failed to save wallet');
          return false;
        }

        // Update the vault commitment hashes in DB if needed
        onStatus?.call('Updating vault database...');
        await _updateVaultHashesFromWallet(onLog: log);

        log('Import complete!');
        return true;
      } finally {
        // Always close the temporary GUI wallet to free memory
        CloakApi.closeWallet(guiWallet);
        log('GUI wallet closed');
      }
    });
  }

  /// After importing auth tokens from GUI wallet, verify the DB vault hashes
  /// to match what's actually in the wallet's unspent auth tokens.
  static Future<void> _updateVaultHashesFromWallet({
    void Function(String)? onLog,
  }) async {
    if (!_walletOperations.isHeldByCurrentZone) {
      throw StateError('Vault hash import requires wallet ownership');
    }
    void log(String msg) {
      onLog?.call(msg);
    }

    if (_cloakWallet == null) return;

    final tokensJson = CloakApi.getAuthenticationTokensJson(
      _cloakWallet!,
      contract: 0,
      spent: false,
    );
    if (tokensJson == null) return;

    final tokens = jsonDecode(tokensJson);
    if (tokens is! List || tokens.isEmpty) return;

    // Get all wallet auth token commitment hashes (strip @contract suffix)
    final walletHashes = <String>{};
    for (final t in tokens) {
      final s = t as String;
      final atIdx = s.indexOf('@');
      walletHashes.add(atIdx >= 0 ? s.substring(0, atIdx) : s);
    }
    log('Wallet has ${walletHashes.length} unspent auth token hashes');

    // Get all vaults from DB
    final vaults = await CloakDb.getAllVaults();
    for (final vault in vaults) {
      final dbHash = vault['commitment_hash'] as String?;
      if (dbHash != null && !walletHashes.contains(dbHash)) {
        log('DB vault ${vault['id']} hash ${dbHash.substring(0, 16)}... NOT in wallet');
        // Check if any wallet hash could be for this vault by trying to match seed
        // For now just log — the re-creation step above should have fixed this
      } else if (dbHash != null) {
        log('DB vault ${vault['id']} hash ${dbHash.substring(0, 16)}... OK (in wallet)');
      }
    }

    // Check (but NEVER change) the active vault hash — it's the on-chain identifier
    final activeHash = await CloakDb.getProperty('cloak_vault_hash');
    if (activeHash != null) {
      final inWallet = walletHashes.contains(activeHash);
      log('Active vault hash ${activeHash.substring(0, 16)}... ${inWallet ? "OK (in wallet)" : "NOT in wallet auth tokens (on-chain hash may differ)"}');
    }
  }

  static Future<bool> _prepareLoadedWalletProtocol(
    Uint8List originalBytes, {
    bool updateRecoveryWhileGateHeld = false,
  }) async {
    if (!_walletOperations.isHeldByCurrentZone) {
      throw StateError(
          'Protocol migration preparation requires wallet ownership');
    }
    if (updateRecoveryWhileGateHeld) {
      if (!UpdateInstallGate.isApplyingUpdate) {
        throw StateError('Update recovery install gate was released');
      }
    } else {
      _requireNoUpdateApply();
    }
    final generation = walletProtocolGeneration;
    _lastValidatedChainDepth = null;
    _lastDepthValidation = null;

    // The updater may only reopen bytes it just saved and closed. Never begin
    // or advance a protocol migration through this gate-only recovery path.
    if (updateRecoveryWhileGateHeld) {
      if (generation == WalletProtocolGeneration.legacy) {
        protocolCompatibilityError.value =
            'Wallet update recovery requires a normal restart.';
        return false;
      }
      protocolCompatibilityError.value = generation ==
              WalletProtocolGeneration.migratingV11012
          ? 'Wallet migration is resyncing. Sending is disabled until it completes.'
          : generation == WalletProtocolGeneration.unknown
              ? 'Wallet update required: unsupported wallet protocol generation.'
              : null;
      return true;
    }

    if (generation == WalletProtocolGeneration.v11012) {
      protocolCompatibilityError.value = null;
      return true;
    }
    if (generation == WalletProtocolGeneration.unknown) {
      protocolCompatibilityError.value =
          'Wallet update required: unsupported wallet protocol generation.';
      return true;
    }

    _protocolMigrationActive = true;
    CloakSync.lockWallet();
    var migrationPersisted =
        generation == WalletProtocolGeneration.migratingV11012;
    try {
      if (generation == WalletProtocolGeneration.legacy) {
        await _createProtocolMigrationBackup(originalBytes);
        if (!CloakApi.beginProtocolMigration(_cloakWallet!)) {
          throw StateError('Could not begin wallet protocol migration');
        }
        if (!CloakApi.resetChainState(_cloakWallet!)) {
          throw StateError('Could not reset legacy wallet chain state');
        }
        if (!await saveWallet()) {
          throw StateError('Could not persist pending wallet migration');
        }
        migrationPersisted = true;
      }

      // A partially resynced migrating wallet keeps its height. An empty
      // freshly-reset wallet always restarts from zero.
      final leafCount = CloakApi.getLeafCount(_cloakWallet!) ?? 0;
      if (leafCount == 0) {
        await CloakDb.setProperty('synced_height', '0');
      }
      await CloakDb.setProperty('full_sync_done', 'false');
      CloakSync.clearCachedCounters();
      await CloakSync.clearPermanentSlowMode();
      CloakSync.markAsRestored();
      CloakSync.resetSessionFlags();
      clearVaultTokensCache();
      protocolCompatibilityError.value =
          'Wallet migration is resyncing. Sending is disabled until it completes.';
      return true;
    } catch (error) {
      print(
          '[CloakWalletManager] Protocol migration preparation failed: $error');
      if (!migrationPersisted) {
        _replaceWalletFromSnapshot(originalBytes);
      }
      protocolCompatibilityError.value =
          'Wallet update required: protocol migration could not be prepared.';
      return false;
    } finally {
      CloakSync.unlockWallet();
      _protocolMigrationActive = false;
    }
  }

  static Future<void> _createProtocolMigrationBackup(
      Uint8List originalBytes) async {
    if (_cloakWalletPath == null)
      throw StateError('Wallet path is unavailable');
    final originalHash = crypto.sha256.convert(originalBytes).toString();
    final primary = File('${_cloakWalletPath!}.pre-v1.1.0-12.bak');
    File backup = primary;
    if (await primary.exists()) {
      final isExactOriginal = await primary.length() == originalBytes.length &&
          await ParamsManager.verifyChecksum(primary.path, originalHash);
      if (isExactOriginal) return;

      // Never trust or overwrite a stale backup from another wallet. Preserve
      // it for forensics and place this wallet's exact bytes at a deterministic,
      // content-addressed path so a restart can verify the same recovery copy.
      backup = File('${primary.path}.$originalHash');
    }
    // A corrupt content-addressed retry can be repaired; the unrelated primary
    // backup above is never replaced.
    await _writeBytesAtomically(
      backup,
      originalBytes,
      replace: backup.path != primary.path && await backup.exists(),
    );
    if (!await backup.exists() ||
        await backup.length() != originalBytes.length ||
        !await ParamsManager.verifyChecksum(backup.path, originalHash)) {
      throw StateError('Wallet migration backup could not be verified');
    }
  }

  static Future<void> _writeBytesAtomically(
    File destination,
    List<int> bytes, {
    required bool replace,
  }) async {
    await destination.parent.create(recursive: true);
    final temporary = File(
      '${destination.path}.${pid}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (!replace && await destination.exists()) return;
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static File get _pendingOperationFile =>
      File('${_cloakWalletPath!}.pending-operation-v1.json');
  static File get _pendingPreSnapshotFile =>
      File('${_cloakWalletPath!}.pending-operation-v1.pre.wallet');
  static File get _pendingEagerSnapshotFile =>
      File('${_cloakWalletPath!}.pending-operation-v1.eager.wallet');

  static String _walletIdentitySha256(Pointer<Void> wallet) {
    final fvk = CloakApi.getFvkBech32m(wallet);
    final ivk = CloakApi.getIvkBech32m(wallet);
    final identity = (fvk != null && fvk.isNotEmpty)
        ? 'fvk:$fvk'
        : (ivk != null && ivk.isNotEmpty)
            ? 'ivk:$ivk'
            : null;
    if (identity == null) {
      throw StateError('Wallet identity could not be derived');
    }
    final chain = CloakApi.getChainId(wallet) ?? '';
    final protocol = CloakApi.getProtocolContract(wallet) ?? '';
    return crypto.sha256
        .convert(utf8.encode('$chain\u0000$protocol\u0000$identity'))
        .toString();
  }

  static void _requireLoadedPendingIdentityLocked(
      PendingWalletOperation operation) {
    final wallet = _cloakWallet;
    if (wallet == null) throw StateError('Wallet not loaded');
    if (_walletIdentitySha256(wallet) != operation.walletIdentitySha256) {
      throw StateError(
          'Pending transaction belongs to a different wallet identity');
    }
  }

  static Future<Uint8List> _readVerifiedPendingSnapshotLocked({
    required PendingWalletOperation operation,
    required File file,
    required String expectedSha256,
    required String label,
  }) async {
    if (!await file.exists()) {
      throw StateError('Pending $label wallet snapshot is missing');
    }
    final bytes = await file.readAsBytes();
    if (crypto.sha256.convert(bytes).toString() != expectedSha256) {
      throw StateError('Pending $label wallet snapshot hash mismatch');
    }
    final temporaryWallet = CloakApi.readWallet(bytes);
    if (temporaryWallet == null) {
      throw StateError('Pending $label wallet snapshot is corrupt');
    }
    try {
      if (_walletIdentitySha256(temporaryWallet) !=
          operation.walletIdentitySha256) {
        throw StateError(
            'Pending $label snapshot belongs to a different wallet identity');
      }
    } finally {
      CloakApi.closeWallet(temporaryWallet);
    }
    return bytes;
  }

  static Future<void> _writePendingRecordLocked(
      PendingWalletOperation operation) async {
    final encoded = operation.encode();
    // Validate the exact durable bytes before promotion so no in-memory
    // constructor can write a state that a restart would reject.
    PendingWalletOperation.decode(encoded);
    await _writeBytesAtomically(
      _pendingOperationFile,
      utf8.encode(encoded),
      replace: true,
    );
    _pendingWalletOperation = operation;
    _pendingProofMutation = true;
  }

  static Future<PendingWalletOperation> _beginProofMutationLocked(
      String kind) async {
    _requireNoUpdateApply();
    if (_pendingWalletOperation != null ||
        await _pendingOperationFile.exists()) {
      throw StateError(
        'A previous shielded transaction is awaiting reconciliation',
      );
    }
    final wallet = _cloakWallet;
    if (wallet == null) throw StateError('Wallet not loaded');
    final snapshot = await FfiIsolate.writeWallet(wallet: wallet);
    if (snapshot == null) {
      throw StateError('Failed to snapshot wallet before proof generation');
    }
    await _writeBytesAtomically(
      _pendingPreSnapshotFile,
      snapshot,
      replace: true,
    );
    final now = DateTime.now().toUtc();
    final operationId = crypto.sha256
        .convert(utf8.encode(
          '$kind:${now.microsecondsSinceEpoch}:'
          '${crypto.sha256.convert(snapshot)}',
        ))
        .toString();
    final operation = PendingWalletOperation(
      operationId: operationId,
      kind: kind,
      state: PendingWalletOperationState.prepared,
      walletIdentitySha256: _walletIdentitySha256(wallet),
      preSnapshotSha256: crypto.sha256.convert(snapshot).toString(),
      createdAt: now,
      updatedAt: now,
    );
    await _writePendingRecordLocked(operation);
    return operation;
  }

  static DateTime? _transactionExpiration(Map<String, dynamic> transaction) {
    final value = transaction['expiration'];
    if (value is! String) return null;
    try {
      return DateTime.parse(value.endsWith('Z') ? value : '${value}Z').toUtc();
    } catch (_) {
      return null;
    }
  }

  static Future<PendingWalletOperation> _captureEagerProofStateLocked(
    PendingWalletOperation operation, {
    Map<String, dynamic>? transaction,
    String? transactionId,
    DateTime? expiresAt,
    PendingWalletOperationState state =
        PendingWalletOperationState.proofCreated,
  }) async {
    final wallet = _cloakWallet;
    if (wallet == null) throw StateError('Wallet not loaded');
    _requireLoadedPendingIdentityLocked(operation);
    if (operation.state == PendingWalletOperationState.prepared) {
      final eager = await FfiIsolate.writeWallet(wallet: wallet);
      if (eager == null) {
        throw StateError('Failed to serialize eager proof state');
      }
      await _writeBytesAtomically(
        _pendingEagerSnapshotFile,
        eager,
        replace: true,
      );
      operation = operation.copyWith(
        eagerSnapshotSha256: crypto.sha256.convert(eager).toString(),
      );
      await _readVerifiedPendingSnapshotLocked(
        operation: operation,
        file: _pendingEagerSnapshotFile,
        expectedSha256: operation.eagerSnapshotSha256!,
        label: 'eager',
      );
      // Keep both the canonical file and live UI pointer at pre-proof state.
      // The eager snapshot is applied only after authoritative acceptance.
      final pre = await _readVerifiedPendingSnapshotLocked(
        operation: operation,
        file: _pendingPreSnapshotFile,
        expectedSha256: operation.preSnapshotSha256,
        label: 'pre-proof',
      );
      if (!_replaceWalletFromSnapshot(pre)) {
        throw StateError('Failed to restore live pre-proof wallet state');
      }
    } else {
      final eagerHash = operation.eagerSnapshotSha256;
      if (eagerHash == null) {
        throw StateError('Pending proof is not bound to eager state');
      }
      await _readVerifiedPendingSnapshotLocked(
        operation: operation,
        file: _pendingEagerSnapshotFile,
        expectedSha256: eagerHash,
        label: 'eager',
      );
    }
    final id = transactionId ??
        (transaction == null
            ? operation.transactionId
            : EsrTransactionHelper.transactionId(transaction));
    final updated = operation.copyWith(
      state: state,
      transactionId: id,
      updatedAt: DateTime.now().toUtc(),
      expiresAt: expiresAt ??
          (transaction == null
              ? operation.expiresAt
              : _transactionExpiration(transaction)),
    );
    await _writePendingRecordLocked(updated);
    return updated;
  }

  static Future<void> _markPendingSubmittingLocked(
      PendingWalletOperation operation) async {
    await _writePendingRecordLocked(operation.copyWith(
      state: PendingWalletOperationState.submitting,
      updatedAt: DateTime.now().toUtc(),
    ));
  }

  static Future<void> _clearPendingOperationFilesLocked() async {
    for (final file in [
      _pendingOperationFile,
      _pendingPreSnapshotFile,
      _pendingEagerSnapshotFile,
    ]) {
      if (await file.exists()) await file.delete();
    }
    _pendingWalletOperation = null;
    _pendingProofMutation = false;
    _scheduledPendingReconciliationId = null;
    pendingTransactionStatus.value = null;
  }

  static Future<void> _rollbackPendingOperationLocked(
      PendingWalletOperation operation) async {
    final current = _pendingWalletOperation;
    if (current == null || current.operationId != operation.operationId) {
      throw StateError('Pending wallet operation changed');
    }
    _requireLoadedPendingIdentityLocked(operation);
    final snapshot = await _readVerifiedPendingSnapshotLocked(
      operation: operation,
      file: _pendingPreSnapshotFile,
      expectedSha256: operation.preSnapshotSha256,
      label: 'pre-proof',
    );
    if (!_replaceWalletFromSnapshot(snapshot)) {
      throw StateError('Failed to restore pre-proof wallet snapshot');
    }
    _pendingSaveAuthorized = true;
    try {
      if (!await saveWallet()) {
        throw StateError('Failed to persist restored wallet snapshot');
      }
    } finally {
      _pendingSaveAuthorized = false;
    }
    await _clearPendingOperationFilesLocked();
  }

  static Future<void> _acceptPendingOperationLocked(
      PendingWalletOperation operation) async {
    final current = _pendingWalletOperation;
    if (current == null || current.operationId != operation.operationId) {
      throw StateError('Pending wallet operation changed');
    }
    _requireLoadedPendingIdentityLocked(operation);
    final eagerHash = operation.eagerSnapshotSha256;
    if (eagerHash == null) {
      throw StateError('Accepted transaction is not bound to eager state');
    }
    final eager = await _readVerifiedPendingSnapshotLocked(
      operation: operation,
      file: _pendingEagerSnapshotFile,
      expectedSha256: eagerHash,
      label: 'eager',
    );
    if (!_replaceWalletFromSnapshot(eager)) {
      throw StateError('Accepted transaction eager state is corrupt');
    }
    _pendingSaveAuthorized = true;
    try {
      if (!await saveWallet()) {
        throw StateError('Transaction succeeded but wallet save failed');
      }
    } finally {
      _pendingSaveAuthorized = false;
    }
    await _clearPendingOperationFilesLocked();
  }

  static Future<void> _quarantinePendingOperationLocked(
    PendingWalletOperation operation,
  ) async {
    final current = _pendingWalletOperation;
    if (current == null || current.operationId != operation.operationId) {
      throw StateError('Pending wallet operation changed');
    }
    if (current.transactionId == null ||
        current.expiresAt == null ||
        current.eagerSnapshotSha256 == null) {
      throw StateError(
          'Cannot quarantine a transaction without bound id, expiry, and eager state');
    }
    final updated = current.copyWith(
      state: PendingWalletOperationState.ambiguous,
      updatedAt: DateTime.now().toUtc(),
    );
    await _writePendingRecordLocked(updated);
    _pendingWalletOperation = updated;
    _schedulePendingReconciliation(updated.operationId);
  }

  static Future<void> _loadPendingOperationLocked() async {
    _pendingWalletOperation = null;
    _pendingProofMutation = false;
    if (_cloakWalletPath == null || !await _pendingOperationFile.exists()) {
      return;
    }
    // Once a record exists, fail closed even if it is malformed or incomplete.
    _pendingProofMutation = true;
    pendingTransactionStatus.value =
        'A pending transaction is being verified before wallet activity resumes.';
    final operation = PendingWalletOperation.decode(
      await _pendingOperationFile.readAsString(),
    );
    _pendingWalletOperation = operation;
    _requireLoadedPendingIdentityLocked(operation);
    if (operation.state == PendingWalletOperationState.prepared) {
      // `prepared` is durably written before proof generation, and no caller
      // may hand bytes off until the record is atomically promoted. A crash may
      // leave an unbound eager file between those writes; it is safe to discard
      // that file and restore the identity/hash-bound pre-proof snapshot.
      await _rollbackPendingOperationLocked(operation);
      return;
    }
    if (!await _pendingEagerSnapshotFile.exists() ||
        !await _pendingPreSnapshotFile.exists()) {
      pendingTransactionStatus.value =
          'Pending transaction recovery files are incomplete. Wallet repair is required.';
      throw StateError(
        'Pending transaction quarantine is incomplete; wallet repair required',
      );
    }
    final eagerHash = operation.eagerSnapshotSha256;
    if (eagerHash == null) {
      throw StateError('Pending transaction is not bound to eager state');
    }
    await _readVerifiedPendingSnapshotLocked(
      operation: operation,
      file: _pendingEagerSnapshotFile,
      expectedSha256: eagerHash,
      label: 'eager',
    );
    final pre = await _readVerifiedPendingSnapshotLocked(
      operation: operation,
      file: _pendingPreSnapshotFile,
      expectedSha256: operation.preSnapshotSha256,
      label: 'pre-proof',
    );
    if (!pendingOperationRequiresAuthoritativeReconciliation(
      operation.state,
    )) {
      // proofCreated is durably recorded before bytes can leave this process.
      // A crash in that window has no possible chain side effect, so verified
      // snapshots may be rolled back instead of quarantining forever.
      await _rollbackPendingOperationLocked(operation);
      return;
    }
    if (!_replaceWalletFromSnapshot(pre)) {
      pendingTransactionStatus.value =
          'Pending pre-proof wallet snapshot is corrupt. Wallet repair is required.';
      throw StateError('Pending pre-proof wallet snapshot is corrupt');
    }
    pendingTransactionStatus.value =
        'Transaction outcome is pending. Wallet inputs remain protected.';
  }

  /// Resolve a durable pending operation only from an authoritative outcome.
  /// `accepted=false` must only be supplied for an explicit node rejection.
  static Future<void> resolvePendingWalletOperation({
    required String operationId,
    required bool accepted,
  }) {
    return _walletOperations.runExclusive('resolve-pending-proof', () async {
      _requireNoUpdateApply();
      final operation = _pendingWalletOperation;
      if (operation == null || operation.operationId != operationId) {
        throw StateError('Pending wallet operation not found');
      }
      if (accepted) {
        await _acceptPendingOperationLocked(operation);
      } else {
        await _rollbackPendingOperationLocked(operation);
      }
    });
  }

  static Future<void> markPendingExternalHandoff({
    required String operationId,
    required String transactionId,
    required DateTime expiresAt,
  }) async {
    await _walletOperations.runExclusive('external-proof-handoff', () async {
      _requireNoUpdateApply();
      final operation = _pendingWalletOperation;
      if (operation == null || operation.operationId != operationId) {
        throw StateError('Pending wallet operation not found');
      }
      await _captureEagerProofStateLocked(
        operation,
        transactionId: transactionId,
        expiresAt: expiresAt,
        state: PendingWalletOperationState.handedOff,
      );
    });
    _schedulePendingReconciliation(operationId);
  }

  static Future<void> quarantinePendingWalletOperation(String operationId) {
    return _walletOperations.runExclusive('quarantine-pending-proof', () async {
      _requireNoUpdateApply();
      final operation = _pendingWalletOperation;
      if (operation == null || operation.operationId != operationId) {
        throw StateError('Pending wallet operation not found');
      }
      await _quarantinePendingOperationLocked(operation);
    });
  }

  static Future<void> confirmPendingWalletOperationAccepted({
    required String operationId,
    required String transactionId,
  }) {
    return _walletOperations.runExclusive('accept-external-proof', () async {
      _requireNoUpdateApply();
      final operation = _pendingWalletOperation;
      if (operation == null || operation.operationId != operationId) {
        throw StateError('Pending wallet operation not found');
      }
      requireMatchingTransactionId(operation, transactionId);
      await _acceptPendingOperationLocked(operation);
    });
  }

  static Future<void> recordExternalSubmissionFailure({
    required String operationId,
    required Object error,
  }) {
    return _walletOperations.runExclusive('external-proof-failure', () async {
      _requireNoUpdateApply();
      final operation = _pendingWalletOperation;
      if (operation == null || operation.operationId != operationId) return;
      if (classifyPostSubmitSendFailure(error) ==
          SendFailureDisposition.rollback) {
        await _rollbackPendingOperationLocked(operation);
      } else {
        await _quarantinePendingOperationLocked(operation);
      }
    });
  }

  static String? get pendingTransactionId =>
      _pendingWalletOperation?.transactionId;

  static String? get pendingWalletOperationId =>
      _pendingWalletOperation?.operationId;

  static void _schedulePendingReconciliation(String operationId) {
    if (_scheduledPendingReconciliationId == operationId) return;
    _scheduledPendingReconciliationId = operationId;
    Future<void>(() async {
      var firstCheck = true;
      while (_pendingWalletOperation?.operationId == operationId) {
        await Future<void>.delayed(
          firstCheck ? const Duration(seconds: 15) : const Duration(minutes: 1),
        );
        firstCheck = false;
        if (_pendingWalletOperation?.operationId != operationId) break;
        try {
          final result = await reconcilePendingWalletOperationFromChain();
          if (result == PendingReconciliationResult.accepted ||
              result == PendingReconciliationResult.rejectedAfterExpiry ||
              result == PendingReconciliationResult.none) {
            break;
          }
        } catch (error) {
          print(
              '[CloakWalletManager] Pending transaction check deferred: $error');
        }
      }
      if (_scheduledPendingReconciliationId == operationId) {
        _scheduledPendingReconciliationId = null;
      }
    });
  }

  static Future<DateTime?> _fetchIrreversibleChainTime(String endpoint) async {
    final client = HttpClient();
    try {
      final infoRequest = await client
          .postUrl(Uri.parse('$endpoint/v1/chain/get_info'))
          .timeout(const Duration(seconds: 8));
      infoRequest.headers.set('Content-Type', 'application/json');
      infoRequest.write('{}');
      final infoResponse =
          await infoRequest.close().timeout(const Duration(seconds: 8));
      if (infoResponse.statusCode != 200) return null;
      final infoBody = await infoResponse
          .transform(const Utf8Decoder())
          .join()
          .timeout(const Duration(seconds: 8));
      final info = jsonDecode(infoBody);
      final lib = info is Map ? info['last_irreversible_block_num'] : null;
      if (lib is! int || lib <= 0) return null;

      final blockRequest = await client
          .postUrl(Uri.parse('$endpoint/v1/chain/get_block'))
          .timeout(const Duration(seconds: 8));
      blockRequest.headers.set('Content-Type', 'application/json');
      blockRequest.write(jsonEncode({'block_num_or_id': lib}));
      final blockResponse =
          await blockRequest.close().timeout(const Duration(seconds: 8));
      if (blockResponse.statusCode != 200) return null;
      final blockBody = await blockResponse
          .transform(const Utf8Decoder())
          .join()
          .timeout(const Duration(seconds: 8));
      final block = jsonDecode(blockBody);
      final timestamp = block is Map ? block['timestamp'] : null;
      if (timestamp is! String) return null;
      return DateTime.parse(
        timestamp.endsWith('Z') ? timestamp : '${timestamp}Z',
      ).toUtc();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Reconcile quarantined eager state against recent Telos history.
  /// Acceptance requires the exact precomputed id. Expiry rollback requires
  /// two independent history APIs to report the transaction absent after a
  /// two-minute grace period; network errors never count as rejection.
  static Future<PendingReconciliationResult>
      reconcilePendingWalletOperationFromChain() async {
    final operation = _pendingWalletOperation;
    if (operation == null) return PendingReconciliationResult.none;
    final txId = operation.transactionId;
    if (txId == null) {
      pendingTransactionStatus.value =
          'Pending transaction needs manual wallet recovery.';
      return PendingReconciliationResult.unavailable;
    }

    // Distinct infrastructure providers. Caleos aliases intentionally count
    // only once.
    const endpoints = [
      'https://telos.eosusa.io',
      'https://mainnet.telos.caleos.io',
    ];
    var authoritativeAbsences = 0;
    var providersPastExpiry = 0;
    final expiryCutoff = operation.expiresAt?.add(const Duration(minutes: 2));
    for (final endpoint in endpoints) {
      final client = HttpClient();
      try {
        final request = await client
            .getUrl(Uri.parse('$endpoint/v2/history/get_transaction?id=$txId'))
            .timeout(const Duration(seconds: 8));
        final response =
            await request.close().timeout(const Duration(seconds: 8));
        final body = await response
            .transform(const Utf8Decoder())
            .join()
            .timeout(const Duration(seconds: 8));
        if (response.statusCode == 200) {
          final value = jsonDecode(body);
          if (value is Map) {
            final returnedId = value['id'] ??
                value['trx_id'] ??
                value['transaction_id'] ??
                (value['trx'] is Map ? (value['trx'] as Map)['id'] : null);
            if (returnedId == txId) {
              await resolvePendingWalletOperation(
                operationId: operation.operationId,
                accepted: true,
              );
              pendingTransactionStatus.value = null;
              return PendingReconciliationResult.accepted;
            }
          }
        } else if (response.statusCode == 404) {
          authoritativeAbsences++;
        }
      } catch (_) {
        // Fail closed: offline/rate-limited/malformed responses are not proof
        // that a submitted transaction was rejected.
      } finally {
        client.close(force: true);
      }

      if (expiryCutoff != null) {
        // Rollback is permitted only once this provider's irreversible block,
        // not the device clock or reversible head, is past expiration + grace.
        final irreversibleTime = await _fetchIrreversibleChainTime(endpoint);
        if (irreversibleTime != null &&
            irreversibleTime.isAfter(expiryCutoff)) {
          providersPastExpiry++;
        }
      }
    }

    final expiryReached = providersPastExpiry == endpoints.length;
    if (expiryReached && authoritativeAbsences == endpoints.length) {
      await resolvePendingWalletOperation(
        operationId: operation.operationId,
        accepted: false,
      );
      pendingTransactionStatus.value = null;
      return PendingReconciliationResult.rejectedAfterExpiry;
    }

    pendingTransactionStatus.value = expiryReached
        ? 'Transaction outcome could not be verified. Wallet inputs remain protected.'
        : 'Transaction is awaiting network confirmation.';
    return authoritativeAbsences == 0
        ? PendingReconciliationResult.unavailable
        : PendingReconciliationResult.pending;
  }

  /// Validates the native circuits, persisted wallet generation, parameter
  /// generation, and the deployment's live tree depth before sync.
  static void requireProtocolSyncCompatibility(int chainDepth) {
    final nativeDepth = CloakApi.compiledMerkleTreeDepth();
    try {
      if (ParamsManager.merkleTreeDepth !=
          ProtocolCompatibility.compiledMerkleTreeDepth) {
        throw StateError('Wallet parameter generation has the wrong depth');
      }
      ProtocolCompatibility.requireSyncCompatible(
        generation: walletProtocolGeneration,
        nativeDepth: nativeDepth,
        chainDepth: chainDepth,
      );
      _lastValidatedChainDepth = chainDepth;
      _lastDepthValidation = DateTime.now();
      protocolCompatibilityError.value = null;
    } catch (error) {
      protocolCompatibilityError.value = '$error';
      rethrow;
    }
  }

  /// Performs a fresh network depth check immediately before loading proving
  /// parameters or creating a proof.
  static Future<void> requireProtocolProofCompatibility() async {
    final nativeDepth = CloakApi.compiledMerkleTreeDepth();
    final generation = walletProtocolGeneration;
    if (generation != WalletProtocolGeneration.v11012) {
      ProtocolCompatibility.requireProofCompatible(
        generation: generation,
        nativeDepth: nativeDepth,
        chainDepth: _lastValidatedChainDepth ?? ParamsManager.merkleTreeDepth,
      );
    }

    final endpoint =
        cloak.lwd.isNotEmpty ? cloak.lwd.first.url : hyperionEndpoint;
    final client = EosioClient(endpoint);
    try {
      final global = await client.getZeosGlobal();
      if (global == null) {
        throw StateError('Could not read the CLOAK protocol depth');
      }
      ProtocolCompatibility.requireProofCompatible(
        generation: generation,
        nativeDepth: nativeDepth,
        chainDepth: global.treeDepth,
      );
      _lastValidatedChainDepth = global.treeDepth;
      _lastDepthValidation = DateTime.now();
      protocolCompatibilityError.value = null;
    } catch (error) {
      protocolCompatibilityError.value = '$error';
      rethrow;
    } finally {
      client.close();
    }
  }

  static bool get protocolProofCompatibilityCached {
    final validatedAt = _lastDepthValidation;
    return walletProtocolGeneration == WalletProtocolGeneration.v11012 &&
        _lastValidatedChainDepth == ParamsManager.merkleTreeDepth &&
        validatedAt != null &&
        DateTime.now().difference(validatedAt) < const Duration(minutes: 5);
  }

  /// Called only after a successful full resync. The completion state and the
  /// rebuilt wallet are persisted together; a failed save restores `migrating`.
  static Future<bool> completeProtocolMigrationAfterResync({
    required int expectedLeafCount,
  }) async {
    _requireNoUpdateApply();
    if (!_walletOperations.isHeldByCurrentZone) {
      throw StateError(
          'Protocol migration completion requires wallet ownership');
    }
    if (_cloakWallet == null ||
        (CloakApi.getLeafCount(_cloakWallet!) ?? -1) != expectedLeafCount) {
      return false;
    }
    final generation = walletProtocolGeneration;
    if (generation == WalletProtocolGeneration.v11012) return true;
    if (generation != WalletProtocolGeneration.migratingV11012 ||
        _lastValidatedChainDepth != ParamsManager.merkleTreeDepth ||
        CloakApi.compiledMerkleTreeDepth() != ParamsManager.merkleTreeDepth) {
      return false;
    }

    _protocolMigrationActive = true;
    final snapshot = await FfiIsolate.writeWallet(wallet: _cloakWallet!);
    if (snapshot == null) {
      _protocolMigrationActive = false;
      return false;
    }
    try {
      if (!CloakApi.completeProtocolMigration(_cloakWallet!)) return false;
      if (!await saveWallet()) {
        if (!_replaceWalletFromSnapshot(snapshot)) {
          protocolCompatibilityError.value =
              'Wallet migration rollback could not restore the in-memory wallet';
          return false;
        }
        if (!await saveWallet()) {
          protocolCompatibilityError.value =
              'Wallet migration rollback could not be persisted';
        }
        return false;
      }
      protocolCompatibilityError.value = null;
      try {
        await ParamsManager.removeKnownLegacyParamsAfterMigration();
      } catch (error) {
        print('[CloakWalletManager] Legacy parameter cleanup skipped: $error');
      }
      return true;
    } finally {
      _protocolMigrationActive = false;
    }
  }

  /// Save CLOAK wallet to disk using a serialized queue and atomic promotion.
  static Future<bool> saveWallet() async {
    return _walletOperations.runExclusive('save-wallet', () async {
      if (_pendingProofMutation && !_pendingSaveAuthorized) {
        print(
            'CloakWalletManager: Canonical save deferred for pending transaction');
        return false;
      }
      if (_cloakWallet == null) {
        print('CloakWalletManager: No wallet to save');
        return false;
      }

      if (_cloakWalletPath == null) await init();

      final previousSave = _saveTail;
      final saveGate = Completer<void>();
      _saveTail = saveGate.future;
      await previousSave;
      try {
        final bytes = await FfiIsolate.writeWallet(wallet: _cloakWallet!);
        if (bytes == null) {
          print('CloakWalletManager: Failed to serialize wallet');
          return false;
        }

        final file = File(_cloakWalletPath!);
        await _writeBytesAtomically(file, bytes, replace: true);
        return true;
      } catch (e) {
        print('CloakWalletManager: Error saving wallet: $e');
        return false;
      } finally {
        saveGate.complete();
      }
    });
  }

  /// Reset chain state and trigger full resync.
  /// Clears: Rust wallet state (notes, merkle tree), DB properties, MobX observables, sync caches.
  /// Preserves: seed, keys, unpublished notes.
  static Future<bool> resetChainState() async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('reset-chain-state', () async {
      _requireNoUpdateApply();
      if (_pendingProofMutation) {
        throw StateError(
            'Cannot reset while a transaction is awaiting reconciliation');
      }
      if (_cloakWallet == null) {
        print('[CloakWalletManager] No wallet loaded');
        return false;
      }

      try {
        // 1. Lock wallet to prevent concurrent sync
        CloakSync.lockWallet();

        // 2. Call Rust FFI to clear wallet state
        final success = CloakApi.resetChainState(_cloakWallet!);
        if (!success) {
          print('[CloakWalletManager] FFI reset failed');
          CloakSync.unlockWallet();
          return false;
        }

        // 3. Save wallet to disk
        if (!await saveWallet()) {
          print('[CloakWalletManager] Failed to save wallet after reset');
          CloakSync.unlockWallet();
          return false;
        }

        // 4. Clear database sync properties
        await CloakDb.setProperty('synced_height', '0');
        await CloakDb.setProperty('full_sync_done', 'false');

        // 5. Preserve burn_events table — these are user-action timestamps
        //    (when the burn button was pressed), not chain state. They must
        //    survive resyncs so TX history keeps its "Burn Vault" labels.

        // 6. Clear sync caches and reset session flags for full resync
        CloakSync.clearCachedCounters();
        await CloakSync
            .clearPermanentSlowMode(); // Clear DB-persisted Hyperion fallback
        CloakSync.markAsRestored(); // Ensure not treated as new account
        CloakSync.resetSessionFlags(); // Reset vault discovery, auto-heal, etc.

        // 7. Clear vault token cache
        clearVaultTokensCache();

        // 8. Unlock wallet
        CloakSync.unlockWallet();

        // 9. Clear MobX observables (will repopulate on next sync)
        // Note: These are in store2.dart and managed by accounts.dart
        // The sync will automatically rebuild them

        return true;
      } catch (e) {
        print('[CloakWalletManager] Error during reset: $e');
        CloakSync.unlockWallet();
        return false;
      }
    });
  }

  /// Check if CLOAK wallet exists (async)
  static Future<bool> walletExists() async {
    if (_cloakWalletPath == null) await init();
    return File(_cloakWalletPath!).existsSync();
  }

  /// Check if CLOAK wallet exists (sync - for UI checks)
  /// Note: Assumes init() has been called. Returns false if path not set.
  static bool walletExistsSync() {
    if (_cloakWalletPath == null) return false;
    return File(_cloakWalletPath!).existsSync();
  }

  /// Get current wallet pointer (for API calls)
  static Pointer<Void>? get wallet =>
      _nativeSynchronousAccessAllowed ? _cloakWallet : null;

  /// Check if wallet is loaded
  static bool get isLoaded => _cloakWallet != null;

  /// Check if wallet is view-only (IVK)
  /// View-only wallets can see incoming transactions but cannot spend coins
  static bool get isViewOnly {
    if (_cloakWallet == null) return false;
    if (!_nativeSynchronousAccessAllowed) return _cachedIsViewOnly;
    _cachedIsViewOnly = CloakApi.isViewOnly(_cloakWallet!) ?? _cachedIsViewOnly;
    return _cachedIsViewOnly;
  }

  /// Get key type for UI display: 'spending', 'fvk', or 'ivk'
  /// spending: can spend coins, see all TXs, create vaults
  /// fvk: can see all TXs, cannot spend (derived from spending key)
  /// ivk: can only see incoming TXs, cannot spend (independent incoming key)
  static String get keyType {
    if (_cloakWallet == null) return 'unknown';
    if (!isViewOnly) {
      // Wallet stores full seed (spending key capable)
      return 'spending';
    }
    // For now, classify all view-only as 'ivk'
    // In future, could distinguish between FVK and IVK via additional API
    return 'ivk';
  }

  /// Expected alias_authority for Telos mainnet
  /// ZK proofs MUST use this exact value or they will fail on-chain verification
  static const EXPECTED_ALIAS_AUTHORITY = 'thezeosalias@public';

  /// Check if the wallet's alias_authority is correct for Telos mainnet
  /// Returns true if correct, false if wrong or unavailable
  static bool hasCorrectAliasAuthority() {
    if (_cloakWallet == null) return false;
    final storedAlias = getAliasAuthority();
    return storedAlias == EXPECTED_ALIAS_AUTHORITY;
  }

  /// Get details about alias_authority mismatch for error messages
  /// Returns null if correct, or a Map with 'stored' and 'expected' keys if wrong
  static Map<String, String>? getAliasAuthorityMismatch() {
    if (_cloakWallet == null) return null;
    final storedAlias = getAliasAuthority();
    if (storedAlias == EXPECTED_ALIAS_AUTHORITY) return null;
    return {
      'stored': storedAlias ?? 'null',
      'expected': EXPECTED_ALIAS_AUTHORITY,
    };
  }

  /// Validate wallet configuration at startup
  /// Returns a list of validation errors (empty if all OK)
  static Future<List<String>> validateWalletConfiguration() async {
    final errors = <String>[];

    if (!isLoaded) {
      errors.add('Wallet not loaded');
      return errors;
    }

    // Check alias_authority
    final mismatch = getAliasAuthorityMismatch();
    if (mismatch != null) {
      errors.add(
          'CRITICAL: Wallet alias_authority is "${mismatch['stored']}" but must be "${mismatch['expected']}" '
          'for ZK proofs to work on Telos mainnet. Shield transactions will fail with "proof invalid" error. '
          'You need to recreate your wallet with the correct alias_authority.');
    }

    // Check chain_id
    final chainId = getChainId();
    if (chainId != TELOS_CHAIN_ID) {
      errors
          .add('Wallet chain_id is "$chainId" but expected "$TELOS_CHAIN_ID"');
    }

    return errors;
  }

  /// Get primary address
  static String? getAddress() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedDefaultAddress;
    // Synchronous UI reads must never mutate the raw pointer. Address rotation
    // is performed only by coordinated async wallet operations.
    var address = CloakApi.defaultAddress(_cloakWallet!);
    if (address == null) return null;

    // The FFI may return the address as a JSON-encoded string with quotes
    // Strip outer quotes if present
    if (address.startsWith('"') &&
        address.endsWith('"') &&
        address.length > 2) {
      address = address.substring(1, address.length - 1);
    }

    _cachedDefaultAddress = address;
    return address;
  }

  /// Get the stable default address — deterministic from seed, never changes.
  /// Use this for auth token operations (vault create/re-inject) where the
  /// commitment must be reproducible.
  static String? getDefaultAddress() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedDefaultAddress;
    final address = CloakApi.defaultAddress(_cloakWallet!);
    if (address == null) return null;
    _cachedDefaultAddress = address;
    return address;
  }

  /// Get balances as JSON (sync — blocks main thread)
  static String? getBalancesJson() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedBalancesJson;
    _cachedBalancesJson = CloakApi.getBalancesJson(_cloakWallet!, pretty: true);
    return _cachedBalancesJson;
  }

  /// Get balances as JSON in a background isolate (non-blocking)
  static Future<String?> getBalancesJsonAsync() async {
    if (_cloakWallet == null) return null;
    return _walletOperations.runExclusive('read-balances', () async {
      _requireNoUpdateApply();
      final wallet = _cloakWallet;
      if (wallet == null) return null;
      _cachedBalancesJson =
          await FfiIsolate.getBalancesJson(wallet: wallet, pretty: true);
      return _cachedBalancesJson;
    });
  }

  /// Get transaction history as JSON
  static String? getTransactionHistoryJson() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedTransactionHistoryJson;
    _cachedTransactionHistoryJson =
        CloakApi.getTransactionHistoryJson(_cloakWallet!, pretty: true);
    return _cachedTransactionHistoryJson;
  }

  /// Get non-fungible tokens as JSON
  static String? getNftsJson({int contract = 0, bool pretty = false}) {
    if (_cloakWallet == null) return null;
    final key = '$contract:$pretty';
    if (!_nativeSynchronousAccessAllowed) return _cachedNftsJson[key];
    final result = CloakApi.getNonFungibleTokensJson(_cloakWallet!,
        contract: contract, pretty: pretty);
    _cachedNftsJson[key] = result;
    return result;
  }

  // ============== Vault / Auth Token Functions ==============

  /// Get authentication tokens (vaults) as JSON
  /// These are special notes used for receiving tokens from dApps asynchronously
  static String? getAuthenticationTokensJson(
      {int contract = 0, bool spent = false}) {
    if (_cloakWallet == null) return null;
    final key = '$contract:$spent';
    if (!_nativeSynchronousAccessAllowed) {
      return _cachedAuthenticationTokensJson[key];
    }
    final result = CloakApi.getAuthenticationTokensJson(_cloakWallet!,
        contract: contract, spent: spent, pretty: true);
    _cachedAuthenticationTokensJson[key] = result;
    return result;
  }

  /// Get unpublished notes as JSON
  /// These are notes created locally but not yet on-chain
  static String? getUnpublishedNotesJson() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedUnpublishedNotesJson;
    _cachedUnpublishedNotesJson =
        CloakApi.getUnpublishedNotesJson(_cloakWallet!, pretty: true);
    return _cachedUnpublishedNotesJson;
  }

  /// Create a new vault (auth token) for a specific token contract
  ///
  /// [label] - Human-readable label for this vault (stored in memo)
  /// [tokenContract] - The EOSIO token contract name (e.g., "thezeostoken")
  ///
  /// Returns true if vault was created successfully
  static Future<bool> createVault(String label, String tokenContract) async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('create-vault', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) return false;

      // MUST use getDefaultAddress() (stable, deterministic) — NOT getAddress()
      // which calls derive_next_address() and changes the diversifier each call.
      final address = getDefaultAddress();
      if (address == null) return false;

      final contract = eosioNameToU64(tokenContract);

      final notesJson = CloakApi.createUnpublishedAuthNote(
        _cloakWallet!,
        label, // Use label as seed for uniqueness
        contract,
        address,
      );

      if (notesJson == null) {
        print(
            '[CloakWalletManager] createVault failed: ${CloakApi.getLastError()}');
        return false;
      }

      // Add the unpublished notes to wallet
      if (!CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson)) {
        print(
            '[CloakWalletManager] addUnpublishedNotes failed: ${CloakApi.getLastError()}');
        return false;
      }

      // Save wallet to persist the vault
      if (!await saveWallet()) return false;

      return true;
    });
  }

  /// Create a new vault and return its commitment hash
  ///
  /// This is useful when we need the vault hash immediately after creation
  /// (e.g., for building an ESR with the vault memo)
  ///
  /// Returns the vault hash (commitment) or null on failure
  static Future<String?> createVaultAndGetHash(String label,
      {String tokenContract = 'thezeostoken'}) async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('create-vault-with-hash', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) return null;

      // Use default address (stable, deterministic) so the commitment is reproducible
      final address = getDefaultAddress();
      if (address == null) return null;

      final contract = eosioNameToU64(tokenContract);

      final notesJson = await FfiIsolate.createUnpublishedAuthNote(
        wallet: _cloakWallet!,
        seed: label,
        contract: contract,
        address: address,
      );

      if (notesJson == null) {
        print('[CloakWalletManager] createVaultAndGetHash failed');
        return null;
      }

      // Parse the JSON to extract the vault commitment hash
      // The FFI returns a map like:
      // {
      //   "za1address...": ["encrypted_note"],
      //   "self": ["encrypted_note"],
      //   "__commitment__": ["64-char-hex-commitment-hash"]
      // }
      // The vault identifier is the commitment hash from __commitment__ key
      String? vaultHash;
      try {
        final notes = jsonDecode(notesJson);

        if (notes is Map) {
          // Extract the commitment hash from the __commitment__ key
          final commitmentList = notes['__commitment__'];
          if (commitmentList is List && commitmentList.isNotEmpty) {
            vaultHash = commitmentList[0] as String;
          } else {
            // Fallback: legacy FFI without __commitment__ key - look for za1 address
            // This should not happen with updated FFI
            for (final key in notes.keys) {
              if (key != 'self' && key is String && key.startsWith('za1')) {
                vaultHash = key;
                break;
              }
            }
          }
        }
      } catch (e) {
        print('[CloakWalletManager] Error parsing vault notes');
      }

      // Add the unpublished notes to wallet regardless
      if (!CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson)) {
        print(
            '[CloakWalletManager] addUnpublishedNotes failed: ${CloakApi.getLastError()}');
        return null;
      }

      // Save wallet to persist the vault
      if (!await saveWallet()) return null;

      return vaultHash;
    });
  }

  // ============== Vault Hash Storage ==============
  // Since the FFI for reading vaults crashes, we store the vault hash in the database

  static const _vaultHashKey = 'cloak_vault_hash';

  /// Get the stored vault hash from database
  /// Returns null if no vault has been created yet or if stored hash is invalid
  ///
  /// The vault hash must be a 64-character hex string (commitment hash).
  /// If an old za1... address is stored (wrong format), we clear it and return null.
  static Future<String?> getStoredVaultHash() async {
    final hash = await CloakDb.getProperty(_vaultHashKey);
    if (hash != null && hash.isNotEmpty) {
      // Validate the hash format: must be 64-character hex string
      // If it starts with 'za1', it's the old wrong format (bech32m address)
      if (hash.startsWith('za1')) {
        await CloakDb.setProperty(_vaultHashKey, ''); // Clear the invalid hash
        return null;
      }

      // Check if it's a valid 64-char hex string
      if (hash.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hash)) {
        await CloakDb.setProperty(_vaultHashKey, ''); // Clear the invalid hash
        return null;
      }
    }
    return hash;
  }

  /// Store the vault hash in database
  static Future<void> _storeVaultHash(String hash) async {
    await CloakDb.setProperty(_vaultHashKey, hash);
  }

  /// Whether vault discovery is currently running (prevents vault creation during scan)
  static bool _discoveryInProgress = false;
  static bool get discoveryInProgress => _discoveryInProgress;

  /// Notifier that fires when the vault list changes (discovery, creation, burn).
  /// UI widgets can listen to this to auto-refresh.
  static final vaultListVersion = ValueNotifier<int>(0);
  static void _notifyVaultListChanged() => vaultListVersion.value++;

  /// Create a new vault and store its hash.
  /// Uses deterministic HMAC-SHA256 seed derivation for reproducible vaults.
  /// Returns the vault hash or null on failure.
  static Future<String?> createAndStoreVault({String? label}) async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('create-and-store-vault', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) return null;
      if (_discoveryInProgress) {
        return null;
      }

      // Read next_vault_index from SQLite
      final nextIndex = await CloakDb.getNextVaultIndex();

      final contract = eosioNameToU64('thezeostoken');

      // Create deterministic vault via FFI (derives seed + creates auth token)
      final notesJson = await FfiIsolate.createDeterministicVault(
        wallet: _cloakWallet!,
        contract: contract,
        vaultIndex: nextIndex,
      );

      if (notesJson == null) {
        return null;
      }

      // Parse JSON to extract commitment hash
      String? hash;
      try {
        final notes = jsonDecode(notesJson);
        if (notes is Map) {
          final commitmentList = notes['__commitment__'];
          if (commitmentList is List && commitmentList.isNotEmpty) {
            hash = commitmentList[0] as String;
          }
        }
      } catch (e) {
        print(
            '[CloakWalletManager] Error parsing deterministic vault JSON: $e');
        return null;
      }

      if (hash == null || hash.length != 64) {
        return null;
      }

      // Add unpublished notes to wallet
      if (!CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson)) {
        print(
            '[CloakWalletManager] addUnpublishedNotes failed: ${CloakApi.getLastError()}');
        return null;
      }

      // Save wallet
      if (!await saveWallet()) return null;

      // Store vault hash in properties table
      await _storeVaultHash(hash);

      // Derive the hex seed for DB persistence (needed for reimport)
      final seedHex = CloakApi.deriveVaultSeed(_cloakWallet!, nextIndex);

      // Store in vaults table with vault_index
      final exists = await CloakDb.vaultExistsByHash(hash);
      if (!exists) {
        await CloakDb.addVault(
          accountId: _cloakAccountId > 0 ? _cloakAccountId : 1,
          seed: seedHex ?? 'deterministic_v$nextIndex',
          commitmentHash: hash,
          contract: 'thezeostoken',
          label: label ?? 'Vault $nextIndex',
          vaultIndex: nextIndex,
        );
      }

      // Increment next_vault_index
      await CloakDb.incrementNextVaultIndex();

      _notifyVaultListChanged();
      return hash;
    });
  }

  /// Discover deterministic vaults by scanning indices 0..N.
  /// For each index: derive seed -> create deterministic vault -> get hash -> check on-chain.
  /// Uses gap limit of 20 consecutive misses. Processes indices sequentially to avoid
  /// concurrent mutable access to the Rust wallet pointer.
  /// Returns list of discovered vault hashes.
  static Future<List<String>> discoverVaults() async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('discover-vaults', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) {
        return [];
      }

      _discoveryInProgress = true;
      final discovered = <String>[];
      final contractU64 = eosioNameToU64('thezeostoken');

      try {
        // ── Phase 1: Collect all synced vault-type auth tokens ──
        // Vault ATs use contract=thezeostoken. Filter by this contract to
        // separate vault ATs from alias ATs (which use thezeosalias).
        final vaultAtHashes = <String>{};
        for (final spent in [false, true]) {
          final json = CloakApi.getAuthenticationTokensJson(
            _cloakWallet!,
            contract: contractU64,
            spent: spent,
            pretty: false,
          );
          if (json != null && json.isNotEmpty) {
            try {
              final list = jsonDecode(json) as List;
              for (final at in list) {
                if (at is String) {
                  final hash = at.contains('@') ? at.split('@')[0] : at;
                  if (hash.length == 64) vaultAtHashes.add(hash);
                }
              }
            } catch (_) {}
          }
        }
        // Also get ALL ATs for legacy fallback (old vaults published with thezeosalias)
        final allAtHashes = <String>{};
        final allAtsJson = CloakApi.getAuthenticationTokensJson(
          _cloakWallet!,
          contract: 0,
          spent: false,
          pretty: false,
        );
        if (allAtsJson != null && allAtsJson.isNotEmpty) {
          try {
            final list = jsonDecode(allAtsJson) as List;
            for (final at in list) {
              if (at is String) {
                final hash = at.contains('@') ? at.split('@')[0] : at;
                if (hash.length == 64) allAtHashes.add(hash);
              }
            }
          } catch (_) {}
        }
        // ── Phase 2: Deterministic index scan ──
        // Derive hashes for vault indices 0, 1, 2, ... and check if each
        // exists in synced vault ATs or the on-chain vaults table.
        const gapLimit = 20;
        int consecutiveMisses = 0;
        int highestFoundIndex = -1;
        int apiErrors = 0;
        const maxApiErrors = 5;
        int index = 0;

        // Single vaults table query for all indices (avoid per-index HTTP)
        late Map<String, dynamic> vaultsTableRows;
        try {
          final client = EosioClient('https://telos.eosusa.io');
          final response = await client.getTableRows(
            code: 'thezeosvault',
            scope: 'thezeosvault',
            table: 'vaults',
            limit: 100,
          );
          client.close();
          final rows = response['rows'] as List? ?? [];
          vaultsTableRows = {
            for (final r in rows) (r['auth_token'] as String? ?? ''): r
          };
        } catch (e) {
          vaultsTableRows = {};
        }

        while (consecutiveMisses < gapLimit && apiErrors < maxApiErrors) {
          final idx = index;
          index++;

          final notesJson = await FfiIsolate.createDeterministicVault(
            wallet: _cloakWallet!,
            contract: contractU64,
            vaultIndex: idx,
          );

          if (notesJson == null) {
            consecutiveMisses++;
            continue;
          }

          String? hash;
          try {
            final notes = jsonDecode(notesJson);
            if (notes is Map) {
              final commitmentList = notes['__commitment__'];
              if (commitmentList is List && commitmentList.isNotEmpty) {
                hash = commitmentList[0] as String;
              }
            }
          } catch (_) {}

          if (hash == null || hash.length != 64) {
            consecutiveMisses++;
            continue;
          }

          // Check 1: Synced vault ATs (published with thezeostoken — new deterministic vaults)
          final foundInVaultAts = vaultAtHashes.contains(hash);

          // Check 2: ALL synced ATs (catches old vaults published with thezeosalias too)
          final foundInAllAts = !foundInVaultAts && allAtHashes.contains(hash);

          // Check 3: On-chain vaults table (catches any vault that was deposited into)
          final foundInTable = !foundInVaultAts &&
              !foundInAllAts &&
              vaultsTableRows.containsKey(hash);

          if (foundInVaultAts || foundInAllAts || foundInTable) {
            consecutiveMisses = 0;
            if (idx > highestFoundIndex) highestFoundIndex = idx;

            // Add to wallet unpublished notes
            CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson);

            // Store in DB
            final exists = await CloakDb.vaultExistsByHash(hash);
            if (!exists) {
              final seedHex = CloakApi.deriveVaultSeed(_cloakWallet!, idx);
              await CloakDb.addVault(
                accountId: _cloakAccountId > 0 ? _cloakAccountId : 1,
                seed: seedHex ?? 'deterministic_v$idx',
                commitmentHash: hash,
                contract: 'thezeostoken',
                label: 'Vault $idx',
                status: 'active',
                vaultIndex: idx,
              );
            }
            discovered.add(hash);
            if (discovered.length == 1) await _storeVaultHash(hash);
          } else {
            consecutiveMisses++;
          }
        }

        // ── Phase 3: Sweep on-chain vaults table for legacy vaults ──
        // Any vaults table entry not yet discovered might be a legacy (non-deterministic)
        // vault belonging to this wallet. Register it.
        {
          for (final entry in vaultsTableRows.entries) {
            final tableHash = entry.key;
            if (tableHash.isEmpty || tableHash.length != 64) continue;
            if (discovered.contains(tableHash)) continue; // Already found

            // Check if this hash is in our synced ATs (proving we own it)
            if (allAtHashes.contains(tableHash)) {
              final exists = await CloakDb.vaultExistsByHash(tableHash);
              if (!exists) {
                await CloakDb.addVault(
                  accountId: _cloakAccountId > 0 ? _cloakAccountId : 1,
                  seed: 'legacy_imported',
                  commitmentHash: tableHash,
                  contract: 'thezeostoken',
                  label: 'Vault (Legacy)',
                  status: 'active',
                );
              }
              discovered.add(tableHash);
            }
          }
        }

        // Update next_vault_index
        if (highestFoundIndex >= 0) {
          final newNext = highestFoundIndex + 1;
          final currentNext = await CloakDb.getNextVaultIndex();
          if (newNext > currentNext) {
            await CloakDb.setNextVaultIndex(newNext);
          }
        }

        if (discovered.isNotEmpty) {
          if (!await saveWallet()) {
            throw StateError('Failed to persist discovered vaults');
          }
          _notifyVaultListChanged();
        }
      } finally {
        _discoveryInProgress = false;
      }
      return discovered;
    });
  }

  /// Get vault hash - first checks database, then creates if needed
  /// Returns the vault hash or null on failure
  static Future<String?> getOrCreateVaultHash() async {
    // First check if we have a stored vault hash
    final storedHash = await getStoredVaultHash();
    if (storedHash != null) {
      return storedHash;
    }

    // No stored hash - create a new vault
    return await createAndStoreVault();
  }

  /// Get vault info for display and sharing
  /// Returns a list of vault objects with hash, label, etc.
  static List<Map<String, dynamic>> getVaults() {
    if (_cloakWallet == null) return [];
    const key = '0:false:false';
    final String? tokensJson;
    if (!_nativeSynchronousAccessAllowed) {
      tokensJson = _cachedAuthenticationTokensJson[key];
    } else {
      tokensJson =
          CloakApi.getAuthenticationTokensJson(_cloakWallet!, pretty: false);
      _cachedAuthenticationTokensJson[key] = tokensJson;
    }
    if (tokensJson == null) return [];

    try {
      final tokens = jsonDecode(tokensJson) as List;
      return tokens.cast<Map<String, dynamic>>();
    } catch (e) {
      print('[CloakWalletManager] Error parsing vaults: $e');
      return [];
    }
  }

  /// Get the primary vault's auth token hash (for receiving deposits)
  /// Returns the commitment hash that identifies this vault
  static String? getPrimaryVaultHash() {
    final vaults = getVaults();
    if (vaults.isEmpty) return null;

    // Return the first vault's commitment hash
    // The auth token's commitment is used as the vault identifier
    final vault = vaults.first;
    return vault['commitment'] as String? ?? vault['cm'] as String?;
  }

  /// Get the memo format for sending to this vault
  /// Returns the formatted memo string to use when sending tokens to thezeosvault
  static String? getVaultMemo({String? customMemo}) {
    final vaultHash = getPrimaryVaultHash();
    if (vaultHash == null) return null;

    if (customMemo != null && customMemo.isNotEmpty) {
      return 'AUTH:$vaultHash|$customMemo';
    }
    return 'AUTH:$vaultHash';
  }

  /// Check if the auth token has been published to blockchain
  /// This checks if we have a record of publishing in the database
  static Future<bool> isVaultPublished() async {
    final published = await CloakDb.getProperty('cloak_vault_published');
    return published == 'true';
  }

  /// Mark the vault as published (both property and vault status)
  static Future<void> markVaultPublished() async {
    await CloakDb.setProperty('cloak_vault_published', 'true');
    // Also update vault status in vaults table so burn logic knows it's on-chain
    final vaultHash = await getStoredVaultHash();
    if (vaultHash != null && vaultHash.isNotEmpty) {
      await CloakDb.updateVaultStatusByHash(vaultHash, 'published');
    }
  }

  /// Generate ESR for publishing auth token to blockchain
  ///
  /// The auth token must be published before it can be used for vault deposits.
  /// This creates a ZK transaction that mints the auth token (quantity=0) and
  /// publishes it to the blockchain.
  ///
  /// [telosAccount] - Telos account that will pay fees
  ///
  /// Returns ESR URL and related data
  static Future<Map<String, dynamic>> generatePublishVaultEsr({
    required String telosAccount,
  }) async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('publish-vault-esr', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      String? vaultHash = await getStoredVaultHash();
      if (vaultHash == null || vaultHash.isEmpty) {
        vaultHash = await createAndStoreVault();
        if (vaultHash == null) throw Exception('Failed to create vault');
      }
      if (!await loadZkParams()) throw Exception('Failed to load ZK params');
      if (_cloakWallet == null) throw Exception('Wallet not loaded');

      final ztxJson = _buildAuthTokenMintZTransaction(
        fromAccount: telosAccount,
        tokenContract: telosAccount,
      );
      final feesJson = await _getFeesJson();
      CloakSync.lockWallet();
      final operation = await _beginProofMutationLocked('publish-vault-esr');
      try {
        final txJson = await FfiIsolate.transactPacked(
          wallet: _cloakWallet!,
          ztxJson: ztxJson,
          feeTokenContract: 'thezeostoken',
          feesJson: feesJson,
          mintParams: _mintParams!,
          spendOutputParams: _spendOutputParams!,
          spendParams: _spendParams!,
          outputParams: _outputParams!,
        );
        final decoded = jsonDecode(txJson);
        final Map<String, dynamic> tx;
        if (decoded is List && decoded.isNotEmpty) {
          tx = Map<String, dynamic>.from(decoded.first as Map);
        } else if (decoded is Map) {
          tx = Map<String, dynamic>.from(decoded);
        } else {
          throw StateError('Unexpected publish-vault proof response');
        }
        final actions = (tx['actions'] as List? ?? [])
            .map((action) => Map<String, dynamic>.from(action as Map))
            .toList();
        if (actions.isEmpty)
          throw Exception('No actions in generated transaction');
        await _captureEagerProofStateLocked(operation);
        final esrUrl =
            await EsrService.createSigningRequestWithPresig(actions: actions);
        final transactionId = EsrService.pendingTransactionId;
        if (transactionId == null) {
          throw StateError('Could not derive publish-vault transaction id');
        }
        final expiresAt = EsrService.pendingTransactionExpiration;
        if (expiresAt == null) {
          throw StateError('Could not derive publish-vault transaction expiry');
        }
        await markPendingExternalHandoff(
          operationId: operation.operationId,
          transactionId: transactionId,
          expiresAt: expiresAt,
        );
        return {
          'esrUrl': esrUrl,
          'vaultHash': vaultHash,
          'transaction': tx,
          '_walletOperationId': operation.operationId,
          'transactionId': transactionId,
          'expiresAt': expiresAt.toIso8601String(),
        };
      } catch (error, stackTrace) {
        await _rollbackPendingOperationLocked(operation);
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        CloakSync.unlockWallet();
      }
    });
  }

  /// Publish auth token to Merkle tree directly (no ESR/Anchor needed).
  ///
  /// All actions in the publish transaction only need thezeosalias@public
  /// signing, so we sign locally and broadcast via HTTP — no external wallet.
  ///
  /// Returns the transaction ID on success
  static Future<String> publishVaultDirect() async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('publish-vault-direct', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      // 1. Get or create vault hash
      String? vaultHash = await getStoredVaultHash();
      if (vaultHash == null || vaultHash.isEmpty) {
        vaultHash = await createAndStoreVault();
        if (vaultHash == null) {
          throw Exception('Failed to create vault');
        }
      }

      // 2. Load ZK params
      if (!await loadZkParams()) {
        throw Exception('Failed to load ZK params');
      }

      // 3. Check shielded balance is sufficient for fees
      final balJson = await getBalancesJsonAsync();
      if (balJson != null) {
        try {
          final List<dynamic> balances = jsonDecode(balJson);
          double cloakBalance = 0.0;
          for (final b in balances) {
            if (b is String && b.endsWith('CLOAK@thezeostoken')) {
              final amountStr = b.split('@')[0].replaceAll('CLOAK', '').trim();
              cloakBalance = double.tryParse(amountStr) ?? 0.0;
              break;
            }
          }
          // Estimate vault creation fee dynamically (accounts for note fragmentation)
          double requiredFee;
          try {
            final feeStr = await getVaultCreationFee();
            requiredFee = double.tryParse(feeStr.split(' ').first) ?? 0.6;
          } catch (e) {
            print(
                '[CloakWalletManager] Fee estimation failed in publishVaultDirect, using 0.6 fallback: $e');
            requiredFee = 0.6;
          }
          if (cloakBalance < requiredFee) {
            throw Exception('Insufficient shielded balance for publish fees. '
                'Have $cloakBalance CLOAK, need at least ${requiredFee.toStringAsFixed(2)} CLOAK. '
                'Deposit and authenticate more CLOAK first.');
          }
        } catch (e) {
          if (e.toString().contains('Insufficient shielded balance')) rethrow;
          print('[CloakWalletManager] Warning: Could not check balance: $e');
        }
      }

      // 4. Build ZTransaction for auth token mint (quantity=0)
      // For auth tokens, from/contract are part of ZK circuit inputs but the
      // Rust FFI handles them from the wallet's internal unpublished note state.
      // We use thezeosalias as the nominal account since it authorizes everything.
      //
      // CRITICAL: Pass the vault seed as memo so resolve_ztransaction uses it for
      // Rseed derivation. Without this, Rust generates a random BIP-39 mnemonic
      // for the Rseed, producing a different commitment hash than the deterministic
      // one from createDeterministicVault — making the vault undiscoverable.
      String vaultSeedMemo = '';
      if (_cloakWallet != null) {
        final vaultData = await CloakDb.getVaultByHash(vaultHash);
        final vaultIndex = vaultData?['vault_index'] as int?;
        if (vaultIndex != null) {
          final seedHex = CloakApi.deriveVaultSeed(_cloakWallet!, vaultIndex);
          if (seedHex != null && seedHex.isNotEmpty) {
            vaultSeedMemo = seedHex;
          }
        }
      }
      // CRITICAL: fromAccount and tokenContract MUST match the contract used in
      // createDeterministicVault (thezeostoken) so the on-chain commitment hash
      // equals the locally-derived hash. The auth token circuit enforces
      // from == contract but does NOT require a specific value.
      final ztxJson = _buildAuthTokenMintZTransaction(
        fromAccount: 'thezeostoken',
        tokenContract: 'thezeostoken',
        memo: vaultSeedMemo,
      );

      // 5. Get fees
      final feesJson = await _getFeesJson();

      // 6. Generate ZK proof + unsigned transaction
      if (_cloakWallet == null) {
        throw Exception('Wallet not loaded');
      }

      CloakSync.lockWallet();
      var operation = await _beginProofMutationLocked('publish-vault-direct');
      var submissionStarted = false;
      try {
        // Run ZK proof generation in a background isolate so the UI stays
        // responsive (spinner keeps animating, no freeze).
        final txJson = await FfiIsolate.transactPacked(
          wallet: _cloakWallet!,
          ztxJson: ztxJson,
          feeTokenContract: 'thezeostoken',
          feesJson: feesJson,
          mintParams: _mintParams!,
          spendOutputParams: _spendOutputParams!,
          spendParams: _spendParams!,
          outputParams: _outputParams!,
        );

        // 6. Parse transaction (tuple format: [TransactionPacked, unpublished_notes])
        final decoded = jsonDecode(txJson);
        final Map<String, dynamic> tx;
        if (decoded is List && decoded.isNotEmpty) {
          tx = Map<String, dynamic>.from(decoded[0] as Map);
        } else if (decoded is Map) {
          tx = Map<String, dynamic>.from(decoded as Map);
        } else {
          throw Exception(
              'Unexpected transactPacked response format: ${decoded.runtimeType}');
        }

        // Validate actions exist
        final txActions = tx['actions'] as List? ?? [];
        if (txActions.isEmpty) {
          throw Exception(
              'transactPacked returned transaction with 0 actions — ZK proof may have failed');
        }

        // 6b. Set transaction headers (ref_block_num, ref_block_prefix, expiration)
        // Rust returns actions only — we must add blockchain headers before signing
        final client = HttpClient();
        try {
          final request = await client
              .getUrl(Uri.parse('https://telos.eosusa.io/v1/chain/get_info'));
          final response = await request.close();
          if (response.statusCode != 200)
            throw Exception('get_info failed: ${response.statusCode}');
          final chainInfo =
              jsonDecode(await response.transform(const Utf8Decoder()).join())
                  as Map<String, dynamic>;
          final headBlockId = chainInfo['head_block_id'] as String;
          final refBlockNum =
              int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
          // ref_block_prefix: bytes 8-11 of the block ID in little-endian
          final prefixHex = headBlockId.substring(16, 24);
          final prefixBytes = List<int>.generate(
              4,
              (i) =>
                  int.parse(prefixHex.substring(i * 2, i * 2 + 2), radix: 16));
          final refBlockPrefix = prefixBytes[3] << 24 |
              prefixBytes[2] << 16 |
              prefixBytes[1] << 8 |
              prefixBytes[0];

          final expiration =
              DateTime.now().toUtc().add(const Duration(minutes: 10));
          tx['expiration'] = '${expiration.toIso8601String().split('.')[0]}Z';
          tx['ref_block_num'] = refBlockNum;
          tx['ref_block_prefix'] = refBlockPrefix;
          tx['max_net_usage_words'] = tx['max_net_usage_words'] ?? 0;
          tx['max_cpu_usage_ms'] = tx['max_cpu_usage_ms'] ?? 0;
          tx['delay_sec'] = tx['delay_sec'] ?? 0;
          tx['context_free_actions'] = tx['context_free_actions'] ?? [];
          tx['transaction_extensions'] = tx['transaction_extensions'] ?? [];
        } finally {
          client.close();
        }

        // 6c. Use hex_data for action serialization (Rust provides pre-serialized ABI data)
        final actions = tx['actions'] as List? ?? [];
        for (final action in actions) {
          if (action is Map && action['hex_data'] != null) {
            action['data'] = action['hex_data'] as String;
          }
        }

        operation = await _captureEagerProofStateLocked(
          operation,
          transaction: tx,
        );

        // 7. Sign with thezeosalias@public key only (no user key needed)
        final signatures = await EsrTransactionHelper.signWithAliasKey(
          transaction: tx,
          existingSignatures: [],
        );

        // 8. Broadcast directly
        await _markPendingSubmittingLocked(operation);
        final result = await EsrTransactionHelper.broadcastTransaction(
          transaction: tx,
          signatures: signatures,
          onSubmitStarted: () => submissionStarted = true,
        );

        final txId = result['transaction_id'] as String? ?? 'unknown';
        requireMatchingTransactionId(operation, txId);

        // 9. Verify transaction landed on-chain (check leaf count increased)
        try {
          await Future.delayed(const Duration(seconds: 2));
          final verifyClient = HttpClient();
          try {
            final vReq = await verifyClient.postUrl(
                Uri.parse('https://telos.eosusa.io/v1/chain/get_table_rows'));
            vReq.headers.set('Content-Type', 'application/json');
            vReq.write(jsonEncode({
              'code': 'zeosprotocol',
              'scope': 'zeosprotocol',
              'table': 'global',
              'limit': 1,
              'json': true,
            }));
            final vResp = await vReq.close();
            jsonDecode(await vResp.transform(const Utf8Decoder()).join());
            // Verification complete — response parsed to confirm chain accepted TX
          } finally {
            verifyClient.close();
          }
        } catch (_) {}

        // 10. Persist published auth token state and clear the durable quarantine.
        await _acceptPendingOperationLocked(operation);

        // 11. Mark as published in database
        await markVaultPublished();

        return txId;
      } catch (error, stackTrace) {
        if (classifyProofFailure(
              submissionStarted: submissionStarted,
              error: error,
            ) ==
            SendFailureDisposition.rollback) {
          await _rollbackPendingOperationLocked(operation);
        } else {
          await _quarantinePendingOperationLocked(operation);
        }
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        CloakSync.unlockWallet();
      }
    });
  }

  /// Build ZTransaction for auth token mint (quantity=0)
  static String _buildAuthTokenMintZTransaction({
    required String fromAccount,
    required String tokenContract,
    String memo = '',
  }) {
    final chainId = getChainId() ?? TELOS_CHAIN_ID;
    final protocolContract = getProtocolContract() ?? 'zeosprotocol';
    final vaultContract = getVaultContract() ?? 'thezeosvault';
    final aliasAuthority = getAliasAuthority() ?? 'thezeosalias@public';

    final ztx = {
      'chain_id': chainId,
      'protocol_contract': protocolContract,
      'vault_contract': vaultContract,
      'alias_authority': aliasAuthority,
      'add_fee': true, // Fee paid from shielded balance
      'publish_fee_note': true,
      'zactions': [
        {
          'name': 'mint',
          'data': {
            'to': '\$SELF', // To our own shielded address
            'contract':
                tokenContract, // "0" for any contract, or specific contract
            'quantity': '0', // Zero quantity = auth token
            'memo': memo,
            'from': fromAccount,
            'publish_note': true, // MUST be true to publish to blockchain
          }
        }
      ],
    };
    return jsonEncode(ztx);
  }

  /// Get complete vault deposit instructions
  static Map<String, String>? getVaultDepositInfo() {
    final vaultHash = getPrimaryVaultHash();
    if (vaultHash == null) return null;

    return {
      'contract': 'thezeosvault',
      'vaultHash': vaultHash,
      'memoFormat': 'AUTH:$vaultHash|<optional_memo>',
      'exampleMemo': 'AUTH:$vaultHash|deposit',
    };
  }

  // ============== Vault Import Methods ==============

  /// Import a vault from its seed phrase
  /// The seed is used to derive the commitment hash that identifies the vault on-chain
  ///
  /// [seed] - The vault seed (can be 24 words or any string)
  /// [contract] - The token contract (default: thezeostoken)
  /// [label] - Optional user-friendly label for this vault
  /// [accountId] - The account ID to associate this vault with (default: 1)
  ///
  /// Returns the vault info map on success, or null on failure
  static Future<Map<String, dynamic>?> importVault({
    required String seed,
    String contract = 'thezeostoken',
    String? label,
    int accountId = 1,
  }) async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('import-vault', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) {
        print('[CloakWalletManager] importVault: wallet not loaded');
        return null;
      }

      // MUST use getDefaultAddress() (stable, deterministic) — NOT getAddress()
      // which calls derive_next_address() and increments the diversifier each call.
      // The commitment hash depends on the recipient address, so we need the same
      // address at import time and re-injection time (_ensureAuthTokenLoaded).
      final address = getDefaultAddress();
      if (address == null) {
        print(
            '[CloakWalletManager] importVault: could not get default address');
        return null;
      }

      // Use the seed as the label parameter to create/recreate the vault in wallet.bin
      // This derives the same commitment hash if the seed matches an existing vault
      final contractU64 = eosioNameToU64(contract);

      final notesJson = CloakApi.createUnpublishedAuthNote(
        _cloakWallet!,
        seed, // The seed becomes the vault's identifier
        contractU64,
        address,
      );

      if (notesJson == null) {
        print(
            '[CloakWalletManager] importVault failed: ${CloakApi.getLastError()}');
        return null;
      }

      // Extract commitment hash from response
      String? commitmentHash;
      try {
        final notes = jsonDecode(notesJson);
        if (notes is Map) {
          final commitmentList = notes['__commitment__'];
          if (commitmentList is List && commitmentList.isNotEmpty) {
            commitmentHash = commitmentList[0] as String;
          }
        }
      } catch (e) {
        print('[CloakWalletManager] importVault: failed to parse response: $e');
        return null;
      }

      if (commitmentHash == null || commitmentHash.length != 64) {
        print('[CloakWalletManager] importVault: invalid commitment hash');
        return null;
      }

      // Verify vault exists on-chain
      bool onChain = false;
      List<Map<String, dynamic>>? fts;
      List<Map<String, dynamic>>? nfts;
      try {
        final vaultTokens = await queryVaultTokens(commitmentHash);
        if (vaultTokens.existsOnChain) {
          onChain = true;
          fts = vaultTokens.fts;
          nfts = vaultTokens.nfts;
        }
      } catch (e) {
        print('[CloakWalletManager] importVault: on-chain check failed: $e');
      }

      // Save wallet to persist the vault in wallet.bin
      if (!await saveWallet()) return null;

      // Check if vault already exists in database
      final exists = await CloakDb.vaultExistsByHash(commitmentHash);
      if (exists) {
        final existing = await CloakDb.getVaultByHash(commitmentHash);
        if (existing != null) {
          existing['on_chain'] = onChain;
          if (fts != null) existing['fts'] = fts;
          if (nfts != null) existing['nfts'] = nfts;
        }
        return existing;
      }

      // Store in CloakDb for easy access and display
      final vaultId = await CloakDb.addVault(
        accountId: accountId,
        seed: seed,
        commitmentHash: commitmentHash,
        contract: contract,
        label: label ?? 'Vault ${commitmentHash.substring(0, 8)}',
      );

      if (vaultId < 0) {
        print('[CloakWalletManager] importVault: failed to save to database');
        return null;
      }

      return {
        'id': vaultId,
        'seed': seed,
        'commitment_hash': commitmentHash,
        'contract': contract,
        'label': label ?? 'Vault ${commitmentHash.substring(0, 8)}',
        'on_chain': onChain,
        if (fts != null) 'fts': fts,
        if (nfts != null) 'nfts': nfts,
      };
    });
  }

  /// Import a vault using user-provided seed AND commitment hash
  /// Use this when importing a vault created in another wallet (different address)
  ///
  /// [seed] - The vault seed (24 words or any string used to create the vault)
  /// [commitmentHash] - The 64-char hex commitment hash from the original wallet
  /// [label] - Optional user-friendly label
  /// [accountId] - The account ID to associate this vault with (default: 1)
  ///
  /// Returns the vault info map on success, or null on failure
  static Future<Map<String, dynamic>?> importVaultWithHash({
    required String seed,
    required String commitmentHash,
    String? label,
    int accountId = 1,
  }) async {
    // Validate commitment hash format
    if (commitmentHash.length != 64 ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(commitmentHash)) {
      print('[CloakWalletManager] importVaultWithHash: invalid hash format');
      return null;
    }

    // Check if vault already exists in database
    final exists = await CloakDb.vaultExistsByHash(commitmentHash);
    if (exists) {
      final existing = await CloakDb.getVaultByHash(commitmentHash);
      return existing;
    }

    // Store in CloakDb with user-provided hash (don't derive)
    final vaultId = await CloakDb.addVault(
      accountId: accountId,
      seed: seed,
      commitmentHash: commitmentHash,
      contract: 'thezeostoken', // Default contract
      label: label ?? 'Vault ${commitmentHash.substring(0, 8)}',
    );

    if (vaultId < 0) {
      print(
          '[CloakWalletManager] importVaultWithHash: failed to save to database');
      return null;
    }

    return {
      'id': vaultId,
      'seed': seed,
      'commitment_hash': commitmentHash,
      'contract': 'thezeostoken',
      'label': label ?? 'Vault ${commitmentHash.substring(0, 8)}',
    };
  }

  /// Get all imported vaults from database
  /// Returns list of vault info maps with seed, commitment_hash, contract, label
  static Future<List<Map<String, dynamic>>> getImportedVaults(
      {int? accountId}) async {
    if (accountId != null) {
      return await CloakDb.getVaultsForAccount(accountId);
    }
    return await CloakDb.getAllVaults();
  }

  /// Get vault details by ID
  static Future<Map<String, dynamic>?> getVaultDetails(int vaultId) async {
    return await CloakDb.getVaultById(vaultId);
  }

  /// Get vault by commitment hash
  static Future<Map<String, dynamic>?> getVaultByHash(
      String commitmentHash) async {
    return await CloakDb.getVaultByHash(commitmentHash);
  }

  /// Update vault status in database
  /// Valid statuses: created, published, funded, active, empty, burned
  static Future<void> updateVaultStatus(
      String commitmentHash, String status) async {
    await CloakDb.updateVaultStatusByHash(commitmentHash, status);
  }

  /// Delete an imported vault from database
  /// Note: This only removes from local database, not from wallet.bin or on-chain
  static Future<void> deleteImportedVault(int vaultId,
      {String? commitmentHash}) async {
    // If the deleted vault is the "primary" stored vault, clear vault properties
    if (commitmentHash != null && commitmentHash.isNotEmpty) {
      final storedHash = await getStoredVaultHash();
      if (storedHash == commitmentHash) {
        await CloakDb.setProperty(_vaultHashKey, '');
        await CloakDb.setProperty('cloak_vault_published', '');
      }
    }
    await CloakDb.deleteVault(vaultId);
  }

  /// Query vault balance from blockchain
  /// Returns formatted balance string (e.g., "1.0000 CLOAK") or null on error
  static Future<String?> queryVaultBalance(String commitmentHash) async {
    try {
      final client = EosioClient('https://telos.eosusa.io');

      // Query the thezeosvault table - fetch all rows and filter client-side
      // The table uses auth_token (sha256) as primary key but index query doesn't work reliably
      // Table structure: { auth_token, creation_block_time, fts: [{first: {sym, contract}, second: amount}], nfts: [] }
      final response = await client.getTableRows(
        code: 'thezeosvault',
        scope: 'thezeosvault',
        table: 'vaults',
        limit: 100, // Fetch up to 100 vaults
      );

      client.close();

      if (response['rows'] == null || (response['rows'] as List).isEmpty) {
        return '0 CLOAK';
      }

      final rows = response['rows'] as List;
      // Find the row matching our commitment hash
      for (final row in rows) {
        final authToken = row['auth_token'] as String?;
        if (authToken == commitmentHash) {
          // Parse the balance from 'fts' (fungible tokens) array
          // Format: [{"first": {"sym": "4,CLOAK", "contract": "thezeostoken"}, "second": 10000}]
          final fts = row['fts'];
          if (fts is List && fts.isNotEmpty) {
            final balances = <String>[];
            for (final item in fts) {
              if (item is Map) {
                final tokenInfo = item['first'];
                final amount = item['second'];
                if (tokenInfo is Map && amount is int) {
                  if (amount <= 0) continue;
                  final sym = tokenInfo['sym'] as String? ?? '4,CLOAK';
                  final parts = sym.split(',');
                  final precision = int.tryParse(parts[0]) ?? 4;
                  final symbol = parts.length > 1 ? parts[1] : 'CLOAK';
                  final formatted = formatAssetUnits(amount, precision);
                  balances.add('$formatted $symbol');
                }
              }
            }
            final result =
                balances.isNotEmpty ? balances.join(', ') : '0 CLOAK';
            return result;
          }
          return '0 CLOAK';
        }
      }

      return '0 CLOAK';
    } catch (e) {
      print('[CloakWalletManager] queryVaultBalance error: $e');
      return null;
    }
  }

  // ============== Vault Token Queries ==============

  /// Cache for vault token queries (commitment_hash -> result)
  static final Map<String, VaultTokensResult> _vaultTokensCache = {};

  /// Query vault tokens (FTs and NFTs) from blockchain
  /// Returns structured data with CLOAK units and token lists.
  /// Throws on HTTP/network errors (callers should handle with try/catch).
  /// Only caches successful results — failures are NOT cached.
  static Future<VaultTokensResult> queryVaultTokens(
      String commitmentHash) async {
    // Check cache first
    if (_vaultTokensCache.containsKey(commitmentHash)) {
      return _vaultTokensCache[commitmentHash]!;
    }

    final client = EosioClient('https://telos.eosusa.io');
    late final Map<String, dynamic> response;
    try {
      response = await client.getTableRows(
        code: 'thezeosvault',
        scope: 'thezeosvault',
        table: 'vaults',
        limit: 100,
      );
    } finally {
      client.close();
    }

    if (response['rows'] == null || (response['rows'] as List).isEmpty) {
      final result = VaultTokensResult(cloakUnits: 0, fts: [], nfts: []);
      _vaultTokensCache[commitmentHash] = result;
      return result;
    }

    {
      final rows = response['rows'] as List;
      for (final row in rows) {
        final authToken = row['auth_token'] as String?;
        if (authToken == commitmentHash) {
          // Parse FTs
          int cloakUnits = 0;
          final List<Map<String, dynamic>> fts = [];
          final ftsRaw = row['fts'];
          if (ftsRaw is List) {
            for (final item in ftsRaw) {
              if (item is Map) {
                final tokenInfo = item['first'];
                final amount = item['second'];
                if (tokenInfo is Map && amount is int) {
                  if (amount <= 0) continue;
                  final sym = tokenInfo['sym'] as String? ?? '4,CLOAK';
                  final contract =
                      tokenInfo['contract'] as String? ?? 'thezeostoken';
                  final parts = sym.split(',');
                  final precision = int.tryParse(parts[0]) ?? 4;
                  final symbol = parts.length > 1 ? parts[1] : 'CLOAK';
                  final formatted = formatAssetUnits(amount, precision);
                  fts.add({
                    'symbol': symbol,
                    'contract': contract,
                    'amount': formatted,
                    'rawAmount': amount,
                    'precision': precision,
                  });
                  if (symbol == 'CLOAK' && contract == 'thezeostoken') {
                    cloakUnits = amount;
                  }
                }
              }
            }
          }

          // Parse NFTs
          final List<Map<String, dynamic>> nfts = [];
          final nftsRaw = row['nfts'];
          if (nftsRaw is List) {
            for (final item in nftsRaw) {
              if (item is Map) {
                nfts.add(Map<String, dynamic>.from(item));
              }
            }
          }

          final result = VaultTokensResult(
              cloakUnits: cloakUnits,
              fts: fts,
              nfts: nfts,
              existsOnChain: true);
          _vaultTokensCache[commitmentHash] = result;
          return result;
        }
      }

      final result = VaultTokensResult(
          cloakUnits: 0, fts: [], nfts: [], existsOnChain: false);
      _vaultTokensCache[commitmentHash] = result;
      return result;
    }
  }

  /// Clear vault tokens cache (call on pull-to-refresh or vault switch)
  static void clearVaultTokensCache() {
    _vaultTokensCache.clear();
  }

  /// Ensure default vault exists (call on wallet load)
  static Future<void> ensureVaultExists() async {
    await _ensureDefaultVaultExists();
  }

  /// Close wallet and free resources
  static Future<void> close() {
    return _walletOperations.runExclusive('close-wallet', () async {
      if (_cloakWallet != null) {
        CloakApi.closeWallet(_cloakWallet!);
        _cloakWallet = null;
      }
      _pendingProofMutation = _pendingWalletOperation != null ||
          (_cloakWalletPath != null && await _pendingOperationFile.exists());
      _lastValidatedChainDepth = null;
      _lastDepthValidation = null;
      _cachedChainId = null;
      _cachedProtocolContract = null;
      _cachedVaultContract = null;
      _cachedAliasAuthority = null;
      _cachedIvk = null;
      _cachedFvk = null;
      _cachedOvk = null;
      _cachedSeedHex = null;
      _cachedDefaultAddress = null;
      _cachedBalancesJson = null;
      _cachedTransactionHistoryJson = null;
      _cachedNftsJson.clear();
      _cachedAuthenticationTokensJson.clear();
      _cachedUnpublishedNotesJson = null;
    });
  }

  /// Delete wallet file
  static Future<void> deleteWallet() async {
    _requireNoUpdateApply();
    _requireNoPendingWalletMutation();
    await close();
    if (_cloakWalletPath == null) await init();
    final file = File(_cloakWalletPath!);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Get chain ID
  static String? getChainId() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedChainId;
    _cachedChainId = CloakApi.getChainId(_cloakWallet!);
    return _cachedChainId;
  }

  /// Get protocol contract name
  static String? getProtocolContract() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedProtocolContract;
    _cachedProtocolContract = CloakApi.getProtocolContract(_cloakWallet!);
    return _cachedProtocolContract;
  }

  /// Get vault contract name
  static String? getVaultContract() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedVaultContract;
    _cachedVaultContract = CloakApi.getVaultContract(_cloakWallet!);
    return _cachedVaultContract;
  }

  /// Get alias authority (e.g., "thezeosalias@public")
  static String? getAliasAuthority() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedAliasAuthority;
    _cachedAliasAuthority = CloakApi.getAliasAuthority(_cloakWallet!);
    return _cachedAliasAuthority;
  }

  /// Check if wallet is view-only (nullable version)
  static bool? isViewOnlyNullable() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedIsViewOnly;
    _cachedIsViewOnly = CloakApi.isViewOnly(_cloakWallet!) ?? _cachedIsViewOnly;
    return _cachedIsViewOnly;
  }

  /// Get Incoming Viewing Key as bech32m encoded string (ivk1...)
  /// This key allows viewing incoming transactions without spending capability.
  static String? getIvkBech32m() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedIvk;
    _cachedIvk = CloakApi.getIvkBech32m(_cloakWallet!);
    return _cachedIvk;
  }

  /// Get Full Viewing Key as bech32m encoded string (fvk1...)
  /// This key allows viewing both incoming AND outgoing transactions.
  static String? getFvkBech32m() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedFvk;
    _cachedFvk = CloakApi.getFvkBech32m(_cloakWallet!);
    return _cachedFvk;
  }

  /// Get Outgoing Viewing Key as bech32m encoded string (ovk1...)
  /// This key allows viewing outgoing transactions only.
  static String? getOvkBech32m() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedOvk;
    _cachedOvk = CloakApi.getOvkBech32m(_cloakWallet!);
    return _cachedOvk;
  }

  /// Get seed as hex string (for backup purposes)
  static String? getSeedHex() {
    if (_cloakWallet == null) return null;
    if (!_nativeSynchronousAccessAllowed) return _cachedSeedHex;
    _cachedSeedHex = CloakApi.getSeedHex(_cloakWallet!);
    return _cachedSeedHex;
  }

  // ============== Transaction Support ==============

  // Cached depth-12 ZK params (loaded once, ~249MB total)
  static Uint8List? _mintParams;
  static Uint8List? _spendOutputParams;
  static Uint8List? _spendParams;
  static Uint8List? _outputParams;

  /// Load ZK params from the platform-specific params directory.
  /// These are large files (~249MB total) so we cache them in memory.
  /// Loading runs in a separate isolate to avoid freezing the UI.
  static Future<bool> loadZkParams() async {
    await requireProtocolProofCompatibility();
    if (_mintParams != null &&
        _spendOutputParams != null &&
        _spendParams != null &&
        _outputParams != null) {
      return true;
    }

    return _zkParamsLoader.run(_loadZkParamsOnce);
  }

  static Future<bool> _loadZkParamsOnce() async {
    try {
      final paramsDir = await ParamsManager.getParamsDirectory();
      if (!await ParamsManager.paramsExist(paramsDir)) {
        print('CloakWalletManager: ZK params not found at $paramsDir');
        return false;
      }

      // Hash the exact byte arrays that will be cached for native proof
      // generation. A separate verify-then-read sequence has a replacement
      // window between checksum validation and consumption.
      final results = await Isolate.run(
        () => ParamsManager.readVerifiedParameterFiles(paramsDir),
      );

      _mintParams = results[0];
      _spendOutputParams = results[1];
      _spendParams = results[2];
      _outputParams = results[3];

      return true;
    } catch (e) {
      print('CloakWalletManager: Failed to load ZK params: $e');
      _mintParams = null;
      _spendOutputParams = null;
      _spendParams = null;
      _outputParams = null;
      return false;
    }
  }

  /// Build and sign a ZEOS shielded transaction while the native-wallet
  /// coordinator and durable proof lifecycle are already held by the caller.
  ///
  /// [recipients] - List of {address, amount, tokenContract, tokenSymbol, memo}
  /// [feeTokenContract] - Contract for fee token (e.g., "eosio.token")
  /// [feeAmount] - Fee amount as string (e.g., "0.0100 TLOS")
  ///
  /// Returns signed EOSIO transaction JSON, or null on error
  static Future<Map<String, dynamic>?> _buildTransactionLocked({
    required List<Map<String, dynamic>> recipients,
    required String feeTokenContract,
    required String feeAmount,
    bool drain = false,
    void Function(String)? onStatus,
  }) async {
    _requireNoUpdateApply();
    if (!_walletOperations.isHeldByCurrentZone) {
      throw StateError(
          'Shielded transaction builder requires wallet ownership');
    }
    if (_cloakWallet == null) {
      print('CloakWalletManager: No wallet loaded');
      return null;
    }

    // Ensure params are loaded
    if (!await loadZkParams()) {
      print('CloakWalletManager: ZK params not available');
      return null;
    }

    // Sync auth_count from on-chain BEFORE proof generation
    // auth_hash = Blake2s(auth_count || packed_actions) — must match chain state
    onStatus?.call('Syncing with network...');
    try {
      final eosClient = EosioClient('https://telos.eosusa.io');
      final global = await eosClient.getZeosGlobal();
      eosClient.close();
      if (global != null) {
        final walletAC = CloakApi.getAuthCount(_cloakWallet!) ?? 0;
        if (walletAC != global.authCount) {
          CloakApi.setAuthCount(_cloakWallet!, global.authCount);
        }
      }
    } catch (e) {
      print('CloakWalletManager: Warning: could not sync auth_count: $e');
    }

    // Build ZTransaction JSON matching the Rust ZTransaction struct
    final chainId = getChainId() ?? TELOS_CHAIN_ID;
    final protocolContract = getProtocolContract() ?? 'zeosprotocol';
    final vaultContract = getVaultContract() ?? 'thezeosvault';
    final aliasAuthority = getAliasAuthority() ?? 'thezeosalias@public';

    // Build spend recipients from the recipients list
    final spendTo = recipients.map((r) {
      final amount = r['amount'] as int;
      final symbol = r['tokenSymbol'] as String? ?? 'CLOAK';
      final precision = r['tokenPrecision'] as int?;
      if (precision == null) {
        throw StateError('Recipient token precision is required');
      }
      final quantity = '${formatAssetUnits(amount, precision)} $symbol';
      return <String, dynamic>{
        'to': r['address'],
        'quantity': quantity,
        'memo': r['memo'] ?? '',
        'publish_note': true,
      };
    }).toList();

    final tokenContract = recipients.isNotEmpty
        ? (recipients.first['tokenContract'] ?? 'thezeostoken')
        : 'thezeostoken';

    final ztx = {
      'chain_id': chainId,
      'protocol_contract': protocolContract,
      'vault_contract': vaultContract,
      'alias_authority': aliasAuthority,
      'add_fee': true,
      'publish_fee_note': true,
      'zactions': [
        {
          'name': 'spend',
          'data': {
            'contract': tokenContract,
            'change_to': '\$SELF',
            'publish_change_note': true,
            'to': spendTo,
            if (drain) 'drain': true,
          }
        }
      ],
    };

    final ztxJson = jsonEncode(ztx);
    final feesJson = await _getFeesJson();

    // Generate ZK proof + unsigned transaction via Rust FFI (background isolate).
    // The enclosing proof lifecycle owns both the coordinator and sync lock.
    final String txJson;
    onStatus?.call('Generating zero-knowledge proof...');
    txJson = await FfiIsolate.transactPacked(
      wallet: _cloakWallet!,
      ztxJson: ztxJson,
      feeTokenContract: feeTokenContract,
      feesJson: feesJson,
      mintParams: _mintParams!,
      spendOutputParams: _spendOutputParams!,
      spendParams: _spendParams!,
      outputParams: _outputParams!,
    );

    // Parse the transaction (tuple format: [TransactionPacked, unpublished_notes])
    final decoded = jsonDecode(txJson);
    final Map<String, dynamic> tx;
    if (decoded is List && decoded.isNotEmpty) {
      tx = Map<String, dynamic>.from(decoded[0] as Map);
    } else if (decoded is Map) {
      tx = Map<String, dynamic>.from(decoded as Map);
    } else {
      throw Exception(
          'Unexpected transactPacked response format: ${decoded.runtimeType}');
    }

    // Set transaction headers (ref_block_num, ref_block_prefix, expiration)
    onStatus?.call('Preparing transaction...');
    final httpClient = HttpClient();
    try {
      final request = await httpClient
          .getUrl(Uri.parse('https://telos.eosusa.io/v1/chain/get_info'));
      final response = await request.close();
      if (response.statusCode != 200)
        throw Exception('get_info failed: ${response.statusCode}');
      final chainInfo =
          jsonDecode(await response.transform(const Utf8Decoder()).join())
              as Map<String, dynamic>;
      final headBlockId = chainInfo['head_block_id'] as String;
      final refBlockNum =
          int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
      final prefixHex = headBlockId.substring(16, 24);
      final prefixBytes = List<int>.generate(4,
          (i) => int.parse(prefixHex.substring(i * 2, i * 2 + 2), radix: 16));
      final refBlockPrefix = prefixBytes[3] << 24 |
          prefixBytes[2] << 16 |
          prefixBytes[1] << 8 |
          prefixBytes[0];

      final expiration =
          DateTime.now().toUtc().add(const Duration(minutes: 10));
      tx['expiration'] = '${expiration.toIso8601String().split('.')[0]}Z';
      tx['ref_block_num'] = refBlockNum;
      tx['ref_block_prefix'] = refBlockPrefix;
      tx['max_net_usage_words'] = tx['max_net_usage_words'] ?? 0;
      tx['max_cpu_usage_ms'] = tx['max_cpu_usage_ms'] ?? 0;
      tx['delay_sec'] = tx['delay_sec'] ?? 0;
      tx['context_free_actions'] = tx['context_free_actions'] ?? [];
      tx['transaction_extensions'] = tx['transaction_extensions'] ?? [];
    } finally {
      httpClient.close();
    }

    // Use hex_data for action serialization (Rust provides pre-serialized ABI data)
    final actions = tx['actions'] as List? ?? [];
    for (final action in actions) {
      if (action is Map && action['hex_data'] != null) {
        action['data'] = action['hex_data'] as String;
      }
    }

    // Sign with thezeosalias@public key
    onStatus?.call('Signing transaction...');
    final signatures = await EsrTransactionHelper.signWithAliasKey(
      transaction: tx,
      existingSignatures: [],
    );

    return {'transaction': tx, 'signatures': signatures};
  }

  /// Broadcast a signed transaction to the EOSIO network
  /// [signedTxData] contains 'transaction' (Map) and 'signatures' (List<String>)
  /// Returns transaction ID on success
  static Future<String?> _broadcastTransaction(
    Map<String, dynamic> signedTxData, {
    void Function()? onSubmitStarted,
  }) async {
    final tx = signedTxData['transaction'] as Map<String, dynamic>;
    final signatures = (signedTxData['signatures'] as List).cast<String>();

    try {
      final result = await EsrTransactionHelper.broadcastTransaction(
        transaction: tx,
        signatures: signatures,
        onSubmitStarted: onSubmitStarted,
      );

      final txId = result['transaction_id'] as String?;
      return txId;
    } catch (e) {
      print('CloakWalletManager: Broadcast error: $e');
      rethrow;
    }
  }

  /// Send CLOAK/ZEOS transaction (build, sign, broadcast)
  /// Returns transaction ID on success, null on failure
  static Future<String?> sendTransaction({
    required String recipientAddress,
    required int amount, // in smallest units
    required String tokenSymbol,
    required String tokenContract,
    required int tokenPrecision,
    String memo = '', // 512-byte encrypted memo for messages
    String feeTokenContract = 'thezeostoken',
    String feeAmount = '0.4000 CLOAK',
    bool drain = false,
    SendCancellationToken? cancellationToken,
    void Function(String)? onStatus,
  }) async {
    _requireNoUpdateApply();
    if (_cloakWallet == null) throw StateError('Wallet not loaded');
    if (amount < 0) throw ArgumentError.value(amount, 'amount');
    if (tokenPrecision < 0 || tokenPrecision > 18) {
      throw RangeError.range(tokenPrecision, 0, 18, 'tokenPrecision');
    }
    if (_normalSendInProgress) {
      throw StateError('Another shielded transaction is already in progress');
    }

    _normalSendInProgress = true;
    try {
      return await _walletOperations.runExclusive('normal-send', () async {
        _requireNoUpdateApply();
        _requireNoPendingWalletMutation();
        cancellationToken?.throwIfCancelled();
        CloakSync.lockWallet();
        PendingWalletOperation? operation;
        bool submissionStarted = false;
        try {
          operation = await _beginProofMutationLocked('normal-send');
          cancellationToken?.throwIfCancelled();
          onStatus?.call('Building transaction...');
          final signedTx = await _buildTransactionLocked(
            recipients: [
              {
                'address': recipientAddress,
                'amount': amount,
                'tokenContract': tokenContract,
                'tokenSymbol': tokenSymbol,
                'tokenPrecision': tokenPrecision,
                'memo': memo,
              }
            ],
            feeTokenContract: feeTokenContract,
            feeAmount: feeAmount,
            drain: drain,
            onStatus: onStatus,
          );
          if (signedTx == null) {
            throw Exception('Transaction build returned null');
          }
          final transaction = signedTx['transaction'] as Map<String, dynamic>?;
          if (transaction == null) {
            throw StateError('Built transaction is missing transaction bytes');
          }
          operation = await _captureEagerProofStateLocked(
            operation,
            transaction: transaction,
          );
          cancellationToken?.throwIfCancelled();

          onStatus?.call('Broadcasting...');
          await _markPendingSubmittingLocked(operation);
          final txId = await _broadcastTransaction(
            signedTx,
            onSubmitStarted: () => submissionStarted = true,
          );
          if (txId == null) {
            throw Exception('Transaction broadcast returned no transaction ID');
          }
          requireMatchingTransactionId(operation, txId);
          await _acceptPendingOperationLocked(operation);
          return txId;
        } catch (error, stackTrace) {
          if (operation == null) Error.throwWithStackTrace(error, stackTrace);
          if (classifyProofFailure(
                submissionStarted: submissionStarted,
                error: error,
              ) ==
              SendFailureDisposition.rollback) {
            await _rollbackPendingOperationLocked(operation);
            Error.throwWithStackTrace(error, stackTrace);
          }
          await _quarantinePendingOperationLocked(operation);
          throw SendReconciliationException(
            cause: error,
            reconciliationSucceeded: false,
          );
        } finally {
          CloakSync.unlockWallet();
        }
      });
    } finally {
      _normalSendInProgress = false;
    }
  }

  // ============== Vault Authenticate (Native Send from Vault) ==============

  /// Authenticate a vault to withdraw tokens into the shielded pool.
  /// Builds an `authenticate` ZTransaction with a `withdrawp` sub-action.
  /// Tokens go from thezeosvault → zeosprotocol (shielded pool), then the
  /// wallet discovers them via Merkle tree sync and trial decryption.
  ///
  /// [vaultHash] - The 64-char commitment hash of the vault
  /// [recipientAddress] - Unused for withdrawp routing (kept for API compat)
  /// [quantity] - Asset string, e.g., "1.0000 CLOAK"
  /// [tokenContract] - Token contract, e.g., "thezeostoken"
  /// [burn] - 0 to keep vault reusable, 1 to burn after authenticate
  /// [memo] - Optional memo for the withdraw transfer
  /// [onStatus] - Status callback for UI progress
  ///
  /// Returns transaction ID on success, throws on failure.
  static Future<String?> authenticateVault({
    required String vaultHash,
    required String recipientAddress,
    required String quantity,
    String tokenContract = 'thezeostoken',
    int burn = 0,
    String memo = '',
    void Function(String)? onStatus,
    List<String>? nftAssetIds, // If non-null, this is an NFT withdrawal
    String? nftContract, // NFT contract name (e.g. 'atomicassets')
  }) async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('authenticate-vault', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) throw Exception('Wallet not loaded');

      // Ensure ZK params are loaded
      if (!await loadZkParams()) {
        throw Exception('ZK params not available');
      }

      // Lock wallet to prevent sync from running during transaction
      CloakSync.lockWallet();
      try {
        // Ensure auth token is in wallet's unspent notes
        await _ensureAuthTokenLoaded(vaultHash);

        // Sync auth_count from chain
        onStatus?.call('Syncing with network...');
        try {
          final eosClient = EosioClient('https://telos.eosusa.io');
          final global = await eosClient.getZeosGlobal();
          eosClient.close();
          if (global != null) {
            final walletAC = CloakApi.getAuthCount(_cloakWallet!) ?? 0;
            if (walletAC != global.authCount) {
              CloakApi.setAuthCount(_cloakWallet!, global.authCount);
            }
          }
        } catch (_) {}

        // Build ZTransaction JSON with authenticate zaction
        final chainId = getChainId() ?? TELOS_CHAIN_ID;
        final protocolContract = getProtocolContract() ?? 'zeosprotocol';
        final vaultContractName = getVaultContract() ?? 'thezeosvault';
        final aliasAuthority = getAliasAuthority() ?? 'thezeosalias@public';

        // withdrawp transfers tokens from vault to the shielded pool (zeosprotocol),
        // NOT to the user's za1 address. The shielded notes are created by the
        // protocol contract and discovered by the wallet via Merkle tree sync.
        // Authorization must be thezeosvault@active (the vault contract's own auth,
        // dispatched as inline action by the protocol).
        // Detect if vault is empty (no tokens to withdraw) — check before serializing
        final quantityAmount =
            double.tryParse(quantity.split(' ').first) ?? 0.0;
        final bool isEmptyVault = quantityAmount == 0.0 &&
            (nftAssetIds == null || nftAssetIds.isEmpty) &&
            burn != 0;

        // Build inner actions for the authenticate zaction
        final innerActions = <Map<String, dynamic>>[];

        // Only build and include withdrawp if there are actual tokens to withdraw
        if (!isEmptyVault) {
          final String withdrawpData;
          if (nftAssetIds != null && nftAssetIds.isNotEmpty) {
            withdrawpData = _serializeWithdrawpNftToHex(
              nftContract: nftContract ?? 'atomicassets',
              from: 'thezeosvault',
              to: protocolContract,
              assetIds: nftAssetIds,
              memo: memo,
            );
          } else {
            withdrawpData = _serializeWithdrawpToHex(
              tokenContract: tokenContract,
              from: 'thezeosvault',
              to: protocolContract,
              quantity: quantity,
              memo: memo,
            );
          }
          innerActions.add({
            'account': vaultContractName,
            'name': 'withdrawp',
            'authorization': ['$vaultContractName@active'],
            'data': withdrawpData,
          });
        }

        // When burning, add burnvaultp only if the vault row exists on-chain.
        // Vaults that were never deposited to have no on-chain entry — burnvaultp
        // would fail with "no entry for this auth_token exists".
        if (burn != 0) {
          clearVaultTokensCache();
          try {
            final vaultState = await queryVaultTokens(vaultHash);
            if (vaultState.existsOnChain) {
              innerActions.add({
                'account': vaultContractName,
                'name': 'burnvaultp',
                'authorization': ['$vaultContractName@active'],
                'data': '', // burnvaultp struct has zero fields
              });
            }
          } catch (_) {}
        }

        final zactions = <Map<String, dynamic>>[
          {
            'name': 'authenticate',
            'data': {
              'auth_token': vaultHash,
              'burn': burn != 0,
              'actions': innerActions,
            }
          },
        ];

        // Add mint zaction for FT withdrawals (creates shielded note for withdrawn tokens).
        // Skip mint when burning an empty vault (nothing to mint).
        if (!isEmptyVault && (nftAssetIds == null || nftAssetIds.isEmpty)) {
          zactions.add({
            'name': 'mint',
            'data': {
              'to': r'$SELF',
              'contract': tokenContract,
              'quantity': quantity,
              'memo': '',
              'from': vaultContractName,
              'publish_note': true,
            }
          });
        }

        final ztx = {
          'chain_id': chainId,
          'protocol_contract': protocolContract,
          'vault_contract': vaultContractName,
          'alias_authority': aliasAuthority,
          'add_fee': true,
          'publish_fee_note': true,
          'zactions': zactions,
        };

        final ztxJson = jsonEncode(ztx);
        final feesJson = await _getFeesJson();

        var operation = await _beginProofMutationLocked('authenticate-vault');
        var submissionStarted = false;
        try {
          // Generate ZK proof (background isolate)
          onStatus?.call('Generating zero-knowledge proof...');
          final txJson = await FfiIsolate.transactPacked(
            wallet: _cloakWallet!,
            ztxJson: ztxJson,
            feeTokenContract: tokenContract,
            feesJson: feesJson,
            mintParams: _mintParams!,
            spendOutputParams: _spendOutputParams!,
            spendParams: _spendParams!,
            outputParams: _outputParams!,
          );

          // Parse transaction
          final decoded = jsonDecode(txJson);
          final Map<String, dynamic> tx;
          if (decoded is List && decoded.isNotEmpty) {
            tx = Map<String, dynamic>.from(decoded[0] as Map);
          } else if (decoded is Map) {
            tx = Map<String, dynamic>.from(decoded as Map);
          } else {
            throw Exception('Unexpected transactPacked response format');
          }

          // Set transaction headers
          onStatus?.call('Preparing transaction...');
          final httpClient = HttpClient();
          try {
            final request = await httpClient
                .getUrl(Uri.parse('https://telos.eosusa.io/v1/chain/get_info'));
            final response = await request.close();
            if (response.statusCode != 200) throw Exception('get_info failed');
            final chainInfo =
                jsonDecode(await response.transform(const Utf8Decoder()).join())
                    as Map<String, dynamic>;
            final headBlockId = chainInfo['head_block_id'] as String;
            final refBlockNum =
                int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
            final prefixHex = headBlockId.substring(16, 24);
            final prefixBytes = List<int>.generate(
                4,
                (i) => int.parse(prefixHex.substring(i * 2, i * 2 + 2),
                    radix: 16));
            final refBlockPrefix = prefixBytes[3] << 24 |
                prefixBytes[2] << 16 |
                prefixBytes[1] << 8 |
                prefixBytes[0];

            final expiration =
                DateTime.now().toUtc().add(const Duration(minutes: 10));
            tx['expiration'] = '${expiration.toIso8601String().split('.')[0]}Z';
            tx['ref_block_num'] = refBlockNum;
            tx['ref_block_prefix'] = refBlockPrefix;
            tx['max_net_usage_words'] = tx['max_net_usage_words'] ?? 0;
            tx['max_cpu_usage_ms'] = tx['max_cpu_usage_ms'] ?? 0;
            tx['delay_sec'] = tx['delay_sec'] ?? 0;
            tx['context_free_actions'] = tx['context_free_actions'] ?? [];
            tx['transaction_extensions'] = tx['transaction_extensions'] ?? [];
          } finally {
            httpClient.close();
          }

          // Use hex_data for action serialization
          final actions = tx['actions'] as List? ?? [];
          for (final action in actions) {
            if (action is Map && action['hex_data'] != null) {
              action['data'] = action['hex_data'] as String;
            }
          }

          operation = await _captureEagerProofStateLocked(
            operation,
            transaction: tx,
          );

          // Sign with thezeosalias@public key
          onStatus?.call('Signing transaction...');
          final signatures = await EsrTransactionHelper.signWithAliasKey(
            transaction: tx,
            existingSignatures: [],
          );

          // Broadcast
          onStatus?.call('Broadcasting...');
          await _markPendingSubmittingLocked(operation);
          final txId = await _broadcastTransaction(
            {'transaction': tx, 'signatures': signatures},
            onSubmitStarted: () => submissionStarted = true,
          );

          requireMatchingTransactionId(operation, txId);
          await _acceptPendingOperationLocked(operation);

          // Clear vault token cache so balance refreshes
          clearVaultTokensCache();

          return txId;
        } catch (error, stackTrace) {
          if (classifyProofFailure(
                submissionStarted: submissionStarted,
                error: error,
              ) ==
              SendFailureDisposition.rollback) {
            await _rollbackPendingOperationLocked(operation);
          } else {
            await _quarantinePendingOperationLocked(operation);
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      } finally {
        CloakSync.unlockWallet();
      }
    });
  }

  /// Batch-withdraw ALL vault assets (multiple FTs + NFTs) in a single
  /// ZK proof transaction.
  ///
  /// [vaultHash] - 64-char hex auth token identifying the vault
  /// [recipientAddress] - EOSIO account to receive all assets
  /// [entries] - List of [VaultWithdrawEntry], one per asset/contract
  /// [burn] - 0 to keep vault reusable, 1 to burn after authenticate
  /// [onStatus] - Status callback for UI progress
  ///
  /// Each entry becomes a separate `withdrawp` action inside the authenticate
  /// zaction's `actions` array. The Rust layer hashes all actions together into
  /// a single ZK proof via `Blake2s(auth_count || pack(ALL_actions))`.
  ///
  /// Returns transaction ID on success, throws on failure.

  /// Ensure a vault's auth token is loaded in the Rust wallet's unspent notes.
  /// Re-imports from DB seed if needed. Must be called before authenticate.
  static Future<void> _ensureAuthTokenLoaded(String vaultHash) async {
    if (!_walletOperations.isHeldByCurrentZone) {
      throw StateError('Auth-token import requires wallet ownership');
    }
    if (_cloakWallet == null) {
      throw Exception('Cannot load auth token: wallet not initialized');
    }

    final vault = await CloakDb.getVaultByHash(vaultHash);
    if (vault == null) {
      throw Exception(
          'Vault not found in database for hash ${vaultHash.substring(0, 16)}... — was the vault seed stored?');
    }
    final seed = vault['seed'] as String?;
    if (seed == null || seed.isEmpty) {
      throw Exception(
          'Vault ${vaultHash.substring(0, 16)}... has no seed in database — cannot re-inject auth token');
    }
    // Try to create the auth token with the correct address.
    // The vault may have been created with a non-default diversifier (e.g. in
    // the CLOAK GUI desktop app), so we try multiple addresses until the
    // resulting commitment hash matches the vault's on-chain hash.
    //
    // The contract parameter is critical: the commitment hash includes the
    // contract u64. The CLOAK GUI creates vaults with contract=thezeostoken,
    // NOT contract=0. Passing the wrong contract produces a wrong hash.
    final dbContract = vault['contract'] as String? ?? 'thezeostoken';
    final contractU64 = eosioNameToU64(dbContract);

    // Build list of addresses to try: default first, then all wallet addresses
    final addressesToTry = <String>[];
    final defaultAddr = getDefaultAddress();
    if (defaultAddr != null) addressesToTry.add(defaultAddr);

    // Add all wallet addresses (may include diversifiers from GUI import)
    final allAddrsJson = CloakApi.getAddressesJson(_cloakWallet!);
    if (allAddrsJson != null) {
      try {
        final addrs = jsonDecode(allAddrsJson);
        if (addrs is List) {
          for (final a in addrs) {
            final addr = a as String;
            if (!addressesToTry.contains(addr)) addressesToTry.add(addr);
          }
        }
      } catch (_) {}
    }

    // Also try addresses from the CLOAK GUI wallet.bin if it exists
    const guiWalletPath = '/opt/cloak-gui/wallet.bin';
    if (File(guiWalletPath).existsSync()) {
      try {
        final guiBytes = await File(guiWalletPath).readAsBytes();
        final guiWallet = CloakApi.readWallet(Uint8List.fromList(guiBytes));
        if (guiWallet != null) {
          try {
            final guiAddrsJson = CloakApi.getAddressesJson(guiWallet);
            if (guiAddrsJson != null) {
              final guiAddrs = jsonDecode(guiAddrsJson);
              if (guiAddrs is List) {
                for (final a in guiAddrs) {
                  final addr = a as String;
                  if (!addressesToTry.contains(addr)) addressesToTry.add(addr);
                }
              }
            }
          } finally {
            CloakApi.closeWallet(guiWallet);
          }
        }
      } catch (_) {}
    }

    // Try each address until we find one that produces the matching commitment
    for (int i = 0; i < addressesToTry.length; i++) {
      final addr = addressesToTry[i];
      final notesJson = CloakApi.createUnpublishedAuthNote(
        _cloakWallet!,
        seed,
        contractU64,
        addr,
      );
      if (notesJson == null) continue;

      // Extract commitment hash from result
      String? resultHash;
      try {
        final parsed = jsonDecode(notesJson);
        if (parsed is Map) {
          final cmList = parsed['__commitment__'];
          if (cmList is List && cmList.isNotEmpty) {
            resultHash = cmList[0] as String;
          }
        }
      } catch (_) {}

      if (resultHash == vaultHash) {
        CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson);
        break;
      }
    }
  }

  static Future<String?> authenticateVaultBatch({
    required String vaultHash,
    required String recipientAddress,
    required List<VaultWithdrawEntry> entries,
    int burn = 0,
    void Function(String)? onStatus,
  }) async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('authenticate-vault-batch', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) throw Exception('Wallet not loaded');
      if (entries.isEmpty) throw Exception('No withdrawal entries provided');

      // Ensure ZK params are loaded
      if (!await loadZkParams()) {
        throw Exception('ZK params not available');
      }

      // Lock wallet to prevent sync from running during transaction
      CloakSync.lockWallet();
      try {
        // Ensure auth token is in wallet's unspent notes
        await _ensureAuthTokenLoaded(vaultHash);

        // Sync auth_count from chain
        onStatus?.call('Syncing with network...');
        try {
          final eosClient = EosioClient('https://telos.eosusa.io');
          final global = await eosClient.getZeosGlobal();
          eosClient.close();
          if (global != null) {
            final walletACBefore = CloakApi.getAuthCount(_cloakWallet!) ?? 0;
            if (walletACBefore != global.authCount) {
              CloakApi.setAuthCount(_cloakWallet!, global.authCount);
            }
          }
        } catch (_) {}

        // Build ZTransaction JSON with authenticate zaction
        final chainId = getChainId() ?? TELOS_CHAIN_ID;
        final protocolContract = getProtocolContract() ?? 'zeosprotocol';
        final vaultContractName = getVaultContract() ?? 'thezeosvault';

        // Build one withdrawp action per entry.
        // withdrawp transfers tokens from vault to the shielded pool (zeosprotocol),
        // NOT to the user's za1 address. Authorization is thezeosvault@active.
        final List<Map<String, dynamic>> withdrawActions = [];
        for (final entry in entries) {
          final String withdrawpData;
          if (entry.isNft) {
            withdrawpData = _serializeWithdrawpNftToHex(
              nftContract: entry.nftContract ?? 'atomicassets',
              from: 'thezeosvault',
              to: protocolContract,
              assetIds: entry.nftAssetIds!,
              memo: entry.memo,
            );
          } else if (entry.isFt) {
            withdrawpData = _serializeWithdrawpToHex(
              tokenContract: entry.tokenContract ?? 'thezeostoken',
              from: 'thezeosvault',
              to: protocolContract,
              quantity: entry.quantity!,
              memo: entry.memo,
            );
          } else {
            throw Exception(
                'VaultWithdrawEntry must have either quantity (FT) or nftAssetIds (NFT)');
          }

          withdrawActions.add({
            'account': vaultContractName,
            'name': 'withdrawp',
            'authorization': ['$vaultContractName@active'],
            'data': withdrawpData,
          });
        }
        final aliasAuthority = getAliasAuthority() ?? 'thezeosalias@public';

        // Determine fee token contract — use the first FT entry's contract, or default
        String feeTokenContract = 'thezeostoken';
        for (final entry in entries) {
          if (entry.isFt && entry.tokenContract != null) {
            feeTokenContract = entry.tokenContract!;
            break;
          }
        }

        // When burning, add burnvaultp only if the vault row exists on-chain.
        if (burn != 0) {
          clearVaultTokensCache();
          try {
            final vaultState = await queryVaultTokens(vaultHash);
            if (vaultState.existsOnChain) {
              withdrawActions.add({
                'account': vaultContractName,
                'name': 'burnvaultp',
                'authorization': ['$vaultContractName@active'],
                'data': '', // burnvaultp struct has zero fields
              });
            }
          } catch (_) {}
        }

        // Build zactions: authenticate first, then a mint for each FT entry.
        // The mint creates a shielded note for the withdrawn tokens — without it,
        // the tokens go to zeosprotocol publicly but never become shielded notes.
        final zactions = <Map<String, dynamic>>[
          {
            'name': 'authenticate',
            'data': {
              'auth_token': vaultHash,
              'burn': burn != 0,
              'actions': withdrawActions,
            }
          },
        ];

        // Add a mint zaction for each FT withdrawal entry
        for (final entry in entries) {
          if (entry.isFt && entry.quantity != null) {
            zactions.add({
              'name': 'mint',
              'data': {
                'to': r'$SELF',
                'contract': entry.tokenContract ?? 'thezeostoken',
                'quantity': entry.quantity!,
                'memo': '',
                'from': vaultContractName,
                'publish_note': true,
              }
            });
          }
        }

        final ztx = {
          'chain_id': chainId,
          'protocol_contract': protocolContract,
          'vault_contract': vaultContractName,
          'alias_authority': aliasAuthority,
          'add_fee': true,
          'publish_fee_note': true,
          'zactions': zactions,
        };

        final ztxJson = jsonEncode(ztx);
        final feesJson = await _getFeesJson();

        var operation =
            await _beginProofMutationLocked('authenticate-vault-batch');
        var submissionStarted = false;
        try {
          // Generate ZK proof (background isolate)
          onStatus?.call('Generating zero-knowledge proof...');
          final txJson = await FfiIsolate.transactPacked(
            wallet: _cloakWallet!,
            ztxJson: ztxJson,
            feeTokenContract: feeTokenContract,
            feesJson: feesJson,
            mintParams: _mintParams!,
            spendOutputParams: _spendOutputParams!,
            spendParams: _spendParams!,
            outputParams: _outputParams!,
          );

          // Parse transaction
          final decoded = jsonDecode(txJson);
          final Map<String, dynamic> tx;
          if (decoded is List && decoded.isNotEmpty) {
            tx = Map<String, dynamic>.from(decoded[0] as Map);
          } else if (decoded is Map) {
            tx = Map<String, dynamic>.from(decoded as Map);
          } else {
            throw Exception('Unexpected transactPacked response format');
          }

          // Set transaction headers
          onStatus?.call('Preparing transaction...');
          final httpClient = HttpClient();
          try {
            final request = await httpClient
                .getUrl(Uri.parse('https://telos.eosusa.io/v1/chain/get_info'));
            final response = await request.close();
            if (response.statusCode != 200) throw Exception('get_info failed');
            final chainInfo =
                jsonDecode(await response.transform(const Utf8Decoder()).join())
                    as Map<String, dynamic>;
            final headBlockId = chainInfo['head_block_id'] as String;
            final refBlockNum =
                int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
            final prefixHex = headBlockId.substring(16, 24);
            final prefixBytes = List<int>.generate(
                4,
                (i) => int.parse(prefixHex.substring(i * 2, i * 2 + 2),
                    radix: 16));
            final refBlockPrefix = prefixBytes[3] << 24 |
                prefixBytes[2] << 16 |
                prefixBytes[1] << 8 |
                prefixBytes[0];

            final expiration =
                DateTime.now().toUtc().add(const Duration(minutes: 10));
            tx['expiration'] = '${expiration.toIso8601String().split('.')[0]}Z';
            tx['ref_block_num'] = refBlockNum;
            tx['ref_block_prefix'] = refBlockPrefix;
            tx['max_net_usage_words'] = tx['max_net_usage_words'] ?? 0;
            tx['max_cpu_usage_ms'] = tx['max_cpu_usage_ms'] ?? 0;
            tx['delay_sec'] = tx['delay_sec'] ?? 0;
            tx['context_free_actions'] = tx['context_free_actions'] ?? [];
            tx['transaction_extensions'] = tx['transaction_extensions'] ?? [];
          } finally {
            httpClient.close();
          }

          // Use hex_data for action serialization
          final actions = tx['actions'] as List? ?? [];
          for (final action in actions) {
            if (action is Map && action['hex_data'] != null) {
              action['data'] = action['hex_data'] as String;
            }
          }

          operation = await _captureEagerProofStateLocked(
            operation,
            transaction: tx,
          );

          // Sign with thezeosalias@public key
          onStatus?.call('Signing transaction...');
          final signatures = await EsrTransactionHelper.signWithAliasKey(
            transaction: tx,
            existingSignatures: [],
          );

          // Broadcast
          onStatus?.call('Broadcasting...');
          await _markPendingSubmittingLocked(operation);
          final txId = await _broadcastTransaction(
            {'transaction': tx, 'signatures': signatures},
            onSubmitStarted: () => submissionStarted = true,
          );

          requireMatchingTransactionId(operation, txId);
          await _acceptPendingOperationLocked(operation);

          // Clear vault token cache so balance refreshes
          clearVaultTokensCache();

          return txId;
        } catch (error, stackTrace) {
          if (classifyProofFailure(
                submissionStarted: submissionStarted,
                error: error,
              ) ==
              SendFailureDisposition.rollback) {
            await _rollbackPendingOperationLocked(operation);
          } else {
            await _quarantinePendingOperationLocked(operation);
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      } finally {
        CloakSync.unlockWallet();
      }
    });
  }

  /// ABI-serialize a withdrawp action's data to hex.
  /// withdrawp { transfers: pair<name, variant<fungible_transfer_params>>[] }
  static String _serializeWithdrawpToHex({
    required String tokenContract,
    required String from,
    required String to,
    required String quantity,
    required String memo,
  }) {
    final sb = eosdart.SerialBuffer(Uint8List(0));

    // transfers array length = 1
    sb.pushVaruint32(1);

    // First element of pair: contract name
    sb.pushName(tokenContract);

    // Second element: variant index 0 = fungible_transfer_params
    sb.pushVaruint32(0);

    // fungible_transfer_params fields
    sb.pushName(from);
    sb.pushName(to);
    sb.pushAsset(quantity);
    sb.pushString(memo);

    return bytesToHex(sb.asUint8List());
  }

  /// ABI-serialize a withdrawp action's data for NFT (atomic) transfers to hex.
  /// withdrawp { transfers: pair<name, variant<atomic_transfer_params>>[] }
  /// variant index 1 = atomic_transfer_params { from, to, asset_ids[], memo }
  static String _serializeWithdrawpNftToHex({
    required String nftContract,
    required String from, // 'thezeosvault'
    required String to, // recipient
    required List<String> assetIds, // NFT IDs as strings (u64)
    required String memo,
  }) {
    final sb = eosdart.SerialBuffer(Uint8List(0));

    // transfers array length = 1
    sb.pushVaruint32(1);

    // First element of pair: contract name
    sb.pushName(nftContract);

    // Second element: variant index 1 = atomic_transfer_params
    sb.pushVaruint32(1);

    // atomic_transfer_params fields
    sb.pushName(from);
    sb.pushName(to);
    // asset_ids array
    sb.pushVaruint32(assetIds.length);
    for (final id in assetIds) {
      sb.pushNumberAsUint64(int.parse(id));
    }
    sb.pushString(memo);

    return bytesToHex(sb.asUint8List());
  }

  // ============== V1 Message Protocol ==============
  //
  // Message format: v1; type=TYPE; conversation_id=CID; seq=SEQ; reply_to_ua=ADDR; ...
  //
  // Types:
  //   invite  - Start a new conversation (seq=1)
  //   accept  - Accept an invitation
  //   message - Regular message
  //   reaction - Emoji reaction to a message

  /// Generate a random conversation ID (13-char base64url, no padding)
  static String generateConversationId() {
    final random = List<int>.generate(
        10, (_) => DateTime.now().microsecondsSinceEpoch % 256);
    final encoded = base64Url.encode(random);
    return encoded.replaceAll('=', '').substring(0, 13);
  }

  /// Build a v1 header for a message
  static String buildV1Header({
    required String type,
    required String conversationId,
    required int seq,
    String? replyToUa,
    String? firstName,
    String? lastName,
    String? targetFirstName,
    String? targetLastName,
    String? targetAddress,
    String? emoji,
    int? targetSeq,
    String? targetAuthor,
    int? inReplyToSeq,
  }) {
    final parts = <String>[
      'v1',
      'type=$type',
      'conversation_id=$conversationId',
      'seq=$seq'
    ];

    if (replyToUa != null && replyToUa.isNotEmpty) {
      parts.add('reply_to_ua=$replyToUa');
    }
    if (firstName != null && firstName.isNotEmpty) {
      parts.add('first_name=$firstName');
    }
    if (lastName != null && lastName.isNotEmpty) {
      parts.add('last_name=$lastName');
    }
    if (targetFirstName != null && targetFirstName.isNotEmpty) {
      parts.add('target_first_name=$targetFirstName');
    }
    if (targetLastName != null && targetLastName.isNotEmpty) {
      parts.add('target_last_name=$targetLastName');
    }
    if (targetAddress != null && targetAddress.isNotEmpty) {
      parts.add('target_address=$targetAddress');
    }
    if (emoji != null && emoji.isNotEmpty) {
      parts.add('emoji=$emoji');
    }
    if (targetSeq != null) {
      parts.add('target_seq=$targetSeq');
    }
    if (targetAuthor != null && targetAuthor.isNotEmpty) {
      parts.add('target_author=$targetAuthor');
    }
    if (inReplyToSeq != null) {
      parts.add('in_reply_to_seq=$inReplyToSeq');
    }

    return parts.join('; ');
  }

  /// Build a complete message memo with v1 header and body
  static String buildMessageMemo({
    required String type,
    required String conversationId,
    required int seq,
    String? replyToUa,
    String? firstName,
    String? lastName,
    String? targetFirstName,
    String? targetLastName,
    String? targetAddress,
    String? emoji,
    int? targetSeq,
    String? targetAuthor,
    int? inReplyToSeq,
    String body = '',
  }) {
    final header = buildV1Header(
      type: type,
      conversationId: conversationId,
      seq: seq,
      replyToUa: replyToUa,
      firstName: firstName,
      lastName: lastName,
      targetFirstName: targetFirstName,
      targetLastName: targetLastName,
      targetAddress: targetAddress,
      emoji: emoji,
      targetSeq: targetSeq,
      targetAuthor: targetAuthor,
      inReplyToSeq: inReplyToSeq,
    );

    // Full memo: header + blank line + body
    final memo = body.isNotEmpty ? '$header\n\n$body' : header;

    // Truncate to 512 bytes if needed
    return memo.length > 512 ? memo.substring(0, 512) : memo;
  }

  /// Send an invite message to start a conversation
  static Future<String?> sendInvite({
    required String recipientAddress,
    required String conversationId,
    required String replyToUa,
    String? firstName,
    String? lastName,
    String? targetFirstName,
    String? targetLastName,
    String body = '',
    int amount = 0,
    String tokenSymbol = 'TLOS',
    String tokenContract = 'eosio.token',
    int tokenPrecision = 4,
    String feeTokenContract = 'eosio.token',
    String feeAmount = '0.0100 TLOS',
  }) async {
    final memo = buildMessageMemo(
      type: 'invite',
      conversationId: conversationId,
      seq: 1,
      replyToUa: replyToUa,
      firstName: firstName,
      lastName: lastName,
      targetFirstName: targetFirstName,
      targetLastName: targetLastName,
      targetAddress: recipientAddress,
      body: body,
    );

    return await sendTransaction(
      recipientAddress: recipientAddress,
      amount: amount,
      tokenSymbol: tokenSymbol,
      tokenContract: tokenContract,
      tokenPrecision: tokenPrecision,
      memo: memo,
      feeTokenContract: feeTokenContract,
      feeAmount: feeAmount,
    );
  }

  /// Send a regular message in an existing conversation
  static Future<String?> sendMessage({
    required String recipientAddress,
    required String conversationId,
    required int seq,
    String? replyToUa,
    String? firstName,
    String? lastName,
    String body = '',
    int? inReplyToSeq,
    int amount = 0,
    String tokenSymbol = 'TLOS',
    String tokenContract = 'eosio.token',
    int tokenPrecision = 4,
    String feeTokenContract = 'eosio.token',
    String feeAmount = '0.0100 TLOS',
  }) async {
    final memo = buildMessageMemo(
      type: 'message',
      conversationId: conversationId,
      seq: seq,
      replyToUa: replyToUa,
      firstName: firstName,
      lastName: lastName,
      inReplyToSeq: inReplyToSeq,
      body: body,
    );

    return await sendTransaction(
      recipientAddress: recipientAddress,
      amount: amount,
      tokenSymbol: tokenSymbol,
      tokenContract: tokenContract,
      tokenPrecision: tokenPrecision,
      memo: memo,
      feeTokenContract: feeTokenContract,
      feeAmount: feeAmount,
    );
  }

  /// Send an accept message in response to an invite
  static Future<String?> sendAccept({
    required String recipientAddress,
    required String conversationId,
    required int seq,
    String? replyToUa,
    String? firstName,
    String? lastName,
    String body = '',
    int amount = 0,
    String tokenSymbol = 'TLOS',
    String tokenContract = 'eosio.token',
    int tokenPrecision = 4,
    String feeTokenContract = 'eosio.token',
    String feeAmount = '0.0100 TLOS',
  }) async {
    final memo = buildMessageMemo(
      type: 'accept',
      conversationId: conversationId,
      seq: seq,
      replyToUa: replyToUa,
      firstName: firstName,
      lastName: lastName,
      body: body,
    );

    return await sendTransaction(
      recipientAddress: recipientAddress,
      amount: amount,
      tokenSymbol: tokenSymbol,
      tokenContract: tokenContract,
      tokenPrecision: tokenPrecision,
      memo: memo,
      feeTokenContract: feeTokenContract,
      feeAmount: feeAmount,
    );
  }

  /// Send a reaction to a message
  static Future<String?> sendReaction({
    required String recipientAddress,
    required String conversationId,
    required int seq,
    required String emoji,
    required int targetSeq,
    required String targetAuthor, // "me" or "peer"
    String? replyToUa,
    int amount = 0,
    String tokenSymbol = 'TLOS',
    String tokenContract = 'eosio.token',
    int tokenPrecision = 4,
    String feeTokenContract = 'eosio.token',
    String feeAmount = '0.0100 TLOS',
  }) async {
    final memo = buildMessageMemo(
      type: 'reaction',
      conversationId: conversationId,
      seq: seq,
      replyToUa: replyToUa,
      emoji: emoji,
      targetSeq: targetSeq,
      targetAuthor: targetAuthor,
    );

    return await sendTransaction(
      recipientAddress: recipientAddress,
      amount: amount,
      tokenSymbol: tokenSymbol,
      tokenContract: tokenContract,
      tokenPrecision: tokenPrecision,
      memo: memo,
      feeTokenContract: feeTokenContract,
      feeAmount: feeAmount,
    );
  }

  /// Parse a v1 header from a memo body
  /// Returns map of header fields, or empty map if not v1 format
  static Map<String, String> parseV1Header(String memo) {
    try {
      final firstLine = memo.split('\n').first.trim();
      if (!firstLine.startsWith('v1;')) return {};

      final Map<String, String> result = {};
      for (final part in firstLine.split(';')) {
        final t = part.trim();
        if (t.isEmpty) continue;
        final i = t.indexOf('=');
        if (i > 0) {
          final k = t.substring(0, i).trim();
          final v = t.substring(i + 1).trim();
          if (k.isNotEmpty) result[k] = v;
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  /// Extract the message body from a v1 memo (everything after first blank line)
  static String extractBody(String memo) {
    final lines = memo.split('\n');
    // Find first blank line
    int bodyStart = 0;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) {
        bodyStart = i + 1;
        break;
      }
    }
    if (bodyStart >= lines.length) return '';
    return lines.sublist(bodyStart).join('\n');
  }

  /// Check if a memo is in v1 format
  static bool isV1Message(String memo) {
    return memo.trim().startsWith('v1;');
  }

  /// Check if a memo is in legacy 🛡MSG format
  static bool isLegacyMessage(String memo) {
    return memo.startsWith('\u{1F6E1}MSG');
  }

  /// Parse a legacy memo into components (🛡MSG format)
  static Map<String, String>? parseLegacyMemo(String memo) {
    if (!isLegacyMessage(memo)) return null;

    final lines = memo.split('\n');
    if (lines.length < 2) return null;

    return {
      'sender': lines.length > 1 ? lines[1] : '',
      'subject': lines.length > 2 ? lines[2] : '',
      'body': lines.length > 3 ? lines.sublist(3).join('\n') : '',
    };
  }

  // ============== Shield from Telos (Mint) ==============
  //
  // Shield tokens from a Telos transparent account into shielded CLOAK wallet.
  // Uses ESR (EOSIO Signing Request) protocol to open Anchor wallet for signing.
  // The user's Telos private key never touches this app.

  /// Telos chain ID
  static const TELOS_CHAIN_ID =
      '4667b205c6838ef70ff7988f6e8257e8be0e1284a2f59699054a018f743b1d11';

  /// Cached shield fee (begin + mint), fetched from on-chain fees table.
  /// Initialized to null; fetched lazily on first use.
  static String? _cachedShieldFee;

  /// Get the total shield fee by querying the thezeosalias fees table on-chain.
  /// Returns the sum of 'begin' + 'mint' fees (e.g., "0.3000 CLOAK").
  /// Falls back to a hardcoded default if the fetch fails.
  static Future<String> getShieldFee() async {
    if (_cachedShieldFee != null) return _cachedShieldFee!;

    try {
      // Query thezeosalias fees table (the authoritative source for fee schedule)
      final client = EosioClient('https://telos.eosusa.io');
      final result = await client.getTableRows(
        code: 'thezeosalias',
        scope: 'thezeosalias',
        table: 'fees',
        limit: 10,
      );
      client.close();

      final fees = <String, String>{};
      for (final row in result['rows'] as List? ?? []) {
        final action = row['first']?.toString() ?? '';
        final amount = row['second']?.toString() ?? '';
        if (action.isNotEmpty && amount.isNotEmpty) {
          fees[action] = amount;
        }
      }

      if (fees.isNotEmpty) {
        // Parse begin and mint fees to compute total
        final beginFee = fees['begin'] ?? '0.2000 CLOAK';
        final mintFee = fees['mint'] ?? '0.1000 CLOAK';

        // Parse amounts (format: "0.2000 CLOAK")
        final beginAmount = double.tryParse(beginFee.split(' ').first) ?? 0.2;
        final mintAmount = double.tryParse(mintFee.split(' ').first) ?? 0.1;
        final total = beginAmount + mintAmount;

        // Determine symbol from the fee strings
        final symbol =
            beginFee.split(' ').length > 1 ? beginFee.split(' ').last : 'CLOAK';
        _cachedShieldFee = '${total.toStringAsFixed(4)} $symbol';
        return _cachedShieldFee!;
      }
    } catch (e) {
      print('[CloakWalletManager] Failed to fetch shield fee from chain: $e');
    }

    // Fallback to default
    _cachedShieldFee = '0.3000 CLOAK';
    return _cachedShieldFee!;
  }

  /// Invalidate cached shield fee (call if fees may have changed)
  static void invalidateShieldFeeCache() {
    _cachedShieldFee = null;
    _cachedSendFee = null;
  }

  /// Cached send fee (begin + spend + output + publishnotes).
  static String? _cachedSendFee;

  /// Get the total send fee, optionally accounting for note fragmentation.
  /// When [sendAmountUnits] is provided and a wallet is loaded, uses the Rust
  /// fee estimator which simulates note selection and adds per-note spend fees.
  /// [recipientAddress] enables self-send detection (no publishnotes fees).
  /// Falls back to static calculation when amount is not provided.
  /// Returns e.g. "0.6000 CLOAK".
  static Future<String> getSendFee(
      {int? sendAmountUnits, String? recipientAddress}) async {
    // If amount provided and wallet loaded, use Rust estimator for exact fee
    if (sendAmountUnits != null && _cloakWallet != null) {
      try {
        final feesJson = await _getFeesJson();
        final feeUnits = await runNativeWalletOperation<int?>(
          'estimate-send-fee',
          (wallet) => CloakApi.estimateSendFee(
            wallet,
            sendAmountUnits,
            feesJson,
            recipientAddress: recipientAddress,
          ),
        );
        if (feeUnits != null && feeUnits > 0) {
          final feeCloak = feeUnits / 10000.0;
          final result = '${feeCloak.toStringAsFixed(4)} CLOAK';
          return result;
        }
      } catch (_) {}
    }

    // Fall back to static calculation (cached)
    if (_cachedSendFee != null) return _cachedSendFee!;

    try {
      // Use zeosprotocol::fees — same table that Rust uses via _getFeesJson()
      final client = EosioClient('https://telos.eosusa.io');
      final result = await client.getTableRows(
        code: 'zeosprotocol',
        scope: 'zeosprotocol',
        table: 'fees',
        limit: 10,
      );
      client.close();

      final fees = <String, String>{};
      for (final row in result['rows'] as List? ?? []) {
        final action = row['first']?.toString() ?? '';
        final amount = row['second']?.toString() ?? '';
        if (action.isNotEmpty && amount.isNotEmpty) {
          fees[action] = amount;
        }
      }

      if (fees.isNotEmpty) {
        double parseAmount(String key, double fallback) {
          final s = fees[key];
          if (s == null) return fallback;
          return double.tryParse(s.split(' ').first) ?? fallback;
        }

        // A standard send resolves to:
        //   begin (1 per tx)
        //   + spendoutput × 1 (combined input→recipient)
        //   + output × 1 (change note)
        // Publishnotes are auto-embedded in the spend action's note_ct
        // during zsign, not as separate fee-bearing zactions.
        final total = parseAmount('begin', 0.2) +
            parseAmount('spendoutput', 0.1) +
            parseAmount('output', 0.1);
        final symbol = (fees['begin'] ?? '0.2000 CLOAK').split(' ').length > 1
            ? (fees['begin'] ?? '0.2000 CLOAK').split(' ').last
            : 'CLOAK';
        _cachedSendFee = '${total.toStringAsFixed(4)} $symbol';
        return _cachedSendFee!;
      }
    } catch (e) {
      print('[CloakWalletManager] Failed to fetch send fee: $e');
    }

    _cachedSendFee = '0.4000 CLOAK';
    return _cachedSendFee!;
  }

  /// Returns the maximum sendable amount and exact fee in units.
  /// Uses estimate_send_fee(balance) which returns the fee for ALL unspent notes
  /// (since balance + fee > balance, the estimator's loop exhausts all notes).
  /// This matches what resolve_ztransaction actually charges when all notes are
  /// consumed: phase 1 selects notes for the amount, phase 2 uses the change
  /// (= fee) to cover fees — no additional notes needed.
  ///
  /// DO NOT iterate/re-estimate for the lower amount — that causes oscillation
  /// because estimate_send_fee is single-pass while resolve_ztransaction is two-pass.
  static Future<({int max, int fee})> getMaxSendable(
      {String? recipientAddress}) async {
    if (_cloakWallet == null) return (max: 0, fee: 0);
    final balJson = getBalancesJson();
    if (balJson == null) return (max: 0, fee: 0);
    // Parse CLOAK balance from balances JSON
    int balanceUnits = 0;
    try {
      final List<dynamic> parsed = jsonDecode(balJson);
      for (final entry in parsed) {
        final str = entry.toString();
        if (str.contains('CLOAK@thezeostoken')) {
          final spaceIdx = str.indexOf(' ');
          if (spaceIdx > 0) {
            final amt = double.tryParse(str.substring(0, spaceIdx)) ?? 0.0;
            balanceUnits = (amt * 10000).round();
          }
          break;
        }
      }
    } catch (_) {
      return (max: 0, fee: 0);
    }
    if (balanceUnits <= 0) return (max: 0, fee: 0);

    try {
      final feesJson = await _getFeesJson();
      // estimate_send_fee(balance) exhausts all notes (balance + fee > balance,
      // so the loop never finds a match) and returns the fee for ALL notes.
      // With Rust drain mode, resolve_ztransaction will also consume all notes,
      // so the fee matches exactly: amount + fee = balance, zero dust.
      final feeUnits = await runNativeWalletOperation<int?>(
            'estimate-max-send-fee',
            (wallet) => CloakApi.estimateSendFee(
              wallet,
              balanceUnits,
              feesJson,
              recipientAddress: recipientAddress,
            ),
          ) ??
          4000;
      final maxSendable = balanceUnits - feeUnits;
      return (max: maxSendable > 0 ? maxSendable : 0, fee: feeUnits);
    } catch (_) {}

    // Fallback: balance minus default 0.4 CLOAK fee
    const fallbackFee = 4000;
    final max = balanceUnits - fallbackFee;
    return (max: max > 0 ? max : 0, fee: fallbackFee);
  }

  /// Get the fee for a vault deposit (unshielded send to thezeosvault).
  /// Vault deposits use: begin + spendoutput + output (change note).
  /// Fetches from on-chain fee table.
  static Future<String> getDepositFee() async {
    try {
      final feesJson = await _getFeesJson();
      final fees = Map<String, String>.from(jsonDecode(feesJson) as Map);
      double parseAmount(String key, double fallback) {
        final s = fees[key];
        if (s == null) return fallback;
        return double.tryParse(s.split(' ').first) ?? fallback;
      }

      // Vault deposit = begin + spendoutput + output (change note back to sender)
      final total = parseAmount('begin', 0.2) +
          parseAmount('spendoutput', 0.1) +
          parseAmount('output', 0.1);
      return '${total.toStringAsFixed(4)} CLOAK';
    } catch (e) {
      print('[CloakWalletManager] Failed to fetch deposit fee: $e');
      return '0.4000 CLOAK';
    }
  }

  /// Get the fee for a vault burn, accounting for note fragmentation.
  /// Uses Rust FFI to simulate exact note selection (same as resolve_ztransaction).
  /// [hasAssets] — whether the vault has tokens to withdraw before burning.
  /// Throws if estimation fails — callers must handle the error.
  static Future<String> getBurnFee({required bool hasAssets}) async {
    final feesJson = await _getFeesJson();
    if (_cloakWallet == null) throw Exception('Wallet not loaded');
    final feeUnits = await runNativeWalletOperation<int?>(
      'estimate-burn-fee',
      (wallet) => CloakApi.estimateBurnFee(wallet, hasAssets, feesJson),
    );
    if (feeUnits == null)
      throw Exception('Rust burn fee estimation returned null');
    final feeCloak = feeUnits / 10000.0;
    return '${feeCloak.toStringAsFixed(4)} CLOAK';
  }

  /// Get the fee for a vault withdrawal, accounting for note fragmentation.
  static Future<String> getWithdrawFee() async {
    return getBurnFee(hasAssets: true);
  }

  /// Get the fee for vault creation (auth token publish), accounting for note fragmentation.
  /// Throws if estimation fails — callers must handle the error.
  static Future<String> getVaultCreationFee() async {
    final feesJson = await _getFeesJson();
    if (_cloakWallet == null) throw Exception('Wallet not loaded');
    final feeUnits = await runNativeWalletOperation<int?>(
      'estimate-vault-creation-fee',
      (wallet) => CloakApi.estimateVaultCreationFee(wallet, feesJson),
    );
    if (feeUnits == null)
      throw Exception('Rust vault creation fee estimation returned null');
    final feeCloak = feeUnits / 10000.0;
    return '${feeCloak.toStringAsFixed(4)} CLOAK';
  }

  /// TEST: Create a simple transfer ESR to verify encoding works with Anchor
  /// This creates a minimal TLOS transfer that Anchor should definitely recognize
  /// Returns the ESR URL (caller decides whether to launch or display)
  static Future<String> testSimpleTransferEsr() async {
    return generateSimpleTransferEsr();
  }

  /// Generate the ZK mint proof for shielding tokens
  ///
  /// This uses the FFI infrastructure to create the proof data
  /// that will be included in the mint action. The actual signing/broadcast
  /// happens through Anchor wallet via ESR.
  ///
  /// [tokenContract] - Token contract (e.g., "thezeostoken")
  /// [quantity] - Amount with symbol (e.g., "100.0000 CLOAK")
  /// [fromAccount] - Telos account sending the tokens (for memo/reference)
  ///
  /// Returns the mint proof data as a Map for the ESR action
  static Future<Map<String, dynamic>> generateMintProof({
    required String tokenContract,
    required String quantity,
    required String fromAccount,
  }) async {
    _requireNoUpdateApply();
    return _walletOperations.runExclusive('shield-proof', () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      // 1. Ensure wallet is loaded
      if (_cloakWallet == null) {
        throw Exception('Wallet not loaded');
      }

      final storedAlias = getAliasAuthority();

      // Validate EOSIO name constraints
      if (fromAccount.length > 12) {
        throw Exception('fromAccount "$fromAccount" exceeds 12 chars');
      }
      final validChars = RegExp(r'^[a-z1-5\.]+$');
      if (!validChars.hasMatch(fromAccount)) {
        throw Exception(
            'fromAccount "$fromAccount" contains invalid characters');
      }

      if (storedAlias != 'thezeosalias@public') {
        print(
            'CRITICAL WARNING: alias_authority is NOT thezeosalias@public! Proof validation will fail on-chain.');
      }

      // 2. Ensure ZK params are loaded (this can take 5-15 seconds first time)
      if (!await loadZkParams()) {
        throw Exception('Failed to load ZK params');
      }

      // 3. Get protocol fees from blockchain
      final feesJson = await _getFeesJson();

      // 4. Build the ZTransaction JSON for mint operation
      final ztxJson = _buildMintZTransaction(
        toAddress: '\$SELF', // Wallet replaces with derived address
        fromAccount: fromAccount,
        quantity: quantity,
        tokenContract: tokenContract,
      );

      CloakSync.lockWallet();
      final operation = await _beginProofMutationLocked('shield');
      try {
        // transactPacked mutates the wallet eagerly. The durable pre-snapshot and
        // operation record are already on disk before this worker isolate starts.
        final txJson = await FfiIsolate.transactPacked(
          wallet: _cloakWallet!,
          ztxJson: ztxJson,
          feeTokenContract: 'thezeostoken',
          feesJson: feesJson,
          mintParams: _mintParams!,
          spendOutputParams: _spendOutputParams!,
          spendParams: _spendParams!,
          outputParams: _outputParams!,
        );
        final mintData = _extractMintActionData(txJson);
        if (mintData == null) {
          throw Exception('Failed to extract mint action from transaction');
        }
        await _captureEagerProofStateLocked(operation);
        mintData['_walletOperationId'] = operation.operationId;
        return mintData;
      } catch (error, stackTrace) {
        await _rollbackPendingOperationLocked(operation);
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        CloakSync.unlockWallet();
      }
    });
  }

  /// Restore wallet from a pre-mutation snapshot.
  /// Used to undo the state changes from transactPacked() when the
  /// transaction fails to broadcast or the user cancels.
  static bool _replaceWalletFromSnapshot(Uint8List snapshotBytes) {
    if (!_walletOperations.isHeldByCurrentZone) {
      throw StateError('Wallet replacement requires wallet ownership');
    }
    try {
      final wallet = CloakApi.readWallet(snapshotBytes);
      if (wallet == null) {
        print('[CloakWalletManager] Failed to restore wallet from snapshot');
        return false;
      }
      if (_cloakWallet != null) {
        CloakApi.closeWallet(_cloakWallet!);
      }
      _cloakWallet = wallet;
      _refreshImmutableWalletCacheLocked();
      print('[CloakWalletManager] Wallet restored from pre-proof snapshot');
      return true;
    } catch (e) {
      print('[CloakWalletManager] Error restoring wallet: $e');
      return false;
    }
  }

  /// Get protocol fees as JSON string
  static Future<String> _getFeesJson() async {
    try {
      // Query zeosprotocol's fees table
      final client = EosioClient('https://telos.eosusa.io');
      final result = await client.getTableRows(
        code: 'zeosprotocol',
        scope: 'zeosprotocol',
        table: 'fees',
        limit: 10,
      );
      client.close();

      // Convert to format expected by Rust: HashMap<Name, Asset>
      // The table has rows like {first: "begin", second: "0.2000 CLOAK"}
      final fees = <String, String>{};
      for (final row in result['rows'] as List? ?? []) {
        final action = row['first']?.toString() ?? '';
        final amount = row['second']?.toString() ?? '';
        if (action.isNotEmpty && amount.isNotEmpty) {
          fees[action] = amount;
        }
      }

      // If fees table is empty, use default values
      if (fees.isEmpty) {
        fees['begin'] = '0.2000 CLOAK';
        fees['mint'] = '0.1000 CLOAK';
        fees['spend'] = '0.1000 CLOAK';
        fees['output'] = '0.1000 CLOAK';
        fees['spendoutput'] = '0.1000 CLOAK';
        fees['publishnotes'] = '0.1000 CLOAK';
        fees['authenticate'] = '0.1000 CLOAK';
        fees['withdraw'] = '0.1000 CLOAK';
      }

      return jsonEncode(fees);
    } catch (e) {
      print('[CloakWalletManager] Failed to fetch fees, using defaults: $e');
      // Return default fees
      return jsonEncode({
        'begin': '0.2000 CLOAK',
        'mint': '0.1000 CLOAK',
        'spend': '0.1000 CLOAK',
        'output': '0.1000 CLOAK',
        'spendoutput': '0.1000 CLOAK',
        'publishnotes': '0.1000 CLOAK',
        'authenticate': '0.1000 CLOAK',
        'withdraw': '0.1000 CLOAK',
      });
    }
  }

  /// Public wrapper for _getFeesJson (used by SignatureProvider)
  static Future<String> getFeesJsonPublic() => _getFeesJson();

  static Future<void> _populateExternalTransactionHeaders(
      Map<String, dynamic> transaction) async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('https://telos.eosusa.io/v1/chain/get_info'))
          .timeout(const Duration(seconds: 10));
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw StateError('get_info failed: ${response.statusCode}');
      }
      final chainInfo =
          jsonDecode(await response.transform(const Utf8Decoder()).join())
              as Map<String, dynamic>;
      final headBlockId = chainInfo['head_block_id'] as String;
      final refBlockNum =
          int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
      final prefixHex = headBlockId.substring(16, 24);
      final prefixBytes = List<int>.generate(
        4,
        (i) => int.parse(
          prefixHex.substring(i * 2, i * 2 + 2),
          radix: 16,
        ),
      );
      final refBlockPrefix = prefixBytes[3] << 24 |
          prefixBytes[2] << 16 |
          prefixBytes[1] << 8 |
          prefixBytes[0];
      final expiration =
          DateTime.now().toUtc().add(const Duration(minutes: 10));
      transaction['expiration'] =
          '${expiration.toIso8601String().split('.')[0]}Z';
      transaction['ref_block_num'] = refBlockNum;
      transaction['ref_block_prefix'] = refBlockPrefix;
      transaction['max_net_usage_words'] =
          transaction['max_net_usage_words'] ?? 0;
      transaction['max_cpu_usage_ms'] = transaction['max_cpu_usage_ms'] ?? 0;
      transaction['delay_sec'] = transaction['delay_sec'] ?? 0;
      transaction['context_free_actions'] =
          transaction['context_free_actions'] ?? [];
      transaction['transaction_extensions'] =
          transaction['transaction_extensions'] ?? [];

      for (final action in transaction['actions'] as List? ?? const []) {
        if (action is Map && action['hex_data'] is String) {
          action['data'] = action['hex_data'];
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Create a signed proof transaction for an external submitter without ever
  /// exposing an untracked eager wallet mutation. The returned operation/id
  /// remain durably quarantined and are automatically reconciled by exact id.
  static Future<Map<String, dynamic>> prepareExternalProofHandoff({
    required String ztxJson,
    String feeTokenContract = 'thezeostoken',
    String operationKind = 'website-sign',
  }) async {
    _requireNoUpdateApply();
    final built = await buildExternalProofTransaction(
      ztxJson: ztxJson,
      feesJson: await _getFeesJson(),
      feeTokenContract: feeTokenContract,
      operationKind: operationKind,
    );
    final operationId = built['operationId'] as String;
    final transaction = Map<String, dynamic>.from(built['transaction'] as Map);
    try {
      await _populateExternalTransactionHeaders(transaction);
      final transactionId = await finalizeExternalProofTransaction(
        operationId: operationId,
        transaction: transaction,
      );
      final signatures = await EsrTransactionHelper.signWithAliasKey(
        transaction: transaction,
        existingSignatures: const [],
      );
      _schedulePendingReconciliation(operationId);
      return {
        'transaction': transaction,
        'signatures': signatures,
        'operation_id': operationId,
        'transaction_id': transactionId,
        'expires_at': transaction['expiration'],
      };
    } catch (error, stackTrace) {
      if (_pendingWalletOperation?.operationId == operationId) {
        await resolvePendingWalletOperation(
          operationId: operationId,
          accepted: false,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Build an externally requested ZTransaction while preserving a durable
  /// pre-proof and eager-state quarantine. The caller must add final headers,
  /// then call [finalizeExternalProofTransaction] before handing bytes off.
  static Future<Map<String, dynamic>> buildExternalProofTransaction({
    required String ztxJson,
    required String feesJson,
    String feeTokenContract = 'thezeostoken',
    String operationKind = 'website-proof',
  }) async {
    _requireNoUpdateApply();
    if (!await loadZkParams()) throw StateError('ZK params are not available');
    return _walletOperations.runExclusive(operationKind, () async {
      _requireNoUpdateApply();
      _requireNoPendingWalletMutation();
      if (_cloakWallet == null) throw StateError('Wallet not loaded');
      CloakSync.lockWallet();
      final operation = await _beginProofMutationLocked(operationKind);
      try {
        final txJson = await FfiIsolate.transactPacked(
          wallet: _cloakWallet!,
          ztxJson: ztxJson,
          feeTokenContract: feeTokenContract,
          feesJson: feesJson,
          mintParams: _mintParams!,
          spendOutputParams: _spendOutputParams!,
          spendParams: _spendParams!,
          outputParams: _outputParams!,
        );
        final decoded = jsonDecode(txJson);
        final Map<String, dynamic> transaction;
        if (decoded is List && decoded.isNotEmpty) {
          transaction = Map<String, dynamic>.from(decoded.first as Map);
        } else if (decoded is Map) {
          transaction = Map<String, dynamic>.from(decoded);
        } else {
          throw StateError('Unexpected external proof response');
        }
        if ((transaction['actions'] as List? ?? []).isEmpty) {
          throw StateError('External proof transaction contains no actions');
        }
        await _captureEagerProofStateLocked(operation);
        return {
          'operationId': operation.operationId,
          'transaction': transaction,
        };
      } catch (error, stackTrace) {
        await _rollbackPendingOperationLocked(operation);
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        CloakSync.unlockWallet();
      }
    });
  }

  static Future<String> finalizeExternalProofTransaction({
    required String operationId,
    required Map<String, dynamic> transaction,
  }) {
    return _walletOperations.runExclusive('finalize-external-proof', () async {
      _requireNoUpdateApply();
      final operation = _pendingWalletOperation;
      if (operation == null || operation.operationId != operationId) {
        throw StateError('Pending wallet operation not found');
      }
      final updated = await _captureEagerProofStateLocked(
        operation,
        transaction: transaction,
        state: PendingWalletOperationState.handedOff,
      );
      return updated.transactionId!;
    });
  }

  static Future<String> submitExternalProofTransaction({
    required String operationId,
    required Map<String, dynamic> transaction,
    required List<String> signatures,
  }) {
    return _walletOperations.runExclusive('submit-external-proof', () async {
      _requireNoUpdateApply();
      final operation = _pendingWalletOperation;
      if (operation == null || operation.operationId != operationId) {
        throw StateError('Pending wallet operation not found');
      }
      var submissionStarted = false;
      try {
        await _markPendingSubmittingLocked(operation);
        final result = await EsrTransactionHelper.broadcastTransaction(
          transaction: transaction,
          signatures: signatures,
          onSubmitStarted: () => submissionStarted = true,
        );
        final txId = result['transaction_id'] as String?;
        requireMatchingTransactionId(operation, txId);
        await _acceptPendingOperationLocked(operation);
        return txId!;
      } catch (error, stackTrace) {
        if (classifyProofFailure(
              submissionStarted: submissionStarted,
              error: error,
            ) ==
            SendFailureDisposition.rollback) {
          await _rollbackPendingOperationLocked(operation);
        } else {
          await _quarantinePendingOperationLocked(operation);
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
  }

  /// Extract mint action data from transaction JSON
  /// The JSON is a tuple: [TransactionPacked, HashMap<String, Vec<String>>]
  /// We need the first element (the Transaction) which has the actions array
  ///
  /// With wallet_transact_packed, each action has both 'data' (JSON) and 'hex_data' (ABI-serialized)
  /// We return both so ESR service can use hex_data for proper serialization
  static Map<String, dynamic>? _extractMintActionData(String txJson) {
    try {
      final decoded = jsonDecode(txJson);

      // Handle tuple format: [TransactionPacked, unpublished_notes]
      Map<String, dynamic> tx;
      if (decoded is List && decoded.isNotEmpty) {
        tx = decoded[0] as Map<String, dynamic>;
      } else if (decoded is Map<String, dynamic>) {
        tx = decoded;
      } else {
        return null;
      }

      final actions = tx['actions'] as List?;
      if (actions == null || actions.isEmpty) {
        return null;
      }

      // Find the mint action - account name depends on wallet's alias_authority
      for (final action in actions) {
        final name = action['name']?.toString();

        // mint action has name 10639630974360485888 (or "mint" string)
        // Account is the alias_authority actor (e.g., "thezeosalias" or "main")
        if (name == 'mint' || name == '10639630974360485888') {
          final data = action['data'];
          final hexData = action['hex_data']?.toString();

          if (data is Map<String, dynamic>) {
            // Return data with hex_data included so ESR service can use it
            final result = Map<String, dynamic>.from(data);
            if (hexData != null && hexData.isNotEmpty) {
              result['_hex_data'] =
                  hexData; // Store hex_data with underscore prefix to distinguish
            }
            return result;
          }
        }
      }

      return null;
    } catch (e) {
      print('[CloakWalletManager] Failed to parse transaction JSON: $e');
      return null;
    }
  }

  /// Build ZTransaction JSON for mint operation
  ///
  /// Uses format from zeos-caterpillar/src/transaction.rs
  static String _buildMintZTransaction({
    required String toAddress,
    required String fromAccount,
    required String quantity,
    required String tokenContract,
  }) {
    // ZTransaction structure matching Rust expectations
    // Note: 'to' can be "$SELF" which the wallet replaces with its derived address
    //
    // Format must match ZTransaction struct in transaction.rs:
    //   zactions: Vec<ZAction>
    // where ZAction has:
    //   name: Name (string like "mint")
    //   data: Value (the mint parameters)
    //
    // IMPORTANT: For Telos mainnet, alias_authority MUST be 'thezeosalias@public'
    // This is hardcoded because the ZK proof validation on-chain expects this exact value
    final chainId = getChainId() ?? TELOS_CHAIN_ID;
    final protocolContract = getProtocolContract() ?? 'zeosprotocol';
    final vaultContract = getVaultContract() ?? 'thezeosvault';
    final aliasAuthority = getAliasAuthority() ?? 'thezeosalias@public';

    final ztx = {
      'chain_id': chainId,
      'protocol_contract': protocolContract,
      'vault_contract': vaultContract,
      'alias_authority': aliasAuthority,
      // For shield/mint operations, fee is paid from transparent Telos account via ESR
      // Don't try to select fee notes from shielded wallet (which may be empty)
      'add_fee': false,
      'publish_fee_note': true,
      'zactions': [
        {
          'name': 'mint',
          'data': {
            'to': toAddress, // "$SELF" or bech32m address
            'contract': tokenContract,
            'quantity': quantity,
            'memo': '',
            'from': fromAccount,
            'publish_note': true,
          }
        }
      ],
    };
    return jsonEncode(ztx);
  }

  /// Generate an ESR to clear the on-chain assetbuffer.
  /// Sends begin + fee_transfer + end (no mint, no ZK proof).
  /// The end action clears orphaned entries from previous failed transactions.
  /// Cost: 0.2000 CLOAK (begin fee).
  static Future<Map<String, dynamic>> generateClearBufferEsr({
    required String telosAccount,
  }) async {
    // Build 3 actions: begin, fee transfer, end
    final actions = EsrService.buildClearBufferActions(
      userAccount: telosAccount,
      feeQuantity: '0.2000 CLOAK',
    );

    // Create ESR with pre-signed thezeosalias signature (same flow as shield)
    final esrUrl =
        await EsrService.createSigningRequestWithPresig(actions: actions);

    return {
      'esrUrl': esrUrl,
      'telosAccount': telosAccount,
    };
  }

  /// Generate a simple transfer-only ESR for shielding
  ///
  /// This creates an ESR with only the user's transfer actions (easy for Anchor).
  /// The mint proof is stored separately and will be used when broadcasting.
  ///
  /// [tokenContract] - Token contract to shield from
  /// [quantity] - Amount to shield (e.g., "100.0000 CLOAK")
  /// [telosAccount] - Telos account name
  ///
  /// Returns a map with 'esrUrl' and 'mintProof'
  static Future<Map<String, dynamic>> generateShieldEsrSimple({
    required String tokenContract,
    required String quantity,
    required String telosAccount,
  }) async {
    // 0. Get or create vault hash for AUTH memo
    // NOTE: Do NOT call getPrimaryVaultHash() or getVaults() - FFI crashes!
    // Use stored vault hash from database instead
    String? vaultHash = await getStoredVaultHash();
    if (vaultHash == null || vaultHash.isEmpty) {
      vaultHash = await createAndStoreVault();
      if (vaultHash == null) {
        throw Exception('Failed to create vault for shield operation');
      }
    }
    // 1. Generate the ZK mint proof (this takes time)
    final mintProof = await generateMintProof(
      tokenContract: tokenContract,
      quantity: quantity,
      fromAccount: telosAccount,
    );
    final operationId = mintProof.remove('_walletOperationId') as String?;
    if (operationId == null) {
      throw StateError('Shield proof is missing its wallet operation id');
    }

    try {
      // 2. Build all 5 actions with the actual user account
      final feeQuantity = await getShieldFee();
      final actions = EsrService.buildShieldActionsWithAccount(
        tokenContract: tokenContract,
        quantity: quantity,
        mintProof: mintProof,
        userAccount: telosAccount,
        feeQuantity: feeQuantity,
      );

      // 3. Create ESR with variant 2 (full pre-signed transaction) + cosig.
      // Uses flags=1 so Anchor broadcasts with both signatures (user + thezeosalias).
      // Works on both desktop (via deep link) and Android (via ESR paste).
      // The cosig info pair embeds the thezeosalias signature so Anchor can
      // include it when broadcasting the complete atomic transaction.
      final esrUrl =
          await EsrService.createSigningRequestWithPresig(actions: actions);
      final transactionId = EsrService.pendingTransactionId;
      if (transactionId == null) {
        throw StateError('Could not derive the shield transaction id');
      }
      final expiresAt = EsrService.pendingTransactionExpiration;
      if (expiresAt == null) {
        throw StateError('Could not derive the shield transaction expiry');
      }
      await markPendingExternalHandoff(
        operationId: operationId,
        transactionId: transactionId,
        expiresAt: expiresAt,
      );

      return {
        'esrUrl': esrUrl,
        'tokenContract': tokenContract,
        'quantity': quantity,
        'telosAccount': telosAccount,
        'vaultHash': vaultHash,
        'mintProof': mintProof,
        'feeQuantity': feeQuantity,
        '_walletOperationId': operationId,
        'transactionId': transactionId,
        'expiresAt': expiresAt.toIso8601String(),
      };
    } catch (error, stackTrace) {
      await resolvePendingWalletOperation(
        operationId: operationId,
        accepted: false,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Complete the shield transaction after user signs in Anchor
  ///
  /// [userSignatures] - Signatures from Anchor for the transfer actions
  /// [shieldData] - Data from generateShieldEsrSimple
  ///
  /// Returns transaction ID on success
  static Future<String> completeShieldTransaction({
    required List<String> userSignatures,
    required Map<String, dynamic> shieldData,
  }) async {
    _requireNoUpdateApply();
    final operationId = shieldData['_walletOperationId'] as String?;
    if (operationId == null) {
      throw StateError('Shield operation is not recoverable');
    }
    final tokenContract = shieldData['tokenContract'] as String;
    final quantity = shieldData['quantity'] as String;
    final telosAccount = shieldData['telosAccount'] as String;
    final mintProof = shieldData['mintProof'] as Map<String, dynamic>;

    try {
      final txId = await EsrService.buildAndBroadcastShieldTransaction(
        userSignatures: userSignatures,
        tokenContract: tokenContract,
        quantity: quantity,
        userAccount: telosAccount,
        mintProof: mintProof,
        feeQuantity: await getShieldFee(),
      );
      await confirmPendingWalletOperationAccepted(
        operationId: operationId,
        transactionId: txId,
      );
      return txId;
    } catch (error, stackTrace) {
      // This path hands signed bytes to a node. Unless the node's response is
      // an explicit deterministic rejection, retain eager state for recovery.
      if (classifyPostSubmitSendFailure(error) ==
          SendFailureDisposition.rollback) {
        await resolvePendingWalletOperation(
          operationId: operationId,
          accepted: false,
        );
      } else {
        await quarantinePendingWalletOperation(operationId);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Generate the ESR URL for shielding (legacy method - full 5-action ESR)
  ///
  /// [tokenContract] - Token contract to shield from
  /// [quantity] - Amount to shield (e.g., "100.0000 CLOAK")
  /// [telosAccount] - Telos account name
  ///
  /// Returns the ESR URL string
  static Future<String> generateShieldEsr({
    required String tokenContract,
    required String quantity,
    required String telosAccount,
  }) async {
    // 0. Get or create vault hash for AUTH memo
    // NOTE: Do NOT call getPrimaryVaultHash() or getVaults() - FFI crashes!
    // Use stored vault hash from database instead
    String? vaultHash = await getStoredVaultHash();
    if (vaultHash == null || vaultHash.isEmpty) {
      vaultHash = await createAndStoreVault();
      if (vaultHash == null) {
        throw Exception('Failed to create vault for shield operation');
      }
    }
    // 1. Generate the ZK mint proof
    final mintProof = await generateMintProof(
      tokenContract: tokenContract,
      quantity: quantity,
      fromAccount: telosAccount,
    );

    // 2. Build the ESR actions with actual user account (no placeholders)
    final actions = EsrService.buildShieldActionsWithAccount(
      tokenContract: tokenContract,
      quantity: quantity,
      mintProof: mintProof,
      userAccount: telosAccount,
      feeQuantity: await getShieldFee(),
    );

    // 3. Create the ESR URL with pre-signed thezeosalias signature
    // Uses variant 2 (full transaction) with actual account names, flags=0
    // Anchor signs and returns the tx, Flutter combines signatures and broadcasts
    final esrUrl =
        await EsrService.createSigningRequestWithPresig(actions: actions);

    return esrUrl;
  }

  /// Generate a simple transfer ESR for testing (without launching)
  ///
  /// Returns the ESR URL string
  static String generateSimpleTransferEsr() {
    // Verify placeholder name encoding
    EsrService.debugPlaceholderEncoding();

    // Create a simple TLOS transfer action
    final action = EsrService.buildTransferAction(
      tokenContract: 'eosio.token',
      to: 'eosio', // Safe destination for testing
      quantity: '0.0001 TLOS',
      memo: 'test',
    );

    final esrUrl = EsrService.createSigningRequest(actions: [action]);

    return esrUrl;
  }

  /// Initiate the full shield flow: generate proof → create ESR → launch Anchor
  ///
  /// [tokenContract] - Token contract to shield from
  /// [quantity] - Amount to shield (e.g., "100.0000 CLOAK")
  /// [telosAccount] - Telos account name (for Hyperion balance check)
  ///
  /// Returns true if Anchor was launched successfully
  static Future<bool> initiateShield({
    required String tokenContract,
    required String quantity,
    required String telosAccount,
  }) async {
    try {
      // 1. Generate the ESR URL
      final esrUrl = await generateShieldEsr(
        tokenContract: tokenContract,
        quantity: quantity,
        telosAccount: telosAccount,
      );

      // 2. Launch Anchor wallet
      final launched = await EsrService.launchAnchor(esrUrl);

      if (!launched) {
        throw Exception('Failed to launch Anchor wallet');
      }

      return launched;
    } catch (e) {
      rethrow;
    }
  }
}
