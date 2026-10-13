import AppKit
import ZephyrRender

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var launchMode: LaunchMode?
    private(set) var updater: AppUpdater?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.register()
        launchMode = LaunchMode.fromArguments()
        // Checks and snapshots share the reader's bundle: they restore none of the reader's
        // windows, and their windows are not restorable (`DocumentWindowController`).
        if launchMode != nil { UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true]) }
        // The theme's palette and light or dark are in place before the first window draws.
        _ = AppearanceStore.shared
        FocusRing.install()
        if launchMode == nil {
            let updater = AppUpdater()
            self.updater = updater
        }
        NSApp.mainMenu = MainMenu.build(delegate: self, updater: updater)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if launchMode == nil {
            updater?.start()
        } else {
            launchMode?.run()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        launchMode == nil
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.bool(forKey: Preferences.quitWithLastWindow)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
    }

    /// File → Close where no document window answers it (Settings, a sheet's parent): the key window closes.
    @objc func closeDocument(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://commonmark.org/help/")!)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    /// A recent folder opens as its Folder Home, in the window in front or a window of its own.
    @objc func openRecentFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let controller = DocumentWindowController.front ?? {
            let window = DocumentWindowController(document: nil)
            window.showWindow(nil)
            return window
        }()
        controller.openFolder(url)
    }

    @objc func clearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
        UserDefaults.standard.removeObject(forKey: Preferences.recentRoots)
        NotificationCenter.default.post(name: Preferences.recentRootsDidChange, object: nil)
    }

    func menuWillOpen(_ menu: NSMenu) { MainMenu.normalizeFileMenu(menu) }

    // Open Recent is filled from NSDocumentController on demand (public API only).
    func menuNeedsUpdate(_ menu: NSMenu) {
        MainMenu.normalizeFileMenu(menu)
        guard menu.identifier == MainMenu.recentMenuID else { return }
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path), action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        let folders = Preferences.recentRootURLs
        if !folders.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let heading = NSMenuItem(title: String(localized: "Recent Folders"), action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for url in folders {
                let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path), action: #selector(openRecentFolder(_:)), keyEquivalent: "")
                item.representedObject = url
                item.target = self
                item.toolTip = url.path
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: String(localized: "Clear Menu"), action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }
}
