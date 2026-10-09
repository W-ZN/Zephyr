import Foundation
import Markdown
import Testing
@testable import ZephyrCore

/// Web content in Markdown (design §9): the safe HTML subset Zephyr draws itself, and static
/// badges it recognizes from their URL.
@Suite struct WebContentTests {
    static let readmeHeader = """
    <p align="center">
      <a href="https://github.com/W-ZN/Zephyr/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/W-ZN/Zephyr?include_prereleases&color=0f4a55"></a>
      <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-0f4a55">
      <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue"></a>
    </p>
    """

    @Test func parsesAReadmeHeader() throws {
        let fragment = try #require(HTMLFragment.parse(Self.readmeHeader))
        guard case let .element(p) = try #require(fragment.nodes.first(where: { if case .element = $0 { true } else { false } })) else { Issue.record("no element"); return }
        #expect(p.name == "p" && p["align"] == "center")
        let elements = p.children.compactMap { node -> HTMLFragment.Element? in if case let .element(e) = node { e } else { nil } }
        #expect(elements.map(\.name) == ["a", "img", "a"])
        guard case let .element(img) = elements[0].children[0] else { Issue.record("no image in the link"); return }
        // Entities in attribute values are decoded (`&color` is not an entity and stays).
        #expect(img["src"] == "https://img.shields.io/github/v/release/W-ZN/Zephyr?include_prereleases&color=0f4a55")
        #expect(img["alt"] == "Release")
        #expect(elements[0]["href"] == "https://github.com/W-ZN/Zephyr/releases/latest")
    }

    @Test func refusesWhatTheSubsetDoesNotAllow() {
        #expect(HTMLFragment.parse("<p>hi<script>alert(1)</script></p>") == nil)
        #expect(HTMLFragment.parse("<iframe src=\"https://example.com\"></iframe>") == nil)
        #expect(HTMLFragment.parse("<table><tr><td>a</td></tr></table>") == nil)
        #expect(HTMLFragment.parse("<a href=\"javascript:alert(1)\">x</a>") == nil)
        #expect(HTMLFragment.parse("<img src=\"data:image/png;base64,AAAA\">") == nil)
        #expect(HTMLFragment.parse("<!DOCTYPE html><p>x</p>") == nil)
        // Nothing to show: comments only, an empty container.
        #expect(HTMLFragment.parse("<!-- a note -->") == nil)
        #expect(HTMLFragment.parse("<div align=\"center\">") == nil)
        #expect(HTMLFragment.parse("<p>unterminated <!-- comment") == nil)
    }

    @Test func dropsAttributesOutsideTheAllowlist() throws {
        let fragment = try #require(HTMLFragment.parse("<p align=right style=\"color:red\" onclick=\"x()\" class=c>Hi <b id=x>there</b></p>"))
        guard case let .element(p) = fragment.nodes[0] else { Issue.record("no element"); return }
        #expect(p.attributes == ["align": "right"])
        guard case let .element(b) = p.children[1] else { Issue.record("no bold"); return }
        #expect(b.attributes.isEmpty)
    }

    @Test func isLenientLikeABrowser() throws {
        // Unclosed elements close at the end; a block closes an open paragraph; stray end tags vanish.
        let fragment = try #require(HTMLFragment.parse("<p>one<div>two</span></div><b>three"))
        let names = fragment.nodes.compactMap { node -> String? in if case let .element(e) = node { e.name } else { nil } }
        #expect(names == ["p", "div", "b"])
        // `<` that does not start a tag is text; comments are dropped.
        let text = try #require(HTMLFragment.parse("<p>1 < 2 <!-- no --> &amp; 3 &copy; &#x263A; &unknown;</p>"))
        #expect(text.plainText == "1 < 2 & 3 © ☺ &unknown;")
    }

    @Test func serializesOnlyTheSubset() throws {
        let fragment = try #require(HTMLFragment.parse("<p align=\"center\" style=\"x\"><a href=\"LICENSE\"><img src=\"https://x/y.svg\" alt=\"A &amp; B\"></a> <br/> <i>t</i></p>"))
        #expect(fragment.serialized() == "<p align=\"center\"><a href=\"LICENSE\"><img alt=\"A &amp; B\" src=\"https://x/y.svg\"></a> <br> <i>t</i></p>")
        // A dropped image source leaves its alt text; a dropped link target leaves its content.
        #expect(fragment.serialized { attribute, value in attribute == "src" ? nil : value } == "<p align=\"center\"><a href=\"LICENSE\">A &amp; B</a> <br> <i>t</i></p>")
        #expect(fragment.serialized { attribute, value in attribute == "href" ? nil : value }.hasPrefix("<p align=\"center\"><img"))
    }

    @Test func plainTextReadsLikeThePage() throws {
        let fragment = try #require(HTMLFragment.parse(Self.readmeHeader))
        #expect(fragment.plainText == "Release macOS 15+ MIT License")
        let blocks = try #require(HTMLFragment.parse("<h1 align=center>Zephyr</h1>\n<p>A <b>quiet</b>\n   editor.<br>Native.</p>"))
        #expect(blocks.plainText == "Zephyr\nA quiet editor.\nNative.")
    }

    @Test func staticBadgesComeFromTheirURL() throws {
        let macOS = try #require(Badge.parse("https://img.shields.io/badge/macOS-15%2B-0f4a55"))
        #expect(macOS == Badge(label: "macOS", message: "15+", color: 0x0F4A55))
        let chips = try #require(Badge.parse("https://img.shields.io/badge/Apple%20silicon%20%7C%20Intel-universal-0f4a55"))
        #expect(chips.label == "Apple silicon | Intel" && chips.message == "universal")
        let license = try #require(Badge.parse("https://img.shields.io/badge/license-MIT-blue"))
        #expect(license.color == 0x007EC6)
        // Dashes and underscores: `--` is a dash, `__` an underscore, `_` a space.
        let escaped = try #require(Badge.parse("https://img.shields.io/badge/built--in_tools-snake__case-F05138.svg?style=flat-square"))
        #expect(escaped.label == "built-in tools" && escaped.message == "snake_case" && escaped.color == 0xF05138 && escaped.style == .flatSquare)
        let messageOnly = try #require(Badge.parse("https://img.shields.io/badge/stable-green"))
        #expect(messageOnly.label.isEmpty && messageOnly.message == "stable")
        let short = try #require(Badge.parse("https://img.shields.io/badge/a-b-f0a?labelColor=%23222"))
        #expect(short.color == 0xFF00AA && short.labelColor == 0x222222)
    }

    @Test func otherURLsAreNotStaticBadges() {
        #expect(Badge.parse("https://img.shields.io/github/v/release/W-ZN/Zephyr") == nil)
        #expect(Badge.parse("https://img.shields.io/badge/Swift-6-F05138?logo=swift") == nil)
        #expect(Badge.parse("https://img.shields.io/badge/a-b-notacolor") == nil)
        #expect(Badge.parse("https://example.com/badge/a-b-blue") == nil)
        #expect(Badge.parse("docs/images/badge.svg") == nil)
    }

    @Test func analyzerMakesHTMLBlocksAndInlineImagesComponents() throws {
        let text = Self.readmeHeader + "\n\nText ![chip](https://img.shields.io/badge/a-b-blue) and [![CI](ci.svg)](https://ci) <img src=\"icon.png\" height=\"16\">\n\n<div>\n<script>x</script>\n</div>\n"
        let a = MarkdownAnalyzer.analyze(text)
        let kinds = a.components.map(\.kind)
        guard case .html = kinds[0] else { Issue.record("no HTML block: \(kinds)"); return }
        #expect(kinds.dropFirst().compactMap { kind -> String? in if case let .inlineImage(source, _, _, _) = kind { source } else { nil } } == ["https://img.shields.io/badge/a-b-blue", "ci.svg", "icon.png"])
        #expect(kinds.contains(.inlineImage(source: "icon.png", alt: "", width: nil, height: 16)))
        // The block with a script stays HTML source.
        let scriptLine = text.components(separatedBy: "\n").firstIndex(of: "<script>x</script>")!
        #expect(a.lines[scriptLine].kind == .html)
        // The header's component covers its block and excludes the line break after it.
        let header = a.components[0].range
        #expect((text as NSString).substring(with: header) == Self.readmeHeader)
    }

    static let container = """
    Intro.

    <div align="center">

    # Zephyr

    A **quiet** editor.<br>
    [![CI](https://img.shields.io/badge/ci-passing-brightgreen)](https://ci) [Docs](docs/guide.md)

    </div>

    After.
    """

    @Test func alignedContainersStayInOneChunk() {
        let chunks = ChunkIndex(text: Self.container as NSString).chunks.map { (Self.container as NSString).substring(with: $0.range) }
        #expect(chunks.count == 3)
        #expect(chunks[1].hasPrefix("<div align=\"center\">") && chunks[1].contains("</div>"))
        // Without an alignment the tags change nothing: blocks split as usual.
        let plain = Self.container.replacingOccurrences(of: "<div align=\"center\">", with: "<div>")
        #expect(ChunkIndex(text: plain as NSString).chunks.count > 3)
    }

    @Test func alignedContainerDrawsAsOneHTMLBlock() throws {
        let chunk = (Self.container as NSString).substring(with: ChunkIndex(text: Self.container as NSString).chunks[1].range)
        let a = MarkdownAnalyzer.analyze(chunk)
        #expect(a.components.count == 1)
        guard case let .html(fragment) = try #require(a.components.first).kind, case let .element(div) = fragment.nodes[0] else { Issue.record("no HTML block"); return }
        #expect(div.name == "div" && div["align"] == "center")
        #expect(fragment.plainText == "Zephyr\nA quiet editor.\nCI Docs")
        #expect(a.lines.allSatisfy { $0.kind == .component || $0.kind == .blank })
        // A list has no place in the subset: the container stays as written.
        let list = chunk.replacingOccurrences(of: "# Zephyr", with: "- one\n- two")
        let b = MarkdownAnalyzer.analyze(list)
        #expect(!b.components.contains { if case .html = $0.kind { true } else { false } })
        #expect(b.lines.first?.kind == .html)
    }

    @Test func containerOpeningsNeedAnAlignment() {
        #expect(HTMLContainer.opening(#"<div align="center">"#)! == ("div", "center"))
        #expect(HTMLContainer.opening("<p align=right>")! == ("p", "right"))
        #expect(HTMLContainer.opening("<center>")! == ("center", "center"))
        #expect(HTMLContainer.opening("<div>") == nil)
        #expect(HTMLContainer.opening(#"<div align="left">"#) == nil)
        #expect(HTMLContainer.opening(#"<div align="center"><img src="x.png"></div>"#) == nil)
    }

    @Test func pairedInlineTagsHideAndStyle() {
        let text = "Press <kbd>⌘</kbd><kbd>K</kbd>, H<sub>2</sub>O, x<sup>2</sup>, <b>bold</b> and <span>plain</span>."
        let a = MarkdownAnalyzer.analyze(text)
        let ns = text as NSString
        func styled(_ style: InlineStyle) -> [String] { a.inlines.filter { $0.style == style }.map { ns.substring(with: $0.range) } }
        #expect(styled(.keycap) == ["⌘", "K"])
        #expect(styled(.subscript) == ["2"] && styled(.superscript) == ["2"] && styled(.strong) == ["bold"])
        // The paired tags hide; `<span>` is not styled and stays visible HTML.
        let hidden = a.markers.filter { $0.style == .hide }.map { ns.substring(with: $0.range) }
        #expect(hidden.filter { $0 == "<kbd>" }.count == 2 && hidden.contains("</sup>") && !hidden.contains("<span>"))
        #expect(styled(.html) == ["<span>", "</span>"])
        // An unpaired tag stays as written.
        #expect(MarkdownAnalyzer.analyze("a <kbd>b").markers.isEmpty)
    }

    // MARK: Review regressions (round 44)

    @Test func formulasInsideAnImageStayPartOfIt() {
        let a = MarkdownAnalyzer.analyze("before ![price $x$](icon.png) after\n")
        #expect(a.components.count == 1)
        #expect(a.components.allSatisfy { if case .inlineImage = $0.kind { true } else { false } })
    }

    @Test func standaloneImagesUseTheSafeURLSubset() {
        #expect(MarkdownAnalyzer.safeHTMLImage("<img src=\"data:image/png;base64,AAAA\">") == nil)
        #expect(MarkdownAnalyzer.safeHTMLImage("<img src=\"vbscript:x\">") == nil)
        #expect(MarkdownAnalyzer.safeHTMLImage("<img src=\"images/a.png\" width=\"1e30\">")?.width == 20_000)
    }

    @Test func indentedContainersStayInOneChunk() {
        let text = Self.container.replacingOccurrences(of: "<div align=\"center\">", with: "  <div align=\"center\">")
        let chunks = ChunkIndex(text: text as NSString).chunks.map { (text as NSString).substring(with: $0.range) }
        // An indented line continues the chunk before it; the blank lines inside do not split it.
        #expect(chunks.contains { $0.contains("<div") && $0.contains("</div>") })
    }

    @Test func containersPairInlineTagsAndRefuseUnknownOnes() throws {
        let keys = MarkdownAnalyzer.analyze("<div align=\"center\">\n\nPress <kbd>⌘</kbd> <kbd>K</kbd>, H<sub>2</sub>O\n\n</div>\n")
        guard case let .html(fragment) = try #require(keys.components.first).kind else { Issue.record("no container"); return }
        #expect(fragment.plainText == "Press ⌘ K, H2O")
        #expect(fragment.serialized().contains("<kbd>⌘</kbd> <kbd>K</kbd>, H<sub>2</sub>O"))
        // A tag outside the subset leaves the container as source, not as a line break.
        let unknown = MarkdownAnalyzer.analyze("<div align=\"center\">\n\nA<bravo>B\n\n</div>\n")
        #expect(!unknown.components.contains { if case .html = $0.kind { true } else { false } })
    }

    @Test func manyInlineTagsPairInOnePass() {
        let n = 3000
        let text = (0..<n).map { _ in "<kbd>x</kbd>" }.joined(separator: "\n") + "\n"
        let a = MarkdownAnalyzer.analyze(text)
        #expect(a.inlines.filter { $0.style == .keycap }.count == n)
        #expect(!a.inlines.contains { $0.style == .html })
    }

    @Test func cssColorNamesMakeStaticBadges() throws {
        #expect(try #require(Badge.parse("https://img.shields.io/badge/a-b-blueviolet")).color == 0x8A2BE2)
        // shields.io's own names win: its green is not CSS green.
        #expect(try #require(Badge.parse("https://img.shields.io/badge/a-b-green")).color == 0x97CA00)
    }

    @Test func formulasInATableCellImageStayPartOfIt() {
        // A cell holding only an image parses as a block image.
        let a = MarkdownAnalyzer.analyze("![price $x$](icon.png)\n")
        #expect(!a.components.contains { if case .inlineMath = $0.kind { true } else { false } })
    }

    @Test func containersWithFormulasStaySourceForEveryReader() {
        let blocks = Document(parsing: "<div align=\"center\">\n\nMass $m$\n\n</div>\n").children.map { $0 }
        #expect(HTMLContainer.container(in: blocks, at: 0) == nil)
        let plain = Document(parsing: "<div align=\"center\">\n\nMass m\n\n</div>\n").children.map { $0 }
        #expect(HTMLContainer.container(in: plain, at: 0) != nil)
    }
}
