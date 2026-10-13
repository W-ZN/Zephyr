import Foundation

/// Extra words close in meaning to a query's words, each with a weight below 1 (the system's
/// language data in the app; nothing here depends on it, and a search without one still works).
public protocol RelatedTermExpander: Sendable {
    func expansions(for query: String) -> [(word: String, weight: Float)]
}

/// Ranked search by meaning-ish relevance (design §12): the files are read once per query,
/// split into passages under their headings, and scored with BM25 over words and CJK character
/// pairs, a heading and the file's path counting more than the text. Nothing is indexed, cached or
/// kept between queries, and nothing runs when no query does. A question in other words than the
/// text's finds it as far as they share terms; `RelatedTermExpander` adds near neighbours of each
/// word at a low weight.
public enum RelatedSearch {
    public struct Limits: Sendable {
        public var maxResults = 20
        public var maxPerFile = 3
        public var snippetLength = 120
        /// Threads reading files at once: a few, so the machine stays free for the person typing.
        public var workers = 3
        /// A passage ends at the first blank line after this many bytes (and at any heading).
        public var passageBytes = 700
        public var maxFileBytes = 32 << 20
        public init() {}
    }

    public struct Hit: Sendable, Hashable {
        public let file: ScopeFile
        /// The heading the passage sits under, if any.
        public let heading: String?
        /// 1-based line of the best matching term.
        public let line: Int
        public let snippet: String
        public let snippetRange: NSRange
        /// UTF-16 offset in the decoded file of the matching term, and its length, for jumping to it.
        public let location: Int
        public let length: Int
        public let score: Float
    }

    /// How many terms a query has, to tell a one-word lookup (which the literal search answers
    /// well) from a question in words.
    public static func termCount(of query: String) -> Int { RelatedLexer.terms(of: query).count }

    private static let k1: Float = 1.2, b: Float = 0.75
    /// How much more a term counts in a heading or the file's path than in the text.
    private static let fieldBoost: Float = 3
    private static let maxTerms = 40
    private static let maxSections = 20_000

    private struct Passage {
        var start: Int
        var end: Int
        var section: Int
        /// Where this passage's counts begin in the file's pool.
        var counts: Int
        var length: Float
    }

    /// What one file contributes: the passages that hold a query term, and the totals every
    /// passage (hit or not) adds to the corpus statistics.
    private final class FileScan {
        let file: Int
        var passages: [Passage] = []
        var pool: [UInt8] = []
        var passageCount = 0
        var totalLength: Float = 0
        var df: [Int]
        /// Headings by the byte offset of the section's first line, -1 before any heading.
        var headings: [Int: Range<Int>] = [:]
        init(file: Int, terms: Int) {
            self.file = file
            df = [Int](repeating: 0, count: terms)
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var scans: [FileScan] = []
        private var next = 0
        func take(limit: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard next < limit else { return nil }
            next += 1
            return next - 1
        }
        func add(_ scan: FileScan) {
            lock.lock(); defer { lock.unlock() }
            scans.append(scan)
        }
        var all: [FileScan] { lock.lock(); defer { lock.unlock() }; return scans }
    }

    public static func search(_ query: String, in files: [ScopeFile], limits: Limits = Limits(), expander: RelatedTermExpander? = nil,
                              isCancelled: @escaping @Sendable () -> Bool) -> [Hit] {
        // Terms: the query's own at weight 1 (twice said, a little more), then neighbours.
        var weights: [UInt64: Float] = [:]
        var order: [UInt64] = []
        for (term, count) in RelatedLexer.terms(of: query) where weights[term] == nil {
            weights[term] = Float(min(count, 2))
            order.append(term)
        }
        guard !order.isEmpty else { return [] }
        for (word, weight) in expander?.expansions(for: query) ?? [] where order.count < maxTerms {
            for (term, _) in RelatedLexer.terms(of: word) where weights[term] == nil && order.count < maxTerms {
                weights[term] = weight
                order.append(term)
            }
        }
        let index = TermTable(order)
        let termWeights = order.map { weights[$0]! }

        let collector = Collector()
        let workers = max(1, min(limits.workers, ProcessInfo.processInfo.activeProcessorCount - 1, files.count))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var scratch = [UInt8]()
            while !isCancelled(), let i = collector.take(limit: files.count) {
                if let result = scanFile(files[i], at: i, terms: order.count, index: index, limits: limits, scratch: &scratch, isCancelled: isCancelled) { collector.add(result) }
            }
        }
        guard !isCancelled() else { return [] }

        // BM25 over every passage of every file.
        let scans = collector.all
        let n = Float(scans.reduce(0) { $0 + $1.passageCount })
        guard n > 0 else { return [] }
        let average = scans.reduce(0) { $0 + $1.totalLength } / n
        var df = [Int](repeating: 0, count: order.count)
        for s in scans { for t in df.indices { df[t] += s.df[t] } }
        let idf = df.map { log(1 + (n - Float($0) + 0.5) / (Float($0) + 0.5)) }

        struct Scored { var file: Int, section: Int, start: Int, end: Int, score: Float }
        var scored: [Scored] = []
        for s in scans {
            for p in s.passages {
                var score: Float = 0
                let norm = k1 * (1 - b + b * p.length / average)
                for t in order.indices {
                    let f = Float(s.pool[p.counts + t])
                    if f > 0 { score += termWeights[t] * idf[t] * f * (k1 + 1) / (f + norm) }
                }
                scored.append(Scored(file: s.file, section: p.section, start: p.start, end: p.end, score: score))
            }
        }
        scored.sort { $0.score > $1.score }

        // One passage per section, a few per file.
        var seen = Set<[Int]>()
        var perFile: [Int: Int] = [:]
        var picked: [Scored] = []
        for s in scored {
            if picked.count >= limits.maxResults { break }
            guard seen.insert([s.file, s.section]).inserted, perFile[s.file, default: 0] < limits.maxPerFile else { continue }
            perFile[s.file, default: 0] += 1
            picked.append(s)
        }

        let headings = Dictionary(uniqueKeysWithValues: scans.map { ($0.file, $0.headings) })
        let termScores = Dictionary(uniqueKeysWithValues: order.indices.map { (order[$0], idf[$0] * termWeights[$0]) })
        var scratch = [UInt8]()
        var hits: [Hit] = []
        for p in picked {
            if let h = hit(files[p.file], start: p.start, end: p.end, score: p.score, heading: headings[p.file]?[p.section],
                           termScores: termScores, limits: limits, scratch: &scratch) { hits.append(h) }
        }
        return hits
    }

    // MARK: Scanning

    private static func scanFile(_ file: ScopeFile, at fileIndex: Int, terms: Int, index: TermTable, limits: Limits, scratch: inout [UInt8], isCancelled: @Sendable () -> Bool) -> FileScan? {
        guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe), !data.isEmpty, data.count <= limits.maxFileBytes else { return nil }
        let T = terms
        let scan = FileScan(file: fileIndex, terms: T)
        // The path counts as one more heading over the whole file.
        var pathCounts = [UInt8](repeating: 0, count: T)
        var pathLength: Float = 0
        let pathBytes = Array(((file.relativePath as NSString).deletingPathExtension).lowercased().utf8)
        pathBytes.withUnsafeBufferPointer { p in
            RelatedLexer.scan(p, 0, p.count, scratch: &scratch) { term, _, _ in
                pathLength += 1
                if let t = index[term], pathCounts[t] < 255 { pathCounts[t] += 1 }
            }
        }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var counts = [UInt16](repeating: 0, count: T)
            var headingCounts = [UInt16](repeating: 0, count: T)
            var headingLength: Float = 0
            var section = -1
            scan.headings[-1] = 0..<0
            var passageStart = 0, passageLength: Float = 0, passageBytes = 0
            var inFence = false, fenceMark: UInt8 = 0

            func flush(upTo end: Int) {
                defer {
                    for t in 0..<T { counts[t] = 0 }
                    passageLength = 0
                    passageBytes = 0
                }
                guard passageLength > 0 else { return }
                let length = passageLength + fieldBoost * (headingLength + pathLength)
                scan.passageCount += 1
                scan.totalLength += length
                var hit = false
                var combined = [UInt8](repeating: 0, count: T)
                for t in 0..<T {
                    let c = Float(counts[t]) + fieldBoost * Float(headingCounts[t]) + fieldBoost * Float(pathCounts[t])
                    combined[t] = UInt8(min(c, 255))
                    if combined[t] > 0 { scan.df[t] += 1; hit = true }
                }
                guard hit else { return }
                scan.passages.append(Passage(start: passageStart, end: end, section: section, counts: scan.pool.count, length: length))
                scan.pool.append(contentsOf: combined)
            }

            var lineStart = 0
            var lines = 0
            while lineStart < n {
                lines += 1
                if lines & 0x3FF == 0, isCancelled() { return }
                var lineEnd = lineStart
                if let hit = memchr(bytes.baseAddress! + lineStart, 0x0A, n - lineStart) {
                    lineEnd = bytes.baseAddress!.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                } else {
                    lineEnd = n
                }
                var contentEnd = lineEnd
                if contentEnd > lineStart, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
                let next = min(n, lineEnd + 1)

                // Fences: code is text to search, but a `#` inside it is not a heading.
                var k = lineStart
                while k < contentEnd, k - lineStart < 3, bytes[k] == 0x20 { k += 1 }
                if k + 2 < contentEnd, bytes[k] == 0x60 || bytes[k] == 0x7E, bytes[k + 1] == bytes[k], bytes[k + 2] == bytes[k] {
                    if !inFence { inFence = true; fenceMark = bytes[k] } else if bytes[k] == fenceMark { inFence = false }
                }
                if !inFence, k < contentEnd, bytes[k] == 0x23 {
                    var h = k
                    while h < contentEnd, bytes[h] == 0x23 { h += 1 }
                    if h - k <= 6, h == contentEnd || bytes[h] == 0x20 || bytes[h] == 0x09 {
                        flush(upTo: lineStart)
                        while h < contentEnd, bytes[h] == 0x20 || bytes[h] == 0x09 { h += 1 }
                        var e = contentEnd
                        while e > h, bytes[e - 1] == 0x23 || bytes[e - 1] == 0x20 { e -= 1 }
                        section = lineStart
                        scan.headings[lineStart] = h..<e
                        for t in 0..<T { headingCounts[t] = 0 }
                        headingLength = 0
                        RelatedLexer.scan(bytes, h, e, scratch: &scratch) { term, _, _ in
                            headingLength += 1
                            if let t = index[term] { headingCounts[t] += 1 }
                        }
                        passageStart = next
                        lineStart = next
                        continue
                    }
                }

                let before = passageLength
                RelatedLexer.scan(bytes, lineStart, contentEnd, scratch: &scratch) { term, _, _ in
                    passageLength += 1
                    if let t = index[term] { counts[t] &+= 1 }
                }
                if passageLength == before, passageLength == 0 { passageStart = next }
                passageBytes += next - lineStart
                let blank = passageLength == before
                if passageBytes >= limits.passageBytes, blank || passageBytes >= limits.passageBytes * 3 {
                    flush(upTo: next)
                    passageStart = next
                }
                lineStart = next
            }
            flush(upTo: n)
        }
        // Many sections would make the per-file table the biggest thing in memory.
        if scan.headings.count > maxSections { scan.headings = [:] }
        return scan
    }

    // MARK: Results

    private static func hit(_ file: ScopeFile, start: Int, end: Int, score: Float, heading headings: Range<Int>?,
                            termScores: [UInt64: Float], limits: Limits, scratch: inout [UInt8]) -> Hit? {
        guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe), end <= data.count else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Hit? in
            let bytes = raw.bindMemory(to: UInt8.self)
            // The line of the passage that holds the most telling terms, and the best one there;
            // the heading itself when only the heading matched.
            var found: (Int, Int)?
            var lineScore: Float = 0, bestLine: Float = 0, lineBest: Float = 0
            func newline(from i: Int) -> Int {
                guard i < end, let p = memchr(bytes.baseAddress! + i, 0x0A, end - i) else { return end }
                return bytes.baseAddress!.distance(to: p.assumingMemoryBound(to: UInt8.self))
            }
            var lineEnding = newline(from: start)
            var lineTerms = Set<UInt64>()
            var lineHit: (Int, Int)?
            func endLine() {
                if lineScore > bestLine { bestLine = lineScore; found = lineHit }
                lineScore = 0
                lineBest = 0
                lineHit = nil
                lineTerms.removeAll(keepingCapacity: true)
            }
            RelatedLexer.scan(bytes, start, end, scratch: &scratch) { term, a, z in
                if a >= lineEnding { endLine(); lineEnding = newline(from: a) }
                guard let score = termScores[term] else { return }
                if lineTerms.insert(term).inserted { lineScore += score }
                if score > lineBest { lineBest = score; lineHit = (a, z) }
            }
            endLine()
            var headingText: String?
            if let h = headings, !h.isEmpty { headingText = String(decoding: UnsafeBufferPointer(rebasing: bytes[h]), as: UTF8.self) }
            let (a, z): (Int, Int)
            if let found { (a, z) = found } else if let h = headings, !h.isEmpty { (a, z) = (h.lowerBound, h.upperBound) } else { (a, z) = (start, min(end, start + 1)) }
            var line = 1, utf16 = 0, lineStart = 0
            for i in 0..<a {
                let c = bytes[i]
                if c == 0x0A { line += 1; lineStart = i + 1 }
                if c & 0xC0 != 0x80 { utf16 += c >= 0xF0 ? 2 : 1 }
            }
            var lineEnd = z
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A, bytes[lineEnd] != 0x0D { lineEnd += 1 }
            func text(_ r: Range<Int>) -> String { String(decoding: UnsafeBufferPointer(rebasing: bytes[r]), as: UTF8.self) }
            let hitText = text(a..<z)
            let (snippet, range) = FolderScanner.makeSnippet(prefix: text(lineStart..<a), hit: hitText, suffix: text(z..<lineEnd), length: limits.snippetLength)
            return Hit(file: file, heading: headingText, line: line, snippet: snippet, snippetRange: range, location: utf16,
                       length: hitText.utf16.count, score: score)
        }
    }
}
