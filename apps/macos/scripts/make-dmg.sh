#!/bin/bash
# Packages the built app as a release disk image (make dmg): copies it, adds the license texts of
# Zephyr and of the Swift packages it is built from, signs the copy ad-hoc inside-out and writes a
# compressed image holding Zephyr.app, an Applications link and the install notes.
set -euo pipefail
APP="$1"
DMG="$2"
CHECKOUTS="$3"
ROOT="${ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
STAGE="$ROOT/build.noindex/dmg/Zephyr"

rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Zephyr.app"

LICENSES="$STAGE/Zephyr.app/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
cp "$ROOT/LICENSE" "$LICENSES/Zephyr-LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$LICENSES/THIRD_PARTY_NOTICES.md"
cp "$CHECKOUTS/swift-markdown/LICENSE.txt" "$LICENSES/swift-markdown-LICENSE.txt"
cp "$CHECKOUTS/swift-markdown/NOTICE.txt" "$LICENSES/swift-markdown-NOTICE.txt"
cp "$CHECKOUTS/swift-cmark/COPYING" "$LICENSES/swift-cmark-COPYING.txt"
cp "$CHECKOUTS/SwaTex/LICENSE" "$LICENSES/SwaTex-LICENSE.txt"
cp "$CHECKOUTS/SwaTex/THIRD_PARTY_NOTICES.md" "$LICENSES/SwaTex-THIRD_PARTY_NOTICES.md"
cp "$CHECKOUTS/Sparkle/LICENSE" "$LICENSES/Sparkle-LICENSE.txt"
# Package checkouts are read-only; writable copies let `xattr -dr` clear the quarantine mark.
chmod 644 "$LICENSES"/*

ADHOC=1 ROOT="$ROOT" "$ROOT/apps/macos/scripts/sign.sh" "$STAGE/Zephyr.app"

ln -s /Applications "$STAGE/Applications"
cp "$ROOT/apps/macos/scripts/dmg-install.txt" "$STAGE/Install.txt"

rm -f "$DMG"
hdiutil create -volname Zephyr -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
( cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "$DMG"
cat "$DMG.sha256"
