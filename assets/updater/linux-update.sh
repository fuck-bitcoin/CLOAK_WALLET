#!/usr/bin/env bash
set -euo pipefail

parent_pid="$1"
current="$2"
staged="$3"
previous="$4"
token="$5"

[[ "$token" =~ ^[0-9a-f]{32}$ ]] || exit 2
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
expected="$data_home/cloak-wallet/CLOAK_Wallet-x86_64.AppImage"
[[ "$current" == "$expected" ]] || exit 2
[[ "$staged" == "$expected.update-$token" ]] || exit 2
[[ "$previous" == "$expected.previous" ]] || exit 2
[[ -f "$current" && -x "$current" ]] || exit 2
[[ -f "$staged" && -x "$staged" ]] || exit 2
ready_file="${TMPDIR:-/tmp}/cloak-wallet-update-$token.ready"
printf '%s' "$token" > "$ready_file"

for _ in $(seq 1 360); do
  kill -0 "$parent_pid" 2>/dev/null || break
  sleep 0.25
done
kill -0 "$parent_pid" 2>/dev/null && exit 3

health_file="${TMPDIR:-/tmp}/cloak-wallet-update-$token.ok"
rm -f -- "$health_file"
rm -f -- "$previous"
mv -- "$current" "$previous"
if ! mv -- "$staged" "$current"; then
  # The old image has already moved aside. Restore it before returning so a
  # failed activation never leaves the managed path empty.
  if ! mv -- "$previous" "$current"; then
    echo "CLOAK updater could not restore $current from $previous" >&2
    exit 5
  fi
  exit 4
fi

"$current" "--cloak-update-health=$token" &
new_pid=$!
for _ in $(seq 1 240); do
  [[ -f "$health_file" ]] && exit 0
  kill -0 "$new_pid" 2>/dev/null || break
  sleep 0.25
done

kill "$new_pid" 2>/dev/null || true
failed="$current.failed-$token"
mv -- "$current" "$failed"
mv -- "$previous" "$current"
"$current" >/dev/null 2>&1 &
exit 1
