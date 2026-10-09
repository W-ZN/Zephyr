import AppKit
import ImageIO
import ZephyrCore

/// An image a document refers to, as Zephyr resolves it (design §9): a local file (the header is
/// read now, the pixels decode later on the shared queue), a static badge Zephyr draws itself, a
/// remote image that loads only when the document allows it, or a source that cannot be shown.
/// It holds no pixels: decoded images live in the bounded `ImageCache`. Used on the main thread
/// only, like the components that hold it.
final class DocumentImage {
    enum Origin {
        case file(URL, ImageCache.Key, natural: CGSize)
        case badge(Badge)
        case remote(URL)
        case missing
    }

    let source: String
    let alt: String
    let origin: Origin
    /// Set for a one-shot output (print, PDF, image export): local pixels decode synchronously at
    /// full size, and nothing starts loading.
    var forOutput = false
    private var request: UUID?
    private var waitsForRemote = false

    init(source: String, alt: String, baseURL: URL?) {
        self.source = source
        self.alt = alt
        origin = Self.resolve(source, baseURL: baseURL)
    }

    deinit {
        guard let request else { return }
        Task { @MainActor in ImageDecodeQueue.shared.cancel(request) }
    }

    /// The local file `source` names (relative to `baseURL`), a badge, or a web URL. A document
    /// loaded from the web resolves every relative source against the web.
    static func resolve(_ source: String, baseURL: URL?) -> Origin {
        if let badge = Badge.parse(source) { return .badge(badge) }
        let lower = source.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: source).map { .remote($0) } ?? .missing
        }
        if let baseURL, !baseURL.isFileURL {
            return URL(string: source, relativeTo: baseURL).map { .remote($0.absoluteURL) } ?? .missing
        }
        let path = source.removingPercentEncoding ?? source
        let url: URL
        if lower.hasPrefix("file://"), let u = URL(string: source) {
            url = u
        } else if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if let baseURL {
            url = baseURL.appendingPathComponent(path).standardizedFileURL
        } else {
            return .missing
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pixels = naturalPixels(props) else { return .missing }
        let dpi = props[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        let scale = dpi >= 144 ? dpi / 72 : 1
        let (w, h) = (pixels.width, pixels.height)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = ImageCache.Key(url: url, modificationDate: values?.contentModificationDate, fileSize: values?.fileSize)
        return .file(url, key, natural: CGSize(width: w / scale, height: h / scale))
    }

    /// Pixel size as displayed: orientations 5–8 (a portrait photo stored sideways) swap the
    /// sides, like the decoded thumbnail does.
    static func naturalPixels(_ props: [CFString: Any]) -> CGSize? {
        guard let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Size in points when known: a remote image's only after it loaded.
    var naturalSize: CGSize? {
        switch origin {
        case let .file(_, _, natural): natural
        case let .badge(badge): BadgeRenderer.size(badge)
        case let .remote(url): MainActor.assumeIsolated { RemoteImages.shared.size(of: url) }
        case .missing: nil
        }
    }

    var remoteURL: URL? {
        if case let .remote(url) = origin { return url }
        return nil
    }

    /// A remote image the document has not allowed yet (a click on it loads the document's images).
    func isBlocked(allowRemote: Bool) -> Bool {
        guard let url = remoteURL, !allowRemote else { return false }
        return MainActor.assumeIsolated { RemoteImages.shared.image(for: url) == nil && !RemoteImages.shared.hasFailed(url) }
    }

    /// The pill drawn while there is nothing else to show: the alt text, or a glyph alone.
    func placeholderSize(fontSize: CGFloat) -> CGSize {
        let font = Self.placeholderFont(fontSize)
        let glyph = Self.glyph("photo", font)?.size.width ?? font.pointSize
        let text = alt.isEmpty ? 0 : ceil((alt as NSString).size(withAttributes: [.font: font]).width) + Self.gap
        return CGSize(width: min(320, ceil(Self.inset + glyph + text + Self.inset + 1)), height: ceil(font.pointSize * 1.9))
    }

    private static let inset: CGFloat = 7
    private static let gap: CGFloat = 5
    private static func placeholderFont(_ fontSize: CGFloat) -> NSFont { NSFont.systemFont(ofSize: max(11, fontSize * 0.75)) }
    private static func glyph(_ symbol: String, _ font: NSFont) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
    }

    /// Draws into `rect` (flipped view coordinates): the pixels, the badge, or a placeholder.
    /// Starting a load is a side effect; `changed(sizeKnown)` reports when it finishes. A finished
    /// load must redraw only `rect`: redrawing neighbors whose pixels the cache let go would
    /// request them again, and images that do not fit the cache together would take turns forever.
    func draw(in rect: NSRect, context ctx: CGContext, allowRemote: Bool, fontSize: CGFloat, changed: @escaping (_ sizeChanged: Bool) -> Void) {
        MainActor.assumeIsolated { drawOnMain(in: rect, context: ctx, allowRemote: allowRemote, fontSize: fontSize, changed: changed) }
    }

    @MainActor
    private func drawOnMain(in rect: NSRect, context ctx: CGContext, allowRemote: Bool, fontSize: CGFloat, changed: @escaping (_ sizeChanged: Bool) -> Void) {
        let output = forOutput || NSGraphicsContext.current?.isDrawingToScreen == false
        switch origin {
        case let .badge(badge):
            BadgeRenderer.draw(badge, in: rect)
        case let .file(url, fileKey, _):
            // Pixels at the size drawn (output at full size): a row of screenshots fits the cache.
            var key = fileKey
            if !output { key.maxPixels = ImageCache.pixels(for: rect.size) }
            if let image = ImageCache.shared.image(for: key) {
                Self.draw(image, in: rect, context: ctx)
            } else if output, let image = ImageCache.decode(url) {
                ImageCache.shared.insert(image, for: key)
                Self.draw(image, in: rect, context: ctx)
            } else {
                Palette.codeBackground.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                guard request == nil else { return }
                request = ImageDecodeQueue.shared.request(key, url: url) { [weak self] image, completed in
                    self?.request = nil
                    if completed, image != nil { changed(false) }
                    // Dropped while too many waited: draw again soon, which asks again if still shown.
                    if !completed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { changed(false) } }
                }
            }
        case let .remote(url):
            if let image = RemoteImages.shared.image(for: url) {
                Self.draw(image, in: rect, context: ctx)
                return
            }
            let failed = RemoteImages.shared.hasFailed(url)
            // One request per image however often it is drawn while loading.
            if allowRemote, !failed, !output, !waitsForRemote {
                let known = RemoteImages.shared.size(of: url) != nil
                waitsForRemote = true
                RemoteImages.shared.load(url) { [weak self] ok in
                    self?.waitsForRemote = false
                    if ok { changed(!known) }
                }
            }
            placeholder(in: rect, symbol: failed ? "exclamationmark.triangle" : (allowRemote ? "arrow.down.circle" : "photo"), fontSize: fontSize)
        case .missing:
            placeholder(in: rect, symbol: "exclamationmark.triangle", fontSize: fontSize)
        }
    }

    private func placeholder(in rect: NSRect, symbol: String, fontSize: CGFloat) {
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(6, box.height / 2)
        Palette.codeBackground.setFill()
        NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
        let font = Self.placeholderFont(fontSize)
        var x = box.minX + Self.inset
        if let glyph = Self.glyph(symbol, font)?.tinted(Palette.muted), box.width >= glyph.size.width + 10 {
            glyph.draw(in: NSRect(x: x, y: box.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height))
            x += glyph.size.width + Self.gap
        }
        guard !alt.isEmpty, box.maxX - x > 12 else { return }
        let text = NSAttributedString(string: alt, attributes: [.font: font, .foregroundColor: Palette.muted])
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: box).addClip()
        text.draw(with: NSRect(x: x, y: box.midY - (font.ascender - font.descender) / 2, width: box.maxX - x - Self.inset + 2, height: font.ascender - font.descender + 2),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }

    static func draw(_ image: CGImage, in frame: NSRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: frame.size))
        ctx.restoreGState()
    }
}
