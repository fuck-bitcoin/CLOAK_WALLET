# Update manifest v1

`update-v1.json` is generated from completed artifacts and signed without
changing or canonicalizing its bytes afterward. `update-v1.sig` is JSON:

```json
{"algorithm":"Ed25519","keyId":"cloak-release-v1","signature":"BASE64"}
```

Clients verify that detached signature over the raw manifest bytes before JSON
decoding. Every asset records its explicit platform, architecture, immutable
GitHub release URL, byte size, and SHA-256. The map key must equal
`platform-architecture`. `requiredParameterGeneration` binds the app release to
one complete, signed proving-parameter generation without bundling or replacing
those parameters during an app update.
