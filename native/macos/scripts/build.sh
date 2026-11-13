#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
cd "$script_dir/.."

if [ -d "$script_dir/../Vendor/libsodium/lib/pkgconfig" ]; then
  export PKG_CONFIG_PATH="$script_dir/../Vendor/libsodium/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

extra_flags=()
if [ -d "$script_dir/../Vendor/libsodium/lib" ]; then
  vendor_lib=$(cd "$script_dir/../Vendor/libsodium/lib" && pwd)
  extra_flags+=(-Xlinker -rpath -Xlinker "$vendor_lib")
fi

echo "Building pux-macos (release)..."
swift build -c release "${extra_flags[@]}" --disable-sandbox
echo "Build complete: .build/release/pux"
