#!/usr/bin/env bash
# Renders the PNGs derived from brand/ SVGs. Needs rsvg-convert (brew install librsvg) and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

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
