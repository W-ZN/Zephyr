import AppKit
import Foundation
import Testing
@testable import ZephyrRender

/// A keystroke invalidates its presentation region and preserves layouts in untouched chunks.
@MainActor
@Suite struct RestyleTests {
    @Test func typingTouchesOnlyTheEditedSpot() {
        let sentence = "Zephyr 是一个 Markdown 编辑器，**粗体** 和 `code` 混排，公式 $x^2$ 也在行内。"
        let text = "# 标题\n\n" + String(repeating: sentence + "\n\n", count: 400) + "后面一段。\n"
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let canvas = editor.blockCanvas
        let last = canvas.units.unit(containing: (text as NSString).range(of: "后面一段").location)
        let layout = canvas.layout(last)
        editor.select(NSRange(location: 8, length: 0))
        editor.type("a")
        #expect(canvas.layout(last) === layout, "a distant unchanged paragraph retains its shaped lines")
    }

    @Test func rangesFollowEdits() {
        let edit = NSRange(location: 10, length: 3)  // 3 characters inserted at 10
        #expect(NSRange(location: 2, length: 5).shifted(byEdit: edit, delta: 3) == NSRange(location: 2, length: 5))
        #expect(NSRange(location: 10, length: 4).shifted(byEdit: edit, delta: 3) == NSRange(location: 13, length: 4))
        #expect(NSRange(location: 8, length: 4).shifted(byEdit: edit, delta: 3) == nil)
        #expect(NSRange(location: NSNotFound, length: 0).shifted(byEdit: edit, delta: 3) == nil)
    }
}

/// Presentation never changes the text (principle 1): what the canvas holds is exactly what was
/// decoded, and an edit changes exactly the edited characters (design §5 byte contract).
@MainActor
@Suite struct ByteContractTests {
    @Test(arguments: [
        "# Title\r\n\r\n**bold** and `code`\r\n- item\r\n",
        "mixed\nline\r\nendings\rhere\n",
        "e\u{301}cole NFD, \u{200B}zero width, \u{2028}line separator, \u{FEFF} inner BOM\n",
        "$x^2$ | a | b |\n|---|---|\n| 1 | 2 |\n\n$$\n\\int\n$$\nno final newline",
        "---\ntitle: 'x'\n---\n> quote\n>\n> - [ ] task\n",
    ])
    func textSurvivesStylingAndEditing(_ text: String) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        editor.layoutAll()
        #expect(Array(editor.string.utf16) == Array(text.utf16))
        let at = (text as NSString).length / 2
        editor.select(NSRange(location: at, length: 0))
        editor.blockCanvas.view.insertText("中", replacementRange: editor.blockCanvas.view.selectedRange())
        let expected = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "中")
        #expect(Array(editor.string.utf16) == Array(expected.utf16))
    }
}

@MainActor
@Suite struct BlockMoveTests {
    func editor(_ text: String, caret: String) -> MarkdownEditor {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        editor.select(NSRange(location: (text as NSString).range(of: caret).location, length: 0))
        return editor
    }

    @Test func movesParagraphsAndKeepsTheCaret() {
        let e = editor("# T\n\nfirst\n\nsecond\n\nthird\n", caret: "cond")
        e.moveBlock(up: true)
        #expect(e.string == "# T\n\nsecond\n\nfirst\n\nthird\n")
        #expect((e.string as NSString).substring(from: e.blockCanvas.view.selectedRange().location).hasPrefix("cond"))
        e.moveBlock(up: false)
        e.moveBlock(up: false)
        #expect(e.string == "# T\n\nfirst\n\nthird\n\nsecond\n")
        e.blockCanvas.view.undoManager?.undo()
    }

    @Test func movesListItemsWithinTheirList() {
        let e = editor("- a\n- b\n  - b1\n- c\n", caret: "b\n")
        e.moveBlock(up: false)
        #expect(e.string == "- a\n- c\n- b\n  - b1\n")
    }
}
