import AppKit

/// Zephyr's own motion (design §8.2): values pulled by springs and stepped by the display, in
/// place of fixed-duration curves. A spring has no duration; it heads for its target with the
/// speed it already has, so motion retargeted midway (a pointer moving on, a heading chosen during
/// a zoom) stays continuous. Each step is the exact solution of the damped oscillator, so where a
/// value is after some time does not depend on the frame rate: 60 or 120 Hz, or one long step in
/// a snapshot.
public struct Spring: Equatable {
    public var value: CGFloat
    public var target: CGFloat
    public var velocity: CGFloat = 0
    /// Seconds per undamped oscillation: how quick the spring is.
    public var response: CGFloat
    /// 1 arrives without overshoot; below 1 overshoots a little, then settles.
    public var damping: CGFloat

    public init(_ value: CGFloat = 0, response: CGFloat = 0.3, damping: CGFloat = 1) {
        self.value = value
        self.target = value
        self.response = response
        self.damping = damping
    }

    public var isSettled: Bool { value == target && velocity == 0 }

    /// Jumps to the target (Reduce Motion, first placement).
    public mutating func snap() {
        value = target
        velocity = 0
    }

    public mutating func snap(to value: CGFloat) {
        target = value
        snap()
    }

    public mutating func step(_ dt: CGFloat) {
        let x0 = value - target, v0 = velocity
        guard dt > 0, x0 != 0 || v0 != 0 else { return }
        let w = 2 * .pi / max(response, 0.001), z = min(max(damping, 0), 1)
        let x: CGFloat, v: CGFloat
        if z < 1 {
            let wd = w * (1 - z * z).squareRoot(), decay = exp(-z * w * dt)
            let b = (v0 + z * w * x0) / wd, c = cos(wd * dt), s = sin(wd * dt)
            x = decay * (x0 * c + b * s)
            v = decay * ((b * wd - z * w * x0) * c - (x0 * wd + z * w * b) * s)
        } else {
            let decay = exp(-w * dt), b = v0 + w * x0
            x = decay * (x0 + b * dt)
            v = decay * (v0 - w * b * dt)
        }
        // Rest once the remainder is below what a display can show.
        if abs(x) < 0.002, abs(v) < 0.02 { snap() } else { value = target + x; velocity = v }
    }
}

/// Calls `tick` with the seconds since the previous frame, once per display refresh, for as long
/// as it returns true; then the clock stops. Nothing runs while nothing moves (principle 5).
@MainActor public final class FrameClock: NSObject {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private let tick: (CGFloat) -> Bool

    public init(view: NSView, tick: @escaping (CGFloat) -> Bool) {
        self.view = view
        self.tick = tick
    }

    public var isRunning: Bool { link != nil }

    public func start() {
        guard link == nil, let view else { return }
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        last = 0
        self.link = link
    }

    public func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        // A stall (a long layout, a window drag) costs at most two frames of motion, not a jump.
        let dt = last == 0 ? link.duration : min(link.targetTimestamp - last, 1.0 / 30)
        last = link.targetTimestamp
        if !tick(CGFloat(dt)) { stop() }
    }
}
