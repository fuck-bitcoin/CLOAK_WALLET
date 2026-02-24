import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'cloak_api_generated.dart';

// Telos Mainnet configuration
const TELOS_CHAIN_ID = '4667b205c6838ef70ff7988f6e8257e8be0e1284a2f59699054a018f743b1d11';
const ZEOS_PROTOCOL_CONTRACT = 'zeosprotocol';
const ZEOS_VAULT_CONTRACT = 'thezeosvault';

final cloak_api_lib = _init();

NativeLibrary _init() {
  return NativeLibrary(CloakApi.open());
}

Pointer<Char> _toNative(String s) {
  return s.toNativeUtf8().cast<Char>();
}

String _fromNative(Pointer<Char> ptr) {
  if (ptr == nullptr) return '';
  final str = ptr.cast<Utf8>().toDartString();
  cloak_api_lib.free_string(ptr);
  return str;
}

String? _getLastError() {
  final errPtr = cloak_api_lib.wallet_last_error();
  if (errPtr == nullptr) return null;
  return _fromNative(errPtr);
}

class CloakApi {
  static DynamicLibrary open() {
    if (Platform.isAndroid) return DynamicLibrary.open('libzeos_caterpillar.so');
    if (Platform.isIOS) return DynamicLibrary.executable();
    if (Platform.isWindows) return DynamicLibrary.open('zeos_caterpillar.dll');
    if (Platform.isLinux) return DynamicLibrary.open('libzeos_caterpillar.so');
    if (Platform.isMacOS) {
      // macOS: dylib is in Contents/Frameworks/ of the app bundle.
      // DynamicLibrary.open() with a bare name calls dlopen() which does NOT
      // search @rpath or Frameworks/. Resolve the full path relative to the
      // executable (Contents/MacOS/<exe> → ../Frameworks/).
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return DynamicLibrary.open('$exeDir/../Frameworks/libzeos_caterpillar.dylib');
    }
    throw UnsupportedError('This platform is not supported.');
  }

  /// Get the last error message from the Rust library
  static String? getLastError() => _getLastError();

  /// Create a new CLOAK wallet from seed phrase
  /// Returns wallet pointer or null on error
  static Pointer<Void>? createWallet(
    String seed, {
    bool isIvk = false,
    String chainId = TELOS_CHAIN_ID,
    String protocolContract = ZEOS_PROTOCOL_CONTRACT,
    String vaultContract = ZEOS_VAULT_CONTRACT,
    String aliasAuthority = 'thezeosalias@public',
  }) {
    print('[CloakApi.createWallet] Creating wallet with:');
    print('  chainId: $chainId');
    print('  protocolContract: $protocolContract');
    print('  vaultContract: $vaultContract');
    print('  aliasAuthority: $aliasAuthority');

    final seedPtr = _toNative(seed);
    final chainIdPtr = _toNative(chainId);
    final protocolPtr = _toNative(protocolContract);
    final vaultPtr = _toNative(vaultContract);
    final aliasPtr = _toNative(aliasAuthority);
    final outWallet = calloc<Pointer<Void>>();

    try {
      final success = cloak_api_lib.wallet_create(
        seedPtr,
        isIvk,
        chainIdPtr,
        protocolPtr,
        vaultPtr,
        aliasPtr,
        outWallet,
      );

      if (!success) {
        final err = _getLastError();
        print('wallet_create failed: $err');
        return null;
      }

      return outWallet.value;
    } finally {
      calloc.free(seedPtr);
      calloc.free(chainIdPtr);
      calloc.free(protocolPtr);
      calloc.free(vaultPtr);
      calloc.free(aliasPtr);
      calloc.free(outWallet);
    }
  }

  /// Close and free wallet
  static void closeWallet(Pointer<Void> wallet) {
    cloak_api_lib.wallet_close(wallet);
  }

  /// Get wallet size in bytes (for serialization)
  static int? getWalletSize(Pointer<Void> wallet) {
    final outSize = calloc<Uint64>();
    try {
      if (!cloak_api_lib.wallet_size(wallet, outSize)) {
        print('wallet_size failed: ${_getLastError()}');
        return null;
      }
      return outSize.value;
    } finally {
      calloc.free(outSize);
    }
  }

  /// Serialize wallet to bytes
  static Uint8List? writeWallet(Pointer<Void> wallet) {
    final size = getWalletSize(wallet);
    if (size == null || size == 0) return null;

    final outBytes = calloc<Uint8>(size);
    try {
      if (!cloak_api_lib.wallet_write(wallet, outBytes)) {
        print('wallet_write failed: ${_getLastError()}');
        return null;
      }
      return Uint8List.fromList(outBytes.asTypedList(size));
    } finally {
      calloc.free(outBytes);
    }
  }

  /// Deserialize wallet from bytes
  static Pointer<Void>? readWallet(Uint8List bytes) {
    final bytesPtr = calloc<Uint8>(bytes.length);
    final outWallet = calloc<Pointer<Void>>();

    try {
      bytesPtr.asTypedList(bytes.length).setAll(0, bytes);

      if (!cloak_api_lib.wallet_read(bytesPtr, bytes.length, outWallet)) {
        print('wallet_read failed: ${_getLastError()}');
        return null;
      }

      return outWallet.value;
    } finally {
      calloc.free(bytesPtr);
      calloc.free(outWallet);
    }
  }

  /// Get the stable default address (deterministic from seed, never changes)
  static String? defaultAddress(Pointer<Void> wallet) {
    final outAddress = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_default_address(wallet, outAddress)) {
        print('wallet_default_address failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outAddress.value);
    } finally {
      calloc.free(outAddress);
    }
  }

  /// Derive the next shielded address (increments internal diversifier)
  static String? deriveAddress(Pointer<Void> wallet) {
    final outAddress = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_derive_address(wallet, outAddress)) {
        print('wallet_derive_address failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outAddress.value);
    } finally {
      calloc.free(outAddress);
    }
  }

  /// Get all derived addresses as JSON
  static String? getAddressesJson(Pointer<Void> wallet, {bool pretty = false}) {
    final outJson = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_addresses_json(wallet, pretty, outJson)) {
        print('wallet_addresses_json failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outJson.value);
    } finally {
      calloc.free(outJson);
    }
  }

  /// Get wallet balances as JSON
  static String? getBalancesJson(Pointer<Void> wallet, {bool pretty = false}) {
    final outJson = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_balances_json(wallet, pretty, outJson)) {
        print('wallet_balances_json failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outJson.value);
    } finally {
      calloc.free(outJson);
    }
  }

  /// Estimate the total send fee for a given amount, accounting for note fragmentation.
  /// [sendAmount] is in smallest units (10000 = 1.0 CLOAK).
  /// [feesJson] is the JSON fees map from _getFeesJson().
  /// [recipientAddress] optional recipient for self-send detection (reduces publishnotes fees).
  /// Returns the fee in smallest units, or null on failure.
  static int? estimateSendFee(Pointer<Void> wallet, int sendAmount, String feesJson, {String feeTokenContract = 'thezeostoken', String? recipientAddress}) {
    final feesPtr = _toNative(feesJson);
    final contractPtr = _toNative(feeTokenContract);
    final recipientPtr = recipientAddress != null ? _toNative(recipientAddress) : nullptr.cast<Char>();
    final outFee = calloc<Uint64>();
    try {
      if (!cloak_api_lib.wallet_estimate_send_fee(wallet, sendAmount, feesPtr, contractPtr, recipientPtr, outFee)) {
        print('wallet_estimate_send_fee failed: ${_getLastError()}');
        return null;
      }
      return outFee.value;
    } finally {
      calloc.free(feesPtr);
      calloc.free(contractPtr);
      if (recipientAddress != null) calloc.free(recipientPtr);
      calloc.free(outFee);
    }
  }

  /// Estimate the total burn fee for a vault burn, accounting for note fragmentation.
  /// [hasAssets] whether the vault has tokens to withdraw before burning.
  /// [feesJson] is the JSON fees map from _getFeesJson().
  /// Returns the fee in smallest units, or null on failure.
  static int? estimateBurnFee(Pointer<Void> wallet, bool hasAssets, String feesJson, {String feeTokenContract = 'thezeostoken'}) {
    final feesPtr = _toNative(feesJson);
    final contractPtr = _toNative(feeTokenContract);
    final outFee = calloc<Uint64>();
    try {
      if (!cloak_api_lib.wallet_estimate_burn_fee(wallet, hasAssets, feesPtr, contractPtr, outFee)) {
        print('wallet_estimate_burn_fee failed: ${_getLastError()}');
        return null;
      }
      return outFee.value;
    } finally {
      calloc.free(feesPtr);
      calloc.free(contractPtr);
      calloc.free(outFee);
    }
  }

  /// Estimate vault creation (auth token publish) fee accounting for note fragmentation.
  /// Returns the fee in smallest units, or null on failure.
  static int? estimateVaultCreationFee(Pointer<Void> wallet, String feesJson, {String feeTokenContract = 'thezeostoken'}) {
    final feesPtr = _toNative(feesJson);
    final contractPtr = _toNative(feeTokenContract);
    final outFee = calloc<Uint64>();
    try {
      if (!cloak_api_lib.wallet_estimate_vault_creation_fee(wallet, feesPtr, contractPtr, outFee)) {
        print('wallet_estimate_vault_creation_fee failed: ${_getLastError()}');
        return null;
      }
      return outFee.value;
    } finally {
      calloc.free(feesPtr);
      calloc.free(contractPtr);
      calloc.free(outFee);
    }
  }

  /// Get non-fungible tokens as JSON
  static String? getNonFungibleTokensJson(Pointer<Void> wallet, {int contract = 0, bool pretty = false}) {
    final outJson = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_non_fungible_tokens_json(wallet, contract, pretty, outJson)) {
        print('wallet_non_fungible_tokens_json failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outJson.value);
    } finally {
      calloc.free(outJson);
    }
  }

  /// Get unspent notes as JSON
  static String? getUnspentNotesJson(Pointer<Void> wallet, {bool pretty = false}) {
    final outJson = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_unspent_notes_json(wallet, pretty, outJson)) {
        print('wallet_unspent_notes_json failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outJson.value);
    } finally {
      calloc.free(outJson);
    }
  }

  /// Get transaction history as JSON
  static String? getTransactionHistoryJson(Pointer<Void> wallet, {bool pretty = false}) {
    final outJson = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_transaction_history_json(wallet, pretty, outJson)) {
        print('wallet_transaction_history_json failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outJson.value);
    } finally {
      calloc.free(outJson);
    }
  }

  /// Get full wallet state as JSON (for debugging)
  static String? getWalletJson(Pointer<Void> wallet, {bool pretty = true}) {
    final outJson = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_json(wallet, pretty, outJson)) {
        print('wallet_json failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outJson.value);
    } finally {
      calloc.free(outJson);
    }
  }

  /// Get chain ID
  static String? getChainId(Pointer<Void> wallet) {
    final outChainId = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_chain_id(wallet, outChainId)) {
        print('wallet_chain_id failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outChainId.value);
    } finally {
      calloc.free(outChainId);
    }
  }

  /// Get protocol contract name
  static String? getProtocolContract(Pointer<Void> wallet) {
    final outContract = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_protocol_contract(wallet, outContract)) {
        print('wallet_protocol_contract failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outContract.value);
    } finally {
      calloc.free(outContract);
    }
  }

  /// Get vault contract name
  static String? getVaultContract(Pointer<Void> wallet) {
    final outContract = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_vault_contract(wallet, outContract)) {
        print('wallet_vault_contract failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outContract.value);
    } finally {
      calloc.free(outContract);
    }
  }

  /// Get alias authority (e.g., "thezeosalias@public")
  static String? getAliasAuthority(Pointer<Void> wallet) {
    final outAuth = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_alias_authority(wallet, outAuth)) {
        print('wallet_alias_authority failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outAuth.value);
    } finally {
      calloc.free(outAuth);
    }
  }

  /// Get current block number
  static int? getBlockNum(Pointer<Void> wallet) {
    final outNum = calloc<Uint32>();
    try {
      if (!cloak_api_lib.wallet_block_num(wallet, outNum)) {
        print('wallet_block_num failed: ${_getLastError()}');
        return null;
      }
      return outNum.value;
    } finally {
      calloc.free(outNum);
    }
  }

  /// Get leaf count in merkle tree
  static int? getLeafCount(Pointer<Void> wallet) {
    final outCount = calloc<Uint64>();
    try {
      if (!cloak_api_lib.wallet_leaf_count(wallet, outCount)) {
        print('wallet_leaf_count failed: ${_getLastError()}');
        return null;
      }
      return outCount.value;
    } finally {
      calloc.free(outCount);
    }
  }

  /// Process a block for note detection
  static int? digestBlock(Pointer<Void> wallet, String blockJson) {
    final blockPtr = _toNative(blockJson);
    final outDigest = calloc<Uint64>();
    try {
      if (!cloak_api_lib.wallet_digest_block(wallet, blockPtr, outDigest)) {
        print('wallet_digest_block failed: ${_getLastError()}');
        return null;
      }
      return outDigest.value;
    } finally {
      calloc.free(blockPtr);
      calloc.free(outDigest);
    }
  }

  /// Check if wallet is view-only (IVK)
  static bool? isViewOnly(Pointer<Void> wallet) {
    final outIsIvk = calloc<Uint8>();
    try {
      if (!cloak_api_lib.wallet_is_ivk(wallet, outIsIvk)) {
        print('wallet_is_ivk failed: ${_getLastError()}');
        return null;
      }
      return outIsIvk.value != 0;
    } finally {
      calloc.free(outIsIvk);
    }
  }

  /// Get seed as hex string
  static String? getSeedHex(Pointer<Void> wallet) {
    final outSeed = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_seed_hex(wallet, outSeed)) {
        print('wallet_seed_hex failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outSeed.value);
    } finally {
      calloc.free(outSeed);
    }
  }

  /// Get Incoming Viewing Key as bech32m encoded string (ivk1...)
  /// This key allows viewing incoming transactions without spending capability.
  static String? getIvkBech32m(Pointer<Void> wallet) {
    final outIvk = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_ivk_bech32m(wallet, outIvk)) {
        print('wallet_ivk_bech32m failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outIvk.value);
    } finally {
      calloc.free(outIvk);
    }
  }

  /// Get Full Viewing Key as bech32m encoded string (fvk1...)
  /// This key allows viewing both incoming AND outgoing transactions.
  static String? getFvkBech32m(Pointer<Void> wallet) {
    final outFvk = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_fvk_bech32m(wallet, outFvk)) {
        print('wallet_fvk_bech32m failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outFvk.value);
    } finally {
      calloc.free(outFvk);
    }
  }

  /// Get Outgoing Viewing Key as bech32m encoded string (ovk1...)
  /// This key allows viewing outgoing transactions only.
  static String? getOvkBech32m(Pointer<Void> wallet) {
    final outOvk = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_ovk_bech32m(wallet, outOvk)) {
        print('wallet_ovk_bech32m failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outOvk.value);
    } finally {
      calloc.free(outOvk);
    }
  }

  /// Mark notes as spent by checking on-chain nullifiers.
  /// [nullifiersHex] - hex-encoded concatenated 32-byte nullifier values.
  /// Returns the number of notes marked as spent, or null on error.
  static int? addNullifiers(Pointer<Void> wallet, String nullifiersHex) {
    if (nullifiersHex.isEmpty) return 0;
    final hexPtr = _toNative(nullifiersHex);
    final outCount = calloc<Uint64>();
    try {
      if (!cloak_api_lib.wallet_add_nullifiers(wallet, hexPtr, outCount)) {
        print('wallet_add_nullifiers failed: ${_getLastError()}');
        return null;
      }
      return outCount.value;
    } finally {
      calloc.free(hexPtr);
      calloc.free(outCount);
    }
  }

  /// Add merkle tree leaves to the wallet
  /// leavesHex: Hex-encoded concatenated 32-byte leaf values
  /// Example: "abcd1234...5678efgh..." where each 64 hex chars = 1 leaf
  static bool addLeaves(Pointer<Void> wallet, String leavesHex) {
    final leavesPtr = _toNative(leavesHex);
    try {
      if (!cloak_api_lib.wallet_add_leaves(wallet, leavesPtr)) {
        print('wallet_add_leaves failed: ${_getLastError()}');
        return false;
      }
      return true;
    } finally {
      calloc.free(leavesPtr);
    }
  }

  /// Add encrypted notes for trial decryption
  /// notesJson: JSON array of base64-encoded TransmittedNoteCiphertext objects
  /// Example: ["base64note1", "base64note2", ...]
  /// blockNum: block number for timestamp (0 if unknown)
  /// blockTsMs: block timestamp in milliseconds since epoch (0 if unknown)
  /// Returns packed count: (ats << 16) | (nfts << 8) | fts
  static int addNotes(Pointer<Void> wallet, String notesJson, {int blockNum = 0, int blockTsMs = 0}) {
    final notesPtr = _toNative(notesJson);
    try {
      return cloak_api_lib.wallet_add_notes(wallet, notesPtr, blockNum, blockTsMs);
    } finally {
      calloc.free(notesPtr);
    }
  }

  /// Build and sign a ZEOS transaction
  ///
  /// [wallet] - The wallet pointer
  /// [ztxJson] - Transaction description JSON (amounts, recipients, etc.)
  /// [feeTokenContract] - Fee token contract name (e.g., "eosio.token")
  /// [feesJson] - Fee amounts JSON
  /// [mintParams] - Mint circuit params bytes
  /// [spendOutputParams] - SpendOutput circuit params bytes
  /// [spendParams] - Spend circuit params bytes
  /// [outputParams] - Output circuit params bytes
  ///
  /// Returns signed EOSIO transaction JSON ready for broadcast, or null on error
  static String? transact({
    required Pointer<Void> wallet,
    required String ztxJson,
    required String feeTokenContract,
    required String feesJson,
    required Uint8List mintParams,
    required Uint8List spendOutputParams,
    required Uint8List spendParams,
    required Uint8List outputParams,
  }) {
    // Convert strings to native
    final ztxPtr = _toNative(ztxJson);
    final feeContractPtr = _toNative(feeTokenContract);
    final feesPtr = _toNative(feesJson);

    // Allocate and copy param bytes to native memory
    final mintParamsPtr = calloc<Uint8>(mintParams.length);
    final spendOutputParamsPtr = calloc<Uint8>(spendOutputParams.length);
    final spendParamsPtr = calloc<Uint8>(spendParams.length);
    final outputParamsPtr = calloc<Uint8>(outputParams.length);

    mintParamsPtr.asTypedList(mintParams.length).setAll(0, mintParams);
    spendOutputParamsPtr.asTypedList(spendOutputParams.length).setAll(0, spendOutputParams);
    spendParamsPtr.asTypedList(spendParams.length).setAll(0, spendParams);
    outputParamsPtr.asTypedList(outputParams.length).setAll(0, outputParams);

    final outTxJson = calloc<Pointer<Char>>();

    try {
      final success = cloak_api_lib.wallet_transact(
        wallet,
        ztxPtr,
        feeContractPtr,
        feesPtr,
        mintParamsPtr,
        mintParams.length,
        spendOutputParamsPtr,
        spendOutputParams.length,
        spendParamsPtr,
        spendParams.length,
        outputParamsPtr,
        outputParams.length,
        outTxJson,
      );

      if (!success) {
        print('wallet_transact failed: ${_getLastError()}');
        return null;
      }

      return _fromNative(outTxJson.value);
    } finally {
      calloc.free(ztxPtr);
      calloc.free(feeContractPtr);
      calloc.free(feesPtr);
      calloc.free(mintParamsPtr);
      calloc.free(spendOutputParamsPtr);
      calloc.free(spendParamsPtr);
      calloc.free(outputParamsPtr);
      calloc.free(outTxJson);
    }
  }

  // ============== Auth Count ==============

  /// Get the wallet's current auth_count value
  static int? getAuthCount(Pointer<Void> wallet) {
    final outCount = calloc<Uint64>();
    try {
      if (!cloak_api_lib.wallet_auth_count(wallet, outCount)) {
        print('wallet_auth_count failed: ${_getLastError()}');
        return null;
      }
      return outCount.value;
    } finally {
      calloc.free(outCount);
    }
  }

  /// Set the wallet's auth_count to match on-chain global state
  /// This is critical for ZK proof generation — the proof's auth_hash
  /// uses auth_count, so it must match the on-chain value.
  static bool setAuthCount(Pointer<Void> wallet, int count) {
    if (!cloak_api_lib.wallet_set_auth_count(wallet, count)) {
      print('wallet_set_auth_count failed: ${_getLastError()}');
      return false;
    }
    return true;
  }

  /// Reset wallet chain state to empty (preserves unpublished_notes).
  /// Caller must call writeWallet() after to persist.
  /// Returns false on error (e.g., null wallet pointer).
  static bool resetChainState(Pointer<Void> wallet) {
    final success = cloak_api_lib.wallet_reset_chain_state(wallet);
    if (!success) {
      final err = _getLastError();
      print('wallet_reset_chain_state failed: $err');
    }
    return success;
  }

  /// Clear all unpublished notes (auth tokens for vaults) from the wallet.
  /// Called before re-importing vaults from DB to prevent duplicate accumulation.
  /// Caller must call writeWallet() after to persist.
  static bool clearUnpublishedNotes(Pointer<Void> wallet) {
    final success = cloak_api_lib.wallet_clear_unpublished_notes(wallet);
    if (!success) {
      final err = _getLastError();
      print('wallet_clear_unpublished_notes failed: $err');
    }
    return success;
  }

  // ============== Vault / Auth Token Functions ==============

  /// Get authentication tokens (vaults) as JSON array
  /// These are special notes with amount=0 used for receiving tokens asynchronously
  ///
  /// [contract] - Filter by contract (0 for all contracts)
  /// [spent] - If true, include spent auth tokens
  static String? getAuthenticationTokensJson(Pointer<Void> wallet, {int contract = 0, bool spent = false, bool seed = false, bool pretty = false}) {
    final outJson = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_authentication_tokens_json(wallet, contract, spent, seed, pretty, outJson)) {
        print('wallet_authentication_tokens_json failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outJson.value);
    } finally {
      calloc.free(outJson);
    }
  }

  /// Get unpublished notes as JSON
  /// These are notes created locally but not yet committed to blockchain
  static String? getUnpublishedNotesJson(Pointer<Void> wallet, {bool pretty = false}) {
    final outJson = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_unpublished_notes_json(wallet, pretty, outJson)) {
        print('wallet_unpublished_notes_json failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outJson.value);
    } finally {
      calloc.free(outJson);
    }
  }

  /// Add unpublished notes to wallet
  /// [notesJson] - JSON map: { "address": ["note_ct_base64", ...], ... }
  static bool addUnpublishedNotes(Pointer<Void> wallet, String notesJson) {
    final notesPtr = _toNative(notesJson);
    try {
      if (!cloak_api_lib.wallet_add_unpublished_notes(wallet, notesPtr)) {
        print('wallet_add_unpublished_notes failed: ${_getLastError()}');
        return false;
      }
      return true;
    } finally {
      calloc.free(notesPtr);
    }
  }

  /// Create a new vault (authentication token) for receiving tokens
  ///
  /// This creates a special note with amount=0 that can be shared with dApps.
  /// When a dApp sends tokens to the vault contract with the auth token hash,
  /// the wallet can claim those tokens using the `authenticate` action.
  ///
  /// [seed] - Random seed string (used for note randomness)
  /// [contract] - Token contract as EOSIO name u64 (e.g., for thezeostoken)
  /// [address] - Recipient bech32m address (usually your own address)
  ///
  /// Returns JSON map of unpublished notes to be added to wallet
  static String? createUnpublishedAuthNote(Pointer<Void> wallet, String seed, int contract, String address) {
    final seedPtr = _toNative(seed);
    final addressPtr = _toNative(address);
    final outJson = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_create_unpublished_auth_note(wallet, seedPtr, contract, addressPtr, outJson)) {
        print('wallet_create_unpublished_auth_note failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outJson.value);
    } finally {
      calloc.free(seedPtr);
      calloc.free(addressPtr);
      calloc.free(outJson);
    }
  }

  /// Build and sign a ZEOS transaction with packed (ABI-serialized) action data.
  ///
  /// This is like [transact] but returns actions with hex_data field containing
  /// ABI-serialized binary data. This is required for ESR/Anchor wallet integration
  /// which expects actions in packed format.
  ///
  /// [wallet] - The wallet pointer
  /// [ztxJson] - Transaction description JSON (amounts, recipients, etc.)
  /// [feeTokenContract] - Fee token contract name (e.g., "eosio.token")
  /// [feesJson] - Fee amounts JSON
  /// [mintParams] - Mint circuit params bytes
  /// [spendOutputParams] - SpendOutput circuit params bytes
  /// [spendParams] - Spend circuit params bytes
  /// [outputParams] - Output circuit params bytes
  ///
  /// Returns signed EOSIO transaction JSON with hex_data for each action, or null on error
  static String? transactPacked({
    required Pointer<Void> wallet,
    required String ztxJson,
    required String feeTokenContract,
    required String feesJson,
    required Uint8List mintParams,
    required Uint8List spendOutputParams,
    required Uint8List spendParams,
    required Uint8List outputParams,
  }) {
    // Convert strings to native
    final ztxPtr = _toNative(ztxJson);
    final feeContractPtr = _toNative(feeTokenContract);
    final feesPtr = _toNative(feesJson);

    // Allocate and copy param bytes to native memory
    final mintParamsPtr = calloc<Uint8>(mintParams.length);
    final spendOutputParamsPtr = calloc<Uint8>(spendOutputParams.length);
    final spendParamsPtr = calloc<Uint8>(spendParams.length);
    final outputParamsPtr = calloc<Uint8>(outputParams.length);

    mintParamsPtr.asTypedList(mintParams.length).setAll(0, mintParams);
    spendOutputParamsPtr.asTypedList(spendOutputParams.length).setAll(0, spendOutputParams);
    spendParamsPtr.asTypedList(spendParams.length).setAll(0, spendParams);
    outputParamsPtr.asTypedList(outputParams.length).setAll(0, outputParams);

    final outTxJson = calloc<Pointer<Char>>();

    try {
      final success = cloak_api_lib.wallet_transact_packed(
        wallet,
        ztxPtr,
        feeContractPtr,
        feesPtr,
        mintParamsPtr,
        mintParams.length,
        spendOutputParamsPtr,
        spendOutputParams.length,
        spendParamsPtr,
        spendParams.length,
        outputParamsPtr,
        outputParams.length,
        outTxJson,
      );

      if (!success) {
        print('wallet_transact_packed failed: ${_getLastError()}');
        return null;
      }

      return _fromNative(outTxJson.value);
    } finally {
      calloc.free(ztxPtr);
      calloc.free(feeContractPtr);
      calloc.free(feesPtr);
      calloc.free(mintParamsPtr);
      calloc.free(spendOutputParamsPtr);
      calloc.free(spendParamsPtr);
      calloc.free(outputParamsPtr);
      calloc.free(outTxJson);
    }
  }

  // ============== Deterministic Vault Functions ==============

  /// Derive a deterministic vault seed at the given index.
  /// Returns hex-encoded 32-byte HMAC-SHA256 seed, or null on failure.
  static String? deriveVaultSeed(Pointer<Void> wallet, int index) {
    final outHex = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_derive_vault_seed(wallet, index, outHex)) {
        print('wallet_derive_vault_seed failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outHex.value);
    } finally {
      calloc.free(outHex);
    }
  }

  /// Compare spending keys of two wallets. Returns true if they derive from the same seed.
  static bool seedsMatch(Pointer<Void> walletA, Pointer<Void> walletB) {
    return cloak_api_lib.wallet_seeds_match(walletA, walletB);
  }

  /// Create a deterministic vault: derives seed at vault_index, creates auth token
  /// using the wallet's default address and the given contract.
  /// Returns JSON with commitment hash and unpublished notes, or null on failure.
  static String? createDeterministicVault(Pointer<Void> wallet, int contract, int vaultIndex) {
    final outJson = calloc<Pointer<Char>>();
    try {
      if (!cloak_api_lib.wallet_create_deterministic_vault(wallet, contract, vaultIndex, outJson)) {
        print('wallet_create_deterministic_vault failed: ${_getLastError()}');
        return null;
      }
      return _fromNative(outJson.value);
    } finally {
      calloc.free(outJson);
    }
  }
}
