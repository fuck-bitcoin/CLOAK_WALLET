# Changelog

## [2.0.0] - 2026-02-24

### Overview

CLOAK Wallet v2.0.0 -- the first public release of a privacy-focused shielded
wallet for Telos. Forked from YWallet and entirely rebranded and rearchitected
for the CLOAK/ZEOS protocol.

### Features

- Shielded send/receive with zk-SNARK proofs on Telos mainnet
- Deterministic vault creation and discovery (HMAC-SHA256 derived)
- Full Viewing Key (FVK) wallet support (view-only mode)
- In-app ZK parameter download with resume support and SHA256 verification
- ESR (EOSIO Signing Request) deep-link integration with Anchor Wallet
- WebSocket bridge for app.cloak.today (balance queries, transaction signing)
- Vault management: create, deposit, withdraw, burn
- Transaction history with fee breakdown (Send Fee, Burn Vault labels)
- Multi-language support (English, Spanish, French, Portuguese)
- AppImage packaging for Linux with XWayland support

### Security

- SHA256 checksum verification on all ZK parameter downloads
- SQLCipher encrypted local database
- No private keys transmitted over network
- View-only wallets reject all signing requests

### Platform

- Linux x86_64 (primary target, AppImage)
- macOS, Windows, Android, iOS (build targets present, not yet released)

---

*CLOAK Wallet is built on the ZEOS protocol. Originally forked from
[YWallet](https://github.com/hhanh00/zwallet) by hhanh00.*
