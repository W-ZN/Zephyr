import AppKit

/// The document scroller keeps AppKit's proportional knob, hit testing and accessibility behavior,
/// while making its visual weight suitable for a long reading surface.
public final class ReaderScroller: NSScroller {
    static let maximumKnobLength: CGFloat = 120
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var pressing = false { didSet { if pressing != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    public override class var isCompatibleWithOverlayScrollers: Bool { true }
    public override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 16 }

    private var isActive: Bool { hovering || pressing }

    /// Cap only an otherwise larger native knob. Keeping AppKit's own minimum target and using its
    /// own knob proportion means paging, dragging and accessibility all address the same geometry.
    public override var knobProportion: CGFloat {
        get { super.knobProportion }
        set {
            guard newValue < 1 else {
                super.knobProportion = newValue
                return
            }
            let slot = rect(for: .knobSlot)
            let cap = min(Self.maximumKnobLength, slot.height)
            guard cap > 0, slot.height > 0 else {
                super.knobProportion = newValue
                return
            }
            super.knobProportion = min(newValue, cap / slot.height)
        }
    }

    public override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard isActive || flag else { return }
        let track = slotRect.insetBy(dx: 5, dy: 1)
        guard !track.isEmpty else { return }
        Tokens.ink3.withAlphaComponent(pressing || flag ? 0.18 : 0.10).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.width / 2, yRadius: track.width / 2).fill()
    }

    public override func drawKnob() {
        let nativeKnob = rect(for: .knob)
        guard !nativeKnob.isEmpty else { return }
        let knob = Self.paintedKnobRect(in: nativeKnob, active: isActive)
        Tokens.ink2.withAlphaComponent(isActive ? 0.82 : 0.62).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }

    /// This is strictly inset inside AppKit's native knob rectangle: its position and length stay
    /// synchronized with AppKit's proportional scroll geometry and drag target.
    static func paintedKnobRect(in nativeKnob: NSRect, active: Bool) -> NSRect {
        let width = min(active ? 8 : 6, nativeKnob.width)
        let x = nativeKnob.midX - width / 2
        return NSRect(x: x, y: nativeKnob.minY + 1, width: width, height: max(0, nativeKnob.height - 2))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }

    public override func mouseDown(with event: NSEvent) {
        pressing = true
        super.mouseDown(with: event)
        pressing = false
    }
}
