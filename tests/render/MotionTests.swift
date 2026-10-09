import CoreGraphics
import Testing
@testable import ZephyrRender

/// The spring behind Zephyr's motion (design §8.2): exact steps, so frame rate does not matter,
/// and retargeting keeps the motion continuous.
@Suite struct MotionTests {
    private func run(_ spring: Spring, for seconds: CGFloat, hz: CGFloat) -> Spring {
        var s = spring
        for _ in 0..<Int((seconds * hz).rounded()) { s.step(1 / hz) }
        return s
    }

    @Test(arguments: [(CGFloat(0.42), CGFloat(0.86)), (0.3, 1)])
    func sameMotionAtAnyFrameRate(response: CGFloat, damping: CGFloat) {
        var spring = Spring(0, response: response, damping: damping)
        spring.target = 1
        let at60 = run(spring, for: 0.2, hz: 60), at120 = run(spring, for: 0.2, hz: 120)
        var once = spring
        once.step(0.2)
        #expect(abs(at60.value - at120.value) < 1e-9)
        #expect(abs(at60.value - once.value) < 1e-9)
        #expect(abs(at60.velocity - once.velocity) < 1e-9)
    }

    @Test func criticalDampingNeverOvershoots() {
        var spring = Spring(0, response: 0.3, damping: 1)
        spring.target = 1
        var highest: CGFloat = 0
        for _ in 0..<240 {
            spring.step(1.0 / 120)
            highest = max(highest, spring.value)
        }
        #expect(highest <= 1)
        #expect(spring.isSettled && spring.value == 1)
    }

    @Test func lightDampingOvershootsALittleThenRests() {
        var spring = Spring(0, response: 0.42, damping: 0.86)
        spring.target = 1
        var highest: CGFloat = 0
        for _ in 0..<240 {
            spring.step(1.0 / 120)
            highest = max(highest, spring.value)
        }
        #expect(highest > 1 && highest < 1.03, "a slight settle, not a bounce")
        #expect(spring.isSettled, "at rest within two seconds, so the display link stops")
    }

    @Test func retargetingKeepsPositionAndSpeed() {
        var spring = Spring(0, response: 0.3, damping: 1)
        spring.target = 1
        spring = run(spring, for: 0.1, hz: 120)
        let (value, velocity) = (spring.value, spring.velocity)
        spring.target = 0
        #expect(spring.value == value && spring.velocity == velocity)
        spring.step(1.0 / 120)
        #expect(spring.value > value, "still moving the way it was going for a moment")
    }
}
