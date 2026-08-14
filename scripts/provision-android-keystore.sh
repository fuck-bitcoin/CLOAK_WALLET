#!/usr/bin/env bash
set -euo pipefail

destination="${1:-release-keys/cloak-android-release.jks}"
[[ ! -e "$destination" ]] || {
  echo "Refusing to overwrite $destination" >&2
  exit 1
}
mkdir -p "$(dirname "$destination")"
umask 077

read -r -s -p 'Android keystore password: ' store_password
echo
read -r -s -p 'Repeat Android keystore password: ' repeated_password
echo
[[ "$store_password" == "$repeated_password" && ${#store_password} -ge 16 ]] || {
  echo 'Passwords differ or are shorter than 16 characters' >&2
  exit 1
}

keytool -genkeypair -v \
  -keystore "$destination" \
  -storetype JKS \
  -alias cloak-release \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass "$store_password" -keypass "$store_password" \
  -dname 'CN=CLOAK Wallet Release, O=CLOAK'
chmod 600 "$destination"
unset store_password repeated_password
echo "Android release keystore created at $destination. No password was printed."
echo 'Keep two encrypted offline backups; this key cannot be replaced in-place.'
