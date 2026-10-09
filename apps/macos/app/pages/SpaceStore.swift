import AppKit
import ZephyrCore

/// The notes behind the app's panels (design §8.3): `Today/<date>.md` and `Goals.md` in
/// `~/Library/Application Support/Zephyr/Space`, plain Markdown the user can open and agents can
/// read. A note is created only when something is written to it. A change from a panel goes
/// through the note's editor when it is open (so it is one undoable edit there), and otherwise is
/// written in place; either way only the changed characters change.
@MainActor final class SpaceStore {
    static let shared = SpaceStore()
    static let didChange = Notification.Name("ZephyrSpaceDidChange")
    /// A page's note was renamed (`userInfo["to"]` is its new address) or moved to the Trash (no
    /// `to`); `object` is its old address. Every window follows it: its history, the page it shows.
    static let pageMoved = Notification.Name("ZephyrSpacePageMoved")

    let root = Space.folder
    private var activityStore: ActivityStore?
    private var activityScanSequence: UInt64 = 0

    func daily(_ date: Date = Date()) -> URL { Space.dailyURL(date) }
    var goals: URL { Space.goalsURL }

    private func activity() throws -> ActivityStore {
        if let activityStore { return activityStore }
        let store = try ActivityStore(url: Space.activityURL)
        activityStore = store
        return store
    }

    /// An opened document is one activity visit for its local calendar day. The core store keeps
    /// only an opaque, deduplicated path identifier; content is never copied.
    func recordActivityOpen(_ url: URL) throws {
        if try activity().recordOpen(activityPath(url)) {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// A document write completed successfully. Saves and metadata refreshes both deduplicate on
    /// the same opaque path identifier for the local day.
    func recordActivityModified(_ url: URL) throws {
        if try activity().recordModified(activityPath(url)) {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// Compare an explicitly requested completed scope scan with the in-memory baseline. The
    /// first scan after launch only establishes that baseline.
    @discardableResult
    func beginActivityScopeScan() -> UInt64 {
        activityScanSequence &+= 1
        return activityScanSequence
    }

    func observeActivityScope(_ root: URL, metadata: [String: Activity.FileState], sequence: UInt64) throws -> Activity.Diff? {
        let diff = try activity().observe(scopeRoot: root, files: metadata, sequence: sequence)
        if diff != nil { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        return diff
    }

    func activityHistory(days: Int) -> [Activity.Day] {
        (try? activity().history(days: days)) ?? []
    }

    private func activityPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// What a new note starts with: its title.
    func template(for url: URL) -> String {
        if url == goals { return "# " + String(localized: "Goals") + "\n" }
        if url.deletingLastPathComponent().standardizedFileURL == Board.folder.standardizedFileURL { return "# " + url.deletingPathExtension().lastPathComponent + "\n" }
        let date = Space.date(ofDaily: url.lastPathComponent) ?? Date()
        return "# " + date.formatted(.dateTime.weekday(.wide).month(.wide).day()) + "\n"
    }

    private func open(_ url: URL) -> MarkdownDocument? {
        NSDocumentController.shared.documents.first { $0.fileURL?.standardizedFileURL == url.standardizedFileURL } as? MarkdownDocument
    }

    /// The note as it is now: the open editor's text, the file's, or its template before it exists.
    /// Panels make their patches against this.
    func text(of url: URL) -> String {
        if let editor = open(url)?.editor { return editor.string }
        guard let data = try? Data(contentsOf: url) else { return template(for: url) }
        return SourceDecoder.decode(data).text
    }

    /// The note, created from its template, for opening in a window.
    func ensure(_ url: URL) throws -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { try write(template(for: url), to: url) }
        return url
    }

    /// Applies `patch` (made against `text(of:)`, or the template for a note not yet written).
    /// A note that cannot be written says why, and the pages show it unchanged.
    func apply(_ patch: TextPatch, to url: URL, actionName: String) {
        if let doc = open(url), let editor = doc.editor {
            editor.apply([patch], actionName: actionName)
            doc.autosave(withImplicitCancellability: false) { _ in }
        } else {
            do {
                // Another writer got there first: nothing is written, and the pages read the note again.
                if try !write(patch, to: url, base: text(of: url)) { NSSound.beep() }
            } catch {
                NSApp.presentError(error)
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: url)
    }

    /// Checks or clears `item` where it is in the note now (`Space.locate`): a page shows what it
    /// read last, and the note may have changed since. When the task is gone or already changed,
    /// nothing is written and the pages read the note again.
    func toggle(_ item: Space.Item, in url: URL) {
        guard let current = Space.locate(item, in: text(of: url) as NSString) else {
            NotificationCenter.default.post(name: Self.didChange, object: url)
            return
        }
        apply(Space.toggle(current), to: url, actionName: current.done ? String(localized: "Uncheck Task") : String(localized: "Check Task"))
    }

    /// Writes `patch`, made against `base`, over the note as it is on disk, in one coordinated
    /// write: when another writer changed the note in between, nothing is written (false). The note
    /// keeps its byte-order mark; one that is not valid UTF-8 is left as it is (principle 2).
    private func write(_ patch: TextPatch, to url: URL, base: String) throws -> Bool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = template(for: url)
        var coordination: NSError?
        var failure: Error?
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordination) { target in
            do {
                var (text, encoding) = (template, SourceEncoding(hasBOM: false, isValidUTF8: true, lineEnding: .lf))
                if FileManager.default.fileExists(atPath: target.path) { (text, encoding) = SourceDecoder.decode(try Data(contentsOf: target)) }
                guard encoding.isValidUTF8 else {
                    throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSLocalizedDescriptionKey: String(localized: "This note is not valid UTF-8, so Zephyr leaves it unchanged.")])
                }
                guard text.utf8.elementsEqual(base.utf8) else { return }
                try SourceDecoder.encode(patch.applied(to: text), encoding: encoding).write(to: target, options: .atomic)
                written = true
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
        return written
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordination) { target in
            do { try Data(text.utf8).write(to: target, options: .atomic) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }

    // MARK: Pages

    /// The reader's pages: the notes in `Space/Pages`, by name.
    func boards() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Board.folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "md" }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func page(_ url: URL) -> Board.Page { Board.page(in: text(of: url) as NSString) }

    /// A new page named after `title`, numbered when the name is taken; `text` makes its note
    /// from the title it ends up with. Announced only once it is written.
    func createBoard(title: String, text: (String) -> String) throws -> URL {
        let taken = Set(boards().map(\.lastPathComponent))
        let url = Board.folder.appendingPathComponent(Board.fileName(for: title, taken: taken))
        try write(text(url.deletingPathExtension().lastPathComponent), to: url)
        NotificationCenter.default.post(name: Self.didChange, object: url)
        return url
    }

    /// Moves a page's file to the name `title` gives, when that name is free and the note is not
    /// open in a window; the page's address afterwards. Windows follow the new address at once
    /// (`pageMoved`); the caller then retitles the note (`Board.retitling`), which announces the
    /// change of its text.
    func moveBoard(_ url: URL, toTitle title: String) -> URL {
        let taken = Set(boards().map(\.lastPathComponent)).subtracting([url.lastPathComponent])
        let target = url.deletingLastPathComponent().appendingPathComponent(Board.fileName(for: title, taken: taken))
        guard target.lastPathComponent != url.lastPathComponent, open(url) == nil else { return url }
        var error: NSError?
        var moved = url
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &error) { from, to in
            if (try? FileManager.default.moveItem(at: from, to: to)) != nil { moved = target }
        }
        if moved != url { NotificationCenter.default.post(name: Self.pageMoved, object: url, userInfo: ["to": moved]) }
        return moved
    }

    /// A page to the Trash (it can be put back from there); windows showing it move on.
    func trashBoard(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.recycle([url])
        NotificationCenter.default.post(name: Self.pageMoved, object: url)
        NotificationCenter.default.post(name: Self.didChange, object: url)
    }

}

/// Markdown files opened lately, in any window and any folder (the sidebar's Recent): an app
/// preference of paths, never anything written beside the files.
enum RecentPages {
    static let didChange = Notification.Name("ZephyrRecentPagesDidChange")
    private static let key = "recentPages"
    static let limit = 8

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func note(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func remove(_ url: URL) {
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != url.path }, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
