import AppKit
import ZephyrCore
import ZephyrRender

/// One reading window. Its top bar holds only the scope entry (sidebar button) and the path, which
/// doubles as the scope control (design §7.2, §8.2). A window holds the documents opened in it
/// (`DocumentTab`, design §7.8), listed in the sidebar's Open section rather than on a tab bar:
/// what is opened from the sidebar, the path, Open Quickly or a page gets its own place there (or
/// shows its place again); a link followed in the text replaces the shown document, with Back to
/// return. The app's pages are permanent places, not open documents: one shows over the current
/// document, in its history, and the last document closing leaves the window on Activity.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let canvas = CanvasViewController()
    var editor: MarkdownEditor? { canvas.editor }
    /// What a tab has shown, for back and forward: documents and the app's pages.
    enum Page: Equatable {
        case file(URL)
        /// An untitled document: it can only be returned to while its tab still holds it.
        case untitled(MarkdownDocument)
        case panel(SpacePanel)
    }
    /// The window's places, in the order the sidebar lists them, and the one shown. Each holds a
    /// document, except a lone place showing a page while the window has no document.
    private(set) var tabs: [DocumentTab]
    private(set) var current: DocumentTab
    /// The places the Open section lists, the switcher counts and ⌃⇥ steps through: documents.
    var openTabs: [DocumentTab] { tabs.filter { $0.document != nil } }
    /// The app page shown over the document, if any.
    var panel: SpacePanel? { current.panel }
    private(set) var scopeRoot: URL?
    private var scopeFiles: [ScopeFile]?
    private var scanTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var outlineRefresh: DispatchWorkItem?
    private var statistics = (document: TextStatistics(), selection: TextStatistics?.none)
    private var statisticsWork: DispatchWorkItem?
    private var statisticsGeneration = 0
    /// The text changed since the document was last counted; a selection count does not clear it.
    private var statisticsStale = true
    private weak var statisticsCard: StatisticsCard?
    private static let statisticsQueue = DispatchQueue(label: "dev.zephyr.statistics", qos: .utility)
    private var scrollObserver: NSObjectProtocol?
    /// A document keeps its window's controller; a window showing only a page, or a document's
    /// window while another of its documents shows, has none to, so it keeps itself until it closes.
    private var keepAlive: DocumentWindowController?

    /// A window showing `document`, or (nil) only an app page until something is opened.
    convenience init(document: MarkdownDocument?) {
        self.init(tab: DocumentTab(document: nil))
        if let document { attach(document, recordHistory: true) } else { present() }
    }

    /// A window for a tab that already exists (moved out of another window).
    private init(tab: DocumentTab) {
        tabs = [tab]
        current = tab
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(920, screen.width - 80), height: min(1000, screen.height - 40))
        let window = DocumentWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.acceptsMouseMovedEvents = true
        // An empty toolbar only gives the title bar the top bar's height; Zephyr draws the bar.
        window.toolbar = NSToolbar(identifier: "ZephyrDocument")
        window.toolbarStyle = .unifiedCompact
        // Several documents live in one window's sidebar, never on the system's tab bar.
        window.tabbingMode = .disallowed
        window.isRestorable = UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState") == false
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)
        keepAlive = self
        window.delegate = self
        shouldCascadeWindows = true
        canvas.controller = self
        canvas.sidebar.controller = self
        canvas.topBar.controller = self
        window.contentViewController = canvas
        window.setContentSize(size)
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: AppearanceStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(frontMatterChanged), name: Preferences.frontMatterDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(remoteImagesChanged), name: Preferences.remoteImagesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(agentAccessChanged), name: AgentAccess.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pageMoved(_:)), name: SpaceStore.pageMoved, object: nil)
        canvas.setMinimal(UserDefaults.standard.bool(forKey: Preferences.minimalMode))
        canvas.outlineCard.onSelect = { [weak self] heading in self?.revealHeading(heading) }
        canvas.outlineRail.onSelect = { [weak self] heading in self?.revealHeading(heading) }
        canvas.outlineRail.onScroll = { [weak self] event in self?.editor?.scrollView.scrollWheel(with: event) }
        canvas.outlineRail.onPress = { [weak self] in self?.showOutlineTab(nil) }
        canvas.outlineCard.onRename = { [weak self] heading, title in self?.renameHeading(heading, to: title) }
        if let editor = tab.editor { connect(editor) }
    }

    required init?(coder: NSCoder) { fatalError() }

    var markdownDocument: MarkdownDocument? { current.document }

    /// The document window in front, for notices that are not about one document.
    static var front: DocumentWindowController? {
        (NSApp.mainWindow?.windowController as? DocumentWindowController)
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? DocumentWindowController }.first
    }

    /// Where a document opened by `NSDocumentController` goes when not into a window of its own:
    /// the window that asked (New in This Window), or the one in front when the system's tab
    /// preference says documents open as tabs — always, or while that window is in full screen.
    static func hostForNewDocument() -> DocumentWindowController? {
        if let asking = openingHere { return asking }
        guard let front else { return nil }
        switch NSWindow.userTabbingPreference {
        case .always: return front
        case .inFullScreen: return front.window?.styleMask.contains(.fullScreen) == true ? front : nil
        default: return nil
        }
    }

    private static weak var openingHere: DocumentWindowController?

    /// File → New in This Window: an untitled document beside the current one.
    @objc func newDocumentHere(_ sender: Any?) {
        Self.openingHere = self
        defer { Self.openingHere = nil }
        NSDocumentController.shared.newDocument(sender)
    }

    /// The window holding `document`, shown or in the background.
    static func hosting(_ document: MarkdownDocument) -> DocumentWindowController? {
        all.first { $0.tabs.contains { $0.document === document } }
    }

    /// A quiet notice above the text of the tab showing `document` (the current tab when nil); a
    /// tab in the background shows it when it comes forward.
    func showBanner(_ text: String?, symbol: String = "info.circle", for document: MarkdownDocument? = nil, actions: [(String, () -> Void)] = []) {
        let tab = document.flatMap { doc in tabs.first { $0.document === doc } } ?? current
        tab.banner = text.map { ($0, symbol, actions) }
        if tab === current { canvas.showBanner(text, symbol: symbol, actions: actions) }
    }
    var fileURL: URL? { markdownDocument?.fileURL }
    var scopeFileCount: Int? { scopeFiles?.count }
    var scopedFiles: [ScopeFile] { scopeFiles ?? [] }

    // MARK: - Document

    /// The document's canvas, made once for the tab that holds it.
    private func prepare(_ doc: MarkdownDocument, in tab: DocumentTab) {
        let editor = MarkdownEditor(text: doc.loadedText, typography: AppearanceStore.shared.typography, baseURL: doc.fileURL?.deletingLastPathComponent(), isEditable: !doc.isReadOnly, canvas: writesPlainText ? .source : LaunchMode.canvasChoice)
        doc.editorDidLoad()
        editor.newline = doc.encoding.newline
        editor.frontMatterCollapsed = UserDefaults.standard.bool(forKey: Preferences.frontMatterCollapsed)
        editor.remoteImagesPreferred = UserDefaults.standard.bool(forKey: Preferences.remoteImages)
        connect(editor)
        doc.editor = editor
        tab.document = doc
        tab.editor = editor
        tab.panel = nil
        tab.banner = Self.readOnlyReason(of: doc).map { ($0, "lock.fill", []) }
    }

    /// The canvas reports to this window (again, after its tab moved here from another).
    private func connect(_ editor: MarkdownEditor) {
        editor.openLink = { [weak self] destination in self?.openLink(destination) }
        editor.askLinkPreview = { [weak self] destination, excerpt in
            guard let self else { return }
            if !self.canvas.isAIOpen { self.canvas.toggleAIPanel() }
            let request = String(localized: "Help me understand this linked content:")
            self.canvas.aiPanel?.prefill("\(request)\n\(destination)\n\n\(excerpt)")
        }
        // A tab in the background has no outline or count on show.
        editor.structureDidChange = { [weak self, weak editor] in
            guard let self, editor === self.editor else { return }
            self.scheduleOutlineRefresh()
            self.scheduleStatistics(textChanged: true)
        }
        editor.selectionDidChange = { [weak self, weak editor] in
            guard let self, let editor, editor === self.editor else { return }
            self.scheduleStatistics(textChanged: false)
            self.canvas.setCaretLocation(editor.selectedRange.location)
        }
        editor.frontMatterCollapseToggled = { collapsed in
            UserDefaults.standard.set(collapsed, forKey: Preferences.frontMatterCollapsed)
            NotificationCenter.default.post(name: Preferences.frontMatterDidChange, object: nil)
        }
        editor.tableDefaultsChosen = { width, alignment in
            try? AppearanceStore.shared.update {
                try $0.set("table.width", width.rawValue)
                try $0.set("table.align", alignment.rawValue)
            }
        }
    }

    private static func readOnlyReason(of doc: MarkdownDocument) -> String? {
        doc.isStoredVersion ? String(localized: "An earlier version kept by macOS, opened read-only for comparison.")
            : doc.isReadOnly ? String(localized: "Read-only: this file is not valid UTF-8, so Zephyr will not rewrite it.") : nil
    }

    /// A document comes into the current tab and shows.
    private func attach(_ doc: MarkdownDocument, recordHistory: Bool) {
        prepare(doc, in: current)
        if recordHistory { record(page(of: doc)) }
        if let url = doc.fileURL, !url.standardizedFileURL.path.hasPrefix(SpaceStore.shared.root.standardizedFileURL.path) {
            RecentPages.note(url)
            do { try SpaceStore.shared.recordActivityOpen(url) } catch { window?.presentError(error) }
        }
        if current.banner == nil, !writesPlainText, current.editor?.blockCanvas.mode == .source {
            // Said once per open, and dismissable: the file is fine, only its presentation differs.
            current.banner = (String(localized: "Shown as source to stay fast."), "text.alignleft", [(String(localized: "OK"), { [weak self] in self?.showBanner(nil) })])
        }
        present()
        if let url = doc.fileURL, let editor, let position = current.readingPositions[url] { editor.scrollToCharacter(position) }
    }

    /// Shows the current tab: its document's canvas, its page, its notice and its chat; the bar, the
    /// sidebar and the window's title follow.
    private func present() {
        let doc = current.document
        canvas.setEditor(current.editor, readOnlyReason: nil)
        canvas.restoreAssistant(current.assistant)
        current.assistant = nil
        if let (text, symbol, actions) = current.banner { canvas.showBanner(text, symbol: symbol, actions: actions) }
        canvas.showPage(current.panel.map { $0.makePage(self) })
        canvas.sidebar.setPage(shownPage)
        window?.representedURL = doc?.fileURL
        window?.isDocumentEdited = doc?.isDocumentEdited ?? false
        if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) }
        scrollObserver = editor.map { editor in
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: editor.scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackReadingHeading(scrolling: true) }
            }
        }
        updatePath()
        scheduleOutlineRefresh(immediately: true)
        statistics = (TextStatistics(), nil)
        statisticsStale = true
        canvas.topBar.setStatistics("", help: "")
        scheduleStatistics(textChanged: true, immediately: true)
        if let root = scopeRoot { canvas.sidebar.setScope(root: root, files: scopeFiles, current: doc?.fileURL) }
        agentAccessChanged()
        openDocumentsChanged()
        if current.panel == nil, let editor { window?.makeFirstResponder(editor.focusView) }
    }

    /// What the sidebar marks as shown.
    private var shownPage: Page? {
        if let panel = current.panel { return .panel(panel) }
        return fileURL.map { .file($0) }
    }

    private func page(of doc: MarkdownDocument) -> Page { doc.fileURL.map { .file($0) } ?? .untitled(doc) }

    /// Replace this tab's document (in-place navigation). Unsaved changes are written before the
    /// document leaves the window; when that fails it stays here with the error, and the target
    /// opens beside it instead.
    private func swap(to doc: MarkdownDocument, recordHistory: Bool, then done: @escaping () -> Void) {
        guard let old = markdownDocument, old.isDocumentEdited || old.hasUnautosavedChanges else {
            replace(with: doc, recordHistory: recordHistory)
            return done()
        }
        old.autosave(withImplicitCancellability: false) { [weak self] error in
            guard let self, self.markdownDocument === old else { return }
            if let error {
                self.window?.presentError(error)
                self.openAlongside(doc)
                return
            }
            // Typed while it saved: save that too before leaving.
            self.swap(to: doc, recordHistory: recordHistory, then: done)
        }
    }

    private func replace(with doc: MarkdownDocument, recordHistory: Bool) {
        if let old = markdownDocument {
            if let url = old.fileURL, let editor { current.readingPositions[url] = editor.firstVisibleCharacter() }
            // An untitled document replaced in place was empty; it is gone, and so is its place in history.
            if old.fileURL == nil { forget(.untitled(old), in: current) }
            old.removeWindowController(self)
            current.document = nil
            current.editor = nil
            old.close()
        }
        doc.addWindowController(self)
        attach(doc, recordHistory: recordHistory)
    }

    /// `alongside`: the document gets its own place in the window's Open list, or its place there
    /// shows again. Otherwise it replaces the shown document, with Back to return; text that exists
    /// nowhere else is never replaced, so it goes alongside then too.
    func navigate(to url: URL, alongside: Bool = false, select: NSRange? = nil, anchor: String? = nil, recordHistory: Bool = true, then done: (() -> Void)? = nil) {
        if fileURL?.standardizedFileURL == url.standardizedFileURL, !alongside || panel == nil {
            if panel != nil {
                hidePanel()
                if recordHistory { record(.file(url)) }
            }
            if !url.standardizedFileURL.path.hasPrefix(SpaceStore.shared.root.standardizedFileURL.path) {
                RecentPages.note(url)
                do { try SpaceStore.shared.recordActivityOpen(url) } catch { window?.presentError(error) }
            }
            if let select { self.select(select) }
            if let anchor { self.revealAnchor(anchor) }
            done?()
            return
        }
        // Text that exists nowhere else is never replaced: the target opens beside it.
        let keepCurrent = current.holdsUnsavedText
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { [weak self] document, alreadyOpen, error in
            guard let self else { return }
            if let error {
                self.window?.presentError(error)
                return
            }
            guard let doc = document as? MarkdownDocument else { return }
            if alreadyOpen, let host = Self.hosting(doc) {
                host.reveal(doc)
                host.hidePanel()
                if let select { host.select(select) }
                if let anchor { host.revealAnchor(anchor) }
                done?()
                return
            }
            if alongside || keepCurrent {
                self.openAlongside(doc, select: select, anchor: anchor)
                return done?() ?? ()
            }
            self.swap(to: doc, recordHistory: recordHistory) {
                if let select { self.select(select) }
                if let anchor { self.revealAnchor(anchor) }
                done?()
            }
        }
    }

    private func record(_ page: Page) {
        let tab = current
        guard tab.history.indices.contains(tab.historyIndex) == false || tab.history[tab.historyIndex] != page else { return }
        tab.history = Array(tab.history.prefix(tab.historyIndex + 1)) + [page]
        tab.historyIndex = tab.history.count - 1
    }

    // MARK: - Open documents (design §7.8)

    /// A new place in this window after the current one, shown (empty until something comes into it).
    private func insertTab() {
        sendToBackground(current)
        let tab = DocumentTab(document: nil)
        tabs.insert(tab, at: (tabs.firstIndex { $0 === current } ?? tabs.count - 1) + 1)
        current = tab
        window?.invalidateRestorableState()
    }

    /// `doc` joins the window's open documents, after the current one, and shows. A place showing
    /// only a page (a window without documents) takes it, so Back returns to the page.
    func openAlongside(_ doc: MarkdownDocument, select: NSRange? = nil, anchor: String? = nil) {
        if current.document != nil { insertTab() }
        doc.addWindowController(self)
        attach(doc, recordHistory: true)
        window?.makeKeyAndOrderFront(nil)
        if let select { self.select(select) }
        if let anchor { revealAnchor(anchor) }
    }

    /// A document that `NSDocumentController` opened for this window (New in This Window, Open…
    /// or the Finder with the system's preference for tabs).
    func adopt(_ doc: MarkdownDocument) {
        // An untouched empty document gives its place to a file opened from elsewhere.
        if Self.openingHere == nil, let old = markdownDocument, old.isEmptyUntitled, !old.isDocumentEdited, panel == nil { return replace(with: doc, recordHistory: true) }
        openAlongside(doc)
    }

    /// An app page opened by the reader shows in the current place, over its document (design §7.8).
    func open(panel: SpacePanel) { show(panel: panel) }

    /// Brings the tab holding `doc` forward, with its window.
    func reveal(_ doc: MarkdownDocument) {
        if let tab = tabs.first(where: { $0.document === doc }) { activate(tab) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// A place comes forward showing its document: an Open row, ⌃⇥ and the switcher choose a
    /// document, whatever page was over it.
    func activate(_ tab: DocumentTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        guard tab !== current else { return returnToDocument() }
        sendToBackground(current)
        current = tab
        if let doc = tab.document {
            if tab.panel != nil {
                tab.panel = nil
                record(page(of: doc))
            }
            doc.addWindowController(self)
        }
        present()
        window?.invalidateRestorableState()
    }

    /// The page over the current document is put away, as a step in its history.
    private func returnToDocument() {
        guard let doc = current.document, current.panel != nil else { return }
        hidePanel()
        record(page(of: doc))
    }

    /// The shown place goes to the background: its chat is kept, its document stops naming this
    /// window, and its canvas keeps its text and place but lets go of its shaped lines.
    private func sendToBackground(_ tab: DocumentTab) {
        tab.assistant = canvas.takeAssistant()
        if let doc = tab.document, doc.windowControllers.contains(self) { doc.removeWindowController(self) }
        tab.editor?.blockCanvas.releaseLayouts()
    }

    /// The sidebar's Open section, the count beside the sidebar button and the quick switcher.
    private func openDocumentsChanged() {
        canvas.openDocumentsChanged()
    }

    /// File → Close acts on what is shown: a document leaves the window (the last one leaves it on
    /// Activity); a page, which cannot leave, is put away to show the document under it, or the
    /// window closes when there is none.
    @objc func closeDocument(_ sender: Any?) {
        guard current.panel == nil else {
            return current.document == nil ? window?.performClose(nil) ?? () : returnToDocument()
        }
        close(current)
    }

    /// Every document leaves, each asking what its own close would; the window stays, on Activity.
    func closeAll() {
        closeOthers(than: current) { [weak self] in
            guard let self, self.current.document != nil else { return }
            self.close(self.current)
        }
    }

    func close(_ tab: DocumentTab) {
        guard tab.document != nil else { window?.performClose(nil); return }
        // Its question (keep or delete an untitled document) shows over it.
        if Self.asksBeforeClosing(tab) { activate(tab) }
        askToClose(tab.document) { [weak self] ok in
            guard ok, let self else { return }
            self.remove(tab)
            tab.discard()
            tab.document?.close()
        }
    }

    /// Every other document leaves, each asking what its own close would; a cancel stops there.
    func closeOthers(than tab: DocumentTab, then done: (() -> Void)? = nil) {
        guard let other = tabs.first(where: { $0 !== tab }) else {
            activate(tab)
            done?()
            return
        }
        if Self.asksBeforeClosing(other) { activate(other) }
        askToClose(other.document) { [weak self] ok in
            guard ok, let self else { return }
            self.remove(other)
            other.discard()
            other.document?.close()
            self.closeOthers(than: tab, then: done)
        }
    }

    /// The document was closed (by AppKit replacing an untouched untitled document, or elsewhere):
    /// its place in the sidebar goes too. The last one takes the window with it, as usual.
    func documentClosed(_ doc: MarkdownDocument) {
        guard tabs.count > 1, let tab = tabs.first(where: { $0.document === doc }) else { return }
        remove(tab)
        tab.discard()
    }

    private static func asksBeforeClosing(_ tab: DocumentTab) -> Bool {
        tab.holdsUnsavedText && tab.document?.isDocumentEdited == true
    }

    /// The tab leaves the window; its document stays open for the caller to close or move. Without
    /// another, the window shows Activity.
    private func remove(_ tab: DocumentTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tab === current {
            if tabs.count > 1 {
                activate(tabs[index + 1 < tabs.count ? index + 1 : index - 1])
            } else {
                let page = DocumentTab(document: nil)
                page.panel = .activity
                page.history = [.panel(.activity)]
                page.historyIndex = 0
                tabs.append(page)
                activate(page)
            }
        }
        tabs.removeAll { $0 === tab }
        openDocumentsChanged()
        window?.invalidateRestorableState()
    }

    private final class Reply {
        let run: (Bool) -> Void
        init(_ run: @escaping (Bool) -> Void) { self.run = run }
    }

    /// NSDocument's own question before closing (an untitled document: keep or delete); a file that
    /// autosaves in place closes without one.
    private func askToClose(_ doc: MarkdownDocument?, then: @escaping (Bool) -> Void) {
        guard let doc else { return then(true) }
        doc.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: Unmanaged.passRetained(Reply(then)).toOpaque())
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo else { return }
        Unmanaged<Reply>.fromOpaque(contextInfo).takeRetainedValue().run(shouldClose)
    }

    /// Closing the window closes every document in it: the others first, each asking what its own
    /// close would, then the window the usual way for the one shown.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A document under a page is not the window's document, so AppKit would not ask it: the
        // page gives way, then the window closes the usual way.
        if current.panel != nil, current.document != nil {
            returnToDocument()
            DispatchQueue.main.async { [weak self] in self?.window?.performClose(nil) }
            return false
        }
        guard tabs.count > 1 else { return true }
        closeOthers(than: current) { [weak self] in
            DispatchQueue.main.async { self?.window?.performClose(nil) }
        }
        return false
    }

    @objc func showNextDocument(_ sender: Any?) { step(tabsBy: 1) }
    @objc func showPreviousDocument(_ sender: Any?) { step(tabsBy: -1) }

    private func step(tabsBy delta: Int) {
        let open = openTabs
        guard let index = open.firstIndex(where: { $0 === current }), open.count > 1 else { return }
        activate(open[(index + delta + open.count) % open.count])
    }

    /// The tab shown moves into a window of its own, beside this one, showing its document.
    @objc func moveToNewWindow(_ sender: Any?) {
        guard openTabs.count > 1, current.document != nil else { return }
        let tab = current
        remove(tab)
        tab.panel = nil
        let controller = DocumentWindowController(tab: tab)
        if let doc = tab.document { doc.addWindowController(controller) }
        controller.inheritScope(from: self)
        controller.present()
        if let frame = window?.frame { controller.window?.setFrame(frame.offsetBy(dx: 24, dy: -24), display: false) }
        controller.showWindow(nil)
    }

    /// Every document window's documents come into this one, after its own.
    @objc func mergeAllWindows(_ sender: Any?) {
        for other in Self.all where other !== self {
            for tab in other.tabs { other.release(tab) }
            other.tabs.forEach { receive($0) }
            other.tabs = []
            other.window?.close()
        }
        openDocumentsChanged()
        window?.invalidateRestorableState()
    }

    /// A tab leaving for another window: its chat goes with it, its document stops naming this window.
    private func release(_ tab: DocumentTab) {
        if tab === current { tab.assistant = canvas.takeAssistant() }
        if let doc = tab.document, doc.windowControllers.contains(self) { doc.removeWindowController(self) }
    }

    private func receive(_ tab: DocumentTab) {
        tabs.append(tab)
        if let editor = tab.editor { connect(editor) }
    }

    // MARK: - The app's pages

    /// Shows an app page in place of the document, which stays open underneath but stops being the
    /// window's document while hidden (Save, Export and Undo do not reach it).
    func show(panel: SpacePanel, recordHistory: Bool = true) {
        if recordHistory { record(.panel(panel)) }
        guard panel != current.panel else { return }
        if let doc = current.document, doc.windowControllers.contains(self) { doc.removeWindowController(self) }
        current.panel = panel
        canvas.showPage(panel.makePage(self))
        canvas.sidebar.setPage(.panel(panel))
        updatePath()
        openDocumentsChanged()
    }

    private func hidePanel() {
        guard current.panel != nil else { return }
        current.panel = nil
        if let doc = current.document, !doc.windowControllers.contains(self) { doc.addWindowController(self) }
        canvas.showPage(nil)
        canvas.sidebar.setPage(fileURL.map { .file($0) })
        updatePath()
        openDocumentsChanged()
    }

    /// A note of Zephyr's space, created from its template if needed; nil, with the reason shown,
    /// when it cannot be written.
    func ensured(_ url: URL) -> URL? {
        do {
            return try SpaceStore.shared.ensure(url)
        } catch {
            window?.presentError(error)
            return nil
        }
    }

    /// A note of Zephyr's space, created from its template if needed, opened in this window.
    func openSpaceNote(_ url: URL, select: NSRange? = nil) {
        guard let url = ensured(url) else { return }
        navigate(to: url, alongside: true, select: select)
    }

    /// A user explicitly chooses an existing Markdown file to view as blocks. This changes no
    /// file; any later editing remains a separate, visible document action.
    func showAsPage(_ url: URL) {
        guard FolderScanner.markdownExtensions.contains(url.pathExtension.lowercased()) else { return }
        open(panel: .markdown(url))
    }

    /// The note opens with the assistant beside it, the request typed but not sent: the reader
    /// can adjust it, and whatever the assistant changes is a proposal to review (design §21.6).
    func askAssistant(about note: URL, prompt: String) {
        guard let note = ensured(note) else { return }
        navigate(to: note, alongside: true) { [weak self] in
            guard let self else { return }
            if !self.canvas.isAIOpen { self.canvas.toggleAIPanel() }
            self.canvas.aiPanel?.prefill(prompt)
        }
    }

    /// What a new page can start from: the sidebar's Pages +, and New Page.
    func newPageMenu() -> NSMenu {
        let menu = NSMenu()
        for preset in PagePreset.allCases {
            let item = ClosureMenuItem(title: preset.title) { [weak self] in self?.createPage(preset) }
            item.image = NSImage(systemSymbolName: preset.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let ask = ClosureMenuItem(title: String(localized: "Make a Page with the Assistant…")) { [weak self] in self?.createPageWithAssistant() }
        ask.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(ask)
        return menu
    }

    @objc func newBlankPage(_ sender: Any?) { createPage(.blank) }

    /// A new page from a preset, shown with its title ready to rename.
    func createPage(_ preset: PagePreset) {
        let tracking = trackingNotes()
        let url: URL
        do {
            url = try SpaceStore.shared.createBoard(title: preset.pageTitle) { preset.text(title: $0, tracking: tracking) }
        } catch {
            return presentError(error)
        }
        PalettePanel.refresh(over: window)
        open(panel: .board(url))
        (canvas.shownPage as? BoardPanel)?.beginRenaming()
    }

    /// A blank page opened as its note with the assistant, asked to lay it out (design §21.6):
    /// the request names the conventions, the reader says what the page is for.
    private func createPageWithAssistant() {
        let url: URL
        do {
            url = try SpaceStore.shared.createBoard(title: PagePreset.blank.pageTitle) { PagePreset.blank.text(title: $0, tracking: []) }
        } catch {
            return presentError(error)
        }
        PalettePanel.refresh(over: window)
        askAssistant(about: url, prompt: String(localized: "Lay out this note as a Zephyr page. Each “## heading” is a block: tasks (- [ ] …), links to notes (- [Title](path)), figures (- Label: value) or any Markdown; a line <!-- zephyr: wide --> under a heading gives it the full width, and <!-- zephyr: today --> (or goals, activity, recent) brings in a live block. The page is for: "))
    }

    /// The folder's own progress notes, for a project page to follow.
    private func trackingNotes() -> [URL] {
        let names = ["readme.md", "progress.md", "docs/progress.md", "todo.md", "roadmap.md", "docs/roadmap.md", "plan.md", "docs/plan.md", "changelog.md"]
        let files = scopeFiles ?? []
        return Array(names.compactMap { name in files.first { $0.relativePath.lowercased() == name }?.url }.prefix(4))
    }

    private func presentError(_ error: Error) {
        window?.presentError(error)
    }

    /// A page renamed with its file, in any window (`SpaceStore.pageMoved`): history and the page
    /// shown follow it. A page moved to the Trash leaves history, and its tab shows Activity.
    @objc private func pageMoved(_ notification: Notification) {
        guard let old = notification.object as? URL else { return }
        guard let new = notification.userInfo?["to"] as? URL else {
            for tab in tabs {
                forget(.panel(.board(old)), in: tab)
                forget(.file(old), in: tab)
                if tab.panel == .board(old) {
                    if tab === current { show(panel: .activity) } else { tab.panel = .activity }
                }
            }
            openDocumentsChanged()
            return
        }
        for tab in tabs {
            tab.history = tab.history.map { page in
                switch page {
                case .panel(.board(old)): .panel(.board(new))
                case .file(old): .file(new)
                default: page
                }
            }
            guard tab.panel == .board(old) else { continue }
            tab.panel = .board(new)
            guard tab === current else { continue }
            if let board = canvas.shownPage as? BoardPanel, board.url == old {
                board.url = new
                board.reload()
            }
            canvas.sidebar.setPage(.panel(.board(new)))
            updatePath()
        }
        openDocumentsChanged()
    }

    /// History without a page that is gone; neighbours that become the same page are one step.
    private func forget(_ gone: Page, in tab: DocumentTab) {
        var kept: [Page] = []
        var index = 0
        for (i, page) in tab.history.enumerated() where page != gone {
            if kept.last != page { kept.append(page) }
            if i <= tab.historyIndex { index = kept.count - 1 }
        }
        tab.history = kept
        tab.historyIndex = kept.isEmpty ? -1 : index
    }

    /// The shown page's note changed (its title may have).
    func pageTitleChanged() {
        if panel != nil {
            updatePath()
            openDocumentsChanged()
        }
    }

    /// A page to the Trash (it can be put back from there); every window showing it moves to the
    /// Activity (`pageMoved`).
    func trashPage(_ url: URL) {
        Task { @MainActor [weak self] in
            do {
                try await SpaceStore.shared.trashBoard(url)
            } catch {
                self?.window?.presentError(error)
            }
        }
    }

    @objc func showActivity(_ sender: Any?) { open(panel: .activity) }

    func select(_ range: NSRange) {
        guard let editor else { return }
        editor.reveal(location: min(range.location, editor.length))
        editor.select(range, indicate: true)
    }

    private func inheritScope(from other: DocumentWindowController) {
        guard let root = other.scopeRoot else { return }
        scopeRoot = root
        scopeFiles = other.scopeFiles
        canvas.sidebar.setScope(root: root, files: scopeFiles, current: fileURL)
        updatePath()
    }

    @objc func goBack(_ sender: Any?) { step(-1) }
    @objc func goForward(_ sender: Any?) { step(1) }

    /// To the nearest page that way that still exists (a file deleted or moved elsewhere, an
    /// untitled document no longer here, is passed over); the place in history moves only with the
    /// page shown.
    private func step(_ delta: Int) {
        var i = current.historyIndex + delta
        while current.history.indices.contains(i) {
            let page = current.history[i]
            let exists: Bool = switch page {
            case let .file(url), let .panel(.board(url)): FileManager.default.fileExists(atPath: url.path)
            case let .untitled(doc): doc === markdownDocument
            case .panel: true
            }
            if exists {
                current.historyIndex = i
                return go(to: page)
            }
            i += delta
        }
    }

    private func go(to page: Page) {
        switch page {
        case let .file(url): navigate(to: url, recordHistory: false)
        case .untitled: hidePanel()
        case let .panel(panel): show(panel: panel, recordHistory: false)
        }
    }

    // MARK: - Links

    private func openLink(_ destination: String) {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            revealAnchor(String(trimmed.dropFirst()))
            return
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme != "file" {
            NSWorkspace.shared.open(url)
            return
        }
        var fragment: String?
        let target: URL
        if let url = URL(string: trimmed), url.isFileURL {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            fragment = components?.fragment
            components?.fragment = nil
            target = (components?.url ?? url).standardizedFileURL
        } else {
            var path = trimmed
            if let hash = path.firstIndex(of: "#") {
                fragment = String(path[path.index(after: hash)...])
                path = String(path[..<hash])
            }
            path = path.removingPercentEncoding ?? path
            if path.hasPrefix("/") { target = URL(fileURLWithPath: path) }
            else if let base = fileURL?.deletingLastPathComponent() { target = base.appendingPathComponent(path).standardizedFileURL }
            else { return }
        }
        if FolderScanner.markdownExtensions.contains(target.pathExtension.lowercased()) {
            navigate(to: target, alongside: NSApp.currentEvent?.modifierFlags.contains(.option) == true, anchor: fragment)
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    /// GitHub-style heading anchors: lowercase, punctuation dropped, spaces to hyphens.
    static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) } else if ch == " " { out.append("-") }
        }
        return out
    }

    private func revealAnchor(_ anchor: String) {
        guard let editor else { return }
        let wanted = (anchor.removingPercentEncoding ?? anchor).lowercased()
        if let heading = editor.headings().first(where: { Self.slug($0.title) == wanted }) {
            editor.reveal(location: heading.location)
        }
    }

    // MARK: - Path (the scope control)

    private func updatePath() {
        if let panel {
            canvas.topBar.setPage(panel)
            window?.title = panel.title
            return
        }
        guard let doc = markdownDocument else {
            canvas.topBar.setPage(nil)
            window?.title = MainMenu.appName
            return
        }
        var folders: [(name: String, url: URL)] = []
        if let url = doc.fileURL {
            let stop = scopeRoot ?? ScopeResolver.root(for: url, registeredRoots: Preferences.registeredRootURLs)
            var dir = url.deletingLastPathComponent()
            while folders.count < 6 {
                folders.insert((FileManager.default.displayName(atPath: dir.path), dir), at: 0)
                if dir.path == stop.path || dir.path == "/" { break }
                dir = dir.deletingLastPathComponent()
            }
        }
        canvas.topBar.setPath(folders: folders, scopeRoot: scopeRoot, file: doc.displayName)
        window?.title = doc.displayName
    }

    /// From a folder's menu in the path: that folder becomes the explicit scope root, its files in
    /// the sidebar. (A click on the folder itself only opens the menu; the sidebar has its button.)
    func showFolderInSidebar(_ folder: URL) {
        expandScope(to: folder, explicit: true)
        canvas.sidebar.show(.files)
        canvas.setSidebar(visible: true)
    }

    /// Something chosen in the sidebar opened; a sidebar over the text makes way for it.
    func sidebarDidOpenItem() { canvas.sidebarDidOpenItem() }

    // MARK: - Scope

    func expandScope(to root: URL?, explicit: Bool) {
        guard let file = fileURL ?? root else { return chooseScopeFolder(nil) }
        let target = root ?? ScopeResolver.root(for: file, registeredRoots: Preferences.registeredRootURLs)
        if explicit { Preferences.register(root: target) } else { Preferences.noteRecent(root: target) }
        guard target != scopeRoot || scopeFiles == nil else { return }
        scopeRoot = target
        scopeFiles = nil
        scanTask?.cancel()
        if case let .some(.folderHome(previous)) = panel {
            if current.history.indices.contains(current.historyIndex), current.history[current.historyIndex] == .panel(.folderHome(previous)) {
                current.history[current.historyIndex] = .panel(.folderHome(target))
            }
            show(panel: .folderHome(target), recordHistory: false)
        }
        for doc in tabs.compactMap(\.document) { AgentAccess.shared.scopeChanged(for: doc, to: target) }
        canvas.sidebar.setScope(root: target, files: [], current: fileURL)
        canvas.sidebar.setScanning(true)
        let activitySequence = SpaceStore.shared.beginActivityScopeScan()
        let scanned: @MainActor ([ScopeFile], [String: Activity.FileState]) -> Void = { [weak self] files, metadata in
            guard !Task.isCancelled, let self, self.scopeRoot == target else { return }
            self.scopeFiles = files
            self.canvas.sidebar.setScope(root: target, files: files, current: self.fileURL)
            self.canvas.sidebar.setScanning(false)
            do { _ = try SpaceStore.shared.observeActivityScope(target, metadata: metadata, sequence: activitySequence) } catch { self.window?.presentError(error) }
            if case let .some(.folderHome(root)) = self.panel, root.standardizedFileURL == target.standardizedFileURL {
                (self.canvas.shownPage as? FolderHomePanel)?.reload()
            }
            PalettePanel.refresh(over: self.window)
        }
        scanTask = Task.detached(priority: .userInitiated) {
            let files = FolderScanner.markdownFiles(in: target, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            let metadata = FolderScanner.activityMetadata(for: files)
            guard !Task.isCancelled else { return }
            await scanned(files, metadata)
        }
        updatePath()
    }

    /// Narrowing the scope cancels folder work and releases its results (design §7.5).
    @objc func closeScope(_ sender: Any?) {
        scanTask?.cancel()
        searchTask?.cancel()
        searchGeneration += 1
        scopeRoot = nil
        scopeFiles = nil
        for doc in tabs.compactMap(\.document) { AgentAccess.shared.scopeChanged(for: doc, to: nil) }
        canvas.sidebar.setScope(root: nil, files: [], current: nil)
        canvas.sidebar.clearResults()
        canvas.sidebar.show(.files)
        if case .some(.folderHome) = panel { show(panel: .activity) }
        PalettePanel.refresh(over: window)
        updatePath()
    }

    @objc func chooseScopeFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = scopeRoot ?? fileURL?.deletingLastPathComponent()
        panel.prompt = String(localized: "Use Folder")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.expandScope(to: url, explicit: true)
            self?.canvas.setSidebar(visible: true)
        }
    }

    /// A recent folder chosen again: it becomes this window's folder and its Folder Home shows.
    func openFolder(_ url: URL) {
        expandScope(to: url, explicit: true)
        open(panel: .folderHome(url))
    }

    @objc func useEnclosingFolder(_ sender: Any?) {
        guard let parent = fileURL?.deletingLastPathComponent() else { return }
        expandScope(to: parent, explicit: true)
    }

    func runScopeSearch(_ query: String) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        canvas.sidebar.clearResults()
        guard !query.isEmpty else { return }
        if scopeRoot == nil { expandScope(to: nil, explicit: false) }
        guard let root = scopeRoot else { return }
        let known = scopeFiles
        let finished: @MainActor (Bool) -> Void = { [weak self] empty in
            guard let self, self.searchGeneration == generation else { return }
            self.canvas.sidebar.searchFinished(empty: empty)
        }
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let files = known ?? FolderScanner.markdownFiles(in: root, isCancelled: { Task.isCancelled })
            var found = false
            FolderScanner.search(query, in: files, isCancelled: { Task.isCancelled }) { batch in
                found = true
                DispatchQueue.main.async {
                    guard let self, self.searchGeneration == generation else { return }
                    self.canvas.sidebar.appendResults(batch)
                }
            }
            await finished(!found)
        }
    }

    func open(match: FolderScanner.Match, length: Int) {
        navigate(to: match.file.url, alongside: true, select: NSRange(location: match.location, length: length))
    }

    func revealHeading(_ heading: MarkdownEditor.Heading) {
        editor?.reveal(location: heading.location)
    }

    func scheduleOutlineRefresh(immediately: Bool = false) {
        outlineRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let editor = self.editor else { return self.canvas.setOutline([]) }
            self.canvas.setOutline(editor.headings())
            self.canvas.setCaretLocation(editor.selectedRange.location)
            self.trackReadingHeading(scrolling: false)
        }
        outlineRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.3), execute: work)
    }

    private func trackReadingHeading(scrolling: Bool) {
        guard let editor else { return }
        canvas.setReadingLocation(editor.readingCharacter(), scrolling: scrolling)
    }

    // MARK: - Renaming

    /// The top bar's name field: renames the file beside itself, or names an untitled document by
    /// saving it into the folder in view (where the reader chooses when there is none).
    func renameDocument(to raw: String) {
        guard let doc = markdownDocument, let window else { return }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else { return NSSound.beep() }
        let fileName = (name as NSString).pathExtension.isEmpty ? name + ".md" : name
        func refuse(_ target: URL) {
            let alert = NSAlert()
            alert.messageText = String(localized: "A file named \(target.lastPathComponent) already exists.")
            alert.informativeText = String(localized: "Choose another name.")
            alert.beginSheetModal(for: window)
        }
        let done: (Error?) -> Void = { [weak self] error in
            if let error { self?.window?.presentError(error) }
            self?.updatePath()
            self?.openDocumentsChanged()
            self?.rescanScope()
        }
        if let url = doc.fileURL {
            let target = url.deletingLastPathComponent().appendingPathComponent(fileName)
            guard target.lastPathComponent != url.lastPathComponent else { return }
            // A change of case alone names the same file on the usual case-insensitive volume.
            if FileManager.default.fileExists(atPath: target.path), target.path.lowercased() != url.path.lowercased() { return refuse(target) }
            doc.move(to: target, completionHandler: done)
        } else if let root = scopeRoot {
            let target = root.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: target.path) { return refuse(target) }
            doc.save(to: target, ofType: doc.fileType ?? "net.daringfireball.markdown", for: .saveAsOperation, completionHandler: done)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = fileName
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let target = panel.url else { return }
                doc.save(to: target, ofType: doc.fileType ?? "net.daringfireball.markdown", for: .saveAsOperation, completionHandler: done)
            }
        }
    }

    // MARK: - Statistics (design §8)

    /// Counted off the main thread once edits pause: soon for short texts, after a longer pause
    /// for long ones (a megabyte takes about 70 ms). A selection is counted on its own.
    private func scheduleStatistics(textChanged: Bool, immediately: Bool = false) {
        guard let editor else { return }
        if textChanged { statisticsStale = true }
        if !statisticsStale, editor.selectedRange.length == 0 {
            if statistics.selection == nil { return }
            statisticsWork?.cancel()
            statisticsGeneration += 1
            statistics.selection = nil
            return showStatistics()
        }
        statisticsWork?.cancel()
        statisticsGeneration += 1
        let generation = statisticsGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, let editor = self.editor else { return }
            let text = editor.string as NSString
            let selection = editor.selectedRange
            let recount = self.statisticsStale
            let previous = self.statistics.document
            Self.statisticsQueue.async { [weak self] in
                let document = recount ? TextStatistics.count(text) : previous
                let selected = selection.length > 0 ? TextStatistics.count(text, in: selection) : nil
                DispatchQueue.main.async {
                    guard let self, self.statisticsGeneration == generation else { return }
                    if recount { self.statisticsStale = false }
                    self.statistics = (document, selected)
                    self.showStatistics()
                }
            }
        }
        statisticsWork = work
        let delay = immediately ? 0 : !statisticsStale ? 0.12 : editor.length < 200_000 ? 0.3 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func showStatistics() {
        let (document, selection) = statistics
        canvas.topBar.setStatistics(StatisticsMetric.chip(document: document, selection: selection),
                                    help: String(localized: "Text statistics (excludes code, formulas and diagrams)"))
        statisticsCard?.show(document: document, selection: selection)
    }

    /// The card under the count, with every figure and the choice of what the bar shows.
    @objc func showStatistics(_ sender: Any?) {
        // A second click on the count closes the card.
        guard !FloatingCard.closed(byClickOn: canvas.topBar.stats) else { return }
        let card = StatisticsCard()
        card.onChoose = { [weak self] in self?.showStatistics() }
        card.show(document: statistics.document, selection: statistics.selection)
        statisticsCard = card
        let chip = canvas.topBar.stats
        FloatingCard(content: card).show(below: chip.bounds, in: chip, alignment: .trailing)
    }

    /// A heading renamed in the outline: only its text changes, markers and closing #s stay, as
    /// one undoable edit.
    func renameHeading(_ heading: MarkdownEditor.Heading, to title: String) {
        guard let editor else { return }
        let ns = editor.string as NSString
        guard heading.location < ns.length else { return }
        let line = ns.lineRange(for: NSRange(location: heading.location, length: 0))
        let text = ns.substring(with: line).trimmingCharacters(in: .newlines)
        // ATX: container prefix and #s, the text, optional closing #s; setext: the whole line.
        let atx = try! NSRegularExpression(pattern: #"^((?:\s*>)*\s*#{1,6}[ \t]+)(.*?)([ \t]+#+)?[ \t]*$"#)
        let setext = try! NSRegularExpression(pattern: #"^((?:\s*>)*\s*)(.*?)[ \t]*$"#)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        guard let match = atx.firstMatch(in: text, range: whole) ?? setext.firstMatch(in: text, range: whole) else { return }
        let range = match.range(at: 2)
        editor.apply([TextPatch(range: NSRange(location: line.location + range.location, length: range.length), replacement: title)], actionName: String(localized: "Rename Heading"))
        scheduleOutlineRefresh(immediately: true)
    }

    /// The folder listing again, after a file in it was renamed or created.
    private func rescanScope() {
        guard let root = scopeRoot else { return }
        scopeFiles = nil
        expandScope(to: root, explicit: false)
    }

    /// Activity refreshes only when the reader asks. The completed scan is compared with the
    /// in-memory baseline in `ActivityStore`; there is no watcher or periodic work.
    func refreshActivityScope() {
        rescanScope()
    }

    // MARK: - Commands

    @objc func toggleScopeSidebar(_ sender: Any?) {
        if canvas.isSidebarVisible {
            canvas.setSidebar(visible: false)
            window?.makeFirstResponder(editor?.focusView)
            return
        }
        if scopeRoot == nil, fileURL != nil { expandScope(to: nil, explicit: false) }
        canvas.setSidebar(visible: true)
    }

    @objc func showFilesTab(_ sender: Any?) {
        if scopeRoot == nil { expandScope(to: nil, explicit: false) }
        canvas.sidebar.show(.files)
        canvas.setSidebar(visible: true)
    }

    @objc func renameFromMenu(_ sender: Any?) { canvas.topBar.beginRename() }

    /// Opens the outline card, held until Esc or a choice; again closes it.
    @objc func showOutlineTab(_ sender: Any?) {
        trackReadingHeading(scrolling: false)
        canvas.toggleOutlineCard()
    }

    @objc func showScopeSearch(_ sender: Any?) {
        if scopeRoot == nil { expandScope(to: nil, explicit: false) }
        canvas.setSidebar(visible: true)
        var selected: String?
        if let editor, (1...200).contains(editor.selectedRange.length) {
            selected = (editor.string as NSString).substring(with: editor.selectedRange)
        }
        canvas.sidebar.focusSearch(with: selected)
    }

    @objc func openQuickly(_ sender: Any?) {
        guard let window else { return }
        if scopeRoot == nil, fileURL != nil { expandScope(to: nil, explicit: false) }
        // One switcher for the whole app: its pages, documents opened lately anywhere, then the
        // files of the folder in view. What it opens gets its own place in the window.
        PalettePanel.show(over: window, placeholder: String(localized: "Open Quickly")) { [weak self] query in
            guard let self else { return [] }
            let matches: (String) -> Bool = { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            let pages = SpacePanel.all(scopeRoot: self.scopeRoot).filter { matches($0.title) }.map { panel in
                PalettePanel.Entry(title: panel.title, detail: String(localized: "Page"), image: NSImage(systemSymbolName: panel.symbol, accessibilityDescription: nil)) { [weak self] in
                    self?.open(panel: panel)
                }
            }
            let files = self.scopeFiles.map { PalettePanel.rankFiles($0, query: query).prefix(60) } ?? []
            let inScope = Set(files.map { $0.url.standardizedFileURL })
            let recent = RecentPages.urls.filter { !inScope.contains($0.standardizedFileURL) && matches($0.lastPathComponent) }.map { url in
                PalettePanel.Entry(title: url.lastPathComponent, detail: url.deletingLastPathComponent().path, image: NSImage(systemSymbolName: "clock", accessibilityDescription: nil)) { [weak self] in
                    self?.navigate(to: url, alongside: true)
                }
            }
            return pages + recent + files.map { file in
                PalettePanel.Entry(title: file.name, detail: (file.relativePath as NSString).deletingLastPathComponent, image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)) { [weak self] in
                    self?.navigate(to: file.url, alongside: true)
                }
            }
        }
    }

    @objc func showCommandPalette(_ sender: Any?) {
        guard let window else { return }
        PalettePanel.show(over: window, placeholder: String(localized: "Search Commands")) { query in
            PalettePanel.commands(matching: query, in: window)
        }
    }

    @objc func toggleMinimalMode(_ sender: Any?) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Preferences.minimalMode), forKey: Preferences.minimalMode)
        Self.applyMinimalMode()
    }

    static var all: [DocumentWindowController] {
        NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
    }

    /// Window-wide preferences, applied to every open window (menus and Settings share these).
    static func applyMinimalMode() {
        let minimal = UserDefaults.standard.bool(forKey: Preferences.minimalMode)
        for controller in all {
            controller.canvas.setMinimal(minimal)
            controller.canvas.updateAIButton()
        }
    }

    /// The outline's place and levels changed in Settings.
    static func applyOutline() {
        for controller in all { controller.scheduleOutlineRefresh(immediately: true) }
    }

    static func applyAIButton() {
        for controller in all { controller.canvas.updateAIButton() }
    }

    /// The quick switcher was turned on or off in Settings.
    static func applyQuickSwitcher() {
        for controller in all { controller.openDocumentsChanged() }
    }

    /// Plain-text writing (⌘/) belongs to the window: a document opened in it later is written the
    /// same way, until the command is chosen again.
    private var writesPlainText = false
    @objc func togglePlainText(_ sender: Any?) {
        guard let editor else { return }
        writesPlainText = !editor.showsPlainText
        editor.setPlainText(writesPlainText)
        window?.makeFirstResponder(editor.focusView)
    }

    @objc func toggleAIPanel(_ sender: Any?) { canvas.toggleAIPanel() }
    var aiPanelForSnapshot: AIPanelController? { canvas.aiPanel }
    var canvasForSnapshot: CanvasViewController { canvas }

    @objc func toggleAIButton(_ sender: Any?) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Preferences.aiButtonHidden), forKey: Preferences.aiButtonHidden)
        Self.applyAIButton()
    }

    /// Grant or revoke agent access for this document (design §11: the GUI grants credentials).
    @objc func toggleAgentAccess(_ sender: Any?) {
        guard let doc = markdownDocument else { return }
        AgentAccess.shared.toggle(doc)
    }

    @objc private func agentAccessChanged(_ note: Notification? = nil) {
        let grant = AgentAccess.shared.grant(for: markdownDocument)
        canvas.topBar.setAgentAccess(grant != nil, root: grant?.root)
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func themeChanged() {
        for editor in tabs.compactMap(\.editor) { editor.apply(typography: AppearanceStore.shared.typography) }
    }

    @objc private func frontMatterChanged() {
        for editor in tabs.compactMap(\.editor) { editor.frontMatterCollapsed = UserDefaults.standard.bool(forKey: Preferences.frontMatterCollapsed) }
    }

    @objc private func remoteImagesChanged() {
        for editor in tabs.compactMap(\.editor) { editor.remoteImagesPreferred = UserDefaults.standard.bool(forKey: Preferences.remoteImages) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleScopeSidebar(_:)):
            menuItem.title = canvas.isSidebarVisible ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        case #selector(toggleMinimalMode(_:)):
            menuItem.state = UserDefaults.standard.bool(forKey: Preferences.minimalMode) ? .on : .off
        case #selector(togglePlainText(_:)):
            menuItem.state = editor?.showsPlainText == true ? .on : .off
            return editor != nil && panel == nil
        case #selector(goBack(_:)):
            return current.historyIndex > 0
        case #selector(goForward(_:)):
            return current.historyIndex + 1 < current.history.count
        case #selector(showNextDocument(_:)), #selector(showPreviousDocument(_:)), #selector(moveToNewWindow(_:)):
            return openTabs.count > 1
        case #selector(mergeAllWindows(_:)):
            return Self.all.count > 1
        case #selector(showInFinder(_:)), #selector(useEnclosingFolder(_:)):
            return fileURL != nil
        case #selector(closeScope(_:)):
            return scopeRoot != nil
        case #selector(renameFromMenu(_:)):
            return !canvas.topBar.isHidden && markdownDocument?.isReadOnly == false && panel == nil
        case #selector(toggleAIButton(_:)):
            menuItem.state = UserDefaults.standard.bool(forKey: Preferences.aiButtonHidden) ? .off : .on
        case #selector(toggleAIPanel(_:)):
            menuItem.title = canvas.isAIOpen ? String(localized: "Collapse AI") : String(localized: "Ask AI")
            return editor != nil
        case #selector(toggleAgentAccess(_:)):
            menuItem.state = AgentAccess.shared.grant(for: markdownDocument) != nil ? .on : .off
            return fileURL != nil && markdownDocument?.isReadOnly == false
        default:
            break
        }
        return true
    }

    // MARK: - Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        markdownDocument?.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        scanTask?.cancel()
        searchTask?.cancel()
        if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) }
        for tab in tabs { tab.discard() }
        keepAlive = nil
    }

    // MARK: - Restoration

    private static let openKey = "zephyrOpenDocuments", shownKey = "zephyrShownDocument"

    /// The window's other documents, by path (an untitled one by its autosaved copy), so they come
    /// back beside the one the system restores (`DocumentWindow` hands over its coder).
    func encodeOpenDocuments(with coder: NSCoder) {
        let entries = tabs.map { tab -> String in
            guard let doc = tab.document else { return "" }
            if let url = doc.fileURL { return url.path }
            return doc.autosavedContentsFileURL.map { "untitled:" + $0.path } ?? ""
        }
        coder.encode(entries as NSArray, forKey: Self.openKey)
        coder.encode(tabs.firstIndex { $0 === current } ?? 0, forKey: Self.shownKey)
    }

    func restoreOpenDocuments(with coder: NSCoder) {
        guard let entries = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: Self.openKey) as? [String] else { return }
        let shown = coder.decodeInteger(forKey: Self.shownKey)
        reopen(Array(entries.enumerated()).filter { $0.offset != shown && !$0.element.isEmpty }, shown: shown)
    }

    /// One at a time, so they keep their order around the restored document.
    private func reopen(_ entries: [(offset: Int, element: String)], shown: Int) {
        guard let (offset, entry) = entries.first else { return }
        let rest = Array(entries.dropFirst())
        let done: (NSDocument?, Bool, Error?) -> Void = { [weak self] document, alreadyOpen, _ in
            guard let self else { return }
            if let doc = document as? MarkdownDocument, !alreadyOpen, Self.hosting(doc) == nil {
                let tab = DocumentTab(document: nil)
                self.prepare(doc, in: tab)
                tab.history = [self.page(of: doc)]
                tab.historyIndex = 0
                let before = self.tabs.firstIndex { $0 === self.current } ?? 0
                self.tabs.insert(tab, at: offset < shown ? min(before, self.tabs.count) : self.tabs.count)
                self.openDocumentsChanged()
            }
            self.reopen(rest, shown: shown)
        }
        if entry.hasPrefix("untitled:") {
            let url = URL(fileURLWithPath: String(entry.dropFirst("untitled:".count)))
            NSDocumentController.shared.reopenDocument(for: nil, withContentsOf: url, display: false, completionHandler: done)
        } else {
            NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: entry), display: false, completionHandler: done)
        }
    }
}
