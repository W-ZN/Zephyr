import AppKit
import Foundation
import Testing
@testable import ZephyrRender
import ZephyrCore

/// Stable geometry on the rendered canvas (design §8.1): moving the caret never changes a line's
/// height; each Return and Backspace moves the caret by a regular step; block components are one
/// stop for the arrow keys; the handle selects what a block shows; ⌘/ switches to plain text.
@MainActor
@Suite struct EditingGeometryTests {
    func open(_ text: String, caret: Int? = nil, size: NSSize = NSSize(width: 900, height: 2400)) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: 0), size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.makeFirstResponder(editor.focusView)
        editor.select(NSRange(location: caret ?? editor.length, length: 0))
        editor.layoutAll()
        draw(editor)
        return (editor, window)
    }

    func draw(_ editor: MarkdownEditor) {
        let view = editor.focusView
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
    }

    func caretY(_ editor: MarkdownEditor) -> CGFloat { editor.blockCanvas.caretRect(at: editor.selectedRange.location).minY }

    /// Return after a paragraph: a line of it (line height and the line-break gap), then a new
    /// paragraph (the rest of the paragraph gap), then one empty paragraph per Return; Backspace
    /// walks the same steps back. After a heading every further Return is an empty paragraph.
    @Test(arguments: ["Hello", "# Title"])
    func returnStepsAreRegularAndBackspaceMirrors(_ start: String) {
        let (e, window) = open(start)
        defer { window.close() }
        var ys = [caretY(e)]
        for _ in 0..<4 {
            e.pressReturn()
            ys.append(caretY(e))
        }
        let steps = zip(ys.dropFirst(), ys).map { $0 - $1 }
        #expect(steps.allSatisfy { $0 > 0 }, "every Return moves the caret down: \(steps)")
        #expect(steps[2] == steps[3], "further Returns add one empty paragraph each: \(steps)")
        if start.hasPrefix("#") { #expect(steps[1] == steps[2], "after a heading the second Return is an empty paragraph too: \(steps)") }
        e.type("x")
        #expect(e.blockCanvas.caretRect(at: e.selectedRange.location - 1).minY == ys.last, "the first character sits where the caret was")
        e.blockCanvas.view.deleteBackward(nil)
        var back: [CGFloat] = []
        for _ in 0..<4 {
            let y = caretY(e)
            e.blockCanvas.view.deleteBackward(nil)
            back.append(y - caretY(e))
        }
        #expect(back == steps.reversed(), "Backspace takes the same steps back: \(back) for \(steps)")
        #expect(e.string == start)
    }

    static let rich = """
    # Title of the doc

    Paragraph one is here with some words.
    Second line after a line break.

    ## Section

    - item one
    - item two
      - nested item

    > quote line here

    ```swift
    let x = 1
    ```

    | a | b |
    |---|---|
    | 1 | 2 |

    $$
    x^2 + y^2
    $$

    Last paragraph of the doc.
    """

    /// Up and Down through every kind of block: nothing is laid out again, every step goes the
    /// way of the key, and the way back ends where it started.
    @Test func navigationNeverChangesTheLayout() {
        let (e, window) = open(Self.rich, caret: 4)
        defer { window.close() }
        let canvas = e.blockCanvas
        let total = canvas.heights.total
        var y = caretY(e), stops = 0
        func top() -> CGFloat { canvas.focusedComponent.map { canvas.lineBox(at: $0.location).minY } ?? caretY(e) }
        let ns = Self.rich as NSString
        let lastLine = ns.lineRange(for: NSRange(location: ns.length, length: 0))
        while ns.lineRange(for: canvas.selection) != lastLine || canvas.focusedComponent != nil, stops < 40 {
            canvas.view.moveDown(nil)
            stops += 1
            #expect(canvas.heights.total == total, "Down #\(stops) changed the layout")
            #expect(top() >= y, "Down #\(stops) went up")
            y = top()
        }
        #expect(stops == 11, "every line that shows (a code block's fences are passed), each component once")
        for n in 1...stops {
            canvas.view.moveUp(nil)
            #expect(canvas.heights.total == total, "Up #\(n) changed the layout")
            #expect(top() <= y, "Up #\(n) went down")
            y = top()
        }
        #expect(canvas.selection.location == 4, "back to the same column")
    }

    /// A table is one stop: outlined, still drawn; Return edits its first cell, Delete removes it
    /// in one undoable step.
    @Test func componentsAreOneStop() throws {
        let text = "Before.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter.\n"
        let (e, window) = open(text, caret: 2)
        defer { window.close() }
        let canvas = e.blockCanvas
        let ns = text as NSString
        let table = NSRange(location: ns.range(of: "| a").location, length: NSMaxRange(ns.range(of: "| 2 |")) - ns.range(of: "| a").location)
        canvas.view.moveDown(nil)
        #expect(canvas.focusedComponent == table)
        #expect(canvas.place(table.location).layout.content.component is TableBox, "still drawn, not turned into source")
        canvas.view.moveDown(nil)
        #expect(canvas.focusedComponent == nil)
        #expect(ns.lineRange(for: canvas.selection) == ns.lineRange(for: ns.range(of: "After.")))
        canvas.view.moveUp(nil)
        #expect(canvas.focusedComponent == table)
        canvas.view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(e.string == text, "an outlined component takes no text")
        canvas.view.insertNewline(nil)
        #expect(e.cellField?.row == 0 && e.cellField?.column == 0, "Return edits the first cell")
        e.endCellEdit(commit: false)
        e.select(NSRange(location: 2, length: 0))
        canvas.view.moveDown(nil)
        canvas.view.deleteBackward(nil)
        #expect(e.string == "Before.\n\nAfter.\n")
        window.undoManager?.undo()
        #expect(e.string == text)
    }

    /// The caret entering a heading reveals its markers in the margin where they fit (a wide
    /// window): its text stays put.
    @Test func headingMarkersHangInTheMargin() {
        let text = "Intro.\n\n## Heading text\n"
        let (e, window) = open(text, caret: 1, size: NSSize(width: 1400, height: 2400))
        defer { window.close() }
        let canvas = e.blockCanvas
        let h = (text as NSString).range(of: "Heading").location
        let before = canvas.caretRect(at: h + 3)
        e.select(NSRange(location: h + 3, length: 0))
        #expect(canvas.place(h).layout.content.string.string == "## Heading text")
        #expect(canvas.caretRect(at: h + 3).minX == before.minX)
        #expect(canvas.caretRect(at: h + 3).minY == before.minY)
    }

    /// Return on an empty item or quote line leaves it: a nested item moves out one level, the
    /// rest becomes a new paragraph after a blank line, with a blank line before what follows.
    @Test func returnLeavesListsAndQuotes() {
        let (list, w1) = open("- a")
        defer { w1.close() }
        list.pressReturn()
        list.pressReturn()
        #expect(list.string == "- a\n\n")
        list.type("x")
        #expect(list.string == "- a\n\nx", "a paragraph, not the item's continuation")

        let (middle, w2) = open("- a\n- b", caret: 3)
        defer { w2.close() }
        middle.pressReturn()
        middle.pressReturn()
        #expect(middle.string == "- a\n\n\n\n- b")
        #expect(middle.selectedRange.location == 5)

        let (nested, w3) = open("- a\n  - b", caret: 9)
        defer { w3.close() }
        nested.pressReturn()
        nested.pressReturn()
        #expect(nested.string == "- a\n  - b\n- ", "out one level")

        let (quote, w4) = open("> q")
        defer { w4.close() }
        quote.pressReturn()
        #expect(quote.string == "> q\n> ")
        quote.pressReturn()
        #expect(quote.string == "> q\n\n")

        let (setext, w5) = open("Owner\n=====\nNext")
        defer { w5.close() }
        setext.select(NSRange(location: 5, length: 0))
        setext.pressReturn()
        #expect(setext.string == "Owner\n=====\n\nNext", "the new line goes after the underline")
    }

    /// ⌘/: the Markdown as written on the same canvas, then back; the text, selection and undo stay.
    @Test func plainTextKeepsTextSelectionAndUndo() {
        let text = "# Title\n\nSome **bold** word.\n"
        let (e, window) = open(text)
        defer { window.close() }
        let bold = (text as NSString).range(of: "bold")
        e.select(bold)
        e.setPlainText(true)
        #expect(e.showsPlainText && e.blockCanvas.mode == .source)
        #expect(e.selectedRange == bold)
        #expect(e.blockCanvas.place(0).layout.content.string.string == "# Title", "as written")
        e.type("BOLD")
        e.setPlainText(false)
        #expect(e.blockCanvas.mode == .rendered)
        #expect(e.string == "# Title\n\nSome **BOLD** word.\n")
        window.undoManager?.undo()
        #expect(e.string == text)
    }

    /// The handle selects the text a block shows: no heading markers, list marker, task box or
    /// quote marker; a code block's code; with Shift, the selection grows; a component is selected
    /// whole and stays drawn.
    @Test func handleSelectsWhatTheBlockShows() throws {
        let text = "## Head\n\n- [ ] task\n\n> quoted\n\n```\ncode\n```\n\nTitle\n=====\n\n| a |\n|---|\n| 1 |\n"
        let (e, window) = open(text, caret: 0)
        defer { window.close() }
        let ns = text as NSString
        func block(_ needle: String) throws -> MarkdownBlock {
            let at = ns.range(of: needle).location
            return try #require(BlockMap.block(at: at, in: e.blocks(near: NSRange(location: at, length: 0))))
        }
        for (needle, expected) in [("## Head", "Head"), ("- [ ]", "task"), ("> quoted", "quoted"), ("```", "code"), ("Title", "Title")] {
            e.handleClicked(try block(needle), extending: false)
            #expect(ns.substring(with: e.selectedRange) == expected)
        }
        e.handleClicked(try block("## Head"), extending: false)
        e.handleClicked(try block("- [ ]"), extending: true)
        #expect(ns.substring(with: e.selectedRange) == "Head\n\n- [ ] task")
        e.handleClicked(try block("| a"), extending: false)
        #expect(e.selectedRange == NSRange(location: ns.range(of: "| a").location, length: NSMaxRange(ns.range(of: "| 1 |")) - ns.range(of: "| a").location))
        #expect(e.blockCanvas.focusedComponent == nil && e.componentBox(at: ns.range(of: "| a").location) is TableBox)
    }

    /// A click in the gap between two blocks: the upper half belongs to the line above.
    @Test func clicksInGapsLandOnTheNearestLine() {
        let text = "First paragraph.\n\n## Heading\n"
        let (e, window) = open(text, caret: 0)
        defer { window.close() }
        let canvas = e.blockCanvas
        let heading = (text as NSString).range(of: "Heading").location
        let first = canvas.lineBox(at: 0), second = canvas.lineBox(at: heading)
        let line = { (y: CGFloat) in (text as NSString).lineRange(for: NSRange(location: canvas.hit(NSPoint(x: canvas.columnX + 4, y: y)).location, length: 0)) }
        let gapTop = first.maxY, gapBottom = canvas.caretRect(at: heading).minY
        #expect(gapBottom - gapTop > 10)
        #expect(line(gapTop + 2) == (text as NSString).lineRange(for: NSRange(location: 0, length: 0)))
        #expect(line(gapBottom - 2) == (text as NSString).lineRange(for: NSRange(location: heading, length: 0)))
        #expect(second.maxY > gapBottom)
    }

    /// Left and Right take a component whole too, and leave it past its source; Delete removes it,
    /// paste is refused like typing.
    @Test func leftAndRightTakeComponentsWhole() {
        let text = "Before.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter.\n"
        let ns = text as NSString
        let (e, window) = open(text, caret: ns.range(of: "Before.").length)
        defer { window.close() }
        let canvas = e.blockCanvas
        let table = NSRange(location: ns.range(of: "| a").location, length: NSMaxRange(ns.range(of: "| 2 |")) - ns.range(of: "| a").location)
        canvas.view.moveRight(nil)
        #expect(canvas.focusedComponent == table)
        canvas.view.moveRight(nil)
        #expect(canvas.focusedComponent == nil && canvas.selection.location == ns.range(of: "After.").location)
        canvas.view.moveLeft(nil)
        #expect(canvas.focusedComponent == table)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("x", forType: .string)
        canvas.view.paste(nil)
        #expect(e.string == text, "an outlined component takes no pasted text")
    }

    /// Backspace where a block's text begins always shows its effect and never breaks structure.
    @Test func backspaceAtTheStartOfABlock() {
        func after(_ text: String, caretAt needle: String, offset: Int = 0) -> (MarkdownEditor, NSWindow) {
            let (e, w) = open(text, caret: (text as NSString).range(of: needle).location + offset)
            e.blockCanvas.view.deleteBackward(nil)
            return (e, w)
        }
        let (heading, w1) = after("Intro.\n\n## Title\n", caretAt: "Title")
        #expect(heading.string == "Intro.\n\nTitle\n", "a heading's markers go: it becomes body text")
        let (quote, w2) = after("> > Deep\n", caretAt: "Deep")
        #expect(quote.string == "> Deep\n", "out of the innermost quote")
        let (joined, w3) = after("> one\n> two\n", caretAt: "two")
        #expect(joined.string == "> onetwo\n", "inside a quote paragraph the line joins the one above")
        let table = "| a |\n|---|\n| 1 |\n\nAfter\n"
        let (component, w4) = after(table, caretAt: "After")
        #expect(component.string == table && component.blockCanvas.focusedComponent?.location == 0, "the table is taken whole, nothing merges into it")
        let code = "```\ncode\n```\n\nAfter\n"
        let (fence, w5) = after(code, caretAt: "After")
        #expect(fence.string == code && fence.selectedRange.location == NSMaxRange((code as NSString).range(of: "code")), "to the code's last line")
        let (atx, w6) = after("# Head\n\nAfter\n", caretAt: "After")
        #expect(atx.string == "# HeadAfter\n")
        let (setext, w7) = after("Head\n====\n\nAfter\n", caretAt: "After")
        #expect(setext.string == "Head\n====\n\nAfter\n" && setext.selectedRange.location == 4)
        for w in [w1, w2, w3, w4, w5, w6, w7] { w.close() }
    }

    /// A setext underline never shows in the rendered canvas, and the caret passes over it.
    @Test func setextUnderlinesStayHidden() {
        let text = "Title\n=====\nNext line.\n"
        let (e, window) = open(text, caret: 2)
        defer { window.close() }
        let canvas = e.blockCanvas
        let total = canvas.heights.total
        canvas.view.moveToEndOfLine(nil)
        canvas.view.moveRight(nil)
        #expect(canvas.selection.location == (text as NSString).range(of: "Next").location)
        canvas.view.moveLeft(nil)
        #expect(canvas.selection.location == 5)
        #expect(canvas.heights.total == total)
    }

    /// Return on an empty nested item inside a quote moves it out one level, tabs included.
    @Test func nestedItemsInQuotesMoveOutOneLevel() {
        let (spaces, w1) = open("> - a\n>   - ")
        defer { w1.close() }
        spaces.pressReturn()
        #expect(spaces.string == "> - a\n> - ", "\(spaces.string.debugDescription)")
        let (tab, w2) = open("- a\n\t- ")
        defer { w2.close() }
        tab.pressReturn()
        #expect(tab.string == "- a\n- ", "\(tab.string.debugDescription)")
    }

    /// Where the margin cannot hold them, revealed markers show inline at their own size: they
    /// start where the heading's text started and push it along the same line.
    @Test func headingMarkersShowInlineInANarrowWindow() {
        let text = "Intro.\n\n###### Small heading\n"
        let (e, window) = open(text, caret: 1, size: NSSize(width: 320, height: 800))
        defer { window.close() }
        let canvas = e.blockCanvas
        let line = (text as NSString).range(of: "######").location
        let h = (text as NSString).range(of: "Small").location
        let before = canvas.caretRect(at: h)
        e.select(NSRange(location: h + 2, length: 0))
        let shown = canvas.place(h).layout
        #expect(shown.content.string.string.hasPrefix("######") && shown.hang == 0)
        #expect(canvas.caretRect(at: line).minX == before.minX, "the markers start where the text did")
        #expect(canvas.caretRect(at: h).minX > before.minX && canvas.caretRect(at: h).minY == before.minY, "the text moves along the same line")
    }

    /// Below a final table the caret gets a new line to type into; the table stays drawn.
    @Test func belowAFinalTableANewParagraphOpens() {
        let text = "Intro.\n\n| a |\n|---|\n| 1 |\n"
        let (e, window) = open(text, caret: 0)
        defer { window.close() }
        let canvas = e.blockCanvas
        let table = (text as NSString).range(of: "| a").location
        canvas.view.moveDown(nil)
        #expect(canvas.focusedComponent?.location == table)
        canvas.view.moveDown(nil)
        #expect(canvas.focusedComponent == nil && canvas.selection.location == (text as NSString).length, "\(canvas.selection)")
        #expect(canvas.place(table).layout.content.component is TableBox)
        canvas.view.moveUp(nil)
        canvas.view.moveRight(nil)
        #expect(canvas.focusedComponent == nil && canvas.selection.location == (text as NSString).length, "Right leaves it too")
        canvas.view.moveUp(nil)
        let below = canvas.hit(NSPoint(x: canvas.columnX + 4, y: canvas.heights.total + BlockCanvas.topInset + 20))
        canvas.select(NSRange(location: below.location, length: 0), passing: true)
        #expect(canvas.focusedComponent == nil && canvas.selection.location == (text as NSString).length, "a click below lands there")
        let caret = canvas.caretRect(at: canvas.selection.location)
        e.type("x")
        #expect(canvas.caretRect(at: canvas.selection.location).minY == caret.minY, "the text appears where the caret was: the separator has no height")
        #expect(e.string == text + "\nx", "a paragraph of its own, not a row of the table: \(e.string.debugDescription)")
        #expect(MarkdownAnalyzer.analyze(e.string).components.map(\.range) == [NSRange(location: table, length: (text as NSString).length - 1 - table)])
    }

    /// A file that ends with a table and no line break: the caret still gets the line below (it
    /// is not in the file until something is typed), and leaving it leaves the file as it was.
    @Test func belowATableThatEndsTheFile() {
        let text = "Intro.\n\n| a |\n|---|\n| 1 |"
        let (e, window) = open(text, caret: 0)
        defer { window.close() }
        let canvas = e.blockCanvas, view = canvas.view
        let table = NSRange(location: 8, length: (text as NSString).length - 8)
        view.moveDown(nil)
        view.moveDown(nil)
        #expect(canvas.belowComponent == table && canvas.focusedComponent == nil)
        let tableBottom = canvas.top(of: canvas.place(table.location).unit) + canvas.place(table.location).layout.height
        #expect(canvas.caretRect(at: canvas.selection.location).minY > tableBottom + 8, "drawn on its own line below")
        #expect(canvas.place(table.location).layout.content.component is TableBox, "the table stays drawn")
        view.moveUp(nil)
        #expect(canvas.focusedComponent == table)
        view.moveRight(nil)
        #expect(canvas.belowComponent == table)
        view.deleteBackward(nil)
        #expect(canvas.focusedComponent == table && e.string == text, "Backspace takes the table, deletes nothing")
        view.moveToEndOfDocument(nil)
        #expect(canvas.belowComponent == table)
        let caret = canvas.caretRect(at: canvas.selection.location)
        e.type("x")
        #expect(e.string == text + "\n\nx")
        #expect(canvas.caretRect(at: canvas.selection.location).minY == caret.minY, "typed where the caret was drawn \(caret) \(canvas.caretRect(at: canvas.selection.location))")
        view.undoManager?.undo()
        #expect(e.string == text, "one step undoes the line and the text")

        // Return, and an input method's composition, start the paragraph the same way.
        view.moveToEndOfDocument(nil)
        view.insertNewline(nil)
        #expect(e.string == text + "\n\n" && canvas.selection.location == (e.string as NSString).length, "\(e.string.debugDescription) \(canvas.selection)")
        view.undoManager?.undo()
        view.moveToEndOfDocument(nil)
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(e.string == text + "\n\n你", "\(e.string.debugDescription)")
        view.undoManager?.undo()
        #expect(e.string == text)
    }
}
