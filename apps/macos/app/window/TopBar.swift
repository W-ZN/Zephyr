import AppKit
import ZephyrCore
import ZephyrRender

/// The window's top bar (design §8.2), drawn by Zephyr in the title bar area in the canvas color.
/// Left: the sidebar button and the file path, drawn as text on the bar itself (no boxes): a folder
/// opens a menu of its Markdown files and subfolders to move between documents; a double click on
/// the file's name renames it in place, and names an untitled document. Right: agent
/// access while it is on, so sharing is never silent (design §11), the text's statistics, and the
/// outline. The assistant is not here: it floats at the bottom right, over the text.
final class TopBar: NSView, NSTextFieldDelegate {
    weak var controller: DocumentWindowController?
    private let sidebarButton = ChromeButton(symbol: "sidebar.leading")
    private let crumbs = NSStackView()
    private let agents = ChromeButton(title: String(localized: "Agents"), symbol: "dot.radiowaves.left.and.right")
    private var leading: NSLayoutConstraint!
    let stats = ChromeButton()
    let outlineButton = ChromeButton(symbol: "list.bullet")
    private var fileCrumb: PathCrumb?
    private var renaming: NSLayoutConstraint?
    private var renameCancelled = false

    static let minimumHeight: CGFloat = 38

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sidebarButton.toolTip = String(localized: "Show the folder scope")
        sidebarButton.setAccessibilityLabel(String(localized: "Sidebar"))
        sidebarButton.target = nil
        sidebarButton.action = #selector(DocumentWindowController.toggleScopeSidebar(_:))
        // The count of open documents beside it (`setOpenCount`) leaves the symbol as it is.
        sidebarButton.symbolSize = 14
        sidebarButton.titleFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        crumbs.spacing = 6
        crumbs.setAccessibilityLabel(String(localized: "Document path and folder scope"))
        crumbs.setContentHuggingPriority(.required, for: .horizontal)
        crumbs.setClippingResistancePriority(.defaultLow, for: .horizontal)
        agents.toolTip = String(localized: "Agents can read this document and propose changes")
        agents.target = self
        agents.action = #selector(showAgentMenu)
        agents.isHidden = true
        // A menu, so it says so: a small chevron after the count.
        stats.titleFont = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        stats.symbolName = "chevron.down"
        stats.symbolSize = 8
        stats.trailingSymbol = true
        stats.target = nil
        stats.action = #selector(DocumentWindowController.showStatistics(_:))
        stats.setAccessibilityLabel(String(localized: "Text statistics"))
        stats.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        outlineButton.toolTip = String(localized: "Outline (⌃⌘2)")
        outlineButton.setAccessibilityLabel(String(localized: "Outline"))
        outlineButton.target = nil
        outlineButton.action = #selector(DocumentWindowController.showOutlineTab(_:))
        let row = NSStackView(views: [sidebarButton, crumbs, NSView(), agents, stats, outlineButton])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        leading = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 80)
        NSLayoutConstraint.activate([
            leading,
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Tokens.canvas.cgColor }
    }

    // AppKit moves the window on a drag. DocumentWindow owns blank-space double clicks,
    // including the upper strip where AppKit consumes mouseUp before it reaches this view.
    override var mouseDownCanMoveWindow: Bool { true }

    func isBlank(at windowPoint: NSPoint) -> Bool {
        guard !isHidden, bounds.contains(convert(windowPoint, from: nil)) else { return false }
        if [sidebarButton, agents, stats, outlineButton].contains(where: { !$0.isHidden && $0.bounds.contains($0.convert(windowPoint, from: nil)) }) { return false }
        return !crumbs.bounds.contains(crumbs.convert(windowPoint, from: nil))
    }

    func pathCrumb(at windowPoint: NSPoint) -> PathCrumb? {
        guard let crumb = fileCrumb, !isHidden, crumb.bounds.contains(crumb.convert(windowPoint, from: nil)) else { return nil }
        return crumb
    }

    func ownsFieldEditor(_ view: NSView) -> Bool {
        guard let editor = fileCrumb?.currentEditor() as? NSTextView else { return false }
        return view === editor || view.isDescendant(of: editor)
    }

    /// Clears the traffic lights, or the window edge in full screen.
    override func layout() {
        super.layout()
        guard let window else { return }
        var inset: CGFloat = 12
        if !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton), let superview = zoom.superview, !zoom.isHidden {
            inset = convert(superview.convert(zoom.frame, to: nil), from: nil).maxX + 14
        }
        if abs(leading.constant - inset) > 0.5 { leading.constant = inset }
    }

    /// Folders from the scope root down to the file's folder, then the file. A folder opens its
    /// menu (`FolderMenu`): the documents beside, subfolders, and the folder in the sidebar.
    func setPath(folders: [(name: String, url: URL)], scopeRoot: URL?, file: String) {
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stats.isHidden = statsTitle.isEmpty
        var shown = folders
        if shown.count > 3 { shown = Array(shown.suffix(3)) }
        if shown.count < folders.count { crumbs.addArrangedSubview(separator("…")) }
        for folder in shown {
            let crumb = PathCrumb(folder.name, kind: .folder)
            crumb.toolTip = folder.url.path
            crumb.onPress = { [weak self, weak crumb] in
                guard let self, let crumb, let controller = self.controller else { return }
                FolderMenu(folder: folder.url, controller: controller).popUp(below: crumb)
            }
            crumbs.addArrangedSubview(crumb)
            crumbs.addArrangedSubview(separator("/"))
        }
        let crumb = PathCrumb(file, kind: .file)
        crumb.toolTip = String(localized: "Double-click to rename")
        crumb.onPress = { [weak self] in self?.beginRename() }
        crumb.delegate = self
        crumb.menu = fileMenu()
        crumbs.addArrangedSubview(crumb)
        fileCrumb = crumb
        renaming = nil
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu()
        let rename = NSMenuItem(title: String(localized: "Rename"), action: #selector(DocumentWindowController.renameFromMenu(_:)), keyEquivalent: "")
        rename.target = controller
        menu.addItem(rename)
        menu.addItem(.separator())
        let finder = NSMenuItem(title: String(localized: "Show in Finder"), action: #selector(DocumentWindowController.showInFinder(_:)), keyEquivalent: "")
        finder.target = controller
        menu.addItem(finder)
        return menu
    }

    /// An app page instead of a path: its symbol and name, nothing to rename, no text to count.
    /// Nil while a new place in the window shows nothing yet.
    func setPage(_ panel: SpacePanel?) {
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fileCrumb = nil
        renaming = nil
        stats.isHidden = true
        guard let panel else { return }
        if let image = Tokens.symbol(panel.symbol, size: 13, weight: .medium, color: Tokens.ink2) { crumbs.addArrangedSubview(NSImageView(image: image)) }
        crumbs.addArrangedSubview(PathCrumb(panel.title, kind: .file))
    }

    /// With more than one document open in the window and nothing else listing them (the sidebar
    /// and the quick switcher hidden), their number sits beside the sidebar button.
    func setOpenCount(_ count: Int?) {
        let title = count.map { "\($0)" } ?? ""
        guard title != sidebarButton.title else { return }
        sidebarButton.setTitle(title)
        sidebarButton.setAccessibilityLabel(count.map { String(localized: "Sidebar, \($0) documents open") } ?? String(localized: "Sidebar"))
    }

    // MARK: Renaming

    /// The name itself becomes editable, with only a caret: Return renames (or saves an untitled
    /// document), Esc keeps it, a click elsewhere renames.
    func beginRename() {
        guard renaming == nil, let crumb = fileCrumb else { return }
        crumb.stringValue = controller?.fileURL?.lastPathComponent ?? crumb.stringValue
        renameCancelled = false
        let width = crumb.widthAnchor.constraint(equalToConstant: 0)
        width.isActive = true
        renaming = width
        fitRename()
        crumb.beginEditing()
        // The name without its extension is selected, ready to type over.
        let stem = ((crumb.stringValue as NSString).deletingPathExtension as NSString).length
        crumb.currentEditor()?.selectedRange = NSRange(location: 0, length: stem)
    }

    private func fitRename() {
        guard let crumb = fileCrumb, let renaming else { return }
        let text = (crumb.currentEditor()?.string ?? crumb.stringValue) as NSString
        renaming.constant = min(max(ceil(text.size(withAttributes: [.font: crumb.font!]).width) + 12, 40), 420)
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === fileCrumb { fitRename() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === fileCrumb, selector == #selector(cancelOperation(_:)) else { return false }
        renameCancelled = true
        window?.endEditing(for: control)
        window?.makeFirstResponder(controller?.editor?.focusView)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let crumb = fileCrumb, obj.object as? NSTextField === crumb, let renaming else { return }
        renaming.isActive = false
        self.renaming = nil
        let name = crumb.stringValue
        crumb.endEditing(showing: controller?.markdownDocument?.displayName ?? name)
        layoutSubtreeIfNeeded()
        if !renameCancelled { controller?.renameDocument(to: name) }
    }

    // MARK: Assistant

    /// The count the reader chose, or the selection's.
    func setStatistics(_ title: String, help: String) {
        statsTitle = title
        stats.setTitle(title)
        stats.toolTip = help
        stats.isHidden = title.isEmpty || fileCrumb == nil
    }

    private var statsTitle = ""

    private func separator(_ text: String) -> NSTextField {
        let label = flatLabel(text, size: 13, color: Tokens.ink3)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// Shown while agents may read this document; `root` is the folder they may also read.
    func setAgentAccess(_ on: Bool, root: URL?) {
        agents.isHidden = !on
        agents.emphasized = on
        agentScope = root
        agents.toolTip = Self.agentSummary(root)
    }

    private var agentScope: URL?

    static func agentSummary(_ root: URL?) -> String {
        root.map { String(localized: "Agents can read this document and the files in \($0.lastPathComponent), and propose changes") }
            ?? String(localized: "Agents can read this document and propose changes")
    }

    @objc private func showAgentMenu() {
        let menu = NSMenu()
        let info = NSMenuItem(title: Self.agentSummary(agentScope), action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Copy Session ID")) { [weak self] in
            guard let grant = AgentAccess.shared.grant(for: self?.controller?.markdownDocument) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(grant.id, forType: .string)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "Stop Agent Access")) { [weak self] in
            if let doc = self?.controller?.markdownDocument { AgentAccess.shared.revoke(doc) }
        })
        menu.popUp(below: agents)
    }
}

/// A piece of the path as text on the bar (design §8.2: the bar is the window, not a row of
/// boxes). Folders are secondary ink and darken under the pointer; the file is ink, medium. A
/// folder acts on press, like a menu; the file on a double click, when the same text becomes
/// editable in place with no field drawn around it.
final class PathCrumb: NSTextField {
    enum Kind { case folder, file }
    let kind: Kind
    var onPress: (() -> Void)?
    private var hovering = false { didSet { restyle() } }

    init(_ title: String, kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        stringValue = title
        isBordered = false
        isBezeled = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        focusRingType = .none
        lineBreakMode = .byTruncatingMiddle
        cell?.usesSingleLineMode = true
        font = Tokens.font(13, kind == .file ? .medium : .regular)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(kind == .file ? .defaultLow : .defaultLow - 1, for: .horizontal)
        setAccessibilityRole(kind == .folder ? .popUpButton : .staticText)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        textColor = kind == .file || hovering ? Tokens.ink : Tokens.ink2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    override func mouseEntered(with event: NSEvent) { if kind == .folder { hovering = true } }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard !isEditable else { return super.mouseDown(with: event) }
        switch kind {
        case .folder: onPress?()
        case .file: if event.clickCount == 2 { onPress?() }
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func resetCursorRects() {
        if isEditable { addCursorRect(bounds, cursor: .iBeam) }
    }

    func beginEditing() {
        isEditable = true
        isSelectable = true
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    func endEditing(showing title: String) {
        isEditable = false
        isSelectable = false
        stringValue = title
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: self)
    }
}

/// A folder's menu from the path: its Markdown documents (the open one checked) and subfolders,
/// each a submenu filled when opened; then the folder in the sidebar, or in Finder. Choosing a
/// document goes there in this window, or in a new tab with ⌘.
final class FolderMenu: NSObject, NSMenuDelegate {
    private let folder: URL
    private weak var controller: DocumentWindowController?
    private let menu = NSMenu()

    init(folder: URL, controller: DocumentWindowController) {
        self.folder = folder
        self.controller = controller
        super.init()
        fill(menu, with: folder, top: true)
    }

    func popUp(below view: NSView) {
        // The menu holds this object for as long as it is open.
        objc_setAssociatedObject(menu, &Self.key, self, .OBJC_ASSOCIATION_RETAIN)
        menu.popUp(below: view)
    }

    private static var key = 0

    private func entries(_ folder: URL) -> (folders: [URL], files: [URL]) {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var folders: [URL] = [], files: [URL] = []
        for url in items {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if !FolderScanner.skippedDirectories.contains(url.lastPathComponent) { folders.append(url) }
            } else if FolderScanner.markdownExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        let byName: (URL, URL) -> Bool = { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (folders.sorted(by: byName), files.sorted(by: byName))
    }

    private func fill(_ menu: NSMenu, with folder: URL, top: Bool) {
        menu.removeAllItems()
        let (folders, files) = entries(folder)
        let current = controller?.fileURL?.standardizedFileURL
        for file in files {
            let item = ClosureMenuItem(title: file.deletingPathExtension().lastPathComponent) { [weak self] in
                self?.controller?.navigate(to: file, alongside: true)
            }
            item.image = Tokens.symbol("doc.text", size: 12, color: Tokens.ink2)
            item.state = file.standardizedFileURL == current ? .on : .off
            item.toolTip = file.lastPathComponent
            menu.addItem(item)
        }
        if !folders.isEmpty, !files.isEmpty { menu.addItem(.separator()) }
        for sub in folders {
            let item = NSMenuItem(title: sub.lastPathComponent, action: nil, keyEquivalent: "")
            item.image = Tokens.symbol("folder", size: 12, color: Tokens.ink2)
            let submenu = NSMenu()
            submenu.delegate = self
            submenu.identifier = NSUserInterfaceItemIdentifier(sub.path)
            submenu.addItem(NSMenuItem(title: "…", action: nil, keyEquivalent: ""))
            item.submenu = submenu
            menu.addItem(item)
        }
        if files.isEmpty, folders.isEmpty {
            let none = NSMenuItem(title: String(localized: "No Markdown files"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        guard top else { return }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Open in Sidebar")) { [weak self] in
            guard let self else { return }
            self.controller?.showFolderInSidebar(self.folder)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "Show in Finder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.folder])
        })
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let path = menu.identifier?.rawValue else { return }
        fill(menu, with: URL(fileURLWithPath: path), top: false)
    }
}
