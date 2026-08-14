#!/usr/bin/env bash
set -euo pipefail

readonly SOURCE_BUNDLE_URL='https://downloads.cloak.today/cloak-gui-v1.26.06.2-windows.zip'
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OUTPUT_DIRECTORY" >&2
  exit 2
fi

output_dir=$1
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
bundle="$work_dir/cloak-gui-v1.26.06.2-windows.zip"
verified_dir="$work_dir/verified-params"
mkdir -p "$verified_dir"

curl --fail --location --retry 3 --output "$bundle" "$SOURCE_BUNDLE_URL"

for name in mint.params spend-output.params spend.params output.params; do
  mapfile -t matches < <(unzip -Z1 "$bundle" | grep -E "(^|/)params/$name$")
  if [[ ${#matches[@]} -ne 1 ]]; then
    echo "expected one params/$name entry, found ${#matches[@]}" >&2
    exit 1
  fi
  unzip -p "$bundle" "${matches[0]}" > "$verified_dir/$name"
done

cargo run --locked --release \
  --manifest-path "$REPO_ROOT/zeos-caterpillar/Cargo.toml" \
  --example verify_params -- "$verified_dir"

for name in mint.params spend-output.params spend.params output.params; do
  partial="$output_dir/$name.part"
  final="$output_dir/$name"
  cp -- "$verified_dir/$name" "$partial"
  cmp --silent "$verified_dir/$name" "$partial"
  mv -f -- "$partial" "$final"
done

cp "$REPO_ROOT/release/params/params-manifest-v1.json" "$output_dir/"
echo "verified parameter release staged at $output_dir"
