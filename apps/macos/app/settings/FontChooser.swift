import AppKit
import ZephyrRender

/// A focused font-search sheet. It leaves the settings page and saved values unchanged until Use.
final class FontChooser: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let preview = flatLabel("", size: 23, wraps: true)
    private let detail = flatLabel("", size: 12, color: Tokens.ink2, wraps: true)
    private let count = flatLabel("", size: 11, color: Tokens.ink3)
    private let use = FlatButton(title: String(localized: "Use Font", table: "Fonts"), style: .primary)
    private let get = FlatButton(title: String(localized: "Font Website", table: "Fonts"), style: .plain)
    private var catalog = FontCatalog()
    private var results: [FontCatalog.Entry] = []
    private let scope: FontCatalog.Scope
    private let selected: String
    private let onChoose: (String) -> Void

    static func present(from view: NSView, scope: FontCatalog.Scope, selected: String, onChoose: @escaping (String) -> Void) {
        guard let window = view.window else { return }
        let chooser = FontChooser(scope: scope, selected: selected, onChoose: onChoose)
        window.beginSheet(chooser.panel) { [chooser] _ in chooser.panel.orderOut(nil) }
        chooser.panel.makeFirstResponder(chooser.search)
    }

    private init(scope: FontCatalog.Scope, selected: String, onChoose: @escaping (String) -> Void) {
        self.scope = scope
        self.selected = selected
        self.onChoose = onChoose
        super.init()
        panel.title = String(localized: "Find a Font", table: "Fonts")
        panel.backgroundColor = Tokens.canvas
        let content = SurfaceView(fill: Tokens.canvas, border: nil, radius: 0)
        panel.contentView = content
        search.placeholderString = String(localized: "Chinese name, English name or pinyin", table: "Fonts")
        search.setAccessibilityLabel(String(localized: "Search Fonts", table: "Fonts"))
        search.delegate = self
        let refresh = FlatButton(title: String(localized: "Refresh Fonts", table: "Fonts"), style: .plain) { [weak self] in
            guard let self else { return }
            self.catalog = FontCatalog()
            self.filter()
        }
        let top = NSStackView(views: [search, refresh])
        top.spacing = 12
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("font"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(choose)
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(String(localized: "Font Results", table: "Fonts"))
        table.flatten()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        use.target = self
        use.action = #selector(choose)
        use.keyEquivalent = "\r"
        get.target = self
        get.action = #selector(openWebsite)
        let cancel = FlatButton(title: String(localized: "Cancel", table: "Fonts"), style: .secondary) { [weak self] in self?.close() }
        cancel.keyEquivalent = "\u{1b}"
        let bottom = NSStackView(views: [get, NSView(), cancel, use])
        bottom.spacing = 10
        let stack = NSStackView(views: [top, count, scroll, preview, detail, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            preview.heightAnchor.constraint(equalToConstant: 62),
            detail.heightAnchor.constraint(equalToConstant: 36),
        ])
        for view in [top, scroll, preview, detail, bottom] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        filter(preferred: selected)
    }

    private var selection: FontCatalog.Entry? { results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil }

    private func filter(preferred: String? = nil) {
        let family = preferred ?? selection?.family
        results = catalog.search(search.stringValue, scope: scope)
        table.reloadData()
        count.stringValue = results.isEmpty ? String(localized: "No matching fonts. Try another name or refresh after installing.", table: "Fonts") : String(format: String(localized: "%ld fonts", table: "Fonts"), results.count)
        if let row = results.firstIndex(where: { $0.family == family }) ?? (results.isEmpty ? nil : 0) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updatePreview()
    }

    private func updatePreview() {
        use.isEnabled = selection?.installed == true
        get.isHidden = selection?.page == nil
        guard let entry = selection else { preview.stringValue = ""; detail.stringValue = ""; return }
        if entry.installed, let font = NSFontManager.shared.font(withFamily: entry.family, traits: [], weight: 5, size: 23) {
            preview.font = font
            preview.stringValue = entry.chinese ? "清风徐来，水波不兴。\nAa Bb 0123 · Zephyr" : "The quick brown fox\nAa Bb 0123 · Zephyr"
            detail.stringValue = entry.title
        } else {
            preview.font = Tokens.font(18)
            preview.stringValue = String(localized: "This font is not installed", table: "Fonts")
            detail.stringValue = String(localized: "Install it in Font Book, then refresh.", table: "Fonts")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FlatRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = results[row]
        let label = flatLabel(entry.title + (entry.installed ? "" : " — " + String(localized: "Not installed", table: "Fonts")), size: 13, color: entry.installed ? Tokens.ink : Tokens.ink2)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = label.stringValue
        let cell = NSTableCellView()
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updatePreview() }
    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let step = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(0, table.selectedRow + step), results.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    @objc private func choose() {
        guard let entry = selection, entry.installed else { return }
        onChoose(entry.family)
        close()
    }

    @objc private func openWebsite() {
        if let url = selection?.page { NSWorkspace.shared.open(url) }
    }

    private func close() { panel.sheetParent?.endSheet(panel) }
}
