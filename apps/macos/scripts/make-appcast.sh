#!/bin/bash
# Sign the GitHub feed after packaging. Keep each enclosure on its immutable release tag.
set -euo pipefail
DMG="$1"
VERSION="$2"
ROOT="${ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
TOOLS="$ROOT/build.noindex/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
STAGE=$(mktemp -d "$ROOT/build.noindex/appcast.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
OUTPUT="$ROOT/dist/appcast.xml"

cp "$DMG" "$STAGE/$(basename "$DMG")"
# Release notes shown in the update dialog: apps/macos/release-notes/<version>.html, embedded in the feed.
NOTES="$ROOT/apps/macos/release-notes/$VERSION.html"
[ -f "$NOTES" ] && cp "$NOTES" "$STAGE/$(basename "$DMG" .dmg).html"
"$TOOLS/generate_appcast" --account dev.zephyr.Zephyr \
    --download-url-prefix "https://github.com/W-ZN/Zephyr/releases/download/v$VERSION/" \
    --link "https://github.com/W-ZN/Zephyr/releases/tag/v$VERSION" \
    --maximum-deltas 0 --embed-release-notes -o "$OUTPUT" "$STAGE"
swift "$ROOT/apps/macos/scripts/verify-appcast.swift" "$OUTPUT" "$DMG" "$ROOT/dist/Zephyr.app/Contents/Info.plist"
echo "$OUTPUT"
