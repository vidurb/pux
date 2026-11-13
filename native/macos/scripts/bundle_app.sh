#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
macos_dir=$(cd "$script_dir/.." && pwd)
repo_root=$(cd "$macos_dir/../.." && pwd)

configuration=${1:-release}
raw_output_dir="${2:-$macos_dir/build}"
mkdir -p "$raw_output_dir"
output_dir=$(cd "$raw_output_dir" && pwd)

cd "$macos_dir"
if [ -d "$macos_dir/Vendor/libsodium/lib/pkgconfig" ]; then
  export PKG_CONFIG_PATH="$macos_dir/Vendor/libsodium/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi
extra_flags=()
if [ -d "$macos_dir/Vendor/libsodium/lib" ]; then
  vendor_lib=$(cd "$macos_dir/Vendor/libsodium/lib" && pwd)
  extra_flags+=(-Xlinker -rpath -Xlinker "$vendor_lib")
fi

echo "Compiling pux ($configuration) for arm64 and x86_64..."
swift build -c "$configuration" --arch arm64 "${extra_flags[@]}" --disable-sandbox
bin_arm64=$(swift build -c "$configuration" --arch arm64 --show-bin-path --disable-sandbox)/pux
if [ ! -f "$bin_arm64" ]; then
  echo "error: arm64 binary not found at $bin_arm64" >&2
  exit 1
fi
tmp_arm=$(mktemp)
cp "$bin_arm64" "$tmp_arm"

swift build -c "$configuration" --arch x86_64 "${extra_flags[@]}" --disable-sandbox
bin_x86_64=$(swift build -c "$configuration" --arch x86_64 --show-bin-path --disable-sandbox)/pux
if [ ! -f "$bin_x86_64" ]; then
  echo "error: x86_64 binary not found at $bin_x86_64" >&2
  rm -f "$tmp_arm"
  exit 1
fi

app_bundle="$output_dir/pux.app"
thin_bin="$output_dir/pux.universal"
lipo -create "$tmp_arm" "$bin_x86_64" -output "$thin_bin"
rm -f "$tmp_arm"
lipo -info "$thin_bin"

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"
mkdir -p "$app_bundle/Contents/Frameworks"

cp "$thin_bin" "$app_bundle/Contents/MacOS/pux"
rm -f "$thin_bin"
cp "$macos_dir/Resources/Info.plist" "$app_bundle/Contents/Info.plist"

pubspec="$repo_root/mobile/pubspec.yaml"
if [ -f "$pubspec" ]; then
  marketing=$(grep -E '^version:' "$pubspec" | head -1 | sed -E 's/^version:[[:space:]]*([^[:space:]#+]+).*/\1/')
else
  marketing="${PUX_MARKETING_VERSION:-0.1.0}"
fi
build_number="${PUX_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDevelopmentRegion en" "$app_bundle/Contents/Info.plist"

# Compile asset catalog (AppIcon and MenuBarIcon) with actool
if [ -d "$macos_dir/Resources/Assets.xcassets" ]; then
  echo "Compiling assets with actool..."
  partial_plist=$(mktemp)
  if ! actool "$macos_dir/Resources/Assets.xcassets" \
    --compile "$app_bundle/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 12.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$partial_plist"; then
    echo "error: actool asset compilation failed" >&2
    rm -f "$partial_plist"
    exit 1
  fi
  rm -f "$partial_plist"

  if [ ! -f "$app_bundle/Contents/Resources/AppIcon.icns" ] || [ ! -f "$app_bundle/Contents/Resources/Assets.car" ]; then
    echo "error: expected AppIcon.icns and Assets.car in $app_bundle/Contents/Resources" >&2
    exit 1
  fi
fi

sodium_lib="$macos_dir/Vendor/libsodium/lib/libsodium.26.dylib"
if [ ! -f "$sodium_lib" ]; then
  echo "error: vendored libsodium not found at $sodium_lib" >&2
  exit 1
fi
expected_hash=$(grep -E 'Binary SHA-256' "$macos_dir/Vendor/libsodium/PROVENANCE.md" | sed -E 's/.*`([0-9a-f]{64})`.*/\1/')
actual_hash=$(shasum -a 256 "$sodium_lib" | awk '{print $1}')
if [ -z "$expected_hash" ] || [ "$expected_hash" != "$actual_hash" ]; then
  echo "error: libsodium dylib SHA-256 mismatch (expected ${expected_hash:-missing}, got $actual_hash)" >&2
  exit 1
fi

real_sodium=$(readlink -f "$sodium_lib" 2>/dev/null || realpath "$sodium_lib" 2>/dev/null || echo "$sodium_lib")
sodium_filename=$(basename "$real_sodium")

echo "Bundling libsodium ($sodium_filename)..."
cp "$real_sodium" "$app_bundle/Contents/Frameworks/$sodium_filename"
chmod +w "$app_bundle/Contents/Frameworks/$sodium_filename"

base_dylib="libsodium.dylib"
if [ "$sodium_filename" != "$base_dylib" ]; then
  ln -sf "$sodium_filename" "$app_bundle/Contents/Frameworks/$base_dylib"
fi

raw_dep=$(otool -L "$app_bundle/Contents/MacOS/pux" | grep libsodium | awk '{print $1}' || true)

install_name_tool -id "@rpath/$sodium_filename" "$app_bundle/Contents/Frameworks/$sodium_filename"

chmod +w "$app_bundle/Contents/MacOS/pux"
if [ -n "$raw_dep" ]; then
  install_name_tool -change "$raw_dep" "@executable_path/../Frameworks/$sodium_filename" "$app_bundle/Contents/MacOS/pux"
fi

list_rpaths() {
  otool -l "$1" | awk '/cmd LC_RPATH/{show=1; next} show&&$1=="path"{print $2; show=0}'
}

strip_rpaths() {
  local binary=$1
  set +e
  for _ in $(seq 1 32); do
    local changed=0
    while IFS= read -r rpath; do
      [ -n "$rpath" ] || continue
      case "$rpath" in
        @executable_path/../Frameworks) continue ;;
      esac
      install_name_tool -delete_rpath "$rpath" "$binary"
      if [ $? -eq 0 ]; then changed=1; fi
    done < <(list_rpaths "$binary")
    [ "$changed" -eq 1 ] || break
  done
  set -e
}
strip_rpaths "$app_bundle/Contents/MacOS/pux"

if otool -l "$app_bundle/Contents/MacOS/pux" | awk '/cmd LC_RPATH/{show=1; next} show&&$1=="path"{print $2; show=0}' | grep -qE '^/Applications/Xcode\.app/'; then
  echo "error: absolute Xcode toolchain LC_RPATH remains in shipped binary" >&2
  exit 1
fi

if ! otool -l "$app_bundle/Contents/MacOS/pux" | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_bundle/Contents/MacOS/pux"
fi

codesign -f -s - "$app_bundle/Contents/Frameworks/$sodium_filename"
codesign -f -s - "$app_bundle/Contents/MacOS/pux"

chmod +w "$app_bundle/Contents/MacOS/pux"
strip_rpaths "$app_bundle/Contents/MacOS/pux"
if ! otool -l "$app_bundle/Contents/MacOS/pux" | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_bundle/Contents/MacOS/pux"
fi
codesign -f -s - "$app_bundle/Contents/MacOS/pux"

for arch in x86_64 arm64; do
  if ! lipo -verify_arch "$arch" "$app_bundle/Contents/MacOS/pux"; then
    echo "error: pux binary lacks $arch" >&2
    exit 1
  fi
  if ! lipo -verify_arch "$arch" "$app_bundle/Contents/Frameworks/$sodium_filename"; then
    echo "error: bundled libsodium lacks $arch" >&2
    exit 1
  fi
  minos=$(otool -arch "$arch" -l "$app_bundle/Contents/Frameworks/$sodium_filename" | awk '
    $1 == "cmd" { command = $2 }
    command == "LC_BUILD_VERSION" && $1 == "minos" { print $2; exit }
    command == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2; exit }
  ')
  if ! [[ "$minos" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] ||
     ! awk -v version="$minos" 'BEGIN { split(version, v, "."); exit !(v[1] < 12 || (v[1] == 12 && v[2] == 0 && v[3] == 0)) }'; then
    echo "error: invalid or unsupported $arch libsodium deployment target: ${minos:-missing}" >&2
    exit 1
  fi
  echo "Bundled libsodium: $arch minimum macOS $minos"
done

echo "Created app bundle at $app_bundle"
lipo -info "$app_bundle/Contents/MacOS/pux"
echo "Verifying bundled binary dependencies:"
otool -L "$app_bundle/Contents/MacOS/pux"

if otool -l "$app_bundle/Contents/MacOS/pux" | awk '/cmd LC_RPATH/{show=1; next} show&&$1=="path"{print $2; show=0}' | grep -qE '^/Applications/Xcode\.app/'; then
  echo "error: absolute Xcode toolchain LC_RPATH remains after packaging" >&2
  exit 1
fi

echo "Verifying bundled app execution:"
"$app_bundle/Contents/MacOS/pux" --check
