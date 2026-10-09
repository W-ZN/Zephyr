import Foundation

/// One theme's look (design §8, §21.7), as one atomic key per value: typefaces, light or dark,
/// zoom, typography (layout and structure), colors, and the details of code blocks, formulas,
/// heading numbers, tables and diagrams. Everything belongs to a theme, nothing is shared between
/// themes, so switching themes switches the whole look. The settings window, `zephyr config`, the
/// MCP tools and the built-in assistant all read and write through this type, so a key added here
/// reaches every entry at once. Only values that differ from the defaults are stored.
public struct AppearanceSettings: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case number(Double)
        case text(String)
        case flag(Bool)
    }

    public struct Spec: Sendable {
        public enum Kind: Sendable, Equatable {
            case number(min: Double, max: Double, step: Double, unit: String)
            case choice([String])
            /// `#RRGGBB` or `#RRGGBBAA`.
            case color
            /// A CSS-like list of families, the first installed one wins: `Newsreader, serif`.
            /// `system`, `serif` and `mono` are the macOS families (and `body` for headings).
            case font
            case flag
            case text
        }

        public let key: String
        public let kind: Kind
        /// nil: worked out from other settings ("auto"), such as a heading size from the scale.
        public let defaultValue: Value?
        public let help: String
    }

    public struct SettingError: Error, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public private(set) var overrides: [String: Value]

    public init(overrides: [String: Value] = [:]) {
        self.overrides = overrides
    }

    // MARK: Registry

    public static let headingLevels = 1...6
    public static let colorRoles = ["background", "text", "muted", "accent", "link", "heading", "quote", "codeBackground", "tableBorder", "tableHeader", "selection"]

    public static let specs: [Spec] = {
        func number(_ key: String, _ min: Double, _ max: Double, _ step: Double, _ unit: String, _ value: Double?, _ help: String) -> Spec {
            Spec(key: key, kind: .number(min: min, max: max, step: step, unit: unit), defaultValue: value.map(Value.number), help: help)
        }
        func choice(_ key: String, _ options: [String], _ help: String) -> Spec {
            Spec(key: key, kind: .choice(options), defaultValue: .text(options[0]), help: help)
        }
        func flag(_ key: String, _ value: Bool, _ help: String) -> Spec {
            Spec(key: key, kind: .flag, defaultValue: .flag(value), help: help)
        }
        var s: [Spec] = [
            Spec(key: "font.body", kind: .font, defaultValue: .text("system"), help: "Typeface of Latin text: a list of families, the first installed wins (system, serif, mono are the macOS ones)."),
            Spec(key: "font.cjk", kind: .font, defaultValue: nil, help: "Typeface of Chinese and Japanese text, such as PingFang SC, Songti SC or Noto Serif CJK SC; auto pairs it with font.body."),
            Spec(key: "font.heading", kind: .font, defaultValue: .text("body"), help: "Typeface of headings: body (the text's) or a list of families."),
            Spec(key: "font.code", kind: .font, defaultValue: .text("mono"), help: "Typeface of code: mono, or a list of families."),
            choice("appearance", ["system", "light", "dark"], "Light or dark: follow macOS, or always one."),
            number("zoom", 0.75, 1.6, 0.05, "×", 1, "Zoom of all sizes (⌘+ and ⌘− change it)."),
            number("text.size", 11, 28, 1, "pt", 16, "Size of the text, before zoom."),
            number("text.lineHeight", 1.2, 2.4, 0.05, "×", 1.65, "Line height of the text, as a multiple of its size."),
            number("text.width", 30, 80, 1, "characters", 56, "Width of the reading column, in characters (em)."),
            choice("text.align", ["left", "justify"], "Alignment of paragraphs."),
            number("paragraph.spacing", 0, 2, 0.05, "em", 1, "Space between paragraphs."),
            number("paragraph.indent", 0, 4, 0.5, "em", 0, "First-line indent of paragraphs (2 is the Chinese convention)."),
            number("list.indent", 1, 3, 0.1, "em", 1.6, "Indent of each list level."),
            number("list.spacing", 0, 1, 0.025, "em", 0.25, "Space between list items."),
            number("headings.scale", 0.5, 1.6, 0.05, "×", 1, "Contrast of the heading sizes: below 1 flatter, above 1 bolder. Sizes set per level win."),
            number("headings.lineHeight", 1, 2, 0.05, "×", 1.3, "Line height of headings."),
            choice("headings.numbering", ["none", "decimal", "chinese"], "Numbers before headings, drawn only (the file keeps its text): decimal 1 / 1.1 / 1.1.1, or chinese 一、/（一）/ 1."),
            number("headings.numberFrom", 1, 3, 1, "", 2, "The first heading level that is numbered (2 leaves the title alone)."),
        ]
        let ramp = [1.875, 1.5, 1.25, 1.0625, 1.0, 0.9375]
        let above = [2.5, 2, 1.5, 1.25, 1.25, 1.25], below = [0.625, 0.5, 0.375, 0.25, 0.25, 0.25]
        for level in headingLevels {
            let h = "h\(level)"
            s.append(number("\(h).size", 0.75, 3, 0.0125, "em", nil, "Size of level-\(level) headings relative to the text; auto follows headings.scale (\(ramp[level - 1]) at scale 1)."))
            s.append(number("\(h).weight", 100, 900, 100, "", level <= 2 ? 700 : 600, "Weight of level-\(level) headings (400 regular, 700 bold)."))
            s.append(number("\(h).spaceAbove", 0, 4, 0.125, "em", above[level - 1], "Space above level-\(level) headings."))
            s.append(number("\(h).spaceBelow", 0, 2, 0.125, "em", below[level - 1], "Space below level-\(level) headings."))
            s.append(flag("\(h).rule", false, "A rule under level-\(level) headings."))
        }
        s += [
            number("code.size", 0.7, 1.2, 0.025, "em", 0.875, "Size of code relative to the text."),
            number("code.lineHeight", 1.2, 2.2, 0.05, "×", 1.55, "Line height of code blocks."),
            choice("code.style", ["shaded", "card", "outline", "plain"], "Code blocks on a tint, on a tint with a border (card), in an outline, or bare."),
            flag("code.lineNumbers", false, "Line numbers beside fenced code blocks."),
            flag("code.syntax", true, "Color fenced code by its language (```json, ```python, ```bash, …): keywords, strings, numbers, comments, function names; colors follow the theme."),
            flag("math.render", true, "Draw $…$ and $$…$$ as formulas; off shows their TeX."),
            number("math.size", 0.8, 1.5, 0.05, "×", 1, "Size of formulas relative to the text around them."),
            choice("image.align", ["center", "left"], "Default position of pictures without an explicit HTML align attribute."),
            choice("table.width", ["column", "fit", "window"], "Default table width: the reading column, fit the content, or the window."),
            choice("table.align", ["center", "left"], "Position of tables narrower than the column."),
            number("table.textSize", 0.75, 1.1, 0.025, "em", 0.9375, "Size of table text relative to the text."),
            number("table.padding", 0.25, 1.5, 0.0625, "em", 0.75, "Horizontal padding of table cells."),
            choice("table.lines", ["rows", "grid", "none"], "Rules inside tables: between rows, a full grid, or none."),
            flag("table.headerShade", true, "Shade the header row."),
            flag("table.headerBold", true, "Set the header row in bold."),
            flag("table.stripes", false, "Shade every other row."),
            number("table.radius", 0, 12, 1, "pt", 0, "Corner radius of the table outline."),
            flag("diagram.render", true, "Draw ```mermaid blocks as diagrams; off shows their source."),
            number("diagram.textSize", 0.6, 1.2, 0.025, "em", 0.875, "Size of diagram labels relative to the text."),
            choice("diagram.spacing", ["standard", "compact", "roomy"], "Space between diagram nodes."),
            choice("diagram.lines", ["curved", "straight", "angled"], "How diagram edges are drawn."),
            choice("diagram.style", ["filled", "outline"], "Diagram nodes: tinted fill or outline only."),
            choice("diagram.colors", ["accent", "neutral"], "Diagram colors: the theme's accent or neutral grays."),
            choice("palette", ["zephyr", "readme", "notional", "anthology"], "Base colors (each with a light and a dark side); color.* keys change single roles."),
            number("sidebar.size", 11, 16, 0.5, "pt", 13, "Size of names in the sidebar; section titles and details follow."),
            choice("sidebar.spacing", ["standard", "compact", "roomy"], "Height of the sidebar's rows."),
        ]
        for mode in ["light", "dark"] {
            for role in colorRoles {
                s.append(Spec(key: "color.\(mode).\(role)", kind: .color, defaultValue: nil, help: "\(role) color in \(mode) mode; auto takes the palette's."))
            }
        }
        s.append(Spec(key: "css", kind: .text, defaultValue: .text(""), help: "Custom CSS, the advanced tier: body, p, h1–h6, code, a, blockquote, table, th, td, .mermaid. What it sets wins over the keys above."))
        return s
    }()

    private static let index: [String: Spec] = Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0) })

    public static func spec(_ key: String) -> Spec? { index[key] }

    // MARK: Reading

    /// The effective value: the override, else the default (nil for an "auto" value).
    public func value(_ key: String) -> Value? {
        overrides[key] ?? Self.index[key]?.defaultValue
    }

    public func number(_ key: String) -> Double? {
        if case let .number(n)? = value(key) { return n }
        return nil
    }

    public func string(_ key: String) -> String {
        if case let .text(t)? = value(key) { return t }
        return ""
    }

    public func flag(_ key: String) -> Bool {
        if case let .flag(f)? = value(key) { return f }
        return false
    }

    public func isSet(_ key: String) -> Bool { overrides[key] != nil }

    // MARK: Writing

    /// Set `key` from text as typed on a command line: a number, a choice, a color, `true` /
    /// `false`, or `default` (also `auto`) to remove the override. Values are checked, never coerced
    /// into range: a value outside it is refused with the range.
    @discardableResult
    public mutating func set(_ key: String, _ raw: String) throws -> Value? {
        guard let spec = Self.index[key] else { throw SettingError(Self.unknown(key)) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["default", "auto"].contains(text.lowercased()), spec.kind != .text {
            overrides[key] = nil
            return value(key)
        }
        let parsed: Value
        switch spec.kind {
        case .number:
            guard let n = Double(text.replacingOccurrences(of: spec.unitSuffix, with: "").trimmingCharacters(in: .whitespaces)) else {
                throw SettingError("\(key) takes a number\(spec.rangeText).")
            }
            parsed = .number(n)
        case .flag:
            switch text.lowercased() {
            case "true", "yes", "on", "1": parsed = .flag(true)
            case "false", "no", "off", "0": parsed = .flag(false)
            default: throw SettingError("\(key) takes true or false.")
            }
        case .text:
            parsed = .text(raw)
        case .choice, .color, .font:
            parsed = .text(text)
        }
        try set(key, value: parsed)
        return value(key)
    }

    /// Set `key` to a typed value (JSON from a tool call or a theme file).
    public mutating func set(_ key: String, value: Value) throws {
        guard let spec = Self.index[key] else { throw SettingError(Self.unknown(key)) }
        switch (spec.kind, value) {
        case let (.number(min, max, step, _), .number(n)):
            guard n.isFinite, n >= min - 1e-9, n <= max + 1e-9 else { throw SettingError("\(key) must be within \(Self.format(min))–\(Self.format(max))\(spec.unitSuffix.isEmpty ? "" : " " + spec.unitSuffix).") }
            // Snapped to the step, then to six decimals: 24 × 0.05 must read back as 1.2.
            overrides[key] = .number(((n / step).rounded() * step * 1e6).rounded() / 1e6)
        case let (.choice(options), .text(t)):
            let choice = t.lowercased()
            guard options.contains(choice) else { throw SettingError("\(key) is one of: \(options.joined(separator: ", ")).") }
            overrides[key] = .text(choice)
        case (.color, .text(let t)):
            guard let hex = Self.normalizedColor(t) else { throw SettingError("\(key) takes a color as #RRGGBB or #RRGGBBAA.") }
            overrides[key] = .text(hex)
        case (.font, .text(let t)):
            let families = Self.families(t)
            guard !families.isEmpty, t.count <= 200 else { throw SettingError("\(key) takes a font family, or a list such as \"Newsreader, serif\".") }
            guard !families.contains("body") || key == "font.heading" else { throw SettingError("Only font.heading can be body.") }
            overrides[key] = .text(families.joined(separator: ", "))
        case (.flag, .flag):
            overrides[key] = value
        case (.text, .text(let t)):
            guard t.utf8.count <= 64 << 10 else { throw SettingError("\(key) is limited to 64 KB.") }
            overrides[key] = t.isEmpty ? nil : value
        default:
            throw SettingError("\(key) takes \(spec.kindName).")
        }
        if overrides[key] == spec.defaultValue { overrides[key] = nil }
    }

    public mutating func reset(_ key: String) throws {
        guard Self.index[key] != nil else { throw SettingError(Self.unknown(key)) }
        overrides[key] = nil
    }

    /// Remove every override whose key starts with `prefix` ("" for all, "h2." for one level).
    public mutating func reset(prefix: String) {
        overrides = overrides.filter { !$0.key.hasPrefix(prefix) }
    }

    /// A font value's families, trimmed and unquoted; the generic names lowercased.
    public static func families(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { !$0.isEmpty }.map {
            ["system", "serif", "mono", "body"].contains($0.lowercased()) ? $0.lowercased() : $0
        }
    }

    // MARK: Describing (CLI, MCP, the assistant)

    /// One line per key: `key = value  (default …)  [kind]  help`.
    public func describe(prefix: String = "") -> String {
        Self.specs.filter { $0.key.hasPrefix(prefix) }.map(describe).joined(separator: "\n")
    }

    public func describe(_ spec: Spec) -> String {
        var line = "\(spec.key) = \(Self.text(value(spec.key), spec: spec))"
        if isSet(spec.key) { line += "  (default \(Self.text(spec.defaultValue, spec: spec)))" }
        line += "  [\(spec.kindName)]  \(spec.help)"
        return line
    }

    static func text(_ value: Value?, spec: Spec) -> String {
        switch value {
        case nil: return "auto"
        case let .number(n)?: return format(n) + (spec.unitSuffix.isEmpty ? "" : " " + spec.unitSuffix)
        case let .flag(f)?: return f ? "true" : "false"
        case let .text(t)?:
            if spec.kind == .text { return t.isEmpty ? "(empty)" : "(\(t.utf8.count) bytes)" }
            return t
        }
    }

    static func format(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(format: "%g", n)
    }

    static func unknown(_ key: String) -> String {
        let near = specs.map(\.key).filter { $0.hasPrefix(key.split(separator: ".").first.map(String.init) ?? key) }.prefix(6)
        return near.isEmpty ? "Unknown setting \(key). zephyr config list shows them all." : "Unknown setting \(key). Did you mean: \(near.joined(separator: ", "))?"
    }

    /// `#rgb`, `#rrggbb`, `#rrggbbaa` (with or without #), uppercased; nil otherwise.
    static func normalizedColor(_ text: String) -> String? {
        var hex = text.trimmingCharacters(in: .whitespaces).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + hex
    }

    // MARK: JSON

    /// A flat JSON object of the overrides, keys sorted.
    public func json(extra: [String: Any] = [:]) -> Data {
        var object = extra
        for (key, value) in overrides { object[key] = Self.jsonValue(value) }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func jsonValue(_ value: Value) -> Any {
        switch value {
        case let .number(n): n
        case let .text(t): t
        case let .flag(f): f
        }
    }

    static func value(json raw: Any) -> Value? {
        if let n = raw as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? .flag(n.boolValue) : .number(n.doubleValue) }
        return (raw as? String).map(Value.text)
    }

    /// Settings from a JSON object; unknown keys (other than `ignoring`) and invalid values are
    /// reported, not kept.
    public static func parse(json data: Data, ignoring: Set<String> = []) -> (settings: AppearanceSettings, problems: [String]) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (AppearanceSettings(), ["Not a JSON object."])
        }
        return parse(object: object, ignoring: ignoring)
    }

    public static func parse(object: [String: Any], ignoring: Set<String> = []) -> (settings: AppearanceSettings, problems: [String]) {
        let object = migrated(object)
        var settings = AppearanceSettings()
        var problems: [String] = []
        for key in object.keys.sorted() where !ignoring.contains(key) {
            guard let value = value(json: object[key]!) else {
                problems.append("\(key): unsupported value")
                continue
            }
            do { try settings.set(key, value: value) } catch let e as SettingError { problems.append(e.message) } catch {}
        }
        return (settings, problems)
    }
}

extension AppearanceSettings {
    /// Keys of earlier versions, read as today's: `table.header` (shaded, bold or plain) became
    /// two switches, so a shaded header can be plain text and a bold one unshaded.
    public static func migrated(_ object: [String: Any]) -> [String: Any] {
        guard let header = object["table.header"] as? String else { return object }
        var o = object
        o["table.header"] = nil
        if o["table.headerShade"] == nil { o["table.headerShade"] = header.lowercased() == "shaded" }
        if o["table.headerBold"] == nil { o["table.headerBold"] = header.lowercased() != "plain" }
        return o
    }
}

extension AppearanceSettings.Spec {
    var unitSuffix: String {
        if case let .number(_, _, _, unit) = kind { return unit }
        return ""
    }

    var rangeText: String {
        if case let .number(min, max, _, unit) = kind { return " within \(AppearanceSettings.format(min))–\(AppearanceSettings.format(max))\(unit.isEmpty ? "" : " " + unit)" }
        return ""
    }

    /// The kind as an agent reads it: `number 11–28 pt`, `one of left, justify`, `color`.
    public var kindName: String {
        switch kind {
        case let .number(min, max, step, unit):
            return "number \(AppearanceSettings.format(min))–\(AppearanceSettings.format(max))\(unit.isEmpty ? "" : " " + unit), step \(AppearanceSettings.format(step))" + (defaultValue == nil ? ", or auto" : "")
        case let .choice(options): return "one of " + options.joined(separator: ", ")
        case .color: return "color #RRGGBB, or auto"
        case .font: return "font families, first installed wins" + (defaultValue == nil ? ", or auto" : "")
        case .flag: return "true or false"
        case .text: return "text"
        }
    }
}
