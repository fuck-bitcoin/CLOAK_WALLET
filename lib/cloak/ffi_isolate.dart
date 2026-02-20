import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:cloak_api/cloak_api.dart' show CloakApi;
import 'package:cloak_api/cloak_api_generated.dart' show NativeLibrary;

/// Wraps blocking FFI calls in [Isolate.run] so the main UI thread stays
/// responsive. Each method re-opens the shared .so inside the spawned isolate,
/// reads thread-local error state there, and returns the result to the caller.
class FfiIsolate {
  /// Run [wallet_transact_packed] (ZKP generation) in a background isolate.
  /// The main thread stays responsive while the 10-30 s proof generates.
  ///
  /// Returns the signed EOSIO transaction JSON, or throws on failure.
  static Future<String> transactPacked({
    required Pointer<Void> wallet,
    required String ztxJson,
    required String feeTokenContract,
    required String feesJson,
    required Uint8List mintParams,
    required Uint8List spendOutputParams,
    required Uint8List spendParams,
    required Uint8List outputParams,
  }) async {
    // Pointer.address is a plain int — valid across isolates (same process).
    final walletAddr = wallet.address;

    return await Isolate.run(() {
      // Re-open the library in this isolate (cheap, .so already loaded).
      final lib = NativeLibrary(CloakApi.open());
      final walletPtr = Pointer<Void>.fromAddress(walletAddr);

      // Convert Dart strings to native UTF-8.
      final ztxPtr = ztxJson.toNativeUtf8().cast<Char>();
      final feeContractPtr = feeTokenContract.toNativeUtf8().cast<Char>();
      final feesPtr = feesJson.toNativeUtf8().cast<Char>();

      // Allocate and copy param buffers.
      final mintPtr = calloc<Uint8>(mintParams.length);
      final soPtr = calloc<Uint8>(spendOutputParams.length);
      final spPtr = calloc<Uint8>(spendParams.length);
      final opPtr = calloc<Uint8>(outputParams.length);

      mintPtr.asTypedList(mintParams.length).setAll(0, mintParams);
      soPtr.asTypedList(spendOutputParams.length).setAll(0, spendOutputParams);
      spPtr.asTypedList(spendParams.length).setAll(0, spendParams);
      opPtr.asTypedList(outputParams.length).setAll(0, outputParams);

      final outTxJson = calloc<Pointer<Char>>();

      try {
        final success = lib.wallet_transact_packed(
          walletPtr,
          ztxPtr,
          feeContractPtr,
          feesPtr,
          mintPtr,
          mintParams.length,
          soPtr,
          spendOutputParams.length,
          spPtr,
          spendParams.length,
          opPtr,
          outputParams.length,
          outTxJson,
        );

        if (!success) {
          // wallet_last_error() uses Rust thread_local! — MUST read in this
          // isolate, the same thread that made the FFI call.
          final errPtr = lib.wallet_last_error();
          String errMsg = 'ZK proof generation failed';
          if (errPtr != nullptr) {
            errMsg = errPtr.cast<Utf8>().toDartString();
            lib.free_string(errPtr);
          }
          throw errMsg;
        }

        // Read result string and free it in THIS isolate.
        final resultPtr = outTxJson.value;
        final resultStr = resultPtr.cast<Utf8>().toDartString();
        lib.free_string(resultPtr);
        return resultStr;
      } finally {
        calloc.free(ztxPtr);
        calloc.free(feeContractPtr);
        calloc.free(feesPtr);
        calloc.free(mintPtr);
        calloc.free(soPtr);
        calloc.free(spPtr);
        calloc.free(opPtr);
        calloc.free(outTxJson);
      }
    });
  }

  /// Run the [wallet_add_notes] loop in a background isolate.
  ///
  /// Each entry in [noteActions] is a map with keys:
  ///   - `notesJson` (String): JSON array of base64-encoded ciphertexts
  ///   - `blockNum` (int): block number for the action
  ///   - `blockTsMs` (int): block timestamp in ms since epoch
  ///
  /// Returns aggregate counts: `{fts, nfts, ats}`.
  static Future<Map<String, int>> addNotesAll({
    required Pointer<Void> wallet,
    required List<Map<String, dynamic>> noteActions,
  }) async {
    final walletAddr = wallet.address;

    return await Isolate.run(() {
      final lib = NativeLibrary(CloakApi.open());
      final walletPtr = Pointer<Void>.fromAddress(walletAddr);

      int totalFts = 0, totalNfts = 0, totalAts = 0;

      for (final action in noteActions) {
        final notesPtr =
            (action['notesJson'] as String).toNativeUtf8().cast<Char>();
        try {
          final result = lib.wallet_add_notes(
            walletPtr,
            notesPtr,
            action['blockNum'] as int,
            action['blockTsMs'] as int,
          );
          // Packed: (ats << 16) | (nfts << 8) | fts
          totalFts += result & 0xFF;
          totalNfts += (result >> 8) & 0xFF;
          totalAts += (result >> 16) & 0xFF;
        } finally {
          calloc.free(notesPtr);
        }
      }

      return {'fts': totalFts, 'nfts': totalNfts, 'ats': totalAts};
    });
  }

  /// Run [wallet_add_leaves] in a background isolate.
  ///
  /// [leavesHex]: hex-encoded concatenated 32-byte leaf values.
  /// Returns true on success.
  static Future<bool> addLeaves({
    required Pointer<Void> wallet,
    required String leavesHex,
  }) async {
    final walletAddr = wallet.address;
    return await Isolate.run(() {
      final lib = NativeLibrary(CloakApi.open());
      final walletPtr = Pointer<Void>.fromAddress(walletAddr);
      final leavesPtr = leavesHex.toNativeUtf8().cast<Char>();
      try {
        return lib.wallet_add_leaves(walletPtr, leavesPtr);
      } finally {
        calloc.free(leavesPtr);
      }
    });
  }

  /// Run [wallet_add_nullifiers] in a background isolate.
  ///
  /// [nullifiersHex]: hex-encoded concatenated 32-byte nullifier values.
  /// Returns the number of notes marked as spent, or 0 on failure.
  static Future<int> addNullifiers({
    required Pointer<Void> wallet,
    required String nullifiersHex,
  }) async {
    if (nullifiersHex.isEmpty) return 0;
    final walletAddr = wallet.address;
    return await Isolate.run(() {
      final lib = NativeLibrary(CloakApi.open());
      final walletPtr = Pointer<Void>.fromAddress(walletAddr);
      final nullPtr = nullifiersHex.toNativeUtf8().cast<Char>();
      final outCount = calloc<Uint64>();
      try {
        final success =
            lib.wallet_add_nullifiers(walletPtr, nullPtr, outCount);
        return success ? outCount.value : 0;
      } finally {
        calloc.free(nullPtr);
        calloc.free(outCount);
      }
    });
  }

  /// Run [wallet_transaction_history_json] in a background isolate.
  ///
  /// Returns the JSON string of transaction history, or null on failure.
  static Future<String?> getTransactionHistoryJson({
    required Pointer<Void> wallet,
    bool pretty = false,
  }) async {
    final walletAddr = wallet.address;
    return await Isolate.run(() {
      final lib = NativeLibrary(CloakApi.open());
      final walletPtr = Pointer<Void>.fromAddress(walletAddr);
      final outJson = calloc<Pointer<Char>>();
      try {
        if (!lib.wallet_transaction_history_json(walletPtr, pretty, outJson)) {
          return null;
        }
        final resultPtr = outJson.value;
        final resultStr = resultPtr.cast<Utf8>().toDartString();
        lib.free_string(resultPtr);
        return resultStr;
      } finally {
        calloc.free(outJson);
      }
    });
  }

  /// Run [wallet_balances_json] in a background isolate.
  /// Returns the JSON string of balances, or null on failure.
  static Future<String?> getBalancesJson({
    required Pointer<Void> wallet,
    bool pretty = false,
  }) async {
    final walletAddr = wallet.address;
    return await Isolate.run(() {
      final lib = NativeLibrary(CloakApi.open());
      final walletPtr = Pointer<Void>.fromAddress(walletAddr);
      final outJson = calloc<Pointer<Char>>();
      try {
        if (!lib.wallet_balances_json(walletPtr, pretty, outJson)) {
          return null;
        }
        final resultPtr = outJson.value;
        final resultStr = resultPtr.cast<Utf8>().toDartString();
        lib.free_string(resultPtr);
        return resultStr;
      } finally {
        calloc.free(outJson);
      }
    });
  }

  /// Run [wallet_create_unpublished_auth_note] in a background isolate.
  /// Returns the JSON string of unpublished notes, or null on failure.
  static Future<String?> createUnpublishedAuthNote({
    required Pointer<Void> wallet,
    required String seed,
    required int contract,
    required String address,
  }) async {
    final walletAddr = wallet.address;
    return await Isolate.run(() {
      final lib = NativeLibrary(CloakApi.open());
      final walletPtr = Pointer<Void>.fromAddress(walletAddr);
      final seedPtr = seed.toNativeUtf8().cast<Char>();
      final addressPtr = address.toNativeUtf8().cast<Char>();
      final outJson = calloc<Pointer<Char>>();
      try {
        if (!lib.wallet_create_unpublished_auth_note(
          walletPtr, seedPtr, contract, addressPtr, outJson,
        )) {
          return null;
        }
        final resultPtr = outJson.value;
        final resultStr = resultPtr.cast<Utf8>().toDartString();
        lib.free_string(resultPtr);
        return resultStr;
      } finally {
        calloc.free(seedPtr);
        calloc.free(addressPtr);
        calloc.free(outJson);
      }
    });
  }

  /// Run [wallet_derive_vault_seed] in a background isolate.
  /// Returns the hex-encoded 32-byte HMAC-SHA256 seed, or null on failure.
  static Future<String?> deriveVaultSeed({
    required Pointer<Void> wallet,
    required int index,
  }) async {
    final walletAddr = wallet.address;
    return await Isolate.run(() {
      final lib = NativeLibrary(CloakApi.open());
      final walletPtr = Pointer<Void>.fromAddress(walletAddr);
      final outHex = calloc<Pointer<Char>>();
      try {
        if (!lib.wallet_derive_vault_seed(walletPtr, index, outHex)) {
          return null;
        }
        final resultPtr = outHex.value;
        final resultStr = resultPtr.cast<Utf8>().toDartString();
        lib.free_string(resultPtr);
        return resultStr;
      } finally {
        calloc.free(outHex);
      }
    });
  }

  /// Run [wallet_seeds_match] in a background isolate.
  /// Returns true if both wallets derive from the same seed.
  static Future<bool> seedsMatch({
    required Pointer<Void> walletA,
    required Pointer<Void> walletB,
  }) async {
    final addrA = walletA.address;
    final addrB = walletB.address;
    return await Isolate.run(() {
      final lib = NativeLibrary(CloakApi.open());
      final ptrA = Pointer<Void>.fromAddress(addrA);
      final ptrB = Pointer<Void>.fromAddress(addrB);
      return lib.wallet_seeds_match(ptrA, ptrB);
    });
  }

  /// Run [wallet_create_deterministic_vault] in a background isolate.
  /// Returns JSON with commitment hash and unpublished notes, or null on failure.
  static Future<String?> createDeterministicVault({
    required Pointer<Void> wallet,
    required int contract,
    required int vaultIndex,
  }) async {
    final walletAddr = wallet.address;
    return await Isolate.run(() {
      final lib = NativeLibrary(CloakApi.open());
      final walletPtr = Pointer<Void>.fromAddress(walletAddr);
      final outJson = calloc<Pointer<Char>>();
      try {
        if (!lib.wallet_create_deterministic_vault(walletPtr, contract, vaultIndex, outJson)) {
          return null;
        }
        final resultPtr = outJson.value;
        final resultStr = resultPtr.cast<Utf8>().toDartString();
        lib.free_string(resultPtr);
        return resultStr;
      } finally {
        calloc.free(outJson);
      }
    });
  }

  /// Run [wallet_write] in a background isolate.
  /// Returns the serialized wallet bytes, or null on failure.
  static Future<Uint8List?> writeWallet({
    required Pointer<Void> wallet,
  }) async {
    final walletAddr = wallet.address;
    return await Isolate.run(() {
      final lib = NativeLibrary(CloakApi.open());
      final walletPtr = Pointer<Void>.fromAddress(walletAddr);

      // First get size
      final outSize = calloc<Uint64>();
      try {
        if (!lib.wallet_size(walletPtr, outSize)) return null;
        final size = outSize.value;
        if (size == 0) return null;

        // Then write
        final outBytes = calloc<Uint8>(size);
        try {
          if (!lib.wallet_write(walletPtr, outBytes)) return null;
          return Uint8List.fromList(outBytes.asTypedList(size));
        } finally {
          calloc.free(outBytes);
        }
      } finally {
        calloc.free(outSize);
      }
    });
  }
}
