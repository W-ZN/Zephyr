import AppKit
import ZephyrCore
import ZephyrRender

/// The look of the running app (design §21.7). `appearance.json` says which theme is active and
/// retains legacy overrides; every theme's keys live in a user-owned JSON file. The
/// settings window changes them through `update`; `zephyr config`, MCP clients and agents may write
/// the files directly, and the app picks the change up within a moment and offers to undo it, so
/// no change of look is silent.
@MainActor
final class AppearanceStore {
    static let shared = AppearanceStore()
    static let didChange = Notification.Name("ZephyrAppearanceDidChange")

    private(set) var state: AppearanceState
    /// The active theme's keys.
    private(set) var settings: AppearanceSettings
    private(set) var fileError: String?
    private(set) var typography = Typography()
    /// What this process last wrote or read; anything else on disk came from outside.
    private var known: [URL: Data] = [:]
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pendingReload: DispatchWorkItem?
    /// -ZephyrSet "key=value;…" and -ZephyrTheme: this run only (snapshots, never saved).
    private let launchOverrides: [(String, String)]
    /// A temporary -ZephyrTheme run must not replace Finder's saved appearance snapshot.
    private let hasLaunchThemeOverride: Bool
    private var appliedMode = "system"
    let url = AppearanceState.fileURL

    var folder: URL { state.folder }
    var isPreset: Bool { state.activePreset != nil }
    var isModified: Bool { state.isModified(state.active) }
    var customThemes: [String] { ThemeLibrary.names(in: folder) }

    private init() {
        launchOverrides = (UserDefaults.standard.string(forKey: "ZephyrSet") ?? "").split(separator: ";").compactMap {
            let pair = $0.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        }
        state = AppearanceState.load(from: url) ?? AppearanceState()
        settings = AppearanceSettings()
        if !FileManager.default.fileExists(atPath: url.path) { state = Self.firstRun(state) }
        state.migrate()
        do { try state.prepareThemeFiles() } catch { fileError = (error as? AppearanceSettings.SettingError)?.message ?? error.localizedDescription }
        let launchTheme = UserDefaults.standard.string(forKey: "ZephyrTheme")
        hasLaunchThemeOverride = launchTheme != nil
        if let theme = launchTheme { state.active = ThemeLibrary.preset(theme)?.id ?? theme }
        known[url] = try? Data(contentsOf: url)
        knownNames = customThemes
        loadActive()
        activate()
        watch()
    }

    // MARK: Changes from the app

    /// Change the active theme's file, then apply the saved values.
    func update(_ change: (inout AppearanceSettings) throws -> Void) throws {
        var next = state
        try next.prepareThemeFiles()
        let changed = try next.change(change)
        guard changed != settings || next != state else { return }
        state = next
        settings = changed
        record()
        activate()
    }

    func set(_ key: String, _ raw: String) {
        do { try update { try $0.set(key, raw) } } catch { NSSound.beep() }
    }

    func set(_ key: String, number: Double) {
        do { try update { try $0.set(key, value: .number(number)) } } catch { NSSound.beep() }
    }

    /// Make `name` (a preset id or a custom theme) the active theme.
    func use(_ name: String) {
        guard name != state.active else { return }
        state.active = name
        saveState()
        loadActive()
        activate()
    }

    /// A new custom theme: a copy of `source` (a built-in or a custom theme) as it is now, changes
    /// included, or of Zephyr's design.
    func newTheme(named raw: String, from source: String?) throws {
        let name = try ThemeLibrary.check(name: raw, in: folder)
        var probe = state
        probe.active = source ?? ThemeLibrary.defaultTheme
        try ThemeLibrary.save(probe.loadedSettings(), as: name, in: folder)
        use(name)
    }

    /// The active built-in theme's overrides, to restore them (Undo of Restore Defaults).
    var overrides: [String: AppearanceSettings.Value]? { state.currentOverrides(state.active) }

    /// Sets the active built-in theme's overrides: nil restores its defaults.
    func setOverrides(_ overrides: [String: AppearanceSettings.Value]?) {
        guard isPreset else { return }
        do {
            try state.prepareThemeFiles()
            try state.setOverrides(overrides, for: state.active)
        } catch { reportFileError(error); return }
        record()
        loadActive()
        activate()
    }

    func renameActive(to raw: String) throws {
        guard !isPreset else { return }
        let name = try ThemeLibrary.check(name: raw, in: folder, allowing: state.active)
        try ThemeLibrary.rename(state.active, to: name, in: folder)
        state.active = name
        saveState()
        loadActive()
        activate()
    }

    /// Moves the active custom theme's file to the Trash and switches to Zephyr's theme.
    func deleteActive() throws {
        guard !isPreset else { return }
        try ThemeLibrary.delete(state.active, in: folder)
        state.active = ThemeLibrary.defaultTheme
        saveState()
        loadActive()
        activate()
    }

    /// Keep custom themes in `folder` (nil: Zephyr's own). A custom theme that is not there gives
    /// way to Zephyr's.
    func setFolder(_ folder: URL?) {
        var next = state
        next.themesFolder = folder?.path
        do {
            // A new location inherits the user's existing built-in looks. Files already in the
            // destination belong to that folder and are never replaced by a folder switch.
            for preset in ThemeLibrary.presets where !FileManager.default.fileExists(atPath: ThemeLibrary.themeFile(preset.id, in: next.folder).path) {
                var source = state
                source.active = preset.id
                try ThemeLibrary.saveTheme(source.loadedSettings(), as: preset.id, in: next.folder)
            }
            next.migrate()
            try next.prepareThemeFiles()
        } catch { reportFileError(error); return }
        state = next
        if !isPreset, !customThemes.contains(state.active) { state.active = ThemeLibrary.defaultTheme }
        saveState()
        loadActive()
        activate()
        watch()
    }

    @discardableResult
    private func loadActive() -> Bool {
        if let preset = state.activePreset { state.active = preset.id }
        if !isPreset, !customThemes.contains(state.active) { state.active = ThemeLibrary.defaultTheme }
        let file = ThemeLibrary.themeFile(state.active, in: folder)
        known[file] = try? Data(contentsOf: file)
        do {
            settings = try state.loadedSettings()
            fileError = nil
            return true
        } catch {
            reportFileError(error)
            return false
        }
    }

    private func reportFileError(_ error: Error) {
        fileError = (error as? AppearanceSettings.SettingError)?.message ?? error.localizedDescription
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        DocumentWindowController.front?.showBanner(String(localized: "The theme file could not be loaded. Your last valid appearance is still in use."), symbol: "paintbrush")
    }

    private func saveState() {
        let data = state.json()
        known[url] = data
        try? state.save(to: url)
    }

    /// Remember our writes so the file watcher reports only external edits.
    private func record() {
        if isPreset { saveState() }
        let file = ThemeLibrary.themeFile(state.active, in: folder)
        known[file] = try? Data(contentsOf: file)
        fileError = nil
    }

    // MARK: Changes from outside (zephyr config, agents, an editor)

    /// Watch the folders: saves replace files, so watching a file itself would lose track.
    private func watch() {
        watchers.forEach { $0.cancel() }
        watchers = []
        for folder in Set([url.deletingLastPathComponent(), self.folder, ThemeLibrary.builtInFolder(in: self.folder)]) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadFromDisk() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Theme names last seen, so a theme added or removed outside updates the settings window.
    private var knownNames: [String] = []

    private func reloadFromDisk(banner: Bool = true) {
        let stateData = try? Data(contentsOf: url)
        let file = ThemeLibrary.themeFile(state.active, in: folder)
        let themeData = try? Data(contentsOf: file)
        let namesChanged = customThemes != knownNames
        knownNames = customThemes
        guard stateData != known[url] || themeData != known[file] else {
            if namesChanged { NotificationCenter.default.post(name: Self.didChange, object: nil) }
            return
        }
        let previous = (state, settings)
        known[url] = stateData
        let oldFolder = folder
        if let stateData { state = AppearanceState.parse(json: stateData) }
        if folder != oldFolder {
            do { try state.prepareThemeFiles() } catch { reportFileError(error); return }
            watch()
        }
        guard loadActive() else { return }
        guard state != previous.0 || settings != previous.1 else { return }
        activate()
        guard banner else { return }
        DocumentWindowController.front?.showBanner(String(localized: "The theme was changed outside Zephyr."), symbol: "paintbrush", actions: [
            (String(localized: "Undo"), { [weak self] in
                guard let self else { return }
                self.state = previous.0
                self.saveState()
                try? ThemeLibrary.saveTheme(previous.1, as: self.state.active, in: self.folder)
                self.loadActive()
                self.activate()
                DocumentWindowController.front?.showBanner(nil)
            }),
            (String(localized: "Keep"), { DocumentWindowController.front?.showBanner(nil) }),
        ])
    }

    // MARK: Changes from the built-in assistant

    /// An appearance tool call from the built-in assistant: the tools MCP clients use, applied at
    /// once and without the outside-change banner, since the assistant panel shows the change with
    /// its own Undo, which puts back every theme file and the state as they were.
    func perform(tool name: String, arguments: [String: Any]) -> (text: String, isError: Bool, undo: (() -> Void)?) {
        let files = [url] + (customThemes + ThemeLibrary.presets.map(\.id)).map { ThemeLibrary.themeFile($0, in: folder) }
        let before = files.compactMap { file in (try? Data(contentsOf: file)).map { (file, $0) } }
        let result = AppearanceTools.run(name, arguments: arguments, url: url)
        guard name == "set_appearance", !result.isError else { return (result.text, result.isError, nil) }
        pendingReload?.cancel()
        reloadFromDisk(banner: false)
        return (result.text, false, { [weak self] in
            for (file, data) in before { try? data.write(to: file, options: .atomic) }
            self?.pendingReload?.cancel()
            self?.reloadFromDisk(banner: false)
        })
    }

    // MARK: Applying

    /// Typography for new and open documents, the active palette, light or dark.
    private func activate() {
        // Publish persisted settings before process-only launch overrides so Finder never inherits a
        // -ZephyrSet snapshot. A -ZephyrTheme run is itself a temporary appearance and publishes no
        // replacement for Finder's existing snapshot.
        if !hasLaunchThemeOverride && !PreviewAppearance.isIsolatedRun { try? PreviewAppearance.publish(settings) }
        var effective = settings
        for (key, value) in launchOverrides { _ = try? effective.set(key, value) }
        let parsed = CustomStyle.parse(effective.string("css"), baseSize: effective.number("text.size") ?? 16).style
        typography = Typography(effective, css: parsed)
        Palette.configure(effective, css: parsed)
        // Only a change of this setting touches the app's appearance (snapshots force their own).
        let mode = effective.string("appearance")
        if mode != appliedMode {
            NSApp.appearance = mode == "light" ? NSAppearance(named: .aqua) : mode == "dark" ? NSAppearance(named: .darkAqua) : nil
            appliedMode = mode
        }
        // Layer-backed surfaces cache their colors: every view draws again with the new palette.
        for window in NSApp.windows { window.contentView.map(Self.redraw) }
        // The interface typeface, before the first window at launch; later, for every window open.
        if let old = Tokens.setInterfaceFont(effective.string("font.interface")) {
            for window in NSApp.windows { (window.contentView?.superview ?? window.contentView).map { Tokens.restyleInterface(in: $0, from: old) } }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        // Views tint their images for an appearance; a theme switch changes colors without one.
        view.viewDidChangeEffectiveAppearance()
        view.subviews.forEach(redraw)
    }

    // MARK: First run

    /// The library starts with the Zephyr theme. Typography used to live in user defaults (design
    /// 0.5); those values become changes to it, and the old keys go, so there is one source.
    private static func firstRun(_ state: AppearanceState) -> AppearanceState {
        var state = state
        var settings = AppearanceSettings()
        if let id = Bundle.main.bundleIdentifier, let domain = UserDefaults.standard.persistentDomain(forName: id) {
            let map: [(old: String, key: String)] = [("fontPreset", "font.body"), ("fontSize", "text.size"), ("measure", "text.width"),
                                                     ("lineSpacing", "text.lineHeight"), ("headingScale", "headings.scale"),
                                                     ("tableWidth", "table.width"), ("tableAlignment", "table.align"), ("customCSS", "css")]
            for (old, key) in map {
                guard let value = domain[old] else { continue }
                if let n = value as? NSNumber { try? settings.set(key, value: .number(n.doubleValue)) } else if let t = value as? String { try? settings.set(key, value: .text(t)) }
                UserDefaults.standard.removeObject(forKey: old)
            }
        }
        if !settings.overrides.isEmpty { state.adjustments[ThemeLibrary.defaultTheme] = settings.overrides }
        try? state.save()
        return state
    }
}
