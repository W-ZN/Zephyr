// swift-tools-version: 6.1
import PackageDescription

// Shared libraries for every Zephyr client. Platform hosts live in apps/<platform>.
//   sources/core    ZephyrCore    portable: bytes, positions, Markdown structure, search (Foundation only)
//   sources/layout  ZephyrLayout  portable: layout units, height map, scroll anchors for the block canvas
//   sources/render  ZephyrRender  Core Text block canvas and AppKit editing controls
//   tests/<module> unit tests per module; tests/fixtures shared sample documents
let package = Package(
    name: "Zephyr",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ZephyrCore", targets: ["ZephyrCore"]),
        .library(name: "ZephyrLayout", targets: ["ZephyrLayout"]),
        .library(name: "ZephyrRender", targets: ["ZephyrRender"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
        .package(url: "https://github.com/PhraseHQ/SwaTex.git", exact: "0.5.0"),
    ],
    targets: [
        .target(
            name: "ZephyrCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            path: "sources/core"
        ),
        .target(name: "ZephyrLayout", path: "sources/layout"),
        .target(
            name: "ZephyrRender",
            dependencies: [
                "ZephyrCore",
                "ZephyrLayout",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwaTex", package: "SwaTex"),
                .product(name: "SwaTexRender", package: "SwaTex"),
            ],
            path: "sources/render",
            // Preserve the renderer's language mode while removing the legacy document engine;
            // AppKit components and text-input delegates still cross actor-isolation boundaries.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ZephyrCoreTests", dependencies: ["ZephyrCore"], path: "tests/core"),
        .testTarget(name: "ZephyrLayoutTests", dependencies: ["ZephyrLayout"], path: "tests/layout"),
        .testTarget(name: "ZephyrRenderTests", dependencies: ["ZephyrRender"], path: "tests/render", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
