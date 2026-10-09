import AppKit

/// Lightweight Markdown coloring for source mode. It only examines the unit being shaped, so
/// opening and editing a large source document never requires a document-wide Markdown parse.
enum SourceSyntax {
    /// Styling a gigantic source line would make every viewport layout run several full scans.
    /// It remains editable as plain source, matching the document router's long-line boundary.
    static let maximumStyledLength = 20_000

    static func highlight(_ source: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let styled = NSMutableAttributedString(string: source, attributes: attributes)
        guard styled.length > 0, styled.length <= maximumStyledLength else { return styled }
        let text = source as NSString

        let fence = styleBlockMarkers(in: text, storage: styled)
        styleHTML(in: text, storage: styled)
        styleLinks(in: text, storage: styled)
        styleInlineCode(in: text, storage: styled)
        styleFormulaMarkers(in: text, storage: styled)
        if !fence { styleEmphasisMarkers(in: text, storage: styled) }
        return styled
    }

    /// Line-local structure: Markdown blocks whose syntax is useful while navigating a source file.
    /// A fence's contents remain ordinary source text because source units deliberately have no
    /// cross-line state.
    @discardableResult
    private static func styleBlockMarkers(in text: NSString, storage: NSMutableAttributedString) -> Bool {
        let length = text.length
        var start = 0
        while start < min(3, length), text.character(at: start) == 0x20 || text.character(at: start) == 0x09 { start += 1 }

        var cursor = start
        while cursor < length, text.character(at: cursor) == 0x3E {
            storage.addAttribute(.foregroundColor, value: syntaxColor(0.30), range: NSRange(location: cursor, length: 1))
            cursor += 1
            if cursor < length, text.character(at: cursor) == 0x20 { cursor += 1 }
        }
        if let heading = heading(at: cursor, in: text) {
            storage.addAttribute(.foregroundColor, value: headingColor(level: heading.level), range: heading.range)
            let tail = NSRange(location: NSMaxRange(heading.range), length: length - NSMaxRange(heading.range))
            if let closing = trailingHeadingMarker(in: text, range: tail) {
                storage.addAttribute(.foregroundColor, value: Palette.faint, range: closing)
            }
            return false
        }

        if cursor + 2 < length {
            let character = text.character(at: cursor)
            if (character == 0x60 || character == 0x7E), text.character(at: cursor + 1) == character, text.character(at: cursor + 2) == character {
                var end = cursor + 3
                while end < length, text.character(at: end) == character { end += 1 }
                storage.addAttribute(.foregroundColor, value: Palette.faint, range: NSRange(location: cursor, length: end - cursor))
                if end < length { storage.addAttribute(.foregroundColor, value: Palette.link, range: NSRange(location: end, length: length - end)) }
                return true
            }
        }

        if let marker = listMarker(at: cursor, in: text) {
            storage.addAttribute(.foregroundColor, value: Palette.faint, range: marker)
            cursor = NSMaxRange(marker)
        }
        if cursor + 2 < length, text.character(at: cursor) == 0x5B,
           (text.character(at: cursor + 1) == 0x20 || text.character(at: cursor + 1) == 0x78 || text.character(at: cursor + 1) == 0x58),
           text.character(at: cursor + 2) == 0x5D {
            storage.addAttribute(.foregroundColor, value: Palette.faint, range: NSRange(location: cursor, length: 3))
            if text.character(at: cursor + 1) != 0x20 {
                storage.addAttribute(.foregroundColor, value: Palette.accent, range: NSRange(location: cursor + 1, length: 1))
            }
        }

        var pipes: [Int] = []
        for index in 0..<length where text.character(at: index) == 0x7C { pipes.append(index) }
        if !pipes.isEmpty {
            if tableDivider(text) {
                storage.addAttribute(.foregroundColor, value: Palette.faint, range: NSRange(location: 0, length: length))
            } else {
                for index in pipes { storage.addAttribute(.foregroundColor, value: Palette.faint, range: NSRange(location: index, length: 1)) }
            }
        }
        return false
    }

    private static func heading(at start: Int, in text: NSString) -> (level: Int, range: NSRange)? {
        guard start < text.length, text.character(at: start) == 0x23 else { return nil }
        var end = start
        while end < text.length, text.character(at: end) == 0x23 { end += 1 }
        let level = end - start
        guard (1...6).contains(level), end == text.length || text.character(at: end) == 0x20 || text.character(at: end) == 0x09 else { return nil }
        return (level, NSRange(location: start, length: level))
    }

    private static func headingColor(level: Int) -> NSColor {
        let amount: CGFloat
        switch level {
        case 1: amount = 0.78
        case 2: amount = 0.66
        case 3: amount = 0.54
        case 4: amount = 0.42
        case 5: amount = 0.30
        default: amount = 0.18
        }
        return syntaxColor(amount)
    }

    private static func syntaxColor(_ amount: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.isDark
            return Palette.mix(Palette.resolved(.text, dark: dark), Palette.resolved(.accent, dark: dark), amount)
        }
    }

    private static func trailingHeadingMarker(in text: NSString, range: NSRange) -> NSRange? {
        var end = NSMaxRange(range)
        while end > range.location, text.character(at: end - 1) == 0x20 || text.character(at: end - 1) == 0x09 { end -= 1 }
        let markerEnd = end
        while end > range.location, text.character(at: end - 1) == 0x23 { end -= 1 }
        return end == markerEnd ? nil : NSRange(location: end, length: markerEnd - end)
    }

    private static func listMarker(at start: Int, in text: NSString) -> NSRange? {
        guard start < text.length else { return nil }
        let c = text.character(at: start)
        if (c == 0x2D || c == 0x2A || c == 0x2B), start + 1 < text.length, text.character(at: start + 1) == 0x20 {
            return NSRange(location: start, length: 2)
        }
        var end = start
        while end < text.length, (0x30...0x39).contains(text.character(at: end)) { end += 1 }
        guard end > start, end + 1 < text.length, (text.character(at: end) == 0x2E || text.character(at: end) == 0x29), text.character(at: end + 1) == 0x20 else { return nil }
        return NSRange(location: start, length: end + 2 - start)
    }

    private static func tableDivider(_ text: NSString) -> Bool {
        var hasDash = false
        for index in 0..<text.length {
            switch text.character(at: index) {
            case 0x20, 0x09, 0x7C, 0x3A: continue
            case 0x2D: hasDash = true
            default: return false
            }
        }
        return hasDash
    }

    private static func styleHTML(in text: NSString, storage: NSMutableAttributedString) {
        var index = 0
        while index < text.length {
            guard text.character(at: index) == 0x3C else { index += 1; continue }
            var end = index + 1
            while end < text.length, text.character(at: end) != 0x3E { end += 1 }
            guard end < text.length else { break }
            storage.addAttribute(.foregroundColor, value: Palette.muted, range: NSRange(location: index, length: end + 1 - index))
            index = end + 1
        }
    }

    private static func styleLinks(in text: NSString, storage: NSMutableAttributedString) {
        var index = 0
        while index < text.length {
            var bracket = index
            if text.character(at: bracket) == 0x21 { storage.addAttribute(.foregroundColor, value: Palette.faint, range: NSRange(location: bracket, length: 1)); bracket += 1 }
            guard bracket < text.length, text.character(at: bracket) == 0x5B else { index += 1; continue }
            var labelEnd = bracket + 1
            while labelEnd < text.length, text.character(at: labelEnd) != 0x5D { labelEnd += 1 }
            guard labelEnd < text.length else { break }
            guard labelEnd + 1 < text.length, text.character(at: labelEnd + 1) == 0x28 else { index = labelEnd + 1; continue }
            var destinationEnd = labelEnd + 2
            while destinationEnd < text.length, text.character(at: destinationEnd) != 0x29 { destinationEnd += 1 }
            guard destinationEnd < text.length else { break }
            storage.addAttribute(.foregroundColor, value: Palette.faint, range: NSRange(location: bracket, length: 1))
            storage.addAttribute(.foregroundColor, value: Palette.link, range: NSRange(location: bracket + 1, length: labelEnd - bracket - 1))
            storage.addAttribute(.foregroundColor, value: Palette.faint, range: NSRange(location: labelEnd, length: 2))
            storage.addAttribute(.foregroundColor, value: Palette.muted, range: NSRange(location: labelEnd + 2, length: destinationEnd - labelEnd - 2))
            storage.addAttribute(.foregroundColor, value: Palette.faint, range: NSRange(location: destinationEnd, length: 1))
            index = destinationEnd + 1
        }
    }

    private static func styleInlineCode(in text: NSString, storage: NSMutableAttributedString) {
        styleDelimited(in: text, delimiter: 0x60, storage: storage, contentColor: Palette.muted)
    }

    private static func styleFormulaMarkers(in text: NSString, storage: NSMutableAttributedString) {
        styleDelimited(in: text, delimiter: 0x24, storage: storage, contentColor: nil)
        styleEscapedFormulaMarkers(in: text, storage: storage, opening: 0x28, closing: 0x29)
        styleEscapedFormulaMarkers(in: text, storage: storage, opening: 0x5B, closing: 0x5D)
    }

    private static func styleEscapedFormulaMarkers(in text: NSString, storage: NSMutableAttributedString, opening: unichar, closing: unichar) {
        var index = 0
        while index + 1 < text.length {
            guard text.character(at: index) == 0x5C, text.character(at: index + 1) == opening else { index += 1; continue }
            var end = index + 2
            while end + 1 < text.length, !(text.character(at: end) == 0x5C && text.character(at: end + 1) == closing) { end += 1 }
            guard end + 1 < text.length else { break }
            storage.addAttribute(.foregroundColor, value: Palette.accent, range: NSRange(location: index, length: 2))
            storage.addAttribute(.foregroundColor, value: Palette.accent, range: NSRange(location: end, length: 2))
            index = end + 2
        }
    }

    private static func styleEmphasisMarkers(in text: NSString, storage: NSMutableAttributedString) {
        styleDelimited(in: text, delimiter: 0x2A, storage: storage, contentColor: nil)
        styleDelimited(in: text, delimiter: 0x5F, storage: storage, contentColor: nil)
        styleDelimited(in: text, delimiter: 0x7E, storage: storage, contentColor: nil)
    }

    private static func styleDelimited(in text: NSString, delimiter: unichar, storage: NSMutableAttributedString, contentColor: NSColor?) {
        var index = 0
        while index < text.length {
            guard text.character(at: index) == delimiter else { index += 1; continue }
            var count = 1
            while index + count < text.length, text.character(at: index + count) == delimiter { count += 1 }
            var end = index + count
            while end + count <= text.length {
                if (0..<count).allSatisfy({ text.character(at: end + $0) == delimiter }) { break }
                end += 1
            }
            guard end + count <= text.length else { index += count; continue }
            let marker = NSRange(location: index, length: count)
            storage.addAttribute(.foregroundColor, value: Palette.faint, range: marker)
            storage.addAttribute(.foregroundColor, value: Palette.faint, range: NSRange(location: end, length: count))
            if let contentColor, end > NSMaxRange(marker) {
                storage.addAttribute(.foregroundColor, value: contentColor, range: NSRange(location: NSMaxRange(marker), length: end - NSMaxRange(marker)))
            }
            index = end + count
        }
    }
}
