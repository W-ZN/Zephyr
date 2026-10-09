import Foundation

/// A `$…$` or `$$…$$` span found before Markdown parsing.
struct MathSpan: Equatable {
    var range: Range<Int>      // UTF-16, including delimiters
    var content: Range<Int>    // UTF-16, TeX source
    var display: Bool
    /// Opened by `$$` at the start of a line: a block that may span lines (and blank lines).
    var isBlock: Bool
}

/// Finds TeX math before cmark sees the text, so escapes, `*` and `_` inside formulas are not
/// interpreted as Markdown. Fenced code is opaque, code spans win over math, `\$` is a literal
/// dollar, and inline closers are only searched within the current paragraph.
enum MathScanner {
    private static let dollar: UInt16 = 0x24, backslash: UInt16 = 0x5C, backtick: UInt16 = 0x60
    private static let newline: UInt16 = 0x0A, carriageReturn: UInt16 = 0x0D

    static func scan(_ t: TextLines) -> [MathSpan] {
        let u = t.units
        let n = u.count
        var spans: [MathSpan] = []
        // Line pass: fenced code and `$$` blocks become opaque regions; blank lines end paragraphs.
        var opaque: [Range<Int>] = []
        var blankStarts: [Int] = []
        var line = 0
        while line < t.lineCount {
            let start = t.lineStarts[line], end = t.contentEnd(ofLine: line)
            if t.isBlank(line: line) {
                blankStarts.append(start)
                line += 1
                continue
            }
            let text = u[start..<end]
            if let fence = Fence(opening: text) {
                var last = line + 1
                while last < t.lineCount, !fence.isClosed(by: u[t.lineStarts[last]..<t.contentEnd(ofLine: last)]) { last += 1 }
                opaque.append(start..<(last < t.lineCount ? t.fullEnd(ofLine: last) : n))
                line = last + 1
                continue
            }
            if let open = Fence.opensMathBlock(text), let close = closingDisplay(u, from: open + 2, limit: n),
               restIsBlank(u, from: close + 2) {
                spans.append(MathSpan(range: open..<(close + 2), content: (open + 2)..<close, display: true, isBlock: true))
                opaque.append(open..<(close + 2))
                line = t.line(containing: close + 1) + 1
                continue
            }
            line += 1
        }

        var i = 0, k = 0, b = 0
        var inline: [MathSpan] = []
        while i < n {
            if k < opaque.count, i >= opaque[k].lowerBound {
                i = max(i, opaque[k].upperBound)
                k += 1
                continue
            }
            while b < blankStarts.count, blankStarts[b] <= i { b += 1 }
            let limit = min(b < blankStarts.count ? blankStarts[b] : n, k < opaque.count ? opaque[k].lowerBound : n)
            let c = u[i]
            if c == backslash {
                i += 2
                continue
            }
            if c == backtick {
                var run = 0
                while i + run < limit, u[i + run] == backtick { run += 1 }
                if let close = closingBacktickRun(u, from: i + run, length: run, limit: limit) {
                    i = close + run
                } else {
                    i += run
                }
                continue
            }
            if c == dollar {
                if i + 1 < limit, u[i + 1] == dollar {
                    if let close = closingDisplay(u, from: i + 2, limit: limit), close > i + 2 {
                        inline.append(MathSpan(range: i..<(close + 2), content: (i + 2)..<close, display: true, isBlock: false))
                        i = close + 2
                        continue
                    }
                    i += 2
                    continue
                }
                if let close = closingInline(u, from: i + 1, limit: limit) {
                    inline.append(MathSpan(range: i..<(close + 1), content: (i + 1)..<close, display: false, isBlock: false))
                    i = close + 1
                    continue
                }
            }
            i += 1
        }
        if spans.isEmpty { return inline }
        return (spans + inline).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The closing `$$` of a block must end its line, otherwise the formula is inline.
    private static func restIsBlank(_ u: [UInt16], from start: Int) -> Bool {
        var i = start
        while i < u.count, u[i] != newline, u[i] != carriageReturn {
            if u[i] != 0x20 && u[i] != 0x09 { return false }
            i += 1
        }
        return true
    }

    private static func closingBacktickRun(_ u: [UInt16], from start: Int, length: Int, limit: Int) -> Int? {
        var i = start
        while i < limit {
            if u[i] == backtick {
                var run = 0
                while i + run < limit, u[i + run] == backtick { run += 1 }
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func closingDisplay(_ u: [UInt16], from start: Int, limit: Int) -> Int? {
        var i = start
        while i + 1 < limit {
            if u[i] == backslash { i += 2; continue }
            if u[i] == dollar, u[i + 1] == dollar { return i }
            i += 1
        }
        return nil
    }

    /// Pandoc rule: the opener is not followed by whitespace, the closer is not preceded by
    /// whitespace and not followed by a digit. Inline math stays on one line, which keeps
    /// prices like "$5 and $10" from turning into formulas.
    private static func closingInline(_ u: [UInt16], from start: Int, limit: Int) -> Int? {
        guard start < limit, !isSpace(u[start]), u[start] != dollar else { return nil }
        var i = start
        while i < limit {
            let c = u[i]
            if c == newline || c == carriageReturn { return nil }
            if c == backslash { i += 2; continue }
            if c == dollar {
                if i > start, !isSpace(u[i - 1]), !(i + 1 < u.count && isDigit(u[i + 1])) { return i }
                return nil
            }
            i += 1
        }
        return nil
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == newline || c == carriageReturn }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    /// Replace math content with ASCII placeholders of identical UTF-8 length (line breaks kept),
    /// so cmark's byte columns stay valid for the original text.
    static func mask(_ string: String, spans: [MathSpan]) -> String {
        guard !spans.isEmpty else { return string }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count)
        var offset = 0
        var spanIndex = 0
        for scalar in string.unicodeScalars {
            while spanIndex < spans.count, spans[spanIndex].content.upperBound <= offset { spanIndex += 1 }
            let inMath = spanIndex < spans.count && spans[spanIndex].content.contains(offset)
            if inMath && scalar != "\n" && scalar != "\r" {
                bytes.append(contentsOf: repeatElement(UInt8(ascii: "x"), count: scalar.utf8.count))
            } else {
                bytes.append(contentsOf: scalar.utf8)
            }
            offset += scalar.utf16.count
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
