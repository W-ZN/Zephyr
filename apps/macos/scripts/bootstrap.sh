#!/bin/bash
# Fetches the pinned XcodeGen release into build.noindex/tools. Nothing is installed system-wide.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
VERSION=2.46.0
SHA256=8774da746668bc18fe74e54cbaf10f2631a1fb05947cd374179aa912f14f99db  # bin/xcodegen in that release
DEST="$ROOT/build.noindex/tools"

mkdir -p "$DEST"
TMP=$(mktemp -d "$DEST/xcodegen-download.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip" -o "$TMP/xcodegen.zip"
ditto -x -k "$TMP/xcodegen.zip" "$TMP"
echo "$SHA256  $TMP/xcodegen/bin/xcodegen" | shasum -a 256 -c - >/dev/null
rm -rf "$DEST/xcodegen"
mv "$TMP/xcodegen" "$DEST/xcodegen"
echo "xcodegen $VERSION -> $DEST/xcodegen"
