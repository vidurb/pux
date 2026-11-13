#!/usr/bin/env bash
# Bundle the native Linux binary like release CI: pux-$VERSION-linux-x64.tar.gz
#
#   build_tar.sh <binary-path> <version> <output.tar.gz>
#
# Layout (binary at the tarball root, as .github/workflows/release.yml expects):
#
#   ./pux          the executable
#   ./README.txt   runtime dependency guidance (tarball-README.txt)
#   ./copyright    third-party license notices
#
# The libraries pux links come from the user's distribution, so the guidance is
# part of the package. check_tar.sh runs on the result and fails the build if the
# README does not cover every library an ELF binary links.
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <binary-path> <version> <output.tar.gz>" >&2
  exit 64
fi

here=$(cd "$(dirname "$0")" && pwd)
binary=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
version=$2
output=$3

work=$(mktemp -d "${TMPDIR:-/tmp}/pux-package.XXXXXX")
trap 'rm -rf "$work"' EXIT
chmod 755 "$work"

install -m 755 "$binary" "$work/pux"
install -m 644 "$here/tarball-README.txt" "$work/README.txt"
install -m 644 "$here/copyright" "$work/copyright"

mkdir -p "$(dirname "$output")"
tar -C "$work" -czf "$output" .
"$here/check_tar.sh" "$output"
echo "Built $output (version $version)"
