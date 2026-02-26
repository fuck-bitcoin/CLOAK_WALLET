# Changelog

All notable changes to CLOAK Wallet will be documented in this file.

## [1.0.3] - 2026-02-25

### Fixed

- **Failed sync permanently prevents retry**: When `syncFromTables()` failed
  (API down, network error, HTTP 500), the sync engine set
  `_syncedHeight = _latestHeight` and persisted it to the database. This told
  the wallet it was fully synced when it had fetched zero data. Subsequent sync
  ticks saw `_syncedHeight >= _latestHeight` and skipped all work — the wallet
  was permanently stuck until a new on-chain block changed the latest height.
  Now on failure, `_syncedHeight` is left untouched so the 3-second timer
  retries automatically. Added exponential backoff (capped at ~30 seconds) via
  `_consecutiveFailures` counter to avoid hammering a dead API.

---

## [1.0.2] - 2026-02-25

### Fixed

- **Incorrect balance after seed restore (all platforms)**: Wallet showed only
  10 CLOAK instead of 180+ after restoring from seed. The Hyperion action query
  in `_getZeosActionsHyperion()` had a hard `limit=1000` with no pagination
  loop. If the protocol had more than 1000 total on-chain actions (mint, spend,
  publishnotes, authenticate across ALL users), note ciphertexts beyond the
  1000th action were silently dropped. Without the ciphertext, `add_notes()`
  could never trial-decrypt those notes, so they were never added to
  `unspent_notes` and never counted in the balance. Merkle tree leaves and
  nullifiers were already correctly paginated — only the action/note fetch was
  broken. Added a pagination loop using the Hyperion `skip` parameter to fetch
  ALL matching actions, matching the existing pattern used by
  `getZeosMerkleTree()` and `getZeosNullifiers()`. Affects all platforms
  (Linux, Android, macOS, Windows) since this is shared Dart code.

---

## [1.0.1] - 2026-02-25

### Fixed

- **Linux installer breaks system desktop icons**: Installing CLOAK Wallet
  created `~/.local/share/icons/hicolor/256x256/apps/` for the app icon. This
  triggered auto-generation of a local `index.theme` that only listed
  `256x256/apps`, shadowing the system hicolor `index.theme` and hiding all
  GNOME/GTK app icons (they appeared as generic blue diamonds). The installer
  now removes any auto-generated local `index.theme` and stale icon cache after
  icon installation to prevent the override.

---

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
