import AppKit

/// Dragging on the block canvas, as a text view does it: the selection drags out as plain text
/// (moved within Zephyr, copied elsewhere; Option copies), text drops where the pointer is, and
/// files drop as Markdown references relative to the document (design §9: Zephyr links files where
/// they are and never copies them).
extension BlockCanvasView: NSDraggingSource {
    func dragSelection(with event: NSEvent) {
        let range = canvas.selection
        let item = NSDraggingItem(pasteboardWriter: canvas.text.substring(with: range) as NSString)
        // The picture is the selection as drawn, as much of it as is on screen.
        let frame = canvas.rects(for: range, within: visibleRect).reduce(NSRect.null) { $0.union($1) }.intersection(visibleRect)
        if !frame.isEmpty, let rep = bitmapImageRepForCachingDisplay(in: frame) {
            cacheDisplay(in: frame, to: rep)
            let image = NSImage(size: frame.size)
            image.addRepresentation(rep)
            item.setDraggingFrame(frame, contents: image)
        } else {
            item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: NSSize(width: 1, height: 1)), contents: nil)
        }
        dragged = range
        beginDraggingSession(with: [item], event: event, source: self)
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        canvas.isEditable && context == .withinApplication ? [.move, .copy] : .copy
    }

    /// Moved into another document: the text leaves this one. A drop into this view has already
    /// moved it and cleared `dragged`.
    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .move, let range = dragged, NSMaxRange(range) <= canvas.text.length {
            canvas.replace(range, with: "", actionName: String(localized: "Move"))
        }
        dragged = nil
    }

    // MARK: Drops

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canvas.isEditable else { return [] }
        setDropCaret(canvas.hit(convert(sender.draggingLocation, from: nil)).location)
        return isMove(sender) ? .move : .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) { setDropCaret(nil) }

    public override func concludeDragOperation(_ sender: NSDraggingInfo?) { setDropCaret(nil) }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropCaret(nil)
        guard canvas.isEditable else { return false }
        let location = canvas.hit(convert(sender.draggingLocation, from: nil)).location
        let pasteboard = sender.draggingPasteboard
        let text: String
        if let editor, let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            text = urls.map(editor.markdownReference(to:)).joined(separator: canvas.newline)
        } else if let string = pasteboard.string(forType: .string) {
            text = localNewlines(string)
        } else {
            return false
        }
        let moving = isMove(sender) ? dragged : nil
        if moving != nil { dragged = nil }
        window?.makeFirstResponder(self)
        return drop(text, at: location, moving: moving)
    }

    private func isMove(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? BlockCanvasView) === self && sender.draggingSourceOperationMask.contains(.move)
    }

    /// Insert `text` at `location` and select it; when it is `moving` text from this document, the
    /// original goes in the same undo step. A drop onto the moved text itself changes nothing.
    @discardableResult
    func drop(_ text: String, at location: Int, moving: NSRange? = nil) -> Bool {
        let length = (text as NSString).length
        guard let moving else {
            canvas.replace(NSRange(location: location, length: 0), with: text, select: NSRange(location: location, length: length), actionName: String(localized: "Drop"))
            return true
        }
        guard location < moving.location || location > NSMaxRange(moving) else { return false }
        let target = location > moving.location ? location - moving.length : location
        undoManager?.beginUndoGrouping()
        canvas.replace(moving, with: "")
        canvas.replace(NSRange(location: target, length: 0), with: text, select: NSRange(location: target, length: length))
        undoManager?.setActionName(String(localized: "Move"))
        undoManager?.endUndoGrouping()
        return true
    }

    func dropCaretRect(_ location: Int) -> NSRect {
        let caret = canvas.caretRect(at: location)
        return NSRect(x: caret.minX - 1, y: caret.minY, width: 2, height: caret.height)
    }

    private func setDropCaret(_ location: Int?) {
        guard location != dropCaret else { return }
        if let old = dropCaret { setNeedsDisplay(dropCaretRect(old).insetBy(dx: -1, dy: -1)) }
        dropCaret = location
        if let location { setNeedsDisplay(dropCaretRect(location).insetBy(dx: -1, dy: -1)) }
    }
}
