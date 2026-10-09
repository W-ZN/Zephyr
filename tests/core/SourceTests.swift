import Foundation
import Testing
@testable import ZephyrCore

@Suite struct SourceDecoderTests {
    @Test(arguments: [
        "plain\nlines\n", "crlf\r\nlines\r\n", "mixed\r\nends\nhere\r", "", "no newline", "中文\r\n😀 emoji\n",
    ])
    func roundTrip(_ text: String) {
        for bom in [false, true] {
            var data = Data(bom ? [0xEF, 0xBB, 0xBF] : [])
            data.append(contentsOf: text.utf8)
            let (decoded, encoding) = SourceDecoder.decode(data)
            #expect(decoded == text)
            #expect(encoding.hasBOM == bom)
            #expect(encoding.isValidUTF8)
            #expect(SourceDecoder.encode(decoded, encoding: encoding) == data)
        }
    }

    @Test func lineEndings() {
        #expect(SourceDecoder.decode(Data("a\nb\n".utf8)).encoding.lineEnding == .lf)
        #expect(SourceDecoder.decode(Data("a\r\nb\r\n".utf8)).encoding.newline == "\r\n")
        #expect(SourceDecoder.decode(Data("a\r\nb\n".utf8)).encoding.lineEnding == .mixed)
        #expect(SourceDecoder.decode(Data("a".utf8)).encoding.lineEnding == LineEnding.none)
    }

    @Test func invalidUTF8IsFlagged() {
        let data = Data([0x61, 0xFF, 0x62])
        let (text, encoding) = SourceDecoder.decode(data)
        #expect(!encoding.isValidUTF8)
        #expect(text.hasPrefix("a") && text.hasSuffix("b"))
    }
}

@Suite struct TextLinesTests {
    @Test func mapsUTF8ColumnsToUTF16() {
        var t = TextLines("a中😀b\r\nsecond")
        #expect(t.lineStarts == [0, 7])
        #expect(t.offset(line: 1, utf8Column: 1) == 0)
        #expect(t.offset(line: 1, utf8Column: 2) == 1)      // after "a"
        #expect(t.offset(line: 1, utf8Column: 5) == 2)      // after "中" (3 bytes)
        #expect(t.offset(line: 1, utf8Column: 9) == 4)      // after "😀" (4 bytes, 2 units)
        #expect(t.offset(line: 2, utf8Column: 3) == 9)
        #expect(t.contentEnd(ofLine: 0) == 5)
    }

    @Test func longLinesUseCheckpoints() {
        let unit = "汉a😀"   // 3 + 1 + 4 bytes, 1 + 1 + 2 units
        let line = String(repeating: unit, count: 3000)
        var t = TextLines(line + "\nx")
        for k in stride(from: 0, to: 3000, by: 97) {
            #expect(t.offset(line: 1, utf8Column: k * 8 + 1) == k * 4)
            #expect(t.offset(line: 1, utf8Column: k * 8 + 4) == k * 4 + 1)
        }
        #expect(t.offset(line: 2, utf8Column: 1) == 12001)
    }
}

@Suite struct MathScannerTests {
    func spans(_ s: String) -> [String] {
        let t = TextLines(s)
        return MathScanner.scan(t).map { String(decoding: t.units[$0.content], as: UTF16.self) }
    }

    @Test func inlineRules() {
        #expect(spans("a $x^2$ b") == ["x^2"])
        #expect(spans("costs $5 and $10 today") == [])
        #expect(spans("escaped \\$x$ y$") == [])
        #expect(spans("code `$x$` and $y$") == ["y"])
        #expect(spans("$ x$ and $x $") == [])
        #expect(spans("inline $$a+b$$ display") == ["a+b"])
    }

    @Test func blocksAndFences() {
        #expect(spans("$$\n\\frac{a}{b}\n\n= c\n$$\n") == ["\n\\frac{a}{b}\n\n= c\n"])
        #expect(spans("```sh\necho $$\n```\nafter $z$") == ["z"])
        #expect(spans("para $a\n\nb$ end") == [])
        let blocks = MathScanner.scan(TextLines("> $$\n> x\n> $$\n"))
        #expect(blocks.count == 1 && blocks[0].isBlock)
    }

    @Test func maskKeepsUTF8Layout() {
        let s = "前 $\\alpha_中$ 后\n$$\nx_文\n$$"
        let t = TextLines(s)
        let masked = MathScanner.mask(s, spans: MathScanner.scan(t))
        #expect(masked.utf8.count == s.utf8.count)
        #expect(!masked.contains("alpha") && !masked.contains("文"))
        #expect(masked.split(separator: "\n", omittingEmptySubsequences: false).count == s.split(separator: "\n", omittingEmptySubsequences: false).count)
    }
}

@Suite struct FolderScannerTests {
    /// A frozen scope only shrinks: narrowing applies at once, widening never reaches a running task.
    @Test func frozenScopesOnlyNarrow() {
        let notes = URL(fileURLWithPath: "/tmp/zephyr-scope/notes"), sub = URL(fileURLWithPath: "/tmp/zephyr-scope/notes/sub")
        let parent = URL(fileURLWithPath: "/tmp/zephyr-scope"), other = URL(fileURLWithPath: "/tmp/zephyr-scope/other")
        #expect(ScopeResolver.narrowed(notes, to: notes) == notes.resolvingSymlinksInPath())
        #expect(ScopeResolver.narrowed(notes, to: sub) == sub.resolvingSymlinksInPath())
        #expect(ScopeResolver.narrowed(notes, to: parent) == notes.resolvingSymlinksInPath())
        #expect(ScopeResolver.narrowed(notes, to: other) == nil)
        #expect(ScopeResolver.narrowed(notes, to: nil) == nil)
        #expect(ScopeResolver.narrowed(nil, to: notes) == nil)
        #expect(ScopeResolver.narrowed(URL(fileURLWithPath: "/tmp/zephyr-scope/no"), to: URL(fileURLWithPath: "/tmp/zephyr-scope/notes")) == nil, "a sibling sharing a name prefix is outside")
    }

    @Test func searchFindsCaseInsensitiveAndCJK() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Title\n中文😀 Hello World\nsecond hello\n".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "nothing here\n知识库\n".write(to: dir.appendingPathComponent("sub/b.markdown"), atomically: true, encoding: .utf8)
        try "hello".write(to: dir.appendingPathComponent("node_modules/c.md"), atomically: true, encoding: .utf8)
        try "hello".write(to: dir.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        let files = FolderScanner.markdownFiles(in: dir)
        #expect(files.map(\.relativePath) == ["a.md", "sub/b.markdown"])
        var matches: [FolderScanner.Match] = []
        FolderScanner.search("HELLO", in: files, isCancelled: { false }) { matches += $0 }
        #expect(matches.map(\.line) == [2, 3])
        let text = "# Title\n中文😀 Hello World\nsecond hello\n" as NSString
        #expect(text.substring(with: NSRange(location: matches[0].location, length: 5)) == "Hello")
        #expect((matches[0].snippet as NSString).substring(with: matches[0].snippetRange) == "Hello")
        var cjk: [FolderScanner.Match] = []
        FolderScanner.search("知识", in: files, isCancelled: { false }) { cjk += $0 }
        #expect(cjk.count == 1 && cjk[0].file.relativePath == "sub/b.markdown" && cjk[0].line == 2)
    }
}
