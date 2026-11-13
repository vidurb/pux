#!/usr/bin/env bash
# Validates app-style Data Protection Keychain access (non-production service).
# Unbundled `swift run` builds lack keychain entitlements; XCTest covers the API (with XCTSkip on -34018).
# Release signing should also run: pux.app/Contents/MacOS/pux --probe-keychain
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
macos_dir=$(cd "$script_dir/.." && pwd)

extra_flags=()
if [ -d "$macos_dir/Vendor/libsodium/lib/pkgconfig" ]; then
  export PKG_CONFIG_PATH="$macos_dir/Vendor/libsodium/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi
if [ -d "$macos_dir/Vendor/libsodium/lib" ]; then
  vendor_lib=$(cd "$macos_dir/Vendor/libsodium/lib" && pwd)
  extra_flags+=(-Xlinker -rpath -Xlinker "$vendor_lib")
fi

cd "$macos_dir"
echo "Running KeychainAppProbeTests..."
swift test "${extra_flags[@]}" --disable-sandbox --filter KeychainAppProbeTests
