#!/usr/bin/env bash
# Checks that an app signed like the release build can use the data protection
# keychain, where pux keeps its keys. It builds a tiny probe app with the same
# bundle ID, signs it with sign_app.sh and the same arguments, and runs it.
#
#   keychain_probe.sh <path/to/pux.app> <identity> [team-id] [provisioning-profile]
#
# The probe exits non-zero when the keychain refuses the write. An ad-hoc or
# profile-less signature fails with -34018 (errSecMissingEntitlement).
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

app=$1
shift
script_dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

probe="$work/probe.app"
mkdir -p "$probe/Contents/MacOS"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
plutil -create xml1 "$probe/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "$bundle_id" "$probe/Contents/Info.plist"
plutil -insert CFBundleExecutable -string probe "$probe/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$probe/Contents/Info.plist"
swiftc -O "$script_dir/keychain_probe.swift" -o "$probe/Contents/MacOS/probe"

"$script_dir/sign_app.sh" "$probe" "$@" > "$work/sign.log" 2>&1 || { cat "$work/sign.log" >&2; exit 1; }
"$probe/Contents/MacOS/probe"
