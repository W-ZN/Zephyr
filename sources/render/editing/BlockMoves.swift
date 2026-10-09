import AppKit
import ZephyrCore

/// Moving blocks (design §8 "拖动块"): ⌥⌘↑ / ⌥⌘↓ and the hover handle. Blocks come from the
/// chunks around the place in question, never from parsing the whole document; lists are never
/// split across chunks, so a list's items are always complete siblings.
extension MarkdownEditor {
    /// Blocks of the chunks covering `range`, plus one chunk on each side, in document offsets.
    func blocks(near range: NSRange) -> [MarkdownBlock] {
        // The block canvas keeps the chunks in its presenter.
        guard let structure = blockCanvas.presenter?.structure else { return [] }
        let chunks = structure.chunks
        guard !chunks.isEmpty else { return [] }
        let length = source.length
        let first = max(0, structure.index.index(containing: min(range.location, max(0, length - 1))) - 1)
        let last = min(chunks.count - 1, structure.index.index(containing: min(NSMaxRange(range), max(0, length - 1))) + 1)
        let start = chunks[first].range.location
        let region = NSRange(location: start, length: NSMaxRange(chunks[last].range) - start)
        if let cache = blockCache, cache.revision == revision, cache.region.location <= region.location,
           NSMaxRange(region) <= NSMaxRange(cache.region) { return cache.blocks }
        let text = source.substring(with: region)
        let blocks = BlockMap.blocks(in: text, atDocumentStart: start == 0).map {
            MarkdownBlock(range: NSRange(location: $0.range.location + start, length: $0.range.length),
                          group: $0.group < 0 ? -1 : $0.group + start, isListItem: $0.isListItem)
        }
        blockCache = (revision, region, blocks)
        return blocks
    }

    /// Top of a block's first line (above its block gap), the top of its text (below the gap), the
    /// vertical center of the first line's text, and where the block starts on the left: a list
    /// item at its marker, anything else at the column (quote bars included), a heading whose
    /// markers hang in the margin at those.
    func blockGeometry(_ block: MarkdownBlock) -> (top: CGFloat, textTop: CGFloat, center: CGFloat, left: CGFloat)? {
        guard block.range.location < length else { return nil }
        let p = blockCanvas.place(block.range.location)
        let content = p.layout.content, m = content.metrics
        let top = blockCanvas.top(of: p.unit)
        let center = top + content.gap + (content.component != nil ? 14 : m.spacingBefore + m.lineHeight / 2)
        var left = blockCanvas.columnX + (block.isListItem ? m.indent - typography.listIndent : 0)
        if p.layout.hang > 0 { left = min(left, blockCanvas.columnX + p.layout.xs[0]) }
        return (top, top + content.gap, center, left)
    }

    /// The hover handle for the block under `point`, in text view coordinates.
    func blockHandle(at point: NSPoint) -> (block: MarkdownBlock, rect: NSRect)? {
        guard isEditable, let index = characterIndex(at: point) else { return nil }
        guard let block = BlockMap.block(at: index, in: blocks(near: NSRange(location: index, length: 0))),
              let g = blockGeometry(block) else { return nil }
        // A table or formula wider than the column has the handle outside its own left edge.
        var left = g.left
        if let box = componentBox(at: block.range.location), box.isBlock, box.drawnRect.minX < left { left = box.drawnRect.minX }
        return (block, NSRect(x: left - 26, y: (g.center - 11).rounded(), width: 18, height: 22))
    }

    /// The handle's rect for the block under `point` (snapshots and checks).
    public func handleRect(at point: NSPoint) -> NSRect? { blockHandle(at: point)?.rect }

    /// What a block covers on screen, for the faint band shown while its handle is hovered: from
    /// the top of its text to the bottom of its last line, across the column (or the component).
    func blockScope(_ block: MarkdownBlock) -> NSRect? {
        guard let g = blockGeometry(block) else { return nil }
        let column = self.column
        var rect = NSRect(x: min(g.left, column.x) - 6, y: g.textTop - 3, width: 0, height: max(8, blockBottom(block) - g.textTop + 6))
        rect.size.width = column.x + column.width + 6 - rect.minX
        if let box = componentBox(at: block.range.location), box.isBlock, !box.drawnRect.isEmpty { rect = rect.union(box.drawnRect.insetBy(dx: -6, dy: -3)) }
        return rect
    }

    /// What a click on a block's handle selects (design §8): the text the block shows, from after
    /// its first line's markers (`#`, `- `, `> `, a task box) to the end of its last line, without
    /// the line break; a fenced code block's code; a setext heading's text line. Nil for a block
    /// component: it is outlined instead.
    func visibleText(of block: MarkdownBlock) -> NSRange? {
        let ns = source
        if let box = componentBox(at: block.range.location), box.isBlock { return nil }
        let range = Self.withoutTerminator(block.range, in: ns)
        let firstLine = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let firstEnd = Self.withoutTerminator(firstLine, in: ns)
        var start = range.location, end = NSMaxRange(range)
        if lineMetrics(at: range.location)?.kind == .fence {
            // Between the fences (an unclosed block runs to its end).
            let lastLine = ns.lineRange(for: NSRange(location: max(range.location, end - 1), length: 0))
            start = min(NSMaxRange(firstLine), end)
            let closed = lastLine.location > range.location && lineMetrics(at: lastLine.location)?.kind == .fence
            end = max(start, closed ? Self.withoutTerminator(NSRange(location: start, length: lastLine.location - start), in: ns).upperBound : end)
            return NSRange(location: start, length: end - start)
        }
        if NSMaxRange(firstLine) < end, lineMetrics(at: NSMaxRange(firstLine))?.kind == .setextUnderline { end = NSMaxRange(firstEnd) }
        let head = ns.substring(with: firstEnd) as NSString
        // Indented code is literal: only a quote's markers come before it.
        let prefix = lineMetrics(at: range.location)?.kind == .code ? #"^(?:[ \t]*>[ \t]?)*"# : #"^(?:[ \t]*>[ \t]?)*[ \t]*(?:(?:[-*+]|\d{1,9}[.)])(?:[ \t]+|$)(?:\[[ xX]\](?:[ \t]+|$))?)?(?:#{1,6}(?:[ \t]+|$))?"#
        let markers = head.range(of: prefix, options: .regularExpression)
        if markers.location != NSNotFound { start = min(end, start + markers.length) }
        return NSRange(location: start, length: end - start)
    }

    /// A click on a block's handle: its text selected, or a component outlined. With Shift, the
    /// selection grows to take the block's text in.
    func handleClicked(_ block: MarkdownBlock, extending: Bool) {
        // A component is taken whole: outlined alone, or covered whole by a growing selection.
        let component = componentBox(at: block.range.location).flatMap { $0.isBlock ? source(of: $0) : nil }
        if extending {
            var current = blockCanvas.focusedComponent ?? selection
            if current.length == 0, blockCanvas.focusedComponent == nil { current = visibleText(of: block) ?? current }
            selection = NSUnionRange(current, component ?? visibleText(of: block) ?? current)
            return
        }
        // The block's text, or a component's whole source (it stays drawn, under the selection).
        if let component {
            selection = component
        } else if let text = visibleText(of: block) {
            selection = text
        }
    }

    /// The menu of a block (its handle's: clicked or right-clicked), like Notion's: turn it into
    /// another kind, duplicate, copy, move or delete it.
    public func blockMenu(_ block: MarkdownBlock) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, symbol: String? = nil, tag: Int = 0, to target: NSMenu = menu) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = surface
            item.tag = tag
            item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            target.addItem(item)
        }
        let component = componentBox(at: block.range.location).map(\.isBlock) == true
        if !component {
            let turn = NSMenu()
            add(String(localized: "Body Text"), #selector(BlockCanvasView.applyHeading(_:)), symbol: "textformat", tag: 0, to: turn)
            for level in 1...3 { add(String(localized: "Heading \(level)"), #selector(BlockCanvasView.applyHeading(_:)), tag: level, to: turn) }
            turn.addItem(.separator())
            add(String(localized: "Bulleted List"), #selector(BlockCanvasView.toggleBulletList(_:)), symbol: "list.bullet", to: turn)
            add(String(localized: "Numbered List"), #selector(BlockCanvasView.toggleNumberedList(_:)), symbol: "list.number", to: turn)
            add(String(localized: "Checklist"), #selector(BlockCanvasView.toggleTaskList(_:)), symbol: "checklist", to: turn)
            add(String(localized: "Block Quote"), #selector(BlockCanvasView.toggleBlockQuote(_:)), symbol: "text.quote", to: turn)
            add(String(localized: "Code Block"), #selector(BlockCanvasView.insertCodeBlock(_:)), symbol: "chevron.left.forwardslash.chevron.right", to: turn)
            let turnItem = NSMenuItem(title: String(localized: "Turn Into"), action: nil, keyEquivalent: "")
            turnItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            turnItem.submenu = turn
            menu.addItem(turnItem)
        }
        menu.addItem(ClosureMenuItem(title: String(localized: "Duplicate Block")) { [weak self] in self?.duplicate(block) })
        menu.items.last?.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
        add(String(localized: "Copy"), #selector(BlockCanvasView.copy(_:)), symbol: "doc.on.doc")
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        add(String(localized: "Move Block Up"), #selector(BlockCanvasView.moveBlockUp(_:)), up, [.command, .option], symbol: "arrow.up")
        add(String(localized: "Move Block Down"), #selector(BlockCanvasView.moveBlockDown(_:)), down, [.command, .option], symbol: "arrow.down")
        menu.addItem(ClosureMenuItem(title: String(localized: "Delete Block")) { [weak self] in self?.delete(block) })
        menu.items.last?.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(.separator())
        // The window's controller answers this (the responder chain from the text).
        let ask = NSMenuItem(title: String(localized: "Ask AI"), action: Selector(("toggleAIPanel:")), keyEquivalent: "j")
        ask.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(ask)
        return menu
    }

    /// Select the block's text (the right-click menu acts on it); a component is covered whole.
    func selectText(in block: MarkdownBlock) {
        if let box = componentBox(at: block.range.location), box.isBlock, let range = source(of: box) { selection = range; return }
        selection = visibleText(of: block) ?? Self.withoutTerminator(block.range, in: source)
    }

    /// Move the block at the caret past its previous or next sibling; the caret moves with it.
    public func moveBlock(up: Bool) {
        let sel = selection
        let all = blocks(near: sel)
        guard isEditable, let block = BlockMap.block(at: sel.location, in: all) else { NSSound.beep(); return }
        let group = BlockMap.siblings(of: block, in: all)
        guard let i = group.firstIndex(of: block) else { return }
        if up {
            guard i > 0 else { NSSound.beep(); return }
            move(block, before: group[i - 1], siblings: group, caretOffset: sel.location - block.range.location, selectionLength: sel.length)
        } else {
            guard i + 1 < group.count else { NSSound.beep(); return }
            move(block, before: i + 2 < group.count ? group[i + 2] : nil, siblings: group, caretOffset: sel.location - block.range.location, selectionLength: sel.length)
        }
    }

    /// One undoable minimal edit; the selection keeps its place inside the moved block.
    func move(_ block: MarkdownBlock, before target: MarkdownBlock?, siblings: [MarkdownBlock], caretOffset: Int, selectionLength: Int) {
        let old = source as String
        guard let (text, location) = BlockMap.moved(block, before: target, siblings: siblings, in: old, newline: newline),
              let patch = TextPatch.minimal(from: old, to: text) else { return }
        replace(patch.range, with: patch.replacement)
        let caret = min(location + max(0, caretOffset), source.length)
        selection = NSRange(location: caret, length: min(selectionLength, source.length - caret))
        scrollSelectionToVisible()
    }
}

extension MarkdownEditor {
    /// Bottom of a block's last line: the drop slot after it.
    func blockBottom(_ block: MarkdownBlock) -> CGFloat {
        let last = max(block.range.location, NSMaxRange(block.range) - 1)
        return blockCanvas.lineBox(at: last).maxY
    }

    /// Right-click in the text (design §8): on the selection, its formats; elsewhere the block
    /// under the pointer is selected and the menu acts on it. Ask AI sees the selection.
    /// The right-click menu. On a handle, the block's menu. On text, as in any Mac text: a click
    /// outside the selection selects the word there; then Look Up, the edit commands, the formats
    /// and the assistant (a link adds Open and Copy). Block actions stay on the handle.
    func textMenu(at point: NSPoint, base: NSMenu?, block handleBlock: MarkdownBlock? = nil) -> NSMenu? {
        if isEditable, let handleBlock {
            handleClicked(handleBlock, extending: false)
            return blockMenu(handleBlock)
        }
        guard let index = characterIndex(at: point) else { return base }
        if !(selection.length > 0 && index >= selection.location && index <= NSMaxRange(selection)) {
            selection = blockCanvas.wordRange(at: index)
        }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = surface
            item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        if let destination = link(at: point) {
            menu.addItem(ClosureMenuItem(title: String(localized: "Preview Link")) { [weak self] in self?.previewLink(destination, at: point) })
            menu.addItem(ClosureMenuItem(title: String(localized: "Open Link")) { [weak self] in self?.openLink?(destination) })
            menu.addItem(ClosureMenuItem(title: String(localized: "Copy Link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(destination, forType: .string)
            })
            menu.addItem(.separator())
        }
        let selected = selection.length > 0 ? source.substring(with: selection) : ""
        if !selected.isEmpty, selected.count <= 60, !selected.contains(where: \.isNewline) {
            menu.addItem(ClosureMenuItem(title: String(localized: "Look Up “\(selected)”")) { [weak self] in self?.lookUp(selected) })
            menu.addItem(.separator())
        }
        for item in base?.items ?? [] {
            base?.removeItem(item)
            menu.addItem(item)
        }
        guard isEditable else { return menu }
        menu.addItem(.separator())
        add(String(localized: "Bold"), #selector(BlockCanvasView.toggleBoldface(_:)), "b", symbol: "bold")
        add(String(localized: "Italic"), #selector(BlockCanvasView.toggleItalics(_:)), "i", symbol: "italic")
        add(String(localized: "Strikethrough"), #selector(BlockCanvasView.toggleStrikethrough(_:)), "x", [.command, .shift], symbol: "strikethrough")
        add(String(localized: "Inline Code"), #selector(BlockCanvasView.toggleInlineCode(_:)), "`", .control, symbol: "chevron.left.forwardslash.chevron.right")
        add(String(localized: "Link"), #selector(BlockCanvasView.insertMarkdownLink(_:)), "k", symbol: "link")
        menu.addItem(.separator())
        // The window's controller answers this (the responder chain from the text).
        let ask = NSMenuItem(title: String(localized: "Ask AI"), action: Selector(("toggleAIPanel:")), keyEquivalent: "j")
        ask.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(ask)
        return menu
    }

    /// The system's dictionary panel for `text`, at the selection.
    func lookUp(_ text: String) {
        let caret = blockCanvas.caretRect(at: selection.location)
        let font = blockCanvas.typography.bodyFont
        surface.showDefinition(for: NSAttributedString(string: text, attributes: [.font: font]), at: NSPoint(x: caret.maxX - 1, y: caret.maxY - 1 - font.descender.magnitude))
    }

    /// A block's lines without the last one's line break: what a selection of it covers.
    static func withoutTerminator(_ range: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(range)
        while end > range.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: range.location, length: end - range.location)
    }

    /// A copy of the block right after it, selected: the next item of a list, or a block of its own
    /// after a blank line.
    func duplicate(_ block: MarkdownBlock) {
        let lines = Self.withoutTerminator(block.range, in: source)
        let copy = source.substring(with: lines), gap = block.isListItem ? newline : newline + newline
        replace(NSRange(location: NSMaxRange(lines), length: 0), with: gap + copy)
        selection = NSRange(location: NSMaxRange(lines) + (gap as NSString).length, length: (copy as NSString).length)
    }

    /// The block and, between two blank lines, one of them.
    func delete(_ block: MarkdownBlock) {
        var range = block.range
        let text = source
        let blankBefore = range.location == 0 || (range.location >= 2 && text.character(at: range.location - 2) == 0x0A)
        if blankBefore, NSMaxRange(range) < text.length, text.character(at: NSMaxRange(range)) == 0x0A { range.length += 1 }
        replace(range, with: "")
    }

    /// The reading column's left edge and width in the canvas view (the drop line spans it).
    public var column: (x: CGFloat, width: CGFloat) {
        (blockCanvas.columnX, blockCanvas.columnWidth)
    }
}

/// The hover handle beside the block under the pointer, and what a drag by it shows: the block
/// dimmed in place, a picture of it under the pointer, the drop line gliding between slots, and
/// the block settling where it lands. Each canvas view owns one and forwards drawing and pointer
/// events to it; the drag's views exist only while it lasts.
@MainActor
final class BlockHandleOverlay {
    private unowned let view: NSView
    private(set) var handle: (block: MarkdownBlock, rect: NSRect)?
    private(set) var adders: TableAdders?
    /// The pointer is on the handle: the block it acts on shows as a faint band.
    private(set) var hot = false
    /// The handle is held down (before a drag begins, or a click ends).
    private var pressed = false
    /// Where that band is drawn (beneath the text).
    private var scope: NSRect?

    init(view: NSView) { self.view = view }

    func draw(_ dirtyRect: NSRect) {
        if let handle, handle.rect.intersects(dirtyRect) { drawHandle(handle.rect) }
        if let adders {
            for rect in [adders.row, adders.column] where !rect.isEmpty && rect.intersects(dirtyRect) { drawAdder(rect) }
        }
    }

    /// The handle answers within 24 × 24 pt around its dots, a little more than it draws.
    func hits(_ point: NSPoint) -> Bool { handle.map { $0.rect.insetBy(dx: -3, dy: -1).contains(point) } ?? false }

    /// Beneath the text: the band over the block whose handle the pointer is on, at 60% of the
    /// hover token's own strength.
    func drawUnderlay(_ dirtyRect: NSRect) {
        guard hot, let scope, scope.intersects(dirtyRect) else { return }
        let hover = Tokens.hover.usingColorSpace(.sRGB) ?? Tokens.hover
        hover.withAlphaComponent(hover.alphaComponent * 0.6).setFill()
        NSBezierPath(roundedRect: scope, xRadius: 6, yRadius: 6).fill()
    }

    /// The pointer moved: whether it is on the handle, and the band that goes with it.
    func pointer(at point: NSPoint, editor: MarkdownEditor?) {
        let on = hits(point)
        guard on != hot else { return }
        hot = on
        if let scope { view.setNeedsDisplay(scope.insetBy(dx: -1, dy: -1)) }
        scope = on ? handle.flatMap { editor?.blockScope($0.block) } : nil
        if let scope { view.setNeedsDisplay(scope.insetBy(dx: -1, dy: -1)) }
        if let handle { view.setNeedsDisplay(handle.rect) }
    }

    /// Six dots, like Notion's block handle: third ink beside the block under the pointer, the
    /// hover tint and second ink on the handle, the pressed tint and the text ink while held.
    private func drawHandle(_ rect: NSRect) {
        if hot || pressed {
            (pressed ? Tokens.pressed : Tokens.hover).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        (pressed ? Tokens.ink : hot ? Tokens.ink2 : Tokens.ink3).setFill()
        for column in 0..<2 {
            for row in 0..<3 {
                let center = NSPoint(x: rect.midX + (CGFloat(column) - 0.5) * 5, y: rect.midY + CGFloat(row - 1) * 5)
                NSBezierPath(ovalIn: NSRect(x: center.x - 1.25, y: center.y - 1.25, width: 2.5, height: 2.5)).fill()
            }
        }
    }

    /// A quiet strip with a plus; firmer under the pointer.
    private func drawAdder(_ rect: NSRect) {
        let hot = view.window.map { rect.contains(view.convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        (hot ? Tokens.hover : Tokens.hover.withAlphaComponent(0.55)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (hot ? Tokens.ink2 : Tokens.ink3).setFill()
        let c = NSPoint(x: rect.midX, y: rect.midY)
        NSRect(x: c.x - 4, y: c.y - 0.75, width: 8, height: 1.5).fill()
        NSRect(x: c.x - 0.75, y: c.y - 4, width: 1.5, height: 8).fill()
    }

    func setAdders(_ new: TableAdders?) {
        guard new?.row != adders?.row || new?.column != adders?.column else { return }
        for rect in [adders?.row, adders?.column, new?.row, new?.column].compactMap({ $0 }).filter({ !$0.isEmpty }) { view.setNeedsDisplay(rect.insetBy(dx: -1, dy: -1)) }
        adders = new
    }

    /// Redraws a strip as the pointer moves onto or off it.
    func pointerMoved() {
        for rect in [adders?.row, adders?.column].compactMap({ $0 }).filter({ !$0.isEmpty }) { view.setNeedsDisplay(rect.insetBy(dx: -1, dy: -1)) }
    }

    func set(_ new: (block: MarkdownBlock, rect: NSRect)?) {
        guard new?.block != handle?.block || new?.rect != handle?.rect else { return }
        if let old = handle { view.setNeedsDisplay(old.rect) }
        if hot, let scope { view.setNeedsDisplay(scope.insetBy(dx: -1, dy: -1)) }
        hot = false
        scope = nil
        handle = new
        if let new { view.setNeedsDisplay(new.rect) }
    }

    /// Drag the whole block; a click selects its text without the final line break (Shift adds it
    /// to the selection), or outlines a component.
    func drag(_ editor: MarkdownEditor, extending: Bool = false) {
        guard let block = handle?.block, let window = view.window, let top = editor.blockGeometry(block)?.textTop else { return }
        let siblings = BlockMap.siblings(of: block, in: editor.blocks(near: editor.visibleCharacters()))
        guard let index = siblings.firstIndex(of: block) else { return }
        // Drop slots: in the middle of the gap before each sibling, and below the last one.
        var slots: [(y: CGFloat, before: MarkdownBlock?)] = siblings.compactMap { s in editor.blockGeometry(s).map { (($0.top + $0.textTop) / 2, s) } }
        if let last = siblings.last { slots.append((editor.blockBottom(last) + 4, nil)) }
        let column = editor.column
        var source = NSRect(x: column.x - 8, y: top, width: column.width + 16, height: max(editor.blockBottom(block) - top, 8))
        // A table or formula wider than the column is carried whole.
        if let box = editor.componentBox(at: block.range.location), box.isBlock, !box.drawnRect.isEmpty { source = source.union(box.drawnRect.insetBy(dx: -8, dy: 0)) }
        let down = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let start = down.y
        var chosen: Int?
        var drag: (dim: NSView, ghost: NSView, line: NSView)?
        pressed = true
        if let handle { view.setNeedsDisplay(handle.rect) }
        defer {
            pressed = false
            if let handle { view.setNeedsDisplay(handle.rect) }
        }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), event.type == .leftMouseDragged {
            let point = view.convert(event.locationInWindow, from: nil)
            // A press that moves less than 4 pt is still a click.
            if drag == nil, hypot(point.x - down.x, point.y - down.y) < 4 { continue }
            view.autoscroll(with: event)
            let y = point.y
            if drag == nil {
                drag = beginDrag(source)
                NSCursor.closedHand.push()
            }
            drag?.ghost.setFrameOrigin(NSPoint(x: source.minX, y: source.minY + y - start))
            let slot = slots.indices.min { abs(slots[$0].y - y) < abs(slots[$1].y - y) }
            if let slot, slot != chosen, let line = drag?.line {
                let frame = NSRect(x: column.x, y: slots[slot].y - 1, width: column.width, height: 2)
                if chosen == nil || !Self.animates { line.frame = frame } else {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.09
                        line.animator().frame = frame
                    }
                }
                line.isHidden = false
            }
            chosen = slot
        }
        if drag != nil { NSCursor.pop() }
        guard let chosen, let drag else {
            window.makeFirstResponder(view)
            let rect = handle?.rect
            set(nil)
            editor.handleClicked(block, extending: extending)
            // A click selects the block and opens its menu under the handle; Shift only extends.
            if !extending, let rect, editor.isEditable { editor.blockMenu(block).popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: view) }
            return
        }
        drag.line.removeFromSuperview()
        // Slots `index` and `index + 1` put the block where it already is: it glides back.
        guard chosen != index, chosen != index + 1 else { return endDrag(drag, at: source, landed: false) }
        set(nil)
        editor.move(block, before: slots[chosen].before, siblings: siblings, caretOffset: 0, selectionLength: 0)
        let moved = editor.selectedRange.location
        guard let landed = BlockMap.block(at: moved, in: editor.blocks(near: NSRange(location: moved, length: 0))),
              let newTop = editor.blockGeometry(landed)?.textTop else { return endDrag(drag, at: nil, landed: false) }
        endDrag(drag, at: NSRect(x: source.minX, y: newTop, width: source.width, height: max(editor.blockBottom(landed) - newTop, 8)), landed: true)
    }

    private static var animates: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The block dimmed where it is, a picture of it to carry, and the (hidden) drop line.
    private func beginDrag(_ source: NSRect) -> (dim: NSView, ghost: NSView, line: NSView) {
        let image = NSImage(size: source.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: source) {
            view.cacheDisplay(in: source, to: rep)
            image.addRepresentation(rep)
        }
        let dim = NSView(frame: source)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = Tokens.canvas.withAlphaComponent(0.6).cgColor
        let ghost = NSImageView(frame: source)
        ghost.image = image
        ghost.imageScaling = .scaleNone
        ghost.wantsLayer = true
        ghost.layer?.backgroundColor = Tokens.canvas.cgColor
        ghost.layer?.cornerRadius = 6
        ghost.alphaValue = 0.9
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        ghost.shadow = shadow
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Tokens.accent.cgColor
        line.layer?.cornerRadius = 1
        line.isHidden = true
        for v in [dim, line, ghost] { view.addSubview(v) }
        return (dim, ghost, line)
    }

    /// The picture glides to where the block now is (or back) and fades; a moved block glows
    /// briefly in the accent.
    private func endDrag(_ drag: (dim: NSView, ghost: NSView, line: NSView), at target: NSRect?, landed: Bool) {
        drag.dim.removeFromSuperview()
        guard Self.animates, let target else { return drag.ghost.removeFromSuperview() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            drag.ghost.animator().setFrameOrigin(target.origin)
            drag.ghost.animator().alphaValue = 0
        }, completionHandler: { drag.ghost.removeFromSuperview() })
        guard landed else { return }
        let glow = NSView(frame: target)
        glow.wantsLayer = true
        glow.layer?.backgroundColor = Tokens.accent.withAlphaComponent(0.1).cgColor
        glow.layer?.cornerRadius = 6
        view.addSubview(glow, positioned: .below, relativeTo: nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            glow.animator().alphaValue = 0
        }, completionHandler: { glow.removeFromSuperview() })
    }
}
