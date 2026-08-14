#!/usr/bin/env bash
set -euo pipefail

destination="${1:-release-keys}"
umask 077
mkdir -p "$destination"
private_key="$destination/release-manifest-private.pem"
public_pem="$destination/release-manifest-public.pem"
public_base64="$destination/release-manifest-public.base64"

[[ ! -e "$private_key" && ! -e "$public_pem" && ! -e "$public_base64" ]] || {
  echo "Refusing to overwrite an existing release key in $destination" >&2
  exit 1
}

openssl genpkey -algorithm ED25519 -out "$private_key"
openssl pkey -in "$private_key" -pubout -out "$public_pem"
openssl pkey -pubin -in "$public_pem" -outform DER \
  | tail -c 32 | base64 | tr -d '\n' > "$public_base64"
chmod 600 "$private_key"
chmod 644 "$public_pem" "$public_base64"

echo "Release manifest key files were created in $destination."
echo "No private key material was printed. Make two encrypted offline backups."
