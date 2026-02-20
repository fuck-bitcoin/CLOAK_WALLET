// Simple test to verify CLOAK API FFI bindings work
// Run with: flutter test test/cloak_api_test.dart

import 'dart:ffi';
import 'dart:io';
import 'package:cloak_api/cloak_api.dart';

void main() {
  print('=== CLOAK API FFI Test ===\n');

  // Test 1: Library loads
  print('Test 1: Loading libzeos_caterpillar.so...');
  try {
    final lib = CloakApi.open();
    print('  SUCCESS: Library loaded\n');
  } catch (e) {
    print('  FAILED: $e\n');
    exit(1);
  }

  // Test 2: Create wallet from seed
  print('Test 2: Creating wallet from test seed...');
  final testSeed = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  
  final wallet = CloakApi.createWallet(
    testSeed,
    aliasAuthority: 'testaccount@active',
  );
  
  if (wallet == null) {
    print('  FAILED: wallet_create returned null\n');
    exit(1);
  }
  print('  SUCCESS: Wallet created at ${wallet.address}\n');

  // Test 3: Get wallet size
  print('Test 3: Getting wallet size...');
  final size = CloakApi.getWalletSize(wallet);
  if (size == null || size == 0) {
    print('  FAILED: wallet_size returned null or 0\n');
  } else {
    print('  SUCCESS: Wallet size = $size bytes\n');
  }

  // Test 4: Derive address
  print('Test 4: Deriving shielded address...');
  final address = CloakApi.deriveAddress(wallet);
  if (address == null) {
    print('  FAILED: wallet_derive_address returned null\n');
  } else {
    print('  SUCCESS: Address = $address\n');
    if (address.startsWith('za1')) {
      print('  Address format correct (starts with za1)\n');
    }
  }

  // Test 5: Get chain ID
  print('Test 5: Getting chain ID...');
  final chainId = CloakApi.getChainId(wallet);
  if (chainId == null) {
    print('  FAILED: wallet_chain_id returned null\n');
  } else {
    print('  SUCCESS: Chain ID = $chainId\n');
  }

  // Test 6: Get protocol contract
  print('Test 6: Getting protocol contract...');
  final contract = CloakApi.getProtocolContract(wallet);
  if (contract == null) {
    print('  FAILED: wallet_protocol_contract returned null\n');
  } else {
    print('  SUCCESS: Protocol contract = $contract\n');
  }

  // Test 7: Get balances JSON
  print('Test 7: Getting balances JSON...');
  final balances = CloakApi.getBalancesJson(wallet, pretty: true);
  if (balances == null) {
    print('  FAILED: wallet_balances_json returned null\n');
  } else {
    print('  SUCCESS: Balances JSON =\n$balances\n');
  }

  // Test 8: Serialize wallet
  print('Test 8: Serializing wallet...');
  final bytes = CloakApi.writeWallet(wallet);
  if (bytes == null) {
    print('  FAILED: wallet_write returned null\n');
  } else {
    print('  SUCCESS: Serialized to ${bytes.length} bytes\n');
  }

  // Test 9: Deserialize wallet
  if (bytes != null) {
    print('Test 9: Deserializing wallet...');
    final wallet2 = CloakApi.readWallet(bytes);
    if (wallet2 == null) {
      print('  FAILED: wallet_read returned null\n');
    } else {
      print('  SUCCESS: Wallet restored from bytes\n');
      
      // Verify address can still be derived
      final address2 = CloakApi.deriveAddress(wallet2);
      if (address == address2) {
        print('  Address matches after round-trip!\n');
      } else {
        print('  WARNING: Address mismatch after round-trip\n');
      }
      
      CloakApi.closeWallet(wallet2);
    }
  }

  // Cleanup
  print('Test 10: Closing wallet...');
  CloakApi.closeWallet(wallet);
  print('  SUCCESS: Wallet closed\n');

  print('=== All tests completed ===');
}
