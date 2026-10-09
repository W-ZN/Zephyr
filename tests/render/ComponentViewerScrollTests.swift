import AppKit
import Testing
@testable import ZephyrRender

@MainActor
struct ComponentViewerScrollTests {
    @Test func downGestureZoomsOutWithEitherNaturalScrollingPreference() {
        #expect(ComponentViewer.scrollFactor(deltaY: 20, precise: true, inverted: true) < 1)
        #expect(ComponentViewer.scrollFactor(deltaY: -20, precise: true, inverted: false) < 1)
        #expect(ComponentViewer.scrollFactor(deltaY: -2, precise: false, inverted: false) < 1)
    }

    @Test func upGestureZoomsInWithEitherNaturalScrollingPreference() {
        #expect(ComponentViewer.scrollFactor(deltaY: -20, precise: true, inverted: true) > 1)
        #expect(ComponentViewer.scrollFactor(deltaY: 20, precise: true, inverted: false) > 1)
        #expect(ComponentViewer.scrollFactor(deltaY: 2, precise: false, inverted: false) > 1)
        #expect(ComponentViewer.scrollFactor(deltaY: 0, precise: true, inverted: true) == 1)
    }
}
