import AppKit
import ImageIO

/// Remote images in documents (design §9): loaded only when the document's context allows it,
/// over HTTPS, without cookies or a disk cache, at most `byteLimit` bytes each. One request per URL
/// however many components show it. Pixels go to the shared, bounded `ImageCache`; the natural size
/// stays after the pixels are evicted, so the layout does not jump when they load again.
@MainActor
final class RemoteImages {
    static let shared = RemoteImages()
    nonisolated static let byteLimit = 8 << 20
    /// SVG renders at this many pixels per point, for sharp badges on Retina screens and zoom.
    nonisolated static let vectorScale: CGFloat = 3

    /// Requests in flight at once, across all hosts; the rest wait their turn.
    nonisolated static let concurrentLimit = 6
    /// A failed image is not asked for again for this long (offline, a timeout, a server error).
    nonisolated static let retryDelay: TimeInterval = 60
    /// Natural sizes kept, oldest forgotten first; a few bytes each.
    nonisolated static let sizeLimit = 4096

    private var sizes: [URL: CGSize] = [:]
    private var sizeOrder: [URL] = []
    private var failed: [URL: Date] = [:]
    private var pending: [URL: [(token: UUID, completion: (Bool) -> Void)]] = [:]
    private var queued: [URL] = []
    private var running = 0
    private var session: URLSession?

    static func key(_ url: URL) -> ImageCache.Key { ImageCache.Key(url: url, modificationDate: nil, fileSize: nil) }

    /// Natural size in points, once the image has loaded.
    func size(of url: URL) -> CGSize? { sizes[url] }
    /// The pixels, while their natural size is also known (both are needed to draw them in place).
    func image(for url: URL) -> CGImage? { sizes[url] == nil ? nil : ImageCache.shared.image(for: Self.key(url)) }
    func hasFailed(_ url: URL) -> Bool {
        if url.scheme?.lowercased() != "https" { return true }
        guard let date = failed[url] else { return false }
        return Date().timeIntervalSince(date) < Self.retryDelay
    }

    /// Loads `url` unless its pixels are cached; `completion(true)` once they are. The token
    /// cancels the completion (the request itself goes on for anyone else showing the image).
    @discardableResult
    func load(_ url: URL, completion: @escaping (Bool) -> Void) -> UUID? {
        if image(for: url) != nil { completion(true); return nil }
        guard !hasFailed(url) else { completion(false); return nil }
        let token = UUID()
        if pending[url] != nil {
            pending[url]?.append((token, completion))
            return token
        }
        pending[url] = [(token, completion)]
        queued.append(url)
        startQueued()
        return token
    }

    func cancel(_ token: UUID) {
        for url in pending.keys { pending[url]?.removeAll { $0.token == token } }
    }

    private func startQueued() {
        while running < Self.concurrentLimit, !queued.isEmpty {
            let url = queued.removeFirst()
            running += 1
            let session = self.session ?? Self.makeSession()
            self.session = session
            Task.detached(priority: .utility) {
                let result = await Self.fetch(url, session: session)
                await MainActor.run { RemoteImages.shared.finish(url, result) }
            }
        }
    }

    private func finish(_ url: URL, _ result: (CGImage, CGSize)?) {
        running -= 1
        if let (image, size) = result {
            if sizes.updateValue(size, forKey: url) == nil { sizeOrder.append(url) }
            if sizeOrder.count > Self.sizeLimit { sizes[sizeOrder.removeFirst()] = nil }
            failed[url] = nil
            ImageCache.shared.insert(image, for: Self.key(url))
        } else {
            failed[url] = Date()
        }
        let waiting = pending.removeValue(forKey: url) ?? []
        for waiter in waiting { waiter.completion(result != nil) }
        startQueued()
    }

    private nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    private nonisolated static func fetch(_ url: URL, session: URLSession) async -> (CGImage, CGSize)? {
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength <= Int64(byteLimit) else { return nil }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteLimit { return nil }
            }
        } catch { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("svg") || isSVG(data) { return rasterizeSVG(data) }
        return decode(data)
    }

    nonisolated static func isSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(512), encoding: .utf8)?.lowercased() else { return false }
        return head.contains("<svg")
    }

    /// Bitmaps decode as a bounded thumbnail; the natural size follows the image's resolution.
    nonisolated static func decode(_ data: Data) -> (CGImage, CGSize)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixels = DocumentImage.naturalPixels(props) else { return nil }
        let (w, h) = (pixels.width, pixels.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ImageCache.thumbnailMaxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let dpi = props[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        let scale = dpi >= 144 ? dpi / 72 : 1
        return (image, CGSize(width: w / scale, height: h / scale))
    }

    /// SVG through AppKit's own renderer, into a bitmap at `vectorScale` (at most the cache's
    /// thumbnail size on the long side).
    nonisolated static func rasterizeSVG(_ data: Data) -> (CGImage, CGSize)? {
        guard let svg = NSImage(data: data), svg.size.width > 0, svg.size.height > 0 else { return nil }
        let size = svg.size
        let scale = min(vectorScale, CGFloat(ImageCache.thumbnailMaxPixels) / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        svg.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        return (image, size)
    }
}
