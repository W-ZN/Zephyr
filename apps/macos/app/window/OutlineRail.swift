import AppKit
import ZephyrRender

/// The outline beside the text (design §8.2). At rest it is only ticks, one per heading: longer
/// and darker for higher levels, with a little more room before each chapter, so the column reads
/// as the document's structure. One tick is in the accent: the section holding the caret. While
/// the text scrolls, a second mark in the ink color slides along the ticks to show where the
/// reading is, then fades. Pointing at the column zooms it in around the pointer like a camera:
/// the ticks spread to readable rows while the one pointed at stays under the pointer, a rounded
/// surface grows out of them and the titles grow to their left, parents first. Near the pointer,
/// ticks lengthen and titles brighten as in the Dock; the pointed row's chapter and section stay
/// bright and a thin guide marks the group it belongs to. Rows never move under a still pointer,
/// so what a click chooses never shifts. A long outline keeps to a bounded strip at rest and a
/// bounded panel open, and scrolls inside them. All of it moves on springs (`Spring`, `FrameClock`)
/// that are retargeted as the pointer and the text move, so no motion restarts or jumps.
final class OutlineRail: NSView {
    var onSelect: ((MarkdownEditor.Heading) -> Void)?
    /// Over the resting ticks, and over a panel with nothing to scroll, the wheel moves the text.
    var onScroll: ((NSEvent) -> Void)?
    /// VoiceOver's press: the outline as a list.
    var onPress: (() -> Void)?
    /// While the assistant is open the rail stays still.
    var isQuiet = false { didSet { if isQuiet { close(immediately: true) } } }
    private(set) var headings: [MarkdownEditor.Heading] = []
    /// The section holding the caret: the one colored tick.
    private(set) var current: Int?

    /// The margin a resting rail needs beside the reading column.
    static let width: CGFloat = 44
    static let maxPanelWidth: CGFloat = 320
    /// Room kept clear at the bottom of the rail's frame (the assistant's button below it). The
    /// frame spans the text area, so the resting ticks center on the text, not on what is left.
    var bottomClearance: CGFloat = 0 { didSet { needsLayout = true } }
    private var usableHeight: CGFloat { bounds.height - bottomClearance }

    private static let tickInset: CGFloat = 10
    private static let row: CGFloat = 28
    /// Extra room before each chapter (a top-level heading), at rest and in the panel.
    private static let restChapterGap: CGFloat = 4
    private static let chapterGap: CGFloat = 8
    /// The second line of a long title.
    private static let lineGap: CGFloat = 16
    /// Inside the panel, above the first row and below the last.
    private static let pad: CGFloat = 8
    /// The panel keeps this far inside the rail's ends.
    private static let edge: CGFloat = 8
    /// The tallest the resting ticks and the open panel's rows get; a longer outline scrolls.
    private static let restCap: CGFloat = 440
    private static let panelCap: CGFloat = 480
    private static let textLead: CGFloat = 14
    private static let indent: CGFloat = 12
    /// Right of the titles: the gap and the ticks.
    private static let tickColumn: CGFloat = 50
    /// Titles next to the pointer grow to this scale.
    private static let lift: CGFloat = 1.06
    private static let contextColor = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)

    private struct Row {
        var depth: Int
        var lines: [CTLine]
        var truncated: Bool
        var height: CGFloat
        /// From the top of the panel's content.
        var center: CGFloat
        /// Top-level headings before this one, not counting the first row (the chapter gaps above it).
        var chapters: Int
        var parent: Int?
        /// The last row of this heading's section (itself when it has no subheadings).
        var end: Int
    }
    private var rows: [Row] = []
    private var contentHeight: CGFloat = 0
    private var panelWidth: CGFloat = 200
    private var panelTop: CGFloat = 0
    /// The heading the zoom opened on: titles appear outward from it.
    private var anchor = 0

    // Positions along the list are fractional row indices, so the marks glide between rows of any
    // height, in the resting column and the panel alike.
    private var zoom = Spring(0, response: 0.42, damping: 0.86)
    private var titles = Spring(0, response: 0.3)
    private var scroll = Spring(0, response: 0.22)
    private var focus = Spring(0, response: 0.14)
    private var pill = Spring(0, response: 0.2, damping: 0.86)
    private var pillAlpha = Spring(0, response: 0.18)
    private var marker = Spring(0, response: 0.36, damping: 0.9)
    private var reading = Spring(0, response: 0.16)
    private var readingAlpha = Spring(0, response: 0.2)
    private var guideTop = Spring(0, response: 0.22, damping: 0.9)
    private var guideBottom = Spring(0, response: 0.22, damping: 0.9)
    private var guideDepth = Spring(1, response: 0.22, damping: 0.9)
    private var guideAlpha = Spring(0, response: 0.18)
    private static let springs: [ReferenceWritableKeyPath<OutlineRail, Spring>] = [\.zoom, \.titles, \.scroll, \.focus, \.pill, \.pillAlpha, \.marker,
                                                                                  \.reading, \.readingAlpha, \.guideTop, \.guideBottom, \.guideDepth, \.guideAlpha]
    private lazy var clock = FrameClock(view: self) { [weak self] dt in self?.advance(dt) ?? false }

    private let plate = SurfaceView(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.panel, elevated: true)
    private let ink = InkView()
    private var pointer = NSPoint.zero
    private var hovered: Int?
    private var pressed = false
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var readingTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        plate.alphaValue = 0
        addSubview(plate)
        ink.frame = bounds
        ink.autoresizingMask = [.width, .height]
        ink.drawer = { [weak self] context in self?.drawInk(context) }
        addSubview(ink)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// A resized window moves the resting ticks and can shorten the panel: both follow at once.
    override func layout() {
        super.layout()
        guard !rows.isEmpty else { return }
        panelTop = max(Self.edge, min(panelTop, usableHeight - Self.edge - (viewport + 2 * Self.pad))).rounded()
        scroll.snap(to: min(scroll.target, maxScroll))
        redraw()
    }

    private var isOpen: Bool { zoom.target == 1 }

    func setHeadings(_ list: [MarkdownEditor.Heading]) {
        guard list != headings else { return }
        headings = list
        current = current.flatMap { list.indices.contains($0) ? $0 : nil }
        buildRows()
        let last = CGFloat(max(list.count - 1, 0))
        marker.snap(to: CGFloat(current ?? 0))
        for k in [\OutlineRail.pill, \.focus, \.reading] { self[keyPath: k].snap(to: min(self[keyPath: k].target, last)) }
        anchor = min(anchor, max(list.count - 1, 0))
        hovered = nil
        guideAlpha.snap(to: 0)
        if isOpen { placePanel(on: anchor, at: shownY(anchor)) }
        redraw()
        window?.invalidateCursorRects(for: self)
        setAccessibilityLabel(String(localized: "Outline, \(list.count) headings"))
    }

    /// The section holding the caret at `location`; none before the first heading.
    func setCaret(location: Int) {
        let index = headings.lastIndex { $0.location <= location }
        guard index != current else { return }
        let first = current == nil
        current = index
        marker.target = CGFloat(index ?? 0)
        if first { marker.snap() }
        kick()
    }

    /// Where the reading is: `location` is the character at the reading line. While scrolling the
    /// ink mark shows it and fades a moment after the text stops.
    func setReading(location: Int, scrolling: Bool) {
        guard !headings.isEmpty else { return }
        // Between the ticks of the section's heading and the next, by how far into it the reading
        // is; on the first tick before any heading, on the last through the last section.
        let next = headings.firstIndex { $0.location > location } ?? headings.count
        if next == 0 || next == headings.count {
            reading.target = next == 0 ? 0 : CGFloat(headings.count - 1)
        } else {
            let start = headings[next - 1].location, end = headings[next].location
            reading.target = CGFloat(next - 1) + CGFloat(location - start) / CGFloat(max(end - start, 1))
        }
        guard scrolling else {
            reading.snap()
            return redraw()
        }
        if readingAlpha.value < 0.05 { reading.snap() }
        readingAlpha.target = 1
        readingTimer?.invalidate()
        readingTimer = after(0.8) { rail in
            rail.readingAlpha.target = 0
            rail.kick()
        }
        kick()
    }

    // MARK: Layout

    private func title(_ i: Int) -> String { headings[i].title.isEmpty ? String(localized: "Untitled") : headings[i].title }

    private static func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

    /// Titles measured once per change of the outline: the panel is as wide as its longest title
    /// needs (within 180–300 pt); a title wider still takes a second line, then an ellipsis. Each
    /// row also knows its parent and where its section ends, for the guide.
    private func buildRows() {
        let top = headings.map(\.level).min() ?? 1
        let measured = headings.indices.map { i -> (depth: Int, text: NSAttributedString, line: CTLine) in
            let depth = min(max(headings[i].level - top, 0), 3)
            let text = NSAttributedString(string: title(i), attributes: [.font: Tokens.font(13, depth == 0 ? .medium : .regular), Self.contextColor: true])
            return (depth, text, CTLineCreateWithAttributedString(text))
        }
        let widest = measured.map { Self.textLead + CGFloat($0.depth) * Self.indent + Self.width($0.line) * Self.lift + Self.tickColumn }.max() ?? 0
        panelWidth = min(max(widest, 220), Self.maxPanelWidth).rounded(.up)
        var y: CGFloat = 0, chapters = 0
        var open: [Int] = []
        rows = measured.indices.map { i in
            let m = measured[i]
            let room = (panelWidth - Self.textLead - CGFloat(m.depth) * Self.indent - Self.tickColumn) / Self.lift
            var lines = [m.line], truncated = false
            if Self.width(m.line) > room {
                let setter = CTTypesetterCreateWithAttributedString(m.text)
                let split = CTTypesetterSuggestLineBreak(setter, 0, Double(room))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: m.text.attributes(at: 0, effectiveRange: nil)))
                if split > 0, split < m.text.length {
                    let tail = CTLineCreateWithAttributedString(m.text.attributedSubstring(from: NSRange(location: split, length: m.text.length - split)))
                    truncated = Self.width(tail) > room
                    lines = [CTTypesetterCreateLine(setter, CFRange(location: 0, length: split)), CTLineCreateTruncatedLine(tail, Double(room), .end, ellipsis) ?? tail]
                } else {
                    truncated = true
                    lines = [CTLineCreateTruncatedLine(m.line, Double(room), .end, ellipsis) ?? m.line]
                }
            }
            if i > 0, m.depth == 0 {
                chapters += 1
                y += Self.chapterGap
            }
            while let last = open.last, measured[last].depth >= m.depth { open.removeLast() }
            let parent = open.last
            open.append(i)
            let height = Self.row + CGFloat(lines.count - 1) * Self.lineGap
            defer { y += height }
            return Row(depth: m.depth, lines: lines, truncated: truncated, height: height, center: y + height / 2, chapters: chapters, parent: parent, end: i)
        }
        // A section ends where the next heading of its level or higher starts.
        for i in rows.indices.reversed() {
            var end = i
            while end + 1 < rows.count, rows[end + 1].depth > rows[i].depth { end = rows[end + 1].end }
            rows[i].end = end
        }
        contentHeight = y
    }

    private static func tickLength(_ depth: Int) -> CGFloat { [16, 12, 9, 7][depth] }

    /// Resting ticks: centered on the text area, 12 pt apart (down to 6 when the outline is long),
    /// a little more room before each chapter, in a strip no taller than `restCap`.
    private var restWindowCap: CGFloat { max(40, min(Self.restCap, usableHeight - 80)) }
    private var restPitch: CGFloat {
        let gaps = CGFloat(rows.last?.chapters ?? 0) * Self.restChapterGap
        return min(12, max(6, (restWindowCap - gaps) / CGFloat(max(rows.count, 1))))
    }
    /// The strip's middle: the frame's, unless that would bring it down to the bottom's clear room.
    private var restCenter: CGFloat { min(bounds.midY, usableHeight - 40 - restWindow / 2) }
    /// The whole column of ticks, first to last, and the part of it the strip shows.
    private var restSpan: CGFloat { CGFloat(rows.count - 1) * restPitch + CGFloat(rows[rows.count - 1].chapters) * Self.restChapterGap }
    private var restWindow: CGFloat { min(restSpan, restWindowCap) }
    /// How far a longer column has moved up: in proportion to how far the reading is, so the
    /// reading mark travels down the strip, from its top at the start of the document to its
    /// bottom at the end, over the ticks of the sections around it.
    private var restScroll: CGFloat {
        let hidden = restSpan - restWindow
        guard hidden > 0, rows.count > 1 else { return 0 }
        return hidden * min(max(reading.value / CGFloat(rows.count - 1), 0), 1)
    }
    private func restY(_ i: Int) -> CGFloat {
        let y = restCenter - restWindow / 2 + CGFloat(i) * restPitch + CGFloat(rows[i].chapters) * Self.restChapterGap - restScroll
        return (y * 2).rounded() / 2
    }
    private var restZone: NSRect {
        NSRect(x: bounds.maxX - 36, y: (restCenter - restWindow / 2).rounded() - 10, width: 36, height: restWindow.rounded() + 20)
    }
    /// At rest, ticks near an end of the strip fade where more of the outline lies beyond it.
    private func restFade(_ y: CGFloat) -> CGFloat {
        let zone = restZone, band: CGFloat = 18
        var f: CGFloat = 1
        if restScroll > 0.5 { f = min(f, (y - zone.minY) / band) }
        if restScroll < restSpan - restWindow - 0.5 { f = min(f, (zone.maxY - y) / band) }
        return min(max(f, 0), 1)
    }

    private var viewport: CGFloat { min(contentHeight, usableHeight - 2 * (Self.edge + Self.pad), Self.panelCap) }
    private var maxScroll: CGFloat { max(0, contentHeight - viewport) }
    private var panelRect: NSRect { NSRect(x: bounds.maxX - panelWidth, y: panelTop, width: panelWidth, height: viewport + 2 * Self.pad) }
    private func expandedY(_ i: Int, scroll s: CGFloat) -> CGFloat { panelTop + Self.pad + rows[i].center - s }

    /// Where row `i` is drawn now: between its tick at rest and its row in the panel.
    private func shownY(_ i: Int) -> CGFloat {
        let rest = restY(i)
        return rest + (expandedY(i, scroll: scroll.value) - rest) * zoom.value
    }

    private func shownY(at f: CGFloat) -> CGFloat { interpolate(f) { self.shownY($0) } }

    private func interpolate(_ f: CGFloat, _ value: (Int) -> CGFloat) -> CGFloat {
        let f = min(max(f, 0), CGFloat(rows.count - 1)), i = Int(f), t = f - CGFloat(i)
        return t == 0 ? value(i) : value(i) + (value(i + 1) - value(i)) * t
    }

    private func textLeft(_ depth: CGFloat) -> CGFloat { bounds.maxX - panelWidth + Self.textLead + depth * Self.indent }

    /// The panel opens on heading `i`, its row placed at `y`: a list that fits moves to put it
    /// there; a longer one is centered on `y` (as far as the rail allows) and scrolls it there.
    private func placePanel(on i: Int, at y: CGFloat) {
        let height = viewport + 2 * Self.pad
        let ideal = maxScroll > 0 ? y - height / 2 : y - Self.pad - rows[i].center
        panelTop = min(max(ideal, Self.edge), usableHeight - Self.edge - height).rounded()
        scroll.snap(to: min(max(panelTop + Self.pad + rows[i].center - y, 0), maxScroll))
    }

    /// Fractional row under `y` in the open panel (the lens follows it smoothly).
    private func fractionalIndex(_ y: CGFloat) -> CGFloat {
        let s = scroll.target
        guard let next = rows.indices.first(where: { expandedY($0, scroll: s) > y }) else { return CGFloat(rows.count - 1) }
        guard next > 0 else { return 0 }
        let a = expandedY(next - 1, scroll: s), b = expandedY(next, scroll: s)
        return CGFloat(next - 1) + (y - a) / (b - a)
    }

    /// The row a click at `y` chooses in the open panel.
    private func rowIndex(_ y: CGFloat) -> Int? {
        let panel = panelRect
        guard y >= panel.minY + Self.pad / 2, y < panel.maxY - Self.pad / 2 else { return nil }
        // A chapter's row also takes the gap above it.
        return rows.indices.last { expandedY($0, scroll: scroll.target) - rows[$0].height / 2 - ($0 > 0 && rows[$0].depth == 0 ? Self.chapterGap : 0) <= y }
    }

    private func guideGroup(_ i: Int) -> Int? { rows[i].end > i ? i : rows[i].parent }

    private func isAncestor(_ a: Int, of i: Int) -> Bool {
        var p = rows[i].parent
        while let q = p {
            if q == a { return true }
            p = rows[q].parent
        }
        return false
    }

    // MARK: Motion

    private func open(at p: NSPoint) {
        guard !rows.isEmpty, !isQuiet, !isOpen else { return }
        if zoom.value < 0.02 {
            // Fresh: the tick pointed at stays under the pointer while the rest spread from it.
            anchor = rows.indices.min { abs(restY($0) - p.y) < abs(restY($1) - p.y) } ?? 0
            placePanel(on: anchor, at: p.y)
            focus.snap(to: CGFloat(anchor))
            pill.snap(to: CGFloat(anchor))
        }
        zoom.target = 1
        zoom.response = 0.42
        zoom.damping = 0.86
        titles.target = 1
        titles.response = 0.3
        pillAlpha.target = 1
        hover(p)
        window?.invalidateCursorRects(for: self)
    }

    private func close(immediately: Bool = false) {
        openTimer?.invalidate()
        closeTimer?.invalidate()
        openTimer = nil
        closeTimer = nil
        guard isOpen || immediately else { return }
        zoom.target = 0
        zoom.response = 0.32
        zoom.damping = 1
        titles.target = 0
        titles.response = 0.16
        pillAlpha.target = 0
        guideAlpha.target = 0
        hovered = nil
        pressed = false
        toolTip = nil
        if immediately { Self.springs.forEach { self[keyPath: $0].snap() } }
        kick()
        window?.invalidateCursorRects(for: self)
    }

    private func hover(_ p: NSPoint) {
        focus.target = fractionalIndex(p.y)
        let row = rowIndex(p.y)
        if row != hovered {
            hovered = row
            if let row {
                pill.target = CGFloat(row)
                // The guide marks a group: the row's own subheadings, or else its siblings.
                if let group = guideGroup(row) {
                    let fresh = guideAlpha.value < 0.05
                    guideTop.target = CGFloat(group + 1)
                    guideBottom.target = CGFloat(rows[group].end)
                    guideDepth.target = CGFloat(rows[group].depth + 1)
                    if fresh { [\OutlineRail.guideTop, \.guideBottom, \.guideDepth].forEach { self[keyPath: $0].snap() } }
                }
            }
            toolTip = row.flatMap { rows[$0].truncated ? title($0) : nil }
        }
        pillAlpha.target = row == nil ? 0 : 1
        guideAlpha.target = row.flatMap(guideGroup) == nil ? 0 : 1
        kick()
    }

    /// Starts the clock, or with Reduce Motion (or no window) puts everything where it is going.
    private func kick() {
        guard !isFrozen else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil {
            Self.springs.forEach { self[keyPath: $0].snap() }
            redraw()
        } else {
            clock.start()
        }
    }

    private func advance(_ dt: CGFloat) -> Bool {
        Self.springs.forEach { self[keyPath: $0].step(dt) }
        redraw()
        return Self.springs.contains { !self[keyPath: $0].isSettled }
    }

    /// The zoom as a camera's scale: the resting pitch over the panel's row height at rest, 1 open.
    /// Titles and the surface's width scale with it about the ticks' right end.
    private var camera: CGFloat {
        let rest = restPitch / Self.row
        return rest + (1 - rest) * min(max(zoom.value, 0), 1.05)
    }
    private var pivot: CGFloat { bounds.maxX - Self.tickInset }

    /// The surface follows the zoom: vertically from the strip of resting ticks to the panel, as
    /// the rows do; horizontally with the camera, as the titles do, so they stay on it.
    private func redraw() {
        guard !rows.isEmpty else { return ink.needsDisplay = true }
        let z = zoom.value, from = restZone, to = panelRect
        let left = min(pivot - (pivot - to.minX) * camera, from.minX)
        plate.frame = NSRect(x: left, y: from.minY + (to.minY - from.minY) * z, width: bounds.maxX - left, height: from.height + (to.height - from.height) * z)
        // Closing, the titles' quicker spring takes the surface with them.
        plate.alphaValue = min(max(min(z * 1.6, titles.value * 1.5), 0), 1)
        ink.needsDisplay = true
    }

    // MARK: Drawing

    private static func gauss(_ d: CGFloat) -> CGFloat { exp(-d * d / (2 * 1.4 * 1.4)) }

    private static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> CGColor {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return a.cgColor }
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return CGColor(srgbRed: m(a.redComponent, b.redComponent), green: m(a.greenComponent, b.greenComponent), blue: m(a.blueComponent, b.blueComponent), alpha: m(a.alphaComponent, b.alphaComponent))
    }

    private func fillTick(_ context: CGContext, y: CGFloat, length: CGFloat) {
        let right = bounds.maxX - Self.tickInset
        context.addPath(CGPath(roundedRect: CGRect(x: right - length, y: y - 1, width: length, height: 2), cornerWidth: 1, cornerHeight: 1, transform: nil))
        context.fillPath()
    }

    /// The tick length at a fractional row, plus the lens near the pointer.
    private func markLength(_ f: CGFloat, lens e: CGFloat) -> CGFloat {
        interpolate(f) { Self.tickLength(self.rows[$0].depth) } + 10 * Self.gauss(f - focus.value) * e
    }

    private func drawInk(_ context: CGContext) {
        guard !rows.isEmpty else { return }
        let e = min(max(zoom.value, 0), 1), surface = plate.frame
        context.saveGState()
        context.clip(to: surface)
        if pillAlpha.value > 0.01, e > 0.01 {
            let y = shownY(at: pill.value), h = interpolate(pill.value) { self.rows[$0].height } - 4
            context.setAlpha(pillAlpha.value * e)
            context.setFillColor((pressed ? Tokens.pressed : Tokens.hover).cgColor)
            context.addPath(CGPath(roundedRect: CGRect(x: surface.minX + 6, y: y - h / 2, width: surface.width - 12, height: h), cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
            context.setAlpha(1)
        }
        if guideAlpha.value > 0.01, e > 0.01 {
            let x = textLeft(guideDepth.value) - 7
            let top = shownY(at: guideTop.value) - interpolate(guideTop.value) { self.rows[$0].height } / 2 + 5
            let bottom = shownY(at: guideBottom.value) + interpolate(guideBottom.value) { self.rows[$0].height } / 2 - 5
            context.setAlpha(guideAlpha.value * e * min(max((titles.value - 0.5) * 2, 0), 1))
            context.setFillColor(Tokens.line.cgColor)
            context.fill(CGRect(x: x, y: top, width: 1, height: max(0, bottom - top)))
            context.setAlpha(1)
        }
        // Higher levels are a little darker, so the structure reads even at rest.
        for i in rows.indices {
            let y = shownY(i)
            guard y > surface.minY - 2, y < surface.maxY + 2 else { continue }
            let g = Self.gauss(CGFloat(i) - focus.value) * e, weight: CGFloat = [1, 0.85, 0.7, 0.6][rows[i].depth]
            let fade = restFade(restY(i))
            context.saveGState()
            context.setAlpha((weight + (1 - weight) * g) * (fade + (1 - fade) * e))
            context.setFillColor(Self.mix(Tokens.ink3, Tokens.ink2, g))
            fillTick(context, y: y, length: Self.tickLength(rows[i].depth) + 10 * g)
            context.restoreGState()
        }
        // The reading mark, hidden where it would sit on the caret's.
        if readingAlpha.value > 0.01 {
            let f = reading.value
            let apart = current == nil ? 1 : min(max((abs(f - marker.value) - 0.15) / 0.45, 0), 1)
            context.saveGState()
            context.setAlpha(readingAlpha.value * apart)
            context.setFillColor(Tokens.ink.cgColor)
            fillTick(context, y: shownY(at: f), length: markLength(f, lens: e) + 6)
            context.restoreGState()
        }
        if current != nil {
            let f = marker.value
            context.saveGState()
            context.setShadow(offset: .zero, blur: 5, color: Tokens.accent.cgColor.copy(alpha: 0.5))
            context.setFillColor(Tokens.accent.cgColor)
            fillTick(context, y: shownY(at: f), length: markLength(f, lens: e) + 4)
            context.restoreGState()
        }
        if titles.value > 0.01 { drawTitles(context, surface: surface, lens: e) }
        // Rows scrolled out of view fade at the panel's ends.
        if maxScroll > 0, e > 0.01 {
            let raised = Tokens.raised.cgColor
            for (top, visible) in [(true, scroll.value > 0.5), (false, scroll.value < maxScroll - 0.5)] where visible {
                let band = CGRect(x: surface.minX, y: top ? surface.minY : surface.maxY - 20, width: surface.width, height: 20)
                let colors = [raised, raised.copy(alpha: 0)!] as CFArray
                guard let gradient = CGGradient(colorsSpace: nil, colors: top ? colors : [raised.copy(alpha: 0)!, raised] as CFArray, locations: nil) else { continue }
                context.saveGState()
                context.clip(to: band)
                context.setAlpha(e)
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: band.minY), end: CGPoint(x: 0, y: band.maxY), options: [])
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    /// Titles take part in the zoom: scaled about the ticks' right end from the size the resting
    /// pitch implies to full size, so they grow out of the ticks and never meet the surface's
    /// edge. They fade in outward from the heading the zoom opened on, parents a beat before their
    /// subheadings. The nearest to the pointer are brighter and slightly larger; the pointed row's
    /// chapter and section stay bright too.
    private func drawTitles(_ context: CGContext, surface: NSRect, lens e: CGFloat) {
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let font = Tokens.font(13)
        let mid = (font.ascender + font.descender) / 2
        let camera = self.camera, gate = min(max((zoom.value - 0.35) / 0.4, 0), 1)
        for i in rows.indices {
            let row = rows[i]
            let delay = min(0.05 * CGFloat(abs(i - anchor)), 0.25) + 0.03 * CGFloat(row.depth)
            let a = min(max((titles.value - delay) / 0.67, 0), 1) * gate
            let y = shownY(i)
            guard a > 0.01, y + row.height / 2 > surface.minY, y - row.height / 2 < surface.maxY else { continue }
            let near = Self.gauss(CGFloat(i) - focus.value) * e
            let g = max(near, hovered.map { isAncestor(i, of: $0) ? 0.8 * e : 0 } ?? 0)
            let scale = camera * (1 + (Self.lift - 1) * near)
            context.saveGState()
            context.setAlpha(a * (0.72 + 0.28 * g))
            context.setFillColor(i == current ? Tokens.accent.cgColor : Self.mix(Tokens.ink2, Tokens.ink, g))
            context.translateBy(x: pivot - (pivot - textLeft(CGFloat(row.depth))) * camera, y: y)
            context.scaleBy(x: scale, y: scale)
            for (n, line) in row.lines.enumerated() {
                context.textPosition = CGPoint(x: 0, y: mid + (CGFloat(n) - CGFloat(row.lines.count - 1) / 2) * Self.lineGap)
                CTLineDraw(line, context)
            }
            context.restoreGState()
        }
    }

    // MARK: Pointer

    /// What takes the pointer: the strip around the ticks, or the open panel.
    private var activeRect: NSRect { isOpen ? panelRect : restZone }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !isQuiet, !rows.isEmpty, let superview else { return nil }
        return activeRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        guard !isQuiet, !rows.isEmpty else { return }
        addCursorRect(activeRect, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)) }
    }

    /// Opens after the pointer has been on the ticks for a moment (passing over them on the way
    /// to the scroll bar does not), and closes a moment after it leaves the panel.
    override func mouseMoved(with event: NSEvent) {
        guard !isQuiet, !rows.isEmpty else { return }
        pointer = convert(event.locationInWindow, from: nil)
        if isOpen {
            if panelRect.insetBy(dx: -6, dy: -6).contains(pointer) {
                closeTimer?.invalidate()
                closeTimer = nil
                hover(pointer)
            } else if closeTimer == nil {
                closeTimer = after(0.14) { $0.close() }
            }
        } else if restZone.contains(pointer) {
            if openTimer == nil { openTimer = after(0.07) { $0.open(at: $0.pointer) } }
        } else {
            openTimer?.invalidate()
            openTimer = nil
        }
    }

    /// On the run loop in common modes, so it also fires while AppKit tracks an event.
    private func after(_ seconds: Double, _ action: @escaping (OutlineRail) -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] timer in
            guard let self else { return }
            if timer === self.openTimer { self.openTimer = nil }
            if timer === self.closeTimer { self.closeTimer = nil }
            action(self)
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        openTimer?.invalidate()
        openTimer = nil
        if isOpen, closeTimer == nil { closeTimer = after(0.14) { $0.close() } }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard isOpen, rowIndex(p.y) != nil else { return }
        pressed = true
        ink.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressed = false
        // A click on the resting ticks opens at once.
        guard isOpen else { return open(at: p) }
        guard let i = rowIndex(p.y) else { return }
        ink.needsDisplay = true
        onSelect?(headings[i])
    }

    override func scrollWheel(with event: NSEvent) {
        guard isOpen, maxScroll > 0 else {
            onScroll?(event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.row
        scroll.target = min(max(scroll.target - delta, 0), maxScroll)
        // The trackpad already carries its own momentum; a wheel's notches glide.
        if event.hasPreciseScrollingDeltas { scroll.snap() }
        hover(convert(event.locationInWindow, from: nil))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    // MARK: Snapshots

    /// Snapshots step the motion by hand, so a frame at a chosen moment can be checked.
    private var isFrozen = false

    /// The pointer resting on the ticks, `fraction` of the way down them.
    func pointForSnapshot(_ fraction: CGFloat) -> NSPoint {
        let zone = restZone.insetBy(dx: 0, dy: 10)
        return NSPoint(x: bounds.maxX - 20, y: zone.minY + fraction * zone.height)
    }

    /// Opens at `point` (no hover delay) and runs the motion for `seconds`, in 120 Hz steps.
    func hoverForSnapshot(at point: NSPoint, seconds: CGFloat) {
        isFrozen = true
        clock.stop()
        pointer = point
        open(at: point)
        run(seconds)
    }

    /// Then the pointer moves to `fraction` of the open panel's height, or leaves (nil).
    func moveForSnapshot(to fraction: CGFloat?, seconds: CGFloat) {
        if let fraction {
            let panel = panelRect
            pointer = NSPoint(x: bounds.maxX - 60, y: panel.minY + fraction * panel.height)
            hover(pointer)
        } else {
            close()
        }
        run(seconds)
    }

    private func run(_ seconds: CGFloat) {
        for _ in 0..<Int((seconds * 120).rounded()) { _ = advance(1.0 / 120) }
        redraw()
    }
}

/// The rail's drawing layer, above its surface.
private final class InkView: NSView {
    var drawer: ((CGContext) -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawer?(context)
    }
}

/// The outline as a card: headings indented by level, the one being read marked. A click goes to a
/// heading; a double click (or Return on a selected row) renames it in place, as an undoable edit.
final class OutlineCard: SurfaceView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onSelect: ((MarkdownEditor.Heading) -> Void)?
    var onRename: ((MarkdownEditor.Heading, String) -> Void)?
    private var headings: [MarkdownEditor.Heading] = []
    private var current: Int?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let title = flatLabel(String(localized: "Outline"), size: 11, weight: .semibold, color: Tokens.ink3)
    private var editing: Int?
    private var height: NSLayoutConstraint!

    static let width: CGFloat = 280

    init() {
        super.init(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.panel, elevated: true)
        pointer = .arrow
        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.flatten()
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityLabel(String(localized: "Outline"))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        for v in [title, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        height = heightAnchor.constraint(equalToConstant: 200)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), title.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            widthAnchor.constraint(equalToConstant: Self.width), height,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ list: [MarkdownEditor.Heading], current: Int?) {
        if list != headings {
            headings = list
            table.reloadData()
        }
        self.current = current
        height.constant = CGFloat(list.count) * 28 + 44
        for row in 0..<table.numberOfRows { (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HeadingCell)?.marked = row == current }
        if let current, current < list.count { table.scrollRowToVisible(current) }
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0, row < headings.count, editing == nil else { return }
        onSelect?(headings[row])
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < headings.count else { return }
        beginRename(row)
    }

    override func keyDown(with event: NSEvent) {
        if event.specialKey == .carriageReturn, table.selectedRow >= 0 { beginRename(table.selectedRow) } else { super.keyDown(with: event) }
    }

    private func beginRename(_ row: Int) {
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HeadingCell else { return }
        editing = row
        cell.label.cell?.isScrollable = true
        cell.label.isEditable = true
        cell.label.delegate = self
        cell.label.stringValue = headings[row].title
        window?.makeFirstResponder(cell.label)
        cell.label.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)), let row = editing else { return false }
        editing = nil
        (control as? NSTextField)?.stringValue = headings[row].title
        (control as? NSTextField)?.isEditable = false
        (control as? NSTextField)?.cell?.isScrollable = false
        window?.makeFirstResponder(table)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let row = editing else { return }
        editing = nil
        field.isEditable = false
        field.cell?.isScrollable = false
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != headings[row].title { onRename?(headings[row], text) } else { field.stringValue = headings[row].title }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FlatRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("heading"), owner: nil) as? HeadingCell ?? HeadingCell()
        let top = headings.map(\.level).min() ?? 1
        cell.configure(headings[row].title.isEmpty ? String(localized: "Untitled") : headings[row].title, depth: headings[row].level - top)
        cell.marked = row == current
        return cell
    }
}

private final class HeadingCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!
    private var depth = 0
    var marked = false { didSet { restyle() } }

    init() {
        super.init(frame: .zero)
        identifier = .init("heading")
        label.translatesAutoresizingMaskIntoConstraints = false
        // A long title ends in an ellipsis (its full text in the tooltip); it scrolls only while renamed.
        label.lineBreakMode = .byTruncatingTail
        label.focusRingType = .none
        addSubview(label)
        textField = label
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        NSLayoutConstraint.activate([leading, label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ title: String, depth: Int) {
        label.stringValue = title
        toolTip = title
        self.depth = max(0, depth)
        leading.constant = 10 + CGFloat(min(self.depth, 4)) * 14
        restyle()
    }

    private func restyle() {
        label.font = Tokens.font(13, marked ? .semibold : depth == 0 ? .medium : .regular)
        label.textColor = marked ? Tokens.accent : depth <= 1 ? Tokens.ink : Tokens.ink2
    }
}
