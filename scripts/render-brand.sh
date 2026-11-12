#!/usr/bin/env bash
# Renders the PNGs derived from brand/ SVGs. Needs rsvg-convert (brew install librsvg) and python3.
# After this, regenerate the platform sets from mobile/:
#   flutter pub run flutter_launcher_icons && flutter pub run flutter_native_splash:create
# Review the result as brand/README.md describes: the generators also change files they should not.
set -euo pipefail
cd "$(dirname "$0")/.."

# Mobile inputs for flutter_launcher_icons and flutter_native_splash
icons=mobile/assets/icon
mkdir -p "$icons"
for name in ios macos adaptive-foreground adaptive-monochrome splash; do
  rsvg-convert -w 1024 -h 1024 "brand/app/$name.svg" -o "$icons/$name.png"
done

# Android notification icon, by density
res=mobile/android/app/src/main/res
for spec in mdpi:24 hdpi:36 xhdpi:48 xxhdpi:72 xxxhdpi:96; do
  dir="$res/drawable-${spec%%:*}"
  mkdir -p "$dir"
  rsvg-convert -w "${spec##*:}" -h "${spec##*:}" brand/app/notification.svg -o "$dir/ic_stat_pux.png"
done

# Website
static=server/priv/static
mkdir -p "$static/images"
cp brand/pux-icon.svg "$static/favicon.svg"
rsvg-convert -w 180 -h 180 brand/app/ios.svg -o "$static/images/apple-touch-icon.png"
rsvg-convert -w 1200 -h 630 brand/og-image.svg -o "$static/images/og-image.png"
rsvg-convert -w 32 -h 32 brand/pux-icon.svg -o "$static/favicon-32.png.tmp"
python3 -I - "$static/favicon-32.png.tmp" "$static/favicon.ico" <<'PY'
import struct, sys
png = open(sys.argv[1], "rb").read()
# A single-image ICO holding a PNG, which every current browser reads.
open(sys.argv[2], "wb").write(
    struct.pack("<HHH", 0, 1, 1)
    + struct.pack("<BBBBHHII", 32, 32, 0, 0, 1, 32, len(png), 22)
    + png
)
PY
rm "$static/favicon-32.png.tmp"

# Store listings. Play rejects a feature graphic with an alpha channel, so
# flatten it onto pine.
store=brand/store
mkdir -p "$store"
rsvg-convert -w 1024 -h 500 -b '#0E3B32' brand/play-feature-graphic.svg -o "$store/play-feature-graphic.png"
