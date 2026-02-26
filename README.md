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

<div align="center">

### Update

</div>

Already installed? Run the same one-liner to update to the latest version. Your wallet data, ZK parameters, and settings are preserved.

| Platform | Update Command |
|:---------|:---------------|
| **Linux** | `curl -sSL https://raw.githubusercontent.com/fuck-bitcoin/CLOAK_WALLET/main/install.sh \| bash` |
| **macOS** | `curl -sSL https://raw.githubusercontent.com/fuck-bitcoin/CLOAK_WALLET/main/install-macos.sh \| bash` |
| **Windows** | `irm https://raw.githubusercontent.com/fuck-bitcoin/CLOAK_WALLET/main/install.ps1 \| iex` |
| **Android** | [Download latest APK](https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/latest/download/CLOAK_Wallet.apk) and install over the existing app |

> **Android users:** Download the latest APK from the [releases page](https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/latest) and sideload it over your existing install. If the install fails due to a signing key change, back up your seed phrase first, uninstall the old version, install the new APK, and restore from seed.

**What gets preserved on update:**
- Wallet data (accounts, transaction history, vault state)
- ZK proving parameters (~383 MB) — no re-download required
- SSL certificates (mkcert)
- Desktop shortcuts

<div align="center">

### Uninstall in One Command

</div>

| Platform | Uninstall Command |
|:---------|:------------------|
| **Linux** | `~/.local/bin/mkcert -uninstall 2>/dev/null; rm -rf ~/.local/share/cloak-wallet ~/.local/bin/cloak-wallet ~/.local/share/applications/app.cloak.wallet.desktop ~/.local/share/mkcert ~/.local/bin/mkcert` |
| **macOS** | `~/.local/bin/mkcert -uninstall 2>/dev/null; rm -rf "/Applications/CLOAK Wallet.app" ~/Library/Containers/app.cloak.wallet ~/Library/Application\ Support/cloak-wallet ~/Library/Application\ Support/mkcert ~/.local/bin/mkcert` |
| **Windows** | `& "$env:LOCALAPPDATA\mkcert\mkcert.exe" -uninstall 2>$null; Remove-Item -Recurse -Force "$env:LOCALAPPDATA\cloak-wallet","$env:LOCALAPPDATA\databases","$env:LOCALAPPDATA\mkcert" -ErrorAction SilentlyContinue; Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\CLOAK Wallet.lnk","$env:USERPROFILE\Desktop\CLOAK Wallet.lnk" -ErrorAction SilentlyContinue` |
| **Android** | Uninstall from Settings → Apps → CLOAK Wallet |

> **Note:** Uninstalling removes the app, wallet data, and SSL certificates. **Back up your seed phrase before uninstalling.**

---

## Why This Wallet Rocks

### Lightning-Fast Table Sync

Unlike traditional block-by-block synchronization that can take hours, CLOAK Wallet uses **table-focused sync** — directly querying ZEOS protocol smart contract tables on the Telos blockchain. Your wallet syncs in seconds, not minutes. The sync fetches merkle tree data, nullifier sets, and note commitments directly from contract state, then decrypts only the notes that belong to you.

### Create & Restore Accounts

Generate a fresh wallet with a cryptographically secure 24-word seed phrase, or restore an existing wallet from your seed. Your entire identity fits in your memory — no accounts, no emails, no phone numbers.

### Deterministic Vault Derivation

Vaults are derived directly from your wallet seed using HMAC-SHA256. This means when you restore your wallet, **all vaults created with this wallet are automatically recovered**. No need to remember vault keys or export backup files.

### Easy Key & Token Management

Export and import Full Viewing Keys (FVK) or Incoming Viewing Keys (IVK) to monitor balances without spending capability. View your vault authentication tokens and manage multiple vaults from a single seed.

### View-Only Wallets

Import a viewing key to track your funds from a secondary device. See your full transaction history and balance without the ability to spend. Perfect for monitoring cold storage or shared family accounts.

### Rotating Addresses for Maximum Privacy

Every time you open the Receive screen, a fresh diversified address is generated. This prevents address reuse — a common privacy leak where observers can link multiple payments to the same recipient. All rotating addresses derive from your single seed phrase, so funds sent to any of them appear in the same wallet balance. Use a new address for every transaction without any extra effort.

### Multi-Asset Support

Send, receive, and manage multiple token types beyond just CLOAK. The wallet parses extended asset formats and displays token symbols, contracts, and precision correctly. Your transaction history shows all assets with proper formatting.

### NFT Functionality

View, send, and receive AtomicAssets NFTs through the shielded pool. NFT metadata is fetched from the AtomicAssets API with collection names, images, and attributes displayed in a clean gallery view with lightbox zoom.

### Clean & Intuitive UI

A modern dark theme with smooth animations and slide transitions. Transaction details show clear status badges, copyable fields, and direct links to the Telos block explorer. The send flow is streamlined with amount entry, address validation, and confirmation screens.

### Web App Authentication

Sign in to [app.cloak.today](https://app.cloak.today) directly from your desktop wallet. The wallet runs a local signature provider that handles ESR (EOSIO Signing Request) links — no passwords, no browser extensions. Your keys never leave your device.

#### Browser Setup

The wallet runs a secure WebSocket server on `localhost:9367`. Some browsers require extra configuration to allow localhost connections from external websites.

<details>
<summary><strong>Brave Browser</strong></summary>

1. Open `brave://flags` in the address bar
2. Search for "localhost"
3. Enable **"Enable Localhost Access Permission Prompt"**
4. Restart Brave
5. When you visit app.cloak.today and click authenticate, Brave will prompt you to allow localhost access — click **Allow**

Alternatively, visit `https://127.0.0.1:9367/` directly and click **Advanced** → **Proceed to 127.0.0.1** to trust the certificate.

</details>

<details>
<summary><strong>Google Chrome</strong></summary>

Chrome typically works out of the box if you've run `mkcert -install` (included in the wallet's first-run setup on Linux). If authentication fails:

1. Open `chrome://flags/#allow-insecure-localhost`
2. Enable **"Allow invalid certificates for resources loaded from localhost"**
3. Restart Chrome

Or visit `https://127.0.0.1:9367/` directly and click **Advanced** → **Proceed to 127.0.0.1**.

</details>

<details>
<summary><strong>Firefox</strong></summary>

Firefox uses its own certificate store, not the system keychain. You need to manually trust the certificate:

1. Open `https://127.0.0.1:9367/` in Firefox
2. Click **Advanced** → **Accept the Risk and Continue**
3. Firefox will remember this for future sessions
4. Return to app.cloak.today and authenticate

</details>

<details>
<summary><strong>Safari</strong></summary>

Safari uses the macOS system keychain. If you've run `mkcert -install`, authentication should work immediately with no extra configuration.

If it fails, open **Keychain Access**, find "mkcert" in the System keychain, and set it to "Always Trust".

</details>

<details>
<summary><strong>Edge</strong></summary>

Edge uses the same certificate store as Chrome/Windows. If authentication fails:

1. Open `edge://flags/#allow-insecure-localhost`
2. Enable **"Allow invalid certificates for resources loaded from localhost"**
3. Restart Edge

</details>

#### Android Authentication

On mobile, browsers can't connect to localhost WebSocket servers. Instead, Android authentication uses **deep links** — the wallet registers the `cloak://` URL scheme and handles authentication requests directly.

**How it works:**
1. Website generates a `cloak://auth?origin=app.cloak.today` link
2. Tapping the link opens CLOAK Wallet
3. Wallet shows an approval screen: "app.cloak.today wants to log in"
4. User taps Approve → wallet signs and broadcasts
5. Wallet redirects back to the browser with the result

**Status:** The wallet-side implementation is complete and ready. Authentication will work automatically once app.cloak.today enables deep link support for mobile users.

### Cross-Platform

Runs natively on Linux, macOS (Apple Silicon and Intel), Windows, and Android. Same codebase, same features, same privacy everywhere.

### Encrypted Local Storage

Your wallet database is encrypted with SQLCipher, protected by a 6-digit PIN. Even if someone gets physical access to your device, they can't read your wallet data without the PIN.

### Open Source

Every line of code is public. The Rust cryptography library, Flutter UI, and build scripts are all here. Trust through transparency.

---

## Understanding Vaults

Vaults solve a fundamental privacy problem: **how do you move assets from a public Telos account to your private CLOAK wallet without creating a traceable link?**

### The Problem

If you send CLOAK tokens directly from your public Telos account to your shielded address, anyone watching the blockchain can see: "Account X sent Y tokens to this shielded address." Your privacy is compromised before you even start.

### The Solution

Vaults act as a cryptographic intermediary:

1. **Deposit (Public)** — You deposit tokens into a vault from your public Telos account. The deposit is visible on-chain.

2. **Wait** — Time passes. Other people deposit and withdraw from the vault system. The link between deposits and withdrawals becomes statistically meaningless.

3. **Withdraw (Private)** — You generate a zero-knowledge proof that you have the right to withdraw from the vault, without revealing which deposit was yours. The tokens appear in your shielded wallet.

The vault system uses authentication tokens — special zero-value ZK commitments that act as "smart keys" proving your withdrawal rights without linking to your deposit.

### Vault Restoration

**Important:** Vaults can be restored from your seed phrase, but **only if the vault was created with this wallet**. We derive vault authentication tokens deterministically from your seed using HMAC-SHA256. The main CLOAK wallet by Matthias Schönebeck may use different derivation — vaults created there won't appear when you restore here.

---

## Technical Notes

### Vault Burn Fee Labeling

When you destroy a vault (burn it), the Telos blockchain doesn't have a native "Vault Burn Fee" action type. The fee is processed the same way as a "Vault Publish Fee" on-chain.

This wallet uses a **client-side timing mechanism** to correctly label burn fees:

1. When you press the burn button, the wallet records the exact timestamp locally in a `burn_events` table
2. When displaying transaction history, the wallet matches fee entries against these timestamps (within a 5-second tolerance)
3. Entries that match a burn timestamp are relabeled from "Publish Vault" to "Burn Vault"

**What this means:**

- If you restore your wallet from seed, all vault burn fees will appear as "Vault Publishing" fees (the raw on-chain label)
- New burns you perform after restoration will be correctly labeled
- This labeling persists until you delete your wallet data

This is a limitation of the ZEOS protocol, not this wallet — there's simply no on-chain distinction between publish and burn fee actions.

### Table-Based Sync Architecture

Traditional ZK wallets scan every block looking for notes encrypted to your key. On a fast chain like Telos, this is painfully slow.

CLOAK Wallet takes a different approach:

1. Query the `merkletree` table for the current Merkle root and commitment list
2. Query the `nf` (nullifier) table to identify spent notes
3. Query the `notes` table for encrypted note data
4. Decrypt locally using your viewing key
5. Reconstruct your balance and transaction history

This reduces sync time from minutes to seconds. The trade-off is reliance on Telos API nodes for table queries, but your keys and decryption always happen locally.

---

## Features in Development

The following features exist as incomplete modules in the codebase. They're not ready for deployment but could be implemented if resources become available:

### Contact Management

Save names to addresses. The contacts table exists in the database schema, and a contacts management page is partially built. Associates human-readable names with za1 addresses for easier sending.

### Encrypted Chat

Fully encrypted 1:1 messaging with:
- Message threads grouped by conversation
- Reply chains with quoted messages
- Emoji reactions (full emoji picker with categories)
- Read receipts and typing indicators
- Photo attachments with chunked encoding

The message parsing, thread building, and reaction aggregation code exists. The ZK-memo infrastructure is there. Real-time delivery comes naturally from Telos's ~0.5 second block times — messages are shielded transaction memos that confirm instantly. No WebSocket relay or external servers required. What's missing is polish and UI completion.

### Voice & Video Calling

WebRTC signaling infrastructure for peer-to-peer calls. SDP offers/answers are exchanged through shielded transaction memos on Telos — no STUN/TURN servers or centralized signaling required. Once the handshake completes, audio/video streams flow directly peer-to-peer. Privacy-preserving communication with zero reliance on external infrastructure.

### Payment Requests

Request assets from contacts (similar to Venmo/Cash App):
- Generate a request with amount and memo
- Send to a contact
- They see "X requested Y CLOAK from you"
- One-tap to send the requested amount

The request flow UI exists for generating QR codes with payment URIs. Thread-based requests are stubbed but not fully wired.

### Multi-Send

Send to multiple recipients in a single transaction. The batch asset selection UI exists for vault withdrawals. Extending this to regular shielded sends would allow splitting payments across many addresses efficiently.

### Rewind / Selective Sync

Resync transactions from a chosen block height instead of from genesis. The rewind confirmation dialog and localization strings exist. This would let users recover from corrupted state without a full resync, or selectively re-scan a time period where transactions might have been missed.

### Cold Wallet / Air-Gapped Signing

Turn an old phone into a dedicated cold storage device:
- Keep your spending keys on an offline device that never connects to the internet
- Generate unsigned transactions on your online wallet
- Transfer via QR code to the offline device for signing
- Broadcast the signed transaction from your online device

Your private keys stay air-gapped — immune to remote attacks, malware, and network-based exploits. Perfect for long-term savings or high-value holdings.

### Hardware Wallet Integration

Support for dedicated hardware signing devices:
- **Keystone** integration for QR-based air-gapped signing
- Hardware-backed key storage with secure element protection
- Transaction review and confirmation on the hardware device display
- Compatible with existing Keystone firmware and workflows

Hardware wallets provide the strongest security model: keys generated and stored in tamper-resistant hardware, never exposed to general-purpose operating systems.

---

## How It Works

CLOAK Wallet uses **zk-SNARKs** (Groth16 on BLS12-381) to create shielded transactions on the Telos blockchain. When you send CLOAK tokens:

1. Your wallet generates a zero-knowledge proof that you have enough funds — without revealing your balance
2. The proof is verified on-chain by the ZEOS protocol smart contract
3. The recipient gets the tokens, but the amount, sender, and recipient are all hidden from public view

Your wallet stores encrypted notes locally. Only your private key can decrypt them. The blockchain only sees cryptographic commitments — not amounts, not addresses, not balances.

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

## Credits

CLOAK Wallet is a fork of [Ywallet](https://github.com/hhanh00/ywallet) by **Hahn**. We extend our gratitude for the foundational work on privacy-preserving cryptocurrency wallets that made this project possible.

### Matthias Schönebeck & ZEOS Protocol

This wallet would not exist without the extraordinary work of [**Matthias Schönebeck**](https://github.com/mschoenebeck), creator of the [ZEOS Protocol](https://github.com/mschoenebeck/zeos-caterpillar) and the `zeos-caterpillar` cryptographic library that powers every shielded transaction in CLOAK.

Matthias accomplished something remarkable: he brought **true zero-knowledge privacy** to EOSIO and Antelope blockchains — ecosystems that had no native privacy features. His implementation of Groth16 zk-SNARKs on BLS12-381, the Merkle tree commitment scheme, the nullifier system, and the entire shielded protocol architecture represents years of deep cryptographic engineering.

Before ZEOS, privacy on Telos and other Antelope chains simply didn't exist. Matthias changed that. Every private transaction you make with CLOAK Wallet is a testament to his vision and technical brilliance.

But this work is about more than technology — it's about **preserving the liberty of the individual**. In a world of increasing financial surveillance, the ability to transact privately isn't a luxury; it's a fundamental right. Matthias gave a dying ecosystem a shot at new life, introducing dynamics that unlock possibilities never before available on these chains. EOSIO and Antelope networks offer the most powerful and expressive smart contract platform in the industry — unmatched flexibility, human-readable accounts, sophisticated permission systems, and the ability to build complex on-chain logic that other platforms can only dream of. What they lacked was the one feature that makes truly sovereign money possible: privacy. CLOAK fills that gap, allowing these high-performance chains to finally realize their full potential as platforms for financial freedom.

Thank you, Matthias, for giving us the tools to build a more private, more free future.

---

## License

[MIT](LICENSE.md) — CLOAK Wallet Contributors
