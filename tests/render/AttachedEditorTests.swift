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

    @Test func addersAppearOnlyAtTheMatchingTableEdge() {
        let (e, _) = editor("| a | b |\n|---|---|\n| 1 | 2 |\n")
        let rect = table(e).drawnRect
        #expect(e.tableAdders(at: NSPoint(x: rect.midX, y: rect.midY)) == nil)
        let bottom = e.tableAdders(at: NSPoint(x: rect.midX, y: rect.maxY + 4))
        #expect(bottom?.row.isEmpty == false)
        #expect(bottom?.column.isEmpty == true)
        let right = e.tableAdders(at: NSPoint(x: rect.maxX + 4, y: rect.midY))
        #expect(right?.row.isEmpty == true)
        #expect(right?.column.isEmpty == false)
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
