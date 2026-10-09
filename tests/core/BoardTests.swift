import Foundation
import Testing
@testable import ZephyrCore

/// Pages of blocks are plain Markdown read as a layout (design §8.3).
@Suite struct BoardTests {
    static let page = """
    ---
    icon: hammer
    ---
    # Zephyr launch

    Ship the reader, then the space.

    ## Next
    - [ ] Sidebar wheel
    - [x] Pages of blocks

    ## Tracking
    - [Progress](/Users/me/Code/Zephyr/docs/progress.md)
    - [Design](<docs/design notes.md>)

    ## Numbers
    - Tests: 172/180
    - Coverage: 81%
    - Users: 1.2k

    ## Notes
    Anything else is text, **with** Markdown.

    | A | B |
    |---|---|
    | 1 | 2 |

    ## Today
    <!-- zephyr: today, wide -->

    ## Later
    <!-- zephyr: tasks -->
    """

    @Test func blocksFollowWhatTheyHold() {
        let page = Board.page(in: Self.page as NSString)
        #expect(page.title == "Zephyr launch")
        #expect(page.symbol == "hammer")
        #expect(page.intro == "Ship the reader, then the space.")
        #expect(page.blocks.map(\.title) == ["Next", "Tracking", "Numbers", "Notes", "Today", "Later"])
        guard case let .tasks(items) = page.blocks[0].content else { Issue.record("tasks"); return }
        #expect(items.map(\.text) == ["Sidebar wheel", "Pages of blocks"])
        guard case let .links(links) = page.blocks[1].content else { Issue.record("links"); return }
        #expect(links.map(\.destination) == ["/Users/me/Code/Zephyr/docs/progress.md", "docs/design notes.md"])
        guard case let .numbers(numbers) = page.blocks[2].content else { Issue.record("numbers"); return }
        #expect(numbers.map(\.label) == ["Tests", "Coverage", "Users"])
        #expect(numbers.map(\.progress) == [172.0 / 180, 0.81, nil])
        #expect(page.blocks[3].content == .text)
        #expect(page.blocks[4].content == .live(.today))
        #expect(page.blocks[5].content == .tasks([]))
        #expect(page.blocks.map(\.wide) == [false, false, false, true, true, false])
    }

    @Test func addingATaskStaysInItsBlock() {
        var text = Self.page
        var page = Board.page(in: text as NSString)
        text = Space.addition("Quick Look", to: text, within: page.blocks[0].range).applied(to: text)
        page = Board.page(in: text as NSString)
        guard case let .tasks(next) = page.blocks[0].content else { Issue.record("tasks"); return }
        #expect(next.map(\.text) == ["Sidebar wheel", "Pages of blocks", "Quick Look"])
        // The first task of an empty block comes after its hint, a blank line between.
        text = Space.addition("Someday", to: text, within: page.blocks[5].range).applied(to: text)
        #expect(text.hasSuffix("## Later\n<!-- zephyr: tasks -->\n\n- [ ] Someday"))
        guard case let .tasks(later) = Board.page(in: text as NSString).blocks[5].content else { Issue.record("later"); return }
        #expect(later.map(\.text) == ["Someday"])
    }

    @Test func movingWideningAndRemoving() throws {
        var text = Self.page
        var page = Board.page(in: text as NSString)
        text = try #require(Board.moving(page.blocks[1], up: true, in: page, text: text)).applied(to: text)
        page = Board.page(in: text as NSString)
        #expect(page.blocks.map(\.title) == ["Tracking", "Next", "Numbers", "Notes", "Today", "Later"])
        #expect(text.contains("docs/design notes.md>)\n\n## Next\n"))
        // The last block moves up and keeps the note's ending.
        text = try #require(Board.moving(page.blocks[5], up: true, in: page, text: text)).applied(to: text)
        page = Board.page(in: text as NSString)
        #expect(page.blocks.suffix(2).map(\.title) == ["Later", "Today"])
        #expect(text.hasSuffix("## Today\n<!-- zephyr: today, wide -->"))

        text = Board.setting(wide: true, of: page.blocks[0], in: text).applied(to: text)
        #expect(text.contains("## Tracking\n<!-- zephyr: wide -->\n- [Progress]"))
        page = Board.page(in: text as NSString)
        #expect(page.blocks[0].wide)
        text = Board.setting(wide: false, of: page.blocks[0], in: text).applied(to: text)
        #expect(text.contains("## Tracking\n- [Progress]"))
        page = Board.page(in: text as NSString)
        text = Board.setting(wide: false, of: page.blocks[5], in: text).applied(to: text)
        #expect(text.hasSuffix("## Today\n<!-- zephyr: today -->"))

        page = Board.page(in: text as NSString)
        text = Board.removing(page.blocks[2]).applied(to: text)
        #expect(Board.page(in: text as NSString).blocks.map(\.title) == ["Tracking", "Next", "Notes", "Later", "Today"])
    }

    @Test func appendingLinksAndTitles() {
        var text = "# Week\n"
        text = Board.appending(title: "Reading", words: ["links"], to: text).applied(to: text)
        #expect(text == "# Week\n\n## Reading\n<!-- zephyr: links -->\n")
        var page = Board.page(in: text as NSString)
        #expect(page.blocks[0].content == .links([]))
        text = Board.linkAddition(title: "Plan", destination: "/tmp/my plan.md", to: page.blocks[0], in: text).applied(to: text)
        page = Board.page(in: text as NSString)
        text = Board.linkAddition(title: "Log", destination: "/tmp/log.md", to: page.blocks[0], in: text).applied(to: text)
        guard case let .links(links) = Board.page(in: text as NSString).blocks[0].content else { Issue.record("links"); return }
        #expect(links.map(\.title) == ["Plan", "Log"])
        #expect(links.first?.destination == "/tmp/my plan.md")
        #expect(Board.retitling("Next week", in: text).applied(to: text).hasPrefix("# Next week\n\n## Reading"))
        #expect(Board.retitling("Untitled", in: "Text\n").applied(to: "Text\n") == "# Untitled\n\nText\n")
        #expect(Board.fileName(for: "Plan: Q4/Q1", taken: ["plan  q4 q1.md"]) == "Plan  Q4 Q1 2.md")
    }

    /// Patch boundaries from the round-18 review: each change touches only what it means to.
    @Test func patchesKeepTheRestOfTheNote() throws {
        // Removing a block never takes a fenced heading's code with it.
        var text = "## Code\n  ```\n## fake\n  ```\n\n## Real\nok\n"
        var page = Board.page(in: text as NSString)
        #expect(page.blocks.map(\.title) == ["Code", "Real"])
        // Moving keeps a line's trailing spaces (a hard break, or code).
        text = "## A\n    payload  \n\n## B\nb\n"
        page = Board.page(in: text as NSString)
        text = try #require(Board.moving(page.blocks[1], up: true, in: page, text: text)).applied(to: text)
        #expect(text == "## B\nb\n\n## A\n    payload  \n")
        // A setext title is replaced whole; `===` under an ATX heading is body text.
        #expect(Board.retitling("New", in: "Old\n===\n\nText\n").applied(to: "Old\n===\n\nText\n") == "# New\n\nText\n")
        page = Board.page(in: "## A\n===\nbody\n" as NSString)
        #expect(page.blocks[0].body.location == 5)
        // A title after front matter that ends the note starts on its own line.
        let front = "---\nicon: hammer\n---"
        #expect(Board.retitling("New", in: front).applied(to: front) == "---\nicon: hammer\n---\n# New\n\n")
        // A body with its own line breaks takes the note's.
        let crlf = "# W\r\n"
        #expect(Board.appending(title: "N", body: "x\r\ny\n", to: crlf).applied(to: crlf) == "# W\r\n\r\n## N\r\n\r\nx\r\ny\r\n")
        // Parentheses in a path stay inside the link.
        text = "## L\n<!-- zephyr: links -->\n"
        page = Board.page(in: text as NSString)
        text = Board.linkAddition(title: "A", destination: "/tmp/a(b).md", to: page.blocks[0], in: text).applied(to: text)
        guard case let .links(links) = Board.page(in: text as NSString).blocks[0].content else { Issue.record("links"); return }
        #expect(links.map(\.destination) == ["/tmp/a(b).md"])
    }

}
