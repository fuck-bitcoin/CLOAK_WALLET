<div align="center">

# CLOAK Wallet

**Your money. Your privacy. No compromises.**

Private transactions on the [Telos](https://telos.net) blockchain using zero-knowledge proofs.

[![Release](https://img.shields.io/github/v/release/fuck-bitcoin/CLOAK_WALLET?color=black&label=Latest)](https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-black.svg)](LICENSE.md)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows%20%7C%20Android-333333.svg)](#install-in-one-command)
[![Build](https://img.shields.io/github/actions/workflow/status/fuck-bitcoin/CLOAK_WALLET/build-linux.yml?label=Build&color=333333)](https://github.com/fuck-bitcoin/CLOAK_WALLET/actions)

**[Web App](https://app.cloak.today)** · **[Telegram](https://t.me/ZeosOfficial)**

---

### Install in One Command

</div>

| Platform | Install Command |
|:---------|:----------------|
| **Linux** | `curl -sSL https://raw.githubusercontent.com/fuck-bitcoin/CLOAK_WALLET/main/install.sh \| bash` |
| **macOS** | `curl -sSL https://raw.githubusercontent.com/fuck-bitcoin/CLOAK_WALLET/main/install-macos.sh \| bash` |
| **Windows** | `irm https://raw.githubusercontent.com/fuck-bitcoin/CLOAK_WALLET/main/install.ps1 \| iex` |
| **Android** | [Download APK](https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/latest/download/CLOAK_Wallet.apk) |

Or download directly from [Releases](https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/latest).

> On first launch, CLOAK Wallet downloads zero-knowledge proving parameters (~383 MB). This is a one-time download.

---

## Features

### Private Transactions

Your balance and transaction history are hidden from everyone. Not even the blockchain can see what you own. Send and receive CLOAK tokens with complete privacy.

### Vault System

A secure holding area for your tokens. Deposit publicly, withdraw privately. Like a safety deposit box that makes your money invisible. Deterministic vault derivation means your vaults are automatically recovered from your seed phrase.

### Zero-Knowledge Proofs

Mathematical proofs that let you prove you own something without revealing what it is or how much you have. All proofs are generated locally on your device -- nothing leaves your machine.

### Encrypted Storage

Your wallet database is encrypted with SQLCipher, protected by a 6-digit PIN. Even if someone gets your device, they can't read your wallet data without the PIN.

### View-Only Wallets

Import a Full Viewing Key (FVK) or Incoming Viewing Key (IVK) to monitor balances and transaction history without spending capability. Track your funds from a secondary device.

### Self-Custody

Your keys, your coins. No company, no server, no middleman can touch your funds. A 24-word seed phrase is your entire identity.

### Web App Authentication

Sign in to [app.cloak.today](https://app.cloak.today) directly from your desktop wallet. The wallet runs a local signature provider -- no passwords, no browser extensions. Your keys never leave your device.

### Cross-Platform

Runs on Linux, macOS (Apple Silicon and Intel), Windows, and Android.

### Open Source

Every line of code is public. Trust through transparency.

---

## How It Works

CLOAK Wallet uses **zk-SNARKs** (Groth16 on BLS12-381) to create shielded transactions on the Telos blockchain. When you send CLOAK tokens:

1. Your wallet generates a zero-knowledge proof that you have enough funds -- without revealing your balance
2. The proof is verified on-chain by the ZEOS protocol smart contract
3. The recipient gets the tokens, but the amount, sender, and recipient are all hidden from public view

Your wallet stores encrypted notes locally. Only your private key can decrypt them. The blockchain only sees cryptographic commitments -- not amounts, not addresses, not balances.

**Vaults** add another layer: deposit tokens publicly into a vault, then withdraw them privately later. The link between deposit and withdrawal is cryptographically severed.

---

## Build from Source

### Prerequisites

- [Rust](https://rustup.rs) (stable, MSRV 1.80)
- [Flutter 3.22.2](https://flutter.dev) (exact version required)
- Platform-specific dependencies listed below

### Linux (Ubuntu/Debian)

```bash
# Clone the repository
git clone https://github.com/fuck-bitcoin/CLOAK_WALLET.git
cd CLOAK_WALLET

# Install system dependencies
sudo apt-get install -y clang cmake ninja-build libgtk-3-dev \
    libssl-dev libsecret-1-dev libjsoncpp-dev libunwind-dev \
    libudev-dev pkg-config

# Build Rust native library
cd zeos-caterpillar && cargo build --release && cd ..

# Copy .so to Flutter bundle location
cp zeos-caterpillar/target/release/libzeos_caterpillar.so linux/lib/

# Build Flutter app
flutter pub get && dart run build_runner build -d
(cd packages/cloak_api_ffi && flutter pub get)
flutter build linux --release
```

The built application is at `build/linux/x64/release/bundle/`.

### macOS

```bash
git clone https://github.com/fuck-bitcoin/CLOAK_WALLET.git
cd CLOAK_WALLET

cd zeos-caterpillar && cargo build --release && cd ..
flutter pub get && dart run build_runner build -d
(cd packages/cloak_api_ffi && flutter pub get)
flutter build macos --release
```

### Windows (PowerShell)

Requires Visual Studio Build Tools with C++ workload.

```powershell
git clone https://github.com/fuck-bitcoin/CLOAK_WALLET.git
cd CLOAK_WALLET

cd zeos-caterpillar; cargo build --release; cd ..
flutter pub get; dart run build_runner build -d
cd packages\cloak_api_ffi; flutter pub get; cd ..\..
flutter build windows --release
copy zeos-caterpillar\target\release\zeos_caterpillar.dll build\windows\x64\runner\Release\
```

### Android

Requires [cargo-ndk](https://github.com/aspect-build/cargo-ndk) and Android NDK.

```bash
git clone https://github.com/fuck-bitcoin/CLOAK_WALLET.git
cd CLOAK_WALLET

# Build Rust for Android targets
cd zeos-caterpillar
cargo ndk -t arm64-v8a -t armeabi-v7a -o ../android/app/src/main/jniLibs build --release
cd ..

# Build APK
flutter pub get && dart run build_runner build -d
(cd packages/cloak_api_ffi && flutter pub get)
flutter build apk --release
```

---

## Security

CLOAK Wallet uses:

- **Groth16 BLS12-381** zero-knowledge proofs for transaction privacy
- **SQLCipher** for PIN-encrypted local database storage
- **BIP-39** 24-word seed phrases for wallet generation
- **HMAC-SHA256** for deterministic vault derivation
- **Sapling** note encryption for shielded outputs

Your private keys never leave your device. All zero-knowledge proofs are generated locally. No servers, no telemetry, no tracking.

### Verifying Downloads

Each release includes SHA256 checksums. Verify your download:

```bash
sha256sum -c SHA256SUMS-linux
```

---

## Architecture

```
┌──────────────────────────────────────────────┐
│  Flutter UI (Dart)                           │
│  PIN • Accounts • Vaults • TX History • NFTs │
├──────────────────────────────────────────────┤
│  Dart FFI Bridge                             │
│  CloakWalletManager • CloakSync • CloakDb   │
├──────────────────────────────────────────────┤
│  Rust Native Library (zeos-caterpillar)      │
│  Wallet • ZK Proofs • Merkle Tree • Signing  │
├──────────────────────────────────────────────┤
│  Telos Blockchain                            │
│  zeosprotocol • thezeostoken • thezeosvault  │
└──────────────────────────────────────────────┘
```

- **Flutter** handles the UI, encrypted local storage (SQLCipher), and platform integration
- **Rust** handles all cryptography: key derivation, proof generation, transaction building, and note encryption
- **Telos** provides the on-chain smart contracts that verify proofs and manage shielded state

---

## License

[MIT](LICENSE.md) -- CLOAK Wallet Contributors
