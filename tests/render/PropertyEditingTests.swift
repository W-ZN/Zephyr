import AppKit
import Foundation
import Testing
@testable import ZephyrRender

/// In-place property editing (design §6, §8): only the edited value's bytes change, as one edit;
/// Escape leaves the file alone; values that are not single-line scalars stay source-only.
@MainActor
@Suite struct PropertyEditingTests {
    let text = "---\ntitle: Old  # keep\ntags:\n  - a\ndraft:\n---\n\nBody\n"

    func editor() -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        editor.select(NSRange(location: (text as NSString).range(of: "Body").location, length: 0))
        draw(editor)
        return (editor, window)
    }

    func draw(_ editor: MarkdownEditor) {
        editor.layoutAll()
        let view = editor.blockCanvas.view
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
    }

    func center(of entry: Int, _ editor: MarkdownEditor) -> NSPoint {
        let rect = editor.frontMatterBox()!.valueRects[entry]
        return NSPoint(x: rect.minX + 4, y: rect.midY)
    }

    @Test func editsOnlyTheValue() {
        let (e, _) = editor()
        #expect(e.propertyEntry(at: center(of: 1, e)) == nil, "sequences stay source-only")
        let title = e.propertyEntry(at: center(of: 0, e))
        #expect(title == 0)
        e.beginPropertyEdit(0)
        #expect(e.propertyField?.stringValue == "Old")
        e.propertyField?.stringValue = "New: title"
        e.endPropertyEdit(commit: true)
        #expect(e.string == "---\ntitle: \"New: title\"  # keep\ntags:\n  - a\ndraft:\n---\n\nBody\n")
        #expect(e.propertyField == nil)
    }

    @Test func fillsAnEmptyValueAndCancels() {
        let (e, _) = editor()
        e.beginPropertyEdit(2)
        e.propertyField?.stringValue = "yes please"
        e.endPropertyEdit(commit: false)
        #expect(e.string == text, "Escape changes nothing")
        draw(e)
        e.beginPropertyEdit(2)
        e.propertyField?.stringValue = "false"
        e.endPropertyEdit(commit: true)
        #expect(e.string == "---\ntitle: Old  # keep\ntags:\n  - a\ndraft: false\n---\n\nBody\n")
    }
}
