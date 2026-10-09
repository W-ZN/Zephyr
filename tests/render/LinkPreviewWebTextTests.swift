import Foundation
import Testing
@testable import ZephyrRender

@Suite struct LinkPreviewWebTextTests {
    @Test func emptyMainDoesNotHideArticleAndTruncatedBodyRemainsReadable() {
        let html = "<html><head><title>Article</title></head><body><main></main><article><h1>Actual heading</h1><p>Actual paragraph.</p><script>unfinished()"
        let content = LinkPreviewHTML.content(html, fallbackTitle: "example.test")
        #expect(content.title == "Article")
        #expect(content.body == "Actual heading\nActual paragraph.")
        #expect(!content.isSummary)
        #expect(!content.body.contains("unfinished"))
    }

    @Test func clientRenderedShellUsesClearlyIdentifiedMetadataSummary() {
        let html = "<html><head><title>Generic title</title><meta content='Specific &amp; useful' property='og:title'><meta content='Readable description.' name='description'><script>window.app = true</script></head><body><div id='root'></div></body></html>"
        let content = LinkPreviewHTML.content(html, fallbackTitle: "example.test")
        #expect(content.title == "Specific & useful")
        #expect(content.body == "Readable description.")
        #expect(content.isSummary)
        #expect(!content.body.contains("Generic title"))
    }

    @Test func structuredArticleIsReadAsDataWithoutExecutingScript() {
        let html = #"<html><head><title>Data article</title><script type="application/ld+json">{"@graph":[{"@type":"NewsArticle","articleBody":"First paragraph.\nSecond paragraph."}]}</script><script>secret()</script></head><body><main></main></body></html>"#
        let content = LinkPreviewHTML.content(html, fallbackTitle: "example.test")
        #expect(content.body == "First paragraph.\nSecond paragraph.")
        #expect(!content.isSummary)
    }

    @Test func declaredEncodingAndMarkdownResponsesAreRecognized() throws {
        let encoded = Data([0x63, 0x61, 0x66, 0xE9])
        #expect(LinkPreviewHTTP.decode(encoded, contentType: "text/html; charset=iso-8859-1") == "café")
        #expect(LinkPreviewHTTP.decode(encoded, contentType: "text/html; charset=unknown-encoding") == nil)
        #expect(LinkPreviewHTTP.accepts("text/markdown; charset=utf-8"))
        #expect(LinkPreviewHTTP.isMarkdown("text/plain", url: URL(string: "https://example.test/README.md")!))
        #expect(!LinkPreviewHTTP.isMarkdown("text/html", url: URL(string: "https://example.test/page.md")!))
        #expect(LinkPreviewHTTP.isHTML(nil, prefix: "\n<!DOCTYPE html><html>"))
        #expect(!LinkPreviewHTTP.isHTML(nil, prefix: "# A Markdown heading"))
    }

    @Test func extractedContentAndSummaryStayBounded() {
        let paragraph = String(repeating: "Readable word ", count: 10_000)
        let content = LinkPreviewHTML.content("<body><main><p>\(paragraph)</p></main></body>", fallbackTitle: "example.test")
        #expect(content.body.count <= 8 << 10)
        #expect(!content.isSummary)
        let summary = LinkPreviewHTML.content("<head><meta name='description' content='\(paragraph)'></head><body></body>", fallbackTitle: "example.test")
        #expect(summary.body.count <= 1_800)
        #expect(summary.isSummary)
    }

    @Test func networkFailuresHaveSpecificReadableStates() {
        #expect(LinkPreviewHTTP.failureDescription(.notConnectedToInternet) == String(localized: "No network connection. Local files can still be previewed."))
        #expect(LinkPreviewHTTP.failureDescription(.networkConnectionLost) == String(localized: "The network connection was lost. Local files can still be previewed."))
        #expect(LinkPreviewHTTP.failureDescription(.timedOut) == String(localized: "The website took too long to respond. Open the link to try again."))
        #expect(LinkPreviewHTTP.failureDescription(.cannotFindHost) == String(localized: "The website could not be reached."))
    }

    @Test func commonEditorialEntitiesRemainReadable() {
        let result = LinkPreviewHTML.content("<main><p>It&rsquo;s &ldquo;ready&rdquo;&mdash;A &amp; B&hellip;</p></main>", fallbackTitle: "Article")
        #expect(result.body == "It’s “ready”—A & B…")
    }
}
