import AppKit
import ZephyrCore
import ZephyrRender

/// User preferences (design §8: stored in UserDefaults). Typography and theme live in
/// `appearance.json` instead (`AppearanceStore`), where `zephyr config` and agents reach them too.
enum Preferences {
    static let frontMatterCollapsed = "frontMatterCollapsed"
    static let registeredRoots = "registeredRoots"
    static let recentRoots = "recentScopeRoots"
    static let minimalMode = "minimalMode"
    /// The count in the top bar: characters, words or paragraphs.
    static let statisticsMetric = "statisticsMetric"
    static let aiEndpoint = "aiEndpoint"
    static let aiButtonHidden = "aiButtonHidden"
    /// The open documents as a rail on the left edge while the sidebar is hidden (design §7.8);
    /// on unless turned off, so switching and closing stay one pointing away.
    static let quickSwitcher = "quickSwitcher"
    /// The sidebar card's width with names, as its edge was last dragged.
    static let sidebarWidth = "sidebarWidth"
    /// New windows open with the sidebar, the folder's files in it, unless it was last put away
    /// with its button (minimal mode hides it without changing this).
    static let sidebarVisible = "sidebarVisible"
    /// The sidebar as a strip of icons, chosen only in Settings (never by the window's width).
    static let sidebarIconsOnly = "sidebarIconsOnly"
    static let sidebarDidChange = Notification.Name("ZephyrSidebarDidChange")
    /// Quit once the last window closes, instead of staying open like most Mac document apps.
    static let quitWithLastWindow = "quitWithLastWindow"
    static let linkPreviews = "linkPreviews"
    static let linkPreviewDelay = "linkPreviewDelay"
    /// Images on the web that documents show (a README's release badge, a screenshot), over HTTPS
    /// without cookies (design §9). Static badges are drawn by Zephyr and need no request.
    static let remoteImages = "remoteImages"

    static func register() {
        UserDefaults.standard.register(defaults: [
            frontMatterCollapsed: false,
            minimalMode: false,
            aiButtonHidden: true,
            quickSwitcher: true,
            sidebarWidth: 280.0,
            sidebarIconsOnly: false,
            sidebarVisible: true,
            quitWithLastWindow: false,
            linkPreviews: true,
            linkPreviewDelay: 0.8,
            remoteImages: true,
            "outlineBesideText": true,
            "outlineDepth": 3,
        ])
    }

    /// The outline as a rail beside the text, or as a button in the top bar (design §8).
    static var outlineBesideText: Bool {
        get { UserDefaults.standard.bool(forKey: "outlineBesideText") }
        set { UserDefaults.standard.set(newValue, forKey: "outlineBesideText") }
    }

    /// How many heading levels the outline shows, from the document's top level (1–6).
    static var outlineDepth: Int {
        get { min(max(UserDefaults.standard.integer(forKey: "outlineDepth"), 1), 6) }
        set { UserDefaults.standard.set(newValue, forKey: "outlineDepth") }
    }

    /// The AI provider (design §10). Its key is stored encrypted by `CredentialStore`, bound to this endpoint.
    static var endpoint: AIEndpoint {
        get {
            guard let data = UserDefaults.standard.data(forKey: aiEndpoint), let e = try? JSONDecoder().decode(AIEndpoint.self, from: data) else { return .preset(.anthropic) }
            return e
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: aiEndpoint)
            NotificationCenter.default.post(name: aiDidChange, object: nil)
        }
    }

    static let aiDidChange = Notification.Name("ZephyrAIDidChange")

    /// Standing instructions for the built-in assistant and terminal agents (Settings → Agents);
    /// agents read them in the context card.
    static var agentInstructions: String? {
        get { UserDefaults.standard.string(forKey: "agentInstructions").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: "agentInstructions") }
    }

    static var registeredRootURLs: [URL] {
        (UserDefaults.standard.stringArray(forKey: registeredRoots) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// A folder the reader chose: later scopes stop at it (design §7 item 2), and it is recent.
    static func register(root: URL) {
        var roots = UserDefaults.standard.stringArray(forKey: registeredRoots) ?? []
        if !roots.contains(root.path) {
            roots.append(root.path)
            UserDefaults.standard.set(roots, forKey: registeredRoots)
        }
        noteRecent(root: root)
    }

    static let recentRootsDidChange = Notification.Name("ZephyrRecentRootsDidChange")

    /// A folder whose tree the reader used, chosen or found from a file: first among the recent
    /// folders (File → Open Recent, the Activity page).
    static func noteRecent(root: URL) {
        var recent = UserDefaults.standard.stringArray(forKey: recentRoots) ?? []
        guard recent.first != root.path else { return }
        recent.removeAll { $0 == root.path }
        recent.insert(root.path, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(8)), forKey: recentRoots)
        NotificationCenter.default.post(name: recentRootsDidChange, object: nil)
    }

    static var recentRootURLs: [URL] {
        (UserDefaults.standard.stringArray(forKey: recentRoots) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }.filter {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory) && directory.boolValue
        }
    }

    static let frontMatterDidChange = Notification.Name("ZephyrFrontMatterDidChange")
    static let remoteImagesDidChange = Notification.Name("ZephyrRemoteImagesDidChange")
}
