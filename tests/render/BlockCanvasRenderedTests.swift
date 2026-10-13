import AppKit
import Foundation
import Testing
@testable import ZephyrRender
import ZephyrCore

/// The block canvas rendering Markdown (design §4): measured layout, hidden
/// syntax revealed at the caret, exact undoable edits, and no jump when typing into a new line.
@MainActor
@Suite struct BlockCanvasRenderedTests {
    static let sample = try! String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../fixtures/sample.md"), encoding: .utf8)

    func open(_ text: String, canvas kind: MarkdownEditor.Canvas = .block, size: NSSize = NSSize(width: 900, height: 2400)) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: kind)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: 0), size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.displayIfNeeded()
        window.makeFirstResponder(editor.focusView)
        return (editor, window)
    }

    /// The display text of the unit holding `location`.
    func shown(_ canvas: BlockCanvas, at location: Int) -> String {
        canvas.place(location).layout.content.string.string
    }

    @Test func engine() {
        let (editor, _) = open("# Title\n")
        #expect(editor.blockCanvas.mode == .rendered)
    }

    @Test func theReadingSurfaceShowsNoScrollBar() {
        let (editor, _) = open(String(repeating: "A long reading line.\n", count: 400))
        let scrollView = editor.blockCanvas.scrollView
        #expect(!scrollView.hasVerticalScroller)
        #expect(scrollView.contentView.frame.width == scrollView.bounds.width)
    }

    @Test func syntaxHidesAndShowsAtTheCaret() {
        let text = "Intro line.\n\nSome **bold** and `code` here.\n\n## Heading\n"
        let (editor, _) = open(text)
        let canvas = editor.blockCanvas
        let ns = text as NSString
        let bold = ns.range(of: "bold").location
        #expect(shown(canvas, at: bold) == "Some bold and code here.")
        #expect(shown(canvas, at: ns.range(of: "Heading").location) == "Heading")
        editor.select(NSRange(location: bold + 1, length: 0))
        #expect(shown(canvas, at: bold) == "Some **bold** and code here.", "the caret reveals the markers it touches, only those")
        editor.select(NSRange(location: ns.range(of: "Heading").location + 2, length: 0))
        #expect(shown(canvas, at: bold) == "Some bold and code here.")
        #expect(shown(canvas, at: ns.range(of: "Heading").location) == "## Heading")
    }

    @Test(arguments: ["# ", "## ", "### ", "#### ", "##### ", "###### "])
    func narrowHeadingMarkersShowInlineAndPushTheBody(_ marker: String) {
        let body = "A heading with enough words to wrap at the narrow reading width."
        let text = marker + body + "\n"
        let (editor, window) = open(text, size: NSSize(width: 720, height: 600))
        defer { window.close() }
        let canvas = editor.blockCanvas
        let bodyStart = marker.utf16.count
        let hidden = canvas.place(bodyStart).layout
        let hiddenRect = canvas.caretRect(at: bodyStart)
        editor.select(NSRange(location: 0, length: 0))
        let shown = canvas.place(bodyStart).layout
        let shownRect = canvas.caretRect(at: bodyStart)
        #expect(hidden.content.string.string == body, "the parsed marker does not leave a hidden prefix slot")
        #expect(shown.content.string.string.hasPrefix(marker))
        // The margin holds only the handle: the markers show inline instead of hanging (design §8.1).
        #expect(shown.hang == 0)
        #expect(canvas.caretRect(at: 0).minX == hiddenRect.minX, "the markers start where the body did")
        #expect(shownRect.minX > hiddenRect.minX, "the body moves along after them")
        #expect(shownRect.minY == hiddenRect.minY, "on the same line")
    }

    @Test func clicksLandBesideHiddenSyntax() {
        let text = "Some **bold** word.\n"
        let (editor, _) = open(text)
        let canvas = editor.blockCanvas
        editor.select(NSRange(location: text.utf16.count, length: 0))
        let ns = text as NSString
        // Caret positions and hit tests agree on the visible characters.
        for i in [0, 3, ns.range(of: "bold").location + 2, ns.range(of: "word").location + 1] {
            let rect = canvas.caretRect(at: i)
            #expect(canvas.characterIndex(at: NSPoint(x: rect.midX, y: rect.midY)) == i, "position \(i)")
        }
        // Past the end of the line: after the last character, closing syntax included.
        let end = canvas.caretRect(at: ns.length - 1)
        #expect(canvas.characterIndex(at: NSPoint(x: end.maxX + 300, y: end.midY)) == ns.length - 1)
    }

    /// A drag begun in the second item's visible text and extended into a wrapped first item spans
    /// the intervening line break and hidden list marker. The first item's final visual line still
    /// ends at its text, rather than filling the remaining column.
    @Test(arguments: ["\n", "\r\n"])
    func listSelectionStopsAtTheFinalDisplayedCharacter(_ newline: String) throws {
        let first = "first item with enough words to wrap across several visual lines in a narrow reading column"
        let text = "- \(first)\(newline)- second item\(newline)"
        let (editor, window) = open(text, size: NSSize(width: 360, height: 600))
        defer { window.close() }
        let canvas = editor.blockCanvas
        let ns = text as NSString
        let firstRange = ns.range(of: first)
        let secondStart = ns.range(of: "second").location

        // A normalized range has no drag direction; this is the range made by dragging from
        // `second` back to the beginning of `first`.
        editor.select(NSRange(location: firstRange.location, length: secondStart - firstRange.location))

        let layout = canvas.place(firstRange.location).layout
        #expect(layout.lines.count > 1, "the first item wraps")
        let firstLineRects = canvas.rects(for: editor.selectedRange).filter { $0.midY < canvas.caretRect(at: secondStart).midY }
        let finalRect = try #require(firstLineRects.last)
        let textEnd = canvas.caretRect(at: NSMaxRange(firstRange)).midX
        #expect(abs(finalRect.maxX - textEnd) < 0.5, "the selected newline does not fill trailing blank space")
        #expect(finalRect.maxX < editor.column.x + editor.column.width - 5)
    }

    @Test func typingIsExactAndUndoable() {
        let (editor, window) = open(Self.sample)
        let original = editor.string
        let at = (original as NSString).range(of: "中英文混排").location
        editor.select(NSRange(location: at, length: 0))
        for c in "**新** " { editor.type(String(c)) }
        #expect((editor.string as NSString).substring(with: NSRange(location: at, length: 6)) == "**新** ")
        window.undoManager?.undo()
        #expect(editor.string == original)
    }

    /// Return leaves the caret on a line laid out as the text it is about to hold: typing the first
    /// character moves nothing below (design §8.1, WYSIWYG input).
    @Test func typingIntoANewLineMovesNothing() {
        let text = "First paragraph.\n\nSecond paragraph.\n"
        let (editor, _) = open(text)
        let canvas = editor.blockCanvas
        for line in ["First paragraph.", "Second paragraph."] {
            let at = NSMaxRange((editor.string as NSString).range(of: line))
            editor.select(NSRange(location: at, length: 0))
            editor.pressReturn()
            let next = canvas.caretRect(at: editor.string.utf16.count).minY
            let caret = canvas.caretRect(at: editor.selectedRange.location)
            editor.type("x")
            #expect(canvas.caretRect(at: editor.string.utf16.count).minY == next, "the text below stays")
            #expect(abs(canvas.caretRect(at: editor.selectedRange.location - 1).midY - caret.midY) < 1, "the typed character sits where the caret was")
            editor.select(NSRange(location: 0, length: 0))
        }
    }

    @Test(arguments: ["# Owner", "# Owner\n", "Owner\n=====\n", "Owner"])
    func newLineCaretMatchesFirstCharacter(_ text: String) {
        let (editor, window) = open(text)
        defer { window.close() }
        editor.select(NSRange(location: editor.length, length: 0))
        editor.pressReturn()
        let start = editor.selectedRange.location
        let before = editor.blockCanvas.caretRect(at: start)
        editor.type("n")
        let after = editor.blockCanvas.caretRect(at: start)
        #expect(abs(before.minY - after.minY) < 1, "empty line \(before) versus first character \(after)")
        #expect(abs(before.minX - after.minX) < 1)
        #expect(abs(before.height - after.height) < 1)
    }

    @Test func newLineCaretMatchesInputMethodComposition() {
        let (editor, window) = open("# Owner")
        defer { window.close() }
        editor.select(NSRange(location: editor.length, length: 0))
        editor.pressReturn()
        let start = editor.selectedRange.location
        let canvas = editor.blockCanvas
        let before = canvas.caretRect(at: start)
        canvas.view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(canvas.view.hasMarkedText())
        #expect(canvas.caretRect(at: start) == before, "composition starts on the empty line's existing baseline")
        canvas.view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!canvas.view.hasMarkedText())
        #expect(editor.string == "# Owner\n你")
        #expect(canvas.caretRect(at: start) == before)
    }

    /// Down walks the lines that show: the blank line between blocks has no height and is no stop;
    /// a code block's fences are syntax the arrows pass (they show in their bands while the caret
    /// is in the block, and nothing moves). An empty block keeps its opening fence as its stop.
    @Test func verticalMovesWalkTheLines() {
        let text = "One\n\n```\ncode\n```\n\nTwo\n"
        let (editor, _) = open(text)
        let canvas = editor.blockCanvas
        let ns = text as NSString
        editor.select(NSRange(location: 1, length: 0))
        let fence = ns.range(of: "```").location
        #expect(shown(canvas, at: fence).isEmpty, "a fence is hidden away from the caret")
        let two = canvas.caretRect(at: ns.range(of: "Two").location).minY
        func line(_ needle: String) -> NSRange { ns.lineRange(for: ns.range(of: needle)) }
        canvas.view.moveDown(nil)
        #expect(ns.lineRange(for: canvas.selection) == line("code"), "at \(canvas.selection.location)")
        #expect(shown(canvas, at: fence) == "```")
        #expect(canvas.caretRect(at: ns.range(of: "Two").location).minY == two, "the fences show in their bands: nothing below moves")
        canvas.view.moveDown(nil)
        #expect(ns.lineRange(for: canvas.selection) == line("Two"))
        #expect(canvas.caretRect(at: ns.range(of: "Two").location).minY == two)
        canvas.view.moveUp(nil)
        canvas.view.moveUp(nil)
        #expect(canvas.selection.location == 1, "back to the same column")

        let empty = "One\n\n```\n```\n\nTwo\n"
        let (e2, _) = open(empty)
        e2.select(NSRange(location: 1, length: 0))
        e2.blockCanvas.view.moveDown(nil)
        #expect(e2.selectedRange.location == (empty as NSString).range(of: "```").location, "into an empty block: its opening fence")
        e2.blockCanvas.view.moveDown(nil)
        #expect((empty as NSString).lineRange(for: e2.selectedRange) == (empty as NSString).lineRange(for: (empty as NSString).range(of: "Two")))
    }

    @Test func upMovesPastParagraphSpacing() {
        let text = "First paragraph.\nSecond paragraph.\nThird paragraph."
        let (editor, window) = open(text)
        defer { window.close() }
        let canvas = editor.blockCanvas
        let ns = text as NSString
        let start = ns.range(of: "Third").location + 3
        editor.select(NSRange(location: start, length: 0))
        let before = canvas.caretRect(at: start)
        canvas.view.moveUp(nil)
        let target = canvas.selection.location
        #expect(ns.lineRange(for: NSRange(location: target, length: 0)) == ns.lineRange(for: ns.range(of: "Second")))
        #expect(canvas.caretRect(at: target).minY < before.minY)
        canvas.view.moveDown(nil)
        #expect(canvas.selection.location == start)
    }

    @Test(arguments: [MarkdownEditor.Canvas.block, .source])
    func verticalKeepsColumnAcrossShortLines(_ kind: MarkdownEditor.Canvas) {
        let text = "abcdefghij\nx\nabcdefghij"
        let (editor, window) = open(text, canvas: kind)
        defer { window.close() }
        let canvas = editor.blockCanvas
        editor.select(NSRange(location: 8, length: 0))
        canvas.view.moveDown(nil)
        #expect(canvas.selection.location == 12)
        canvas.view.moveDown(nil)
        #expect(canvas.selection.location == 21)
        canvas.view.moveUp(nil)
        #expect(canvas.selection.location == 12)
        canvas.view.moveUp(nil)
        #expect(canvas.selection.location == 8)
        #expect(editor.string == text)
    }

    @Test(arguments: [MarkdownEditor.Canvas.block, .source])
    func verticalAtWrapEndStaysOnTheTargetLine(_ kind: MarkdownEditor.Canvas) throws {
        let text = String(repeating: "A wrapped paragraph with several different words. ", count: 12)
        let (editor, window) = open(text, canvas: kind, size: NSSize(width: 320, height: 1200))
        defer { window.close() }
        let canvas = editor.blockCanvas
        let layout = canvas.place(0).layout
        #expect(layout.lines.count > 2)
        editor.select(NSRange(location: layout.sourceStart(ofLine: 1), length: 0))
        canvas.goalX = editor.column.x + editor.column.width
        canvas.view.moveUp(nil)
        #expect(canvas.selection.location == layout.sourceEnd(ofLine: 0))
        #expect(canvas.place(canvas.selection.location).line == 0, "the shared wrap offset belongs to the line we moved onto")
        canvas.view.moveDown(nil)
        #expect(canvas.place(canvas.selection.location).line == 1)
        canvas.view.moveUpAndModifySelection(nil)
        canvas.view.moveUpAndModifySelection(nil)
        #expect(canvas.selection.location == 0, "Shift-Up continues from the active end at the wrap")
        #expect(editor.string == text)
    }

    @Test func shiftUpAndDownExtendAndShrinkAcrossParagraphs() {
        let text = "abcdef\nabcdef\nabcdef"
        let (editor, window) = open(text)
        defer { window.close() }
        let canvas = editor.blockCanvas
        editor.select(NSRange(location: 17, length: 0))
        canvas.view.moveUpAndModifySelection(nil)
        #expect(canvas.selection == NSRange(location: 10, length: 7))
        canvas.view.moveUpAndModifySelection(nil)
        #expect(canvas.selection == NSRange(location: 3, length: 14))
        canvas.view.moveDownAndModifySelection(nil)
        #expect(canvas.selection == NSRange(location: 10, length: 7))
        canvas.view.moveDownAndModifySelection(nil)
        #expect(canvas.selection == NSRange(location: 17, length: 0))
        #expect(editor.string == text)
    }

    @Test func outlineIncludesSetextHeadings() {
        let (editor, _) = open("Title\n=====\n\nText\n\n## Two\n\n- item\n---\n")
        #expect(editor.headings().map(\.title) == ["Title", "Two"])
    }

    /// The `---` closing front matter is not a setext underline, nor a YAML comment a heading.
    @Test func outlineSkipsFrontMatter() {
        let (editor, _) = open("---\ntitle: Plan\n# a comment\ndue: 2026-10-16\n---\n\n# Plan\n")
        #expect(editor.headings().map(\.title) == ["Plan"])
    }
}
