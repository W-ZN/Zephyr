import Foundation
import Testing
@testable import ZephyrCore

@Suite struct RelatedSearchTests {
    /// A folder of files, removed when the closure ends.
    func scope(_ files: [String: String], _ body: ([ScopeFile], URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-related-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try body(FolderScanner.markdownFiles(in: dir), dir)
    }

    func run(_ query: String, _ files: [ScopeFile], expander: RelatedTermExpander? = nil) -> [RelatedSearch.Hit] {
        RelatedSearch.search(query, in: files, expander: expander, isCancelled: { false })
    }

    @Test func termsFoldCaseStemAndPairCJK() {
        let a = RelatedLexer.terms(of: "Searching SEARCHES search the")
        #expect(a.count == 1 && a[0].count == 3, "endings fold together and a stop word is dropped")
        #expect(RelatedLexer.terms(of: "内存占用").count == 3, "three overlapping pairs")
        #expect(RelatedLexer.terms(of: "内").count == 1, "a lone character stands for itself")
        #expect(RelatedLexer.terms(of: "ＷｅｂView").map(\.term) == RelatedLexer.terms(of: "webview").map(\.term), "full-width forms fold")
        #expect(RelatedLexer.terms(of: "snake_case").count == 2)
        #expect(RelatedLexer.terms(of: "，。！？").isEmpty)
    }

    @Test func findsInflectedWordsAndRanksTheBestPassageFirst() throws {
        try scope([
            "a.md": "# Notes\nWe talked about lunch and the weather.\n\n# Search\nSearching the folder uses BM25 ranking to order passages.\n",
            "b.md": "# Misc\nSearch is mentioned once here, in passing, among many other unrelated words about gardens and trees.\n",
        ]) { files, _ in
            let hits = run("how does ranking order the passages when searching", files)
            #expect(hits.first?.file.relativePath == "a.md" && hits.first?.heading == "Search")
            #expect(hits.first?.line == 5, "the line of the best term")
            #expect(hits.first.map { ($0.snippet as NSString).substring(with: $0.snippetRange) } != nil)
        }
    }

    @Test func chineseQueriesNeedNoSegmentation() throws {
        try scope([
            "x.md": "# 搜索\n不建索引，按需扫描文件夹；中文用相邻两字匹配，不需要分词。\n",
            "y.md": "# 其他\n今天天气很好，适合出门散步，也适合在家喝茶。\n",
        ]) { files, _ in
            let hits = run("中文为什么不需要分词", files)
            #expect(hits.first?.file.relativePath == "x.md")
            let first = try #require(hits.first)
            let text = "# 搜索\n不建索引，按需扫描文件夹；中文用相邻两字匹配，不需要分词。\n" as NSString
            #expect(text.substring(with: NSRange(location: first.location, length: first.length)) == (first.snippet as NSString).substring(with: first.snippetRange))
        }
    }

    @Test func aHeadingAndAFilePathCountMoreThanText() throws {
        try scope([
            "memory/budget.md": "# Overview\nSome sentences with nothing special in them at all, just filler text for the file.\n",
            "other.md": "# Overview\nThe memory budget is mentioned in the body of this file only once.\n",
        ]) { files, _ in
            let hits = run("memory budget", files)
            #expect(hits.map(\.file.relativePath) == ["memory/budget.md", "other.md"], "the path matches twice; the body once")
        }
    }

    @Test func oneHitPerSectionAndAFewPerFile() throws {
        var long = ""
        for i in 1...6 { long += "# Part \(i)\n" + String(repeating: "zebra stripes and more zebra words about zebra herds. ", count: 20) + "\n\n" }
        try scope(["z.md": long]) { files, _ in
            let hits = run("zebra", files)
            #expect(hits.count == 3, "at most three passages from one file")
            #expect(Set(hits.map(\.heading)).count == 3)
        }
    }

    @Test func offsetsCountUTF16AndSurrogates() throws {
        let text = "# T\n😀😀 intro line\n\nplain words\nthe quokka lives here\n"
        try scope(["q.md": text]) { files, _ in
            let hit = try #require(run("quokka", files).first)
            #expect(hit.line == 5)
            #expect((text as NSString).substring(with: NSRange(location: hit.location, length: hit.length)) == "quokka")
        }
    }

    @Test func nothingMatchesAndCancelledSearchesReturnNothing() throws {
        try scope(["a.md": "# A\nhello world\n"]) { files, _ in
            #expect(run("quokka", files).isEmpty)
            #expect(run("，。", files).isEmpty)
            #expect(RelatedSearch.search("hello", in: files, isCancelled: { true }).isEmpty)
        }
    }

    @Test func neighboursAddFilesThatSayItDifferently() throws {
        struct Fixed: RelatedTermExpander {
            func expansions(for query: String) -> [(word: String, weight: Float)] { [("annotators", 0.5)] }
        }
        try scope(["d.md": "# Cards\nWho are the annotators? People who wrote the labels.\n", "e.md": "# Other\nUnrelated content about trees.\n"]) { files, _ in
            #expect(run("who made the tags", files).isEmpty || run("who made the tags", files).first?.file.relativePath != "d.md")
            #expect(run("who made the tags", files, expander: Fixed()).first?.file.relativePath == "d.md")
        }
    }

    /// The retrieval benchmark of design §12 (its corpus and queries are kept with the round's
    /// evidence): `ZEPHYR_RELATED_EVAL=<dir holding corpus/, queries.json, sections.json>`.
    @Test func benchmark() throws {
        guard let dir = ProcessInfo.processInfo.environment["ZEPHYR_RELATED_EVAL"] else { return }
        struct Section: Decodable { var file: String, heading: String }
        struct Query: Decodable { var q: String, gold: [Int] }
        let root = URL(fileURLWithPath: dir)
        let sections = try JSONDecoder().decode([Section].self, from: Data(contentsOf: root.appendingPathComponent("sections.json")))
        let queries = try JSONDecoder().decode([Query].self, from: Data(contentsOf: root.appendingPathComponent("queries.json")))
        let files = FolderScanner.markdownFiles(in: root.appendingPathComponent("corpus"))
        var expander: RelatedTermExpander?
        #if canImport(NaturalLanguage)
        expander = ProcessInfo.processInfo.environment["ZEPHYR_RELATED_NOEXPAND"] == nil ? NeighborExpander() : nil
        #endif
        var ranks: [Int?] = []
        let started = Date()
        for q in queries {
            var limits = RelatedSearch.Limits()
            limits.maxResults = 50
            limits.maxPerFile = 50
            if let v = ProcessInfo.processInfo.environment["ZEPHYR_RELATED_PASSAGE"].flatMap(Int.init) { limits.passageBytes = v }
            let hits = RelatedSearch.search(q.q, in: files, limits: limits, expander: expander, isCancelled: { false })
            let gold = Set(q.gold.map { sections[$0] }.map { "\($0.file)#\($0.heading)" })
            let rank = hits.firstIndex { gold.contains("\($0.file.relativePath)#\($0.heading ?? ($0.file.name))") }
            ranks.append(rank.map { $0 + 1 })
        }
        let ms = Date().timeIntervalSince(started) * 1000 / Double(queries.count)
        func recall(_ k: Int) -> Double { Double(ranks.filter { $0 != nil && $0! <= k }.count) / Double(ranks.count) }
        let mrr = ranks.reduce(0.0) { $0 + ($1.map { 1.0 / Double($0) } ?? 0) } / Double(ranks.count)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "RELATED-EVAL files %d queries %d  R@1 %.2f R@5 %.2f R@10 %.2f R@20 %.2f R@50 %.2f MRR %.3f  %.1f ms/query  peak RSS %d MB", files.count, queries.count, recall(1), recall(5), recall(10), recall(20), recall(50), mrr, ms, usage.ru_maxrss / 1_048_576))
        for (q, r) in zip(queries, ranks) { print("  \(r.map(String.init) ?? "-")\t\(q.q)") }
    }
}
