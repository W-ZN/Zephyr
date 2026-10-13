import AppKit
import QuartzCore
import ZephyrCore
import ZephyrRender

/// Headless-ish modes for verification without Screen Recording permission: render a window
/// to PNG, or measure open / layout / jump / typing costs and memory (design §3.4, §16).
/// The app runs as an accessory (no Dock icon, never activates) with its window off-screen.
enum LaunchMode {
    case snapshot(file: URL, output: URL, size: NSSize, dark: Bool, scroll: Double, select: Int?, sidebar: String?, type: String?, wait: Double)
    case bench(file: URL, output: URL?)
    /// Open, optionally type at -ZephyrSelect, save through NSDocument, exit (tests/save).
    case save(file: URL, select: Int, type: String?)
    /// Share a document with agents and answer every review with -ZephyrAgent apply|discard, for
    /// -ZephyrWait seconds (tests/agent).
    case agent(file: URL, decision: String, seconds: Double)

    static func fromArguments() -> LaunchMode? {
        let d = UserDefaults.standard
        if let decision = d.string(forKey: "ZephyrAgent"), let file = d.string(forKey: "ZephyrOpen") {
            return .agent(file: URL(fileURLWithPath: file), decision: decision, seconds: d.object(forKey: "ZephyrWait") == nil ? 20 : d.double(forKey: "ZephyrWait"))
        }
        if d.bool(forKey: "ZephyrSave"), let file = d.string(forKey: "ZephyrOpen") {
            return .save(file: URL(fileURLWithPath: file), select: d.integer(forKey: "ZephyrSelect"), type: d.string(forKey: "ZephyrType"))
        }
        if let out = d.string(forKey: "ZephyrSnapshot"), let file = d.string(forKey: "ZephyrOpen") {
            let parts = (d.string(forKey: "ZephyrSize") ?? "900x1000").split(separator: "x").compactMap { Double($0) }
            let size = parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : NSSize(width: 900, height: 1000)
            let select = d.object(forKey: "ZephyrSelect") != nil ? d.integer(forKey: "ZephyrSelect") : nil
            return .snapshot(file: URL(fileURLWithPath: file), output: URL(fileURLWithPath: out), size: size,
                             dark: d.bool(forKey: "ZephyrDark"), scroll: d.double(forKey: "ZephyrScroll"), select: select,
                             sidebar: d.string(forKey: "ZephyrSidebar"), type: d.string(forKey: "ZephyrType"), wait: max(1.2, d.double(forKey: "ZephyrWait")))
        }
        if let file = d.string(forKey: "ZephyrBench") {
            return .bench(file: URL(fileURLWithPath: file), output: d.string(forKey: "ZephyrBenchOut").map { URL(fileURLWithPath: $0) })
        }
        return nil
    }

    /// -ZephyrCanvas source|block forces a presentation mode; otherwise automatic.
    static var canvasChoice: MarkdownEditor.Canvas {
        switch UserDefaults.standard.string(forKey: "ZephyrCanvas") {
        case "source": .source
        case "block", "rendered": .block
        default: .automatic
        }
    }

    @MainActor func run() {
        NSApp.setActivationPolicy(.accessory)
        switch self {
        case let .snapshot(file, output, size, dark, scroll, select, sidebar, type, wait):
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { document, _, error in
                guard let controller = document?.windowControllers.first as? DocumentWindowController, let window = controller.window,
                      let editor = (document as? MarkdownDocument)?.editor else {
                    FileHandle.standardError.write(Data("open failed: \(String(describing: error))\n".utf8))
                    exit(2)
                }
                window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
                // The system keeps part of the window on screen; cards stay where they belong to it.
                FloatingCard.keepsOnScreen = false
                window.setContentSize(size)
                // -ZephyrType: keystrokes ("\n" is Return), e.g. to check merges or open the slash menu.
                if let type {
                    editor.select(NSRange(location: min(select ?? 0, editor.length), length: 0))
                    for character in type {
                        if character == "\n" { editor.pressReturn() } else { editor.type(String(character)) }
                    }
                }
                // A selection is made early too, so work it starts (its statistics) lands before the capture.
                if let select, type == nil, UserDefaults.standard.integer(forKey: "ZephyrSelectLength") > 0 {
                    let start = min(select, editor.length)
                    editor.select(NSRange(location: start, length: min(UserDefaults.standard.integer(forKey: "ZephyrSelectLength"), editor.length - start)))
                }
                // -ZephyrNewPage blank|project|dashboard: a new page from that preset, shown.
                if let name = UserDefaults.standard.string(forKey: "ZephyrNewPage"), let preset = PagePreset.allCases.first(where: { "\($0)" == name }) {
                    controller.createPage(preset)
                }
                // -ZephyrAlso a.md,b.md: more documents open alongside the first, which stays shown
                // (the sidebar's Open section, the count, the quick switcher).
                // -ZephyrPanel overview|today|goals|<page>: an app page in place of the document.
                let panel = UserDefaults.standard.string(forKey: "ZephyrPanel").flatMap(SpacePanel.init(name:))
                if let also = UserDefaults.standard.string(forKey: "ZephyrAlso") {
                    let first = controller.current
                    for path in also.split(separator: ",") {
                        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: String(path)), display: false) { opened, _, _ in
                            if let opened = opened as? MarkdownDocument { controller.openAlongside(opened) }
                            // Showing the first document again puts a page away; the page comes back over it.
                            controller.activate(first)
                            if let panel { controller.show(panel: panel, recordHistory: false) }
                        }
                    }
                }
                if let panel { controller.show(panel: panel) }
                switch sidebar {
                case "outline": controller.showOutlineTab(nil)
                case "files": controller.showFilesTab(nil)
                case "search": controller.showScopeSearch(nil)
                default: break
                }
                // -ZephyrFind text [-ZephyrReplace text]: the Find bar open on that search (and its replace row).
                if let find = UserDefaults.standard.string(forKey: "ZephyrFind") {
                    let replacement = UserDefaults.standard.string(forKey: "ZephyrReplace")
                    editor.find.show(replace: replacement != nil)
                    editor.find.queryChanged(find)
                    if let replacement { editor.find.setReplacement(replacement) }
                }
                // -ZephyrSearch text: the sidebar's folder search open on that text.
                if let search = UserDefaults.standard.string(forKey: "ZephyrSearch") {
                    controller.showScopeSearch(for: search)
                }
                // -ZephyrAIPanel YES|demo: the AI panel open (demo: with a sample exchange), early
                // enough for its slide-in to finish before the capture.
                if let ai = UserDefaults.standard.string(forKey: "ZephyrAIPanel") {
                    controller.toggleAIPanel(nil)
                    if ai == "demo" { controller.aiPanelForSnapshot?.showSample() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    // Applied last: becoming first responder scrolls the text view back to its selection.
                    // -ZephyrSelectLength n: a selection of n characters from there.
                    if let select, type == nil {
                        let start = min(select, editor.length)
                        editor.select(NSRange(location: start, length: min(UserDefaults.standard.integer(forKey: "ZephyrSelectLength"), editor.length - start)))
                    }
                    if UserDefaults.standard.bool(forKey: "ZephyrEditProperties") { editor.editProperties() }
                    // -ZephyrPanelAdd text, -ZephyrPanelCheck n: on an app page, the entry field submits
                    // the text, and the nth check is pressed, through the controls themselves.
                    func views<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { view.subviews.flatMap { ($0 as? T).map { [$0] } ?? views($0, type) } }
                    if let text = UserDefaults.standard.string(forKey: "ZephyrPanelAdd"), let entry = views(window.contentView!, EntryField.self).first {
                        entry.field.stringValue = text
                        _ = entry.control(entry.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
                    }
                    // -ZephyrPanelDraft text: typed into the first entry and not added, then the page
                    // reloads (a change to the space): the draft and its focus stay.
                    if let draft = UserDefaults.standard.string(forKey: "ZephyrPanelDraft"), let entry = views(window.contentView!, EntryField.self).first {
                        window.makeFirstResponder(entry.field)
                        entry.field.currentEditor()?.insertText(draft)
                        NotificationCenter.default.post(name: SpaceStore.didChange, object: nil)
                    }
                    if UserDefaults.standard.object(forKey: "ZephyrPanelCheck") != nil {
                        let checks = views(window.contentView!, TaskCheck.self)
                        let n = UserDefaults.standard.integer(forKey: "ZephyrPanelCheck")
                        if checks.indices.contains(n) { _ = checks[n].accessibilityPerformPress() }
                    }
                    // -ZephyrPanelAsk YES: an app page's assistant button (the first one found).
                    if UserDefaults.standard.bool(forKey: "ZephyrPanelAsk") {
                        views(window.contentView!, FlatButton.self).first { $0.symbolName == "sparkles" }?.performClick(nil)
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
                    }
                    // -ZephyrRenamePage title: a page's title changed in place (as typed, then Return).
                    if let title = UserDefaults.standard.string(forKey: "ZephyrRenamePage"), let board = controller.canvasForSnapshot.shownPage as? BoardPanel {
                        board.heading.stringValue = title
                        board.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: board.heading))
                    }
                    // -ZephyrRename YES: the file's name being renamed in the top bar.
                    if UserDefaults.standard.bool(forKey: "ZephyrRename") { controller.renameFromMenu(nil) }
                    // -ZephyrDocs n: the open documents' rail opened with the pointer on document n's
                    // row; -ZephyrDocsClose YES: on its close button.
                    if UserDefaults.standard.object(forKey: "ZephyrDocs") != nil {
                        controller.canvasForSnapshot.documentRail.hoverForSnapshot(UserDefaults.standard.integer(forKey: "ZephyrDocs"), onClose: UserDefaults.standard.bool(forKey: "ZephyrDocsClose"), seconds: 1)
                    }
                    // -ZephyrStatistics YES: the statistics card under the top bar's count.
                    if UserDefaults.standard.bool(forKey: "ZephyrStatistics") { controller.showStatistics(nil) }
                    // -ZephyrSettings general|ai: capture the settings window instead.
                    var captured = window
                    if let tab = UserDefaults.standard.string(forKey: "ZephyrSettings") {
                        if let settings = SettingsWindowController.shared.window {
                            // Placed before it shows: a resizable window is kept partly on screen.
                            settings.styleMask.remove(.resizable)
                            // -ZephyrSettingsHeight: a taller window, to see a whole page at once.
                            let height = UserDefaults.standard.double(forKey: "ZephyrSettingsHeight")
                            if height > 0 { settings.setContentSize(NSSize(width: settings.frame.width, height: height)) }
                            settings.setFrameOrigin(NSPoint(x: -20_000, y: 2_000))
                            captured = settings
                        }
                        SettingsWindowController.shared.show(tab: SettingsWindowController.Tab(rawValue: tab) ?? .general)
                    }
                    // -ZephyrClick x,y: a click at that point of the text view (attached editors).
                    var clicked: NSPoint?
                    if let click = UserDefaults.standard.string(forKey: "ZephyrClick")?.split(separator: ",").compactMap({ Double($0) }), click.count == 2 {
                        editor.focusView.displayIfNeeded()
                        let point = editor.focusView.convert(NSPoint(x: click[0], y: click[1]), to: nil)
                        clicked = point
                        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            editor.focusView.mouseDown(with: event)
                        }
                        // -ZephyrClickType text: typed where the click put the focus (a table cell).
                        if let typed = UserDefaults.standard.string(forKey: "ZephyrClickType") {
                            (window.firstResponder as? NSTextView)?.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
                        }
                    }
                    // -ZephyrHover <offset>: the pointer rests on the line of that character (block handle).
                    if UserDefaults.standard.object(forKey: "ZephyrHover") != nil {
                        let offset = min(UserDefaults.standard.integer(forKey: "ZephyrHover"), editor.length - 1)
                        let line = editor.lineRect(at: offset)
                        let point = editor.focusView.convert(NSPoint(x: line.minX + 40, y: line.maxY - 8), to: nil)
                        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                            editor.focusView.mouseMoved(with: event)
                        }
                        // -ZephyrHoverHandle YES: then onto that block's handle (its scope shows).
                        if UserDefaults.standard.bool(forKey: "ZephyrHoverHandle"), let handle = editor.handleRect(at: editor.focusView.convert(point, from: nil)),
                           let event = NSEvent.mouseEvent(with: .mouseMoved, location: editor.focusView.convert(NSPoint(x: handle.midX, y: handle.midY), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                            editor.focusView.mouseMoved(with: event)
                        }
                    }
                    // -ZephyrKeys "down down return": keys pressed in the text, in order (down, up,
                    // left, right, return, delete, plain = ⌘/).
                    if let keys = UserDefaults.standard.string(forKey: "ZephyrKeys") {
                        window.makeFirstResponder(editor.focusView)
                        for key in keys.split(separator: " ") {
                            let commands: [Substring: Selector] = ["down": #selector(NSResponder.moveDown(_:)), "up": #selector(NSResponder.moveUp(_:)),
                                                                   "left": #selector(NSResponder.moveLeft(_:)), "right": #selector(NSResponder.moveRight(_:)),
                                                                   "return": #selector(NSResponder.insertNewline(_:)), "delete": #selector(NSResponder.deleteBackward(_:))]
                            if key == "plain" { controller.togglePlainText(nil) } else if let command = commands[key] { editor.focusView.doCommand(by: command) }
                        }
                    }
                    // -ZephyrFocusAt x,y: the view there made first responder (as a click does with
                    // keyboard navigation on); prints whether it took it and any focus views AppKit added.
                    if let at = UserDefaults.standard.string(forKey: "ZephyrFocusAt")?.split(separator: ",").compactMap({ Double($0) }), at.count == 2 {
                        window.contentView?.layoutSubtreeIfNeeded()
                        let content = window.contentView!
                        let hit = content.hitTest(content.superview!.convert(NSPoint(x: at[0], y: at[1]), from: nil))
                        // As the window does for a click: only a view that accepts it takes the focus.
                        let accepts = hit?.acceptsFirstResponder == true
                        let took = accepts && window.makeFirstResponder(hit)
                        Swift.print("focus ring bounds \(hit?.focusRingMaskBounds ?? .zero)")
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                        let focusViews = all(content.superview ?? content).map { String(describing: Swift.type(of: $0)) }.filter { $0.localizedCaseInsensitiveContains("focus") }
                        Swift.print("focus \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nil"): took \(took), first responder \(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil"), focus views \(focusViews)")
                    }
                    // -ZephyrPointer "x,y;x,y": the text's tracking area sees the pointer at each point
                    // (window coordinates, from the bottom left); prints the pointer the text leaves
                    // and the view on top there, starting from an arrow each time.
                    if let probes = UserDefaults.standard.string(forKey: "ZephyrPointer") {
                        window.contentView?.layoutSubtreeIfNeeded()
                        for probe in probes.split(separator: ";") {
                            let xy = probe.split(separator: ",").compactMap { Double($0) }
                            guard xy.count == 2 else { continue }
                            let point = NSPoint(x: xy[0], y: xy[1])
                            NSCursor.arrow.set()
                            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                                editor.focusView.mouseMoved(with: event)
                                editor.focusView.cursorUpdate(with: event)
                            }
                            let name = NSCursor.current == .iBeam ? "iBeam" : NSCursor.current == .arrow ? "arrow" : NSCursor.current == .pointingHand ? "pointingHand" : "other"
                            let content = window.contentView!
                            let hit = content.hitTest(content.superview!.convert(point, from: nil)).map { String(describing: Swift.type(of: $0)) } ?? "nil"
                            Swift.print("pointer \(probe): \(name) over \(hit)")
                        }
                    }
                    // -ZephyrRail f: the pointer on the outline rail, f of the way down its ticks;
                    // -ZephyrRailTime s: the frame s seconds after it arrived (default: settled).
                    if UserDefaults.standard.object(forKey: "ZephyrRail") != nil {
                        let rail = controller.canvasForSnapshot.outlineRail
                        rail.layoutSubtreeIfNeeded()
                        let time = UserDefaults.standard.object(forKey: "ZephyrRailTime") == nil ? 1.5 : UserDefaults.standard.double(forKey: "ZephyrRailTime")
                        rail.hoverForSnapshot(at: rail.pointForSnapshot(CGFloat(UserDefaults.standard.double(forKey: "ZephyrRail"))), seconds: CGFloat(time))
                        // -ZephyrRailMove f|leave and -ZephyrRailMoveTime s: then the pointer moves to f
                        // of the open panel's height (or leaves it), and the frame s seconds later.
                        if let move = UserDefaults.standard.string(forKey: "ZephyrRailMove") {
                            rail.moveForSnapshot(to: Double(move).map { CGFloat($0) }, seconds: CGFloat(UserDefaults.standard.object(forKey: "ZephyrRailMoveTime") == nil ? 1.5 : UserDefaults.standard.double(forKey: "ZephyrRailMoveTime")))
                        }
                    }
                    // -ZephyrList title and -ZephyrListTime s: the sidebar's section or folder of that
                    // title opened or closed, the frame s seconds later. -ZephyrListUnroll s: the list
                    // s seconds into unrolling, as when the sidebar opens.
                    if let title = UserDefaults.standard.string(forKey: "ZephyrList") {
                        let list = controller.canvasForSnapshot.sidebar.list
                        if let i = list.indexForSnapshot(title) { list.stepForSnapshot(CGFloat(UserDefaults.standard.double(forKey: "ZephyrListTime")), toggling: i) }
                    }
                    // -ZephyrListHover title: the pointer over that row (a heading shows its actions).
                    if let title = UserDefaults.standard.string(forKey: "ZephyrListHover") {
                        let list = controller.canvasForSnapshot.sidebar.list
                        if let point = list.pointForSnapshot(title), let event = NSEvent.mouseEvent(with: .mouseMoved, location: list.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                            list.mouseMoved(with: event)
                        }
                    }
                    if UserDefaults.standard.object(forKey: "ZephyrListUnroll") != nil {
                        // As `didAppear`: the current row scrolled into view first.
                        controller.canvasForSnapshot.sidebar.list.scrollToCurrent()
                        controller.canvasForSnapshot.sidebar.list.stepForSnapshot(CGFloat(UserDefaults.standard.double(forKey: "ZephyrListUnroll")), unrolling: true)
                    }
                    // -ZephyrRailLive f: the same through the real path (pointer events, the hover
                    // delay, the display link), one second of run loop later.
                    if UserDefaults.standard.object(forKey: "ZephyrRailLive") != nil {
                        let rail = controller.canvasForSnapshot.outlineRail
                        rail.layoutSubtreeIfNeeded()
                        let point = rail.convert(rail.pointForSnapshot(CGFloat(UserDefaults.standard.double(forKey: "ZephyrRailLive"))), to: nil)
                        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                            rail.mouseMoved(with: event)
                            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                            rail.mouseMoved(with: event)
                        }
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
                    }
                    if scroll > 0 {
                        let height = (editor.scrollView.documentView?.bounds.height ?? 0) - editor.scrollView.contentView.bounds.height
                        editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, height * scroll)))
                        editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
                    }
                    // Each window draws its frame view (title bar and window buttons included), then
                    // the document window's floating children (slash menu, cards) in place. Drawing
                    // does not depend on the window server, which returns nothing for a locked screen.
                    if UserDefaults.standard.bool(forKey: "ZephyrActive"), let active = captured as? DocumentWindow {
                        active.drawsAsActive = true
                        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { active.standardWindowButton(kind)?.needsDisplay = true }
                        active.contentView?.superview?.needsDisplay = true
                    }
                    captured.contentView?.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
                    func render(_ w: NSWindow) -> NSBitmapImageRep? {
                        guard let frame = w.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
                        frame.cacheDisplay(in: frame.bounds, to: rep)
                        return rep
                    }
                    guard let rep = render(captured) else { exit(3) }
                    if let context = NSGraphicsContext(bitmapImageRep: rep) {
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = context
                        for child in NSApp.windows where captured === window && child !== window && child.isVisible && child.frame.intersects(window.frame) {
                            guard let image = render(child) else { continue }
                            var origin = NSPoint(x: child.frame.minX - captured.frame.minX, y: child.frame.minY - captured.frame.minY)
                            // The system moves popovers of an off-screen window onto the screen; draw them under the click.
                            if child.className.contains("Popover"), let clicked {
                                origin = NSPoint(x: clicked.x - child.frame.width / 2, y: clicked.y - 60 - child.frame.height)
                            }
                            image.draw(in: NSRect(origin: origin, size: child.frame.size))
                        }
                        // -ZephyrActive YES: AppKit lights the window buttons only while the app is
                        // frontmost, which a snapshot never makes it; paint them as an active window shows them.
                        if UserDefaults.standard.bool(forKey: "ZephyrActive") {
                            let lit: [(NSWindow.ButtonType, UInt32, UInt32)] = [(.closeButton, 0xFF5F57, 0xE2463F), (.miniaturizeButton, 0xFEBC2E, 0xE1A116), (.zoomButton, 0x28C840, 0x12AC28)]
                            for (kind, fill, edge) in lit {
                                guard let button = captured.standardWindowButton(kind) else { continue }
                                let frame = button.convert(button.bounds, to: nil)
                                let d = min(frame.width, frame.height)
                                let circle = NSBezierPath(ovalIn: NSRect(x: frame.midX - d / 2, y: frame.midY - d / 2, width: d, height: d).insetBy(dx: 0.25, dy: 0.25))
                                func color(_ rgb: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(rgb >> 16) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1) }
                                color(fill).setFill()
                                circle.fill()
                                color(edge).setStroke()
                                circle.lineWidth = 0.5
                                circle.stroke()
                            }
                        }
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    try? rep.representation(using: .png, properties: [:])?.write(to: output)
                    if type != nil { try? editor.string.write(to: output.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8) }
                    exit(0)
                }
            }
        case let .bench(file, output):
            if UserDefaults.standard.bool(forKey: "ZephyrBenchProduct") {
                Bench.runProduct(file: file, output: output)
            } else {
                DispatchQueue.main.async { Bench.run(file: file, output: output) }
            }
        case let .agent(file, decision, seconds):
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { document, _, error in
                guard let document = document as? MarkdownDocument, let window = document.windowControllers.first?.window else {
                    print("open failed: \(String(describing: error))")
                    exit(2)
                }
                window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
                // The system keeps part of the window on screen; cards stay where they belong to it.
                FloatingCard.keepsOnScreen = false
                // -ZephyrAgentScope YES: the window shows the file's folder first, so the share includes it.
                if UserDefaults.standard.bool(forKey: "ZephyrAgentScope") {
                    (window.windowController as? DocumentWindowController)?.expandScope(to: file.deletingLastPathComponent(), explicit: false)
                }
                AgentAccess.shared.share(document)
                print("shared")
                fflush(stdout)
                let title = decision == "apply" ? String(localized: "Apply") : String(localized: "Discard")
                Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard let sheet = window.attachedSheet else { return }
                        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
                        // Twice, as a double click: the review must act on it once.
                        guard let button = buttons(sheet.contentView!).first(where: { $0.title == title }) else { return }
                        button.performClick(nil)
                        button.performClick(nil)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
            }
        case let .save(file, select, type):
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { document, _, error in
                guard let document = document as? MarkdownDocument, let editor = document.editor, let typeName = document.fileType else {
                    print("open failed: \(String(describing: error))")
                    exit(2)
                }
                document.windowControllers.first?.window?.setFrameOrigin(NSPoint(x: -20_000, y: 0))
                if let type, editor.isEditable {
                    // Typed as keystrokes: "\n" is Return, so line breaks follow the file's style.
                    editor.select(NSRange(location: min(select, editor.length), length: 0))
                    for (i, part) in type.components(separatedBy: "\n").enumerated() {
                        if i > 0 { editor.pressReturn() }
                        if !part.isEmpty { editor.type(part) }
                    }
                }
                document.save(to: file, ofType: typeName, for: .saveOperation) { error in
                    print(error.map { "error: \($0.localizedDescription)" } ?? "saved")
                    exit(error == nil ? 0 : 1)
                }
            }
        }
    }
}

@MainActor
enum Bench {
    static func now() -> Double { CACurrentMediaTime() * 1000 }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// Whole-app opening and idle work, including NSDocument, outline and statistics. The older
    /// canvas benchmark remains useful for interaction costs, but does not measure this path.
    static func runProduct(file: URL, output: URL?) {
        // Keep an off-screen document eligible for the same work as a foreground window.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "product benchmark")
        let start = now()
        let baseline = footprintMB()
        NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { document, _, error in
            guard let document = document as? MarkdownDocument,
                  let window = document.windowControllers.first?.window, let editor = document.editor else {
                FileHandle.standardError.write(Data("open failed: \(String(describing: error))\n".utf8))
                ProcessInfo.processInfo.endActivity(activity)
                exit(2)
            }
            window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
            window.displayIfNeeded()
            var result: [String: Any] = ["path": "product", "file": file.lastPathComponent,
                "canvas": editor.blockCanvas.mode == .source ? "source" : "block",
                "open_total_ms": now() - start, "footprint_baseline_mb": baseline,
                "footprint_open_mb": footprintMB()]
            // Let the document's asynchronous outline/statistics and first image decode settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                result["footprint_settled_mb"] = footprintMB()
                let cpuStart = cpuSeconds()
                let idleStart = now()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    result["idle_cpu_percent"] = (cpuSeconds() - cpuStart) / ((now() - idleStart) / 1000) * 100
                    result["idle_seconds"] = (now() - idleStart) / 1000
                    result["footprint_idle_mb"] = footprintMB()
                    let clip = editor.scrollView.contentView
                    var frames: [Double] = []
                    for _ in 0..<180 {
                        autoreleasepool {
                            let frameStart = now()
                            CFRunLoopRunInMode(.defaultMode, 0, true)
                            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 60))
                            editor.scrollView.reflectScrolledClipView(clip)
                            window.displayIfNeeded()
                            frames.append(now() - frameStart)
                        }
                    }
                    result["scroll_p99_ms"] = percentile(frames, 0.99)
                    result["scroll_max_ms"] = frames.max() ?? 0
                    result["footprint_scroll_mb"] = footprintMB()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        result["footprint_after_scroll_settled_mb"] = footprintMB()
                        do {
                            let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                            if let output { try json.write(to: output, options: .atomic) } else { FileHandle.standardOutput.write(json) }
                            ProcessInfo.processInfo.endActivity(activity)
                            exit(0)
                        } catch {
                            FileHandle.standardError.write(Data("\(error)\n".utf8))
                            ProcessInfo.processInfo.endActivity(activity)
                            exit(2)
                        }
                    }
                }
            }
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func run(file: URL, output: URL?) {
        var result: [String: Any] = ["file": file.lastPathComponent]
        // An off-screen accessory app is a candidate for App Nap; measure it as a foreground app.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "benchmark")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // §3.2 times opening with the app already running: warm fonts and Core Text on a short document first.
        autoreleasepool {
            let warm = MarkdownEditor(text: "# Zephyr\n\n中文 **bold** `code` $x^2$\n\n| a | b |\n|---|---|\n| 1 | 2 |\n", typography: Typography(), baseURL: nil)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = warm.scrollView
            window.orderBack(nil)
            window.displayIfNeeded()
            window.orderOut(nil)
        }
        let baseline = footprintMB()
        let t0 = now()
        // The bytes go once decoded, as NSDocument's read hands them over and lets them go.
        guard let (bytes, text, encoding) = (try? Data(contentsOf: file)).map({ data -> (Int, String, SourceEncoding) in
            let (text, encoding) = SourceDecoder.decode(data)
            return (data.count, text, encoding)
        }) else { exit(2) }
        let t1 = now()
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: file.deletingLastPathComponent(), isEditable: true, canvas: LaunchMode.canvasChoice)
        result["canvas"] = editor.blockCanvas.mode == .source ? "source" : "block"
        editor.newline = encoding.newline
        result["editor_create_ms"] = now() - t1
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 900, height: 1000), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        let t2 = now()
        window.orderBack(nil)
        window.displayIfNeeded()
        let t3 = now()
        result["bytes"] = bytes
        result["decode_ms"] = t1 - t0
        result["editor_init_ms"] = t2 - t1
        result["first_screen_ms"] = t3 - t2
        result["open_total_ms"] = t3 - t0
        result["footprint_baseline_mb"] = baseline
        result["footprint_open_mb"] = footprintMB()
        // Early report, so a run stopped by the time limit still says how opening went.
        FileHandle.standardError.write(Data("bench open: total \(Int(t3 - t0)) ms, first screen \(Int(t3 - t2)) ms, \(Int(result["footprint_open_mb"] as! Double)) MB\n".utf8))

        // Interaction while the rest of the document is still styled in the background (design §3.2:
        // responsiveness during rendering). A frame = one run-loop turn (where a background slice
        // runs, as between two real frames) + a 60 px scroll + display.
        func scrollFrames(_ count: Int, by step: CGFloat) -> [Double] {
            let clip = editor.scrollView.contentView
            var frames: [Double] = []
            for _ in 0..<count {
                // One pool per frame, as the event loop drains one per event.
                autoreleasepool {
                    let start = now()
                    CFRunLoopRunInMode(.defaultMode, 0, true)
                    var origin = clip.bounds.origin
                    origin.y += step
                    clip.scroll(to: origin)
                    editor.scrollView.reflectScrolledClipView(clip)
                    window.displayIfNeeded()
                    frames.append(now() - start)
                }
            }
            return frames
        }
        let scroll = scrollFrames(180, by: 60)
        result["scroll_p50_ms"] = percentile(scroll, 0.5)
        result["scroll_p99_ms"] = percentile(scroll, 0.99)
        result["scroll_max_ms"] = scroll.max() ?? 0
        result["footprint_scroll_mb"] = footprintMB()

        // Typography changed on the fly: time to the restyled screen, then scrolling while the rest restyles.
        autoreleasepool {
            let tt = now()
            var serif = AppearanceSettings()
            _ = try? serif.set("font.body", "serif")
            _ = try? serif.set("text.size", "18")
            editor.apply(typography: Typography(serif))
            window.displayIfNeeded()
            result["theme_switch_ms"] = now() - tt
        }
        let afterTheme = scrollFrames(120, by: -60)
        result["theme_scroll_p99_ms"] = percentile(afterTheme, 0.99)
        editor.apply(typography: Typography())  // the rest is measured in the default typography
        result["footprint_theme_mb"] = footprintMB()

        // Live resize: the window narrows 8 px per frame.
        var resize: [Double] = []
        for _ in 0..<40 {
            autoreleasepool {
                let start = now()
                var size = window.contentView!.frame.size
                size.width -= 8
                window.setContentSize(size)
                window.displayIfNeeded()
                resize.append(now() - start)
            }
        }
        result["resize_p99_ms"] = percentile(resize, 0.99)
        result["footprint_resize_mb"] = footprintMB()

        // -ZephyrBenchFull NO skips styling and laying out everything (pathological for 100 KB lines).
        if UserDefaults.standard.object(forKey: "ZephyrBenchFull") == nil || UserDefaults.standard.bool(forKey: "ZephyrBenchFull") {
            let t4 = now()
            editor.layoutAll()
            window.displayIfNeeded()
            result["style_and_layout_all_ms"] = now() - t4
            result["footprint_full_mb"] = footprintMB()
        }
        result["math_cache_bytes"] = MathRendererProbe.bytes

        var rng = SystemRandomNumberGenerator()
        var jumps: [Double] = []
        let length = editor.length
        for _ in 0..<60 {
            let target = Int.random(in: 0..<max(1, length), using: &rng)
            autoreleasepool {
                let start = now()
                editor.scrollToCharacter(target)
                window.displayIfNeeded()
                jumps.append(now() - start)
            }
        }
        result["jump_p50_ms"] = percentile(jumps, 0.5)
        result["jump_p95_ms"] = percentile(jumps, 0.95)
        result["jump_max_ms"] = jumps.max() ?? 0
        result["footprint_jumps_mb"] = footprintMB()

        var keys: [Double] = []
        editor.scrollToCharacter(length / 2)
        window.displayIfNeeded()
        let visible = editor.firstVisibleCharacter()
        editor.select(NSRange(location: min(visible + 40, editor.length), length: 0))
        for i in 0..<200 {
            autoreleasepool {
                let start = now()
                editor.type(i % 17 == 16 ? " " : "a")
                window.displayIfNeeded()
                keys.append(now() - start)
            }
        }
        result["key_p50_ms"] = percentile(keys, 0.5)
        result["key_p95_ms"] = percentile(keys, 0.95)
        result["key_p99_ms"] = percentile(keys, 0.99)
        result["key_max_ms"] = keys.max() ?? 0
        result["footprint_end_mb"] = footprintMB()
        // Steady state (design §3.1): Core Animation keeps recent drawing surfaces for a moment.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        result["footprint_settled_mb"] = footprintMB()

        let json = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let output { try? json.write(to: output) } else { FileHandle.standardOutput.write(json) }
        exit(0)
    }
}
