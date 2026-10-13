import AppKit
import ZephyrCore

/// One document, one block canvas. Core Text shapes each unit; Zephyr owns layout and editing.
/// Very large or mostly long-line files use the same canvas as source.
@MainActor
public final class MarkdownEditor: NSObject, @preconcurrency RenderContext {
    public enum Canvas: Sendable { case automatic, block, source }
    public let blockCanvas: BlockCanvas
    public var scrollView: NSScrollView { blockCanvas.scrollView }
    public private(set) var typography: Typography
    public var baseURL: URL?
    /// The app's preference for remote images (design §9). Off, a click on a waiting image allows
    /// them for this document while it is open. Quick Look never loads them.
    public var remoteImagesPreferred = false {
        didSet { if remoteImagesPreferred != oldValue { blockCanvas.view.needsDisplay = true } }
    }
    private var remoteImagesAllowedHere = false
    public var loadsRemoteImages: Bool { remoteImagesPreferred || remoteImagesAllowedHere }
    /// Animated GIFs play on screen (the app's preference; previews and output keep stills).
    public var isShowing: Bool {
        guard let window = scrollView.window else { return false }
        return window.occlusionState.contains(.visible) && !scrollView.isHiddenOrHasHiddenAncestor
    }
    public var animatesImages = false {
        didSet { if !animatesImages { GIFPlayer.shared.stopAll(); blockCanvas.view.needsDisplay = true } }
    }
    public var frontMatterCollapsed = false {
        didSet {
            guard frontMatterCollapsed != oldValue else { return }
            blockCanvas.invalidate(range: NSRange(location: 0, length: 0))
        }
    }
    public var frontMatterCollapseToggled: ((Bool) -> Void)?
    public var tableDefaultsChosen: ((Typography.TableWidth, Typography.BlockAlignment) -> Void)?
    public var newline = "\n" { didSet { blockCanvas.newline = newline } }
    public var openLink: ((String) -> Void)?
    /// Opens an assistant draft with the preview's bounded excerpt; it never sends a request.
    public var askLinkPreview: ((String, String) -> Void)?
    public var structureDidChange: (() -> Void)?
    private var findController: FindController?
    /// Find and Replace for this document, created when first used.
    public var find: FindController {
        if let findController { return findController }
        let controller = FindController(editor: self)
        findController = controller
        return controller
    }
    public var selectionDidChange: (() -> Void)?
    private(set) var revision = 0
    var blockCache: (revision: Int, region: NSRange, blocks: [MarkdownBlock])?
    var slashMenu: SlashMenu?
    var languageMenu: SlashMenu?
    /// The image suggestion after a typed `!`.
    var imageMenu: SlashMenu?
    /// The fence line where Escape put the language list away (until the caret leaves it).
    var languageDismissed: Int?
    var propertyField: PropertyField?
    var cellField: CellField?
    private var linkPreview: LinkPreviewController?
    private var componentViewer: ComponentViewer?
    private var componentViewButton: ComponentOverlayButton?
    private var componentMenuButton: ComponentOverlayButton?
    private weak var previewComponent: ComponentBox?
    private weak var hoveredResizeImage: ImageBox?
    private var pendingComponentPreview: (id: UUID, work: DispatchWorkItem)?

    public init(text: String, typography: Typography, baseURL: URL?, isEditable: Bool = true, canvas: Canvas = .automatic) {
        self.typography = typography
        self.baseURL = baseURL
        let mode: BlockCanvas.Mode
        switch canvas {
        case .source: mode = .source
        case .block: mode = .rendered
        case .automatic: mode = text.utf8.count >= 20_000 && BlockCanvas.prefers(text as NSString) ? .source : .rendered
        }
        blockCanvas = BlockCanvas(text: NSMutableString(string: text), typography: typography, mode: mode)
        super.init()
        blockCanvas.attach(context: self)
        blockCanvas.view.editor = self
        blockCanvas.isEditable = isEditable
        NotificationCenter.default.addObserver(self, selector: #selector(scrollPositionChanged), name: NSView.boundsDidChangeNotification, object: blockCanvas.scrollView.contentView)
        blockCanvas.selectionDidChange = { [weak self] in self?.selectionDidChange?() }
        blockCanvas.textDidChange = { [weak self] in
            self?.cancelPendingComponentPreview()
            self?.clearLinkPreview()
            self?.hideComponentViewButton()
            self?.revision += 1
            self?.findController?.documentChanged()
            DispatchQueue.main.async { self?.structureDidChange?() }
        }
    }

    /// Reload from disk: earlier undo steps no longer match the text.
    public func load(_ text: String) {
        blockCanvas.replaceExternally(NSRange(location: 0, length: length), with: text)
        focusView.undoManager?.removeAllActions()
    }
    public var string: String { blockCanvas.text as String }
    /// An input method's composition is under way.
    public var isComposing: Bool { blockCanvas.markedRange != nil }
    public var length: Int { blockCanvas.text.length }
    /// A merged change from another app: not an undo step; the writer's own steps stay undoable
    /// where it did not reach into them.
    public func applyExternal(_ patch: TextPatch) {
        blockCanvas.replaceExternally(patch.range, with: patch.replacement)
    }
    public func apply(typography newTheme: Typography) {
        cancelPendingComponentPreview()
        clearLinkPreview()
        hideComponentViewButton()
        componentViewer?.dismiss()
        typography = newTheme
        blockCanvas.apply(typography: newTheme)
    }
    /// Plain-text writing (⌘/): the Markdown as written, on the same canvas, with the same text,
    /// selection and undo. Fields open over a table cell or a property are committed first.
    public var showsPlainText: Bool { blockCanvas.mode == .source }
    public func setPlainText(_ on: Bool) {
        guard on != showsPlainText else { return }
        cancelPendingComponentPreview()
        componentViewer?.dismiss()
        hideComponentViewButton()
        closeSlashMenu()
        if cellField != nil { endCellEdit(commit: true) }
        if propertyField != nil { endPropertyEdit(commit: true) }
        blockCanvas.setMode(on ? .source : .rendered)
        blockCache = nil
        structureDidChange?()
    }
    public func componentNeedsLayout(_ box: ComponentBox) {
        if box.lastKnownRange.location != NSNotFound { blockCanvas.invalidate(range: box.lastKnownRange) }
    }
    public func componentNeedsDisplay(_ box: ComponentBox) {
        blockCanvas.redrawComponent(box.drawnRect)
    }
    public func componentNeedsDisplay(_ box: ComponentBox, in rect: NSRect) {
        blockCanvas.redrawComponent(rect)
    }

    // MARK: Interaction

    func link(at point: NSPoint) -> String? {
        if let html = blockComponent(at: point)?.box as? HTMLBox { return html.link(at: point) }
        guard let index = characterIndex(at: point), let destination = linkDestination(at: index) else { return nil }
        let a = blockCanvas.caretRect(at: max(0, index - 1)), b = blockCanvas.caretRect(at: min(index + 1, length))
        guard a.minY == b.minY, NSRect(x: a.minX, y: a.minY, width: b.minX - a.minX, height: a.height).insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return destination
    }
    private func checkbox(at point: NSPoint) -> NSRange? {
        guard let (i, layout, top) = blockCanvas.unit(at: point), case .checkbox = layout.content.listMarker else { return nil }
        let textX = blockCanvas.columnX + layout.content.metrics.indent
        let target = NSRect(x: textX - typography.listIndent, y: top + layout.tops[0], width: typography.listIndent, height: layout.heights[0])
        guard target.contains(point) else { return nil }
        return NSRange(location: blockCanvas.units.range(of: i).location, length: layout.sourceStart(ofLine: 0))
    }
    /// A remote image under the pointer that waits for the document to allow remote images.
    private func blockedImage(at point: NSPoint) -> Bool {
        if let box = blockComponent(at: point)?.box {
            if let html = box as? HTMLBox { return html.blockedImage(at: point) }
            return (box as? ImageBox)?.isBlocked == true && box.drawnRect.contains(point)
        }
        guard let index = characterIndex(at: point), let image = componentBox(at: index) as? InlineImageBox else { return false }
        return image.isBlocked && image.drawnRect.contains(point)
    }

    func handleClick(at point: NSPoint, event: NSEvent) -> Bool {
        if !loadsRemoteImages, blockedImage(at: point) {
            remoteImagesAllowedHere = true
            blockCanvas.view.needsDisplay = true
            return true
        }
        if let box = frontMatterBox(), box.toggleRect.contains(point) || (frontMatterCollapsed && box.drawnRect.contains(point)) {
            frontMatterCollapsed.toggle()
            frontMatterCollapseToggled?(frontMatterCollapsed)
            return true
        }
        if let entry = propertyEntry(at: point) { beginPropertyEdit(entry); return true }
        if event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            if let cell = tableCell(at: point) { beginCellEdit(cell.box, row: cell.row, column: cell.column, at: point); return true }
            if let math = mathBlock(at: point) { editMath(math); return true }
        }
        if isEditable, let range = checkbox(at: point) { toggleCheckbox(range); return true }
        if event.modifierFlags.contains(.command), let destination = link(at: point) { openLink?(destination); return true }
        return false
    }

    @discardableResult
    func openComponentViewer(_ box: ComponentBox) -> Bool {
        guard box is ImageBox || box is DiagramBox, box.viewerNaturalSize() != nil,
              scrollView.window != nil else { return false }
        cancelPendingComponentPreview()
        let host = scrollView
        clearLinkPreview()
        hideComponentViewButton()
        commitAttachedEditors()
        componentViewer?.removeFromSuperview()
        let viewer = ComponentViewer(box: box, frame: host.bounds, allowsSourceEditing: isEditable) { [weak self, weak box] in
            guard let self, let box else { return }
            self.enterComponentSource(box)
        }
        viewer.onClose = { [weak self, weak viewer] in
            guard let self, self.componentViewer === viewer else { return }
            self.componentViewer = nil
            self.focusView.window?.makeFirstResponder(self.focusView)
        }
        componentViewer = viewer
        viewer.show(in: host)
        return true
    }

    func openSelectedComponentViewer() -> Bool {
        guard let range = blockCanvas.focusedComponent, let box = componentBox(at: range.location) else { return false }
        return openComponentViewer(box)
    }

    func updateComponentViewerHover(at point: NSPoint?) {
        if let point, [componentViewButton, componentMenuButton].compactMap({ $0 }).contains(where: { $0.frame.contains(point) }) { return }
        guard let point, let box = viewerComponent(at: point) else { hideComponentViewButton(); return }
        if previewComponent !== box {
            hideComponentViewButton()
            let button = ComponentOverlayButton(symbol: "arrow.up.left.and.arrow.down.right")
            button.target = self
            button.action = #selector(viewHoveredComponent)
            button.toolTip = String(localized: "View image or diagram (⌘Return)")
            button.setAccessibilityLabel(String(localized: "View image or diagram"))
            blockCanvas.view.addSubview(button)
            componentViewButton = button
            let menu = ComponentOverlayButton(symbol: "ellipsis")
            menu.target = self
            menu.action = #selector(showHoveredComponentMenu(_:))
            menu.toolTip = String(localized: "Image or diagram actions")
            menu.setAccessibilityLabel(String(localized: "Image or diagram actions"))
            blockCanvas.view.addSubview(menu)
            componentMenuButton = menu
            previewComponent = box
        }
        componentMenuButton?.frame = NSRect(x: box.drawnRect.maxX - 68, y: box.drawnRect.minY + 8, width: 28, height: 28)
        componentViewButton?.frame = NSRect(x: box.drawnRect.maxX - 36, y: box.drawnRect.minY + 8, width: 28, height: 28)
    }

    func hideComponentViewButton() {
        componentViewButton?.removeFromSuperview()
        componentMenuButton?.removeFromSuperview()
        componentViewButton = nil
        componentMenuButton = nil
        previewComponent = nil
    }

    @objc private func viewHoveredComponent() {
        guard let box = previewComponent else { return }
        _ = openComponentViewer(box)
    }

    func viewerComponent(at point: NSPoint) -> ComponentBox? {
        guard !blockedImage(at: point), let box = blockComponent(at: point)?.box, box is ImageBox || box is DiagramBox,
              box.viewerNaturalSize() != nil else { return nil }
        return box
    }

    func previewComponentAfterDoubleClickInterval(_ box: ComponentBox) {
        cancelPendingComponentPreview()
        let id = UUID()
        let work = DispatchWorkItem { [weak self, weak box] in
            guard let self, let box, self.pendingComponentPreview?.id == id else { return }
            self.pendingComponentPreview = nil
            _ = self.openComponentViewer(box)
        }
        pendingComponentPreview = (id, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    func cancelPendingComponentPreview() {
        pendingComponentPreview?.work.cancel()
        pendingComponentPreview = nil
    }

    @objc private func showHoveredComponentMenu(_ sender: NSView) {
        guard let box = previewComponent else { return }
        componentMenu(for: box).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    func enterComponentSource(_ box: ComponentBox) {
        cancelPendingComponentPreview()
        guard let range = source(of: box) else { return }
        componentViewer?.removeFromSuperview()
        componentViewer = nil
        let location = NSMaxRange(range)
        blockCanvas.select(NSRange(location: location, length: 0), entering: true)
        focusView.window?.makeFirstResponder(focusView)
    }

    func imageResize(at point: NSPoint) -> ImageBox? {
        guard isEditable, let image = blockComponent(at: point)?.box as? ImageBox, canResize(image), image.resizeHit(at: point) else { return nil }
        return image
    }

    func beginImageResize(at point: NSPoint) -> (image: ImageBox, width: CGFloat)? {
        guard let image = imageResize(at: point), let range = source(of: image) else { return nil }
        let raw = source.substring(with: range)
        let measuredWidth = image.displayedWidth
        let ordinal = imageOrdinal(raw, box: image)
        commitAttachedEditors()
        blockCanvas.layoutAll()
        guard let fresh = imageMatching(raw, ordinal: ordinal) else { return nil }
        return (fresh, measuredWidth)
    }

    func commitAttachedEditors() {
        if cellField != nil { endCellEdit(commit: true) }
        if propertyField != nil { endPropertyEdit(commit: true) }
    }

    func updateImageResizeHover(at point: NSPoint?) {
        let image = point.flatMap { imageResize(at: $0) }
        guard image !== hoveredResizeImage else { return }
        hoveredResizeImage?.setResizeHandleVisible(false)
        image?.setResizeHandleVisible(true)
        hoveredResizeImage = image
    }

    private func canResize(_ image: ImageBox) -> Bool {
        guard let range = source(of: image) else { return false }
        let raw = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        if MarkdownAnalyzer.safeHTMLImage(raw) != nil { return true }
        return !MarkdownAnalyzer.standaloneMarkdownImageHasTitle(raw)
    }

    private func imageOrdinal(_ raw: String, box: ImageBox) -> Int? {
        guard let target = source(of: box) else { return nil }
        var ordinal = 0
        let text = source as NSString
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let match = text.range(of: raw, options: [], range: search)
            guard match.location != NSNotFound else { break }
            if componentBox(at: match.location) is ImageBox {
                if match.location == target.location { return ordinal }
                ordinal += 1
            }
            let next = NSMaxRange(match)
            search = NSRange(location: next, length: text.length - next)
        }
        return nil
    }

    private func imageMatching(_ raw: String, ordinal: Int?) -> ImageBox? {
        guard let ordinal else { return nil }
        return imageMatches(raw).dropFirst(ordinal).first
    }

    private func imageMatches(_ raw: String) -> [ImageBox] {
        let text = source as NSString
        var search = NSRange(location: 0, length: text.length)
        var matches: [ImageBox] = []
        while search.length > 0 {
            let match = text.range(of: raw, options: [], range: search)
            guard match.location != NSNotFound else { break }
            if let image = componentBox(at: match.location) as? ImageBox {
                matches.append(image)
            }
            let next = NSMaxRange(match)
            search = NSRange(location: next, length: text.length - next)
        }
        return matches
    }

    func previewImageResize(_ image: ImageBox, width: CGFloat) {
        image.previewResize(to: width)
        componentNeedsLayout(image)
    }

    func cancelImageResize(_ image: ImageBox) {
        image.finishResize()
        componentNeedsLayout(image)
    }

    func commitImageResize(_ image: ImageBox, initialWidth: CGFloat) {
        defer {
            image.finishResize()
            componentNeedsLayout(image)
        }
        guard let range = source(of: image) else { return }
        let original = source.substring(with: range)
        let width = image.committedWidth().rounded()
        guard abs(width - initialWidth) > 0.5 else { return }
        let replacement: String
        if MarkdownAnalyzer.safeHTMLImage(original) != nil {
            guard let resized = replacingHTMLImageWidth(in: original, width: Int(width)) else { return }
            replacement = resized
        } else {
            guard canResize(image) else { return }
            guard let markup = MarkdownAnalyzer.safeHTMLImageMarkup(source: image.source, alt: image.alt, width: width) else { return }
            replacement = markup
        }
        guard replacement != original else { return }
        apply([TextPatch(range: range, replacement: replacement)], actionName: String(localized: "Resize image"), keepingComponents: true)
    }

    private func replacingHTMLImageWidth(in raw: String, width: Int) -> String? {
        replacingHTMLImageAttribute(in: raw, name: "width", value: String(width))
    }

    private func replacingHTMLImageAlignment(in raw: String, alignment: ImageAlignment) -> String? {
        replacingHTMLImageAttribute(in: raw, name: "align", value: alignment.rawValue)
    }

    private func replacingHTMLImageAttribute(in raw: String, name targetName: String, value replacementValue: String) -> String? {
        guard MarkdownAnalyzer.safeHTMLImage(raw) != nil else { return nil }
        var index = raw.startIndex
        while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
        guard raw[index...].hasPrefix("<img") else { return nil }
        index = raw.index(index, offsetBy: 4)
        while index < raw.endIndex {
            while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
            if raw[index...].hasPrefix(">") || raw[index...].hasPrefix("/>") {
                let separator = raw[..<index].last?.isWhitespace == true ? "" : " "
                return String(raw[..<index]) + separator + "\(targetName)=\"\(replacementValue)\"" + String(raw[index...])
            }
            let nameStart = index
            while index < raw.endIndex, raw[index].isLetter { index = raw.index(after: index) }
            let name = raw[nameStart..<index].lowercased()
            while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
            guard index < raw.endIndex, raw[index] == "=" else { return nil }
            index = raw.index(after: index)
            while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
            guard index < raw.endIndex, raw[index] == "\"" || raw[index] == "'" else { return nil }
            let quote = raw[index]
            index = raw.index(after: index)
            let valueStart = index
            while index < raw.endIndex, raw[index] != quote { index = raw.index(after: index) }
            guard index < raw.endIndex else { return nil }
            if name == targetName { return String(raw[..<valueStart]) + replacementValue + String(raw[index...]) }
            index = raw.index(after: index)
        }
        return nil
    }
    func wantsPointingHand(at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        if let box = frontMatterBox(), box.toggleRect.contains(point) { return true }
        if !loadsRemoteImages, blockedImage(at: point) { return true }
        if isEditable, checkbox(at: point) != nil { return true }
        return modifiers.contains(.command) && link(at: point) != nil
    }
    func updateLinkPreview(at point: NSPoint) {
        guard blockCanvas.mode == .rendered, !isComposing, let destination = link(at: point) else {
            linkPreview?.pointerExited()
            return
        }
        if linkPreview == nil { linkPreview = LinkPreviewController(editor: self) }
        linkPreview?.hover(destination: destination, at: point, in: blockCanvas.view)
    }
    func clearLinkPreview() { linkPreview?.cancel() }
    func canvasDidResignFirstResponder() { linkPreview?.canvasDidResignFirstResponder() }
    func previewLink(_ destination: String, at point: NSPoint) {
        if linkPreview == nil { linkPreview = LinkPreviewController(editor: self) }
        linkPreview?.preview(destination: destination, at: point, in: blockCanvas.view)
    }
    func linkPreviewPointerExited() { linkPreview?.pointerExited() }
    @objc private func scrollPositionChanged() { clearLinkPreview() }
    func contextMenu(at point: NSPoint, base: NSMenu?) -> NSMenu? {
        guard let (box, _) = blockComponent(at: point) else { return textMenu(at: point, base: base) }
        let menu: NSMenu
        if let table = box as? TableBox { menu = tableMenu(table, at: point) }
        else if let math = box as? MathBlockBox, isEditable { menu = mathMenu(math) }
        else if box is ImageBox || box is DiagramBox {
            menu = componentMenu(for: box)
        } else { return base }
        if let base, !base.items.isEmpty {
            menu.addItem(.separator())
            for item in base.items { base.removeItem(item); menu.addItem(item) }
        }
        return menu
    }

    private func componentMenu(for box: ComponentBox) -> NSMenu {
        let menu = NSMenu()
        if let image = box as? ImageBox {
            menu.addItem(ClosureMenuItem(title: String(localized: "Copy image Markdown")) { [weak self, weak image] in
                guard let image else { return }
                self?.copyComponentSource(image)
            })
            let save = ClosureMenuItem(title: String(localized: "Save image…")) { [weak self, weak image] in
                guard let image else { return }
                self?.saveComponentImage(image)
            }
            save.isEnabled = image.viewerNaturalSize() != nil
            menu.addItem(save)
        } else if let diagram = box as? DiagramBox {
            menu.addItem(ClosureMenuItem(title: String(localized: "Copy Mermaid source")) { [weak self, weak diagram] in
                guard let diagram else { return }
                self?.copyComponentSource(diagram)
            })
            let save = ClosureMenuItem(title: String(localized: "Save image…")) { [weak self, weak diagram] in
                guard let diagram else { return }
                self?.saveComponentImage(diagram)
            }
            save.isEnabled = diagram.viewerNaturalSize() != nil
            menu.addItem(save)
        }
        return menu
    }

    private func copyComponentSource(_ box: ComponentBox) {
        guard let range = source(of: box) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source.substring(with: range), forType: .string)
    }

    private func saveComponentImage(_ box: ComponentBox) {
        guard let window = blockCanvas.view.window, box.viewerNaturalSize() != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Image.png"
        panel.beginSheetModal(for: window) { [weak self, weak box] response in
            guard response == .OK, let output = panel.url, let box else { return }
            do {
                try ComponentPNG.write(box, to: output)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
                if let self { window.makeFirstResponder(self.focusView) }
            }
        }
    }

    func setImageAlignment(_ image: ImageBox, to alignment: ImageAlignment) {
        guard image.alignment != alignment, canResize(image), let range = source(of: image) else { return }
        let original = source.substring(with: range)
        let replacement: String?
        if MarkdownAnalyzer.safeHTMLImage(original) != nil {
            replacement = replacingHTMLImageAlignment(in: original, alignment: alignment)
        } else {
            replacement = MarkdownAnalyzer.safeHTMLImageMarkup(source: image.source, alt: image.alt, alignment: alignment)
        }
        guard let replacement, replacement != original else { return }
        apply([TextPatch(range: range, replacement: replacement)], actionName: String(localized: "Align image"), keepingComponents: true)
    }
    private func toggleCheckbox(_ range: NSRange) {
        let ns = source
        let open = ns.range(of: "[", options: .literal, range: range)
        guard open.location != NSNotFound, open.location + 1 < NSMaxRange(range) else { return }
        let inner = NSRange(location: open.location + 1, length: 1)
        replace(inner, with: ns.substring(with: inner) == " " ? "x" : " ")
    }

    /// Document-ordered patches form one undoable step; last first keeps ranges valid.
    public func apply(_ patches: [TextPatch], actionName: String, keepingComponents: Bool = false) {
        let undo = focusView.undoManager
        blockCanvas.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        for patch in patches.reversed() { blockCanvas.replace(patch.range, with: patch.replacement, keepingComponent: keepingComponents ? patch.range : nil) }
        undo?.setActionName(actionName)
        undo?.endUndoGrouping()
        if let first = patches.first { blockCanvas.scroll(toCharacter: first.range.location, margin: 80) }
    }
    func replace(_ range: NSRange, with string: String, keepingComponent: NSRange? = nil) {
        blockCanvas.replace(range, with: string, keepingComponent: keepingComponent)
    }

    // MARK: Lists

    struct ListPrefix {
        var lineStart: Int
        var indent: String
        var marker: String
        var spacing: String
        var checkbox: Bool
        var contentStart: Int
    }
    private static let listPrefixPattern = try! NSRegularExpression(pattern: #"^((?:[ \t]*>[ \t]?)*[ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX]\][ \t]+)?"#)
    func listPrefix(at location: Int) -> ListPrefix? {
        let ns = source
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let text = ns.substring(with: line)
        guard let match = Self.listPrefixPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let t = text as NSString
        return ListPrefix(lineStart: line.location, indent: t.substring(with: match.range(at: 1)), marker: t.substring(with: match.range(at: 2)),
                          spacing: t.substring(with: match.range(at: 3)), checkbox: match.range(at: 4).location != NSNotFound,
                          contentStart: line.location + match.range.length)
    }
    /// Return (design §8.1): lists and quotes continue; Return on an empty item or quote line
    /// leaves it. A nested item moves out one level; otherwise the line becomes a new paragraph
    /// after a blank line, so what is typed there is not drawn into the list or quote above.
    func insertNewline() -> Bool {
        guard isEditable else { return false }
        if quickBlockOnReturn() { return true }
        let sel = selection, ns = source
        if sel.length == 0, let p = listPrefix(at: sel.location), sel.location >= p.contentStart {
            let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            var contentEnd = NSMaxRange(line)
            while contentEnd > line.location, [0x0A, 0x0D].contains(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
            if contentEnd == p.contentStart {
                // Nested (indented after any quote markers): out one level. Else out of the list.
                let (quote, nesting) = Self.split(p.indent)
                if !nesting.isEmpty { return shiftListItem(outdent: true) }
                leaveLine(NSRange(location: p.lineStart, length: contentEnd - p.lineStart), container: quote, before: NSMaxRange(line))
                return true
            }
            var marker = p.marker
            if let number = Int(marker.dropLast()) { marker = "\(number + 1)\(marker.last!)" }
            typeText(newline + p.indent + marker + p.spacing + (p.checkbox ? "[ ] " : ""), replacing: sel)
            return true
        }
        if sel.length == 0 {
            let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            // At the end of a setext heading's text the new line goes after its underline.
            if NSMaxRange(line) < ns.length, sel.location == NSMaxRange(Self.withoutTerminator(line, in: ns)), lineMetrics(at: NSMaxRange(line))?.kind == .setextUnderline {
                let underline = Self.withoutTerminator(ns.lineRange(for: NSRange(location: NSMaxRange(line), length: 0)), in: ns)
                blockCanvas.replace(NSRange(location: NSMaxRange(underline), length: 0), with: newline)
                return true
            }
            let head = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
            if let quote = head.range(of: #"^(?:[ \t]*>[ \t]?)+"#, options: .regularExpression) {
                if head[quote.upperBound...].contains(where: { !$0.isWhitespace }) {
                    typeText(newline + head[quote], replacing: sel)
                    return true
                }
                var end = NSMaxRange(line)
                while end > line.location, [0x0A, 0x0D].contains(ns.character(at: end - 1)) { end -= 1 }
                if end == sel.location {
                    // An empty quote line: out of the innermost quote.
                    let outer = String(head[quote]).replacingOccurrences(of: #">[ \t]?$"#, with: "", options: .regularExpression)
                    leaveLine(NSRange(location: line.location, length: end - line.location), container: outer, before: NSMaxRange(line))
                    return true
                }
            }
        }
        blockCanvas.insertNewline()
        return true
    }

    /// Replace an emptied item or quote line by a blank line and a new line in the container
    /// around it (`container`, the quote markers left, or nothing), the caret on the new line. A
    /// line that follows directly gets a blank line too, so it stays its own block.
    private func leaveLine(_ range: NSRange, container: String, before next: Int) {
        let ns = source
        let kept = container.trimmingCharacters(in: .whitespaces)
        let prefix = kept.isEmpty ? "" : kept + " "
        var replacement = kept + newline + prefix
        let caret = range.location + (replacement as NSString).length
        var following = next
        while following < ns.length, [0x20, 0x09].contains(ns.character(at: following)) { following += 1 }
        if next < ns.length, following < ns.length, ![0x0A, 0x0D].contains(ns.character(at: following)) { replacement += newline + kept }
        blockCanvas.replace(range, with: replacement, select: NSRange(location: caret, length: 0))
    }
    /// Backspace after a list marker: the item becomes text at its own level, as in Notion: a
    /// nested item a paragraph under its parent item, a top-level one a paragraph after the list.
    /// A blank line above keeps it from joining the line before (a lazy continuation), so the
    /// text above keeps its meaning.
    func deleteListMarkerBackward() -> Bool {
        let sel = selection, ns = source
        guard isEditable, sel.length == 0, let p = listPrefix(at: sel.location), sel.location == p.contentStart else { return false }
        var separate = false
        if p.lineStart > 0 {
            let above = Self.withoutTerminator(ns.lineRange(for: NSRange(location: p.lineStart - 1, length: 0)), in: ns)
            separate = ns.substring(with: above).contains { !$0.isWhitespace && $0 != ">" }
        }
        let quote = Self.split(p.indent).quote.trimmingCharacters(in: .whitespaces)
        let lead = separate ? quote + newline : ""
        replace(NSRange(location: p.lineStart, length: p.contentStart - p.lineStart), with: lead + p.indent)
        selection = NSRange(location: p.lineStart + ((lead + p.indent) as NSString).length, length: 0)
        return true
    }
    /// Tab and Shift-Tab on an item: one level in or out, after any quote markers. A level is a
    /// tab or the marker's width in spaces.
    func shiftListItem(outdent: Bool) -> Bool {
        let sel = selection
        guard isEditable, let p = listPrefix(at: sel.location) else { return false }
        let (quote, nesting) = Self.split(p.indent)
        let width = (p.marker as NSString).length + (p.spacing as NSString).length
        let at = p.lineStart + (quote as NSString).length
        if outdent {
            let remove = nesting.hasPrefix("\t") ? 1 : min(width, nesting.prefix { $0 == " " }.count)
            guard remove > 0 else { return true }
            replace(NSRange(location: at, length: remove), with: "")
        } else {
            replace(NSRange(location: at, length: 0), with: String(repeating: " ", count: width))
        }
        return true
    }

    /// Tab in a block right after a list nests it under the list's last top-level item, at the
    /// item's text column (Notion nests a block under the one above); Shift-Tab moves a paragraph
    /// nested in an item out one level. Only the moved lines change: the items keep their meaning.
    func nestBlock(outdent: Bool) -> Bool {
        let sel = selection, ns = source
        guard isEditable, sel.length == 0, listPrefix(at: sel.location) == nil,
              let m = lineMetrics(at: ns.lineRange(for: NSRange(location: sel.location, length: 0)).location),
              m.kind != .code, m.kind != .fence else { return false }
        func hasText(_ r: NSRange) -> Bool { ns.substring(with: r).contains { !$0.isWhitespace } }
        func lines(in range: NSRange) -> [NSRange] {
            var result: [NSRange] = [], at = range.location
            while at < NSMaxRange(range) {
                let r = ns.lineRange(for: NSRange(location: at, length: 0))
                result.append(r)
                at = NSMaxRange(r)
            }
            return result
        }
        if !outdent {
            let blocks = blocks(near: sel)
            guard m.listDepth == 0, let block = BlockMap.block(at: sel.location, in: blocks), !block.isListItem else { return false }
            let before = blocks.filter { $0.isListItem && NSMaxRange($0.range) <= block.range.location }
            guard let end = before.map({ NSMaxRange($0.range) }).max(),
                  let item = before.filter({ NSMaxRange($0.range) == end }).min(by: { $0.range.location < $1.range.location }),
                  !hasText(NSRange(location: end, length: block.range.location - end)),
                  let p = listPrefix(at: item.range.location) else { return false }
            let pad = String(repeating: " ", count: ((p.indent + p.marker + p.spacing) as NSString).length)
            var patches: [TextPatch] = []
            var shift = 0
            for r in lines(in: block.range) where hasText(r) {
                patches.append(TextPatch(range: NSRange(location: r.location, length: 0), replacement: pad))
                if r.location <= sel.location { shift += (pad as NSString).length }
            }
            apply(patches, actionName: String(localized: "Indent"))
            selection = NSRange(location: sel.location + shift, length: 0)
            return true
        }
        // The paragraph: its lines between blank lines, none of them an item, after a blank line
        // (else it continues the item's text) and before one (else the lines below would move).
        guard m.listDepth > 0, m.kind == .body || m.kind == .heading,
              let owner = MarkdownPresenter.listOwner(ofLine: sel.location, in: ns) else { return false }
        var first = ns.lineRange(for: NSRange(location: sel.location, length: 0)), last = first
        while first.location > 0 {
            let r = ns.lineRange(for: NSRange(location: first.location - 1, length: 0))
            guard hasText(r) else { break }
            first = r
        }
        while NSMaxRange(last) < ns.length {
            let r = ns.lineRange(for: NSRange(location: NSMaxRange(last), length: 0))
            guard hasText(r) else { break }
            last = r
        }
        let run = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        guard first.location > 0, NSLocationInRange(owner.line.location, run) == false,
              !lines(in: run).contains(where: { listPrefix(at: $0.location) != nil }) else { return false }
        let own = ns.substring(with: first).prefix { $0 == " " || $0 == "\t" }.reduce(0) { c, ch in ch == "\t" ? c / 4 * 4 + 4 : c + 1 }
        let remove = own - owner.marker
        var patches: [TextPatch] = []
        var shift = 0
        for r in lines(in: run) {
            var column = 0, count = 0
            for ch in ns.substring(with: r) {
                guard column < remove, ch == " " || ch == "\t" else { break }
                column = ch == "\t" ? column / 4 * 4 + 4 : column + 1
                count += 1
            }
            patches.append(TextPatch(range: NSRange(location: r.location, length: count), replacement: ""))
            if r.location <= sel.location { shift += min(count, sel.location - r.location) }
        }
        apply(patches, actionName: String(localized: "Outdent"))
        selection = NSRange(location: sel.location - shift, length: 0)
        return true
    }

    /// A line prefix split into its quote markers (`> > `) and the indentation after them.
    static func split(_ indent: String) -> (quote: String, nesting: String) {
        let ns = indent as NSString
        let quote = ns.range(of: #"^(?:[ \t]*>[ \t]?)*"#, options: .regularExpression)
        let end = quote.location == NSNotFound ? 0 : NSMaxRange(quote)
        return (ns.substring(to: end), ns.substring(from: end))
    }

    // MARK: Backspace at the start of a block

    /// Backspace where a block's text begins (design §8.1), so every press visibly does something
    /// and no press breaks the structure: after a heading's markers the heading becomes body text;
    /// after a quote's markers the line leaves the innermost quote (or, inside a quote paragraph,
    /// joins the line above); at the start of a line that follows a component, the component is
    /// taken whole; after a code block, the caret goes to its last line; after an ATX heading, the
    /// text joins it; after a setext heading, the caret goes to its end.
    func deleteBlockStartBackward() -> Bool {
        let sel = selection, ns = source
        guard isEditable, sel.length == 0, sel.location > 0, blockCanvas.presenter != nil else { return false }
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let head = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location)) as NSString
        if head.length > 0 {
            let heading = head.range(of: #"^(?:[ \t]*>[ \t]?)*[ \t]{0,3}#{1,6}[ \t]+$"#, options: .regularExpression)
            if heading.location != NSNotFound {
                let markers = (Self.split(head as String).quote as NSString).length
                replace(NSRange(location: line.location + markers, length: head.length - markers), with: "")
                return true
            }
            guard head.range(of: #"^(?:[ \t]*>[ \t]?)+$"#, options: .regularExpression).location != NSNotFound else { return false }
            // Inside a quote paragraph (the line above is in the same quote and has text): join it.
            if line.location > 0 {
                let above = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
                let text = ns.substring(with: Self.withoutTerminator(above, in: ns)) as NSString
                let prefix = text.range(of: #"^(?:[ \t]*>[ \t]?)+"#, options: .regularExpression)
                if prefix.location != NSNotFound, prefix.length == head.length, text.length > prefix.length {
                    replace(NSRange(location: NSMaxRange(Self.withoutTerminator(above, in: ns)), length: sel.location - NSMaxRange(Self.withoutTerminator(above, in: ns))), with: "")
                    return true
                }
            }
            let outer = (head as String).replacingOccurrences(of: #">[ \t]?$"#, with: "", options: .regularExpression)
            replace(NSRange(location: line.location, length: head.length), with: outer)
            return true
        }
        // At the start of a line: what shows above it decides.
        guard Self.withoutTerminator(line, in: ns).length > 0, let above = blockCanvas.shownLine(before: sel.location) else { return false }
        let content = above.layout.content
        if content.component != nil, let whole = blockCanvas.presenter?.drawnComponent(around: above.location + above.layout.sourceStart(ofLine: 0)) {
            blockCanvas.select(NSRange(location: whole.location, length: 0), focus: whole)
            return true
        }
        switch content.metrics.kind {
        case .fence:
            // The closing fence: to the end of the code's last line.
            var end = above.location
            if end > 0, ns.character(at: end - 1) == 0x0A { end -= 1 }
            if end > 0, ns.character(at: end - 1) == 0x0D { end -= 1 }
            blockCanvas.select(NSRange(location: end, length: 0))
            return true
        case .heading:
            let next = above.location + above.length
            if next < ns.length, lineMetrics(at: next)?.kind == .setextUnderline {
                blockCanvas.select(NSRange(location: above.location + above.layout.contentLength, length: 0))
                return true
            }
            let end = above.location + above.layout.contentLength
            replace(NSRange(location: end, length: sel.location - end), with: "")
            return true
        default:
            return false
        }
    }

    // MARK: Components the arrow keys stop on

    /// Return on an outlined component: its attached editor (a table's first cell, a formula, the
    /// properties), or for the others their source, the caret at its end.
    func editComponent(at range: NSRange) {
        switch componentBox(at: range.location) {
        case let table as TableBox: beginCellEdit(table, row: 0, column: 0)
        case let math as MathBlockBox: editMath(math)
        case is FrontMatterBox: editProperties()
        default:
            blockCanvas.select(NSRange(location: NSMaxRange(range), length: 0), entering: true)
            scrollSelectionToVisible()
        }
    }

    /// Delete on an outlined component: its own lines, not the quote or list item it sits in.
    func deleteComponent(_ component: NSRange) {
        guard isEditable else { return NSSound.beep() }
        let lines = source.lineRange(for: component)
        if let block = BlockMap.block(at: component.location, in: blocks(near: component)), block.range == lines { return delete(block) }
        replace(lines, with: "")
    }

    /// A click on a block component no attached editor took: the component, to outline.
    func clickedComponent(at point: NSPoint) -> NSRange? {
        if let math = mathBlock(at: point) { return source(of: math) }
        guard let (box, range) = blockComponent(at: point), range.location != NSNotFound, componentBox(at: range.location) === box else { return nil }
        return range
    }

    // MARK: Host interface

    public typealias Heading = Outline.Heading
    public func headings() -> [Heading] { blockCanvas.headings() }
    public func reveal(location: Int) {
        blockCanvas.scroll(toCharacter: location, margin: 24)
        blockCanvas.select(NSRange(location: min(location, length), length: 0))
        focusView.window?.makeFirstResponder(focusView)
    }
    public var focusView: NSView { blockCanvas.view }
    public var selectedRange: NSRange { blockCanvas.selection }
    public func select(_ range: NSRange, indicate: Bool = false) {
        let r = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - min(range.location, length))))
        blockCanvas.scroll(toCharacter: r.location, margin: scrollView.contentView.bounds.height / 3)
        blockCanvas.select(r)
    }
    public var isEditable: Bool {
        get { blockCanvas.isEditable }
        set { blockCanvas.isEditable = newValue }
    }
    public func breakUndoCoalescing() { blockCanvas.breakUndoCoalescing() }
    public func type(_ text: String) { blockCanvas.view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    public func pressReturn() { blockCanvas.view.insertNewline(nil) }
    public func lineRect(at location: Int) -> NSRect { blockCanvas.lineBox(at: location) }
    public func layoutAll() { blockCanvas.layoutAll() }
    public func firstVisibleCharacter() -> Int { blockCanvas.firstVisibleCharacter() }
    public func readingCharacter() -> Int { blockCanvas.readingCharacter() }
    public func scrollToCharacter(_ index: Int) { blockCanvas.scroll(toCharacter: index) }
    public var printView: NSView { PrintSheet(self) }
}

/// Translucent component controls. They leave pixels beneath them untouched at rest and derive
/// their hover/pressed fills from the active appearance tokens.
private final class ComponentOverlayButton: NSControl {
    private let symbol: String
    private var hovering = false { didSet { updateAppearance() } }
    private var pressed = false { didSet { updateAppearance() } }

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.control
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func updateAppearance() {
        layer?.backgroundColor = (pressed ? Tokens.pressed : hovering ? Tokens.hover : .clear).cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = hovering || pressed || window?.firstResponder === self ? Tokens.ink : Tokens.ink2
        guard let image = Tokens.symbol(symbol, size: 13, weight: .medium, color: color) else { return }
        let scale = min(14 / image.size.width, 14 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: floor(bounds.midX - size.width / 2), y: floor(bounds.midY - size.height / 2), width: size.width, height: size.height))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let activate = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if activate, let action { NSApp.sendAction(action, to: target, from: self) }
    }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); needsDisplay = true; return accepted }
    override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); needsDisplay = true; return accepted }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 {
            if let action { NSApp.sendAction(action, to: target, from: self) }
        } else {
            super.keyDown(with: event)
        }
    }
    override func accessibilityPerformPress() -> Bool {
        if let action { NSApp.sendAction(action, to: target, from: self) }
        return true
    }
}
