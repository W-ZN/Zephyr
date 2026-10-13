# Contributing to Zephyr

Thanks for your interest. Zephyr is a small, opinionated app: before larger changes, please open an issue to talk through the idea. How each part behaves is described in the [user guide](docs/guide.md).

## Building and checking

Requires macOS 15 or later and Xcode 27 (Swift 6.4). No Apple developer account is needed. Python 3 (standard library only) runs the end-to-end checks.

```bash
make test           # unit tests for the shared libraries (SwiftPM)
make build          # fetch the pinned XcodeGen, generate the Xcode project, build Release, sign, move to dist/Zephyr.app
make window-check   # AppKit window routing, sidebar and rail checks (after make build)
make save-check     # byte-exact saves through the packaged app (BOM, CRLF, mixed line breaks, invalid UTF-8)
make agent-check    # agent access through the packaged app and CLI: read, search, proposals, refusal
make run            # run the packaged app; its preferences and state stay in build.noindex/home
make xcode          # open the generated Xcode project
```

Optional:

```bash
make signing-init   # create a self-signed identity in .signing/ so rebuilt apps keep a stable signature
make dmg            # release disk image: dist/Zephyr-<version>.dmg, signed ad-hoc, with license texts
make appcast        # package, then sign dist/appcast.xml with the Sparkle key in the login Keychain
make install        # copy the packaged app to ~/Applications
```

Please run `make test` and, for app-level changes, `make build window-check save-check` before sending a pull request.

## Publishing macOS updates

The macOS target pins Sparkle in `apps/macos/project.yml`. Keep `CFBundleVersion` monotonically increasing, and keep the bundle identifier and `SUPublicEDKey` stable so existing installations can update. The first updater-enabled release is 0.1.2; older versions need one manual installation.

The current local/ad-hoc distribution has no Apple Team ID. Its main app carries the explicitly approved `disable-library-validation` entitlement so macOS can load the bundled Sparkle framework; this relaxes process library validation, while signed-feed and pre-extraction update verification remain mandatory. Quick Look and the CLI do not receive this entitlement. When switching to Developer ID signing for the whole bundle, remove this exception and verify the packaged launch again.

Sparkle's signing tools are resolved with the Xcode dependencies under `build.noindex/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`. The release key is in the login Keychain under account `dev.zephyr.Zephyr`. Back it up securely with the vendor's `generate_keys -x` command; never commit or upload the exported private key. A new machine must import the same key, not silently generate a replacement. The app embeds only the public key.

After the tests and packaged app launch pass, run `make appcast`. It produces the versioned DMG, checksum and signed `dist/appcast.xml`. Create a draft GitHub release for the matching source tag, upload all three files, and publish only after the complete set is present. The app reads `releases/latest/download/appcast.xml`; each feed enclosure points to the immutable versioned release URL. Never edit the feed or DMG after signing. Configuration remains outside the app bundle and must not be included in an update archive.

Build output stays inside the checkout, in two places. `dist/` is what is kept: the packaged products at its top (today `dist/Zephyr.app` and the release disk image, later other platforms' packages beside them) and `dist/archive/` for everything retained. The build moves the app there out of Xcode's build folder, so it is the active Zephyr.app: the copy that runs, is tested and is registered with macOS. `build.noindex/` (below) holds only what the build can make again and can be deleted at any time; `.signing/` holds the local signing identity.

## Repository layout

```text
.
├── Package.swift        SwiftPM manifest for the shared libraries
├── Makefile             build, test, and run entry points
├── sources/             shared libraries, one folder per module
│   ├── core/            ZephyrCore: bytes, structure, search, edits, the HTML subset and badges (web/), document tools, AI client, agent IPC, the app pages' notes (Foundation only)
│   ├── layout/          ZephyrLayout: block layout core: layout units, prefix sums, height map, reading anchor (Foundation only)
│   └── render/          ZephyrRender: Core Text block canvas, printing, design tokens and flat controls for Apple platforms
│       ├── canvas/      the block canvas: units and their layout, the rendered presentation, caret navigation, blank lines
│       ├── editing/     editing commands, block moves, the slash menu, attached editors (tables, formulas, properties)
│       ├── components/  tables, formulas, images, diagrams, HTML blocks and badges, and their renderers
│       ├── theme/       typography, palette, custom CSS
│       ├── controls/    design tokens, flat controls, spring motion
│       └── output/      printing, read-only snippets
├── apps/                one host app per client platform
│   └── macos/           AppKit app, Quick Look extension, zephyr CLI, XcodeGen spec, signing and packaging scripts
│       └── app/         entry, menus, the document, launch modes, preferences and resources; window/, sidebar/,
│                        pages/ (the app's pages), settings/, assistant/ (AI panel, agent access, reviews, keys)
├── tests/               all tests and test inputs
│   ├── core/            ZephyrCoreTests
│   ├── layout/          ZephyrLayoutTests (randomized edits against invariants)
│   ├── render/          ZephyrRenderTests (block-canvas editing, layout, drawing and PDF checks)
│   ├── save/            byte-exact save check through the built app
│   ├── agent/           CLI / MCP end-to-end check through the built app
│   ├── bench/           corpus generator and benchmark runner
│   └── fixtures/        sample documents for tests and snapshots
├── docs/                user guide and README images
│
│   Not committed (git-ignored), made by the Makefile:
├── dist/                what is kept: Zephyr.app (what make run, the checks and macOS use), the release disk image
│   └── archive/         retained, never rebuilt: apps/ (older packages, zipped), verification/ (evidence per round),
│                        design-assets/ (icon and mascot drafts), history/ (old material and source backups)
├── build.noindex/       what the build can make again; safe to delete
│   ├── DerivedData/     Xcode intermediates (the built app is moved out to dist/)
│   ├── spm/             SwiftPM scratch, cache, config and security folders
│   ├── tools/           the pinned XcodeGen
│   ├── home/            the app's preferences and data when run from here
│   ├── output/          what make save-check, agent-check, bench, corpus, snapshot and the unit tests write
│   └── dmg/             disk image staging
└── .signing/            the local self-signed identity
```

Planned slots, added when the work starts:

| Path | Purpose |
|---|---|
| `apps/ios/` | UIKit host reusing ZephyrCore and ZephyrRender |
| `apps/windows/`, `apps/linux/` | Native hosts built on ZephyrCore and ZephyrLayout; the canvas needs the platform's text shaper (DirectWrite, Pango / HarfBuzz) in place of Core Text |
| `sources/<module>/` | New shared modules |

## Conventions

- **Directories** use lowercase kebab-case (`quick-look`, `fixtures`). A module's folder is its target name without the `Zephyr` prefix: `sources/render` is ZephyrRender, and `tests/render` is ZephyrRenderTests. Inside a module or app, files are grouped by responsibility into subfolders (above); a new file goes into the one it belongs to.
- **Files** follow their language. A Swift file is named after the main type it declares, in PascalCase (`MarkdownAnalyzer.swift`). Scripts, docs, and configuration files use lowercase kebab-case (`signing-init.sh`, `guide.md`, `quick-look.entitlements`).
- **Tool-mandated names** keep the spelling their tools require: `Package.swift`, `Package.resolved`, `Makefile`, `Info.plist`, `main.swift`, `README.md`.
- **Portability:** `sources/core` and `sources/layout` depend only on Foundation and pure-Swift packages. AppKit, UIKit, and Core Text belong in renderer modules or under `apps/<platform>/`.
- **Generated files** stay out of the source tree. The only exception is the Xcode project, which XcodeGen writes next to its spec in `apps/macos/` and git ignores.
