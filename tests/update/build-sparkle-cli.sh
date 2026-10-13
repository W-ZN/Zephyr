#!/bin/bash
# Build Sparkle 2.10's source-only sparkle-cli into a dedicated DerivedData tree.
# Sparkle 2.10 does not ship this CLI in its SPM binary artifact.  Do not pass
# CODE_SIGNING_ALLOWED=NO: the app embeds Sparkle helpers used by its installer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SPARKLE_SOURCE="${1:-$ROOT/build.noindex/DerivedData/SourcePackages/checkouts/Sparkle}"
OUT="$ROOT/build.noindex/sparkle-cli-build"
DERIVED="$OUT/DerivedData"

if [[ ! -f "$SPARKLE_SOURCE/Sparkle.xcodeproj/project.pbxproj" ]]; then
    echo "Sparkle source checkout not found: $SPARKLE_SOURCE" >&2
    exit 2
fi

TAG="$(git -C "$SPARKLE_SOURCE" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$TAG" != "2.10.0" ]]; then
    echo "Expected exact Sparkle tag 2.10.0, got: ${TAG:-none}" >&2
    exit 2
fi

mkdir -p "$OUT"
xcodebuild -list -project "$SPARKLE_SOURCE/Sparkle.xcodeproj" | tee "$OUT/xcodebuild-list.txt"
xcodebuild -project "$SPARKLE_SOURCE/Sparkle.xcodeproj" -scheme sparkle-cli -configuration Release \
    -derivedDataPath "$DERIVED" build | tee "$OUT/xcodebuild-build.log"

CLI="$DERIVED/Build/Products/Release/sparkle.app/Contents/MacOS/sparkle"
if [[ ! -x "$CLI" ]]; then
    echo "sparkle-cli executable missing after build: $CLI" >&2
    exit 1
fi

codesign --verify --deep --strict "$DERIVED/Build/Products/Release/sparkle.app"
printf '%s\n' "$CLI" | tee "$OUT/sparkle-cli-path.txt"
