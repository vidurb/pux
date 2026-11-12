#!/usr/bin/env bash
# Renders the scenes in lib/screenshots/scenes.dart to PNGs, with no device or
# emulator: Google Play's phone and tablet sets, and the README's screenshots.
#
#   cd mobile && tool/render_screenshots.sh [output-dir]
#
# Writes <output-dir>/play/{phone,tablet-7,tablet-10}/NN-<scene>.png in store
# order and <output-dir>/readme/app-<scene>.png (default build/screenshots).
# They are RGB PNGs with no alpha channel, as both stores require. The scenes
# render as on Android, in Roboto. For the App Store, which wants the iOS look,
# use ios/scripts/app_store_screenshots.sh.
#
# To update the README's copies:
#   cp build/screenshots/readme/*.png ../brand/screenshots/
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-build/screenshots}"
mkdir -p "$out"
PUX_SCREENSHOTS_OUT="$(cd "$out" && pwd)" flutter test tool/render_screenshots_test.dart
echo "Screenshots are in $out"
