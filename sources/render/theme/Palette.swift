import AppKit
import ZephyrCore

/// Colors (design §8.2, §21.7): the theme, separate from typography. One palette is active for
/// the whole app; every color here is dynamic, resolved at drawing time for the drawing
/// appearance, so switching theme or light/dark only needs a redraw, never a restyle.
/// A theme defines each role for light and dark; settings and custom CSS override single roles.
public enum Palette {
    public enum Role: String, CaseIterable, Sendable {
        // Overridable (AppearanceSettings.colorRoles).
        case background, text, muted, accent, link, heading, quote, codeBackground, tableBorder, tableHeader, selection
        // Derived from the ones above, or tuned per theme.
        case faint, sidebar, raised, sunken, line, hover, pressed, accentSoft, onAccent, inlineCodeBackground, codeBorder, tableStripe, danger, added, removed
        // Diagrams: node fill, node outline, edges.
        case diagramNode, diagramStroke, diagramLine
        // Code: strings, numbers and literals, function names, types and keys, added diff lines.
        case syntaxKeyword, syntaxString, syntaxNumber, syntaxFunction, syntaxType, syntaxComment, syntaxInserted
    }

    /// One theme's colors for one appearance.
    public struct Scheme {
        var colors: [Role: NSColor]
        subscript(role: Role) -> NSColor { colors[role] ?? .magenta }
    }

    /// Base palettes: Zephyr's own and those of the three preset themes. Any theme may start from
    /// any of them and change single roles.
    public enum Theme: String, CaseIterable, Sendable {
        case zephyr, readme, notional, anthology
    }

    static func hex(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    /// Each palette's roles; what a palette leaves out is derived in `scheme`. The preset palettes
    /// imitate familiar reading styles: a code host's README, a workspace page, an editorial essay.
    static func base(_ theme: Theme, dark: Bool) -> [Role: NSColor] {
        switch (theme, dark) {
        // Zephyr's own (design §8.1): cool paper, green-gray ink, deep teal; text 12.8:1 (light) and
        // 13.9:1 (dark) on the canvas, faint text still 4.5:1.
        case (.zephyr, false):
            return [.background: hex(0xFBFCFC), .text: hex(0x253332), .muted: hex(0x566663), .faint: hex(0x6B7678), .accent: hex(0x15796D),
                    .link: hex(0x126F65), .selection: hex(0xD5EBE5), .inlineCodeBackground: hex(0xEEF3F0), .codeBackground: hex(0xF1F5F3),
                    .codeBorder: hex(0xD7E1DC), .tableHeader: hex(0xEAF0ED), .tableBorder: hex(0xD4DED9), .tableStripe: hex(0xF4F7F5),
                    .quote: hex(0x72958A), .sidebar: hex(0xF0F4F2), .hover: hex(0xE7EEEA), .line: hex(0xDCE5E0), .raised: hex(0xFFFFFF),
                    .sunken: hex(0xF1F5F3), .onAccent: hex(0xFFFFFF),
                    .diagramNode: hex(0xFFFFFF), .diagramStroke: hex(0xBCCDC4), .diagramLine: hex(0x73867C)]
        case (.zephyr, true):
            return [.background: hex(0x17201D), .text: hex(0xE4ECE9), .muted: hex(0xA6B7B0), .faint: hex(0x899B93), .accent: hex(0x73C9B5),
                    .link: hex(0x8BD3C1), .selection: hex(0x294D43), .inlineCodeBackground: hex(0x28362F), .codeBackground: hex(0x1D2923),
                    .codeBorder: hex(0x35483E), .tableHeader: hex(0x25372D), .tableBorder: hex(0x3A4C42), .tableStripe: hex(0x1B2621),
                    .quote: hex(0x79AD99), .sidebar: hex(0x1B2922), .hover: hex(0x2A3B31), .line: hex(0x304238), .raised: hex(0x22332A),
                    .sunken: hex(0x1D2923), .onAccent: hex(0x17201D),
                    .diagramNode: hex(0x26382E), .diagramStroke: hex(0x50695A), .diagramLine: hex(0x9AAF9F)]
        case (.readme, false):
            return [.background: hex(0xFFFFFF), .text: hex(0x1F2328), .muted: hex(0x59636E), .faint: hex(0x818B98), .accent: hex(0x0969DA),
                    .sidebar: hex(0xF6F8FA), .raised: hex(0xFFFFFF), .sunken: hex(0xF6F8FA), .quote: hex(0xD1D9E0),
                    .codeBackground: hex(0xF6F8FA), .inlineCodeBackground: hex(0x818B98, 0.12), .tableBorder: hex(0xD1D9E0),
                    .tableHeader: hex(0xF6F8FA, 0), .tableStripe: hex(0xF6F8FA), .selection: hex(0x0969DA, 0.2)]
        case (.readme, true):
            return [.background: hex(0x0D1117), .text: hex(0xF0F6FC), .muted: hex(0x9198A1), .faint: hex(0x656C76), .accent: hex(0x4493F8),
                    .sidebar: hex(0x151B23), .raised: hex(0x161B22), .sunken: hex(0x151B23), .quote: hex(0x3D444D),
                    .codeBackground: hex(0x151B23), .inlineCodeBackground: hex(0x656C76, 0.2), .tableBorder: hex(0x3D444D),
                    .tableHeader: hex(0x151B23, 0), .tableStripe: hex(0x151B23), .selection: hex(0x4493F8, 0.3)]
        case (.notional, false):
            return [.background: hex(0xFFFFFF), .text: hex(0x37352F), .muted: hex(0x787774), .faint: hex(0xA5A39E), .accent: hex(0x2383E2),
                    .link: hex(0x37352F), .sidebar: hex(0xF7F7F5), .raised: hex(0xFFFFFF), .sunken: hex(0xF1F1EF), .quote: hex(0x37352F),
                    .codeBackground: hex(0xF7F6F3), .inlineCodeBackground: hex(0x878378, 0.15), .tableBorder: hex(0xE9E9E7),
                    .tableHeader: hex(0xF7F6F3), .tableStripe: hex(0xFBFBFA), .selection: hex(0x2383E2, 0.25)]
        case (.notional, true):
            return [.background: hex(0x191919), .text: hex(0xD4D4D4), .muted: hex(0x9B9B9B), .faint: hex(0x7D7D7D), .accent: hex(0x529CCA),
                    .link: hex(0xD4D4D4), .sidebar: hex(0x202020), .raised: hex(0x252525), .sunken: hex(0x202020), .quote: hex(0xD4D4D4),
                    .codeBackground: hex(0x202020), .inlineCodeBackground: hex(0x878378, 0.2), .tableBorder: hex(0x2F2F2F),
                    .tableHeader: hex(0x202020), .tableStripe: hex(0x1D1D1D), .selection: hex(0x529CCA, 0.3)]
        case (.anthology, false):
            return [.background: hex(0xFAF9F5), .text: hex(0x141413), .muted: hex(0x5E5D59), .faint: hex(0x9A9893), .accent: hex(0xC96442),
                    .sidebar: hex(0xF0EEE6), .raised: hex(0xFFFEFB), .sunken: hex(0xF0EEE6), .quote: hex(0xC96442),
                    .codeBackground: hex(0xF0EEE6), .inlineCodeBackground: hex(0x141413, 0.06), .tableBorder: hex(0xDEDCD1),
                    .tableHeader: hex(0xF0EEE6), .tableStripe: hex(0xF5F4EE), .selection: hex(0xC96442, 0.18)]
        case (.anthology, true):
            return [.background: hex(0x1F1E1D), .text: hex(0xECEBE5), .muted: hex(0xA3A199), .faint: hex(0x73716B), .accent: hex(0xD97757),
                    .sidebar: hex(0x262624), .raised: hex(0x2B2A27), .sunken: hex(0x262624), .quote: hex(0xD97757),
                    .codeBackground: hex(0x2B2A27), .inlineCodeBackground: hex(0xECEBE5, 0.08), .tableBorder: hex(0x3E3D39),
                    .tableHeader: hex(0x2B2A27), .tableStripe: hex(0x232220), .selection: hex(0xD97757, 0.28)]
        }
    }

    /// The full scheme: theme roles, then overrides, then everything derived from them. Surfaces
    /// follow an overridden background; lines and fills follow an overridden text color.
    static func scheme(_ theme: Theme, dark: Bool, overrides: [Role: NSColor]) -> Scheme {
        var c = base(theme, dark: dark)
        for (role, color) in overrides { c[role] = color }
        let bg = c[.background]!, text = c[.text]!, accent = c[.accent]!
        if overrides[.background] != nil {
            c[.hover] = nil
            c[.line] = nil
            c[.sidebar] = mix(bg, text, dark ? 0.035 : 0.03)
            c[.sunken] = mix(bg, text, dark ? 0.05 : 0.045)
            c[.raised] = dark ? mix(bg, text, 0.07) : mix(bg, .white, 0.6)
        }
        if overrides[.text] != nil || overrides[.background] != nil {
            if overrides[.muted] == nil { c[.muted] = mix(text, bg, 0.38) }
            c[.faint] = mix(text, bg, 0.55)
        }
        let ink = dark ? NSColor.white : NSColor.black
        c[.link] = c[.link] ?? accent
        c[.heading] = c[.heading] ?? text
        c[.quote] = c[.quote] ?? ink.withAlphaComponent(dark ? 0.2 : 0.14)
        c[.codeBackground] = c[.codeBackground] ?? ink.withAlphaComponent(dark ? 0.065 : 0.04)
        c[.inlineCodeBackground] = c[.inlineCodeBackground] ?? ink.withAlphaComponent(dark ? 0.1 : 0.055)
        c[.tableBorder] = c[.tableBorder] ?? ink.withAlphaComponent(dark ? 0.14 : 0.11)
        c[.codeBorder] = c[.codeBorder] ?? c[.tableBorder]
        if overrides[.background] != nil || overrides[.text] != nil { c[.diagramNode] = nil; c[.diagramStroke] = nil; c[.diagramLine] = nil }
        c[.diagramNode] = c[.diagramNode] ?? c[.raised]
        c[.diagramStroke] = c[.diagramStroke] ?? mix(bg, c[.muted]!, dark ? 0.45 : 0.35)
        c[.diagramLine] = c[.diagramLine] ?? mix(c[.muted]!, bg, 0.12)
        c[.tableHeader] = c[.tableHeader] ?? ink.withAlphaComponent(dark ? 0.05 : 0.035)
        c[.tableStripe] = c[.tableStripe] ?? ink.withAlphaComponent(dark ? 0.025 : 0.018)
        c[.selection] = c[.selection] ?? accent.withAlphaComponent(dark ? 0.28 : 0.18)
        c[.accentSoft] = accent.withAlphaComponent(dark ? 0.16 : 0.12)
        c[.line] = c[.line] ?? ink.withAlphaComponent(dark ? 0.09 : 0.10)
        c[.hover] = c[.hover] ?? ink.withAlphaComponent(dark ? 0.06 : 0.055)
        c[.pressed] = ink.withAlphaComponent(dark ? 0.1 : 0.09)
        c[.onAccent] = c[.onAccent] ?? (dark ? hex(0x0D1515) : .white)
        c[.danger] = dark ? hex(0xEE7B67) : hex(0xC4432F)
        c[.added] = dark ? hex(0x4CC27F, 0.16) : hex(0x2E9B5F, 0.14)
        c[.removed] = dark ? hex(0xEE6F61, 0.16) : hex(0xD0473A, 0.12)
        syntax(&c, dark: dark)
        return Scheme(colors: c)
    }

    /// Code colors (design §8.1), from the theme rather than a fixed scheme: keywords take the
    /// accent, types and keys the accent toned toward the text; strings, numbers and function
    /// names take the first three of five hues that stand apart from the accent, all at one
    /// lightness for the appearance and pulled a little toward the text, so a theme's code reads
    /// in its own colors and stays quiet beside its prose.
    static func syntax(_ c: inout [Role: NSColor], dark: Bool) {
        let accent = c[.accent]!, text = c[.text]!
        // What code sits on: the code background over the page.
        let page = c[.background]!.usingColorSpace(.sRGB) ?? c[.background]!
        let code = c[.codeBackground]!.usingColorSpace(.sRGB) ?? c[.codeBackground]!
        let fill = mix(page, code.withAlphaComponent(1), code.alphaComponent)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        (accent.usingColorSpace(.sRGB) ?? accent).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        func distance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
        // Warm, violet, blue, green, rose.
        let candidates: [CGFloat] = [28, 285, 212, 145, 340]
        let hues = saturation < 0.15 ? candidates : candidates.filter { distance($0, hue * 360) > 35 }
        // Toward the text until it reads on the code background (a light accent, a faint gray).
        func readable(_ color: NSColor, _ minimum: CGFloat) -> NSColor {
            var t: CGFloat = 0
            var result = color
            while contrast(result, fill) < minimum, t < 1 {
                t += 0.1
                result = mix(color, text, t)
            }
            return result
        }
        func tone(_ degrees: CGFloat) -> NSColor {
            let pure = NSColor(colorSpace: .sRGB, hue: degrees / 360, saturation: dark ? 0.42 : 0.68, brightness: dark ? 0.9 : 0.58, alpha: 1)
            return readable(mix(pure, text, 0.18), 4.5)
        }
        c[.syntaxKeyword] = readable(accent, 4.5)
        c[.syntaxString] = tone(hues[0])
        c[.syntaxNumber] = tone(hues[1])
        c[.syntaxFunction] = tone(hues[2])
        c[.syntaxType] = readable(mix(accent, text, 0.4), 4.5)
        c[.syntaxComment] = readable(c[.faint]!, 3.6)
        c[.syntaxInserted] = tone(145)
    }

    /// WCAG contrast ratio of two opaque colors.
    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB) ?? color
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `a` moved toward `b` by `t`, in sRGB.
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a }
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t, green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t, alpha: x.alphaComponent + (y.alphaComponent - x.alphaComponent) * t)
    }

    // MARK: Active palette

    private static var light = scheme(.zephyr, dark: false, overrides: [:])
    private static var dark = scheme(.zephyr, dark: true, overrides: [:])
    /// Heading colors per level from custom CSS (light, dark).
    private static var headingColors: [Int: (light: NSColor?, dark: NSColor?)] = [:]

    /// Make a theme's palette and color keys, with its custom CSS colors on top, the active palette.
    public static func configure(_ settings: AppearanceSettings, css: CustomStyle = CustomStyle()) {
        let theme = Theme(rawValue: settings.string("palette")) ?? .zephyr
        light = scheme(theme, dark: false, overrides: overrides(settings, css: css, dark: false))
        dark = scheme(theme, dark: true, overrides: overrides(settings, css: css, dark: true))
        headingColors = css.headings.compactMapValues { $0.color.isEmpty ? nil : ($0.color.light, $0.color.dark) }
    }

    private static func overrides(_ settings: AppearanceSettings, css: CustomStyle, dark: Bool) -> [Role: NSColor] {
        var result: [Role: NSColor] = [:]
        for name in AppearanceSettings.colorRoles {
            guard let role = Role(rawValue: name), let color = CustomStyle.parseColor(settings.string("color.\(dark ? "dark" : "light").\(name)")) else { continue }
            result[role] = color
        }
        for (role, color) in css.colors {
            if let value = dark ? color.dark : color.light { result[role] = value }
        }
        return result
    }

    /// A theme's color for previews (the theme cards), regardless of the active one.
    public static func preview(_ theme: Theme, _ role: Role, dark: Bool) -> NSColor {
        scheme(theme, dark: dark, overrides: [:])[role]
    }

    /// Resolves a complete preview without changing the active app palette.
    public static func preview(_ settings: AppearanceSettings, _ role: Role, css: CustomStyle = CustomStyle(), dark: Bool) -> NSColor {
        let theme = Theme(rawValue: settings.string("palette")) ?? .zephyr
        return scheme(theme, dark: dark, overrides: overrides(settings, css: css, dark: dark))[role]
    }

    /// Synchronous output resolves its own colors, then restores the reader's palette.
    public static func withConfiguration<Result>(_ settings: AppearanceSettings, css: CustomStyle = CustomStyle(), _ body: () throws -> Result) rethrows -> Result {
        let previous = (light, dark, headingColors)
        configure(settings, css: css)
        defer { (light, dark, headingColors) = previous }
        return try body()
    }

    public static func resolved(_ role: Role, dark isDark: Bool) -> NSColor { (isDark ? dark : light)[role] }

    public static func color(_ role: Role) -> NSColor {
        NSColor(name: NSColor.Name("zephyr." + role.rawValue)) { appearance in
            resolved(role, dark: appearance.isDark)
        }
    }

    /// Heading text: a CSS color for that level, else the theme's (level 6 is quieter).
    public static func heading(level: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.isDark
            if let custom = headingColors[level], let c = isDark ? custom.dark : custom.light { return c }
            return resolved(level == 6 ? .muted : .heading, dark: isDark)
        }
    }

    public static let text = color(.text)
    public static let muted = color(.muted)
    public static let faint = color(.faint)
    public static let accent = color(.accent)
    public static let link = color(.link)
    public static let quote = color(.quote)
    /// The quote bar: the theme's quote color, kept apart from both the caret and the page. A gray
    /// as dark as the text (a monochrome theme) would read as a second caret beside the real one,
    /// so it is drawn halfway to the background; one barely off the background is drawn a third
    /// of the way to the text. Colored bars stay as the theme sets them.
    public static let quoteBar = NSColor(name: nil) { appearance in
        let dark = appearance.isDark
        guard let quote = resolved(.quote, dark: dark).usingColorSpace(.sRGB), let page = resolved(.background, dark: dark).usingColorSpace(.sRGB),
              let ink = resolved(.text, dark: dark).usingColorSpace(.sRGB) else { return resolved(.quote, dark: dark) }
        func luminance(_ c: NSColor) -> CGFloat {
            func channel(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let a = luminance(quote), b = luminance(page)
        let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        if quote.saturationComponent < 0.15, contrast > 3.5 { return page.blended(withFraction: 0.5, of: quote) ?? quote }
        if contrast < 1.6 { return quote.blended(withFraction: 0.35, of: ink) ?? quote }
        return quote
    }
    public static let codeBackground = color(.codeBackground)
    public static let codeBorder = color(.codeBorder)
    public static let inlineCodeBackground = color(.inlineCodeBackground)
    public static let rule = color(.tableBorder)
    public static let tableHeader = color(.tableHeader)
    public static let tableStripe = color(.tableStripe)

    /// The color of a code token (design §8.1).
    public static func syntax(_ role: CodeSyntax.Role) -> NSColor {
        switch role {
        case .keyword: syntaxColors.keyword
        case .string: syntaxColors.string
        case .number: syntaxColors.number
        case .function: syntaxColors.function
        case .type, .property: syntaxColors.type
        case .comment: syntaxColors.comment
        case .inserted: syntaxColors.inserted
        case .deleted: syntaxColors.deleted
        }
    }

    private static let syntaxColors = (keyword: color(.syntaxKeyword), string: color(.syntaxString), number: color(.syntaxNumber), function: color(.syntaxFunction),
                                       type: color(.syntaxType), comment: color(.syntaxComment), inserted: color(.syntaxInserted), deleted: color(.danger))
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
