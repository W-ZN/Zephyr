import AppKit
import CoreText
import ZephyrCore
import ZephyrLayout

/// The block canvas (design §4, block layout): Zephyr's own layout engine on top of Core Text
/// shaping and line breaking. The text is cut into units (`TextUnits`, one per source line) that
/// are laid out independently; only units near the viewport are ever shaped, the rest have
/// estimated heights (`HeightMap`), and the text on screen is anchored while estimates turn into
/// real heights. Opening, jumping, resizing and typing therefore cost the same on a 20 MB paragraph
/// as on a short note.
///
/// It presents the text in one of two ways. `rendered` shows Markdown as the reader sees it
/// (`MarkdownPresenter`: hidden syntax revealed at the caret, list markers, code blocks, headings,
/// formulas, tables and other components). `source` shows the text as written: plain-text writing
/// (⌘/), and the files that are too big or too long-lined to style in budget (design §3.2). The two
/// share the text, selection and undo, so switching between them changes only the presentation.
///
/// Its text model is a plain `NSMutableString`, not an `NSTextStorage`: a text storage walks to the
/// paragraph's ends on every edit (37 ms per keystroke in a 20 MB paragraph). `MarkdownEditor`
/// routes the document's text, external merges and proposals here, so saving, agents and undo work
/// as on the TextKit canvas (design §5).
@MainActor
public final class BlockCanvas: NSObject {
    public enum Mode: Sendable { case source, rendered }

    public private(set) var mode: Mode
    /// A print copy uses the paper width and omits the screen's background and margins.
    var isPrinting = false
    /// Print uses white paper unless an export snapshot supplies its theme's page color.
    var printBackground: NSColor?
    /// A snippet (`MarkdownSnippet`) sets its text across the whole width it is given.
    var fillsWidth = false
    public let scrollView = NSScrollView()
    public let view: BlockCanvasView
    /// The document's text while this canvas shows it.
    public let text: NSMutableString
    public private(set) var typography: Typography
    /// Inserted by Return, matching the file (design §5).
    public var newline = "\n"
    public var isEditable = true { didSet { view.updateCaret() } }
    public var selectionDidChange: (() -> Void)?
    /// The Find bar's matches in order, and the index of the one it is on (design §8).
    var findMatches: [NSRange] = [] { didSet { view.needsDisplay = true } }
    var findCurrent: Int?
    /// After every change to the text (typed, undone, merged, proposed).
    public var textDidChange: (() -> Void)?
    private(set) var presenter: MarkdownPresenter?

    private(set) var units: TextUnits
    private(set) var heights = HeightMap()
    private var layouts: [UInt64: UnitLayout] = [:]
    private var lastUse: [UInt64: Int] = [:]
    private var clock = 0
    private var cachedCost = 0
    /// Units showing a block component: their layout follows the window's width, not only the column's.
    private var wideUnits = Set<UInt64>()
    /// Shaped lines kept for units off screen, in bytes (design §3.1): a few screens of the
    /// longest units.
    static let cacheBudget = 16 << 20

    private var plainAttributes: [NSAttributedString.Key: Any] = [:]
    private var plainMetrics: LineMetrics!
    private(set) var lineHeight: CGFloat = 26
    private var averageAdvance: CGFloat = 9
    private(set) var columnWidth: CGFloat = 700
    private(set) var columnX: CGFloat = 28
    static let topInset: CGFloat = 40
    static let bottomInset: CGFloat = 40
    /// The least room on each side of the column; the left one holds a block's handle (18 pt,
    /// 8 pt from what it moves, 2 pt from the edge). A heading's revealed markers hang left of the
    /// handle's slot only where the margin has room for them too, otherwise they show inline
    /// (design §8.1).
    public static let minimumMargin: CGFloat = 28
    static let handleSlot: CGFloat = 28
    /// Width covered on the leading side by something floating over the canvas (an open sidebar):
    /// the column keeps clear of it, moving no further than it must (design §7.4).
    public var leadingInset: CGFloat = 0 {
        didSet { if leadingInset != oldValue { widthChanged() } }
    }
    /// Width at the trailing edge that is outside the reader's usable area (the compact outline
    /// rail, measured against the scroll view's actual content viewport).
    public var trailingInset: CGFloat = 0 {
        didSet { if trailingInset != oldValue { widthChanged() } }
    }
    /// Room each side of the column keeps for something drawn beside it (the outline rail): the
    /// column narrows to keep it, the same on both sides (design §8).
    public var reservedMargin: CGFloat = 0 {
        didSet { if reservedMargin != oldValue { widthChanged() } }
    }
    private var sideMargin: CGFloat { max(Self.minimumMargin, reservedMargin) }
    /// Where the band a table set to the window's width may use starts; it keeps the same margins
    /// as the column, so it never reaches under a rail.
    private var bandLeading: CGFloat { isPrinting || fillsWidth ? 0 : sideMargin + leadingInset }
    private var bandTrailing: CGFloat { isPrinting || fillsWidth ? 0 : sideMargin + trailingInset }

    public private(set) var selection = NSRange(location: 0, length: 0)
    /// Text the input method is composing; it lives in the text like typed text.
    var markedRange: NSRange?
    /// What the composition replaced, restored when it is cancelled and undone as one step.
    var markOrigin: (range: NSRange, text: String)?
    /// The moving selection end at a wrap point belongs to the end of the line above.
    var upstream = false
    /// Horizontal position kept by Up and Down.
    var goalX: CGFloat?
    /// A block component the arrow keys stopped on as a whole: drawn, outlined, not turned into
    /// source (design §8.1). Return edits it, Delete removes it, the arrows move on.
    private(set) var focusedComponent: NSRange?
    /// The component the caret sits below when it ends the file without a line break: the caret is
    /// on a line the file does not have yet, and the first input supplies it (design §8.1).
    private(set) var belowComponent: NSRange?
    /// Changes from outside the undo history (merged external edits), in order. An undo step
    /// recorded before one maps its range across it, so a merge keeps the writer's history.
    private var outsideEdits: [(range: NSRange, delta: Int)] = []

    /// `range`, recorded after `count` outside changes, in the text as it is now; nil when an
    /// outside change reached into it.
    private func current(_ range: NSRange, since count: Int) -> NSRange? {
        var r = range
        for edit in outsideEdits[count...] {
            if NSMaxRange(r) <= edit.range.location { continue }
            guard r.location >= NSMaxRange(edit.range) else { return nil }
            r.location += edit.delta
        }
        return r
    }

    /// Units edits made in plain text, settled like the rendered canvas's when it comes back.
    private var sourceCreated = Set<UInt64>()
    /// Blank lines laid out as empty lines (`MarkdownPresenter.settle`), by unit id: kept while the
    /// document is open, in both presentations.
    var openBlanks = Set<UInt64>()
    /// Units an edit at the caret made, until the selection after it settles the blank lines.
    private var pendingSettle: Set<UInt64>?
    private var adjusting = false
    private var typing: TypingRun?

    public init(text: NSMutableString, typography: Typography, mode: Mode = .source, context: RenderContext? = nil) {
        self.text = text
        self.typography = typography
        self.mode = mode
        units = TextUnits(text: text)
        view = BlockCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        self.context = context
        if mode == .rendered, let context { presenter = MarkdownPresenter(canvas: self, context: context, typography: typography) }
        view.canvas = self
        scrollView.documentView = view
        // No scroll bar, in any "Show scroll bars" mode: the outline's reading mark is the position
        // indicator, and the text still scrolls by wheel, trackpad and keys.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Tokens.canvas
        view.autoresizingMask = [.width]
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        applyMetrics()
        resetHeights()
    }

    /// The document the rendered canvas resolves images against and reports async layout to
    /// (it owns the canvas, so it attaches itself once it exists).
    public func attach(context: RenderContext) {
        self.context = context
        guard mode == .rendered else { return }
        presenter = MarkdownPresenter(canvas: self, context: context, typography: typography)
        resetHeights()
    }
    private weak var context: RenderContext?

    /// Show the text rendered or as written. The text, selection and undo stay; the caret's line
    /// keeps its place in the window (or, off screen, the top line does).
    public func setMode(_ new: Mode) {
        guard new != mode else { return }
        let clip = scrollView.contentView
        let caret = selection.location
        let caretTop = lineBox(at: caret).minY - clip.bounds.minY
        let caretShown = selection.length == 0 && caretTop >= 0 && caretTop < clip.bounds.height
        let anchor = firstVisibleCharacter()
        mode = new
        presenter = new == .rendered && context != nil ? MarkdownPresenter(canvas: self, context: context, typography: typography) : nil
        focusedComponent = nil
        wideUnits.removeAll()
        applyMetrics()
        if selection.length == 0 { presenter?.openLine(at: selection.location) }
        // Blank lines Return made in plain text are this session's, as on the rendered canvas.
        if let presenter, !sourceCreated.isEmpty, selection.length == 0 { _ = presenter.settle(caret: selection.location, created: sourceCreated) }
        sourceCreated.removeAll()
        resetHeights()
        select(selection, upstream: upstream)
        if caretShown {
            scroll(toCharacter: caret, margin: caretTop)
        } else {
            scroll(toCharacter: anchor)
        }
    }

    // MARK: - Routing (design §3.2)

    /// Whether a text belongs on the source canvas rather than a rendered one: 8 M UTF-16 units or
    /// more, or mostly lines of 20 000 units or more (the length at which rendering already shows
    /// source). A normal document with one long line (an inline base64 image) stays rendered.
    public static func prefers(_ text: NSString) -> Bool {
        let n = text.length
        if n >= 8_000_000 { return true }
        guard n >= 20_000 else { return false }
        var long = 0, lineStart = 0, base = 0
        let chunk = 65_536
        var buffer = [unichar](repeating: 0, count: chunk)
        while base < n {
            let count = min(chunk, n - base)
            buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: base, length: count)) }
            for i in 0..<count where buffer[i] == 0x0A || buffer[i] == 0x0D {
                if base + i - lineStart >= 20_000 { long += base + i - lineStart }
                lineStart = base + i + 1
            }
            base += count
        }
        if n - lineStart >= 20_000 { long += n - lineStart }
        return long * 2 >= n
    }

    // MARK: - Metrics

    private func applyMetrics() {
        let font = typography.bodyFont
        plainAttributes = [.font: font, .foregroundColor: Palette.text]
        lineHeight = typography.lineHeight(for: font, kind: .body)
        plainMetrics = LineMetrics(kind: .body, font: font, lineHeight: lineHeight, quoteDepth: 0, listDepth: 0, indent: 0)
        // The average advance of the document's own opening text sizes the estimates.
        let ns: NSString = text
        let sample = ns.substring(to: min(ns.length, 3000)).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        if sample.isEmpty {
            averageAdvance = font.pointSize * 0.6
        } else {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample, attributes: [.font: font]))
            averageAdvance = max(1, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) / CGFloat((sample as NSString).length))
        }
        (columnX, columnWidth) = column(for: view.bounds.width)
    }

    /// The reading column is centered between its insets (what a rail covers on either side) and
    /// narrows with that room; the left keeps the handle's and markers' slots.
    private func column(for width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        if fillsWidth { return (0, max(40, width)) }
        if isPrinting {
            let w = min(typography.readableWidth, width)
            return (max(0, (width - w) / 2), w)
        }
        let leading = sideMargin + leadingInset
        let trailing = sideMargin + trailingInset
        let readerWidth = width - leading - trailing
        let w = min(typography.readableWidth + 10, max(40, readerWidth))
        let centered = floor((width + sideMargin + leadingInset - trailing - w) / 2)
        return (max(leading, centered) + 5, w - 10)
    }

    private func estimate(_ length: Int) -> Double {
        // Empty lines are mostly the gaps between blocks.
        if length <= 1, mode == .rendered { return Double(lineHeight) * 0.5 }
        return Double(max(1, ceil(Double(length) * Double(averageAdvance) / Double(columnWidth)))) * Double(lineHeight)
    }

    private func resetHeights() {
        layouts.removeAll()
        lastUse.removeAll()
        cachedCost = 0
        heights.reset(units.units.map { estimate($0.length) })
        updateFrameHeight()
    }

    /// Typography changed: the text stays where it is on screen.
    public func apply(typography newTheme: Typography) {
        let anchor = firstVisibleCharacter()
        typography = newTheme
        presenter?.apply(typography: newTheme)
        applyMetrics()
        resetHeights()
        scroll(toCharacter: anchor)
    }

    func widthChanged() {
        let new = column(for: view.bounds.width)
        columnX = new.x
        guard abs(new.width - columnWidth) > 0.5 else {
            // The column kept its width: only components that break out into the band follow the window.
            forget(Array(wideUnits))
            wideUnits.removeAll()
            view.needsDisplay = true
            prepareVisible()
            return
        }
        // Every height depends on the width: estimate again, keep the first visible character on top.
        let anchor = firstVisibleCharacter()
        columnWidth = new.width
        resetHeights()
        scroll(toCharacter: anchor)
    }

    /// Light and dark resolve the text's colors when lines are shaped: shape again.
    func appearanceChanged() {
        layouts.removeAll()
        lastUse.removeAll()
        cachedCost = 0
        view.needsDisplay = true
    }

    // MARK: - Layout

    func layout(_ index: Int) -> UnitLayout {
        let unit = units.units[index]
        clock += 1
        if let cached = layouts[unit.id] {
            lastUse[unit.id] = clock
            return cached
        }
        let content = presenter?.content(index) ?? plainContent(index)
        var componentHeight: CGFloat = 0
        if let box = content.component {
            componentHeight = box.height(in: blockSpace(content))
            wideUnits.insert(unit.id)
        }
        let layout = UnitLayout.typeset(content, width: columnWidth, componentHeight: componentHeight, margin: isPrinting || fillsWidth ? 0 : columnX - leadingInset - Self.handleSlot)
        // Hanging syntax depends on the margin, which follows the window's width.
        if content.markerWidth > 0 { wideUnits.insert(unit.id) }
        layouts[unit.id] = layout
        lastUse[unit.id] = clock
        cachedCost += layout.cost
        if cachedCost > Self.cacheBudget { evict() }
        let height = Double(layout.height)
        if !heights.isMeasured(index) || heights.height(of: index) != height { heights.setMeasured(index, height) }
        return layout
    }

    /// A unit as written: source spelling and geometry stay exact, with only line-local color
    /// attributes for Markdown syntax. It never parses the document outside this visible unit.
    private func plainContent(_ index: Int) -> UnitContent {
        let range = units.range(of: index)
        var length = range.length
        while length > 0, TextUnits.isTerminator(text.character(at: range.location + length - 1)) { length -= 1 }
        let string = SourceSyntax.highlight(text.substring(with: NSRange(location: range.location, length: length)), attributes: plainAttributes)
        return UnitContent(body: .text, string: string, map: .identity(length), metrics: plainMetrics)
    }

    /// Room for a block component: the column after its indent, and the band up to the window
    /// margins that only a table set to the window's width uses (design §8.1).
    func blockSpace(_ content: UnitContent) -> BlockSpace {
        let column = max(40, columnWidth - content.metrics.indent)
        return BlockSpace(column: column, wide: max(column, view.bounds.width - bandLeading - bandTrailing))
    }

    /// Least recently used first, down to three quarters of the budget.
    private func evict() {
        for (id, _) in lastUse.sorted(by: { $0.value < $1.value }) {
            guard cachedCost > Self.cacheBudget * 3 / 4 else { break }
            if let layout = layouts.removeValue(forKey: id) { cachedCost -= layout.cost }
            lastUse[id] = nil
        }
    }

    /// A canvas no one looks at (its document waits in the window's Open list) keeps its text,
    /// heights and place but not its shaped lines; they are made again when it shows (design §3.1).
    public func releaseLayouts() {
        forget(Array(layouts.keys))
        wideUnits.removeAll()
    }

    private func forget(_ ids: [UInt64]) {
        for id in ids {
            if let layout = layouts.removeValue(forKey: id) { cachedCost -= layout.cost }
            lastUse[id] = nil
        }
    }

    /// Lay out again the units covering `ranges` (their presentation changed).
    private func invalidate(_ ranges: [NSRange]) {
        guard units.count > 0 else { return }
        var ids: [UInt64] = []
        for r in ranges {
            let first = units.unit(containing: min(r.location, text.length))
            // The empty unit at EOF has no preceding character, but its layout changes too.
            let end = min(NSMaxRange(r), text.length)
            let last = units.unit(containing: end == text.length ? end : max(r.location, end - 1))
            for i in first...max(first, last) { ids.append(units.units[i].id) }
        }
        guard !ids.isEmpty else { return }
        forget(ids)
        view.needsDisplay = true
    }

    /// Typeset again, keeping the text on screen in place (a component changed its size).
    public func invalidate(range: NSRange) {
        invalidate([range])
        prepareVisible()
        componentChanged?()
    }

    /// A component changed its geometry, for hosts that draw the canvas themselves.
    public var componentChanged: (() -> Void)?

    /// Decoded pixels do not change the header-derived image size. Invalidate only their region,
    /// so an evicted neighboring image is not decoded again by this update.
    func redrawComponent(_ rect: NSRect) {
        view.setNeedsDisplay(rect)
        componentPixelsChanged?(rect)
    }
    public var componentPixelsChanged: ((NSRect) -> Void)?

    /// Top of unit `index` in view coordinates.
    func top(of index: Int) -> CGFloat { Self.topInset + CGFloat(heights.y(of: index)) }

    private func updateFrameHeight() {
        let visible = scrollView.contentView.bounds.height
        let below = lastComponent != nil ? typography.fontSize + lineHeight : 0
        let height = max(visible, Self.topInset + CGFloat(heights.total) + below + Self.bottomInset)
        if abs(view.frame.height - height) > 0.25 {
            adjusting = true
            view.setFrameSize(NSSize(width: view.frame.width, height: height))
            adjusting = false
        }
    }

    // MARK: - Viewport

    @objc private func boundsChanged() {
        guard !adjusting else { return }
        prepareVisible()
    }

    /// Lay out the units in and around the visible rect, and keep the text at its top in place
    /// while estimates above it turn into measured heights.
    public func prepareVisible() {
        guard !adjusting, units.count > 0 else { return }
        let clip = scrollView.contentView
        let visible = clip.bounds
        let top = Double(visible.minY - Self.topInset)
        let anchor = LayoutAnchor(y: top, in: heights)
        let overscan = Double(visible.height) * 0.5
        var i = heights.unit(at: max(0, top - overscan))
        let bottom = top + Double(visible.height) + overscan
        var y = heights.y(of: i)
        while i < units.count, y < bottom {
            _ = layout(i)
            y = heights.y(of: i) + heights.height(of: i)
            i += 1
        }
        updateFrameHeight()
        let newTop = CGFloat(anchor.y(in: heights)) + Self.topInset
        if abs(newTop - visible.minY) > 0.25 {
            adjusting = true
            clip.scroll(to: NSPoint(x: visible.minX, y: newTop))
            scrollView.reflectScrolledClipView(clip)
            adjusting = false
        }
        view.updateCaret()
    }

    /// Put the line holding `location` at the top of the view (`margin` below the top).
    public func scroll(toCharacter location: Int, margin: CGFloat = 0) {
        guard units.count > 0 else { return }
        let location = min(max(0, location), text.length)
        let p = place(location)
        updateFrameHeight()
        let clip = scrollView.contentView
        let maxY = max(0, view.frame.height - clip.bounds.height)
        let y = min(maxY, max(0, top(of: p.unit) + p.layout.tops[p.line] - margin))
        adjusting = true
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        adjusting = false
        prepareVisible()
        view.needsDisplay = true
    }

    /// The first character of the top visible line.
    public func firstVisibleCharacter() -> Int {
        guard units.count > 0 else { return 0 }
        let visible = scrollView.contentView.bounds
        return characterIndex(at: NSPoint(x: columnX, y: max(visible.minY, Self.topInset) + 1))
    }

    /// The character at the reading line: the top of the view at the start of the document,
    /// sliding to its bottom as the scroll reaches the end, so the last sections, which can never
    /// reach the top, are read too (the outline's reading mark).
    public func readingCharacter() -> Int {
        guard units.count > 0 else { return 0 }
        let visible = scrollView.contentView.bounds
        let room = view.frame.height - visible.height
        let progress = room > 1 ? min(max(visible.minY / room, 0), 1) : 0
        return characterIndex(at: NSPoint(x: columnX, y: max(visible.minY, Self.topInset) + 1 + (visible.height - 2) * progress))
    }

    /// Scroll as little as needed for `location` to be visible.
    func scrollToVisible(_ location: Int) {
        let rect = lineBox(at: location).insetBy(dx: 0, dy: -lineHeight * 0.5)
        let visible = scrollView.contentView.bounds
        if rect.minY >= visible.minY, rect.maxY <= visible.maxY { return }
        let y = rect.minY < visible.minY ? rect.minY : rect.maxY - visible.height
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, min(y, view.frame.height - visible.height))))
        scrollView.reflectScrolledClipView(clip)
    }

    var visibleCharacterRange: NSRange {
        let visible = scrollView.contentView.bounds
        let a = characterIndex(at: NSPoint(x: columnX, y: visible.minY))
        let b = characterIndex(at: NSPoint(x: columnX + columnWidth, y: visible.maxY))
        return NSRange(location: a, length: max(0, b - a))
    }

    // MARK: - Geometry

    /// The character position nearest to `point` (view coordinates).
    func characterIndex(at point: NSPoint) -> Int { hit(point).location }

    /// The position nearest to `point`, and whether it is the end of a wrapped line (upstream).
    func hit(_ point: NSPoint) -> (location: Int, upstream: Bool) {
        guard units.count > 0 else { return (0, false) }
        let y = Double(point.y - Self.topInset)
        if y < 0 { return (0, false) }
        if y >= heights.total { return (text.length, false) }
        var i = heights.unit(at: y)
        var layout = layout(i)
        var local = CGFloat(y - heights.y(of: i))
        // The upper half of the gap between two blocks belongs to the line above it.
        if local < layout.content.gap / 2, let above = shownUnit(before: i) {
            i = above
            layout = self.layout(i)
            local = layout.height - 0.5
        }
        let base = units.range(of: i).location
        let k = layout.line(atY: local)
        if layout.content.component != nil { return (base + layout.sourceStart(ofLine: 0), false) }
        let offset = layout.source(atX: point.x - columnX, line: k)
        // The end of a wrapped line, or of a piece of a cut line: the caret stays on this line.
        let wrapEnd = (k + 1 < layout.starts.count && offset == layout.sourceEnd(ofLine: k) && point.x - columnX >= layout.x(ofSource: offset, line: k) - 1)
            || (k == layout.starts.count - 1 && offset == units.units[i].length && i + 1 < units.count && !units.units[i + 1].startsLine)
        return (base + offset, wrapEnd)
    }

    /// The line that shows above `location`'s line: its first unit's start, length and layout
    /// (closed blank lines, setext underlines and the rest of a component are passed over).
    func shownLine(before location: Int) -> (location: Int, length: Int, layout: UnitLayout)? {
        guard units.count > 0 else { return nil }
        let line = units.firstUnit(ofLine: units.line(ofUnit: units.unit(containing: min(location, text.length))))
        guard var j = shownUnit(before: line) else { return nil }
        j = units.firstUnit(ofLine: units.line(ofUnit: j))
        return (units.range(of: j).location, units.range(of: j).length, layout(j))
    }

    /// The nearest unit before `i` that has height (closed blank lines and the rest of a component
    /// have none).
    private func shownUnit(before i: Int) -> Int? {
        var j = i - 1
        while j >= 0 {
            if layout(j).height >= 0.5 { return j }
            j -= 1
        }
        return nil
    }

    /// Unit, layout and line of a position, honoring the upstream caret.
    func place(_ location: Int) -> (unit: Int, layout: UnitLayout, line: Int, local: Int) {
        var i = units.unit(containing: location)
        var local = location - units.range(of: i).location
        if upstream, local == 0, i > 0, !units.units[i].startsLine {
            i -= 1
            local = units.units[i].length
        }
        let layout = layout(i)
        local = min(local, layout.contentLength)
        let d = layout.content.map.display(local)
        var k = layout.line(forDisplay: d)
        if upstream, k > 0, d == layout.starts[k] { k -= 1 }
        return (i, layout, k, local)
    }

    /// The box of the visual line holding `location` (view coordinates, the column's width).
    func lineBox(at location: Int) -> NSRect {
        guard units.count > 0 else { return NSRect(x: columnX, y: Self.topInset, width: columnWidth, height: lineHeight) }
        let p = place(min(max(0, location), text.length))
        return NSRect(x: columnX, y: top(of: p.unit) + p.layout.tops[p.line], width: columnWidth, height: max(1, p.layout.heights[p.line]))
    }

    func caretRect(at location: Int) -> NSRect {
        guard units.count > 0 else { return NSRect(x: columnX, y: Self.topInset, width: 2, height: lineHeight) }
        if belowComponent != nil, location == text.length {
            // A body line a block gap below the component, set as `UnitLayout.typeset` sets it.
            let font = typography.bodyFont
            let m = LineMetrics(kind: .body, font: font, lineHeight: typography.lineHeight(for: font, kind: .body), quoteDepth: 0, listDepth: 0, indent: 0)
            let top = self.top(of: units.count - 1) + layout(units.count - 1).height + typography.fontSize
            let baseline = top + round(m.ascent + max(0, (m.lineHeight - m.ascent - m.descent) / 2))
            return NSRect(x: columnX - 1, y: baseline - ceil(m.ascent) - 1, width: 2, height: ceil(m.ascent + m.descent) + 2)
        }
        let p = place(min(max(0, location), text.length))
        let m = p.layout.content.metrics
        let x = p.layout.x(ofSource: p.local, line: p.line)
        let baseline = top(of: p.unit) + p.layout.baselines[p.line]
        return NSRect(x: columnX + x - 1, y: baseline - ceil(m.ascent) - 1, width: 2, height: ceil(m.ascent + m.descent) + 2)
    }

    /// Rects covering `range` on screen lines, one per visual line (for selection, find, VoiceOver).
    func rects(for range: NSRange, within area: NSRect? = nil) -> [NSRect] {
        guard units.count > 0, range.length > 0 else { return [] }
        var first = units.unit(containing: range.location)
        var last = units.unit(containing: max(range.location, NSMaxRange(range) - 1))
        if let area {
            first = max(first, heights.unit(at: Double(area.minY - Self.topInset)))
            last = min(last, heights.unit(at: Double(area.maxY - Self.topInset)))
        }
        guard first <= last else { return [] }
        var result: [NSRect] = []
        for i in first...last { result += rects(for: range, inUnit: i, area: area) }
        return result
    }

    private func rects(for range: NSRange, inUnit i: Int, area: NSRect?) -> [NSRect] {
        let unitRange = units.range(of: i)
        let layout = layout(i)
        let unitTop = top(of: i)
        let a = max(range.location, unitRange.location) - unitRange.location
        let b = min(NSMaxRange(range), NSMaxRange(unitRange)) - unitRange.location
        guard a < b || (a == b && range.length > 0 && b > layout.contentLength) else { return [] }
        if layout.content.component != nil {
            return [NSRect(x: columnX + layout.content.indent, y: unitTop + layout.tops[0], width: columnWidth - layout.content.indent, height: max(1, layout.heights[0]))]
        }
        if case .space = layout.content.body, layout.heights[0] < 1 { return [] }
        var result: [NSRect] = []
        let map = layout.content.map
        let da = map.display(a), db = map.display(min(b, layout.contentLength))
        for k in layout.line(forDisplay: da)...layout.line(forDisplay: db) {
            let start = layout.starts[k], end = layout.displayEnd(ofLine: k)
            let lineTop = unitTop + layout.tops[k]
            if let area, lineTop > area.maxY || lineTop + layout.heights[k] < area.minY { continue }
            let x0 = layout.xs[k] + CTLineGetOffsetForStringIndex(layout.lines[k], max(da, start), nil)
            // A selected visual wrap fills the rest of that visual line. A source line break does
            // not: its final line stops after its last displayed character.
            let throughEnd = db > end || (db == end && k + 1 < layout.starts.count)
            let x1 = throughEnd ? columnWidth : layout.xs[k] + CTLineGetOffsetForStringIndex(layout.lines[k], min(db, end), nil)
            if x1 > x0 || throughEnd { result.append(NSRect(x: columnX + x0, y: lineTop, width: max(x1 - x0, 4), height: layout.heights[k])) }
        }
        return result
    }

    /// The position `lines` visual lines above (negative) or below `location`, at the goal x
    /// (design §8.1, up and down). It walks the lines that show: closed blank lines and the rest of
    /// a component are passed over, and a block component is one stop (`component`), entered whole.
    func verticalTarget(from location: Int, lines: Int) -> (location: Int, upstream: Bool, component: NSRange?) {
        let x = goalX ?? caretRect(at: location).midX
        goalX = x
        let origin = place(location)
        var unit = origin.unit, line = origin.line, targetLayout = origin.layout
        let step = lines > 0 ? 1 : -1
        // Lines the arrows pass: those without height, and a code block's fences, which are
        // syntax: from the line above a block to its first line of code, and out past its closing
        // fence (an empty block keeps one fence as its stop).
        func passed(_ j: Int) -> Bool {
            let l = layout(j)
            if l.height < 0.5 { return true }
            guard l.content.metrics.kind == .fence, let code = l.content.code else { return false }
            let leaving = step > 0 ? !code.isFirst : code.isFirst
            let beside = j + step
            return leaving || beside >= 0 && beside < units.count && layout(beside).content.metrics.kind == .code
        }
        for _ in 0..<abs(lines) {
            if line + step >= 0, line + step < targetLayout.lines.count {
                line += step
                continue
            }
            var next = unit + step
            while next >= 0, next < units.count, passed(next) { next += step }
            guard next >= 0 else { return (0, false, nil) }
            guard next < units.count else { return (text.length, false, nil) }
            unit = next
            targetLayout = layout(unit)
            line = step > 0 ? 0 : targetLayout.lines.count - 1
        }
        let base = units.range(of: unit).location
        if let box = targetLayout.content.component {
            let range = box.lastKnownRange.location != NSNotFound ? box.lastKnownRange : NSRange(location: base + targetLayout.sourceStart(ofLine: 0), length: 0)
            return (range.location, false, range)
        }
        let target = targetSource(targetLayout, unit: unit, line: line, x: x)
        return (base + target.local, target.upstream, nil)
    }

    /// The source offset at `x` on line `line` of `unit`, and whether it is the end of a wrapped line.
    private func targetSource(_ layout: UnitLayout, unit: Int, line: Int, x: CGFloat) -> (local: Int, upstream: Bool) {
        // Walk actual lines, not their surrounding spacing; keep the side of a shared wrap offset.
        let local = layout.source(atX: x - columnX, line: line)
        let wrapEnd = (line + 1 < layout.lines.count && local == layout.sourceEnd(ofLine: line))
            || (line == layout.lines.count - 1 && local == units.units[unit].length && unit + 1 < units.count && !units.units[unit + 1].startsLine)
        return (local, wrapEnd)
    }

    /// After Up or Down: the caret's line may have changed as the caret arrived (it reveals
    /// syntax), so the goal x is found again on the line as it is now.
    func goalPosition(on location: Int) -> (location: Int, upstream: Bool)? {
        guard let goalX, focusedComponent == nil, units.count > 0 else { return nil }
        let p = place(min(location, text.length))
        guard p.layout.content.component == nil else { return nil }
        let target = targetSource(p.layout, unit: p.unit, line: p.line, x: goalX)
        return (units.range(of: p.unit).location + target.local, target.upstream)
    }

    /// The block component drawn under `point`, unless the caret has turned it into source.
    func component(at point: NSPoint) -> ComponentBox? {
        guard units.count > 0 else { return nil }
        let y = Double(point.y - Self.topInset)
        guard y >= 0, y < heights.total else { return nil }
        guard let box = layout(heights.unit(at: y)).content.component, box.drawnRect.contains(point) else { return nil }
        return box
    }

    /// The unit at `point` and what it shows (list markers, components), for clicks on decorations.
    func unit(at point: NSPoint) -> (index: Int, layout: UnitLayout, top: CGFloat)? {
        guard units.count > 0 else { return nil }
        let y = Double(point.y - Self.topInset)
        guard y >= 0, y < heights.total else { return nil }
        let i = heights.unit(at: y)
        return (i, layout(i), top(of: i))
    }

    /// Start and end (before the line break) of the visual line holding `location`.
    func visualLine(_ location: Int) -> (start: Int, end: Int) {
        let p = place(location)
        let base = units.range(of: p.unit).location
        return (base + p.layout.sourceStart(ofLine: p.line), base + p.layout.sourceEnd(ofLine: p.line))
    }

    // MARK: - Drawing

    /// `background` false draws only the glyphs (the find bar's highlight sits behind them).
    /// Code block languages met while drawing units, drawn after them.
    private var codeLabels: [(NSString, CGPoint)] = []

    /// `fillsBackground` lets embedded Markdown keep its host surface while drawing block styles.
    /// `underlay` draws on the background, beneath the text (the hovered handle's band).
    func draw(_ dirty: NSRect, in context: CGContext, background: Bool = true, fillsBackground: Bool = true, underlay: ((NSRect) -> Void)? = nil, needsToDraw: ((NSRect) -> Bool)? = nil) {
        if background && fillsBackground {
            if isPrinting, let printBackground {
                context.setFillColor(printBackground.cgColor)
                context.fill(dirty)
            } else {
                (isPrinting ? NSColor.white : Tokens.canvas).setFill()
                dirty.fill()
            }
            underlay?(dirty)
        }
        guard units.count > 0 else { return }
        // Heading rules hang below their unit: start a little above the dirty rect.
        let reach = presenter == nil ? 0 : typography.fontSize * 2
        var i = heights.unit(at: Double(max(0, dirty.minY - reach - Self.topInset)))
        while i < units.count, top(of: i) <= dirty.maxY {
            let layout = layout(i)
            let unitTop = top(of: i)
            if unitTop + layout.height + reach >= dirty.minY { drawUnit(i, layout, at: unitTop, dirty: dirty, in: context, background: background, needsToDraw: needsToDraw) }
            i += 1
        }
        // A code block's language sits on its top lines, so it is drawn after their backgrounds.
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: Palette.faint]
        for (language, topRight) in codeLabels {
            let size = language.size(withAttributes: attrs)
            language.draw(at: CGPoint(x: topRight.x - size.width, y: topRight.y), withAttributes: attrs)
        }
        codeLabels.removeAll()
        if let marked = markedRange, marked.length > 0 {
            Palette.text.setFill()
            for r in rects(for: marked, within: dirty) {
                NSRect(x: r.minX, y: r.maxY - 3, width: r.width, height: 1).fill()
            }
        }
    }

    private func drawFindMatches(in i: Int, dirty: NSRect) {
        let unit = units.range(of: i)
        var lo = 0, hi = findMatches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(findMatches[mid]) <= unit.location { lo = mid + 1 } else { hi = mid }
        }
        var k = lo
        while k < findMatches.count, findMatches[k].location < NSMaxRange(unit) {
            let current = k == findCurrent
            (current ? Tokens.findCurrent : Tokens.findMatch).setFill()
            for r in rects(for: findMatches[k], inUnit: i, area: dirty) {
                let path = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3)
                path.fill()
                if current {
                    Tokens.accent.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
            k += 1
        }
    }

    private func drawUnit(_ i: Int, _ layout: UnitLayout, at unitTop: CGFloat, dirty: NSRect, in context: CGContext, background: Bool, needsToDraw: ((NSRect) -> Bool)?) {
        let content = layout.content
        let m = content.metrics
        if background {
            if let code = content.code { drawCodeSlice(code, layout, at: unitTop) }
            drawInlineCode(layout, at: unitTop)
            if !findMatches.isEmpty { drawFindMatches(in: i, dirty: dirty) }
            if selection.length > 0 {
                Tokens.selection.setFill()
                for r in rects(for: selection, inUnit: i, area: dirty) { r.fill(using: .sourceOver) }
            }
            if m.quoteDepth > 0 { drawQuoteBars(content, at: unitTop, height: layout.height) }
        }
        switch content.body {
        case let .component(box):
            let space = blockSpace(content)
            let top = unitTop + content.gap
            let bounds = NSRect(x: 0, y: top, width: view.bounds.width, height: layout.height - content.gap)
            guard dirty.intersects(bounds), needsToDraw?(bounds) != false else { return }
            let column = NSRect(x: columnX + m.indent, y: top, width: space.column, height: 0)
            var wide = column
            if space.wide > space.column {
                wide = NSRect(x: (bandLeading + (view.bounds.width - bandLeading - bandTrailing - space.wide) / 2).rounded(), y: top, width: space.wide, height: 0)
            }
            box.draw(in: BlockFrame(column: column, wide: wide), context: context)
            return
        case .space:
            if background, let code = content.code, code.isFirst, let language = code.box.language, !language.isEmpty {
                // Centered in the fence's band, where the fence itself shows once the caret is inside.
                let y = unitTop + content.gap + max(2, ((layout.height - content.gap) - 13) / 2)
                codeLabels.append((language as NSString, CGPoint(x: columnX + columnWidth - 12, y: y.rounded())))
            }
            return
        case .text:
            break
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        if content.singleLine { context.clip(to: NSRect(x: 0, y: unitTop, width: columnX + columnWidth - 12, height: layout.height)) }
        for (k, line) in layout.lines.enumerated() {
            let lineTop = unitTop + layout.tops[k]
            if lineTop > dirty.maxY { break }
            if lineTop + layout.heights[k] < dirty.minY { continue }
            let x = columnX + layout.xs[k]
            let baseline = unitTop + layout.baselines[k]
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            drawRunExtras(line, x: x, baseline: baseline, in: context)
        }
        context.restoreGState()
        guard background else { return }
        if let marker = content.listMarker { drawListMarker(marker, content, baseline: unitTop + layout.baselines[0]) }
        if let number = content.code?.number { drawLineNumber(number, content, baseline: unitTop + layout.baselines[0]) }
        // Revealed markers hang where the number goes: the number steps aside while they show.
        if m.kind == .heading, layout.hang == 0, let presenter, let number = presenter.headingNumber(at: units.range(of: i).location) {
            let level = min(max(m.headingLevel, 1), 6)
            let font = typography.numberFont(level: level)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.muted]
            let width = ceil((number as NSString).size(withAttributes: attrs).width)
            let room = typography.numberSlot(level: level) - typography.numberGap(number, level: level)
            let x = columnX + m.indent
            (number as NSString).draw(at: NSPoint(x: width <= room ? x : x + room - width, y: unitTop + layout.baselines[0] - font.ascender), withAttributes: attrs)
        }
        if content.headingRule {
            let scale = view.window?.backingScaleFactor ?? 2
            let y = ((unitTop + layout.height + round(typography.fontSize * 0.3)) * scale).rounded() / scale
            Palette.rule.setFill()
            NSRect(x: columnX + m.indent, y: y, width: columnWidth - m.indent, height: 1 / scale).fill(using: .sourceOver)
        }
    }

    /// What Core Text does not draw: strikethrough, and inline formulas and images in their
    /// reserved runs.
    private func drawRunExtras(_ line: CTLine, x: CGFloat, baseline: CGFloat, in context: CGContext) {
        guard presenter != nil else { return }
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if let object = attrs[NSAttributedString.Key.zComponent] as? any InlineComponent {
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let color = attrs[NSAttributedString.Key.foregroundColor] as? NSColor ?? Palette.text
                // The text matrix is not part of the graphics state: put the flipped one back after the object.
                context.saveGState()
                context.textMatrix = .identity
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                object.draw(atX: x + position.x, baseline: baseline, width: width, color: color == Palette.faint ? Palette.text : color, context: context)
                context.restoreGState()
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                continue
            }
            if let style = attrs[NSAttributedString.Key.strikethroughStyle] as? Int, style != 0 {
                let range = CTRunGetStringRange(run)
                let x0 = CTLineGetOffsetForStringIndex(line, range.location, nil)
                let x1 = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
                let font = attrs[NSAttributedString.Key.font] as? NSFont ?? typography.bodyFont
                (attrs[NSAttributedString.Key.strikethroughColor] as? NSColor ?? Palette.muted).setFill()
                NSRect(x: x + x0, y: (baseline - font.xHeight * 0.55).rounded(), width: x1 - x0, height: 1).fill(using: .sourceOver)
            }
        }
    }

    private func drawInlineCode(_ layout: UnitLayout, at unitTop: CGFloat) {
        let string = layout.content.string
        guard presenter != nil, string.length > 0 else { return }
        string.enumerateAttribute(.zInlineCode, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let value else { return }
            // `true` for code, "keycap:…" for `<kbd>` (outlined), "mark:…" for `<mark>` (highlighted).
            let kind = (value as? String)?.split(separator: ":").first.map(String.init)
            let font = string.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? typography.codeFont
            for k in layout.line(forDisplay: range.location)...layout.line(forDisplay: max(range.location, NSMaxRange(range) - 1)) {
                let start = max(range.location, layout.starts[k]), end = min(NSMaxRange(range), layout.displayEnd(ofLine: k))
                guard end > start else { continue }
                let x0 = CTLineGetOffsetForStringIndex(layout.lines[k], start, nil)
                let x1 = CTLineGetOffsetForStringIndex(layout.lines[k], end, nil)
                let baseline = unitTop + layout.baselines[k]
                // A key's last character carries the room after it as kerning (MarkdownStyler.keyRoom).
                let room = kind == "keycap" && end == NSMaxRange(range) ? (string.attribute(.kern, at: end - 1, effectiveRange: nil) as? CGFloat ?? 0) : 0
                let rect = NSRect(x: columnX + layout.xs[k] + x0 - 3, y: baseline - font.ascender - 1.5, width: x1 - x0 - room + 6, height: font.ascender - font.descender + 3)
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                (kind == "mark" ? Palette.accent.withAlphaComponent(0.18) : Palette.inlineCodeBackground).setFill()
                path.fill()
                if kind == "keycap" {
                    Palette.rule.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
    }

    /// One unit's slice of a code block's background: corners rounded at the block's ends only.
    private func drawCodeSlice(_ code: UnitContent.CodeSlice, _ layout: UnitLayout, at unitTop: CGFloat) {
        let m = layout.content.metrics
        let slice = NSRect(x: columnX + m.indent, y: unitTop + layout.content.gap, width: columnWidth - m.indent, height: layout.height - layout.content.gap)
        guard slice.height > 0 else { return }
        var block = slice
        if !code.isFirst { block.origin.y -= 20; block.size.height += 20 }
        if !code.isLast { block.size.height += 20 }
        NSGraphicsContext.saveGraphicsState()
        slice.clip()
        CodeBlockBox.drawBackground(block, style: typography.codeStyle, scale: view.window?.backingScaleFactor ?? 2)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLineNumber(_ number: Int, _ content: UnitContent, baseline: CGFloat) {
        let code = typography.codeFont
        let font = Typography.resize(code, round(code.pointSize * 0.85 * 2) / 2)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.faint]
        let text = "\(number)" as NSString
        let right = columnX + content.metrics.indent + typography.codePadding + typography.codeGutter - round(typography.fontSize * 0.6)
        text.draw(at: NSPoint(x: right - text.size(withAttributes: attrs).width, y: baseline - font.ascender), withAttributes: attrs)
    }

    private func drawQuoteBars(_ content: UnitContent, at unitTop: CGFloat, height: CGFloat) {
        let m = content.metrics
        let skip = content.quoteSkip
        guard height - skip > 0 else { return }
        Palette.quoteBar.setFill()
        let base = columnX + CGFloat(m.quoteBase) * typography.listIndent
        for d in 0..<m.quoteDepth {
            // Square ends: one unit's bar meets the next without a notch.
            NSRect(x: base + CGFloat(d) * typography.quoteIndent, y: unitTop + skip, width: 3, height: height - skip).fill()
        }
    }

    private func drawListMarker(_ kind: ListMarkerBox.Kind, _ content: UnitContent, baseline: CGFloat) {
        let m = content.metrics
        let font = content.string.length > 0 ? (content.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? typography.bodyFont) : typography.bodyFont
        let textX = columnX + m.indent
        let gutter = typography.listIndent
        switch kind {
        case let .bullet(depth):
            // Drawn shapes, not a glyph: the same size on every item whatever script it starts
            // with (a glyph would come from the fallback font of the first character).
            let side = max(4, round(font.xHeight * 0.7 * 2) / 2)
            let center = CGPoint(x: textX - gutter / 2, y: baseline - font.xHeight / 2)
            let dot = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            Palette.muted.set()
            switch (depth - 1) % 3 {
            case 0: NSBezierPath(ovalIn: dot).fill()
            case 1:
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                ring.stroke()
            default: NSBezierPath(rect: dot.insetBy(dx: 0.5, dy: 0.5)).fill()
            }
        case let .ordinal(text):
            let numberFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: Palette.muted]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: textX - size.width - 6, y: baseline - numberFont.ascender), withAttributes: attrs)
        case let .checkbox(checked):
            let side = round(font.pointSize)
            let name = checked ? "checkmark.circle.fill" : "circle"
            let color = checked ? Palette.link : Palette.faint
            let config = NSImage.SymbolConfiguration(pointSize: side, weight: .regular).applying(.init(paletteColors: [checked ? .white : color, color]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: checked ? "checked" : "unchecked")?.withSymbolConfiguration(config) else { return }
            let size = image.size
            let center = CGPoint(x: textX - gutter / 2, y: baseline - font.xHeight / 2)
            image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        }
    }

    /// Shape every unit once (benchmarks); the cache keeps only the budget's worth.
    public func layoutAll() {
        for i in 0..<units.count { _ = layout(i) }
        updateFrameHeight()
        view.needsDisplay = true
    }

    /// Make local component pixels available synchronously for a one-shot output operation.
    /// Layout creates the boxes first, so this never introduces a second rendering path.
    func prepareForOutput() {
        for i in 0..<units.count {
            let content = layout(i).content
            content.component?.prepareForOutput()
            content.string.enumerateAttribute(.zComponent, in: NSRange(location: 0, length: content.string.length)) { value, _, _ in
                (value as? ComponentBox)?.prepareForOutput()
            }
        }
    }

    /// The outline (`Outline.Scanner`, shared with the CLI and agents), fed the canvas's own line
    /// units so a long document is not scanned again.
    public func headings() -> [Outline.Heading] {
        var scanner = Outline.Scanner(text: text, rendered: mode == .rendered)
        var location = 0
        for unit in units.units {
            if unit.startsLine { scanner.line(at: location, length: unit.length) }
            location += unit.length
        }
        return scanner.headings
    }

    // MARK: - Selection

    /// `focus` takes a block component whole. A caret that is only `passing` (the arrow keys, a
    /// click) takes a drawn component whole instead of entering its source; `entering` skips even
    /// the move off a line without height.
    func select(_ range: NSRange, upstream: Bool = false, keepGoal: Bool = false, focus: NSRange? = nil, passing: Bool = false, entering: Bool = false) {
        let length = text.length
        var r = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - min(range.location, length))))
        var component = focus
        // The end of a file that ends with a drawn component is the line below it (design §8.1).
        let below = r == NSRange(location: length, length: 0) && component == nil && !entering ? lastComponent : nil
        // Off a line without height (a closed blank line, a setext underline): on to the next line,
        // or back to the end of the line before. An edit settles first and may open the line it
        // leaves the caret on.
        if r.length == 0, component == nil, below == nil, !entering, pendingSettle == nil, let presenter {
            let opened = openBlanks.count
            switch presenter.caretOffBlankLine(r.location, backward: r.location < selection.location) {
            case let .caret(target)?: r.location = target
            case let .component(whole)?: component = whole
            case nil: break
            }
            // Nowhere else to go (an empty document): the line opened for the caret.
            if openBlanks.count != opened { invalidate([NSRange(location: r.location, length: 0)]) }
            // Into a drawn component (Left, Right, a click in its gap): taken whole.
            if component == nil, passing, let whole = presenter.drawnComponent(around: r.location) { component = whole }
            if let component { r.location = component.location }
        }
        // Out of always-hidden prefixes: after them, or, moving left out of a line's text, to the
        // end of the line before.
        if r.length == 0, component == nil, below == nil, let span = presenter?.alwaysHiddenSpan(at: r.location) {
            let movingLeft = span.location > 0 && selection.length == 0 && selection.location == NSMaxRange(span) && r.location < selection.location
            r.location = movingLeft ? span.location - 1 : NSMaxRange(span)
            if movingLeft, r.location > 0, text.character(at: r.location) == 0x0A, text.character(at: r.location - 1) == 0x0D { r.location -= 1 }
        }
        if r != selection || component != focusedComponent { typing = nil }
        selection = r
        focusedComponent = component
        belowComponent = below
        self.upstream = upstream
        if !keepGoal { goalX = nil }
        selectionMoved()
    }

    public func setSelectedRange(_ range: NSRange) { select(range) }

    /// The drawn block component that ends the file with no line break after it.
    var lastComponent: NSRange? {
        guard text.length > 0, !TextUnits.isTerminator(text.character(at: text.length - 1)),
              let r = presenter?.drawnComponent(around: text.length), NSMaxRange(r) == text.length else { return nil }
        return r
    }

    /// Line breaks that `string` typed at `range` needs first to start a paragraph of its own: on
    /// the line right below a drawn component it would join it (a table's row, an image's
    /// paragraph), so a blank line goes between (design §8.1).
    func separator(before string: String, at range: NSRange) -> String {
        guard range.length == 0, let presenter else { return "" }
        let needed = belowComponent != nil && range.location == text.length ? 2 : presenter.isEmptyLineBelowComponent(range.location) ? 1 : 0
        var lead = 0, rest = Substring(string)
        while lead < needed, rest.hasPrefix(newline) { lead += 1; rest = rest.dropFirst() }
        return String(repeating: newline, count: needed - lead)
    }

    /// The selection changed: what it reveals, then the view.
    private func selectionMoved() {
        if let presenter {
            var dirty: [NSRange] = []
            if let created = pendingSettle {
                pendingSettle = nil
                if selection.length == 0, let settled = presenter.settle(caret: selection.location, created: created) { dirty.append(settled) }
            }
            dirty += presenter.selectionChanged(selection, focused: focusedComponent ?? belowComponent)
            if !dirty.isEmpty {
                invalidate(dirty)
                prepareVisible()
            }
        }
        view.selectionChanged()
        selectionDidChange?()
    }

    // MARK: - Editing

    /// Typing that coalesces into one undo step: the range it covers now and the text it replaced.
    private final class TypingRun {
        var range: NSRange
        var replaced: String
        init(range: NSRange, replaced: String) {
            self.range = range
            self.replaced = replaced
        }
    }

    /// NSDocument saves break the run, so text typed after a save marks the document edited again.
    public func breakUndoCoalescing() { typing = nil }

    /// Replace `range` with `string` as one undoable edit; the caret goes after it unless `select` says otherwise.
    func replace(_ range: NSRange, with string: String, select: NSRange? = nil, actionName: String? = nil, keepingComponent componentBefore: NSRange? = nil) {
        guard isEditable else { return }
        let ns: NSString = text
        let old = ns.substring(with: range)
        let inserted = NSRange(location: range.location, length: (string as NSString).length)
        let delta = inserted.length - range.length
        let componentAfter = componentBefore.map { component in
            if range.location >= component.location, NSMaxRange(range) <= NSMaxRange(component) {
                return NSRange(location: component.location, length: component.length + delta)
            }
            return Self.shift(component, by: range, delta: delta, length: text.length + delta)
        }
        perform(range, with: string)
        if let undo = view.undoManager {
            let epoch = outsideEdits.count
            undo.registerUndo(withTarget: self) { canvas in
                guard let inserted = canvas.current(inserted, since: epoch) else { return NSSound.beep() }
                let component = componentAfter.flatMap { canvas.current($0, since: epoch) }
                canvas.replace(inserted, with: old, select: NSRange(location: inserted.location, length: (old as NSString).length), keepingComponent: component)
            }
            if let actionName { undo.setActionName(actionName) }
        }
        typing = nil
        if let componentAfter {
            self.select(NSRange(location: componentAfter.location, length: 0), focus: componentAfter)
        } else {
            self.select(select ?? NSRange(location: NSMaxRange(inserted), length: 0))
        }
    }

    /// Typed text: consecutive keystrokes are one undo step (design §8 interaction: undo everywhere).
    func type(_ string: String, replacing range: NSRange) {
        guard isEditable else { return }
        let string = separator(before: string, at: range) + string
        let length = (string as NSString).length
        if let run = typing, range.length == 0, range.location == NSMaxRange(run.range) {
            perform(range, with: string)
            run.range.length += length
            selection = NSRange(location: range.location + length, length: 0)
            focusedComponent = nil
            upstream = false
            goalX = nil
            selectionMoved()
            return
        }
        let old = text.substring(with: range)
        perform(range, with: string)
        let run = TypingRun(range: NSRange(location: range.location, length: length), replaced: old)
        let epoch = outsideEdits.count
        view.undoManager?.registerUndo(withTarget: self) { canvas in
            guard let typed = canvas.current(run.range, since: epoch) else { return NSSound.beep() }
            canvas.replace(typed, with: run.replaced, select: NSRange(location: typed.location, length: (run.replaced as NSString).length))
        }
        view.undoManager?.setActionName(String(localized: "Typing"))
        select(NSRange(location: range.location + length, length: 0))
        typing = run
    }

    /// Return: a line break in the file's style. On the rendered canvas the empty line it leaves the
    /// caret on is laid out as the line it is about to become (the edit settles it), so typing into
    /// it moves nothing.
    func insertNewline() {
        type(newline, replacing: selection)
    }

    /// Backspace inside the current typing run shortens it instead of starting a new undo step.
    func deleteBackward(_ range: NSRange) {
        guard isEditable, range.length > 0 else { return }
        if let run = typing, NSMaxRange(range) == NSMaxRange(run.range), range.location >= run.range.location {
            perform(range, with: "")
            run.range.length -= range.length
            selection = NSRange(location: range.location, length: 0)
            focusedComponent = nil
            upstream = false
            selectionMoved()
            return
        }
        replace(range, with: "")
    }

    /// A change that is not an undo step of its own (input method composition).
    func performUntracked(_ range: NSRange, with string: String) {
        typing = nil
        perform(range, with: string)
    }

    /// An edit at the caret: the selection that follows settles the blank lines around it.
    private func perform(_ range: NSRange, with string: String) {
        text.replaceCharacters(in: range, with: string)
        let created = didEdit(range, newLength: (string as NSString).length)
        if presenter != nil { pendingSettle = (pendingSettle ?? []).union(created) } else { sourceCreated.formUnion(created) }
    }

    /// A change that did not come from this canvas (a reload, a merged external edit): not an
    /// undo step; the selection moves past it.
    public func replaceExternally(_ range: NSRange, with string: String) {
        typing = nil
        text.replaceCharacters(in: range, with: string)
        let delta = (string as NSString).length - range.length
        outsideEdits.append((range, delta))
        didEdit(range, newLength: (string as NSString).length)
        select(Self.shift(selection, by: range, delta: delta, length: text.length))
        // A composition moves with the text, or ends when the change reaches into it.
        guard let marked = markedRange else { return }
        if NSMaxRange(range) <= marked.location || range.location >= NSMaxRange(marked) {
            let moved = Self.shift(marked, by: range, delta: delta, length: text.length)
            markedRange = moved
            // What the composition replaces is no longer in the text: it starts where the composition does.
            markOrigin = markOrigin.map { (NSRange(location: moved.location, length: $0.range.length), $0.text) }
        } else {
            markedRange = nil
            markOrigin = nil
            view.inputContext?.discardMarkedText()
        }
    }

    /// After `old` was replaced by `newLength` characters: re-cut the touched units, keep the
    /// text on screen in place. Returns the ids of the units the edit made.
    @discardableResult
    private func didEdit(_ old: NSRange, newLength: Int) -> Set<UInt64> {
        let visible = scrollView.contentView.bounds
        let anchor = LayoutAnchor(y: Double(visible.minY - Self.topInset), in: heights)
        let change = units.edit(replacing: old, with: newLength, in: text)
        forget(change.removed)
        openBlanks.subtract(change.removed)
        if let focused = focusedComponent, NSMaxRange(old) > focused.location, old.location < NSMaxRange(focused) + 1 { focusedComponent = nil }
        heights.replace(change.old, with: units.units[change.new].map { estimate($0.length) })
        var kept = anchor
        if anchor.unit >= change.old.upperBound {
            kept.unit += change.new.count - change.old.count
        } else if anchor.unit >= change.old.lowerBound {
            kept.unit = change.new.lowerBound
        }
        if let presenter {
            // Neighbours of the edit may look different now (an opened fence, a new heading, a
            // blank line that carries a gap): from the blank lines before the region to its end.
            let affected = presenter.didEdit(old, newLength: newLength)
            var first = units.unit(containing: min(affected.location, text.length))
            var steps = 0
            while first > 0, steps < 64 {
                first -= 1
                steps += 1
                let r = units.range(of: first)
                if r.length > 2 || !(r.length == 0 || TextUnits.isTerminator(text.character(at: r.location))) { break }
            }
            invalidate([NSRange(location: units.range(of: first).location, length: NSMaxRange(affected) - units.range(of: first).location)])
        }
        for i in change.new where i < units.count { _ = layout(i) }
        if anchor.unit >= change.old.lowerBound, anchor.unit < change.old.upperBound, change.old.lowerBound < units.count {
            kept.offset = min(kept.offset, heights.height(of: kept.unit))
        }
        updateFrameHeight()
        let newTop = CGFloat(kept.y(in: heights)) + Self.topInset
        if abs(newTop - visible.minY) > 0.25 {
            let clip = scrollView.contentView
            adjusting = true
            clip.scroll(to: NSPoint(x: visible.minX, y: max(0, newTop)))
            scrollView.reflectScrolledClipView(clip)
            adjusting = false
        }
        view.needsDisplay = true
        prepareVisible()
        textDidChange?()
        return Set(units.units[change.new].map(\.id))
    }

    /// The word around `i` (double click), looked for in a window around it so a 20 MB line costs
    /// the same as a short one; outside words, the character there.
    func wordRange(at i: Int) -> NSRange {
        let n = text.length
        guard n > 0 else { return NSRange(location: 0, length: 0) }
        let i = min(i, n - 1)
        let window = text.rangeOfComposedCharacterSequences(for: NSRange(location: max(0, i - 256), length: min(n, i + 256) - max(0, i - 256)))
        var found: NSRange?
        text.enumerateSubstrings(in: window, options: [.byWords, .substringNotRequired]) { _, r, _, stop in
            if NSLocationInRange(i, r) {
                found = r
                stop.pointee = true
            } else if r.location > i {
                stop.pointee = true
            }
        }
        return found ?? text.rangeOfComposedCharacterSequence(at: i)
    }

    /// The next word boundary from `i` (Option-arrows, Option-Delete), within 1 024 characters.
    func nextWord(from i: Int, forward: Bool) -> Int {
        let n = text.length
        if forward {
            guard i < n else { return n }
            let window = text.rangeOfComposedCharacterSequences(for: NSRange(location: i, length: min(1024, n - i)))
            var end: Int?
            text.enumerateSubstrings(in: window, options: [.byWords, .substringNotRequired]) { _, r, _, stop in
                if NSMaxRange(r) > i {
                    end = NSMaxRange(r)
                    stop.pointee = true
                }
            }
            return end ?? NSMaxRange(window)
        }
        guard i > 0 else { return 0 }
        let start = max(0, i - 1024)
        let window = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: i - start))
        var begin: Int?
        text.enumerateSubstrings(in: window, options: [.byWords, .substringNotRequired, .reverse]) { _, r, _, stop in
            if r.location < i {
                begin = r.location
                stop.pointee = true
            }
        }
        return begin ?? window.location
    }

    static func shift(_ r: NSRange, by edit: NSRange, delta: Int, length: Int) -> NSRange {
        if NSMaxRange(r) <= edit.location { return r }
        if r.location >= NSMaxRange(edit) { return NSRange(location: r.location + delta, length: r.length) }
        let start = min(r.location, edit.location)
        return NSRange(location: min(start, length), length: 0)
    }
}
