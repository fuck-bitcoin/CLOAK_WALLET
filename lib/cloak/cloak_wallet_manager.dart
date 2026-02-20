// CLOAK Wallet Manager
// Handles CLOAK-specific wallet operations that differ from Zcash/Ycash

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:cloak_api/cloak_api.dart';
import 'package:eosdart/eosdart.dart' as eosdart;

import '../coin/coins.dart';
import '../pages/utils.dart';
import 'cloak_db.dart';
import 'cloak_sync.dart';
import 'eosio_client.dart';
import 'ffi_isolate.dart';
import 'esr_service.dart';

// CLOAK coin ID
const int CLOAK_COIN = 2;

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
    if (c == 0x2E) return 0;                        // '.'
    if (c >= 0x31 && c <= 0x35) return (c - 0x31) + 1; // '1'-'5'
    if (c >= 0x61 && c <= 0x7A) return (c - 0x61) + 6; // 'a'-'z'
    throw ArgumentError('Invalid EOSIO name character: ${String.fromCharCode(c)}');
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
  const VaultTokensResult({required this.cloakUnits, required this.fts, required this.nfts, this.existsOnChain = false});
}

/// A single withdrawal entry for batch vault authenticate.
/// Either [quantity]+[tokenContract] for FTs, or [nftAssetIds]+[nftContract] for NFTs.
class VaultWithdrawEntry {
  final String? quantity;        // e.g. "1.0000 CLOAK" (FT only)
  final String? tokenContract;   // e.g. "thezeostoken" (FT only)
  final List<String>? nftAssetIds; // NFT asset IDs as strings (NFT only)
  final String? nftContract;     // e.g. "atomicassets" (NFT only)
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
  static Future<int> createWallet(String name, String seed, {
    String aliasAuthority = 'thezeosalias@public',
  }) async {
    if (_cloakWalletPath == null) await init();

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
      aliasAuthority: aliasAuthority,
    );

    if (wallet == null) {
      print('CloakWalletManager: Failed to create wallet');
      return -1;
    }

    _cloakWallet = wallet;
    
    // Get the address for this wallet
    final address = CloakApi.deriveAddress(wallet) ?? '';

    // Get IVK (incoming viewing key) in bech32m format
    final ivk = CloakApi.getIvkBech32m(wallet) ?? '';

    // Save to disk
    if (!await saveWallet()) {
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
    print('CloakWalletManager: Marking as new account...');
    CloakSync.markAsNewAccount();
    print('CloakWalletManager: isNewAccount is now ${CloakSync.isNewAccount}');

    // Wrap in try/catch to prevent crashes during setup
    try {
      await CloakSync.setInitialHeightForNewAccount();
    } catch (e) {
      print('CloakWalletManager: setInitialHeightForNewAccount error (non-fatal): $e');
    }

    // Preload ZK params in background so first send is instant
    print('CloakWalletManager: About to preload ZK params...');
    _preloadZkParamsInBackground();
    print('CloakWalletManager: ZK params preload started');

    // Skip auto-vault creation for now - causes FFI crash
    // User can create vault manually later via Shield page
    // TODO: Fix CloakApi.getAuthenticationTokensJson crash on new wallet
    print('CloakWalletManager: Skipping auto-vault creation (FFI issue)');

    print('CloakWalletManager: Created wallet "$name" with id=$accountId');
    return accountId;
  }

  /// Ensure a default vault exists for this wallet
  /// Creates one if none exist
  static Future<bool> _ensureDefaultVaultExists() async {
    print('CloakWalletManager: _ensureDefaultVaultExists() called');
    if (_cloakWallet == null) {
      print('CloakWalletManager: _cloakWallet is null, returning false');
      return false;
    }

    // Check if we already have auth tokens
    print('CloakWalletManager: Calling getAuthenticationTokensJson...');
    final tokensJson = CloakApi.getAuthenticationTokensJson(_cloakWallet!, pretty: true);
    final spentTokensJson = CloakApi.getAuthenticationTokensJson(_cloakWallet!, spent: true, pretty: true);
    final balancesJson = getBalancesJson();
    // Dump to log file for debugging
    try {
      final logFile = File('/tmp/cloak_at_debug.log');
      logFile.writeAsStringSync(
        '=== CLOAK Wallet Auth Token Debug ===\n'
        'Timestamp: ${DateTime.now().toIso8601String()}\n\n'
        'UNSPENT AUTH TOKENS:\n${tokensJson ?? "null"}\n\n'
        'SPENT AUTH TOKENS:\n${spentTokensJson ?? "null"}\n\n'
        'BALANCES:\n${balancesJson ?? "null"}\n\n'
      );
    } catch (_) {}
    print('CloakWalletManager: getAuthenticationTokensJson returned: ${tokensJson?.substring(0, tokensJson.length > 50 ? 50 : tokensJson.length) ?? "null"}...');
    if (tokensJson != null) {
      try {
        final tokens = jsonDecode(tokensJson) as List;
        if (tokens.isNotEmpty) {
          print('CloakWalletManager: Vault already exists (${tokens.length} auth tokens)');
          return true;
        }
      } catch (e) {
        print('CloakWalletManager: Error parsing auth tokens: $e');
      }
    }

    // Create a default vault — use createAndStoreVault() which persists the
    // seed to the DB vaults table (needed for _ensureAuthTokenLoaded recovery).
    print('CloakWalletManager: Creating default vault...');
    final hash = await createAndStoreVault();
    print('CloakWalletManager: createAndStoreVault returned: ${hash != null ? "${hash.substring(0, 16)}..." : "null"}');
    return hash != null;
  }

  /// Preload ZK params in background (non-blocking)
  static void _preloadZkParamsInBackground() {
    // Fire and forget - load params while user does other things
    Future(() async {
      print('CloakWalletManager: Preloading ZK params in background...');
      final success = await loadZkParams();
      print('CloakWalletManager: ZK params preload ${success ? "complete" : "failed"}');
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
  static Future<int> restoreWallet(String name, String seed, {
    String aliasAuthority = 'thezeosalias@public',
  }) async {
    // Mark as restored BEFORE creating - sync will do full history
    CloakSync.markAsRestored();

    // Create the wallet normally
    final accountId = await createWallet(name, seed, aliasAuthority: aliasAuthority);

    // Override the new account marking - this is a restore
    CloakSync.markAsRestored();

    // Reset synced_height to 0 so sync() triggers a full sync.
    // createWallet() called setInitialHeightForNewAccount() which set it to latest block.
    await CloakDb.setProperty('synced_height', '0');
    await CloakDb.setProperty('full_sync_done', 'false');

    print('CloakWalletManager: Restored wallet "$name" - full sync needed (synced_height reset to 0)');
    return accountId;
  }
  
  /// Get account ID
  static int get accountId => _cloakAccountId;
  
  /// Get account name
  static String get accountName => _cloakAccountName;

  /// Load CLOAK wallet from disk
  static Future<bool> loadWallet() async {
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

      // Load account info from database
      final account = await CloakDb.getFirstAccount();
      if (account != null) {
        _cloakAccountId = account['id_account'] as int;
        _cloakAccountName = account['name'] as String;
      }

      print('CloakWalletManager: Loaded wallet "$_cloakAccountName" (id=$_cloakAccountId)');

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

          // Debug log
          try {
            final unspentAts = CloakApi.getAuthenticationTokensJson(w, pretty: true);
            final spentAts = CloakApi.getAuthenticationTokensJson(w, spent: true, pretty: true);
            final bals = CloakApi.getBalancesJson(w, pretty: true);
            final leafCount = CloakApi.getLeafCount(w);
            final logFile = File('/tmp/cloak_at_debug.log');
            await logFile.writeAsString(
              '=== CLOAK Wallet Debug (loadWallet) ===\n'
              'Timestamp: ${DateTime.now().toIso8601String()}\n\n'
              'LEAF COUNT: $leafCount\n\n'
              'UNSPENT AUTH TOKENS:\n${unspentAts ?? "null"}\n\n'
              'SPENT AUTH TOKENS:\n${spentAts ?? "null"}\n\n'
              'BALANCES:\n${bals ?? "null"}\n\n'
            );
            print('CloakWalletManager: Debug log written to /tmp/cloak_at_debug.log');
          } catch (e) {
            print('CloakWalletManager: Debug log error: $e');
          }

          // Check alias_authority - this is CRITICAL for ZK proofs
          final storedAlias = getAliasAuthority();
          print('CloakWalletManager: Wallet alias_authority: $storedAlias');
          if (storedAlias != EXPECTED_ALIAS_AUTHORITY) {
            print('');
            print('!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!');
            print('!! CRITICAL WARNING: Wallet has wrong alias_authority!            ');
            print('!! Stored: "$storedAlias"                                         ');
            print('!! Expected: "$EXPECTED_ALIAS_AUTHORITY"                          ');
            print('!! Shield transactions will FAIL with "proof invalid" error!      ');
            print('!! You need to recreate your wallet with the correct authority.   ');
            print('!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!');
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
  }

  /// One-time import of unpublished auth token notes from the CLOAK GUI wallet.
  /// The auth token was created in /opt/cloak-gui/ and is needed for vault
  /// authenticate operations. This reads the extracted JSON and injects it
  /// into the Flutter wallet's Rust state, then saves.
  static Future<void> _importAuthTokenFromCloakGui() async {
    if (_cloakWallet == null) return;

    // Check if we already imported (stored as a DB property)
    final alreadyImported = await CloakDb.getProperty('cloak_gui_auth_imported');
    if (alreadyImported == 'true') {
      print('[CloakWalletManager] Auth token already imported from CLOAK GUI');
      return;
    }

    // Path to the extracted unpublished notes JSON from CLOAK GUI wallet.bin
    const importPath = '/tmp/cloak_unpublished_notes.json';
    final file = File(importPath);
    if (!await file.exists()) {
      print('[CloakWalletManager] No CLOAK GUI auth token file at $importPath — skipping import');
      return;
    }

    try {
      final notesJson = await file.readAsString();
      print('[CloakWalletManager] Importing auth token from CLOAK GUI: ${notesJson.length} chars');

      // Validate JSON structure
      final parsed = jsonDecode(notesJson);
      if (parsed is! Map || !parsed.containsKey('self')) {
        print('[CloakWalletManager] Invalid auth token JSON format — expected {"self": [...]}');
        return;
      }

      // Inject into wallet's Rust state
      if (!CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson)) {
        print('[CloakWalletManager] addUnpublishedNotes failed: ${CloakApi.getLastError()}');
        return;
      }

      // Save wallet to persist the imported auth token
      if (!await saveWallet()) {
        print('[CloakWalletManager] Failed to save wallet after auth token import');
        return;
      }

      // Mark as imported so we don't repeat
      await CloakDb.setProperty('cloak_gui_auth_imported', 'true');
      print('[CloakWalletManager] Successfully imported auth token from CLOAK GUI!');
      print('[CloakWalletManager] Vault operations should now work via app.cloak.today');
    } catch (e) {
      print('[CloakWalletManager] Error importing auth token: $e');
    }
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
      print('[importGuiWallet] $msg');
      onLog?.call(msg);
    }

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
      _cloakWallet!, contract: 0, spent: false,
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
      final guiAddresses = CloakApi.getAddressesJson(guiWallet, pretty: false);
      log('GUI wallet addresses: $guiAddresses');

      final guiAuthTokens = CloakApi.getAuthenticationTokensJson(
        guiWallet, contract: 0, spent: false,
      );
      log('GUI wallet unspent auth tokens: $guiAuthTokens');

      final guiSpentTokens = CloakApi.getAuthenticationTokensJson(
        guiWallet, contract: 0, spent: true,
      );
      log('GUI wallet spent auth tokens: $guiSpentTokens');

      // Extract unpublished notes from GUI wallet
      onStatus?.call('Extracting unpublished notes...');
      final unpublishedJson = CloakApi.getUnpublishedNotesJson(
        guiWallet, pretty: false,
      );
      if (unpublishedJson == null || unpublishedJson.isEmpty || unpublishedJson == '{}') {
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
        guiWallet, contract: 0, spent: false, seed: true,
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
              final hash = atIdx >= 0 ? hashAndContract.substring(0, atIdx) : hashAndContract;
              final contractName = atIdx >= 0 ? hashAndContract.substring(atIdx + 1) : '';
              log('  Re-creating auth token: hash=${hash.substring(0, 16)}... contract=$contractName');

              // Try each GUI wallet address to find the one that produces the right commitment
              final importContractU64 = contractName.isNotEmpty ? eosioNameToU64(contractName) : 0;
              if (guiAddrs != null) {
                bool matched = false;
                for (final addr in guiAddrs) {
                  final addrStr = addr as String;
                  final notesJson = CloakApi.createUnpublishedAuthNote(
                    _cloakWallet!, seed, importContractU64, addrStr,
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
                    if (matched) break; // Found the right address, stop trying others
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
        _cloakWallet!, contract: 0, spent: false,
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
  }

  /// After importing auth tokens from GUI wallet, verify the DB vault hashes
  /// to match what's actually in the wallet's unspent auth tokens.
  static Future<void> _updateVaultHashesFromWallet({
    void Function(String)? onLog,
  }) async {
    void log(String msg) {
      print('[updateVaultHashes] $msg');
      onLog?.call(msg);
    }

    if (_cloakWallet == null) return;

    final tokensJson = CloakApi.getAuthenticationTokensJson(
      _cloakWallet!, contract: 0, spent: false,
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

  /// Save CLOAK wallet to disk
  static Future<bool> saveWallet() async {
    if (_cloakWallet == null) {
      print('CloakWalletManager: No wallet to save');
      return false;
    }

    if (_cloakWalletPath == null) await init();

    try {
      final bytes = await FfiIsolate.writeWallet(wallet: _cloakWallet!);
      if (bytes == null) {
        print('CloakWalletManager: Failed to serialize wallet');
        return false;
      }

      final file = File(_cloakWalletPath!);
      await file.writeAsBytes(bytes);
      return true;
    } catch (e) {
      print('CloakWalletManager: Error saving wallet: $e');
      return false;
    }
  }

  /// Reset chain state and trigger full resync.
  /// Clears: Rust wallet state (notes, merkle tree), DB properties, MobX observables, sync caches.
  /// Preserves: seed, keys, unpublished notes.
  static Future<bool> resetChainState() async {
    if (_cloakWallet == null) {
      print('[CloakWalletManager] No wallet loaded');
      return false;
    }

    try {
      print('[CloakWalletManager] Starting chain state reset...');

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

      // 6. Clear sync caches
      CloakSync.clearCachedCounters();

      // 7. Clear vault token cache
      clearVaultTokensCache();

      // 8. Unlock wallet
      CloakSync.unlockWallet();

      // 9. Clear MobX observables (will repopulate on next sync)
      // Note: These are in store2.dart and managed by accounts.dart
      // The sync will automatically rebuild them

      print('[CloakWalletManager] Chain state reset complete. Ready for resync.');
      return true;
    } catch (e) {
      print('[CloakWalletManager] Error during reset: $e');
      CloakSync.unlockWallet();
      return false;
    }
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
  static Pointer<Void>? get wallet => _cloakWallet;

  /// Check if wallet is loaded
  static bool get isLoaded => _cloakWallet != null;

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
        'You need to recreate your wallet with the correct alias_authority.'
      );
    }

    // Check chain_id
    final chainId = getChainId();
    if (chainId != TELOS_CHAIN_ID) {
      errors.add('Wallet chain_id is "$chainId" but expected "$TELOS_CHAIN_ID"');
    }

    return errors;
  }

  /// Get primary address
  static String? getAddress() {
    if (_cloakWallet == null) return null;
    var address = CloakApi.deriveAddress(_cloakWallet!);
    if (address == null) return null;

    // The FFI may return the address as a JSON-encoded string with quotes
    // Strip outer quotes if present
    if (address.startsWith('"') && address.endsWith('"') && address.length > 2) {
      address = address.substring(1, address.length - 1);
    }

    print('[CloakWalletManager] getAddress() returned: $address');
    return address;
  }

  /// Get the stable default address — deterministic from seed, never changes.
  /// Use this for auth token operations (vault create/re-inject) where the
  /// commitment must be reproducible.
  static String? getDefaultAddress() {
    if (_cloakWallet == null) return null;
    final address = CloakApi.defaultAddress(_cloakWallet!);
    if (address == null) return null;
    print('[CloakWalletManager] getDefaultAddress() returned: $address');
    return address;
  }

  /// Get balances as JSON (sync — blocks main thread)
  static String? getBalancesJson() {
    if (_cloakWallet == null) return null;
    return CloakApi.getBalancesJson(_cloakWallet!, pretty: true);
  }

  /// Get balances as JSON in a background isolate (non-blocking)
  static Future<String?> getBalancesJsonAsync() async {
    if (_cloakWallet == null) return null;
    return FfiIsolate.getBalancesJson(wallet: _cloakWallet!, pretty: true);
  }

  /// Get transaction history as JSON
  static String? getTransactionHistoryJson() {
    if (_cloakWallet == null) return null;
    return CloakApi.getTransactionHistoryJson(_cloakWallet!, pretty: true);
  }

  /// Get non-fungible tokens as JSON
  static String? getNftsJson({int contract = 0, bool pretty = false}) {
    if (_cloakWallet == null) return null;
    return CloakApi.getNonFungibleTokensJson(_cloakWallet!, contract: contract, pretty: pretty);
  }

  // ============== Vault / Auth Token Functions ==============

  /// Get authentication tokens (vaults) as JSON
  /// These are special notes used for receiving tokens from dApps asynchronously
  static String? getAuthenticationTokensJson({int contract = 0, bool spent = false}) {
    if (_cloakWallet == null) return null;
    return CloakApi.getAuthenticationTokensJson(_cloakWallet!, contract: contract, spent: spent, pretty: true);
  }

  /// Get unpublished notes as JSON
  /// These are notes created locally but not yet on-chain
  static String? getUnpublishedNotesJson() {
    if (_cloakWallet == null) return null;
    return CloakApi.getUnpublishedNotesJson(_cloakWallet!, pretty: true);
  }

  /// Create a new vault (auth token) for a specific token contract
  ///
  /// [label] - Human-readable label for this vault (stored in memo)
  /// [tokenContract] - The EOSIO token contract name (e.g., "thezeostoken")
  ///
  /// Returns true if vault was created successfully
  static Future<bool> createVault(String label, String tokenContract) async {
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
      print('[CloakWalletManager] createVault failed: ${CloakApi.getLastError()}');
      return false;
    }

    // Add the unpublished notes to wallet
    if (!CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson)) {
      print('[CloakWalletManager] addUnpublishedNotes failed: ${CloakApi.getLastError()}');
      return false;
    }

    // Save wallet to persist the vault
    await saveWallet();

    print('[CloakWalletManager] Vault created: $label');
    return true;
  }

  /// Create a new vault and return its commitment hash
  ///
  /// This is useful when we need the vault hash immediately after creation
  /// (e.g., for building an ESR with the vault memo)
  ///
  /// Returns the vault hash (commitment) or null on failure
  static Future<String?> createVaultAndGetHash(String label, {String tokenContract = 'thezeostoken'}) async {
    if (_cloakWallet == null) return null;

    // Use default address (stable, deterministic) so the commitment is reproducible
    final address = getDefaultAddress();
    if (address == null) return null;

    // Debug: print the address to check for invalid characters
    print('[CloakWalletManager] createVaultAndGetHash address: "$address"');
    print('[CloakWalletManager] address length: ${address.length}');
    print('[CloakWalletManager] address codeUnits: ${address.codeUnits}');

    final contract = eosioNameToU64(tokenContract);
    print('[CloakWalletManager] createVaultAndGetHash contract="$tokenContract" => u64=$contract');

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
    print('[CloakWalletManager] Raw notesJson from FFI: ${notesJson.substring(0, notesJson.length > 200 ? 200 : notesJson.length)}...');
    try {
      final notes = jsonDecode(notesJson);
      print('[CloakWalletManager] Decoded notes type: ${notes.runtimeType}');

      if (notes is Map) {
        // Extract the commitment hash from the __commitment__ key
        final commitmentList = notes['__commitment__'];
        if (commitmentList is List && commitmentList.isNotEmpty) {
          vaultHash = commitmentList[0] as String;
          print('[CloakWalletManager] Found vault commitment hash: $vaultHash');
          print('[CloakWalletManager] Commitment hash length: ${vaultHash.length}');
        } else {
          // Fallback: legacy FFI without __commitment__ key - look for za1 address
          // This should not happen with updated FFI
          for (final key in notes.keys) {
            if (key != 'self' && key is String && key.startsWith('za1')) {
              vaultHash = key;
              print('[CloakWalletManager] WARNING: Using legacy za1 address as vault hash: $vaultHash');
              break;
            }
          }
        }
      }

      if (vaultHash == null) {
        print('[CloakWalletManager] Could not extract vault hash from: ${notes.runtimeType}');
        if (notes is Map) {
          print('[CloakWalletManager] Keys: ${notes.keys.toList()}');
        }
      }
    } catch (e, stack) {
      print('[CloakWalletManager] Error parsing vault notes: $e');
      print('[CloakWalletManager] Stack trace: $stack');
    }

    // Add the unpublished notes to wallet regardless
    if (!CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson)) {
      print('[CloakWalletManager] addUnpublishedNotes failed: ${CloakApi.getLastError()}');
      return null;
    }

    // Save wallet to persist the vault
    await saveWallet();

    print('[CloakWalletManager] Vault created with hash: $vaultHash');
    return vaultHash;
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
        print('[CloakWalletManager] Found INVALID vault hash (za1 address): ${hash.substring(0, 20)}...');
        print('[CloakWalletManager] Clearing invalid hash - will create new vault');
        await CloakDb.setProperty(_vaultHashKey, '');  // Clear the invalid hash
        return null;
      }

      // Check if it's a valid 64-char hex string
      if (hash.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hash)) {
        print('[CloakWalletManager] Found INVALID vault hash format: ${hash.substring(0, hash.length > 20 ? 20 : hash.length)}...');
        print('[CloakWalletManager] Clearing invalid hash - will create new vault');
        await CloakDb.setProperty(_vaultHashKey, '');  // Clear the invalid hash
        return null;
      }

      print('[CloakWalletManager] Found valid stored vault hash: ${hash.substring(0, 16)}...');
    }
    return hash;
  }

  /// Store the vault hash in database
  static Future<void> _storeVaultHash(String hash) async {
    await CloakDb.setProperty(_vaultHashKey, hash);
    print('[CloakWalletManager] Stored vault hash: ${hash.substring(0, 16)}...');
  }

  /// Whether vault discovery is currently running (prevents vault creation during scan)
  static bool _discoveryInProgress = false;
  static bool get discoveryInProgress => _discoveryInProgress;

  /// Create a new vault and store its hash.
  /// Uses deterministic HMAC-SHA256 seed derivation for reproducible vaults.
  /// Returns the vault hash or null on failure.
  static Future<String?> createAndStoreVault({String? label}) async {
    if (_cloakWallet == null) return null;
    if (_discoveryInProgress) {
      print('[CloakWalletManager] createAndStoreVault blocked — vault discovery in progress');
      return null;
    }

    print('[CloakWalletManager] Creating new deterministic vault...');

    // Read next_vault_index from SQLite
    final nextIndex = await CloakDb.getNextVaultIndex();
    print('[CloakWalletManager] next_vault_index = $nextIndex');

    final contract = eosioNameToU64('thezeostoken');

    // Create deterministic vault via FFI (derives seed + creates auth token)
    final notesJson = await FfiIsolate.createDeterministicVault(
      wallet: _cloakWallet!,
      contract: contract,
      vaultIndex: nextIndex,
    );

    if (notesJson == null) {
      print('[CloakWalletManager] createDeterministicVault failed');
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
      print('[CloakWalletManager] Error parsing deterministic vault JSON: $e');
      return null;
    }

    if (hash == null || hash.length != 64) {
      print('[CloakWalletManager] Invalid commitment hash from deterministic vault');
      return null;
    }

    // Add unpublished notes to wallet
    if (!CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson)) {
      print('[CloakWalletManager] addUnpublishedNotes failed: ${CloakApi.getLastError()}');
      return null;
    }

    // Save wallet
    await saveWallet();

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
      print('[CloakWalletManager] Deterministic vault $nextIndex persisted to DB');
    }

    // Increment next_vault_index
    await CloakDb.incrementNextVaultIndex();

    print('[CloakWalletManager] Vault created: index=$nextIndex hash=${hash.substring(0, 16)}...');
    return hash;
  }

  /// Discover deterministic vaults by scanning indices 0..N.
  /// For each index: derive seed -> create deterministic vault -> get hash -> check on-chain.
  /// Uses gap limit of 50 consecutive misses and parallelism of 3.
  /// Returns list of discovered vault hashes.
  static Future<List<String>> discoverVaults() async {
    if (_cloakWallet == null) return [];

    _discoveryInProgress = true;
    print('[discoverVaults] Starting vault discovery scan...');
    final discovered = <String>[];
    const gapLimit = 50;
    const parallelism = 3;
    int consecutiveMisses = 0;
    int index = 0;
    int highestFoundIndex = -1;

    final contract = eosioNameToU64('thezeostoken');

    try {
      while (consecutiveMisses < gapLimit) {
        // Process up to `parallelism` indices concurrently
        final batch = <int>[];
        for (int i = 0; i < parallelism && consecutiveMisses + i < gapLimit; i++) {
          batch.add(index + i);
        }

        // Derive all vault hashes in the batch
        final futures = batch.map((idx) async {
          final notesJson = await FfiIsolate.createDeterministicVault(
            wallet: _cloakWallet!,
            contract: contract,
            vaultIndex: idx,
          );
          if (notesJson == null) return null;

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

          if (hash == null || hash.length != 64) return null;
          return {'index': idx, 'hash': hash, 'notesJson': notesJson};
        });

        final results = await Future.wait(futures);

        for (final result in results) {
          if (result == null) {
            consecutiveMisses++;
            index++;
            continue;
          }

          final idx = result['index'] as int;
          final hash = result['hash'] as String;
          final notesJson = result['notesJson'] as String;

          // Check if vault exists on-chain
          try {
            final vaultState = await queryVaultTokens(hash);
            if (vaultState.existsOnChain) {
              print('[discoverVaults] FOUND vault at index $idx: ${hash.substring(0, 16)}...');
              consecutiveMisses = 0;
              if (idx > highestFoundIndex) highestFoundIndex = idx;

              // Add to wallet
              CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson);

              // Store in DB if not already there
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
            } else {
              consecutiveMisses++;
            }
          } catch (e) {
            print('[discoverVaults] Error checking vault at index $idx: $e');
            consecutiveMisses++;
          }

          index++;
        }

        // Clear vault tokens cache between batches to avoid stale data
        clearVaultTokensCache();
      }

      // Update next_vault_index to be one past the highest discovered
      if (highestFoundIndex >= 0) {
        final newNext = highestFoundIndex + 1;
        final currentNext = await CloakDb.getNextVaultIndex();
        if (newNext > currentNext) {
          await CloakDb.setNextVaultIndex(newNext);
          print('[discoverVaults] Updated next_vault_index to $newNext');
        }
      }

      if (discovered.isNotEmpty) {
        await saveWallet();
      }

      print('[discoverVaults] Discovery complete: found ${discovered.length} vault(s), scanned $index indices');
    } finally {
      _discoveryInProgress = false;
    }
    return discovered;
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

    final tokensJson = CloakApi.getAuthenticationTokensJson(_cloakWallet!, pretty: false);
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
    print('[CloakWalletManager] Vault marked as published');
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
    print('[CloakWalletManager] Generating publish vault ESR');

    // Get or create vault hash
    String? vaultHash = await getStoredVaultHash();
    if (vaultHash == null || vaultHash.isEmpty) {
      vaultHash = await createAndStoreVault();
      if (vaultHash == null) {
        throw Exception('Failed to create vault');
      }
    }

    // Ensure ZK params are loaded
    if (!await loadZkParams()) {
      throw Exception('Failed to load ZK params');
    }

    // Build ZTransaction for auth token mint (quantity=0)
    // For auth tokens, the contract must equal the from account
    final ztxJson = _buildAuthTokenMintZTransaction(
      fromAccount: telosAccount,
      tokenContract: telosAccount, // Auth tokens require contract == from account
    );

    print('[CloakWalletManager] Auth token ZTransaction built');
    print('[CloakWalletManager] ZTransaction: $ztxJson');

    // Get fees
    final feesJson = await _getFeesJson();
    print('[CloakWalletManager] Fees JSON: $feesJson');

    // Ensure wallet is loaded
    if (_cloakWallet == null) {
      throw Exception('Wallet not loaded');
    }

    print('[CloakWalletManager] Generating ZK proof for auth token publish...');
    print('[CloakWalletManager] This may take 10-30 seconds...');

    // Call FFI to generate transaction with ZK proof
    final txJson = CloakApi.transactPacked(
      wallet: _cloakWallet!,
      ztxJson: ztxJson,
      feeTokenContract: 'thezeostoken',
      feesJson: feesJson,
      mintParams: _mintParams!,
      spendOutputParams: _spendOutputParams!,
      spendParams: _spendParams!,
      outputParams: _outputParams!,
    );

    if (txJson == null) {
      final error = CloakApi.getLastError();
      throw Exception('wallet_transact_packed failed: $error');
    }

    print('[CloakWalletManager] Auth token ZK proof generated!');

    // Parse the transaction to extract actions
    final tx = jsonDecode(txJson) as Map<String, dynamic>;
    final actions = tx['actions'] as List? ?? [];

    if (actions.isEmpty) {
      throw Exception('No actions in generated transaction');
    }

    // Build ESR from the transaction actions
    final esrUrl = EsrService.createSigningRequest(
      actions: actions.cast<Map<String, dynamic>>(),
    );

    print('[CloakWalletManager] ESR URL generated for vault publish');

    return {
      'esrUrl': esrUrl,
      'vaultHash': vaultHash,
      'transaction': tx,
    };
  }

  /// Publish auth token to Merkle tree directly (no ESR/Anchor needed).
  ///
  /// All actions in the publish transaction only need thezeosalias@public
  /// signing, so we sign locally and broadcast via HTTP — no external wallet.
  ///
  /// Returns the transaction ID on success
  static Future<String> publishVaultDirect() async {
    print('[CloakWalletManager] Publishing vault directly (no ESR)...');

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
          print('[CloakWalletManager] Fee estimation failed in publishVaultDirect, using 0.6 fallback: $e');
          requiredFee = 0.6;
        }
        if (cloakBalance < requiredFee) {
          throw Exception(
            'Insufficient shielded balance for publish fees. '
            'Have $cloakBalance CLOAK, need at least ${requiredFee.toStringAsFixed(2)} CLOAK. '
            'Deposit and authenticate more CLOAK first.');
        }
        print('[CloakWalletManager] Shielded balance: $cloakBalance CLOAK (sufficient for fees)');
      } catch (e) {
        if (e.toString().contains('Insufficient shielded balance')) rethrow;
        print('[CloakWalletManager] Warning: Could not check balance: $e');
      }
    }

    // 4. Build ZTransaction for auth token mint (quantity=0)
    // For auth tokens, from/contract are part of ZK circuit inputs but the
    // Rust FFI handles them from the wallet's internal unpublished note state.
    // We use thezeosalias as the nominal account since it authorizes everything.
    final ztxJson = _buildAuthTokenMintZTransaction(
      fromAccount: 'thezeosalias',
      tokenContract: 'thezeosalias',
    );

    print('[CloakWalletManager] Auth token ZTransaction built');

    // 5. Get fees
    final feesJson = await _getFeesJson();

    // 6. Generate ZK proof + unsigned transaction
    if (_cloakWallet == null) {
      throw Exception('Wallet not loaded');
    }

    print('[CloakWalletManager] Generating ZK proof for auth token publish...');
    print('[CloakWalletManager] This may take 10-30 seconds...');

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

    print('[CloakWalletManager] ZK proof generated, signing with alias key...');

    // 6. Parse transaction (tuple format: [TransactionPacked, unpublished_notes])
    final decoded = jsonDecode(txJson);
    final Map<String, dynamic> tx;
    if (decoded is List && decoded.isNotEmpty) {
      tx = Map<String, dynamic>.from(decoded[0] as Map);
    } else if (decoded is Map) {
      tx = Map<String, dynamic>.from(decoded as Map);
    } else {
      throw Exception('Unexpected transactPacked response format: ${decoded.runtimeType}');
    }

    // 6b. Set transaction headers (ref_block_num, ref_block_prefix, expiration)
    // Rust returns actions only — we must add blockchain headers before signing
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('https://telos.eosusa.io/v1/chain/get_info'));
      final response = await request.close();
      if (response.statusCode != 200) throw Exception('get_info failed: ${response.statusCode}');
      final chainInfo = jsonDecode(await response.transform(const Utf8Decoder()).join()) as Map<String, dynamic>;
      final headBlockId = chainInfo['head_block_id'] as String;
      final refBlockNum = int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
      // ref_block_prefix: bytes 8-11 of the block ID in little-endian
      final prefixHex = headBlockId.substring(16, 24);
      final prefixBytes = List<int>.generate(4, (i) => int.parse(prefixHex.substring(i * 2, i * 2 + 2), radix: 16));
      final refBlockPrefix = prefixBytes[3] << 24 | prefixBytes[2] << 16 | prefixBytes[1] << 8 | prefixBytes[0];

      final expiration = DateTime.now().toUtc().add(const Duration(minutes: 10));
      tx['expiration'] = '${expiration.toIso8601String().split('.')[0]}Z';
      tx['ref_block_num'] = refBlockNum;
      tx['ref_block_prefix'] = refBlockPrefix;
      tx['max_net_usage_words'] = tx['max_net_usage_words'] ?? 0;
      tx['max_cpu_usage_ms'] = tx['max_cpu_usage_ms'] ?? 0;
      tx['delay_sec'] = tx['delay_sec'] ?? 0;
      tx['context_free_actions'] = tx['context_free_actions'] ?? [];
      tx['transaction_extensions'] = tx['transaction_extensions'] ?? [];

      print('[CloakWalletManager] TX headers set: ref_block_num=$refBlockNum, expiration=${tx['expiration']}');
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

    // 7. Sign with thezeosalias@public key only (no user key needed)
    final signatures = await EsrTransactionHelper.signWithAliasKey(
      transaction: tx,
      existingSignatures: [],
    );

    print('[CloakWalletManager] Signed, broadcasting...');

    // 8. Broadcast directly
    final result = await EsrTransactionHelper.broadcastTransaction(
      transaction: tx,
      signatures: signatures,
    );

    final txId = result['transaction_id'] as String? ?? 'unknown';
    print('[CloakWalletManager] Vault published! TX: $txId');

    // 9. Save wallet to persist published auth token state (runs in isolate)
    await saveWallet();

    // 10. Mark as published in database
    await markVaultPublished();

    return txId;
  }

  /// Build ZTransaction for auth token mint (quantity=0)
  static String _buildAuthTokenMintZTransaction({
    required String fromAccount,
    required String tokenContract,
  }) {
    final chainId = getChainId() ?? TELOS_CHAIN_ID;
    final protocolContract = getProtocolContract() ?? 'zeosprotocol';
    final vaultContract = getVaultContract() ?? 'thezeosvault';
    final aliasAuthority = getAliasAuthority() ?? 'thezeosalias@public';

    print('[CloakWalletManager] Building auth token ZTransaction');

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
            'contract': tokenContract, // "0" for any contract, or specific contract
            'quantity': '0', // Zero quantity = auth token
            'memo': '',
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
      print('[CloakWalletManager] importVault: could not get default address');
      return null;
    }

    print('[CloakWalletManager] Importing vault with seed: "${seed.substring(0, seed.length > 30 ? 30 : seed.length)}..."');

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
      print('[CloakWalletManager] importVault failed: ${CloakApi.getLastError()}');
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
        print('[CloakWalletManager] importVault: vault found on-chain, fts=${fts.length}, nfts=${nfts.length}');
      } else {
        print('[CloakWalletManager] importVault: vault NOT found on-chain (may be burned or wrong seed)');
      }
    } catch (e) {
      print('[CloakWalletManager] importVault: on-chain check failed: $e');
    }

    // Save wallet to persist the vault in wallet.bin
    await saveWallet();

    // Check if vault already exists in database
    final exists = await CloakDb.vaultExistsByHash(commitmentHash);
    if (exists) {
      print('[CloakWalletManager] Vault already imported: ${commitmentHash.substring(0, 16)}...');
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

    print('[CloakWalletManager] Vault imported successfully: ${commitmentHash.substring(0, 16)}...');

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
    if (commitmentHash.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(commitmentHash)) {
      print('[CloakWalletManager] importVaultWithHash: invalid hash format');
      return null;
    }

    print('[CloakWalletManager] Importing vault with provided hash: ${commitmentHash.substring(0, 16)}...');

    // Check if vault already exists in database
    final exists = await CloakDb.vaultExistsByHash(commitmentHash);
    if (exists) {
      print('[CloakWalletManager] Vault already imported: ${commitmentHash.substring(0, 16)}...');
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
      print('[CloakWalletManager] importVaultWithHash: failed to save to database');
      return null;
    }

    print('[CloakWalletManager] Vault imported successfully: ${commitmentHash.substring(0, 16)}...');

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
  static Future<List<Map<String, dynamic>>> getImportedVaults({int? accountId}) async {
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
  static Future<Map<String, dynamic>?> getVaultByHash(String commitmentHash) async {
    return await CloakDb.getVaultByHash(commitmentHash);
  }

  /// Update vault status in database
  /// Valid statuses: created, published, funded, active, empty, burned
  static Future<void> updateVaultStatus(String commitmentHash, String status) async {
    await CloakDb.updateVaultStatusByHash(commitmentHash, status);
  }

  /// Delete an imported vault from database
  /// Note: This only removes from local database, not from wallet.bin or on-chain
  static Future<void> deleteImportedVault(int vaultId, {String? commitmentHash}) async {
    // If the deleted vault is the "primary" stored vault, clear vault properties
    if (commitmentHash != null && commitmentHash.isNotEmpty) {
      final storedHash = await getStoredVaultHash();
      if (storedHash == commitmentHash) {
        await CloakDb.setProperty(_vaultHashKey, '');
        await CloakDb.setProperty('cloak_vault_published', '');
        print('[CloakWalletManager] Cleared primary vault properties for deleted vault');
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

      print('[queryVaultBalance] Looking for hash: $commitmentHash');
      print('[queryVaultBalance] Response: $response');

      if (response['rows'] == null || (response['rows'] as List).isEmpty) {
        print('[queryVaultBalance] No rows found');
        return '0 CLOAK';
      }

      final rows = response['rows'] as List;
      // Find the row matching our commitment hash
      for (final row in rows) {
        final authToken = row['auth_token'] as String?;
        print('[queryVaultBalance] Checking row with auth_token: $authToken');
        if (authToken == commitmentHash) {
          print('[queryVaultBalance] Found matching vault!');
          // Parse the balance from 'fts' (fungible tokens) array
          // Format: [{"first": {"sym": "4,CLOAK", "contract": "thezeostoken"}, "second": 10000}]
          final fts = row['fts'];
          if (fts is List && fts.isNotEmpty) {
            final balances = <String>[];
            for (final item in fts) {
              if (item is Map) {
                final tokenInfo = item['first'];
                final amount = item['second'];
                print('[queryVaultBalance] Token: $tokenInfo, Amount: $amount');
                if (tokenInfo is Map && amount is int) {
                  final sym = tokenInfo['sym'] as String? ?? '4,CLOAK';
                  final parts = sym.split(',');
                  final precision = int.tryParse(parts[0]) ?? 4;
                  final symbol = parts.length > 1 ? parts[1] : 'CLOAK';
                  // Calculate divisor: 10^precision
                  int divisor = 1;
                  for (int i = 0; i < precision; i++) divisor *= 10;
                  final formatted = (amount / divisor).toStringAsFixed(precision);
                  balances.add('$formatted $symbol');
                  print('[queryVaultBalance] Formatted balance: $formatted $symbol');
                }
              }
            }
            final result = balances.isNotEmpty ? balances.join(', ') : '0 CLOAK';
            print('[queryVaultBalance] Returning: $result');
            return result;
          }
          return '0 CLOAK';
        }
      }

      print('[queryVaultBalance] No matching vault found');
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
  /// Returns structured data with CLOAK units and token lists
  static Future<VaultTokensResult> queryVaultTokens(String commitmentHash) async {
    // Check cache first
    if (_vaultTokensCache.containsKey(commitmentHash)) {
      print('[queryVaultTokens] cache HIT for ${commitmentHash.substring(0, 16)}...');
      return _vaultTokensCache[commitmentHash]!;
    }

    try {
      print('[queryVaultTokens] cache MISS — querying chain for ${commitmentHash.substring(0, 16)}...');
      final client = EosioClient('https://telos.eosusa.io');
      final response = await client.getTableRows(
        code: 'thezeosvault',
        scope: 'thezeosvault',
        table: 'vaults',
        limit: 100,
      );
      client.close();

      if (response['rows'] == null || (response['rows'] as List).isEmpty) {
        print('[queryVaultTokens] no rows returned from chain');
        final result = VaultTokensResult(cloakUnits: 0, fts: [], nfts: []);
        _vaultTokensCache[commitmentHash] = result;
        return result;
      }

      final rows = response['rows'] as List;
      print('[queryVaultTokens] got ${rows.length} vault rows from chain');
      for (final row in rows) {
        final authToken = row['auth_token'] as String?;
        if (authToken == commitmentHash) {
          print('[queryVaultTokens] FOUND vault — fts: ${row['fts']}');
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
                  final sym = tokenInfo['sym'] as String? ?? '4,CLOAK';
                  final contract = tokenInfo['contract'] as String? ?? 'thezeostoken';
                  final parts = sym.split(',');
                  final precision = int.tryParse(parts[0]) ?? 4;
                  final symbol = parts.length > 1 ? parts[1] : 'CLOAK';
                  int divisor = 1;
                  for (int i = 0; i < precision; i++) divisor *= 10;
                  final formatted = (amount / divisor).toStringAsFixed(precision);
                  fts.add({
                    'symbol': symbol,
                    'contract': contract,
                    'amount': formatted,
                    'rawAmount': amount,
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

          final result = VaultTokensResult(cloakUnits: cloakUnits, fts: fts, nfts: nfts, existsOnChain: true);
          _vaultTokensCache[commitmentHash] = result;
          return result;
        }
      }

      final result = VaultTokensResult(cloakUnits: 0, fts: [], nfts: [], existsOnChain: false);
      _vaultTokensCache[commitmentHash] = result;
      return result;
    } catch (e) {
      print('[CloakWalletManager] queryVaultTokens error: $e');
      return VaultTokensResult(cloakUnits: 0, fts: [], nfts: [], existsOnChain: false);
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
  static void close() {
    if (_cloakWallet != null) {
      CloakApi.closeWallet(_cloakWallet!);
      _cloakWallet = null;
    }
  }

  /// Delete wallet file
  static Future<void> deleteWallet() async {
    close();
    if (_cloakWalletPath == null) await init();
    final file = File(_cloakWalletPath!);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Get chain ID
  static String? getChainId() {
    if (_cloakWallet == null) return null;
    return CloakApi.getChainId(_cloakWallet!);
  }

  /// Get protocol contract name
  static String? getProtocolContract() {
    if (_cloakWallet == null) return null;
    return CloakApi.getProtocolContract(_cloakWallet!);
  }

  /// Get vault contract name
  static String? getVaultContract() {
    if (_cloakWallet == null) return null;
    return CloakApi.getVaultContract(_cloakWallet!);
  }

  /// Get alias authority (e.g., "thezeosalias@public")
  static String? getAliasAuthority() {
    if (_cloakWallet == null) return null;
    return CloakApi.getAliasAuthority(_cloakWallet!);
  }

  /// Check if wallet is view-only
  static bool? isViewOnly() {
    if (_cloakWallet == null) return null;
    return CloakApi.isViewOnly(_cloakWallet!);
  }

  /// Get Incoming Viewing Key as bech32m encoded string (ivk1...)
  /// This key allows viewing incoming transactions without spending capability.
  static String? getIvkBech32m() {
    if (_cloakWallet == null) return null;
    return CloakApi.getIvkBech32m(_cloakWallet!);
  }

  /// Get Full Viewing Key as bech32m encoded string (fvk1...)
  /// This key allows viewing both incoming AND outgoing transactions.
  static String? getFvkBech32m() {
    if (_cloakWallet == null) return null;
    return CloakApi.getFvkBech32m(_cloakWallet!);
  }

  /// Get Outgoing Viewing Key as bech32m encoded string (ovk1...)
  /// This key allows viewing outgoing transactions only.
  static String? getOvkBech32m() {
    if (_cloakWallet == null) return null;
    return CloakApi.getOvkBech32m(_cloakWallet!);
  }

  /// Get seed as hex string (for backup purposes)
  static String? getSeedHex() {
    if (_cloakWallet == null) return null;
    return CloakApi.getSeedHex(_cloakWallet!);
  }

  // ============== Transaction Support ==============

  // Cached ZK params (loaded once, ~623MB total)
  static Uint8List? _mintParams;
  static Uint8List? _spendOutputParams;
  static Uint8List? _spendParams;
  static Uint8List? _outputParams;

  /// Load ZK params from assets (call once at app startup or before first tx)
  /// These are large files (~400MB total) so we cache them in memory.
  /// Loading runs in a separate isolate to avoid freezing the UI.
  static Future<bool> loadZkParams() async {
    if (_mintParams != null) return true; // Already loaded

    try {
      final paramsDir = '/home/kameron/Projects/CLOAK Wallet/zwallet/assets/zeos';

      print('CloakWalletManager: Loading ZK params from $paramsDir (in isolate)...');

      // Read all 4 param files in a separate isolate so the UI stays responsive.
      // Dart transfers Uint8List between isolates by reference (zero-copy).
      final results = await Isolate.run(() async {
        final mint = await File('$paramsDir/mint.params').readAsBytes();
        final spendOutput = await File('$paramsDir/spend-output.params').readAsBytes();
        final spend = await File('$paramsDir/spend.params').readAsBytes();
        final output = await File('$paramsDir/output.params').readAsBytes();
        return [mint, spendOutput, spend, output];
      });

      _mintParams = results[0];
      _spendOutputParams = results[1];
      _spendParams = results[2];
      _outputParams = results[3];

      print('CloakWalletManager: ZK params loaded - mint=${_mintParams!.length}, spendOutput=${_spendOutputParams!.length}, spend=${_spendParams!.length}, output=${_outputParams!.length}');
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

  /// Build and sign a ZEOS shielded transaction
  ///
  /// [recipients] - List of {address, amount, tokenContract, tokenSymbol, memo}
  /// [feeTokenContract] - Contract for fee token (e.g., "eosio.token")
  /// [feeAmount] - Fee amount as string (e.g., "0.0100 TLOS")
  ///
  /// Returns signed EOSIO transaction JSON, or null on error
  static Future<Map<String, dynamic>?> buildTransaction({
    required List<Map<String, dynamic>> recipients,
    required String feeTokenContract,
    required String feeAmount,
    void Function(String)? onStatus,
  }) async {
    if (_cloakWallet == null) {
      print('CloakWalletManager: No wallet loaded');
      return null;
    }

    // Ensure params are loaded
    if (_mintParams == null && !await loadZkParams()) {
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
          print('CloakWalletManager: auth_count mismatch: wallet=$walletAC chain=${global.authCount} — updating');
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
    const aliasAuthority = 'thezeosalias@public';

    // Build spend recipients from the recipients list
    final spendTo = recipients.map((r) {
      final amount = r['amount'] as int;
      final symbol = r['tokenSymbol'] ?? 'CLOAK';
      // Format as EOSIO asset string: "1.0000 CLOAK"
      final wholePart = amount ~/ _unitScale;
      final fracPart = amount % _unitScale;
      final quantity = '$wholePart.${fracPart.toString().padLeft(4, '0')} $symbol';
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
          }
        }
      ],
    };

    final ztxJson = jsonEncode(ztx);
    final feesJson = await _getFeesJson();

    print('CloakWalletManager: Building transaction - ztx=$ztxJson');
    print('CloakWalletManager: Generating ZK proof... this may take 10-30 seconds');

    // Generate ZK proof + unsigned transaction via Rust FFI (background isolate).
    // Lock wallet to prevent sync from running during ZKP generation — avoids
    // concurrent FFI wallet access from different isolates (data race).
    CloakSync.lockWallet();
    final String txJson;
    try {
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
    } finally {
      CloakSync.unlockWallet();
    }

    print('CloakWalletManager: ZK proof generated, preparing transaction...');

    // Parse the transaction (tuple format: [TransactionPacked, unpublished_notes])
    final decoded = jsonDecode(txJson);
    final Map<String, dynamic> tx;
    if (decoded is List && decoded.isNotEmpty) {
      tx = Map<String, dynamic>.from(decoded[0] as Map);
    } else if (decoded is Map) {
      tx = Map<String, dynamic>.from(decoded as Map);
    } else {
      throw Exception('Unexpected transactPacked response format: ${decoded.runtimeType}');
    }

    // Set transaction headers (ref_block_num, ref_block_prefix, expiration)
    onStatus?.call('Preparing transaction...');
    final httpClient = HttpClient();
    try {
      final request = await httpClient.getUrl(Uri.parse('https://telos.eosusa.io/v1/chain/get_info'));
      final response = await request.close();
      if (response.statusCode != 200) throw Exception('get_info failed: ${response.statusCode}');
      final chainInfo = jsonDecode(await response.transform(const Utf8Decoder()).join()) as Map<String, dynamic>;
      final headBlockId = chainInfo['head_block_id'] as String;
      final refBlockNum = int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
      final prefixHex = headBlockId.substring(16, 24);
      final prefixBytes = List<int>.generate(4, (i) => int.parse(prefixHex.substring(i * 2, i * 2 + 2), radix: 16));
      final refBlockPrefix = prefixBytes[3] << 24 | prefixBytes[2] << 16 | prefixBytes[1] << 8 | prefixBytes[0];

      final expiration = DateTime.now().toUtc().add(const Duration(minutes: 10));
      tx['expiration'] = '${expiration.toIso8601String().split('.')[0]}Z';
      tx['ref_block_num'] = refBlockNum;
      tx['ref_block_prefix'] = refBlockPrefix;
      tx['max_net_usage_words'] = tx['max_net_usage_words'] ?? 0;
      tx['max_cpu_usage_ms'] = tx['max_cpu_usage_ms'] ?? 0;
      tx['delay_sec'] = tx['delay_sec'] ?? 0;
      tx['context_free_actions'] = tx['context_free_actions'] ?? [];
      tx['transaction_extensions'] = tx['transaction_extensions'] ?? [];

      print('CloakWalletManager: TX headers set: ref_block_num=$refBlockNum, expiration=${tx['expiration']}');
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

    print('CloakWalletManager: Transaction signed successfully');
    return {'transaction': tx, 'signatures': signatures};
  }

  /// Broadcast a signed transaction to the EOSIO network
  /// [signedTxData] contains 'transaction' (Map) and 'signatures' (List<String>)
  /// Returns transaction ID on success
  static Future<String?> broadcastTransaction(Map<String, dynamic> signedTxData) async {
    final tx = signedTxData['transaction'] as Map<String, dynamic>;
    final signatures = (signedTxData['signatures'] as List).cast<String>();

    try {
      final result = await EsrTransactionHelper.broadcastTransaction(
        transaction: tx,
        signatures: signatures,
      );

      final txId = result['transaction_id'] as String?;
      if (txId != null) {
        print('CloakWalletManager: Transaction broadcast successful: $txId');
      }
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
    String memo = '',  // 512-byte encrypted memo for messages
    String feeTokenContract = 'thezeostoken',
    String feeAmount = '0.4000 CLOAK',
    void Function(String)? onStatus,
  }) async {
    // Build transaction (throws on failure with specific error)
    onStatus?.call('Building transaction...');
    final signedTx = await buildTransaction(
      recipients: [
        {
          'address': recipientAddress,
          'amount': amount,
          'tokenContract': tokenContract,
          'tokenSymbol': tokenSymbol,
          'memo': memo,
        }
      ],
      feeTokenContract: feeTokenContract,
      feeAmount: feeAmount,
      onStatus: onStatus,
    );

    if (signedTx == null) {
      throw Exception('Transaction build returned null');
    }

    // Broadcast (throws on failure with specific error)
    onStatus?.call('Broadcasting...');
    final txId = await broadcastTransaction(signedTx);

    // Save wallet state to persist spent notes
    await saveWallet();

    return txId;
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
    List<String>? nftAssetIds,    // If non-null, this is an NFT withdrawal
    String? nftContract,          // NFT contract name (e.g. 'atomicassets')
  }) async {
    if (_cloakWallet == null) throw Exception('Wallet not loaded');

    // Ensure ZK params are loaded
    if (_mintParams == null && !await loadZkParams()) {
      throw Exception('ZK params not available');
    }

    // Lock wallet to prevent sync from running during transaction
    CloakSync.lockWallet();
    try {

    // Ensure auth token is in wallet's unspent notes
    print('[authenticateVault] Calling _ensureAuthTokenLoaded for vaultHash=${vaultHash.substring(0, 16)}...');
    await _ensureAuthTokenLoaded(vaultHash);
    print('[authenticateVault] _ensureAuthTokenLoaded completed');

    // Sync auth_count from chain
    onStatus?.call('Syncing with network...');
    try {
      final eosClient = EosioClient('https://telos.eosusa.io');
      final global = await eosClient.getZeosGlobal();
      eosClient.close();
      if (global != null) {
        final walletAC = CloakApi.getAuthCount(_cloakWallet!) ?? 0;
        print('[authenticateVault] auth_count: wallet=$walletAC chain=${global.authCount}');
        if (walletAC != global.authCount) {
          print('[authenticateVault] auth_count mismatch: wallet=$walletAC chain=${global.authCount} — updating');
          CloakApi.setAuthCount(_cloakWallet!, global.authCount);
        }
      }
    } catch (e) {
      print('[authenticateVault] Warning: could not sync auth_count: $e');
    }

    // Build ZTransaction JSON with authenticate zaction
    final chainId = getChainId() ?? TELOS_CHAIN_ID;
    final protocolContract = getProtocolContract() ?? 'zeosprotocol';
    final vaultContractName = getVaultContract() ?? 'thezeosvault';
    const aliasAuthority = 'thezeosalias@public';

    // withdrawp transfers tokens from vault to the shielded pool (zeosprotocol),
    // NOT to the user's za1 address. The shielded notes are created by the
    // protocol contract and discovered by the wallet via Merkle tree sync.
    // Authorization must be thezeosvault@active (the vault contract's own auth,
    // dispatched as inline action by the protocol).
    // Detect if vault is empty (no tokens to withdraw) — check before serializing
    final quantityAmount = double.tryParse(quantity.split(' ').first) ?? 0.0;
    final bool isEmptyVault = quantityAmount == 0.0
        && (nftAssetIds == null || nftAssetIds.isEmpty)
        && burn != 0;

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
      final vaultState = await queryVaultTokens(vaultHash);
      if (vaultState.existsOnChain) {
        innerActions.add({
          'account': vaultContractName,
          'name': 'burnvaultp',
          'authorization': ['$vaultContractName@active'],
          'data': '', // burnvaultp struct has zero fields
        });
      } else {
        print('[authenticateVault] vault has no on-chain entry — skipping burnvaultp');
      }
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

    print('[authenticateVault] ZTransaction: $ztxJson');

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

    print('[authenticateVault] ZK proof generated');

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
      final request = await httpClient.getUrl(Uri.parse('https://telos.eosusa.io/v1/chain/get_info'));
      final response = await request.close();
      if (response.statusCode != 200) throw Exception('get_info failed');
      final chainInfo = jsonDecode(await response.transform(const Utf8Decoder()).join()) as Map<String, dynamic>;
      final headBlockId = chainInfo['head_block_id'] as String;
      final refBlockNum = int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
      final prefixHex = headBlockId.substring(16, 24);
      final prefixBytes = List<int>.generate(4, (i) => int.parse(prefixHex.substring(i * 2, i * 2 + 2), radix: 16));
      final refBlockPrefix = prefixBytes[3] << 24 | prefixBytes[2] << 16 | prefixBytes[1] << 8 | prefixBytes[0];

      final expiration = DateTime.now().toUtc().add(const Duration(minutes: 10));
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

    // Sign with thezeosalias@public key
    onStatus?.call('Signing transaction...');
    final signatures = await EsrTransactionHelper.signWithAliasKey(
      transaction: tx,
      existingSignatures: [],
    );

    // Broadcast
    onStatus?.call('Broadcasting...');
    final txId = await broadcastTransaction({'transaction': tx, 'signatures': signatures});

    // Save wallet state
    await saveWallet();

    // Clear vault token cache so balance refreshes
    clearVaultTokensCache();

    return txId;
    } finally {
      CloakSync.unlockWallet();
    }
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

  /// Append diagnostic lines to /tmp/cloak_auth_debug.log.
  /// This file persists across app restarts and is the primary debug artifact
  /// for diagnosing InvalidAuthToken failures.
  static void _appendAuthDebugLog(List<String> lines) {
    try {
      final logFile = File('/tmp/cloak_auth_debug.log');
      logFile.writeAsStringSync(
        '${lines.join('\n')}\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// Ensure a vault's auth token is loaded in the Rust wallet's unspent notes.
  /// Re-imports from DB seed if needed. Must be called before authenticate.
  static Future<void> _ensureAuthTokenLoaded(String vaultHash) async {
    final logLines = <String>[
      '=== _ensureAuthTokenLoaded ===',
      'Timestamp: ${DateTime.now().toIso8601String()}',
      'vaultHash: $vaultHash',
    ];

    print('[_ensureAuthTokenLoaded] START for vaultHash=${vaultHash.substring(0, 16)}...');
    if (_cloakWallet == null) {
      logLines.add('ABORT: _cloakWallet is null');
      _appendAuthDebugLog(logLines);
      throw Exception('Cannot load auth token: wallet not initialized');
    }

    // Capture wallet state BEFORE re-injection
    final beforeTokens = CloakApi.getAuthenticationTokensJson(_cloakWallet!, contract: 0, spent: false);
    final beforeSpent = CloakApi.getAuthenticationTokensJson(_cloakWallet!, contract: 0, spent: true);
    final beforeUnpublished = CloakApi.getUnpublishedNotesJson(_cloakWallet!);
    final beforeAuthCount = CloakApi.getAuthCount(_cloakWallet!);
    final beforeLeafCount = CloakApi.getLeafCount(_cloakWallet!);
    logLines.addAll([
      '',
      '--- BEFORE re-injection ---',
      'unspent auth tokens: $beforeTokens',
      'spent auth tokens: $beforeSpent',
      'unpublished notes (${beforeUnpublished?.length ?? 0} chars): $beforeUnpublished',
      'auth_count: $beforeAuthCount',
      'leaf_count: $beforeLeafCount',
    ]);
    print('[_ensureAuthTokenLoaded] Auth tokens BEFORE re-injection: $beforeTokens');
    print('[_ensureAuthTokenLoaded] Unpublished notes BEFORE: ${beforeUnpublished?.length ?? 0} chars');

    final vault = await CloakDb.getVaultByHash(vaultHash);
    if (vault == null) {
      logLines.add('ABORT: no vault in DB for hash $vaultHash');
      _appendAuthDebugLog(logLines);
      throw Exception('Vault not found in database for hash ${vaultHash.substring(0, 16)}... — was the vault seed stored?');
    }
    final seed = vault['seed'] as String?;
    final dbCommitment = vault['commitment_hash'] as String?;
    final dbPublished = vault['published'] as int?;
    logLines.addAll([
      '',
      '--- DB vault row ---',
      'seed length: ${seed?.length ?? 0}',
      'commitment_hash: $dbCommitment',
      'published: $dbPublished',
      'vault row keys: ${vault.keys.toList()}',
    ]);
    if (seed == null || seed.isEmpty) {
      logLines.add('ABORT: no seed for $vaultHash');
      _appendAuthDebugLog(logLines);
      throw Exception('Vault ${vaultHash.substring(0, 16)}... has no seed in database — cannot re-inject auth token');
    }
    print('[_ensureAuthTokenLoaded] seed length=${seed.length} (NOT logging seed value)');

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
    logLines.add('contract from DB: "$dbContract" => u64: $contractU64');
    print('[_ensureAuthTokenLoaded] contract="$dbContract" => u64=$contractU64');
    bool matched = false;

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
      } catch (e) {
        logLines.add('Could not load GUI wallet for address scan: $e');
      }
    }

    logLines.add('Addresses to try: ${addressesToTry.length}');
    print('[_ensureAuthTokenLoaded] Trying ${addressesToTry.length} addresses to match vault hash');

    // Try each address until we find one that produces the matching commitment
    for (int i = 0; i < addressesToTry.length; i++) {
      final addr = addressesToTry[i];
      final notesJson = CloakApi.createUnpublishedAuthNote(
        _cloakWallet!, seed, contractU64, addr,
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
        logLines.add('MATCH at address[$i]: ${addr.substring(0, 20)}... => $resultHash');
        print('[_ensureAuthTokenLoaded] MATCH found at address[$i]=${addr.substring(0, 20)}...');
        CloakApi.addUnpublishedNotes(_cloakWallet!, notesJson);
        matched = true;
        break;
      } else if (i == 0) {
        logLines.add('Default address: ${addr.substring(0, 20)}... => ${resultHash ?? "null"} (no match)');
      }
    }

    // Capture wallet state AFTER
    final afterTokens = CloakApi.getAuthenticationTokensJson(_cloakWallet!, contract: 0, spent: false);
    logLines.addAll([
      '',
      '--- AFTER re-injection ---',
      'unspent auth tokens: $afterTokens',
      'matched: $matched',
    ]);
    print('[_ensureAuthTokenLoaded] Auth tokens AFTER: $afterTokens');

    // Final verification
    final bool found = afterTokens != null && afterTokens.contains(vaultHash);
    logLines.addAll([
      '',
      '--- VERDICT ---',
      'vault hash found in unspent auth tokens: $found',
    ]);
    if (!found) {
      logLines.add('WARNING: vault hash NOT in unspent auth tokens after trying ${addressesToTry.length} addresses');
      print('[_ensureAuthTokenLoaded] WARNING: vault hash ${vaultHash.substring(0, 16)}... NOT found after trying ${addressesToTry.length} addresses');
    } else {
      print('[_ensureAuthTokenLoaded] vault hash ${vaultHash.substring(0, 16)}... found in unspent auth tokens');
    }

    _appendAuthDebugLog(logLines);
    print('[_ensureAuthTokenLoaded] END');
  }

  static Future<String?> authenticateVaultBatch({
    required String vaultHash,
    required String recipientAddress,
    required List<VaultWithdrawEntry> entries,
    int burn = 0,
    void Function(String)? onStatus,
  }) async {
    final batchLog = <String>[
      '',
      '===============================================',
      '=== authenticateVaultBatch ===',
      'Timestamp: ${DateTime.now().toIso8601String()}',
      'vaultHash: $vaultHash',
      'recipientAddress: $recipientAddress',
      'entries: ${entries.length}',
      'burn: $burn',
    ];

    if (_cloakWallet == null) throw Exception('Wallet not loaded');
    if (entries.isEmpty) throw Exception('No withdrawal entries provided');

    // Ensure ZK params are loaded
    if (_mintParams == null && !await loadZkParams()) {
      throw Exception('ZK params not available');
    }

    // Lock wallet to prevent sync from running during transaction
    CloakSync.lockWallet();
    batchLog.add('wallet LOCKED at ${DateTime.now().toIso8601String()}');
    try {

    // Ensure auth token is in wallet's unspent notes
    print('[authenticateVaultBatch] Calling _ensureAuthTokenLoaded for vaultHash=${vaultHash.substring(0, 16)}...');
    await _ensureAuthTokenLoaded(vaultHash);
    print('[authenticateVaultBatch] _ensureAuthTokenLoaded completed');

    // Snapshot auth tokens RIGHT AFTER _ensureAuthTokenLoaded (before any other FFI)
    final postEnsureTokens = CloakApi.getAuthenticationTokensJson(_cloakWallet!, contract: 0, spent: false);
    final postEnsureFound = postEnsureTokens != null && postEnsureTokens.contains(vaultHash);
    batchLog.addAll([
      '',
      '--- post-_ensureAuthTokenLoaded snapshot ---',
      'unspent auth tokens: $postEnsureTokens',
      'target vault hash found: $postEnsureFound',
    ]);

    // Sync auth_count from chain
    onStatus?.call('Syncing with network...');
    int? walletACBefore;
    int? chainAC;
    try {
      final eosClient = EosioClient('https://telos.eosusa.io');
      final global = await eosClient.getZeosGlobal();
      eosClient.close();
      if (global != null) {
        walletACBefore = CloakApi.getAuthCount(_cloakWallet!) ?? 0;
        chainAC = global.authCount;
        print('[authenticateVaultBatch] auth_count: wallet=$walletACBefore chain=$chainAC');
        if (walletACBefore != chainAC) {
          print('[authenticateVaultBatch] auth_count mismatch: wallet=$walletACBefore chain=$chainAC — updating');
          CloakApi.setAuthCount(_cloakWallet!, chainAC);
        }
      }
    } catch (e) {
      print('[authenticateVaultBatch] Warning: could not sync auth_count: $e');
      batchLog.add('auth_count sync error: $e');
    }
    final walletACAfter = CloakApi.getAuthCount(_cloakWallet!);
    batchLog.addAll([
      '',
      '--- auth_count sync ---',
      'wallet auth_count BEFORE sync: $walletACBefore',
      'chain auth_count: $chainAC',
      'wallet auth_count AFTER sync: $walletACAfter',
    ]);

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
        throw Exception('VaultWithdrawEntry must have either quantity (FT) or nftAssetIds (NFT)');
      }

      withdrawActions.add({
        'account': vaultContractName,
        'name': 'withdrawp',
        'authorization': ['$vaultContractName@active'],
        'data': withdrawpData,
      });
    }
    const aliasAuthority = 'thezeosalias@public';

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
      final vaultState = await queryVaultTokens(vaultHash);
      if (vaultState.existsOnChain) {
        withdrawActions.add({
          'account': vaultContractName,
          'name': 'burnvaultp',
          'authorization': ['$vaultContractName@active'],
          'data': '', // burnvaultp struct has zero fields
        });
      } else {
        print('[authenticateVaultBatch] vault has no on-chain entry — skipping burnvaultp');
      }
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

    batchLog.addAll([
      '',
      '--- ZTransaction ---',
      'chainId: $chainId',
      'protocolContract: $protocolContract',
      'vaultContract: $vaultContractName',
      'feeTokenContract: $feeTokenContract',
      'withdrawActions: ${withdrawActions.length}',
      'mintActions: ${zactions.length - 1}',
      'ztxJson: $ztxJson',
    ]);

    // Final auth token check RIGHT BEFORE transactPacked
    final preTransactTokens = CloakApi.getAuthenticationTokensJson(_cloakWallet!, contract: 0, spent: false);
    final preTransactFound = preTransactTokens != null && preTransactTokens.contains(vaultHash);
    batchLog.addAll([
      '',
      '--- pre-transactPacked final check ---',
      'unspent auth tokens: $preTransactTokens',
      'target vault hash found: $preTransactFound',
      'transactPacked call at: ${DateTime.now().toIso8601String()}',
    ]);
    _appendAuthDebugLog(batchLog);

    print('[authenticateVaultBatch] ZTransaction (${withdrawActions.length} actions): $ztxJson');

    // Generate ZK proof (background isolate)
    onStatus?.call('Generating zero-knowledge proof...');
    String txJson;
    try {
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
    } catch (e) {
      final errLog = <String>[
        '',
        '!!! transactPacked FAILED !!!',
        'Timestamp: ${DateTime.now().toIso8601String()}',
        'Error: $e',
        'CloakApi.getLastError(): ${CloakApi.getLastError()}',
      ];
      // Capture post-failure wallet state for diagnosis
      final failTokens = CloakApi.getAuthenticationTokensJson(_cloakWallet!, contract: 0, spent: false);
      final failSpent = CloakApi.getAuthenticationTokensJson(_cloakWallet!, contract: 0, spent: true);
      final failAuthCount = CloakApi.getAuthCount(_cloakWallet!);
      errLog.addAll([
        'unspent auth tokens after failure: $failTokens',
        'spent auth tokens after failure: $failSpent',
        'auth_count after failure: $failAuthCount',
      ]);
      _appendAuthDebugLog(errLog);
      rethrow;
    }

    _appendAuthDebugLog([
      '',
      '--- transactPacked SUCCESS ---',
      'Timestamp: ${DateTime.now().toIso8601String()}',
      'txJson length: ${txJson.length}',
    ]);

    print('[authenticateVaultBatch] ZK proof generated');

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
      final request = await httpClient.getUrl(Uri.parse('https://telos.eosusa.io/v1/chain/get_info'));
      final response = await request.close();
      if (response.statusCode != 200) throw Exception('get_info failed');
      final chainInfo = jsonDecode(await response.transform(const Utf8Decoder()).join()) as Map<String, dynamic>;
      final headBlockId = chainInfo['head_block_id'] as String;
      final refBlockNum = int.parse(headBlockId.substring(0, 8), radix: 16) & 0xFFFF;
      final prefixHex = headBlockId.substring(16, 24);
      final prefixBytes = List<int>.generate(4, (i) => int.parse(prefixHex.substring(i * 2, i * 2 + 2), radix: 16));
      final refBlockPrefix = prefixBytes[3] << 24 | prefixBytes[2] << 16 | prefixBytes[1] << 8 | prefixBytes[0];

      final expiration = DateTime.now().toUtc().add(const Duration(minutes: 10));
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

    // Sign with thezeosalias@public key
    onStatus?.call('Signing transaction...');
    final signatures = await EsrTransactionHelper.signWithAliasKey(
      transaction: tx,
      existingSignatures: [],
    );

    // Broadcast
    onStatus?.call('Broadcasting...');
    final txId = await broadcastTransaction({'transaction': tx, 'signatures': signatures});

    // Save wallet state
    await saveWallet();

    // Clear vault token cache so balance refreshes
    clearVaultTokensCache();

    return txId;
    } finally {
      CloakSync.unlockWallet();
    }
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
    required String from,       // 'thezeosvault'
    required String to,         // recipient
    required List<String> assetIds,  // NFT IDs as strings (u64)
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
    final random = List<int>.generate(10, (_) => DateTime.now().microsecondsSinceEpoch % 256);
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
    final parts = <String>['v1', 'type=$type', 'conversation_id=$conversationId', 'seq=$seq'];

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
    required String targetAuthor,  // "me" or "peer"
    String? replyToUa,
    int amount = 0,
    String tokenSymbol = 'TLOS',
    String tokenContract = 'eosio.token',
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

  /// CLOAK token decimal precision (4 decimals = 10000 smallest units per 1 CLOAK)
  static const _unitScale = 10000;

  /// Telos chain ID
  static const TELOS_CHAIN_ID = '4667b205c6838ef70ff7988f6e8257e8be0e1284a2f59699054a018f743b1d11';

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
        final symbol = beginFee.split(' ').length > 1 ? beginFee.split(' ').last : 'CLOAK';
        _cachedShieldFee = '${total.toStringAsFixed(4)} $symbol';
        print('[CloakWalletManager] Shield fee fetched from chain: $_cachedShieldFee (begin=$beginFee, mint=$mintFee)');
        return _cachedShieldFee!;
      }
    } catch (e) {
      print('[CloakWalletManager] Failed to fetch shield fee from chain: $e');
    }

    // Fallback to default
    _cachedShieldFee = '0.3000 CLOAK';
    print('[CloakWalletManager] Using default shield fee: $_cachedShieldFee');
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
  static Future<String> getSendFee({int? sendAmountUnits, String? recipientAddress}) async {
    // If amount provided and wallet loaded, use Rust estimator for exact fee
    if (sendAmountUnits != null && _cloakWallet != null) {
      try {
        final feesJson = await _getFeesJson();
        print('[FEE_DEBUG] Calling estimateSendFee: amount=$sendAmountUnits, recipient=$recipientAddress');
        final feeUnits = CloakApi.estimateSendFee(
          _cloakWallet!, sendAmountUnits, feesJson,
          recipientAddress: recipientAddress,
        );
        if (feeUnits != null && feeUnits > 0) {
          final feeCloak = feeUnits / 10000.0;
          final result = '${feeCloak.toStringAsFixed(4)} CLOAK';
          print('[FEE_DEBUG] Send fee estimated (amount=$sendAmountUnits, recipient=$recipientAddress): $result (${feeUnits} units)');
          return result;
        }
        print('[FEE_DEBUG] estimateSendFee returned null or 0, falling back');

      } catch (e) {
        print('[CloakWalletManager] Rust fee estimation failed, falling back: $e');
      }
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
        print('[CloakWalletManager] Send fee fetched: $_cachedSendFee');
        return _cachedSendFee!;
      }
    } catch (e) {
      print('[CloakWalletManager] Failed to fetch send fee: $e');
    }

    _cachedSendFee = '0.4000 CLOAK';
    return _cachedSendFee!;
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
    final feeUnits = CloakApi.estimateBurnFee(_cloakWallet!, hasAssets, feesJson);
    if (feeUnits == null) throw Exception('Rust burn fee estimation returned null');
    final feeCloak = feeUnits / 10000.0;
    print('[CloakWalletManager] estimateBurnFee(hasAssets=$hasAssets) = $feeUnits units ($feeCloak CLOAK)');
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
    final feeUnits = CloakApi.estimateVaultCreationFee(_cloakWallet!, feesJson);
    if (feeUnits == null) throw Exception('Rust vault creation fee estimation returned null');
    final feeCloak = feeUnits / 10000.0;
    print('[CloakWalletManager] estimateVaultCreationFee = $feeUnits units ($feeCloak CLOAK)');
    return '${feeCloak.toStringAsFixed(4)} CLOAK';
  }

  /// TEST: Create a simple transfer ESR to verify encoding works with Anchor
  /// This creates a minimal TLOS transfer that Anchor should definitely recognize
  /// Returns the ESR URL (caller decides whether to launch or display)
  static Future<String> testSimpleTransferEsr() async {
    print('[CloakWalletManager] Creating TEST transfer ESR...');
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
    print('[CloakWalletManager] Generating mint proof for $quantity from $fromAccount');

    // 1. Ensure wallet is loaded
    if (_cloakWallet == null) {
      throw Exception('Wallet not loaded');
    }

    // DEBUG: Print ALL wallet stored values - CRITICAL FOR ZK PROOFS
    final storedAlias = getAliasAuthority();
    final storedChainId = getChainId();
    final storedProtocol = getProtocolContract();
    final storedVault = getVaultContract();
    print('[CloakWalletManager] *** WALLET CONFIG ***');
    print('[CloakWalletManager]   chain_id: $storedChainId');
    print('[CloakWalletManager]   protocol_contract: $storedProtocol');
    print('[CloakWalletManager]   vault_contract: $storedVault');
    print('[CloakWalletManager]   alias_authority: $storedAlias');
    print('[CloakWalletManager] *** PROOF INPUTS ***');
    print('[CloakWalletManager]   from (account): "$fromAccount"');
    print('[CloakWalletManager]   from length: ${fromAccount.length}');
    print('[CloakWalletManager]   quantity: "$quantity"');
    print('[CloakWalletManager]   tokenContract: "$tokenContract"');

    // Validate EOSIO name constraints
    if (fromAccount.length > 12) {
      print('[CloakWalletManager] ERROR: fromAccount "$fromAccount" exceeds 12 chars!');
    }
    final validChars = RegExp(r'^[a-z1-5\.]+$');
    if (!validChars.hasMatch(fromAccount)) {
      print('[CloakWalletManager] ERROR: fromAccount "$fromAccount" contains invalid characters!');
    }

    if (storedAlias != 'thezeosalias@public') {
      print('[CloakWalletManager] WARNING: alias_authority is NOT thezeosalias@public!');
      print('[CloakWalletManager] This WILL cause proof validation to fail on-chain!');
    }

    // === DIAGNOSTIC LOGGING: Capture all inputs ===
    final logFile = File('/tmp/cloak_shield_debug.log');
    final timestamp = DateTime.now().toIso8601String();
    final logBuffer = StringBuffer();
    logBuffer.writeln('');
    logBuffer.writeln('=== generateMintProof called at $timestamp ===');
    logBuffer.writeln('');
    logBuffer.writeln('WALLET STORED VALUES:');
    logBuffer.writeln('  chain_id: $storedChainId');
    logBuffer.writeln('  protocol_contract: $storedProtocol');
    logBuffer.writeln('  vault_contract: $storedVault');
    logBuffer.writeln('  alias_authority: $storedAlias');
    logBuffer.writeln('');
    logBuffer.writeln('PROOF INPUT VALUES:');
    logBuffer.writeln('  from (Telos account): "$fromAccount"');
    logBuffer.writeln('  from length: ${fromAccount.length} chars');
    logBuffer.writeln('  quantity: "$quantity"');
    logBuffer.writeln('  tokenContract: "$tokenContract"');
    logBuffer.writeln('');
    logBuffer.writeln('VALIDATION:');
    logBuffer.writeln('  alias_authority matches "thezeosalias@public": ${storedAlias == 'thezeosalias@public'}');
    logBuffer.writeln('  fromAccount is valid EOSIO name: ${validChars.hasMatch(fromAccount) && fromAccount.length <= 12}');
    // === END DIAGNOSTIC ===

    // 2. Ensure ZK params are loaded (this can take 5-15 seconds first time)
    if (!await loadZkParams()) {
      throw Exception('Failed to load ZK params');
    }

    // 3. Get protocol fees from blockchain
    print('[CloakWalletManager] Fetching protocol fees...');
    final feesJson = await _getFeesJson();

    // 4. Build the ZTransaction JSON for mint operation
    final ztxJson = _buildMintZTransaction(
      toAddress: '\$SELF', // Wallet replaces with derived address
      fromAccount: fromAccount,
      quantity: quantity,
      tokenContract: tokenContract,
    );

    // === DIAGNOSTIC LOGGING: Capture ZTransaction JSON ===
    logBuffer.writeln('');
    logBuffer.writeln('ZTransaction JSON being sent to Rust FFI:');
    logBuffer.writeln(ztxJson);
    // === END DIAGNOSTIC ===

    print('[CloakWalletManager] ZTransaction JSON built, calling wallet_transact...');
    print('[CloakWalletManager] This may take 10-30 seconds for ZK proof generation...');

    // 5. Call FFI to generate transaction with ZK proof
    // NOTE: This is CPU-intensive and takes 5-30 seconds
    // Use transactPacked to get hex_data for ABI-serialized action data (required for ESR/Anchor)
    final txJson = CloakApi.transactPacked(
      wallet: _cloakWallet!,
      ztxJson: ztxJson,
      feeTokenContract: 'thezeostoken',
      feesJson: feesJson,
      mintParams: _mintParams!,
      spendOutputParams: _spendOutputParams!,
      spendParams: _spendParams!,
      outputParams: _outputParams!,
    );

    // === DIAGNOSTIC LOGGING: Capture transactPacked response ===
    logBuffer.writeln('');
    logBuffer.writeln('transactPacked response:');
    if (txJson == null) {
      final error = CloakApi.getLastError();
      logBuffer.writeln('FAILED - txJson is null');
      logBuffer.writeln('Error from getLastError(): $error');
      // Write log before throwing
      await logFile.writeAsString(logBuffer.toString(), mode: FileMode.append);
      throw Exception('wallet_transact_packed failed: $error');
    } else {
      logBuffer.writeln('SUCCESS - txJson length: ${txJson.length} chars');
      // Check for hex_data presence in the response
      final hasHexData = txJson.contains('"hex_data"');
      logBuffer.writeln('Contains "hex_data": $hasHexData');
      // Log first 2000 chars of response for inspection
      final preview = txJson.length > 2000 ? txJson.substring(0, 2000) : txJson;
      logBuffer.writeln('Response preview (first 2000 chars):');
      logBuffer.writeln(preview);
      if (txJson.length > 2000) {
        logBuffer.writeln('... (truncated, total length: ${txJson.length})');
      }
    }
    // Write all diagnostic info to log file
    await logFile.writeAsString(logBuffer.toString(), mode: FileMode.append);
    // === END DIAGNOSTIC ===

    print('[CloakWalletManager] ZK proof generated successfully!');

    // 6. Parse the transaction and extract mint action data (includes hex_data)
    final mintData = _extractMintActionData(txJson);
    if (mintData == null) {
      throw Exception('Failed to extract mint action from transaction');
    }

    // === PROOF VALIDATION: Check proof size before returning ===
    // Valid ZEOS Groth16 proof = 384 bytes = 768 hex chars
    final hexData = mintData['_hex_data']?.toString();
    if (hexData != null && hexData.isNotEmpty) {
      final proofSizeBytes = hexData.length ~/ 2;
      print('[CloakWalletManager] PROOF VALIDATION:');
      print('[CloakWalletManager]   hex_data length: ${hexData.length} hex chars = $proofSizeBytes bytes');

      // Log to file for post-mortem analysis
      final validationLog = StringBuffer();
      validationLog.writeln('');
      validationLog.writeln('=== PROOF VALIDATION ===');
      validationLog.writeln('hex_data length: ${hexData.length} hex chars = $proofSizeBytes bytes');

      // The PlsMintAction contains multiple PlsMint entries, each with a 384-byte proof
      // Check if hex_data seems reasonable (should be > 768 for at least one proof)
      if (hexData.length < 768) {
        print('[CloakWalletManager] WARNING: hex_data too small for a valid proof!');
        print('[CloakWalletManager] Expected at least 768 hex chars, got ${hexData.length}');
        validationLog.writeln('WARNING: hex_data too small! Expected >= 768 hex chars');
      }

      // Log first and last 100 chars of hex_data
      if (hexData.length > 200) {
        validationLog.writeln('hex_data (first 100): ${hexData.substring(0, 100)}');
        validationLog.writeln('hex_data (last 100): ${hexData.substring(hexData.length - 100)}');
      } else {
        validationLog.writeln('hex_data (full): $hexData');
      }
      validationLog.writeln('');

      await logFile.writeAsString(validationLog.toString(), mode: FileMode.append);
    } else {
      print('[CloakWalletManager] WARNING: No hex_data in mintData - fallback serialization will be used');
      await logFile.writeAsString('\nWARNING: No hex_data found!\n', mode: FileMode.append);
    }

    // Also check for proof field in actions array if present
    final actions = mintData['actions'];
    if (actions is List) {
      for (int i = 0; i < actions.length; i++) {
        final action = actions[i];
        if (action is Map) {
          final proof = action['proof'];
          if (proof != null) {
            String proofInfo = '';
            if (proof is List) {
              proofInfo = '${proof.length} bytes (List)';
              if (proof.length != 384) {
                print('[CloakWalletManager] WARNING: actions[$i].proof is ${proof.length} bytes, expected 384!');
              }
            } else if (proof is String) {
              proofInfo = '${proof.length ~/ 2} bytes (hex string ${proof.length} chars)';
              if (proof.length != 768) {
                print('[CloakWalletManager] WARNING: actions[$i].proof is ${proof.length} hex chars, expected 768!');
              }
            }
            print('[CloakWalletManager]   actions[$i].proof: $proofInfo');
          }
        }
      }
    }
    // === END PROOF VALIDATION ===

    print('[CloakWalletManager] Mint action data extracted');
    return mintData;
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

  /// Public wrapper for CloakApi.getLastError() (used by SignatureProvider)
  static String? getLastErrorPublic() => CloakApi.getLastError();

  /// Public wrapper for transactPacked (used by SignatureProvider)
  /// Takes a ZTransaction JSON and returns the packed transaction JSON
  static String? transactPackedPublic({
    required String ztxJson,
    required String feesJson,
  }) {
    if (_cloakWallet == null) {
      print('[CloakWalletManager] transactPackedPublic: wallet is null');
      return null;
    }
    if (_mintParams == null || _spendOutputParams == null ||
        _spendParams == null || _outputParams == null) {
      print('[CloakWalletManager] transactPackedPublic: ZK params not loaded!'
          ' mint=${_mintParams != null}, spendOutput=${_spendOutputParams != null},'
          ' spend=${_spendParams != null}, output=${_outputParams != null}');
      return null;
    }
    return CloakApi.transactPacked(
      wallet: _cloakWallet!,
      ztxJson: ztxJson,
      feeTokenContract: 'thezeostoken',
      feesJson: feesJson,
      mintParams: _mintParams!,
      spendOutputParams: _spendOutputParams!,
      spendParams: _spendParams!,
      outputParams: _outputParams!,
    );
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
        print('[CloakWalletManager] Transaction extracted from tuple');
      } else if (decoded is Map<String, dynamic>) {
        tx = decoded;
      } else {
        print('[CloakWalletManager] Unexpected JSON format: ${decoded.runtimeType}');
        return null;
      }

      final actions = tx['actions'] as List?;
      if (actions == null || actions.isEmpty) {
        print('[CloakWalletManager] No actions in transaction');
        return null;
      }

      print('[CloakWalletManager] Found ${actions.length} actions in transaction');

      // Find the mint action - account name depends on wallet's alias_authority
      for (final action in actions) {
        final account = action['account']?.toString();
        final name = action['name']?.toString();
        print('[CloakWalletManager] Action: account=$account, name=$name');

        // mint action has name 10639630974360485888 (or "mint" string)
        // Account is the alias_authority actor (e.g., "thezeosalias" or "main")
        if (name == 'mint' || name == '10639630974360485888') {
          // Log ALL fields in the action to see if hex_data is available
          print('[CloakWalletManager] Mint action keys: ${action.keys.toList()}');

          final data = action['data'];
          final hexData = action['hex_data']?.toString();

          if (hexData != null && hexData.isNotEmpty) {
            print('[CloakWalletManager] Found hex_data! Length: ${hexData.length} chars');
            print('[CloakWalletManager] hex_data preview: ${hexData.substring(0, hexData.length > 100 ? 100 : hexData.length)}...');
          } else {
            print('[CloakWalletManager] WARNING: No hex_data found in mint action!');
          }

          if (data is Map<String, dynamic>) {
            print('[CloakWalletManager] Found mint action data');
            print('[CloakWalletManager] Mint data keys: ${data.keys.toList()}');
            // Log sample of each field to understand the format
            for (final key in data.keys) {
              final value = data[key];
              final valueStr = value.toString();
              final preview = valueStr.length > 100 ? '${valueStr.substring(0, 100)}...' : valueStr;
              print('[CloakWalletManager] Mint.$key (${value.runtimeType}): $preview');
            }

            // Return data with hex_data included so ESR service can use it
            final result = Map<String, dynamic>.from(data);
            if (hexData != null && hexData.isNotEmpty) {
              result['_hex_data'] = hexData;  // Store hex_data with underscore prefix to distinguish
              print('[CloakWalletManager] Added _hex_data to result');
            }
            return result;
          }
        }
      }

      print('[CloakWalletManager] Mint action not found in transaction');
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
    // FORCE correct alias_authority - wallet storage may have wrong value
    const aliasAuthority = 'thezeosalias@public';

    // Debug: show what wallet thinks vs what we're using
    final storedAlias = getAliasAuthority();
    print('[CloakWalletManager] Building ZTransaction with:');
    print('  chain_id: $chainId');
    print('  protocol_contract: $protocolContract');
    print('  vault_contract: $vaultContract');
    print('  alias_authority (FORCED): $aliasAuthority');
    print('  alias_authority (stored): $storedAlias');
    if (storedAlias != aliasAuthority) {
      print('  *** WARNING: Wallet has wrong alias_authority stored! Using forced value. ***');
    }

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
    print('[CloakWalletManager] Generating clear-buffer ESR for $telosAccount');

    // Build 3 actions: begin, fee transfer, end
    final actions = EsrService.buildClearBufferActions(
      userAccount: telosAccount,
      feeQuantity: '0.2000 CLOAK',
    );

    // Create ESR with pre-signed thezeosalias signature (same flow as shield)
    final esrUrl = await EsrService.createSigningRequestWithPresig(actions: actions);

    print('[CloakWalletManager] Clear-buffer ESR created (${esrUrl.length} chars)');

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
    print('[CloakWalletManager] Generating full shield ESR: $quantity from $telosAccount');

    // 0. Get or create vault hash for AUTH memo
    // NOTE: Do NOT call getPrimaryVaultHash() or getVaults() - FFI crashes!
    // Use stored vault hash from database instead
    String? vaultHash = await getStoredVaultHash();
    if (vaultHash == null || vaultHash.isEmpty) {
      print('[CloakWalletManager] No stored vault hash, creating vault...');
      vaultHash = await createAndStoreVault();
      if (vaultHash == null) {
        throw Exception('Failed to create vault for shield operation');
      }
    }
    print('[CloakWalletManager] Using vault hash for AUTH memo: ${vaultHash.substring(0, 16)}...');

    // 1. Generate the ZK mint proof (this takes time)
    final mintProof = await generateMintProof(
      tokenContract: tokenContract,
      quantity: quantity,
      fromAccount: telosAccount,
    );

    // 2. Build all 5 actions with the actual user account
    final feeQuantity = await getShieldFee();
    final actions = EsrService.buildShieldActionsWithAccount(
      tokenContract: tokenContract,
      quantity: quantity,
      mintProof: mintProof,
      userAccount: telosAccount,
      feeQuantity: feeQuantity,
    );

    // 3. Create ESR with pre-signed thezeosalias signature and flags=0
    // Flow:
    //   a. Build the full 5-action transaction, serialize it, compute digest
    //   b. Sign digest with thezeosalias@public key, store in _lastPresignature
    //   c. Store serialized transaction bytes in _lastTxBytes
    //   d. Create ESR variant 2 (full transaction) with flags=0
    //   e. Anchor signs the same full transaction, returns user signature via WebSocket
    //   f. Flutter combines both signatures and broadcasts via push_transaction
    final esrUrl = await EsrService.createSigningRequestWithPresig(actions: actions);

    print('[CloakWalletManager] Shield ESR created (${esrUrl.length} chars, flags=0)');
    print('[CloakWalletManager] thezeosalias signature stored in EsrService._lastPresignature');
    print('[CloakWalletManager] Transaction bytes stored in EsrService._lastTxBytes');

    return {
      'esrUrl': esrUrl,
      'tokenContract': tokenContract,
      'quantity': quantity,
      'telosAccount': telosAccount,
      'vaultHash': vaultHash,
      'mintProof': mintProof,
      'feeQuantity': feeQuantity,
    };
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
    print('[CloakWalletManager] Completing shield transaction');
    print('[CloakWalletManager] User signatures: ${userSignatures.length}');

    final tokenContract = shieldData['tokenContract'] as String;
    final quantity = shieldData['quantity'] as String;
    final telosAccount = shieldData['telosAccount'] as String;
    final mintProof = shieldData['mintProof'] as Map<String, dynamic>;

    // Build and broadcast the complete transaction
    final txId = await EsrService.buildAndBroadcastShieldTransaction(
      userSignatures: userSignatures,
      tokenContract: tokenContract,
      quantity: quantity,
      userAccount: telosAccount,
      mintProof: mintProof,
      feeQuantity: await getShieldFee(),
    );

    print('[CloakWalletManager] Shield transaction complete! TX: $txId');
    return txId;
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
    print('[CloakWalletManager] Generating shield ESR: $quantity from $telosAccount');

    // 0. Get or create vault hash for AUTH memo
    // NOTE: Do NOT call getPrimaryVaultHash() or getVaults() - FFI crashes!
    // Use stored vault hash from database instead
    String? vaultHash = await getStoredVaultHash();
    if (vaultHash == null || vaultHash.isEmpty) {
      print('[CloakWalletManager] No stored vault hash, creating vault...');
      vaultHash = await createAndStoreVault();
      if (vaultHash == null) {
        throw Exception('Failed to create vault for shield operation');
      }
    }
    print('[CloakWalletManager] Using vault hash for AUTH memo: ${vaultHash.substring(0, 16)}...');

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
    final esrUrl = await EsrService.createSigningRequestWithPresig(actions: actions);

    print('[CloakWalletManager] ESR URL created (${esrUrl.length} chars)');
    print('[CloakWalletManager] Full ESR URL: $esrUrl');

    return esrUrl;
  }

  /// Generate a simple transfer ESR for testing (without launching)
  ///
  /// Returns the ESR URL string
  static String generateSimpleTransferEsr() {
    print('[CloakWalletManager] Generating simple transfer ESR for testing...');

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
    print('[CloakWalletManager] Test ESR URL: $esrUrl');

    // Validate the generated ESR
    final decoded = EsrService.decodeEsrForDebug(esrUrl);
    if (decoded != null && decoded['valid'] == true) {
      print('[CloakWalletManager] ESR VALID! Header: 0x${(decoded['header'] as int).toRadixString(16)}');
    }

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
    print('[CloakWalletManager] Initiating shield: $quantity from $telosAccount');

    try {
      // 1. Generate the ESR URL
      final esrUrl = await generateShieldEsr(
        tokenContract: tokenContract,
        quantity: quantity,
        telosAccount: telosAccount,
      );

      // 2. Launch Anchor wallet
      print('[CloakWalletManager] Launching Anchor with ESR...');
      final launched = await EsrService.launchAnchor(esrUrl);

      if (launched) {
        print('[CloakWalletManager] Anchor launched - user will approve transaction');
      } else {
        throw Exception('Failed to launch Anchor wallet');
      }

      return launched;
    } catch (e) {
      print('[CloakWalletManager] Shield error: $e');
      rethrow;
    }
  }
}
