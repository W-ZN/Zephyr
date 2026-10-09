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
        checkSidebarRoom()
        checkExportOptions()
    }

    static func untitled(_ text: String) throws -> MarkdownDocument {
        let document = MarkdownDocument()
        try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        NSDocumentController.shared.addDocument(document)
        return document
    }

    static func settle() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }

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
        print("Open documents: a page shows over an untitled document without taking a place, its row and Close return to it with its text, Back returns under a page, an emptied untitled document closes without asking.")

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
        // hidden, the column keeping clear of it on both sides; a row's close button closes it.
        precondition(UserDefaults.standard.bool(forKey: Preferences.quickSwitcher), "The quick switcher is off by default")
        open(urls[3], alongside: true)
        let canvas = controller.canvasForSnapshot
        let rail = canvas.documentRail
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(!canvas.isSidebarVisible && !rail.isHidden && rail.items.count == 4, "The open documents' rail does not show with several documents and the sidebar hidden")
        precondition(rail.items.map(\.title) == ["a", "b", "c", "d"] && rail.items.map(\.current) == [false, false, false, true], "The rail does not list the documents with the shown one: \(rail.items)")
        let column = controller.editor!.column, width = controller.editor!.blockCanvas.view.bounds.width
        precondition(column.x >= CanvasViewController.railMargin && width - column.x - column.width >= CanvasViewController.railMargin, "The column does not keep clear of the rail: \(column) in \(width)")
        rail.onClose?(3)
        wait("The rail's close button did not close its document") { names() == ["a.md", "b.md", "c.md"] }
        canvas.setSidebar(visible: true, animated: false)
        precondition(rail.isHidden, "The rail stays beside an open sidebar")
        canvas.setSidebar(visible: false, animated: false)
        print("Open documents' rail: on by default on the left edge with the sidebar hidden, the column clear of it; a row's close button closes its document; hidden beside the sidebar.")

        // Recent is where to start without a folder; the folder's tree replaces it, and the folder
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

    /// An open sidebar beside the text where the window has room, over it (closing after a choice) where not.
    @MainActor static func checkSidebarRoom() {
        let document = try! untitled("# Room\n\nBody.\n")
        let controller = DocumentWindowController(document: document)
        document.addWindowController(controller)
        let window = controller.window!
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
        window.orderBack(nil)
        defer { window.close() }
        let canvas = controller.canvasForSnapshot
        for (width, room) in [(1200, true), (760, false)] as [(CGFloat, Bool)] {
            window.setContentSize(NSSize(width: width, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
            canvas.setSidebar(visible: true, animated: false)
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(canvas.sidebarMakesRoom == room, "At \(width) pt the sidebar should \(room ? "" : "not ")make room")
            let column = controller.editor!.column
            if room { precondition(column.x >= CanvasViewController.sidebarWidth + 16, "The text is under the sidebar at \(width) pt: \(column)") }
            controller.sidebarDidOpenItem()
            precondition(canvas.isSidebarVisible == room, "At \(width) pt a choice should \(room ? "keep" : "close") the sidebar")
            canvas.setSidebar(visible: false, animated: false)
        }
        print("Sidebar: beside the text at 1200 pt and stays after a choice; over it at 760 pt and closes after a choice.")

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
        precondition(selected == ["pdf", "", "<null>", "<null>", "letter", "36", "612", "2"], "The options do not start from the settings: \(selected)")
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
}
