import AppKit
import ZephyrCore

/// Layout and structure of the canvas (design §8.1, §21.7): typefaces, sizes, line heights, the
/// reading column, block spacing, tables and diagrams. Colors are not here; they belong to the
/// theme (`Palette`). Built from the atomic appearance settings with custom CSS on top.
public final class Typography {
    /// The three typeface presets; `font.body` may also name any installed family.
    public enum Preset: String, CaseIterable, Sendable {
        case system, serif, mono
    }
    /// Default width of tables (design §8.1): natural width, the reading column, or the window.
    public enum TableWidth: String, CaseIterable, Sendable {
        case fit, column, window
    }
    public enum BlockAlignment: String, CaseIterable, Sendable {
        case center, left
    }
    public enum TableLines: String, CaseIterable, Sendable { case rows, grid, none }

    public enum CodeStyle: String, CaseIterable, Sendable { case shaded, card, outline, plain }
    public enum Numbering: String, CaseIterable, Sendable { case none, decimal, chinese }

    /// The settings in effect (custom CSS applied), for anything that reads a key directly.
    public let settings: AppearanceSettings
    /// The Latin family in use (the first installed of `font.body`), or a macOS preset.
    public let latinFamily: String
    /// The Chinese and Japanese family in use (`font.cjk`, else paired with the Latin family).
    public let cjkFamily: String
    /// Text size with zoom applied.
    public let fontSize: CGFloat
    public let bodyFont: NSFont
    public let codeFont: NSFont
    /// A code fence's band (design §8.1): the space a fence keeps at the top and bottom of its code
    /// block, collapsed or shown. Revealed, the fence is set in `fenceFont` inside the same band, so
    /// the caret entering or leaving a code block moves nothing.
    public let fenceFont: NSFont
    public let fenceBand: CGFloat
    /// Width of the reading column in points (`text.width` em); the text view centers it.
    public let readableWidth: CGFloat
    public let listIndent: CGFloat
    public let quoteIndent: CGFloat
    public let codePadding: CGFloat
    /// Body line height as a multiple of the font size (design §8.1: 1.65).
    public let lineSpacing: CGFloat
    public let alignment: NSTextAlignment
    /// First-line indent of paragraphs, in points.
    public let paragraphIndent: CGFloat
    public let codeStyle: CodeStyle
    public let codeLineNumbers: Bool
    /// Fenced code colored by its language (`CodeSyntax`).
    public let syntaxColors: Bool
    /// Room for line numbers before code: three digits and a gap (0 without line numbers).
    public let codeGutter: CGFloat
    public let mathRender: Bool
    public let mathScale: CGFloat
    public let numbering: Numbering
    public let numberFrom: Int
    /// Default position of Markdown images and HTML images without `align`.
    public let imageAlignment: BlockAlignment
    public let tableWidth: TableWidth
    public let tableAlignment: BlockAlignment
    public let tableFont: NSFont
    public let tablePadding: CGFloat
    public let tableLines: TableLines
    public let tableHeaderShade: Bool
    public let tableHeaderBold: Bool
    public let tableStripes: Bool
    public let tableRadius: CGFloat
    /// Mermaid diagrams: drawn or left as code, their label font, layout and look.
    public let diagramRender: Bool
    public let diagramFont: NSFont
    public let diagram: DiagramStyle
    public let diagramFilled: Bool
    public let diagramAccent: Bool
    /// The custom CSS, for its colors (applied to the palette by whoever activates it).
    public let css: CustomStyle

    private var headingFonts: [Int: NSFont] = [:]
    private var traitFonts: [String: NSFont] = [:]

    public init(_ base: AppearanceSettings = AppearanceSettings(), css: CustomStyle = CustomStyle()) {
        var s = base
        for (key, value) in css.overrides(baseSize: base.number("text.size") ?? 16) { try? s.set(key, value: value) }
        settings = s
        self.css = css
        func n(_ key: String) -> CGFloat { CGFloat(s.number(key) ?? 0) }
        let fontSize = round(n("text.size") * n("zoom"))
        self.fontSize = fontSize
        readableWidth = round(n("text.width") * fontSize)
        lineSpacing = n("text.lineHeight")
        alignment = s.string("text.align") == "justify" ? .justified : .natural
        paragraphIndent = round(n("paragraph.indent") * fontSize)
        listIndent = round(fontSize * n("list.indent"))
        quoteIndent = round(fontSize * 1.15)
        codePadding = round(fontSize * 0.75)
        codeStyle = CodeStyle(rawValue: s.string("code.style")) ?? .shaded
        codeLineNumbers = s.flag("code.lineNumbers")
        syntaxColors = s.flag("code.syntax")
        mathRender = s.flag("math.render")
        mathScale = n("math.size")
        numbering = Numbering(rawValue: s.string("headings.numbering")) ?? .none
        numberFrom = Int(n("headings.numberFrom"))
        imageAlignment = BlockAlignment(rawValue: s.string("image.align")) ?? .center
        tableWidth = TableWidth(rawValue: s.string("table.width")) ?? .fit
        tableAlignment = BlockAlignment(rawValue: s.string("table.align")) ?? .center
        tablePadding = round(n("table.padding") * fontSize)
        tableLines = TableLines(rawValue: s.string("table.lines")) ?? .rows
        tableHeaderShade = s.flag("table.headerShade")
        tableHeaderBold = s.flag("table.headerBold")
        tableStripes = s.flag("table.stripes")
        tableRadius = n("table.radius")

        let installed = NSFontManager.shared.availableFontFamilies
        let latin = Self.available(s.string("font.body"), installed: installed) ?? "system"
        latinFamily = latin
        let serifText = latin == "serif" || AppearanceSettings.families(s.string("font.body")).contains("serif")
        cjkFamily = Self.available(s.string("font.cjk"), installed: installed) ?? (serifText ? "Songti SC" : "PingFang SC")
        let codeSize = round(n("code.size") * fontSize * 2) / 2
        let code = Self.available(s.string("font.code"), installed: installed) ?? "mono"
        codeFont = Self.cascade(Self.font(family: code, size: codeSize, weight: .regular) ?? NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular), cjk: "PingFang SC")
        fenceFont = Self.resize(codeFont, round(codeSize * 0.8 * 2) / 2)
        fenceBand = max(round(fontSize), ceil(fenceFont.ascender - fenceFont.descender) + 3)
        let size = latin == "mono" ? round(fontSize * 0.94 * 2) / 2 : fontSize
        bodyFont = Self.cascade(Self.font(family: latin, size: size, weight: .regular) ?? NSFont.systemFont(ofSize: fontSize), cjk: cjkFamily)
        let tableSize = round(n("table.textSize") * fontSize * 2) / 2
        tableFont = Self.resize(bodyFont, tableSize)
        codeGutter = codeLineNumbers ? ceil(("000" as NSString).size(withAttributes: [.font: codeFont]).width) + round(fontSize * 0.6) : 0
        diagramRender = s.flag("diagram.render")
        diagramFont = Self.resize(bodyFont, round(n("diagram.textSize") * fontSize * 2) / 2)
        let spacing: [String: Double] = ["compact": 0.75, "standard": 1, "roomy": 1.35]
        diagram = DiagramStyle(fontSize: Double(diagramFont.pointSize), spacing: spacing[s.string("diagram.spacing")] ?? 1,
                               lines: DiagramStyle.Lines(rawValue: s.string("diagram.lines")) ?? .curved)
        diagramFilled = s.string("diagram.style") != "outline"
        diagramAccent = s.string("diagram.colors") != "neutral"
    }

    /// With New York as the primary font and Songti as the CJK fallback, Core Text adds half an em
    /// after full-width punctuation (measured: "，只" is 40 pt instead of 32 pt at 16 pt). The system
    /// font cascade instead squeezes adjacent punctuation correctly, so serif Latin text turns
    /// kerning off inside CJK runs.
    public var disablesCJKKerning: Bool { latinFamily == "serif" || cjkFamily.hasPrefix("Songti") }

    /// The first family of a font list that is installed; `system`, `serif` and `mono` always are.
    static func available(_ list: String, installed: [String]) -> String? {
        for family in AppearanceSettings.families(list) {
            if ["system", "serif", "mono"].contains(family) { return family }
            if let match = installed.first(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) { return match }
        }
        return nil
    }

    /// Pin the CJK fallback to one family instead of whatever the locale cascade picks. Bold text
    /// in Songti barely differs from regular, and Chinese typesetting sets emphasis in a sans (黑体)
    /// within serif (宋体) text, so weights from medium up fall back to PingFang there.
    static func cascade(_ font: NSFont, cjk family: String) -> NSFont {
        let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        let heavy = weight >= NSFont.Weight.medium.rawValue
        let cjk = heavy && family.hasPrefix("Songti") ? "PingFang SC" : family
        let fallback = NSFontDescriptor(fontAttributes: [.family: cjk, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    static func serif(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// A font of `family` (an installed family, or the macOS presets `system`, `serif`, `mono`),
    /// or nil when it is not installed.
    static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        switch family {
        case "system", "system-ui": return NSFont.systemFont(ofSize: size, weight: weight)
        case "mono", "ui-monospace": return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case "serif", "ui-serif": return serif(size: size, weight: weight)
        default:
            let scale: [(NSFont.Weight, Int)] = [(.ultraLight, 2), (.thin, 3), (.light, 4), (.regular, 5), (.medium, 6), (.semibold, 8), (.bold, 9), (.heavy, 10), (.black, 11)]
            let managerWeight = scale.min { abs($0.0.rawValue - weight.rawValue) < abs($1.0.rawValue - weight.rawValue) }?.1 ?? 5
            return NSFontManager.shared.font(withFamily: family, traits: [], weight: managerWeight, size: size)
        }
    }

    /// CSS weight (100–900) as a font weight.
    static func weight(_ css: Double) -> NSFont.Weight {
        let table: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        return table[min(max(Int((css / 100).rounded()) - 1, 0), 8)]
    }

    // MARK: Fonts

    /// The size of a level relative to the text: the level's own setting, else the ramp of design
    /// §8.1 stretched or flattened by the heading scale.
    public func headingSize(level: Int) -> CGFloat {
        let level = min(max(level, 1), 6)
        if let em = settings.number("h\(level).size") { return round(CGFloat(em) * fontSize) }
        let ramp: [CGFloat] = [1.875, 1.5, 1.25, 1.0625, 1.0, 0.9375]
        let scale = CGFloat(settings.number("headings.scale") ?? 1)
        return round(fontSize * (1 + (ramp[level - 1] - 1) * scale))
    }

    public func headingFont(level: Int) -> NSFont {
        let level = min(max(level, 1), 6)
        if let f = headingFonts[level] { return f }
        let size = headingSize(level: level)
        let weight = Self.weight(settings.number("h\(level).weight") ?? 600)
        let installed = NSFontManager.shared.availableFontFamilies
        let family = settings.string("font.heading") == "body" ? latinFamily : Self.available(settings.string("font.heading"), installed: installed) ?? latinFamily
        let base = Self.font(family: family, size: family == "mono" ? round(size * 0.94) : size, weight: weight) ?? NSFont.systemFont(ofSize: size, weight: weight)
        let font = Self.cascade(base, cjk: cjkFamily)
        headingFonts[level] = font
        return font
    }

    /// The rule drawn under headings of `level`, if any.
    public func headingRule(level: Int) -> Bool { settings.flag("h\(min(max(level, 1), 6)).rule") }

    // MARK: Heading numbers

    /// Whether headings of `level` carry a drawn number (levels from headings.numberFrom).
    public func isNumbered(level: Int) -> Bool { numbering != .none && level >= numberFrom }

    /// The number of a heading of `level`, from the running counts of levels 1–6 (index = level).
    /// Decimal: 1, 1.1, 1.1.1 from the first numbered level. Chinese: 一、（一） 1. （1） ① by depth.
    public func headingNumber(level: Int, counts: [Int]) -> String? {
        guard isNumbered(level: level) else { return nil }
        switch numbering {
        case .none: return nil
        case .decimal: return counts[numberFrom...level].map(String.init).joined(separator: ".")
        case .chinese:
            let n = counts[level]
            switch level - numberFrom {
            case 0: return Self.chinese(n) + "、"
            case 1: return "（" + Self.chinese(n) + "）"
            case 2: return "\(n)."
            case 3: return "（\(n)）"
            default: return n <= 20 ? String(UnicodeScalar(0x2460 + n - 1).map(Character.init) ?? "·") : "\(n)."
            }
        }
    }

    /// Room before a numbered heading's text: a one-digit number of its depth and a gap. A longer
    /// number reaches left into the margin rather than into the text.
    public func numberSlot(level: Int) -> CGFloat {
        guard let template = headingNumber(level: level, counts: [Int](repeating: 1, count: 7)) else { return 0 }
        return ceil((template as NSString).size(withAttributes: [.font: numberFont(level: level)]).width) + numberGap(template, level: level)
    }

    /// The heading font with tabular digits, so numbers of one depth line up.
    public func numberFont(level: Int) -> NSFont {
        let font = headingFont(level: level)
        let key = "number|\(font.fontName)|\(font.pointSize)"
        if let f = traitFonts[key] { return f }
        let tabular = font.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector]]])
        let f = NSFont(descriptor: tabular, size: font.pointSize) ?? font
        traitFonts[key] = f
        return f
    }

    /// Space between a number and the heading text; full-width 、 and ） carry their own.
    public func numberGap(_ number: String, level: Int) -> CGFloat {
        number.last.map { "、）".contains($0) } == true ? 0 : round(headingFont(level: level).pointSize * 0.45)
    }

    /// 1–99 in Chinese numerals.
    static func chinese(_ n: Int) -> String {
        let digits = Array("〇一二三四五六七八九")
        guard n > 0, n < 100 else { return "\(n)" }
        if n < 10 { return String(digits[n]) }
        return (n / 10 == 1 ? "" : String(digits[n / 10])) + "十" + (n % 10 == 0 ? "" : String(digits[n % 10]))
    }

    public static func resize(_ font: NSFont, _ size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    /// Bold / italic variant of `font`, cached. CJK fallback keeps its own weight cascade.
    public func withTraits(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        guard bold || italic else { return font }
        let key = "\(font.fontName)|\(font.pointSize)|\(bold)|\(italic)"
        if let f = traitFonts[key] { return f }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        var result = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        if bold {
            // The CJK fallback keeps up: a semibold of the CJK family (PingFang where Songti's bold is too faint).
            let family = cjkFamily.hasPrefix("Songti") ? "PingFang SC" : cjkFamily
            let fallback = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]])
            result = NSFont(descriptor: result.fontDescriptor.addingAttributes([.cascadeList: [fallback]]), size: font.pointSize) ?? result
        }
        traitFonts[key] = result
        return result
    }

    public func inlineCodeFont(for font: NSFont) -> NSFont {
        let key = "code|\(font.pointSize)"
        if let f = traitFonts[key] { return f }
        let size = round(font.pointSize * CGFloat(settings.number("code.size") ?? 0.875) * 2) / 2
        let f = Self.resize(codeFont, size)
        traitFonts[key] = f
        return f
    }

    // MARK: Line metrics

    /// Target line height (CSS-like: glyphs centered, half-leading above and below).
    public func lineHeight(for font: NSFont, kind: LineMetrics.Kind) -> CGFloat {
        switch kind {
        case .heading: round(font.pointSize * CGFloat(settings.number("headings.lineHeight") ?? 1.3))
        case .code: round(font.pointSize * CGFloat(settings.number("code.lineHeight") ?? 1.55))
        default: round(font.pointSize * lineSpacing)
        }
    }

    /// Smallest height of a blank line holding the caret, so the caret stays visible.
    public var blankLineHeight: CGFloat { round(fontSize * 0.75) }

    /// Space between two blocks (design §8.1), from the last line of the block above and the first
    /// line of the block below. How many blank lines the source has does not matter.
    public func blockGap(after previous: LineMetrics?, before next: LineMetrics) -> CGFloat {
        guard let previous else { return 0 }
        func em(_ key: String) -> CGFloat { round(fontSize * CGFloat(settings.number(key) ?? 0)) }
        if next.headingLevel > 0 { return em("h\(min(next.headingLevel, 6)).spaceAbove") }
        if previous.headingLevel > 0 { return em("h\(min(previous.headingLevel, 6)).spaceBelow") }
        if previous.isBlockLike || next.isBlockLike { return fontSize }
        // Items of one list stay tight, including the first item of a nested list.
        if next.isListItem, previous.listDepth > 0, !next.startsList || next.listDepth > previous.listDepth { return em("list.spacing") }
        return em("paragraph.spacing")
    }

    /// Above a line that follows a single line break in a paragraph: set apart from the lines the
    /// text wraps into (half an em), and at most half a paragraph's gap, so that the Return that
    /// turns the line into a new paragraph still moves the caret visibly (design §8.1).
    public var lineBreakGap: CGFloat { round(fontSize * min(0.5, CGFloat(settings.number("paragraph.spacing") ?? 0) / 2)) }
}
