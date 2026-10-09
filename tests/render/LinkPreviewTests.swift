import AppKit
import Testing
@testable import ZephyrRender

@MainActor
@Suite struct LinkPreviewTests {
    @Test func localTargetsUseTheDocumentDirectoryAndDropFragments() throws {
        let base = URL(fileURLWithPath: "/notes/project", isDirectory: true)
        let markdown = try #require(LinkPreviewTarget(destination: "plan%20draft.md#next", baseURL: base))
        #expect(markdown == .markdown(URL(fileURLWithPath: "/notes/project/plan draft.md"), nil))
        let pdf = try #require(LinkPreviewTarget(destination: "file:///notes/reference.pdf#page=4", baseURL: base))
        #expect(pdf == .pdf(URL(fileURLWithPath: "/notes/reference.pdf")))
        #expect(LinkPreviewTarget(destination: "#section", baseURL: base) == nil)
        #expect(LinkPreviewTarget(destination: "mailto:writer@example.com", baseURL: base) == nil)
    }

    @Test func lineAnchorsSelectTheExactNumberedLocalExcerpt() throws {
        let base = URL(fileURLWithPath: "/notes/project", isDirectory: true)
        let target = try #require(LinkPreviewTarget(destination: "src/main.swift#L10-L12", baseURL: base))
        guard case let .text(url, lines) = target else { Issue.record("Expected a text target"); return }
        #expect(url == URL(fileURLWithPath: "/notes/project/src/main.swift"))
        #expect(lines == LinkPreviewLineRange(fragment: "L10-L12"))
        let text = (1...14).map { "line \($0)" }.joined(separator: "\n")
        #expect(LinkPreviewText.excerpt(from: text, lines: lines, limit: 1_000) == "10  line 10\n11  line 11\n12  line 12")
        #expect(LinkPreviewText.decodeUTF8(Data("safe".utf8) + Data([0xE4])) == "safe")
        #expect(LinkPreviewText.decodeUTF8(Data("safe".utf8) + Data([0xFF])) == nil)
        let colonTarget = try #require(LinkPreviewTarget(destination: "src/main.swift:3", baseURL: base))
        guard case let .text(_, colonLines) = colonTarget else { Issue.record("Expected a colon line target"); return }
        #expect(LinkPreviewText.excerpt(from: text, lines: colonLines, limit: 1_000) == "3  line 3")
    }

    @Test func githubBlobLineLinksFetchRawSourceWithoutForwardingLinkMetadata() throws {
        let target = try #require(LinkPreviewTarget(destination: "https://github.com/Decem-Y/kaggriculture-bc/blob/d4fbdc4b2abef3ac88c27e03b6a0313f060d21fe/src/policy.py?plain=1#L361-L365", baseURL: nil))
        guard case let .web(raw, lines) = target else { Issue.record("Expected a web target"); return }
        #expect(raw.absoluteString == "https://raw.githubusercontent.com/Decem-Y/kaggriculture-bc/d4fbdc4b2abef3ac88c27e03b6a0313f060d21fe/src/policy.py")
        #expect(lines == LinkPreviewLineRange(fragment: "L361-L365"))
        #expect(LinkPreviewGitHub.rawURL(for: URL(string: "https://github.com/Decem-Y/kaggriculture-bc/tree/main")!) == nil)
    }

    @Test func plainResponseAppliesLineAnchorsBeforeItsDisplayLimit() {
        let text = (1...8).map { "    row \($0)" }.joined(separator: "\n")
        let lines = LinkPreviewLineRange(fragment: "L3-L6")
        #expect(LinkPreviewHTML.plainResponse(text, lines: lines, limit: 1_000) == "3      row 3\n4      row 4\n5      row 5\n6      row 6")
        #expect(LinkPreviewHTML.plainResponse(text, lines: LinkPreviewLineRange(fragment: "L9"), limit: 1_000) == nil)
    }

    @Test func webBodyWinsOverMetadataAndExcludesChromeAndScripts() {
        let html = "<html><head><title> A &amp; B </title><meta property=\"og:description\" content=\"Metadata only\"><script>secret()</script></head><body><nav>Navigation</nav><main><h1>Actual heading</h1><p>Actual paragraph.</p></main><footer>Footer</footer></body></html>"
        let content = LinkPreviewHTML.content(html, fallbackTitle: "example.test")
        #expect(content.title == "A & B")
        #expect(content.body == "Actual heading\nActual paragraph.")
        #expect(!content.body.contains("Metadata only"))
        #expect(!content.body.contains("secret"))
        #expect(LinkPreviewHTML.content("<body><p>One&nbsp;&#x32;</p></body>", fallbackTitle: "example.test").body == "One 2")
    }

    @Test func webPreviewAcceptsOnlyTextResponses() {
        #expect(LinkPreviewHTTP.accepts(nil))
        #expect(LinkPreviewHTTP.accepts("text/html; charset=utf-8"))
        #expect(LinkPreviewHTTP.accepts("application/xhtml+xml"))
        #expect(!LinkPreviewHTTP.accepts("image/png"))
        #expect(!LinkPreviewHTTP.accepts("application/pdf"))
        #expect(LinkPreviewHTTP.accepts("application/json; charset=utf-8"))
        #expect(LinkPreviewHTTP.accepts("application/problem+json"))
        #expect(LinkPreviewHTTP.accepts("application/xml"))
        #expect(LinkPreviewHTTP.accepts("text/x-python"))
        #expect(!LinkPreviewHTTP.accepts("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"))
    }

    @Test func officeFilesUseSystemThumbnailsInsteadOfTextDecoding() throws {
        let base = URL(fileURLWithPath: "/notes")
        for ext in ["doc", "docx", "xls", "xlsx", "pptx", "pages", "numbers", "key", "odt", "ods", "rtf"] {
            #expect(LinkPreviewTarget(destination: "file.\(ext)", baseURL: base) == .office(base.appendingPathComponent("file.\(ext)")))
        }
        #expect(LinkPreviewTarget(destination: "file.json", baseURL: base) == .text(base.appendingPathComponent("file.json"), nil))
        #expect(LinkPreviewTarget(destination: "file.xml", baseURL: base) == .text(base.appendingPathComponent("file.xml"), nil))
    }

    @Test func cardStaysInsideTheCurrentWindow() {
        let small = LinkPreviewLayout.cardSize(for: NSSize(width: 420, height: 300))
        #expect(small == NSSize(width: 396, height: 276))
        #expect(LinkPreviewLayout.cardSize(for: NSSize(width: 1_200, height: 900)) == NSSize(width: 420, height: 560))
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 300)
        for anchor in [NSPoint(x: 0, y: 0), NSPoint(x: 420, y: 0), NSPoint(x: 0, y: 300), NSPoint(x: 420, y: 300)] {
            for flipped in [true, false] {
                let frame = LinkPreviewLayout.cardFrame(size: small, in: bounds, anchor: anchor, flipped: flipped)
                #expect(frame.minX >= 12 && frame.maxX <= 408)
                #expect(frame.minY >= 12 && frame.maxY <= 288)
            }
        }
        let card = NSSize(width: 200, height: 120)
        #expect(LinkPreviewLayout.cardFrame(size: card, in: NSRect(x: 0, y: 0, width: 800, height: 600), anchor: NSPoint(x: 300, y: 200), flipped: true).minX == 314)
        #expect(LinkPreviewLayout.cardFrame(size: card, in: NSRect(x: 0, y: 0, width: 800, height: 600), anchor: NSPoint(x: 780, y: 200), flipped: true).minX == 566)
    }

    @Test func overlayResizesItsCardAndUsesSuperviewHitCoordinates() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let card = LinkPreviewCard(size: NSSize(width: 420, height: 300), typography: Typography())
        let overlay = LinkPreviewOverlay(frame: NSRect(x: 40, y: 50, width: 420, height: 300), card: card, anchor: NSPoint(x: 210, y: 150))
        host.addSubview(overlay)
        overlay.layoutSubtreeIfNeeded()
        let cardPoint = NSPoint(x: overlay.frame.minX + card.frame.midX, y: overlay.frame.minY + card.frame.midY)
        #expect(overlay.hitTest(cardPoint) != nil)
        #expect(overlay.hitTest(NSPoint(x: overlay.frame.minX + 1, y: overlay.frame.minY + 1)) == nil)
        overlay.setFrameSize(NSSize(width: 600, height: 480))
        overlay.layoutSubtreeIfNeeded()
        #expect(card.frame.size == NSSize(width: 420, height: 112))
        #expect(overlay.bounds.contains(card.frame))
    }

    @Test func explicitPreviewReusesAnExistingPreviewForTheSameDestination() throws {
        let editor = MarkdownEditor(text: "[preview](file:///dev/null)", typography: Typography(), baseURL: nil, isEditable: false)
        editor.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.scrollView.layoutSubtreeIfNeeded()
        let controller = LinkPreviewController(editor: editor)
        let destination = "file:///dev/null"
        controller.preview(destination: destination, at: NSPoint(x: 20, y: 20), in: editor.blockCanvas.view)
        let overlay = try #require(editor.scrollView.contentView.subviews.last)

        controller.preview(destination: destination, at: NSPoint(x: 20, y: 20), in: editor.blockCanvas.view)
        #expect(editor.scrollView.contentView.subviews.contains { $0 === overlay })
    }

    @Test func sourcePreviewFocusKeepsTheCardUntilFocusLeavesIt() async throws {
        let editor = MarkdownEditor(text: "[preview](file:///dev/null)", typography: Typography(), baseURL: nil, isEditable: false)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(editor.blockCanvas.view))
        editor.previewLink("file:///dev/null", at: NSPoint(x: 20, y: 20))
        let overlay = try #require(editor.scrollView.contentView.subviews.last as? LinkPreviewOverlay)
        overlay.card.show(.text(title: "Example.swift", text: "let value = [1]"))
        let scroll = try #require(overlay.card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let source = try #require(scroll.documentView as? LinkPreviewSourceView)
        let outside = NSTextView(frame: .zero)
        window.contentView?.addSubview(outside)

        #expect(window.makeFirstResponder(source))
        #expect(window.firstResponder === source)
        await Task.yield()
        #expect(overlay.superview != nil)

        #expect(window.makeFirstResponder(outside))
        #expect(window.firstResponder === outside)
        await Task.yield()
        #expect(overlay.superview == nil)
    }

    @Test func sourcePreviewEscapeRestoresTheCanvasResponder() throws {
        let editor = MarkdownEditor(text: "[preview](file:///dev/null)", typography: Typography(), baseURL: nil, isEditable: false)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(editor.blockCanvas.view))
        editor.previewLink("file:///dev/null", at: NSPoint(x: 20, y: 20))
        let overlay = try #require(editor.scrollView.contentView.subviews.last as? LinkPreviewOverlay)
        overlay.card.show(.text(title: "Example.swift", text: "let value = [1]"))
        let scroll = try #require(overlay.card.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let source = try #require(scroll.documentView as? LinkPreviewSourceView)

        #expect(window.makeFirstResponder(source))
        source.cancelOperation(nil)
        #expect(overlay.superview == nil)
        #expect(window.firstResponder === editor.blockCanvas.view)
    }

    @Test func wideCardsShrinkVerticallyWhenNeitherSideCanFit() {
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 400)
        for anchor in [NSPoint(x: 300, y: 40), NSPoint(x: 300, y: 200), NSPoint(x: 300, y: 360)] {
            let height = LinkPreviewLayout.availableHeight(forWidth: 572, in: bounds, anchor: anchor)
            for flipped in [true, false] {
                let frame = LinkPreviewLayout.cardFrame(size: NSSize(width: 572, height: height), in: bounds, anchor: anchor, flipped: flipped)
                #expect(bounds.insetBy(dx: 12, dy: 12).contains(frame))
                #expect(!frame.contains(anchor))
            }
        }
    }

}
