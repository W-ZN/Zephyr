import AppKit
import ZephyrCore

/// The advanced customization tier (design §8): custom CSS, read through a whitelist onto the same
/// atomic settings as the settings window (typography keys) and onto typography color roles. Only
/// presentation changes (principle 8); nothing is written to documents. Everything outside the
/// whitelist is reported, never guessed at.
///
/// Typography: `body` (font-family, font-size, line-height, max-width, text-align), `p` (margin,
/// margin-bottom, text-indent, text-align), `h1`…`h6` (font-family, font-size, font-weight,
/// margin-top, margin-bottom, line-height), `code` / `pre` (font-family, font-size, line-height),
/// `table` / `th` / `td` (font-size, padding), `.mermaid` (font-size).
/// Colors: `body` color and background, `h1`…`h6` color, `a` color, `blockquote` border color,
/// `table` / `td` border color, `th` background. Colors outside
/// `@media (prefers-color-scheme: dark)` apply in light mode, colors inside it in dark mode, so one
/// fixed color never becomes unreadable.
public struct CustomStyle: Equatable {
    public enum Length: Equatable {
        case points(CGFloat)
        case em(CGFloat)

        func points(relativeTo base: CGFloat) -> CGFloat {
            switch self {
            case let .points(p): p
            case let .em(e): e * base
            }
        }

        func em(relativeTo base: CGFloat) -> CGFloat {
            switch self {
            case let .points(p): p / base
            case let .em(e): e
            }
        }
    }

    public struct Color: Equatable {
        public var light: NSColor?
        public var dark: NSColor?
        var isEmpty: Bool { light == nil && dark == nil }
    }

    public struct Heading: Equatable {
        public var color = Color()
    }

    /// A typography value as written: a length (resolved against the body size later), a plain
    /// number (line heights, weights) or text (font families, choices).
    public enum Declared: Equatable {
        case length(Length)
        case number(Double)
        case text(String)
    }

    /// Settings keys (AppearanceSettings) and their declared values.
    public var typography: [String: Declared] = [:]
    public var colors: [Palette.Role: Color] = [:]
    public var headings: [Int: Heading] = [:]

    public init() {}

    public var isEmpty: Bool { self == CustomStyle() }

    /// The typography as settings overrides. Lengths become em of the body size (the CSS body
    /// size if it sets one, else `baseSize`), or points for `text.size`.
    public func overrides(baseSize: Double) -> [String: AppearanceSettings.Value] {
        var base = CGFloat(baseSize)
        if case let .length(l)? = typography["text.size"] { base = l.points(relativeTo: base) }
        var result: [String: AppearanceSettings.Value] = [:]
        for (key, declared) in typography {
            switch declared {
            case let .text(t): result[key] = .text(t)
            case let .number(n): result[key] = .number(n)
            case let .length(l):
                switch key {
                case "text.size": result[key] = .number(Double(round(base)))
                // A line height given as a length is relative to the text it sets.
                default: result[key] = .number(Double(l.em(relativeTo: base)))
                }
            }
        }
        return result
    }

    // MARK: Parsing

    /// The style and one note per declaration that was applied or ignored, in source order.
    /// `baseSize` checks lengths against the settings' ranges (the text size in use).
    public static func parse(_ css: String, baseSize: Double = 16) -> (style: CustomStyle, applied: [String], ignored: [String]) {
        var style = CustomStyle()
        var applied: [String] = [], ignored: [String] = []
        let source = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var lightColors = false, darkColors = false
        var labels: [String: [String]] = [:]

        func rules(_ text: Substring, dark: Bool) {
            var rest = text
            while let open = rest.firstIndex(of: "{") {
                let head = rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
                // The block, with nested braces for @media.
                var depth = 0, close = open
                for i in rest[open...].indices {
                    if rest[i] == "{" { depth += 1 } else if rest[i] == "}" { depth -= 1; if depth == 0 { close = i; break } }
                }
                guard depth == 0 else { ignored.append("Unclosed block after “\(head)”"); return }
                let body = rest[rest.index(after: open)..<close]
                rest = rest[rest.index(after: close)...]
                if head.hasPrefix("@") {
                    let condition = head.lowercased().replacingOccurrences(of: " ", with: "")
                    if condition == "@media(prefers-color-scheme:dark)" { rules(body, dark: true) } else { ignored.append(head) }
                    continue
                }
                for selector in head.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) {
                    for declaration in body.split(separator: ";") {
                        let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        guard parts.count == 2, !parts[0].isEmpty else { continue }
                        let property = parts[0].lowercased()
                        let value = parts[1].replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
                        let label = "\(selector) { \(property): \(value) }"
                        let before = style.typography
                        if let problem = apply(selector, property, value, dark: dark, to: &style) {
                            ignored.append(problem.isEmpty ? label : "\(label): \(problem)")
                        } else {
                            applied.append(label)
                            for (key, declared) in style.typography where before[key] != declared { labels[key, default: []].append(label) }
                            if property.hasSuffix("color") || property.hasPrefix("background") { if dark { darkColors = true } else { lightColors = true } }
                        }
                    }
                }
            }
        }
        rules(source[...], dark: false)
        // Values outside the settings' ranges are dropped and reported, like any other mistake.
        var check = AppearanceSettings()
        for (key, value) in style.overrides(baseSize: baseSize) {
            do { try check.set(key, value: value) } catch let e as AppearanceSettings.SettingError {
                style.typography[key] = nil
                applied.removeAll { labels[key, default: []].contains($0) }
                ignored.append(e.message)
            } catch {}
        }
        if lightColors, !darkColors {
            applied.append(String(localized: "Colors apply in light mode; add @media (prefers-color-scheme: dark) { … } for dark mode."))
        }
        return (style, applied, ignored)
    }

    /// nil when applied; otherwise why not ("" for an unsupported selector or property).
    private static func apply(_ selector: String, _ property: String, _ value: String, dark: Bool, to s: inout CustomStyle) -> String? {
        func color(_ role: Palette.Role) -> String? {
            guard let c = parseColor(value) else { return "unknown color" }
            var entry = s.colors[role] ?? Color()
            if dark { entry.dark = c } else { entry.light = c }
            s.colors[role] = entry
            return nil
        }
        func set(_ key: String, _ declared: Declared?, _ problem: String) -> String? {
            guard let declared else { return problem }
            s.typography[key] = declared
            return nil
        }
        func len(_ key: String) -> String? { set(key, length(value).map(Declared.length), "unknown length") }
        func lineHeight(_ key: String) -> String? {
            if let n = Double(value) { return set(key, .number(n), "") }
            return set(key, length(value).map(Declared.length), "unknown line height")
        }
        let colorOnly = ["color", "border-left-color", "border-color", "background", "background-color"].contains(property)
        if dark, !colorOnly { return "only colors are read inside the dark-mode block" }
        switch selector {
        case "body", "html", ":root":
            switch property {
            case "font-family": return set("font.body", family(value).map(Declared.text), "font not installed")
            case "font-size": return len("text.size")
            case "line-height": return lineHeight("text.lineHeight")
            case "max-width": return set("text.width", length(value).map(Declared.length), "unknown width")
            case "text-align": return set("text.align", ["left", "justify"].contains(value.lowercased()) ? .text(value.lowercased()) : nil, "left or justify")
            case "color": return color(.text)
            case "background", "background-color": return color(.background)
            default: return ""
            }
        case "p":
            switch property {
            case "margin-bottom": return len("paragraph.spacing")
            case "margin":
                // `margin: 0 0 1em` and the like: the bottom value (third, or first when alone).
                let parts = value.split(separator: " ").map(String.init)
                let bottom = parts.count >= 3 ? parts[2] : parts.first ?? ""
                if bottom == "0" { s.typography["paragraph.spacing"] = .number(0); return nil }
                return set("paragraph.spacing", length(bottom).map(Declared.length), "unknown length")
            case "text-indent": return value == "0" ? set("paragraph.indent", .number(0), "") : len("paragraph.indent")
            case "text-align": return set("text.align", ["left", "justify"].contains(value.lowercased()) ? .text(value.lowercased()) : nil, "left or justify")
            case "line-height": return lineHeight("text.lineHeight")
            default: return ""
            }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let h = selector
            switch property {
            case "font-family": return set("font.heading", family(value).map(Declared.text), "font not installed")
            case "font-size": return len("\(h).size")
            case "font-weight": return set("\(h).weight", weight(value).map(Declared.number), "unknown weight")
            case "margin-top": return value == "0" ? set("\(h).spaceAbove", .number(0), "") : len("\(h).spaceAbove")
            case "margin-bottom": return value == "0" ? set("\(h).spaceBelow", .number(0), "") : len("\(h).spaceBelow")
            case "line-height": return lineHeight("headings.lineHeight")
            case "color":
                let level = Int(h.dropFirst())!
                guard let c = parseColor(value) else { return "unknown color" }
                var entry = s.headings[level] ?? Heading()
                if dark { entry.color.dark = c } else { entry.color.light = c }
                s.headings[level] = entry
                return nil
            default: return ""
            }
        case "code", "pre", "pre code":
            switch property {
            case "font-family": return set("font.code", family(value).map(Declared.text), "font not installed")
            case "font-size": return len("code.size")
            case "line-height": return lineHeight("code.lineHeight")
            case "background", "background-color": return color(.codeBackground)
            default: return ""
            }
        case "table", "td", "th":
            switch property {
            case "font-size": return len("table.textSize")
            case "padding":
                // `padding: 6px 12px`: the horizontal value (second, or first when alone).
                let parts = value.split(separator: " ").map(String.init)
                return set("table.padding", length(parts.count >= 2 ? parts[1] : parts.first ?? "").map(Declared.length), "unknown length")
            case "border-color": return color(.tableBorder)
            case "background", "background-color": return selector == "th" ? color(.tableHeader) : ""
            default: return ""
            }
        case ".mermaid", "pre.mermaid":
            return property == "font-size" ? len("diagram.textSize") : ""
        case "a":
            return property == "color" ? color(.link) : ""
        case "blockquote":
            return property == "border-left-color" || property == "border-color" ? color(.quote) : ""
        default:
            return ""
        }
    }

    /// The first installed family of a CSS font-family list; generic names map to the presets.
    static func family(_ value: String) -> String? {
        let installed = NSFontManager.shared.availableFontFamilies
        for raw in value.split(separator: ",") {
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            switch name.lowercased() {
            case "system-ui", "-apple-system", "sans-serif", "ui-sans-serif": return "system"
            case "serif", "ui-serif": return "serif"
            case "monospace", "ui-monospace": return "mono"
            default: break
            }
            if let match = installed.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        }
        return nil
    }

    static func length(_ value: String) -> Length? {
        let v = value.lowercased()
        for (unit, make) in [("rem", { Length.em($0) }), ("em", { Length.em($0) }), ("px", { Length.points($0) }), ("pt", { Length.points($0) }),
                             ("ch", { Length.em($0 / 2) }), ("%", { Length.em($0 / 100) })] as [(String, (CGFloat) -> Length)] {
            if v.hasSuffix(unit), let n = Double(v.dropLast(unit.count).trimmingCharacters(in: .whitespaces)), n >= 0 { return make(CGFloat(n)) }
        }
        return nil
    }

    static func weight(_ value: String) -> Double? {
        switch value.lowercased() {
        case "normal": 400
        case "bold": 700
        default: Double(value).flatMap { (100...900).contains($0) ? $0 : nil }
        }
    }

    public static func parseColor(_ value: String) -> NSColor? {
        let v = value.lowercased().trimmingCharacters(in: .whitespaces)
        let named: [String: UInt32] = ["black": 0x000000, "white": 0xFFFFFF, "gray": 0x808080, "grey": 0x808080, "red": 0xFF0000, "green": 0x008000,
                                       "blue": 0x0000FF, "orange": 0xFFA500, "purple": 0x800080, "teal": 0x008080, "navy": 0x000080, "maroon": 0x800000]
        if let rgb = named[v] { return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1) }
        if v.hasPrefix("#") {
            var hex = String(v.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let n = UInt64(hex, radix: 16) else { return nil }
            let full = hex.count == 6 ? n << 8 | 0xFF : n
            return NSColor(srgbRed: CGFloat(full >> 24 & 0xFF) / 255, green: CGFloat(full >> 16 & 0xFF) / 255, blue: CGFloat(full >> 8 & 0xFF) / 255, alpha: CGFloat(full & 0xFF) / 255)
        }
        if v.hasPrefix("rgb"), let open = v.firstIndex(of: "("), let close = v.lastIndex(of: ")") {
            let parts = v[v.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count >= 3 else { return nil }
            func channel(_ s: String) -> CGFloat? { s.hasSuffix("%") ? Double(s.dropLast()).map { CGFloat($0) / 100 } : Double(s).map { CGFloat($0) / 255 } }
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            let a = parts.count > 3 ? (parts[3].hasSuffix("%") ? Double(parts[3].dropLast()).map { CGFloat($0) / 100 } : Double(parts[3]).map { CGFloat($0) }) ?? 1 : 1
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        return nil
    }
}

extension NSColor {
    /// This color as drawn under `appearance`.
    func resolved(for appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance { result = self.usingColorSpace(.sRGB) ?? self }
        return result
    }

    /// `#RRGGBB` (or `#RRGGBBAA` when translucent), in sRGB.
    public var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded()), a = Int((c.alphaComponent * 255).rounded())
        return a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
