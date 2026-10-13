import AppKit
import Sparkle
import ZephyrRender

/// The menu bar, built in code. The command palette lists these same items, so menus,
/// shortcuts and the palette always run the same commands (design §8).
enum MainMenu {
    static let fileMenuID = NSUserInterfaceItemIdentifier("zephyrFile")
    static let recentMenuID = NSUserInterfaceItemIdentifier("openRecent")
    private static var fileItems: [NSMenuItem] = []

    static func normalizeFileMenu(_ menu: NSMenu) {
        guard menu.identifier == fileMenuID, menu.items != fileItems else { return }
        menu.removeAllItems()
        for item in fileItems { menu.addItem(item) }
    }

    static func build(delegate: AppDelegate, updater: AppUpdater? = nil) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appName, appMenu(delegate, updater: updater)))
        main.addItem(submenu(String(localized: "File"), fileMenu(delegate)))
        main.addItem(submenu(String(localized: "Edit"), editMenu()))
        main.addItem(submenu(String(localized: "Format"), formatMenu()))
        main.addItem(submenu(String(localized: "View"), viewMenu()))
        main.addItem(submenu(String(localized: "Go"), goMenu()))
        let window = windowMenu()
        main.addItem(submenu(String(localized: "Window"), window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: String(localized: "Help"))
        help.addItem(item(String(localized: "Markdown Reference"), #selector(AppDelegate.showHelp(_:)), "", target: delegate))
        main.addItem(submenu(String(localized: "Help"), help))
        NSApp.helpMenu = help
        return main
    }

    static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Zephyr" }

    static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        menu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0, target: AnyObject? = nil, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = modifiers
        i.tag = tag
        i.target = target
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    private static func appMenu(_ delegate: AppDelegate, updater: AppUpdater?) -> NSMenu {
        let m = NSMenu()
        m.addItem(item(String(localized: "About \(appName)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ",", target: delegate))
        if let updater {
            m.addItem(item(String(localized: "Check for Updates…"), #selector(SPUStandardUpdaterController.checkForUpdates(_:)), "", target: updater.controller))
        }
        m.addItem(.separator())
        let services = NSMenu()
        m.addItem(submenu(String(localized: "Services"), services))
        NSApp.servicesMenu = services
        m.addItem(.separator())
        m.addItem(item(String(localized: "Hide \(appName)"), #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:)), ""))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Quit \(appName)"), #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu(_ delegate: AppDelegate) -> NSMenu {
        let m = NSMenu()
        m.identifier = fileMenuID
        m.delegate = delegate
        m.addItem(item(String(localized: "New"), #selector(NSDocumentController.newDocument(_:)), "n"))
        m.addItem(item(String(localized: "New in This Window"), #selector(DocumentWindowController.newDocumentHere(_:)), "t"))
        m.addItem(item(String(localized: "Open…"), #selector(NSDocumentController.openDocument(_:)), "o"))
        m.addItem(item(String(localized: "Open Quickly…"), #selector(DocumentWindowController.openQuickly(_:)), "o", [.command, .shift]))
        let recent = NSMenu()
        recent.identifier = recentMenuID
        recent.delegate = delegate
        m.addItem(submenu(String(localized: "Open Recent"), recent))
        m.addItem(.separator())
        // Close takes the shown document out of its window (the window with the last one); in any
        // other window it closes the window (`AppDelegate.closeDocument`).
        m.addItem(item(String(localized: "Close"), #selector(DocumentWindowController.closeDocument(_:)), "w"))
        m.addItem(item(String(localized: "Close Window"), #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        m.addItem(item(String(localized: "Save"), #selector(NSDocument.save(_:)), "s"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Export As…"), #selector(ExportCommand.exportDocument(_:)), "e", [.command, .shift], target: MarkdownDocument.exportCommand))
        m.addItem(.separator())
        // The one place the GUI grants agents a session for the shown document (design §11); the
        // top bar's icon then copies the session or stops it.
        m.addItem(item(String(localized: "Allow Agent Access"), #selector(DocumentWindowController.toggleAgentAccess(_:)), ""))
        fileItems = m.items
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z"))
        m.addItem(item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"))
        m.addItem(item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"))
        m.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"))
        m.addItem(item(String(localized: "Delete"), #selector(NSText.delete(_:)), ""))
        m.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
        m.addItem(.separator())
        let find = NSMenu()
        let findAction = #selector(NSTextView.performFindPanelAction(_:))
        find.addItem(item(String(localized: "Find…"), findAction, "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)))
        find.addItem(item(String(localized: "Find and Replace…"), findAction, "f", [.command, .option], tag: 12))
        find.addItem(item(String(localized: "Find Next"), findAction, "g", tag: Int(NSFindPanelAction.next.rawValue)))
        find.addItem(item(String(localized: "Find Previous"), findAction, "g", [.command, .shift], tag: Int(NSFindPanelAction.previous.rawValue)))
        find.addItem(item(String(localized: "Use Selection for Find"), findAction, "e", tag: Int(NSFindPanelAction.setFindString.rawValue)))
        // ⌘J opens the assistant (design §8), as in Notion; this keeps its place without the key.
        find.addItem(item(String(localized: "Jump to Selection"), #selector(NSTextView.centerSelectionInVisibleArea(_:)), ""))
        m.addItem(submenu(String(localized: "Find"), find))
        m.addItem(item(String(localized: "Search in Folder…"), #selector(DocumentWindowController.showScopeSearch(_:)), "f", [.command, .shift]))
        m.addItem(.separator())
        let spelling = NSMenu()
        spelling.addItem(item(String(localized: "Show Spelling and Grammar"), #selector(NSText.showGuessPanel(_:)), ":"))
        spelling.addItem(item(String(localized: "Check Document Now"), #selector(NSText.checkSpelling(_:)), ";"))
        spelling.addItem(item(String(localized: "Check Spelling While Typing"), #selector(NSTextView.toggleContinuousSpellChecking(_:)), ""))
        m.addItem(submenu(String(localized: "Spelling and Grammar"), spelling))
        let speech = NSMenu()
        speech.addItem(item(String(localized: "Start Speaking"), #selector(NSTextView.startSpeaking(_:)), ""))
        speech.addItem(item(String(localized: "Stop Speaking"), #selector(NSTextView.stopSpeaking(_:)), ""))
        m.addItem(submenu(String(localized: "Speech"), speech))
        return m
    }

    private static func formatMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item(String(localized: "Bold"), #selector(BlockCanvasView.toggleBoldface(_:)), "b", symbol: "bold"))
        m.addItem(item(String(localized: "Italic"), #selector(BlockCanvasView.toggleItalics(_:)), "i", symbol: "italic"))
        m.addItem(item(String(localized: "Underline"), #selector(BlockCanvasView.toggleUnderlined(_:)), "u", symbol: "underline"))
        m.addItem(item(String(localized: "Strikethrough"), #selector(BlockCanvasView.toggleStrikethrough(_:)), "x", [.command, .shift], symbol: "strikethrough"))
        m.addItem(item(String(localized: "Highlight"), #selector(BlockCanvasView.toggleHighlight(_:)), "h", [.command, .shift], symbol: "highlighter"))
        m.addItem(item(String(localized: "Inline Code"), #selector(BlockCanvasView.toggleInlineCode(_:)), "`", [.control], symbol: "chevron.left.forwardslash.chevron.right"))
        m.addItem(item(String(localized: "Link"), #selector(BlockCanvasView.insertMarkdownLink(_:)), "k", symbol: "link"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Body Text"), #selector(BlockCanvasView.applyHeading(_:)), "0", tag: 0, symbol: "textformat"))
        for level in 1...6 {
            m.addItem(item(String(localized: "Heading \(level)"), #selector(BlockCanvasView.applyHeading(_:)), "\(level)", tag: level))
        }
        m.addItem(.separator())
        m.addItem(item(String(localized: "Bulleted List"), #selector(BlockCanvasView.toggleBulletList(_:)), "7", [.command, .shift], symbol: "list.bullet"))
        m.addItem(item(String(localized: "Numbered List"), #selector(BlockCanvasView.toggleNumberedList(_:)), "9", [.command, .shift], symbol: "list.number"))
        m.addItem(item(String(localized: "Checklist"), #selector(BlockCanvasView.toggleTaskList(_:)), "l", [.command, .shift], symbol: "checklist"))
        m.addItem(item(String(localized: "Block Quote"), #selector(BlockCanvasView.toggleBlockQuote(_:)), "'", symbol: "text.quote"))
        m.addItem(item(String(localized: "Code Block"), #selector(BlockCanvasView.insertCodeBlock(_:)), "c", [.command, .option], symbol: "curlybraces"))
        m.addItem(.separator())
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        m.addItem(item(String(localized: "Move Block Up"), #selector(BlockCanvasView.moveBlockUp(_:)), up, [.command, .option], symbol: "arrow.up"))
        m.addItem(item(String(localized: "Move Block Down"), #selector(BlockCanvasView.moveBlockDown(_:)), down, [.command, .option], symbol: "arrow.down"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Edit Properties"), #selector(BlockCanvasView.editProperties(_:)), "", symbol: "list.bullet.rectangle"))
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item(String(localized: "Show Sidebar"), #selector(DocumentWindowController.toggleScopeSidebar(_:)), "s", [.command, .control], symbol: "sidebar.leading"))
        m.addItem(item(String(localized: "Files"), #selector(DocumentWindowController.showFilesTab(_:)), "1", [.command, .control]))
        m.addItem(item(String(localized: "Outline"), #selector(DocumentWindowController.showOutlineTab(_:)), "2", [.command, .control], symbol: "list.bullet.indent"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Command Palette…"), #selector(DocumentWindowController.showCommandPalette(_:)), "p", [.command, .shift]))
        m.addItem(item(String(localized: "Minimal Mode"), #selector(DocumentWindowController.toggleMinimalMode(_:)), "m", [.command, .control]))
        m.addItem(item(String(localized: "Plain Text"), #selector(DocumentWindowController.togglePlainText(_:)), "/", symbol: "text.alignleft"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Ask AI"), #selector(DocumentWindowController.toggleAIPanel(_:)), "j", symbol: "sparkles"))
        m.addItem(item(String(localized: "Show AI Button"), #selector(DocumentWindowController.toggleAIButton(_:)), ""))
        m.addItem(.separator())
        let typeface = NSMenu()
        for preset in Typography.Preset.allCases {
            let i = item(SettingsWindowController.name(of: preset), #selector(SettingsWindowController.selectTypeface(_:)), "", target: SettingsWindowController.shared)
            i.representedObject = preset.rawValue
            typeface.addItem(i)
        }
        m.addItem(submenu(String(localized: "Typeface"), typeface))
        m.addItem(item(String(localized: "Bigger"), #selector(SettingsWindowController.makeTextBigger(_:)), "+", target: SettingsWindowController.shared))
        m.addItem(item(String(localized: "Smaller"), #selector(SettingsWindowController.makeTextSmaller(_:)), "-", target: SettingsWindowController.shared))
        m.addItem(item(String(localized: "Actual Size"), #selector(SettingsWindowController.makeTextStandardSize(_:)), "0", [.command, .shift], target: SettingsWindowController.shared))
        m.addItem(.separator())
        return m
    }

    private static func goMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item(String(localized: "Back"), #selector(DocumentWindowController.goBack(_:)), "[", symbol: "chevron.backward"))
        m.addItem(item(String(localized: "Forward"), #selector(DocumentWindowController.goForward(_:)), "]", symbol: "chevron.forward"))
        m.addItem(.separator())
        // The app's own pages (design §8.3).
        m.addItem(item(SpacePanel.activity.title, #selector(DocumentWindowController.showActivity(_:)), "1", [.command, .option], symbol: SpacePanel.activity.symbol))
        m.addItem(item(String(localized: "New Page"), #selector(DocumentWindowController.newBlankPage(_:)), "n", [.command, .option], symbol: "plus.square"))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Open Quickly…"), #selector(DocumentWindowController.openQuickly(_:)), ""))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:)), ""))
        m.addItem(.separator())
        // A window's open documents, listed in its sidebar (design §7.8).
        m.addItem(item(String(localized: "Show Previous Document"), #selector(DocumentWindowController.showPreviousDocument(_:)), "\t", [.control, .shift]))
        m.addItem(item(String(localized: "Show Next Document"), #selector(DocumentWindowController.showNextDocument(_:)), "\t", [.control]))
        m.addItem(item(String(localized: "Move to New Window"), #selector(DocumentWindowController.moveToNewWindow(_:)), ""))
        m.addItem(item(String(localized: "Merge All Windows"), #selector(DocumentWindowController.mergeAllWindows(_:)), ""))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)), ""))
        return m
    }
}
