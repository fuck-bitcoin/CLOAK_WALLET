#!/usr/bin/env bash
set -euo pipefail

destination="${1:-release-keys}"
private_key="$destination/sparkle-private.base64"
public_key="$destination/sparkle-public.base64"

[[ ! -e "$private_key" && ! -e "$public_key" ]] || {
  echo "Refusing to overwrite an existing Sparkle key in $destination" >&2
  exit 1
}

umask 077
mkdir -p "$destination"
working_directory="$(mktemp -d)"
trap 'rm -rf "$working_directory"' EXIT
seed="$working_directory/seed.bin"
private_der="$working_directory/private.der"
public_der="$working_directory/public.der"

# Sparkle 2.9.5's current private-key file format is base64 of a 32-byte
# Ed25519 seed. Build the RFC 8410 PKCS#8 wrapper only to derive its public key.
openssl rand 32 > "$seed"
openssl base64 -A -in "$seed" -out "$private_key"
printf '302e020100300506032b657004220420' | xxd -r -p > "$private_der"
cat "$seed" >> "$private_der"
openssl pkey -inform DER -in "$private_der" -pubout -outform DER \
  > "$public_der"
tail -c 32 "$public_der" | openssl base64 -A > "$public_key"

[[ "$(openssl base64 -d -A -in "$private_key" | wc -c | tr -d ' ')" == 32 ]] || exit 1
[[ "$(openssl base64 -d -A -in "$public_key" | wc -c | tr -d ' ')" == 32 ]] || exit 1
chmod 600 "$private_key"
chmod 644 "$public_key"

echo "Sparkle 2.9.5 key files were created in $destination."
echo "No private key material was printed. Make two encrypted offline backups."
