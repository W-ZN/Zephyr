import AppKit
import Foundation
import Testing
@testable import ZephyrRender

/// A code block's language (design §8.1): after its opening fence the languages that match what is
/// typed follow the caret, the language of the block above first; choosing one writes it and goes
/// to the first line of code.
@MainActor
@Suite struct CodeLanguageTests {
    func editor(_ text: String, caret: Int? = nil) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.makeFirstResponder(editor.focusView)
        editor.select(NSRange(location: caret ?? editor.length, length: 0))
        editor.layoutAll()
        return (editor, window)
    }

    func type(_ s: String, _ editor: MarkdownEditor) {
        for c in s { editor.blockCanvas.view.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    @Test func aNewBlockSuggestsTheLanguageAbove() {
        let text = "Intro.\n\n```stata\nreg y x\n```\n\nNext"
        let (e, window) = editor(text)
        defer { window.close() }
        e.pressReturn()
        e.pressReturn()
        type("/code", e)
        e.blockCanvas.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e.slashMenu == nil)
        #expect(e.languageMenu?.items.first?.hint == "stata", "the language of the block above comes first")
        e.blockCanvas.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e.string == text + "\n\n```stata\n\n```")
        #expect(e.selectedRange.location == (text as NSString).length + 11, "on the first line of code")
        #expect(e.languageMenu == nil)
    }

    @Test func typedLettersFilterAndAnOpenFenceIsClosed() {
        let (e, window) = editor("Notes.")
        defer { window.close() }
        e.pressReturn()
        e.pressReturn()
        type("```sw", e)
        #expect(e.languageMenu?.items.map(\.hint) == ["swift"])
        e.blockCanvas.view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(e.string == "Notes.\n\n```swift\n\n```")
        #expect(e.selectedRange.location == 17)
    }

    @Test func escapeKeepsTheListAwayOnThatLine() {
        let (e, window) = editor("```\ncode\n```\n", caret: 3)
        defer { window.close() }
        #expect(e.languageMenu != nil)
        e.blockCanvas.view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(e.languageMenu == nil)
        type("p", e)
        #expect(e.languageMenu == nil, "dismissed on this line")
        #expect(e.string == "```p\ncode\n```\n")
    }
}
