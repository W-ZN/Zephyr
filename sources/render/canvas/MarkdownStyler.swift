import AppKit
import ZephyrCore

/// Applies a chunk analysis as attributes. The presenter removes hidden syntax from display
/// text and maps rendered components back to their original source ranges.
final class MarkdownStyler {
    let typography: Typography
    unowned let context: RenderContext
    private var paragraphStyles: [String: NSParagraphStyle] = [:]

    /// Room a key's box takes beyond its text on each side, and the gap between two adjacent keys.
    static let keyPadding: CGFloat = 3
    static let keyGap: CGFloat = 2

    /// A key gets its padding as kerning: after the character before `<kbd>` and after its own last
    /// character, wider when another key follows at once (`</kbd><kbd>`).
    private func keyRoom(_ r: NSRange, in storage: NSMutableAttributedString) {
        let string = storage.string as NSString
        let closeEnd = NSMaxRange(r) + "</kbd>".utf16.count
        let adjacent = closeEnd < string.length && string.character(at: closeEnd) == 0x3C
        storage.addAttribute(.kern, value: Self.keyPadding + (adjacent ? Self.keyPadding + Self.keyGap : 0), range: NSRange(location: NSMaxRange(r) - 1, length: 1))
        let before = r.location - "<kbd>".utf16.count - 1
        if before >= 0, [0x20, 0x09].contains(string.character(at: before)) {
            storage.addAttribute(.kern, value: Self.keyPadding, range: NSRange(location: before, length: 1))
        }
    }

    /// A fenced block's code (its lines between the fences) in its language's colors.
    private func colorCode(_ block: CodeBlockToken, _ language: CodeSyntax.Language, in a: ChunkAnalysis, base: Int, storage: NSMutableAttributedString) {
        // Lines are in order: find the block's first one, then walk to its end.
        var low = 0, high = a.lines.count
        while low < high {
            let mid = (low + high) / 2
            if a.lines[mid].range.location < block.range.location { low = mid + 1 } else { high = mid }
        }
        var first: LineInfo?, last: LineInfo?
        for line in a.lines[low...] {
            guard NSLocationInRange(line.range.location, block.range) else { break }
            if line.kind == .code { first = first ?? line; last = line }
        }
        guard let first, let last else { return }
        let code = NSRange(location: base + first.range.location, length: NSMaxRange(last.range) - first.range.location)
        for token in CodeSyntax.tokens((storage.string as NSString).substring(with: code), language: language) {
            storage.addAttribute(.foregroundColor, value: Palette.syntax(token.role), range: NSRange(location: code.location + token.range.location, length: token.range.length))
        }
    }

    init(typography: Typography, context: RenderContext) {
        self.typography = typography
        self.context = context
    }

    func style(_ a: ChunkAnalysis, at base: Int, in storage: NSMutableAttributedString) {
        let string = storage.string as NSString
        // Lines and code blocks are both in document order: one walk marks the code lines.
        var codeLines = Set<Int>()
        var lineIndex = 0
        for block in a.codeBlocks {
            while lineIndex < a.lines.count, a.lines[lineIndex].range.location < block.range.location { lineIndex += 1 }
            var j = lineIndex
            while j < a.lines.count, NSLocationInRange(a.lines[j].range.location, block.range) { codeLines.insert(j); j += 1 }
        }
        for (i, line) in a.lines.enumerated() {
            let r = NSRange(location: base + line.range.location, length: line.range.length)
            guard r.length > 0 || r.location < storage.length else { continue }
            storage.setAttributes(lineAttributes(line, index: i, in: a, isCode: codeLines.contains(i)), range: r)
        }
        for block in a.codeBlocks {
            storage.addAttribute(.zCodeBlock, value: CodeBlockBox(language: block.language, isFenced: block.isFenced), range: shift(block.range, base))
            if typography.syntaxColors, block.isFenced, let language = CodeSyntax.language(block.language) { colorCode(block, language, in: a, base: base, storage: storage) }
        }
        for token in a.inlines { applyInline(token, base: base, storage: storage) }
        for m in a.markers {
            let r = shift(m.range, base)
            switch m.style {
            case .hide:
                storage.addAttributes([.zHide: true, .foregroundColor: Palette.faint], range: r)
            case .structural:
                storage.addAttribute(.zStructural, value: true, range: r)
            case let .bullet(depth):
                storage.addAttribute(.zListMarker, value: ListMarkerBox(.bullet(depth: depth)), range: r)
            case .ordinal:
                let text = string.substring(with: r).trimmingCharacters(in: .whitespaces)
                storage.addAttribute(.zListMarker, value: ListMarkerBox(.ordinal(text)), range: r)
            case let .checkbox(checked):
                storage.addAttribute(.zListMarker, value: ListMarkerBox(.checkbox(checked: checked)), range: r)
                if checked, let line = a.lines.first(where: { NSLocationInRange(m.range.location, $0.range) }) {
                    let end = base + line.range.location + line.range.length
                    let rest = NSRange(location: NSMaxRange(r), length: max(0, end - NSMaxRange(r)))
                    storage.addAttribute(.foregroundColor, value: Palette.muted, range: rest)
                }
            }
        }
        for c in a.components {
            let r = shift(c.range, base)
            guard r.length > 0 else { continue }
            // With formulas or diagrams off (math.render, diagram.render), their source stays as text.
            switch c.kind {
            case .displayMath, .inlineMath: if !typography.mathRender { continue }
            case .diagram: if !typography.diagramRender { continue }
            default: break
            }
            let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont ?? typography.bodyFont
            let box = ComponentBox.make(c.kind, fontSize: font.pointSize, context: context)
            box.lastKnownRange = r
            storage.addAttribute(.zComponent, value: box, range: r)
        }
        guard !a.isPlain else { return }
        // Every marker is hidden text for spacing; sorted once, then each line starts its walk at the
        // first marker that does not end before it.
        let hidden = a.markers.map { shift($0.range, base) }.sorted { $0.location < $1.location }
        var firstHidden = 0
        for (i, line) in a.lines.enumerated() where !codeLines.contains(i) {
            switch line.kind {
            case .paragraph, .heading:
                let r = NSRange(location: base + line.range.location, length: line.range.length)
                while firstHidden < hidden.count, NSMaxRange(hidden[firstHidden]) <= r.location { firstHidden += 1 }
                autospace(r, hidden: hidden, from: firstHidden, storage: storage, string: string)
            default: break
            }
        }
    }

    private func shift(_ r: NSRange, _ base: Int) -> NSRange { NSRange(location: r.location + base, length: r.length) }

    // MARK: Lines

    private func lineAttributes(_ line: LineInfo, index: Int, in a: ChunkAnalysis, isCode: Bool) -> [NSAttributedString.Key: Any] {
        let indent = CGFloat(line.listDepth) * typography.listIndent + CGFloat(line.quoteDepth) * typography.quoteIndent
        var font = typography.bodyFont
        var color: NSColor = line.quoteDepth > 0 ? Palette.muted : Palette.text
        let metrics: LineMetrics
        var codeInset: CGFloat = 0
        let starts = line.startsBlock || line.isListItemStart
        switch line.kind {
        case let .heading(level):
            font = typography.headingFont(level: level)
            if line.quoteDepth == 0 { color = Palette.heading(level: level) }
            metrics = LineMetrics(kind: .heading, font: font, lineHeight: typography.lineHeight(for: font, kind: .heading),
                                  quoteDepth: line.quoteDepth, listDepth: line.listDepth, quoteBase: line.quoteListBase, indent: indent,
                                  headingLevel: level, startsBlock: starts, isListItem: line.isListItemStart, startsList: line.startsList)
        case .setextUnderline:
            color = Palette.faint
            var level = 1
            if index > 0, case let .heading(l) = a.lines[index - 1].kind { level = l }
            metrics = LineMetrics(kind: .setextUnderline, font: font, lineHeight: typography.lineHeight(for: font, kind: .body),
                                  quoteDepth: line.quoteDepth, listDepth: line.listDepth, quoteBase: line.quoteListBase, indent: indent, headingLevel: level)
        case .codeFence:
            // Collapsed or shown, the fence keeps its band (the shown height is set by the same rounding).
            font = typography.fenceFont
            color = Palette.faint
            codeInset = typography.codePadding
            let band = typography.fenceBand
            let leading = max(0, (band - font.ascender + font.descender) / 2)
            metrics = LineMetrics(kind: .fence, font: font, lineHeight: band,
                                  collapsedHeight: round(font.ascender + leading) + round(-font.descender + leading), quoteDepth: line.quoteDepth, listDepth: line.listDepth, quoteBase: line.quoteListBase, indent: indent,
                                  startsBlock: starts, isListItem: line.isListItemStart, startsList: line.startsList)
        case .code:
            font = typography.codeFont
            codeInset = typography.codePadding
            // Indented code has no fence lines to carry the padding.
            let fenced = a.codeBlocks.first { NSLocationInRange(line.range.location, $0.range) }?.isFenced ?? true
            let first = index == 0 || a.lines[index - 1].kind != .code
            let last = index == a.lines.count - 1 || a.lines[index + 1].kind != .code
            let pad = fenced ? 0 : round(typography.codePadding * 0.85)
            metrics = LineMetrics(kind: .code, font: font, lineHeight: typography.lineHeight(for: font, kind: .code),
                                  spacingBefore: first ? pad : 0, spacingAfter: last ? pad : 0,
                                  quoteDepth: line.quoteDepth, listDepth: line.listDepth, quoteBase: line.quoteListBase, indent: indent,
                                  startsBlock: starts, isListItem: line.isListItemStart, startsList: line.startsList)
        case .html:
            font = typography.codeFont
            color = Palette.muted
            metrics = LineMetrics(kind: .code, font: font, lineHeight: typography.lineHeight(for: font, kind: .code),
                                  quoteDepth: line.quoteDepth, listDepth: line.listDepth, quoteBase: line.quoteListBase, indent: indent,
                                  startsBlock: starts, isListItem: line.isListItemStart, startsList: line.startsList)
        case .component:
            font = typography.codeFont
            color = Palette.muted
            metrics = LineMetrics(kind: .component, font: font, lineHeight: typography.lineHeight(for: font, kind: .code),
                                  quoteDepth: line.quoteDepth, listDepth: line.listDepth, quoteBase: line.quoteListBase, indent: indent,
                                  startsBlock: starts, isListItem: line.isListItemStart, startsList: line.startsList)
        case .blank:
            metrics = LineMetrics(kind: isCode ? .code : .blank, font: isCode ? typography.codeFont : font,
                                  lineHeight: isCode ? typography.lineHeight(for: typography.codeFont, kind: .code) : typography.blankLineHeight,
                                  quoteDepth: line.quoteDepth, listDepth: line.listDepth, quoteBase: line.quoteListBase, indent: indent)
            if isCode {
                font = typography.codeFont
                codeInset = typography.codePadding
            }
        case .paragraph:
            metrics = LineMetrics(kind: .body, font: font, lineHeight: typography.lineHeight(for: font, kind: .body),
                                  quoteDepth: line.quoteDepth, listDepth: line.listDepth, quoteBase: line.quoteListBase, indent: indent,
                                  startsBlock: starts, isListItem: line.isListItemStart, startsList: line.startsList)
        }
        // Body text takes the theme's alignment, and a paragraph's first line its indent (never
        // list items: their marker already marks the start).
        let prose = line.kind == .paragraph
        let first = prose && line.startsBlock && line.listDepth == 0 ? typography.paragraphIndent : 0
        // A numbered heading's text starts after its number's slot, wrapped lines included.
        var slot: CGFloat = 0
        if case let .heading(level) = line.kind, line.quoteDepth == 0, line.listDepth == 0 { slot = typography.numberSlot(level: level) }
        let gutter = codeInset > 0 ? typography.codeGutter : 0
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle(indent: indent + codeInset + gutter + slot, first: first, tail: codeInset, alignment: prose ? typography.alignment : .natural), .zLine: metrics]
    }

    private func paragraphStyle(indent: CGFloat, first: CGFloat, tail: CGFloat, alignment: NSTextAlignment) -> NSParagraphStyle {
        let key = "\(indent)|\(first)|\(tail)|\(alignment.rawValue)"
        if let p = paragraphStyles[key] { return p }
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = indent + first
        p.headIndent = indent
        p.tailIndent = -tail
        p.alignment = alignment
        p.lineBreakMode = .byWordWrapping
        p.lineBreakStrategy = .standard
        paragraphStyles[key] = p
        return p
    }

    // MARK: Inline

    private func applyInline(_ token: InlineToken, base: Int, storage: NSMutableAttributedString) {
        let r = shift(token.range, base)
        guard r.length > 0 else { return }
        switch token.style {
        case .strong, .emphasis:
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                guard let f = value as? NSFont else { return }
                storage.addAttribute(.font, value: typography.withTraits(f, bold: token.style == .strong, italic: token.style == .emphasis), range: sub)
            }
        case .strikethrough:
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: Palette.muted, .foregroundColor: Palette.muted], range: r)
        case .code:
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                let f = value as? NSFont ?? typography.bodyFont
                storage.addAttribute(.font, value: typography.inlineCodeFont(for: f), range: sub)
            }
            storage.addAttribute(.zInlineCode, value: true, range: r)
        case let .link(destination):
            storage.addAttribute(.foregroundColor, value: Palette.link, range: r)
            if let destination { storage.addAttribute(.zLink, value: destination, range: r) }
        case .html:
            storage.addAttribute(.foregroundColor, value: Palette.muted, range: r)
        case .keycap, .highlight:
            if token.style == .keycap {
                storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                    storage.addAttribute(.font, value: typography.inlineCodeFont(for: value as? NSFont ?? typography.bodyFont), range: sub)
                }
            }
            // Each element its own value, so `<kbd>⌘</kbd><kbd>K</kbd>` draws two keys, not one.
            storage.addAttribute(.zInlineCode, value: (token.style == .keycap ? "keycap:" : "mark:") + String(r.location), range: r)
            if token.style == .keycap { keyRoom(r, in: storage) }
        case .superscript, .subscript, .small:
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                let f = value as? NSFont ?? typography.bodyFont
                var a: [NSAttributedString.Key: Any] = [.font: Typography.resize(f, round(f.pointSize * (token.style == .small ? 0.85 : 0.75) * 2) / 2)]
                if token.style != .small {
                    // The canvas draws with a flipped text matrix: a negative offset raises the glyphs.
                    a[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] = token.style == .superscript ? -round(f.pointSize * 0.35) : round(f.pointSize * 0.15)
                }
                storage.addAttributes(a, range: sub)
            }
        case .underline:
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
        }
    }

    // MARK: CJK / Latin spacing

    /// Adds a quarter-em of kerning between CJK and Latin letters or digits (design §8:
    /// mixed CJK/Latin spacing is a core requirement). Text bytes are untouched.
    private func autospace(_ line: NSRange, hidden: [NSRange], from first: Int, storage: NSMutableAttributedString, string: NSString) {
        guard line.length > 1 else { return }
        var nextHidden = first
        var previous: (index: Int, width: Int, cjk: Bool, latin: Bool)?
        var cjkRun: Int?
        let unkernCJK = typography.disablesCJKKerning
        var i = line.location
        let end = NSMaxRange(line)
        var buffer = [unichar](repeating: 0, count: line.length)
        string.getCharacters(&buffer, range: line)
        while i < end {
            // Walk the sorted hidden ranges alongside the text: one pass, not one search per character.
            while nextHidden < hidden.count, NSMaxRange(hidden[nextHidden]) <= i { nextHidden += 1 }
            if nextHidden < hidden.count, NSLocationInRange(i, hidden[nextHidden]) {
                i = NSMaxRange(hidden[nextHidden])
                continue
            }
            var c = UInt32(buffer[i - line.location])
            var width = 1
            if UTF16.isLeadSurrogate(UInt16(c)), i + 1 < end {
                c = 0x10000 + ((c - 0xD800) << 10) + (UInt32(buffer[i + 1 - line.location]) - 0xDC00)
                width = 2
            }
            let cjk = Self.isCJK(c)
            let latin = Self.isLatin(c)
            if unkernCJK {
                let wide = cjk || Self.isCJKPunctuation(c)
                if wide, cjkRun == nil { cjkRun = i }
                if !wide, let start = cjkRun {
                    storage.addAttribute(.kern, value: 0, range: NSRange(location: start, length: i - start))
                    cjkRun = nil
                }
            }
            if let p = previous, (p.cjk && latin) || (p.latin && cjk) {
                let font = storage.attribute(.font, at: p.index, effectiveRange: nil) as? NSFont ?? typography.bodyFont
                storage.addAttribute(.kern, value: round(font.pointSize * 0.22 * 2) / 2, range: NSRange(location: p.index, length: p.width))
            }
            previous = (i, width, cjk, latin)
            i += width
        }
        if let start = cjkRun { storage.addAttribute(.kern, value: 0, range: NSRange(location: start, length: end - start)) }
    }

    static func isCJK(_ c: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(c) || (0x3400...0x4DBF).contains(c) || (0x3040...0x30FF).contains(c)
            || (0xAC00...0xD7AF).contains(c) || (0xF900...0xFAFF).contains(c) || (0x20000...0x2FFFF).contains(c)
    }

    /// CJK symbols and punctuation, and full-width forms (、。，：「」（）…).
    static func isCJKPunctuation(_ c: UInt32) -> Bool {
        (0x3000...0x303F).contains(c) || (0xFF00...0xFFEF).contains(c)
    }

    static func isLatin(_ c: UInt32) -> Bool {
        (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
            || ((0xC0...0x24F).contains(c) && c != 0xD7 && c != 0xF7)
    }
}
