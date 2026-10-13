import AppKit
import Testing
import ZephyrCore
@testable import ZephyrRender

@MainActor
@Suite struct WidescreenLayoutTests {
    @Test(arguments: ThemeLibrary.presets.map(\.id))
    func themesKeepOneColumnOnWideAndNarrowWindows(_ theme: String) throws {
        let typography = Typography(AppearanceSettings(overrides: try #require(ThemeLibrary.preset(theme)).keys))
        #expect((896...960).contains(typography.readableWidth))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-width-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: NSSize(width: 1200, height: 240), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        try image.tiffRepresentation!.write(to: folder.appendingPathComponent("wide.png"))
        let text = "Body text.\n\n| Name | Value |\n|---|---|\n| A | B |\n\n![wide](wide.png)\n"
        let editor = MarkdownEditor(text: text, typography: typography, baseURL: folder, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 1728, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        defer { window.close() }
        for width: CGFloat in [1728, 900, 420] {
            window.setContentSize(NSSize(width: width, height: 900))
            window.orderBack(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            editor.layoutAll()
            let view = editor.blockCanvas.view
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
            let canvas = editor.blockCanvas
            if width == 1728 { #expect(canvas.columnWidth >= 896) }
            #expect(canvas.columnWidth <= width - BlockCanvas.minimumMargin * 2)
            let table = try #require(editor.componentBox(at: (text as NSString).range(of: "| Name").location) as? TableBox)
            let imageBox = try #require(editor.componentBox(at: (text as NSString).range(of: "![wide]").location) as? ImageBox)
            // A small table keeps its natural width (table.width = fit) inside the column.
            #expect(table.drawnRect.minX >= canvas.columnX - 1)
            #expect(table.drawnRect.maxX <= canvas.columnX + canvas.columnWidth + 1)
            #expect(imageBox.drawnRect.width <= canvas.columnWidth + 1)
            #expect(abs(imageBox.drawnRect.minX - canvas.columnX) <= 1)
        }
    }
}
