import Foundation

/// Activity is deliberately a small, app-owned record rather than an index. It remembers which
/// Markdown paths Zephyr opened on each day (as opaque identifiers), plus folder changes it saw
/// when the reader explicitly refreshed a scope. Folder metadata lives only in memory, so the
/// first scan after launch is always a baseline. Scope metadata keys are canonical absolute
/// paths, so a save and a later scan share one daily file identifier.
public enum Activity {
    public struct FileState: Codable, Equatable, Sendable {
        public var modified: Int64
        public var size: Int64

        public init(modified: Int64, size: Int64) {
            self.modified = modified
            self.size = size
        }
    }

    public struct Day: Codable, Equatable, Sendable {
        public var date: String
        public var opened: Set<String>
        public var added: Set<String>
        public var removed: Set<String>
        public var modified: Set<String>
        /// A bounded store can preserve exact per-day uniqueness until this flag is set. The UI
        /// renders a trailing `+` then, rather than implying a precise count it cannot retain.
        public var saturated: Bool

        public init(date: String, opened: Set<String> = [], added: Set<String> = [], removed: Set<String> = [], modified: Set<String> = [], saturated: Bool = false) {
            self.date = date
            self.opened = opened
            self.added = added
            self.removed = removed
            self.modified = modified
            self.saturated = saturated
        }

        public var observedChanges: Int { added.count + removed.count + modified.count }
        public var total: Int { opened.count + observedChanges }
        public var identifierCount: Int { total }
    }

    public struct Diff: Equatable, Sendable {
        public var added: Int
        public var removed: Int
        public var modified: Int

        public init(added: Int, removed: Int, modified: Int) {
            self.added = added
            self.removed = removed
            self.modified = modified
        }
    }
}

/// Bounded persistence for activity summaries. The disk format has no folder inventory or file
/// contents; the in-memory baseline is discarded when the app quits.
public final class ActivityStore {
    private struct Archive: Codable {
        var version = 1
        var days: [Activity.Day] = []
    }

    public static let maximumDays = 365
    public static let maximumBytes = 1_500_000
    /// Keeps even a pathological single day far below the two-megabyte app-data budget.
    public static let maximumIdentifiersPerDay = 12_000
    private static let maximumBaselines = 4

    private let url: URL
    private let calendar: Calendar
    private var archive: Archive
    private var baselines: [String: [String: Activity.FileState]] = [:]
    private var baselineOrder: [String] = []
    private var baselineSequences: [String: UInt64] = [:]

    public init(url: URL, calendar: Calendar = .current) throws {
        self.url = url
        self.calendar = calendar
        if FileManager.default.fileExists(atPath: url.path) {
            archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        } else {
            archive = Archive()
        }
        trimDays()
    }

    public var days: [Activity.Day] { archive.days }

    @discardableResult
    public func recordOpen(_ path: String, on date: Date = Date()) throws -> Bool {
        let identifier = Self.identifier(for: Self.canonicalPath(path))
        let changed = update(date, inserting: identifier, into: \.opened)
        if changed { try persist() }
        return changed
    }

    /// A successful save is one changed file for the day, regardless of how many edits produced
    /// it. Metadata refreshes use the same absolute-path set, so the two observation paths never
    /// double-count.
    @discardableResult
    public func recordModified(_ path: String, on date: Date = Date()) throws -> Bool {
        let changed = update(date, inserting: Self.identifier(for: Self.canonicalPath(path)), into: \.modified)
        if changed { try persist() }
        return changed
    }

    /// Returns nil for a scope's first observation in this process. It is a baseline, not a
    /// burst of added files. Later calls compare only metadata supplied by the caller. A sequence
    /// lets a shared store reject an older scan that finishes after a newer scan of the same root.
    @discardableResult
    public func observe(scopeRoot: URL, files: [String: Activity.FileState], sequence: UInt64? = nil, on date: Date = Date()) throws -> Activity.Diff? {
        let root = scopeRoot.standardizedFileURL.resolvingSymlinksInPath().path
        if let sequence, let previous = baselineSequences[root], sequence <= previous { return nil }
        // FolderScanner supplies canonical absolute keys from its resolved scope root.
        let canonicalFiles = files
        guard let before = baselines[root] else {
            if baselines.count >= Self.maximumBaselines, let oldest = baselineOrder.first {
                baselines.removeValue(forKey: oldest)
                baselineSequences.removeValue(forKey: oldest)
                baselineOrder.removeFirst()
            }
            baselines[root] = canonicalFiles
            baselineOrder.append(root)
            if let sequence { baselineSequences[root] = sequence }
            return nil
        }
        let added = Set(canonicalFiles.keys).subtracting(before.keys)
        let removed = Set(before.keys).subtracting(canonicalFiles.keys)
        let changed = Set(canonicalFiles.keys).intersection(before.keys).filter { canonicalFiles[$0] != before[$0] }
        baselines[root] = canonicalFiles
        baselineOrder.removeAll { $0 == root }
        baselineOrder.append(root)
        if let sequence { baselineSequences[root] = sequence }
        guard !added.isEmpty || !removed.isEmpty || !changed.isEmpty else { return Activity.Diff(added: 0, removed: 0, modified: 0) }
        var changedArchive = false
        for path in added { changedArchive = update(date, inserting: Self.identifier(for: path), into: \.added) || changedArchive }
        for path in removed { changedArchive = update(date, inserting: Self.identifier(for: path), into: \.removed) || changedArchive }
        for path in changed { changedArchive = update(date, inserting: Self.identifier(for: path), into: \.modified) || changedArchive }
        if changedArchive { try persist() }
        return Activity.Diff(added: added.count, removed: removed.count, modified: changed.count)
    }

    public func history(days: Int, ending date: Date = Date()) -> [Activity.Day] {
        let end = calendar.startOfDay(for: date)
        let requested = (0..<max(0, days)).compactMap { calendar.date(byAdding: .day, value: -$0, to: end) }.reversed()
        let byDate = Dictionary(uniqueKeysWithValues: archive.days.map { ($0.date, $0) })
        return requested.map { byDate[Self.dayName($0, calendar: calendar)] ?? Activity.Day(date: Self.dayName($0, calendar: calendar)) }
    }

    @discardableResult
    private func update(_ date: Date, inserting identifier: String, into keyPath: WritableKeyPath<Activity.Day, Set<String>>) -> Bool {
        let key = Self.dayName(date, calendar: calendar)
        let index: Int
        if let existing = archive.days.firstIndex(where: { $0.date == key }) {
            index = existing
        } else {
            archive.days.append(Activity.Day(date: key))
            archive.days.sort { $0.date < $1.date }
            index = archive.days.firstIndex(where: { $0.date == key })!
        }
        if archive.days[index][keyPath: keyPath].contains(identifier) { return false }
        guard archive.days[index].identifierCount < Self.maximumIdentifiersPerDay else {
            let changed = !archive.days[index].saturated
            archive.days[index].saturated = true
            return changed
        }
        archive.days[index][keyPath: keyPath].insert(identifier)
        trimDays()
        return true
    }

    private func trimDays() {
        if archive.days.count > Self.maximumDays { archive.days.removeFirst(archive.days.count - Self.maximumDays) }
    }

    private func persist() throws {
        trimDays()
        var data = try JSONEncoder().encode(archive)
        while data.count > Self.maximumBytes, archive.days.count > 1 {
            archive.days.removeFirst()
            data = try JSONEncoder().encode(archive)
        }
        // The per-day identifier cap makes this an assertion of the storage contract rather than
        // silently allowing a single huge day to exceed it.
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func dayName(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A stable FNV-1a identifier keeps path names out of the activity store while preserving
    /// per-day uniqueness across launches.
    private static func identifier(for path: String) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return String(value, radix: 16)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
