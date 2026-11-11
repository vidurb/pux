#!/usr/bin/env bash
# Takes App Store screenshots of the scenes in lib/screenshots/scenes.dart.
#
# Builds the screenshot entry point once for the simulator, then on a 6.9"
# iPhone and a 13" iPad opens each scene, sets a clean status bar and saves a
# PNG at the size App Store Connect asks for. Before each launch it writes the
# scene name to tmp/pux_scene in the app's data container, so one build covers
# every scene. (Flutter on iOS sees an empty environment, so SIMCTL_CHILD_*
# variables don't work for this.)
#
# Uses its own simulators ("pux screenshots ..."), created on first run, so
# your other simulators are left alone. Needs Xcode with an iOS simulator
# runtime (xcodebuild -downloadPlatform iOS).
#
#   cd mobile && ios/scripts/app_store_screenshots.sh [output-dir]
#
# SETTLE_SECONDS (default 4) is how long each scene gets to draw.
set -euo pipefail

cd "$(dirname "$0")/../.."
out="${1:-build/app_store_screenshots}"
settle="${SETTLE_SECONDS:-4}"
bundle_id=xyz.vidur.pux
app=build/ios/iphonesimulator/Runner.app

# name | device type | expected pixel size
devices=(
  "iphone-6.9|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max|1320x2868"
  "ipad-13|com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB|2064x2752"
)

# Scene names, in store order, straight from the enum.
scenes=()
while IFS= read -r scene; do scenes+=("$scene"); done < <(
  awk '/^enum Scene \{/ { on = 1; next } on && /^  [a-zA-Z]+\($/ { sub(/^  /, ""); sub(/\($/, ""); print } on && /^}/ { exit }' \
    lib/screenshots/scenes.dart
)
if [ "${#scenes[@]}" -eq 0 ]; then
  echo "No scenes found in lib/screenshots/scenes.dart" >&2
  exit 1
fi

runtime=$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
ios = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(max(ios, key=lambda r: [int(p) for p in r["version"].split(".")])["identifier"] if ios else "")
')
if [ -z "$runtime" ]; then
  echo "No iOS simulator runtime. Install one with: xcodebuild -downloadPlatform iOS" >&2
  exit 1
fi

simulator() { # name, device type -> UDID, creating the simulator if needed
  local name="pux screenshots $1" udid
  udid=$(xcrun simctl list devices --json | python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
for device in json.load(sys.stdin)["devices"].get(runtime, []):
    if device["name"] == name and device["isAvailable"]:
        print(device["udid"]); break
' "$name" "$runtime")
  if [ -z "$udid" ]; then udid=$(xcrun simctl create "$name" "$2" "$runtime"); fi
  echo "$udid"
}

echo "Building the screenshot app for the simulator..."
flutter build ios --simulator --debug -t lib/screenshots/main.dart

for entry in "${devices[@]}"; do
  IFS='|' read -r name type size <<<"$entry"
  udid=$(simulator "$name" "$type")
  dir="$out/$name"
  mkdir -p "$dir"
  echo "== $name ($udid)"

  was_booted=$(xcrun simctl list devices | grep -q "$udid) (Booted)" && echo yes || echo no)
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance light
  # Wi-Fi only: the store copy is about codes arriving without mobile signal.
  xcrun simctl status_bar "$udid" override --time 9:41 \
    --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode notSupported \
    --batteryState charged --batteryLevel 100
  xcrun simctl install "$udid" "$app"
  scene_file="$(xcrun simctl get_app_container "$udid" "$bundle_id" data)/tmp/pux_scene"
  mkdir -p "$(dirname "$scene_file")"

  index=1
  for scene in "${scenes[@]}"; do
    file=$(printf '%s/%02d-%s.png' "$dir" "$index" "$scene")
    xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
    printf '%s' "$scene" >"$scene_file"
    xcrun simctl launch "$udid" "$bundle_id" >/dev/null
    # The first launch of a debug build loads the Dart VM, so give it longer.
    if [ "$index" -eq 1 ]; then sleep $((settle * 2)); else sleep "$settle"; fi
    xcrun simctl io "$udid" screenshot --type=png "$file" >/dev/null 2>&1
    actual=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { print w "x" h }')
    if [ "$actual" != "$size" ]; then
      echo "  $file is $actual, but App Store Connect expects $size" >&2
      exit 1
    fi
    echo "  $file"
    index=$((index + 1))
  done

  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
  rm -f "$scene_file"
  xcrun simctl status_bar "$udid" clear
  if [ "$was_booted" = no ]; then xcrun simctl shutdown "$udid"; fi
done

echo "Screenshots are in $out"
