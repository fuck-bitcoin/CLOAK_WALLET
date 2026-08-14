#!/usr/bin/env bash
set -euo pipefail

# CLOAK Wallet manual trust-bootstrap installer for Linux x64. Application
# files are the only mutable scope; wallet data, parameters, preferences, and
# local TLS material are preserved.

version="${CLOAK_VERSION:-latest}"
repository="fuck-bitcoin/CLOAK_WALLET"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
install_directory="$data_home/cloak-wallet"
artifact="CLOAK_Wallet-x86_64.AppImage"
app_path="$install_directory/$artifact"
previous_path="$app_path.previous"
temporary_directory="$(mktemp -d)"

cleanup() {
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT INT TERM

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$version" == "latest" || "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "CLOAK_VERSION must be latest or vMAJOR.MINOR.PATCH"
[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] \
  || fail "CLOAK Wallet requires x86_64 Linux"

if [[ "$version" == "latest" ]]; then
  release_base="https://github.com/$repository/releases/latest/download"
else
  release_base="https://github.com/$repository/releases/download/$version"
fi
downloaded="$temporary_directory/$artifact"
checksums="$temporary_directory/SHA256SUMS-linux"

echo "Downloading the CLOAK Wallet trust baseline..."
curl -fL --progress-bar "$release_base/$artifact" -o "$downloaded" \
  || fail "Application download failed"
curl -fsSL "$release_base/SHA256SUMS-linux" -o "$checksums" \
  || fail "Release checksum list is unavailable"
expected="$(awk -v name="$artifact" '$2 == name || $2 == "*" name {print $1}' "$checksums")"
actual="$(sha256sum "$downloaded" | awk '{print $1}')"
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "$expected" == "$actual" ]] \
  || fail "Release checksum verification failed"

if pgrep -f "$app_path" >/dev/null 2>&1; then
  fail "Close CLOAK Wallet before installing the baseline"
fi
mkdir -p "$install_directory"
staged_path="$app_path.staging.$$"
cp -- "$downloaded" "$staged_path"
chmod 700 "$staged_path"
if [[ -e "$previous_path" ]]; then
  rm -f -- "$previous_path"
fi
if [[ -e "$app_path" ]]; then
  mv -- "$app_path" "$previous_path"
fi
if ! mv -- "$staged_path" "$app_path"; then
  [[ -e "$previous_path" ]] && mv -- "$previous_path" "$app_path"
  fail "Could not activate the new AppImage"
fi

health_token="$(openssl rand -hex 16)"
health_file="${TMPDIR:-/tmp}/cloak-wallet-update-$health_token.ok"
rm -f -- "$health_file"
APPIMAGE_EXTRACT_AND_RUN=1 "$app_path" \
  "--cloak-update-health=$health_token" >/dev/null 2>&1 &
health_pid=$!
healthy=false
for _ in $(seq 1 240); do
  if [[ -f "$health_file" ]]; then
    healthy=true
    break
  fi
  kill -0 "$health_pid" 2>/dev/null || break
  sleep 0.25
done
if [[ "$healthy" != true ]]; then
  kill "$health_pid" 2>/dev/null || true
  failed_path="$app_path.failed-$health_token"
  mv -- "$app_path" "$failed_path" 2>/dev/null || true
  if [[ -e "$previous_path" ]]; then
    mv -- "$previous_path" "$app_path"
    APPIMAGE_EXTRACT_AND_RUN=1 "$app_path" >/dev/null 2>&1 &
  fi
  fail "Baseline health check failed; the previous AppImage was restored"
fi

bin_directory="$HOME/.local/bin"
mkdir -p "$bin_directory"
launcher="$bin_directory/cloak-wallet"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'export APPIMAGE_EXTRACT_AND_RUN=1' \
  "exec \"$app_path\" \"\$@\"" > "$launcher"
chmod 700 "$launcher"

echo "CLOAK Wallet installed at $app_path"
echo "Launcher installed at $launcher"
echo "Wallet data, parameters, preferences, and local TLS files were preserved."
