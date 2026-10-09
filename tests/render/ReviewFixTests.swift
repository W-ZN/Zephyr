import AppKit
import Foundation
import Testing
@testable import ZephyrRender
import ZephyrCore

/// Regressions from the round-28 code review: each test is one defect that was found and fixed.
@MainActor
@Suite struct ReviewFixTests {
    func open(_ text: String, caret: Int = 0) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: 0), size: NSSize(width: 900, height: 1600)), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.makeFirstResponder(editor.focusView)
        editor.select(NSRange(location: caret, length: 0))
        editor.layoutAll()
        return (editor, window)
    }

    /// Delete on an outlined table inside a quote removes the table's lines, not the quote.
    @Test func deletingAComponentKeepsItsContainer() {
        let text = "> before\n>\n> | a |\n> |---|\n> | 1 |\n>\n> after\n"
        let (e, window) = open(text)
        defer { window.close() }
        let canvas = e.blockCanvas
        canvas.view.moveDown(nil)
        #expect(canvas.focusedComponent != nil)
        canvas.view.deleteBackward(nil)
        #expect(e.string == "> before\n>\n>\n> after\n")
        canvas.view.undoManager?.undo()
        #expect(e.string == text)
    }

    /// A composition over a selection, then a change elsewhere from another app: committing still
    /// replaces exactly the selection.
    @Test func compositionSurvivesAnExternalChangeAfterIt() {
        let text = "ABCDEFGHIJKLMNO!\n\nb\n\nend\n"
        let (e, window) = open(text)
        defer { window.close() }
        let view = e.blockCanvas.view
        e.select(NSRange(location: 0, length: 15))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let end = (e.string as NSString).range(of: "end")
        e.applyExternal(TextPatch(range: end, replacement: "END"))
        view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(e.string == "你!\n\nb\n\nEND\n")
    }

    /// A merged change from another app keeps the writer's own undo steps where it did not reach.
    @Test func undoSurvivesAMergeElsewhere() {
        let (e, window) = open("first\n\nmiddle\n\nlast\n", caret: 5)
        defer { window.close() }
        e.type("!")
        let last = (e.string as NSString).range(of: "last")
        e.applyExternal(TextPatch(range: NSRange(location: last.location, length: 0), replacement: "very "))
        #expect(e.string == "first!\n\nmiddle\n\nvery last\n")
        e.blockCanvas.view.undoManager?.undo()
        #expect(e.string == "first\n\nmiddle\n\nvery last\n")
        // Before the merge, after it: the step maps across the inserted text.
        e.select(NSRange(location: (e.string as NSString).length - 1, length: 0))
        e.type("?")
        e.applyExternal(TextPatch(range: NSRange(location: 0, length: 0), replacement: "# "))
        e.blockCanvas.view.undoManager?.undo()
        #expect(e.string == "# first\n\nmiddle\n\nvery last\n")
    }

    /// Shift-Right from an outlined table selects it whole; it stays drawn.
    @Test func shiftArrowsTakeAComponentWhole() {
        let text = "Before.\n\n| a |\n|---|\n| 1 |\n\nAfter.\n"
        let (e, window) = open(text, caret: 2)
        defer { window.close() }
        let canvas = e.blockCanvas
        let ns = text as NSString
        let table = NSRange(location: ns.range(of: "| a").location, length: NSMaxRange(ns.range(of: "| 1 |")) - ns.range(of: "| a").location)
        canvas.view.moveDown(nil)
        canvas.view.moveRightAndModifySelection(nil)
        #expect(canvas.selection == table)
        #expect(canvas.place(table.location).layout.content.component is TableBox)
        e.select(NSRange(location: ns.range(of: "After.").location, length: 0))
        for _ in 0..<3 { canvas.view.moveLeftAndModifySelection(nil) }
        #expect(canvas.selection.location == table.location, "stepping back into it from below takes it whole")
    }

    /// ⌘/ keeps the caret on the visual line it was on at a wrap, and the blank lines Return made in
    /// plain text show as empty paragraphs back on the rendered canvas.
    @Test func plainTextRoundTripKeepsAffinityAndNewLines() {
        let long = String(repeating: "word ", count: 120)
        let (e, window) = open(long, caret: 0)
        defer { window.close() }
        let canvas = e.blockCanvas
        canvas.view.moveToEndOfLine(nil)
        let end = canvas.caretRect(at: canvas.selection.location)
        e.setPlainText(true)
        e.setPlainText(false)
        #expect(canvas.caretRect(at: canvas.selection.location).minY == end.minY, "still the end of the first visual line")

        let (p, w2) = open("A", caret: 1)
        defer { w2.close() }
        p.setPlainText(true)
        for _ in 0..<4 { p.pressReturn() }
        p.setPlainText(false)
        let rendered = p.blockCanvas
        let y = rendered.caretRect(at: p.selectedRange.location).minY
        #expect(p.string == "A\n\n\n\n")
        #expect(y - rendered.caretRect(at: 0).minY > 3 * 26, "three empty paragraphs and the caret's line, not one")
    }

    /// Changing a reference definition restyles the links that use it, wherever they are.
    @Test func definitionChangesReachTheirLinks() {
        let text = "[go][r]\n\n" + String(repeating: "Paragraph.\n\n", count: 40) + "[r]: https://a.example\n"
        let (e, window) = open(text)
        defer { window.close() }
        let presenter = e.blockCanvas.presenter!
        #expect(presenter.attribute(.zLink, at: 1) as? String == "https://a.example")
        let a = (e.string as NSString).range(of: "a.example")
        e.blockCanvas.select(NSRange(location: a.location, length: 1))
        e.type("b")
        e.layoutAll()
        #expect(presenter.attribute(.zLink, at: 1) as? String == "https://b.example")
    }

    /// Editing one cell and then clicking another starts editing that one.
    @Test func secondCellOpensAfterAnEdit() {
        let (e, window) = open("| a | b |\n|---|---|\n| 1 | 2 |\n\nafter\n")
        defer { window.close() }
        let box = e.componentBox(at: 0) as! TableBox
        e.beginCellEdit(box, row: 1, column: 0)
        e.cellField?.stringValue = "one"
        e.beginCellEdit(box, row: 1, column: 1)
        #expect(e.cellField?.stringValue == "2")
        #expect(e.string == "| a | b |\n|---|---|\n| one | 2 |\n\nafter\n")
        e.endCellEdit(commit: false)
    }

    /// Revealed, a fence keeps its band even when its info string is longer than the column.
    @Test func longFencesKeepTheirBand() {
        let text = "Intro.\n\n```" + String(repeating: "a", count: 200) + "\ncode\n```\n\nAfter.\n"
        let (e, window) = open(text)
        defer { window.close() }
        let canvas = e.blockCanvas
        let total = canvas.heights.total
        e.select(NSRange(location: (text as NSString).range(of: "code").location, length: 0))
        e.layoutAll()
        #expect(canvas.place((text as NSString).range(of: "```").location).layout.lines.count == 1)
        #expect(canvas.heights.total == total)
    }

    /// The handle of an indented code block selects its literal text, `# ` included.
    @Test func indentedCodeIsLiteralForTheHandle() {
        let text = "Intro.\n\n    # literal\n"
        let (e, window) = open(text)
        defer { window.close() }
        let at = (text as NSString).range(of: "    #").location
        let block = BlockMap.block(at: at, in: e.blocks(near: NSRange(location: at, length: 0)))!
        #expect(e.visibleText(of: block) == NSRange(location: at, length: 13))
    }

    /// In an empty document the first character does not move the caret.
    @Test func emptyDocumentStartsOnItsLine() {
        let (e, window) = open("")
        defer { window.close() }
        let before = e.blockCanvas.caretRect(at: 0)
        e.type("x")
        #expect(e.blockCanvas.caretRect(at: 1).minY == before.minY)
    }

    /// A click on a display formula's row, beside the formula too, is for its editor (no outline);
    /// committing keeps the caret where it was and the formula drawn.
    @Test func formulaRowsOpenTheirEditor() {
        let text = "Before.\n\n$$\nx^2\n$$\n\nAfter.\n"
        let (e, window) = open(text)
        defer { window.close() }
        let canvas = e.blockCanvas
        let at = (text as NSString).range(of: "$$").location
        if let rep = canvas.view.bitmapImageRepForCachingDisplay(in: canvas.view.bounds) { canvas.view.cacheDisplay(in: canvas.view.bounds, to: rep) }
        let box = try? #require(e.componentBox(at: at) as? MathBlockBox)
        guard let box else { return }
        let beside = NSPoint(x: canvas.columnX + 6, y: box.drawnRect.midY)
        #expect(!box.drawnRect.contains(beside))
        #expect(e.mathBlock(at: beside) === box, "beside the formula is the formula")
        #expect(e.clickedComponent(at: beside)?.location == at)
        e.commitMath(box, tex: "y^2", prefix: "")
        #expect(e.string == "Before.\n\n$$\ny^2\n$$\n\nAfter.\n")
        #expect(e.selectedRange.location == 0 && canvas.focusedComponent == nil)
        #expect(e.componentBox(at: at) is MathBlockBox, "still drawn")
    }
}
