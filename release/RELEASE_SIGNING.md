# Self-managed release signing

CLOAK releases use three permanent keysets and no Apple Developer ID,
notarization account, or Microsoft Authenticode identity:

1. A release-manifest Ed25519 key signs the exact bytes of app and parameter
   manifests.
2. A separate Sparkle Ed25519 key signs the macOS archive and appcast.
3. A stable Android keystore establishes the permanent `app.cloak.wallet`
   package identity.

The reviewed public identities are tracked at
`release/keys/release-manifest-public.base64`,
`release/keys/sparkle-public.base64`, and
`release/keys/android-cert-sha256.txt`. Release and parameter workflows reject
configured identities that differ from these files, so rotating a trust root
requires a reviewed source change. Private keys are stored only in the
restricted GitHub `release` environment and encrypted recovery archives.

Run the provisioning scripts only on an offline administration machine. Never
run them in CI and never commit `release-keys/`. Keep two encrypted offline
backups of every private key. Losing the Sparkle or Android private key requires
a manual reinstall; there is no Apple/Microsoft identity fallback.

- `scripts/provision-release-manifest-key.sh` creates the shared manifest key.
- `scripts/provision-sparkle-key.sh` creates Sparkle 2.9.5's compatible
  base64-encoded 32-byte Ed25519 seed without using or prompting for Keychain.
- `scripts/provision-android-keystore.sh` creates the permanent JKS.

## GitHub release environment

Create a `release` environment with the repository owner as a required
reviewer. Restrict deployment branches to protected `main` and stable release
tags. The keys are self-managed and non-interactive; the reviewer gate controls
when those permanent keys may be used and when a reviewed draft may be
published. Configure:

Repository/environment variables:

- `CLOAK_RELEASE_MANIFEST_PUBLIC_KEY`: contents of
  `release-manifest-public.base64`.
- `CLOAK_SPARKLE_PUBLIC_KEY`: contents of `sparkle-public.base64`.
- `CLOAK_ANDROID_KEY_ALIAS`: normally `cloak-release`.
- `CLOAK_ANDROID_CERT_SHA256`: the uppercase certificate digest reported by
  `apksigner verify --print-certs` for the permanent-key baseline APK.

Environment secrets:

- `CLOAK_RELEASE_MANIFEST_PRIVATE_KEY_B64`: base64 of the entire private PEM
  file, not the raw seed.
- `CLOAK_SPARKLE_PRIVATE_KEY`: contents of `sparkle-private.base64`.
- `CLOAK_ANDROID_KEYSTORE_B64`: base64 of the permanent keystore.
- `CLOAK_ANDROID_KEYSTORE_PASSWORD` and `CLOAK_ANDROID_KEY_PASSWORD`.

The tag/build phase reconstructs private material only in the runner's
temporary directory, verifies the corresponding public identity, and creates a
fully assembled draft. It never publishes. A separate owner-approved
`publish-draft` dispatch downloads that existing draft, repeats signature,
version, commit, size, hash, checksum, target, and Sparkle checks, and only then
promotes it. Pull-request checks have read-only repository permission and no
access to the release environment or its keys.

## Baseline migration

The manually installed v2.1.0 baseline is the one-time root-of-trust bootstrap:
the operator trusts the reviewed installer fetched over GitHub HTTPS from an
immutable, owner-approved release. Its platform checksum detects download or
staging corruption, but is not a pre-existing detached-signature trust anchor.
After that bootstrap, the wallet verifies every update manifest against the
committed release-manifest key before parsing it; platform installers also
verify the signed asset size and SHA-256.

- macOS: run `install-macos.sh`. It verifies the release checksum, stages the
  app atomically in `~/Applications`, retains the previous copy, and rolls back
  if the new build does not acknowledge healthy startup. Only after that
  acknowledgement, a writable legacy `/Applications/CLOAK Wallet.app` is moved
  to the non-overwriting `~/Applications/CLOAK Wallet.app.legacy-from-Applications`
  backup. Permission failures require a manual move and never invoke `sudo`.
  An unsigned first install can show Gatekeeper's unidentified-developer warning.
- Windows: run `install.ps1`. It now fails closed on checksum errors, stages
  beside the current app, health-checks the new build, and restores
  `app.previous` on failure. SmartScreen can show Unknown publisher.
- Android: existing ephemeral-CI-key builds cannot update in place. Verify the
  seed backup, uninstall once, install the stable-key baseline APK, and restore
  the wallet. Android requires an Unknown apps grant and user confirmation for
  subsequent sideloaded updates; silent rollback/downgrade is unavailable.

Routine app updates never reinstall mkcert, replace its local CA, touch
localhost TLS material, remove wallet databases, or replace parameter
generations.
