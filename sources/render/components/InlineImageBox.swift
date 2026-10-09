import AppKit
import ZephyrCore

/// An image inside a line of text (design §9): a badge in a paragraph, an icon in a link, an
/// inline `<img>`. Centered on the x-height like images in the HTML layout, at most as wide as
/// the reading column, and a placeholder with the alt text until its pixels or size are known.
final class InlineImageBox: ComponentBox, InlineComponent {
    let image: DocumentImage
    let requestedWidth: CGFloat?
    let requestedHeight: CGFloat?
    let fontSize: CGFloat
    private(set) var size: CGSize = .zero
    private(set) var metrics: (width: CGFloat, ascent: CGFloat, descent: CGFloat) = (0, 0, 0)
    /// A hair of room on each side, so an image next to text or another image does not touch it.
    var advance: CGFloat { metrics.width + 2 }

    init(source: String, alt: String, width: CGFloat?, height: CGFloat?, fontSize: CGFloat, kind: ComponentKind, context: RenderContext) {
        image = DocumentImage(source: source, alt: alt, baseURL: context.baseURL)
        requestedWidth = width
        requestedHeight = height
        self.fontSize = fontSize
        super.init(kind: kind, context: context)
        measure()
    }

    /// Size and metrics for the current theme (again when a reused box meets a new theme).
    func measure() {
        let column = context?.typography.readableWidth ?? 640
        let natural = image.naturalSize
        let placeholder = image.placeholderSize(fontSize: fontSize)
        var s: CGSize
        switch (requestedWidth, requestedHeight, natural) {
        case let (w?, h?, _): s = CGSize(width: w, height: h)
        case let (w?, nil, n?): s = CGSize(width: w, height: w * n.height / n.width)
        case let (nil, h?, n?): s = CGSize(width: h * n.width / n.height, height: h)
        case let (nil, nil, n?): s = n
        case let (w?, nil, nil): s = CGSize(width: w, height: placeholder.height)
        case let (nil, h?, nil): s = CGSize(width: placeholder.width, height: h)
        case (nil, nil, nil): s = placeholder
        }
        if s.width > column { s = CGSize(width: column, height: s.height * column / s.width) }
        s = ImageCache.capped(s)
        size = CGSize(width: max(1, s.width.rounded()), height: max(1, s.height.rounded()))
        let xHeight = (context?.typography.bodyFont ?? NSFont.systemFont(ofSize: fontSize)).xHeight
        let ascent = min(size.height, round(size.height / 2 + xHeight / 2))
        metrics = (size.width, ascent, size.height - ascent)
    }

    func draw(atX x: CGFloat, baseline: CGFloat, width: CGFloat, color: NSColor, context ctx: CGContext) {
        // Narrower than its advance: the line scaled the image down to fit the column.
        let scale = width < advance - 0.5 ? max(1, width - (advance - metrics.width)) / metrics.width : 1
        let rect = NSRect(x: x + 1, y: baseline - metrics.ascent * scale, width: size.width * scale, height: size.height * scale)
        drawnRect = rect
        image.draw(in: rect, context: ctx, allowRemote: context?.loadsRemoteImages ?? false, fontSize: fontSize) { [weak self] sizeChanged in
            guard let self else { return }
            if sizeChanged {
                self.measure()
                self.context?.componentNeedsLayout(self)
            } else {
                self.context?.componentNeedsDisplay(self)
            }
        }
    }

    override func prepareForOutput() { image.forOutput = true }

    /// A remote image waiting for the document to allow remote images.
    var isBlocked: Bool { image.isBlocked(allowRemote: context?.loadsRemoteImages ?? false) }
}
