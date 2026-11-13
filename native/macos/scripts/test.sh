#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
cd "$script_dir/.."

if [ -d "$script_dir/../Vendor/libsodium/lib/pkgconfig" ]; then
  export PKG_CONFIG_PATH="$script_dir/../Vendor/libsodium/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export DYLD_LIBRARY_PATH="$script_dir/../Vendor/libsodium/lib:${DYLD_LIBRARY_PATH:-}"
fi

extra_flags=()
if [ -d "$script_dir/../Vendor/libsodium/lib" ]; then
  vendor_lib=$(cd "$script_dir/../Vendor/libsodium/lib" && pwd)
  extra_flags+=(-Xlinker -rpath -Xlinker "$vendor_lib")
fi

echo "Running keychain probe (non-production service)..."
"$script_dir/keychain_probe.sh"

echo "Running pux-macos tests..."
swift test "${extra_flags[@]}" --disable-sandbox
