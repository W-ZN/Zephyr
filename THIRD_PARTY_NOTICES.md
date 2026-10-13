# Third-party notices

Zephyr is MIT-licensed (see [LICENSE](LICENSE)). The macOS app is built with the Swift packages
below, pinned in [Package.resolved](Package.resolved) and the [macOS project](apps/macos/project.yml). Their code, and the fonts SwaTex bundles,
ship inside `Zephyr.app`. The release disk image carries each package's full license text in its
`Licenses` folder.

| Package | Version | License | Used for |
|---|---|---|---|
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | 0.9.0 | Apache License 2.0 (see its `LICENSE.txt` and `NOTICE.txt`) | Markdown parsing |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | (dependency of swift-markdown) | BSD 2-Clause (see its `COPYING`) | CommonMark / GFM parser |
| [SwaTex](https://github.com/PhraseHQ/SwaTex) | 0.5.0 | MIT | TeX formula layout and rendering |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | MIT (with bundled component notices in its `LICENSE`) | Signed macOS app updates |

SwaTex in turn derives from, and bundles material of:

- **RaTeX** — MIT License, Copyright (c) erweixin.
- **KaTeX** — MIT License, Copyright (c) 2013–2020 Khan Academy and other contributors. The bundled
  KaTeX fonts are licensed under the SIL Open Font License 1.1.
- **mhchem** — MIT License, Copyright (c) Martin Hensel.

See SwaTex's `THIRD_PARTY_NOTICES.md` for details.
