import AppKit

/// Document features share the canvas's text, selection, geometry and undo operations.
extension MarkdownEditor {
    var source: NSString { blockCanvas.text }
    var selection: NSRange {
        get { selectedRange }
        set { blockCanvas.select(newValue) }
    }
    var surface: NSView { focusView }
    var editUndo: UndoManager? { focusView.undoManager }
    var surfaceHasMarkedText: Bool { blockCanvas.view.hasMarkedText() }
    func typeText(_ string: String, replacing range: NSRange) { blockCanvas.type(string, replacing: range) }
    func scrollToTop() { blockCanvas.scroll(toCharacter: 0) }
    func scrollSelectionToVisible() { blockCanvas.scrollToVisible(blockCanvas.selection.location) }
    func lineMetrics(at location: Int) -> LineMetrics? {
        let i = blockCanvas.units.unit(containing: min(location, length))
        let start = blockCanvas.units.range(of: blockCanvas.units.firstUnit(ofLine: blockCanvas.units.line(ofUnit: i))).location
        return blockCanvas.presenter?.lineMetrics(at: start)
    }
    func componentBox(at location: Int) -> ComponentBox? { blockCanvas.presenter?.attribute(.zComponent, at: location) as? ComponentBox }
    func linkDestination(at location: Int) -> String? { blockCanvas.presenter?.attribute(.zLink, at: location) as? String }
    func screenRect(for range: NSRange) -> NSRect { blockCanvas.view.firstRect(forCharacterRange: range, actualRange: nil) }
    func characterIndex(at point: NSPoint) -> Int? {
        let i = blockCanvas.characterIndex(at: point)
        return i < length ? i : nil
    }
    func blockComponent(at point: NSPoint) -> (box: ComponentBox, range: NSRange)? {
        guard let box = blockCanvas.component(at: point) else { return nil }
        return (box, box.lastKnownRange)
    }
    func frontMatterBox() -> FrontMatterBox? {
        guard blockCanvas.units.count > 0 else { return nil }
        return blockCanvas.layout(0).content.component as? FrontMatterBox
    }
    var hasFrontMatter: Bool { componentBox(at: 0) is FrontMatterBox }
    func source(of box: ComponentBox) -> NSRange? {
        let r = box.lastKnownRange
        guard r.location != NSNotFound, NSMaxRange(r) <= length, componentBox(at: r.location) === box else { return nil }
        return r
    }
    func visibleCharacters() -> NSRange {
        let visible = scrollView.contentView.bounds
        let a = blockCanvas.characterIndex(at: NSPoint(x: 0, y: visible.minY - visible.height))
        let b = blockCanvas.characterIndex(at: NSPoint(x: visible.maxX, y: visible.maxY + visible.height))
        return NSRange(location: a, length: max(0, b - a))
    }
}
