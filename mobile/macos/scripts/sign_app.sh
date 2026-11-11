#!/usr/bin/env bash
# Signs a built pux.app for distribution outside the Mac App Store.
#
#   sign_app.sh <path/to/pux.app> <identity> [team-id] [provisioning-profile]
#
# <identity> is a codesign identity: the SHA-1 or name of a "Developer ID
# Application" certificate, or "-" for an ad-hoc signature (local testing only).
#
# With a team ID, the app also gets the keychain entitlements that
# flutter_secure_storage needs. It stores keys in the data protection keychain,
# which refuses programs without a keychain access group (errSecMissingEntitlement,
# -34018). On macOS those entitlements are restricted, so they must be backed by
# an embedded Developer ID provisioning profile for the same App ID, or the
# system refuses to launch the app.
#
# Nested code is signed first, then the app. A real identity gets the hardened
# runtime and a secure timestamp, as notarization requires.
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

app=$1
identity=$2
team_id=${3:-}
profile=${4:-}
script_dir=$(cd "$(dirname "$0")" && pwd)

if [ -n "$team_id" ] && [ -z "$profile" ]; then
  echo "error: a team ID needs a provisioning profile; the keychain entitlements are restricted" >&2
  exit 64
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

entitlements="$work/app.entitlements"
cp "$script_dir/../Runner/Release.entitlements" "$entitlements"
if [ -n "$team_id" ]; then
  app_id="$team_id.$bundle_id"
  plutil -insert com.apple.application-identifier -string "$app_id" "$entitlements"
  plutil -insert com.apple.developer.team-identifier -string "$team_id" "$entitlements"
  plutil -insert keychain-access-groups -array "$entitlements"
  plutil -insert keychain-access-groups.0 -string "$app_id" "$entitlements"

  security cms -D -i "$profile" > "$work/profile.plist"
  profile_app_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$work/profile.plist")
  if [ "$profile_app_id" != "$app_id" ]; then
    echo "error: the provisioning profile is for $profile_app_id, not $app_id" >&2
    exit 1
  fi
  # A development profile only runs on the Macs listed in it.
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$work/profile.plist" 2>/dev/null)" != true ]; then
    echo "error: the provisioning profile is not a Developer ID profile" >&2
    exit 1
  fi
  cp "$profile" "$app/Contents/embedded.provisionprofile"
fi

# An ad-hoc signature has no team ID, so the hardened runtime's library
# validation would refuse to load the app's own frameworks. Skip it for local
# ad-hoc runs; notarization only ever sees the Developer ID signature.
flags=(--force --sign "$identity")
if [ "$identity" != "-" ]; then flags+=(--options runtime --timestamp); fi

# Deepest first, so each bundle is signed after the code inside it.
while IFS= read -r -d '' item; do
  codesign "${flags[@]}" "$item"
done < <(find "$app/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.app' \) -print0)

codesign "${flags[@]}" --entitlements "$entitlements" "$app"

codesign --verify --strict --deep --verbose=2 "$app"
echo "Entitlements:"
codesign --display --entitlements - --xml "$app" | plutil -p -
