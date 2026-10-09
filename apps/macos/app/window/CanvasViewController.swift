import AppKit
import ZephyrRender

/// Hosts the top bar, the canvas, the floating folder panel and the outline. The panel is a card
/// over the canvas and never changes the window's size; where the window has room for a comfortable
/// column beside it, the text moves clear of it, otherwise the card floats over the text and goes
/// once something is chosen in it (design §7.4). The outline is a rail beside the text or a button
/// in the top bar, as chosen in Settings (design §8).
final class CanvasViewController: NSViewController {
    weak var controller: DocumentWindowController?
    let topBar = TopBar()
    let sidebar = ScopeSidebarView()
    private let editorContainer = NSView()
    /// The part of the canvas the text and pages use: all of it, or right of an open sidebar that
    /// makes room (`sidebarMakesRoom`).
    private let textArea = NSLayoutGuide()
    private var textLeading: NSLayoutConstraint!
    private var sidebarLeading: NSLayoutConstraint!
    /// The text starts under the top bar, or (minimal mode) right under the title bar.
    private var editorTopToBar: NSLayoutConstraint!
    private var editorTopToTitleBar: NSLayoutConstraint!
    /// The assistant floats over the text: its launcher at the bottom right, the chat above it.
    private(set) lazy var aiLauncher = AILauncher { [weak self] in self?.toggleAIPanel() }
    private var aiConstraints: [NSLayoutConstraint] = []
    private var aiShort = false
    /// The chat outlives a collapse (conversation, draft, running request); a new document ends it.
    private(set) var isAIOpen = false
    private var banner: NSView?
    private var clickMonitor: Any?
    private(set) var editor: MarkdownEditor?
    private(set) var isSidebarVisible = false
    /// The open sidebar has the text beside it rather than under it.
    private(set) var sidebarMakesRoom = false
    private(set) var aiPanel: AIPanelController?
    let outlineRail = OutlineRail()
    let outlineCard = OutlineCard()
    /// The window's open documents on the left edge while the sidebar is hidden (Settings).
    let documentRail = DocumentRail()
    /// An app page (Today, Goals, Overview) shown over the document.
    private var page: NSView?

    static let sidebarWidth: CGFloat = 280
    /// The margins belong to the panel, so dragging there cannot select text underneath.
    static let sidebarInset: CGFloat = 8
    private var sidebarPanelWidth: CGFloat { Self.sidebarWidth + 2 * Self.sidebarInset }
    /// The narrowest reading column the text keeps beside an open sidebar; a narrower window has the
    /// card over the text instead.
    static let columnBesideSidebar: CGFloat = 480

    override func loadView() {
        let root = CanvasRootView(frame: NSRect(x: 0, y: 0, width: 900, height: 1000))
        root.wantsLayer = true
        topBar.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(editorContainer)
        root.addSubview(topBar)
        root.addSubview(sidebar)
        sidebarLeading = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: -Self.sidebarWidth - 20)
        // The bar fills the title bar area, so the traffic lights sit centered in it.
        let barHeight = topBar.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        barHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            barHeight,
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: TopBar.minimumHeight),
            editorContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarLeading,
            sidebar.widthAnchor.constraint(equalToConstant: sidebarPanelWidth),
            sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        editorContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        editorTopToBar = editorContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor)
        editorTopToTitleBar = editorContainer.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        editorTopToBar.isActive = true
        root.addLayoutGuide(textArea)
        textLeading = textArea.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor)
        NSLayoutConstraint.activate([
            textLeading,
            textArea.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            textArea.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            textArea.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
        ])
        sidebar.isHidden = true
        // The outline: the rail beside the text; the card (button, ⌃⌘2) under the top bar's right end.
        // The open documents' rail mirrors it on the left edge.
        for v in [outlineRail, outlineCard, documentRail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            outlineRail.widthAnchor.constraint(equalToConstant: OutlineRail.maxPanelWidth + 2),
            outlineRail.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor, constant: -14),
            // Both rails span the text area, so their marks center on it; the outline keeps clear of
            // the assistant's launcher at the bottom right (`bottomClearance`).
            outlineRail.topAnchor.constraint(equalTo: editorContainer.topAnchor, constant: 8),
            outlineRail.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor, constant: -8),
            outlineCard.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            outlineCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            outlineCard.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
            documentRail.widthAnchor.constraint(equalToConstant: DocumentRail.maxPanelWidth + 2),
            documentRail.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor, constant: 14),
            documentRail.topAnchor.constraint(equalTo: outlineRail.topAnchor),
            documentRail.bottomAnchor.constraint(equalTo: outlineRail.bottomAnchor),
        ])
        outlineCard.isHidden = true
        outlineRail.bottomClearance = 58
        documentRail.isHidden = true
        documentRail.onSelect = { [weak self] index in
            guard let controller = self?.controller, controller.openTabs.indices.contains(index) else { return }
            controller.activate(controller.openTabs[index])
        }
        documentRail.onClose = { [weak self] index in
            guard let controller = self?.controller, controller.openTabs.indices.contains(index) else { return }
            controller.close(controller.openTabs[index])
        }
        documentRail.onScroll = { [weak self] event in self?.editor?.scrollView.scrollWheel(with: event) }
        aiLauncher.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(aiLauncher)
        NSLayoutConstraint.activate([
            aiLauncher.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor, constant: -18),
            aiLauncher.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            aiLauncher.widthAnchor.constraint(equalToConstant: AILauncher.side), aiLauncher.heightAnchor.constraint(equalToConstant: AILauncher.side),
        ])
        view = root
    }

    /// Minimal mode leaves only the text (design §2 principle 7): the top bar and its space go,
    /// the title bar shrinks to the window buttons, and the sidebar and AI panel close.
    func setMinimal(_ minimal: Bool) {
        topBar.isHidden = minimal
        view.window?.toolbar?.isVisible = !minimal
        updateRails()
        editorTopToBar.isActive = !minimal
        editorTopToTitleBar.isActive = minimal
        if minimal {
            setSidebar(visible: false, animated: false)
            collapseAIPanel()
            setOutline(open: false)
        }
        updateOpenIndicators()
    }

    /// The text shown, or none (a tab showing only an app page).
    func setEditor(_ editor: MarkdownEditor?, readOnlyReason: String?) {
        self.editor?.scrollView.removeFromSuperview()
        self.editor = editor
        // A chat is about one document: navigating to another starts over.
        discardAIPanel()
        guard let editor else {
            showBanner(nil, symbol: "")
            updateAIButton()
            return
        }
        editor.blockCanvas.leadingInset = textLeading.constant
        // Laid out first as the previous text was, rails or not; `updateRails` settles it.
        editor.blockCanvas.reservedMargin = outlineRail.isHidden && documentRail.isHidden ? 0 : Self.railMargin
        let scroll = editor.scrollView
        scroll.isHidden = page != nil
        scroll.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(scroll, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
        ])
        showBanner(readOnlyReason, symbol: "lock.fill")
        updateAIButton()
    }

    // MARK: AI (design §8: the assistant floats at the bottom right, over the text)

    /// The launcher shows unless hidden in Settings or minimal mode; the text can scroll its last
    /// line clear of it whether or not the chat is open.
    func updateAIButton() {
        let enabled = !UserDefaults.standard.bool(forKey: Preferences.aiButtonHidden) && !topBar.isHidden
        aiLauncher.isHidden = !enabled || (isAIOpen && aiShort)
        aiLauncher.isOpen = isAIOpen
        if let scroll = editor?.scrollView {
            // The last line scrolls clear of the launcher.
            let bottom: CGFloat = enabled ? 76 : 0
            if scroll.contentInsets.bottom != bottom {
                scroll.automaticallyAdjustsContentInsets = false
                scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
                scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -bottom, right: 0)
            }
        }
    }

    /// Motion only where someone can see it, and never with Reduce Motion on.
    private var animates: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && view.window?.occlusionState.contains(.visible) == true
    }

    func toggleAIPanel() {
        isAIOpen ? collapseAIPanel() : openAIPanel()
    }

    private func openAIPanel() {
        let panel: AIPanelController
        if let existing = aiPanel {
            panel = existing
        } else {
            panel = AIPanelController()
            panel.document = controller?.markdownDocument
            panel.scopeRoot = { [weak self] in self?.controller?.scopeRoot }
            panel.onClose = { [weak self] in self?.collapseAIPanel() }
            addChild(panel)
            panel.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel.view)
            aiPanel = panel
        }
        isAIOpen = true
        outlineRail.isQuiet = true
        panel.view.isHidden = false
        setOutline(open: false)
        placeAIPanel()
        updateAIButton()
        view.window?.makeFirstResponder(panel.view)
        guard animates else { return panel.view.alphaValue = 1 }
        // Fades in, rising 6 pt into place.
        view.layoutSubtreeIfNeeded()
        panel.view.alphaValue = 0
        panel.view.layer?.transform = CATransform3DMakeTranslation(0, -6, 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.view.animator().alphaValue = 1
            panel.view.layer?.transform = CATransform3DIdentity
        }
    }

    /// Above the launcher, right edges aligned: 400 pt wide at most, 620 pt tall at most, never
    /// past the top bar. A short window (under 400 pt of text) gives the chat the whole text area.
    private func placeAIPanel() {
        guard let card = aiPanel?.view else { return }
        NSLayoutConstraint.deactivate(aiConstraints)
        aiShort = editorContainer.bounds.height < 400
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 400)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = card.heightAnchor.constraint(equalToConstant: 620)
        preferredHeight.priority = .defaultHigh - 1
        aiConstraints = [preferredWidth, card.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
                         card.widthAnchor.constraint(lessThanOrEqualTo: editorContainer.widthAnchor, constant: -24)]
        if aiShort {
            aiConstraints += [card.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor, constant: -12),
                              card.topAnchor.constraint(equalTo: editorContainer.topAnchor, constant: 12),
                              card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)]
        } else {
            aiConstraints += [card.trailingAnchor.constraint(equalTo: aiLauncher.trailingAnchor, constant: -2),
                              card.bottomAnchor.constraint(equalTo: aiLauncher.topAnchor, constant: -10),
                              card.topAnchor.constraint(greaterThanOrEqualTo: editorContainer.topAnchor, constant: 16), preferredHeight]
        }
        NSLayoutConstraint.activate(aiConstraints)
    }

    /// A window resized across the short-window line moves the chat.
    override func viewDidLayout() {
        super.viewDidLayout()
        if isAIOpen, (editorContainer.bounds.height < 400) != aiShort {
            placeAIPanel()
            updateAIButton()
        }
        // A resize across the line between room and none.
        if isSidebarVisible, sidebarFits != sidebarMakesRoom { makeRoomForSidebar(animated: false) }
        updateRails()
    }

    /// Hides the chat; it keeps its conversation, draft and any request still running.
    func collapseAIPanel() {
        guard isAIOpen, let panel = aiPanel else { return }
        isAIOpen = false
        outlineRail.isQuiet = false
        updateAIButton()
        if view.window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: panel.view) == true }) == true {
            view.window?.makeFirstResponder(editor?.focusView)
        }
        guard animates else { return panel.view.isHidden = true }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            panel.view.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.isAIOpen == false { panel.view.isHidden = true }
        })
    }

    /// The chat leaves with its tab, as it is (conversation, draft, a running request), until the
    /// tab shows again (`restoreAssistant`).
    func takeAssistant() -> (panel: AIPanelController, open: Bool)? {
        guard let panel = aiPanel else { return nil }
        let open = isAIOpen
        NSLayoutConstraint.deactivate(aiConstraints)
        aiConstraints = []
        panel.view.removeFromSuperview()
        panel.removeFromParent()
        aiPanel = nil
        isAIOpen = false
        outlineRail.isQuiet = false
        updateAIButton()
        return (panel, open)
    }

    func restoreAssistant(_ kept: (panel: AIPanelController, open: Bool)?) {
        guard let (panel, open) = kept else { return }
        addChild(panel)
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel.view)
        panel.scopeRoot = { [weak self] in self?.controller?.scopeRoot }
        panel.onClose = { [weak self] in self?.collapseAIPanel() }
        aiPanel = panel
        isAIOpen = open
        outlineRail.isQuiet = open
        panel.view.isHidden = !open
        panel.view.alphaValue = 1
        if open { placeAIPanel() }
        updateAIButton()
    }

    /// Ends the chat (another document): its request stops and the panel goes.
    private func discardAIPanel() {
        guard let panel = aiPanel else { return }
        panel.stop()
        NSLayoutConstraint.deactivate(aiConstraints)
        aiConstraints = []
        panel.view.removeFromSuperview()
        panel.removeFromParent()
        aiPanel = nil
        isAIOpen = false
        outlineRail.isQuiet = false
    }

    /// A quiet notice above the text, optionally with actions (read-only files, external changes).
    func showBanner(_ text: String?, symbol: String, actions: [(String, () -> Void)] = []) {
        banner?.removeFromSuperview()
        banner = nil
        guard let text else { return }
        let icon = NSImageView(image: Tokens.symbol(symbol, size: 12, color: Tokens.ink2)!)
        let label = flatLabel(text, size: 12, color: Tokens.ink2)
        let buttons = actions.map { title, handler in FlatButton(title: title, style: .secondary, handler: handler) }
        let stack = NSStackView(views: [icon, label] + buttons)
        stack.setCustomSpacing(12, after: label)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: buttons.isEmpty ? 14 : 6)
        let card = SurfaceView(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.menu, elevated: true)
        card.pointer = .arrow
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: textArea.centerXAnchor),
            card.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            card.widthAnchor.constraint(lessThanOrEqualTo: editorContainer.widthAnchor, constant: -32),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        banner = card
    }

    // MARK: Sidebar

    func setSidebar(visible: Bool, animated: Bool = true) {
        guard visible != isSidebarVisible else { return }
        isSidebarVisible = visible
        sidebar.isHidden = false
        if visible {
            sidebar.didAppear()
        }
        makeRoomForSidebar(animated: animated)
        updateOpenIndicators()
        let finish = { [weak self] in
            guard let self else { return }
            if !self.isSidebarVisible { self.sidebar.isHidden = true }
        }
        if visible { installClickMonitor() } else { removeClickMonitor() }
        guard animated, animates else {
            sidebarLeading.constant = visible ? 0 : -sidebarPanelWidth - 20
            sidebar.alphaValue = visible ? 1 : 0
            view.layoutSubtreeIfNeeded()
            return finish()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sidebarLeading.animator().constant = visible ? 0 : -sidebarPanelWidth - 20
            sidebar.animator().alphaValue = visible ? 1 : 0
            view.layoutSubtreeIfNeeded()
        }, completionHandler: finish)
    }

    /// The window's open documents changed, or the one shown: the sidebar lists them; with the
    /// sidebar hidden, the rail of open documents or a count beside the sidebar button stands in.
    func openDocumentsChanged() {
        sidebar.refresh()
        updateOpenIndicators()
    }

    private func updateOpenIndicators() {
        let tabs = controller?.openTabs ?? []
        // While a page shows, no document is the shown one.
        documentRail.items = tabs.map { DocumentRail.Item(title: $0.shortTitle, current: $0 === controller?.current && controller?.panel == nil, unsaved: $0.holdsUnsavedText) }
        updateRails()
    }

    /// Whether the window holds the card and a comfortable column side by side.
    private var sidebarFits: Bool {
        editorContainer.bounds.width - sidebarPanelWidth - 2 * BlockCanvas.minimumMargin >= Self.columnBesideSidebar
    }

    /// The text and pages move clear of an open sidebar where the window has room, sliding with the
    /// card; the column keeps its width when it can and narrows only as far as it must.
    private func makeRoomForSidebar(animated: Bool) {
        sidebarMakesRoom = isSidebarVisible && sidebarFits
        let inset = sidebarMakesRoom ? sidebarPanelWidth : 0
        guard textLeading.constant != inset else { return }
        let before = editor?.column.x
        textLeading.constant = inset
        view.layoutSubtreeIfNeeded()
        editor?.blockCanvas.leadingInset = inset
        guard animated, animates else { return }
        // Drawn in place at once, then carried over from where it was, so nothing lays out per frame.
        if let editor, let before, page == nil { slide(editor.scrollView, from: before - editor.column.x) }
        if let page { slide(page, from: sidebarMakesRoom ? -sidebarPanelWidth : sidebarPanelWidth) }
    }

    private func slide(_ view: NSView, from offset: CGFloat) {
        guard abs(offset) > 0.5, let layer = view.layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = offset
        slide.toValue = 0
        slide.isAdditive = true
        slide.duration = 0.22
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(slide, forKey: "zephyr.sidebarRoom")
    }

    /// A choice made in a sidebar over the text (a page, a document, a match) is what the reader
    /// wants to see: the card goes. Beside the text it stays, for the next one.
    func sidebarDidOpenItem() {
        if isSidebarVisible, !sidebarMakesRoom { setSidebar(visible: false) }
    }

    /// A sidebar over the text closes when the reader clicks back into the text; one beside the
    /// text covers nothing and stays.
    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isSidebarVisible, !self.sidebarMakesRoom, event.window === self.view.window else { return event }
            let point = self.sidebar.convert(event.locationInWindow, from: nil)
            if !self.sidebar.bounds.contains(point), self.editorContainer.convert(event.locationInWindow, from: nil).y < self.editorContainer.bounds.maxY {
                let inEditor = self.editorContainer.hitTest(self.editorContainer.superview!.convert(event.locationInWindow, from: nil)) != nil
                if inEditor { self.setSidebar(visible: false) }
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    override func cancelOperation(_ sender: Any?) {
        if !outlineCard.isHidden {
            setOutline(open: false)
            view.window?.makeFirstResponder(editor?.focusView)
        } else if isSidebarVisible {
            setSidebar(visible: false)
            view.window?.makeFirstResponder(editor?.focusView)
        }
    }

    // MARK: Outline

    /// A rail's room beside the text, kept on both sides so the column stays centered.
    static let railMargin: CGFloat = 14 + OutlineRail.width + 12
    /// The narrowest column the text keeps for the rails; below it the top bar stands in.
    static let columnBesideRail: CGFloat = 560

    /// The two rails beside the text, each while the window keeps a comfortable column beside them
    /// (the column gives up the same room on both sides for either): on the right the outline when
    /// chosen (two headings or more, outside minimal mode), otherwise the top bar's button; on the
    /// left the open documents while the sidebar is hidden (two or more, the quick switcher on),
    /// otherwise a count beside the sidebar button.
    func updateRails() {
        let room = editorContainer.bounds.width - textLeading.constant - 2 * Self.railMargin >= Self.columnBesideRail
        let outlineWanted = Preferences.outlineBesideText && outlineRail.headings.count >= 2 && !topBar.isHidden && page == nil
        let several = documentRail.items.count > 1 && !topBar.isHidden && !isSidebarVisible
        let documentsWanted = several && UserDefaults.standard.bool(forKey: Preferences.quickSwitcher) && page == nil
        let outline = outlineWanted && room, documents = documentsWanted && room
        editor?.blockCanvas.reservedMargin = outline || documents ? Self.railMargin : 0
        if outlineRail.isHidden == outline { outlineRail.isHidden = !outline }
        if documentRail.isHidden == documents {
            documentRail.isHidden = !documents
            if !documents { documentRail.dismiss() }
        }
        let button = !outline && !outlineRail.headings.isEmpty && page == nil
        if topBar.outlineButton.isHidden == button { topBar.outlineButton.isHidden = !button }
        topBar.setOpenCount(several && !documents ? documentRail.items.count : nil)
    }

    /// The headings down to the levels chosen in Settings, counted from the document's top level.
    func setOutline(_ headings: [MarkdownEditor.Heading]) {
        let top = headings.map(\.level).min() ?? 1
        let shown = headings.filter { $0.level < top + Preferences.outlineDepth }
        outlineRail.setHeadings(shown)
        if !outlineCard.isHidden { outlineCard.show(shown, current: outlineRail.current) }
        updateRails()
    }

    /// The caret's section is the outline's one colored mark, in the rail and the card alike.
    func setCaretLocation(_ location: Int) {
        let before = outlineRail.current
        outlineRail.setCaret(location: location)
        if !outlineCard.isHidden, outlineRail.current != before { outlineCard.show(outlineRail.headings, current: outlineRail.current) }
    }

    /// Where the reading is; while scrolling, the rail shows it for a moment.
    func setReadingLocation(_ location: Int, scrolling: Bool) {
        outlineRail.setReading(location: location, scrolling: scrolling)
    }

    /// The outline as a list under the top bar (its button, ⌃⌘2): stays until Esc, the button
    /// again or a choice elsewhere; opening it collapses the assistant, which keeps its chat.
    func setOutline(open: Bool) {
        guard open == outlineCard.isHidden else { return }
        if open {
            if isAIOpen { collapseAIPanel() }
            outlineCard.show(outlineRail.headings, current: outlineRail.current)
            outlineCard.isHidden = false
            reveal(outlineCard)
        } else {
            outlineCard.isHidden = true
        }
    }

    func toggleOutlineCard() { setOutline(open: outlineCard.isHidden) }

    /// The app page over the document, if one is shown.
    var shownPage: NSView? { page }

    /// Pages replace each other fully opaque; the loaded document stays hidden until returning
    /// to it. Fading a page from zero opacity would briefly expose that document on every switch.
    func showPage(_ view: NSView?) {
        let previous = page
        page = view
        setOutline(open: false)
        editor?.scrollView.isHidden = view != nil
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            editorContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: textArea.leadingAnchor), view.trailingAnchor.constraint(equalTo: textArea.trailingAnchor),
                view.topAnchor.constraint(equalTo: textArea.topAnchor), view.bottomAnchor.constraint(equalTo: textArea.bottomAnchor),
            ])
            editorContainer.layoutSubtreeIfNeeded()
        }
        previous?.removeFromSuperview()
        if view == nil { self.view.window?.makeFirstResponder(editor?.focusView) }
        updateRails()
    }

    /// A card appearing: fades in, dropping 4 pt into place (none with Reduce Motion).
    private func reveal(_ card: NSView) {
        guard animates else { return card.alphaValue = 1 }
        card.wantsLayer = true
        card.alphaValue = 0
        card.layer?.transform = CATransform3DMakeTranslation(0, 4, 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.animator().alphaValue = 1
            card.layer?.transform = CATransform3DIdentity
        }
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }
}

/// The canvas color behind everything, so no window material shows through (design §8.2).
final class CanvasRootView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Tokens.canvas.cgColor }
    }
}
