import AppKit
import PDFKit
import Testing
import Vision
import ZephyrCore
@testable import ZephyrRender

@MainActor
@Suite struct MarkdownExportTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recognizedText(in image: NSBitmapImageRep) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        let cgImage = try #require(image.cgImage)
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
    }

    private func contains(_ image: NSBitmapImageRep, color: NSColor) -> Bool {
        guard let expected = color.usingColorSpace(.deviceRGB) else { return false }
        return (0..<image.pixelsWide).contains { x in
            (0..<image.pixelsHigh).contains { y in
                guard let actual = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return abs(actual.redComponent - expected.redComponent) < 0.01 && abs(actual.greenComponent - expected.greenComponent) < 0.01 && abs(actual.blueComponent - expected.blueComponent) < 0.01
            }
        }
    }

    private func pixel(_ image: NSBitmapImageRep, x: Int, y: Int) throws -> [UInt8] {
        let cgImage = try #require(image.cgImage)
        let data = try #require(cgImage.dataProvider?.data) as Data
        let offset = y * cgImage.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 3)])
    }

    /// A one-node `F` diagram is centered in its card. Its top bar has more ink than its bottom;
    /// vertically flipping AppKit attributed-string output reverses that relation.
    private func diagramLabelIsUpright(in image: NSBitmapImageRep) -> Bool {
        let x = image.pixelsWide / 2
        guard let background = image.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return false }
        let counts = (0..<image.pixelsHigh).map { y in
            (max(0, x - 12)...min(image.pixelsWide - 1, x + 12)).reduce(0) { total, x in
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return total }
                let contrast = max(abs(color.redComponent - background.redComponent), abs(color.greenComponent - background.greenComponent), abs(color.blueComponent - background.blueComponent))
                return total + (contrast > 0.2 ? 1 : 0)
            }
        }
        var candidates: [(start: Int, end: Int)] = []
        var start: Int?
        for (y, count) in counts.enumerated() {
            if count >= 2, start == nil { start = y }
            if count < 2, let first = start {
                if y - first >= 8 { candidates.append((first, y)) }
                start = nil
            }
        }
        if let start, counts.count - start >= 8 { candidates.append((start, counts.count)) }
        guard let glyph = candidates.max(by: { lhs, rhs in
            counts[lhs.start..<lhs.end].reduce(0, +) < counts[rhs.start..<rhs.end].reduce(0, +)
        }) else { return false }
        let third = max(1, (glyph.end - glyph.start) / 3)
        let top = counts[glyph.start..<(glyph.start + third)].reduce(0, +)
        let bottom = counts[(glyph.end - third)..<glyph.end].reduce(0, +)
        return top > bottom
    }

    @Test func htmlIsSemanticAndEscapesUnsafeMarkup() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("note.html")
        let source = "# A **title**\n\n## Part\n\n### Key_name-2!\n\n[guide](guide%20name.md#part) [absolute](/tmp/guide%20name.md#part) [file](file:///tmp/file%20guide.md#section)\n\nSoft\nbreak  \nline\n\n<script>alert(1)</script>\n\n[unsafe](javascript:alert(1))\n\n![remote](//example.com/x.png)\n\n![local](assets/red%20image.png)\n\n<img src=\"assets/raw%20image.png\" alt=\"Sized &amp; photo\" width=\"320\" align=\"center\">\n\n<img src=\"//example.com/remote.png\" alt=\"Remote\">\n\n<img src=\" javascript:alert(1)\" alt=\"Unsafe\">\n\n3. Third\n\n- [x] Done\n\n| A | B |\n|---|---|\n| x | y |\n"
        try MarkdownExport.write(text: source, typography: Typography(), baseURL: folder, format: .html, output: output)
        let html = try String(contentsOf: output, encoding: .utf8)
        #expect(html.contains("<h1 id=\"a-title\">A <strong>title</strong></h1>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("href=\"javascript:"))
        #expect(!html.contains("<img src=\"//"))
        #expect(!html.contains("<img src=\" javascript:"))
        #expect(html.contains(folder.appendingPathComponent("assets/red image.png").absoluteString))
        #expect(html.contains("<h2 id=\"part\">Part</h2>"))
        #expect(html.contains("<h3 id=\"key_name-2\">Key_name-2!</h3>"))
        #expect(html.contains(folder.appendingPathComponent("guide name.md").absoluteString + "#part"))
        #expect(html.contains(URL(fileURLWithPath: "/tmp/guide name.md").absoluteString + "#part"))
        #expect(html.contains(URL(fileURLWithPath: "/tmp/file guide.md").absoluteString + "#section"))
        #expect(html.contains("<img src=\"" + folder.appendingPathComponent("assets/raw image.png").absoluteString + "\" alt=\"Sized &amp; photo\" width=\"320\" align=\"center\">"))
        #expect(html.contains("img{max-width:100%;height:auto;display:block;margin-left:auto;margin-right:auto}"))
        #expect(html.contains("img[align=\"left\"]{margin-left:0;margin-right:0}img[align=\"center\"]{margin-left:auto;margin-right:auto}"))
        #expect(html.contains("Soft\nbreak<br>"))
        #expect(html.contains("<ol start=\"3\">"))
        #expect(html.contains("checkbox\" disabled checked"))
        #expect(html.contains("<th>A</th><th>B</th>"))

        let plain = folder.appendingPathComponent("note.txt")
        try MarkdownExport.write(text: source, typography: Typography(), baseURL: folder, format: .txt, output: plain)
        let text = try String(contentsOf: plain, encoding: .utf8)
        #expect(text.contains("[x] Done"))
        #expect(text.contains("3. Third"))
        #expect(text.contains("A\tB"))
        #expect(text.contains("local"))
        #expect(text.contains("Sized & photo"))
        #expect(!text.contains("<img"))
    }

    @Test func pdfPaginatesRenderedContentAndRasterWaitsForLocalImage() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "# Export proof\n\n" + (1...60).map { "Paragraph \($0): **rendered** text.\n\n" }.joined()
        let pdf = folder.appendingPathComponent("proof.pdf")
        try MarkdownExport.write(text: text, typography: Typography(), baseURL: folder, format: .pdf, output: pdf)
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.pageCount > 1)
        #expect((document.string ?? "").contains("Paragraph 60"))
        #expect(!(document.string ?? "").contains("**rendered**"))

        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let imageURL = folder.appendingPathComponent("red.png")
        try image.tiffRepresentation!.write(to: imageURL)
        let png = folder.appendingPathComponent("image.png")
        try MarkdownExport.write(text: "![red](red.png)\n", typography: Typography(), baseURL: folder, format: .png, output: png)
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: png)))
        let hasRed = (0..<rep.pixelsWide).contains { x in
            (0..<rep.pixelsHigh).contains { y in
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2
            }
        }
        #expect(hasRed, "local images are decoded before raster output is captured")
    }

    @Test func rasterPagesUseExplicitNamesAndNeverOverwrite() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("pages.png")
        let text = (1...80).map { "Line \($0)\n\n" }.joined()
        let files = try MarkdownExport.write(text: text, typography: Typography(), baseURL: folder, format: .png, output: output)
        #expect(files.count > 1)
        #expect(files.first == output)
        #expect(files.dropFirst().allSatisfy { $0.lastPathComponent.hasPrefix("pages-") })
        #expect(throws: MarkdownExport.Error.self) {
            try MarkdownExport.write(text: text, typography: Typography(), baseURL: folder, format: .png, output: output)
        }
    }

    @Test func rasterKeepsHeadingAndDiagramTextUpright() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("geometry.png")
        let source = "# RASTER HEADING\n\nA paragraph before the diagram.\n\n```mermaid\nflowchart LR\n    A[START] --> B[FINISH]\n```\n"
        try MarkdownExport.write(text: source, typography: Typography(), baseURL: folder, format: .png, output: output)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        let text = try recognizedText(in: image).uppercased()
        #expect(text.contains("RASTER HEADING"), "the first heading is on raster page one, without clipping")
        #expect(text.contains("START") && text.contains("FINISH"), "diagram labels retain their upright raster orientation")
    }

    @Test func rasterDiagramLabelUsesFlippedAppKitContext() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("diagram-orientation.png")
        var settings = AppearanceState(active: "zephyr", themesFolder: FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-themes-\(UUID())").path).settings()
        try settings.set("appearance", "light")
        try MarkdownExport.write(text: "```mermaid\nflowchart LR\n    A[F]\n```\n", typography: Typography(settings), baseURL: folder, format: .png, output: output)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        #expect(diagramLabelIsUpright(in: image), "diagram NSAttributedString labels must keep their top-to-bottom glyph geometry")
    }

    @Test func sourceModeAndInputAliasesStayProtected() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let editor = MarkdownEditor(text: "---\ntitle: Proof\n---\n\n# Rendered\n", typography: Typography(), baseURL: folder, isEditable: false, canvas: .source)
        editor.frontMatterCollapsed = true
        let output = folder.appendingPathComponent("proof.pdf")
        try MarkdownExport.write(editor: editor, format: .pdf, output: output)
        #expect(editor.blockCanvas.mode == .source)
        #expect(editor.string.contains("title: Proof"))

        let source = folder.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let alias = folder.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: source.path)
        #expect(throws: MarkdownExport.Error.self) {
            try MarkdownExport.write(text: "replacement", typography: Typography(), baseURL: folder, format: .txt, output: alias, inputURL: source)
        }
    }

    @Test func derivedRasterCollisionNeedsExplicitApproval() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("pages.png")
        let derived = folder.appendingPathComponent("pages-2.png")
        try Data("existing".utf8).write(to: derived)
        let text = (1...80).map { "Line \($0)\n\n" }.joined()
        do {
            _ = try MarkdownExport.write(text: text, typography: Typography(), baseURL: folder, format: .png, output: output, approvedOutputs: [output])
            Issue.record("Expected derived collision")
        } catch let MarkdownExport.Error.outputsExist(urls) {
            #expect(urls == [derived])
        }
    }

    @Test func exportSettingsPersistInAnIsolatedDomainAndControlRasterSize() throws {
        let settingsURL = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let settings = MarkdownExport.Settings(format: .jpg, themeID: "anthology", paper: .a4, margin: 54, rasterWidth: 480, rasterScale: 1)
        try settings.save(to: settingsURL)
        #expect(try MarkdownExport.Settings.load(from: settingsURL) == settings)
        try Data("{\"format\":\"jpg\",\"paper\":\"a4\",\"margin\":145,\"rasterWidth\":480,\"rasterScale\":1}".utf8).write(to: settingsURL)
        #expect(throws: DecodingError.self) { try MarkdownExport.Settings.load(from: settingsURL) }

        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("sized.png")
        try MarkdownExport.write(text: "# Sized\n", typography: Typography(), baseURL: folder, format: .png, output: output, settings: settings)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        #expect(image.pixelsWide == 480)
    }

    @Test func htmlUsesTheConfiguredExportTheme() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("theme.html")
        let export = MarkdownExport.Settings(themeID: "anthology", textSize: nil)
        var appearance = AppearanceState(active: "anthology", themesFolder: FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-themes-\(UUID())").path)
        appearance.adjustments["anthology"] = ["appearance": .text("light")]
        let typography = try MarkdownExport.typography(for: export, appearance: appearance)
        try MarkdownExport.write(text: "# Theme\n", typography: typography, baseURL: folder, format: .html, output: output, settings: export)
        let html = try String(contentsOf: output, encoding: .utf8)
        #expect(html.contains("background:#FAF9F5"))
        #expect(html.contains("line-height:49.0pt"))
    }

    @Test func rasterUsesTheExportThemeWithoutChangingTheReaderPalette() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("theme.png")
        let export = MarkdownExport.Settings(themeID: "anthology", rasterWidth: 480, rasterScale: 1, textSize: nil)
        let typography = try MarkdownExport.typography(for: export, appearance: AppearanceState(active: "zephyr", themesFolder: FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-themes-\(UUID())").path))
        let before = Palette.resolved(.codeBackground, dark: false).hexString
        try MarkdownExport.write(text: "```swift\nlet themed = true\n```\n", typography: typography, baseURL: folder, format: .png, output: output, settings: export)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        let codeBackground = Palette.preview(typography.settings, .codeBackground, css: typography.css, dark: false)
        #expect(contains(image, color: codeBackground))
        #expect(Palette.resolved(.codeBackground, dark: false).hexString == before)
    }

    @Test func pinnedDarkThemeDrivesHTMLAndRasterWithoutChangingReaderAppearance() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var appearance = AppearanceState(active: "anthology", themesFolder: FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-themes-\(UUID())").path)
        appearance.adjustments["anthology"] = ["appearance": .text("dark")]
        let export = MarkdownExport.Settings(themeID: "anthology", rasterWidth: 480, rasterScale: 1, textSize: nil)
        let typography = try MarkdownExport.typography(for: export, appearance: appearance)
        let beforePalette = Palette.resolved(.codeBackground, dark: false).hexString
        let beforeAppearance = NSApplication.shared.appearance?.name

        let html = folder.appendingPathComponent("dark.html")
        try MarkdownExport.write(text: "# Dark\n", typography: typography, baseURL: folder, format: .html, output: html, settings: export)
        #expect(try String(contentsOf: html, encoding: .utf8).contains("background:#1F1E1D"))

        let png = folder.appendingPathComponent("dark.png")
        try MarkdownExport.write(text: "# Dark\n", typography: typography, baseURL: folder, format: .png, output: png, settings: export)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: png)))
        #expect(try pixel(image, x: 0, y: 0) == [0x1F, 0x1E, 0x1D])
        #expect(Palette.resolved(.codeBackground, dark: false).hexString == beforePalette)
        #expect(NSApplication.shared.appearance?.name == beforeAppearance)
    }

    @Test func shortDarkPDFPaintsItsPhysicalPage() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var appearance = AppearanceState(active: "anthology", themesFolder: FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-themes-\(UUID())").path)
        appearance.adjustments["anthology"] = ["appearance": .text("dark")]
        let export = MarkdownExport.Settings(themeID: "anthology", paper: .a4, margin: 36)
        let typography = try MarkdownExport.typography(for: export, appearance: appearance)
        let output = folder.appendingPathComponent("short-dark.pdf")
        try MarkdownExport.write(text: "# Dark\n", typography: typography, baseURL: folder, format: .pdf, output: output, settings: export)
        let document = try #require(PDFDocument(url: output))
        let page = try #require(document.page(at: 0))
        // Rasterize the PDF itself in sRGB, independent of PDFKit's display-oriented thumbnail.
        let size = page.bounds(for: .mediaBox).size
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.drawPDFPage(try #require(page.pageRef))
        let image = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let pageColor = try pixel(image, x: image.pixelsWide / 2, y: image.pixelsHigh - 10)
        #expect(pageColor == [0x1F, 0x1E, 0x1D])
    }

    @Test func exportTextSizeAndLineHeightReplaceTheThemes() throws {
        let theme = try MarkdownExport.typography(for: MarkdownExport.Settings(themeID: "zephyr", textSize: nil), appearance: AppearanceState(active: "zephyr", themesFolder: FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-themes-\(UUID())").path))
        let export = MarkdownExport.Settings(themeID: "zephyr", textSize: 12, lineHeight: 1.5)
        let typography = try MarkdownExport.typography(for: export, appearance: AppearanceState(active: "zephyr", themesFolder: FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-themes-\(UUID())").path))
        #expect(typography.settings.number("text.size") == 12 && typography.settings.number("text.lineHeight") == 1.5)
        #expect(typography.fontSize < theme.fontSize)
        // Headings keep their size relative to the text.
        #expect(abs(typography.headingSize(level: 1) / typography.fontSize - theme.headingSize(level: 1) / theme.fontSize) < 0.05)
        // Out of range values are clamped by the initializer and refused in a file; older files have neither.
        #expect(MarkdownExport.Settings(textSize: 99, lineHeight: 9).textSize == 28)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-text-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try export.save(to: url)
        #expect(try MarkdownExport.Settings.load(from: url) == export)
        try Data("{\"format\":\"pdf\",\"paper\":\"a4\",\"margin\":36,\"rasterWidth\":612,\"rasterScale\":2}".utf8).write(to: url)
        #expect(try MarkdownExport.Settings.load(from: url).textSize == nil)
        try Data("{\"format\":\"pdf\",\"paper\":\"a4\",\"margin\":36,\"rasterWidth\":612,\"rasterScale\":2,\"textSize\":4}".utf8).write(to: url)
        #expect(throws: DecodingError.self) { try MarkdownExport.Settings.load(from: url) }
    }

    @Test func exportTextSizeWinsOverTheThemesCSS() throws {
        var appearance = AppearanceState(active: "zephyr", themesFolder: FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-export-themes-\(UUID())").path)
        appearance.adjustments["zephyr"] = ["css": .text("body { font-size: 20pt; line-height: 2; }")]
        let theme = try MarkdownExport.typography(for: MarkdownExport.Settings(textSize: nil), appearance: appearance)
        #expect(theme.fontSize == 20)
        #expect(MarkdownExport.Settings().textSize == 11, "a new export starts at a printed page's size")
        let export = try MarkdownExport.typography(for: MarkdownExport.Settings(textSize: 12, lineHeight: 1.5), appearance: appearance)
        #expect(export.fontSize == 12 && export.lineSpacing == 1.5)
    }

    @Test func htmlExportKeepsContainersWithFormulasAsSource() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("math.html")
        try MarkdownExport.write(text: "<div align=\"center\">\n\nMass $m$\n\n</div>\n", typography: Typography(), baseURL: folder, format: .html, output: output)
        let html = try String(contentsOf: output, encoding: .utf8)
        #expect(!html.contains("<div align=\"center\">") && html.contains("&lt;div"))
    }

    @Test func imageExportsKeepTheMarginAroundThePage() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("margins.png")
        let settings = MarkdownExport.Settings(format: .png, margin: 36, rasterWidth: 480, rasterScale: 1)
        let text = "# Margins\n\n" + String(repeating: "Words that fill the column to its edge. ", count: 30) + "\n"
        try MarkdownExport.write(text: text, typography: Typography(), baseURL: folder, format: .png, output: output, settings: settings)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        #expect(image.pixelsWide == 480)
        let page = try pixel(image, x: 0, y: 0)
        // Only the page's color within 33 pt of every edge (the margin is 36 pt)…
        for y in stride(from: 0, to: image.pixelsHigh, by: 5) {
            for x in [0, 16, 32, 447, 463, 479] { #expect(try pixel(image, x: x, y: y) == page, "x \(x), y \(y)") }
        }
        for x in stride(from: 0, to: image.pixelsWide, by: 5) {
            for y in [0, 16, 32, image.pixelsHigh - 33, image.pixelsHigh - 1] { #expect(try pixel(image, x: x, y: y) == page, "x \(x), y \(y)") }
        }
        // …and the text inside it, reaching close to both sides of the column.
        var inked: [Int] = []
        for x in 33..<447 where (0..<image.pixelsHigh).contains(where: { (try? pixel(image, x: x, y: $0)) != page }) { inked.append(x) }
        #expect((inked.min() ?? 999) < 40 && (inked.max() ?? 0) > 420)
    }
}
