import AppKit
import ZephyrCore

/// The field over one front matter value while it is edited in place.
final class PropertyField: NSTextField {
    var entry = 0
    var key = ""
}

/// In-place property editing (design §6, §8): clicking a value of a top-level single-line scalar
/// opens a field over it; committing writes only that value's bytes (`FrontMatterEdit`) as one
/// undoable edit. Everything else in the front matter is edited as source.
extension MarkdownEditor: NSTextFieldDelegate {
    /// The editable value under `point`.
    func propertyEntry(at point: NSPoint) -> Int? {
        guard isEditable, !frontMatterCollapsed, let box = frontMatterBox(),
              let i = box.valueRects.firstIndex(where: { $0.insetBy(dx: -6, dy: -1).contains(point) }),
              box.model.entries[i].valueRange.location != NSNotFound else { return nil }
        return i
    }

    func updatePropertyHover(at point: NSPoint?) {
        guard let box = frontMatterBox() else { return }
        let i = point.flatMap(propertyEntry(at:))
        guard i != box.hoveredEntry else { return }
        box.hoveredEntry = i
        surface.setNeedsDisplay(box.drawnRect.insetBy(dx: -8, dy: -4))
    }

    func beginPropertyEdit(_ index: Int) {
        endPropertyEdit(commit: true)
        guard let box = frontMatterBox(), box.valueRects.indices.contains(index) else { return }
        let entry = box.model.entries[index]
        let field = PropertyField(string: entry.value)
        field.entry = index
        field.key = entry.key
        field.font = box.valueFont
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = Tokens.canvas
        field.focusRingType = .exterior
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel(entry.key)
        // NSTextField insets its text by 2 pt; shift so the text stays where it was drawn.
        let rect = box.valueRects[index]
        field.frame = NSRect(x: rect.minX - 2, y: rect.minY - 1, width: rect.width + 2, height: ceil(field.intrinsicContentSize.height))
        box.hoveredEntry = nil
        surface.addSubview(field)
        propertyField = field
        surface.window?.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
    }

    /// Keyboard path (design §8 辅助功能): edit the first editable value; Tab moves on.
    public func editProperties() {
        if frontMatterCollapsed {
            frontMatterCollapsed = false
            frontMatterCollapseToggled?(false)
        }
        scrollToTop()
        surface.displayIfNeeded()
        guard let box = frontMatterBox(), let first = box.model.entries.indices.first(where: { box.model.entries[$0].valueRange.location != NSNotFound }) else {
            NSSound.beep()
            return
        }
        beginPropertyEdit(first)
    }

    func endPropertyEdit(commit: Bool) {
        guard let field = propertyField else { return }
        propertyField = nil
        field.delegate = nil
        let value = field.stringValue
        field.removeFromSuperview()
        if commit, let box = frontMatterBox(), box.model.entries.indices.contains(field.entry), box.model.entries[field.entry].key == field.key,
           let patch = FrontMatterEdit.patch(setting: box.model.entries[field.entry], to: value, in: source as String) {
            replace(patch.range, with: patch.replacement)
        }
        surface.window?.makeFirstResponder(surface)
    }

    // MARK: Field delegate (property and table cell fields)

    public func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? CellField, field === cellField { followCell(field) }
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        if let field = notification.object as? CellField, field === cellField { return cellFieldDidEnd(field, movement: movement) }
        guard let field = notification.object as? PropertyField, field === propertyField else { return }
        let entry = field.entry
        endPropertyEdit(commit: true)
        // Tab and Shift-Tab move between editable values, like a form.
        guard movement == NSTextMovement.tab.rawValue || movement == NSTextMovement.backtab.rawValue else { return }
        surface.displayIfNeeded()  // the edited box draws, so its value rects are current
        guard let box = frontMatterBox() else { return }
        let editable = box.model.entries.indices.filter { box.model.entries[$0].valueRange.location != NSNotFound }
        let next = movement == NSTextMovement.tab.rawValue ? editable.first { $0 > entry } : editable.last { $0 < entry }
        if let next { beginPropertyEdit(next) }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if let field = control as? CellField, field === cellField { return cellField(field, textView: textView, doCommandBy: selector) }
        guard selector == #selector(NSResponder.cancelOperation(_:)), control === propertyField else { return false }
        endPropertyEdit(commit: false)
        return true
    }
}
