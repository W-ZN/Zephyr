import AppKit
import ZephyrRender

/// Hosts the top bar, the reading area, the sidebar and the outline. The open sidebar is a card
/// beside the text, never over it and never changing the window's size: as wide as its edge was
/// dragged, narrower only as far as a narrow window needs, never under its minimum; a strip of
/// icons where Settings asks for one. The text, pages and previews keep to the room right of it
/// (`textArea`). The outline is a rail beside the text or a button in the top bar, as chosen in
/// Settings (design §8).
final class CanvasViewController: NSViewController {
    weak var controller: DocumentWindowController?
    let topBar = TopBar()
    let sidebar = ScopeSidebarView()
    private let editorContainer = NSView()
    /// The part of the canvas the text and pages use: all of it, or right of the open sidebar.
    private let textArea = NSLayoutGuide()
    private var textLeading: NSLayoutConstraint!
    private var sidebarLeading: NSLayoutConstraint!
    private var sidebarWidthConstraint: NSLayoutConstraint!
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
    private(set) var editor: MarkdownEditor?
    private(set) var isSidebarVisible = false
    /// The sidebar is open, with the text beside it.
    private(set) var sidebarMakesRoom = false
    private(set) var aiPanel: AIPanelController?
    let outlineRail = OutlineRail()
    let outlineCard = OutlineCard()
    /// The window's open documents on the left edge while the sidebar is hidden (Settings).
    let documentRail = DocumentRail()
    /// An app page (Today, Goals, Overview) shown over the document.
    private var page: NSView?

    /// The card's width with names: 280 until its edge is dragged, from 220 to 400.
    static let sidebarWidth: CGFloat = 280
    static let minimumSidebarWidth: CGFloat = 220
    static let maximumSidebarWidth: CGFloat = 400
    /// The card's width with icons only.
    static let iconSidebarWidth: CGFloat = 52
    /// The margins belong to the panel, so dragging there cannot select text underneath.
    static let sidebarInset: CGFloat = 8
    /// The room the text keeps beside a wider card: the card gives way, down to its minimum.
    static let textBesideSidebar: CGFloat = 320
    /// The dragged width, kept for every window (`Preferences.sidebarWidth`).
    private var cardWidth = CanvasViewController.storedSidebarWidth
    private static var storedSidebarWidth: CGFloat {
        min(max(UserDefaults.standard.double(forKey: Preferences.sidebarWidth), minimumSidebarWidth), maximumSidebarWidth)
    }
    /// Files and search temporarily need names; the navigation returns to the chosen style.
    private var compactSidebar: Bool { UserDefaults.standard.bool(forKey: Preferences.sidebarIconsOnly) && sidebar.tab == .places }
    /// The widest card the window has room for beside the text, never under the minimum.
    private var sidebarRoom: CGFloat { max(Self.minimumSidebarWidth, view.bounds.width - 2 * Self.sidebarInset - Self.textBesideSidebar) }
    private var sidebarPanelWidth: CGFloat {
        (compactSidebar ? Self.iconSidebarWidth : min(cardWidth, sidebarRoom)) + 2 * Self.sidebarInset
    }

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
        sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth + 2 * Self.sidebarInset)
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
            sidebarWidthConstraint,
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
        sidebar.onResize = { [weak self] width in self?.resizeSidebar(to: width) }
        sidebar.onSearchModeChanged = { [weak self] in self?.makeRoomForSidebar(animated: false) }
        NotificationCenter.default.addObserver(self, selector: #selector(sidebarPreferencesChanged), name: Preferences.sidebarDidChange, object: nil)
        makeRoomForSidebar(animated: false)
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
        editor.blockCanvas.leadingInset = 0
        // Laid out first as the previous text was, rails or not; `updateRails` settles it.
        editor.blockCanvas.reservedMargin = 0
        editor.blockCanvas.trailingInset = 0
        let scroll = editor.scrollView
        scroll.isHidden = page != nil
        scroll.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(scroll, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: textArea.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: textArea.trailingAnchor),
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
                         card.widthAnchor.constraint(lessThanOrEqualTo: textArea.widthAnchor, constant: -24)]
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
        // A narrow window narrows the card, down to its minimum.
        makeRoomForSidebar(animated: false)
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
            card.widthAnchor.constraint(lessThanOrEqualTo: textArea.widthAnchor, constant: -32),
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

    /// Settings changed the sidebar (names or icons only).
    @objc private func sidebarPreferencesChanged() {
        cardWidth = Self.storedSidebarWidth
        makeRoomForSidebar(animated: false)
        updateRails()
    }

    /// The card's edge dragged to `width`: kept between the minimum and what the window has room for.
    func resizeSidebar(to width: CGFloat) {
        guard !compactSidebar else { return }
        cardWidth = max(Self.minimumSidebarWidth, min(width, Self.maximumSidebarWidth, sidebarRoom))
        UserDefaults.standard.set(cardWidth, forKey: Preferences.sidebarWidth)
        makeRoomForSidebar(animated: false)
    }

    /// The text and pages move clear of the open sidebar, sliding with the card; the card's width
    /// follows the window (`sidebarPanelWidth`), the window never follows the card.
    private func makeRoomForSidebar(animated: Bool) {
        sidebar.setCompact(compactSidebar)
        let panelWidth = sidebarPanelWidth
        if sidebarWidthConstraint.constant != panelWidth { sidebarWidthConstraint.constant = panelWidth }
        sidebarMakesRoom = isSidebarVisible
        let inset = sidebarMakesRoom ? panelWidth : 0
        guard textLeading.constant != inset else { return }
        let before = editor.map { view.convert(NSPoint(x: $0.column.x, y: 0), from: $0.scrollView).x }
        textLeading.constant = inset
        view.layoutSubtreeIfNeeded()
        guard animated, animates else { return }
        // Drawn in place at once, then carried over from where it was, so nothing lays out per frame.
        if let editor, let before, page == nil {
            let after = view.convert(NSPoint(x: editor.column.x, y: 0), from: editor.scrollView).x
            slide(editor.scrollView, from: before - after)
        }
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

    /// A choice made in the sidebar: it is beside the text, so it stays for the next one.
    func sidebarDidOpenItem() {}

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

    /// The edge strip each side of the reading area keeps for a resting rail: the outline's ticks
    /// on the right, the open documents' dots on the left, each 14 pt in from the edge with its
    /// pointer zone. Both strips are kept whether or not a rail shows, so the text stays centered
    /// in the reading area and does not move between documents with and without an outline.
    static let railStrip: CGFloat = 44
    /// How far from the trailing edge the outline's ticks reach at most: the rail's 14 pt inset,
    /// the ticks' 10 pt and the longest tick's 16 pt.
    static let ticksReach: CGFloat = 40
    /// The narrowest column the text keeps for the rails; below it the top bar stands in.
    static let columnBesideRail: CGFloat = 560

    /// The two rails beside the text: on the right the outline when chosen (two headings or more,
    /// outside minimal mode), otherwise the top bar's button; on the left the open documents while
    /// the sidebar is hidden (two or more, the quick switcher on), otherwise a count beside the
    /// sidebar button. Where there is room for them, both rails' strips bound the reading area.
    func updateRails() {
        let readerWidth = editorContainer.bounds.width - textLeading.constant
        let outlineWanted = Preferences.outlineBesideText && outlineRail.headings.count >= 2 && !topBar.isHidden && page == nil
        let several = documentRail.items.count > 1 && !topBar.isHidden && !isSidebarVisible
        let documentsWanted = several && UserDefaults.standard.bool(forKey: Preferences.quickSwitcher) && page == nil
        let room = readerWidth - 2 * Self.railStrip >= Self.columnBesideRail
        let outline = outlineWanted && room
        let documents = documentsWanted && room
        editor?.blockCanvas.reservedMargin = 0
        if outlineRail.isHidden == outline { outlineRail.isHidden = !outline }
        if documentRail.isHidden == documents {
            documentRail.isHidden = !documents
            if !documents { documentRail.dismiss() }
        }
        updateReaderInsets(strips: room)
        let button = !outline && !outlineRail.headings.isEmpty && page == nil
        if topBar.outlineButton.isHidden == button { topBar.outlineButton.isHidden = !button }
        topBar.setOpenCount(several && !documents ? documentRail.items.count : nil)
    }

    /// The scroll view still spans the text area, including a persistent scroller gutter. The
    /// canvas centers the reader between the two rail strips, measured against the content
    /// viewport, so overlay and legacy scroller styles center it in the same visible area. Beside
    /// an open sidebar, which the documents' rail never shares, the text centers between what is
    /// seen: the card's edge and the ticks' reach, with the card's clearance on both sides, so it
    /// is as far from the sidebar as from the outline.
    private func updateReaderInsets(strips: Bool) {
        guard let editor else { return }
        // In the scroll view's own terms, so a window laid out for the first time (its scroll view
        // not yet moved beside the sidebar) gets the same insets as later: the text area starts
        // where the viewport does, and a legacy scroller's gutter already takes part of the right.
        let scroll = editor.scrollView
        let gutter = max(0, scroll.bounds.maxX - scroll.contentView.frame.maxX)
        let leading: CGFloat, trailing: CGFloat
        if strips, isSidebarVisible {
            // The text area already starts the card's clearance past its edge; the same past the ticks.
            (leading, trailing) = (0, Self.ticksReach + Self.sidebarInset)
        } else if strips {
            (leading, trailing) = (Self.railStrip, Self.railStrip)
        } else {
            (leading, trailing) = (0, 0)
        }
        editor.blockCanvas.leadingInset = leading
        editor.blockCanvas.trailingInset = max(0, trailing - gutter)
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

}

/// The canvas color behind everything, so no window material shows through (design §8.2).
final class CanvasRootView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Tokens.canvas.cgColor }
    }
}
