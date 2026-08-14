#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 MANIFEST PRIVATE_KEY OUTPUT_SIGNATURE EXPECTED_PUBLIC_KEY_BASE64" >&2
  exit 2
fi

manifest="$1"
private_key="$2"
output_signature="$3"
expected_public_key="$4"

[[ -f "$manifest" && -s "$manifest" ]] || {
  echo "Manifest is missing or empty: $manifest" >&2
  exit 1
}
[[ -f "$private_key" && -s "$private_key" ]] || {
  echo "Release private key is missing or empty" >&2
  exit 1
}
[[ "$expected_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
  echo "Expected release public key is malformed" >&2
  exit 1
}

umask 077
temporary_directory="$(mktemp -d)"
trap 'rm -rf -- "$temporary_directory"' EXIT
public_key="$temporary_directory/public.pem"
signature_binary="$temporary_directory/signature.bin"

openssl pkey -in "$private_key" -pubout -out "$public_key"
derived_public_key="$({
  openssl pkey -pubin -in "$public_key" -outform DER
} | tail -c 32 | openssl base64 -A)"
[[ "$derived_public_key" == "$expected_public_key" ]] || {
  echo "Release private key does not match the configured public key" >&2
  exit 1
}

openssl pkeyutl -sign -rawin -inkey "$private_key" \
  -in "$manifest" -out "$signature_binary"
signature="$(openssl base64 -A -in "$signature_binary")"

python3 - "$output_signature" "$signature" <<'PY'
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
payload = {
    "algorithm": "Ed25519",
    "keyId": "cloak-release-v1",
    "signature": sys.argv[2],
}
output.write_bytes(
    (json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n").encode()
)
PY
chmod 644 "$output_signature"

openssl pkeyutl -verify -rawin -pubin -inkey "$public_key" \
  -sigfile "$signature_binary" -in "$manifest" >/dev/null
echo "Signed and verified exact manifest bytes: $manifest"
