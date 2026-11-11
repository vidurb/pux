#!/usr/bin/env bash
# Puts a signed pux.app in a compressed disk image next to an Applications link,
# so people can drag it across to install.
#
#   make_dmg.sh <path/to/pux.app> <output.dmg>
#
# Sign and notarize the image afterwards; see the release workflow.
set -euo pipefail

if [ $# -ne 2 ]; then
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

app=$1
output=$2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ditto "$app" "$work/pux/$(basename "$app")"
ln -s /Applications "$work/pux/Applications"

# hdiutil fails now and then on CI runners with "Resource busy"; a retry clears it.
for attempt in 1 2 3; do
  if hdiutil create -volname pux -srcfolder "$work/pux" -fs HFS+ -format UDZO -ov "$output"; then
    exit 0
  fi
  echo "hdiutil failed (attempt $attempt), retrying" >&2
  sleep 5
done
exit 1
