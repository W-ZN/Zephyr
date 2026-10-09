import AppKit
import Foundation
import Testing
@testable import ZephyrRender
import ZephyrCore

/// Zephyr's own HTML layout (design §9): a README header's badges set in a centered row, images
/// sized by their attributes, rows that wrap inside the column, links that can be hit, static
/// badges drawn without a request, and inline images in a line of text.
@MainActor
@Suite struct HTMLLayoutTests {
    nonisolated static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../fixtures").standardizedFileURL

    func open(_ text: String, width: CGFloat = 900, baseURL: URL? = HTMLLayoutTests.fixtures) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: baseURL, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: 0), size: NSSize(width: width, height: 1600)), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        editor.layoutAll()
        draw(editor)
        return (editor, window)
    }

    /// Draws the visible canvas (offscreen windows do not), so components know where they are.
    func draw(_ editor: MarkdownEditor) {
        let view = editor.focusView
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) { view.cacheDisplay(in: view.visibleRect, to: rep) }
    }

    func box<T: ComponentBox>(_ editor: MarkdownEditor, _ type: T.Type) -> T? {
        let canvas = editor.blockCanvas
        for i in 0..<canvas.units.count {
            if let box = canvas.layout(i).content.component as? T { return box }
        }
        return nil
    }

    static let header = """
    <p align="center">
      <a href="https://github.com/W-ZN/Zephyr/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/W-ZN/Zephyr?include_prereleases&color=0f4a55"></a>
      <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-0f4a55">
      <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138">
      <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue"></a>
    </p>

    After.
    """

    @Test func readmeBadgesSitInOneCenteredRow() throws {
        let (editor, _) = open(Self.header)
        let html = try #require(box(editor, HTMLBox.self))
        let column = html.drawnRect
        #expect(column.width > 500)
        #expect(html.placed.count == 4)
        let rects = html.placed.map(\.rect)
        // One row, in source order, a space apart, centered in the column.
        #expect(Set(rects.map { $0.midY.rounded() }).count == 1)
        #expect(zip(rects, rects.dropFirst()).allSatisfy { $0.maxX < $1.minX })
        let left = rects[0].minX - column.minX, right = column.maxX - rects[3].maxX
        #expect(abs(left - right) <= 2)
        // Static badges are drawn by Zephyr at shields.io's height; the release badge is remote.
        #expect(rects[1].height == 20 && rects[2].height == 20 && rects[3].height == 20)
        guard case .remote = html.placed[0].image.origin else { Issue.record("release badge should be remote"); return }
        guard case .badge = html.placed[1].image.origin else { Issue.record("static badge should be drawn"); return }
        // Links cover their images; the text after the block is untouched.
        #expect(html.link(at: NSPoint(x: rects[3].midX, y: rects[3].midY)) == "LICENSE")
        #expect(html.link(at: NSPoint(x: rects[0].midX, y: rects[0].midY)) == "https://github.com/W-ZN/Zephyr/releases/latest")
        #expect(html.link(at: NSPoint(x: rects[1].midX, y: rects[1].midY)) == nil)
        #expect(editor.link(at: NSPoint(x: rects[3].midX, y: rects[3].midY)) == "LICENSE")
    }

    @Test func percentWidthsShareARowAndRowsWrapInsideTheColumn() throws {
        let side = "<p align=\"center\">\n  <img src=\"images/pipeline.png\" width=\"49%\">\n  <img src=\"images/pipeline.png\" width=\"49%\">\n</p>\n"
        let (editor, _) = open(side)
        let html = try #require(box(editor, HTMLBox.self))
        let rects = html.placed.map(\.rect)
        #expect(rects.count == 2)
        #expect(abs(rects[0].width - (html.drawnRect.width * 0.49).rounded()) <= 1)
        #expect(rects[0].minY == rects[1].minY)
        #expect(rects[1].maxX <= html.drawnRect.maxX + 0.5)

        let many = "<p>" + String(repeating: "<img src=\"https://img.shields.io/badge/a%20long%20label-message-blue\"> ", count: 12) + "</p>\n"
        let (narrow, _) = open(many, width: 520)
        let row = try #require(box(narrow, HTMLBox.self))
        let tops = Set(row.placed.map { $0.rect.minY })
        #expect(tops.count > 1)
        #expect(row.placed.allSatisfy { $0.rect.maxX <= row.drawnRect.maxX + 0.5 && $0.rect.minX >= row.drawnRect.minX - 0.5 })
    }

    @Test func headingsTextAndBreaksLayOutAsBlocks() throws {
        let (editor, _) = open("<h1 align=\"center\">Zephyr</h1>\n<p>One line<br>Two <kbd>⌘</kbd> <sup>3</sup></p>\n")
        let html = try #require(box(editor, HTMLBox.self))
        let layout = html.layout(width: html.drawnRect.width)
        #expect(layout.lines.count == 3)
        // The heading is centered; the paragraph starts at the left edge.
        let heading = layout.lines[0]
        let headingWidth = CGFloat(CTLineGetTypographicBounds(heading.line, nil, nil, nil))
        #expect(abs(heading.origin.x - (html.drawnRect.width - headingWidth) / 2) <= 1)
        #expect(layout.lines[1].origin.x == 0 && layout.lines[2].origin.x == 0)
        #expect(layout.lines[1].origin.y < layout.lines[2].origin.y)
        // The keycap gets an outlined box.
        #expect(layout.marks.contains { if case .box(_, _, .some) = $0 { true } else { false } })
    }

    @Test func revealedSourceIsEditable() throws {
        let (editor, _) = open(Self.header)
        let html = try #require(box(editor, HTMLBox.self))
        let range = html.lastKnownRange
        #expect(range.location == 0)
        editor.blockCanvas.select(NSRange(location: 3, length: 0))
        draw(editor)
        // The caret inside shows the HTML as text.
        #expect(editor.blockCanvas.place(3).layout.content.component == nil)
    }

    @Test func inlineImagesSitInTheLine() throws {
        let (editor, _) = open("Built with ![Swift](https://img.shields.io/badge/Swift-6-F05138) and [![chip](https://img.shields.io/badge/a-b-blue)](https://example.com) today.\n")
        let layout = editor.blockCanvas.place(0).layout
        let shown = layout.content.string.string
        #expect(shown.filter { $0 == "\u{FFFC}" }.count == 2)
        #expect(shown.hasPrefix("Built with ") && shown.hasSuffix(" today."))
        let box = try #require(editor.componentBox(at: 11) as? InlineImageBox)
        #expect(box.size == CGSize(width: BadgeRenderer.size(Badge(label: "Swift", message: "6", color: 0xF05138)).width, height: 20))
        // The badge in a link carries the link.
        let source = editor.string as NSString
        let chip = source.range(of: "![chip]").location
        #expect(editor.linkDestination(at: chip) == "https://example.com")
    }

    @Test func aClickOnAWaitingRemoteImageAllowsTheDocumentsImages() throws {
        let (editor, window) = open(Self.header)
        editor.remoteImagesPreferred = false
        draw(editor)
        let html = try #require(box(editor, HTMLBox.self))
        let release = html.placed[0].rect
        #expect(html.blockedImage(at: NSPoint(x: release.midX, y: release.midY)))
        #expect(!html.blockedImage(at: NSPoint(x: html.placed[1].rect.midX, y: html.placed[1].rect.midY)))
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!editor.loadsRemoteImages)
        #expect(editor.handleClick(at: NSPoint(x: release.midX, y: release.midY), event: event))
        #expect(editor.loadsRemoteImages)
        draw(editor)
        #expect(!html.blockedImage(at: NSPoint(x: release.midX, y: release.midY)))
    }

    @Test func badgesDrawTheirParts() {
        let badge = Badge(label: "macOS", message: "15+", color: 0x0F4A55)
        let size = BadgeRenderer.size(badge)
        // shields.io: Verdana 11 text plus 5 pt on each side of each part.
        #expect(size.height == 20)
        #expect(size.width > 70 && size.width < 100)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        BadgeRenderer.draw(badge, in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        // Left part grey, right part the badge color (sampled away from the text).
        let left = rep.colorAt(x: 2, y: 20)!.usingColorSpace(.sRGB)!
        let right = rep.colorAt(x: Int(size.width) * 2 - 3, y: 20)!.usingColorSpace(.sRGB)!
        #expect(abs(left.redComponent - left.blueComponent) < 0.05 && left.redComponent > 0.25 && left.redComponent < 0.4)
        #expect(right.blueComponent > right.redComponent + 0.1)
    }

    @Test func alignedContainerIsOneBlockWithoutEmptyLines() throws {
        let text = "Intro.\n\n<div align=\"center\">\n\n# Zephyr\n\n[![CI](https://img.shields.io/badge/ci-passing-brightgreen)](https://ci)\n\n</div>\n\nAfter.\n"
        let (editor, _) = open(text)
        let html = try #require(box(editor, HTMLBox.self))
        let canvas = editor.blockCanvas
        let ns = text as NSString
        let first = canvas.place(ns.range(of: "<div").location).unit
        let last = canvas.place(ns.range(of: "</div>").location).unit
        // The first line draws the block; every other line of the container, blank or not, has no height.
        #expect(canvas.layout(first).content.component === html)
        for unit in (first + 1)...last { #expect(canvas.layout(unit).height == 0, "unit \(unit)") }
        let layout = html.layout(width: html.drawnRect.width)
        #expect(layout.lines.count == 2)
        #expect(html.placed.count == 1 && abs(html.placed[0].rect.midX - html.drawnRect.midX) <= 1)
    }

    // MARK: Review regressions (round 44)

    @Test func hugeImageSizesStayBounded() throws {
        #expect(ImageCache.pixels(for: CGSize(width: 1, height: 1e20)) == ImageCache.thumbnailMaxPixels)
        #expect(ImageCache.pixels(for: CGSize(width: CGFloat.infinity, height: 1)) == ImageCache.thumbnailMaxPixels)
        #expect(ImageCache.pixels(for: CGSize(width: 100, height: 50)) == 256)
        let (editor, _) = open("<p><img src=\"images/pipeline.png\" width=\"1\" height=\"1e20\"></p>\n\nText <img src=\"images/pipeline.png\" height=\"1e20\"> end.\n")
        let html = try #require(box(editor, HTMLBox.self))
        #expect(html.placed.first.map { $0.rect.height <= ImageCache.maximumSide } == true)
        let inline = try #require(editor.componentBox(at: (editor.string as NSString).range(of: "<img src=\"images/pipeline.png\" height").location) as? InlineImageBox)
        #expect(inline.size.height <= ImageCache.maximumSide)
    }

    @Test func wideInlineImagesFitANarrowColumn() throws {
        let (editor, _) = open("Text ![wide](images/pipeline.png) end.\n", width: 360)
        let canvas = editor.blockCanvas
        let layout = canvas.place(0).layout
        let column = canvas.columnWidth
        // Trailing spaces hang past the edge, as in any line.
        for line in layout.lines { #expect(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)) <= column + 1) }
        let box = try #require(editor.componentBox(at: 5) as? InlineImageBox)
        #expect(box.drawnRect.width <= column + 1 && box.drawnRect.width > column / 2)
    }

    @Test func htmlExportKeepsAlignedContainers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-container-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("readme.html")
        try MarkdownExport.write(text: "<div align=\"center\">\n\n# Zephyr\n\nPress <kbd>K</kbd>.\n\n</div>\n", typography: Typography(), baseURL: folder, format: .html, output: output)
        let html = try String(contentsOf: output, encoding: .utf8)
        #expect(html.contains("<div align=\"center\"><h1>Zephyr</h1>"))
        #expect(html.contains("<kbd>K</kbd>"))
        #expect(!html.contains("&lt;div"))
    }

    @Test func fencedCodeTakesTheThemesSyntaxColors() throws {
        let text = "```json\n{\"name\": \"Zephyr\", \"open\": true}\n```\n\n```\n{\"plain\": 1}\n```\n"
        let (editor, _) = open(text)
        let source = text as NSString
        func color(_ needle: String) -> NSColor? {
            editor.blockCanvas.presenter?.attribute(.foregroundColor, at: source.range(of: needle).location) as? NSColor
        }
        #expect(color("\"name\"") == Palette.syntax(.property))
        #expect(color("\"Zephyr\"") == Palette.syntax(.string))
        #expect(color("true") == Palette.syntax(.number))
        // A fence without a language stays the text's color.
        #expect(color("\"plain\"") != Palette.syntax(.property))
        var settings = AppearanceSettings()
        try settings.set("code.syntax", value: .flag(false))
        let (plain, _) = open(text)
        plain.apply(typography: Typography(settings))
        #expect(plain.blockCanvas.presenter?.attribute(.foregroundColor, at: source.range(of: "\"name\"").location) as? NSColor != Palette.syntax(.property))
    }

    @Test func sizesStayFiniteAndInProportion() throws {
        #expect(ImageCache.capped(CGSize(width: 10, height: 50_000)) == CGSize(width: 4, height: 20_000))
        #expect(ImageCache.capped(CGSize(width: 300, height: 200)) == CGSize(width: 300, height: 200))
        let (editor, _) = open("<p><img src=\"images/pipeline.png\" width=\"1e308%\"></p>\n")
        let html = try #require(box(editor, HTMLBox.self))
        let rect = try #require(html.placed.first?.rect)
        #expect(rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0)
    }
}
