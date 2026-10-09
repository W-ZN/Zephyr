import Foundation

/// A Markdown file inside a folder scope.
public struct ScopeFile: Hashable, Sendable {
    public let url: URL
    /// Path relative to the scope root, `/`-separated.
    public let relativePath: String

    public init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }

    public var name: String { url.lastPathComponent }
}

/// On-demand folder scanning (design §7, §12): no index, no cache, nothing written to disk.
public enum FolderScanner {
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdx"]
    /// Dependency, build and VCS folders that are never part of a reading scope.
    public static let skippedDirectories: Set<String> = [
        "node_modules", "build", "dist", "DerivedData", "Pods", "Carthage", "target", "vendor", "venv",
        "__pycache__", "site-packages",
    ]

    /// Markdown files under `root`, sorted by relative path. Hidden entries are skipped and
    /// symbolic links are never followed, so the scope cannot escape its root.
    public static func markdownFiles(in root: URL, limit: Int = 50_000, isCancelled: () -> Bool = { false }) -> [ScopeFile] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [ScopeFile] = []
        for case let url as URL in enumerator {
            if isCancelled() || files.count >= limit { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, markdownExtensions.contains(url.pathExtension.lowercased()) else { continue }
            // The enumerator may report /var for /private/var, so derive the relative path from depth.
            let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            files.append(ScopeFile(url: url, relativePath: relative))
        }
        files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return files
    }

    /// The minimal metadata Activity needs to compare two explicit scope scans. This is not an
    /// index: callers keep it only while the app is open, and scans remain on demand.
    public static func activityMetadata(for files: [ScopeFile]) -> [String: Activity.FileState] {
        var result: [String: Activity.FileState] = [:]
        for file in files {
            guard let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate,
                  let size = values.fileSize else { continue }
            result[file.url.standardizedFileURL.resolvingSymlinksInPath().path] = Activity.FileState(modified: Int64((modified.timeIntervalSince1970 * 1_000).rounded()), size: Int64(size))
        }
        return result
    }

    public struct Match: Sendable, Hashable {
        public let file: ScopeFile
        /// 1-based line number.
        public let line: Int
        /// The matching line, trimmed and shortened around the hit.
        public let snippet: String
        /// Range of the hit inside `snippet`.
        public let snippetRange: NSRange
        /// UTF-16 offset of the hit in the decoded file, for jumping to it.
        public let location: Int
    }

    public struct Limits: Sendable {
        public var maxResults = 500
        public var maxResultsPerFile = 50
        public var snippetLength = 120
        public init() {}
    }

    /// Literal search over UTF-8 bytes. ASCII letters match case-insensitively; everything else
    /// (CJK included) matches exactly, which needs no segmentation (design §12).
    public static func search(_ query: String, in files: [ScopeFile], limits: Limits = Limits(),
                              isCancelled: () -> Bool, onBatch: ([Match]) -> Void) {
        let needle = Array(query.utf8).map(lowerASCII)
        guard !needle.isEmpty else { return }
        var total = 0
        var batch: [Match] = []
        var lastFlush = Date()
        var buffer = [UInt8]()
        for file in files {
            if isCancelled() || total >= limits.maxResults { break }
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe), data.count >= needle.count else { continue }
            let matches = searchFile(data, needle: needle, file: file, buffer: &buffer, limit: min(limits.maxResultsPerFile, limits.maxResults - total), snippetLength: limits.snippetLength)
            total += matches.count
            batch += matches
            if !batch.isEmpty, batch.count >= 40 || Date().timeIntervalSince(lastFlush) > 0.05 {
                onBatch(batch)
                batch.removeAll()
                lastFlush = Date()
            }
        }
        if !batch.isEmpty, !isCancelled() { onBatch(batch) }
    }

    @inline(__always) static func lowerASCII(_ b: UInt8) -> UInt8 { b &- 0x41 < 26 ? b | 0x20 : b }

    static func searchFile(_ data: Data, needle: [UInt8], file: ScopeFile, buffer: inout [UInt8], limit: Int, snippetLength: Int) -> [Match] {
        let n = data.count
        if buffer.count < n { buffer = [UInt8](repeating: 0, count: n) }
        var matches: [Match] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let source = raw.bindMemory(to: UInt8.self)
            buffer.withUnsafeMutableBufferPointer { lower in
                for i in 0..<n { lower[i] = lowerASCII(source[i]) }
                needle.withUnsafeBufferPointer { q in
                    var offset = 0
                    var line = 1
                    var lineCountedTo = 0
                    var utf16 = 0
                    while offset <= n - q.count, matches.count < limit,
                          let hit = memmem(lower.baseAddress! + offset, n - offset, q.baseAddress!, q.count) {
                        let at = lower.baseAddress!.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                        for i in lineCountedTo..<at {
                            let b = source[i]
                            if b == 0x0A { line += 1 }
                            // UTF-16 length: one unit per scalar lead byte, two for 4-byte sequences.
                            if b & 0xC0 != 0x80 { utf16 += b >= 0xF0 ? 2 : 1 }
                        }
                        lineCountedTo = at
                        var start = at
                        while start > 0, source[start - 1] != 0x0A { start -= 1 }
                        var end = at + q.count
                        while end < n, source[end] != 0x0A, source[end] != 0x0D { end += 1 }
                        let prefix = String(decoding: UnsafeBufferPointer(rebasing: source[start..<at]), as: UTF8.self)
                        let hitText = String(decoding: UnsafeBufferPointer(rebasing: source[at..<(at + q.count)]), as: UTF8.self)
                        let suffix = String(decoding: UnsafeBufferPointer(rebasing: source[(at + q.count)..<end]), as: UTF8.self)
                        let (snippet, range) = makeSnippet(prefix: prefix, hit: hitText, suffix: suffix, length: snippetLength)
                        matches.append(Match(file: file, line: line, snippet: snippet, snippetRange: range, location: utf16))
                        // Next hit starts on the next line: one result per line is enough to navigate.
                        offset = end
                    }
                }
            }
        }
        return matches
    }

    static func makeSnippet(prefix: String, hit: String, suffix: String, length: Int) -> (String, NSRange) {
        var head = prefix.drop { $0 == " " || $0 == "\t" }
        let room = max(12, (length - hit.count) / 2)
        if head.count > room { head = "…" + head.suffix(room - 1) }
        var tail = Substring(suffix)
        if tail.count > length - head.count - hit.count { tail = tail.prefix(max(0, length - head.count - hit.count)) + "…" }
        let snippet = String(head) + hit + String(tail)
        return (snippet, NSRange(location: String(head).utf16.count, length: hit.utf16.count))
    }
}

/// Where a folder scope starts (design §7): explicit choice, then the deepest registered root,
/// then the nearest `.git`, then the file's parent folder.
public enum ScopeResolver {
    public static func root(for file: URL, registeredRoots: [URL]) -> URL {
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        let containing = registeredRoots
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
        if let containing { return containing }
        var dir = file.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        while dir.path != "/" && dir.path != home {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return file.deletingLastPathComponent()
    }

    /// The folder a running task or an agent share may still read after the window's scope
    /// changed (design §7, §20.1): what was frozen when it started, limited to what the window
    /// shows now. Narrowing takes effect at once; widening waits for the next task or share.
    public static func narrowed(_ frozen: URL?, to current: URL?) -> URL? {
        guard let frozen, let current else { return nil }
        let f = frozen.standardizedFileURL.resolvingSymlinksInPath(), c = current.standardizedFileURL.resolvingSymlinksInPath()
        if c.path == f.path || c.path.hasPrefix(f.path.hasSuffix("/") ? f.path : f.path + "/") { return c }
        if f.path.hasPrefix(c.path.hasSuffix("/") ? c.path : c.path + "/") { return f }
        return nil
    }
}
