import AppKit
import Foundation
import Testing
@testable import ZephyrRender

/// Slash menu (design §8): opens only at the start of an empty line outside code, filters by what is
/// typed after the slash, and replaces `/query` with plain Markdown as one undoable edit.
@MainActor
@Suite struct SlashMenuTests {
    func editor(_ text: String, caretAfter needle: String) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        let at = NSMaxRange((text as NSString).range(of: needle))
        editor.select(NSRange(location: at, length: 0))
        return (editor, window)
    }

    func type(_ s: String, _ editor: MarkdownEditor) {
        editor.blockCanvas.view.insertText(s, replacementRange: editor.blockCanvas.view.selectedRange())
    }

    @Test func opensOnlyAtTheStartOfAnEmptyLine() {
        let (e, _) = editor("para\n\n```\ncode\n\n```\n", caretAfter: "para")
        e.pressReturn()
        e.pressReturn()
        type("/", e)
        #expect(e.slashMenu != nil)
        e.blockCanvas.view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(e.slashMenu == nil)
        #expect(e.string.hasPrefix("para\n\n/\n"), "Escape keeps what was typed")

        let (inText, _) = editor("para\n", caretAfter: "para")
        type("/", inText)
        #expect(inText.slashMenu == nil, "a slash after text is just a slash (paths, URLs)")
        let (between, _) = editor("a b\n", caretAfter: "a ")
        type("/", between)
        #expect(between.slashMenu == nil, "nor before text")

        let (inCode, _) = editor("```\ncode\n\n```\n", caretAfter: "code\n")
        type("/", inCode)
        #expect(inCode.slashMenu == nil, "never inside code")
    }

    /// After text and a space: what goes into the line; in a list item, also an item under it.
    @Test func inlineSlashInsertsInTheLineAndUnderTheItem() {
        let (p, _) = editor("Call ", caretAfter: "Call ")
        type("/", p)
        #expect(p.slashMenu?.items.contains { if case .child = $0.kind { true } else { false } } == false, "no child items outside a list")
        type("code", p)
        p.blockCanvas.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(p.string == "Call ``" && p.selectedRange.location == 6)

        let (t, _) = editor("- [ ] Write report\n- [ ] Send", caretAfter: "Write report")
        type(" ", t)
        type("/", t)
        type("子任务", t)
        #expect(t.slashMenu?.items.first.map(\.title) == String(localized: "Sub-task"))
        t.blockCanvas.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(t.string == "- [ ] Write report\n  - [ ] \n- [ ] Send", "\(t.string.debugDescription)")
        #expect(t.selectedRange.location == ("- [ ] Write report\n  - [ ] " as NSString).length)
        type("Outline", t)
        #expect(t.string == "- [ ] Write report\n  - [ ] Outline\n- [ ] Send")

        let (q, _) = editor("> 1. one", caretAfter: "one")
        type(" ", q)
        type("/", q)
        type("sub-i", q)
        q.blockCanvas.view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(q.string == "> 1. one\n>    - ", "under a numbered item in a quote: \(q.string.debugDescription)")
    }

    @Test func filtersAndInsertsMarkdown() {
        let (e, _) = editor("# T", caretAfter: "# T")
        e.pressReturn()
        e.pressReturn()
        type("/", e)
        type("tab", e)
        #expect(e.slashMenu?.items.map(\.keywords.first) == ["table"])
        e.blockCanvas.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e.slashMenu == nil)
        #expect(e.string == "# T\n\n|  |  |\n| --- | --- |\n|  |  |")
        #expect(e.blockCanvas.view.selectedRange().location == ("# T\n\n| " as NSString).length)
    }

    @Test func separatesBlocksThatWouldJoinTheLineAbove() {
        // `---` right under a paragraph would turn it into a heading.
        let (e, _) = editor("text\n\nnext\n", caretAfter: "text\n")
        e.select(NSRange(location: 4, length: 0))
        type("\n", e)
        type("/", e)
        type("div", e)
        e.blockCanvas.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e.string == "text\n\n---\n\n\nnext\n")
    }

    @Test func continuesQuotesAndLists() {
        let (q, _) = editor("> a", caretAfter: "> a")
        q.pressReturn()
        type("/", q)
        type("code", q)
        q.blockCanvas.view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(q.string == "> a\n> ```\n> \n> ```")

        let (l, _) = editor("- a\n- ", caretAfter: "- a\n- ")
        type("/", l)
        #expect(l.slashMenu?.items.contains { $0.keywords.first == "divider" } == false, "no divider inside a list item")
        type("math", l)
        l.blockCanvas.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(l.string == "- a\n- $$\n  \n  $$")
    }

    @Test func chineseInputSlashOpensItToo() {
        let (e, _) = editor("", caretAfter: "")
        type("、", e)
        #expect(e.slashMenu != nil)
        type("表", e)
        #expect(e.slashMenu?.items.first?.keywords.first == "table", "prefix matches rank first")
        type("格", e)
        #expect(e.slashMenu?.items.count == 1)
        type(" ", e)
        #expect(e.slashMenu == nil, "a space ends the query")
    }
}
