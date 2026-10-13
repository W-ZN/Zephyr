import AppKit
import ZephyrCore
import Markdown
import UniformTypeIdentifiers

@MainActor
public enum MarkdownExport {
    public enum Format: String, CaseIterable, Sendable, Codable {
        case pdf, html, png, jpg, txt
        public var fileExtension: String { rawValue }
        public var contentType: UTType {
            switch self {
            case .pdf: .pdf
            case .html: UTType(filenameExtension: "html")!
            case .png: .png
            case .jpg: .jpeg
            case .txt: .plainText
            }
        }
        public var displayName: String {
            switch self {
            case .pdf: String(localized: "PDF")
            case .html: String(localized: "HTML")
            case .png: String(localized: "PNG Image")
            case .jpg: String(localized: "JPEG Image")
            case .txt: String(localized: "Plain Text")
            }
        }
    }

    public enum Error: LocalizedError {
        case sourceAndOutputMatch, outputExists(URL), outputsExist([URL]), printFailed, rasterLimit, themeNotFound(String)
        public var errorDescription: String? {
            switch self {
            case .sourceAndOutputMatch: String(localized: "Export must use a different file from the Markdown source.")
            case let .outputExists(url): String(localized: "Export will not overwrite an existing file: \(url.lastPathComponent)")
            case let .outputsExist(urls): String(localized: "Export will not overwrite existing files: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
            case .printFailed: String(localized: "Zephyr could not create the PDF.")
            case .rasterLimit: String(localized: "This raster export exceeds Zephyr's 100-page or 100-megapixel limit.")
            case let .themeNotFound(name): String(localized: "The export theme \(name) is no longer available.")
            }
        }
    }

    /// Export choices live outside a document and use the app's shared preference domain so the
    /// GUI and bundled command-line tool make the same output by default.
    public struct Settings: Equatable, Sendable, Codable {
        public enum Paper: String, CaseIterable, Sendable, Codable {
            case letter, a4

            public var size: NSSize {
                switch self {
                case .letter: NSSize(width: 612, height: 792)
                case .a4: NSSize(width: 595, height: 842)
                }
            }
        }

        public var format: Format
        /// nil follows the currently selected reader theme; a value is a stable theme ID or name.
        public var themeID: String?
        public var paper: Paper
        public var margin: CGFloat
        /// Raster page width in points before multiplying by `rasterScale`.
        public var rasterWidth: CGFloat
        public var rasterScale: CGFloat
        /// Text size in points for exports; nil follows the theme. Headings, code and tables keep
        /// their sizes relative to it.
        public var textSize: CGFloat?
        /// Line height as a multiple of the text size; nil follows the theme.
        public var lineHeight: CGFloat?

        public static let textSizes: ClosedRange<CGFloat> = 11...28
        public static let lineHeights: ClosedRange<CGFloat> = 1.2...2.4
        /// Body text for a printed page: the reading themes' 16–18 pt is screen size, large on A4
        /// or Letter; 11 pt is the usual document size for both Latin and CJK text.
        public static let defaultTextSize: CGFloat = 11

        /// Letter where it is the standard paper (the US and Canada), A4 elsewhere.
        public static var regionalPaper: Paper {
            ["US", "CA"].contains(Locale.current.region?.identifier ?? "") ? .letter : .a4
        }

        public init(format: Format = .pdf, themeID: String? = nil, paper: Paper = Settings.regionalPaper, margin: CGFloat = 36, rasterWidth: CGFloat = 612, rasterScale: CGFloat = 2, textSize: CGFloat? = Settings.defaultTextSize, lineHeight: CGFloat? = nil) {
            self.format = format
            self.themeID = themeID?.isEmpty == false ? themeID : nil
            self.paper = paper
            self.margin = min(max(margin, 0), 144)
            self.rasterWidth = min(max(rasterWidth, 320), 1440)
            self.rasterScale = min(max(rasterScale.rounded(), 1), 3)
            self.textSize = textSize.map { min(max($0.rounded(), Self.textSizes.lowerBound), Self.textSizes.upperBound) }
            self.lineHeight = lineHeight.map { min(max(($0 * 20).rounded() / 20, Self.lineHeights.lowerBound), Self.lineHeights.upperBound) }
        }

        public var rasterPaperSize: NSSize {
            let paperSize = paper.size
            return NSSize(width: rasterWidth, height: rasterWidth * paperSize.height / paperSize.width)
        }

        public static var fileURL: URL { AppearanceState.fileURL.deletingLastPathComponent().appendingPathComponent("export.json") }

        public static func load(from url: URL = fileURL) throws -> Settings {
            guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
            return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        }

        public func save(to url: URL = fileURL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let format = try values.decode(Format.self, forKey: .format)
            let themeID = try values.decodeIfPresent(String.self, forKey: .themeID)
            let paper = try values.decode(Paper.self, forKey: .paper)
            let margin = try values.decode(CGFloat.self, forKey: .margin)
            let rasterWidth = try values.decode(CGFloat.self, forKey: .rasterWidth)
            let rasterScale = try values.decode(CGFloat.self, forKey: .rasterScale)
            // Added later: files written before have neither, and follow the theme.
            let textSize = try values.decodeIfPresent(CGFloat.self, forKey: .textSize)
            let lineHeight = try values.decodeIfPresent(CGFloat.self, forKey: .lineHeight)
            guard (0...144).contains(margin), (320...1440).contains(rasterWidth), [1, 2, 3].contains(rasterScale),
                  textSize.map(Self.textSizes.contains) ?? true, lineHeight.map(Self.lineHeights.contains) ?? true else {
                throw DecodingError.dataCorruptedError(forKey: .margin, in: values, debugDescription: "Export settings contain a value outside its supported range.")
            }
            self.format = format
            self.themeID = themeID?.isEmpty == false ? themeID : nil
            self.paper = paper
            self.margin = margin
            self.rasterWidth = rasterWidth
            self.rasterScale = rasterScale
            self.textSize = textSize
            self.lineHeight = lineHeight
        }
    }

    private static let rasterPageLimit = 100, rasterPixelLimit = 100_000_000

    @discardableResult
    public static func write(text: String, typography: Typography, baseURL: URL?, format: Format, output: URL, inputURL: URL? = nil, frontMatterCollapsed: Bool = false, settings: Settings = Settings(), overwrite: Bool = false, approvedOutputs: Set<URL> = []) throws -> [URL] {
        let editor = MarkdownEditor(text: text, typography: typography, baseURL: baseURL, isEditable: false, canvas: .block)
        editor.frontMatterCollapsed = frontMatterCollapsed
        return try write(editor: editor, format: format, output: output, inputURL: inputURL, settings: settings, overwrite: overwrite, approvedOutputs: approvedOutputs)
    }

    /// Visual formats always use a rendered snapshot. `NSDocument` printing keeps its current mode.
    @discardableResult
    public static func write(editor: MarkdownEditor, format: Format, output: URL, inputURL: URL? = nil, settings: Settings = Settings(), overwrite: Bool = false, approvedOutputs: Set<URL> = []) throws -> [URL] {
        let output = canonical(output), input = inputURL.map { canonical($0) }
        let approved = Set(approvedOutputs.map(canonical))
        if format == .pdf || format == .png || format == .jpg {
            return try Palette.withConfiguration(editor.typography.settings, css: editor.typography.css) {
                try writeConfigured(editor: editor, format: format, output: output, input: input, settings: settings, overwrite: overwrite, approved: approved)
            }
        }
        return try writeConfigured(editor: editor, format: format, output: output, input: input, settings: settings, overwrite: overwrite, approved: approved)
    }

    private static func writeConfigured(editor: MarkdownEditor, format: Format, output: URL, input: URL?, settings: Settings, overwrite: Bool, approved: Set<URL>) throws -> [URL] {
        if input == output { throw Error.sourceAndOutputMatch }
        switch format {
        case .html:
            try writeSingle(output: output, input: input, overwrite: overwrite, approved: approved) { try HTML.render(editor.string, baseURL: editor.baseURL, typography: editor.typography, dark: outputAppearance(for: editor.typography.settings).isDark).data(using: .utf8)!.write(to: $0) }
            return [output]
        case .txt:
            try writeSingle(output: output, input: input, overwrite: overwrite, approved: approved) { try HTML.plainText(editor.string).data(using: .utf8)!.write(to: $0) }
            return [output]
        case .pdf:
            let snapshot = outputSheet(editor)
            try writeSingle(output: output, input: input, overwrite: overwrite, approved: approved) { staged in
                let info = NSPrintInfo()
                info.isVerticallyCentered = false
                info.paperSize = settings.paper.size
                info.topMargin = settings.margin
                info.bottomMargin = settings.margin
                info.leftMargin = settings.margin
                info.rightMargin = settings.margin
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = staged
                let operation = NSPrintOperation(view: snapshot, printInfo: info)
                operation.showsPrintPanel = false
                operation.showsProgressPanel = false
                guard operation.run() else { throw Error.printFailed }
            }
            return [output]
        case .png, .jpg:
            let sheet = outputSheet(editor)
            let paper = settings.rasterPaperSize
            // The margin surrounds each image as it does a PDF page; the column is what remains
            // (at least 240 pt of it on the narrowest page).
            let margin = min(settings.margin, max(0, (paper.width - 240) / 2))
            sheet.paginate(size: NSSize(width: paper.width - margin * 2, height: paper.height - margin * 2))
            let pixels = Int(paper.width * settings.rasterScale) * Int(paper.height * settings.rasterScale) * sheet.pages.count
            guard sheet.pages.count <= rasterPageLimit, pixels <= rasterPixelLimit else { throw Error.rasterLimit }
            let targets = rasterTargets(for: output, pages: sheet.pages.count)
            try validate(targets: targets, input: input, overwrite: overwrite, approved: approved)
            let folder = try stagingFolder(for: output)
            defer { try? FileManager.default.removeItem(at: folder) }
            let staged = rasterTargets(for: folder.appendingPathComponent(output.lastPathComponent), pages: sheet.pages.count)
            let type: NSBitmapImageRep.FileType = format == .png ? .png : .jpeg
            for (page, url) in zip(sheet.pages, staged) { try render(sheet, page: page, margin: margin, scale: settings.rasterScale).representation(using: type, properties: [:])!.write(to: url) }
            try commit(zip(staged, targets).map { ($0.0, $0.1) }, in: folder, overwrite: overwrite, approved: approved)
            return targets
        }
    }

    public static func typography(for export: Settings, appearance: AppearanceState) throws -> Typography {
        let theme = export.themeID ?? appearance.active
        var selected = appearance
        if let preset = ThemeLibrary.preset(theme) {
            selected.active = preset.id
        } else {
            guard ThemeLibrary.names(in: selected.folder).contains(theme) else { throw Error.themeNotFound(theme) }
            selected.active = theme
        }
        var settings = selected.settings()
        // The export's own text size and line height replace the theme's; the rest scales with them.
        if let size = export.textSize { try settings.set("text.size", value: .number(Double(size))) }
        if let height = export.lineHeight { try settings.set("text.lineHeight", value: .number(Double(height))) }
        // …and over the theme's custom CSS, which would otherwise set them again.
        var css = CustomStyle.parse(settings.string("css"), baseSize: settings.number("text.size") ?? 16).style
        if export.textSize != nil { css.typography["text.size"] = nil }
        if export.lineHeight != nil { css.typography["text.lineHeight"] = nil }
        return Typography(settings, css: css)
    }

    private static func renderedSnapshot(of editor: MarkdownEditor) -> MarkdownEditor {
        let snapshot = MarkdownEditor(text: editor.string, typography: editor.typography, baseURL: editor.baseURL, isEditable: false, canvas: .block)
        snapshot.frontMatterCollapsed = editor.frontMatterCollapsed
        return snapshot
    }

    private static func outputSheet(_ editor: MarkdownEditor) -> PrintSheet {
        let sheet = PrintSheet(renderedSnapshot(of: editor))
        let appearance = outputAppearance(for: editor.typography.settings)
        let background = Palette.preview(editor.typography.settings, .background, css: editor.typography.css, dark: appearance.isDark)
        sheet.appearance = appearance
        sheet.editor.blockCanvas.view.appearance = appearance
        sheet.pageBackground = background
        sheet.editor.blockCanvas.printBackground = background
        sheet.editor.apply(typography: editor.typography)
        return sheet
    }

    private static func outputAppearance(for settings: AppearanceSettings) -> NSAppearance {
        switch settings.string("appearance") {
        case "dark": NSAppearance(named: .darkAqua)!
        case "light": NSAppearance(named: .aqua)!
        default: NSApplication.shared.effectiveAppearance
        }
    }

    private static func writeSingle(output: URL, input: URL?, overwrite: Bool, approved: Set<URL>, _ write: (URL) throws -> Void) throws {
        try validate(targets: [output], input: input, overwrite: overwrite, approved: approved)
        let folder = try stagingFolder(for: output)
        defer { try? FileManager.default.removeItem(at: folder) }
        let staged = folder.appendingPathComponent(output.lastPathComponent)
        try write(staged)
        try commit([(staged, output)], in: folder, overwrite: overwrite, approved: approved)
    }

    private static func validate(targets: [URL], input: URL?, overwrite: Bool, approved: Set<URL>) throws {
        for target in targets {
            if canonical(target) == input { throw Error.sourceAndOutputMatch }
        }
        let collisions = targets.filter { FileManager.default.fileExists(atPath: $0.path) && !overwrite && !approved.contains(canonical($0)) }
        if !collisions.isEmpty { throw Error.outputsExist(collisions) }
    }

    private static func stagingFolder(for output: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: output.deletingLastPathComponent(), create: true)
    }

    /// Commits fully rendered staged files; failures restore prior outputs and remove new ones.
    private static func commit(_ pairs: [(URL, URL)], in folder: URL, overwrite: Bool, approved: Set<URL>) throws {
        let manager = FileManager.default
        var completed: [(URL, URL?)] = []
        do {
            for (index, pair) in pairs.enumerated() {
                let (staged, target) = pair
                if manager.fileExists(atPath: target.path) {
                    guard overwrite || approved.contains(canonical(target)) else { throw Error.outputExists(target) }
                    let backup = folder.appendingPathComponent("backup-\(index)")
                    try manager.copyItem(at: target, to: backup)
                    _ = try manager.replaceItemAt(target, withItemAt: staged, backupItemName: nil, options: [])
                    completed.append((target, backup))
                } else {
                    try manager.moveItem(at: staged, to: target)
                    completed.append((target, nil))
                }
            }
        } catch {
            for (target, backup) in completed.reversed() {
                if let backup { try? manager.removeItem(at: target); try? manager.moveItem(at: backup, to: target) }
                else { try? manager.removeItem(at: target) }
            }
            throw error
        }
    }

    private static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    private static func rasterTargets(for output: URL, pages: Int) -> [URL] {
        guard pages > 1 else { return [output] }
        let folder = output.deletingLastPathComponent(), name = output.deletingPathExtension().lastPathComponent, ext = output.pathExtension
        return (1...pages).map { folder.appendingPathComponent(name + ($0 == 1 ? "" : "-\($0)")).appendingPathExtension(ext) }
    }

    private static func render(_ sheet: PrintSheet, page: NSRect, margin: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
        let size = NSSize(width: page.width + margin * 2, height: page.height + margin * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)), pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(bitmapImageRep: rep)!
        let context = graphics.cgContext
        // The margin in the page's color, like the paper around a PDF page.
        context.setFillColor(sheet.pageBackground.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        // `NSBitmapImageRep.size` already maps its 2× pixels to page points. Scaling the
        // context again magnifies and clips the document instead of increasing resolution.
        context.translateBy(x: margin, y: size.height - margin)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -page.minY)
        context.clip(to: page)
        // `PrintSheet` is a flipped view. Core Text sets its own text matrix, but AppKit's
        // attributed-string drawing (used by diagram labels) consults this context flag.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        sheet.draw(page)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

private enum HTML {
    static func render(_ source: String, baseURL: URL?, typography: Typography, dark: Bool) -> String {
        let document = Document(parsing: MarkdownAnalyzer.rewritingLooseEmphasis(source), options: [.disableSmartOpts])
        let style = stylesheet(typography, dark: dark)
        return "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>Zephyr export</title><style>\(style)</style></head><body>\n" + children(document, baseURL: baseURL) + "</body></html>\n"
    }

    private static func stylesheet(_ typography: Typography, dark: Bool) -> String {
        let settings = typography.settings
        func color(_ role: Palette.Role) -> String { Palette.preview(settings, role, css: typography.css, dark: dark).hexString }
        func headingColor(_ level: Int) -> String {
            let custom = dark ? typography.css.headings[level]?.color.dark : typography.css.headings[level]?.color.light
            return (custom ?? Palette.preview(settings, level == 6 ? .muted : .heading, css: typography.css, dark: dark)).hexString
        }
        func font(_ value: NSFont) -> String {
            let family = (value.familyName ?? value.fontName).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            return "'\(family)'"
        }
        let headings = (1...6).map { level in
            let heading = typography.headingFont(level: level)
            return "h\(level){font-family:\(font(heading));font-size:\(Int(heading.pointSize.rounded()))pt;line-height:\(typography.lineHeight(for: heading, kind: .heading))pt;color:\(headingColor(level))}"
        }.joined()
        let imageAlignment = typography.imageAlignment == .center ? "display:block;margin-left:auto;margin-right:auto" : "display:block;margin-left:0;margin-right:0"
        return "body{max-width:\(Int(typography.readableWidth.rounded()))pt;margin:3rem auto;padding:0 1.25rem;font:\(typography.fontSize)pt/\(typography.lineSpacing) \(font(typography.bodyFont));color:\(color(.text));background:\(color(.background))}a{color:\(color(.link))}\(headings)img{max-width:100%;height:auto;\(imageAlignment)}img[align=\"left\"]{margin-left:0;margin-right:0}img[align=\"center\"]{margin-left:auto;margin-right:auto}table{border-collapse:collapse}th,td{border:1px solid \(color(.tableBorder));padding:\(typography.tablePadding)pt;text-align:left}th{background:\(color(.tableHeader))}code{font-family:\(font(typography.codeFont));background:\(color(.inlineCodeBackground));padding:.1em .25em;border-radius:3px}pre{padding:.8rem;overflow:auto;background:\(color(.codeBackground));border:1px solid \(color(.codeBorder))}blockquote{border-left:3px solid \(color(.quote));padding-left:1em;color:\(color(.muted))}"
    }

    static func plainText(_ source: String) -> String { text(Document(parsing: MarkdownAnalyzer.rewritingLooseEmphasis(source), options: [.disableSmartOpts])).trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
    /// Children in order; an aligned container (`<div align="center">` … `</div>`) exports as the
    /// one element the editor draws.
    private static func children(_ markup: Markup, baseURL: URL?) -> String {
        let nodes = Array(markup.children)
        var out = "", i = 0
        while i < nodes.count {
            if let (element, close) = HTMLContainer.container(in: nodes, at: i) {
                out += sanitized(HTMLFragment(nodes: [.element(element)]), baseURL: baseURL)
                i = close + 1
            } else {
                out += render(nodes[i], baseURL: baseURL)
                i += 1
            }
        }
        return out
    }

    private static func sanitized(_ fragment: HTMLFragment, baseURL: URL?) -> String {
        fragment.serialized { attribute, value in
            attribute == "href" ? safeLink(value, baseURL: baseURL) : safeImage(attribute == "srcset" ? String(value.split(separator: " ").first ?? "") : value, baseURL: baseURL)
        } + "\n"
    }
    private static func render(_ markup: Markup, baseURL: URL?) -> String {
        switch markup {
        case let node as Paragraph: return "<p>\(children(node, baseURL: baseURL))</p>\n"
        case let node as Heading: return "<h\(node.level) id=\"\(attribute(headingID(node)))\">\(children(node, baseURL: baseURL))</h\(node.level)>\n"
        case let node as BlockQuote: return "<blockquote>\(children(node, baseURL: baseURL))</blockquote>\n"
        case let node as UnorderedList: return "<ul>\(children(node, baseURL: baseURL))</ul>\n"
        case let node as OrderedList: return "<ol\(node.startIndex == 1 ? "" : " start=\"\(node.startIndex)\"")>\(children(node, baseURL: baseURL))</ol>\n"
        case let node as ListItem:
            let checkbox = node.checkbox.map { $0 == .checked ? "<input type=\"checkbox\" disabled checked> " : "<input type=\"checkbox\" disabled> " } ?? ""
            return "<li>\(checkbox)\(children(node, baseURL: baseURL))</li>\n"
        case let node as CodeBlock:
            let language = node.language.map { " class=\"language-\(attribute($0))\"" } ?? ""
            return "<pre><code\(language)>\(escape(node.code))</code></pre>\n"
        case is ThematicBreak: return "<hr>\n"
        case let node as Table: return "<table>\(children(node, baseURL: baseURL))</table>\n"
        case let node as Table.Head: return "<thead><tr>\(node.children.map { tableCell($0, header: true, baseURL: baseURL) }.joined())</tr></thead>\n"
        case let node as Table.Body: return "<tbody>\(children(node, baseURL: baseURL))</tbody>\n"
        case let node as Table.Row: return "<tr>\(children(node, baseURL: baseURL))</tr>\n"
        case let node as Table.Cell: return tableCell(node, header: false, baseURL: baseURL)
        case let node as Text: return escape(node.string)
        case is SoftBreak: return "\n"
        case is LineBreak: return "<br>\n"
        case let node as Emphasis: return "<em>\(children(node, baseURL: baseURL))</em>"
        case let node as Strong: return "<strong>\(children(node, baseURL: baseURL))</strong>"
        case let node as Strikethrough: return "<del>\(children(node, baseURL: baseURL))</del>"
        case let node as InlineCode: return "<code>\(escape(node.code))</code>"
        case let node as Link:
            let body = children(node, baseURL: baseURL)
            return safeLink(node.destination ?? "", baseURL: baseURL).map { "<a href=\"\(attribute($0))\">\(body)</a>" } ?? body
        case let node as Image:
            let alt = text(node)
            return safeImage(node.source ?? "", baseURL: baseURL).map { "<img src=\"\(attribute($0))\" alt=\"\(attribute(alt))\">" } ?? escape(alt)
        case let node as InlineHTML:
            if let image = safeHTMLImageMarkup(node.rawHTML, baseURL: baseURL) { return image }
            // A styled tag Zephyr draws exports as itself, without attributes.
            if let tag = MarkdownAnalyzer.styledTag(node.rawHTML) { return "<" + (tag.closing ? "/" : "") + tag.name + ">" }
            return escape(node.rawHTML)
        case let node as HTMLBlock:
            if let image = safeHTMLImageMarkup(node.rawHTML, baseURL: baseURL) { return image }
            // The subset Zephyr draws exports as itself (sanitized); other HTML stays visible source.
            guard let fragment = HTMLFragment.parse(node.rawHTML) else { return "<pre><code>\(escape(node.rawHTML))</code></pre>\n" }
            return sanitized(fragment, baseURL: baseURL)
        default: return children(markup, baseURL: baseURL)
        }
    }

    private static func tableCell(_ markup: Markup, header: Bool, baseURL: URL?) -> String {
        guard let cell = markup as? Table.Cell else { return render(markup, baseURL: baseURL) }
        let name = header ? "th" : "td"
        return "<\(name)>\(children(cell, baseURL: baseURL))</\(name)>"
    }

    private static func text(_ markup: Markup) -> String {
        switch markup {
        case let node as Text: return node.string
        case let node as InlineCode: return node.code
        case let node as CodeBlock: return node.code + "\n"
        case is SoftBreak, is LineBreak: return "\n"
        case let node as Image: return node.children.map(text).joined()
        case let node as InlineHTML: return MarkdownAnalyzer.safeHTMLImage(node.rawHTML)?.alt ?? ""
        case let node as HTMLBlock: return MarkdownAnalyzer.safeHTMLImage(node.rawHTML)?.alt ?? HTMLFragment.parse(node.rawHTML).map { $0.plainText + "\n" } ?? ""
        case let node as UnorderedList: return node.children.map { "- " + text($0) }.joined()
        case let node as OrderedList: return node.children.enumerated().map { "\(node.startIndex + UInt($0.offset)). " + text($0.element) }.joined()
        case let node as ListItem:
            let checkbox = node.checkbox.map { $0 == .checked ? "[x] " : "[ ] " } ?? ""
            return checkbox + node.children.map(text).joined()
        case let node as Table.Head: return node.children.map(text).joined(separator: "\t") + "\n"
        case let node as Table.Row: return node.children.map(text).joined(separator: "\t") + "\n"
        case let node as Table.Cell: return node.children.map(text).joined()
        default:
            let body = markup.children.map(text).joined()
            return markup is Paragraph || markup is Heading ? body + "\n" : body
        }
    }

    private static func headingID(_ heading: Heading) -> String {
        var result = ""
        for character in heading.children.map(text).joined().lowercased() {
            if character.isLetter || character.isNumber || character == "_" || character == "-" { result.append(character) }
            else if character == " " { result.append("-") }
        }
        return result
    }

    private static func safeLink(_ destination: String, baseURL: URL?) -> String? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines), lower = trimmed.lowercased()
        guard !trimmed.isEmpty else { return nil }
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") { return trimmed }
        if lower.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.path = URL(fileURLWithPath: url.path).standardizedFileURL.path
            return components?.url?.absoluteString
        }
        guard !trimmed.contains(":"), !trimmed.hasPrefix("//") else { return nil }
        if trimmed.hasPrefix("#") { return trimmed }
        guard let baseURL else { return nil }
        let pieces = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = pieces.first, !path.isEmpty else { return nil }
        let decoded = String(path).removingPercentEncoding ?? String(path)
        let url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : baseURL.appendingPathComponent(decoded)
        var result = url.standardizedFileURL.absoluteString
        if pieces.count == 2 { result += "#" + String(pieces[1]) }
        return result
    }

    private static func safeImage(_ source: String, baseURL: URL?) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines), lower = trimmed.lowercased()
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !lower.hasPrefix("http://"), !lower.hasPrefix("https://") else { return nil }
        if lower.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL { return URL(fileURLWithPath: url.path).absoluteString }
        guard !trimmed.contains(":"), let baseURL else { return nil }
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        return (decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : baseURL.appendingPathComponent(decoded)).standardizedFileURL.absoluteString
    }

    private static func safeHTMLImageMarkup(_ raw: String, baseURL: URL?) -> String? {
        guard let image = MarkdownAnalyzer.safeHTMLImage(raw), let source = safeImage(image.source, baseURL: baseURL) else { return nil }
        let width = image.width.map { min($0, 10_000) }
        return MarkdownAnalyzer.safeHTMLImageMarkup(source: source, alt: image.alt, width: width, alignment: image.alignment)
    }

    private static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    private static func attribute(_ text: String) -> String { escape(text).replacingOccurrences(of: "\"", with: "&quot;") }
}
