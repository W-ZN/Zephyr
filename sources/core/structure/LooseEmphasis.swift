import Foundation

/// A second emphasis pass for what cmark leaves as literal text. CommonMark lets a delimiter run
/// close only when its neighbours say so, and a run between punctuation and a letter fails that:
/// `**差异A：**内容` and `**Note:**text` stay as typed. People writing Chinese or Japanese rarely
/// put spaces around markup, so Zephyr pairs the runs cmark skipped with a looser rule: a run may
/// open when no whitespace follows it and close when none precedes it; `_` additionally keeps
/// `snake_case` intact (it cannot open or close next to a Latin letter or digit, but can next to
/// CJK text). Pairing then follows CommonMark's own stack algorithm, rule of 3 included.
enum LooseEmphasis {
    struct Pair: Equatable {
        var open: Range<Int>
        var close: Range<Int>
        var style: InlineStyle
    }

    private struct Run {
        var mark: UInt16
        var start: Int
        var count: Int
        var left: Int
        var canOpen: Bool
        var canClose: Bool
    }

    /// - Parameters:
    ///   - texts: source ranges of one parent's literal text nodes, in order.
    ///   - blocked: ranges that are not Markdown text (formulas), whose markers are left alone.
    static func pairs(in units: [UInt16], texts: [Range<Int>], blocked: [Range<Int>]) -> [Pair] {
        var runs: [Run] = []
        for text in texts {
            var i = text.lowerBound
            while i < text.upperBound {
                let u = units[i]
                if u == 0x5C { i += 2; continue }
                guard u == 0x2A || u == 0x5F || u == 0x7E else { i += 1; continue }
                var end = i + 1
                while end < text.upperBound, units[end] == u { end += 1 }
                let range = i..<end
                i = end
                if u == 0x7E, range.count != 2 { continue }
                if blocked.contains(where: { $0.overlaps(range) }) { continue }
                if let last = runs.last, last.mark == u, last.start + last.count == range.lowerBound {
                    runs[runs.count - 1].count += range.count
                    runs[runs.count - 1].left += range.count
                    continue
                }
                runs.append(Run(mark: u, start: range.lowerBound, count: range.count, left: range.count, canOpen: false, canClose: false))
            }
        }
        guard !runs.isEmpty else { return [] }
        for k in runs.indices {
            let run = runs[k]
            let before = scalar(before: run.start, in: units), after = scalar(from: run.start + run.count, in: units)
            let open = !isSpace(after), close = !isSpace(before)
            if run.mark == 0x5F {
                runs[k].canOpen = open && !isWord(before)
                runs[k].canClose = close && !isWord(after)
            } else {
                runs[k].canOpen = open
                runs[k].canClose = close
            }
        }

        var pairs: [Pair] = []
        var stack: [Int] = []
        for k in runs.indices {
            var s = runs[k].canClose ? stack.count - 1 : -1
            while s >= 0, runs[k].left > 0 {
                let o = stack[s]
                // Rule of 3: runs that could both open and close pair only if their sizes allow.
                let blockedByRule = (runs[o].canClose || runs[k].canOpen) && (runs[o].count + runs[k].count) % 3 == 0
                    && !(runs[o].count % 3 == 0 && runs[k].count % 3 == 0)
                guard runs[o].mark == runs[k].mark, !blockedByRule else { s -= 1; continue }
                let tilde = runs[k].mark == 0x7E
                if tilde, runs[o].left != 2 || runs[k].left != 2 { s -= 1; continue }
                let use = runs[o].left >= 2 && runs[k].left >= 2 ? 2 : 1
                let openEnd = runs[o].start + runs[o].left, closeStart = runs[k].start + runs[k].count - runs[k].left
                pairs.append(Pair(open: (openEnd - use)..<openEnd, close: closeStart..<(closeStart + use), style: tilde ? .strikethrough : (use == 2 ? .strong : .emphasis)))
                runs[o].left -= use
                runs[k].left -= use
                // Openers between the pair are unmatched for good.
                stack.removeSubrange((runs[o].left > 0 ? s + 1 : s)...)
                s = stack.count - 1
            }
            if runs[k].left > 0, runs[k].canOpen { stack.append(k) }
        }
        return pairs
    }

    // MARK: Characters

    private static func scalar(from i: Int, in units: [UInt16]) -> Unicode.Scalar? {
        guard i < units.count else { return nil }
        let u = units[i]
        if UTF16.isLeadSurrogate(u), i + 1 < units.count, UTF16.isTrailSurrogate(units[i + 1]) {
            return Unicode.Scalar(0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00))
        }
        return Unicode.Scalar(u)
    }

    private static func scalar(before i: Int, in units: [UInt16]) -> Unicode.Scalar? {
        guard i > 0 else { return nil }
        let u = units[i - 1]
        if UTF16.isTrailSurrogate(u), i > 1, UTF16.isLeadSurrogate(units[i - 2]) { return scalar(from: i - 2, in: units) }
        return Unicode.Scalar(u)
    }

    private static func isSpace(_ s: Unicode.Scalar?) -> Bool {
        guard let s else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(s)
    }

    /// A letter or digit outside CJK text: what `_` must not touch.
    private static func isWord(_ s: Unicode.Scalar?) -> Bool {
        guard let s, !s.isCJK else { return false }
        return CharacterSet.alphanumerics.contains(s)
    }
}

extension Unicode.Scalar {
    /// Han, kana, Hangul, CJK punctuation and full-width forms: text written without spaces.
    public var isCJK: Bool {
        switch value {
        case 0x2E80...0xA4CF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3FFFF: true
        default: false
        }
    }
}
