#!/usr/bin/env bash
set -euo pipefail

# Manual trust-bootstrap installer. It replaces only the application bundle;
# wallet data, proving parameters, preferences, and local TLS material are
# intentionally outside its scope.

version="${CLOAK_VERSION:-latest}"
repository="fuck-bitcoin/CLOAK_WALLET"
app_name="CLOAK Wallet"
install_directory="$HOME/Applications"
app_path="$install_directory/$app_name.app"
previous_path="$install_directory/$app_name.app.previous"
legacy_system_path="/Applications/$app_name.app"
legacy_backup_path="$install_directory/$app_name.app.legacy-from-Applications"
artifact="CLOAK_Wallet-macos-universal.dmg"
temporary_directory="$(mktemp -d)"
mount_point=""

cleanup() {
  if [[ -n "$mount_point" && -d "$mount_point" ]]; then
    hdiutil detach "$mount_point" -quiet 2>/dev/null || true
  fi
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT INT TERM

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$version" == "latest" || "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "CLOAK_VERSION must be latest or vMAJOR.MINOR.PATCH"
[[ "$(uname -s)" == "Darwin" ]] || fail "This installer requires macOS"
case "$(uname -m)" in
  arm64|x86_64) ;;
  *) fail "Unsupported Mac architecture: $(uname -m)" ;;
esac

if [[ "$version" == "latest" ]]; then
  release_base="https://github.com/$repository/releases/latest/download"
else
  release_base="https://github.com/$repository/releases/download/$version"
fi
dmg="$temporary_directory/$artifact"
checksums="$temporary_directory/SHA256SUMS-macos"

echo "Downloading the CLOAK Wallet trust baseline..."
curl -fL --progress-bar "$release_base/$artifact" -o "$dmg" \
  || fail "Application download failed"
curl -fsSL "$release_base/SHA256SUMS-macos" -o "$checksums" \
  || fail "Signed-release checksum list is unavailable"

expected="$(awk -v name="$artifact" '$2 == name || $2 == "*" name {print $1}' "$checksums")"
actual="$(shasum -a 256 "$dmg" | awk '{print $1}')"
expected_lower="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
actual_lower="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "$expected_lower" == "$actual_lower" ]] \
  || fail "Release checksum verification failed"

if pgrep -f "$app_path/Contents/MacOS" >/dev/null 2>&1 ||
   pgrep -f "$legacy_system_path/Contents/MacOS" >/dev/null 2>&1; then
  fail "Close CLOAK Wallet before installing the baseline"
fi

mount_plist="$(hdiutil attach "$dmg" -nobrowse -plist)" \
  || fail "The verified disk image could not be mounted"
mount_point="$(printf '%s' "$mount_plist" \
  | sed -n '/<key>mount-point<\/key>/{n;s:.*<string>\(.*\)</string>.*:\1:p;q;}')"
[[ -n "$mount_point" && -d "$mount_point/$app_name.app" ]] \
  || fail "The disk image does not contain CLOAK Wallet"

mkdir -p "$install_directory"
staged_path="$install_directory/.$app_name.app.staging.$$"
ditto "$mount_point/$app_name.app" "$staged_path" \
  || fail "Could not stage the application bundle"
hdiutil detach "$mount_point" -quiet
mount_point=""

codesign --verify --deep --strict "$staged_path" \
  || fail "The staged ad-hoc bundle is internally inconsistent"
# The release digest was already verified. Removing only quarantine avoids
# repeated Gatekeeper translocation while preserving all other attributes.
xattr -dr com.apple.quarantine "$staged_path" 2>/dev/null || true

if [[ -e "$previous_path" ]]; then
  rm -rf -- "$previous_path"
fi
if [[ -d "$app_path" ]]; then
  mv -- "$app_path" "$previous_path" \
    || fail "Could not preserve the previous application"
fi
if ! mv -- "$staged_path" "$app_path"; then
  [[ -d "$previous_path" ]] && mv -- "$previous_path" "$app_path"
  fail "Could not activate the new application"
fi

health_token="$(openssl rand -hex 16)"
health_file="${TMPDIR:-/tmp}/cloak-wallet-update-$health_token.ok"
rm -f -- "$health_file"
echo "Launching the baseline. macOS may require Open Anyway for this self-signed build."
open -n "$app_path" --args "--cloak-update-health=$health_token" \
  || fail "Could not launch the new baseline"

healthy=false
for _ in $(seq 1 480); do
  if [[ -f "$health_file" ]]; then
    healthy=true
    break
  fi
  sleep 0.25
done
if [[ "$healthy" != true ]]; then
  pkill -f "$app_path/Contents/MacOS" 2>/dev/null || true
  failed_path="$install_directory/$app_name.app.failed-$health_token"
  mv -- "$app_path" "$failed_path" 2>/dev/null || true
  if [[ -d "$previous_path" ]]; then
    mv -- "$previous_path" "$app_path"
    open "$app_path" 2>/dev/null || true
  fi
  fail "Baseline health check failed; the previous app was restored"
fi

echo "CLOAK Wallet installed at $app_path"
echo "Wallet data, parameters, preferences, and local TLS files were preserved."
if [[ -L "$legacy_system_path" ]]; then
  echo "WARNING: $legacy_system_path is a symbolic link and was not moved." >&2
  echo "Inspect and remove that legacy launcher manually; sudo was not used." >&2
elif [[ -d "$legacy_system_path" ]]; then
  # This happens only after the replacement under ~/Applications has passed
  # its first-frame health acknowledgement. Keep the legacy bundle as a named
  # backup and never replace an existing backup.
  if [[ -e "$legacy_backup_path" ]]; then
    echo "WARNING: Legacy backup already exists at $legacy_backup_path." >&2
    echo "Move or remove $legacy_system_path manually; nothing was overwritten." >&2
  elif mv -- "$legacy_system_path" "$legacy_backup_path" 2>/dev/null; then
    echo "Retained the former /Applications copy at $legacy_backup_path"
  else
    echo "WARNING: macOS permissions prevented moving $legacy_system_path." >&2
    echo "Move it manually to $legacy_backup_path; this installer will not use sudo." >&2
  fi
fi
