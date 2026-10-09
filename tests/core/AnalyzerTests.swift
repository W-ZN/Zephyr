import Foundation
import Testing
@testable import ZephyrCore

@Suite struct AnalyzerTests {
    func sub(_ s: String, _ r: NSRange) -> String { (s as NSString).substring(with: r) }

    func hidden(_ s: String, _ a: ChunkAnalysis) -> [String] {
        a.markers.filter { $0.style == .hide }.map { sub(s, $0.range) }
    }

    @Test func headingsAndEmphasis() {
        let s = "## Title **bold** ##\nSetext *em*\n===\n"
        let a = MarkdownAnalyzer.analyze(s)
        #expect(a.lines.map(\.kind) == [.heading(level: 2), .heading(level: 1), .setextUnderline])
        #expect(hidden(s, a) == ["## ", "**", "**", " ##", "*", "*", "==="])
        #expect(a.inlines.map { sub(s, $0.range) } == ["**bold**", "*em*"])
        let heading = a.markers[0]
        #expect(sub(s, heading.revealRange) == "## Title **bold** ##")
    }

    /// cmark ends a setext heading on the next line when text follows the underline directly; the
    /// underline is still the `===` line, and the text after it is a paragraph block of its own.
    @Test func setextHeadingFollowedDirectlyByText() {
        let s = "Owner\n=====\nNext\n"
        #expect(MarkdownAnalyzer.analyze(s).lines.map(\.kind) == [.heading(level: 1), .setextUnderline, .paragraph])
        #expect(BlockMap.blocks(in: s).map { sub(s, $0.range) } == ["Owner\n=====\n", "Next\n"])
    }

    /// A lone dash under text is a list being started, not a setext underline: with a space it is
    /// an empty bullet one level in (Tab on an empty item), without one it is still text.
    @Test func loneDashStartsAListNotAHeading() {
        let nested = MarkdownAnalyzer.analyze("- a\n  - ")
        #expect(nested.lines.map(\.kind) == [.paragraph, .paragraph])
        #expect(nested.lines.map(\.listDepth) == [1, 2] && nested.lines[1].isListItemStart)
        #expect(nested.markers.contains { $0.style == .bullet(depth: 2) && $0.range == NSRange(location: 6, length: 2) })
        let quoted = MarkdownAnalyzer.analyze("> Hello\n> - ")
        #expect(quoted.lines.map(\.kind) == [.paragraph, .paragraph] && quoted.lines[1].listDepth == 1)
        let typed = MarkdownAnalyzer.analyze("Hello\n-")
        #expect(typed.lines.map(\.kind) == [.paragraph, .paragraph] && typed.markers.isEmpty)
        #expect(MarkdownAnalyzer.analyze("Hello\n--").lines.map(\.kind) == [.heading(level: 2), .setextUnderline])
    }

    @Test func listsAndTasks() {
        let s = "- a\n  - [x] done\n1. one\n"
        let a = MarkdownAnalyzer.analyze(s)
        let styles = a.markers.map { ($0.style, sub(s, $0.range)) }
        #expect(styles.contains { $0.0 == .bullet(depth: 1) && $0.1 == "- " })
        #expect(styles.contains { $0.0 == .bullet(depth: 2) && $0.1 == "- " })
        #expect(styles.contains { $0.0 == .checkbox(checked: true) && $0.1 == "[x] " })
        #expect(styles.contains { $0.0 == .ordinal && $0.1 == "1. " })
        #expect(styles.contains { $0.0 == .structural && $0.1 == "  " })
        #expect(a.lines.map(\.listDepth) == [1, 2, 1])
    }

    @Test func quotesHidePrefixes() {
        let s = "> one\n> > two\n"
        let a = MarkdownAnalyzer.analyze(s)
        #expect(a.lines.map(\.quoteDepth) == [1, 2])
        #expect(a.markers.filter { $0.style == .structural }.map { sub(s, $0.range) } == ["> ", "> > "])
    }

    @Test func codeBlocks() {
        let s = "```swift\nlet $x$ = 1\n```\n"
        let a = MarkdownAnalyzer.analyze(s)
        #expect(a.lines.map(\.kind) == [.codeFence(language: "swift"), .code, .codeFence(language: nil)])
        #expect(a.components.isEmpty)
        #expect(hidden(s, a) == ["```swift", "```"])
        #expect(a.codeBlocks.first?.language == "swift")
    }

    @Test func linksAndCode() {
        let s = "see [the docs](http://x.y) and <http://a.b> or `co*de*`"
        let a = MarkdownAnalyzer.analyze(s)
        #expect(hidden(s, a) == ["[", "](http://x.y)", "<", ">", "`", "`"])
        #expect(a.inlines.contains { $0.style == .link(destination: "http://x.y") && sub(s, $0.range) == "the docs" })
        #expect(!a.inlines.contains { $0.style == .emphasis })
    }

    @Test func referencesResolveAcrossChunks() {
        let doc = "[x][ref]\n\n[ref]: http://r.example\n"
        let defs = MarkdownAnalyzer.referenceDefinitions(in: doc)
        #expect(defs.map(\.label) == ["ref"])
        let chunk = "[x][ref]\n\n"
        let a = MarkdownAnalyzer.analyze(chunk, references: MarkdownAnalyzer.references(for: chunk, from: defs))
        #expect(a.inlines.contains { $0.style == .link(destination: "http://r.example") })
        #expect(hidden(chunk, a) == ["[", "][ref]"])
    }

    @Test func mathComponents() {
        let s = "Euler $e^{i\\pi}+1=0$ is *nice*\n\n$$\n\\int_0^1 x\\,dx\n$$\n"
        let a = MarkdownAnalyzer.analyze(s)
        #expect(a.components.count == 2)
        #expect(a.components[0].kind == .inlineMath(tex: "e^{i\\pi}+1=0", display: false))
        #expect(a.components[1].kind == .displayMath(tex: "\n\\int_0^1 x\\,dx\n"))
        #expect(a.lines.map(\.kind) == [.paragraph, .blank, .component, .component, .component])
        #expect(a.inlines.contains { $0.style == .emphasis })
    }

    @Test func tablesImagesAndRules() {
        let s = "| a | $x|y$ |\n|---|:-:|\n| 1 | **2** |\n\n![alt](img.png)\n\n---\n"
        let a = MarkdownAnalyzer.analyze(s)
        guard case let .table(model) = a.components.first?.kind else { Issue.record("no table"); return }
        #expect(model.header == ["a", "$x|y$"])
        #expect(model.rows == [["1", "**2**"]])
        #expect(model.alignments == [.left, .center])
        #expect(a.components.contains { $0.kind == .image(source: "img.png", alt: "alt", width: nil) })
        guard case let .image(_, _, _, alignment)? = a.components.first(where: {
            if case .image = $0.kind { return true }
            return false
        })?.kind else { Issue.record("no image"); return }
        #expect(alignment == nil, "Markdown does not bake in a theme alignment")
        #expect(a.components.contains { $0.kind == .thematicBreak })
        #expect(a.lines.filter { $0.kind == .component }.count == 5)
    }

    @Test func safeHTMLImageMarkupEncodesAttributeLineBreaks() throws {
        let markup = try #require(MarkdownAnalyzer.safeHTMLImageMarkup(source: "photo.png", alt: "foo\r\nbar", width: 180))
        #expect(markup == "<img src=\"photo.png\" alt=\"foo&#13;&#10;bar\" width=\"180\">")
        let image = try #require(MarkdownAnalyzer.safeHTMLImage(markup))
        #expect(image.alt == "foo\r\nbar" && image.width == 180)
    }

    /// A row added from the table's + button has empty cells: they show empty, not as pipes.
    @Test func emptyTableCellsAreEmpty() {
        guard case let .table(model)? = MarkdownAnalyzer.analyze("| a | b |\n|---|---|\n|  |  |\n| 1 |  |").components.first?.kind else { Issue.record("no table"); return }
        #expect(model.rows == [["", ""], ["1", ""]])
    }

    @Test func unicodeOffsets() {
        let s = "中文 **粗体😀** 结尾"
        let a = MarkdownAnalyzer.analyze(s)
        #expect(hidden(s, a) == ["**", "**"])
        #expect(a.inlines.map { sub(s, $0.range) } == ["**粗体😀**"])
    }

    @Test func strictStandaloneHTMLImage() {
        let source = #"<img src="folder/a&amp;b.png" alt="&lt;cover&gt;" width="240">"#
        let analysis = MarkdownAnalyzer.analyze(source)
        #expect(analysis.components.map(\.kind) == [.image(source: "folder/a&b.png", alt: "<cover>", width: 240)])
        #expect(analysis.lines.map(\.kind) == [.component])
        #expect(MarkdownAnalyzer.safeHTMLImageMarkup(source: "folder/a&b.png", alt: "<cover>", width: 240) == #"<img src="folder/a&amp;b.png" alt="&lt;cover&gt;" width="240">"#)
    }

    @Test func strictHTMLImageAlignmentRoundTrips() throws {
        let source = #"<img src="cover.png" alt="Cover" width="240" align="center">"#
        let image = try #require(MarkdownAnalyzer.safeHTMLImage(source))
        #expect(image.alignment == .center)
        #expect(MarkdownAnalyzer.analyze(source).components.map(\.kind) == [.image(source: "cover.png", alt: "Cover", width: 240, alignment: .center)])
        #expect(MarkdownAnalyzer.safeHTMLImageMarkup(source: image.source, alt: image.alt, width: image.width, alignment: image.alignment) == source)
        #expect(MarkdownAnalyzer.safeHTMLImage(#"<img src="cover.png" align="right">"#) == nil)
    }

    /// Outside the strict standalone form (which stays an `ImageBox` that can be resized), an
    /// HTML image goes through the safe subset (design §9): attributes outside the allowlist are
    /// dropped and never run, a width that is not a number is ignored, and inside a line of text
    /// the image is inline. A script or a `javascript:` source keeps the whole block literal.
    @Test func otherHTMLImagesUseTheSafeSubset() throws {
        let handler = MarkdownAnalyzer.analyze(#"<img src="x.png" onerror="alert(1)">"#)
        guard case let .html(fragment) = try #require(handler.components.first).kind, case let .element(img) = fragment.nodes[0] else {
            Issue.record("no HTML component: \(handler.components)")
            return
        }
        #expect(img.attributes == ["src": "x.png"])
        guard case .html = try #require(MarkdownAnalyzer.analyze(#"<img src="x.png" width="Infinity">"#).components.first).kind else {
            Issue.record("no HTML component")
            return
        }
        #expect(MarkdownAnalyzer.analyze(#"before <img src="x.png" width="120">"#).components.map(\.kind) == [.inlineImage(source: "x.png", alt: "", width: 120, height: nil)])
        for literal in [#"<img src="javascript:alert(1)">"#, "<div><script>alert(1)</script></div>"] {
            let analysis = MarkdownAnalyzer.analyze(literal)
            #expect(analysis.components.isEmpty)
            #expect(analysis.lines.allSatisfy { $0.kind == .html })
        }
    }

    @Test func untrustedFiniteHTMLImageWidthSerializesWithoutIntegerConversion() {
        let markup = MarkdownAnalyzer.safeHTMLImageMarkup(source: "x.png", alt: "", width: 1e300)
        #expect(markup != nil)
        #expect(markup.flatMap(MarkdownAnalyzer.safeHTMLImage)?.width?.isFinite == true)
    }
}

@Suite struct AnalyzerFuzzTests {
    /// Arbitrary input must never crash and every range must stay inside the chunk.
    @Test func rangesStayInBounds() {
        var rng = SplitMix(seed: 7)
        let atoms = ["#", "## ", "*", "**", "_", "~~", "`", "```", "$", "$$", "[", "]", "(", ")", "![", "<", ">", "> ", "- ", "1. ", "[ ] ", "|", "---", "===", "\\", " ", "  ", "\n", "\r\n", "\n\n", "中", "😀", "a", "word", "http://x.y", "<!--", "-->", "\t"]
        let count = Int(ProcessInfo.processInfo.environment["ZEPHYR_FUZZ_COUNT"] ?? "") ?? 2000
        for _ in 0..<count {
            var s = ""
            for _ in 0..<rng.next(60) { s += atoms[rng.next(atoms.count)] }
            if ProcessInfo.processInfo.environment["ZEPHYR_FUZZ_TRACE"] != nil { FileHandle.standardError.write(Data((s.debugDescription + "\n").utf8)) }
            let a = MarkdownAnalyzer.analyze(s)
            let n = (s as NSString).length
            func ok(_ r: NSRange) -> Bool { r.location >= 0 && r.length >= 0 && NSMaxRange(r) <= n }
            #expect(a.length == n)
            #expect(a.markers.allSatisfy { ok($0.range) && ok($0.revealRange) })
            #expect(a.inlines.allSatisfy { ok($0.range) })
            #expect(a.components.allSatisfy { ok($0.range) })
            #expect(a.lines.allSatisfy { ok($0.range) })
            #expect(a.lines.reduce(0) { $0 + $1.range.length } == n || n == 0)
        }
    }

    @Test func veryLongLinesStayPlainSource() {
        let long = String(repeating: "**粗体** `code` text ", count: 1_200)
        let a = MarkdownAnalyzer.analyze("# Title\n" + long + "\n\nnext\n")
        #expect(a.isPlain)
        #expect(a.markers.isEmpty && a.inlines.isEmpty)
        #expect(a.lines.map(\.kind) == [.paragraph, .paragraph, .blank, .paragraph])
        #expect(a.lines.reduce(0) { $0 + $1.range.length } == a.length)
        #expect(!MarkdownAnalyzer.analyze("# Title\n**short**\n").isPlain)
    }
}
