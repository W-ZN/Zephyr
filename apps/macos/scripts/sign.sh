#!/bin/bash
# Inside-out signing without an Apple developer account (design §4.1): CLI helper, the
# sandboxed Quick Look extension, then the app; hardened runtime everywhere.
set -euo pipefail
APP="$1"
ROOT="${ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
KEYCHAIN="$ROOT/.signing/zephyr-dev.keychain-db"
IDENTITY="-"
KC_ARGS=()
# ADHOC=1 (release builds): ad-hoc even when the local identity exists, so a published app carries
# no machine-specific certificate.
if [ "${ADHOC:-0}" != 1 ] && [ -f "$KEYCHAIN" ]; then
    security unlock-keychain -p "$(cat "$ROOT/.signing/keychain-password")" "$KEYCHAIN"
    IDENTITY="Zephyr Local Signing"
    KC_ARGS=(--keychain "$KEYCHAIN")
fi
sign() { codesign --force --options runtime --timestamp=none --sign "$IDENTITY" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$@"; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP/Contents/Helpers/zephyr"
sign --entitlements "$ROOT/apps/macos/quick-look/quick-look.entitlements" "$APP/Contents/PlugIns/ZephyrQuickLook.appex"
sign --entitlements "$ROOT/apps/macos/app/Zephyr.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed with: $IDENTITY"
