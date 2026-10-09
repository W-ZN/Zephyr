#!/bin/zsh
set -euo pipefail

# Uses the app's actual sources and the shared objects from a Release build.
root=${0:A:h:h:h}
products="$root/build.noindex/DerivedData/Build/Products/Release"
checkouts="$root/build.noindex/DerivedData/SourcePackages/checkouts"
out="$root/build.noindex/output/window-check"
mkdir -p "$out/home"
sources=("$root"/apps/macos/app/**/*.swift)
sources=(${sources:#*/main.swift})

xcrun swiftc -parse-as-library -swift-version 5 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macos15.0" -I "$products" \
    -I "$checkouts/swift-cmark/src/include" \
    -I "$checkouts/swift-cmark/extensions/include" \
    -I "$checkouts/swift-markdown/Sources/CAtomic/include" \
    "${sources[@]}" "$root/tests/window/WindowInteractionCheck.swift" \
    "$products"/*.o -lz -o "$out/check-window"
CFFIXED_USER_HOME="$out/home" "$out/check-window"
