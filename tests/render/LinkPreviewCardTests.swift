import AppKit
import Testing
@testable import ZephyrRender

@MainActor
@Suite struct LinkPreviewCardTests {
    @Test func cardUsesThemeColorsAfterAnAppearanceChange() throws {
        let card = LinkPreviewCard(size: NSSize(width: 420, height: 300), typography: Typography())
        card.show(.text(title: "Example.txt", text: "let answer = 42"))
        let title = try #require(card.subviews.first { $0 is NSTextField } as? NSTextField)
        let scroll = try #require(card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let body = try #require(scroll.documentView as? NSTextView)
        let bodyColor = try #require(body.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)

        let light = try #require(NSAppearance(named: .aqua))
        card.appearance = light
        card.updateLayer()
        #expect(colorsMatch(card.layer?.backgroundColor, Tokens.raised, in: light))
        #expect(colorsMatch(card.layer?.borderColor, Tokens.line, in: light))
        #expect(colorsMatch(title.textColor, Tokens.ink, in: light))
        #expect(colorsMatch(bodyColor, Tokens.ink, in: light))

        let dark = try #require(NSAppearance(named: .darkAqua))
        card.appearance = dark
        #expect(colorsMatch(card.layer?.backgroundColor, Tokens.raised, in: dark))
        #expect(colorsMatch(card.layer?.borderColor, Tokens.line, in: dark))
        #expect(colorsMatch(title.textColor, Tokens.ink, in: dark))
        #expect(colorsMatch(bodyColor, Tokens.ink, in: dark))
    }

    @Test func markdownSnippetStaysInsideTheScrollableCardBody() throws {
        let card = LinkPreviewCard(size: NSSize(width: 420, height: 300), typography: Typography())
        card.show(.markdown(title: "Notes", text: "# Heading\n\nA short preview paragraph.", baseURL: URL(fileURLWithPath: "/notes"), context: "preview context"))
        card.layoutSubtreeIfNeeded()

        let scroll = try #require(card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let host = try #require(scroll.documentView)
        let snippet = try #require(host.subviews.first as? MarkdownSnippet)
        #expect(scroll.hasVerticalScroller)
        #expect(snippet.frame.width == scroll.contentSize.width)
        #expect(host.frame.height >= scroll.contentSize.height)
        let height = snippet.frame.height
        _ = card.fittingHeight(forWidth: 420, maxHeight: 300)
        #expect(snippet.frame.height == height)
    }

    @Test func offlineCardKeepsOpenAvailableAndDisablesAsk() throws {
        let card = LinkPreviewCard(size: NSSize(width: 420, height: 300), typography: Typography())
        let detail = LinkPreviewHTTP.failureDescription(.notConnectedToInternet)
        card.show(.failure(title: "example.test", detail: detail))
        let scroll = try #require(card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let body = try #require(scroll.documentView as? NSTextView)
        #expect(body.string == detail)
        let buttons = card.subviews.compactMap { $0 as? FlatButton }
        #expect(buttons.first { $0.title == String(localized: "Open") }?.isEnabled == true)
        #expect(buttons.first { $0.title == String(localized: "Ask AI") }?.isEnabled == false)
    }

    @Test func cardUsesCompactHeightUntilItsScrollableContentNeedsTheMaximum() {
        let loading = LinkPreviewCard(size: NSSize(width: 420, height: 300), typography: Typography())
        #expect(loading.fittingHeight(forWidth: 420, maxHeight: 300) == 112)

        let failure = LinkPreviewCard(size: NSSize(width: 420, height: 300), typography: Typography())
        var changes = 0
        failure.onContentSizeChanged = { changes += 1 }
        failure.show(.failure(title: "example.test", detail: "Could not load preview."))
        #expect(changes == 1)
        #expect(failure.fittingHeight(forWidth: 420, maxHeight: 300) < 300)

        let long = LinkPreviewCard(size: NSSize(width: 420, height: 300), typography: Typography())
        long.show(.text(title: "large.txt", text: String(repeating: "A long line for the preview.\n", count: 100)))
        #expect(long.fittingHeight(forWidth: 420, maxHeight: 300) == 300)
    }

    @Test func articleGetsAUsefulViewportAndThemeTitleWhileFailureStaysCompact() throws {
        let typography = Typography()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        let card = LinkPreviewCard(size: NSSize(width: 420, height: 112), typography: typography)
        let overlay = LinkPreviewOverlay(frame: host.bounds, card: card, anchor: NSPoint(x: 40, y: 300))
        host.addSubview(overlay)
        card.show(.website(title: "An article with a complete title", detail: String(repeating: "A readable paragraph with useful article content.\n", count: 80), url: URL(string: "https://example.test/article")!, isSummary: false))
        overlay.needsLayout = true
        overlay.layoutSubtreeIfNeeded()
        let scroll = try #require(card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let title = try #require(card.subviews.first { $0 is NSTextField } as? NSTextField)
        #expect(card.frame.width >= 560 && card.frame.height > 400)
        #expect(scroll.contentSize.height >= typography.lineHeight(for: typography.bodyFont, kind: .body) * 14)
        #expect(title.font?.pointSize == typography.bodyFont.pointSize)
        #expect(title.toolTip == "An article with a complete title")

        card.show(.failure(title: "example.test", detail: "Could not load preview."))
        overlay.needsLayout = true
        overlay.layoutSubtreeIfNeeded()
        #expect(card.frame.width == 420 && card.frame.height <= 160, "failure stays compact while retaining the source subtitle")
    }

    @Test func legacyScrollerMeasurementMatchesTheActualTextViewport() throws {
        let card = LinkPreviewCard(size: NSSize(width: 560, height: 300), typography: Typography())
        let scroll = try #require(card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        scroll.scrollerStyle = .legacy
        card.show(.website(title: "Article", detail: String(repeating: "Words at the wrapping boundary. ", count: 12), url: URL(string: "https://example.test/article")!, isSummary: false))
        card.frame.size.height = card.fittingHeight(forWidth: 560, maxHeight: 900)
        card.layoutSubtreeIfNeeded()
        let body = try #require(scroll.documentView as? NSTextView)
        let container = try #require(body.textContainer)
        #expect(container.containerSize.width == scroll.contentSize.width - body.textContainerInset.width * 2)
        let usedHeight = try #require(body.layoutManager?.usedRect(for: container).height) + body.textContainerInset.height * 2
        #expect(ceil(usedHeight) <= scroll.contentSize.height + 1)
    }

    @Test func failedMarkdownImageInvalidatesTheMeasuredCardHeight() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-snippet-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("photo.png")
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(image.bitmapData).initialize(repeating: 255, count: image.bytesPerRow * image.pixelsHigh)
        try #require(image.representation(using: .png, properties: [:])).write(to: url)
        let card = LinkPreviewCard(size: NSSize(width: 420, height: 112), typography: Typography())
        card.show(.markdown(title: "Image", text: "![A](photo.png)\n", baseURL: folder, context: "image"))
        let before = card.fittingHeight(forWidth: 420, maxHeight: 900)
        card.frame.size.height = before
        card.layoutSubtreeIfNeeded()
        let scroll = try #require(card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let snippet = try #require(scroll.documentView?.subviews.first as? MarkdownSnippet)
        var changes = 0
        card.onContentSizeChanged = { changes += 1 }
        // Header dimensions were measured; removing the file now exercises the asynchronous decode failure.
        try FileManager.default.removeItem(at: url)
        let rep = try #require(snippet.bitmapImageRepForCachingDisplay(in: snippet.bounds))
        snippet.cacheDisplay(in: snippet.bounds, to: rep)
        for _ in 0..<100 where changes == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(changes > 0)
        let after = card.fittingHeight(forWidth: 420, maxHeight: 900)
        #expect(after < before - 200)
        card.frame.size.height = after
        card.layoutSubtreeIfNeeded()
        #expect(scroll.documentView?.frame.height == max(snippet.intrinsicContentSize.height, scroll.contentSize.height))
    }

    @Test func pageSnapshotIsPassiveAndReturnsToTheOriginalText() throws {
        let card = LinkPreviewCard(size: NSSize(width: 600, height: 420), typography: Typography())
        card.show(.website(title: "Article", detail: "Useful original text", url: URL(string: "https://example.test/article")!, isSummary: false))
        let page = try #require(card.subviews.compactMap { $0 as? FlatButton }.first { $0.title == String(localized: "Page snapshot") })
        #expect(!page.isHidden)
        let host = card.beginPageSnapshot()
        card.layoutSubtreeIfNeeded()
        let point = host.convert(NSPoint(x: 10, y: 10), to: host.superview)
        #expect(host.hitTest(point) === host, "the passive surface consumes input instead of passing it to the document")
        #expect(host.subviews.first is NSBox, "an opaque surface covers the live page during rendering")
        let image = NSImage(size: NSSize(width: 600, height: 375))
        card.showPageSnapshot(.init(image: image, title: "Rendered article", text: "Rendered text"))
        #expect(page.isEnabled && page.title == String(localized: "Text preview"))
        let scroll = try #require(card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        #expect(!scroll.hasVerticalScroller)
        #expect(host.subviews.compactMap { $0 as? NSImageView }.first?.image === image)
        page.performClick(nil)
        let body = try #require(scroll.documentView as? NSTextView)
        #expect(body.string == "Useful original text")
        #expect(page.title == String(localized: "Page snapshot"))
    }

    @Test func failedPageSnapshotShrinksAndKeepsTextAvailable() throws {
        let card = LinkPreviewCard(size: NSSize(width: 600, height: 420), typography: Typography())
        card.show(.website(title: "Article", detail: "Original text remains useful", url: URL(string: "https://example.test/article")!, isSummary: false))
        _ = card.beginPageSnapshot()
        card.showPageFailure("No network connection.")
        #expect(card.preferredWidth == 420)
        #expect(card.fittingHeight(forWidth: 420, maxHeight: 560) < 180)
        let page = try #require(card.subviews.compactMap { $0 as? FlatButton }.first { $0.title == String(localized: "Text preview") })
        page.performClick(nil)
        let scroll = try #require(card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        #expect((scroll.documentView as? NSTextView)?.string == "Original text remains useful")
        card.show(.markdown(title: "Note", text: "# Markdown", baseURL: URL(fileURLWithPath: "/notes"), context: "note"))
        #expect(page.isHidden)
    }

    @Test func returningDuringPageLoadCancelsAndIgnoresLateSnapshot() throws {
        let card = LinkPreviewCard(size: NSSize(width: 600, height: 420), typography: Typography())
        card.show(.website(title: "Article", detail: "Original body", url: URL(string: "https://example.test")!, isSummary: false))
        var cancelled = 0
        card.onPageCancel = { cancelled += 1 }
        _ = card.beginPageSnapshot()
        let button = try #require(card.subviews.compactMap { $0 as? FlatButton }.first { $0.title == String(localized: "Text preview") })
        #expect(button.isEnabled)
        button.performClick(nil)
        card.showPageSnapshot(.init(image: NSImage(size: NSSize(width: 600, height: 375)), title: "Late page", text: "Late body"))
        let scroll = try #require(card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        #expect((scroll.documentView as? NSTextView)?.string == "Original body")
        #expect(cancelled == 1)
    }

    @Test func documentImagesUseAProportionalContentAreaAndNoImaginaryAIText() throws {
        let card = LinkPreviewCard(size: NSSize(width: 560, height: 450), typography: Typography())
        card.show(.visual(title: "Budget.xlsx", detail: "", image: NSImage(size: NSSize(width: 800, height: 500)), context: "", kind: String(localized: "Thumbnail")))
        card.layoutSubtreeIfNeeded()
        let scroll = try #require(card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let host = try #require(scroll.documentView as? LinkPreviewVisualSurface)
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.subviews.first as? NSImageView)
        #expect(image.frame.width == scroll.contentSize.width)
        #expect(image.frame.height > 120 && image.frame.height <= 320)
        #expect(card.subviews.compactMap { $0 as? FlatButton }.first { $0.title == String(localized: "Ask AI") }?.isEnabled == false)
    }

    private func colorsMatch(_ actual: CGColor?, _ expected: NSColor, in appearance: NSAppearance) -> Bool {
        guard let actual, let color = NSColor(cgColor: actual) else { return false }
        return colorsMatch(color, expected, in: appearance)
    }

    private func colorsMatch(_ actual: NSColor?, _ expected: NSColor, in appearance: NSAppearance) -> Bool {
        guard let actual = resolved(actual, in: appearance), let expected = resolved(expected, in: appearance) else { return false }
        return abs(actual.redComponent - expected.redComponent) < 0.001
            && abs(actual.greenComponent - expected.greenComponent) < 0.001
            && abs(actual.blueComponent - expected.blueComponent) < 0.001
            && abs(actual.alphaComponent - expected.alphaComponent) < 0.001
    }

    private func resolved(_ color: NSColor?, in appearance: NSAppearance) -> NSColor? {
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = color?.usingColorSpace(.sRGB)
        }
        return result
    }
}
