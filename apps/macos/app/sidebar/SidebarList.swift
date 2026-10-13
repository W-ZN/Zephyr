import AppKit
import ZephyrCore
import ZephyrRender

/// The sidebar's list (design §8.3): the app's pages, the window's open documents, documents read
/// lately and the folder (its Home, then its files and folders), in sections that fold away under
/// their headings, drawn by Zephyr as one list that scrolls. Icons only, the folder is Home and a
/// Files entry, whose tree shows beside the strip in a list of its own (`showsFiles`).
///
/// Sections and folders open and close at once. Nothing has a fill: under the pointer a row's ink
/// darkens and a short tick shows at its left; the page the window shows has the accent tick, as
/// the outline marks the caret's heading.
///
/// Icons only (Settings), the same list is a strip: each row its symbol with the same ticks, each
/// section after the first a short hairline, every section open, no Recent; names show beside it
/// (`onHover`).
final class SidebarList: NSView, NSViewToolTipOwner {
    /// In this order: the app's fixed places first, so they never move, then what this window has
    /// open (it grows and shrinks), then where else to find files.
    enum Section: String, CaseIterable { case pages, open, recent, folder }
    enum Accessory { case search, close }

    struct Row {
        enum Kind {
            case header(Section)
            case page(SpacePanel)
            case recent(URL)
            case open(DocumentTab)
            case folder(FileNode, path: String)
            case file(FileNode)
            /// The folder's files, shown in the list's place.
            case files
            case choose
        }
        var kind: Kind
        var title: String
        var detail: String?
        var symbol: String?
        var depth = 0
        var current = false
        /// 0 until `reload` gives it the row height of the current metrics.
        var height: CGFloat = 0
        var tooltip: String?
        /// A recent file's folder (`detail`) shows without the pointer too: another recent file has
        /// the same name.
        var namesFolder = false
        /// A document, whose opening shows after the pointer rests on it.
        var isDocument: Bool {
            switch kind {
            case .open, .recent, .file: true
            default: false
            }
        }
        // Its position in the visible list.
        var y: CGFloat = 0

    }

    /// The row under the pointer, so the owner can name it at once (icons only) and, after a rest,
    /// show a document's opening.
    struct HoverItem {
        let kind: Row.Kind
        let name: String
        let path: String?
        let line: NSRect
    }

    /// Sizes from the theme's sidebar keys (`sidebar.size`, `sidebar.spacing`): names at
    /// `size`, section titles and details a point smaller, rows in proportion.
    struct Metrics: Equatable {
        var size: CGFloat = 13
        var rowHeight: CGFloat = 28

        init() {}

        init(_ settings: AppearanceSettings) {
            size = CGFloat(settings.number("sidebar.size") ?? 13)
            let factor: CGFloat = switch settings.string("sidebar.spacing") {
            case "compact": 1.85
            case "roomy": 2.35
            default: 28.0 / 13
            }
            rowHeight = (size * factor).rounded()
        }

        var sectionGap: CGFloat { (rowHeight / 2).rounded() }
        var title: NSFont { Tokens.font(size) }
        var currentTitle: NSFont { Tokens.font(size, .medium) }
        var header: NSFont { Tokens.font(size - 1, .semibold) }
        var detail: NSFont { NSFont.monospacedDigitSystemFont(ofSize: size - 1, weight: .regular) }
    }

    var metrics = Metrics() {
        didSet { if metrics != oldValue { reload() } }
    }
    private(set) var isCompact = false
    /// The folder's tree in place of the sections.
    private(set) var showsFiles = false

    /// A mode change rebuilds the rows once, with both the final content and presentation.
    func setPresentation(compact: Bool, showsFiles: Bool) {
        guard compact != isCompact || showsFiles != self.showsFiles else { return }
        isCompact = compact
        self.showsFiles = showsFiles
        reload()
    }
    var hasContentPreview = false {
        didSet { if hasContentPreview != oldValue { rebuildToolTips() } }
    }
    private var rowHeight: CGFloat { isCompact ? max(32, metrics.rowHeight) : metrics.rowHeight }
    private static let collapsedKey = "sidebarCollapsedSections"

    // What the list shows; `reload()` applies it.
    /// The window's documents and pages in their order, shown whenever there is one: what is open
    /// is always where it can be found again, an untitled document included.
    var openDocuments: [(tab: DocumentTab, title: String, unsaved: Bool, current: Bool)] = []
    /// The folder's own page, first in the folder section (design §8.3).
    var folderHome: SpacePanel?
    var pages: [(panel: SpacePanel, glance: String?)] = []
    var recent: [URL] = []
    var nodes: [FileNode] = []
    var rootName: String?
    var rootPath: String?
    var fileCount: Int?
    var folderStatus: String?
    /// Files is marked as the shown place while the icon strip's browser shows it.
    var filesOpen = false { didSet { if filesOpen != oldValue { reload() } } }
    var current: DocumentWindowController.Page?

    var onOpen: ((Row.Kind) -> Void)?
    var onAccessory: ((Accessory, NSRect) -> Void)?
    /// A row's own close button (an open document), or a middle click on it.
    var onClose: ((Row.Kind) -> Void)?
    var menuForRow: ((Row.Kind) -> NSMenu?)?
    /// The row under the pointer, or nil when it leaves the list.
    var onHover: ((HoverItem?) -> Void)?
    /// The folder's name heading its files was pressed: back to the sections. Without it (the
    /// icon strip's temporary browser) the name is only a title.
    var onBack: (() -> Void)?
    /// A click ends any hover-only surface before it can receive an action from this list.
    var onPointerDown: (() -> Void)?

    private(set) var rows: [Row] = []
    var filesEntryRect: NSRect? {
        guard let index = rows.firstIndex(where: { if case .files = $0.kind { true } else { false } }) else { return nil }
        return lineRect(index)
    }
    private var collapsed: Set<Section>
    private var expanded: Set<String> = []
    /// Each group's current state, retained for disclosure chevrons and snapshot compatibility.
    private var open: [String: Bool] = [:]
    private var accessibilityRows: [RowElement] = []
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            onHover?(hovered.map { HoverItem(kind: rows[$0].kind, name: rows[$0].title, path: rows[$0].tooltip, line: lineRect($0)) })
        }
    }
    private var hoveredAccessory: Accessory?
    private var pressed: Int?
    private var contentHeight: CGFloat = 0

    override init(frame: NSRect) {
        collapsed = Set((UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []).compactMap(Section.init))
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(String(localized: "Sidebar"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// As wide as the scroll view shows; as tall as the rows (`place`).
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        setFrameSize(NSSize(width: superview?.bounds.width ?? frame.width, height: frame.height))
        rebuildToolTips()
        updateAccessibility()
    }

    // MARK: Model

    /// Rebuilds the visible rows from what the list shows.
    func reload() {
        var rows: [Row] = []
        func groupOpen(_ id: String, _ isOpen: Bool) -> Bool {
            open[id] = isOpen
            return isOpen
        }
        func add(_ list: [FileNode], depth: Int, path: String) {
            for node in list {
                let nodePath = path.isEmpty ? node.name : path + "/" + node.name
                if let url = node.url {
                    var row = Row(kind: .file(node), title: (node.name as NSString).deletingPathExtension, depth: depth)
                    row.current = shows(url)
                    row.tooltip = (url.path as NSString).abbreviatingWithTildeInPath
                    rows.append(row)
                } else {
                    var folder = Row(kind: .folder(node, path: nodePath), title: node.name, depth: depth)
                    folder.tooltip = nodePath
                    rows.append(folder)
                    let inner = "f/" + nodePath
                    if groupOpen(inner, expanded.contains(nodePath)) { add(node.children, depth: depth + 1, path: nodePath) }
                }
            }
        }
        // Files: the folder's name, then its tree, nothing else.
        for section in showsFiles ? [] : Section.allCases {
            let id = "s." + section.rawValue
            var header = Row(kind: .header(section), title: title(of: section))
            header.height = isCompact ? (rows.isEmpty ? 8 : 17) : rowHeight + (rows.isEmpty ? 6 : metrics.sectionGap)
            if section == .folder {
                header.tooltip = rootPath
                header.detail = isCompact ? nil : folderStatus
            }
            // Icons only, the strip is for places and open documents; recent ones are a ⇧⌘O away.
            if section == .recent, recent.isEmpty || isCompact { continue }
            if section == .open, openDocuments.isEmpty { continue }
            rows.append(header)
            guard groupOpen(id, isCompact || !collapsed.contains(section)) else { continue }
            switch section {
            case .open:
                let repeated = Self.repeated(openDocuments.map(\.title))
                for item in openDocuments {
                    // An untitled document with text has nowhere else to be found: a dot says so.
                    var row = Row(kind: .open(item.tab), title: item.title, detail: item.unsaved ? "•" : nil)
                    row.current = item.current
                    if let url = item.tab.document?.fileURL {
                        row.tooltip = (url.path as NSString).abbreviatingWithTildeInPath
                        // Same-named files are told apart by their folders.
                        if repeated.contains(item.title) { row.detail = url.deletingLastPathComponent().lastPathComponent }
                    }
                    rows.append(row)
                }
            case .pages:
                for (panel, glance) in pages {
                    var row = Row(kind: .page(panel), title: panel.title, detail: glance, symbol: panel.symbol)
                    row.current = current == .panel(panel)
                    if case let .board(url) = panel { row.tooltip = url.path }
                    rows.append(row)
                }
            case .recent:
                let repeated = Self.repeated(recent.map { $0.deletingPathExtension().lastPathComponent })
                for url in recent {
                    var row = Row(kind: .recent(url), title: url.deletingPathExtension().lastPathComponent, detail: url.deletingLastPathComponent().lastPathComponent)
                    row.namesFolder = repeated.contains(row.title)
                    row.current = shows(url)
                    row.tooltip = (url.path as NSString).abbreviatingWithTildeInPath
                    rows.append(row)
                }
            case .folder:
                if rootName == nil {
                    rows.append(Row(kind: .choose, title: String(localized: "Choose Folder…"), symbol: "folder.badge.plus"))
                    break
                }
                if let home = folderHome {
                    var row = Row(kind: .page(home), title: String(localized: "Home"), symbol: home.symbol)
                    row.current = current == .panel(home)
                    rows.append(row)
                }
                // With names, the files are right here; the strip has no room for a tree.
                guard isCompact else {
                    add(nodes, depth: 0, path: "")
                    break
                }
                var files = Row(kind: .files, title: String(localized: "Files"), detail: folderStatus ?? fileCount.map { "\($0)" }, symbol: "folder")
                files.tooltip = rootPath
                files.current = filesOpen
                rows.append(files)
            }
        }
        if showsFiles {
            var header = Row(kind: .header(.folder), title: title(of: .folder), detail: folderStatus)
            header.height = rowHeight + 6
            header.tooltip = rootPath
            rows.append(header)
            add(nodes, depth: 0, path: "")
        }
        for k in rows.indices where rows[k].height == 0 { rows[k].height = rowHeight }
        self.rows = rows
        hovered = nil
        place()
        updateAccessibility(recreate: true)
    }

    /// Names that more than one row would show.
    private static func repeated(_ titles: [String]) -> Set<String> {
        var seen = Set<String>(), twice = Set<String>()
        for title in titles where !seen.insert(title).inserted { twice.insert(title) }
        return twice
    }

    private func shows(_ url: URL) -> Bool {
        guard case let .file(shown) = current else { return false }
        return shown.standardizedFileURL.path == url.standardizedFileURL.path
    }

    private func title(of section: Section) -> String {
        switch section {
        case .open: String(localized: "Open")
        case .pages: String(localized: "Pages")
        case .recent: String(localized: "Recent")
        case .folder: rootName ?? String(localized: "Folder")
        }
    }

    /// The current file's folders open, without motion (a document opened from elsewhere).
    func reveal(file url: URL) {
        func find(_ list: [FileNode], _ path: String) -> [String]? {
            for node in list {
                let p = path.isEmpty ? node.name : path + "/" + node.name
                if node.url?.standardizedFileURL == url.standardizedFileURL { return [] }
                if node.isFolder, let found = find(node.children, p) { return [p] + found }
            }
            return nil
        }
        guard let folders = find(nodes, "") else { return }
        for path in folders where !expanded.contains(path) {
            expanded.insert(path)
            open["f/" + path] = true
        }
    }

    /// The row the window shows, scrolled into view.
    func scrollToCurrent() {
        guard let i = rows.firstIndex(where: \.current) else { return }
        scrollToVisible(NSRect(x: 0, y: rows[i].y - 40, width: 1, height: rows[i].height + 80))
    }

    // MARK: Opening and closing

    func toggle(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        switch rows[index].kind {
        case let .header(section):
            if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
            UserDefaults.standard.set(collapsed.map(\.rawValue).sorted(), forKey: Self.collapsedKey)
        case let .folder(_, path):
            if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        default:
            return
        }
        reload()
    }

    /// Kept for callers that ask the sidebar to unroll when it appears. Rows are already placed.
    func unroll() {
        place()
    }

    /// Kept for snapshots that request an animation step; toggles settle immediately.
    func stepForSnapshot(_ seconds: CGFloat, toggling index: Int? = nil, unrolling: Bool = false) {
        if let index { toggle(index) }
        if unrolling { self.unroll() }
    }

    // MARK: Placement

    /// Where every visible row is: a simple, stable vertical list.
    private func place() {
        var y: CGFloat = 0
        for i in rows.indices {
            rows[i].y = y
            y += rows[i].height
        }
        contentHeight = y + 12
        let height = max(contentHeight, enclosingScrollView?.contentView.bounds.height ?? 0)
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
        needsDisplay = true
        rebuildToolTips()
    }

    // MARK: Drawing


    override func draw(_ dirtyRect: NSRect) {
        let visible = visibleRect
        for i in visibleRows(in: visible.insetBy(dx: 0, dy: -2)) {
            drawRow(rows[i], index: i)
        }
    }

    private func drawRow(_ row: Row, index i: Int) {
        let hover = hovered == i
        let inset: CGFloat = 16
        let line = lineRect(i)
        if isCompact { return drawIcon(row, hover: hover, in: line) }
        switch row.kind {
        case let .header(section):
            let open = self.open["s." + section.rawValue] ?? true
            let leads = hover && !(showsFiles && onBack == nil)   // a title that leads somewhere lights up
            var x = inset
            // Heading the files, the folder's name leads back to the sections.
            if showsFiles, onBack != nil, let image = Tokens.symbol("chevron.left", size: metrics.size - 3, weight: .semibold, color: hover ? Tokens.ink2 : Tokens.ink3) {
                image.draw(in: NSRect(x: x, y: line.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
                x += image.size.width + 6
            }
            let title = NSAttributedString(string: row.title, attributes: [.font: metrics.header, .foregroundColor: leads ? Tokens.ink2 : Tokens.ink3])
            let size = title.size()
            let maxTitle = max(0, line.width - x - 70)
            title.draw(with: NSRect(x: x, y: line.midY - size.height / 2, width: min(size.width, maxTitle), height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x += min(size.width, maxTitle) + 5
            // The chevron says the section folds; it shows under the pointer, or while folded.
            if !showsFiles, hover || !open {
                let turn: CGFloat = open ? 1 : 0
                drawChevron(at: NSPoint(x: x + 4, y: line.midY), turn: turn, color: Tokens.ink3)
            }
            var right = line.maxX - 10
            for accessory in accessories(of: section) where hover {
                let frame = NSRect(x: right - 22, y: line.midY - 11, width: 22, height: 22)
                let color = hoveredAccessory == accessory ? Tokens.ink : Tokens.ink2
                if let image = Tokens.symbol(symbol(of: accessory), size: 12, weight: .medium, color: color) {
                    image.draw(in: NSRect(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
                }
                right -= 24
            }
            if !hover, let detail = row.detail {
                drawTrailing(detail, right: line.maxX - inset, midY: line.midY, color: Tokens.ink3)
            }
        case .page, .recent, .open, .file, .files, .choose, .folder:
            var x = inset + CGFloat(row.depth) * 14
            drawTick(current: row.current, hover: hover, midY: line.midY)
            // In the folder section, the tree keeps the places' columns: a folder's chevron where
            // their icons are, every name where theirs are. The separate list keeps a tighter one.
            let slot: (chevron: CGFloat, title: CGFloat) = showsFiles ? (4, 14) : (8, 24)
            if case let .folder(_, path) = row.kind {
                drawChevron(at: NSPoint(x: x + slot.chevron, y: line.midY), turn: open["f/" + path] == true ? 1 : 0, color: hover ? Tokens.ink2 : Tokens.ink3)
                x += slot.title
            } else if case .file = row.kind {
                x += slot.title
            }
            if let symbol = row.symbol, let image = Tokens.symbol(symbol, size: metrics.size, weight: .medium, color: row.current ? Tokens.accent : hover ? Tokens.ink : Tokens.ink2) {
                image.draw(in: NSRect(x: x + 8 - image.size.width / 2, y: line.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
                x += 24
            }
            var detailWidth: CGFloat = 0
            let showsDetail: Bool = {
                if case .recent = row.kind { return hover || row.namesFolder }
                if case .open = row.kind { return !hover }
                return row.detail != nil
            }()
            if showsDetail, let detail = row.detail, !detail.isEmpty {
                detailWidth = drawTrailing(detail, right: line.maxX - inset, midY: line.midY, color: Tokens.ink3) + 10
            }
            // An open document closes from its row, like a tab.
            if case .open = row.kind, hover, let frame = closeFrame(in: line),
               let image = Tokens.symbol("xmark", size: 10, weight: .semibold, color: hoveredAccessory == .close ? Tokens.ink : Tokens.ink3) {
                image.draw(in: NSRect(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
                detailWidth = line.maxX - frame.minX
            }
            let ink: NSColor = {
                if case .folder = row.kind { return hover ? Tokens.ink : Tokens.ink2 }
                if case .choose = row.kind { return hover ? Tokens.ink : Tokens.ink2 }
                if case .files = row.kind { return hover ? Tokens.ink : Tokens.ink.withAlphaComponent(0.82) }
                return row.current || hover ? Tokens.ink : Tokens.ink.withAlphaComponent(0.82)
            }()
            let font = row.current ? metrics.currentTitle : metrics.title
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let title = NSAttributedString(string: row.title, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
            let height = ceil(font.ascender - font.descender + font.leading)
            title.draw(with: NSRect(x: x, y: line.midY - height / 2, width: max(0, line.maxX - inset - detailWidth - x), height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// Icons only: a section is a short hairline (none above the first); a row is its symbol, the
    /// ink and ticks as with names, a folder's chevron beside it, an unsaved document's dot over it.
    private func drawIcon(_ row: Row, hover: Bool, in line: NSRect) {
        if case .header = row.kind {
            guard line.height > rowHeight / 2 else { return }
            Tokens.line.setFill()
            NSRect(x: (line.midX - 10).rounded(), y: line.midY.rounded(), width: 20, height: 1).fill()
            return
        }
        drawTick(current: row.current, hover: hover, midY: line.midY)
        let isFolder: Bool = if case .folder = row.kind { true } else { false }
        let ink = row.current ? Tokens.accent : hover ? Tokens.ink : Tokens.ink2
        if let image = Tokens.symbol(row.symbol ?? (isFolder ? "folder" : "doc.text"), size: metrics.size + 2, weight: .regular, color: ink) {
            image.draw(in: NSRect(x: (line.midX - image.size.width / 2).rounded(), y: (line.midY - image.size.height / 2).rounded(), width: image.size.width, height: image.size.height))
        }
        if case let .folder(_, path) = row.kind {
            drawChevron(at: NSPoint(x: line.maxX - 9, y: line.midY), turn: open["f/" + path] == true ? 1 : 0, color: Tokens.ink3)
        }
        if case .open = row.kind, row.detail == "•" {
            Tokens.ink2.setFill()
            NSBezierPath(ovalIn: NSRect(x: line.midX + 7, y: line.midY - 10, width: 5, height: 5)).fill()
        }
    }

    /// The accent tick for what the window shows; a faint, shorter one under the pointer.
    private func drawTick(current: Bool, hover: Bool, midY: CGFloat) {
        guard current || hover else { return }
        (current ? Tokens.accent : Tokens.ink3.withAlphaComponent(0.6)).setFill()
        let h: CGFloat = current ? 14 : 10
        NSBezierPath(roundedRect: NSRect(x: 5, y: midY - h / 2, width: 3, height: h), xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// A small chevron pointing right, turned down as `turn` goes to 1.
    private func drawChevron(at center: NSPoint, turn: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: -1.6, y: -3.6))
        path.line(to: NSPoint(x: 2, y: 0))
        path.line(to: NSPoint(x: -1.6, y: 3.6))
        var t = AffineTransform(rotationByDegrees: 90 * min(max(turn, 0), 1))
        t.append(AffineTransform(translationByX: center.x, byY: center.y))
        path.transform(using: t)
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    @discardableResult
    private func drawTrailing(_ text: String, right: CGFloat, midY: CGFloat, color: NSColor) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: metrics.detail, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        let width = min(ceil(size.width), 110, bounds.width * 0.35)
        (text as NSString).draw(with: NSRect(x: right - width, y: midY - size.height / 2, width: width, height: size.height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        return width
    }

    private func closeFrame(in line: NSRect) -> NSRect? {
        NSRect(x: line.maxX - 10 - 22, y: line.midY - 11, width: 22, height: 22)
    }

    /// Only the folder's search shows on a heading; creating and the folder's other actions are in
    /// the headings' menus and the menu bar.
    private func accessories(of section: Section) -> [Accessory] {
        section == .folder && rootName != nil ? [.search] : []
    }

    private func symbol(of accessory: Accessory) -> String {
        switch accessory {
        case .search: "magnifyingglass"
        case .close: "xmark"
        }
    }

    /// Accessories sit right to left from the header's trailing edge.
    private func accessory(at point: NSPoint, row i: Int) -> (Accessory, NSRect)? {
        guard !isCompact else { return nil }
        let line = lineRect(i)
        if case .open = rows[i].kind, let frame = closeFrame(in: line), frame.insetBy(dx: -1, dy: -3).contains(point) { return (.close, frame) }
        guard case let .header(section) = rows[i].kind else { return nil }
        var right = line.maxX - 10
        for accessory in accessories(of: section) {
            let frame = NSRect(x: right - 22, y: line.midY - 11, width: 22, height: 22)
            if frame.insetBy(dx: -1, dy: -3).contains(point) { return (accessory, frame) }
            right -= 24
        }
        return nil
    }

    // MARK: Pointer

    /// The part of row `i` that is its line: the bottom `rowHeight`, a header's gap above it; with
    /// icons only, a header is all line (its hairline).
    private func lineRect(_ i: Int) -> NSRect {
        let row = rows[i]
        let height: CGFloat = if isCompact, case .header = row.kind { row.height } else { rowHeight }
        return NSRect(x: 0, y: row.y + row.height - height, width: bounds.width, height: height)
    }

    private func row(at point: NSPoint) -> Int? {
        let i = firstRow(endingAfter: point.y)
        guard rows.indices.contains(i), lineRect(i).contains(NSPoint(x: 0, y: point.y)) else { return nil }
        return i
    }

    private func visibleRows(in rect: NSRect) -> Range<Int> {
        let start = firstRow(endingAfter: rect.minY)
        var low = start, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].y < rect.maxY { low = middle + 1 } else { high = middle }
        }
        return start..<low
    }

    /// The first ordered row whose bottom lies below `y`.
    private func firstRow(endingAfter y: CGFloat) -> Int {
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].y + rows[middle].height <= y { low = middle + 1 } else { high = middle }
        }
        return low
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let i = row(at: point)
        let accessory = i.flatMap { self.accessory(at: point, row: $0)?.0 }
        if accessory != hoveredAccessory {
            hoveredAccessory = accessory
            needsDisplay = true
        }
        hovered = i
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        hoveredAccessory = nil
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        pressed = row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let i = row(at: point), i == pressed else { return }
        pressed = nil
        if let (accessory, frame) = accessory(at: point, row: i) {
            if accessory == .close { return onClose?(rows[i].kind) ?? () }
            return onAccessory?(accessory, frame) ?? ()
        }
        press(i)
    }

    /// A middle click closes an open document, as on a browser's tab.
    override func otherMouseUp(with event: NSEvent) {
        onPointerDown?()
        guard event.buttonNumber == 2, let i = row(at: convert(event.locationInWindow, from: nil)), case .open = rows[i].kind else { return super.otherMouseUp(with: event) }
        onClose?(rows[i].kind)
    }

    private func press(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        switch rows[i].kind {
        case .header where showsFiles: onBack?()
        case .header: if !isCompact { toggle(i) }
        case .folder: toggle(i)
        default: onOpen?(rows[i].kind)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = row(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuForRow?(rows[i].kind)
    }

    // MARK: Tool tips and accessibility

    private func rebuildToolTips() {
        removeAllToolTips()
        // Icons only, the label beside the strip names the row at once (`onHover`); a document's
        // path is on its preview, when previews are on.
        for (i, row) in rows.enumerated() where !isCompact && row.tooltip != nil && !(hasContentPreview && row.isDocument) {
            addToolTip(lineRect(i), owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1))
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let i = row(at: point) else { return "" }
        return rows[i].tooltip ?? ""
    }

    private func updateAccessibility(recreate: Bool = false) {
        guard recreate else {
            guard accessibilityRows.count == rows.count else { return updateAccessibility(recreate: true) }
            for i in rows.indices {
                accessibilityRows[i].setAccessibilityFrameInParentSpace(NSRect(x: 0, y: rows[i].y, width: bounds.width, height: rows[i].height))
            }
            return
        }
        accessibilityRows = rows.indices.map { i in
            let row = rows[i]
            let element = RowElement { [weak self] in self?.press(i) }
            element.setAccessibilityParent(self)
            element.setAccessibilityEnabled(true)
            element.setAccessibilityFrameInParentSpace(NSRect(x: 0, y: row.y, width: bounds.width, height: row.height))
            switch row.kind {
            case .header where showsFiles && onBack != nil:
                element.setAccessibilityRole(.button)
                element.setAccessibilityHelp(String(localized: "Back to the sidebar's sections"))
            case .header where showsFiles:
                element.setAccessibilityRole(.staticText)
            case .header where isCompact:
                element.setAccessibilityRole(.staticText)
            case let .header(section):
                element.setAccessibilityRole(.disclosureTriangle)
                element.setAccessibilityValue(collapsed.contains(section) ? 0 : 1)
            case let .folder(_, path):
                element.setAccessibilityRole(.disclosureTriangle)
                element.setAccessibilityValue(expanded.contains(path) ? 1 : 0)
            default:
                element.setAccessibilityRole(.button)
                if row.current { element.setAccessibilityValue(String(localized: "Shown")) }
            }
            if case let .open(tab) = row.kind {
                element.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: String(localized: "Close")) { [weak self, weak tab] in
                    guard let self, let tab else { return false }
                    self.onClose?(.open(tab))
                    return true
                }])
            }
            // The path too, where the row has one: icons only, it is all there is to read.
            let label = row.detail.map { "\(row.title), \($0)" } ?? row.title
            element.setAccessibilityLabel(isCompact ? [label, row.tooltip].compactMap { $0 }.joined(separator: ", ") : label)
            return element
        }
        setAccessibilityChildren(accessibilityRows)
    }

    /// The rows' titles as shown, for checks.
    var titlesForSnapshot: [String] { rows.map(\.title) }
    func indexForSnapshot(_ title: String) -> Int? { rows.firstIndex { $0.title == title } }
    /// The middle of that row's line, toward its right end (where a heading's actions are).
    func pointForSnapshot(_ title: String) -> NSPoint? {
        indexForSnapshot(title).map { NSPoint(x: bounds.width - 60, y: lineRect($0).midY) }
    }
}

/// A row for VoiceOver: pressing it acts as a click on the row.
private final class RowElement: NSAccessibilityElement {
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

extension SidebarList: InterfaceFontObserver {
    func interfaceFontChanged() { reload() }
}
