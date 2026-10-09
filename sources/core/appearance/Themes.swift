import Foundation

/// Themes (design §8, §21.7): each one is a complete look, every key of `AppearanceSettings`.
/// Four built-in themes ship with Zephyr: its own design, and three that imitate well-known
/// reading styles under names of their own. Any setting of a built-in can change; the changes are
/// kept as overrides on top of its shipped values, so Restore Defaults always brings it back.
/// Custom themes are JSON files in a folder of the user's choice, so they can be kept, copied and
/// shared like any file. Typefaces are chosen as lists: an open-source family first, a macOS
/// family last, so a theme never depends on a commercial font.
public enum ThemeLibrary {
    public struct Preset: Sendable {
        public let id: String
        public let name: String
        /// One line on what it is like.
        public let summary: String
        public let keys: [String: AppearanceSettings.Value]
    }

    /// The theme a library starts with: Zephyr's own design (design §8.1).
    public static let defaultTheme = "zephyr"

    public static let presets: [Preset] = {
        typealias V = AppearanceSettings.Value
        func levels(_ suffix: String, _ values: [Double]) -> [String: V] {
            Dictionary(uniqueKeysWithValues: values.enumerated().map { ("h\($0.offset + 1).\(suffix)", .number($0.element)) })
        }
        func merge(_ parts: [String: V]...) -> [String: V] { parts.reduce(into: [:]) { $0.merge($1) { _, b in b } } }
        // Zephyr's own: cool paper, green-gray ink and deep teal; the system sans with PingFang, a
        // 56 em column, semibold headings without rules, quiet tables aligned with the text, code
        // on a bordered tint, diagrams drawn in neutral lines (design §8.1).
        let zephyr = merge([
            "palette": .text("zephyr"), "font.body": .text("system"), "font.code": .text("mono"),
            "text.size": .number(16), "text.lineHeight": .number(1.65), "text.width": .number(56),
            "paragraph.spacing": .number(1), "list.indent": .number(1.6), "list.spacing": .number(0.25),
            "headings.lineHeight": .number(1.3), "code.size": .number(0.875), "code.lineHeight": .number(1.55), "code.style": .text("card"),
            "table.width": .text("column"), "table.align": .text("left"), "table.lines": .text("rows"),
            "table.textSize": .number(0.875), "table.padding": .number(0.75),
            "diagram.colors": .text("neutral"), "diagram.style": .text("filled"),
        ], levels("size", [1.875, 1.5, 1.25, 1.0625, 1, 0.875]), levels("weight", [600, 600, 600, 600, 600, 500]),
           levels("spaceAbove", [2.5, 2, 1.5, 1.25, 1, 1]), levels("spaceBelow", [0.625, 0.5, 0.375, 0.25, 0.25, 0.25]))
        // A README on a code host: system sans, wide column, ruled top headings, gridded striped tables.
        let readme = merge([
            "palette": .text("readme"), "font.body": .text("system"), "font.cjk": .text("PingFang SC"), "font.code": .text("mono"),
            "text.size": .number(16), "text.lineHeight": .number(1.5), "text.width": .number(60),
            "paragraph.spacing": .number(1), "list.indent": .number(2), "list.spacing": .number(0.25),
            "headings.lineHeight": .number(1.25), "h1.rule": .flag(true), "h2.rule": .flag(true),
            "code.size": .number(0.85), "code.lineHeight": .number(1.45), "code.style": .text("shaded"),
            "table.lines": .text("grid"), "table.headerShade": .flag(false), "table.stripes": .flag(true),
            "table.textSize": .number(1), "table.padding": .number(0.8125),
            "diagram.colors": .text("neutral"),
        ], levels("size", [2, 1.5, 1.25, 1, 0.875, 0.85]), levels("weight", [600, 600, 600, 600, 600, 600]),
           levels("spaceAbove", [1.5, 1.5, 1.5, 1.5, 1.5, 1.5]), levels("spaceBelow", [1, 1, 1, 1, 1, 1]))
        // A workspace page: quiet sans, tight blocks, soft gray tables, outlined diagrams.
        let notional = merge([
            "palette": .text("notional"), "font.body": .text("system"), "font.cjk": .text("PingFang SC"), "font.code": .text("mono"),
            "text.size": .number(16), "text.lineHeight": .number(1.5), "text.width": .number(58),
            "paragraph.spacing": .number(0.5), "list.indent": .number(1.5), "list.spacing": .number(0.125),
            "headings.lineHeight": .number(1.3), "code.size": .number(0.85), "code.lineHeight": .number(1.5),
            "table.lines": .text("grid"),
            "table.textSize": .number(0.875), "table.padding": .number(0.5625),
            "diagram.colors": .text("neutral"), "diagram.style": .text("outline"),
        ], levels("size", [1.875, 1.5, 1.25, 1.0625, 1, 1]), levels("weight", [600, 600, 600, 600, 600, 600]),
           levels("spaceAbove", [2, 1.375, 1.125, 1, 1, 1]), levels("spaceBelow", [0.25, 0.25, 0.25, 0.25, 0.25, 0.25]))
        // An editorial essay: a bookish serif on warm paper, narrow column, light headings, clay accent.
        let anthology = merge([
            "palette": .text("anthology"),
            "font.body": .text("Newsreader, Source Serif 4, Charter, serif"), "font.cjk": .text("Noto Serif SC, Noto Serif CJK SC, Source Han Serif SC, Songti SC"),
            "font.code": .text("JetBrains Mono, IBM Plex Mono, mono"),
            "text.size": .number(18), "text.lineHeight": .number(1.6), "text.width": .number(50),
            "paragraph.spacing": .number(1), "list.spacing": .number(0.375),
            "headings.lineHeight": .number(1.2), "code.size": .number(0.8), "code.lineHeight": .number(1.55), "code.style": .text("shaded"),
            "table.lines": .text("rows"), "table.headerShade": .flag(false),
            "table.textSize": .number(0.875), "table.padding": .number(0.875),
            "diagram.colors": .text("accent"), "diagram.style": .text("outline"),
        ], levels("size", [2.25, 1.625, 1.3, 1.1, 1, 0.9]), levels("weight", [500, 500, 500, 600, 600, 600]),
           levels("spaceAbove", [2.25, 2, 1.625, 1.375, 1.25, 1.25]), levels("spaceBelow", [0.75, 0.625, 0.5, 0.375, 0.375, 0.375]))
        return [
            Preset(id: "zephyr", name: "Zephyr", summary: "Zephyr's own: cool paper, green-gray ink and deep teal, quiet tables, code on a bordered tint.", keys: zephyr),
            Preset(id: "readme", name: "Readme", summary: "A project README: system sans, a wide column, ruled headings, gridded tables.", keys: readme),
            Preset(id: "notional", name: "Notional", summary: "A workspace page: a quiet sans, tight blocks, soft gray tables.", keys: notional),
            Preset(id: "anthology", name: "Anthology", summary: "An editorial essay: a bookish serif on warm paper, a narrow column.", keys: anthology),
        ]
    }()

    public static func preset(_ id: String) -> Preset? { presets.first { $0.id == id.lowercased() } }

    /// A free name for a theme made from `base`: "Zephyr Custom", then "Zephyr Custom 2", …
    public static func suggestedName(from base: String, in folder: URL) -> String {
        let taken = Set(names(in: folder).map { $0.lowercased() })
        let stem = (preset(base)?.name ?? base) + " Custom"
        var name = stem, n = 2
        while taken.contains(name.lowercased()) {
            name = "\(stem) \(n)"
            n += 1
        }
        return name
    }

    /// Custom themes named like a built-in (the "Zephyr" file every library had before Zephyr was
    /// built in) step aside: one with settings of its own becomes "… Custom", an empty one goes
    /// to the Trash, an unreadable one stays. Returns the new names, old → new.
    @discardableResult
    public static func migrate(in folder: URL) -> [String: String] {
        var moved: [String: String] = [:]
        for name in names(in: folder) where presets.contains(where: { $0.id.caseInsensitiveCompare(name) == .orderedSame || $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            guard let settings = try? load(name, in: folder) else { continue }
            guard !settings.overrides.isEmpty else {
                try? delete(name, in: folder)
                continue
            }
            let target = suggestedName(from: name, in: folder)
            if (try? rename(name, to: target, in: folder)) != nil { moved[name] = target }
        }
        return moved
    }

    // MARK: Custom themes

    public static var defaultFolder: URL { AppearanceState.fileURL.deletingLastPathComponent().appendingPathComponent("Themes") }

    public static func names(in folder: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func file(_ name: String, in folder: URL) -> URL {
        folder.appendingPathComponent(name).appendingPathExtension("json")
    }

    /// A usable name for a new custom theme, or why not.
    public static func check(name raw: String, in folder: URL, allowing current: String? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw AppearanceSettings.SettingError("A theme name is 1–60 characters without / or :.")
        }
        guard preset(name) == nil, !presets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw AppearanceSettings.SettingError("\(name) is a preset's name.")
        }
        if name != current, names(in: folder).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw AppearanceSettings.SettingError("A theme named \(name) already exists.")
        }
        return name
    }

    public static func load(_ name: String, in folder: URL) throws -> AppearanceSettings {
        AppearanceSettings.parse(json: try Data(contentsOf: file(name, in: folder))).settings
    }

    public static func save(_ settings: AppearanceSettings, as name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try settings.json().write(to: file(name, in: folder), options: .atomic)
    }

    public static func rename(_ name: String, to newName: String, in folder: URL) throws {
        try FileManager.default.moveItem(at: file(name, in: folder), to: file(newName, in: folder))
    }

    /// Moves the theme's file to the Trash, never deletes it outright.
    public static func delete(_ name: String, in folder: URL) throws {
        try FileManager.default.trashItem(at: file(name, in: folder), resultingItemURL: nil)
    }
}

/// `appearance.json`: which theme is active, where custom themes live, and what the reader
/// changed in each built-in theme (its overrides). The themes' own keys live in the built-ins and
/// in the custom theme files.
public struct AppearanceState: Equatable, Sendable {
    public var active: String
    public var themesFolder: String?
    /// Per built-in theme, the keys whose value differs from what it ships with.
    public var adjustments: [String: [String: AppearanceSettings.Value]]

    public init(active: String = ThemeLibrary.defaultTheme, themesFolder: String? = nil, adjustments: [String: [String: AppearanceSettings.Value]] = [:]) {
        self.active = active
        self.themesFolder = themesFolder
        self.adjustments = adjustments
    }

    /// `~/Library/Application Support/Zephyr/appearance.json`: the app's own data (design §3.3).
    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zephyr/appearance.json")
    }

    public var folder: URL { themesFolder.map { URL(fileURLWithPath: $0) } ?? ThemeLibrary.defaultFolder }
    public var activePreset: ThemeLibrary.Preset? { ThemeLibrary.preset(active) }

    /// Runs `ThemeLibrary.migrate` on the themes folder; the active theme follows a renamed file,
    /// and a built-in is named by its id.
    public mutating func migrate() {
        if let renamed = ThemeLibrary.migrate(in: folder)[active] { active = renamed } else if let preset = activePreset { active = preset.id }
    }

    /// A built-in theme the reader changed.
    public func isModified(_ id: String) -> Bool { !(adjustments[id.lowercased()] ?? [:]).isEmpty }

    /// The active theme's keys: a built-in with the reader's overrides, or a custom theme's file
    /// (the defaults when the file is missing).
    public func settings() -> AppearanceSettings {
        if let preset = activePreset {
            var s = AppearanceSettings(overrides: preset.keys)
            for (key, value) in adjustments[preset.id] ?? [:] { try? s.set(key, value: value) }
            return s
        }
        return (try? ThemeLibrary.load(active, in: folder)) ?? AppearanceSettings()
    }

    public func json() -> Data {
        var object: [String: Any] = ["active": active]
        if let themesFolder { object["themesFolder"] = themesFolder }
        if !adjustments.isEmpty { object["adjustments"] = adjustments.mapValues { $0.mapValues(AppearanceSettings.jsonValue) } }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    public static func parse(json data: Data) -> AppearanceState {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return AppearanceState() }
        // As written: "Zephyr" may still name the custom theme of before Zephyr was built in, which
        // `ThemeLibrary.migrate` renames; the app then names a built-in by its id.
        var state = AppearanceState(active: object["active"] as? String ?? ThemeLibrary.defaultTheme, themesFolder: object["themesFolder"] as? String)
        // Each value checked like any setting, but kept even when it equals the global default:
        // in a built-in that differs, the default is a choice too.
        for (id, raw) in object["adjustments"] as? [String: [String: Any]] ?? [:] {
            var kept: [String: AppearanceSettings.Value] = [:]
            for (key, json) in AppearanceSettings.migrated(raw) where AppearanceSettings.spec(key) != nil {
                var scratch = AppearanceSettings()
                guard let value = AppearanceSettings.value(json: json), (try? scratch.set(key, value: value)) != nil, let checked = scratch.value(key) else { continue }
                kept[key] = checked
            }
            if !kept.isEmpty { state.adjustments[id] = kept }
        }
        return state
    }

    public static func load(from url: URL = fileURL) -> AppearanceState? {
        (try? Data(contentsOf: url)).map(parse)
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json().write(to: url, options: .atomic)
    }

    // MARK: Changing the active theme

    /// Apply `change` to the active theme: a built-in keeps it as overrides of its own values, a
    /// custom theme writes its file. Returns the theme's new settings.
    public mutating func change(_ change: (inout AppearanceSettings) throws -> Void) throws -> AppearanceSettings {
        var next = settings()
        let before = next
        try change(&next)
        if let preset = activePreset {
            let changed = Set(next.overrides.keys).union(before.overrides.keys).filter { next.overrides[$0] != before.overrides[$0] }
            // Kept as the value in effect: choosing the global default in a built-in that differs is a choice too.
            var adjusted = adjustments[preset.id] ?? [:]
            let original = AppearanceSettings(overrides: preset.keys)
            for key in changed {
                let value = next.value(key)
                adjusted[key] = value == original.value(key) ? nil : value
            }
            adjustments[preset.id] = adjusted.isEmpty ? nil : adjusted
        } else {
            try ThemeLibrary.save(next, as: active, in: folder)
        }
        return next
    }

    /// A built-in theme back to what it ships with.
    public mutating func restore(_ id: String) throws {
        guard let preset = ThemeLibrary.preset(id) else { throw AppearanceSettings.SettingError("\(id) is not a built-in theme; only built-ins have defaults to restore.") }
        adjustments[preset.id] = nil
    }
}
