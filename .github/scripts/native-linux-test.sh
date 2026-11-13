#!/usr/bin/env bash
set -euo pipefail
# A private HOME and D-Bus session keep the CI keyring separate from the runner.
export HOME
HOME=$(mktemp -d)
trap 'rm -rf "$HOME"' EXIT
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_RUNTIME_DIR="$HOME/runtime"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
dbus-run-session -- xvfb-run -a bash -eu -o pipefail -c '
  printf "ci-test-keyring" | gnome-keyring-daemon --unlock --components=secrets
  export PUX_REQUIRE_KEYRING=1
  timeout 240s ./native/linux/build/pux_linux_tests
'
