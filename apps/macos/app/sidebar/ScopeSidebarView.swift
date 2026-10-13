import AppKit
import ZephyrCore
import ZephyrRender

/// The sidebar's outer edge: dragging it sets the width, and the drag belongs to it, so it neither
/// moves the window nor selects the text beside it. Under the pointer it shows the list's faint tick.
final class SidebarResizeHandle: NSView {
    var onResize: ((CGFloat) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    /// Where in the edge the drag began, so the edge stays under the pointer.
    private var grab: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(String(localized: "Sidebar width"))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        guard let superview else { return }
        grab = superview.bounds.width - superview.convert(event.locationInWindow, from: nil).x
    }
    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onResize?(superview.convert(event.locationInWindow, from: nil).x + grab - 2 * CanvasViewController.sidebarInset)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Tokens.ink3.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - 14, width: 2, height: 28), xRadius: 1, yRadius: 1).fill()
    }
    override func accessibilityPerformIncrement() -> Bool {
        onResize?((superview?.bounds.width ?? 0) - 2 * CanvasViewController.sidebarInset + 16)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        onResize?((superview?.bounds.width ?? 0) - 2 * CanvasViewController.sidebarInset - 16)
        return true
    }
}

/// An icon-only sidebar's row under the pointer, named beside the strip: a small quiet label, its
/// path under the name where it has one.
private final class SidebarHoverLabel: SurfaceView {
    private let title = flatLabel("", size: 12)
    private let path = flatLabel("", size: 11, color: Tokens.ink3)

    init() {
        super.init(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.control)
        path.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [title, path])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 280), path.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ name: String, path: String?) {
        title.stringValue = name
        self.path.stringValue = path ?? ""
        self.path.isHidden = path == nil
    }
}

/// The icon strip's folder browser: a card in the sidebar's own surface beside the strip and as
/// tall as it, so the strip and the text keep their places while the files show.
private final class FilesFlyout: NSView {
    private let surface = SurfaceView(fill: Tokens.sidebar, border: Tokens.line, radius: Tokens.Radius.panel, elevated: true)
    let scroll = NSScrollView()

    init(list: SidebarList) {
        super.init(frame: .zero)
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        scroll.drawsBackground = false
        scroll.verticalScroller = ThinScroller()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = list
        list.autoresizingMask = [.width]
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        surface.frame = bounds
        // Inside the card's border, as the sidebar's list sits inside its card.
        scroll.frame = bounds.insetBy(dx: 1, dy: 1)
    }
}

/// File tree node built from scope file paths.
final class FileNode: NSObject {
    let name: String
    let url: URL?
    var children: [FileNode] = []
    init(name: String, url: URL?) {
        self.name = name
        self.url = url
    }
    var isFolder: Bool { url == nil }

    static func tree(_ files: [ScopeFile]) -> [FileNode] {
        let root = FileNode(name: "", url: nil)
        for file in files {
            var node = root
            let parts = file.relativePath.split(separator: "/").map(String.init)
            for folder in parts.dropLast() {
                if let next = node.children.first(where: { $0.isFolder && $0.name == folder }) {
                    node = next
                } else {
                    let next = FileNode(name: folder, url: nil)
                    node.children.append(next)
                    node = next
                }
            }
            node.children.append(FileNode(name: parts.last ?? file.name, url: file.url))
        }
        func sort(_ n: FileNode) {
            n.children.sort { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            n.children.forEach(sort)
        }
        sort(root)
        return root.children
    }
}

/// The sidebar (design §7, §8.3, §12): one short list of places (`SidebarList`): the app's pages,
/// the window's open documents (its tabs, listed down the side), documents opened lately while no
/// folder is open, and the folder in view as two rows, its Home and its Files. The folder's tree is
/// a mode, as searching is: Files shows it in the list's place, headed by the folder's name, which
/// leads back; so the tree is laid out only when asked for, and the places never move. Searching
/// the folder: a field at the top (the folder's magnifier, or Find in Folder), its matches in place
/// of the list while it holds text, Esc to leave. Resting the pointer on a document shows its
/// opening, rendered (`SidebarDocumentPreview`). The outline is not here: it is the document's own, at the right edge of the
/// text (`OutlineRail`). The panel is a card beside the text, as wide as its outer edge is dragged;
/// Settings can make it a strip of icons, each named beside it under the pointer.
final class ScopeSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// The places, the folder's files, or its search.
    enum Tab: Int { case places, files, search }

    weak var controller: DocumentWindowController?
    private(set) var tab: Tab = .places
    /// Where Esc in the search field returns: the places or the files.
    private var browseTab: Tab = .places
    private let background = SurfaceView(fill: Tokens.sidebar, border: Tokens.line, radius: Tokens.Radius.panel, elevated: true)
    let list = SidebarList()
    private let filesList = SidebarList()
    private lazy var filesFlyout = FilesFlyout(list: filesList)
    /// Shown, or showing: false from the moment it starts to close.
    private var filesFlyoutOpen = false
    /// Tells a finished close apart from one a reopening overtook.
    private var flyoutGeneration = 0
    /// While the browser shows: Escape and a click elsewhere close it. It never takes focus.
    private var flyoutMonitor: Any?
    private let listScroll = NSScrollView()
    private let searchBox = FieldBox(placeholder: String(localized: "Search in folder"), symbol: "magnifyingglass")
    private var searchField: NSTextField { searchBox.field }
    private let searchRow = NSView()
    private let resultsTable = NSTableView()
    private let resultsScroll = NSScrollView()
    private let empty = flatLabel("", size: 12, color: Tokens.ink3, wraps: true)
    private var listTop: NSLayoutConstraint!
    private var listBottom: NSLayoutConstraint!
    /// Where the panel's card is drawn: inset while it floats, so the margin and the shadow
    /// around it belong to the panel as well; a press there must not reach the text under it.
    private let card = NSLayoutGuide()
    private let resizeHandle = SidebarResizeHandle()
    private let hoverLabel = SidebarHoverLabel()
    private let contentPreview = SidebarDocumentPreview()
    var onResize: ((CGFloat) -> Void)?
    /// Searching and the files need the names, so the panel shows them meanwhile.
    var onSearchModeChanged: (() -> Void)?
    /// Icons only (Settings → General → Sidebar).
    private(set) var isCompact = false

    private var results: [FolderScanner.Match] = []
    /// Ranked passages (`RelatedSearch`), listed after the literal matches under their own heading.
    private var related: [FolderScanner.Match] = []
    private var rootName: String?
    private var searchDebounce: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    private var previewGeneration = 0
    private var searching = false
    private var scanning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for view in [background, searchRow, listScroll, resultsScroll, empty, resizeHandle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The field sits on the panel itself: no box, a hairline under it.
        searchBox.isQuiet = true
        searchBox.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.setAccessibilityLabel(String(localized: "Search in folder"))
        let rule = SurfaceView(fill: Tokens.line, border: nil, radius: 0)
        rule.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(searchBox)
        searchRow.addSubview(rule)
        searchRow.isHidden = true

        listScroll.documentView = list
        for scroll in [listScroll, resultsScroll] {
            scroll.drawsBackground = false
            // A thin knob, no track: the system's overlay scroller is heavy in a 280 pt card.
            scroll.verticalScroller = ThinScroller()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.automaticallyAdjustsContentInsets = false
        }
        listScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: listScroll.contentView)
        list.autoresizingMask = [.width]
        list.frame = NSRect(x: 0, y: 0, width: CanvasViewController.sidebarWidth, height: 400)
        list.onOpen = { [weak self] kind in self?.open(kind) }
        list.onAccessory = { [weak self] accessory, frame in self?.accessory(accessory, at: frame) }
        list.onClose = { [weak self] kind in
            if case let .open(tab) = kind { self?.controller?.close(tab) }
        }
        list.menuForRow = { [weak self] kind in self?.menu(for: kind) }
        list.onHover = { [weak self] item in self?.hoverChanged(item) }
        list.onBack = { [weak self] in self?.show(.places) }
        contentPreview.onHeightChanged = { [weak self] in self?.placeContentPreview() }
        list.onPointerDown = { [weak self] in self?.dismissHoverPreviews() }
        resizeHandle.onResize = { [weak self] width in self?.onResize?(width) }
        filesList.setPresentation(compact: false, showsFiles: true)
        filesList.onOpen = { [weak self] kind in
            self?.closeFilesFlyout()
            self?.open(kind)
        }
        filesList.menuForRow = { [weak self] kind in self?.menu(for: kind) }
        filesList.onAccessory = { [weak self] accessory, _ in
            guard accessory == .search else { return }
            self?.closeFilesFlyout()
            self?.show(.search)
        }

        let column = NSTableColumn(identifier: .init("main"))
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        resultsTable.flatten()
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.target = self
        resultsTable.action = #selector(resultClicked)
        resultsTable.usesAutomaticRowHeights = true
        resultsTable.setAccessibilityLabel(String(localized: "Search results"))
        resultsScroll.documentView = resultsTable
        resultsScroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        resultsScroll.isHidden = true
        empty.alignment = .center
        empty.isHidden = true

        listTop = listScroll.topAnchor.constraint(equalTo: card.topAnchor)
        listBottom = listScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1)
        addLayoutGuide(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CanvasViewController.sidebarInset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CanvasViewController.sidebarInset),
            card.topAnchor.constraint(equalTo: topAnchor, constant: CanvasViewController.sidebarInset),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CanvasViewController.sidebarInset),
            background.leadingAnchor.constraint(equalTo: card.leadingAnchor), background.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            background.topAnchor.constraint(equalTo: card.topAnchor), background.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            searchRow.leadingAnchor.constraint(equalTo: card.leadingAnchor), searchRow.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            searchRow.topAnchor.constraint(equalTo: card.topAnchor), searchRow.heightAnchor.constraint(equalToConstant: 44),
            searchBox.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 8), searchBox.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -8),
            searchBox.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor, constant: 2), searchBox.heightAnchor.constraint(equalToConstant: 30),
            rule.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 16), rule.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -16),
            rule.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor), rule.heightAnchor.constraint(equalToConstant: 1),
            listTop,
            listScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor), listScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            listBottom,
            resultsScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor), resultsScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            resultsScroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor), resultsScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1),
            empty.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24), empty.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            empty.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 28),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor), resizeHandle.widthAnchor.constraint(equalToConstant: 8),
            resizeHandle.topAnchor.constraint(equalTo: card.topAnchor), resizeHandle.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: SpaceStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: RecentPages.didChange, object: nil)
        // Read first: the store's first use loads the theme and posts a change.
        list.metrics = SidebarList.Metrics(AppearanceStore.shared.settings)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: AppearanceStore.didChange, object: nil)
        refresh()
    }

    /// The theme sets the list's text size and row height.
    @objc private func themeChanged() {
        list.metrics = SidebarList.Metrics(AppearanceStore.shared.settings)
    }

    /// Names or icons only; the width each keeps is the canvas's (`CanvasViewController`).
    func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        list.setPresentation(compact: compact, showsFiles: false)
        resizeHandle.isHidden = compact
        if !compact { closeFilesFlyout(animated: false) }
        dismissHoverPreviews()
    }

    /// The row under the pointer: icons only, its name at once beside the strip; a document's
    /// opening after a rest, as long as link previews are on (the same setting and delay).
    private func hoverChanged(_ item: SidebarList.HoverItem?) {
        guard let item, let host = superview, !isHidden, !filesFlyoutOpen else { return dismissHoverPreviews() }
        dismissContentPreview()
        if isCompact {
            hoverLabel.show(item.name, path: item.path)
            if hoverLabel.superview !== host { host.addSubview(hoverLabel, positioned: .above, relativeTo: self) }
            let line = host.convert(item.line, from: list)
            let size = hoverLabel.fittingSize
            let x = frame.maxX - CanvasViewController.sidebarInset + 6
            hoverLabel.frame = NSRect(x: x, y: (line.midY - size.height / 2).rounded(), width: min(size.width, host.bounds.width - x - 8), height: size.height)
        } else {
            hoverLabel.removeFromSuperview()
        }
        guard UserDefaults.standard.bool(forKey: Preferences.linkPreviews) else { return }
        let generation = previewGeneration
        // Once a card has shown, the next row's follows at once, as tooltips do.
        let delay = Date() < previewWarmUntil ? 0 : max(0, UserDefaults.standard.double(forKey: Preferences.linkPreviewDelay))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.previewGeneration == generation else { return }
            self.previewWork = nil
            self.loadContentPreview(for: item, generation: generation)
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dismissHoverPreviews() {
        hoverLabel.removeFromSuperview()
        dismissContentPreview()
    }

    /// Until when moving to another row skips the dwell: shortly after a card was showing.
    private var previewWarmUntil = Date.distantPast

    private func dismissContentPreview() {
        if contentPreview.superview != nil { previewWarmUntil = Date(timeIntervalSinceNow: 0.6) }
        previewGeneration &+= 1
        previewWork?.cancel()
        previewWork = nil
        previewLine = nil
        contentPreview.removeFromSuperview()
        contentPreview.clear()
        list.hasContentPreview = false
    }

    /// The text to show: an open document's as it stands in its editor (unsaved changes included),
    /// a file open in any window likewise, otherwise the file's first 8 KiB read off the main thread.
    private func loadContentPreview(for item: SidebarList.HoverItem, generation: Int) {
        let url: URL
        switch item.kind {
        case let .open(tab):
            guard let document = tab.document else { return }
            let text = (tab.editor ?? document.editor).map { SidebarDocumentPreview.opening(of: $0.blockCanvas.text) } ?? String(document.loadedText.prefix(4000))
            return presentContentPreview(item, markdown: text, baseURL: document.fileURL?.deletingLastPathComponent(), generation: generation)
        case let .recent(recent): url = recent
        case let .file(node):
            guard let file = node.url else { return }
            url = file
        default: return
        }
        if let document = NSDocumentController.shared.document(for: url) as? MarkdownDocument {
            let text = document.editor.map { SidebarDocumentPreview.opening(of: $0.blockCanvas.text) } ?? String(document.loadedText.prefix(4000))
            return presentContentPreview(item, markdown: text, baseURL: url.deletingLastPathComponent(), generation: generation)
        }
        guard url.isFileURL else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let text = Self.fileExcerpt(at: url)
            DispatchQueue.main.async {
                guard let self, let text, self.previewGeneration == generation else { return }
                self.presentContentPreview(item, markdown: text, baseURL: url.deletingLastPathComponent(), generation: generation)
            }
        }
    }

    /// Read only the opening 8 KiB plus an EOF byte; previews never map or load an entire file.
    nonisolated private static func fileExcerpt(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = 8 << 10
        guard let data = try? handle.read(upToCount: limit + 1) else { return nil }
        if data.count <= limit { return String(data: data, encoding: .utf8) }
        for trailingBytes in 0...3 {
            if let text = String(data: Data(data.prefix(limit - trailingBytes)), encoding: .utf8) { return text }
        }
        return nil
    }

    /// The row's line in the host, while its preview shows, to keep the card level with it.
    private var previewLine: NSRect?

    /// Beside the sidebar, level with the row, inside the window; none where the room beside the
    /// sidebar is too narrow to read in.
    private func presentContentPreview(_ item: SidebarList.HoverItem, markdown: String, baseURL: URL?, generation: Int) {
        let markdown = SidebarDocumentPreview.opening(of: markdown as NSString)
        guard previewGeneration == generation, !isHidden, let host = superview,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let x = frame.maxX - CanvasViewController.sidebarInset + 6
        let width = min(SidebarDocumentPreview.width, host.bounds.maxX - x - 10)
        guard width >= 220 else { return }
        hoverLabel.removeFromSuperview()
        previewLine = host.convert(item.line, from: list)
        contentPreview.show(name: item.name, path: item.path, markdown: markdown, baseURL: baseURL, width: width)
        if contentPreview.superview !== host {
            host.addSubview(contentPreview, positioned: .above, relativeTo: self)
            if Date() >= previewWarmUntil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                contentPreview.alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 0.12; contentPreview.animator().alphaValue = 1 }
            } else {
                contentPreview.alphaValue = 1
            }
        }
        list.hasContentPreview = true
        placeContentPreview()
    }

    private func placeContentPreview() {
        guard let line = previewLine, let host = contentPreview.superview else { return }
        let size = contentPreview.frame.size
        let x = frame.maxX - CanvasViewController.sidebarInset + 6
        let y = min(max(line.midY - size.height / 2, host.bounds.minY + 8), host.bounds.maxY - size.height - 8)
        contentPreview.setFrameOrigin(NSPoint(x: x, y: y.rounded()))
    }

    override func viewDidHide() {
        super.viewDidHide()
        dismissHoverPreviews()
        closeFilesFlyout(animated: false)
    }

    /// The browser follows the strip as the window resizes.
    override func layout() {
        super.layout()
        placeFilesFlyout()
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The panel is an arrow: the text's I-beam must not show through.
    /// Its search field sets its own inside.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// The panel came into view: keep its current row visible.
    func didAppear() {
        list.scrollToCurrent()
        list.unroll()
    }

    @objc private func listScrolled() {
        list.needsDisplay = true
        dismissHoverPreviews()
    }

    // MARK: The list

    /// What the window shows, marked in the list.
    func setPage(_ page: DocumentWindowController.Page?) {
        list.current = page
        refresh()
    }

    /// Pages with a glance at each (today's tasks done, the goals on average, a page's tasks),
    /// recent documents, and the folder's state; then the list again.
    @objc func refresh() {
        dismissContentPreview()
        let store = SpaceStore.shared
        let tabs = controller?.openTabs ?? []
        // While a page shows, the page is marked, not the document under it.
        list.openDocuments = tabs.map { ($0, $0.shortTitle, $0.holdsUnsavedText, $0 === controller?.current && controller?.panel == nil) }
        // Folder Home belongs to the folder: it is the folder section's first row.
        list.folderHome = controller?.scopeRoot.map { .folderHome($0) }
        var pages: [(panel: SpacePanel, glance: String?)] = []
        for panel in SpacePanel.all(scopeRoot: nil) {
            var glance: String?
            switch panel {
            case .folderHome: break
            case .activity:
                let today = store.activityHistory(days: 1).first
                if let today, today.total > 0 { glance = "\(today.total)" }
            case let .board(url):
                let items = Space.items(in: store.text(of: url) as NSString)
                if !items.isEmpty { glance = "\(items.filter(\.done).count)/\(items.count)" }
            case .markdown: break
            }
            pages.append((panel, glance))
        }
        list.pages = pages
        // Recent is where to start in a window without a folder; with one, its tree is where to go
        // next. Documents open in this window are in its Open section, not again under Recent.
        var shown = Set(tabs.compactMap { $0.document?.fileURL?.standardizedFileURL.path })
        if case let .file(url) = list.current { shown.insert(url.standardizedFileURL.path) }
        list.recent = rootName != nil ? [] : Array(RecentPages.urls.filter { !shown.contains($0.standardizedFileURL.path) }.prefix(4))
        list.rootName = rootName
        list.fileCount = fileCount
        list.folderStatus = scanning ? String(localized: "Scanning…") : nil
        list.reload()
        if filesFlyoutOpen { refreshFilesList() }
    }

    private func open(_ kind: SidebarList.Row.Kind) {
        dismissHoverPreviews()
        switch kind {
        case let .page(panel): controller?.open(panel: panel)
        case let .recent(url): controller?.navigate(to: url, alongside: true)
        case let .open(tab): controller?.activate(tab)
        case let .file(node): if let url = node.url { controller?.navigate(to: url, alongside: true) }
        case .choose: return controller?.chooseScopeFolder(nil) ?? ()
        case .files: return show(.files)
        case .header, .folder: return
        }
        controller?.sidebarDidOpenItem()
    }

    private func accessory(_ accessory: SidebarList.Accessory, at frame: NSRect) {
        switch accessory {
        case .close: break
        case .search: show(.search)
        }
    }

    /// The folder's actions: a secondary click on its heading or on Files (with Search first, the
    /// way to it while the sidebar shows icons only).
    private func folderMenu(search: Bool) -> NSMenu {
        let menu = NSMenu()
        if search {
            menu.addItem(ClosureMenuItem(title: String(localized: "Search in folder")) { [weak self] in self?.show(.search) })
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: String(localized: "Choose Folder…"), action: #selector(DocumentWindowController.chooseScopeFolder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Use Enclosing Folder"), action: #selector(DocumentWindowController.useEnclosingFolder(_:)), keyEquivalent: "")
        if let root = controller?.scopeRoot {
            menu.addItem(ClosureMenuItem(title: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([root]) })
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close Folder"), action: #selector(DocumentWindowController.closeScope(_:)), keyEquivalent: "")
        return menu
    }

    private func menu(for kind: SidebarList.Row.Kind) -> NSMenu? {
        dismissHoverPreviews()
        let menu = NSMenu()
        switch kind {
        // A heading's actions, also where its buttons do not show (icons only).
        case let .header(section):
            switch section {
            case .pages: return controller?.newPageMenu()
            case .open: menu.addItem(ClosureMenuItem(title: String(localized: "New in This Window")) { [weak self] in self?.controller?.newDocumentHere(nil) })
            case .folder: return rootName == nil ? nil : folderMenu(search: true)
            case .recent: return nil
            }
        case let .open(tab):
            menu.addItem(ClosureMenuItem(title: String(localized: "Close")) { [weak self] in self?.controller?.close(tab) })
            menu.addItem(ClosureMenuItem(title: String(localized: "Close Others")) { [weak self] in self?.controller?.closeOthers(than: tab) })
            menu.addItem(ClosureMenuItem(title: String(localized: "Close All")) { [weak self] in self?.controller?.closeAll() })
            menu.addItem(ClosureMenuItem(title: String(localized: "Move to New Window")) { [weak self] in
                self?.controller?.activate(tab)
                self?.controller?.moveToNewWindow(nil)
            })
            if let url = tab.document?.fileURL {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            }
        case let .recent(url):
            menu.addItem(ClosureMenuItem(title: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            menu.addItem(ClosureMenuItem(title: String(localized: "Remove from Recent")) { RecentPages.remove(url) })
        case let .file(node):
            guard let url = node.url else { return nil }
            menu.addItem(ClosureMenuItem(title: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        case .files: return folderMenu(search: true)
        case let .page(panel):
            guard let note = panel.note else { return nil }
            menu.addItem(ClosureMenuItem(title: String(localized: "Open as Markdown")) { [weak self] in self?.controller?.openSpaceNote(note) })
            menu.addItem(ClosureMenuItem(title: String(localized: "Show in Finder")) { [weak self] in
                if let note = self?.controller?.ensured(note) { NSWorkspace.shared.activateFileViewerSelecting([note]) }
            })
            if case .board = panel {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: String(localized: "Move to Trash")) { [weak self] in self?.controller?.trashPage(note) })
            }
        default:
            return nil
        }
        return menu
    }

    // MARK: Files or matches

    /// The places, the folder's files (the places while no folder is open), or the search field
    /// with its matches.
    func show(_ tab: Tab) {
        dismissHoverPreviews()
        if tab == .files, rootName != nil, UserDefaults.standard.bool(forKey: Preferences.sidebarIconsOnly) {
            if self.tab != .places { show(.places) }
            // Menu commands may show the sidebar immediately after this call. Anchor the browser
            // after that layout, without changing the pinned strip's mode or width.
            DispatchQueue.main.async { [weak self] in self?.toggleFilesFlyout() }
            return
        }
        closeFilesFlyout(animated: false)
        // With names, the folder's files are in the list itself: Files shows the current one.
        let showsFile = tab == .files
        let tab = tab == .files ? .places : tab
        let changedFiles = tab != .search && tab != browseTab
        if changedFiles {
            browseTab = tab
        }
        self.tab = tab
        onSearchModeChanged?()
        list.setPresentation(compact: isCompact, showsFiles: false)
        if changedFiles || showsFile {
            list.scroll(.zero)
            list.scrollToCurrent()
        }
        let searchMode = tab == .search
        searchRow.isHidden = !searchMode
        listTop.constant = searchMode ? 44 : 0
        if searchMode {
            window?.makeFirstResponder(searchField)
        } else if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            searchBox.textDidChangeProgrammatically()
            searchDebounce?.cancel()
            searching = false
            clearResults()
        }
        updateStatus()
    }

    /// Folder browsing is temporary in the icon strip; the pinned navigation never expands.
    private func toggleFilesFlyout() {
        guard let host = superview, !isHiddenOrHasHiddenAncestor, rootName != nil else { return }
        if filesFlyoutOpen { return closeFilesFlyout() }
        filesFlyoutOpen = true
        list.filesOpen = true
        flyoutGeneration &+= 1
        dismissHoverPreviews()
        refreshFilesList()
        if filesFlyout.superview !== host { host.addSubview(filesFlyout, positioned: .above, relativeTo: self) }
        placeFilesFlyout()
        filesList.scrollToCurrent()
        // It slides out from behind the strip as it fades in.
        if animates {
            let target = filesFlyout.frame
            filesFlyout.alphaValue = 0
            filesFlyout.setFrameOrigin(NSPoint(x: target.minX - 8, y: target.minY))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                filesFlyout.animator().alphaValue = 1
                filesFlyout.animator().setFrameOrigin(target.origin)
            }
        } else {
            filesFlyout.alphaValue = 1
        }
        flyoutMonitor = flyoutMonitor ?? NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.filesFlyoutOpen else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.closeFilesFlyout()
                return nil
            }
            // A click in the browser stays there; one on Files closes it (and does not reopen it);
            // anywhere else closes it and goes on to what was clicked.
            if event.window === self.window {
                if self.filesFlyout.bounds.contains(self.filesFlyout.convert(event.locationInWindow, from: nil)) { return event }
                if event.type == .leftMouseDown, let entry = self.list.filesEntryRect, entry.contains(self.list.convert(event.locationInWindow, from: nil)) {
                    self.closeFilesFlyout()
                    return nil
                }
            }
            self.closeFilesFlyout()
            return event
        }
    }

    private func closeFilesFlyout(animated: Bool = true) {
        if let flyoutMonitor { NSEvent.removeMonitor(flyoutMonitor) }
        flyoutMonitor = nil
        list.filesOpen = false
        guard filesFlyout.superview != nil else { return }
        filesFlyoutOpen = false
        let generation = flyoutGeneration
        guard animated, animates else { return filesFlyout.removeFromSuperview() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            filesFlyout.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.filesFlyoutOpen, self.flyoutGeneration == generation else { return }
            self.filesFlyout.removeFromSuperview()
        })
    }

    /// Beside the strip's card, 6 pt from it, as tall as it, and inside the window.
    private func placeFilesFlyout() {
        guard filesFlyoutOpen, let host = filesFlyout.superview else { return }
        let strip = host.convert(card.frame, from: self)
        let x = strip.maxX + 6
        filesFlyout.frame = NSRect(x: x, y: strip.minY, width: max(180, min(280, host.bounds.maxX - x - 10)), height: strip.height)
    }

    /// Motion only where someone can see it, and never with Reduce Motion on.
    private var animates: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && window?.occlusionState.contains(.visible) == true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeFilesFlyout(animated: false) }
    }

    private func refreshFilesList() {
        filesList.metrics = list.metrics
        filesList.nodes = list.nodes
        filesList.rootName = rootName
        filesList.rootPath = list.rootPath
        filesList.folderStatus = list.folderStatus
        filesList.current = list.current
        filesList.reload()
    }

    func setScope(root: URL?, files: [ScopeFile]?, current: URL?) {
        if root == nil { closeFilesFlyout(animated: false) }
        rootName = root?.lastPathComponent
        searchField.placeholderString = rootName.map { String(localized: "Search in \($0)") } ?? String(localized: "Search in folder")
        // The path and the count are the heading's tooltip, not more text in the list.
        list.rootPath = root.map { url in
            let path = (url.path as NSString).abbreviatingWithTildeInPath
            return fileCount.map { path + " · " + String(localized: "\($0) files") } ?? path
        }
        if let files {
            list.nodes = FileNode.tree(files)
            if let current { list.reveal(file: current) }
        }
        // No folder, no files: back to the places.
        if root == nil, tab == .files { show(.places) }
        refresh()
    }

    var fileCount: Int? { controller?.scopeFileCount }

    func setScanning(_ scanning: Bool) {
        self.scanning = scanning
        refresh()
    }

    private func updateStatus() {
        let query = !searchField.stringValue.isEmpty
        resultsScroll.isHidden = !(tab == .search && query)
        listScroll.isHidden = !resultsScroll.isHidden
        let none = tab == .search && query && results.isEmpty && related.isEmpty && !searching
        empty.stringValue = String(localized: "No matches for “\(searchField.stringValue)”.")
        empty.isHidden = !none
    }

    func focusSearch(with text: String?) {
        show(.search)
        if let text, !text.isEmpty {
            searchField.stringValue = text
            searchBox.textDidChangeProgrammatically()
            searchChanged()
        }
        window?.makeFirstResponder(searchField)
    }

    func clearResults() {
        results = []
        related = []
        resultsTable.reloadData()
        updateStatus()
    }

    func appendResults(_ batch: [FolderScanner.Match]) {
        results += batch
        resultsTable.reloadData()
        updateStatus()
    }

    func setRelated(_ batch: [FolderScanner.Match]) {
        related = batch
        resultsTable.reloadData()
        updateStatus()
    }

    func searchFinished(empty: Bool) {
        searching = false
        updateStatus()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === searchField else { return }
        searchChanged()
    }

    /// Esc in the field clears it; on an empty field it leaves search for the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        if searchField.stringValue.isEmpty {
            show(browseTab)
            window?.makeFirstResponder(controller?.editor?.focusView)
            return true
        }
        searchField.stringValue = ""
        searchBox.textDidChangeProgrammatically()
        searchChanged()
        return true
    }

    @objc private func searchChanged() {
        searchDebounce?.cancel()
        let query = searchField.stringValue
        searching = !query.isEmpty
        updateStatus()
        let work = DispatchWorkItem { [weak self] in self?.controller?.runScopeSearch(query) }
        searchDebounce = work
        // Debounce ~150 ms; a new query cancels the running scan (design §12).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func resultClicked() {
        guard let match = match(at: resultsTable.clickedRow) else { return }
        controller?.open(match: match, length: match.length ?? (searchField.stringValue as NSString).length)
        controller?.sidebarDidOpenItem()
    }

    // MARK: Table view (matches)

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FlatRowView() }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count + (related.isEmpty ? 0 : related.count + 1) }

    /// The match shown in `row`; nil for the heading above the related ones.
    private func match(at row: Int) -> FolderScanner.Match? {
        guard row >= 0 else { return nil }
        if row < results.count { return results[row] }
        let i = row - results.count - 1
        return i >= 0 && i < related.count ? related[i] : nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { match(at: row) != nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let match = match(at: row) else { return ResultHeaderCell.make(in: tableView) }
        let cell = ResultCell.make(in: tableView)
        cell.configure(match: match)
        return cell
    }
}

private final class ResultCell: NSTableCellView {
    private let file = NSTextField(labelWithString: "")
    private let snippet = NSTextField(wrappingLabelWithString: "")

    static func make(in table: NSTableView) -> ResultCell {
        if let c = table.makeView(withIdentifier: .init("result"), owner: nil) as? ResultCell { return c }
        let c = ResultCell()
        c.identifier = .init("result")
        c.file.font = Tokens.font(11, .medium)
        c.file.textColor = Tokens.ink3
        c.file.lineBreakMode = .byTruncatingMiddle
        c.file.maximumNumberOfLines = 1
        c.file.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        c.snippet.font = Tokens.font(12)
        c.snippet.maximumNumberOfLines = 2
        c.snippet.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [c.file, c.snippet])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: c.leadingAnchor), stack.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            stack.topAnchor.constraint(equalTo: c.topAnchor), stack.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            c.snippet.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -26),
            c.file.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -26),
        ])
        return c
    }

    func configure(match: FolderScanner.Match) {
        file.stringValue = match.isRelated ? match.file.relativePath + (match.heading.map { " › " + $0 } ?? "") : "\(match.file.relativePath):\(match.line)"
        let text = NSMutableAttributedString(string: match.snippet, attributes: [.font: Tokens.font(12), .foregroundColor: Tokens.ink])
        if NSMaxRange(match.snippetRange) <= text.length {
            text.addAttributes([.font: Tokens.font(12, .semibold), .foregroundColor: Tokens.accent], range: match.snippetRange)
        }
        snippet.attributedStringValue = text
    }
}

/// The quiet heading between the literal matches and the related passages.
private final class ResultHeaderCell: NSTableCellView {
    static func make(in table: NSTableView) -> ResultHeaderCell {
        if let c = table.makeView(withIdentifier: .init("resultHeader"), owner: nil) as? ResultHeaderCell { return c }
        let c = ResultHeaderCell()
        c.identifier = .init("resultHeader")
        let label = NSTextField(labelWithString: String(localized: "Related"))
        label.font = Tokens.font(11, .medium)
        label.textColor = Tokens.ink3
        label.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
            label.topAnchor.constraint(equalTo: c.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -4),
        ])
        c.setAccessibilityLabel(String(localized: "Related passages"))
        return c
    }
}
