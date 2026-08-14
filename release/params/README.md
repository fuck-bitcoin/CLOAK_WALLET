# Depth-12 proving parameters

`params-manifest-v1.json` is the canonical byte-for-byte manifest source. The
release workflow signs these exact UTF-8 bytes with the CLOAK release-manifest
Ed25519 key (the same trust root used for update manifests) and publishes the
detached metadata as `params-manifest-v1.json.sig` beside all four parameter
files. The signature file is the canonical JSON object
`{"algorithm":"Ed25519","keyId":"cloak-release-v1","signature":"<base64>"}`.

Do not hand-edit or reformat the manifest after signing. The wallet first
verifies the detached signature, then parses it, and finally compares every
field with a second set of values pinned in the application.

The public trust root and this generation's detached signature are committed so
reviewers can reproduce verification before the assets are published. Private
signing keys must never be committed here.
