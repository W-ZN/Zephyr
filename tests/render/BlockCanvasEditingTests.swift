import AppKit
import Foundation
import Testing
@testable import ZephyrRender
import ZephyrCore

/// Document editing on the block canvas (design §8): the same commands as on the TextKit canvas,
/// written once against the editing surface — lists, formatting, the slash menu, block moves,
/// checkboxes and the attached editors.
@MainActor
@Suite struct BlockCanvasEditingTests {
    func open(_ text: String, caretAfter needle: String? = nil, size: NSSize = NSSize(width: 900, height: 900)) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: 0), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.makeFirstResponder(editor.focusView)
        let ns = text as NSString
        let at = needle.map { NSMaxRange(ns.range(of: $0)) } ?? ns.length
        editor.select(NSRange(location: at, length: 0))
        draw(editor)
        return (editor, window)
    }

    /// Draw what is on screen: components learn where they are drawn (the test window is never shown).
    func draw(_ editor: MarkdownEditor) {
        let view = editor.focusView
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) { view.cacheDisplay(in: view.visibleRect, to: rep) }
    }

    func view(_ editor: MarkdownEditor) -> BlockCanvasView { editor.blockCanvas.view }

    @Test func listsContinueAndEnd() {
        let (e, _) = open("- a")
        e.pressReturn()
        #expect(e.string == "- a\n- ")
        e.type("b")
        e.pressReturn()
        e.pressReturn()
        #expect(e.string == "- a\n- b\n\n", "Return on an empty item ends the list: a blank line, then a new paragraph")

        let (n, _) = open("1. x")
        n.pressReturn()
        #expect(n.string == "1. x\n2. ")

        let (q, _) = open("> quoted")
        q.pressReturn()
        #expect(q.string == "> quoted\n> ")
    }

    @Test func markersBackspaceAndNest() {
        let (e, _) = open("- a\n- b")
        view(e).insertTab(nil)
        #expect(e.string == "- a\n  - b")
        view(e).insertBacktab(nil)
        #expect(e.string == "- a\n- b")
        e.select(NSRange(location: ("- a\n- " as NSString).length, length: 0))
        view(e).deleteBackward(nil)
        #expect(e.string == "- a\n\nb", "Backspace at an item's text makes it a paragraph after the list, not part of item a")

        // Nested: the item becomes a paragraph under its parent item; the parent's line is unchanged.
        let (n, _) = open("- a\n  - ")
        let canvas = n.blockCanvas
        let column = canvas.caretRect(at: 2).minX
        view(n).deleteBackward(nil)
        #expect(n.string == "- a\n\n  ")
        #expect(abs(canvas.caretRect(at: n.selectedRange.location).minX - column) < 1, "the caret waits at the parent item's text column")
        n.type("more")
        #expect(n.string == "- a\n\n  more")
        #expect(abs(canvas.caretRect(at: (n.string as NSString).range(of: "more").location).minX - column) < 1, "the paragraph lines up with its parent item's text")

        // In a quote the blank line keeps the quote.
        let (q, _) = open("> - a\n> - b", caretAfter: "> - a\n> - ")
        view(q).deleteBackward(nil)
        #expect(q.string == "> - a\n>\n> b", "\(q.string.debugDescription)")

        // Under that line any block can follow: the slash menu indents it to the item.
        let (c, _) = open("- a\n  - ")
        view(c).deleteBackward(nil)
        c.type("/")
        c.type("code")
        view(c).doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(c.string == "- a\n\n  ```\n  \n  ```", "\(c.string.debugDescription)")
    }

    /// Tab nests a block that follows a list under the list's last top-level item; Shift-Tab takes a
    /// nested paragraph out one level. The item lines are untouched.
    @Test func tabNestsABlockUnderTheItemAbove() {
        let text = "- a\n  - b\n\nPara one\nline two\n\nAfter\n"
        let (e, _) = open(text, caretAfter: "Para")
        view(e).insertTab(nil)
        #expect(e.string == "- a\n  - b\n\n  Para one\n  line two\n\nAfter\n", "\(e.string.debugDescription)")
        #expect(e.selectedRange.location == ("- a\n  - b\n\n  Para" as NSString).length)
        view(e).insertTab(nil)
        #expect(e.string.hasPrefix("- a\n  - b\n\n  Para"), "nested already: Tab is a tab character, not another level")
        e.focusView.undoManager?.undo()

        let nested = "- a\n  - b\n\n    deep\n\nAfter\n"
        let (n, _) = open(nested, caretAfter: "deep")
        view(n).insertBacktab(nil)
        #expect(n.string == "- a\n  - b\n\n  deep\n\nAfter\n", "out of b, still under a: \(n.string.debugDescription)")
        view(n).insertBacktab(nil)
        #expect(n.string == "- a\n  - b\n\ndeep\n\nAfter\n")
        #expect(n.selectedRange.location == ("- a\n  - b\n\ndeep" as NSString).length)

        let (lazy, _) = open("- a\n  more\n", caretAfter: "more")
        view(lazy).insertBacktab(nil)
        #expect(lazy.string == "- a\n  more\n", "a line of the item's own text stays")

        let (far, _) = open("- a\n\nPara\n\nOther\n", caretAfter: "Other")
        view(far).insertTab(nil)
        #expect(far.string == "- a\n\nPara\n\nOther\t\n", "not right after a list: a tab")
    }

    @Test func caretStaysOutOfMarkers() {
        let text = "- item\n- two\n"
        let (e, _) = open(text)
        e.select(NSRange(location: 0, length: 0))
        #expect(e.selectedRange.location == 2, "never in front of the hidden marker")
        let two = (text as NSString).range(of: "two").location
        e.select(NSRange(location: two, length: 0))
        view(e).moveLeft(nil)
        #expect(e.selectedRange.location == ("- item" as NSString).length, "left from an item's text goes to the line before")
        e.select(NSRange(location: 2, length: 0))
        view(e).moveLeft(nil)
        #expect(e.selectedRange.location == 2, "the first line has no line before it")
    }

    @Test func formattingIsOneUndoableEdit() {
        let text = "Some word here.\n"
        let (e, window) = open(text)
        let word = (text as NSString).range(of: "word")
        e.select(word)
        view(e).toggleBoldface(nil)
        #expect(e.string == "Some **word** here.\n")
        #expect(e.selectedRange == NSRange(location: word.location + 2, length: word.length))
        view(e).toggleBoldface(nil)
        #expect(e.string == text, "the same command unwraps")
        let heading = NSMenuItem()
        heading.tag = 2
        view(e).applyHeading(heading)
        #expect(e.string == "## Some word here.\n")
        window.undoManager?.undo()
        #expect(e.string == text)
    }

    @Test func slashMenuInsertsMarkdown() {
        let (e, _) = open("# T")
        e.pressReturn()
        e.pressReturn()
        e.type("/")
        #expect(e.slashMenu != nil)
        e.type("tab")
        #expect(e.slashMenu?.items.map(\.keywords.first) == ["table"])
        view(e).doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e.slashMenu == nil)
        #expect(e.string == "# T\n\n|  |  |\n| --- | --- |\n|  |  |")

        let (code, _) = open("```\ncode\n\n```\n", caretAfter: "code\n")
        code.type("/")
        #expect(code.slashMenu == nil, "never inside code")
    }

    @Test func blocksMoveWithTheCaret() {
        let (e, _) = open("# T\n\nfirst\n\nsecond\n\nthird\n", caretAfter: "se")
        view(e).moveBlockUp(nil)
        #expect(e.string == "# T\n\nsecond\n\nfirst\n\nthird\n")
        #expect((e.string as NSString).substring(from: e.selectedRange.location).hasPrefix("cond"))
    }

    @Test(arguments: ["\n", "\r\n"])
    func blockTextSelectionExcludesLineBreak(_ newline: String) throws {
        let text = "# Owner" + newline + newline + "Body" + newline
        let (editor, window) = open(text)
        defer { window.close() }
        let block = try #require(editor.blocks(near: NSRange(location: 0, length: 0)).first)
        editor.selection = try #require(editor.visibleText(of: block))
        #expect(editor.selectedRange == (text as NSString).range(of: "Owner"), "the text the heading shows, not its markers or line break")
        let rect = try #require(editor.blockCanvas.rects(for: editor.selectedRange).last)
        #expect(rect.maxX < editor.column.x + editor.column.width - 10, "highlight ends at the text, not the column edge")
        #expect(editor.string == text)
    }

    @Test func checkboxClickToggles() throws {
        let text = "- [ ] task\n\nafter\n"
        let (e, window) = open(text)
        let canvas = e.blockCanvas
        let caret = canvas.caretRect(at: (text as NSString).range(of: "task").location)
        let point = NSPoint(x: caret.minX - e.typography.listIndent / 2, y: caret.midY)
        #expect(e.wantsPointingHand(at: point, modifiers: []))
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(e.handleClick(at: point, event: event))
        #expect(e.string == "- [x] task\n\nafter\n")
    }

    @Test func tableCellsEditInPlace() throws {
        let (e, _) = open("| a | b |\n|---|---|\n| 1 | 2 |\n\nafter\n")
        let box = try #require(e.componentBox(at: 0) as? TableBox)
        let rect = try #require(box.cellRect(row: 1, column: 1))
        #expect(e.tableCell(at: NSPoint(x: rect.midX, y: rect.midY))?.row == 1)
        e.beginCellEdit(box, row: 1, column: 1)
        #expect(e.cellField?.stringValue == "2")
        #expect(e.cellField?.superview === e.focusView)
        e.cellField?.stringValue = "x | y"
        e.endCellEdit(commit: true)
        #expect(e.string == "| a | b |\n|---|---|\n| 1 | x \\| y |\n\nafter\n")
    }

    /// A click puts the caret where it lands in the cell's text, not at its end.
    @Test func tableCellClickPlacesTheCaretAtThePoint() throws {
        let (e, _) = open("| name | note |\n|---|---|\n| alpha beta gamma | x |\n\nafter\n")
        let box = try #require(e.componentBox(at: 0) as? TableBox)
        let rect = try #require(box.cellRect(row: 1, column: 0))
        e.beginCellEdit(box, row: 1, column: 0, at: NSPoint(x: rect.minX + box.padX + 1, y: rect.midY))
        let start = try #require(e.cellField?.currentEditor()?.selectedRange)
        #expect(start.location == 0 && start.length == 0, "a click at the text's start: \(start)")
        e.endCellEdit(commit: false)
        e.beginCellEdit(box, row: 1, column: 0, at: NSPoint(x: rect.minX + box.padX + 40, y: rect.midY))
        let middle = try #require(e.cellField?.currentEditor()?.selectedRange)
        #expect(middle.location > 0 && middle.location < 16, "a click inside the text: \(middle)")
        e.endCellEdit(commit: false)
        #expect(e.string.hasPrefix("| name | note |"))
    }

    /// Typing in a cell lays the table out as it grows; Return goes down a row, and the "+" strip
    /// adds a row ready for typing.
    @Test func tableCellsGrowAsTypedAndMoveDown() throws {
        let (e, _) = open("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nafter\n")
        let box = try #require(e.componentBox(at: 0) as? TableBox)
        let before = try #require(box.cellRect(row: 1, column: 0))
        e.beginCellEdit(box, row: 1, column: 0)
        let field = try #require(e.cellField)
        field.stringValue = String(repeating: "word ", count: 60)
        e.followCell(field)
        let grown = try #require(box.cellRect(row: 1, column: 0))
        #expect(grown.width > before.width && grown.height > before.height, "the cell grows around the text before it is saved")
        #expect(abs(field.frame.minY - (grown.minY + box.padY)) < 0.5)
        #expect(e.string.contains("| 1 | 2 |"), "nothing is written while typing")
        field.stringValue = "one"
        e.cellFieldDidEnd(field, movement: NSTextMovement.return.rawValue)
        #expect(e.string.hasPrefix("| a | b |\n|---|---|\n| one | 2 |\n"))
        #expect((e.string as NSString).substring(to: e.selectedRange.location).hasSuffix("after"), "the caret stays after the table, which stays rendered")
        #expect(e.cellField?.row == 2 && e.cellField?.column == 0 && e.cellField?.stringValue == "3")
        e.endCellEdit(commit: true)
        let table = try #require(e.componentBox(at: 0) as? TableBox)
        draw(e)
        let adders = try #require(e.tableAdders(at: NSPoint(x: table.drawnRect.midX, y: table.drawnRect.maxY + 8), engaged: table))
        #expect(adders.row.contains(NSPoint(x: table.drawnRect.midX, y: table.drawnRect.maxY + 8)))
        e.addToTable(table, row: true)
        #expect(e.string.contains("| 3 | 4 |\n|  |  |\n"))
        #expect(e.cellField?.row == 3 && e.cellField?.column == 0)
    }

    /// Words never break: a table too wide for the window keeps them whole and scrolls sideways.
    @Test func wideTablesScrollInsteadOfBreakingWords() throws {
        let row = (0..<12).map { "Column\($0)Name" }
        let text = "| " + row.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 12) + "\n| " + row.joined(separator: " | ") + " |\n"
        let (e, _) = open(text)
        let box = try #require(e.componentBox(at: 0) as? TableBox)
        let font = try #require(box.cellFont(row: 1))
        let word = ("Column10Name" as NSString).size(withAttributes: [.font: font]).width
        #expect(box.scrollWidth > 0)
        #expect(try #require(box.cellRect(row: 1, column: 10)).width >= word + box.padX * 2)
        box.scrollToCell(row: 1, column: 11)
        #expect(box.scrollX > 0)
        draw(e)
        let last = try #require(box.cellRect(row: 1, column: 11))
        #expect(last.maxX <= box.drawnRect.maxX + 0.5 && e.tableCell(at: NSPoint(x: last.midX, y: last.midY))?.column == 11)
    }

    @Test func wideTableThumbDragRevealsHiddenColumns() throws {
        let row = (0..<12).map { "Column\($0)Name" }
        let text = "| " + row.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 12) + "\n| " + row.joined(separator: " | ") + " |\n"
        let (e, window) = open(text)
        let box = try #require(e.componentBox(at: 0) as? TableBox)
        #expect(box.scrollWidth > 0)
        #expect(!box.isHorizontalScrollHandleVisible)

        box.setHorizontalScrollHovered(true)
        let thumb = box.horizontalScrollThumb
        #expect(box.isHorizontalScrollHandleVisible && !thumb.isEmpty)
        let canvas = view(e)
        let start = canvas.convert(NSPoint(x: thumb.midX, y: thumb.midY), to: nil)
        let end = NSPoint(x: start.x + box.horizontalScrollTrack.width, y: start.y)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: end, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: drag)
        canvas.mouseUp(with: up)

        #expect(box.scrollX > box.scrollWidth * 0.95)
        let last = try #require(box.cellRect(row: 1, column: 11))
        #expect(last.maxX <= box.drawnRect.maxX + 0.5 && e.tableCell(at: NSPoint(x: last.midX, y: last.midY))?.column == 11)

        box.setHorizontalScrollHovered(false)
        #expect(!box.isHorizontalScrollHandleVisible)
    }

    @Test func tableDividerResizeReflowsWithoutChangingMarkdown() throws {
        let text = "| left | right |\n|---|---|\n| alpha beta gamma delta epsilon zeta eta theta | short |\n"
        let (e, _) = open(text)
        let box = try #require(e.componentBox(at: 0) as? TableBox)
        box.widthOverride = .column
        draw(e)
        let initial = try #require(box.columnWidths())
        let initialHeight = box.height(in: .init(column: e.column.width, wide: e.column.width))
        box.resizeColumns(divider: 0, from: initial, by: -500)
        draw(e)
        let resized = try #require(box.columnWidths())
        #expect(resized[0] == initial[0] - 500)
        #expect(resized[1] == initial[1] + 500)
        #expect(abs(resized.reduce(0, +) - initial.reduce(0, +)) < 0.01)
        #expect(box.height(in: .init(column: e.column.width, wide: e.column.width)) > initialHeight, "the narrowed cell wraps")
        #expect(e.string == text, "resizing is view state, not a Markdown edit")

        box.resizeColumns(divider: 0, from: initial, by: 0)
        draw(e)
        #expect(box.columnWidths() == initial, "returning a drag to its start restores the baseline")

        box.resizeColumns(divider: 0, from: initial, by: -500)
        draw(e)

        let fresh = try #require(e.editTable(box) { TableEdit.setting($0, row: 1, column: 1, to: "changed") })
        draw(e)
        #expect(fresh.columnWidths() == resized, "a cell edit retains the visual widths")
    }

    @Test func draggingATableDividerChangesOnlyItsViewWidths() throws {
        let text = "| left | right |\n|---|---|\n| alpha beta gamma delta epsilon zeta eta theta | short |\n"
        let (e, window) = open(text)
        let box = try #require(e.componentBox(at: 0) as? TableBox)
        let initial = try #require(box.columnWidths())
        let divider = try #require(box.cellRect(row: 0, column: 0)).maxX
        let point = NSPoint(x: divider, y: box.drawnRect.midY)
        let start = view(e).convert(point, to: nil)
        let end = NSPoint(x: start.x - 120, y: start.y)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: end, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view(e).mouseDown(with: down)
        view(e).mouseDragged(with: drag)
        view(e).mouseUp(with: up)
        draw(e)
        let resized = try #require(box.columnWidths())
        #expect(resized[0] == initial[0] - 120 && resized[1] == initial[1] + 120)
        #expect(e.string == text)
    }

    @Test func narrowTableDividerDoesNotExpandItsColumnPair() throws {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        let (e, _) = open(text)
        let box = try #require(e.componentBox(at: 0) as? TableBox)
        let initial = try #require(box.columnWidths())
        box.resizeColumns(divider: 0, from: initial, by: -1_000)
        draw(e)
        let resized = try #require(box.columnWidths())
        #expect(resized.reduce(0, +) == initial.reduce(0, +), "a narrow pair keeps its original total")
        #expect(e.string == text)
    }

    /// A table or formula wider than the reading column stays inside it, even with room beside it
    /// (design §8.1): it scrolls there, fading where it continues; nothing reaches into the margins.
    @Test func wideComponentsKeepToTheColumn() throws {
        let row = (0..<12).map { "Column\($0)Name" }
        let table = "| " + row.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 12) + "\n| " + row.joined(separator: " | ") + " |\n"
        let formula = "$$\n" + (0..<60).map { "x_{\($0)}" }.joined(separator: " + ") + "\n$$\n"
        let text = table + "\n" + formula
        let (e, _) = open(text, size: NSSize(width: 1500, height: 2400))
        draw(e)
        let column = e.column
        for location in [0, (text as NSString).range(of: "$$").location] {
            let box = try #require(e.componentBox(at: location))
            #expect(box.scrollWidth > 0, "\(type(of: box)) scrolls")
            #expect(box.drawnRect.minX >= column.x - 0.5 && box.drawnRect.maxX <= column.x + column.width + 0.5, "\(type(of: box)) at \(box.drawnRect) leaves the column \(column)")
        }
    }

    /// Right-click on text works as in any Mac text: outside the selection the word there is
    /// selected; the menu looks it up, edits and formats it. The block's actions are its handle's.
    @Test func rightClickSelectsTheWordAndBlockActionsAreTheHandles() throws {
        let text = "First paragraph here.\n\nSecond one.\n\n- a\n- b\n"
        let (e, _) = open(text)
        let canvas = e.blockCanvas
        let ns = text as NSString
        func point(_ needle: String) -> NSPoint {
            let r = canvas.caretRect(at: ns.range(of: needle).location + 2)
            return NSPoint(x: r.midX, y: r.midY)
        }
        let words = try #require(e.textMenu(at: point("Second"), base: NSMenu()))
        #expect(e.selectedRange == ns.range(of: "Second"))
        #expect(words.items.first?.title.contains("Second") == true, "Look Up first")
        #expect(words.items.contains { $0.action == #selector(BlockCanvasView.toggleBoldface(_:)) })
        #expect(!words.items.contains { $0.title == String(localized: "Delete Block") })
        e.select(ns.range(of: "paragraph here"))
        _ = try #require(e.textMenu(at: point("paragraph"), base: NSMenu()))
        #expect(e.selectedRange == ns.range(of: "paragraph here"), "a click on the selection keeps it")
        let second = try #require(BlockMap.block(at: ns.range(of: "Second").location, in: e.blocks(near: ns.range(of: "Second"))))
        let blockMenu = try #require(e.textMenu(at: .zero, base: NSMenu(), block: second))
        #expect(e.selectedRange == ns.range(of: "Second one."), "the handle selects its block")
        #expect(blockMenu.items.contains { $0.submenu?.items.contains { $0.action == #selector(BlockCanvasView.toggleBulletList(_:)) } == true })
        #expect(blockMenu.items.contains { $0.title == String(localized: "Delete Block") })

        func block(_ needle: String) throws -> MarkdownBlock {
            let at = (e.string as NSString).range(of: needle).location
            return try #require(BlockMap.block(at: at, in: e.blocks(near: NSRange(location: at, length: 0))))
        }
        e.duplicate(try block("Second"))
        #expect(e.string == "First paragraph here.\n\nSecond one.\n\nSecond one.\n\n- a\n- b\n")
        e.delete(try block("Second"))
        #expect(e.string == text)
        e.duplicate(try block("- a"))
        #expect(e.string == "First paragraph here.\n\nSecond one.\n\n- a\n- a\n- b\n")
    }

    @Test func dropsInsertAndMove() {
        let text = "one two three\n"
        let (e, window) = open(text)
        let v = view(e)
        let two = (text as NSString).range(of: " two")
        v.drop("X", at: 0)
        #expect(e.string == "Xone two three\n")
        #expect(e.selectedRange == NSRange(location: 0, length: 1), "the dropped text is selected")
        window.undoManager?.undo()
        #expect(e.string == text)
        #expect(v.drop(" two", at: two.location + 1, moving: two) == false, "onto itself: nothing moves")
        v.drop(" two", at: (text as NSString).length - 1, moving: two)
        #expect(e.string == "one three two\n")
        #expect((e.string as NSString).substring(with: e.selectedRange) == " two")
        window.undoManager?.undo()
        #expect(e.string == text, "a move is one undo step")
    }

    @Test func filesDropAsReferences() {
        let (e, _) = open("")
        e.baseURL = URL(fileURLWithPath: "/notes/doc")
        #expect(e.markdownReference(to: URL(fileURLWithPath: "/notes/doc/img/a b.png")) == "![a b](img/a%20b.png)")
        #expect(e.markdownReference(to: URL(fileURLWithPath: "/notes/report.pdf")) == "[report.pdf](../report.pdf)")
    }

    @Test func printsTheRenderedText() throws {
        let (e, _) = open("# Title\n\n- [x] done\n")
        let sheet = try #require(e.printView as? PrintSheet)
        #expect(sheet.editor.string == e.string)
        #expect(sheet.editor.isEditable == false)
        #expect(sheet.editor.blockCanvas.layout(0).content.string.string == "Title", "rendered by the same canvas, without syntax")
        #expect(sheet.frame.height > 0 && sheet.pages.count == 1)
    }

    @Test func propertiesEditInPlace() throws {
        let (e, _) = open("---\ntitle: Old\n---\n\nBody\n")
        let box = try #require(e.frontMatterBox())
        let rect = try #require(box.valueRects.first)
        #expect(e.propertyEntry(at: NSPoint(x: rect.minX + 4, y: rect.midY)) == 0)
        e.beginPropertyEdit(0)
        e.propertyField?.stringValue = "New"
        e.endPropertyEdit(commit: true)
        #expect(e.string == "---\ntitle: New\n---\n\nBody\n")
    }
}
