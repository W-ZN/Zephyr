import Foundation
import Testing
@testable import ZephyrCore

/// Text statistics (design §8): one prose stream without Markdown markers, link targets, front
/// matter, code, formulas or diagrams; Han characters count one word each.
@Suite struct TextStatisticsTests {
    func count(_ text: String, _ range: NSRange? = nil) -> TextStatistics { TextStatistics.count(text as NSString, in: range) }

    @Test func mixedChineseAndEnglish() {
        let s = count("hello 世界")
        #expect(s.words == 3 && s.hanUnits == 2)
        #expect(s.characters == 7 && s.charactersWithSpaces == 8)
        #expect(count("don't stop well-known 3.14 and 1,000 snake_case").words == 7)
        #expect(count("你好，世界。").characters == 6, "punctuation counts as characters, not words")
        #expect(count("你好，世界。").words == 4)
    }

    @Test func markdownIsNotCounted() {
        let text = """
        ---
        title: Not counted
        ---

        # Title here

        Some **bold** and `code` with a [link](https://example.com/very/long) and ![alt text](a.png).

        - item one
        - [x] item two
          continued

        > quoted line
        > same paragraph

        ```mermaid
        graph TD
          A --> B
        ```

        $$
        E = mc^2
        $$

        | Name | Value |
        |------|-------|
        | a    | 1     |

        Setext heading
        --------------
        """
        let s = count(text)
        #expect(s.headings == 2)
        #expect(s.paragraphs == 4, "body, two list items, the quote")
        // Title here (2) + Some bold and code with a link and (8) + item one (2) + item two continued (3)
        // + quoted line same paragraph (4) + Name Value a 1 (4) + Setext heading (2)
        #expect(s.words == 25)
    }

    @Test func selectionCountsItsPart() {
        let text = "First paragraph here.\n\n```\ncode words\n```\n\n第二段文字。\n" as NSString
        let all = TextStatistics.count(text)
        #expect(all.paragraphs == 2 && all.words == 3 + 5)
        let second = text.range(of: "第二段")
        let s = TextStatistics.count(text, in: NSRange(location: second.location, length: 3))
        #expect(s.words == 3 && s.paragraphs == 1)
        let code = text.range(of: "code words")
        #expect(TextStatistics.count(text, in: code).words == 0, "code stays out of a selection too")
        // A selection is read as part of its line: a link's target and a formula stay out.
        let line = "See [the label](secret-target) and $x$ here.\n\n## Two words\n" as NSString
        #expect(TextStatistics.count(line, in: line.range(of: "secret-target")).characters == 0)
        #expect(TextStatistics.count(line, in: line.range(of: "x$ he")).characters == 2)
        #expect(TextStatistics.count(line, in: line.range(of: "label](secret")).words == 1)
        let heading = TextStatistics.count(line, in: line.range(of: "## Two"))
        #expect(heading.characters == 3 && heading.headings == 1, "the marks are not text")
    }

    @Test func unclosedBracketsCostOnePass() {
        let line = String(repeating: "[a(`<", count: 40_000)
        let clock = ContinuousClock()
        let time = clock.measure { _ = TextStatistics.count(line as NSString) }
        #expect(time < .seconds(1))
    }

    @Test func readingTime() {
        var s = TextStatistics()
        s.words = 400 + 220
        s.hanUnits = 400
        #expect(s.readingMinutes == 2)
    }
}
