#!/usr/bin/env bash
set -euo pipefail

test_root="$(mktemp -d)"
parent_pid=""
helper_pid=""
cleanup() {
  [[ -z "$helper_pid" ]] || kill "$helper_pid" 2>/dev/null || true
  [[ -z "$parent_pid" ]] || kill "$parent_pid" 2>/dev/null || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT INT TERM

test_home="$test_root/home"
test_tmp="$test_root/tmp"
managed_directory="$test_home/.local/share/cloak-wallet"
current="$managed_directory/CLOAK_Wallet-x86_64.AppImage"
token='0123456789abcdef0123456789abcdef'
staged="$current.update-$token"
previous="$current.previous"
ready="$test_tmp/cloak-wallet-update-$token.ready"
mkdir -p "$managed_directory" "$test_tmp"
printf 'old-appimage\n' > "$current"
printf 'new-appimage\n' > "$staged"
chmod 700 "$current" "$staged"

# Keep the helper in its parent-wait phase until it has validated staging,
# then remove the staged file to deterministically force activation failure.
sleep 30 &
parent_pid=$!
HOME="$test_home" TMPDIR="$test_tmp" \
  bash assets/updater/linux-update.sh \
    "$parent_pid" "$current" "$staged" "$previous" "$token" &
helper_pid=$!

for _ in $(seq 1 100); do
  [[ -f "$ready" ]] && break
  sleep 0.02
done
[[ -f "$ready" ]] || {
  echo 'Linux helper did not reach validated staging' >&2
  exit 1
}
rm -f -- "$staged"
kill "$parent_pid" 2>/dev/null || true
wait "$parent_pid" 2>/dev/null || true
parent_pid=""

set +e
wait "$helper_pid"
status=$?
set -e
helper_pid=""
[[ "$status" == 4 ]] || {
  echo "Linux helper returned $status instead of rollback status 4" >&2
  exit 1
}
[[ "$(tr -d '\n' < "$current")" == 'old-appimage' ]]
[[ ! -e "$previous" ]]

echo 'Linux helper activation rollback passed.'
