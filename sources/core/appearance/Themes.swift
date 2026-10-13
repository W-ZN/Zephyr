import Foundation

/// Themes (design §8, §21.7): each one is a complete look, every key of `AppearanceSettings`.
/// Four built-in themes ship with Zephyr: its own design, and three that imitate well-known
/// reading styles under names of their own. Any setting of a built-in can change; the changes are
/// saved as complete JSON snapshots alongside custom themes, so Restore Defaults always brings it
/// back. Custom themes are JSON files in a folder of the user's choice, so they can be kept, copied
/// and shared like any file. Typefaces are chosen as lists: an open-source family first, a macOS
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
            "table.width": .text("fit"), "table.align": .text("left"), "table.lines": .text("rows"),
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
            guard let settings = try? loadTheme(at: file(name, in: folder), named: name) else { continue }
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

    /// The subfolder for the four editable built-in snapshots. `file` deliberately remains the
    /// root-level custom-theme path: migration must still find old custom files named "Zephyr".
    public static func builtInFolder(in folder: URL) -> URL {
        folder.appendingPathComponent("Built-in", isDirectory: true)
    }

    /// Changes to the shipped built-in values, oldest first. Built-in files are complete snapshots,
    /// so a value an earlier version shipped would otherwise stay after an update; each change moves
    /// a key that still holds its old shipped value, and leaves a value the reader chose.
    public static let shippedChanges: [(key: String, from: AppearanceSettings.Value, to: AppearanceSettings.Value)] = [
        ("table.width", .text("column"), .text("fit")),   // 0.1.2: small tables keep their natural width
    ]

    /// How many of `shippedChanges` the built-in files in `folder` already include.
    static func revisionFile(in folder: URL) -> URL {
        builtInFolder(in: folder).appendingPathComponent(".revision")
    }

    /// The persistent file for any theme. Built-in IDs live apart from root-level custom files.
    public static func themeFile(_ name: String, in folder: URL) -> URL {
        guard let preset = preset(name) else { return file(name, in: folder) }
        return builtInFolder(in: folder).appendingPathComponent(preset.id).appendingPathExtension("json")
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
        try loadTheme(at: themeFile(name, in: folder), named: name)
    }

    private static func loadTheme(at path: URL, named name: String) throws -> AppearanceSettings {
        let data = try Data(contentsOf: path)
        let parsed = AppearanceSettings.parse(json: data)
        guard parsed.problems.isEmpty else {
            throw AppearanceSettings.SettingError("Could not read theme \(name): \(parsed.problems.joined(separator: "; "))")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AppearanceSettings.SettingError("Could not read theme \(name): Not a JSON object.")
        }
        var values = parsed.settings.overrides
        for (key, raw) in AppearanceSettings.migrated(object) {
            guard let defaultValue = AppearanceSettings.spec(key)?.defaultValue,
                  AppearanceSettings.value(json: raw) == defaultValue else { continue }
            values[key] = nil
        }
        return AppearanceSettings(overrides: values)
    }

    /// Writes every effective value so a future change to global defaults cannot change a saved
    /// theme. Values whose effective value is `auto` remain absent by definition.
    public static func saveTheme(_ settings: AppearanceSettings, as name: String, in folder: URL) throws {
        let path = themeFile(name, in: folder)
        try writeSnapshot(settings, to: path)
    }

    private static func writeSnapshot(_ settings: AppearanceSettings, to path: URL) throws {
        let values = Dictionary(uniqueKeysWithValues: AppearanceSettings.specs.compactMap { spec in
            settings.value(spec.key).map { (spec.key, $0) }
        })
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AppearanceSettings(overrides: values).json().write(to: path, options: .atomic)
    }

    /// Compatibility spelling for root-level custom and legacy theme files. It intentionally does
    /// not resolve a built-in name, so migration can still create and move an old "Zephyr.json".
    public static func save(_ settings: AppearanceSettings, as name: String, in folder: URL) throws {
        try writeSnapshot(settings, to: file(name, in: folder))
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
    public func isModified(_ id: String) -> Bool { !currentOverrides(id).isEmpty }

    private func legacySettings(for preset: ThemeLibrary.Preset) -> AppearanceSettings {
        var settings = AppearanceSettings(overrides: preset.keys)
        for (key, value) in adjustments[preset.id] ?? [:] { try? settings.set(key, value: value) }
        return settings
    }

    private func builtInSettings(_ preset: ThemeLibrary.Preset) throws -> AppearanceSettings {
        let path = ThemeLibrary.themeFile(preset.id, in: folder)
        return FileManager.default.fileExists(atPath: path.path) ? try ThemeLibrary.load(preset.id, in: folder) : legacySettings(for: preset)
    }

    /// The active theme read strictly from its file when it has one. Callers that watch theme files
    /// use this to retain their last good appearance after a manual JSON edit goes wrong.
    public func loadedSettings() throws -> AppearanceSettings {
        if let preset = activePreset { return try builtInSettings(preset) }
        let path = ThemeLibrary.themeFile(active, in: folder)
        return FileManager.default.fileExists(atPath: path.path) ? try ThemeLibrary.load(active, in: folder) : AppearanceSettings()
    }

    /// The active theme's keys. This remains a pure, non-throwing convenience API for old callers;
    /// an invalid manually edited file falls back to the last compatible state held in appearance.json.
    public func settings() -> AppearanceSettings {
        if let settings = try? loadedSettings() { return settings }
        return activePreset.map { legacySettings(for: $0) } ?? AppearanceSettings()
    }

    /// Creates each missing built-in snapshot from the complete current effective settings. Existing
    /// files are user data and are never rewritten here.
    /// Files written by an earlier version first take the shipped changes since then; one that does
    /// not read is left as it is.
    public mutating func prepareThemeFiles() throws {
        let revisionFile = ThemeLibrary.revisionFile(in: folder)
        let revision = (try? String(contentsOf: revisionFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let pending = ThemeLibrary.shippedChanges.dropFirst(revision)
        for preset in ThemeLibrary.presets {
            let path = ThemeLibrary.themeFile(preset.id, in: folder)
            guard FileManager.default.fileExists(atPath: path.path) else {
                try ThemeLibrary.saveTheme(legacySettings(for: preset), as: preset.id, in: folder)
                continue
            }
            guard !pending.isEmpty, var settings = try? ThemeLibrary.load(preset.id, in: folder) else { continue }
            let before = settings
            for change in pending where settings.value(change.key) == change.from { try settings.set(change.key, value: change.to) }
            if settings != before { try ThemeLibrary.saveTheme(settings, as: preset.id, in: folder) }
        }
        if revision != ThemeLibrary.shippedChanges.count {
            try String(ThemeLibrary.shippedChanges.count).write(to: revisionFile, atomically: true, encoding: .utf8)
        }
    }

    /// Values of a built-in file relative to what ships with the app. A present file is authoritative
    /// over legacy adjustments; malformed files are left untouched and fall back only for this
    /// non-throwing status query.
    public func currentOverrides(_ id: String) -> [String: AppearanceSettings.Value] {
        guard let preset = ThemeLibrary.preset(id) else { return [:] }
        let settings = (try? builtInSettings(preset)) ?? legacySettings(for: preset)
        let shipped = AppearanceSettings(overrides: preset.keys)
        return Dictionary(uniqueKeysWithValues: AppearanceSettings.specs.compactMap { spec in
            guard let value = settings.value(spec.key), value != shipped.value(spec.key) else { return nil }
            return (spec.key, value)
        })
    }

    /// Replaces a built-in's overrides relative to its shipped values. When its prepared file exists,
    /// the replacement is written as a complete snapshot; an invalid file is never overwritten.
    public mutating func setOverrides(_ overrides: [String: AppearanceSettings.Value]?, for id: String) throws {
        guard let preset = ThemeLibrary.preset(id) else { throw AppearanceSettings.SettingError("\(id) is not a built-in theme.") }
        let path = ThemeLibrary.themeFile(preset.id, in: folder)
        if FileManager.default.fileExists(atPath: path.path) { _ = try ThemeLibrary.load(preset.id, in: folder) }
        var next = AppearanceSettings(overrides: preset.keys)
        for (key, value) in overrides ?? [:] { try next.set(key, value: value) }
        if FileManager.default.fileExists(atPath: path.path) { try ThemeLibrary.saveTheme(next, as: preset.id, in: folder) }
        adjustments[preset.id] = overrides?.isEmpty == false ? overrides : nil
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

    /// Apply `change` to the active theme. A prepared built-in writes its complete snapshot and also
    /// keeps legacy adjustments compatible; an unprepared built-in keeps the old in-memory behavior.
    public mutating func change(_ change: (inout AppearanceSettings) throws -> Void) throws -> AppearanceSettings {
        var next = try loadedSettings()
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
            let path = ThemeLibrary.themeFile(preset.id, in: folder)
            if FileManager.default.fileExists(atPath: path.path) {
                try ThemeLibrary.saveTheme(next, as: preset.id, in: folder)
                let fileOverrides = currentOverrides(preset.id)
                adjustments[preset.id] = fileOverrides.isEmpty ? nil : fileOverrides
            }
        } else {
            try ThemeLibrary.saveTheme(next, as: active, in: folder)
        }
        return next
    }

    /// A built-in theme back to what it ships with.
    public mutating func restore(_ id: String) throws {
        guard let preset = ThemeLibrary.preset(id) else { throw AppearanceSettings.SettingError("\(id) is not a built-in theme; only built-ins have defaults to restore.") }
        let path = ThemeLibrary.themeFile(preset.id, in: folder)
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try ThemeLibrary.load(preset.id, in: folder)
            try ThemeLibrary.saveTheme(AppearanceSettings(overrides: preset.keys), as: preset.id, in: folder)
        }
        adjustments[preset.id] = nil
    }
}
