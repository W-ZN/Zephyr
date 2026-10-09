import AppKit

/// A scroller for small floating surfaces (the sidebar): a 4 pt rounded knob in the quiet ink on
/// no track, 6 pt and a little darker under the pointer. It is an overlay scroller, so it shows
/// while scrolling and fades like the system's, but it never grows a track over the rows.
public final class ThinScroller: NSScroller {
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    public override class var isCompatibleWithOverlayScrollers: Bool { true }

    public override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 10 }

    public override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    public override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let width: CGFloat = hovering ? 6 : 4
        // Against the scroller's own edge: AppKit's knob rect for an overlay scroller is narrower.
        let bar = NSRect(x: bounds.maxX - width - 2, y: knob.minY + 2, width: width, height: max(0, knob.height - 4))
        Tokens.ink3.withAlphaComponent(hovering ? 0.8 : 0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        }
    }

    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }
}
