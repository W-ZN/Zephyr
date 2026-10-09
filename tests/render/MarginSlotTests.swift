import AppKit
import Testing
import ZephyrCore
@testable import ZephyrRender

/// The space beside the reading column (design §7.4, §8, §8.1): the same room on both sides, a
/// handle that never meets a heading's revealed markers (they hang where the margin holds them
/// and show inline where it does not), and an open sidebar that moves the column only as far as
/// it must.
@MainActor
@Suite struct MarginSlotTests {
    private func editor(_ text: String, width: CGFloat) -> (MarkdownEditor, NSWindow) {
        let typography = Typography(AppearanceState(active: ThemeLibrary.presets[0].id).settings())
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

    @Test func columnMovesClearOfAnOpenSidebarOnlyAsFarAsItMust() {
        let sidebar: CGFloat = 296
        // Wide: the column already clears the card and stays where it is, at its width.
        let (wide, wideWindow) = editor("Text.\n", width: 1728)
        defer { wideWindow.close() }
        let before = wide.column
        wide.blockCanvas.leadingInset = sidebar
        #expect(wide.column.x == before.x && wide.column.width == before.width)
        // Narrower: it moves just clear of the card and keeps a right margin, narrowing as needed.
        let (medium, mediumWindow) = editor("Text.\n", width: 1100)
        defer { mediumWindow.close() }
        let centered = medium.column
        medium.blockCanvas.leadingInset = sidebar
        #expect(medium.column.x == sidebar + BlockCanvas.minimumMargin + 5)
        #expect(medium.column.x + medium.column.width <= 1100 - BlockCanvas.minimumMargin)
        #expect(medium.column.x > centered.x)
        // Closing it puts the column back.
        medium.blockCanvas.leadingInset = 0
        #expect(medium.column.x == centered.x && medium.column.width == centered.width)
    }
}
