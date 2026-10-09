import AppKit
import CoreText

/// Where a unit's display text comes from in its source, in unit-local UTF-16 offsets (design §4,
/// block canvas). The display text is the source with hidden syntax left out; an inline formula is
/// one object replacement character that stands for its whole source.
struct IndexMap: Sendable {
    /// A stretch of source shown as display text. Runs are contiguous in the display and ordered in
    /// the source; hidden source lies in the gaps between them.
    struct Run: Sendable {
        var display: Int
        var source: Int
        var displayLength: Int
        var sourceLength: Int
        var isAtomic: Bool { displayLength != sourceLength }
    }

    var runs: [Run]
    let sourceLength: Int
    let displayLength: Int

    static func identity(_ length: Int) -> IndexMap {
        IndexMap(runs: length > 0 ? [Run(display: 0, source: 0, displayLength: length, sourceLength: length)] : [], sourceLength: length, displayLength: length)
    }

    /// The display offset of source offset `s`. Hidden source collapses onto the boundary after
    /// the text before it; a position inside a formula falls after the formula.
    func display(_ s: Int) -> Int {
        var lo = 0, hi = runs.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if runs[mid].source <= s { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return 0 }
        let r = runs[found]
        if s >= r.source + r.sourceLength { return r.display + r.displayLength }
        if r.isAtomic { return s == r.source ? r.display : r.display + r.displayLength }
        return r.display + (s - r.source)
    }

    /// The source offset of display offset `d`. Where hidden source lies at that boundary, `after`
    /// chooses the side after it (a line start skips `## `), otherwise the side before it.
    func source(_ d: Int, after: Bool) -> Int {
        guard !runs.isEmpty else { return after ? sourceLength : 0 }
        var lo = 0, hi = runs.count - 1, k = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if runs[mid].display <= d { k = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let r = runs[k]
        if d > r.display {
            if d < r.display + r.displayLength { return r.isAtomic ? r.source + r.sourceLength : r.source + (d - r.display) }
            // The end of the display text: the hidden tail (a closing `**`) is before or after.
            return after ? sourceLength : r.source + r.sourceLength
        }
        if k == 0 { return after ? r.source : 0 }
        let previousEnd = runs[k - 1].source + runs[k - 1].sourceLength
        return previousEnd == r.source || after ? r.source : previousEnd
    }
}

/// What one layout unit shows (design §4): display text and its map to the source, the vertical
/// metrics of its line, the space above it, and the decorations drawn around the text. Built on
/// the main thread; immutable afterwards, so it can be typeset on any thread.
final class UnitContent: @unchecked Sendable {
    enum Body {
        /// `string`, broken into lines.
        case text
        /// A blank or collapsed line (code fence, setext underline, the rest of a component): this
        /// much height and no text; the caret can still stand there.
        case space(CGFloat)
        /// A block component drawn in place of the line (table, display formula, image…).
        case component(ComponentBox)
    }

    /// A slice of a code block: rounded at the block's first and last line, numbered code lines.
    struct CodeSlice {
        var box: CodeBlockBox
        var isFirst: Bool
        var isLast: Bool
        var number: Int?
    }

    let body: Body
    let string: NSAttributedString
    let map: IndexMap
    let metrics: LineMetrics
    /// Block gap above the first line (design §8.1), outside the line's box.
    let gap: CGFloat
    /// Text start within the column, and the extra indent of the unit's first line.
    let indent: CGFloat
    let firstIndent: CGFloat
    /// Room kept free at the right end of lines (code blocks).
    let tail: CGFloat
    let justified: Bool
    var listMarker: ListMarkerBox.Kind?
    var code: CodeSlice?
    var headingNumber: String?
    var headingRule = false
    /// Height of the gap above that the quote bars leave out (the space before a quote).
    var quoteSkip: CGFloat = 0
    /// Width of a heading's markers (`## `) and whether the caret shows them. Shown, they hang in
    /// the margin where it holds them whole, so the heading's text stays where it is; otherwise
    /// they show inline at their own size and push the text along (a narrow window).
    var markerWidth: CGFloat = 0
    /// Display length of the heading's revealed marker.
    var markerLength = 0
    var markersShown = false
    /// One line whatever its length (a revealed code fence keeps to its band); what does not fit
    /// is cut at the column's edge.
    var singleLine = false

    init(body: Body, string: NSAttributedString, map: IndexMap, metrics: LineMetrics, gap: CGFloat = 0,
         indent: CGFloat = 0, firstIndent: CGFloat = 0, tail: CGFloat = 0, justified: Bool = false) {
        self.body = body
        self.string = string
        self.map = map
        self.metrics = metrics
        self.gap = gap
        self.indent = indent
        self.firstIndent = firstIndent
        self.tail = tail
        self.justified = justified
    }

    var component: ComponentBox? {
        if case let .component(box) = body { return box }
        return nil
    }
}

/// A unit set by Core Text: its visual lines with their boxes and baselines, relative to the unit's
/// top (design §4). Offsets in `starts` are display offsets; the geometry methods take source
/// offsets and go through the content's map.
final class UnitLayout: @unchecked Sendable {
    let content: UnitContent
    let lines: [CTLine]
    /// Display offset where each line starts.
    let starts: [Int]
    /// Left edge of each line from the column's left edge (indents).
    let xs: [CGFloat]
    /// Top and height of each line's box (selection, caret), from the unit's top.
    let tops: [CGFloat]
    let heights: [CGFloat]
    let baselines: [CGFloat]
    let height: CGFloat
    let cost: Int
    /// How far the first line starts left of its indent (the hanging syntax that fit the margin).
    let hang: CGFloat

    private init(content: UnitContent, lines: [CTLine], starts: [Int], xs: [CGFloat], tops: [CGFloat], heights: [CGFloat], baselines: [CGFloat], height: CGFloat, hang: CGFloat = 0) {
        self.content = content
        self.hang = hang
        self.lines = lines
        self.starts = starts
        self.xs = xs
        self.tops = tops
        self.heights = heights
        self.baselines = baselines
        self.height = height
        // Measured: shaped Core Text lines take about 110 bytes per UTF-16 unit.
        cost = 512 + 112 * content.string.length
    }

    /// Source characters of the unit before its line break.
    var contentLength: Int { content.map.sourceLength }

    /// The line holding display offset `d` (an offset at a wrap point belongs to the line it starts).
    func line(forDisplay d: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= d { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func displayEnd(ofLine k: Int) -> Int { k + 1 < starts.count ? starts[k + 1] : content.string.length }

    /// Source range of line `k`: from after the hidden syntax at its start to its last character.
    func sourceStart(ofLine k: Int) -> Int { content.map.source(starts[k], after: true) }
    func sourceEnd(ofLine k: Int) -> Int {
        k + 1 < starts.count ? content.map.source(starts[k + 1], after: false) : contentLength
    }

    /// x of source offset `s` on line `k`, from the column's left edge.
    func x(ofSource s: Int, line k: Int) -> CGFloat {
        let d = min(max(content.map.display(s), starts[k]), displayEnd(ofLine: k))
        return xs[k] + CTLineGetOffsetForStringIndex(lines[k], d, nil)
    }

    /// The source offset nearest to `x` (from the column's left edge) on line `k`.
    func source(atX x: CGFloat, line k: Int) -> Int {
        var d = CTLineGetStringIndexForPosition(lines[k], CGPoint(x: x - xs[k], y: 0))
        if d == kCFNotFound { d = starts[k] }
        d = min(max(d, starts[k]), displayEnd(ofLine: k))
        // Past the last character: after any hidden tail. A line showing nothing (a collapsed
        // fence, a blank line) keeps the caret at its start.
        if k == starts.count - 1, d == content.string.length, d > 0 { return contentLength }
        return content.map.source(d, after: d == starts[k])
    }

    /// The line whose box is nearest to `y` (from the unit's top).
    func line(atY y: CGFloat) -> Int {
        for k in 0..<lines.count where y < tops[k] + heights[k] { return k }
        return lines.count - 1
    }

    // MARK: Typesetting

    /// Lines of `content` for a column `width` wide. Pure Core Text work on immutable input: safe
    /// off the main thread (design §4: shaping ahead of the scroll). A component unit needs its
    /// height, which only the main thread can ask the component for. `margin` is the room left of
    /// the column that hanging syntax may use: a heading's revealed markers hang there when they
    /// fit, and otherwise show inline, pushing the heading's text along (a narrow window).
    static func typeset(_ content: UnitContent, width: CGFloat, componentHeight: CGFloat = 0, margin: CGFloat = 0) -> UnitLayout {
        let m = content.metrics
        let empty = CTLineCreateWithAttributedString(content.string.length == 0 ? NSAttributedString(string: "", attributes: [.font: NSFont.systemFont(ofSize: max(1, m.ascent + m.descent))]) : content.string.attributedSubstring(from: NSRange(location: 0, length: 0)))
        switch content.body {
        case let .space(h):
            let baseline = content.gap + round((h + m.ascent - m.descent) / 2)
            return UnitLayout(content: content, lines: [empty], starts: [0], xs: [content.indent + content.firstIndent], tops: [content.gap], heights: [h], baselines: [baseline], height: content.gap + h)
        case .component:
            return UnitLayout(content: content, lines: [empty], starts: [0], xs: [content.indent], tops: [content.gap], heights: [componentHeight], baselines: [content.gap + m.ascent], height: ceil(content.gap + componentHeight))
        case .text:
            break
        }
        var string = content.string
        let n = string.length
        var lines: [CTLine] = [], starts: [Int] = [], xs: [CGFloat] = []
        let available = max(40, width - content.indent - content.tail)
        string = fitted(string, width: available - max(0, content.firstIndent))
        let gutter = max(0, margin + content.indent + content.firstIndent - 4)
        // Heading syntax hangs in the gutter when it fits there whole. Ask the shaped full line where
        // its body begins: its offset includes the boundary spacing Core Text applies after the marker.
        let hang = content.markersShown && content.markerLength > 0 && content.markerWidth <= gutter
            ? CTLineGetOffsetForStringIndex(CTLineCreateWithAttributedString(string), content.markerLength, nil)
            : 0
        if n == 0 {
            lines = [empty]
            starts = [0]
            xs = [content.indent + content.firstIndent]
        } else {
            autoreleasepool {
                let typesetter = CTTypesetterCreateWithAttributedString(string)
                var start = 0
                while start < n {
                    let first = lines.isEmpty
                    let w = max(20, available - (first ? content.firstIndent - hang : 0))
                    var count = content.singleLine ? n - start : CTTypesetterSuggestLineBreak(typesetter, start, Double(w))
                    if count <= 0 { count = (string.string as NSString).rangeOfComposedCharacterSequence(at: start).length }
                    var line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                    if content.justified, start + count < n, let justified = CTLineCreateJustifiedLine(line, 1, Double(w)) { line = justified }
                    lines.append(line)
                    starts.append(start)
                    xs.append(content.indent + (first ? content.firstIndent - hang : 0))
                    start += count
                }
            }
        }
        var tops: [CGFloat] = [], heights: [CGFloat] = [], baselines: [CGFloat] = []
        var y: CGFloat = 0
        let halfLeading = max(0, (m.lineHeight - m.ascent - m.descent) / 2)
        for (k, line) in lines.enumerated() {
            var ascent = m.ascent, descent = m.descent
            // Inline formulas and images taller than the text open the line up.
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard attrs[NSAttributedString.Key.zComponent] is any InlineComponent else { continue }
                var runAscent: CGFloat = 0, runDescent: CGFloat = 0
                CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &runAscent, &runDescent, nil)
                ascent = max(ascent, runAscent + 1)
                descent = max(descent, runDescent + 1)
            }
            let top = round(ascent + halfLeading)
            let bottom = round(descent + halfLeading)
            let before = k == 0 ? content.gap + m.spacingBefore : 0
            let after = k == lines.count - 1 ? m.spacingAfter : 0
            tops.append(y + (k == 0 ? content.gap : 0))
            heights.append(top + bottom + (k == 0 ? m.spacingBefore : 0) + after)
            baselines.append(y + before + top)
            y += before + top + bottom + after
        }
        return UnitLayout(content: content, lines: lines, starts: starts, xs: xs, tops: tops, heights: heights, baselines: baselines, height: y, hang: hang)
    }
}

extension UnitLayout {
    /// `string` with every inline image wider than the column scaled down to fit it (a narrow
    /// window): the image reads the scale from its run's width when it draws.
    static func fitted(_ string: NSAttributedString, width: CGFloat) -> NSAttributedString {
        var copy: NSMutableAttributedString?
        string.enumerateAttribute(.zComponent, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let box = value as? InlineImageBox, box.advance > width, box.metrics.width > 0 else { return }
            let scale = max(1, width - (box.advance - box.metrics.width)) / box.metrics.width
            guard let delegate = RunSize.delegate(width: width, ascent: box.metrics.ascent * scale, descent: box.metrics.descent * scale) else { return }
            if copy == nil { copy = NSMutableAttributedString(attributedString: string) }
            copy?.addAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String), value: delegate, range: range)
        }
        return copy ?? string
    }
}

// MARK: - Inline objects as run delegates

/// Width, ascent and descent Core Text reserves for an object in a line (an inline formula, an
/// image): the placeholder character's run delegate.
final class RunSize {
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }

    static func delegate(width: CGFloat, ascent: CGFloat, descent: CGFloat) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { ref in
            Unmanaged<RunSize>.fromOpaque(ref).release()
        }, getAscent: { ref in
            Unmanaged<RunSize>.fromOpaque(ref).takeUnretainedValue().ascent
        }, getDescent: { ref in
            Unmanaged<RunSize>.fromOpaque(ref).takeUnretainedValue().descent
        }, getWidth: { ref in
            Unmanaged<RunSize>.fromOpaque(ref).takeUnretainedValue().width
        })
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(RunSize(width: width, ascent: ascent, descent: descent)).toOpaque())
    }

    /// The run delegate that makes Core Text leave room for an inline component.
    static func delegate(for box: any InlineComponent) -> CTRunDelegate? {
        delegate(width: box.advance, ascent: box.metrics.ascent, descent: box.metrics.descent)
    }
}
