import AppKit
import ZephyrCore

/// Where a hovered table offers a new row and a new column.
struct TableAdders {
    weak var table: TableBox?
    var row: NSRect
    var column: NSRect
}

/// The field over a table cell while it is typed in: no border, ring or fill, so the text reads as
/// typed straight into the table.
final class CellField: NSTextField {
    weak var table: TableBox?
    var row = 0
    var column = 0
}

/// Table editing in the rendered table (design §8): a click puts the caret in the cell, and typing
/// goes there, the table growing around the text; leaving the cell writes a minimal patch
/// (`TableEdit`). Tab and Shift-Tab move along the row, Return and the arrows at a cell's first or
/// last line up and down; Tab in the last cell adds a row. The context menu adds and removes rows
/// and columns. Arrow keys into the table still reveal its source.
extension MarkdownEditor {
    func tableCell(at point: NSPoint) -> (box: TableBox, row: Int, column: Int)? {
        guard isEditable, let (box, _) = blockComponent(at: point), let table = box as? TableBox,
              let cell = table.cell(at: point) else { return nil }
        return (table, cell.row, cell.column)
    }

    /// Rewrite the table's source as one undoable minimal edit; returns the table now at that place.
    @discardableResult
    func editTable(_ box: TableBox, _ transform: (String) -> String?) -> TableBox? {
        guard let range = source(of: box) else { return nil }
        let old = source.substring(with: range)
        guard let new = transform(old) else { NSSound.beep(); return box }
        guard let patch = TextPatch.minimal(from: old, to: new) else { return box }
        let kept = selection
        replace(NSRange(location: range.location + patch.range.location, length: patch.range.length), with: patch.replacement, keepingComponent: range)
        let delta = (new as NSString).length - range.length
        guard let fresh = componentBox(at: range.location) as? TableBox else { return nil }
        // Width, position and scroll chosen for this table outlive the edit (design §8.1).
        fresh.widthOverride = box.widthOverride
        fresh.alignmentOverride = box.alignmentOverride
        fresh.scrollX = box.scrollX
        if let freshRange = source(of: fresh) {
            let selected: NSRange
            if NSMaxRange(kept) <= range.location {
                selected = kept
            } else if kept.location >= NSMaxRange(range) {
                selected = NSRange(location: kept.location + delta, length: kept.length)
            } else {
                selected = NSRange(location: freshRange.location, length: 0)
            }
            // An attached edit keeps an outside caret in place while its table remains rendered.
            blockCanvas.select(selected, focus: freshRange)
        }
        return fresh
    }

    // MARK: Cells

    func beginCellEdit(_ box: TableBox, row: Int, column: Int) {
        // Committing the open cell may rewrite a table, this one too: find this one again by place
        // (an edit before it moves it by the change in length).
        var box = box
        let mine = source(of: box), open = cellField?.table.flatMap { source(of: $0) }, before = length
        endCellEdit(commit: true)
        if source(of: box) == nil, let mine {
            let at = (open?.location ?? mine.location) < mine.location ? mine.location + length - before : mine.location
            guard let fresh = componentBox(at: at) as? TableBox else { return }
            box = fresh
        }
        guard let range = source(of: box), let text = TableEdit.cell(source.substring(with: range), row: row, column: column) else { return }
        let field = CellField(string: text)
        field.table = box
        field.row = row
        field.column = column
        field.font = box.cellFont(row: row)
        field.textColor = Palette.text
        field.alignment = box.alignment(ofColumn: column)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = self
        field.setAccessibilityLabel(String(localized: "Table cell"))
        box.editing = (row, column, text)
        surface.addSubview(field)
        cellField = field
        followCell(field)
        box.scrollToCell(row: row, column: column)
        followCell(field)
        surface.window?.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
    }

    func endCellEdit(commit: Bool) {
        guard let field = cellField else { return }
        cellField = nil
        field.delegate = nil
        let value = field.stringValue
        field.removeFromSuperview()
        guard let box = field.table else { return }
        box.editing = nil
        componentNeedsLayout(box)
        if commit { editTable(box) { TableEdit.setting($0, row: field.row, column: field.column, to: value) } }
        surface.window?.makeFirstResponder(surface)
    }

    /// The table lays the text out as it is typed, and the field keeps to its cell. NSTextField
    /// insets its text by 2 pt; a point to spare on the right keeps it from wrapping sooner.
    func followCell(_ field: CellField) {
        guard let box = field.table else { return }
        box.editing = (field.row, field.column, field.stringValue)
        componentNeedsLayout(box)
        surface.displayIfNeeded()
        guard let rect = box.cellRect(row: field.row, column: field.column) else { return }
        let inner = rect.insetBy(dx: box.padX, dy: box.padY)
        field.frame = NSRect(x: inner.minX - (field.alignment == .right ? 3 : 2), y: inner.minY, width: inner.width + 5, height: inner.height)
        field.isHidden = !box.drawnRect.insetBy(dx: -1, dy: -1).contains(rect)
    }

    /// The table scrolled sideways under the field.
    func tableDidScroll(_ box: TableBox) {
        if let field = cellField, field.table === box { followCell(field) }
    }

    /// Leaves the cell for the one `rows` and `columns` away: along a row past its end to the next
    /// row, and past the last row into a new one when moving with Tab.
    func moveCellEdit(_ field: CellField, rows: Int, columns: Int, grows: Bool) {
        let (row, column) = (field.row, field.column)
        guard let box = field.table, let range = source(of: box) else { return endCellEdit(commit: true) }
        endCellEdit(commit: true)
        guard var table = componentBox(at: range.location) as? TableBox else { return }
        var next = (row + rows, column + columns)
        if next.1 >= table.columnCount { next = (next.0 + 1, 0) }
        if next.1 < 0 { next = (next.0 - 1, table.columnCount - 1) }
        guard next.0 >= 0 else { return }
        if next.0 >= table.rowCount {
            guard grows, let grown = editTable(table, { TableEdit.insertingRow($0, before: nil, newline: newline) }) else { return }
            table = grown
        }
        surface.displayIfNeeded()  // the new table draws, so its cell rects are current
        beginCellEdit(table, row: next.0, column: next.1)
    }

    /// Tab, Shift-Tab and Return end the cell's editing with a movement.
    func cellFieldDidEnd(_ field: CellField, movement: Int?) {
        switch movement {
        case NSTextMovement.tab.rawValue?: moveCellEdit(field, rows: 0, columns: 1, grows: true)
        case NSTextMovement.backtab.rawValue?: moveCellEdit(field, rows: 0, columns: -1, grows: false)
        case NSTextMovement.return.rawValue?: moveCellEdit(field, rows: 1, columns: 0, grows: false)
        default: endCellEdit(commit: true)
        }
    }

    /// Up and down leave the cell from its first and last line; Esc puts the text back.
    func cellField(_ field: CellField, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            endCellEdit(commit: false)
        case #selector(NSResponder.moveUp(_:)) where Self.caretOnEdgeLine(textView, top: true):
            moveCellEdit(field, rows: -1, columns: 0, grows: false)
        case #selector(NSResponder.moveDown(_:)) where Self.caretOnEdgeLine(textView, top: false):
            moveCellEdit(field, rows: 1, columns: 0, grows: false)
        default:
            return false
        }
        return true
    }

    private static func caretOnEdgeLine(_ textView: NSTextView, top: Bool) -> Bool {
        guard let manager = textView.layoutManager, let container = textView.textContainer, manager.numberOfGlyphs > 0 else { return true }
        let glyph = manager.glyphIndexForCharacter(at: min(textView.selectedRange().location, textView.string.utf16.count - 1))
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = manager.usedRect(for: container)
        return top ? line.minY <= used.minY + 0.5 : line.maxY >= used.maxY - 0.5 || textView.selectedRange().location >= textView.string.utf16.count
    }

    // MARK: Adding rows and columns

    /// The "+" strips appear only when the pointer reaches the matching table edge. Their trigger
    /// reaches a little into the table and through the strip, so the pointer can travel outside the
    /// border to click without the guide disappearing in the gap.
    func tableAdders(at point: NSPoint) -> TableAdders? {
        guard isEditable else { return nil }
        for probe in [point, NSPoint(x: point.x, y: point.y - 18), NSPoint(x: point.x - 18, y: point.y)] {
            guard let table = blockCanvas.component(at: probe) as? TableBox else { continue }
            let r = table.drawnRect
            let row = NSRect(x: r.minX, y: r.maxY + 3, width: r.width, height: 12)
            let column = NSRect(x: r.maxX + 3, y: r.minY, width: 12, height: r.height)
            let rowEdge = NSRect(x: r.minX, y: r.maxY - 6, width: r.width, height: 21)
            let columnEdge = NSRect(x: r.maxX - 6, y: r.minY, width: 21, height: r.height)
            let showsRow = rowEdge.contains(point), showsColumn = columnEdge.contains(point)
            guard showsRow || showsColumn else { continue }
            return TableAdders(table: table, row: showsRow ? row : .zero, column: showsColumn ? column : .zero)
        }
        return nil
    }

    /// A new last row (or column), its first cell (or header) ready for typing.
    func addToTable(_ table: TableBox, row: Bool) {
        guard let range = source(of: table) else { return }
        endCellEdit(commit: true)
        guard let current = componentBox(at: range.location) as? TableBox,
              let grown = editTable(current, { row ? TableEdit.insertingRow($0, before: nil, newline: self.newline) : TableEdit.insertingColumn($0, before: current.columnCount) }) else { return }
        surface.displayIfNeeded()
        beginCellEdit(grown, row: row ? grown.rowCount - 1 : 0, column: row ? 0 : grown.columnCount - 1)
    }

    // MARK: Menu

    /// Rows, columns and alignment for the clicked cell; width and position for this table or all
    /// tables (design §8.1); and the source itself.
    func tableMenu(_ table: TableBox, at point: NSPoint) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, checked: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, action: action)
            item.state = checked ? .on : .off
            item.isEnabled = enabled
            return item
        }
        menu.autoenablesItems = false
        if isEditable, let (row, column) = table.cell(at: point) {
            let edit: (@escaping (String) -> String?) -> () -> Void = { [weak self, weak table] transform in {
                guard let self, let table else { return }
                self.editTable(table, transform)
            } }
            let nl = newline
            menu.addItem(item(String(localized: "Insert Row Above"), enabled: row > 0, edit { TableEdit.insertingRow($0, before: row, newline: nl) }))
            menu.addItem(item(String(localized: "Insert Row Below"), edit { TableEdit.insertingRow($0, before: row + 1 < table.rowCount ? row + 1 : nil, newline: nl) }))
            menu.addItem(item(String(localized: "Insert Column Left"), edit { TableEdit.insertingColumn($0, before: column) }))
            menu.addItem(item(String(localized: "Insert Column Right"), edit { TableEdit.insertingColumn($0, before: column + 1) }))
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "Delete Row"), enabled: row > 0, edit { TableEdit.deletingRow($0, row) }))
            menu.addItem(item(String(localized: "Delete Column"), enabled: table.columnCount > 1, edit { TableEdit.deletingColumn($0, column) }))
            menu.addItem(.separator())
            let align = NSMenu()
            align.autoenablesItems = false
            let current = table.alignment(ofColumn: column)
            align.addItem(item(String(localized: "Left Aligned"), checked: current == .left, edit { TableEdit.aligning($0, column: column, .none) }))
            align.addItem(item(String(localized: "Centered"), checked: current == .center, edit { TableEdit.aligning($0, column: column, .center) }))
            align.addItem(item(String(localized: "Right Aligned"), checked: current == .right, edit { TableEdit.aligning($0, column: column, .right) }))
            let alignItem = NSMenuItem(title: String(localized: "Column Alignment"), action: nil, keyEquivalent: "")
            alignItem.submenu = align
            menu.addItem(alignItem)
            menu.addItem(.separator())
        }
        let relayout = { [weak self, weak table] in
            guard let self, let table else { return }
            self.componentNeedsLayout(table)
            self.surface.setNeedsDisplay(self.surface.visibleRect)
        }
        let width = NSMenu()
        width.autoenablesItems = false
        width.addItem(item(String(localized: "Fit Content"), checked: table.widthMode == .fit) { table.widthOverride = .fit; relayout() })
        width.addItem(item(String(localized: "Column Width"), checked: table.widthMode == .column) { table.widthOverride = .column; relayout() })
        width.addItem(item(String(localized: "Window Width"), checked: table.widthMode == .window) { table.widthOverride = .window; relayout() })
        width.addItem(.separator())
        width.addItem(item(String(localized: "Align Center"), checked: table.alignment == .center) { table.alignmentOverride = .center; relayout() })
        width.addItem(item(String(localized: "Align Left"), checked: table.alignment == .left) { table.alignmentOverride = .left; relayout() })
        width.addItem(.separator())
        width.addItem(item(String(localized: "Use for All Tables")) { [weak self] in self?.tableDefaultsChosen?(table.widthMode, table.alignment) })
        let layoutItem = NSMenuItem(title: String(localized: "Table Layout"), action: nil, keyEquivalent: "")
        layoutItem.submenu = width
        menu.addItem(layoutItem)
        if isEditable {
            menu.addItem(item(String(localized: "Edit as Markdown")) { [weak self, weak table] in
                guard let self, let table, let range = self.source(of: table) else { return }
                self.selection = NSRange(location: range.location, length: 0)
                self.surface.window?.makeFirstResponder(self.surface)
            })
        }
        return menu
    }
}
