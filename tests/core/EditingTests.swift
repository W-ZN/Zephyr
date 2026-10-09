import Foundation
import Testing
@testable import ZephyrCore

@Suite struct TextPatchTests {
    @Test func keepsCommonPrefixAndSuffix() {
        let p = TextPatch.minimal(from: "alpha beta gamma", to: "alpha BETA gamma")
        #expect(p == TextPatch(range: NSRange(location: 6, length: 4), replacement: "BETA"))
        #expect(p?.applied(to: "alpha beta gamma") == "alpha BETA gamma")
        #expect(TextPatch.minimal(from: "same", to: "same") == nil)
    }

    @Test func neverSplitsSurrogatesOrCRLF() {
        let old = "a😀b\r\nc", new = "a😃b\nc"
        let p = TextPatch.minimal(from: old, to: new)!
        #expect(p.applied(to: old) == new)
        let units = Array(old.utf16)
        #expect(!UTF16.isTrailSurrogate(units[p.range.location]))
        #expect(!(units[p.range.location - 1] == 0x0D && units[p.range.location] == 0x0A))
    }
}

@Suite struct ThreeWayMergeTests {
    let base = "one\ntwo\nthree\nfour\nfive\n"

    @Test func combinesSeparateChanges() {
        let local = "ONE\ntwo\nthree\nfour\nfive\n"
        let remote = "one\ntwo\nthree\nfour\nFIVE\nsix\n"
        let r = ThreeWayMerge.merge(base: base, local: local, remote: remote)
        #expect(r.merged == "ONE\ntwo\nthree\nfour\nFIVE\nsix\n")
        #expect(r.conflicts.isEmpty)
    }

    @Test func identicalChangesAreNotConflicts() {
        let both = "one\nTWO\nthree\nfour\nfive\n"
        #expect(ThreeWayMerge.merge(base: base, local: both, remote: both).merged == both)
    }

    @Test func overlappingDifferentChangesConflict() {
        let local = "one\nTWO-local\nthree\nfour\nfive\n"
        let remote = "one\nTWO-remote\nthree\nfour\nfive\n"
        let r = ThreeWayMerge.merge(base: base, local: local, remote: remote)
        #expect(r.merged == nil)
        #expect(r.conflicts == [1..<2])
    }

    @Test func keepsLineEndingsAndUnicode() {
        let base = "标题\r\n正文\r\n结尾\r\n"
        let local = "标题\r\n正文（本地）\r\n结尾\r\n"
        let remote = "标题\r\n正文\r\n结尾\r\n追加\r\n"
        #expect(ThreeWayMerge.merge(base: base, local: local, remote: remote).merged == "标题\r\n正文（本地）\r\n结尾\r\n追加\r\n")
    }

    @Test func randomNonOverlappingEditsMerge() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let lines = (0..<20).map { "line \($0)\n" }
            var local = lines, remote = lines
            let i = Int.random(in: 0..<10, using: &rng), j = Int.random(in: 11..<20, using: &rng)
            local[i] = "local \(i)\n"
            remote[j] = "remote \(j)\n"
            if Bool.random(using: &rng) { remote.insert("inserted\n", at: j) }
            var expected = lines
            expected[i] = local[i]
            expected.replaceSubrange(j..<(j + 1), with: remote[j..<(j + (remote.count - lines.count) + 1)])
            let r = ThreeWayMerge.merge(base: lines.joined(), local: local.joined(), remote: remote.joined())
            #expect(r.merged == expected.joined())
        }
    }
}

extension ThreeWayMergeTests {
    /// Canonically equivalent is not the same: another app recomposing `é` is a change to keep.
    @Test func comparesBytesNotUnicodeEquivalence() {
        let base = "e\u{301}\ntwo\nthree\n", local = "e\u{301}\ntwo\nTHREE\n", remote = "\u{e9}\ntwo\nthree\n"
        let merged = ThreeWayMerge.merge(base: base, local: local, remote: remote).merged
        #expect(merged.map { Array($0.utf8) } == Array("\u{e9}\ntwo\nTHREE\n".utf8))
    }

    /// A few changes far apart in a long file: no quadratic table (the old LCS needed ~10¹⁰ cells).
    @Test func fewChangesInALongFileStayCheap() {
        let lines = (0..<100_000).map { "line \($0)\n" }
        var local = lines, remote = lines
        local[0] = "first\n"
        local[99_999] = "last\n"
        remote[50_000] = "middle\n"
        var expected = lines
        expected[0] = "first\n"
        expected[99_999] = "last\n"
        expected[50_000] = "middle\n"
        let start = Date()
        #expect(ThreeWayMerge.merge(base: lines.joined(), local: local.joined(), remote: remote.joined()).merged == expected.joined())
        #expect(Date().timeIntervalSince(start) < 5)
    }

    /// The edit script's matches are a longest common subsequence.
    @Test func matchesAreALongestCommonSubsequence() {
        var rng = SplitMix(seed: 11)
        for _ in 0..<300 {
            let a = (0..<rng.next(12)).map { _ in rng.next(4) }, b = (0..<rng.next(12)).map { _ in rng.next(4) }
            var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in stride(from: a.count - 1, through: 0, by: -1) where !a.isEmpty {
                for j in stride(from: b.count - 1, through: 0, by: -1) where !b.isEmpty {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            let pairs = ThreeWayMerge.matches(a, b, limit: 100) ?? []
            #expect(pairs.count == table[0][0])
            #expect(pairs.allSatisfy { a[$0.0] == b[$0.1] })
            #expect(zip(pairs, pairs.dropFirst()).allSatisfy { $0.0 < $1.0 && $0.1 < $1.1 })
        }
        #expect(ThreeWayMerge.matches([1, 2, 3], [4, 5, 6], limit: 2) == nil, "past the budget")
    }
}

@Suite struct BlockMapTests {
    func move(_ text: String, _ from: String, before to: String?) -> String? {
        let blocks = BlockMap.blocks(in: text)
        let ns = text as NSString
        guard let a = BlockMap.block(at: ns.range(of: from).location, in: blocks) else { return nil }
        let b = to.flatMap { BlockMap.block(at: ns.range(of: $0).location, in: blocks) }
        return BlockMap.move(a, before: b, in: text)
    }

    @Test func findsTopLevelBlocksAndListItems() {
        let text = "---\ntitle: x\n---\n# H\n\npara\n\n- a\n  - a1\n- b\n\n```\ncode\n\nmore\n```\n"
        let blocks = BlockMap.blocks(in: text)
        let ns = text as NSString
        let texts = blocks.map { ns.substring(with: $0.range) }
        #expect(texts == ["# H\n", "para\n", "- a\n  - a1\n", "  - a1\n", "- b\n", "```\ncode\n\nmore\n```\n"])
        #expect(blocks[2].group == blocks[4].group && blocks[3].group != blocks[2].group)
    }

    @Test func movesParagraphsKeepingSeparators() {
        let text = "one\n\ntwo\n\nthree\n"
        #expect(move(text, "three", before: "one") == "three\n\none\n\ntwo\n")
        #expect(move(text, "one", before: nil) == "two\n\nthree\n\none\n")
        #expect(move(text, "two", before: "two") == nil)
    }

    @Test func movesListItemsWithNestedContent() {
        let text = "- a\n  - a1\n- b\n- c\n"
        #expect(move(text, "- c", before: "- a") == "- c\n- a\n  - a1\n- b\n")
        #expect(move(text, "- a", before: nil) == "- b\n- c\n- a\n  - a1\n")
    }

    @Test func handlesMissingFinalNewlineAndCRLF() {
        #expect(move("one\n\ntwo", "two", before: "one") == "two\n\none\n")
        let crlf = "one\r\n\r\ntwo\r\n"
        let blocks = BlockMap.blocks(in: crlf)
        #expect(BlockMap.move(blocks[1], before: blocks[0], in: crlf, newline: "\r\n") == "two\r\n\r\none\r\n")
    }
}

@Suite struct FrontMatterEditTests {
    func entries(_ text: String) -> [FrontMatterModel.Entry] {
        let end = ChunkIndex.frontMatterEnd(text as NSString)!
        let a = FrontMatterParser.analyze((text as NSString).substring(to: end))
        guard case let .frontMatter(model)? = a.components.first?.kind else { return [] }
        return model.entries
    }

    @Test func replacesOnlyTheValue() {
        let text = "---\ntitle: Old  # keep\ntags: [a, b]\n---\nbody\n"
        let title = entries(text)[0]
        let p = FrontMatterEdit.patch(setting: title, to: "New title", in: text)
        #expect(p?.applied(to: text) == "---\ntitle: New title  # keep\ntags: [a, b]\n---\nbody\n")
        #expect(FrontMatterEdit.patch(setting: entries(text)[1], to: "x", in: text) == nil, "sequences are edited as source")
    }

    @Test func keepsQuoteStyleAndQuotesWhenNeeded() {
        let text = "---\na: 'it' # c\nb: \"x\"\nc: plain\n---\n"
        let e = entries(text)
        #expect(FrontMatterEdit.patch(setting: e[0], to: "it's", in: text)?.replacement == "'it''s'")
        #expect(FrontMatterEdit.patch(setting: e[1], to: "say \"hi\"", in: text)?.replacement == "\"say \\\"hi\\\"\"")
        #expect(FrontMatterEdit.patch(setting: e[2], to: "key: value", in: text)?.replacement == "\"key: value\"")
        #expect(FrontMatterEdit.patch(setting: e[2], to: "yes", in: text)?.replacement == "\"yes\"")
        #expect(FrontMatterEdit.patch(setting: e[2], to: "中文标题", in: text)?.replacement == "中文标题")
        #expect(FrontMatterEdit.patch(setting: e[2], to: "two\nlines", in: text) == nil)
    }

    @Test func fillsAndClearsValues() {
        let text = "---\nempty:\nspaced: \ndraft: true\n---\n"
        let e = entries(text)
        #expect(FrontMatterEdit.patch(setting: e[0], to: "now", in: text)?.applied(to: text) == "---\nempty: now\nspaced: \ndraft: true\n---\n")
        #expect(FrontMatterEdit.patch(setting: e[1], to: "now", in: text)?.applied(to: text) == "---\nempty:\nspaced: now\ndraft: true\n---\n")
        #expect(FrontMatterEdit.patch(setting: e[2], to: "", in: text)?.applied(to: text) == "---\nempty:\nspaced: \ndraft: \n---\n")
        #expect(FrontMatterEdit.patch(setting: e[0], to: "", in: text) == nil)
        #expect(FrontMatterEdit.patch(setting: e[2], to: "false", in: text)?.replacement == "false", "booleans stay booleans")
        #expect(FrontMatterEdit.patch(setting: e[0], to: "yes", in: text)?.replacement == " yes", "an empty value takes what is typed")
    }

    @Test func continuedValuesStaySource() {
        let text = "---\nauthor:\n  name: A\nsummary: long\n  folded\ntags:\n  - a\n  - b\ntitle: T\n---\n"
        let e = entries(text)
        #expect(e.map(\.key) == ["author", "summary", "tags", "title"])
        #expect(e[0].valueRange.location == NSNotFound, "nested map")
        #expect(e[1].valueRange.location == NSNotFound, "folded plain scalar")
        #expect(e[2].valueRange.location == NSNotFound && e[2].value == "a, b", "indented sequence")
        #expect(e[3].valueRange.location != NSNotFound)
    }
}

@Suite struct TableEditTests {
    let table = "| a | b |\n|---|:-:|\n| 1 | 2 |\n| x \\| y | `c` |"

    @Test func readsAndSetsCells() {
        #expect(TableEdit.cell(table, row: 0, column: 1) == "b")
        #expect(TableEdit.cell(table, row: 2, column: 0) == "x \\| y", "escaped pipes stay in the cell")
        #expect(TableEdit.cell(table, row: 3, column: 0) == nil)
        #expect(TableEdit.setting(table, row: 1, column: 1, to: "two|2") == "| a | b |\n|---|:-:|\n| 1 | two\\|2 |\n| x \\| y | `c` |")
        #expect(TableEdit.setting(table, row: 0, column: 0, to: "") == "|  | b |\n|---|:-:|\n| 1 | 2 |\n| x \\| y | `c` |")
        let empty = "|  |  |\n| --- | --- |\n|  |  |"
        #expect(TableEdit.setting(empty, row: 1, column: 1, to: "v") == "|  |  |\n| --- | --- |\n|  | v |")
        #expect(TableEdit.setting("| a | b |\n|---|---|\n| 1 |", row: 1, column: 1, to: "v") == "| a | b |\n|---|---|\n| 1 | v |", "short rows grow")
    }

    @Test func insertsAndDeletesRows() {
        #expect(TableEdit.insertingRow(table, before: nil) == table + "\n|  |  |")
        #expect(TableEdit.insertingRow(table, before: 1, newline: "\r\n") == "| a | b |\n|---|:-:|\n|  |  |\r\n| 1 | 2 |\n| x \\| y | `c` |")
        #expect(TableEdit.deletingRow(table, 2) == "| a | b |\n|---|:-:|\n| 1 | 2 |")
        #expect(TableEdit.deletingRow(table, 1) == "| a | b |\n|---|:-:|\n| x \\| y | `c` |")
        #expect(TableEdit.deletingRow(table, 0) == nil, "the header stays")
        #expect(TableEdit.insertingRow("> | a |\n> |---|", before: nil) == "> | a |\n> |---|\n> |  |", "quoted tables keep their prefix")
    }

    @Test func insertsAndDeletesColumns() {
        #expect(TableEdit.insertingColumn(table, before: 1) == "| a |   | b |\n|---| --- |:-:|\n| 1 |   | 2 |\n| x \\| y |   | `c` |")
        #expect(TableEdit.insertingColumn(table, before: 2) == "| a | b |   |\n|---|:-:| --- |\n| 1 | 2 |   |\n| x \\| y | `c` |   |")
        #expect(TableEdit.insertingColumn("a | b\n--|--\n1 | 2", before: 0) == "|   | a | b\n--- | --|--\n|   | 1 | 2")
        #expect(TableEdit.deletingColumn(table, 0) == "| b |\n|:-:|\n| 2 |\n| `c` |")
        #expect(TableEdit.deletingColumn("a | b | c\n--|--|--\n1 | 2 | 3", 2) == "a | b \n--|--\n1 | 2 ")
        #expect(TableEdit.deletingColumn("a | b\n--|--\n1 | 2", 1) == nil, "would become a setext heading")
        #expect(TableEdit.deletingColumn("| a |\n|---|", 0) == nil, "the last column stays")
    }

    @Test func alignsColumns() {
        #expect(TableEdit.aligning(table, column: 0, .right) == "| a | b |\n|---:|:-:|\n| 1 | 2 |\n| x \\| y | `c` |")
        #expect(TableEdit.aligning(table, column: 1, .none) == "| a | b |\n|---|---|\n| 1 | 2 |\n| x \\| y | `c` |")
    }
}

@Suite struct MathEditTests {
    @Test func roundTripsTeXInsideItsDelimiters() {
        let source = "$$\n\\int_0^1 x\\,dx\n$$"
        #expect(MathEdit.tex(in: source, prefix: "") == "\\int_0^1 x\\,dx")
        #expect(MathEdit.replacingTeX(in: source, with: "\\int_0^2 x\\,dx", prefix: "") == "$$\n\\int_0^2 x\\,dx\n$$")
        #expect(MathEdit.replacingTeX(in: "$$a+b$$", with: "a-b", prefix: "") == "$$a-b$$", "one line stays one line")
        #expect(MathEdit.replacingTeX(in: "\\[x\\]", with: "y\nz", prefix: "") == "\\[\ny\nz\n\\]")
    }

    @Test func keepsContainerPrefixesAndLineBreaks() {
        let quoted = "$$\n> a \\\\\n> b\n> $$"
        #expect(MathEdit.tex(in: quoted, prefix: "> ") == "a \\\\\nb")
        #expect(MathEdit.replacingTeX(in: quoted, with: "a \\\\\nc", prefix: "> ") == "$$\n> a \\\\\n> c\n> $$")
        let crlf = "$$\r\nx\r\n$$"
        #expect(MathEdit.tex(in: crlf, prefix: "") == "x")
        #expect(MathEdit.replacingTeX(in: crlf, with: "y", prefix: "", newline: "\r\n") == "$$\r\ny\r\n$$")
    }
}

@Suite struct ProposalTests {
    let text = "# Plan\n\nShip on Monday.\n\nOwner: Ann\n"

    @Test func resolvesAppliesAndWithdraws() throws {
        let edits = [ProposedEdit(find: "Owner: Ann", replace: "Owner: Bo"), ProposedEdit(find: "Monday", replace: "Friday afternoon")]
        let patches = try ProposalResolver.patches(for: edits, in: text)
        #expect(patches.map(\.range.location) == [16, 25], "document order")
        let after = ProposalResolver.apply(patches, to: text)
        #expect(after == "# Plan\n\nShip on Friday afternoon.\n\nOwner: Bo\n")
        let applied = ProposalResolver.applied(patches, to: text)
        let back = try #require(ProposalResolver.withdrawal(of: applied, in: after))
        #expect(ProposalResolver.apply(back, to: after) == text)
        // Text changed where the proposal wrote: withdrawing would overwrite it.
        #expect(ProposalResolver.withdrawal(of: applied, in: after.replacingOccurrences(of: "Bo", with: "Cy")) == nil)
    }

    @Test func rejectsMissingAmbiguousAndOverlappingEdits() {
        #expect(throws: ProposalError.notFound(0)) { try ProposalResolver.patches(for: [ProposedEdit(find: "Tuesday", replace: "x")], in: text) }
        #expect(throws: ProposalError.ambiguous(0)) { try ProposalResolver.patches(for: [ProposedEdit(find: "n", replace: "x")], in: text) }
        #expect(throws: ProposalError.overlapping(1)) {
            try ProposalResolver.patches(for: [ProposedEdit(find: "Ship on", replace: "x"), ProposedEdit(find: "on Monday", replace: "y")], in: text)
        }
        #expect(throws: ProposalError.empty) { try ProposalResolver.patches(for: [], in: text) }
    }

    @Test func followsTheFileLineBreaks() throws {
        let crlf = "a\r\nb\r\nc\r\n"
        let patches = try ProposalResolver.patches(for: [ProposedEdit(find: "a\nb", replace: "a\nB\nb")], in: crlf, newline: "\r\n")
        #expect(ProposalResolver.apply(patches, to: crlf) == "a\r\nB\r\nb\r\nc\r\n")
        #expect(TextRevision.of(crlf) != TextRevision.of("a\nb\nc\n"))
    }
}
