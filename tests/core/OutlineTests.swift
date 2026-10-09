import Foundation
import Testing
@testable import ZephyrCore

/// One outline for every reader (the app's rail and card, agents' context, `zephyr outline`).
@Suite struct OutlineTests {
    static let text = """
    ---
    title: Plan
    # a comment
    ---
    ===

    # Plan ##

    Setext two
    ----------

    ```
    # not a heading
    ```

    ### Three `code` **bold**

        # indented code

    - item
    ---
    """

    @Test func renderedTitlesAsTheCanvasShowsThem() {
        let headings = Outline.headings(in: Self.text as NSString)
        #expect(headings.map(\.level) == [1, 2, 3])
        #expect(headings.map(\.title) == ["Plan", "Setext two", "Three code bold"])
        #expect(headings.map(\.location) == [(Self.text as NSString).range(of: "# Plan").location, (Self.text as NSString).range(of: "Setext two").location, (Self.text as NSString).range(of: "### Three").location])
    }

    /// The canvas shows "Hello" then an empty bullet, so the outline lists no heading either.
    @Test func aLoneDashIsNoUnderline() {
        #expect(Outline.headings(in: "Hello\n- " as NSString).isEmpty)
        #expect(Outline.headings(in: "Hello\n--" as NSString).map(\.title) == ["Hello"])
    }

    @Test func sourceModeKeepsTheMarkup() {
        #expect(Outline.headings(in: Self.text as NSString, rendered: false).map(\.title) == ["Plan", "Three `code` **bold**"])
    }

    @Test func crlfLines() {
        let text = "Title\r\n=====\r\n\r\n## Two\r\n" as NSString
        #expect(Outline.headings(in: text).map(\.title) == ["Title", "Two"])
    }

    @Test func fencedHeadingsAreCode() {
        let text = "## Code\n  ```\n## fake\n  ```\n\n````\n```\n## also code\n````\n\n## Real\nok\n"
        #expect(Outline.headings(in: text as NSString).map(\.title) == ["Code", "Real"])
    }

}
