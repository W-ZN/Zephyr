import AppKit
import ZephyrCore
import ZephyrRender

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

/// The sidebar (design §7, §8.3, §12): one list from the window down to the folder (`SidebarList`):
/// the window's open documents (from two on: they are its tabs, listed down the side), the app's
/// pages, documents opened lately anywhere, and the folder in view with its files, each
/// section folding away under its heading. Searching the folder is a mode: a field at the top (the
/// folder heading's magnifier, or Find in Folder), its matches in place of the list while it holds
/// text, Esc to leave. The outline is not here: it is the document's own, at the right edge of the
/// text (`OutlineRail`). The panel floats as a card over the text at every window width.
final class ScopeSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Tab: Int { case files, search }

    weak var controller: DocumentWindowController?
    private(set) var tab: Tab = .files
    private let background = SurfaceView(fill: Tokens.sidebar, border: Tokens.line, radius: Tokens.Radius.panel, elevated: true)
    let list = SidebarList()
    private let listScroll = NSScrollView()
    private let searchBox = FieldBox(placeholder: String(localized: "Search in folder"), symbol: "magnifyingglass")
    private var searchField: NSTextField { searchBox.field }
    private let searchRow = NSView()
    private let resultsTable = NSTableView()
    private let resultsScroll = NSScrollView()
    private let empty = flatLabel("", size: 12, color: Tokens.ink3, wraps: true)
    private var listTop: NSLayoutConstraint!
    /// Where the panel's card is drawn: inset while it floats, so the margin and the shadow
    /// around it belong to the panel as well; a press there must not reach the text under it.
    private let card = NSLayoutGuide()

    private var results: [FolderScanner.Match] = []
    private var rootName: String?
    private var searchDebounce: DispatchWorkItem?
    private var searching = false
    private var scanning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for view in [background, searchRow, listScroll, resultsScroll, empty] as [NSView] {
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
            listScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1),
            resultsScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor), resultsScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            resultsScroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor), resultsScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1),
            empty.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24), empty.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            empty.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 28),
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

    /// The panel is an arrow: the text's I-beam must not show through.
    /// Its search field sets its own inside.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// The panel came into view: its list unrolls.
    func didAppear() {
        list.scrollToCurrent()
        list.unroll()
    }

    @objc private func listScrolled() { list.needsDisplay = true }

    // MARK: The list

    /// What the window shows, marked in the list.
    func setPage(_ page: DocumentWindowController.Page?) {
        list.current = page
        refresh()
    }

    /// Pages with a glance at each (today's tasks done, the goals on average, a page's tasks),
    /// recent documents, and the folder's state; then the list again.
    @objc func refresh() {
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
        list.folderStatus = scanning ? String(localized: "Scanning…") : nil
        list.reload()
    }

    private func open(_ kind: SidebarList.Row.Kind) {
        switch kind {
        case let .page(panel): controller?.open(panel: panel)
        case let .recent(url): controller?.navigate(to: url, alongside: true)
        case let .open(tab): controller?.activate(tab)
        case let .file(node): if let url = node.url { controller?.navigate(to: url, alongside: true) }
        case .choose: return controller?.chooseScopeFolder(nil) ?? ()
        case .header, .folder: return
        }
        controller?.sidebarDidOpenItem()
    }

    private func accessory(_ accessory: SidebarList.Accessory, at frame: NSRect) {
        let anchor = NSPoint(x: frame.minX, y: frame.maxY + 4)
        switch accessory {
        case .add: controller?.newPageMenu().popUp(positioning: nil, at: anchor, in: list)
        case .newDocument: controller?.newDocumentHere(nil)
        case .close: break
        case .search: show(.search)
        case .more:
            let menu = NSMenu()
            menu.addItem(withTitle: String(localized: "Choose Folder…"), action: #selector(DocumentWindowController.chooseScopeFolder(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Use Enclosing Folder"), action: #selector(DocumentWindowController.useEnclosingFolder(_:)), keyEquivalent: "")
            if let root = controller?.scopeRoot {
                menu.addItem(ClosureMenuItem(title: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([root]) })
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Close Folder"), action: #selector(DocumentWindowController.closeScope(_:)), keyEquivalent: "")
            menu.popUp(positioning: nil, at: anchor, in: list)
        }
    }

    private func menu(for kind: SidebarList.Row.Kind) -> NSMenu? {
        let menu = NSMenu()
        switch kind {
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

    /// The list, or the search field with its matches.
    func show(_ tab: Tab) {
        self.tab = tab
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

    func setScope(root: URL?, files: [ScopeFile]?, current: URL?) {
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
        let none = tab == .search && query && results.isEmpty && !searching
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
        resultsTable.reloadData()
        updateStatus()
    }

    func appendResults(_ batch: [FolderScanner.Match]) {
        results += batch
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
            show(.files)
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
        let row = resultsTable.clickedRow
        guard row >= 0, row < results.count else { return }
        controller?.open(match: results[row], length: (searchField.stringValue as NSString).length)
        controller?.sidebarDidOpenItem()
    }

    // MARK: Table view (matches)

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FlatRowView() }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = ResultCell.make(in: tableView)
        cell.configure(match: results[row])
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
        ])
        return c
    }

    func configure(match: FolderScanner.Match) {
        file.stringValue = "\(match.file.relativePath):\(match.line)"
        let text = NSMutableAttributedString(string: match.snippet, attributes: [.font: Tokens.font(12), .foregroundColor: Tokens.ink])
        if NSMaxRange(match.snippetRange) <= text.length {
            text.addAttributes([.font: Tokens.font(12, .semibold), .foregroundColor: Tokens.accent], range: match.snippetRange)
        }
        snippet.attributedStringValue = text
    }
}
