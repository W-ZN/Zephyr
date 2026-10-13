import AppKit
import Foundation
import Testing
@testable import ZephyrRender

/// Attached editors (design §8): table cells and display formulas are edited over the rendered
/// block, which keeps its size until the edit is committed as one minimal patch.
@MainActor
@Suite struct AttachedEditorTests {
    func editor(_ text: String) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        editor.select(NSRange(location: (text as NSString).length, length: 0))
        draw(editor)
        return (editor, window)
    }

    func draw(_ editor: MarkdownEditor) {
        editor.layoutAll()
        let view = editor.blockCanvas.view
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
    }

    func table(_ editor: MarkdownEditor) -> TableBox {
        editor.componentBox(at: 0) as! TableBox
    }

    func rendersTable(_ editor: MarkdownEditor, at location: Int = 0) -> Bool {
        let unit = editor.blockCanvas.units.unit(containing: location)
        if case .component = editor.blockCanvas.layout(unit).content.body { return true }
        return false
    }

    @Test func editsOneCellAndKeepsTheRest() {
        let original = "| a | b |\n|---|---|\n| 1 | 2 |\n\nafter\n"
        let (e, window) = editor(original)
        let box = table(e)
        let rect = box.cellRect(row: 1, column: 1)!
        #expect(e.tableCell(at: NSPoint(x: rect.midX, y: rect.midY))?.row == 1)
        let height = box.drawnRect.height
        e.beginCellEdit(box, row: 1, column: 1)
        #expect(e.cellField?.stringValue == "2")
        e.cellField?.stringValue = "a much longer value | with a pipe"
        #expect(box.drawnRect.height == height, "the table keeps its size while the cell is edited")
        e.endCellEdit(commit: true)
        #expect(e.string == "| a | b |\n|---|---|\n| 1 | a much longer value \\| with a pipe |\n\nafter\n")
        #expect(e.blockCanvas.focusedComponent?.location == 0 && rendersTable(e))
        window.undoManager?.undo()
        #expect(e.string == original && e.blockCanvas.focusedComponent?.location == 0 && rendersTable(e))
        window.undoManager?.redo()
        #expect(e.blockCanvas.focusedComponent?.location == 0 && rendersTable(e))
    }

    @Test func menuAddsRowsAndColumns() {
        let (e, _) = editor("| a | b |\n|---|---|\n| 1 | 2 |\n")
        let box = table(e)
        let rect = box.cellRect(row: 1, column: 0)!
        let menu = e.tableMenu(box, at: NSPoint(x: rect.midX, y: rect.midY))
        func run(_ title: String) {
            let item = menu.items.first { $0.title == String(localized: String.LocalizationValue(title)) }
            #expect(item != nil, "missing \(title)")
            _ = item.map { NSApp.sendAction($0.action!, to: $0.target, from: $0) }
        }
        run("Insert Row Below")
        #expect(e.string == "| a | b |\n|---|---|\n| 1 | 2 |\n|  |  |\n")
        draw(e)
        let fresh = table(e)
        let menu2 = e.tableMenu(fresh, at: NSPoint(x: rect.midX, y: rect.midY))
        _ = menu2.items.first { $0.title == String(localized: "Insert Column Right") }.map { NSApp.sendAction($0.action!, to: $0.target, from: $0) }
        #expect(e.string == "| a |   | b |\n|---| --- |---|\n| 1 |   | 2 |\n|  |   |  |\n")
    }

    @Test func menuDeletesRowsAndColumnsAfterCommittingACell() throws {
        let original = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        let (e, window) = editor(original)

        func choose(_ title: String, from box: TableBox, row: Int, column: Int) throws {
            let rect = try #require(box.cellRect(row: row, column: column))
            let menu = e.tableMenu(box, at: NSPoint(x: rect.midX, y: rect.midY))
            let item = try #require(menu.items.first { $0.title == String(localized: String.LocalizationValue(title)) })
            #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
        }

        let first = table(e)
        e.beginCellEdit(first, row: 1, column: 0)
        try choose("Delete Row", from: first, row: 1, column: 0)
        #expect(e.cellField == nil)
        #expect(e.string == "| a | b |\n|---|---|\n")
        window.undoManager?.undo()
        #expect(e.string == original)
        window.undoManager?.redo()
        #expect(e.string == "| a | b |\n|---|---|\n")

        window.undoManager?.undo()
        draw(e)
        let second = table(e)
        e.beginCellEdit(second, row: 1, column: 1)
        try choose("Delete Column", from: second, row: 1, column: 1)
        #expect(e.cellField == nil)
        #expect(e.string == "| a |\n|---|\n| 1 |\n")
        window.undoManager?.undo()
        #expect(e.string == original)
        window.undoManager?.redo()
        #expect(e.string == "| a |\n|---|\n| 1 |\n")
    }

    @Test func tableWidthModesClearDraggedColumnWidths() throws {
        let (e, _) = editor("| left | right |\n|---|---|\n| alpha beta gamma delta epsilon zeta eta theta | short |\n")
        let box = table(e)
        let rect = try #require(box.cellRect(row: 1, column: 0))

        func choose(_ title: String) throws {
            let menu = e.tableMenu(box, at: NSPoint(x: rect.midX, y: rect.midY))
            let layout = try #require(menu.items.first { $0.title == String(localized: "Table Layout") }?.submenu)
            let item = try #require(layout.items.first { $0.title == String(localized: String.LocalizationValue(title)) })
            #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
            draw(e)
        }

        try choose("Fit Content")
        let fit = try #require(box.columnWidths())
        box.resizeColumns(divider: 0, from: fit, by: -120)
        draw(e)
        #expect(box.columnWidths() != fit)

        try choose("Fit Content")
        #expect(box.columnWidths() == fit)

        box.resizeColumns(divider: 0, from: fit, by: -120)
        draw(e)
        try choose("Window Width")
        #expect(box.widthMode == .window)
        #expect(try #require(box.columnWidths()).reduce(0, +) > fit.reduce(0, +))
    }

    @Test func cellUndoRedoKeepsTheShiftedTableRenderedAfterAnExternalEdit() {
        let original = "| a |\n|---|\n| 1 |\n"
        let (e, window) = editor(original)
        e.beginCellEdit(table(e), row: 1, column: 0)
        e.cellField?.stringValue = "edited"
        e.endCellEdit(commit: true)
        let prefix = "before\n\n"
        e.blockCanvas.replaceExternally(NSRange(location: 0, length: 0), with: prefix)
        let tableLocation = (prefix as NSString).length

        window.undoManager?.undo()
        #expect(e.string == prefix + original)
        #expect(e.blockCanvas.focusedComponent?.location == tableLocation && rendersTable(e, at: tableLocation))
        window.undoManager?.redo()
        #expect(e.string == prefix + "| a |\n|---|\n| edited |\n")
        #expect(e.blockCanvas.focusedComponent?.location == tableLocation && rendersTable(e, at: tableLocation))
    }

    @Test func addersShowFromInsideTheTableOnly() {
        let (e, _) = editor("| a | b |\n|---|---|\n| 1 | 2 |\n")
        let rect = table(e).drawnRect
        let inside = e.tableAdders(at: NSPoint(x: rect.midX, y: rect.midY))
        #expect(inside?.row.isEmpty == false && inside?.column.isEmpty == false, "entering the table shows both strips")
        // From outside, the edge shows nothing; after the table, the pointer keeps them on its way out.
        #expect(e.tableAdders(at: NSPoint(x: rect.midX, y: rect.maxY + 8)) == nil)
        #expect(e.tableAdders(at: NSPoint(x: rect.maxX + 8, y: rect.midY)) == nil)
        let below = e.tableAdders(at: NSPoint(x: rect.midX, y: rect.maxY + 8), engaged: inside?.table)
        #expect(below?.row.contains(NSPoint(x: rect.midX, y: rect.maxY + 8)) == true)
        let beside = e.tableAdders(at: NSPoint(x: rect.maxX + 8, y: rect.midY), engaged: inside?.table)
        #expect(beside?.column.contains(NSPoint(x: rect.maxX + 8, y: rect.midY)) == true)
        #expect(e.tableAdders(at: NSPoint(x: rect.midX, y: rect.maxY + 40), engaged: inside?.table) == nil, "far below, they go")
    }

    @Test func adderUndoRedoKeepsTheRenderedCanvas() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        let (e, window) = editor(text)
        e.addToTable(table(e), row: true)
        e.endCellEdit(commit: false)
        #expect(!e.showsPlainText && e.blockCanvas.focusedComponent?.location == 0 && rendersTable(e))
        window.undoManager?.undo()
        #expect(e.string == text)
        #expect(!e.showsPlainText && e.blockCanvas.focusedComponent?.location == 0 && rendersTable(e))
        window.undoManager?.redo()
        #expect(e.string.contains("|  |  |"))
        #expect(!e.showsPlainText && e.blockCanvas.focusedComponent?.location == 0 && rendersTable(e))
    }

    @Test func formulaCommitsInsideItsDelimiters() {
        let (e, _) = editor("> $$\n> a+b\n> $$\n\nafter\n")
        let box = e.componentBox(at: 2) as! MathBlockBox
        let range = e.source(of: box)!
        let ns = e.string as NSString
        #expect(ns.substring(with: range).hasPrefix("$$"))
        let (tex, prefix) = e.mathSource(box)!
        #expect(tex == "a+b" && prefix == "> ")
        let controller = MathEditorController(tex: tex)
        _ = controller.view
        #expect(controller.source.string == "a+b")
        e.commitMath(box, tex: "a-b \\\\\nc", prefix: prefix)
        #expect(e.string == "> $$\n> a-b \\\\\n> c\n> $$\n\nafter\n")
    }
}
