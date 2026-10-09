import AppKit
import Testing
@testable import ZephyrRender

@MainActor
@Suite struct MarkdownSnippetTests {
    @Test(arguments: ["- Item", "1. Item", "- [x] Item"])
    func embeddedListsKeepTheirMarkersOnATransparentSurface(_ source: String) throws {
        let snippet = MarkdownSnippet(text: source + "\n", typography: Typography(), baseURL: nil)
        snippet.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        snippet.layoutSubtreeIfNeeded()
        let rep = try #require(snippet.bitmapImageRepForCachingDisplay(in: snippet.bounds))
        snippet.cacheDisplay(in: snippet.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / snippet.bounds.width
        let markerVisible = (Int(2 * scale)..<Int(23 * scale)).contains { x in
            (0..<rep.pixelsHigh).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
        }
        #expect(markerVisible)
        #expect((rep.colorAt(x: rep.pixelsWide - 1, y: rep.pixelsHigh - 1)?.alphaComponent ?? 1) == 0)
    }
}
