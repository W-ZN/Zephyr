import AppKit
import UniformTypeIdentifiers
import ZephyrCore
import ZephyrRender

/// The app's pages shown in place of a document. Folder Home and Activity are generated views;
/// custom pages remain ordinary Markdown notes. A user can also explicitly show an existing
/// Markdown document with the board presentation without Zephyr creating or rewriting a file.
enum SpacePanel: Hashable {
    case folderHome(URL)
    case activity
    /// A page of blocks: a note in `Space/Pages`.
    case board(URL)
    /// A user-chosen existing Markdown file shown with the board presentation.
    case markdown(URL)

    static let builtIn: [SpacePanel] = [.activity]
    /// Folder Home exists only with an explicit scope, followed by Activity and custom pages.
    @MainActor static func all(scopeRoot: URL?) -> [SpacePanel] {
        (scopeRoot.map { [.folderHome($0)] } ?? []) + builtIn + SpaceStore.shared.boards().map { .board($0) }
    }

    /// `overview`, `today`, `goals`, or a page's name or path (`-ZephyrPanel`).
    init?(name: String) {
        switch name {
        case "activity": self = .activity
        default:
            let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : Board.folder.appendingPathComponent(name.hasSuffix(".md") ? name : name + ".md")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            self = .board(url)
        }
    }

    var title: String {
        switch self {
        case .activity: String(localized: "Activity")
        case .folderHome: String(localized: "Folder Home")
        case let .board(url): MainActor.assumeIsolated { SpaceStore.shared.page(url).title } ?? url.deletingPathExtension().lastPathComponent
        case let .markdown(url): MainActor.assumeIsolated {
            let text = (try? Data(contentsOf: url)).map { SourceDecoder.decode($0).text } ?? ""
            return Board.page(in: text as NSString).title ?? url.deletingPathExtension().lastPathComponent
        }
        }
    }

    var symbol: String {
        switch self {
        case .activity: "chart.bar.xaxis"
        case .folderHome: "house"
        case let .board(url): MainActor.assumeIsolated { SpaceStore.shared.page(url).symbol } ?? "square.grid.2x2"
        case .markdown: "rectangle.3.group"
        }
    }

    /// The note behind the page; the overview only reads the others.
    @MainActor var note: URL? {
        switch self {
        case .folderHome, .activity: nil
        case let .board(url): url
        case let .markdown(url): url
        }
    }

    @MainActor func makePage(_ controller: DocumentWindowController) -> PanelPage {
        switch self {
        case let .folderHome(root): FolderHomePanel(controller, root: root)
        case .activity: ActivityPanel(controller)
        case let .board(url): BoardPanel(controller, url: url)
        case let .markdown(url): BoardPanel(controller, url: url, isSpaceBoard: false)
        }
    }
}

// MARK: - Page

/// A panel page: a centered column on the canvas, like a document's, with a large title, a line
/// of context under it, actions at its right, then sections. It reloads when shown, when the
/// window comes forward, and when its notes change.
class PanelPage: NSView {
    weak var controller: DocumentWindowController?
    let column = NSStackView()
    let heading: NSTextField
    let subtitle = flatLabel("", size: 13, color: Tokens.ink2)
    let actions = NSStackView()
    private let scroll = NSScrollView()
    private let preferredWidth: CGFloat
    private var columnWidth: NSLayoutConstraint!
    /// The identifier of a field to focus again once the sections are rebuilt (an entry that
    /// just added a line, which a reload replaces).
    var refocus: String?

    init(_ controller: DocumentWindowController, title: String, width: CGFloat = 680) {
        self.controller = controller
        preferredWidth = width
        heading = flatLabel(title, size: 28, weight: .bold)
        super.init(frame: .zero)
        let document = FlippedView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let titles = NSStackView(views: [heading, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4
        actions.spacing = 8
        // On a narrow window the actions give way (by their visibility priority) and the titles
        // truncate, rather than widening the window.
        actions.setClippingResistancePriority(NSLayoutConstraint.Priority(490), for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titles, NSView(), actions])
        header.alignment = .top
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(header)
        column.setCustomSpacing(28, after: header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        document.addSubview(column)
        // Below the window's own size: a page fits the window, it never widens it.
        columnWidth = column.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 44),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -96),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            columnWidth,
        ])
        document.translatesAutoresizingMaskIntoConstraints = false
        document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: SpaceStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        // Child fitting sizes must never become a window minimum. Size the reading column from
        // the actual viewport, including when a page replaces a document in a resized window.
        columnWidth.constant = max(0, min(preferredWidth, bounds.width - 64))
        super.layout()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Tokens.canvas.cgColor }
    }

    /// The page lies over the document's text: an arrow, not its I-beam. Fields and links set
    /// their own inside.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    @objc private func changed() { reload() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        if window != nil { reload() }
    }

    func reload() {}

    /// The sections after the header, replaced on every reload. What is typed in an entry and
    /// not yet added stays, and so does the entry being typed in (entries are known by their
    /// identifier), so a change elsewhere never takes a draft away.
    func setSections(_ views: [NSView]) {
        func entries(_ view: NSView) -> [EntryField] { (view as? EntryField).map { [$0] } ?? view.subviews.flatMap(entries) }
        let old = column.arrangedSubviews.dropFirst().flatMap(entries)
        var drafts: [String: String] = [:]
        var editing: (id: String, selection: NSRange)?
        for entry in old {
            guard let id = entry.field.identifier?.rawValue else { continue }
            if let editor = entry.field.currentEditor() { editing = (id, editor.selectedRange) }
            if !entry.text.isEmpty { drafts[id] = entry.text }
        }
        column.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
        for view in views {
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        let new = column.arrangedSubviews.dropFirst().flatMap(entries)
        for entry in new { if let id = entry.field.identifier?.rawValue, let draft = drafts[id] { entry.text = draft } }
        if let id = refocus ?? editing?.id, let entry = new.first(where: { $0.field.identifier?.rawValue == id }) {
            window?.makeFirstResponder(entry.field)
            if refocus == nil, let selection = editing?.selection, let editor = entry.field.currentEditor() {
                editor.selectedRange = NSRange(location: min(selection.location, (editor.string as NSString).length), length: 0)
            }
        }
        refocus = nil
    }

    /// A small label over a section, with room above it.
    func section(_ title: String, _ body: [NSView], spacing: CGFloat = 2) -> NSView {
        let label = flatLabel(title, size: 12, weight: .semibold, color: Tokens.ink3)
        let stack = NSStackView(views: [label] + body)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.setCustomSpacing(10, after: label)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 28, right: 0)
        for view in body { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    /// The assistant, asked about this page's note: the note opens with the chat beside it.
    func assistantButton(_ title: String, note: URL, prompt: String) -> FlatButton {
        let button = FlatButton(title: title, symbol: "sparkles", style: .text) { [weak self] in
            self?.controller?.askAssistant(about: note, prompt: prompt)
        }
        return button
    }

    func noteButton(_ note: URL) -> FlatButton {
        FlatButton(title: String(localized: "Open as Markdown"), symbol: "doc.text", style: .text) { [weak self] in
            self?.controller?.openSpaceNote(note)
        }
    }

    static func empty(_ text: String) -> NSView {
        let label = flatLabel(text, size: 13, color: Tokens.ink3, wraps: true)
        label.preferredMaxLayoutWidth = 520
        return label
    }
}

// MARK: - Folder Home and Activity

/// A native, generated view of the current scope. Selecting it does not create or change a
/// Markdown file; the reader can then choose a note to show as a board, whose direct controls are
/// separate, explicit edits.
final class FolderHomePanel: PanelPage {
    private let root: URL

    init(_ controller: DocumentWindowController, root: URL) {
        self.root = root
        super.init(controller, title: SpacePanel.folderHome(root).title, width: 920)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func reload() {
        guard controller?.scopeRoot?.standardizedFileURL == root.standardizedFileURL else {
            subtitle.stringValue = String(localized: "Choose this folder again to show its current files.")
            setSections([Self.empty(String(localized: "This Folder Home belongs to a scope that is no longer active."))])
            return
        }
        let files = controller?.scopedFiles ?? []
        subtitle.stringValue = files.isEmpty ? String(localized: "This folder has no Markdown files yet.") : String(localized: "\(files.count) Markdown files in \(root.lastPathComponent)")
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions.addArrangedSubview(FlatButton(title: String(localized: "Show as Page…"), symbol: "rectangle.3.group", style: .text) { [weak self] in self?.choosePage() })
        let root = root
        actions.addArrangedSubview(FlatButton(title: String(localized: "Show in Finder"), symbol: "folder", style: .text) { NSWorkspace.shared.activateFileViewerSelecting([root]) })

        let homeNames = Set(["readme.md", "index.md"])
        let homes = files.filter { !$0.relativePath.contains("/") && homeNames.contains($0.name.lowercased()) }
        var sections: [NSView] = []
        if !homes.isEmpty { sections.append(section(String(localized: "Home notes"), homes.map(fileRow))) }
        let grouped = Dictionary(grouping: files.filter { !homes.contains($0) }) { (file: ScopeFile) -> String in
            let folder = (file.relativePath as NSString).deletingLastPathComponent
            return folder == "." ? String(localized: "Files") : folder
        }
        for group in grouped.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            sections.append(section(group, (grouped[group] ?? []).map(fileRow)))
        }
        if sections.isEmpty { sections.append(Self.empty(String(localized: "Add a Markdown file to this folder to see it here."))) }
        setSections(sections)
    }

    private func fileRow(_ file: ScopeFile) -> NSView {
        LinkRow(title: file.name, target: file.url) { [weak self] newTab in self?.controller?.navigate(to: file.url, alongside: true) }
    }

    private func choosePage() {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = FolderScanner.markdownExtensions.compactMap { UTType(filenameExtension: $0) }
        picker.directoryURL = root
        picker.message = String(localized: "Choose a Markdown file to show as a page")
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            self?.controller?.showAsPage(url)
        }
    }
}

/// Activity is intentionally observational: visits, successful saves and explicit scope refreshes
/// only. There is no file watcher, scheduler or content cache behind this heatmap.
final class ActivityPanel: PanelPage {
    init(_ controller: DocumentWindowController) {
        super.init(controller, title: SpacePanel.activity.title, width: 920)
        NotificationCenter.default.addObserver(self, selector: #selector(recentFoldersChanged), name: Preferences.recentRootsDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func recentFoldersChanged() { reload() }

    override func reload() {
        let days = SpaceStore.shared.activityHistory(days: 365)
        let opened = days.reduce(0) { $0 + $1.opened.count }
        let changes = days.reduce(0) { $0 + $1.observedChanges }
        let saturated = days.contains(where: \.saturated)
        subtitle.stringValue = String(localized: "Files you opened and changed.")
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if controller?.scopeRoot != nil {
            actions.addArrangedSubview(FlatButton(title: String(localized: "Refresh Folder"), symbol: "arrow.clockwise", style: .text) { [weak self] in self?.controller?.refreshActivityScope() })
        }
        let tiles = NSStackView(views: [
            StatTile(value: opened.formatted() + (saturated ? "+" : ""), label: String(localized: "Unique files opened")),
            StatTile(value: changes.formatted(), label: String(localized: "Observed file changes")),
        ])
        tiles.distribution = .fillEqually
        tiles.spacing = 36
        let limit = saturated ? " " + String(localized: "A busy day reached the activity storage limit, so its totals are shown with +.") : ""
        let note = Self.empty(String(localized: "Changes count on save and Refresh Folder, once per file a day. Nothing runs in the background.") + limit)
        // Where the reader worked lately, one click from working there again (in this window), two
        // to a line like the figures; after the record, which is what the page is about.
        let folders: [NSView] = Preferences.recentRootURLs.prefix(4).map { url in
            LinkRow(title: url.lastPathComponent, target: url) { [weak self] _ in self?.controller?.openFolder(url) }
        }
        let lines = stride(from: 0, to: folders.count, by: 2).map { i -> NSView in
            let line = NSStackView(views: [folders[i], i + 1 < folders.count ? folders[i + 1] : NSView()])
            line.distribution = .fillEqually
            line.spacing = 36
            line.alignment = .top
            return line
        }
        let recent = lines.isEmpty ? [] : [section(String(localized: "Recent Folders"), lines)]
        setSections([tiles, section(String(localized: "Last 365 days"), [ActivityHeatmap(days)]), note] + recent)
        column.setCustomSpacing(28, after: tiles)
        column.setCustomSpacing(40, after: note)
    }
}

/// A GitHub-like calendar: each cell is one local day, shaded by unique opens plus observed file
/// changes; each column is a week from the locale's first weekday, top to bottom, so the current
/// week is the last, partial column. Pointer and accessibility text reveal the exact daily totals.
final class ActivityHeatmap: NSView {
    private let days: [Activity.Day]
    /// Empty slots before the first day, so every day lands on its weekday's row.
    private let lead: Int
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(_ days: [Activity.Day]) {
        self.days = days
        let calendar = Calendar.current
        let parts = days.last?.date.split(separator: "-").compactMap { Int($0) } ?? []
        let last = parts.count == 3 ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) : nil
        let lastRow = ((last.map { calendar.component(.weekday, from: $0) } ?? calendar.firstWeekday) - calendar.firstWeekday + 7) % 7
        lead = ((lastRow - (days.count - 1)) % 7 + 7) % 7
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 132).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(days.map { String(localized: "\($0.date): \($0.opened.count) opened, \($0.observedChanges) changes") }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError() }

    private let cellSize: CGFloat = 15
    private let gap: CGFloat = 3
    var visibleColumns: Range<Int> {
        let total = max((lead + days.count + 6) / 7, 1)
        let count = min(total, max(0, Int((bounds.width + gap) / (cellSize + gap))))
        return (total - count)..<total
    }

    func cellRect(at index: Int) -> NSRect? {
        let slot = lead + index
        guard days.indices.contains(index), visibleColumns.contains(slot / 7) else { return nil }
        return NSRect(x: CGFloat(slot / 7 - visibleColumns.lowerBound) * (cellSize + gap),
                      y: CGFloat(6 - slot % 7) * (cellSize + gap) + 8, width: cellSize, height: cellSize)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        hovered = nil
        toolTip = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let maxValue = max(days.map(\.total).max() ?? 0, 1)
        for (index, day) in days.enumerated() {
            guard let rect = cellRect(at: index) else { continue }
            let value = day.total
            let strength = value == 0 ? 0.08 : 0.22 + 0.78 * CGFloat(value) / CGFloat(maxValue)
            Tokens.accent.withAlphaComponent(hovered == nil || hovered == index ? strength : strength * 0.55).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hovered = days.indices.first { cellRect(at: $0)?.contains(p) == true }
        if let index = hovered {
            let day = days[index]
            toolTip = String(localized: "\(day.date): \(day.opened.count) opened · \(day.added.count) added · \(day.modified.count) changed · \(day.removed.count) removed")
        } else {
            toolTip = nil
        }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }
}

/// A field that runs `onSubmit` with its text on Return, then clears.
final class EntryField: NSView, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    private let box: FieldBox
    var field: NSTextField { box.field }

    /// What is typed, also while it is being typed.
    var text: String {
        get { field.currentEditor()?.string ?? field.stringValue }
        set {
            field.stringValue = newValue
            box.textDidChangeProgrammatically()
        }
    }

    /// `quiet`: no box, only the plus and the placeholder (an entry at the end of a block).
    init(placeholder: String, quiet: Bool = false, id: String? = nil) {
        box = FieldBox(placeholder: placeholder, symbol: "plus")
        super.init(frame: .zero)
        box.isQuiet = quiet
        box.field.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
        box.field.delegate = self
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor), box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor), box.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: quiet ? 30 : 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(insertNewline(_:)) else { return false }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        field.stringValue = ""
        box.textDidChangeProgrammatically()
        onSubmit?(text)
        return true
    }
}

/// One task: a round check, its time when it has one, its text. A click on the check toggles it;
/// a click on the text opens the note at that line.
final class TaskRow: NSView {
    private let check: TaskCheck
    private var hovering = false { didSet { needsDisplay = true } }
    private let onOpen: () -> Void

    init(item: Space.Item, timed: Bool, onToggle: @escaping () -> Void, onOpen: @escaping () -> Void) {
        check = TaskCheck(done: item.done, action: onToggle)
        self.onOpen = onOpen
        super.init(frame: .zero)
        let format: (Int) -> String = { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
        let text = NSMutableAttributedString(string: item.text, attributes: [.font: Tokens.font(14), .foregroundColor: item.done ? Tokens.ink3 : Tokens.ink])
        if item.done { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: text.length)) }
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [check]
        if timed, let start = item.start {
            let time = flatLabel(format(start) + (item.end.map { "–" + format($0) } ?? ""), size: 13, color: item.done ? Tokens.ink3 : Tokens.ink2)
            time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            time.widthAnchor.constraint(equalToConstant: 96).isActive = true
            views.append(time)
        }
        views.append(label)
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.setCustomSpacing(12, after: check)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 34),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.text)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Tokens.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onOpen() }
    override func accessibilityPerformPress() -> Bool {
        onOpen()
        return true
    }
}

/// A round check: an outline ring, or filled with the accent and a check mark.
final class TaskCheck: NSView {
    private let done: Bool
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(done: Bool, action: @escaping () -> Void) {
        self.done = done
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(done)
    }

    /// A pointing hand, as on a checkbox in a document.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        if done {
            Tokens.accent.setFill()
            ring.fill()
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 5.2, y: 9.2))
            mark.line(to: NSPoint(x: 7.9, y: 6.4))
            mark.line(to: NSPoint(x: 12.9, y: 11.8))
            mark.lineWidth = 1.8
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            Tokens.onAccent.setStroke()
            mark.stroke()
        } else {
            (hovering ? Tokens.accent : Tokens.ink3).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// A progress meter: a neutral track and the accent fill, rounded ends.
final class Meter: NSView {
    private let value: Double

    init(value: Double, height: CGFloat = 6) {
        self.value = min(max(value, 0), 1)
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        Tokens.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        guard value > 0 else { return }
        Tokens.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * value), height: bounds.height), xRadius: r, yRadius: r).fill()
    }
}

/// A headline number, its label under it; no tile behind it, as a page's figures (`NumberTile`).
final class StatTile: SurfaceView {
    init(value: String, label: String) {
        super.init(fill: nil, border: nil, radius: 0)
        let number = flatLabel(value, size: 24, weight: .semibold)
        number.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        let stack = NSStackView(views: [number, flatLabel(label, size: 12, color: Tokens.ink2)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("\(label): \(value)")
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A label, a meter and a figure on one line.
final class MeterRow: NSView {
    init(title: String, value: Double, detail: String) {
        super.init(frame: .zero)
        let name = flatLabel(title, size: 13)
        name.lineBreakMode = .byTruncatingTail
        let figure = flatLabel(detail, size: 12, color: Tokens.ink2)
        figure.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        figure.alignment = .right
        let meter = Meter(value: value)
        for v in [name, meter, figure] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            name.leadingAnchor.constraint(equalTo: leadingAnchor), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.36),
            meter.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 12), meter.centerYAnchor.constraint(equalTo: centerYAnchor),
            figure.leadingAnchor.constraint(equalTo: meter.trailingAnchor, constant: 12), figure.trailingAnchor.constraint(equalTo: trailingAnchor),
            figure.centerYAnchor.constraint(equalTo: centerYAnchor), figure.widthAnchor.constraint(equalToConstant: 64),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("\(title): \(detail)")
    }

    required init?(coder: NSCoder) { fatalError() }
}
