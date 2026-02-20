# cloak_api

Flutter FFI bindings for the ZEOS/CLOAK privacy protocol.

This package wraps `libzeos_caterpillar.so` to provide privacy-preserving wallet functionality on EOSIO/AntelopeIO blockchains.

## Features

- Create and manage CLOAK wallets
- Derive shielded addresses
- Query balances (multi-asset support)
- Transaction history
- Block synchronization

## Usage

```dart
import 'package:cloak_api/cloak_api.dart';

// Create wallet from seed
final wallet = CloakApi.createWallet(
  'your seed phrase here',
  chainId: TELOS_CHAIN_ID,
  protocolContract: ZEOS_PROTOCOL_CONTRACT,
  vaultContract: ZEOS_VAULT_CONTRACT,
  aliasAuthority: 'youraccount@active',
);

// Derive address
final address = CloakApi.deriveAddress(wallet!, 0);
print('Address: $address');

// Get balances
final balances = CloakApi.getBalancesJson(wallet);
print('Balances: $balances');

// Close wallet when done
CloakApi.closeWallet(wallet);
```

## Platform Support

- Linux: libzeos_caterpillar.so
- macOS: libzeos_caterpillar.dylib
- Windows: zeos_caterpillar.dll
- Android: libzeos_caterpillar.so
- iOS: Bundled in executable

## Building libzeos_caterpillar

```bash
cd zeos-caterpillar
cargo build --release
# Output: target/release/libzeos_caterpillar.so
```
