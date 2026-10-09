import Foundation

/// Text statistics for the top bar (design §8): one prose stream — paragraphs, headings, list,
/// quote and table text, link labels and inline code — without Markdown markers, link targets,
/// front matter, comments, image descriptions, fenced code, formulas or diagrams. One linear pass
/// over the source, cheap enough to run off the main thread after edits.
public struct TextStatistics: Equatable, Sendable {
    /// Han characters (and kana) one each, plus runs of other letters and digits.
    public var words = 0
    public var hanUnits = 0
    /// Grapheme clusters without whitespace; punctuation counts.
    public var characters = 0
    /// The same with spaces and tabs; line breaks never count.
    public var charactersWithSpaces = 0
    public var paragraphs = 0
    public var headings = 0

    public init() {}

    public var otherWords: Int { words - hanUnits }

    /// Reading time in minutes: 400 Han characters or 220 other words a minute.
    public var readingMinutes: Double { Double(hanUnits) / 400 + Double(otherWords) / 220 }

    /// Statistics of `text`, or of the part of it in `range` (a selection). Block state (fences,
    /// front matter, tables) is followed from the start either way.
    public static func count(_ text: NSString, in range: NSRange? = nil) -> TextStatistics {
        var s = TextStatistics()
        let limit = range ?? NSRange(location: 0, length: text.length)
        enum Block { case none, paragraph, listParagraph, table }
        var block = Block.none
        var paragraphLines = 0
        var paragraphCounted = false
        var firstLineHadPipe = false
        var fence: Fence?
        var inMath = false
        var inComment = false
        var inFrontMatter = false
        var pos = 0
        var lineIndex = 0
        while pos < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: pos, length: 0))
            defer { pos = end; lineIndex += 1 }
            if start >= NSMaxRange(limit), limit.length > 0 || start > limit.location { break }
            let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
            let units = ArraySlice(Array(line.utf16))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Front matter: only as the first lines of the file.
            if lineIndex == 0, trimmed == "---" { inFrontMatter = true; continue }
            if inFrontMatter {
                if trimmed == "---" || trimmed == "..." { inFrontMatter = false }
                continue
            }
            if inComment {
                if line.contains("-->") { inComment = false }
                continue
            }
            if let f = fence {
                if f.isClosed(by: units) { fence = nil }
                continue
            }
            if inMath {
                if trimmed.hasSuffix("$$") { inMath = false }
                continue
            }
            if let f = Fence(opening: units) {
                fence = f
                block = .none
                continue
            }
            if let at = Fence.opensMathBlock(units) {
                // `$$ x $$` on one line is a whole formula.
                let rest = units[(at + 2)...]
                if !String(decoding: rest, as: UTF16.self).contains("$$") { inMath = true }
                block = .none
                continue
            }
            if trimmed.isEmpty { block = .none; continue }
            if trimmed.hasPrefix("<!--") {
                if !trimmed.contains("-->") { inComment = true }
                continue
            }
            // Container prefixes: quote markers, a list marker, a task box.
            let prefix = Self.prefix(units)
            var k = units.startIndex + prefix.length
            while k < units.endIndex, units[k] == 0x20 || units[k] == 0x09 { k += 1 }
            let contentStart = start + (k - units.startIndex)
            let content = String(decoding: units[k...], as: UTF16.self).trimmingCharacters(in: .whitespaces)
            if content.isEmpty { block = .none; continue }
            let lineRange = NSRange(location: contentStart, length: contentsEnd - contentStart)
            let selected = NSIntersectionRange(lineRange, limit)
            let inSelection = selected.length > 0 || (limit.length == 0 && limit.location >= lineRange.location && limit.location <= NSMaxRange(lineRange))
            // The part of the line counted, in UTF-16 offsets of `content`: all of it, or the
            // selected part (read as part of the whole line, so a selected link target stays out).
            let window = range == nil ? nil : (selected.location - contentStart)..<(NSMaxRange(selected) - contentStart)
            if !prefix.item, Self.isUnderline(content) {
                // A setext heading: the paragraph above was its text.
                if block == .paragraph {
                    if paragraphCounted { s.paragraphs -= 1; s.headings += 1 }
                    block = .none
                    continue
                }
            }
            if Self.isThematicBreak(content) { block = .none; continue }
            if (block == .paragraph || block == .listParagraph), paragraphLines == 1, firstLineHadPipe, Self.isDelimiterRow(content) {
                // The line above was a table's header row, not a paragraph.
                if paragraphCounted { s.paragraphs -= 1 }
                block = .table
                continue
            }
            if block == .table, content.contains("|") {
                if range == nil || selected.length > 0 { s.add(content, window: window) }
                continue
            }
            if content.hasPrefix("["), content.range(of: #"^\[[^\]]+\]:\s"#, options: .regularExpression) != nil { continue }
            if let title = Self.atxHeading(content) {
                if inSelection { s.headings += 1 }
                if range == nil || selected.length > 0 {
                    let at = (content as NSString).range(of: title).location
                    s.add(title, window: window.map { ($0.lowerBound - at)..<($0.upperBound - at) })
                }
                block = .none
                continue
            }
            let starts = prefix.item || (block != .paragraph && block != .listParagraph)
            if starts {
                paragraphCounted = inSelection
                if inSelection { s.paragraphs += 1 }
                paragraphLines = 0
                firstLineHadPipe = content.contains("|")
            } else if inSelection {
                // A soft line break reads as one space.
                if paragraphCounted { s.charactersWithSpaces += 1 } else { s.paragraphs += 1; paragraphCounted = true }
            }
            paragraphLines += 1
            if range == nil || selected.length > 0 { s.add(content, window: window) }
            block = prefix.item || block == .listParagraph ? .listParagraph : .paragraph
        }
        return s
    }

    // MARK: Lines

    /// Quote markers, indentation, one list marker and a task box at the start of a line.
    static func prefix(_ line: ArraySlice<UInt16>) -> (length: Int, item: Bool) {
        var i = line.startIndex
        let n = line.endIndex
        var item = false
        while i < n {
            let c = line[i]
            if c == 0x20 || c == 0x09 || c == 0x3E { i += 1; continue }
            break
        }
        // A list marker: -, *, + or 1. / 1) followed by a space.
        if i < n, line[i] == 0x2D || line[i] == 0x2A || line[i] == 0x2B, i + 1 < n, line[i + 1] == 0x20 || line[i + 1] == 0x09 {
            // `- - -` and `* * *` are breaks, not items.
            let rest = String(decoding: line[i...], as: UTF16.self)
            if !isThematicBreak(rest.trimmingCharacters(in: .whitespaces)) { i += 2; item = true }
        } else if i < n, line[i] >= 0x30 && line[i] <= 0x39 {
            var j = i
            while j < n, j - i < 9, line[j] >= 0x30 && line[j] <= 0x39 { j += 1 }
            if j + 1 < n, line[j] == 0x2E || line[j] == 0x29, line[j + 1] == 0x20 || line[j + 1] == 0x09 { i = j + 2; item = true }
        }
        if item {
            while i < n, line[i] == 0x20 || line[i] == 0x09 { i += 1 }
            // [ ] / [x] task box
            if i + 2 < n, line[i] == 0x5B, line[i + 2] == 0x5D, line[i + 1] == 0x20 || line[i + 1] == 0x78 || line[i + 1] == 0x58 {
                i += 3
            }
        }
        return (i - line.startIndex, item)
    }

    static func atxHeading(_ content: String) -> String? {
        guard content.hasPrefix("#") else { return nil }
        let hashes = content.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = content.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s after a space is not part of the title.
        if let r = title.range(of: #"(^|\s)#+$"#, options: .regularExpression) { title = String(title[..<r.lowerBound]) }
        return title
    }

    static func isUnderline(_ content: String) -> Bool {
        guard let first = content.first, first == "=" || first == "-" else { return false }
        return content.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == first }
    }

    static func isThematicBreak(_ content: String) -> Bool {
        guard let first = content.first, first == "-" || first == "*" || first == "_" else { return false }
        var marks = 0
        for c in content.unicodeScalars {
            if c == " " || c == "\t" { continue }
            guard Character(c) == first else { return false }
            marks += 1
        }
        return marks >= 3
    }

    static func isDelimiterRow(_ content: String) -> Bool {
        content.contains("-") && content.range(of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$"#, options: .regularExpression) != nil
    }

    // MARK: Inline

    public static func isHan(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0x20000...0x2FA1F).contains(v) || (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
    }

    /// Scalars that belong to the character before them: combining marks, variation selectors,
    /// emoji modifiers, and whatever a zero-width joiner joins on.
    private static func extends(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        if v < 0x300 { return false }
        if v == 0x200D || (0xFE00...0xFE0F).contains(v) || (0x1F3FB...0x1F3FF).contains(v) || (0xE0020...0xE007F).contains(v) { return true }
        switch u.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark: return true
        default: return false
        }
    }

    /// Counts one piece of a line as read, scalar by scalar: link labels without their targets,
    /// code spans as written, and no images, footnote marks, tags, comments or inline formulas.
    /// `*`, `~` and `|` are Markdown; `_` is one except between letters (snake_case); a backslash
    /// escapes the next character. A character's marks and joined parts count with it.
    /// Only what lies in `window` (UTF-16 offsets of `text`) counts, a word it cuts included.
    mutating func add(_ text: String, window: Range<Int>? = nil) {
        let a = Array(text.unicodeScalars)
        var counted = a.indices
        if let window {
            var lo = a.count, hi = a.count, offset = 0
            for (i, u) in a.enumerated() {
                if lo == a.count, offset >= window.lowerBound { lo = i }
                if offset >= window.upperBound { hi = i; break }
                offset += UTF16.width(u)
            }
            counted = lo..<max(lo, hi)
        }
        scan(a[...], literal: false, pairs: Self.pairs(a), counted: counted)
    }

    /// Each `[` and `(` with the bracket that closes it, nested: found in one pass, so a line of
    /// unclosed brackets costs no more than any other.
    private static func pairs(_ a: [Unicode.Scalar]) -> [Int: Int] {
        var pairs: [Int: Int] = [:], squares: [Int] = [], rounds: [Int] = []
        for (i, u) in a.enumerated() {
            switch u {
            case "[": squares.append(i)
            case "]": if let open = squares.popLast() { pairs[open] = i }
            case "(": rounds.append(i)
            case ")": if let open = rounds.popLast() { pairs[open] = i }
            default: break
            }
        }
        return pairs
    }

    private mutating func scan(_ a: ArraySlice<Unicode.Scalar>, literal: Bool, pairs: [Int: Int], counted: Range<Int>) {
        func wordy(_ u: Unicode.Scalar) -> Bool {
            if u.isASCII { return (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || (u >= "0" && u <= "9") }
            let p = u.properties
            return (p.isAlphabetic || p.numericType != nil) && !Self.isHan(u.value)
        }
        func isNumber(_ u: Unicode.Scalar) -> Bool { u.isASCII ? u >= "0" && u <= "9" : u.properties.numericType != nil }
        func isSpace(_ u: Unicode.Scalar) -> Bool { u.isASCII ? u == " " || u == "\t" || u == "\n" || u == "\r" : u.properties.isWhitespace }
        // Where a search for a closing character (or a run of backticks) came up empty: any later
        // search for it does too, so none is repeated.
        var missing: [Unicode.Scalar: Int] = [:], unclosedTicks: [Int: Int] = [:]
        func find(_ target: Unicode.Scalar, from: Int) -> Int? {
            if let m = missing[target], from >= m { return nil }
            var j = from
            while j < a.endIndex { if a[j] == target { return j }; j += 1 }
            missing[target] = min(from, missing[target] ?? from)
            return nil
        }
        /// `[label](target)` or `[label][ref]` starting at `i`: where the label ends and the whole ends.
        func link(at i: Int) -> (label: Int, end: Int)? {
            guard let j = pairs[i], j + 1 < a.endIndex else { return nil }
            if a[j + 1] == "[", let close = find("]", from: j + 2) { return (j, close + 1) }
            guard a[j + 1] == "(", let k = pairs[j + 1] else { return nil }
            return (j, k + 1)
        }
        var inRun = false
        var joined = false
        var i = a.startIndex
        while i < a.endIndex {
            let u = a[i]
            if !literal {
                switch u {
                case "`":
                    var k = i
                    while k < a.endIndex, a[k] == "`" { k += 1 }
                    let ticks = k - i
                    var j = k
                    var close: Int?
                    while j < a.endIndex, k < unclosedTicks[ticks] ?? .max {
                        guard a[j] == "`" else { j += 1; continue }
                        var m = j
                        while m < a.endIndex, a[m] == "`" { m += 1 }
                        if m - j == ticks { close = j; break }
                        j = m
                    }
                    if close == nil { unclosedTicks[ticks] = min(k, unclosedTicks[ticks] ?? k) }
                    if let close {
                        scan(a[k..<close], literal: true, pairs: pairs, counted: counted)
                        i = close + ticks
                        inRun = false
                        continue
                    }
                case "!" where i + 1 < a.endIndex && a[i + 1] == "[":
                    if let l = link(at: i + 1) { i = l.end; inRun = false; continue }
                case "[":
                    if i + 1 < a.endIndex, a[i + 1] == "^", let close = find("]", from: i + 2) { i = close + 1; continue }
                    if let l = link(at: i) {
                        scan(a[(i + 1)..<l.label], literal: false, pairs: pairs, counted: counted)
                        i = l.end
                        inRun = false
                        continue
                    }
                case "<":
                    if i + 1 < a.endIndex, a[i + 1].properties.isAlphabetic || a[i + 1] == "/" || a[i + 1] == "!", let close = find(">", from: i + 1) {
                        i = close + 1
                        inRun = false
                        continue
                    }
                case "$":
                    // $x$: no space inside either end, not a price ($5 and $6).
                    if i + 1 < a.endIndex, a[i + 1] != "$", !isSpace(a[i + 1]), i == a.startIndex || a[i - 1] != "\\" {
                        var j = i + 1
                        while j < a.endIndex, a[j] != "$" { j += 1 }
                        if j < a.endIndex, !isSpace(a[j - 1]), j + 1 == a.endIndex || !isNumber(a[j + 1]) {
                            i = j + 1
                            inRun = false
                            continue
                        }
                    }
                case "\\" where i + 1 < a.endIndex && a[i + 1].properties.generalCategory.isPunctuationOrSymbol:
                    // The escaped character is text, whatever it is.
                    i += 1
                    count(a[i], at: i)
                    i += 1
                    continue
                case "*", "~", "|":
                    inRun = false
                    i += 1
                    continue
                case "_" where !(i > a.startIndex && wordy(a[i - 1]) && i + 1 < a.endIndex && wordy(a[i + 1])):
                    inRun = false
                    i += 1
                    continue
                default:
                    break
                }
            }
            count(u, at: i)
            i += 1
        }

        func count(_ u: Unicode.Scalar, at i: Int) {
            guard counted.contains(i) else {
                inRun = false
                return
            }
            if Self.extends(u) {
                joined = u.value == 0x200D
                return
            }
            if joined {
                joined = false
                return
            }
            if isSpace(u) {
                if u != "\n", u != "\r" { charactersWithSpaces += 1 }
                inRun = false
                return
            }
            characters += 1
            charactersWithSpaces += 1
            if Self.isHan(u.value) {
                hanUnits += 1
                words += 1
                inRun = false
            } else if wordy(u) {
                if !inRun { words += 1 }
                inRun = true
            } else if inRun, i > a.startIndex, i + 1 < a.endIndex,
                      ("'’-_".unicodeScalars.contains(u) && wordy(a[i + 1])) || (".,".unicodeScalars.contains(u) && isNumber(a[i - 1]) && isNumber(a[i + 1])) {
                // Inside a word: don't, well-known, 3.14, 1,000.
            } else {
                inRun = false
            }
        }
    }
}

extension Unicode.GeneralCategory {
    var isPunctuationOrSymbol: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: true
        default: false
        }
    }
}
