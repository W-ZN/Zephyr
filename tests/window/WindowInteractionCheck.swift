import AppKit
import ZephyrRender

/// The app's bundle declares Markdown's document type; this check runs without one.
final class CheckDocumentController: NSDocumentController {
    override func typeForContents(of url: URL) throws -> String { "net.daringfireball.markdown" }
    override func documentClass(forType typeName: String) -> AnyClass? { MarkdownDocument.self }
}

@main
struct WindowInteractionCheck {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        // The first document controller made is the shared one.
        _ = CheckDocumentController()
        NSApp.setActivationPolicy(.accessory)
        Preferences.register()
        // These checks start each window without the sidebar and show it themselves.
        UserDefaults.standard.set(false, forKey: Preferences.sidebarVisible)
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        let delegate = AppDelegate()
        let menu = MainMenu.build(delegate: delegate)
        let fileMenu = menu.items.compactMap(\.submenu).first { $0.identifier == MainMenu.fileMenuID }!
        let ownedItems = fileMenu.items
        fileMenu.addItem(NSMenuItem(title: "Injected Rename", action: nil, keyEquivalent: ""))
        delegate.menuNeedsUpdate(fileMenu)
        precondition(fileMenu.items == ownedItems, "File menu retained an injected document command")
        precondition(fileMenu.items.filter { $0.action == #selector(ExportCommand.exportDocument(_:)) }.count == 1)
        // The File menu is where the GUI grants agents a session for the shown document (design §11).
        precondition(fileMenu.items.contains { $0.action == #selector(DocumentWindowController.toggleAgentAccess(_:)) }, "The File menu offers no agent access")
        let note = URL(fileURLWithPath: "/tmp/Zephyr/home.md")
        precondition(BoardPanel.resolve("#section", from: note)?.fragment == "section")
        precondition(BoardPanel.resolve("other.md#part", from: note)?.path == "/tmp/Zephyr/other.md")
        precondition(BoardPanel.resolve("other.md#part", from: note)?.fragment == "part")
        precondition(BoardPanel.resolve("https://example.com/docs#part", from: note)?.fragment == "part")

        let document = MarkdownDocument()
        try document.read(from: Data("# Window check\n\nBody.\n".utf8), ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        document.addWindowController(controller)
        let window = controller.window as! DocumentWindow
        let canvas = window.contentViewController as! CanvasViewController
        window.isReleasedWhenClosed = false
        defer { window.close() }

        func click(_ point: NSPoint, count: Int) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(event)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        /// NSTextView tracks synchronously from mouseDown until it receives mouseUp. Queue the up
        /// event before handing it the down event, as AppKit's normal event loop would.
        func trackedClick(_ point: NSPoint, count: Int) {
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 0)!
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func blankPoint(in bar: TopBar, depth: CGFloat) -> NSPoint {
            let y = bar.bounds.maxY - depth
            for x in stride(from: bar.bounds.midX, through: bar.bounds.maxX - 80, by: 4) {
                let point = bar.convert(NSPoint(x: x, y: y), to: nil)
                if bar.isBlank(at: point) { return point }
            }
            for x in stride(from: bar.bounds.midX - 4, through: 240, by: -4) {
                let point = bar.convert(NSPoint(x: x, y: y), to: nil)
                if bar.isBlank(at: point) { return point }
            }
            preconditionFailure("No blank title-bar point")
        }

        for screen in NSScreen.screens {
            let available = screen.visibleFrame
            let original = NSRect(x: available.minX + 60, y: available.minY + 60, width: min(720, available.width - 120), height: min(620, available.height - 120))
            window.setFrame(original, display: false)
            window.contentView?.layoutSubtreeIfNeeded()
            for depth: CGFloat in [2, 20, 36] {
                let bar = canvas.topBar
                let point = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.maxY - depth), to: nil)
                precondition(bar.isBlank(at: point))
                click(point, count: 2)
                precondition(window.frame == available, "Top-bar depth \(depth): did not fill \(available), got \(window.frame)")
                precondition(!window.styleMask.contains(.fullScreen))
                let restorePoint = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.maxY - depth), to: nil)
                click(restorePoint, count: 2)
                precondition(window.frame == original, "Top-bar depth \(depth): did not restore \(original), got \(window.frame)")
            }
            print("Top-bar expand/restore passed on \(available): depths 2, 20, 36 pt, exact original frame \(original).")
        }

        // Button routing preserves activation, which requires an ordered AppKit window.
        // Keep the fixture behind other apps and off the desktop for these checks.
        window.orderBack(nil)
        window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
        window.contentView?.layoutSubtreeIfNeeded()
        func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
        }
        let sidebar = views(canvas.topBar, of: ChromeButton.self).first { $0.symbolName == "sidebar.leading" }!
        // A command-line fixture has no active application's responder chain.
        sidebar.target = controller
        let point = sidebar.convert(NSPoint(x: sidebar.bounds.midX, y: sidebar.bounds.midY), to: nil)
        let original = window.frame
        precondition(!canvas.topBar.isBlank(at: point))
        click(point, count: 1)
        precondition(canvas.isSidebarVisible)
        click(point, count: 2)
        precondition(!canvas.isSidebarVisible)
        precondition(window.frame == original, "Sidebar double click changed the window frame")

        let screen = NSScreen.screens[0]
        let available = screen.visibleFrame
        let titleFrame = NSRect(x: available.minX + 60, y: available.minY + 60, width: min(720, available.width - 120), height: min(620, available.height - 120))
        window.setFrame(titleFrame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let crumb = views(canvas.topBar, of: PathCrumb.self).first!
        let crumbPoint = crumb.convert(NSPoint(x: crumb.bounds.midX, y: crumb.bounds.midY), to: nil)
        precondition(!canvas.topBar.isBlank(at: crumbPoint))
        // Round 33: the filename menu offers rename and Finder, no agent access.
        precondition(crumb.menu?.items.contains { $0.action == #selector(DocumentWindowController.renameFromMenu(_:)) && $0.target === controller } == true,
                     "Filename context menu has no Rename action")
        precondition(crumb.menu?.items.contains { $0.action == #selector(DocumentWindowController.toggleAgentAccess(_:)) } == false,
                     "Filename context menu still offers agent access")
        let crumbFrame = window.frame
        click(crumbPoint, count: 2)
        precondition(crumb.isEditable, "Filename double click did not begin renaming")
        precondition(window.frame == crumbFrame, "Filename double click changed the window frame")
        guard let editor = crumb.currentEditor() as? NSTextView else { preconditionFailure("Filename has no field editor") }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        trackedClick(crumbPoint, count: 2)
        precondition(editor.selectedRange().length > 0, "Editable filename double click did not select text")
        precondition(window.frame == crumbFrame, "Editable filename double click changed the window frame")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
        window.sendEvent(escape)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        precondition(!crumb.isEditable, "Escape did not end filename editing")
        let blank = canvas.topBar.convert(NSPoint(x: min(550, canvas.topBar.bounds.maxX - 120), y: canvas.topBar.bounds.maxY - 20), to: nil)
        precondition(canvas.topBar.isBlank(at: blank), "Filename bounds cover a visibly blank title-bar point after Escape")
        click(blank, count: 2)
        precondition(window.frame == available, "Blank title bar did not zoom after filename editing")
        let restorePoint = blankPoint(in: canvas.topBar, depth: 20)
        click(restorePoint, count: 2)
        precondition(window.frame == titleFrame, "Blank title bar did not restore after filename editing")
        canvas.setMinimal(true)
        precondition(!canvas.topBar.isBlank(at: point))
        print("Sidebar and filename double clicks preserve the window frame; blank title-bar clicks zoom and restore.")
        canvas.setMinimal(false)
        try checkOpenDocuments()
        try checkOpeningFiles()
        try checkRestorableState()
        checkSettingsDisclosure()
        checkSidebarRoom()
        checkExportOptions()
        checkInterfaceFont()
        checkExportPanelWidth()
        if ProcessInfo.processInfo.environment["GALLERY"] != nil { try captureGallery() }
    }

    static func untitled(_ text: String) throws -> MarkdownDocument {
        let document = MarkdownDocument()
        try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        NSDocumentController.shared.addDocument(document)
        return document
    }

    static func settle() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }

    @MainActor static func checkSettingsDisclosure() {
        let pane = ThemeSettingsPane()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 660, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        window.orderBack(nil)
        defer { window.close() }
        pane.view.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let button = buttons(pane.view).first { $0.title == String(localized: "Fonts and colors") }!
        let group = button.superview as! NSStackView
        let body = group.arrangedSubviews.last!
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: button.superview)
        precondition(button.hitTest(point) === button, "Disclosure header is not clickable in its real position")
        let label = button.subviews.compactMap { $0 as? NSTextField }.first!
        precondition(label.alignmentRect(forFrame: label.frame).minX >= 28, "Disclosure title crowds its 12 pt chevron slot")
        func toggle() { _ = NSApp.sendAction(button.action!, to: button.target, from: button) }
        let start = ProcessInfo.processInfo.systemUptime
        toggle()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(!body.isHidden && body.frame.height > 200, "Disclosure did not reveal its controls")
        precondition(button.isAccessibilityExpanded(), "Expanded disclosure lost its accessibility state")
        toggle()
        toggle()
        settle()
        precondition(!body.isHidden && button.isAccessibilityExpanded(), "Rapid reversal left the final disclosure closed")
        for width: CGFloat in [520, 860] {
            window.setContentSize(NSSize(width: width, height: 640))
            pane.view.layoutSubtreeIfNeeded()
            let contents = body.subviews.first!
            precondition(abs(contents.frame.height + 4 - body.frame.height) <= 1, "Resizing clips the disclosure's controls or leaves stale space")
        }
        toggle()
        settle()
        precondition(body.isHidden && !button.isAccessibilityExpanded(), "Collapsed controls remained visible")
        if let bitmap = group.bitmapImageRepForCachingDisplay(in: group.bounds) {
            group.cacheDisplay(in: group.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("settings-disclosure.png"))
            }
        }
        print("Settings disclosure: real-position hit test, separated chevron, rapid reversal and resize passed; first Fonts action took \(Int(elapsed * 1000)) ms.")
    }

    struct Missing: Error, CustomStringConvertible { let description: String }
    static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw Missing(description: what) }
        return value
    }

    /// Several documents in one window (design §7.8), pages that show over a document without
    /// taking a place in the Open list (round 39), the untitled document that is never replaced in
    /// place (round 37, item 5), and an empty untitled document that closes without asking (item 6).
    @MainActor static func checkOpenDocuments() throws {
        let scratch = try untitled("Scratch notes.\n")
        let controller = DocumentWindowController(document: scratch)
        scratch.addWindowController(controller)
        let window = controller.window!
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
        window.orderBack(nil)
        defer { window.close() }
        precondition(controller.tabs.count == 1 && controller.current.holdsUnsavedText, "An untitled document with text holds text that exists nowhere else")

        // A page shows over it in the same place; the untitled document stays open underneath and
        // is the only row in the Open section (pages are permanent places, not open documents).
        controller.open(panel: .activity)
        precondition(controller.tabs.count == 1 && controller.openTabs.count == 1, "The page took a place of its own")
        precondition(controller.current.panel == .activity && controller.current.document === scratch, "The page did not show over the untitled document")
        precondition(scratch.windowControllers.isEmpty && controller.document == nil, "Under a page the untitled document is still the window's document (Save and Export would act on it)")
        precondition(NSDocumentController.shared.documents.contains(scratch), "Showing the page closed the untitled document")
        let sidebar = controller.canvasForSnapshot.sidebar
        sidebar.refresh()
        let titles = sidebar.list.titlesForSnapshot
        let header = titles.firstIndex(of: "Open")
        precondition(header.map { titles[$0 + 1] } == scratch.displayName && titles.filter { $0 == SpacePanel.activity.title }.count == 1,
                     "The Open section should list the untitled document and not the page: \(titles)")

        // Back to it, through the sidebar's row: the document shows and is the window's again.
        controller.activate(controller.tabs[0])
        precondition(controller.panel == nil, "The Open row did not put the page away")
        precondition(controller.markdownDocument === scratch && controller.document === scratch && controller.editor === scratch.editor, "Switching back did not show the untitled document")
        precondition(controller.editor?.string == "Scratch notes.\n", "The untitled document lost its text")

        // Over an untitled document a page shown in place (empty: nothing to protect) is one Back away.
        let blank = try untitled("")
        let second = DocumentWindowController(document: blank)
        blank.addWindowController(second)
        second.window?.isReleasedWhenClosed = false
        defer { second.window?.close() }
        second.show(panel: .activity)
        second.goBack(nil)
        precondition(second.panel == nil && second.markdownDocument === blank && second.document === blank, "Back did not return to the untitled document under the page")

        // Typed and deleted again: empty, so it closes without asking.
        second.window?.makeFirstResponder(blank.editor?.focusView)
        blank.editor?.type("x")
        blank.editor?.focusView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        settle()
        precondition(blank.editor?.string.isEmpty == true)
        final class Answer: NSObject {
            var value: Bool?
            @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) { value = shouldClose }
        }
        let answer = Answer()
        blank.updateChangeCount(.changeDone)
        blank.canClose(withDelegate: answer, shouldClose: #selector(Answer.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        settle()
        precondition(answer.value == true && second.window?.attachedSheet == nil, "An empty untitled document asked before closing")

        // Close on a page puts the page away: the document under it shows, still open.
        controller.open(panel: .activity)
        controller.closeDocument(nil)
        settle()
        precondition(controller.tabs.count == 1 && controller.panel == nil && controller.document === scratch, "Close on a page did not return to the untitled document")

        // An untitled document without text gives way: what opens beside it takes its place, and
        // switching to another document closes it.
        let empty = try untitled(""), emptier = try untitled("")
        controller.openAlongside(empty)
        precondition(controller.tabs.count == 2 && controller.document === empty, "The empty untitled document did not open beside the other")
        controller.openAlongside(emptier)
        precondition(controller.tabs.count == 2 && controller.document === emptier && !NSDocumentController.shared.documents.contains(empty), "A document opened beside an empty untitled one did not take its place")
        controller.activate(controller.tabs.first { $0.document === scratch }!)
        settle()
        precondition(controller.tabs.count == 1 && controller.document === scratch && !NSDocumentController.shared.documents.contains(emptier), "Switching away from an empty untitled document left it open")
        print("Open documents: a page shows over an untitled document without taking a place, its row and Close return to it with its text, Back returns under a page, an emptied untitled document closes without asking, and one left without text gives way.")

        // Out into a window of its own and back.
        let other = try untitled("Other.\n")
        controller.openAlongside(other)
        precondition(controller.tabs.count == 2 && controller.markdownDocument === other)
        let before = DocumentWindowController.all.count
        controller.moveToNewWindow(nil)
        let moved = DocumentWindowController.hosting(other)!
        moved.window?.isReleasedWhenClosed = false
        precondition(moved !== controller && controller.tabs.count == 1 && moved.tabs.count == 1 && DocumentWindowController.all.count == before + 1, "Move to New Window")
        precondition(moved.document === other && moved.editor === other.editor && controller.markdownDocument === scratch, "The moved document is not shown in its new window")
        controller.mergeAllWindows(nil)
        settle()
        precondition(controller.tabs.count >= 2 && DocumentWindowController.hosting(other) === controller && NSDocumentController.shared.documents.contains(other), "Merge All Windows")
        print("Move to New Window and Merge All Windows keep each document open, with its canvas.")
    }

    /// Opening a file from the sidebar (as from Open Quickly, the path or a page) gives it a place
    /// of its own in the Open list, and opening it again shows that place; a link followed in the
    /// text replaces the shown document, with Back to return (round 38, items 4 and 5).
    @MainActor static func checkOpeningFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["a.md", "b.md", "c.md", "d.md"].map { folder.appendingPathComponent($0) }
        for url in urls { try "# \(url.lastPathComponent)\n".write(to: url, atomically: true, encoding: .utf8) }
        let first = try MarkdownDocument(contentsOf: urls[0], ofType: "net.daringfireball.markdown")
        NSDocumentController.shared.addDocument(first)
        let controller = DocumentWindowController(document: first)
        first.addWindowController(controller)
        let window = controller.window!
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
        window.orderBack(nil)
        defer { window.close() }
        func names() -> [String] { controller.tabs.map { $0.document?.fileURL?.lastPathComponent ?? "-" } }
        func wait(_ what: String, until done: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 5)
            while !done(), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
            precondition(done(), "\(what): \(names())")
        }
        func open(_ url: URL, alongside: Bool) {
            var finished = false
            controller.navigate(to: url, alongside: alongside) { finished = true }
            wait("Opening \(url.lastPathComponent) did not finish") { finished }
        }
        // One document is already listed: what is open can always be found in the sidebar, under
        // the pages, which keep their place at the top.
        let sidebar = controller.canvasForSnapshot.sidebar
        sidebar.refresh()
        let titles = sidebar.list.titlesForSnapshot
        let header = titles.firstIndex(of: "Open"), pages = titles.firstIndex(of: "Pages")
        precondition(pages == 0 && header.map { $0 > 0 && titles[$0 + 1] == "a" } == true, "The Open section does not list the only document under the pages: \(titles)")

        open(urls[1], alongside: true)
        open(urls[2], alongside: true)
        precondition(names() == ["a.md", "b.md", "c.md"] && controller.fileURL == urls[2], "Files opened from the sidebar did not each get a place")
        open(urls[0], alongside: true)
        precondition(names() == ["a.md", "b.md", "c.md"] && controller.fileURL == urls[0], "Opening an open file again did not show its place")
        let agentItem = NSMenuItem(title: "Allow Agent Access", action: #selector(DocumentWindowController.toggleAgentAccess(_:)), keyEquivalent: "")
        precondition(controller.validateMenuItem(agentItem) && agentItem.state == .off, "Agent access is not offered for a saved document")
        controller.toggleAgentAccess(agentItem)
        precondition(AgentAccess.shared.grant(for: controller.markdownDocument) != nil && controller.validateMenuItem(agentItem) && agentItem.state == .on,
                     "File → Allow Agent Access did not share the shown document")
        controller.toggleAgentAccess(agentItem)
        precondition(AgentAccess.shared.grant(for: controller.markdownDocument) == nil, "Choosing Allow Agent Access again did not stop sharing")
        print("Agent access: File → Allow Agent Access shares the shown saved document and stops on the second choice.")

        // A link in the text replaces the shown document; Back brings it back in the same place.
        controller.activate(controller.tabs[2])
        open(urls[3], alongside: false)
        precondition(names() == ["a.md", "b.md", "d.md"], "A followed link did not replace the shown document")
        controller.goBack(nil)
        wait("Back did not return to the replaced document") { names() == ["a.md", "b.md", "c.md"] }
        print("Opening files: each file opened from the sidebar gets its own place, opening it again shows it, a followed link replaces the shown one and Back returns.")

        // The open documents' rail is on unless turned off: on the left edge while the sidebar is
        // hidden. Its resting edge is the reading area's left bound; a row's close button closes it.
        precondition(UserDefaults.standard.bool(forKey: Preferences.quickSwitcher), "The quick switcher is off by default")
        open(urls[3], alongside: true)
        let canvas = controller.canvasForSnapshot
        let rail = canvas.documentRail
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(!canvas.isSidebarVisible && !rail.isHidden && rail.items.count == 4, "The open documents' rail does not show with several documents and the sidebar hidden")
        precondition(rail.items.map(\.title) == ["a", "b", "c", "d"] && rail.items.map(\.current) == [false, false, false, true], "The rail does not list the documents with the shown one: \(rail.items)")
        let reader = controller.editor!.blockCanvas
        let column = controller.editor!.column, width = reader.view.bounds.width
        precondition(abs(reader.leadingInset - CanvasViewController.railStrip) <= 1, "The reading area does not start after the rail strip: \(reader.leadingInset)")
        precondition(abs(column.x + column.width / 2 - (reader.leadingInset + width - reader.trailingInset) / 2) <= 1, "The reader is not centered between the rail strips: \(column) in \(width)")
        rail.onClose?(3)
        wait("The rail's close button did not close its document") { names() == ["a.md", "b.md", "c.md"] }
        canvas.setSidebar(visible: true, animated: false)
        precondition(rail.isHidden, "The rail stays beside an open sidebar")
        canvas.setSidebar(visible: false, animated: false)
        print("Open documents' rail: on by default on the left edge with the sidebar hidden, the reader centered between the two rail strips; a row's close button closes its document; hidden beside the sidebar.")

        // Recent is where to start without a folder; the folder's two entries replace it, and the folder
        // becomes the first recent folder, one click away on the Activity page.
        let defaults = UserDefaults.standard
        let saved = [Preferences.registeredRoots, Preferences.recentRoots].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        precondition(controller.scopeRoot == nil)
        RecentPages.note(urls[3])
        sidebar.refresh()
        precondition(sidebar.list.titlesForSnapshot.contains("Recent"), "No Recent without a folder: \(sidebar.list.titlesForSnapshot)")
        controller.expandScope(to: folder, explicit: false)
        precondition(!sidebar.list.titlesForSnapshot.contains("Recent"), "Recent stays beside the folder: \(sidebar.list.titlesForSnapshot)")
        precondition(Preferences.recentRootURLs.first?.path == folder.path, "The folder is not the first recent folder: \(Preferences.recentRootURLs)")
        let home = sidebar.list.titlesForSnapshot
        precondition(home.contains("Home") && !home.contains(SpacePanel.folderHome(folder).title), "Folder Home is not the folder section's first row: \(home)")
        wait("The folder never finished scanning") { !sidebar.list.nodes.isEmpty }
        // With names, the folder's files are listed right in the sidebar, with no Files step between.
        precondition(!sidebar.list.titlesForSnapshot.contains("Files") && sidebar.list.rows.contains { row in
            if case .file = row.kind { true } else { false }
        }, "The full sidebar does not list the folder's files directly: \(sidebar.list.titlesForSnapshot)")
        let oldStyle = defaults.object(forKey: Preferences.sidebarIconsOnly)
        defer { defaults.set(oldStyle, forKey: Preferences.sidebarIconsOnly) }
        defaults.set(true, forKey: Preferences.sidebarIconsOnly)
        NotificationCenter.default.post(name: Preferences.sidebarDidChange, object: nil)
        canvas.setSidebar(visible: true, animated: false)
        let sidebarFrame = sidebar.frame
        let readingFrame = controller.editor!.scrollView.frame
        func browser(in view: NSView) -> SidebarList? {
            if let list = view as? SidebarList, list !== sidebar.list, list.showsFiles, list.rootName == folder.lastPathComponent, list.window?.isVisible == true { return list }
            return view.subviews.lazy.compactMap(browser).first
        }
        for fromSearch in [false, true] {
            if fromSearch { sidebar.show(.search) }
            sidebar.show(.files)
            var fileBrowser: SidebarList?
            wait("Files did not show a temporary named browser") {
                fileBrowser = NSApp.windows.compactMap { $0.contentView.flatMap(browser) }.first
                return fileBrowser != nil
            }
            precondition(sidebar.isCompact && !sidebar.list.showsFiles && fileBrowser!.titlesForSnapshot.contains("a"), "Files replaced the pinned icon strip")
            precondition(sidebar.frame == sidebarFrame && controller.editor!.scrollView.frame == readingFrame, "Opening Files moved the sidebar or reader")
            let title = (fileBrowser!.accessibilityChildren() as? [NSAccessibilityElement])!.first!
            precondition(title.accessibilityRole() == .staticText, "The temporary browser's folder name offers a Back it does not have")
            let popoverWindow = fileBrowser!.window!
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: popoverWindow.windowNumber,
                                          context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            // Through the event queue, as the run loop delivers keys (local monitors run there).
            NSApp.postEvent(escape, atStart: false)
            while let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            wait("The file browser stayed open after Escape") { fileBrowser!.window?.isVisible != true }
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(sidebar.tab == .places && sidebar.isCompact && !sidebar.list.showsFiles, "Closing Files changed the compact navigation")
        }
        defaults.set(oldStyle, forKey: Preferences.sidebarIconsOnly)
        NotificationCenter.default.post(name: Preferences.sidebarDidChange, object: nil)
        controller.closeScope(nil)
        controller.open(panel: .activity)
        func links(_ view: NSView) -> [LinkRow] { (view as? LinkRow).map { [$0] } ?? view.subviews.flatMap(links) }
        let page = try require(controller.canvasForSnapshot.shownPage, "The Activity page is not shown")
        page.layoutSubtreeIfNeeded()
        let row = try require(links(page).first { $0.accessibilityLabel()?.hasPrefix(folder.lastPathComponent) == true }, "The Activity page does not list the recent folder")
        _ = row.accessibilityPerformPress()
        precondition(controller.scopeRoot?.path == folder.path && controller.panel == .folderHome(controller.scopeRoot!), "The recent folder did not open as this window's folder")
        print("Recent folders: Recent gives way to an open folder, which becomes the first recent folder with Home as its first row; the Activity page opens it again.")

        // Close All: every document leaves the window and memory; the window stays, on Activity.
        // Close there, with nothing under the page, closes the window.
        final class Weak { weak var value: AnyObject?; init(_ value: AnyObject?) { self.value = value } }
        // Weakly, so only the app could keep them (`first` is this check's own reference).
        let watched = controller.openTabs.filter { $0.document !== first }.flatMap { [Weak($0.document), Weak($0.editor)] }
        let closing = controller.openTabs.count
        precondition(watched.count >= 4)
        controller.closeAll()
        wait("Close All did not leave the window on Activity") { controller.openTabs.isEmpty && controller.panel == .activity }
        precondition(controller.tabs.count == 1 && controller.document == nil && window.isVisible, "Close All left places behind or closed the window")
        precondition(!NSDocumentController.shared.documents.contains { $0.fileURL?.deletingLastPathComponent().path == folder.path }, "Close All left documents open")
        sidebar.refresh()
        precondition(!sidebar.list.titlesForSnapshot.contains("Open"), "The Open section stayed: \(sidebar.list.titlesForSnapshot)")
        wait("Closed documents or their canvases are still in memory") { watched.allSatisfy { $0.value == nil } }
        controller.closeDocument(nil)
        settle()
        precondition(!window.isVisible, "Close on Activity alone did not close the window")
        print("Close All: \(closing) documents left the window and memory (\(watched.count) objects released); the window stayed on Activity, where Close closed it.")
    }

    /// A window's other documents are part of its restorable state, so they come back beside the
    /// one the system restores: the window hands its controller the coder.
    @MainActor static func checkRestorableState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.md"), second = folder.appendingPathComponent("second.md")
        try "# First\n".write(to: first, atomically: true, encoding: .utf8)
        try "# Second\n".write(to: second, atomically: true, encoding: .utf8)
        let one = try MarkdownDocument(contentsOf: first, ofType: "net.daringfireball.markdown")
        let two = try MarkdownDocument(contentsOf: second, ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: one)
        one.addWindowController(controller)
        controller.window?.isReleasedWhenClosed = false
        defer { controller.window?.close() }
        controller.openAlongside(two)
        // The first shows when the state is saved: it is the one the system restores.
        controller.activate(controller.tabs[0])
        // AppKit's own coder refers to responders by identity; this one leaves them out.
        final class StateArchiver: NSKeyedArchiver {
            override func encode(_ object: Any?, forKey key: String) {
                if object is NSResponder { return }
                super.encode(object, forKey: key)
            }
        }
        let archiver = StateArchiver(requiringSecureCoding: true)
        controller.window!.encodeRestorableState(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        let entries = unarchiver.decodeArrayOfObjects(ofClass: NSString.self, forKey: "zephyrOpenDocuments") as? [String]
        precondition(entries == [first.path, second.path], "The window's restorable state does not list its documents: \(String(describing: entries))")
        // Restored: the system brings back the shown document's window; the other comes back beside it.
        controller.window?.close()
        one.close()
        two.close()
        let reopened = try MarkdownDocument(contentsOf: first, ofType: "net.daringfireball.markdown")
        NSDocumentController.shared.addDocument(reopened)
        let restored = DocumentWindowController(document: reopened)
        reopened.addWindowController(restored)
        restored.window?.isReleasedWhenClosed = false
        defer { restored.window?.close() }
        restored.window!.restoreState(with: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        let paths = restored.tabs.map { $0.document?.fileURL?.lastPathComponent }
        precondition(paths == ["first.md", "second.md"] && restored.markdownDocument === reopened, "Restoring did not bring the other document back beside the first: \(paths)")
        print("Restorable state lists the window's documents in order and brings them back: \(entries!.map { ($0 as NSString).lastPathComponent }).")
    }

    /// The open sidebar beside the text at every width, never over it and never resizing the window:
    /// a narrow window narrows it to its minimum, not to icons; its edge drags between the minimum
    /// and the window's room; icons only come from Settings and keep the dragged width for names.
    @MainActor static func checkSidebarRoom() {
        let defaults = UserDefaults.standard
        let oldWidth = defaults.object(forKey: Preferences.sidebarWidth)
        let oldStyle = defaults.object(forKey: Preferences.sidebarIconsOnly)
        let oldPreviews = defaults.object(forKey: Preferences.linkPreviews)
        let oldDelay = defaults.object(forKey: Preferences.linkPreviewDelay)
        let oldAIButton = defaults.object(forKey: Preferences.aiButtonHidden)
        let oldOutline = defaults.object(forKey: "outlineBesideText")
        defaults.set(280, forKey: Preferences.sidebarWidth)
        defaults.set(false, forKey: Preferences.sidebarIconsOnly)
        defaults.set(true, forKey: Preferences.linkPreviews)
        defaults.set(0.2, forKey: Preferences.linkPreviewDelay)
        defaults.removeObject(forKey: Preferences.aiButtonHidden)
        Preferences.outlineBesideText = true
        precondition(defaults.bool(forKey: Preferences.aiButtonHidden), "A fresh preference domain should hide the assistant entry")
        NotificationCenter.default.post(name: Preferences.sidebarDidChange, object: nil)
        defer {
            defaults.set(oldWidth, forKey: Preferences.sidebarWidth)
            defaults.set(oldStyle, forKey: Preferences.sidebarIconsOnly)
            defaults.set(oldPreviews, forKey: Preferences.linkPreviews)
            defaults.set(oldDelay, forKey: Preferences.linkPreviewDelay)
            defaults.set(oldAIButton, forKey: Preferences.aiButtonHidden)
            defaults.set(oldOutline, forKey: "outlineBesideText")
            NotificationCenter.default.post(name: Preferences.sidebarDidChange, object: nil)
        }
        let document = try! untitled("# Room\n\nBody.\n\n## Boundary\n\nMore body.\n")
        let controller = DocumentWindowController(document: document)
        document.addWindowController(controller)
        let window = controller.window!
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
        window.orderBack(nil)
        defer { window.close() }
        let canvas = controller.canvasForSnapshot
        precondition(!canvas.isAIOpen && canvas.aiLauncher.isHidden, "The assistant should start closed with its launcher hidden")
        // The text area keeps a rail strip on each side whether or not a rail shows, so the
        // reader is centered in it and stays put when the outline comes or goes.
        @discardableResult func checkReaderCenter(_ label: String) -> (CGFloat, CGFloat) {
            window.contentView?.layoutSubtreeIfNeeded()
            let editor = controller.editor!
            editor.layoutAll()
            let area = canvas.view.convert(editor.scrollView.bounds, from: editor.scrollView)
            let column = editor.column
            let lo = canvas.view.convert(NSPoint(x: column.x, y: 0), from: editor.blockCanvas.view).x, hi = lo + column.width
            // Without room for the strips, it centers in the viewport (a legacy scroller's gutter aside).
            let viewport = canvas.view.convert(editor.scrollView.contentView.bounds, from: editor.scrollView.contentView)
            let strips = area.width - 2 * CanvasViewController.railStrip >= CanvasViewController.columnBesideRail
            if strips, canvas.isSidebarVisible {
                // As far from the sidebar card's edge as from the outline ticks' reach.
                let card = canvas.sidebar.frame.maxX - CanvasViewController.sidebarInset
                let ticks = area.maxX - CanvasViewController.ticksReach
                precondition(abs((lo - card) - (ticks - hi)) < 1, "\(label): \(lo - card) pt from the sidebar but \(ticks - hi) pt from the outline")
            } else {
                let bounds = strips ? area.insetBy(dx: CanvasViewController.railStrip, dy: 0) : viewport
                precondition(abs((lo + hi) / 2 - bounds.midX) < 1, "\(label): reader \(lo)...\(hi) is not centered in \(bounds.minX)...\(bounds.maxX)")
                if strips { precondition(min(lo - bounds.minX, bounds.maxX - hi) >= BlockCanvas.minimumMargin - 0.5, "\(label): reader \(lo)...\(hi) reaches into a rail strip") }
            }
            return (lo, hi)
        }
        window.setContentSize(NSSize(width: 1200, height: 700))
        canvas.setOutline(controller.editor!.headings())
        let withOutline = checkReaderCenter("outline shown with the sidebar hidden")
        precondition(!canvas.outlineRail.isHidden, "The outline did not appear in a wide reader")
        Preferences.outlineBesideText = false
        canvas.updateRails()
        precondition(checkReaderCenter("outline hidden with the sidebar hidden") == withOutline, "The reader moved when the outline was hidden")
        precondition(canvas.outlineRail.isHidden, "The outline stayed visible after it was disabled")
        Preferences.outlineBesideText = true
        canvas.updateRails()
        let inset = CanvasViewController.sidebarInset
        for (width, card) in [(1900, 280), (1200, 280), (760, 280), (420, CanvasViewController.minimumSidebarWidth)] as [(CGFloat, CGFloat)] {
            window.setContentSize(NSSize(width: width, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
            canvas.setSidebar(visible: true, animated: false)
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(canvas.sidebarMakesRoom && !canvas.sidebar.isCompact, "At \(width) pt the sidebar should keep its names beside the text")
            precondition(abs(canvas.sidebar.frame.width - 2 * inset - card) < 0.5, "At \(width) pt the card is \(canvas.sidebar.frame.width - 2 * inset) pt, not \(card)")
            let scroll = controller.editor!.scrollView
            let readerRect = canvas.view.convert(scroll.bounds, from: scroll)
            precondition(readerRect.minX >= canvas.sidebar.frame.maxX - 0.5 && readerRect.maxX <= canvas.view.bounds.maxX + 0.5, "The text reaches under the sidebar: \(readerRect)")
            checkReaderCenter("sidebar visible at \(width) pt")
            controller.sidebarDidOpenItem()
            precondition(canvas.isSidebarVisible, "At \(width) pt a choice closed the sidebar")
            let before = window.frame
            controller.open(panel: .activity)
            settle()
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(window.frame == before, "Activity resized the window from \(before) to \(window.frame)")
            let page = canvas.view.convert(canvas.shownPage!.bounds, from: canvas.shownPage!)
            precondition(page.minX >= canvas.sidebar.frame.maxX - 0.5 && page.width <= readerRect.width + 1, "Activity reaches under the sidebar: \(page)")
            controller.activate(controller.current)
            canvas.setSidebar(visible: false, animated: false)
        }
        window.setContentSize(NSSize(width: 1200, height: 700))
        canvas.setSidebar(visible: true, animated: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let before = window.frame
        let handle = canvas.sidebar.subviews.compactMap { $0 as? SidebarResizeHandle }.first!
        let dragPoint = canvas.sidebar.convert(NSPoint(x: 356, y: 120), to: nil)
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: dragPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        handle.mouseDragged(with: drag)
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(abs(canvas.sidebar.frame.width - 356) < 1, "Sidebar edge did not resize to 340 + 16 pt")
        precondition(defaults.double(forKey: Preferences.sidebarWidth) == 340, "The dragged width was not kept")
        canvas.resizeSidebar(to: 10)
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(canvas.sidebar.frame.width == CanvasViewController.minimumSidebarWidth + 2 * inset, "Expanded sidebar did not stop at its minimum")
        canvas.resizeSidebar(to: 340)
        // Icons only, from Settings; searching shows the names for the field, then the icons again.
        defaults.set(true, forKey: Preferences.sidebarIconsOnly)
        NotificationCenter.default.post(name: Preferences.sidebarDidChange, object: nil)
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(canvas.sidebar.isCompact && canvas.sidebar.frame.width == CanvasViewController.iconSidebarWidth + 2 * inset && handle.isHidden, "Icons only did not show the strip")
        let excerpt = "# Unsaved preview\n\n**Rendered bold**, with a [local link](details.md).\n\n- First item\n- Second item\n\n| Name | Value |\n| --- | --- |\n| Test | 42 |"
        controller.editor!.blockCanvas.replaceExternally(NSRange(location: 0, length: controller.editor!.length), with: excerpt)
        canvas.sidebar.refresh()
        settle()
        let list = canvas.sidebar.list
        let rowPoint = list.pointForSnapshot(document.displayName)!
        let hoverPoint = list.convert(NSPoint(x: list.bounds.midX, y: rowPoint.y), to: nil)
        let hover = NSEvent.mouseEvent(with: .mouseMoved, location: hoverPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        func hasExcerpt(_ view: NSView) -> Bool {
            if let snippet = view as? MarkdownSnippet { return snippet.intrinsicContentSize.height > 80 && snippet.bounds.width > 200 }
            return view.subviews.contains(where: hasExcerpt)
        }
        let responder = window.firstResponder
        list.mouseMoved(with: hover)
        precondition(!hasExcerpt(canvas.view), "Sidebar preview skipped the dwell interval")
        let previewDeadline = Date(timeIntervalSinceNow: 5)
        while !hasExcerpt(canvas.view), Date() < previewDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        precondition(hasExcerpt(canvas.view), "Sidebar hover did not show the unsaved document text")
        precondition(window.firstResponder === responder && controller.markdownDocument === document, "Sidebar preview stole focus or switched documents")
        canvas.view.layoutSubtreeIfNeeded()
        if let rep = canvas.view.bitmapImageRepForCachingDisplay(in: canvas.view.bounds) {
            canvas.view.cacheDisplay(in: canvas.view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("sidebar-hover.png"))
            }
        }
        list.mouseExited(with: hover)
        precondition(!hasExcerpt(canvas.view), "Sidebar preview stayed after leaving its row")
        print("Sidebar hover: waits for dwell, renders the unsaved Markdown opening without changing focus, and dismisses on exit.")
        canvas.sidebar.show(.search)
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(!canvas.sidebar.isCompact, "Searching kept the icons, with no room for the field")
        canvas.sidebar.show(.places)
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(canvas.sidebar.isCompact, "Leaving search did not return to the icons")
        defaults.set(false, forKey: Preferences.sidebarIconsOnly)
        NotificationCenter.default.post(name: Preferences.sidebarDidChange, object: nil)
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(!canvas.sidebar.isCompact && canvas.sidebar.frame.width == 356, "Restoring names lost the dragged width")
        precondition(window.frame == before, "Changing the sidebar changed the window")
        let days = SpaceStore.shared.activityHistory(days: 365)
        let heatmap = ActivityHeatmap(days)
        heatmap.setFrameSize(NSSize(width: 920, height: 132))
        let wideCount = heatmap.visibleColumns.count
        heatmap.setFrameSize(NSSize(width: 280, height: 132))
        precondition(heatmap.visibleColumns.count < wideCount && heatmap.cellRect(at: 0) == nil)
        precondition(heatmap.cellRect(at: 364) != nil && heatmap.cellRect(at: 364)!.maxX <= 280, "Newest day was clipped")
        print("Sidebar: names beside the text at 1200/760/420 pt (220 pt at 420), drag kept and clamped at 220 pt, icons only from Settings keep the dragged width; Activity keeps the window and the heatmap the newest days.")

        // Its list scrolls with a thin knob on no track (Zephyr's own scroller), drawn here with the
        // knob held visible (an overlay scroller fades when idle).
        let scroller = canvas.sidebar.list.enclosingScrollView?.verticalScroller
        precondition(scroller is ThinScroller && NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) > ThinScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay),
                     "The sidebar does not use the thin scroller: \(String(describing: scroller))")
        let sample = NSScrollView(frame: NSRect(x: 0, y: 0, width: 120, height: 240))
        sample.verticalScroller = ThinScroller()
        sample.hasVerticalScroller = true
        sample.scrollerStyle = .overlay
        sample.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 960))
        sample.verticalScroller?.alphaValue = 1
        let knob = sample.verticalScroller!.rect(for: .knob)
        precondition(knob.height > 0 && knob.height < 120, "The thin scroller has no proportional knob: \(knob)")
        // AppKit leaves an idle overlay scroller out of an offscreen cache, so the knob is drawn
        // directly: what the scroller paints whenever it shows.
        let bar = sample.verticalScroller!
        let image = NSImage(size: bar.bounds.size, flipped: bar.isFlipped) { _ in
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { bar.drawKnob() }
            return true
        }
        if let data = image.tiffRepresentation, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("sidebar-scroller.png"))
        }
        print("Sidebar scroller: Zephyr's thin scroller, \(ThinScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)) pt wide against the system's \(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)) pt; knob \(Int(knob.height)) pt for a quarter of the list.")
    }

    /// File → Export As: the options under the save panel keep the width the panel first gave
    /// them while the theme (or anything else) changes, so they stay centered under it.
    @MainActor static func checkExportPanelWidth() {
        let options = ExportOptionsView(settings: MarkdownExport.Settings(format: .pdf))
        let panel = NSSavePanel()
        panel.accessoryView = options
        panel.allowedContentTypes = [.pdf]
        let host = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        panel.beginSheetModal(for: host) { _ in }
        settle()
        let width = options.frame.width
        let theme = options.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSPopUpButton }[1]
        for i in theme.itemArray.indices where !theme.itemArray[i].isSeparatorItem {
            theme.selectItem(at: i)
            _ = theme.sendAction(theme.action, to: theme.target)
            settle()
            precondition(options.frame.width == width, "Choosing a theme changed the export options' width: \(options.frame.width) from \(width)")
        }
        host.endSheet(panel)
        host.close()
        print("Export panel: the options keep their \(Int(width)) pt width through every theme, centered under the panel.")
    }

    /// A theme's `font.interface` reaches views already on screen: labels and buttons change
    /// family and keep size and weight; the code font stays.
    @MainActor static func checkInterfaceFont() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let label = flatLabel("Name", size: 12, weight: .semibold)
        let button = FlatButton(title: "Open", style: .plain)
        let code = flatLabel("x = 1")
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        [label, button, code].forEach(host.addSubview)
        let old = Tokens.setInterfaceFont("Georgia")!
        Tokens.restyleInterface(in: host, from: old)
        precondition(label.font?.familyName == "Georgia" && label.font?.pointSize == 12 && NSFontManager.shared.traits(of: label.font!).contains(.boldFontMask), "A label did not take the interface font: \(String(describing: label.font))")
        precondition(button.titleFont.familyName == "Georgia" && button.titleFont.pointSize == 13, "A button did not take the interface font: \(button.titleFont)")
        precondition(code.font?.familyName != "Georgia", "The code font changed with the interface font")
        let back = Tokens.setInterfaceFont("system")!
        Tokens.restyleInterface(in: host, from: back)
        precondition(label.font?.familyName == NSFont.systemFont(ofSize: 12).familyName, "The label did not return to the system font")
        print("Interface font: labels and buttons on screen take the theme's typeface at their size and weight, and return; code keeps its font.")
    }

    /// File → Export As's options follow the chosen format.
    @MainActor static func checkExportOptions() {
        let options = ExportOptionsView(settings: MarkdownExport.Settings(format: .pdf))
        func popUps() -> [NSPopUpButton] { options.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSPopUpButton } }
        func shownRows() -> [Int] {
            let grid = options.subviews.compactMap { $0 as? NSGridView }.first!
            return (0..<grid.numberOfRows).filter { !grid.row(at: $0).isHidden }
        }
        precondition(shownRows() == [0, 1, 2, 3, 4, 5], "PDF shows format, theme, text size, line height, paper and margins: \(shownRows())")
        // Every choice starts at the settings' value (numbers included).
        let selected = popUps().map { $0.selectedItem?.representedObject.map { "\($0)" } ?? "" }
        precondition(selected == ["pdf", "", "11", "<null>", "letter", "36", "612", "2"], "The options do not start from the settings: \(selected)")
        var reported: MarkdownExport.Settings?
        options.onChange = { reported = $0 }
        let format = popUps()[0]
        format.selectItem(at: MarkdownExport.Format.allCases.firstIndex(of: .png)!)
        _ = format.sendAction(format.action, to: format.target)
        precondition(reported?.format == .png && shownRows() == [0, 1, 2, 3, 5, 6, 7], "PNG shows format, theme, text, margins, width and scale: \(shownRows())")
        // A text size chosen in the panel reaches the settings.
        let size = popUps()[2]
        size.selectItem(withTitle: "12 pt")
        _ = size.sendAction(size.action, to: size.target)
        precondition(reported?.textSize == 12 && reported?.lineHeight == nil, "The panel's text size is not reported: \(String(describing: reported))")
        format.selectItem(at: MarkdownExport.Format.allCases.firstIndex(of: .txt)!)
        _ = format.sendAction(format.action, to: format.target)
        precondition(reported?.format == .txt && shownRows() == [0], "Plain text shows only the format: \(shownRows())")
        // A picture of the PDF choices, for the round's record.
        let shown = ExportOptionsView(settings: MarkdownExport.Settings(format: .pdf, paper: .a4))
        let holder = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 480, height: shown.fittingSize.height), styleMask: [.titled], backing: .buffered, defer: false)
        holder.isReleasedWhenClosed = false
        shown.frame = NSRect(x: 0, y: 0, width: 480, height: shown.fittingSize.height)
        holder.contentView = shown
        shown.layoutSubtreeIfNeeded()
        if let rep = shown.bitmapImageRepForCachingDisplay(in: shown.bounds) {
            shown.cacheDisplay(in: shown.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent().appendingPathComponent("export-options.png"))
        }
        holder.close()
        print("Export options: PDF, PNG and plain text each show their own choices.")
    }

    /// GALLERY=1: renders the sidebar's states and two Settings pages to PNGs next to the check, for
    /// a visual review. Nothing is asserted here.
    @MainActor static func captureGallery() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("gallery")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shoot(_ view: NSView, _ name: String) {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        }
        func settle(_ seconds: Double = 0.4) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Field Notes")
        try? FileManager.default.removeItem(at: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        for path in ["Welcome.md", "Reading list.md", "Ideas.md", "Projects/Zephyr roadmap.md", "Projects/Engine notes.md", "Archive/2025 review.md"] {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# \(url.deletingPathExtension().lastPathComponent)\n\nA paragraph of body text to read.\n\n| Item | Note |\n|---|---|\n| One | Short |\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let document = try MarkdownDocument(contentsOf: folder.appendingPathComponent("Welcome.md"), ofType: "net.daringfireball.markdown")
        NSDocumentController.shared.addDocument(document)
        let controller = DocumentWindowController(document: document)
        document.addWindowController(controller)
        let window = controller.window!
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: -20_000, y: 0, width: 1200, height: 760), display: false)
        window.orderBack(nil)
        defer { window.close() }
        let canvas = controller.canvasForSnapshot
        let sidebar = canvas.sidebar
        canvas.setSidebar(visible: true, animated: false)
        controller.expandScope(to: folder, explicit: false)
        let deadline = Date(timeIntervalSinceNow: 5)
        while sidebar.list.nodes.isEmpty, Date() < deadline { settle(0.05) }
        let defaults = UserDefaults.standard
        let oldStyle = defaults.object(forKey: Preferences.sidebarIconsOnly)
        defer { defaults.set(oldStyle, forKey: Preferences.sidebarIconsOnly) }
        for (icons, name) in [(false, "names"), (true, "icons")] {
            defaults.set(icons, forKey: Preferences.sidebarIconsOnly)
            NotificationCenter.default.post(name: Preferences.sidebarDidChange, object: nil)
            sidebar.show(.places)
            settle()
            shoot(window.contentView!, "sidebar-\(name)")
            sidebar.show(.files)
            settle()
            shoot(window.contentView!, "files-\(name)")
            sidebar.show(.places)
            settle()
        }
        controller.open(panel: .activity)
        for width: CGFloat in [1200, 760] {
            window.setFrame(NSRect(x: -20_000, y: 0, width: width, height: 760), display: false)
            settle()
            shoot(window.contentView!, "activity-\(Int(width))")
        }
        for (pane, name) in [(GeneralSettingsPane(), "general"), (ThemeSettingsPane(), "theme")] as [(NSViewController, String)] {
            let settings = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 660, height: 1400), styleMask: [.titled], backing: .buffered, defer: false)
            settings.isReleasedWhenClosed = false
            settings.contentViewController = pane
            settings.setContentSize(NSSize(width: 660, height: 1400))
            settings.orderBack(nil)
            settle()
            shoot(settings.contentView!, "settings-\(name)")
            settings.close()
        }
        print("Gallery written to \(out.path).")
    }
}
