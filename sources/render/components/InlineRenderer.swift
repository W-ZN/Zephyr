import AppKit
import ZephyrCore

/// Renders a single line of inline Markdown into a standalone attributed string (table cells),
/// with syntax markers removed and inline math as attachments.
enum InlineRenderer {
    /// `remoteImage` is told about each remote image whose pixels are not loaded yet.
    static func attributedString(_ markdown: String, font: NSFont, typography: Typography, alignment: TableModel.Alignment = .left, baseURL: URL? = nil, remoteImage: ((URL) -> Void)? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment == .center ? .center : (alignment == .right ? .right : .natural)
        paragraph.lineBreakMode = .byWordWrapping
        let result = NSMutableAttributedString(string: markdown, attributes: [.font: font, .foregroundColor: Palette.text, .paragraphStyle: paragraph])
        guard markdown.contains(where: { "*_`~[]<$\\!&".contains($0) }) else { return result }
        let a = MarkdownAnalyzer.analyze(markdown)
        for token in a.inlines {
            let r = token.range
            switch token.style {
            case .strong, .emphasis:
                result.enumerateAttribute(.font, in: r) { value, sub, _ in
                    guard let f = value as? NSFont else { return }
                    result.addAttribute(.font, value: typography.withTraits(f, bold: token.style == .strong, italic: token.style == .emphasis), range: sub)
                }
            case .strikethrough:
                result.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Palette.muted], range: r)
            case .code:
                result.addAttributes([.font: typography.inlineCodeFont(for: font), .backgroundColor: Palette.inlineCodeBackground], range: r)
            case .link:
                result.addAttribute(.foregroundColor, value: Palette.link, range: r)
            case .html:
                result.addAttribute(.foregroundColor, value: Palette.muted, range: r)
            case .keycap:
                result.addAttributes([.font: typography.inlineCodeFont(for: font), .backgroundColor: Palette.inlineCodeBackground], range: r)
            case .highlight:
                result.addAttribute(.backgroundColor, value: Palette.accent.withAlphaComponent(0.18), range: r)
            case .underline:
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .superscript, .subscript, .small:
                let small = Typography.resize(font, round(font.pointSize * (token.style == .small ? 0.85 : 0.75) * 2) / 2)
                result.addAttribute(.font, value: small, range: r)
                if token.style != .small { result.addAttribute(.baselineOffset, value: token.style == .superscript ? round(font.pointSize * 0.35) : -round(font.pointSize * 0.15), range: r) }
            }
        }
        // Replace from the end so earlier ranges stay valid.
        var edits: [(NSRange, NSAttributedString?)] = a.markers.filter { $0.style == .hide }.map { ($0.range, nil) }
        for c in a.components {
            let replacement: NSAttributedString
            switch c.kind {
            case let .inlineMath(tex, display): replacement = mathAttachment(tex, display: display, font: font)
            case let .inlineImage(source, alt, width, height): replacement = imageAttachment(source, alt: alt, width: width, height: height, font: font, baseURL: baseURL, remoteImage: remoteImage)
            // A cell holding only an image parses as a block image; in a cell it is inline.
            case let .image(source, alt, width, _): replacement = imageAttachment(source, alt: alt, width: width, height: nil, font: font, baseURL: baseURL, remoteImage: remoteImage)
            default: continue
            }
            edits.append((c.range, replacement))
            edits.removeAll { $0.1 == nil && NSIntersectionRange($0.0, c.range).length > 0 }
        }
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: replacement ?? NSAttributedString())
        }
        return result
    }

    /// A badge or a local image at its size (at most `maximumWidth`), centered on the x-height; a
    /// remote image that has loaded; otherwise its alt text.
    static let maximumWidth: CGFloat = 320

    private static func imageAttachment(_ source: String, alt: String, width: CGFloat?, height: CGFloat?, font: NSFont, baseURL: URL?, remoteImage: ((URL) -> Void)?) -> NSAttributedString {
        let image = DocumentImage(source: source, alt: alt, baseURL: baseURL)
        let natural: CGSize?
        var drawing: ((NSRect) -> Void)?
        // Pixels come from the shared cache when drawn, so a table holds none of its own.
        switch image.origin {
        case let .badge(badge):
            natural = BadgeRenderer.size(badge)
            drawing = { BadgeRenderer.draw(badge, in: $0) }
        case let .file(url, fileKey, size):
            natural = size
            drawing = { rect in
                var key = fileKey
                key.maxPixels = ImageCache.pixels(for: rect.size)
                let pixels = MainActor.assumeIsolated { () -> CGImage? in
                    if let cached = ImageCache.shared.image(for: key) { return cached }
                    guard let decoded = ImageCache.decode(url, maxPixels: key.maxPixels) else { return nil }
                    ImageCache.shared.insert(decoded, for: key)
                    return decoded
                }
                if let pixels, let ctx = NSGraphicsContext.current?.cgContext { DocumentImage.draw(pixels, in: rect, context: ctx) }
            }
        case let .remote(url):
            natural = MainActor.assumeIsolated { RemoteImages.shared.size(of: url) }
            if natural != nil {
                // Drawn from the cache; pixels it let go are asked for again.
                drawing = { rect in
                    guard let pixels = MainActor.assumeIsolated({ RemoteImages.shared.image(for: url) }), let ctx = NSGraphicsContext.current?.cgContext else { return remoteImage?(url) ?? () }
                    DocumentImage.draw(pixels, in: rect, context: ctx)
                }
            }
            if MainActor.assumeIsolated({ RemoteImages.shared.image(for: url) }) == nil { remoteImage?(url) }
        case .missing:
            natural = nil
        }
        guard let natural, natural.width > 0, natural.height > 0, let drawing else {
            return NSAttributedString(string: alt, attributes: [.font: font, .foregroundColor: Palette.muted])
        }
        var size = natural
        if let width, let height { size = CGSize(width: width, height: height) }
        else if let width { size = CGSize(width: width, height: width * natural.height / natural.width) }
        else if let height { size = CGSize(width: height * natural.width / natural.height, height: height) }
        if size.width > maximumWidth { size = CGSize(width: maximumWidth, height: size.height * maximumWidth / size.width) }
        size = ImageCache.capped(size)
        let rendered = NSImage(size: size, flipped: true) { rect in drawing(rect); return true }
        let attachment = NSTextAttachment()
        attachment.image = rendered
        let ascent = min(size.height, round(size.height / 2 + font.xHeight / 2))
        attachment.bounds = CGRect(x: 0, y: ascent - size.height, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    private static func mathAttachment(_ tex: String, display: Bool, font: NSFont) -> NSAttributedString {
        let formula = MathRenderer.shared.formula(tex, display: display)
        guard formula.error == nil else { return NSAttributedString(string: tex, attributes: [.font: font, .foregroundColor: NSColor.systemRed]) }
        let fontSize = font.pointSize * 1.08
        let size = formula.size(fontSize: fontSize)
        let image = NSImage(size: CGSize(width: ceil(size.width), height: ceil(size.ascent + size.descent)), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            MathRenderer.shared.draw(MathRenderer.shared.formula(tex, display: display), at: .zero, fontSize: fontSize, color: Palette.text, in: ctx)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -size.descent, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }
}
