import Foundation

/// The text cut into layout units (design §4, block layout): every unit is laid out on its own,
/// starting a new visual line, so its height depends only on its own characters and the width.
/// That is what lets the canvas measure any part of a 20 MB document without the text before it.
///
/// A unit is one source line, terminator included. A line longer than `maximum` UTF-16 units is cut
/// into pieces: at the first space or sentence punctuation (。，、；：！？ and closing brackets) past
/// `target`, or, with none before `maximum`, at the last position that splits no character. A very
/// long line therefore shows an early line break every two thousand characters or so, at a natural
/// pause; ordinary lines never do. An edit re-cuts only the units it touches, so the cuts in
/// the rest of a long line stay where they are and their measured heights stay valid.
public struct TextUnits {
    public struct Unit: Equatable, Sendable {
        public var length: Int
        /// False for the second and later pieces of a cut line.
        public var startsLine: Bool
        /// Stable while the unit is unchanged; layout caches key on it.
        public var id: UInt64
    }

    public static let target = 2048
    public static let maximum = 4096

    public private(set) var units: [Unit] = []
    private var lengths = PrefixSum<Int>()
    /// 1 for units that start a source line: line numbers in O(log n).
    private var lineStarts = PrefixSum<Int>()
    private var nextID: UInt64 = 1

    public init(text: NSString) {
        units = cut(text, NSRange(location: 0, length: text.length), startsLine: true, endsText: true)
        lengths = PrefixSum(units.map(\.length))
        lineStarts = PrefixSum(units.map { $0.startsLine ? 1 : 0 })
    }

    /// Source lines (line breaks + 1).
    public var lineCount: Int { lineStarts.total }

    /// The 0-based source line of unit `index`.
    public func line(ofUnit index: Int) -> Int { lineStarts.prefix(index + 1) - 1 }

    /// The first unit of 0-based source line `line`.
    public func firstUnit(ofLine line: Int) -> Int { lineStarts.index(containing: max(0, line)) }

    public var count: Int { units.count }
    public var length: Int { lengths.total }

    public func range(of index: Int) -> NSRange {
        NSRange(location: lengths.prefix(index), length: units[index].length)
    }

    /// The unit holding the character at `location` (the end of the text is in the last unit).
    public func unit(containing location: Int) -> Int {
        lengths.index(containing: max(0, location))
    }

    /// Update after `text` changed: `range` (old coordinates) was replaced by `replacementLength`
    /// characters. Returns the units that were replaced (old indices) and their replacements (new
    /// indices); units outside keep their ids.
    @discardableResult
    public mutating func edit(replacing range: NSRange, with replacementLength: Int, in text: NSString) -> (old: Range<Int>, new: Range<Int>, removed: [UInt64]) {
        var first = unit(containing: range.location)
        var last = range.length > 0 ? max(first, unit(containing: NSMaxRange(range) - 1)) : first
        // A unit ending in a lone CR may now be followed by an LF: CR LF is one line break.
        if first > 0, range.location == lengths.prefix(first), text.character(at: range.location - 1) == 0x0D { first -= 1 }
        let delta = replacementLength - range.length
        var start = lengths.prefix(first)
        var end = lengths.prefix(last + 1) + delta
        // Short neighbours of the same line join the region so that, for example, removing a line
        // break between two short lines gives one unit and not a forced break in the middle.
        if first > 0, !units[first].startsLine, units[first - 1].length < Self.target / 2 {
            first -= 1
            start -= units[first].length
        }
        // The region ends at a line break or at an existing cut inside a long line, both still valid.
        // It grows only when a line break was removed (the next line joins this one) or the piece
        // after it is short; it never re-cuts the rest of a long line.
        while last + 1 < units.count {
            let endsLine = end > start && Self.isTerminator(text.character(at: end - 1))
                && !(text.character(at: end - 1) == 0x0D && end < text.length && text.character(at: end) == 0x0A)
            let next = units[last + 1]
            guard !endsLine, next.startsLine || next.length < Self.target / 2 else { break }
            last += 1
            end += next.length
        }
        let region = NSRange(location: start, length: end - start)
        let fresh = cut(text, region, startsLine: first == 0 || units[first].startsLine, endsText: last == units.count - 1)
        // The unit after the region continues the line when the region does not end with a break.
        if last + 1 < units.count {
            let endsLine = end > start && Self.isTerminator(text.character(at: end - 1))
            units[last + 1].startsLine = endsLine
            lineStarts.set(last + 1, endsLine ? 1 : 0)
        }
        let removed = units[first...last].map(\.id)
        units.replaceSubrange(first...last, with: fresh)
        lengths.replaceSubrange(first..<(last + 1), with: fresh.map(\.length))
        lineStarts.replaceSubrange(first..<(last + 1), with: fresh.map { $0.startsLine ? 1 : 0 })
        return (first..<(last + 1), first..<(first + fresh.count), removed)
    }

    public static func isTerminator(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    /// Units for `range`. Lines end after `\n`, `\r\n` or `\r`; a line running past `maximum` is cut.
    /// When the range reaches the end of the text, a final empty line after a break is its own unit
    /// (the caret can stand there).
    private mutating func cut(_ text: NSString, _ range: NSRange, startsLine: Bool, endsText: Bool) -> [Unit] {
        var result: [Unit] = []
        var unitStart = range.location
        var lineStarts = startsLine
        let end = NSMaxRange(range)
        let chunk = 65_536
        var buffer = [unichar](repeating: 0, count: chunk)
        var base = range.location
        func emit(_ upTo: Int) {
            result.append(Unit(length: upTo - unitStart, startsLine: lineStarts, id: nextID))
            nextID += 1
            lineStarts = upTo > unitStart && Self.isTerminator(text.character(at: upTo - 1))
            unitStart = upTo
        }
        while base < end {
            let n = min(chunk, end - base)
            buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: base, length: n)) }
            var i = 0
            while i < n {
                let c = buffer[i]
                let position = base + i
                if c == 0x0A || (c == 0x0D && !(position + 1 < end && text.character(at: position + 1) == 0x0A)) {
                    emit(position + 1)
                } else if position + 1 - unitStart >= Self.target, Self.isPause(c) {
                    emit(position + 1)
                } else if position + 1 - unitStart >= Self.maximum {
                    // The characters after the cut hold no line break (they were just scanned) and
                    // simply start the next piece.
                    emit(Self.breakOpportunity(in: text, from: unitStart, before: position + 1))
                }
                i += 1
            }
            base += n
        }
        // The rest of the region, or the empty last line after a final line break.
        if unitStart < end || result.isEmpty || (endsText && lineStarts) {
            result.append(Unit(length: end - unitStart, startsLine: lineStarts, id: nextID))
            nextID += 1
        }
        return result
    }

    /// Where to end a piece of an over-long line that starts at `start` and must end by `limit`:
    /// after the last space or tab past the target length, otherwise at the last position that does
    /// not split a surrogate pair, a combining mark or a joiner sequence.
    static func breakOpportunity(in text: NSString, from start: Int, before limit: Int) -> Int {
        let low = start + target
        var p = limit
        while p > low {
            let c = text.character(at: p - 1)
            if c == 0x20 || c == 0x09 { return p }
            p -= 1
        }
        p = limit
        while p > start + 1 {
            let before = text.character(at: p - 1), after = p < text.length ? text.character(at: p) : 0
            let splitsPair = (0xD800...0xDBFF).contains(before) && (0xDC00...0xDFFF).contains(after)
            let joins = isExtending(after) || before == 0x200D
            if !splitsPair && !joins { return p }
            p -= 1
        }
        return limit
    }

    /// A space, tab, or CJK sentence punctuation / closing bracket: a line may always break after it.
    static func isPause(_ c: unichar) -> Bool {
        switch c {
        case 0x20, 0x09, 0x3001, 0x3002, 0xFF0C, 0xFF1B, 0xFF1A, 0xFF01, 0xFF1F, 0x300D, 0x300F, 0xFF09, 0x3011: true
        default: false
        }
    }

    /// Characters that attach to the one before: combining marks, joiners, variation selectors,
    /// emoji modifiers' low surrogates are covered by the pair rule.
    static func isExtending(_ c: unichar) -> Bool {
        (0x0300...0x036F).contains(c) || (0x1AB0...0x1AFF).contains(c) || (0x1DC0...0x1DFF).contains(c)
            || (0x20D0...0x20FF).contains(c) || (0xFE00...0xFE0F).contains(c) || (0xFE20...0xFE2F).contains(c)
            || c == 0x200D || c == 0x200C || (0x3099...0x309A).contains(c)
    }
}
