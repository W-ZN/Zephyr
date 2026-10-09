import AppKit
import ZephyrRender

/// The window's open documents on the left edge while the sidebar is hidden (design §7.8): the
/// outline's counterpart, drawn the same seamless way. At rest a short column of dots, one per
/// document, the shown one larger and in the accent, an unsaved untitled document's hollow.
/// Pointing at the column opens it the way the outline opens: a surface grows out of the dots
/// toward the text, the dots spread to rows and each row's name fades in beside its dot. The row
/// under the pointer is lit and has a close button at its end. A click shows the document; the ×
/// closes it (an ×: closing never deletes the file). Either way the list stays until the pointer
/// leaves it. Dots on the left against ticks on the right,
/// names of documents against headings: the two rails never look alike.
final class DocumentRail: NSView {
    struct Item: Equatable {
        var title: String
        var current: Bool
        var unsaved: Bool
    }

    var items: [Item] = [] { didSet { if items != oldValue { changed() } } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// Over the resting dots, and over a list with nothing to scroll, the wheel moves the text.
    var onScroll: ((NSEvent) -> Void)?

    /// The margin a resting rail needs beside the reading column, as the outline's.
    static let width: CGFloat = 44
    static let maxPanelWidth: CGFloat = 300

    /// The dots' centers, from the rail's left edge, at rest and open alike: as far from the left
    /// edge as the outline's ticks are, on average, from the right.
    private static let dotX: CGFloat = 16
    private static let row: CGFloat = 32
    /// Inside the surface, above the first row and below the last.
    private static let pad: CGFloat = 6
    /// The surface keeps this far inside the rail's ends.
    private static let edge: CGFloat = 8
    private static let textLeft: CGFloat = 34
    /// The close button's circle at a row's end.
    private static let closeSize: CGFloat = 20

    private var open = Spring(0, response: 0.36, damping: 0.88)
    private var titles = Spring(0, response: 0.26)
    private var pill = Spring(0, response: 0.2, damping: 0.86)
    private var pillAlpha = Spring(0, response: 0.18)
    private static let springs: [ReferenceWritableKeyPath<DocumentRail, Spring>] = [\.open, \.titles, \.pill, \.pillAlpha]
    private lazy var clock = FrameClock(view: self) { [weak self] dt in self?.advance(dt) ?? false }

    private let plate = SurfaceView(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.panel, elevated: true)
    private let ink = RailInk()
    private var lines: [CTLine] = []
    private var panelWidth: CGFloat = 180
    private var panelTop: CGFloat = 0
    /// Rows scrolled out above, when there are more than the rail holds.
    private var scroll: CGFloat = 0
    private var pointer = NSPoint.zero
    private var hovered: Int?
    private var onCloseButton = false
    private var pressed: (index: Int, close: Bool)?
    private var openTimer: Timer?
    private var closeTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        plate.alphaValue = 0
        addSubview(plate)
        ink.frame = bounds
        ink.autoresizingMask = [.width, .height]
        ink.drawer = { [weak self] context in self?.drawInk(context) }
        addSubview(ink)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(String(localized: "Open documents"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard !items.isEmpty else { return }
        panelTop = min(max(panelTop, Self.edge), max(Self.edge, bounds.height - Self.edge - panelHeight)).rounded()
        scroll = min(scroll, maxScroll)
        redraw()
    }

    private var isOpen: Bool { open.target == 1 }

    private func changed() {
        let attrs: [NSAttributedString.Key: Any] = [.font: Tokens.font(13), Self.contextColor: true]
        lines = items.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0.title, attributes: attrs)) }
        let widest = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        panelWidth = min(max(Self.textLeft + widest + 12 + Self.closeSize + 8, 220), Self.maxPanelWidth).rounded(.up)
        hovered = hovered.flatMap { items.indices.contains($0) ? $0 : nil }
        pressed = nil
        scroll = min(scroll, maxScroll)
        if isOpen { panelTop = min(max(panelTop, Self.edge), max(Self.edge, bounds.height - Self.edge - panelHeight)).rounded() }
        redraw()
        rebuildAccessibility()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Geometry

    /// Resting dots: centered on the text area (the frame spans it), 18 pt apart (closer, down to
    /// 10, when there are many).
    private var restPitch: CGFloat { min(18, max(10, 400 / CGFloat(max(items.count - 1, 1)))) }
    private func restY(_ i: Int) -> CGFloat {
        let span = CGFloat(items.count - 1) * restPitch
        return (bounds.midY - span / 2 + CGFloat(i) * restPitch).rounded()
    }
    private var restZone: NSRect {
        let first = restY(0), last = restY(items.count - 1)
        return NSRect(x: 0, y: first - 12, width: 38, height: last - first + 24)
    }

    private var panelHeight: CGFloat { min(CGFloat(items.count) * Self.row, bounds.height - 2 * (Self.edge + Self.pad)) + 2 * Self.pad }
    private var maxScroll: CGFloat { max(0, CGFloat(items.count) * Self.row + 2 * Self.pad - panelHeight) }
    private var panelRect: NSRect { NSRect(x: 0, y: panelTop, width: panelWidth, height: panelHeight) }
    private func rowY(_ i: Int) -> CGFloat { panelTop + Self.pad + (CGFloat(i) + 0.5) * Self.row - scroll }

    /// Where document `i`'s dot is now: between its place at rest and its row.
    private func shownY(_ i: Int) -> CGFloat {
        let rest = restY(i)
        return rest + (rowY(i) - rest) * open.value
    }

    /// The surface opens with row `i` under `y`, as far as it fits the rail; a list longer than the
    /// rail is centered on `y` and scrolls the row there.
    private func placePanel(on i: Int, at y: CGFloat) {
        let height = panelHeight
        let ideal = maxScroll > 0 ? y - height / 2 : y - Self.pad - (CGFloat(i) + 0.5) * Self.row
        panelTop = min(max(ideal, Self.edge), max(Self.edge, bounds.height - Self.edge - height)).rounded()
        scroll = min(max(panelTop + Self.pad + (CGFloat(i) + 0.5) * Self.row - y, 0), maxScroll)
    }

    private func rowIndex(_ p: NSPoint) -> Int? {
        let panel = panelRect
        guard panel.insetBy(dx: 0, dy: Self.pad / 2).contains(p) else { return nil }
        let i = Int(floor((p.y - panelTop - Self.pad + scroll) / Self.row))
        return items.indices.contains(i) ? i : nil
    }

    private func closeRect(_ i: Int) -> NSRect {
        NSRect(x: panelWidth - 8 - Self.closeSize, y: rowY(i) - Self.closeSize / 2, width: Self.closeSize, height: Self.closeSize)
    }

    // MARK: Motion

    private func openRail(at p: NSPoint) {
        guard !items.isEmpty, !isOpen else { return }
        if open.value < 0.02 {
            let anchor = items.indices.min { abs(restY($0) - p.y) < abs(restY($1) - p.y) } ?? 0
            placePanel(on: anchor, at: p.y)
            pill.snap(to: CGFloat(anchor))
        }
        open.target = 1
        titles.target = 1
        hover(p)
        window?.invalidateCursorRects(for: self)
    }

    private func closeRail(immediately: Bool = false) {
        openTimer?.invalidate()
        closeTimer?.invalidate()
        openTimer = nil
        closeTimer = nil
        guard isOpen || immediately else { return }
        open.target = 0
        titles.target = 0
        pillAlpha.target = 0
        hovered = nil
        onCloseButton = false
        pressed = nil
        toolTip = nil
        if immediately { Self.springs.forEach { self[keyPath: $0].snap() } }
        kick()
        window?.invalidateCursorRects(for: self)
    }

    /// Closes at once (the sidebar opened, the documents changed under it).
    func dismiss() { closeRail(immediately: true) }

    private func hover(_ p: NSPoint) {
        let row = rowIndex(p)
        if row != hovered {
            hovered = row
            if let row { pill.target = CGFloat(row) }
            toolTip = row.map { items[$0].title }
        }
        onCloseButton = row.map { closeRect($0).insetBy(dx: -3, dy: -3).contains(p) } ?? false
        pillAlpha.target = row == nil ? 0 : 1
        kick()
    }

    private func kick() {
        guard !isFrozen else { return redraw() }
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

    /// The surface follows the opening from the strip around the dots to the list.
    private func redraw() {
        guard !items.isEmpty else { return ink.needsDisplay = true }
        let z = open.value, from = restZone, to = panelRect
        plate.frame = NSRect(x: 0, y: from.minY + (to.minY - from.minY) * z,
                             width: from.width + (to.width - from.width) * z, height: from.height + (to.height - from.height) * z)
        plate.alphaValue = min(max(min(z * 1.6, titles.value * 1.5), 0), 1)
        ink.needsDisplay = true
    }

    // MARK: Drawing

    private static let contextColor = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)

    private func drawInk(_ context: CGContext) {
        guard !items.isEmpty else { return }
        let z = min(max(open.value, 0), 1), surface = plate.frame
        context.saveGState()
        if z > 0.01 { context.clip(to: surface.insetBy(dx: 0, dy: -12)) }
        if pillAlpha.value > 0.01, z > 0.01 {
            let y = rowY(0) + pill.value * Self.row, h = Self.row - 4
            context.setAlpha(pillAlpha.value * z)
            context.setFillColor((pressed.map { !$0.close } == true ? Tokens.pressed : Tokens.hover).cgColor)
            context.addPath(CGPath(roundedRect: CGRect(x: surface.minX + 5, y: y - h / 2, width: surface.width - 10, height: h), cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
            context.setAlpha(1)
        }
        for i in items.indices {
            let y = shownY(i)
            guard z < 0.01 || (y > surface.minY - 4 && y < surface.maxY + 4) else { continue }
            drawDot(context, item: items[i], at: NSPoint(x: Self.dotX, y: y), lit: hovered == i ? z : 0)
        }
        if titles.value > 0.01 { drawTitles(context, surface: surface) }
        context.restoreGState()
    }

    /// A document's dot: 7 pt, or 10 pt in the accent with a soft glow for the one shown; hollow for
    /// an untitled document that exists nowhere else; darker under the pointer.
    private func drawDot(_ context: CGContext, item: Item, at p: NSPoint, lit: CGFloat) {
        let d: CGFloat = item.current ? 10 : 7
        let rect = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        context.saveGState()
        if item.current {
            context.setShadow(offset: .zero, blur: 5, color: Tokens.accent.cgColor.copy(alpha: 0.5))
            context.setFillColor(Tokens.accent.cgColor)
            context.fillEllipse(in: rect)
        } else {
            let color = lit > 0.5 ? Tokens.ink2 : Tokens.ink3
            if item.unsaved {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(1.5)
                context.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
            } else {
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: rect)
            }
        }
        context.restoreGState()
    }

    /// Names fade in beside their dots as the list opens, the shown one in the accent; the row
    /// under the pointer has its close button.
    private func drawTitles(_ context: CGContext, surface: NSRect) {
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let font = Tokens.font(13)
        let mid = (font.ascender + font.descender) / 2
        let a = min(max((titles.value - 0.3) / 0.7, 0), 1) * min(max((open.value - 0.35) / 0.4, 0), 1)
        guard a > 0.01 else { return }
        for i in items.indices {
            let y = rowY(i)
            guard y + Self.row / 2 > surface.minY, y - Self.row / 2 < surface.maxY else { continue }
            let room = panelWidth - Self.textLeft - 12 - Self.closeSize - 8
            var line = lines[i]
            if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > room {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font, Self.contextColor: true]))
                line = CTLineCreateTruncatedLine(line, Double(room), .middle, ellipsis) ?? line
            }
            context.saveGState()
            context.setAlpha(a)
            context.setFillColor(items[i].current ? Tokens.accent.cgColor : hovered == i ? Tokens.ink.cgColor : Tokens.ink2.cgColor)
            context.textPosition = CGPoint(x: Self.textLeft, y: y + mid)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        guard let i = hovered else { return }
        let rect = closeRect(i), active = onCloseButton
        context.saveGState()
        context.setAlpha(a)
        // On the row's own hover tint, the button's circle is a step darker, and darker again pressed.
        if active {
            context.setFillColor(Tokens.pressed.cgColor)
            context.fillEllipse(in: rect)
            if pressed.map(\.close) == true { context.fillEllipse(in: rect) }
        }
        let c = CGPoint(x: rect.midX, y: rect.midY), r: CGFloat = 3.5
        context.setStrokeColor((active ? Tokens.ink : Tokens.ink3).cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: c.x - r, y: c.y - r))
        context.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
        context.move(to: CGPoint(x: c.x - r, y: c.y + r))
        context.addLine(to: CGPoint(x: c.x + r, y: c.y - r))
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Pointer

    private var activeRect: NSRect { isOpen ? panelRect : restZone }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !items.isEmpty, let superview else { return nil }
        return activeRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        guard !items.isEmpty else { return }
        addCursorRect(activeRect, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)) }
    }

    /// Opens after the pointer has been on the dots a moment, closes a moment after it leaves.
    override func mouseMoved(with event: NSEvent) {
        guard !items.isEmpty else { return }
        pointer = convert(event.locationInWindow, from: nil)
        if isOpen {
            if panelRect.insetBy(dx: -6, dy: -6).contains(pointer) {
                closeTimer?.invalidate()
                closeTimer = nil
                hover(pointer)
            } else if closeTimer == nil {
                closeTimer = after(0.14) { $0.closeRail() }
            }
        } else if restZone.contains(pointer) {
            if openTimer == nil { openTimer = after(0.07) { $0.openRail(at: $0.pointer) } }
        } else {
            openTimer?.invalidate()
            openTimer = nil
        }
    }

    private func after(_ seconds: Double, _ action: @escaping (DocumentRail) -> Void) -> Timer {
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
        if isOpen, closeTimer == nil { closeTimer = after(0.14) { $0.closeRail() } }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard isOpen, let i = rowIndex(p) else { return }
        pressed = (i, closeRect(i).insetBy(dx: -3, dy: -3).contains(p))
        ink.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { pressed = nil }
        // A click on the resting dots opens at once.
        guard isOpen else { return openRail(at: p) }
        guard let press = pressed, rowIndex(p) == press.index else { return ink.needsDisplay = true }
        if press.close {
            guard closeRect(press.index).insetBy(dx: -3, dy: -3).contains(p) else { return ink.needsDisplay = true }
            onClose?(press.index)
        } else {
            // The list stays until the pointer leaves it, for a look at the next one.
            onSelect?(press.index)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isOpen, maxScroll > 0 else { return onScroll?(event) ?? () }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.row
        scroll = min(max(scroll - delta, 0), maxScroll)
        hover(convert(event.locationInWindow, from: nil))
        redraw()
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        setAccessibilityChildren(items.indices.map { i in
            let element = RailRowElement { [weak self] in self?.onSelect?(i) }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(items[i].title)
            if items[i].current { element.setAccessibilityValue(String(localized: "Shown")) }
            element.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: String(localized: "Close")) { [weak self] in
                self?.onClose?(i)
                return true
            }])
            return element
        })
    }

    // MARK: Snapshots

    private var isFrozen = false

    /// Opened on document `index` with the pointer on its row (and on its close button), the
    /// motion run for `seconds` in 120 Hz steps.
    func hoverForSnapshot(_ index: Int, onClose: Bool, seconds: CGFloat) {
        guard items.indices.contains(index) else { return }
        isFrozen = true
        clock.stop()
        let rest = NSPoint(x: Self.dotX, y: restY(index))
        openRail(at: rest)
        pointer = onClose ? NSPoint(x: closeRect(index).midX, y: rowY(index)) : NSPoint(x: Self.textLeft + 10, y: rowY(index))
        hover(pointer)
        for _ in 0..<Int((seconds * 120).rounded()) { _ = advance(1.0 / 120) }
        redraw()
    }
}

/// The rail's drawing layer, above its surface.
private final class RailInk: NSView {
    var drawer: ((CGContext) -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawer?(context)
    }
}

private final class RailRowElement: NSAccessibilityElement {
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
