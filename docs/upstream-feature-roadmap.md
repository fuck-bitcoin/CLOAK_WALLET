# Upstream Feature Roadmap

## Current assessment

The upstream [`zeos-wallet`](https://github.com/mschoenebeck/zeos-wallet) work
assessed for this plan (commit `1432b490ae107f27832ca85a58d5c43ac731ba47`) is
best described as
**multi-CLOAK-wallet and multi-deployment**, not as a completed multi-coin
wallet. It contains useful patterns for selecting wallets and deployments, but
it does not provide production-ready Monero, Zcash, or generic native Antelope
wallet backends.

No upstream architecture expansion belongs in the v2.1 protocol-recovery
release. That release stays focused on depth-12 compatibility, safe wallet
migration, balance/send correctness, and self-managed updates.

## Ranked porting plan

### 1. Network/profile catalog and atomic versioned configuration

Introduce explicit profiles for protocol contract, token/vault contracts, RPC
and WebSocket endpoints, chain identity, parameter generation, and supported
features. Validate a complete versioned configuration before swapping it into
use, and retain the last-known-good profile for rollback.

This is first because every later network or wallet feature depends on a clear,
auditable deployment boundary.

### 2. Dynamic token metadata and icon service

Move token display metadata away from hard-coded symbols. Key metadata by chain
identity, contract, and token identifier; validate and cache icons separately
from balances; and provide deterministic fallbacks for missing or untrusted
metadata.

The service must never collapse assets solely because symbols match, and token
metadata must not become authority for signing or amount precision.

### 3. Remembered wallet selector with one live wallet

Port the wallet-selection experience while keeping only one native wallet and
one sync session open at a time. Remember the last selection without storing
seed material in preferences, and complete save/close/lock operations before
opening another wallet.

This captures most of the usability benefit with a much smaller concurrency
and transaction-routing risk.

### 4. Full multi-chain CLOAK profiles

Extend the profile model to multiple supported CLOAK deployments with explicit
chain IDs, contracts, endpoints, parameter generations, and feature flags.
Wallet and cache namespaces must include the profile identity so that state can
never cross chains accidentally.

This remains CLOAK protocol functionality; it is not a claim of independent
support for other cryptocurrencies.

### 5. Simultaneous wallet sessions and WalletConnect routing

Only after single-live-wallet switching is stable, consider multiple open
wallets. Every incoming request must bind to an explicit chain/profile and
wallet identity, show that route during approval, and serialize conflicting
proof/sign operations. Background sync, shutdown, and failure recovery require
per-session ownership rather than global mutable state.

### 6. Independent Monero, Zcash, and native Antelope backends

Treat these as separate wallet products inside a shared shell, each with its
own key model, synchronization engine, transaction lifecycle, fee policy,
security review, and test matrix. UI placeholders or roadmap code are not
backend support. These integrations should begin only after a dedicated scope,
maintainer, and security plan exist for each chain.

## Explicitly roadmap-only

For this codebase, Monero, Zcash, generic native Antelope transfers, hardware
wallets, credential storage, simultaneous wallet sessions, and WalletConnect
routing remain roadmap items. Their appearance in upstream code, comments, or
screens does not make them supported CLOAK features.

## Porting audit requirement

Before copying any additional upstream code or architecture, record and review:

- the source commit and every applicable license, notice, and attribution;
- transitive dependency licenses and platform-distribution restrictions;
- network endpoints, service accounts, API keys, OAuth client data, analytics
  identifiers, certificates, keystores, and signing configuration;
- assumptions about wallet file formats, key custody, selected chain, and
  globally shared state; and
- tests demonstrating that CLOAK-specific viewing keys, Android behavior,
  resets, transaction construction, and protocol migration remain intact.

Credentials and signing keys from upstream must never be copied. Unknown or
embedded credentials block the port until they are removed or replaced with
CLOAK-controlled configuration. A feature advances from this roadmap only
through its own reviewed design and release gate.
