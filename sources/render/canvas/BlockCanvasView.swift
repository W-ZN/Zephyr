import AppKit

/// The document view of `BlockCanvas`: the text input client, selection owner
/// and VoiceOver text area (design §2 principle 6: system input methods, keyboard paths and
/// accessibility come first, also on Zephyr's own canvas).
public final class BlockCanvasView: NSView, NSTextInputClient, NSMenuItemValidation {
    weak var canvas: BlockCanvas!
    /// The document: clicks on rendered things, list continuation, the slash menu, block moves.
    weak var editor: MarkdownEditor?
    private let caret = NSTextInsertionIndicator(frame: .zero)
    private lazy var handles = BlockHandleOverlay(view: self)
    private var tracking: NSTrackingArea?
    /// The fixed end of the selection; the other end moves with Shift and dragging.
    private var anchor = 0
    private var head = 0
    private var dragUnit: (range: NSRange, granularity: Int)?
    /// A press inside the selection: it drags the selection once the pointer moves, else it is a click.
    var pendingDrag: (point: NSPoint, location: Int)?
    private var imageResize: (image: ImageBox, start: NSPoint, width: CGFloat, previewed: Bool)?
    /// A viewable component pressed with the primary button. Its preview only starts when that
    /// press finishes without becoming a drag, leaving the whole double-click interval available.
    private var pendingComponentPreviewClick: (box: ComponentBox, point: NSPoint)?
    /// A table divider drag is visual state only. The box holds the widths; this keeps the mouse
    /// gesture's fixed baseline so repeated move events do not add rounding drift.
    private var tableResize: (table: TableBox, divider: Int, start: NSPoint, widths: [CGFloat])?
    private weak var dividerHover: TableBox?
    private weak var tableScrollHover: TableBox?
    private var tableScroll: (table: TableBox, start: NSPoint, scrollX: CGFloat)?
    /// The selection being dragged out of this view, until it is dropped.
    var dragged: NSRange?
    /// Where a drop would land.
    var dropCaret: Int?
    override init(frame: NSRect) {
        super.init(frame: frame)
        caret.color = Tokens.accent
        caret.displayMode = .hidden
        addSubview(caret)
        setAccessibilityLabel(String(localized: "Document"))
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // A closing window can draw once more after its document's canvas is gone.
    public override func viewWillDraw() {
        canvas?.prepareVisible()
        super.viewWillDraw()
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let context = NSGraphicsContext.current?.cgContext else { return }
        canvas.draw(dirtyRect, in: context, underlay: handles.drawUnderlay, needsToDraw: { self.needsToDraw($0) })
        // The component taken whole: a 2 pt accent outline 4 pt outside it, no fill (selection is a
        // fill, hover a faint band); 1 pt in the third ink while the text is not focused.
        if let component = canvas.focusedComponent, let box = editor?.componentBox(at: component.location), !box.drawnRect.isEmpty {
            let active = window?.isKeyWindow != false && window?.firstResponder === self
            let width: CGFloat = active ? 2 : 1
            let ring = NSBezierPath(roundedRect: box.drawnRect.insetBy(dx: -4 - width / 2, dy: -4 - width / 2), xRadius: 8, yRadius: 8)
            ring.lineWidth = width
            (active ? Tokens.accent : Tokens.ink3).setStroke()
            ring.stroke()
        }
        handles.draw(dirtyRect)
        if let dropCaret {
            Tokens.accent.setFill()
            dropCaretRect(dropCaret).fill()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func becomeFirstResponder() -> Bool {
        updateCaret()
        if canvas?.focusedComponent != nil { needsDisplay = true }
        return true
    }

    public override func resignFirstResponder() -> Bool {
        pendingComponentPreviewClick = nil
        editor?.cancelPendingComponentPreview()
        editor?.closeSlashMenu()
        editor?.canvasDidResignFirstResponder()
        caret.displayMode = .hidden
        if canvas?.focusedComponent != nil { needsDisplay = true }
        return true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        editor?.clearLinkPreview()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func keyChanged() {
        if window?.isKeyWindow != true { editor?.clearLinkPreview() }
        updateCaret()
        if canvas?.focusedComponent != nil { needsDisplay = true }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        canvas?.appearanceChanged()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { canvas?.widthChanged() }
    }

    /// The width is always the clip view's. Autoresizing would only add the clip's change in
    /// width to the starting width, which is wrong whenever the two started apart.
    public override func resize(withOldSuperviewSize oldSize: NSSize) {
        guard let clip = superview else { return }
        setFrameSize(NSSize(width: clip.bounds.width, height: frame.height))
    }

    // MARK: - Selection and caret

    /// Called by the canvas after it changed the selection.
    func selectionChanged() {
        pendingComponentPreviewClick = nil
        editor?.cancelPendingComponentPreview()
        let s = canvas.selection
        if !(min(anchor, head) == s.location && max(anchor, head) == NSMaxRange(s)) {
            anchor = s.location
            head = NSMaxRange(s)
        }
        needsDisplay = true
        updateCaret()
        editor?.updateSlashMenu()
        editor?.updateLanguageMenu()
        editor?.updateImageMenu()
        placeHandleAgain()
    }

    /// A heading's markers hang where its handle was once the caret reveals them: the handle shown
    /// under a still pointer moves beside them at once, instead of overlapping until it moves.
    private func placeHandleAgain() {
        guard handles.handle != nil, let window, let editor else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        handles.set(editor.blockHandle(at: point))
        handles.pointer(at: point, editor: editor)
    }

    func updateCaret() {
        guard let canvas else { return }
        let focused = window?.firstResponder === self && window?.isKeyWindow != false
        guard canvas.selection.length == 0, canvas.focusedComponent == nil, canvas.isEditable, focused else {
            caret.displayMode = .hidden
            return
        }
        caret.frame = canvas.caretRect(at: canvas.selection.location)
        caret.displayMode = .automatic
    }

    private func setCaret(_ location: Int, upstream: Bool = false, keepGoal: Bool = false) {
        anchor = location
        head = location
        canvas.select(NSRange(location: location, length: 0), upstream: upstream, keepGoal: keepGoal, passing: true)
        canvas.scrollToVisible(location)
    }

    private func extend(to location: Int, upstream: Bool = false, keepGoal: Bool = false) {
        head = location
        canvas.select(NSRange(location: min(anchor, head), length: abs(head - anchor)), upstream: upstream, keepGoal: keepGoal)
        canvas.scrollToVisible(location)
    }

    private var ns: NSString { canvas.text }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        pendingComponentPreviewClick = nil
        editor?.closeSlashMenu()
        editor?.clearLinkPreview()
        editor?.cancelPendingComponentPreview()
        let point = convert(event.locationInWindow, from: nil)
        // Control-click is the secondary click: the block's menu, on the handle as on the text.
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            return NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        if let editor, handles.hits(point) {
            handles.drag(editor, extending: event.modifierFlags.contains(.shift))
            return
        }
        if let editor, let adders = handles.adders, let table = adders.table, adders.row.contains(point) || adders.column.contains(point) {
            handles.setAdders(nil)
            editor.addToTable(table, row: adders.row.contains(point))
            return
        }
        if event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty, let editor {
            if let table = canvas.component(at: point) as? TableBox,
               table.isHorizontalScrollHandleVisible, table.horizontalScrollThumb.contains(point) {
                tableScroll = (table, point, table.scrollX)
                return
            }
            if let table = canvas.component(at: point) as? TableBox,
               let divider = table.columnDivider(at: point), let widths = table.columnWidths() {
                // The cell field otherwise keeps an unsaved value over the table. Only a divider
                // click commits it; ordinary canvas clicks retain their existing semantics.
                if editor.cellField != nil {
                    editor.endCellEdit(commit: true)
                    displayIfNeeded()
                    guard let current = canvas.component(at: point) as? TableBox,
                          let currentDivider = current.columnDivider(at: point), let currentWidths = current.columnWidths() else { return }
                    tableResize = (current, currentDivider, point, currentWidths)
                } else {
                    tableResize = (table, divider, point, widths)
                }
                return
            }
            if let resize = editor.beginImageResize(at: point) {
                imageResize = (resize.image, point, resize.width, false)
                return
            }
            if let box = editor.viewerComponent(at: point), let range = editor.source(of: box) {
                if event.clickCount >= 2 {
                    if editor.isEditable { editor.enterComponentSource(box) }
                    else { _ = editor.openComponentViewer(box) }
                    return
                }
                if event.clickCount == 1 {
                    window?.makeFirstResponder(self)
                    anchor = range.location
                    head = range.location
                    canvas.select(NSRange(location: range.location, length: 0), focus: range)
                    editor.updateComponentViewerHover(at: point)
                    pendingComponentPreviewClick = (box, point)
                    return
                }
            }
        }
        if event.clickCount == 1, editor?.handleClick(at: point, event: event) == true { return }
        window?.makeFirstResponder(self)
        // A component no attached editor took: a click outlines it (as the arrow keys do), a
        // double click opens its source.
        if let editor, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty, let component = editor.clickedComponent(at: point) {
            if event.clickCount >= 2 {
                editor.hideComponentViewButton()
                anchor = NSMaxRange(component)
                head = anchor
                return canvas.select(NSRange(location: anchor, length: 0), entering: true)
            }
            anchor = component.location
            head = component.location
            canvas.select(NSRange(location: component.location, length: 0), focus: component)
            editor.updateComponentViewerHover(at: point)
            return
        }
        let hit = canvas.hit(point)
        switch event.clickCount {
        case 2:
            let word = canvas.wordRange(at: hit.location)
            dragUnit = (word, 2)
            anchor = word.location
            head = NSMaxRange(word)
            canvas.select(word)
        case 3...:
            let line = sourceLine(at: hit.location)
            dragUnit = (line, 3)
            anchor = line.location
            head = NSMaxRange(line)
            canvas.select(line)
        default:
            dragUnit = nil
            if event.modifierFlags.contains(.shift) {
                extend(to: hit.location)
            } else if canvas.selection.length > 0, canvas.rects(for: canvas.selection, within: visibleRect).contains(where: { $0.contains(point) }) {
                pendingDrag = (point, hit.location)
            } else {
                anchor = hit.location
                head = hit.location
                canvas.select(NSRange(location: hit.location, length: 0), upstream: hit.upstream, passing: true)
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if let pending = pendingComponentPreviewClick {
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - pending.point.x, point.y - pending.point.y) > 3 else { return }
        }
        pendingComponentPreviewClick = nil
        editor?.cancelPendingComponentPreview()
        if let scroll = tableScroll {
            let point = convert(event.locationInWindow, from: nil)
            scroll.table.dragHorizontalScroll(from: scroll.start, initialScrollX: scroll.scrollX, to: point)
            setNeedsDisplay(scroll.table.drawnRect)
            editor?.tableDidScroll(scroll.table)
            return
        }
        if let resize = tableResize {
            let point = convert(event.locationInWindow, from: nil)
            resize.table.resizeColumns(divider: resize.divider, from: resize.widths, by: point.x - resize.start.x)
            return
        }
        if let resize = imageResize {
            let point = convert(event.locationInWindow, from: nil)
            let width = resize.width + point.x - resize.start.x
            imageResize = (resize.image, resize.start, resize.width, true)
            editor?.previewImageResize(resize.image, width: width)
            return
        }
        if let pending = pendingDrag {
            let p = convert(event.locationInWindow, from: nil)
            guard hypot(p.x - pending.point.x, p.y - pending.point.y) > 3 else { return }
            pendingDrag = nil
            dragSelection(with: event)
            return
        }
        autoscroll(with: event)
        let location = canvas.hit(convert(event.locationInWindow, from: nil)).location
        if let (origin, granularity) = dragUnit {
            let unit = granularity == 2 ? canvas.wordRange(at: location) : sourceLine(at: location)
            let union = NSUnionRange(origin, unit)
            canvas.select(union)
            anchor = location < origin.location ? NSMaxRange(origin) : origin.location
            head = location < origin.location ? union.location : NSMaxRange(union)
        } else {
            head = location
            canvas.select(NSRange(location: min(anchor, head), length: abs(head - anchor)))
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if tableScroll != nil {
            tableScroll = nil
            return
        }
        if tableResize != nil {
            tableResize = nil
            return
        }
        if let resize = imageResize {
            imageResize = nil
            if resize.previewed { editor?.commitImageResize(resize.image, initialWidth: resize.width) }
            else { editor?.cancelImageResize(resize.image) }
            return
        }
        if let pending = pendingComponentPreviewClick {
            pendingComponentPreviewClick = nil
            dragUnit = nil
            editor?.previewComponentAfterDoubleClickInterval(pending.box)
            return
        }
        dragUnit = nil
        // Pressed in the selection without dragging: a plain click.
        if let pending = pendingDrag {
            pendingDrag = nil
            setCaret(pending.location)
        }
    }

    /// The source line (paragraph) holding `location`, its line break included.
    private func sourceLine(at location: Int) -> NSRange {
        let units = canvas.units
        let i = units.unit(containing: location)
        let line = units.line(ofUnit: i)
        let start = units.range(of: units.firstUnit(ofLine: line)).location
        let end = line + 1 < units.lineCount ? units.range(of: units.firstUnit(ofLine: line + 1)).location : canvas.text.length
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Keyboard

    public override func menu(for event: NSEvent) -> NSMenu? {
        let base = NSMenu()
        base.addItem(withTitle: String(localized: "Cut"), action: #selector(cut(_:)), keyEquivalent: "")
        base.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        base.addItem(withTitle: String(localized: "Paste"), action: #selector(paste(_:)), keyEquivalent: "")
        let point = convert(event.locationInWindow, from: nil)
        // On a handle: the menu of that handle's block.
        if handles.hits(point), let block = handles.handle?.block, let editor { return editor.textMenu(at: point, base: base, block: block) }
        return editor?.contextMenu(at: point, base: base) ?? base
    }

    public override func mouseMoved(with event: NSEvent) {
        guard isUnderPointer(event.locationInWindow) else {
            // Over a panel, card or page laid over the text: nothing of the text under it reacts.
            handles.set(nil)
            handles.setAdders(nil)
            editor?.updatePropertyHover(at: nil)
            editor?.updateImageResizeHover(at: nil)
            editor?.hideComponentViewButton()
            editor?.linkPreviewPointerExited()
            updateTableDividerHighlight(at: nil, modifiers: event.modifierFlags)
            updateTableScrollHover(at: nil)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        updateTableScrollHover(at: point)
        updateTableDividerHighlight(at: point, modifiers: event.modifierFlags)
        if handles.hits(point) {
            editor?.linkPreviewPointerExited()
            editor?.updateImageResizeHover(at: nil)
            handles.pointer(at: point, editor: editor)
            NSCursor.openHand.set()
            return
        }
        handles.set(editor?.blockHandle(at: point))
        handles.pointer(at: point, editor: editor)
        handles.setAdders(editor?.tableAdders(at: point, engaged: handles.adders?.table))
        handles.pointerMoved()
        if let adders = handles.adders, adders.row.contains(point) || adders.column.contains(point) {
            editor?.linkPreviewPointerExited()
            editor?.updateImageResizeHover(at: nil)
            NSCursor.pointingHand.set()
            return
        }
        editor?.updatePropertyHover(at: point)
        editor?.updateImageResizeHover(at: point)
        editor?.updateComponentViewerHover(at: point)
        editor?.updateLinkPreview(at: point)
        pointer(at: point, modifiers: event.modifierFlags).set()
    }

    public override func cursorUpdate(with event: NSEvent) {
        guard isUnderPointer(event.locationInWindow) else { return }
        pointer(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags).set()
    }

    /// The pointer over the text (design §8.2): an open hand on a block's handle (it drags), a
    /// pointing hand on what a click acts on (a checkbox, a table's adders, a link with ⌘), an
    /// I-beam elsewhere.
    private func pointer(at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> NSCursor {
        if handles.hits(point) { return .openHand }
        if modifiers.intersection([.command, .shift, .option, .control]).isEmpty,
           let table = canvas.component(at: point) as? TableBox,
           table.isHorizontalScrollHandleVisible, table.horizontalScrollThumb.contains(point) { return .openHand }
        if modifiers.intersection([.command, .shift, .option, .control]).isEmpty,
           let table = canvas.component(at: point) as? TableBox, table.columnDivider(at: point) != nil { return .resizeLeftRight }
        if editor?.imageResize(at: point) != nil { return .resizeLeftRight }
        if let adders = handles.adders, adders.row.contains(point) || adders.column.contains(point) { return .pointingHand }
        return editor?.wantsPointingHand(at: point, modifiers: modifiers) == true ? .pointingHand : .iBeam
    }

    private func updateTableDividerHighlight(at point: NSPoint?, modifiers: NSEvent.ModifierFlags) {
        let table: TableBox? = point.flatMap { point in
            guard modifiers.intersection([.command, .shift, .option, .control]).isEmpty else { return nil }
            return canvas.component(at: point) as? TableBox
        }
        let divider = point.flatMap { point in table?.columnDivider(at: point) }
        if dividerHover !== table {
            dividerHover?.highlightColumnDivider(nil)
            dividerHover = table
        }
        table?.highlightColumnDivider(divider)
    }

    private func updateTableScrollHover(at point: NSPoint?) {
        let table = point.flatMap { canvas.component(at: $0) as? TableBox }
        if tableScrollHover !== table {
            tableScrollHover?.setHorizontalScrollHovered(false)
            tableScrollHover = table
        }
        table?.setHorizontalScrollHovered(true)
    }

    /// The canvas is the view under the pointer, not a panel, card, page or the outline laid over
    /// it. Tracking areas see the pointer through those, so the text only chooses the pointer (and
    /// shows its handles) where it is what the reader points at; the others set their own.
    private func isUnderPointer(_ locationInWindow: NSPoint) -> Bool {
        guard let content = window?.contentView else { return false }
        let point = content.superview.map { $0.convert(locationInWindow, from: nil) } ?? locationInWindow
        return content.hitTest(point)?.isDescendant(of: self) == true
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        handles.set(nil)
        handles.setAdders(nil)
        editor?.updatePropertyHover(at: nil)
        editor?.updateImageResizeHover(at: nil)
        editor?.hideComponentViewButton()
        editor?.linkPreviewPointerExited()
        updateTableDividerHighlight(at: nil, modifiers: event.modifierFlags)
        updateTableScrollHover(at: nil)
    }

    public override func scrollWheel(with event: NSEvent) {
        pendingComponentPreviewClick = nil
        editor?.cancelPendingComponentPreview()
        editor?.hideComponentViewButton()
        handles.set(nil)
        handles.setAdders(nil)
        editor?.updateImageResizeHover(at: nil)
        editor?.closeSlashMenu()
        editor?.clearLinkPreview()
        // Sideways over a table or formula that scrolls in its room: it scrolls, not the page.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), let box = canvas.component(at: convert(event.locationInWindow, from: nil)), box.scrollWidth > 0 {
            box.scrollX = min(max(box.scrollX - event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 8), 0), box.scrollWidth)
            setNeedsDisplay(box.drawnRect.insetBy(dx: 0, dy: -4))
            (box as? TableBox).map { editor?.tableDidScroll($0) }
            return
        }
        super.scrollWheel(with: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(point), isUnderPointer(window.mouseLocationOutsideOfEventStream) {
            pointer(at: point, modifiers: event.modifierFlags).set()
        }
    }

    public override func keyDown(with event: NSEvent) {
        pendingComponentPreviewClick = nil
        editor?.cancelPendingComponentPreview()
        handles.set(nil)
        editor?.hideComponentViewButton()
        editor?.clearLinkPreview()
        if inputContext?.handleEvent(event) != true { interpretKeyEvents([event]) }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           editor?.openSelectedComponentViewer() == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    public override func doCommand(by selector: Selector) {
        if editor?.slashMenuHandles(selector) == true { return }
        if responds(to: selector) { perform(selector, with: nil) } else { super.doCommand(by: selector) }
    }

    private func move(_ extending: Bool, keepGoal: Bool = false, upstream: Bool = false, _ target: (Int) -> Int) {
        let to = target(head)
        if extending { extend(to: to, keepGoal: keepGoal) } else { setCaret(to, upstream: upstream, keepGoal: keepGoal) }
    }

    /// Shift-Left and Shift-Right take a component whole: from its outline, or when the moving end
    /// of the selection steps into it (design §8.1).
    private func extendByCharacter(forward: Bool) {
        if let component = focusedComponent {
            anchor = forward ? component.location : NSMaxRange(component)
            return extend(to: forward ? NSMaxRange(component) : component.location)
        }
        var to = forward ? nextCharacter(head) : previousCharacter(head)
        if let r = canvas.presenter?.drawnComponent(around: to), to > r.location, to < NSMaxRange(r) { to = forward ? NSMaxRange(r) : r.location }
        extend(to: to)
    }

    /// One character back or forward: a composed sequence, and CR LF as one line break (NSString
    /// treats them as two, which would leave a lone CR behind a Backspace).
    private func previousCharacter(_ i: Int) -> Int {
        guard i > 0 else { return 0 }
        if i >= 2, ns.character(at: i - 1) == 0x0A, ns.character(at: i - 2) == 0x0D { return i - 2 }
        return ns.rangeOfComposedCharacterSequence(at: i - 1).location
    }
    private func nextCharacter(_ i: Int) -> Int {
        guard i < ns.length else { return ns.length }
        if i + 1 < ns.length, ns.character(at: i) == 0x0D, ns.character(at: i + 1) == 0x0A { return i + 2 }
        return NSMaxRange(ns.rangeOfComposedCharacterSequence(at: i))
    }

    /// The visual line holding `i`: its start and its end (before the line break).
    private func visualLine(_ i: Int) -> (start: Int, end: Int) { canvas.visualLine(i) }

    private func moveVertically(_ lines: Int, extending: Bool) {
        if !extending, let below = canvas.belowComponent {
            // Below the last component: Up takes it whole, there is nothing further down.
            if lines < 0 { go(to: (below.location, false, below), extending: false) }
            return
        }
        go(to: canvas.verticalTarget(from: head, lines: lines), extending: extending)
    }


    /// Where Up, Down, Page Up and Page Down arrive. A block component is entered whole: outlined,
    /// still drawn; extending a selection takes it in whole. On a line of text, the goal x is found
    /// again once the line shows what the caret reveals (design §8.1).
    private func go(to target: (location: Int, upstream: Bool, component: NSRange?), extending: Bool) {
        // An outlined component at the start or end of the document stays outlined: there is no
        // line beyond it, and its source is not where the arrow keys go.
        if !extending, target.component == nil, let focused = focusedComponent, target.location >= focused.location, target.location <= NSMaxRange(focused) {
            // Past a component that ends the file: the line below it, not yet in the file.
            if target.location == ns.length, canvas.lastComponent == focused { setCaret(ns.length) }
            return
        }
        if let component = target.component {
            if extending {
                extend(to: head < component.location ? NSMaxRange(component) : component.location, keepGoal: true)
            } else {
                anchor = component.location
                head = component.location
                canvas.select(NSRange(location: component.location, length: 0), keepGoal: true, focus: component)
                canvas.scrollToVisible(component.location)
            }
            return
        }
        if extending {
            extend(to: target.location, upstream: target.upstream, keepGoal: true)
        } else {
            setCaret(target.location, upstream: target.upstream, keepGoal: true)
        }
        // At the document's ends the caret goes to its first or last position, whatever the goal.
        guard target.location > 0, target.location < ns.length else { return }
        if let settled = canvas.goalPosition(on: head), settled.location != head {
            extending ? extend(to: settled.location, upstream: settled.upstream, keepGoal: true) : setCaret(settled.location, upstream: settled.upstream, keepGoal: true)
        }
    }

    /// The component the arrow keys stopped on, if any.
    private var focusedComponent: NSRange? { canvas.focusedComponent }

    public override func moveLeft(_ sender: Any?) {
        let s = canvas.selection
        if let component = focusedComponent, component.location == 0 { return }
        if let below = canvas.belowComponent { return go(to: (below.location, false, below), extending: false) }
        s.length > 0 ? setCaret(s.location) : setCaret(previousCharacter(s.location))
    }
    public override func moveRight(_ sender: Any?) {
        let s = canvas.selection
        // From an outlined component: past it, not into its source.
        if let component = focusedComponent {
            // Past the one that ends the file: the line below it.
            guard NSMaxRange(component) < ns.length else { return setCaret(ns.length) }
            return setCaret(nextCharacter(NSMaxRange(component)))
        }
        if canvas.belowComponent != nil { return }
        s.length > 0 ? setCaret(NSMaxRange(s)) : setCaret(nextCharacter(s.location))
    }
    public override func moveBackward(_ sender: Any?) { moveLeft(sender) }
    public override func moveForward(_ sender: Any?) { moveRight(sender) }
    public override func moveUp(_ sender: Any?) { moveVertically(-1, extending: false) }
    public override func moveDown(_ sender: Any?) { moveVertically(1, extending: false) }
    public override func moveWordLeft(_ sender: Any?) { move(false) { self.canvas.nextWord(from: $0, forward: false) } }
    public override func moveWordRight(_ sender: Any?) { move(false) { self.canvas.nextWord(from: $0, forward: true) } }
    public override func moveWordBackward(_ sender: Any?) { moveWordLeft(sender) }
    public override func moveWordForward(_ sender: Any?) { moveWordRight(sender) }
    public override func moveToBeginningOfLine(_ sender: Any?) { move(false) { self.visualLine($0).start } }
    public override func moveToEndOfLine(_ sender: Any?) { move(false, upstream: true) { self.visualLine($0).end } }
    public override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
    public override func moveToRightEndOfLine(_ sender: Any?) { moveToEndOfLine(sender) }
    public override func moveToBeginningOfParagraph(_ sender: Any?) { move(false) { self.sourceLine(at: $0).location } }
    public override func moveToEndOfParagraph(_ sender: Any?) { move(false) { self.paragraphEnd($0) } }
    public override func moveToBeginningOfDocument(_ sender: Any?) { setCaret(0) }
    public override func moveToEndOfDocument(_ sender: Any?) { setCaret(ns.length) }
    public override func pageUp(_ sender: Any?) { page(-1, extending: false) }
    public override func pageDown(_ sender: Any?) { page(1, extending: false) }

    public override func moveLeftAndModifySelection(_ sender: Any?) { extendByCharacter(forward: false) }
    public override func moveRightAndModifySelection(_ sender: Any?) { extendByCharacter(forward: true) }
    public override func moveBackwardAndModifySelection(_ sender: Any?) { moveLeftAndModifySelection(sender) }
    public override func moveForwardAndModifySelection(_ sender: Any?) { moveRightAndModifySelection(sender) }
    public override func moveUpAndModifySelection(_ sender: Any?) { moveVertically(-1, extending: true) }
    public override func moveDownAndModifySelection(_ sender: Any?) { moveVertically(1, extending: true) }
    public override func moveWordLeftAndModifySelection(_ sender: Any?) { move(true) { self.canvas.nextWord(from: $0, forward: false) } }
    public override func moveWordRightAndModifySelection(_ sender: Any?) { move(true) { self.canvas.nextWord(from: $0, forward: true) } }
    public override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { move(true) { self.visualLine($0).start } }
    public override func moveToEndOfLineAndModifySelection(_ sender: Any?) { move(true) { self.visualLine($0).end } }
    public override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { moveToBeginningOfLineAndModifySelection(sender) }
    public override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { moveToEndOfLineAndModifySelection(sender) }
    public override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) { move(true) { self.sourceLine(at: $0).location } }
    public override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) { move(true) { self.paragraphEnd($0) } }
    public override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { extend(to: 0) }
    public override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { extend(to: ns.length) }
    public override func pageUpAndModifySelection(_ sender: Any?) { page(-1, extending: true) }
    public override func pageDownAndModifySelection(_ sender: Any?) { page(1, extending: true) }

    public override func scrollPageUp(_ sender: Any?) { scrollBy(-(canvas.scrollView.contentView.bounds.height - canvas.lineHeight * 2)) }
    public override func scrollPageDown(_ sender: Any?) { scrollBy(canvas.scrollView.contentView.bounds.height - canvas.lineHeight * 2) }
    public override func scrollToBeginningOfDocument(_ sender: Any?) { canvas.scroll(toCharacter: 0) }
    public override func scrollToEndOfDocument(_ sender: Any?) { scrollBy(.greatestFiniteMagnitude) }
    public override func scrollLineUp(_ sender: Any?) { scrollBy(-canvas.lineHeight) }
    public override func scrollLineDown(_ sender: Any?) { scrollBy(canvas.lineHeight) }
    public override func centerSelectionInVisibleArea(_ sender: Any?) {
        canvas.scroll(toCharacter: canvas.selection.location, margin: canvas.scrollView.contentView.bounds.height / 2)
    }

    private func paragraphEnd(_ i: Int) -> Int {
        let line = sourceLine(at: i)
        var end = NSMaxRange(line)
        while end > line.location, [0x0A, 0x0D].contains(ns.character(at: end - 1)) { end -= 1 }
        return end
    }

    private func scrollBy(_ dy: CGFloat) {
        let clip = canvas.scrollView.contentView
        let y = min(max(0, clip.bounds.minY + dy), max(0, frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y))
        canvas.scrollView.reflectScrolledClipView(clip)
    }

    private func page(_ direction: CGFloat, extending: Bool) {
        let height = canvas.scrollView.contentView.bounds.height - canvas.lineHeight * 2
        let lines = Int(height / canvas.lineHeight) * Int(direction)
        let target = canvas.verticalTarget(from: head, lines: lines)
        scrollBy(direction * height)
        go(to: target, extending: extending)
    }

    public override func selectAll(_ sender: Any?) {
        anchor = 0
        head = ns.length
        canvas.select(NSRange(location: 0, length: ns.length))
    }

    // MARK: - Editing commands

    private func deletion(_ range: NSRange) {
        guard canvas.isEditable else { return NSSound.beep() }
        let s = canvas.selection
        if s.length > 0 { return canvas.replace(s, with: "") }
        guard range.length > 0 else { return }
        if NSMaxRange(range) == s.location { canvas.deleteBackward(range) } else { canvas.replace(range, with: "", select: NSRange(location: range.location, length: 0)) }
    }

    public override func deleteBackward(_ sender: Any?) {
        if let component = focusedComponent { return removeComponent(component) }
        // Below the last component nothing is in the file yet: Backspace takes the component.
        if let below = canvas.belowComponent { return go(to: (below.location, false, below), extending: false) }
        if canvas.selection.length == 0, editor?.deleteListMarkerBackward() == true || editor?.deleteBlockStartBackward() == true || editor?.deleteEmptyPair() == true { return }
        let i = canvas.selection.location
        deletion(NSRange(location: previousCharacter(i), length: i - previousCharacter(i)))
    }
    public override func deleteForward(_ sender: Any?) {
        if let component = focusedComponent { return removeComponent(component) }
        let i = canvas.selection.location
        deletion(NSRange(location: i, length: nextCharacter(i) - i))
    }
    public override func deleteWordBackward(_ sender: Any?) {
        let i = canvas.selection.location, start = canvas.nextWord(from: i, forward: false)
        deletion(NSRange(location: start, length: i - start))
    }
    public override func deleteWordForward(_ sender: Any?) {
        let i = canvas.selection.location, end = canvas.nextWord(from: i, forward: true)
        deletion(NSRange(location: i, length: end - i))
    }
    public override func deleteToBeginningOfLine(_ sender: Any?) {
        let i = canvas.selection.location, start = visualLine(i).start
        deletion(NSRange(location: start, length: i - start))
    }
    public override func deleteToEndOfLine(_ sender: Any?) {
        // To the end of the line; at the end, the line break itself (like Control-K in text views).
        let i = canvas.selection.location, end = visualLine(i).end
        deletion(NSRange(location: i, length: (end > i ? end : nextCharacter(i)) - i))
    }
    public override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) { deleteBackward(sender) }

    /// Delete on an outlined component removes its block in one undoable step.
    private func removeComponent(_ component: NSRange) {
        guard canvas.isEditable, let editor else { return NSSound.beep() }
        editor.deleteComponent(component)
    }

    public override func insertNewline(_ sender: Any?) {
        guard canvas.isEditable else { return NSSound.beep() }
        // Return on an outlined component edits it.
        if let component = focusedComponent, let editor { return editor.editComponent(at: component) }
        if hasMarkedText() { unmarkText() }
        // Below the last component the editor's line rules do not apply: the caret's line is new.
        if let editor, canvas.belowComponent == nil { _ = editor.insertNewline() } else { canvas.insertNewline() }
        canvas.scrollToVisible(canvas.selection.location)
    }
    public override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }
    public override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }
    public override func insertTab(_ sender: Any?) {
        if editor?.shiftListItem(outdent: false) == true || editor?.nestBlock(outdent: false) == true { return }
        insertText("\t", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    public override func insertBacktab(_ sender: Any?) { _ = editor?.shiftListItem(outdent: true) == true || editor?.nestBlock(outdent: true) == true }
    public override func insertTabIgnoringFieldEditor(_ sender: Any?) { insertTab(sender) }
    public override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { unmarkText() } else if editor?.find.isOpen == true { editor?.find.close() } else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }

    @objc public func copy(_ sender: Any?) {
        let s = focusedComponent ?? canvas.selection
        guard s.length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ns.substring(with: s), forType: .string)
    }

    @objc public func cut(_ sender: Any?) {
        if let component = focusedComponent, canvas.isEditable {
            copy(sender)
            return removeComponent(component)
        }
        guard canvas.isEditable, canvas.selection.length > 0 else { return }
        copy(sender)
        canvas.replace(canvas.selection, with: "", actionName: String(localized: "Cut"))
    }

    @objc public func paste(_ sender: Any?) {
        // An outlined component takes no text, pasted or typed.
        if focusedComponent != nil { return NSSound.beep() }
        guard canvas.isEditable, let text = NSPasteboard.general.string(forType: .string) else { return }
        let pasted = localNewlines(text)
        canvas.replace(canvas.selection, with: canvas.separator(before: pasted, at: canvas.selection) + pasted, actionName: String(localized: "Paste"))
        canvas.scrollToVisible(canvas.selection.location)
    }

    /// Pasted and dropped line breaks follow the file's (design §5).
    func localNewlines(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return canvas.newline == "\n" ? unified : unified.replacingOccurrences(of: "\n", with: canvas.newline)
    }

    @objc public func pasteAsPlainText(_ sender: Any?) { paste(sender) }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        // Formats are text edits and work in plain text too; moving blocks needs the rendered structure.
        case #selector(toggleBoldface(_:)), #selector(toggleItalics(_:)), #selector(toggleStrikethrough(_:)), #selector(toggleInlineCode(_:)),
             #selector(toggleUnderlined(_:)), #selector(toggleHighlight(_:)),
             #selector(insertMarkdownLink(_:)), #selector(applyHeading(_:)), #selector(toggleBulletList(_:)), #selector(toggleNumberedList(_:)),
             #selector(toggleTaskList(_:)), #selector(toggleBlockQuote(_:)), #selector(insertCodeBlock(_:)):
            return canvas.isEditable && editor != nil && focusedComponent == nil
        case #selector(moveBlockUp(_:)), #selector(moveBlockDown(_:)):
            return canvas.isEditable && editor != nil && canvas.mode == .rendered
        case #selector(editProperties(_:)):
            return canvas.isEditable && editor?.hasFrontMatter == true
        case #selector(copy(_:)): return canvas.selection.length > 0 || focusedComponent != nil
        case #selector(cut(_:)): return canvas.isEditable && (canvas.selection.length > 0 || focusedComponent != nil)
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)): return canvas.isEditable && NSPasteboard.general.string(forType: .string) != nil
        default: return true
        }
    }

    // MARK: - Markdown commands (the Format menu, design §8)

    @objc public func toggleBoldface(_ sender: Any?) { format { $0.toggleWrap("**") } }
    @objc public func toggleItalics(_ sender: Any?) { format { $0.toggleWrap("*") } }
    @objc public func toggleStrikethrough(_ sender: Any?) { format { $0.toggleWrap("~~") } }
    @objc public func toggleInlineCode(_ sender: Any?) { format { $0.toggleWrap("`") } }
    @objc public func toggleUnderlined(_ sender: Any?) { format { $0.toggleWrap("<u>", close: "</u>") } }
    @objc public func toggleHighlight(_ sender: Any?) { format { $0.toggleWrap("<mark>", close: "</mark>") } }
    @objc public func insertMarkdownLink(_ sender: Any?) { format { $0.insertLink() } }
    @objc public func applyHeading(_ sender: Any?) { format { $0.setHeading((sender as? NSMenuItem)?.tag ?? 0) } }
    @objc public func toggleBulletList(_ sender: Any?) { format { $0.toggleLinePrefix("bullet") } }
    @objc public func toggleNumberedList(_ sender: Any?) { format { $0.toggleLinePrefix("number") } }
    @objc public func toggleTaskList(_ sender: Any?) { format { $0.toggleLinePrefix("task") } }
    @objc public func toggleBlockQuote(_ sender: Any?) { format { $0.toggleLinePrefix("quote") } }
    @objc public func insertCodeBlock(_ sender: Any?) { format { $0.insertCodeBlock() } }

    /// A Format command edits the caret's line or selection; below the last component it acts on
    /// the line it adds (an outlined component takes none).
    private func format(_ command: (MarkdownEditor) -> Void) {
        guard let editor, focusedComponent == nil else { return NSSound.beep() }
        if canvas.belowComponent != nil { canvas.type("", replacing: canvas.selection) }
        command(editor)
    }

    @objc public func moveBlockUp(_ sender: Any?) { editor?.moveBlock(up: true) }
    @objc public func moveBlockDown(_ sender: Any?) { editor?.moveBlock(up: false) }
    @objc public func editProperties(_ sender: Any?) { editor?.editProperties() }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        editor?.clearLinkPreview()
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // An outlined component takes no text: Return edits it.
        guard canvas.isEditable, focusedComponent == nil || canvas.markedRange != nil else { return NSSound.beep() }
        if let marked = canvas.markedRange {
            canvas.commitMarked(text, in: marked)
        } else if replacementRange.location == NSNotFound, editor?.typePaired(text) == true {
            // `$` and `*` typed in pairs.
        } else {
            let target = replacementRange.location != NSNotFound ? replacementRange : canvas.selection
            canvas.type(text, replacing: target)
            // A slash at the start of an empty line opens the menu (design §8).
            if text == "/" || text == "、" { editor?.slashTyped(at: canvas.selection.location - 1) }
            if text == "!" { editor?.bangTyped(at: canvas.selection.location - 1) }
            if text == ">" { editor?.closeTagTyped() }
        }
        canvas.scrollToVisible(canvas.selection.location)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        editor?.clearLinkPreview()
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard canvas.isEditable, focusedComponent == nil else { return }
        let target = canvas.markedRange ?? (replacementRange.location != NSNotFound ? replacementRange : canvas.selection)
        canvas.mark(text, replacing: target, selected: selectedRange)
        canvas.scrollToVisible(canvas.selection.location)
    }

    public func unmarkText() {
        guard let marked = canvas.markedRange else { return }
        canvas.commitMarked(ns.substring(with: marked), in: marked)
    }

    public func selectedRange() -> NSRange { canvas.selection }
    public func markedRange() -> NSRange { canvas.markedRange ?? NSRange(location: NSNotFound, length: 0) }
    public func hasMarkedText() -> Bool { canvas.markedRange != nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let r = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        actualRange?.pointee = r
        return NSAttributedString(string: ns.substring(with: r), attributes: [.font: canvas.typography.bodyFont])
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let rect = range.length > 0 ? (canvas.rects(for: range).first ?? canvas.caretRect(at: range.location)) : canvas.caretRect(at: range.location)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return NSNotFound }
        return canvas.characterIndex(at: convert(window.convertPoint(fromScreen: point), from: nil))
    }

    // MARK: - Accessibility (a text area: value, selection, lines, frames)

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityValue() -> Any? { canvas.text }
    public override func accessibilityNumberOfCharacters() -> Int { ns.length }
    public override func accessibilitySelectedTextRange() -> NSRange { canvas.selection }
    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        anchor = range.location
        head = NSMaxRange(range)
        canvas.select(range)
    }
    public override func accessibilitySelectedText() -> String? { ns.substring(with: canvas.selection) }
    public override func accessibilityVisibleCharacterRange() -> NSRange { canvas.visibleCharacterRange }
    public override func accessibilityString(for range: NSRange) -> String? {
        ns.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: ns.length)))
    }
    public override func accessibilityLine(for index: Int) -> Int { canvas.units.line(ofUnit: canvas.units.unit(containing: index)) }
    public override func accessibilityRange(forLine line: Int) -> NSRange {
        let units = canvas.units
        guard line >= 0, line < units.lineCount else { return NSRange(location: NSNotFound, length: 0) }
        let start = units.range(of: units.firstUnit(ofLine: line)).location
        let end = line + 1 < units.lineCount ? units.range(of: units.firstUnit(ofLine: line + 1)).location : ns.length
        return NSRange(location: start, length: end - start)
    }
    public override func accessibilityInsertionPointLineNumber() -> Int { accessibilityLine(for: canvas.selection.location) }
    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        let rects = range.length > 0 ? canvas.rects(for: range) : [canvas.caretRect(at: range.location)]
        let union = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
        return window?.convertToScreen(convert(union, to: nil)) ?? union
    }
    public override func accessibilityRange(for point: NSPoint) -> NSRange {
        let i = characterIndex(for: point)
        guard i != NSNotFound, i < ns.length else { return NSRange(location: ns.length, length: 0) }
        return ns.rangeOfComposedCharacterSequence(at: i)
    }
}

extension BlockCanvas {
    /// The input method's composition replaces `target`; it is not an undo step until committed.
    func mark(_ text: String, replacing target: NSRange, selected: NSRange) {
        var target = target
        if markedRange == nil, !separator(before: text, at: target).isEmpty {
            // Below a component the composition starts a paragraph: the line breaks go in first,
            // as the start of the typing the committed text continues.
            type("", replacing: target)
            target = selection
        }
        if markedRange == nil { markOrigin = (target, self.text.substring(with: target)) }
        performUntracked(target, with: text)
        let length = (text as NSString).length
        markedRange = length > 0 ? NSRange(location: target.location, length: length) : nil
        let caret = NSRange(location: target.location + min(selected.location, length), length: min(selected.length, max(0, length - selected.location)))
        if markedRange == nil, let origin = markOrigin {
            // Composition cancelled: what it replaced comes back.
            performUntracked(NSRange(location: target.location, length: 0), with: origin.text)
            markOrigin = nil
            select(NSRange(location: origin.range.location, length: (origin.text as NSString).length))
            return
        }
        select(caret)
    }

    /// The composition ends with `text`: one typing step from the text before it began.
    func commitMarked(_ text: String, in marked: NSRange) {
        guard let origin = markOrigin else {
            markedRange = nil
            return type(text, replacing: marked)
        }
        performUntracked(marked, with: origin.text)
        markedRange = nil
        markOrigin = nil
        type(text, replacing: origin.range)
    }
}
