import Foundation

/// Themes and their settings for `zephyr config`, `zephyr theme`, MCP clients and the built-in
/// assistant (design §21.7). Every entry runs these commands and prints the same text. They edit
/// the files the app watches, appearance.json and the theme files; the running app applies a
/// change within a moment and offers to undo it.
public enum AppearanceCommands {
    public typealias Failure = AppearanceSettings.SettingError

    public static let usage = """
    usage: zephyr config list [prefix] [--json]    the active theme's settings, with defaults and ranges
           zephyr config get <key>
           zephyr config set <key> <value> [<key> <value>...]   (or key=value; value "default" resets)
           zephyr config reset <key|prefix.|all>...
           (add --theme NAME to read or change a theme that is not active)
           zephyr theme list                       built-in themes and yours, the active one marked *
           zephyr theme use <name>
           zephyr theme new <name> [--from <theme>]   a copy of a theme as it is now, changes included
           zephyr theme restore <built-in>         a built-in theme back to what it ships with
           zephyr theme rename <name> <new name>
           zephyr theme delete <name>              moves the theme's file to the Trash
           zephyr theme folder [path|--default]    where your themes live
    """

    /// Runs a `config` or `theme` command against the state file at `url`.
    public static func run(_ arguments: [String], url: URL = AppearanceState.fileURL) throws -> String {
        var state = AppearanceState.load(from: url) ?? AppearanceState()
        state.migrate()
        let original = state
        let activeBefore = state.settings()
        var words = arguments
        var theme: String?
        if let i = words.firstIndex(of: "--theme") {
            guard i + 1 < words.count else { throw Failure("--theme takes a theme name.") }
            theme = try resolve(words[i + 1], state)
            words.removeSubrange(i...i + 1)
        }
        let json = words.contains("--json")
        words.removeAll { $0 == "--json" }
        guard let group = words.first else { throw Failure(usage) }
        let command = words.count > 1 ? words[1] : "list"
        let rest = Array(words.dropFirst(2))
        let output: String
        switch (group, command) {
        case ("config", "list"):
            output = json ? listJSON(theme ?? state.active, state, prefix: rest.first ?? "") : list(theme ?? state.active, state, prefix: rest.first ?? "")
        case ("config", "get"):
            guard let key = rest.first, rest.count == 1 else { throw Failure("usage: zephyr config get <key>") }
            output = try get(key, theme: theme ?? state.active, state)
        case ("config", "set"):
            output = try apply(set: pairs(rest), reset: [], theme: theme, &state)
        case ("config", "reset"):
            guard !rest.isEmpty else { throw Failure("usage: zephyr config reset <key|prefix.|all>...") }
            output = try apply(set: [], reset: rest, theme: theme, &state)
        case ("theme", "list"):
            output = themes(state)
        case ("theme", "use"):
            guard let name = rest.first, rest.count == 1 else { throw Failure("usage: zephyr theme use <name>") }
            state.active = try resolve(name, state)
            output = "Now using \(display(state.active))."
        case ("theme", "new"):
            output = try newTheme(rest, &state)
        case ("theme", "restore"):
            guard let name = rest.first, rest.count == 1 else { throw Failure("usage: zephyr theme restore <built-in>") }
            let id = try resolve(name, state)
            try state.restore(id)
            output = "\(display(id)) is back to its defaults."
        case ("theme", "rename"):
            guard rest.count == 2 else { throw Failure("usage: zephyr theme rename <name> <new name>") }
            let old = try resolve(rest[0], state)
            guard ThemeLibrary.preset(old) == nil else { throw Failure("\(display(old)) is built in; built-in themes keep their names.") }
            let name = try ThemeLibrary.check(name: rest[1], in: state.folder, allowing: old)
            try ThemeLibrary.rename(old, to: name, in: state.folder)
            if state.active == old { state.active = name }
            output = "Renamed \(old) to \(name)."
        case ("theme", "delete"):
            guard let raw = rest.first, rest.count == 1 else { throw Failure("usage: zephyr theme delete <name>") }
            output = try delete(try resolve(raw, state), &state)
        case ("theme", "folder"):
            output = try folder(rest.first, &state)
        default:
            throw Failure(usage)
        }
        if state != original {
            try state.save(to: url)
        }
        if url == AppearanceState.fileURL, !PreviewAppearance.isIsolatedRun, state.settings() != activeBefore { try PreviewAppearance.publish(state.settings()) }
        return output
    }

    // MARK: Reading

    static func display(_ theme: String) -> String { ThemeLibrary.preset(theme)?.name ?? theme }

    /// A preset id or a custom theme, matched without regard to case.
    static func resolve(_ raw: String, _ state: AppearanceState) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let preset = ThemeLibrary.presets.first(where: { $0.id.caseInsensitiveCompare(name) == .orderedSame || $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return preset.id
        }
        let customs = ThemeLibrary.names(in: state.folder)
        if let custom = customs.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return custom }
        throw Failure("No theme named \(name). Themes: \((ThemeLibrary.presets.map(\.id) + customs).joined(separator: ", ")).")
    }

    static func settings(of theme: String, _ state: AppearanceState) -> AppearanceSettings {
        var probe = state
        probe.active = theme
        return probe.settings()
    }

    static func header(_ theme: String, _ state: AppearanceState) -> String {
        let active = theme == state.active ? ", active" : ""
        if let preset = ThemeLibrary.preset(theme) {
            let modified = state.isModified(preset.id) ? ", modified" : ""
            return "\(preset.name) (built-in\(active)\(modified)): \(preset.summary) Changes are kept as overrides; zephyr theme restore \(preset.id) brings back its defaults."
        }
        return "\(theme) (custom theme\(active)): \(ThemeLibrary.file(theme, in: state.folder).path)"
    }

    static func list(_ theme: String, _ state: AppearanceState, prefix: String) -> String {
        header(theme, state) + "\n" + settings(of: theme, state).describe(prefix: prefix)
    }

    static func listJSON(_ theme: String, _ state: AppearanceState, prefix: String) -> String {
        let s = settings(of: theme, state)
        var keys: [String: Any] = [:]
        for spec in AppearanceSettings.specs where spec.key.hasPrefix(prefix) {
            var entry: [String: Any] = ["kind": spec.kindName, "help": spec.help]
            entry["value"] = s.value(spec.key).map(AppearanceSettings.jsonValue) ?? "auto"
            entry["default"] = spec.defaultValue.map(AppearanceSettings.jsonValue) ?? "auto"
            keys[spec.key] = entry
        }
        let object: [String: Any] = ["theme": display(theme), "builtIn": ThemeLibrary.preset(theme) != nil, "modified": state.isModified(theme), "active": theme == state.active, "settings": keys]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func get(_ key: String, theme: String, _ state: AppearanceState) throws -> String {
        guard let spec = AppearanceSettings.spec(key) else { throw Failure(AppearanceSettings.unknown(key)) }
        let s = settings(of: theme, state)
        // Text values (the CSS) print in full; the rest as their describe line.
        if spec.kind == .text { return s.string(key) }
        return s.describe(spec)
    }

    static func themes(_ state: AppearanceState) -> String {
        var lines = ["Built-in themes"]
        for p in ThemeLibrary.presets {
            lines.append("\(state.active == p.id ? "*" : " ") \(p.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(p.name)\(state.isModified(p.id) ? " (modified)" : ""): \(p.summary)")
        }
        lines.append("Your themes (\(state.folder.path))")
        for name in ThemeLibrary.names(in: state.folder) { lines.append("\(state.active == name ? "*" : " ") \(name)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Changing

    /// `key value key value`, or `key=value` words.
    static func pairs(_ words: [String]) throws -> [(String, String)] {
        var result: [(String, String)] = []
        var i = 0
        while i < words.count {
            if let eq = words[i].firstIndex(of: "="), eq != words[i].startIndex {
                result.append((String(words[i][..<eq]), String(words[i][words[i].index(after: eq)...])))
                i += 1
            } else {
                guard i + 1 < words.count else { throw Failure("\(words[i]) needs a value.") }
                result.append((words[i], words[i + 1]))
                i += 2
            }
        }
        guard !result.isEmpty else { throw Failure("usage: zephyr config set <key> <value> [<key> <value>...]") }
        return result
    }

    /// Sets and resets keys of `theme` (the active one when nil) in one step: all of them, or none
    /// when one is refused. A reset returns a key to the theme's own value: the default in a
    /// custom theme, the shipped value in a built-in.
    public static func apply(set: [(String, String)], reset: [String], theme: String?, _ state: inout AppearanceState) throws -> String {
        var probe = state
        if let theme { probe.active = theme }
        let base = probe.activePreset.map { AppearanceSettings(overrides: $0.keys) } ?? AppearanceSettings()
        var touched: [String] = []
        let result = try probe.change { s in
            for (key, raw) in set {
                try s.set(key, raw)
                touched.append(key)
            }
            for item in reset {
                let keys: [String]
                if item == "all" || item == "--all" {
                    keys = AppearanceSettings.specs.map(\.key)
                } else if item.hasSuffix(".") {
                    keys = AppearanceSettings.specs.map(\.key).filter { $0.hasPrefix(item) }
                    guard !keys.isEmpty else { throw Failure("No settings start with \(item)") }
                } else {
                    guard AppearanceSettings.spec(item) != nil else { throw Failure(AppearanceSettings.unknown(item)) }
                    keys = [item]
                }
                for key in keys {
                    let before = s.value(key)
                    if let value = base.value(key), base.isSet(key) { try s.set(key, value: value) } else { try s.reset(key) }
                    if s.value(key) != before { touched.append(key) }
                }
            }
        }
        state.adjustments = probe.adjustments
        let shown = touched.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(40)
        let lines = shown.compactMap { AppearanceSettings.spec($0).map(result.describe) }
        return ([header(probe.active, state)] + (lines.isEmpty ? ["Nothing changed."] : lines)).joined(separator: "\n")
    }

    static func newTheme(_ words: [String], _ state: inout AppearanceState) throws -> String {
        var words = words
        var source: String?
        if let i = words.firstIndex(of: "--from") {
            guard i + 1 < words.count else { throw Failure("--from takes a theme name.") }
            source = try resolve(words[i + 1], state)
            words.removeSubrange(i...i + 1)
        }
        guard !words.isEmpty else { throw Failure("usage: zephyr theme new <name> [--from <theme>]") }
        let name = try ThemeLibrary.check(name: words.joined(separator: " "), in: state.folder)
        let from = source ?? ThemeLibrary.defaultTheme
        try ThemeLibrary.save(settings(of: from, state), as: name, in: state.folder)
        state.active = name
        return "Created \(name) from \(display(from)) and made it active: \(ThemeLibrary.file(name, in: state.folder).path)"
    }

    static func delete(_ name: String, _ state: inout AppearanceState) throws -> String {
        guard ThemeLibrary.preset(name) == nil else { throw Failure("\(display(name)) is built in and cannot be deleted; zephyr theme restore \(name) brings back its defaults.") }
        try ThemeLibrary.delete(name, in: state.folder)
        var note = ""
        if state.active == name {
            state.active = ThemeLibrary.defaultTheme
            note = " Now using \(display(state.active))."
        }
        return "Moved \(name) to the Trash.\(note)"
    }

    static func folder(_ argument: String?, _ state: inout AppearanceState) throws -> String {
        guard let argument else { return state.folder.path }
        if argument == "--default" {
            state.themesFolder = nil
        } else {
            let url = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath).standardizedFileURL
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            state.themesFolder = url.path
        }
        // A custom theme left behind in the old folder is not available here: the built-in takes over.
        if state.activePreset == nil, !ThemeLibrary.names(in: state.folder).contains(state.active) {
            state.active = ThemeLibrary.defaultTheme
        }
        return "Themes now live in \(state.folder.path)."
    }
}

/// The appearance as two tools for MCP clients and the built-in assistant (design §21.7): read
/// the settings, change them. Results are the CLI's text.
public enum AppearanceTools {
    public static let names = ["get_appearance", "set_appearance"]

    public static func definition(_ name: String) -> (description: String, schema: [String: Any]) {
        if name == "get_appearance" {
            return ("How documents look in Zephyr: the active theme (or `theme`), its settings with values, defaults, ranges and help, and the themes there are. prefix narrows the keys, e.g. \"h2.\", \"table.\", \"diagram.\". Call this before set_appearance.",
                    ["type": "object", "properties": ["prefix": ["type": "string"], "theme": ["type": "string"]], "required": [String]()])
        }
        return ("Change how documents look in Zephyr (never the files): settings of the active theme, or of `theme`; `use` switches the active theme first. Values are checked against the ranges get_appearance lists; \"default\" resets one to the theme's own value. A built-in theme keeps changes as overrides the user can restore. The user can undo.",
                ["type": "object", "properties": [
                    "set": ["type": "object", "description": "key: value, e.g. {\"h2.size\": 1.6, \"table.lines\": \"grid\"}", "additionalProperties": ["type": ["string", "number", "boolean"]]],
                    "reset": ["type": "array", "items": ["type": "string"], "description": "Keys or prefixes ending in \".\" back to the theme's own values."],
                    "theme": ["type": "string"], "use": ["type": "string"],
                ], "required": [String]()])
    }

    /// Runs a tool call; model output is untrusted, so wrong types are refused, never coerced.
    public static func run(_ name: String, arguments a: [String: Any], url: URL = AppearanceState.fileURL) -> (text: String, isError: Bool) {
        do {
            var state = AppearanceState.load(from: url) ?? AppearanceState()
            state.migrate()
            let original = state
            let activeBefore = state.settings()
            var theme: String?
            if let raw = a["theme"] {
                guard let t = raw as? String else { throw AppearanceCommands.Failure("theme must be a string.") }
                theme = try AppearanceCommands.resolve(t, state)
            }
            switch name {
            case "get_appearance":
                var prefix = ""
                if let raw = a["prefix"] {
                    guard let p = raw as? String else { throw AppearanceCommands.Failure("prefix must be a string.") }
                    prefix = p
                }
                return (AppearanceCommands.list(theme ?? state.active, state, prefix: prefix) + "\n\n" + AppearanceCommands.themes(state), false)
            case "set_appearance":
                var lines: [String] = []
                if let raw = a["use"] {
                    guard let u = raw as? String else { throw AppearanceCommands.Failure("use must be a string.") }
                    state.active = try AppearanceCommands.resolve(u, state)
                    lines.append("Now using \(AppearanceCommands.display(state.active)).")
                }
                var set: [(String, String)] = []
                if let raw = a["set"] {
                    guard let object = raw as? [String: Any] else { throw AppearanceCommands.Failure("set must be an object of key: value.") }
                    for key in object.keys.sorted() {
                        switch object[key] {
                        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): set.append((key, n.boolValue ? "true" : "false"))
                        case let n as NSNumber: set.append((key, "\(n.doubleValue)"))
                        case let t as String: set.append((key, t))
                        default: throw AppearanceCommands.Failure("\(key) takes a string, number or boolean.")
                        }
                    }
                }
                var reset: [String] = []
                if let raw = a["reset"] {
                    guard let r = raw as? [String] else { throw AppearanceCommands.Failure("reset must be an array of keys.") }
                    reset = r
                }
                if !set.isEmpty || !reset.isEmpty {
                    lines.append(try AppearanceCommands.apply(set: set, reset: reset, theme: theme, &state))
                }
                guard !lines.isEmpty else { throw AppearanceCommands.Failure("Nothing to change: give set, reset or use.") }
                if state != original {
                    try state.save(to: url)
                }
                if url == AppearanceState.fileURL, !PreviewAppearance.isIsolatedRun, state.settings() != activeBefore { try PreviewAppearance.publish(state.settings()) }
                return (lines.joined(separator: "\n"), false)
            default:
                throw AppearanceCommands.Failure("Unknown tool \(name).")
            }
        } catch let error as AppearanceSettings.SettingError {
            return (error.message, true)
        } catch {
            return (error.localizedDescription, true)
        }
    }
}
