import Foundation
import Testing
@testable import ZephyrCore

@Suite struct ChunkIndexTests {
    func texts(_ s: String) -> [String] {
        let ns = s as NSString
        return ChunkIndex(text: ns).chunks.map { ns.substring(with: $0.range) }
    }

    @Test func splitsAtBlankLines() {
        #expect(texts("a\nb\n\nc\n\n\nd") == ["a\nb\n\n", "c\n\n\n", "d"])
        #expect(texts("") == [""])
        #expect(texts("\n\nfirst") == ["\n\nfirst"])
    }

    @Test func keepsOpaqueBlocksTogether() {
        #expect(texts("```\na\n\nb\n```\n\nc") == ["```\na\n\nb\n```\n\n", "c"])
        #expect(texts("$$\nx\n\ny\n$$\n\nz") == ["$$\nx\n\ny\n$$\n\n", "z"])
        #expect(texts("<!--\nx\n\ny -->\n\nz") == ["<!--\nx\n\ny -->\n\n", "z"])
        // Items of one loose list stay in one chunk, so later items are not parsed as a new list.
        #expect(texts("- a\n\n  more\n\n- b") == ["- a\n\n  more\n\n- b"])
        #expect(texts("- a\n\npara\n\n- b") == ["- a\n\n", "para\n\n", "- b"])
    }

    @Test func frontMatter() {
        let ns = "---\ntitle: x\n\nk: v\n---\nbody\n\nmore" as NSString
        let chunks = ChunkIndex(text: ns).chunks
        #expect(chunks.first?.kind == .frontMatter)
        #expect(ns.substring(with: chunks[0].range) == "---\ntitle: x\n\nk: v\n---\n")
        #expect(chunks.count == 3)
    }

    /// Incremental updates must always equal a full rescan.
    @Test func incrementalMatchesFullScan() {
        var rng = SplitMix(seed: 42)
        let pieces = ["para text", "", "```", "~~~~", "$$", "<!--", "-->", "- item", "  indented", "> quote", "---", "# head", "x $$ y", "中文段落"]
        for _ in 0..<300 {
            var lines: [String] = []
            for _ in 0..<rng.next(40) { lines.append(pieces[rng.next(pieces.count)]) }
            let text = NSMutableString(string: lines.joined(separator: "\n"))
            var index = ChunkIndex(text: text)
            for _ in 0..<12 {
                let location = rng.next(text.length + 1)
                let removeLength = min(rng.next(12), text.length - location)
                let insert = rng.next(3) == 0 ? "" : ["\n", "\n\n", "```\n", "$$", "x", "- ", "  ", "<!--", "-->\n", "---\n"][rng.next(10)]
                text.replaceCharacters(in: NSRange(location: location, length: removeLength), with: insert)
                let edited = NSRange(location: location, length: (insert as NSString).length)
                index.update(text: text, editedRange: edited, delta: edited.length - removeLength)
                #expect(index.chunks == ChunkIndex(text: text).chunks, "text: \(text.debugDescription)")
            }
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}
