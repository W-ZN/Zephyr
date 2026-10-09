import AppKit
import CoreText
import ZephyrCore
import ZephyrLayout

/// Markdown on the block canvas (design §4): the structure layer and the rendered canvas's styler,
/// applied one chunk at a time and cut into the canvas's units. Only chunks near what is shown are
/// ever parsed and styled; a styled chunk is kept until the budget runs out.
///
/// What a unit shows depends on the selection: syntax next to the caret is revealed and a component
/// the caret is in turns back into source. Moving the caret never changes a line's height (design
/// §8.1, stable geometry): revealed heading markers hang in the margin, fences reveal inside their
/// band, and blank lines keep the height an edit gave them. The presenter reports which text a
/// change touches, and the canvas lays out those units again.
@MainActor
final class MarkdownPresenter {
    private unowned let canvas: BlockCanvas
    private weak var context: RenderContext?
    private(set) var typography: Typography
    private(set) var structure: DocumentStructure
    private var styler: MarkdownStyler
    private var styled: [NSAttributedString?]
    private var lastUse: [Int]
    private var clock = 0
    private var styledLength = 0
    /// Characters of styled chunks kept (design §3.1): a few hundred screens.
    static let styledBudget = 300_000
    /// Chunks longer than this are shown as plain lines, unparsed (design §3.2: responsiveness first).
    static let largestStyledChunk = 1_000_000
    /// Components of chunks an edit replaced: the new styling reuses equal ones, so a loaded image,
    /// a table's own layout choice or a diagram's layout survive typing next to them.
    private var retired: [ComponentBox] = []

    /// Absolute ranges of hidden syntax the selection reveals, and of components it turns into source.
    private(set) var revealedMarkers: [NSRange] = []
    private(set) var revealedComponents: [NSRange] = []
    private var headingNumbers: [Int: String]?

    init(canvas: BlockCanvas, context: RenderContext?, typography: Typography) {
        self.canvas = canvas
        self.context = context
        self.typography = typography
        structure = DocumentStructure(text: canvas.text)
        styler = MarkdownStyler(typography: typography, context: context ?? NullContext.shared)
        blankMetrics = Self.blank(typography)
        styled = Array(repeating: nil, count: structure.chunks.count)
        lastUse = Array(repeating: 0, count: structure.chunks.count)
    }

    private var text: NSMutableString { canvas.text }
    private var units: TextUnits { canvas.units }

    func apply(typography newTypography: Typography) {
        typography = newTypography
        styler = MarkdownStyler(typography: newTypography, context: context ?? NullContext.shared)
        blankMetrics = Self.blank(newTypography)
        retireAll()
        headingNumbers = nil
    }

    /// Forget every styled chunk (the look changed); their components stay available for reuse.
    func retireAll() {
        for s in styled.compactMap({ $0 }) { retire(s) }
        styled = Array(repeating: nil, count: structure.chunks.count)
        lastUse = Array(repeating: 0, count: structure.chunks.count)
        styledLength = 0
    }

    private func retire(_ s: NSAttributedString) {
        s.enumerateAttribute(.zComponent, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if let box = value as? ComponentBox, !retired.contains(where: { $0 === box }) { retired.append(box) }
        }
        if retired.count > 256 { retired.removeFirst(retired.count - 256) }
    }

    // MARK: - Chunks

    /// The chunk text with the rendered canvas's attributes, or nil for a chunk shown plain.
    func styledChunk(_ c: Int) -> NSAttributedString? {
        clock += 1
        if let s = styled[c] {
            lastUse[c] = clock
            return s
        }
        let chunk = structure.chunks[c]
        guard chunk.range.length <= Self.largestStyledChunk else { return nil }
        let a = structure.analysis(c, text: text)
        guard !a.isPlain else { return nil }
        let s = NSMutableAttributedString(string: text.substring(with: chunk.range))
        styler.style(a, at: 0, in: s)
        if !retired.isEmpty {
            s.enumerateAttribute(.zComponent, in: NSRange(location: 0, length: s.length)) { value, r, _ in
                guard let box = value as? ComponentBox, let i = retired.firstIndex(where: { type(of: $0) == type(of: box) && $0.kind == box.kind }) else { return }
                let old = retired.remove(at: i)
                if let math = old as? InlineMathBox, math.fontSize != (box as? InlineMathBox)?.fontSize { return }
                if let image = old as? InlineImageBox {
                    guard image.fontSize == (box as? InlineImageBox)?.fontSize else { return }
                    image.measure()
                }
                s.addAttribute(.zComponent, value: old, range: r)
            }
        }
        styled[c] = s
        lastUse[c] = clock
        styledLength += s.length
        if styledLength > Self.styledBudget { evict(keeping: c) }
        return s
    }

    private func evict(keeping keep: Int) {
        let order = styled.indices.filter { styled[$0] != nil && $0 != keep }.sorted { lastUse[$0] < lastUse[$1] }
        for c in order {
            guard styledLength > Self.styledBudget * 3 / 4, let s = styled[c] else { break }
            styledLength -= s.length
            styled[c] = nil
            structure.discardAnalysis(c)
        }
    }

    /// After `old` (old coordinates) was replaced by `newLength` characters. Returns the range of
    /// text (new coordinates) whose presentation may have changed.
    func didEdit(_ old: NSRange, newLength: Int) -> NSRange {
        let delta = newLength - old.length
        let before = structure.chunks.count
        let fresh = structure.edit(text: text, editedRange: NSRange(location: old.location, length: newLength), delta: delta)
        let replaced = fresh.lowerBound..<(fresh.upperBound - (structure.chunks.count - before))
        for c in replaced { if let s = styled[c] { styledLength -= s.length; retire(s) } }
        styled.replaceSubrange(replaced, with: repeatElement(nil, count: fresh.count))
        lastUse.replaceSubrange(replaced, with: repeatElement(0, count: fresh.count))
        headingNumbers = nil
        revealedMarkers = revealedMarkers.compactMap { $0.shifted(byEdit: NSRange(location: old.location, length: newLength), delta: delta) }
        revealedComponents = revealedComponents.compactMap { $0.shifted(byEdit: NSRange(location: old.location, length: newLength), delta: delta) }
        guard !fresh.isEmpty else { return NSRange(location: old.location, length: newLength) }
        let start = structure.chunks[fresh.lowerBound].range.location
        let end = NSMaxRange(structure.chunks[fresh.upperBound - 1].range)
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Selection

    /// The selection moved (or the text under it changed): what it reveals and which line holds the
    /// caret. A component the caret stands on as a whole (`focused`, reached with the arrow keys)
    /// stays drawn. Returns the text whose presentation changed.
    func selectionChanged(_ sel: NSRange, focused: NSRange? = nil) -> [NSRange] {
        var markers: [NSRange] = []
        var components: [NSRange] = []
        if sel.length <= 400, !structure.chunks.isEmpty {
            let first = structure.index.index(containing: max(0, sel.location - 1))
            var i = first
            while i < structure.chunks.count, i <= first + 4 {
                let chunk = structure.chunks[i]
                if chunk.range.location > NSMaxRange(sel) { break }
                if chunk.range.length <= Self.largestStyledChunk {
                    let a = structure.analysis(i, text: text)
                    let base = chunk.range.location
                    for m in a.markers where m.style == .hide && Self.touches(sel, NSRange(location: base + m.revealRange.location, length: m.revealRange.length)) {
                        markers.append(NSRange(location: base + m.range.location, length: m.range.length))
                    }
                    for c in a.components {
                        let r = NSRange(location: base + c.range.location, length: c.range.length)
                        if r != focused, Self.edits(sel, r) { components.append(r) }
                    }
                }
                i += 1
            }
        }
        var dirty = markers.filter { !revealedMarkers.contains($0) } + revealedMarkers.filter { !markers.contains($0) }
        dirty += components.filter { !revealedComponents.contains($0) } + revealedComponents.filter { !components.contains($0) }
        revealedMarkers = markers
        revealedComponents = components
        return dirty
    }

    // MARK: - Blank lines (design §8.1)

    /// Blank lines have no height: the gap between two blocks belongs to the block below, and
    /// further blank lines add nothing, however many the file has. An edit at the caret is the
    /// exception: the blank line it leaves the caret on is laid out as the line it is about to
    /// become, and blank lines Return makes beyond the one that separates two paragraphs stay as
    /// empty paragraphs while the document is open. Moving the caret changes none of this.
    private var open: Set<UInt64> { get { canvas.openBlanks } set { canvas.openBlanks = newValue } }

    /// After an edit at the caret: which blank lines around it are open (laid out as empty lines).
    /// `created` are the units the edit made. Returns the text to lay out again.
    func settle(caret: Int, created: Set<UInt64>) -> NSRange? {
        guard units.count > 0 else { return nil }
        let line = firstUnit(ofLineAt: caret)
        func isFresh(_ j: Int) -> Bool { open.contains(units.units[j].id) || created.contains(units.units[j].id) }
        var above: [Int] = [], below: [Int] = []
        var j = line
        while let p = previousLine(j), isBlankLine(p) { above.insert(p, at: 0); j = p }
        // Text right after a paragraph line or a component would join it (a lazy continuation, a
        // table's row): a blank line between them is a separator, not an empty paragraph.
        let joins = [.body, .component].contains(previousLine(j).flatMap { styledMetrics(at: units.range(of: $0).location) }?.kind)
        j = line
        while let n = nextLine(j), isBlankLine(n) { below.append(n); j = n }
        let caretOnBlank = isBlankLine(line)
        var changed = false
        func setOpen(_ j: Int, _ on: Bool) {
            let id = units.units[j].id
            guard open.contains(id) != on else { return }
            if on { open.insert(id) } else { open.remove(id) }
            changed = true
        }
        // In a run between a paragraph line and what follows, one blank line keeps the paragraphs
        // apart: one the file already had, else the first one made. Every other fresh one opens.
        func assign(_ run: [Int], afterProse: Bool) {
            var separated = !afterProse || run.contains { !isFresh($0) }
            for j in run where isFresh(j) {
                if separated { setOpen(j, true) } else { setOpen(j, false); separated = true }
            }
        }
        assign(above, afterProse: joins)
        if caretOnBlank { setOpen(line, true) }
        let caretMetrics = caretOnBlank ? virtualMetrics(atUnit: line) : styledMetrics(at: units.range(of: line).location)
        assign(below, afterProse: caretMetrics?.kind == .body)
        guard changed else { return nil }
        let a = units.range(of: above.first ?? line).location
        let last = below.last ?? line
        // The line after the run takes its gap from the lines above it.
        let end = nextLine(last).map { NSMaxRange(units.range(of: $0)) } ?? NSMaxRange(units.range(of: last))
        return NSRange(location: a, length: end - a)
    }

    /// Where a caret that is only passing stops instead of `location`.
    enum Stop: Equatable {
        case caret(Int)
        /// A block component, taken whole (outlined, still drawn).
        case component(NSRange)
    }

    /// Where a caret on a line without height goes instead (a closed blank line, a setext
    /// underline: nothing shows there to type into): the next line with something on it, or going
    /// back, the end of the line before; a component on the way is taken whole. Nil when the
    /// location is on a line that shows, or no line in either direction shows anything (then a
    /// blank line opens for the caret).
    func caretOffBlankLine(_ location: Int, backward: Bool) -> Stop? {
        guard units.count > 0 else { return nil }
        let line = firstUnit(ofLineAt: location)
        let underline = styledMetrics(at: units.range(of: line).location)?.kind == .setextUnderline
        guard underline || isBlankLine(line) && !open.contains(units.units[line].id) else { return nil }
        // Lines with something on them: not a closed blank line, not the rest of a component or a
        // hidden setext underline.
        func shown(_ j: Int) -> Bool {
            (!isBlankLine(j) || open.contains(units.units[j].id)) && canvas.layout(j).height >= 0.5
        }
        // A component on the way is taken whole, as the arrow keys take it.
        func whole(_ j: Int) -> Stop? {
            guard let box = canvas.layout(j).content.component else { return nil }
            return drawnComponent(around: units.range(of: j).location + canvas.layout(j).sourceStart(ofLine: 0)).map { .component($0) } ?? .component(box.lastKnownRange)
        }
        func forward() -> Stop? {
            var j = line
            while let n = nextLine(j) {
                if shown(n) { return whole(n) ?? .caret(units.range(of: n).location + canvas.layout(n).sourceStart(ofLine: 0)) }
                j = n
            }
            return nil
        }
        func back() -> Stop? {
            var j = line
            while let p = previousLine(j) {
                if shown(p) {
                    if let stop = whole(p) { return stop }
                    // The end of that line, before its line break.
                    let last = units.range(of: (nextLine(p) ?? units.count) - 1)
                    var end = NSMaxRange(last)
                    while end > last.location, TextUnits.isTerminator(text.character(at: end - 1)) { end -= 1 }
                    return .caret(end)
                }
                j = p
            }
            return nil
        }
        let ahead = forward(), behind = back()
        // Below a final component nothing follows: the line opens for a new paragraph there.
        if ahead == nil, case .component? = behind, !underline {
            open.insert(units.units[line].id)
            return nil
        }
        if let target = backward ? behind ?? ahead : ahead ?? behind { return target }
        if !underline { open.insert(units.units[line].id) }
        return nil
    }

    /// The block component whose source holds `location` (its ends included) while it is drawn: a
    /// caret that only passes takes it whole instead of turning it into source.
    func drawnComponent(around location: Int) -> NSRange? {
        guard !structure.chunks.isEmpty else { return nil }
        for i in [location, location - 1] where i >= 0 && i < text.length {
            let c = structure.index.index(containing: i)
            guard let s = styledChunk(c) else { continue }
            let base = structure.chunks[c].range.location
            guard i - base >= 0, i - base < s.length else { continue }
            var full = NSRange()
            guard let box = s.attribute(.zComponent, at: i - base, longestEffectiveRange: &full, in: NSRange(location: 0, length: s.length)) as? ComponentBox, box.isBlock else { continue }
            let r = NSRange(location: base + full.location, length: full.length)
            if location >= r.location, location <= NSMaxRange(r), !isRevealed(component: r) { return r }
        }
        return nil
    }

    /// `location` starts an empty line right below a drawn block component.
    func isEmptyLineBelowComponent(_ location: Int) -> Bool {
        guard location > 0, location <= text.length else { return false }
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        guard line.location == location, (location..<NSMaxRange(line)).allSatisfy({ TextUnits.isTerminator(text.character(at: $0)) }) else { return false }
        let above = location >= 2 && text.character(at: location - 1) == 0x0A && text.character(at: location - 2) == 0x0D ? location - 2 : location - 1
        return drawnComponent(around: above) != nil
    }

    /// Open the blank line holding `location` (back from plain text, the caret stays where it was).
    func openLine(at location: Int) {
        guard units.count > 0 else { return }
        let line = firstUnit(ofLineAt: location)
        if isBlankLine(line) { open.insert(units.units[line].id) }
    }

    /// The first unit of the source line holding `location`.
    private func firstUnit(ofLineAt location: Int) -> Int {
        units.firstUnit(ofLine: units.line(ofUnit: units.unit(containing: min(location, text.length))))
    }
    private func previousLine(_ j: Int) -> Int? { j > 0 ? units.firstUnit(ofLine: units.line(ofUnit: j - 1)) : nil }
    private func nextLine(_ j: Int) -> Int? {
        let l = units.line(ofUnit: j)
        return l + 1 < units.lineCount ? units.firstUnit(ofLine: l + 1) : nil
    }

    /// A blank source line outside code (a line with only a quote marker is one too).
    func isBlankLine(_ j: Int) -> Bool {
        units.units[j].startsLine && styledMetrics(at: units.range(of: j).location)?.kind == .blank
    }

    private static func touches(_ sel: NSRange, _ r: NSRange) -> Bool {
        sel.location <= NSMaxRange(r) && NSMaxRange(sel) >= r.location
    }

    /// The selection edits a component's source: the caret is in it, or an end of the selection is
    /// strictly inside it. A selection that covers a component whole leaves it drawn (and selected).
    private static func edits(_ sel: NSRange, _ r: NSRange) -> Bool {
        if sel.length == 0 { return touches(sel, r) }
        func inside(_ i: Int) -> Bool { i > r.location && i < NSMaxRange(r) }
        return inside(sel.location) || inside(NSMaxRange(sel))
    }

    private func isRevealed(marker index: Int) -> Bool {
        revealedMarkers.contains { NSLocationInRange(index, $0) }
    }

    private func isRevealed(component range: NSRange) -> Bool {
        revealedComponents.contains { $0 == range }
    }

    // MARK: - Line metrics and block gaps (design §8.1)

    /// Metrics of the source line that unit `j` starts, as the styler set them; nil for plain text.
    private func metrics(atUnit j: Int) -> LineMetrics? {
        if open.contains(units.units[j].id) { return virtualMetrics(atUnit: j) }
        return styledMetrics(at: units.range(of: j).location)
    }

    /// An attribute the styler set on the character at `location` (a link's destination, a
    /// component), or nil in plain chunks.
    func attribute(_ key: NSAttributedString.Key, at location: Int) -> Any? {
        guard !structure.chunks.isEmpty, location < text.length else { return nil }
        let c = structure.index.index(containing: location)
        guard let s = styledChunk(c) else { return nil }
        let local = location - structure.chunks[c].range.location
        guard local >= 0, local < s.length else { return nil }
        return s.attribute(key, at: local, effectiveRange: nil)
    }

    /// The run of always-hidden syntax (container prefixes, list markers) holding the character at
    /// `location`: the caret never stands inside it, where typing would land in front of the syntax.
    func alwaysHiddenSpan(at location: Int) -> NSRange? {
        func hidden(_ i: Int) -> Bool { attribute(.zStructural, at: i) != nil || attribute(.zListMarker, at: i) != nil }
        guard location < text.length, hidden(location) else { return nil }
        var start = location, end = location
        while start > 0, hidden(start - 1) { start -= 1 }
        while end < text.length, hidden(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Metrics of the line starting at `location`, as styled.
    func lineMetrics(at location: Int) -> LineMetrics? { styledMetrics(at: location) }

    private func styledMetrics(at location: Int) -> LineMetrics? {
        guard !structure.chunks.isEmpty else { return nil }
        let c = structure.index.index(containing: location)
        guard let s = styledChunk(c) else { return nil }
        let local = location - structure.chunks[c].range.location
        // The end of a chunk after its last line break, or an empty document: a blank line.
        guard local >= 0, local < s.length else { return local == s.length && (local > 0 || text.length == 0) ? blankMetrics : nil }
        return s.attribute(.zLine, at: local, effectiveRange: nil) as? LineMetrics
    }

    private var blankMetrics: LineMetrics

    private static func blank(_ t: Typography) -> LineMetrics {
        LineMetrics(kind: .blank, font: t.bodyFont, lineHeight: t.blankLineHeight, quoteDepth: 0, listDepth: 0, indent: 0)
    }

    /// What an open blank line is about to become: a line of the paragraph right above it, or a new
    /// paragraph.
    private func virtualMetrics(atUnit j: Int) -> LineMetrics {
        let font = typography.bodyFont
        let height = typography.lineHeight(for: font, kind: .body)
        var above: LineMetrics?
        if j > 0 { above = styledMetrics(at: units.range(of: units.firstUnit(ofLine: units.line(ofUnit: j - 1))).location) }
        if let p = above, p.kind == .body {
            return LineMetrics(kind: .body, font: font, lineHeight: height, quoteDepth: p.quoteDepth, listDepth: p.listDepth, indent: p.indent)
        }
        if let item = Self.listOwner(ofLine: units.range(of: j).location, in: text).flatMap({ styledMetrics(at: $0.line.location) }) {
            return LineMetrics(kind: .body, font: font, lineHeight: height, quoteDepth: item.quoteDepth, listDepth: item.listDepth, indent: item.indent, startsBlock: true)
        }
        return LineMetrics(kind: .body, font: font, lineHeight: height, quoteDepth: 0, listDepth: 0, indent: 0, startsBlock: true)
    }

    /// Quote markers, then indentation, then an optional list marker and its spacing.
    private static let lineLead = try! NSRegularExpression(pattern: #"^((?:[ \t]*>[ \t]?)*)([ \t]*)(?:([-*+]|\d{1,9}[.)])(?:[ \t]+|$))?"#)

    /// The list item a line's indentation puts it under (an indented blank line, as Backspace on a
    /// nested item leaves, or a nested paragraph): the nearest item above, in the same quote, whose
    /// marker is left of the line's indentation and whose text starts at or before it. Its line,
    /// marker column and text column; nil for a line not indented under an item, or an item line.
    static func listOwner(ofLine location: Int, in text: NSString) -> (line: NSRange, marker: Int, content: Int)? {
        func lead(_ r: NSRange) -> (quote: String, column: Int, content: Int?, blank: Bool) {
            let line = text.substring(with: r)
            guard let m = Self.lineLead.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return ("", 0, nil, true) }
            let ns = line as NSString
            var column = 0
            for c in ns.substring(with: m.range(at: 2)) { column = c == "\t" ? column / 4 * 4 + 4 : column + 1 }
            let content = m.range(at: 3).location == NSNotFound ? nil : column + NSMaxRange(m.range) - m.range(at: 3).location
            let blank = ns.substring(from: NSMaxRange(m.range)).allSatisfy(\.isWhitespace) && content == nil
            return (ns.substring(with: m.range(at: 1)).filter { $0 == ">" }, column, content, blank)
        }
        let here = text.lineRange(for: NSRange(location: location, length: 0))
        let own = lead(here)
        guard own.column > 0, own.content == nil else { return nil }
        var start = here.location, steps = 0
        while start > 0, steps < 256 {
            let r = text.lineRange(for: NSRange(location: start - 1, length: 0))
            start = r.location
            steps += 1
            let l = lead(r)
            guard l.quote == own.quote else { return nil }
            if l.blank { continue }
            if let content = l.content, l.column < own.column { return content <= own.column ? (r, l.column, content) : nil }
            // Text at the margin ends the lists above (a lazy continuation line is taken as such).
            if l.content == nil, l.column == 0 { return nil }
        }
        return nil
    }

    /// The nearest line above unit `i` that shows (open blank lines show), and the shallowest quote
    /// among the closed blank lines in between (nil when there are none).
    private func lineAbove(_ i: Int) -> (metrics: LineMetrics?, blankQuote: Int?) {
        var j = i - 1, steps = 0
        var blankQuote: Int?
        while j >= 0, steps < 256 {
            if units.units[j].startsLine {
                guard let m = metrics(atUnit: j) else { return (nil, blankQuote) }
                if m.kind != .blank { return (m, blankQuote) }
                blankQuote = min(blankQuote ?? m.quoteDepth, m.quoteDepth)
                steps += 1
            }
            j -= 1
        }
        return (nil, blankQuote)
    }

    /// Space above unit `i`'s first line: the gap between two blocks (by their kinds, whatever
    /// blank lines lie between), or the space before a line that follows a line break.
    private func gapAbove(_ i: Int, _ m: LineMetrics) -> CGFloat {
        guard i > 0 else { return 0 }
        guard m.startsBlock else { return m.kind == .body ? typography.lineBreakGap : 0 }
        return typography.blockGap(after: lineAbove(i).metrics, before: m)
    }

    // MARK: - Heading numbers

    /// The drawn number of the heading starting at `location` (design §8.1: numbers are drawn, the
    /// file keeps its text). ATX headings outside fenced code, counted once per edit.
    func headingNumber(at location: Int) -> String? {
        guard typography.numbering != .none else { return nil }
        if headingNumbers == nil {
            var result: [Int: String] = [:]
            var counts = [Int](repeating: 0, count: 7)
            for h in canvas.headings() {
                let level = min(max(h.level, 1), 6)
                counts[level] += 1
                for deeper in level + 1 ..< 7 { counts[deeper] = 0 }
                if let number = typography.headingNumber(level: level, counts: counts) { result[h.location] = number }
            }
            headingNumbers = result
        }
        return headingNumbers?[location]
    }

    // MARK: - Unit content

    /// What unit `i` shows, or nil when its chunk is shown plain.
    func content(_ i: Int) -> UnitContent? {
        let unit = units.units[i]
        let range = units.range(of: i)
        var length = range.length
        while length > 0, TextUnits.isTerminator(text.character(at: range.location + length - 1)) { length -= 1 }
        guard !structure.chunks.isEmpty else { return nil }
        let c = structure.index.index(containing: range.location)
        guard let s = styledChunk(c) else { return nil }
        let base = structure.chunks[c].range.location
        let local = range.location - base
        guard local >= 0, local + length <= s.length else { return nil }
        let lineStart = unit.startsLine
        var m = (local < s.length ? s.attribute(.zLine, at: local, effectiveRange: nil) as? LineMetrics : nil) ?? blankMetrics
        let empty = NSAttributedString()

        // Blank lines have no height; an open one is laid out as the line it is about to become
        // (its quote or list prefix, if any, stays hidden before the caret).
        if m.kind == .blank, lineStart {
            guard open.contains(unit.id) else {
                return UnitContent(body: .space(0), string: empty, map: .identity(length), metrics: m, indent: m.indent)
            }
            m = virtualMetrics(atUnit: i)
            let content = UnitContent(body: .text, string: NSAttributedString(string: "", attributes: [.font: typography.bodyFont]),
                                      map: IndexMap(runs: [], sourceLength: length, displayLength: 0), metrics: m, gap: gapAbove(i, m), indent: m.indent)
            content.quoteSkip = quoteSkip(i, m, gap: content.gap)
            return content
        }

        let gap = lineStart ? gapAbove(i, m) : 0
        let unitRange = NSRange(location: local, length: length)

        // A block component on this line (after the container prefix), unless the caret is in it.
        if let (box, full) = blockComponent(in: s, unitRange), !isRevealed(component: NSRange(location: base + full.location, length: full.length)) {
            box.lastKnownRange = NSRange(location: base + full.location, length: full.length)
            if full.location < local {
                return UnitContent(body: .space(0), string: empty, map: .identity(length), metrics: m)
            }
            let start = full.location - local
            let map = IndexMap(runs: [.init(display: 0, source: start, displayLength: 0, sourceLength: length - start)], sourceLength: length, displayLength: 0)
            return UnitContent(body: .component(box), string: empty, map: map, metrics: m, gap: gap, indent: m.indent)
        }

        // Fences collapse into their band unless the caret is in the code block. A setext underline
        // never shows here (it is edited as plain text, ⌘/): showing it would push the text below.
        if m.kind == .setextUnderline || m.kind == .fence
            && !revealedMarkers.contains(where: { NSIntersectionRange($0, NSRange(location: range.location, length: length)).length > 0 }) {
            let content = UnitContent(body: .space(m.collapsedHeight), string: empty, map: .identity(length), metrics: m, gap: gap, indent: m.indent)
            content.code = codeSlice(s, base: base, local: local, length: range.length, m: m)
            return content
        }

        // Text: the line with hidden syntax left out and formulas as single placeholders.
        let (string, map, leading) = display(s, unitRange, base: base)
        var indent = m.indent, first: CGFloat = 0, tail: CGFloat = 0, justified = false
        if let p = (local < s.length ? s.attribute(.paragraphStyle, at: local, effectiveRange: nil) : nil) as? NSParagraphStyle {
            indent = p.headIndent
            first = lineStart ? p.firstLineHeadIndent - p.headIndent : 0
            tail = p.tailIndent < 0 ? -p.tailIndent : 0
            justified = p.alignment == .justified
        }
        let content = UnitContent(body: .text, string: string, map: map, metrics: m, gap: gap, indent: indent, firstIndent: first, tail: tail, justified: justified)
        // A revealed fence stays in its band, however long its info string.
        content.singleLine = m.kind == .fence
        if lineStart {
            content.listMarker = listMarker(s, unitRange)
            if m.kind == .heading, m.quoteDepth == 0, m.listDepth == 0 {
                content.headingRule = typography.headingRule(level: m.headingLevel)
            }
            content.quoteSkip = quoteSkip(i, m, gap: gap)
            // Shown heading markers hang in the margin where they fit, otherwise show inline.
            if m.kind == .heading {
                content.markerWidth = markerWidth(s, unitRange)
                content.markerLength = leading
                content.markersShown = leading > 0 && leading < string.length
            }
        }
        content.code = codeSlice(s, base: base, local: local, length: range.length, m: m)
        return content
    }

    /// Width of the hidden syntax a heading line starts with (`## `), as it shows when revealed.
    private func markerWidth(_ s: NSAttributedString, _ r: NSRange) -> CGFloat {
        let end = NSMaxRange(r)
        var i = r.location
        while i < end, s.attribute(.zStructural, at: i, effectiveRange: nil) != nil || s.attribute(.zListMarker, at: i, effectiveRange: nil) != nil { i += 1 }
        var j = i
        while j < end, s.attribute(.zHide, at: j, effectiveRange: nil) != nil { j += 1 }
        guard j > i, j < end else { return 0 }
        let prefix = NSMutableAttributedString(attributedString: s.attributedSubstring(from: NSRange(location: i, length: j - i)))
        for key in Self.drawnKeys { prefix.removeAttribute(key, range: NSRange(location: 0, length: prefix.length)) }
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(prefix), nil, nil, nil))
    }

    /// The gap above a quote's first line that its bars leave out: where the quote begins, not
    /// between two paragraphs of the same quote.
    private func quoteSkip(_ i: Int, _ m: LineMetrics, gap: CGFloat) -> CGFloat {
        guard m.quoteDepth > 0, m.startsBlock, gap > 0 else { return 0 }
        let above = lineAbove(i)
        let shallowest = min(above.metrics?.quoteDepth ?? 0, above.blankQuote ?? m.quoteDepth)
        return shallowest < m.quoteDepth ? gap : 0
    }

    /// The block component a line shows: the first thing after its container prefix.
    private func blockComponent(in s: NSAttributedString, _ r: NSRange) -> (ComponentBox, NSRange)? {
        let string = s.string as NSString
        var i = r.location
        let end = NSMaxRange(r)
        while i < end {
            var run = NSRange()
            let attrs = s.attributes(at: i, longestEffectiveRange: &run, in: NSRange(location: i, length: end - i))
            if let box = attrs[.zComponent] as? ComponentBox {
                guard box.isBlock else { return nil }
                var full = NSRange()
                s.attribute(.zComponent, at: i, longestEffectiveRange: &full, in: NSRange(location: 0, length: s.length))
                return (box, full)
            }
            if attrs[.zStructural] != nil || attrs[.zListMarker] != nil {
                i = NSMaxRange(run)
            } else if [0x20, 0x09].contains(string.character(at: i)) {
                i += 1
            } else {
                return nil
            }
        }
        // A blank line inside a block component (an HTML container's) belongs to the component.
        guard r.location < s.length, let box = s.attribute(.zComponent, at: r.location, effectiveRange: nil) as? ComponentBox, box.isBlock else { return nil }
        var full = NSRange()
        s.attribute(.zComponent, at: r.location, longestEffectiveRange: &full, in: NSRange(location: 0, length: s.length))
        return full.location < r.location ? (box, full) : nil
    }

    /// The marker drawn before a list item; task items show only their box.
    private func listMarker(_ s: NSAttributedString, _ r: NSRange) -> ListMarkerBox.Kind? {
        var kinds: [ListMarkerBox.Kind] = []
        s.enumerateAttribute(.zListMarker, in: r) { value, _, _ in
            if let box = value as? ListMarkerBox { kinds.append(box.kind) }
        }
        return kinds.first { if case .checkbox = $0 { true } else { false } } ?? kinds.first
    }

    private func codeSlice(_ s: NSAttributedString, base: Int, local: Int, length: Int, m: LineMetrics) -> UnitContent.CodeSlice? {
        // Indented code starts after its indentation: look along the whole line.
        var found: (CodeBlockBox, Int)?
        s.enumerateAttribute(.zCodeBlock, in: NSRange(location: local, length: min(length, s.length - local))) { value, r, stop in
            if let box = value as? CodeBlockBox { found = (box, r.location); stop.pointee = true }
        }
        guard let (box, at) = found else { return nil }
        var full = NSRange()
        s.attribute(.zCodeBlock, at: at, longestEffectiveRange: &full, in: NSRange(location: 0, length: s.length))
        // A drawn diagram stands in for its code block.
        var diagram = NSRange()
        if s.attribute(.zComponent, at: full.location, longestEffectiveRange: &diagram, in: NSRange(location: 0, length: s.length)) is DiagramBox,
           !isRevealed(component: NSRange(location: base + diagram.location, length: diagram.length)) { return nil }
        var number: Int?
        if typography.codeLineNumbers, m.kind != .fence {
            let string = s.string as NSString
            var lines = 0
            var p = full.location
            while p < local {
                let c = string.character(at: p)
                if c == 0x0A || (c == 0x0D && !(p + 1 < string.length && string.character(at: p + 1) == 0x0A)) { lines += 1 }
                p += 1
            }
            let opensWithFence = (s.attribute(.zLine, at: full.location, effectiveRange: nil) as? LineMetrics)?.kind == .fence
            number = lines + 1 - (opensWithFence ? 1 : 0)
        }
        return .init(box: box, isFirst: full.location >= local, isLast: NSMaxRange(full) <= local + length, number: number)
    }

    /// The display text of `r` (chunk-local) and its map: hidden syntax left out unless revealed,
    /// formulas as one placeholder each. Attributes the canvas draws itself are dropped. `leading`
    /// counts the revealed syntax the display text starts with (a heading's `## `).
    private func display(_ s: NSAttributedString, _ r: NSRange, base: Int) -> (NSAttributedString, IndexMap, leading: Int) {
        let out = NSMutableAttributedString()
        var runs: [IndexMap.Run] = []
        var leading = 0, textSeen = false
        let string = s.string as NSString
        func keep(_ range: NSRange, _ attrs: [NSAttributedString.Key: Any]) {
            guard range.length > 0 else { return }
            var a = attrs
            for key in Self.drawnKeys { a[key] = nil }
            let source = range.location - r.location
            out.append(NSAttributedString(string: string.substring(with: range), attributes: a))
            if let last = runs.last, !last.isAtomic, last.source + last.sourceLength == source {
                runs[runs.count - 1].displayLength += range.length
                runs[runs.count - 1].sourceLength += range.length
            } else {
                runs.append(.init(display: out.length - range.length, source: source, displayLength: range.length, sourceLength: range.length))
            }
        }
        var skipUntil = r.location
        s.enumerateAttributes(in: r) { attrs, run, _ in
            var run = run
            if run.location < skipUntil {
                guard NSMaxRange(run) > skipUntil else { return }
                run = NSRange(location: skipUntil, length: NSMaxRange(run) - skipUntil)
            }
            if attrs[.zStructural] != nil || attrs[.zListMarker] != nil { return }
            if let object = attrs[.zComponent] as? any InlineComponent {
                var full = NSRange()
                s.attribute(.zComponent, at: run.location, longestEffectiveRange: &full, in: NSRange(location: 0, length: s.length))
                object.lastKnownRange = NSRange(location: base + full.location, length: full.length)
                if !isRevealed(component: object.lastKnownRange) {
                    let end = min(NSMaxRange(full), NSMaxRange(r))
                    skipUntil = end
                    guard run.location == full.location, let delegate = RunSize.delegate(for: object) else { return }
                    var a = attrs
                    for key in Self.drawnKeys { a[key] = nil }
                    a[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = delegate
                    a[.zComponent] = object
                    out.append(NSAttributedString(string: "\u{FFFC}", attributes: a))
                    textSeen = true
                    runs.append(.init(display: out.length - 1, source: full.location - r.location, displayLength: 1, sourceLength: end - full.location))
                    return
                }
            }
            if attrs[.zHide] != nil {
                // Revealed parts of hidden syntax show (faint, as the styler colored them).
                var p = run.location
                while p < NSMaxRange(run) {
                    let shown = isRevealed(marker: base + p)
                    var q = p + 1
                    while q < NSMaxRange(run), isRevealed(marker: base + q) == shown { q += 1 }
                    if shown {
                        keep(NSRange(location: p, length: q - p), attrs)
                        if !textSeen { leading += q - p }
                    }
                    p = q
                }
                return
            }
            keep(run, attrs)
            textSeen = true
        }
        let map = IndexMap(runs: runs, sourceLength: r.length, displayLength: out.length)
        return (out, map, leading)
    }

    /// Attributes the canvas reads elsewhere or draws itself; Core Text never sees them.
    private static let drawnKeys: [NSAttributedString.Key] = [.paragraphStyle, .zLine, .zHide, .zStructural, .zListMarker, .zCodeBlock, .zComponent]
}

/// A context for presenters built without a document (tests): no base URL.
final class NullContext: RenderContext {
    static let shared = NullContext()
    var typography = Typography()
    var baseURL: URL? { nil }
    var frontMatterCollapsed: Bool { false }
    var loadsRemoteImages: Bool { false }
    func componentNeedsLayout(_ box: ComponentBox) {}
    func componentNeedsDisplay(_ box: ComponentBox) {}
    func componentNeedsDisplay(_ box: ComponentBox, in rect: NSRect) {}
}
