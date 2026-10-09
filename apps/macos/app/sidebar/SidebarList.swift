import AppKit
import ZephyrCore
import ZephyrRender

/// The sidebar's list (design §8.3): the window's open documents (when it holds more than one),
/// the app's pages, documents read lately and the folder's files, in sections that fold away under
/// their headings, drawn by Zephyr as one list that scrolls.
///
/// Opening a section or a folder unrolls it like a scroll of paper: the rows already out lie flat,
/// the next ride a small roll at the leading edge, foreshortened and dim as they turn toward the
/// reader, and the rows below make room as it goes (springs, `Motion`); closing rolls them back
/// up. Opening the sidebar unrolls the whole list once. At an edge with more to scroll, the rows
/// turn away over the same roll. Nothing has a fill: under the pointer a row's ink darkens and a
/// short tick shows at its left; the page the window shows has the accent tick, as the outline
/// marks the caret's heading.
final class SidebarList: NSView, NSViewToolTipOwner {
    /// In this order: the app's fixed places first, so they never move, then what this window has
    /// open (it grows and shrinks), then where else to find files.
    enum Section: String, CaseIterable { case pages, open, recent, folder }
    enum Accessory { case add, newDocument, search, more, close }

    struct Row {
        enum Kind {
            case header(Section)
            case page(SpacePanel)
            case recent(URL)
            case open(DocumentTab)
            case folder(FileNode, path: String)
            case file(FileNode)
            case choose
        }
        var kind: Kind
        var title: String
        var detail: String?
        var symbol: String?
        var depth = 0
        var current = false
        /// The groups it sits in, outermost first: its section, then folders.
        var groups: [String] = []
        /// 0 until `reload` gives it the row height of the current metrics.
        var height: CGFloat = 0
        var tooltip: String?
        /// A recent file's folder (`detail`) shows without the pointer too: another recent file has
        /// the same name.
        var namesFolder = false
        // Where it is drawn this frame.
        var y: CGFloat = 0
        var scale: CGFloat = 1
        var alpha: CGFloat = 1

        var group: String? {
            switch kind {
            case let .header(section): "s." + section.rawValue
            case let .folder(_, path): "f/" + path
            default: nil
            }
        }
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
    private var rowHeight: CGFloat { metrics.rowHeight }
    /// The roll's radius: about two rows ride it at once.
    private static let roll: CGFloat = 34
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
    var folderStatus: String?
    var current: DocumentWindowController.Page?

    var onOpen: ((Row.Kind) -> Void)?
    var onAccessory: ((Accessory, NSRect) -> Void)?
    /// A row's own close button (an open document), or a middle click on it.
    var onClose: ((Row.Kind) -> Void)?
    var menuForRow: ((Row.Kind) -> NSMenu?)?

    private(set) var rows: [Row] = []
    private var collapsed: Set<Section>
    private var expanded: Set<String> = []
    /// Each group's openness, 0...1: what unrolls.
    private var open: [String: Spring] = [:]
    /// The whole list unrolling as the sidebar opens, from the top of what shows (`unrollTop`).
    private var unrolling = Spring(1, response: 0.55, damping: 1)
    private var unrollTop: CGFloat = 0
    private lazy var clock = FrameClock(view: self) { [weak self] dt in self?.advance(dt) ?? false }
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
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
    }

    // MARK: Model

    /// Rebuilds the rows from what the list shows, keeping each group's motion.
    func reload() {
        var rows: [Row] = []
        func groupOpen(_ id: String, _ isOpen: Bool) -> Bool {
            if open[id] == nil { open[id] = Spring(isOpen ? 1 : 0, response: 0.42, damping: 0.92) }
            if open[id]!.target != (isOpen ? 1 : 0) { open[id]!.target = isOpen ? 1 : 0 }
            // Children stay while they roll up.
            return isOpen || open[id]!.value > 0.001
        }
        for section in Section.allCases {
            let id = "s." + section.rawValue
            var header = Row(kind: .header(section), title: title(of: section))
            header.height = rowHeight + (rows.isEmpty ? 6 : metrics.sectionGap)
            if section == .folder {
                header.tooltip = rootPath
                header.detail = folderStatus
            }
            if section == .recent, recent.isEmpty { continue }
            if section == .open, openDocuments.isEmpty { continue }
            rows.append(header)
            guard groupOpen(id, !collapsed.contains(section)) else { continue }
            switch section {
            case .open:
                let repeated = Self.repeated(openDocuments.map(\.title))
                for item in openDocuments {
                    // An untitled document with text has nowhere else to be found: a dot says so.
                    var row = Row(kind: .open(item.tab), title: item.title, detail: item.unsaved ? "•" : nil, groups: [id])
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
                    var row = Row(kind: .page(panel), title: panel.title, detail: glance, symbol: panel.symbol, groups: [id])
                    row.current = current == .panel(panel)
                    if case let .board(url) = panel { row.tooltip = url.path }
                    rows.append(row)
                }
            case .recent:
                let repeated = Self.repeated(recent.map { $0.deletingPathExtension().lastPathComponent })
                for url in recent {
                    var row = Row(kind: .recent(url), title: url.deletingPathExtension().lastPathComponent, detail: url.deletingLastPathComponent().lastPathComponent, groups: [id])
                    row.namesFolder = repeated.contains(row.title)
                    row.current = shows(url)
                    row.tooltip = (url.path as NSString).abbreviatingWithTildeInPath
                    rows.append(row)
                }
            case .folder:
                if rootName == nil {
                    rows.append(Row(kind: .choose, title: String(localized: "Choose Folder…"), symbol: "folder.badge.plus", groups: [id]))
                    break
                }
                if let home = folderHome {
                    var row = Row(kind: .page(home), title: String(localized: "Home"), symbol: home.symbol, groups: [id])
                    row.current = current == .panel(home)
                    rows.append(row)
                }
                func add(_ list: [FileNode], depth: Int, path: String, groups: [String]) {
                    for node in list {
                        let nodePath = path.isEmpty ? node.name : path + "/" + node.name
                        if let url = node.url {
                            var row = Row(kind: .file(node), title: (node.name as NSString).deletingPathExtension, depth: depth, groups: groups)
                            row.current = shows(url)
                            rows.append(row)
                        } else {
                            let folder = Row(kind: .folder(node, path: nodePath), title: node.name, depth: depth, groups: groups)
                            rows.append(folder)
                            let inner = "f/" + nodePath
                            if groupOpen(inner, expanded.contains(nodePath)) { add(node.children, depth: depth + 1, path: nodePath, groups: groups + [inner]) }
                        }
                    }
                }
                add(nodes, depth: 0, path: "", groups: [id])
            }
        }
        for k in rows.indices where rows[k].height == 0 { rows[k].height = rowHeight }
        self.rows = rows
        hovered = nil
        place()
        updateAccessibility()
        if !clock.isRunning, open.values.contains(where: { !$0.isSettled }) { kick() }
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
            open["f/" + path] = Spring(1, response: 0.42, damping: 0.92)
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
        if let id = rows[index].group, var spring = open[id] {
            // Rolling up is quicker and never springs back.
            let opening = spring.target == 0
            spring.response = opening ? 0.42 : 0.3
            spring.damping = opening ? 0.92 : 1
            open[id] = spring
        }
        reload()
    }

    /// The sidebar came into view: the list unrolls from the top of what shows (the current
    /// row was just scrolled into view; the list keeps its full height, so that scroll stays).
    func unroll() {
        beginUnrolling()
        kick()
    }

    private func beginUnrolling() {
        unrollTop = visibleRect.minY
        unrolling.snap(to: 0.12)
        unrolling.target = 1
    }

    private func kick() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil {
            for key in open.keys { open[key]!.snap() }
            unrolling.snap()
            settle()
        } else {
            clock.start()
        }
    }

    private func advance(_ dt: CGFloat) -> Bool {
        for key in open.keys { open[key]!.step(dt) }
        unrolling.step(dt)
        let moving = !unrolling.isSettled || open.values.contains { !$0.isSettled }
        if moving { place() } else { settle() }
        return moving
    }

    /// Motion done: rows of closed groups go, and hover help and VoiceOver take the rows' final
    /// places (the clock is still running on this last frame).
    private func settle() {
        if rows.contains(where: { row in row.groups.contains { open[$0]?.value == 0 } }) { reload() } else { place() }
        rebuildToolTips()
        updateAccessibility()
    }

    /// Advances the motion by `seconds` at once (snapshots).
    func stepForSnapshot(_ seconds: CGFloat, toggling index: Int? = nil, unrolling: Bool = false) {
        clock.stop()
        if let index { toggle(index) }
        if unrolling { beginUnrolling() }
        clock.stop()
        _ = advance(seconds)
    }

    // MARK: Placement

    /// How far a group of `height` shows when it is `p` open, and where a point `s` into it lies:
    /// flat up to the unrolled length, then on the roll (`scale` is its foreshortening).
    private static func unrolled(_ s: CGFloat, p: CGFloat, height: CGFloat) -> (y: CGFloat, scale: CGFloat) {
        if p >= 0.999 { return (s, 1) }
        if p <= 0.001 { return (0, 0) }
        let flat = p * height
        if s <= flat { return (s, 1) }
        let left = height - flat
        let r = Self.roll * min(1, left / (Self.roll * .pi / 2)) * min(1, p * 4)
        guard r > 0.5 else { return (flat, 0) }
        let phi = min((s - flat) / r, .pi / 2)
        return (flat + r * sin(phi), cos(phi))
    }

    private static func extent(p: CGFloat, height: CGFloat) -> CGFloat {
        if p >= 0.999 { return height }
        if p <= 0.001 { return 0 }
        let flat = p * height
        let left = height - flat
        let r = Self.roll * min(1, left / (Self.roll * .pi / 2)) * min(1, p * 4)
        guard r > 0.5 else { return flat }
        return flat + r * sin(min(left / r, .pi / 2))
    }

    /// Where every row is this frame: each group's content measured flat, then unrolled by its
    /// openness, inner groups first; the whole list unrolled by `unrolling` last.
    private func place() {
        var heights: [String: CGFloat] = [:]
        // Content height of the group at `level` that starts at row `i` (consumed).
        func measure(_ i: inout Int, level: Int) -> CGFloat {
            var h: CGFloat = 0
            while i < rows.count, rows[i].groups.count >= level {
                if rows[i].groups.count == level {
                    h += rows[i].height
                    i += 1
                } else {
                    let id = rows[i].groups[level]
                    let inner = measure(&i, level: level + 1)
                    heights[id] = inner
                    h += Self.extent(p: open[id]?.value ?? 1, height: inner)
                }
            }
            return h
        }
        var i = 0
        let total = measure(&i, level: 0)
        // Offsets: each row's flat offset in its innermost group, mapped outward group by group.
        var cursor: [String: CGFloat] = [:]
        var start: [String: CGFloat] = [:]
        var top: CGFloat = 0
        for k in rows.indices {
            let chain = rows[k].groups
            var s: CGFloat
            if let inner = chain.last {
                s = cursor[inner, default: 0]
                cursor[inner] = s + rows[k].height
            } else {
                s = top
                top += rows[k].height
            }
            // The row's middle, unrolled through its groups from the inside out.
            var y = s + rows[k].height / 2
            var scale: CGFloat = 1
            for level in stride(from: chain.count - 1, through: 0, by: -1) {
                let id = chain[level]
                let mapped = Self.unrolled(y, p: open[id]?.value ?? 1, height: heights[id] ?? 0)
                scale *= mapped.scale
                y = (start[id] ?? 0) + mapped.y
            }
            rows[k].y = y - rows[k].height / 2
            rows[k].scale = scale
            rows[k].alpha = scale
            // A group's content starts after its header, in its parent's flat offsets.
            if let id = rows[k].group {
                let parentOffset = chain.last.map { cursor[$0, default: 0] } ?? top
                start[id] = parentOffset
                cursor[id] = 0
                // The parent's cursor moves past the group's shown extent.
                let shown = Self.extent(p: open[id]?.value ?? 1, height: heights[id] ?? 0)
                if let parent = chain.last { cursor[parent, default: 0] += shown } else { top += shown }
            }
        }
        // Inner `start`s were recorded in their parent's flat offsets; they map outward above
        // through each level, since `start[id]` is applied before the parent's unrolling.
        if unrolling.value < 0.999 {
            let top = min(unrollTop, total)
            for k in rows.indices where rows[k].y + rows[k].height / 2 > top {
                let mapped = Self.unrolled(rows[k].y + rows[k].height / 2 - top, p: unrolling.value, height: total - top)
                rows[k].y = top + mapped.y - rows[k].height / 2
                rows[k].scale *= mapped.scale
                rows[k].alpha *= mapped.scale
            }
        }
        contentHeight = total + 12
        let height = max(contentHeight, enclosingScrollView?.contentView.bounds.height ?? 0)
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
        needsDisplay = true
        if !clock.isRunning { rebuildToolTips() }
    }

    // MARK: Drawing


    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let visible = visibleRect
        let scrolledTop = visible.minY > 0.5
        let moreBelow = visible.maxY < contentHeight - 0.5
        for (i, row) in rows.enumerated() {
            guard row.alpha > 0.01, row.y + row.height >= visible.minY - 2, row.y <= visible.maxY + 2 else { continue }
            // Turning away at an edge with more to scroll.
            var scale = row.scale, alpha = row.alpha
            let edge: CGFloat = 36
            let middle = row.y + row.height / 2
            if scrolledTop, middle - visible.minY < edge {
                let f = 1 - max(middle - visible.minY, 0) / edge
                scale *= cos(f * 1.05)
                alpha *= 1 - 0.8 * f
            }
            if moreBelow, visible.maxY - middle < edge {
                let f = 1 - max(visible.maxY - middle, 0) / edge
                scale *= cos(f * 1.05)
                alpha *= 1 - 0.8 * f
            }
            context.saveGState()
            context.setAlpha(min(1, alpha))
            // Foreshortened about the row's middle, receding a little toward the panel's center.
            let depth = 1 - 0.05 * (1 - scale)
            context.translateBy(x: bounds.midX, y: middle)
            context.scaleBy(x: depth, y: max(scale, 0.001))
            context.translateBy(x: -bounds.midX, y: -middle)
            drawRow(row, index: i, in: NSRect(x: 0, y: row.y, width: bounds.width, height: row.height))
            context.restoreGState()
        }
    }

    private func drawRow(_ row: Row, index i: Int, in rect: NSRect) {
        let hover = hovered == i
        let inset: CGFloat = 16
        // The bottom `rowHeight` of the rect holds the row; a header's gap is above it.
        let line = NSRect(x: rect.minX, y: rect.maxY - rowHeight, width: rect.width, height: rowHeight)
        switch row.kind {
        case let .header(section):
            let open = self.open["s." + section.rawValue]?.target == 1
            var x = inset
            let title = NSAttributedString(string: row.title, attributes: [.font: metrics.header, .foregroundColor: hover ? Tokens.ink2 : Tokens.ink3])
            let size = title.size()
            let maxTitle = line.width - inset - 70
            title.draw(with: NSRect(x: x, y: line.midY - size.height / 2, width: min(size.width, maxTitle), height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x += min(size.width, maxTitle) + 5
            // The chevron says the section folds; it shows under the pointer, or while folded.
            if hover || !open {
                let turn = self.open["s." + section.rawValue].map { $0.value } ?? 1
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
        case .page, .recent, .open, .file, .choose, .folder:
            var x = inset + CGFloat(row.depth) * 14
            if row.current || hover {
                (row.current ? Tokens.accent : Tokens.ink3.withAlphaComponent(0.6)).setFill()
                let h: CGFloat = row.current ? 14 : 10
                NSBezierPath(roundedRect: NSRect(x: 5, y: line.midY - h / 2, width: 3, height: h), xRadius: 1.5, yRadius: 1.5).fill()
            }
            if case let .folder(_, path) = row.kind {
                drawChevron(at: NSPoint(x: x + 4, y: line.midY), turn: open["f/" + path]?.value ?? 0, color: hover ? Tokens.ink2 : Tokens.ink3)
                x += 14
            } else if case .file = row.kind {
                x += 14
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
        let width = min(ceil(size.width), 110)
        (text as NSString).draw(with: NSRect(x: right - width, y: midY - size.height / 2, width: width, height: size.height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        return width
    }

    private func closeFrame(in line: NSRect) -> NSRect? {
        NSRect(x: line.maxX - 10 - 22, y: line.midY - 11, width: 22, height: 22)
    }

    private func accessories(of section: Section) -> [Accessory] {
        switch section {
        case .open: [.newDocument]
        case .pages: [.add]
        case .recent: []
        case .folder: rootName == nil ? [] : [.more, .search]
        }
    }

    private func symbol(of accessory: Accessory) -> String {
        switch accessory {
        case .add, .newDocument: "plus"
        case .search: "magnifyingglass"
        case .more: "ellipsis"
        case .close: "xmark"
        }
    }

    /// Accessories sit right to left from the header's trailing edge.
    private func accessory(at point: NSPoint, row i: Int) -> (Accessory, NSRect)? {
        let line = NSRect(x: 0, y: rows[i].y + rows[i].height - rowHeight, width: bounds.width, height: rowHeight)
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

    private func row(at point: NSPoint) -> Int? {
        rows.indices.first { rows[$0].alpha > 0.5 && point.y >= rows[$0].y + rows[$0].height - rowHeight && point.y < rows[$0].y + rows[$0].height }
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
        guard event.buttonNumber == 2, let i = row(at: convert(event.locationInWindow, from: nil)), case .open = rows[i].kind else { return super.otherMouseUp(with: event) }
        onClose?(rows[i].kind)
    }

    private func press(_ i: Int) {
        switch rows[i].kind {
        case .header, .folder: toggle(i)
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
        for (i, row) in rows.enumerated() where row.tooltip != nil && row.alpha > 0.5 {
            addToolTip(NSRect(x: 0, y: row.y + row.height - rowHeight, width: bounds.width, height: rowHeight), owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1))
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let i = row(at: point) else { return "" }
        return rows[i].tooltip ?? ""
    }

    private func updateAccessibility() {
        let elements: [NSAccessibilityElement] = rows.indices.map { i in
            let row = rows[i]
            let element = RowElement { [weak self] in self?.press(i) }
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(NSRect(x: 0, y: row.y, width: bounds.width, height: row.height))
            switch row.kind {
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
            element.setAccessibilityLabel(row.detail.map { "\(row.title), \($0)" } ?? row.title)
            return element
        }
        setAccessibilityChildren(elements)
    }

    /// The rows' titles as shown, for checks.
    var titlesForSnapshot: [String] { rows.map(\.title) }
    func indexForSnapshot(_ title: String) -> Int? { rows.firstIndex { $0.title == title } }
    /// The middle of that row's line, toward its right end (where a heading's actions are).
    func pointForSnapshot(_ title: String) -> NSPoint? {
        indexForSnapshot(title).map { NSPoint(x: bounds.width - 60, y: rows[$0].y + rows[$0].height - rowHeight / 2) }
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
