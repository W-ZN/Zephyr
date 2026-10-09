import AppKit
import ZephyrCore
import ZephyrRender

/// A Spotlight-style floating list used for Open Quickly (⇧⌘O) and the command palette (⇧⌘P).
final class PalettePanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Entry {
        var title: String
        var detail: String?
        var shortcut: String?
        var image: NSImage?
        var action: () -> Void

        init(title: String, detail: String? = nil, shortcut: String? = nil, image: NSImage? = nil, action: @escaping () -> Void) {
            self.title = title
            self.detail = detail
            self.shortcut = shortcut
            self.image = image
            self.action = action
        }
    }

    private static var current: PalettePanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var entries: [Entry] = []
    private let provider: (String) -> [Entry]
    private var heightConstraint: NSLayoutConstraint!

    private init(provider: @escaping (String) -> [Entry], placeholder: String) {
        self.provider = provider
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 60), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        build(placeholder: placeholder)
    }

    override var canBecomeKey: Bool { true }

    static func show(over window: NSWindow, placeholder: String, provider: @escaping (String) -> [Entry]) {
        current?.close()
        let panel = PalettePanel(provider: provider, placeholder: placeholder)
        let width: CGFloat = min(600, window.frame.width - 40)
        panel.setContentSize(NSSize(width: width, height: 60))
        panel.setFrameTopLeftPoint(NSPoint(x: window.frame.midX - width / 2, y: window.frame.maxY - min(140, window.frame.height * 0.15)))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.field)
        current = panel
        panel.reload()
    }

    /// Folder results arrive once; a static command list needs no recurring work.
    static func refresh(over window: NSWindow?) {
        guard let window, let panel = current, panel.parent === window else { return }
        panel.reload()
    }

    private func build(placeholder: String) {
        let background = SurfaceView(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.panel)
        contentView = background

        let icon = NSImageView(image: Tokens.symbol("magnifyingglass", size: 16, color: Tokens.ink3)!)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Tokens.font(17)
        field.textColor = Tokens.ink
        field.delegate = self
        field.cell?.isScrollable = true
        let header = NSStackView(views: [icon, field])
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)
        let divider = SurfaceView(fill: Tokens.line, border: nil, radius: 0)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let column = NSTableColumn(identifier: .init("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.flatten()
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.focusRingType = .none
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        let stack = NSStackView(views: [header, divider, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor), stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor), stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            heightConstraint,
        ])
    }

    private func reload() {
        entries = provider(field.stringValue)
        table.reloadData()
        if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        let rows = CGFloat(min(entries.count, 10))
        heightConstraint.constant = rows == 0 ? 0 : rows * 34 + 12
        let top = frame.maxY
        let height = 50 + (rows == 0 ? 0 : 1) + heightConstraint.constant
        setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): perform(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), entries.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() { perform(table.clickedRow) }

    private func perform(_ row: Int) {
        guard row >= 0, row < entries.count else { return }
        let action = entries[row].action
        close()
        // Run after the panel is gone so the document window is key again for the responder chain.
        DispatchQueue.main.async { action() }
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func close() {
        parent?.removeChildWindow(self)
        super.close()
        if Self.current === self { Self.current = nil }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FlatRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = tableView.makeView(withIdentifier: .init("palette"), owner: nil) as? PaletteCell ?? PaletteCell()
        cell.identifier = .init("palette")
        cell.configure(entry)
        return cell
    }

    // MARK: Sources

    /// Fuzzy subsequence ranking over file names first, then relative paths.
    static func rankFiles(_ files: [ScopeFile], query: String) -> [ScopeFile] {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return files }
        var scored: [(ScopeFile, Int)] = []
        for file in files {
            if let s = fuzzyScore(q, file.name.lowercased()) {
                scored.append((file, s * 2))
            } else if let s = fuzzyScore(q, file.relativePath.lowercased()) {
                scored.append((file, s))
            }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.relativePath.count < $1.0.relativePath.count }.map(\.0)
    }

    static func fuzzyScore(_ q: String, _ s: String) -> Int? {
        var score = 0
        var qi = q.startIndex
        var previous: String.Index?
        var run = 0
        var i = s.startIndex
        while i < s.endIndex, qi < q.endIndex {
            if s[i] == q[qi] {
                score += 10
                if let p = previous, s.index(after: p) == i { run += 1; score += 6 * run } else { run = 0 }
                if i == s.startIndex || "/-_ .".contains(s[s.index(before: i)]) { score += 8 }
                previous = i
                qi = q.index(after: qi)
            }
            i = s.index(after: i)
        }
        guard qi == q.endIndex else { return nil }
        return score - s.count / 6
    }

    /// Every enabled menu command, so the palette, menus and shortcuts stay one command set.
    static func commands(matching query: String, in window: NSWindow) -> [Entry] {
        guard let main = NSApp.mainMenu else { return [] }
        var entries: [(Entry, Int)] = []
        let q = query.lowercased()
        func walk(_ menu: NSMenu, path: [String]) {
            menu.update()
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let sub = item.submenu {
                    if sub === NSApp.servicesMenu || sub.identifier == MainMenu.recentMenuID { continue }
                    walk(sub, path: path + [item.title])
                    continue
                }
                guard item.action != nil, item.isEnabled else { continue }
                let title = item.title
                let score = q.isEmpty ? 0 : fuzzyScore(q, title.lowercased()).map { $0 * 2 } ?? fuzzyScore(q, (path + [title]).joined(separator: " ").lowercased())
                guard q.isEmpty || score != nil else { continue }
                let entry = Entry(title: title, detail: path.dropFirst().joined(separator: " › ").isEmpty ? path.first : path.dropFirst().joined(separator: " › "),
                                  shortcut: shortcut(of: item), image: item.image) { [weak item] in
                    guard let item, let menu = item.menu else { return }
                    let index = menu.index(of: item)
                    if index >= 0 { menu.performActionForItem(at: index) }
                }
                entries.append((entry, score ?? 0))
            }
        }
        for top in main.items.dropFirst() { if let sub = top.submenu { walk(sub, path: [top.title]) } }
        if let app = main.items.first?.submenu { walk(app, path: [MainMenu.appName]) }
        return entries.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func shortcut(of item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var s = ""
        let m = item.keyEquivalentModifierMask
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + item.keyEquivalent.uppercased()
    }
}

private final class PaletteCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = Tokens.ink2
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        title.font = Tokens.font(13.5)
        title.textColor = Tokens.ink
        title.lineBreakMode = .byTruncatingTail
        detail.font = Tokens.font(12)
        detail.textColor = Tokens.ink3
        detail.lineBreakMode = .byTruncatingHead
        shortcut.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        shortcut.textColor = Tokens.ink3
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, title, detail, NSView(), shortcut])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = title
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: PalettePanel.Entry) {
        icon.image = entry.image ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        title.stringValue = entry.title
        detail.stringValue = entry.detail ?? ""
        shortcut.stringValue = entry.shortcut ?? ""
    }
}
