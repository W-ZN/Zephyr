import AppKit

/// Design tokens for everything around the text (design §8.2): three solid surfaces, three ink
/// levels, one accent. They are views of the active theme (`Palette`), the same palette the canvas
/// draws with, so chrome and canvas always match. No translucent materials anywhere.
public enum Tokens {
    public static let canvas = Palette.color(.background)
    public static let sidebar = Palette.color(.sidebar)
    public static let raised = Palette.color(.raised)
    public static let sunken = Palette.color(.sunken)
    public static let ink = Palette.color(.text)
    public static let ink2 = Palette.color(.muted)
    public static let ink3 = Palette.color(.faint)
    public static let line = Palette.color(.line)
    public static let hover = Palette.color(.hover)
    public static let pressed = Palette.color(.pressed)
    public static let accent = Palette.color(.accent)
    public static let accentSoft = Palette.color(.accentSoft)
    /// Text selection on the canvas.
    public static let selection = Palette.color(.selection)
    public static let onAccent = Palette.color(.onAccent)
    public static let danger = Palette.color(.danger)
    public static let added = Palette.color(.added)
    public static let removed = Palette.color(.removed)

    public enum Radius {
        public static let control: CGFloat = 6
        public static let menu: CGFloat = 10
        public static let panel: CGFloat = 12
    }

    public static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    /// A symbol image tinted with a fixed color (`contentTintColor` is not honored everywhere).
    public static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

// MARK: - Focus

/// Focus rings only for keyboard focus, like the web's `:focus-visible` (design §8.2): a click
/// already shows where the user is, a ring would only flash and vanish; Tab and the arrow keys
/// need it. Custom controls ask `isKeyboard` before drawing theirs.
public enum FocusRing {
    public private(set) static var isKeyboard = false
    private static var monitor: Any?

    /// Called once at launch: the last input decides.
    public static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            let keyboard = event.type == .keyDown && (event.keyCode == 48 || event.specialKey != nil)
            if event.type != .keyDown || keyboard, keyboard != isKeyboard {
                isKeyboard = keyboard
                event.window?.firstResponder.flatMap { $0 as? NSView }.map { $0.noteFocusRingMaskChanged(); $0.needsDisplay = true }
            }
            return event
        }
    }
}

// MARK: - Surfaces

/// A solid rounded surface with an optional hairline border and soft shadow.
open class SurfaceView: NSView {
    public var fill: NSColor? { didSet { needsDisplay = true } }
    public var border: NSColor? { didSet { needsDisplay = true } }
    public var radius: CGFloat { didSet { needsDisplay = true } }
    /// Raised surfaces (cards, floating panels) cast a soft shadow.
    public var elevated = false { didSet { needsDisplay = true } }
    /// The pointer over the surface, for one laid over the text (a panel, a card): the text's
    /// I-beam must not show through it. What it holds (fields, links) sets its own inside.
    public var pointer: NSCursor? { didSet { window?.invalidateCursorRects(for: self) } }

    open override func resetCursorRects() {
        if let pointer { addCursorRect(bounds, cursor: pointer) }
    }

    public init(fill: NSColor? = Tokens.raised, border: NSColor? = Tokens.line, radius: CGFloat = Tokens.Radius.panel, elevated: Bool = false) {
        self.fill = fill
        self.border = border
        self.radius = radius
        self.elevated = elevated
        super.init(frame: .zero)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) { fatalError() }

    open override var wantsUpdateLayer: Bool { true }

    open override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fill?.cgColor
            layer.borderColor = border?.cgColor
            layer.shadowColor = NSColor.black.cgColor
        }
        layer.borderWidth = border == nil ? 0 : 1
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        let dark = effectiveAppearance.isDark
        layer.shadowOpacity = elevated ? (dark ? 0.45 : 0.12) : 0
        layer.shadowRadius = elevated ? 14 : 0
        layer.shadowOffset = CGSize(width: 0, height: -4)
    }

    open override func layout() {
        super.layout()
        if elevated { layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil) }
    }
}

// MARK: - Buttons

/// A button drawn from the tokens: primary (accent), secondary (outlined), plain (hover only), icon,
/// field: text that edits in place, which shows a field's outline and I-beam under the pointer,
/// text: never a fill, only its ink darkens under the pointer (chrome that sits in the window), and
/// heading: a section title that opens and closes, always in the text's ink; only its symbol (the
/// disclosure chevron) is quiet at rest and darkens under the pointer.
open class FlatButton: NSButton {
    public enum Style { case primary, secondary, plain, icon, field, text, heading }
    public var style: Style { didSet { restyle() } }
    public var symbolName: String? { didSet { restyle() } }
    /// The symbol's point size, when not the style's own, and whether it follows the title (a
    /// small chevron for a menu).
    public var symbolSize: CGFloat? { didSet { restyle() } }
    public var trailingSymbol = false { didSet { setTitle(title) } }
    /// Plain buttons that stand for the current item (a breadcrumb's file, a selected tab).
    public var emphasized = false { didSet { restyle() } }
    public var titleFont = Tokens.font(13, .medium) { didSet { restyle() } }
    private var hovering: Bool {
        window.map { NSApp.isActive && !isHiddenOrHasHiddenAncestor && visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }
    private var handler: (() -> Void)?

    public init(title: String = "", symbol: String? = nil, style: Style = .secondary, handler: (() -> Void)? = nil) {
        self.style = style
        symbolName = symbol
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        self.title = title
        imagePosition = title.isEmpty ? .imageOnly : trailingSymbol ? .imageTrailing : .imageLeading
        imageHugsTitle = true
        if handler != nil {
            target = self
            action = #selector(run)
        }
        restyle()
    }

    public required init?(coder: NSCoder) { fatalError() }

    @objc private func run() { handler?() }

    public func setTitle(_ title: String) {
        self.title = title
        imagePosition = title.isEmpty ? .imageOnly : trailingSymbol ? .imageTrailing : .imageLeading
        restyle()
    }

    private var foreground: NSColor {
        if !isEnabled { return Tokens.ink3 }
        switch style {
        case .primary: return Tokens.onAccent
        case .secondary: return Tokens.ink
        case .plain, .icon, .field: return emphasized ? Tokens.ink : Tokens.ink2
        case .text: return emphasized || hovering || cell?.isHighlighted == true ? Tokens.ink : Tokens.ink2
        case .heading: return Tokens.ink
        }
    }

    private var symbolColor: NSColor {
        guard style == .heading, isEnabled else { return foreground }
        return hovering || cell?.isHighlighted == true ? Tokens.ink : Tokens.ink3
    }

    /// Text and heading buttons bake the pointer state into their title and symbol colors.
    private var colorFollowsPointer: Bool { style == .text || style == .heading }

    private func restyle() {
        let color = foreground
        attributedTitle = NSAttributedString(string: title, attributes: [.font: emphasized && style != .icon ? Tokens.font(13, .semibold) : titleFont, .foregroundColor: color])
        image = symbolName.flatMap { Tokens.symbol($0, size: symbolSize ?? (style == .icon ? 14 : 12), weight: .medium, color: symbolColor) }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    open override var isEnabled: Bool { didSet { restyle() } }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    open override var intrinsicContentSize: NSSize {
        let inner = super.intrinsicContentSize
        switch style {
        case .icon: return NSSize(width: 28, height: 28)
        default: return NSSize(width: ceil(inner.width) + (title.isEmpty ? 12 : 20), height: 28)
        }
    }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
        // Scrolling or opening a disclosure can move this button without a mouseExited event.
        // Draw from the current pointer position instead of retaining the old hover state.
        colorFollowsPointer ? restyle() : (needsDisplay = true)
    }

    open override func mouseEntered(with event: NSEvent) { colorFollowsPointer ? restyle() : (needsDisplay = true) }
    open override func mouseExited(with event: NSEvent) { colorFollowsPointer ? restyle() : (needsDisplay = true) }

    /// Focus comes from the keyboard (Tab, with keyboard navigation on), never from a click: a
    /// click acts and leaves the focus where it was, the text, as a button on a web page does.
    /// (With keyboard navigation on, AppKit otherwise hands a clicked button the focus.)
    open override var acceptsFirstResponder: Bool { FocusRing.isKeyboard && super.acceptsFirstResponder }

    // The system focus ring for keyboard focus, in the button's rounded shape.
    open override var focusRingMaskBounds: NSRect { bounds }
    open override func drawFocusRingMask() {
        guard FocusRing.isKeyboard else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control).fill()
    }

    open override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control)
        switch style {
        case .primary:
            (isEnabled ? Tokens.accent : Tokens.ink3).setFill()
            path.fill()
            if pressed || hovering {
                (pressed ? NSColor.black.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.07)).setFill()
                path.fill()
            }
        case .secondary:
            Tokens.raised.setFill()
            path.fill()
            if isEnabled, pressed || hovering {
                (pressed ? Tokens.pressed : Tokens.hover).setFill()
                path.fill()
            }
            Tokens.line.setStroke()
            path.lineWidth = 1
            path.stroke()
        case .plain, .icon:
            if isEnabled, pressed || hovering {
                (pressed ? Tokens.pressed : Tokens.hover).setFill()
                path.fill()
            }
        case .field:
            if isEnabled, pressed || hovering {
                Tokens.raised.setFill()
                path.fill()
                Tokens.line.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        case .text, .heading:
            break
        }
        super.draw(dirtyRect)
    }

    open override func resetCursorRects() {
        if style == .field { addCursorRect(bounds, cursor: .iBeam) }
    }
}

/// A button of the window's chrome (the top bar), drawn entirely by Zephyr: nothing behind it at
/// rest, a rounded fill while the pointer is on it, darker while pressed. Not an `NSButton`: in
/// the title-bar strip; its surface, icon and text are all drawn here. An icon, a
/// title, or both (the icon after the title for a menu's chevron); `target` nil sends `action`
/// up the responder chain. Tab reaches it with keyboard navigation on; Space or Return presses it.
public final class ChromeButton: NSControl {
    public private(set) var title: String
    public var symbolName: String? { didSet { changed() } }
    /// The symbol's point size, when not the default (14 alone, 12 beside a title).
    public var symbolSize: CGFloat? { didSet { changed() } }
    public var trailingSymbol = false { didSet { changed() } }
    public var titleFont = Tokens.font(13, .medium) { didSet { changed() } }
    /// Ink instead of secondary ink: the button stands for something that is on.
    public var emphasized = false { didSet { changed() } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    public init(title: String = "", symbol: String? = nil) {
        self.title = title
        symbolName = symbol
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        if !title.isEmpty { setAccessibilityLabel(title) }
        // Leaving the app ends the hover; no exit event comes for it.
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned), name: NSApplication.didResignActiveNotification, object: nil)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public func setTitle(_ title: String) {
        self.title = title
        changed()
    }

    private func changed() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    @objc private func appResigned() { hovering = false; pressed = false }

    private var color: NSColor { emphasized ? Tokens.ink : Tokens.ink2 }
    private var text: NSAttributedString? {
        title.isEmpty ? nil : NSAttributedString(string: title, attributes: [.font: emphasized ? Tokens.font(13, .semibold) : titleFont, .foregroundColor: color])
    }
    private var image: NSImage? { symbolName.flatMap { Tokens.symbol($0, size: symbolSize ?? (title.isEmpty ? 14 : 12), weight: .medium, color: color) } }

    public override var intrinsicContentSize: NSSize {
        guard let text else { return NSSize(width: 28, height: 28) }
        let image = self.image
        return NSSize(width: ceil(text.size().width) + (image.map { $0.size.width + 4 } ?? 0) + 20, height: 28)
    }

    public override func draw(_ dirtyRect: NSRect) {
        // A layer-backed redraw must also erase the previous hover or pressed fill.
        Tokens.canvas.setFill()
        bounds.fill()
        if pressed || hovering {
            (pressed ? Tokens.pressed : Tokens.hover).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control).fill()
        }
        let text = self.text, image = self.image
        let textSize = text.map { NSSize(width: ceil($0.size().width), height: ceil($0.size().height)) } ?? .zero
        let gap: CGFloat = text != nil && image != nil ? 4 : 0
        var x = floor((bounds.width - textSize.width - (image?.size.width ?? 0) - gap) / 2)
        func drawImage() {
            guard let image else { return }
            image.draw(in: NSRect(x: x, y: floor(bounds.midY - image.size.height / 2), width: image.size.width, height: image.size.height))
            x += image.size.width + gap
        }
        func drawText() {
            guard let text else { return }
            text.draw(at: NSPoint(x: x, y: floor(bounds.midY - textSize.height / 2)))
            x += textSize.width + gap
        }
        if trailingSymbol { drawText(); drawImage() } else { drawImage(); drawText() }
    }

    // MARK: Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        }
    }

    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    /// Like a toolbar's buttons, it acts on the click that brings its window forward, and a press
    /// on it never starts dragging the window (it sits in the title-bar strip).
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func mouseDown(with event: NSEvent) { pressed = true }
    public override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    public override func mouseUp(with event: NSEvent) {
        let activate = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if activate { perform() }
    }

    private func perform() {
        guard let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    // MARK: Keyboard and accessibility

    /// Focus only from the keyboard, as for `FlatButton`; a click leaves it where it was.
    public override var acceptsFirstResponder: Bool { FocusRing.isKeyboard && NSApp.isFullKeyboardAccessEnabled }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() {
        guard FocusRing.isKeyboard else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control).fill()
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 { perform() } else { super.keyDown(with: event) }
    }

    public override func accessibilityPerformPress() -> Bool {
        perform()
        return true
    }
}

// MARK: - Choices

/// Segments in a sunken track; the chosen one sits on a raised card (design §8.2). No outline:
/// the track's tint is the boundary, as in a web segmented control.
public final class SegmentedPicker: NSControl {
    public var items: [String] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; rebuildAccessibility() } }
    public var selectedIndex = 0 { didSet { needsDisplay = true; rebuildAccessibility() } }
    public var onChange: ((Int) -> Void)?
    public var segmentFont = Tokens.font(12.5, .medium)
    private var elements: [NSAccessibilityElement] = []
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    public init(items: [String], onChange: ((Int) -> Void)? = nil) {
        self.items = items
        self.onChange = onChange
        super.init(frame: .zero)
        rebuildAccessibility()
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        let widest = items.map { ceil(($0 as NSString).size(withAttributes: [.font: segmentFont]).width) }.max() ?? 0
        return NSSize(width: CGFloat(items.count) * (widest + 24) + 6, height: 28)
    }

    private func segmentRect(_ i: Int) -> NSRect {
        let w = (bounds.width - 6) / CGFloat(max(1, items.count))
        return NSRect(x: 3 + CGFloat(i) * w, y: 3, width: w, height: bounds.height - 6)
    }

    public override func draw(_ dirtyRect: NSRect) {
        // A translucent track reads as sunken on any surface (withAlphaComponent would replace the
        // token's own alpha, not scale it).
        Tokens.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Tokens.Radius.control + 2, yRadius: Tokens.Radius.control + 2).fill()
        for (i, title) in items.enumerated() {
            let r = segmentRect(i)
            let selected = i == selectedIndex
            let card = NSBezierPath(roundedRect: r, xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control)
            if selected {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(effectiveAppearance.isDark ? 0.45 : 0.1)
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                Tokens.raised.setFill()
                card.fill()
                NSGraphicsContext.restoreGraphicsState()
            } else if hovered == i, isEnabled {
                Tokens.hover.setFill()
                card.fill()
            }
            let text = NSAttributedString(string: title, attributes: [.font: segmentFont, .foregroundColor: selected ? Tokens.ink : Tokens.ink2])
            let size = text.size()
            text.draw(with: NSRect(x: r.midX - min(size.width, r.width - 8) / 2, y: r.midY - size.height / 2, width: min(size.width, r.width - 8), height: size.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if window?.firstResponder === self, FocusRing.isKeyboard {
            Tokens.accent.setStroke()
            let ring = NSBezierPath(roundedRect: segmentRect(selectedIndex).insetBy(dx: -1, dy: -1), xRadius: Tokens.Radius.control + 1, yRadius: Tokens.Radius.control + 1)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hovered = items.indices.first { segmentRect($0).contains(p) }
    }

    public override func mouseExited(with event: NSEvent) { hovered = nil }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let i = items.indices.first(where: { segmentRect($0).contains(p) }) { choose(i) }
    }

    private func choose(_ i: Int) {
        guard i != selectedIndex, items.indices.contains(i) else { return }
        selectedIndex = i
        onChange?(i)
        sendAction(action, to: target)
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    public override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?: choose(selectedIndex - 1)
        case .rightArrow?: choose(selectedIndex + 1)
        default: super.keyDown(with: event)
        }
    }

    // Each segment is a radio button for VoiceOver.
    private func rebuildAccessibility() {
        elements = items.enumerated().map { i, title in
            let e = SegmentElement()
            e.press = { [weak self] in self?.choose(i) }
            e.setAccessibilityRole(.radioButton)
            e.setAccessibilityLabel(title)
            e.setAccessibilityValue(i == selectedIndex ? 1 : 0)
            e.setAccessibilityEnabled(isEnabled)
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(segmentRect(i))
            return e
        }
    }

    public override func layout() {
        super.layout()
        rebuildAccessibility()
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
    public override func accessibilityChildren() -> [Any]? { elements }
}

private final class SegmentElement: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        press?()
        return true
    }
}

/// A pop-up button drawn as an outlined field with a chevron; the list is still the system menu.
public final class FlatPopUpButton: NSPopUpButton {
    private var hovering = false { didSet { needsDisplay = true } }

    public init() {
        super.init(frame: .zero, pullsDown: false)
        isBordered = false
    }

    public override var acceptsFirstResponder: Bool { FocusRing.isKeyboard && super.acceptsFirstResponder }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() {
        guard FocusRing.isKeyboard else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control).fill()
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        let font = Tokens.font(13)
        let widest = itemTitles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 40
        return NSSize(width: widest + 40, height: 28)
    }

    public override func addItem(withTitle title: String) {
        super.addItem(withTitle: title)
        invalidateIntrinsicContentSize()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }

    public override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control)
        Tokens.raised.setFill()
        path.fill()
        if hovering, isEnabled {
            Tokens.hover.setFill()
            path.fill()
        }
        Tokens.line.setStroke()
        path.stroke()
        let title = NSAttributedString(string: titleOfSelectedItem ?? "", attributes: [.font: Tokens.font(13), .foregroundColor: isEnabled ? Tokens.ink : Tokens.ink3])
        let size = title.size()
        title.draw(with: NSRect(x: 10, y: bounds.midY - size.height / 2, width: bounds.width - 34, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let chevron = Tokens.symbol("chevron.up.chevron.down", size: 9, weight: .semibold, color: Tokens.ink2) {
            chevron.draw(in: NSRect(x: bounds.maxX - 10 - chevron.size.width, y: bounds.midY - chevron.size.height / 2, width: chevron.size.width, height: chevron.size.height))
        }
    }
}

/// An on/off switch: accent track when on, a white knob (design §8.2).
public final class FlatToggle: NSControl {
    public var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } }
    public var onChange: ((Bool) -> Void)?

    public init(isOn: Bool = false, onChange: ((Bool) -> Void)? = nil) {
        self.isOn = isOn
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 20))
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(isOn ? 1 : 0)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 20) }
    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    public override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 20) / 2, width: 34, height: 20)
        let path = NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10)
        (isOn ? Tokens.accent : Tokens.pressed).setFill()
        path.fill()
        if !isOn {
            Tokens.line.setStroke()
            path.stroke()
        }
        let knob = NSRect(x: isOn ? track.maxX - 18 : track.minX + 2, y: track.minY + 2, width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self, FocusRing.isKeyboard {
            Tokens.accent.withAlphaComponent(0.5).setStroke()
            let ring = NSBezierPath(roundedRect: track.insetBy(dx: -1.5, dy: -1.5), xRadius: 11.5, yRadius: 11.5)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        toggle()
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { toggle() } else { super.keyDown(with: event) }
    }

    public override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    private func toggle() {
        isOn.toggle()
        onChange?(isOn)
        sendAction(action, to: target)
    }
}

/// A slider with a thin track, accent fill up to the knob and a white round knob.
public final class FlatSliderCell: NSSliderCell {
    public override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        Tokens.pressed.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        let knob = knobRect(flipped: flipped)
        var filled = bar
        filled.size.width = max(0, knob.midX - bar.minX)
        (isEnabled ? Tokens.accent : Tokens.ink3).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }

    public override func drawKnob(_ knobRect: NSRect) {
        let d: CGFloat = 16
        let r = NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSGraphicsContext.restoreGraphicsState()
        Tokens.line.setStroke()
        NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25)).stroke()
    }

    public override func drawTickMarks() {}
}

public extension NSSlider {
    /// A slider using `FlatSliderCell`.
    static func flat(value: Double, min: Double, max: Double) -> NSSlider {
        let slider = NSSlider()
        slider.cell = FlatSliderCell()
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = value
        slider.isContinuous = true
        return slider
    }
}

// MARK: - Fields and rows

/// A borderless text field inside an outlined box whose border turns accent while editing.
public final class FieldBox: SurfaceView {
    public let field: NSTextField
    private let clear = NSButton()
    private var fieldTrailing: NSLayoutConstraint!

    /// `symbol` leads the field (a magnifying glass for search); a search field also gets a clear
    /// button while it holds text.
    public init(field: NSTextField = NSTextField(), placeholder: String = "", symbol: String? = nil) {
        self.field = field
        super.init(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.control)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Tokens.font(13)
        field.textColor = Tokens.ink
        field.placeholderString = placeholder
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        var leading = field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        if let symbol, let image = Tokens.symbol(symbol, size: 12, weight: .medium, color: Tokens.ink3) {
            let icon = NSImageView(image: image)
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9), icon.centerYAnchor.constraint(equalTo: centerYAnchor)])
            leading = field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
            // Tinted as a template: a palette of one color fills the cross in too.
            clear.image = Tokens.symbol("xmark.circle.fill", size: 12)
            clear.contentTintColor = Tokens.ink3
            clear.isBordered = false
            clear.imagePosition = .imageOnly
            clear.target = self
            clear.action = #selector(clearText)
            clear.isHidden = true
            clear.setAccessibilityLabel(String(localized: "Clear"))
            clear.translatesAutoresizingMaskIntoConstraints = false
            addSubview(clear)
            NSLayoutConstraint.activate([clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7), clear.centerYAnchor.constraint(equalTo: centerYAnchor)])
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSControl.textDidChangeNotification, object: field)
        }
        fieldTrailing = field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: symbol == nil ? -8 : -26)
        NSLayoutConstraint.activate([
            leading,
            fieldTrailing,
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(began), name: NSControl.textDidBeginEditingNotification, object: field)
        NotificationCenter.default.addObserver(self, selector: #selector(ended), name: NSControl.textDidEndEditingNotification, object: field)
    }

    public required init?(coder: NSCoder) { fatalError() }

    /// No box at all, focused or not: the field sits on its surface (the sidebar's search, an
    /// entry at the end of a block).
    public var isQuiet = false {
        didSet {
            fill = isQuiet ? nil : Tokens.raised
            border = isQuiet ? nil : Tokens.line
        }
    }

    // Focus shows as a firmer neutral outline: no blue ring around a field the reader just clicked.
    @objc private func began() { if !isQuiet { border = Tokens.ink3 } }
    @objc private func ended() { if !isQuiet { border = Tokens.line } }
    @objc private func changed() { clear.isHidden = field.stringValue.isEmpty }

    /// Shows or hides the clear button after the text was set in code.
    public func textDidChangeProgrammatically() { changed() }

    /// A control at the field's trailing end, inside the box (a menu of suggestions).
    public func setAccessory(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        fieldTrailing.isActive = false
        fieldTrailing = field.trailingAnchor.constraint(equalTo: view.leadingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            fieldTrailing,
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func clearText() {
        field.stringValue = ""
        changed()
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        window?.makeFirstResponder(field)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }
}

/// Table rows with rounded hover and selection backgrounds instead of the system highlight.
public final class FlatRowView: NSTableRowView {
    private var hovering = false { didSet { needsDisplay = true } }
    public var inset = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)

    public override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    private var shape: NSBezierPath {
        let r = NSRect(x: bounds.minX + inset.left, y: bounds.minY + inset.bottom, width: bounds.width - inset.left - inset.right, height: bounds.height - inset.top - inset.bottom)
        return NSBezierPath(roundedRect: r, xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control)
    }

    public override func drawBackground(in dirtyRect: NSRect) {
        guard hovering, !isSelected else { return }
        Tokens.hover.setFill()
        shape.fill()
    }

    public override func drawSelection(in dirtyRect: NSRect) {
        Tokens.accentSoft.setFill()
        shape.fill()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }
}

public extension NSTableView {
    /// A plain list on a solid background: no source-list material, custom rows.
    func flatten() {
        style = .plain
        backgroundColor = .clear
        gridStyleMask = []
        intercellSpacing = NSSize(width: 0, height: 0)
        focusRingType = .none
        selectionHighlightStyle = .regular
    }
}

/// Plain label text in the token colors.
public func flatLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = Tokens.ink, wraps: Bool = false) -> NSTextField {
    let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
    label.font = Tokens.font(size, weight)
    label.textColor = color
    if !wraps { label.lineBreakMode = .byTruncatingTail }
    return label
}

public extension NSMenu {
    /// Opens the menu just under `view`, like a web drop-down.
    func popUp(below view: NSView) {
        popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }
}

/// A card floating at a spot of a window, in place of a popover (design §8.2: a solid surface,
/// no popover material). It takes key focus and closes when it loses it, so clicking elsewhere
/// ends it the way a transient popover does.
public final class FloatingCard: NSPanel {
    private static var open: [FloatingCard] = []
    /// Off for snapshots of a window that is mostly off screen.
    public static var keepsOnScreen = true
    public var onClose: (() -> Void)?
    private var closed = false
    /// The view it opened from (`show(below:in:)`).
    private weak var anchor: NSView?
    /// The last card closed by a press on its own anchor, and when: that press was to close it.
    private static weak var closedAnchor: NSView?
    private static var closedAt: TimeInterval = 0

    public init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let surface = SurfaceView(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.menu)
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor), content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: surface.topAnchor), content.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        contentView = surface
    }

    public override var canBecomeKey: Bool { true }

    /// Below `rect` of `view`, or above it when there is more room there, always inside the
    /// screen's visible area; centered on `rect`, or sharing its trailing edge (controls at a
    /// window's right). A card taller or wider than that area is shrunk to it; its content
    /// gives way through lower-priority size constraints (the formula source scrolls, for one).
    public func show(below rect: NSRect, in view: NSView, alignment: NSLayoutConstraint.Attribute = .centerX) {
        guard let window = view.window, let surface = contentView else { return }
        anchor = view
        surface.layoutSubtreeIfNeeded()
        let fitting = surface.fittingSize
        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8) ?? window.frame
        let size = NSSize(width: min(fitting.width, visible.width), height: min(fitting.height, visible.height))
        let roomBelow = anchor.minY - 6 - visible.minY, roomAbove = visible.maxY - anchor.maxY - 6
        var origin = NSPoint(x: alignment == .trailing ? anchor.maxX - size.width : anchor.midX - size.width / 2,
                             y: roomBelow >= size.height || roomBelow >= roomAbove ? anchor.minY - 6 - size.height : anchor.maxY + 6)
        if Self.keepsOnScreen {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        let frame = NSRect(origin: origin, size: size)
        // Fades in, settling 4 pt toward where it opens from.
        setFrame(Self.animates ? frame.offsetBy(dx: 0, dy: origin.y < anchor.minY ? 4 : -4) : frame, display: true)
        alphaValue = Self.animates ? 0 : 1
        window.addChildWindow(self, ordered: .above)
        Self.open.append(self)
        makeKeyAndOrderFront(nil)
        guard Self.animates else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(frame, display: true)
        }
    }

    /// Motion for people who see it: not with Reduce Motion, nor in snapshots.
    static var animates: Bool { keepsOnScreen && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    public override func resignKey() {
        super.resignKey()
        if let anchor, let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === anchor.window,
           anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
            Self.closedAnchor = anchor
            Self.closedAt = event.timestamp
        }
        close()
    }

    /// Whether the click now ending began by closing the card that `anchor` opened. The press
    /// takes the focus from the card, which closes it; the control's action, on release, would
    /// open it again, so a second click could never close it. The control asks this first.
    public static func closed(byClickOn anchor: NSView) -> Bool {
        guard closedAnchor === anchor, let now = NSApp.currentEvent?.timestamp, now - closedAt < 1 else { return false }
        closedAnchor = nil
        return true
    }

    public override func close() {
        guard !closed else { return }
        closed = true
        onClose?()
        onClose = nil
        Self.open.removeAll { $0 === self }
        guard Self.animates, isVisible else {
            parent?.removeChildWindow(self)
            return super.close()
        }
        ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: {
            self.parent?.removeChildWindow(self)
            super.close()
        })
    }
}
