import AppKit
import Testing
@testable import ZephyrRender

@MainActor
@Suite struct ChromeButtonTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func leavingErasesHoverAndPress(_ appearance: NSAppearance.Name) throws {
        let button = ChromeButton(symbol: "sidebar.leading")
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        button.appearance = NSAppearance(named: appearance)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 14, y: 14), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        func pixel() -> NSColor {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            button.effectiveAppearance.performAsCurrentDrawingAppearance { button.draw(button.bounds) }
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.colorAt(x: 3, y: 14)!.usingColorSpace(.deviceRGB)!
        }
        let rest = pixel()
        button.mouseEntered(with: event)
        let hover = pixel()
        #expect(abs(rest.redComponent - hover.redComponent) > 0.01)
        button.mouseDown(with: event)
        let press = pixel()
        #expect(abs(press.redComponent - hover.redComponent) > 0.01)
        button.mouseUp(with: event)
        button.mouseExited(with: event)
        let left = pixel()
        #expect(abs(left.redComponent - rest.redComponent) < 0.001)
        #expect(abs(left.greenComponent - rest.greenComponent) < 0.001)
        #expect(abs(left.blueComponent - rest.blueComponent) < 0.001)
    }

    @Test func clickStaysAControlAndReleaseOutsideCancels() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 100), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = ChromeButton(symbol: "sidebar.leading")
        button.frame = NSRect(x: 20, y: 20, width: 28, height: 28)
        window.contentView!.addSubview(button)
        let target = ClickTarget()
        button.target = target
        button.action = #selector(ClickTarget.clicked(_:))
        func event(_ type: NSEvent.EventType, point: NSPoint, count: Int = 1) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: button.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        }
        let inside = NSPoint(x: 14, y: 14)
        let frame = window.frame
        for count in [1, 2] {
            button.mouseDown(with: try event(.leftMouseDown, point: inside, count: count))
            button.mouseUp(with: try event(.leftMouseUp, point: inside, count: count))
        }
        #expect(target.count == 2)
        #expect(window.frame == frame)
        #expect(!button.mouseDownCanMoveWindow)
        button.mouseDown(with: try event(.leftMouseDown, point: inside))
        button.mouseUp(with: try event(.leftMouseUp, point: NSPoint(x: 60, y: 14)))
        #expect(target.count == 2)
    }
}

@MainActor
private final class ClickTarget: NSObject {
    var count = 0
    @objc func clicked(_ sender: Any?) { count += 1 }
}
