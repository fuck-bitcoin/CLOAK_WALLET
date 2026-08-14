#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-build/macos/Build/Products/Release/CLOAK Wallet.app}"
SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
ENTITLEMENTS_SOURCE="macos/Runner/Release.entitlements"

[[ -d "$APP_PATH" ]] || { echo "App bundle not found: $APP_PATH" >&2; exit 1; }
[[ -f "$ENTITLEMENTS_SOURCE" ]] || {
  echo "Entitlements not found: $ENTITLEMENTS_SOURCE" >&2
  exit 1
}

# Xcode expands PRODUCT_BUNDLE_IDENTIFIER when it signs the initial bundle.
# This script signs the final assembled app directly, so create the same
# expanded entitlement values explicitly instead of embedding the literal
# build-setting placeholder in the final signature.
signing_workspace="$(mktemp -d "${TMPDIR:-/tmp}/cloak-mac-sign.XXXXXX")"
trap 'rm -rf "$signing_workspace"' EXIT
expanded_entitlements="$signing_workspace/Release.entitlements"
cp "$ENTITLEMENTS_SOURCE" "$expanded_entitlements"
mach_lookup_key='com.apple.security.temporary-exception.mach-lookup.global-name'
/usr/libexec/PlistBuddy -c "Set :$mach_lookup_key:0 app.cloak.wallet-spks" \
  "$expanded_entitlements"
/usr/libexec/PlistBuddy -c "Set :$mach_lookup_key:1 app.cloak.wallet-spki" \
  "$expanded_entitlements"
[[ "$(/usr/libexec/PlistBuddy -c "Print :$mach_lookup_key:0" \
  "$expanded_entitlements")" == 'app.cloak.wallet-spks' ]]
[[ "$(/usr/libexec/PlistBuddy -c "Print :$mach_lookup_key:1" \
  "$expanded_entitlements")" == 'app.cloak.wallet-spki' ]]
if grep -Fq '$(PRODUCT_BUNDLE_IDENTIFIER)' "$expanded_entitlements"; then
  echo 'Unexpanded bundle identifier remains in signing entitlements' >&2
  exit 1
fi

# Sign nested Sparkle code leaf-to-root. Never use `codesign --deep` for signing:
# it can replace required XPC entitlements with the host application's set.
if [[ -d "$SPARKLE" ]]; then
  for nested in \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE/Versions/B/Updater.app"; do
    if [[ -e "$nested" ]]; then
      codesign --force --sign - --options runtime \
        --preserve-metadata=identifier,entitlements "$nested"
    fi
  done
  codesign --force --sign - --preserve-metadata=identifier "$SPARKLE"
fi

while IFS= read -r -d '' library; do
  codesign --force --sign - --preserve-metadata=identifier "$library"
done < <(find "$APP_PATH/Contents/Frameworks" -type f \
  \( -name '*.dylib' -o -name '*.so' \) -print0)

codesign --force --sign - \
  --entitlements "$expanded_entitlements" \
  "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
