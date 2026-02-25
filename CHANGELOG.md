# Changelog

All notable changes to CLOAK Wallet will be documented in this file.

## [1.0.0] - 2026-02-25

### Overview

CLOAK Wallet v1.0.0 -- the first public release of a privacy-focused shielded
wallet for Telos. Built on the ZEOS protocol with full zero-knowledge proof
support for private transactions.

### Features

- **Shielded Transactions**: Send/receive with zk-SNARK proofs on Telos mainnet
- **Deterministic Vaults**: HMAC-SHA256 derived vault creation and discovery
- **Full Viewing Key Support**: View-only wallet mode with FVK import
- **ZK Parameters**: In-app download with resume support and SHA256 verification
- **ESR Integration**: Deep-link signing with Anchor Wallet
- **Web Authentication**: WebSocket bridge for app.cloak.today
- **Transaction History**: Detailed history with fee breakdown
- **Multi-language**: English, Spanish, French, Portuguese

### Web Authentication

- mkcert SSL certificate generation for trusted localhost connections
- Automatic mkcert installation in platform installers
- Browser-specific setup documentation for Brave, Chrome, Firefox, Safari, Edge
- Android deep link authentication support (`cloak://auth`)

### Security

- SHA256 checksum verification on all downloads
- SQLCipher encrypted local database
- No private keys transmitted over network
- View-only wallets reject signing requests

### Platforms

- Linux x86_64 (AppImage)
- macOS arm64 (DMG, runs on Intel via Rosetta 2)
- Windows x86_64 (MSIX)
- Android (APK)

### One-Line Installers

All platforms include one-line install commands that download everything needed:
- Application binary
- ZK proving parameters (~380 MB)
- mkcert for SSL certificates

---

*CLOAK Wallet is built on the ZEOS protocol. Originally forked from
[YWallet](https://github.com/hhanh00/zwallet) by hhanh00.*
