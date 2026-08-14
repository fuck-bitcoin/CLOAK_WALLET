# CLOAK Wallet v2.1 Release Runbook

This runbook uses `v2.1.0` as a manually installed trust bootstrap, followed by
`v2.1.1` as the end-to-end proof of the updater. It covers Linux, macOS,
Windows, and Android. **iOS is not a supported build, test, or release target.**

Publishing a tag, release, or production manifest and performing any mainnet
transaction are explicit operator actions. Passing CI alone does not authorize
them.

## Supported release matrix

| Platform | Required target | Distribution and update path | Trust model |
|---|---|---|---|
| Linux | x64 | AppImage; detached helper swaps the managed image under `~/.local/share/cloak-wallet` and retains the previous image. Unknown or non-writable layouts fall back to the verified installer. | CLOAK Ed25519 release manifest plus asset size/SHA-256. |
| macOS | universal (arm64 + x86_64) | Sparkle 2.9.5 archive/feed; install and update under `~/Applications` for password-free replacement. | Separate CLOAK Sparkle Ed25519 signature, signed feed, pre-extraction verification, and finalized bundle ad-hoc-signed leaf-to-root with `codesign -s -`. |
| Windows | x64 | ZIP; detached helper stages and validates, atomically swaps `%LOCALAPPDATA%\cloak-wallet\app`, retains `app.previous`, and requires startup acknowledgement. | CLOAK Ed25519 release manifest plus asset size/SHA-256; no self-signed root installation. |
| Android | Supported release ABIs | APK handed to Android's package installer; user confirmation is always required. | Permanent CLOAK Android JKS plus in-app APK size/SHA-256 verification. |

Desktop release authenticity is self-managed. The project does not require an
Apple Developer account, Apple notarization, a Microsoft code-signing
certificate, or installation of a self-signed Windows root. Initial macOS
Gatekeeper and Windows SmartScreen warnings remain possible and must be stated
plainly on the download page.

## Permanent keys

Provision three independent, long-lived keysets before the bootstrap release:

1. release-manifest Ed25519 key;
2. Sparkle Ed25519 key; and
3. Android JKS for application ID `app.cloak.wallet`.

Store CI copies only in a restricted GitHub release environment with required
reviewers. Store encrypted recovery copies outside GitHub and outside this
repository, with restore instructions tested by two authorized operators. Do
not print private material, passwords, keystore contents, or recovery locations
in CI logs. Remove and never trust the previously tracked macOS P12.

Record public-key fingerprints and Android certificate fingerprints in the
release evidence. A key change is a separately approved trust migration, not a
routine build edit.

## Common pre-release gates

- Start from a reviewed commit on the release branch with a clean worktree.
- Treat `pubspec.yaml` as version authority. Confirm the tag, Flutter version,
  Android version name/code, macOS version/build, Windows version, and About
  screen all match.
- Confirm the native compiled depth, parameter manifest depth, and selected
  Telos `zeosprotocol::global.tree_depth` are all `12`.
- Confirm the immutable `params-v1.1.0-12` release contains the four exact files
  and values recorded in
  [`protocol-v1.1.0-12.md`](protocol-v1.1.0-12.md).
- Re-run all circuit soundness tests, production-parameter parsing and
  verifying-key derivation, representative proof verification, wallet migration
  fixtures, zero-balance asset tests, send rollback/reconciliation tests, and
  updater security tests.
- Exercise malformed and incorrectly signed manifests, size/hash mismatch, ZIP
  traversal, interrupted downloads, active-operation deferral, startup health
  acknowledgement, rollback, and preservation of wallet data.
- Build and smoke-test every row in the release matrix. A single missing target
  blocks publication; the unified workflow must leave the release as a draft.
- Verify that installers and updaters do not modify wallet files, databases,
  proving parameters, local TLS certificates, preferences, or seeds.
- Verify ordinary sync may coexist with download, while proving, sending, or
  signing defers installation until the operation finishes and wallet/native
  state shuts down cleanly.

## Signed update contract

The release workflow generates `update-v1.json` deterministically and signs
its exact bytes with the release-manifest Ed25519 key. Clients verify the
signature before parsing JSON. The manifest includes:

- schema, SemVer, numeric build, tag, and source commit;
- minimum updater version and required parameter generation; and
- each asset's platform, architecture, filename, byte length, and SHA-256.

Reviewers independently download every draft asset, verify its hash and size
against the manifest, verify the manifest signature from a clean checkout, and
confirm the artifact embeds the expected commit/version. Reformatting or
re-serializing a signed manifest invalidates it.

On macOS, Dart passes the stable tag from that verified manifest to Sparkle.
The feed is then loaded only from the tag-specific immutable release URL, and
the proposed Sparkle display version must match the verified manifest version
before the relaunch handshake can run. Sparkle automatic scheduling is disabled
so it cannot independently follow a mutable `latest` feed.

## Phase 1: `v2.1.0` manual bootstrap

Set the canonical version to `2.1.0+2001000`. This release establishes the
public updater keys and must be installed manually; no older updater is trusted
to deliver it.

1. Complete all common gates and create an unpublished draft containing every
   required platform asset, checksums, signed update manifest, public-key
   fingerprints, release notes, and parameter provenance disclosure.
2. Install each artifact on a representative clean machine/device and on an
   existing-wallet fixture. On Android, also test the documented seed-backup,
   uninstall, reinstall, and restore flow required for installations signed by
   the former random certificate.
3. Confirm a legacy wallet creates a recovery backup once, resumes an
   interrupted depth-12 migration without repeating reset, and reaches normal
   operation only after a successful full resync and persistence.
4. Confirm the app checks stable releases no more than once per 24 hours by
   default, supports a manual Settings check, offers Update/Later/Skip, permits
   disabling automatic checks, and keeps offline/rate-limit failures quiet.
5. Complete the testnet and explicitly approved mainnet gates below.
6. Obtain release-owner approval, publish the immutable tag and assets, and
   publish installation instructions that explicitly identify `v2.1.0` as the
   one-time manual bootstrap.

After publication, do not replace artifacts under the same tag. A bad artifact
requires a new version and, where needed, removal of the affected asset from
distribution with a public incident note.

## Phase 2: `v2.1.1` updater proof

Make a minimal, visible, non-security-sensitive change so operators can prove
the installed build changed. Build `v2.1.1` with a higher monotonic build/code
on the same supported matrix and permanent keys.

1. Complete all common gates and keep `v2.1.1` as a draft.
2. From the published `v2.1.0` on every platform, discover `v2.1.1`, choose
   Later and Skip in separate fixtures, then clear/reset the test fixture as
   appropriate and choose Update.
3. Interrupt one download and verify it resumes or safely restarts. Corrupt an
   asset and manifest in isolated tests and verify installation is blocked.
4. Begin a proof/send/sign operation and verify installation waits. After the
   operation, verify wallet save, sync/WSS stop, native close, apply, and
   relaunch order.
5. Confirm Linux and Windows retain the prior executable, and force a failed
   startup acknowledgement to demonstrate automatic rollback. Confirm macOS
   Sparkle signature and pre-extraction checks. Confirm Android presents the
   system installer and cannot silently install.
6. After successful launch, verify wallet/database/parameter byte hashes or
   expected integrity records are unchanged, migration state remains complete,
   and the About screen reports `v2.1.1`.
7. Obtain release-owner approval and publish. Monitor update success/failure by
   platform without collecting seeds, addresses, balances, or transaction data.

Broad announcement waits until `v2.1.0` to `v2.1.1` succeeds on all four
platform rows.

## Network transaction gates

First complete a full testnet round trip with the release candidate: shield,
private spend with change, and unshield. Verify balances, note reuse protection,
transaction history, restart/resync behavior, and on-chain acceptance.

Mainnet testing requires a separate, explicit approval that identifies the
candidate commit, wallet, maximum amount, operator, and time window. After that
approval, use only a low-value amount and perform, in order:

1. Telos mainnet shield;
2. private spend that creates change; and
3. unshield.

Stop immediately on an unexpected balance, proof, contract, broadcast, sync,
or reconciliation result. Preserve logs without secrets and do not retry by
reusing potentially submitted notes. Record transaction IDs and reviewer
sign-off as release evidence. Without explicit mainnet approval, the release
remains a draft regardless of all other results.

## Rollback and incident handling

- Linux and Windows restore the retained previous executable if the new build
  misses its startup acknowledgement; wallet data is never rolled back by the
  executable helper.
- macOS uses Sparkle's validated update path; retain the previously published
  artifact for manual recovery. The baseline installer migrates an old writable
  `/Applications` copy to a named, non-overwriting backup under
  `~/Applications` only after the new build acknowledges healthy startup; it
  warns for a manual move rather than requesting `sudo` when permissions deny it.
- Android rollback means installing a separately versioned APK accepted by
  Android's package rules; never ask users to bypass signature validation.
- A parameter, signing-key, or manifest incident blocks both new downloads and
  release promotion. Preserve the immutable evidence, publish a clear advisory,
  and ship a new version or generation after review.

Every rollback procedure must preserve seeds, wallet files, databases,
parameters, local TLS certificates, preferences, and recovery backups.
