import AppKit
import Foundation
import ImageIO
import PDFKit

/// A small, in-memory preview for the link currently under the pointer. It never writes beside a
/// document, starts network work only after the dwell delay, and gives up that work as soon as the
/// pointer leaves.
@MainActor
final class LinkPreviewController: NSObject {
    static let enabledKey = "linkPreviews"
    static let delayKey = "linkPreviewDelay"

    private weak var editor: MarkdownEditor?
    private var pending: DispatchWorkItem?
    private var loadTask: Task<Void, Never>?
    private var pageRenderer: LinkPreviewPageRenderer?
    private var overlay: LinkPreviewOverlay?
    private var destination: String?
    private var leaveWork: DispatchWorkItem?
    private var explicitPreview = false
    private weak var previousResponder: NSResponder?

    init(editor: MarkdownEditor) {
        self.editor = editor
    }

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? NSNumber)?.boolValue ?? true
    }

    static var delay: TimeInterval {
        let value = UserDefaults.standard.object(forKey: delayKey) as? NSNumber
        return max(0, value?.doubleValue ?? 0.8)
    }

    func hover(destination: String, at anchor: NSPoint, in view: NSView) {
        guard Self.isEnabled else {
            cancel()
            return
        }
        if self.destination == destination {
            leaveWork?.cancel()
            leaveWork = nil
            return
        }
        cancel()
        self.destination = destination
        let delay = Self.delay
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, self.destination == destination else { return }
            self.show(destination: destination, at: anchor, in: view)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func pointerExited() {
        guard !explicitPreview else { return }
        guard destination != nil else { return }
        if overlay == nil {
            cancel()
            return
        }
        // Moving from the link to the card crosses the canvas tracking area. Let the card's own
        // tracking area claim the pointer before deciding that the preview is really abandoned.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.overlay?.card.pointerInside != true else { return }
            self.cancel()
        }
        leaveWork?.cancel()
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func cardPointerEntered() {
        leaveWork?.cancel()
        leaveWork = nil
    }

    func cardPointerExited() {
        pointerExited()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        leaveWork?.cancel()
        leaveWork = nil
        loadTask?.cancel()
        loadTask = nil
        pageRenderer?.cancel()
        pageRenderer = nil
        if let overlay, let window = overlay.window,
           let responder = window.firstResponder as? NSView, responder.isDescendant(of: overlay) {
            window.makeFirstResponder(previousResponder)
        }
        previousResponder = nil
        overlay?.removeFromSuperview()
        overlay = nil
        destination = nil
        explicitPreview = false
    }

    /// AppKit chooses the card's text view as first responder after the canvas resigns. Wait until
    /// that handoff settles before deciding whether the preview has really lost focus.
    func canvasDidResignFirstResponder() {
        previewResponderDidChange()
    }

    func sourceDidResignFirstResponder() {
        previewResponderDidChange()
    }

    private func previewResponderDidChange() {
        guard let overlay else { return }
        Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay, self.overlay === overlay else { return }
            if let responder = overlay.window?.firstResponder as? NSView, responder.isDescendant(of: overlay) { return }
            self.cancel()
        }
    }

    /// The explicit link menu entry also makes previews available without dwelling the pointer.
    func preview(destination: String, at anchor: NSPoint, in view: NSView) {
        if self.destination == destination, overlay != nil {
            explicitPreview = true
            leaveWork?.cancel()
            leaveWork = nil
            return
        }
        cancel()
        explicitPreview = true
        self.destination = destination
        show(destination: destination, at: anchor, in: view)
    }

    private func show(destination: String, at anchor: NSPoint, in view: NSView) {
        guard let editor, let target = LinkPreviewTarget(destination: destination, baseURL: editor.baseURL) else {
            cancel()
            return
        }
        pending = nil
        let container = editor.scrollView.contentView
        let size = LinkPreviewLayout.cardSize(for: container.bounds.size, preferredHeight: 112)
        guard size.width > 0, size.height > 0 else { return }
        let card = LinkPreviewCard(size: size, typography: editor.typography)
        card.sourceDescription = target.sourceDescription
        if case let .web(url, nil) = target { card.pageURL = url }
        card.onPageCancel = { [weak self] in
            self?.loadTask?.cancel()
            self?.loadTask = nil
            self?.pageRenderer?.cancel()
            self?.pageRenderer = nil
        }
        card.onPagePreview = { [weak self, weak card] url in
            guard let self, let card else { return }
            self.explicitPreview = true
            self.leaveWork?.cancel()
            self.leaveWork = nil
            self.loadTask?.cancel()
            let renderer = LinkPreviewPageRenderer()
            self.pageRenderer = renderer
            let host = card.beginPageSnapshot()
            self.loadTask = Task { @MainActor [weak self, weak card] in
                do {
                    let snapshot = try await renderer.render(url, in: host)
                    guard !Task.isCancelled, let self, self.destination == destination, self.overlay?.card === card else { return }
                    self.pageRenderer = nil
                    card?.showPageSnapshot(snapshot)
                } catch {
                    guard !Task.isCancelled, let self, self.destination == destination, self.overlay?.card === card else { return }
                    self.pageRenderer = nil
                    let message = (error as? URLError).map { LinkPreviewHTTP.failureDescription($0.code) } ?? String(localized: "The page snapshot could not be rendered.")
                    card?.showPageFailure(message)
                }
            }
        }
        card.onPointerEntered = { [weak self] in self?.cardPointerEntered() }
        card.onPointerExited = { [weak self] in self?.cardPointerExited() }
        card.onAsk = { [weak self, weak editor] context in
            guard let self, self.destination == destination else { return }
            self.cancel()
            editor?.askLinkPreview?(destination, context)
        }
        card.onOpen = { [weak self, weak editor] in
            self?.cancel()
            editor?.openLink?(destination)
        }
        card.onDismiss = { [weak self] in self?.cancel() }
        card.onSourceResigned = { [weak self] in self?.sourceDidResignFirstResponder() }
        let overlay = LinkPreviewOverlay(frame: container.bounds, card: card, anchor: .zero)
        previousResponder = container.window?.firstResponder
        card.onContentSizeChanged = { [weak overlay] in overlay?.contentChanged() }
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)
        overlay.setAnchor(view.convert(anchor, to: overlay))
        overlay.animateIn()
        self.overlay = overlay
        loadTask = Task { @MainActor [weak self, weak card] in
            let content = await LinkPreviewLoader.load(target)
            guard !Task.isCancelled, let self, self.destination == destination, self.overlay?.card === card else { return }
            card?.show(content)
        }
    }
}

enum LinkPreviewTarget: Equatable {
    case markdown(URL, LinkPreviewLineRange?)
    case pdf(URL)
    case image(URL)
    case office(URL)
    case web(URL, LinkPreviewLineRange?)
    case text(URL, LinkPreviewLineRange?)
    case generic(URL)

    var sourceDescription: String {
        switch self {
        case let .web(url, _): return url.host ?? url.absoluteString
        case .markdown: return "Markdown"
        case let .pdf(url), let .image(url), let .office(url), let .text(url, _), let .generic(url):
            return url.pathExtension.isEmpty ? String(localized: "Local file") : url.pathExtension.uppercased()
        }
    }

    init?(destination: String, baseURL: URL?) {
        let text = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let lines = LinkPreviewLineRange(fragment: components?.fragment)
                components?.fragment = nil
                let previewURL = components?.url ?? url
                self = .web(LinkPreviewGitHub.rawURL(for: previewURL) ?? previewURL, lines)
            case "file":
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let lines = LinkPreviewLineRange(fragment: components?.fragment)
                components?.fragment = nil
                let localURL = (components?.url ?? url).standardizedFileURL
                if lines == nil, let parsed = LinkPreviewLineRange.pathSuffix(localURL.path) {
                    self = Self.local(URL(fileURLWithPath: parsed.path), lines: parsed.range)
                } else {
                    self = Self.local(localURL, lines: lines)
                }
            default: return nil
            }
            return
        }
        let fragmentParts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        var path = fragmentParts.first.map(String.init) ?? ""
        var lines = fragmentParts.count == 2 ? LinkPreviewLineRange(fragment: String(fragmentParts[1])) : nil
        if lines == nil, let parsed = LinkPreviewLineRange.pathSuffix(path) {
            path = parsed.path
            lines = parsed.range
        }
        guard !path.isEmpty else { return nil }
        let decoded = path.removingPercentEncoding ?? path
        let url: URL
        if decoded.hasPrefix("/") { url = URL(fileURLWithPath: decoded) }
        else if let baseURL { url = baseURL.appendingPathComponent(decoded).standardizedFileURL }
        else { return nil }
        self = Self.local(url, lines: lines)
    }

    private static func local(_ url: URL, lines: LinkPreviewLineRange? = nil) -> LinkPreviewTarget {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkdn", "mkd", "mdwn", "mdx": return .markdown(url, lines)
        case "pdf": return .pdf(url)
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp": return .image(url)
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp", "rtf", "rtfd": return .office(url)
        case "zip", "gz", "xz", "bz2", "dmg", "app", "pkg", "mp3", "mp4", "mov", "wav", "aiff", "woff", "woff2", "ttf", "otf", "sqlite", "db": return .generic(url)
        default: return .text(url, lines)
        }
    }
}

enum LinkPreviewGitHub {
    static func rawURL(for url: URL) -> URL? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        guard let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
        let parts = encodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[2] == "blob" else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        components.percentEncodedPath = "/" + parts[0...1].joined(separator: "/") + "/" + parts[3...].joined(separator: "/")
        return components.url
    }
}

struct LinkPreviewLineRange: Equatable, Sendable {
    let start: Int
    let end: Int

    init?(fragment: String?) {
        guard let fragment else { return nil }
        self.init(specification: fragment, prefix: "L")
    }

    private init?(specification: String, prefix: String) {
        let expression = "^" + prefix + "([0-9]+)(?:-" + prefix + "?([0-9]+))?$"
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: specification, range: NSRange(specification.startIndex..., in: specification)),
              let startRange = Range(match.range(at: 1), in: specification),
              let start = Int(specification[startRange]) else { return nil }
        let end = match.range(at: 2).location == NSNotFound ? start : Int(Range(match.range(at: 2), in: specification).map { String(specification[$0]) } ?? "")
        guard let end, start > 0, end >= start else { return nil }
        self.start = start
        self.end = end
    }

    static func pathSuffix(_ path: String) -> (path: String, range: LinkPreviewLineRange)? {
        guard let colon = path.lastIndex(of: ":") else { return nil }
        let suffix = String(path[path.index(after: colon)...])
        guard let range = LinkPreviewLineRange(specification: suffix, prefix: "") else { return nil }
        return (String(path[..<colon]), range)
    }
}

enum LinkPreviewContent {
    case markdown(title: String, text: String, baseURL: URL, context: String)
    case text(title: String, text: String)
    case website(title: String, detail: String, url: URL, isSummary: Bool)
    case visual(title: String, detail: String, image: NSImage, context: String, kind: String)
    case file(title: String, detail: String)
    case failure(title: String, detail: String)
}

private enum LinkPreviewLocalPayload: Sendable {
    case markdown(title: String, text: String, baseURL: URL, context: String)
    case pdf(title: String, detail: String, image: Data?, pages: Int)
    case image(title: String, image: Data?)
    case text(title: String, text: String)
    case file(title: String, detail: String)
    case failure(title: String, detail: String)
}

private enum LinkPreviewWebPayload: Sendable {
    case markdown(title: String, text: String, baseURL: URL)
    case document(title: String, detail: String, url: URL, isSummary: Bool)
    case text(title: String, text: String)
    case file(title: String, detail: String)
    case failure(title: String, detail: String)
}

@MainActor
enum LinkPreviewLoader {
    static let markdownReadLimit = LinkPreviewFileReader.readLimit
    nonisolated static let displayTextLimit = LinkPreviewFileReader.displayLimit
    static let webReadLimit = 256 << 10
    static let pdfSizeLimit = 32 << 20

    static func load(_ target: LinkPreviewTarget) async -> LinkPreviewContent {
        switch target {
        case let .markdown(url, lines): return await markdown(url, lines: lines)
        case let .pdf(url): return await pdf(url)
        case let .image(url): return await image(url)
        case let .office(url): return await office(url)
        case let .web(url, lines): return await web(url, lines: lines)
        case let .text(url, lines): return await text(url, lines: lines)
        case let .generic(url): return generic(url)
        }
    }

    private static func markdown(_ url: URL, lines: LinkPreviewLineRange?) async -> LinkPreviewContent {
        await localText(url, lines: lines, isMarkdown: true)
    }

    private static func text(_ url: URL, lines: LinkPreviewLineRange?) async -> LinkPreviewContent {
        await localText(url, lines: lines, isMarkdown: false)
    }

    private static func localText(_ url: URL, lines: LinkPreviewLineRange?, isMarkdown: Bool) async -> LinkPreviewContent {
        let task = Task.detached(priority: .utility) { () -> LinkPreviewLocalPayload in
            guard !Task.isCancelled else { return .failure(title: url.lastPathComponent, detail: "") }
            do {
                guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    return .failure(title: url.lastPathComponent, detail: String(localized: "The text file could not be read."))
                }
                switch try LinkPreviewFileReader.read(url, lines: lines) {
                case let .text(excerpt):
                    if isMarkdown, lines == nil {
                        return .markdown(title: url.lastPathComponent, text: excerpt, baseURL: url.deletingLastPathComponent(), context: String(excerpt.prefix(8 << 10)))
                    }
                    return .text(title: url.lastPathComponent, text: excerpt)
                case .tooLarge:
                    return .failure(title: url.lastPathComponent, detail: String(localized: "This file is too large to preview. Open it or specify line numbers."))
                case .notUTF8:
                    if !isMarkdown { return .file(title: url.lastPathComponent, detail: String(localized: "Open this file in its default app to view its contents.")) }
                    return .failure(title: url.lastPathComponent, detail: String(localized: "This local file is not UTF-8 text."))
                case .linesUnavailable:
                    return .failure(title: url.lastPathComponent, detail: String(localized: "The requested lines could not be read within the preview limit."))
                }
            } catch is CancellationError {
                return .failure(title: url.lastPathComponent, detail: "")
            } catch {
                return .failure(title: url.lastPathComponent, detail: String(localized: "The text file could not be read."))
            }
        }
        return content(await result(of: task))
    }

    private static func pdf(_ url: URL) async -> LinkPreviewContent {
        let sizeLimit = pdfSizeLimit
        let task = Task.detached(priority: .utility) { () -> LinkPreviewLocalPayload in
            let title = url.lastPathComponent
            guard !Task.isCancelled else { return .failure(title: title, detail: "") }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  let size = values.fileSize, size <= sizeLimit else {
                return .failure(title: title, detail: String(localized: "This PDF is too large to preview."))
            }
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
                return .failure(title: title, detail: String(localized: "The PDF could not be read."))
            }
            guard !Task.isCancelled else { return .failure(title: title, detail: "") }
            let image = page.thumbnail(of: NSSize(width: 720, height: 900), for: .mediaBox).tiffRepresentation
            guard !Task.isCancelled else { return .failure(title: title, detail: "") }
            let excerpt = page.string?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(900) ?? ""
            guard !Task.isCancelled else { return .failure(title: title, detail: "") }
            return .pdf(title: title, detail: String(excerpt), image: image, pages: document.pageCount)
        }
        return content(await result(of: task))
    }

    private static func image(_ url: URL) async -> LinkPreviewContent {
        let sizeLimit = pdfSizeLimit
        let task = Task.detached(priority: .utility) { () -> LinkPreviewLocalPayload in
            let title = url.lastPathComponent
            guard !Task.isCancelled else { return .failure(title: title, detail: "") }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  let size = values.fileSize, size <= sizeLimit else {
                return .failure(title: title, detail: String(localized: "This image is too large to preview."))
            }
            let options: CFDictionary = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_024,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                return .failure(title: title, detail: String(localized: "The image could not be read."))
            }
            guard !Task.isCancelled else { return .failure(title: title, detail: "") }
            return .image(title: title, image: NSImage(cgImage: thumbnail, size: .zero).tiffRepresentation)
        }
        return content(await result(of: task))
    }

    private static func generic(_ url: URL) -> LinkPreviewContent {
        .file(title: url.lastPathComponent, detail: String(localized: "Open this file in its default app to view its contents."))
    }

    private static func office(_ url: URL) async -> LinkPreviewContent {
        do {
            let renderer = LinkPreviewThumbnailRenderer()
            let image = try await renderer.render(url)
            return .visual(title: url.lastPathComponent, detail: "", image: image, context: "", kind: String(localized: "Thumbnail"))
        } catch LinkPreviewThumbnailRenderer.Failure.tooLarge {
            return .file(title: url.lastPathComponent, detail: String(localized: "This document is too large to preview. Open it in its default app."))
        } catch {
            return .file(title: url.lastPathComponent, detail: String(localized: "A thumbnail is unavailable. Open this document in its default app."))
        }
    }

    private static func result(of task: Task<LinkPreviewLocalPayload, Never>) async -> LinkPreviewLocalPayload {
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private static func content(_ payload: LinkPreviewLocalPayload) -> LinkPreviewContent {
        switch payload {
        case let .markdown(title, text, baseURL, context): return .markdown(title: title, text: text, baseURL: baseURL, context: context)
        case let .pdf(title, detail, data, pages):
            guard let image = data.flatMap({ NSImage(data: $0) }) else { return .failure(title: title, detail: String(localized: "The PDF could not be read.")) }
            return .visual(title: title, detail: detail, image: image, context: String(detail.prefix(8 << 10)), kind: String(localized: "Page 1 of \(pages)"))
        case let .image(title, data):
            guard let image = data.flatMap({ NSImage(data: $0) }) else { return .failure(title: title, detail: String(localized: "The image could not be read.")) }
            return .visual(title: title, detail: "", image: image, context: "", kind: String(localized: "Image preview"))
        case let .text(title, text): return .text(title: title, text: text)
        case let .file(title, detail): return .file(title: title, detail: detail)
        case let .failure(title, detail): return .failure(title: title, detail: detail)
        }
    }

    private static func web(_ url: URL, lines: LinkPreviewLineRange?) async -> LinkPreviewContent {
        content(await fetchWeb(url, lines: lines, limit: webReadLimit))
    }

    private static func content(_ payload: LinkPreviewWebPayload) -> LinkPreviewContent {
        switch payload {
        case let .markdown(title, text, baseURL): return .markdown(title: title, text: text, baseURL: baseURL, context: String(text.prefix(8 << 10)))
        case let .document(title, detail, url, summary): return .website(title: title, detail: detail, url: url, isSummary: summary)
        case let .text(title, text): return .text(title: title, text: text)
        case let .file(title, detail): return .file(title: title, detail: detail)
        case let .failure(title, detail): return .failure(title: title, detail: detail)
        }
    }

    nonisolated private static func fetchWeb(_ url: URL, lines: LinkPreviewLineRange?, limit: Int) async -> LinkPreviewWebPayload {
        do {
            let (data, http) = try await boundedResponse(url, limit: limit)
            let type = http.value(forHTTPHeaderField: "Content-Type")
            let finalURL = http.url ?? url
            let isMarkdown = LinkPreviewHTTP.isMarkdown(type, url: finalURL)
            if isMarkdown, lines == nil, data.count == limit {
                return .failure(title: finalURL.lastPathComponent, detail: String(localized: "This Markdown file is too large to preview. Open it or specify line numbers."))
            }
            guard let text = LinkPreviewHTTP.decode(data, contentType: type) else {
                return .failure(title: url.host ?? url.absoluteString, detail: String(localized: "The website text encoding could not be read."))
            }
            if text.prefix(4 << 10).contains("\u{0000}") {
                return .file(title: finalURL.lastPathComponent, detail: String(localized: "Open this file in its default app to view its contents."))
            }
            let isHTML = LinkPreviewHTTP.isHTML(type, prefix: text)
            if !isHTML {
                if isMarkdown, lines == nil {
                    return .markdown(title: finalURL.lastPathComponent, text: String(text.prefix(displayTextLimit)), baseURL: finalURL.deletingLastPathComponent())
                }
                guard let excerpt = LinkPreviewHTML.plainResponse(text, lines: lines, limit: 16 << 10) else {
                    return .failure(title: url.lastPathComponent, detail: String(localized: "The requested lines could not be read."))
                }
                return .text(title: url.lastPathComponent.isEmpty ? (url.host ?? url.absoluteString) : url.lastPathComponent, text: excerpt)
            }
            let content = LinkPreviewHTML.content(text, fallbackTitle: url.host ?? url.absoluteString, isHTML: true)
            guard !content.body.isEmpty else {
                return .failure(title: content.title, detail: String(localized: "The website did not provide readable text."))
            }
            return .document(title: content.title, detail: content.body, url: finalURL, isSummary: content.isSummary)
        } catch let file as LinkPreviewRemoteFile {
            return .file(title: file.url.lastPathComponent, detail: file.description)
        } catch is CancellationError {
            return .failure(title: url.host ?? url.absoluteString, detail: "")
        } catch let error as URLError where error.code == .cannotDecodeContentData {
            return .failure(title: url.host ?? url.absoluteString, detail: String(localized: "This link does not provide text to preview."))
        } catch let error as URLError {
            return .failure(title: url.host ?? url.absoluteString, detail: LinkPreviewHTTP.failureDescription(error.code))
        } catch {
            return .failure(title: url.host ?? url.absoluteString, detail: String(localized: "The website could not be reached."))
        }
    }

    nonisolated private static func boundedResponse(_ url: URL, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Zephyr Link Preview", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, text/plain, text/markdown;q=0.9", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let type = http.value(forHTTPHeaderField: "Content-Type")
        guard LinkPreviewHTTP.accepts(type) else { throw LinkPreviewRemoteFile(url: http.url ?? url, contentType: type ?? "", size: http.expectedContentLength) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count == limit { break }
        }
        return (data, http)
    }
}

private struct LinkPreviewRemoteFile: Error {
    let url: URL
    let contentType: String
    let size: Int64

    var description: String {
        let type = contentType.split(separator: ";").first.map(String.init) ?? contentType
        let metadata = size > 0 ? type + " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : type
        return metadata + "\n\n" + String(localized: "Open this file in its default app to view its contents.")
    }
}

enum LinkPreviewText {
    static func decodeUTF8(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        var leadIndex = data.count
        while leadIndex > 0, data[leadIndex - 1] & 0b1100_0000 == 0b1000_0000 { leadIndex -= 1 }
        guard leadIndex > 0 else { return nil }
        let lead = data[leadIndex - 1]
        let continuationCount = data.count - leadIndex
        let required: Int
        switch lead {
        case 0xC2...0xDF: required = 1
        case 0xE0...0xEF: required = 2
        case 0xF0...0xF4: required = 3
        default: return nil
        }
        guard continuationCount < required, continuationCount + 1 <= 3 else { return nil }
        if continuationCount > 0 {
            let first = data[leadIndex]
            guard !(lead == 0xE0 && first < 0xA0), !(lead == 0xED && first > 0x9F),
                  !(lead == 0xF0 && first < 0x90), !(lead == 0xF4 && first > 0x8F) else { return nil }
        }
        return String(data: Data(data.prefix(leadIndex - 1)), encoding: .utf8)
    }

    static func excerpt(from source: String, lines: LinkPreviewLineRange?, limit: Int) -> String? {
        guard let lines else { return String(source.prefix(limit)) }
        let all = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.start <= all.count else { return nil }
        let end = min(lines.end, all.count)
        let excerpt = (lines.start...end).map { line in
            "\(line)  \(all[line - 1])"
        }.joined(separator: "\n")
        return String(excerpt.prefix(limit))
    }
}

enum LinkPreviewLayout {
    static func cardSize(for window: NSSize, preferredWidth: CGFloat = 420, preferredHeight: CGFloat = 560) -> NSSize {
        NSSize(width: min(preferredWidth, min(640, max(0, window.width - 24))), height: min(preferredHeight, min(560, max(0, window.height - 24))))
    }

    static func availableHeight(forWidth width: CGFloat, in bounds: NSRect, anchor: NSPoint) -> CGFloat {
        let inset: CGFloat = 12, gap: CGFloat = 14
        if anchor.x + gap + width <= bounds.maxX - inset || anchor.x - gap - width >= bounds.minX + inset {
            return max(0, bounds.height - inset * 2)
        }
        return max(0, max(anchor.y - bounds.minY - inset - gap, bounds.maxY - inset - anchor.y - gap))
    }

    static func cardFrame(size: NSSize, in bounds: NSRect, anchor: NSPoint, flipped: Bool) -> NSRect {
        let inset: CGFloat = 12
        let right = anchor.x + 14
        let left = anchor.x - size.width - 14
        let x: CGFloat
        if right + size.width <= bounds.maxX - inset { x = right }
        else if left >= bounds.minX + inset { x = left }
        else { x = min(max(anchor.x - size.width / 2, bounds.minX + inset), bounds.maxX - size.width - inset) }
        let preferred = flipped ? anchor.y + 14 : anchor.y - size.height - 14
        let alternate = flipped ? anchor.y - size.height - 14 : anchor.y + 14
        let y = preferred >= bounds.minY + inset && preferred + size.height <= bounds.maxY - inset ? preferred : min(max(alternate, bounds.minY + inset), bounds.maxY - size.height - inset)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
