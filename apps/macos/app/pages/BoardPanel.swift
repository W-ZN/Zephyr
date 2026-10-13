import AppKit
import UniformTypeIdentifiers
import ZephyrCore
import ZephyrRender

/// What a new page starts from: a blank note, a folder knowledge home that follows its documents,
/// or a dashboard with activity, recent files, links and tasks.
enum PagePreset: CaseIterable {
    case blank, project, dashboard

    var title: String {
        switch self {
        case .blank: String(localized: "Blank Page")
        case .project: String(localized: "Folder Knowledge Home")
        case .dashboard: String(localized: "Dashboard")
        }
    }

    var symbol: String {
        switch self {
        case .blank: "doc"
        case .project: "hammer"
        case .dashboard: "square.grid.2x2"
        }
    }

    /// The first name a page of this kind gets; it is renamed by its title.
    var pageTitle: String { self == .blank ? String(localized: "Untitled") : title }

    /// The note: plain Markdown with a hint comment where a section is still empty. A project
    /// follows `tracking`, the folder's own progress notes (README, progress, TODO…).
    func text(title: String, tracking: [URL]) -> String {
        let t = { (s: String.LocalizationValue) in String(localized: s) }
        switch self {
        case .blank:
            return "# \(title)\n\n"
        case .project:
            let links = tracking.isEmpty ? "<!-- zephyr: links -->\n"
                : tracking.map { "- [\($0.deletingPathExtension().lastPathComponent)](\($0.path.contains(" ") ? "<\($0.path)>" : $0.path))" }.joined(separator: "\n") + "\n"
            return "---\nicon: hammer\n---\n# \(title)\n\n\(t("What this project is for, in a line or two."))\n\n## \(t("Next"))\n<!-- zephyr: tasks -->\n\n## \(t("Tracking"))\n\(links)\n## \(t("Notes"))\n\n\(t("Decisions, links and anything else, in Markdown."))\n"
        case .dashboard:
            return "---\nicon: square.grid.2x2\n---\n# \(title)\n\n## \(t("Activity"))\n<!-- zephyr: activity -->\n\n## \(t("Recent"))\n<!-- zephyr: recent -->\n\n## \(t("Links"))\n<!-- zephyr: links -->\n\n## \(t("Tasks"))\n<!-- zephyr: tasks -->\n"
        }
    }
}

/// A page the reader makes (design §8.3): a note in `Space/Pages` laid out as blocks (`Board`).
/// The title edits in place. Blocks pair up side by side, or take the full width, and stack on a
/// narrow window; a rule above each, no boxes. Tasks check and add, links show how far the notes
/// they point to have come, figures show as numbers and meters, text shows as the canvas draws
/// it, and live blocks bring in today, the goals, the days' activity and recent documents. Each
/// block's menu moves, widens or removes it: all edits of the note, so the assistant and other
/// apps see the same page as plain Markdown.
final class BoardPanel: PanelPage, NSTextFieldDelegate {
    /// The note; it follows a rename of the page.
    var url: URL
    private let isSpaceBoard: Bool
    private var page = Board.page(in: "")
    /// Rows of two blocks; on a narrow page they stack, each block then the row's width.
    private var pairs: [(row: NSStackView, stacked: [NSLayoutConstraint])] = []
    private var titleCancelled = false

    init(_ controller: DocumentWindowController, url: URL, isSpaceBoard: Bool = true) {
        self.url = url
        self.isSpaceBoard = isSpaceBoard
        super.init(controller, title: SpacePanel.board(url).title, width: 920)
        heading.isEditable = isSpaceBoard
        heading.isSelectable = isSpaceBoard
        heading.focusRingType = .none
        heading.delegate = self
        heading.toolTip = isSpaceBoard ? String(localized: "Click to rename") : nil
        heading.setAccessibilityLabel(String(localized: "Page title"))
        // An editable field does not size to its text: the width follows it here, yielding to the
        // actions when the window is narrow.
        titleWidth = heading.widthAnchor.constraint(equalToConstant: 80)
        titleWidth.priority = NSLayoutConstraint.Priority(490)
        titleWidth.isActive = true
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private var titleWidth: NSLayoutConstraint!

    private func fitTitle() {
        let text = (heading.currentEditor()?.string ?? heading.stringValue) as NSString
        titleWidth.constant = ceil(text.size(withAttributes: [.font: heading.font!]).width) + 8
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === heading { fitTitle() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var store: SpaceStore { SpaceStore.shared }
    private var text: String { store.text(of: url) }

    private func apply(_ patch: TextPatch, _ action: String) {
        store.apply(patch, to: url, actionName: action)
    }

    // MARK: Title

    func beginRenaming() {
        window?.makeFirstResponder(heading)
        heading.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === heading else { return false }
        if selector == #selector(insertNewline(_:)) || selector == #selector(cancelOperation(_:)) {
            titleCancelled = selector == #selector(cancelOperation(_:))
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === heading else { return }
        guard isSpaceBoard else { return }
        let title = heading.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = page.title ?? url.deletingPathExtension().lastPathComponent
        defer { titleCancelled = false }
        guard !titleCancelled, !title.isEmpty, title != current else { return heading.stringValue = current }
        // The page follows its file before the note changes and everything reloads; windows
        // showing it follow through `SpaceStore.pageMoved`.
        url = store.moveBoard(url, toTitle: title)
        apply(Board.retitling(title, in: text), String(localized: "Rename Page"))
    }

    // MARK: Reload

    override func reload() {
        let text = self.text
        page = Board.page(in: text as NSString)
        if heading.currentEditor() == nil {
            heading.stringValue = page.title ?? url.deletingPathExtension().lastPathComponent
            fitTitle()
        }
        // The top bar and the window show the page's title too.
        controller?.pageTitleChanged()
        let items = page.blocks.flatMap { block -> [Space.Item] in if case let .tasks(items) = block.content { return items }; return [] }
        var parts = [String(localized: "\(page.blocks.count) blocks")]
        if !items.isEmpty {
            let done = items.filter { $0.done }.count
            parts.append(String(localized: "\(done) of \(items.count) done"))
        }
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            parts.append(String(localized: "edited \(date.formatted(.relative(presentation: .named)))"))
        }
        subtitle.stringValue = parts.joined(separator: " · ")
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let add = FlatButton(title: String(localized: "Add Block"), symbol: "plus", style: .text)
        add.target = self
        add.action = #selector(showAddMenu(_:))
        let note = noteButton(url)
        let ask = assistantButton(String(localized: "Ask Assistant"), note: url, prompt: String(localized: "Update this page: "))
        for view in [add, note, ask] { actions.addArrangedSubview(view) }
        // Narrow: “Open as Markdown” goes first, then “Add Block”; the assistant stays.
        actions.setVisibilityPriority(NSStackView.VisibilityPriority(300), for: note)
        actions.setVisibilityPriority(NSStackView.VisibilityPriority(400), for: add)
        actions.setVisibilityPriority(.mustHold, for: ask)

        var sections: [NSView] = []
        if !page.intro.isEmpty {
            let intro = MarkdownSnippet(text: page.intro, typography: Self.typography, baseURL: url.deletingLastPathComponent())
            sections.append(padded(intro, bottom: 28))
        }
        if page.blocks.isEmpty {
            sections.append(Self.empty(String(localized: "An empty page. Add a block, or write “## sections” in the note.")))
        }
        pairs = []
        var i = 0
        let blocks = page.blocks
        while i < blocks.count {
            if !blocks[i].wide, i + 1 < blocks.count, !blocks[i + 1].wide {
                sections.append(pair(blockView(blocks[i]), blockView(blocks[i + 1])))
                i += 2
            } else {
                sections.append(padded(blockView(blocks[i]), bottom: 32))
                i += 1
            }
        }
        setSections(sections)
        needsLayout = true
    }

    /// The body text's look, a little smaller than a document's.
    private static var typography: Typography {
        var settings = AppearanceStore.shared.typography.settings
        _ = try? settings.set("text.size", "14")
        _ = try? settings.set("zoom", "1")
        return Typography(settings, css: AppearanceStore.shared.typography.css)
    }

    private func padded(_ view: NSView, bottom: CGFloat) -> NSView {
        let box = NSStackView(views: [view])
        box.orientation = .vertical
        box.alignment = .leading
        box.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
        view.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        return box
    }

    private func pair(_ a: NSView, _ b: NSView) -> NSView {
        let row = NSStackView(views: [a, b])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 36
        let stacked = [a.widthAnchor.constraint(equalTo: row.widthAnchor), b.widthAnchor.constraint(equalTo: row.widthAnchor)]
        pairs.append((row, stacked))
        return padded(row, bottom: 32)
    }

    /// Two columns while each keeps 300 points; one below that. The column is 920 wide with 32
    /// points either side at least (`PanelPage`), so the page's own width decides.
    override func layout() {
        super.layout()
        let narrow = bounds.width - 64 < 640
        for pair in pairs where (pair.row.orientation == .vertical) != narrow {
            NSLayoutConstraint.deactivate(pair.stacked)
            pair.row.orientation = narrow ? .vertical : .horizontal
            pair.row.distribution = narrow ? .fill : .fillEqually
            pair.row.alignment = narrow ? .leading : .top
            pair.row.spacing = narrow ? 32 : 36
            if narrow { NSLayoutConstraint.activate(pair.stacked) }
        }
    }

    // MARK: Blocks

    private func blockView(_ block: Board.Block) -> NSView {
        let content: [NSView]
        switch block.content {
        case let .tasks(items): content = tasks(items, in: block)
        case let .links(links): content = self.links(links, in: block)
        case let .numbers(numbers): content = self.numbers(numbers)
        case .text: content = textContent(block)
        case let .live(live): content = self.live(live)
        }
        return BlockView(title: block.title, content: content) { [weak self] in self?.menu(for: block) ?? NSMenu() }
    }

    private func tasks(_ items: [Space.Item], in block: Board.Block) -> [NSView] {
        let url = self.url
        var views: [NSView] = items.map { item in
            TaskRow(item: item, timed: item.start != nil, onToggle: {
                SpaceStore.shared.toggle(item, in: url)
            }, onOpen: { [weak self] in self?.controller?.openSpaceNote(url, select: item.line) })
        }
        let id = "block.add." + String(page.blocks.firstIndex(of: block) ?? 0)
        let entry = EntryField(placeholder: String(localized: "Add a task"), quiet: true, id: id)
        entry.onSubmit = { [weak self] text in
            guard let self, let current = self.located(block) else { return }
            self.refocus = id
            self.apply(Space.addition(text, to: self.text, within: current.range), String(localized: "Add Task"))
        }
        views.append(entry)
        return views
    }

    private func links(_ links: [Board.Link], in block: Board.Block) -> [NSView] {
        var views: [NSView] = links.map { link in
            let target = Self.resolve(link.destination, from: url)
            return LinkRow(title: link.title, target: target) { [weak self] newTab in
                guard let target else { return }
                if target.isFileURL, FolderScanner.markdownExtensions.contains(target.pathExtension.lowercased()) {
                    var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
                    let anchor = components?.fragment
                    components?.fragment = nil
                    self?.controller?.navigate(to: components?.url ?? target, alongside: true, anchor: anchor)
                } else { NSWorkspace.shared.open(target) }
            }
        }
        if links.isEmpty { views.append(Self.empty(String(localized: "Link notes to follow their progress."))) }
        let add = FlatButton(title: String(localized: "Add Link…"), symbol: "plus", style: .text) { [weak self] in self?.chooseLinks(for: block) }
        // The plus lines up with the links' titles, past the button's own padding.
        let holder = NSView()
        add.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(add)
        NSLayoutConstraint.activate([
            add.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: -10), add.topAnchor.constraint(equalTo: holder.topAnchor, constant: 2),
            add.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        views.append(holder)
        return views
    }

    private func numbers(_ numbers: [Board.Metric]) -> [NSView] {
        guard !numbers.isEmpty else { return [Self.empty(String(localized: "Write lines like “- Done: 3/10” in the note."))] }
        var rows: [NSView] = []
        for start in stride(from: 0, to: numbers.count, by: 3) {
            let tiles = numbers[start..<min(start + 3, numbers.count)].map { NumberTile($0) as NSView }
            let row = NSStackView(views: tiles + Array(repeating: NSView(), count: 3 - tiles.count))
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = 16
            rows.append(row)
        }
        return rows
    }

    private func textContent(_ block: Board.Block) -> [NSView] {
        let body = (text as NSString).substring(with: block.body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return [Self.empty(String(localized: "Write anything here in the note, in Markdown."))] }
        let snippet = MarkdownSnippet(text: body, typography: Self.typography, baseURL: url.deletingLastPathComponent())
        snippet.toolTip = String(localized: "Double-click to edit in the note")
        let edit = NSClickGestureRecognizer(target: self, action: #selector(editText(_:)))
        edit.numberOfClicksRequired = 2
        snippet.addGestureRecognizer(edit)
        snippet.identifier = NSUserInterfaceItemIdentifier("text." + String(block.heading.location))
        return [snippet]
    }

    @objc private func editText(_ gesture: NSGestureRecognizer) {
        guard let id = gesture.view?.identifier?.rawValue, let location = Int(id.dropFirst(5)) else { return }
        controller?.openSpaceNote(url, select: NSRange(location: location, length: 0))
    }

    private func live(_ live: Board.Live) -> [NSView] {
        switch live {
        case .today:
            let note = store.daily()
            let items = Space.items(in: store.text(of: note) as NSString).sorted { ($0.start ?? Int.max) < ($1.start ?? Int.max) }
            var views: [NSView] = items.map { item in
                TaskRow(item: item, timed: item.start != nil, onToggle: {
                    SpaceStore.shared.toggle(item, in: note)
                }, onOpen: { [weak self] in self?.controller?.openSpaceNote(note) })
            }
            let entry = EntryField(placeholder: String(localized: "Add to today"), quiet: true, id: "live.today")
            entry.onSubmit = { [weak self] text in
                self?.refocus = "live.today"
                SpaceStore.shared.apply(Space.addition(text, to: SpaceStore.shared.text(of: note)), to: note, actionName: String(localized: "Add Task"))
            }
            views.append(entry)
            return views
        case .goals:
            let goals = Space.goals(in: store.text(of: store.goals) as NSString)
            guard !goals.isEmpty else { return [Self.empty(String(localized: "No goals yet."))] }
            return goals.prefix(6).map { goal in
                let row = MeterRow(title: goal.title, value: goal.progress, detail: "\(goal.done)/\(goal.total)")
                let click = NSClickGestureRecognizer(target: self, action: #selector(openGoals))
                row.addGestureRecognizer(click)
                return row
            }
        case .activity:
            return [ActivityHeatmap(store.activityHistory(days: 365))]
        case .recent:
            let urls = RecentPages.urls.prefix(5)
            guard !urls.isEmpty else { return [Self.empty(String(localized: "Documents you open appear here."))] }
            return urls.map { url in
                LinkRow(title: url.deletingPathExtension().lastPathComponent, target: url) { [weak self] newTab in self?.controller?.navigate(to: url, alongside: true) }
            }
        }
    }

    @objc private func openGoals() { controller?.openSpaceNote(store.goals) }

    // MARK: Menus

    @objc private func showAddMenu(_ sender: NSView) {
        let menu = NSMenu()
        let kinds: [(Board.Kind, String.LocalizationValue, String)] = [
            (.tasks, "Tasks", "checklist"), (.links, "Links", "link"), (.numbers, "Numbers", "number"), (.text, "Notes", "text.alignleft"),
        ]
        for (kind, title, symbol) in kinds {
            let item = ClosureMenuItem(title: String(localized: title)) { [weak self] in self?.addBlock(String(localized: title), words: [kind.rawValue]) }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let lives: [(Board.Live, String.LocalizationValue, String)] = [
            (.today, "Today", "sun.max"), (.goals, "Goals", "target"), (.activity, "Activity", "chart.bar.xaxis"), (.recent, "Recent", "clock"),
        ]
        for (live, title, symbol) in lives {
            let item = ClosureMenuItem(title: String(localized: title)) { [weak self] in self?.addBlock(String(localized: title), words: [live.rawValue]) }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(below: sender)
    }

    private func addBlock(_ title: String, words: [String]) {
        apply(Board.appending(title: title, words: words, to: text), String(localized: "Add Block"))
    }

    /// The block's menu, built against the note as it is now.
    private func menu(for block: Board.Block) -> NSMenu {
        let menu = NSMenu()
        let url = self.url
        menu.addItem(ClosureMenuItem(title: String(localized: "Open as Markdown")) { [weak self] in
            self?.controller?.openSpaceNote(url, select: NSRange(location: block.heading.location, length: 0))
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "Ask Assistant About This Block")) { [weak self] in
            self?.controller?.askAssistant(about: url, prompt: String(localized: "In the “\(block.title)” section of this page, "))
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: block.wide ? String(localized: "Half Width") : String(localized: "Full Width")) { [weak self] in
            guard let self, let current = self.current(block) else { return }
            self.apply(Board.setting(wide: !current.wide, of: current, in: self.text), String(localized: "Change Block Width"))
        })
        let index = page.blocks.firstIndex(of: block) ?? 0
        if index > 0 { menu.addItem(ClosureMenuItem(title: String(localized: "Move Up")) { [weak self] in self?.move(block, up: true) }) }
        if index + 1 < page.blocks.count { menu.addItem(ClosureMenuItem(title: String(localized: "Move Down")) { [weak self] in self?.move(block, up: false) }) }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Remove Block")) { [weak self] in
            guard let self, let current = self.current(block) else { return }
            self.apply(Board.removing(current), String(localized: "Remove Block"))
        })
        return menu
    }

    /// The block in the note as it is now (the page may have changed since the menu was built).
    private func current(_ block: Board.Block) -> Board.Block? {
        Board.page(in: text as NSString).blocks.first { $0 == block }
    }

    /// The block to add to, as the note is now: the same title, and the same one of the blocks
    /// with that title (two “Tasks” blocks are two places). What it holds may have changed.
    private func located(_ block: Board.Block) -> Board.Block? {
        let n = page.blocks.prefix { $0 != block }.filter { $0.title == block.title }.count
        let same = Board.page(in: text as NSString).blocks.filter { $0.title == block.title }
        return same.indices.contains(n) ? same[n] : nil
    }

    private func move(_ block: Board.Block, up: Bool) {
        let text = self.text
        let page = Board.page(in: text as NSString)
        guard let current = page.blocks.first(where: { $0 == block }), let patch = Board.moving(current, up: up, in: page, text: text) else { return }
        apply(patch, String(localized: "Move Block"))
    }

    /// Markdown files chosen in an open panel, linked by their paths.
    private func chooseLinks(for block: Board.Block) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.message = String(localized: "Choose notes to follow on this page")
        if let root = controller?.scopeRoot { panel.directoryURL = root }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            for chosen in panel.urls {
                guard let current = self.located(block) else { return }
                self.apply(Board.linkAddition(title: chosen.deletingPathExtension().lastPathComponent, destination: chosen.path, to: current, in: self.text), String(localized: "Add Link"))
            }
        }
    }

    /// A link's target: a web address, or a file by absolute, home-relative or note-relative path.
    static func resolve(_ destination: String, from note: URL) -> URL? {
        if let url = URL(string: destination), url.scheme != nil { return url }
        var path = destination
        var fragment: String?
        if let hash = path.firstIndex(of: "#") {
            fragment = String(path[path.index(after: hash)...]).removingPercentEncoding
            path = String(path[..<hash])
        }
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        let url = path.isEmpty ? note : URL(fileURLWithPath: path, relativeTo: note.deletingLastPathComponent()).standardizedFileURL
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = fragment
        return components?.url
    }
}

// MARK: - Block views

/// A block: a rule, its title and, under the pointer, its menu; then its content.
final class BlockView: NSView {
    private let more: FlatButton
    private let makeMenu: () -> NSMenu

    init(title: String, content: [NSView], menu: @escaping () -> NSMenu) {
        makeMenu = menu
        more = FlatButton(symbol: "ellipsis", style: .text)
        super.init(frame: .zero)
        let label = flatLabel(title, size: 13, weight: .semibold, color: Tokens.ink)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        more.target = self
        more.action = #selector(showMenu)
        more.alphaValue = 0
        more.toolTip = String(localized: "Block")
        more.setAccessibilityLabel(String(localized: "Block menu"))
        let header = NSStackView(views: [label, NSView(), more])
        let stack = NSStackView(views: [header] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(8, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in [header] + content where !(view is FlatButton) { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Tokens.line.setFill()
        NSRect(x: 0, y: isFlipped ? 0 : bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func showMenu() { makeMenu().popUp(below: more) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    override func mouseEntered(with event: NSEvent) { more.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { more.animator().alphaValue = 0 }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
}

/// A linked note: its title, and how far it has come: tasks done with a meter, the next open
/// task, when it changed. A web address shows its host.
final class LinkRow: NSView {
    private let open: (Bool) -> Void
    private let title: NSTextField
    private var hovering = false { didSet { title.textColor = hovering ? Tokens.accent : Tokens.ink } }

    init(title text: String, target: URL?, open: @escaping (Bool) -> Void) {
        self.open = open
        title = flatLabel(text, size: 14, weight: .medium)
        super.init(frame: .zero)
        var meta: [String] = []
        var next: String?
        var progress: Double?
        if let target, target.isFileURL, target.hasDirectoryPath {
            // A folder: where it is.
            meta.append((target.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        } else if let target, target.isFileURL {
            if let data = try? Data(contentsOf: target) {
                let items = Space.items(in: SourceDecoder.decode(data).text as NSString)
                if !items.isEmpty {
                    let done = items.filter(\.done).count
                    meta.append(String(localized: "\(done) of \(items.count) done"))
                    progress = Double(done) / Double(items.count)
                    next = items.first { !$0.done }?.text
                }
                if let date = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    meta.append(String(localized: "updated \(date.formatted(.relative(presentation: .named)))"))
                }
            } else {
                meta.append(String(localized: "Not found"))
            }
        } else if let target {
            meta.append(target.host() ?? target.absoluteString)
        }
        var views: [NSView] = [title]
        let line = flatLabel(meta.joined(separator: " · "), size: 12, color: Tokens.ink3)
        for label in [title, line] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        if !meta.isEmpty { views.append(line) }
        if let progress { views.append(Meter(value: progress, height: 4)) }
        if let next {
            let label = flatLabel(String(localized: "Next: \(next)"), size: 12, color: Tokens.ink2)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(label)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in views { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        if progress != nil, let meter = views.first(where: { $0 is Meter }) { meter.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = target.map { $0.isFileURL ? ($0.path as NSString).abbreviatingWithTildeInPath : $0.absoluteString }
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel(([text] + meta).joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self)) }
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { open(event.modifierFlags.contains(.command)) }
    }
    override func accessibilityPerformPress() -> Bool {
        open(false)
        return true
    }
}

/// A figure: the value large, its label under it, a meter when it is a share. No tile behind it.
final class NumberTile: NSView {
    init(_ metric: Board.Metric) {
        super.init(frame: .zero)
        let value = flatLabel(metric.value, size: 22, weight: .semibold)
        value.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let label = flatLabel(metric.label, size: 12, color: Tokens.ink2)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [value, label]
        let meter = metric.progress.map { Meter(value: $0, height: 4) }
        if let meter { views.append(meter) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 10, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        meter?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for view in [value, label] { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("\(metric.label): \(metric.value)")
    }

    required init?(coder: NSCoder) { fatalError() }
}
