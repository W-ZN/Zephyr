import AppKit
import Testing
import ZephyrCore
@testable import ZephyrRender

/// The space beside the reading column (design §7.4, §8, §8.1): a handle that never meets a
/// heading's revealed markers (they hang where the margin holds them and show inline where it
/// does not), a trailing outline boundary, and a leading inset that moves the column only as far
/// as it must.
@MainActor
@Suite struct MarginSlotTests {
    private func editor(_ text: String, width: CGFloat) -> (MarkdownEditor, NSWindow) {
        let typography = Typography(AppearanceSettings(overrides: ThemeLibrary.presets[0].keys))
        let editor = MarkdownEditor(text: text, typography: typography, baseURL: nil, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: width, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.contentView?.layoutSubtreeIfNeeded()
        editor.layoutAll()
        return (editor, window)
    }

    @Test(arguments: [420, 520, 920, 1400] as [CGFloat])
    func handleSitsLeftOfRevealedHeadingMarkers(_ width: CGFloat) throws {
        let text = "# One\n\nBody text.\n\n### Three levels\n\nMore.\n"
        let (editor, window) = editor(text, width: width)
        defer { window.close() }
        let canvas = editor.blockCanvas
        for heading in ["# One", "### Three levels"] {
            let location = (text as NSString).range(of: heading).location
            // The caret in the heading reveals its markers: in the margin of a wide window, inline
            // where the margin holds only the handle.
            editor.select(NSRange(location: location + heading.count - 2, length: 0))
            editor.layoutAll()
            let place = canvas.place(location)
            let hangs = width >= 1400
            #expect((place.layout.hang > 0) == hangs, "\(heading) at \(width) pt: markers \(hangs ? "hang" : "show inline")")
            let markersLeft = canvas.columnX + place.layout.xs[0]
            let top = canvas.top(of: place.unit)
            let point = NSPoint(x: canvas.columnX + 20, y: top + place.layout.tops[0] + place.layout.heights[0] / 2)
            let handle = try #require(editor.handleRect(at: point))
            #expect(handle.minX >= 0, "\(heading) at \(width) pt: the handle stays in the window")
            #expect(handle.maxX + 4 <= markersLeft, "\(heading) at \(width) pt: handle \(handle) overlaps markers from \(markersLeft)")
        }
    }

    /// Narrow or wide, the column keeps the same room on each side; the outline rail's room is
    /// taken from both sides alike.
    @Test(arguments: [420, 920, 1400] as [CGFloat])
    func marginsMatchOnBothSides(_ width: CGFloat) {
        let (editor, window) = editor("Text.\n", width: width)
        defer { window.close() }
        let bounds = editor.blockCanvas.view.bounds.width
        for reserved in [0, 70] as [CGFloat] {
            editor.blockCanvas.reservedMargin = reserved
            let (x, w) = editor.column
            let right = bounds - x - w
            #expect(abs(x - right) <= 1, "at \(width) pt, \(reserved) reserved: left \(x), right \(right)")
            #expect(min(x, right) >= max(BlockCanvas.minimumMargin, reserved))
        }
    }

    /// A compact outline takes room only at the actual trailing edge. The reader remains centered
    /// between the sidebar's scroll-view boundary and that edge, not between symmetric rail slots.
    @Test(arguments: [420, 920, 1400] as [CGFloat])
    func trailingInsetCentersInTheActualReaderArea(_ width: CGFloat) {
        let (editor, window) = editor("Text.\n", width: width)
        defer { window.close() }
        let canvas = editor.blockCanvas
        let viewportWidth = canvas.view.bounds.width
        for inset in [0, 58] as [CGFloat] {
            canvas.trailingInset = inset
            let column = editor.column
            #expect(abs(column.x + column.width / 2 - (viewportWidth - inset) / 2) <= 1, "at \(width) pt with \(inset) pt trailing: \(column)")
        }
    }

    @Test func columnCentersBetweenItsLeadingAndTrailingInsets() {
        for width: CGFloat in [1728, 900] {
            let (editor, window) = editor("Text.\n", width: width)
            defer { window.close() }
            let viewport = editor.blockCanvas.view.bounds.width
            let before = editor.column
            editor.blockCanvas.leadingInset = 58
            editor.blockCanvas.trailingInset = 58
            #expect(abs(editor.column.x + editor.column.width / 2 - before.x - before.width / 2) <= 1 && editor.column.width <= before.width, "equal insets keep the center at \(width) pt")
            editor.blockCanvas.trailingInset = 0
            let column = editor.column
            #expect(abs(column.x + column.width / 2 - (58 + viewport) / 2) <= 1, "a left rail moves the center at \(width) pt: \(column)")
            #expect(column.x >= 58 + BlockCanvas.minimumMargin)
            editor.blockCanvas.leadingInset = 0
            #expect(editor.column.x == before.x && editor.column.width == before.width)
        }
    }
}
