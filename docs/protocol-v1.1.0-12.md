# CLOAK Protocol Generation `v1.1.0-12`

This document records the compatibility basis and migration rules for the
depth-12 CLOAK protocol recovery. It is an operational provenance record, not
a substitute for a trusted-setup ceremony transcript.

## Compatibility basis

The wallet targets the live Telos `zeosprotocol` deployment whose
`global.tree_depth` is `12`. The native proving code is ported from the four
circuits and their 37 soundness tests in
[`zeos-caterpillar` tag `v1.1.0-12`](https://github.com/mschoenebeck/zeos-caterpillar/tree/v1.1.0-12)
(commit `c5636dd1bed4ec904c722e91d66e4e9e5d748a31`). CLOAK-specific Flutter FFI,
Android integration, viewing-key behavior, reset handling, and transaction
logic remain CLOAK code rather than wholesale upstream replacements.

The production proving-parameter bytes were recovered from the deployed
[`cloak-gui-v1.26.06.2-windows.zip`](https://downloads.cloak.today/cloak-gui-v1.26.06.2-windows.zip)
wallet bundle. Each file parses as a Groth16 parameter set. The SHA-256 hashes
of its derived verifying keys match the four verifying keys configured by the
live Telos verifier.

| File | Bytes | Parameter SHA-256 | Derived verifying-key SHA-256 |
|---|---:|---|---|
| `mint.params` | 15,600,764 | `502c145d1329e83a72f52b0a3091237b54b238178d05d9e3e484c909a597107a` | `64d3fd942cc195a3a274c07c4059dffb7b1cdccae04cdc09b9ee9e79bf3ac40e` |
| `spend-output.params` | 116,049,020 | `e187e4e0690fc1c053f171b14d9353405d554c07b2a6777d2fe93a4c4c4a50e2` | `90a69e8bf2a40df9e29b79de51749623cc5fc70c2ec3dd96953c9d8130273c38` |
| `spend.params` | 114,333,500 | `0b37b4873684e3fefb459eabd59d1da2a8be2ffadf261401eaa4d843a280b33c` | `af9dafc133cf2453904e04ae1b17bce885e2476eed5cf458cff61005c5369540` |
| `output.params` | 3,070,652 | `7c6b056ed748e842739b2148496d6dbfc387463f98c3b4bddb08c1be60a9aa6b` | `2963b173d0fa297441500ef075654063feff8979d5bc5464313c9eae70484e52` |

The complete generation is 249,053,936 bytes, approximately 37.8% smaller
than the known depth-20 set. It must be published as the immutable CLOAK
release `params-v1.1.0-12` before production rollout.

## Provenance limitation

The original ceremony transcript, participant attestations, and contribution
artifacts for these parameter bytes are not currently available. Therefore,
this record establishes deployment compatibility and byte identity only. It
does **not** independently prove that every setup contribution was generated,
handled, or destroyed correctly.

The files are operationally authoritative for recovery because all four
derived verifying keys match the verifier that the live protocol actually
uses. The missing ceremony record must stay disclosed in release notes and
security documentation until independently verifiable ceremony evidence is
published. A future ceremony or verifier rotation is a new protocol generation
and must not silently replace this one.

## Parameter-set integrity

The generation identifier is `v1.1.0-12`, and all four files are one atomic
set. Release tooling must sign the exact UTF-8 bytes of the parameter manifest
with the long-lived CLOAK release-manifest Ed25519 key. The manifest records:

- schema version, generation, and Merkle depth;
- source bundle;
- each exact filename, byte length, and parameter SHA-256; and
- each derived verifying-key SHA-256.

The wallet also pins the expected values above in code. A valid manifest cannot
authorize different bytes, and matching bytes cannot bypass manifest-signature
verification in the release path.

Each generation has its own directory. Downloads use a `.part` file and are
size- and SHA-256-verified before atomic promotion. A generation marker is
written only after all four files pass verification. Missing files, duplicate
entries, stale generations, mixed generations, unexpected names, corrupt
files, or mismatched verifying-key hashes must be rejected.

Known depth-20 files remain untouched until wallet migration completes. After
completion, cleanup may remove only legacy files whose size and SHA-256 both
match the explicit legacy allow-list. Unknown files are never deleted as part
of migration.

| Known legacy file | Bytes | Legacy SHA-256 |
|---|---:|---|
| `mint.params` | 15,649,884 | `871e81e4f389dd726ce68a8bbdb6cbad211642a5ba4d1d83f49a50be72ec6f9f` |
| `spend-output.params` | 191,716,284 | `17d15a5500ca0a29f7575b28b9ae2f328420374833940fd7c4c7cb2a7ee62d05` |
| `spend.params` | 189,939,708 | `c653ed65e40bbab3e5b78bed09f9e02fd1746bfd5a5192d9e5d5308baca3adc8` |
| `output.params` | 3,089,244 | `73d485439dd35fd3abc1d53af12ad5414a63652fd2018c6ae32bb1dbd6925dcd` |

## Depth guard

Before sync or proof generation, the wallet compares:

1. the Merkle depth compiled into the native library;
2. the parameter generation's declared depth; and
3. `zeosprotocol::global.tree_depth` from the selected deployment.

All three values must equal `12`. Any mismatch blocks sync, signing, and proof
generation with a “wallet update required” state. The wallet must not infer a
new depth from the network and continue with circuits built for another depth.

## Wallet migration state

The wallet serialization extension is backward-compatible. Files without the
extension map to `legacy`; the supported states are:

| State | Meaning | Permitted activity |
|---|---|---|
| `legacy` | Wallet predates the depth-12 migration. | Backup and migration only; no sync or signing. |
| `migrating-v1.1.0-12` | Chain-derived state was reset and a full resync is pending or running. | Full resync only; no proof generation or spend signing. |
| `v1.1.0-12` | Migration and persistence completed successfully. | Normal activity, subject to the depth and parameter checks. |

For a `legacy` wallet, migration follows this order:

1. Stop signing and synchronization, and acquire the wallet-state lock.
2. Create a recoverable, non-overwriting backup of the wallet before mutation.
3. Reset chain-derived wallet state while preserving seed/key material,
   diversifiers, unpublished notes, vault metadata, and burn history.
4. Set `migrating-v1.1.0-12` and durably persist the wallet and reset sync
   metadata before starting network work.
5. Perform a full resync against a depth-12 deployment.
6. After the resync and wallet save both succeed, set `v1.1.0-12` and persist
   that completion atomically.

If the application exits or fails while migration is in progress, the next
launch resumes the resync from `migrating-v1.1.0-12`. It must not reset the
wallet again or overwrite the original recovery backup. A failed resync leaves
the migration state pending and keeps transaction creation blocked.

New wallets are created directly as `v1.1.0-12`. A wallet from an unknown
future generation is not downgraded; it is rejected with an update-required
message.

## Release verification gates

The generation is not production-ready until automation and reviewers have:

- run all 37 upstream circuit soundness tests and locked expected constraint
  counts/hashes;
- parsed all four exact production files and re-derived every verifying-key
  hash in the table;
- created and locally verified representative proofs with the production
  files;
- exercised depth-20 migration, recovery backup, interrupted/resumed resync,
  idempotent restart, new-wallet, and future-depth fixtures; and
- completed the network gates in the v2.1 release runbook.

The deterministic production circuit identities are:

| Circuit | Constraints | Test constraint-system hash |
|---|---:|---|
| Mint | 32,410 | `ec0c2f7f8c0deb8ffc75ba89a8f9a5bd8d811774f8e11fc95baa93af3f56975c` |
| Output | 6,598 | `5e9206a01732651c033c95b8d68eb1dc51167722372354ff70e3d35fa4f73a92` |
| Spend | 227,170 | `51e80a7a5d3cd29de9a1f716059888305e3b5e6f6a7fa23485ff2b25289ad651` |
| SpendOutput | 232,225 | `9696908251ca22f58e94fb4de3b8a8107d06bef2b1bc85e407ea99d8405c233d` |

Spend and SpendOutput identity fixtures must contain exactly
`MERKLE_TREE_DEPTH` authentication-path levels. The former three-level
developer fixtures produced smaller, non-production identities. Any count or
locked circuit-hash change requires cryptographic review; it is not accepted
as routine test drift.
