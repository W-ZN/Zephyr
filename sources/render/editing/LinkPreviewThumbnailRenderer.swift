import AppKit
import QuickLookThumbnailing

/// Produces a Quick Look document thumbnail for a local link-preview card.
@MainActor
final class LinkPreviewThumbnailRenderer {
    static let fileSizeLimit = 16 << 20

    enum Failure: Error {
        case tooLarge
        case unavailable
        case timedOut
    }

    private static weak var active: LinkPreviewThumbnailRenderer?
    private var continuation: CheckedContinuation<NSImage, Error>?
    private var request: QLThumbnailGenerator.Request?
    private var requestID: UUID?
    private var deadline: DispatchWorkItem?

    func render(_ url: URL) async throws -> NSImage {
        try Task.checkCancellation()
        try preflight(url)

        Self.active?.cancel()
        Self.active = self

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: NSSize(width: 1_024, height: 1_024),
                    scale: 1,
                    representationTypes: .thumbnail
                )
                request.iconMode = false
                self.continuation = continuation
                self.request = request
                let requestID = UUID()
                self.requestID = requestID

                let deadline = DispatchWorkItem { [weak self] in
                    guard let self, self.requestID == requestID else { return }
                    self.finish(.failure(Failure.timedOut))
                }
                self.deadline = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: deadline)

                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == requestID, self.continuation != nil else { return }
                        guard let representation, representation.type == .thumbnail else {
                            self.finish(.failure(Failure.unavailable))
                            return
                        }
                        self.finish(.success(representation.nsImage))
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        })
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func preflight(_ url: URL) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw Failure.unavailable
        }
        guard values.isRegularFile == true, let size = values.fileSize else { throw Failure.unavailable }
        guard size <= Self.fileSizeLimit else { throw Failure.tooLarge }
    }

    private func finish(_ result: Result<NSImage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let request = self.request
        self.request = nil
        requestID = nil
        deadline?.cancel()
        deadline = nil
        if let request { QLThumbnailGenerator.shared.cancel(request) }
        if Self.active === self { Self.active = nil }
        continuation.resume(with: result)
    }
}
