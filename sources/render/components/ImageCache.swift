import AppKit
import ImageIO

/// Decoded local-image pixels shared by every rendered document. Image headers stay with their
/// components; this cache is the only long-lived owner of decoded pixels.
@MainActor
final class ImageCache {
    struct Key: Hashable {
        let url: URL
        let modificationDate: Date?
        let fileSize: Int?
        /// The long side the pixels decode to: the cache's largest by default, the drawn size for
        /// images in HTML blocks and lines of text.
        var maxPixels = ImageCache.thumbnailMaxPixels
    }

    /// The decode size for an image drawn `size` points large on a 2× screen, rounded up to a
    /// step so that small changes of the column do not decode it again.
    nonisolated static func pixels(for size: CGSize) -> Int {
        let needed = max(size.width, size.height) * 2
        guard needed.isFinite, needed < CGFloat(thumbnailMaxPixels) else { return thumbnailMaxPixels }
        return [256, 512, 768, 1024, 1536].first { CGFloat($0) >= needed } ?? thumbnailMaxPixels
    }

    /// The largest side an image may be laid out at, in points: generous for long infographics,
    /// small enough that no size arithmetic overflows.
    nonisolated static let maximumSide: CGFloat = 20_000

    /// `size` no taller than `maximumSide`, its proportions kept (a long, thin strip of pixels).
    nonisolated static func capped(_ size: CGSize) -> CGSize {
        guard size.height > maximumSide else { return size }
        return CGSize(width: size.width * maximumSide / size.height, height: maximumSide)
    }

    nonisolated static let byteLimit = 16 << 20
    /// Four bytes per pixel makes a square 2,048 px thumbnail fit the global byte budget.
    nonisolated static let thumbnailMaxPixels = Int(sqrt(Double(byteLimit) / 4))
    static let shared = ImageCache()

    private struct Entry {
        let image: CGImage
        let cost: Int
        var lastUse: Int
    }

    private let limit: Int
    private var entries: [Key: Entry] = [:]
    private var clock = 0
    private(set) var byteCost = 0

    init(byteLimit: Int = ImageCache.byteLimit) {
        limit = byteLimit
    }

    func image(for key: Key) -> CGImage? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.image
    }

    func insert(_ image: CGImage, for key: Key) {
        let cost = Self.cost(of: image)
        guard cost <= limit else { return }
        if let old = entries.removeValue(forKey: key) { byteCost -= old.cost }
        while byteCost + cost > limit, let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            entries.removeValue(forKey: victim.key)
            byteCost -= victim.value.cost
        }
        clock += 1
        entries[key] = Entry(image: image, cost: cost, lastUse: clock)
        byteCost += cost
    }

    func removeAll() {
        entries.removeAll()
        byteCost = 0
    }

    var count: Int { entries.count }

    static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    nonisolated static func decode(_ url: URL, maxPixels: Int = thumbnailMaxPixels) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, thumbnailMaxPixels),
        ]
        return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary)
        }
    }
}

/// A small, coalescing decode queue. Its callbacks capture boxes weakly, so styled chunks that are
/// no longer retained cannot keep a decode or a decoded image alive.
@MainActor
final class ImageDecodeQueue {
    static let shared = ImageDecodeQueue()
    private static let maximumQueued = 32

    private final class DecodeOperation: Operation, @unchecked Sendable {
        let url: URL
        let maxPixels: Int
        var consume: ((CGImage?) -> Void)?

        init(url: URL, maxPixels: Int) {
            self.url = url
            self.maxPixels = maxPixels
        }

        override func main() {
            guard !isCancelled else { return }
            let image = ImageCache.decode(url, maxPixels: maxPixels)
            guard !isCancelled else { return }
            // Keep this worker occupied until the main actor either accepts or drops the image.
            // Otherwise completed operations can accumulate full thumbnails while the main thread is busy.
            DispatchQueue.main.sync { [weak self] in
                guard let self, !self.isCancelled else { return }
                consume?(image)
            }
        }
    }

    private final class Work {
        let key: ImageCache.Key
        let token = UUID()
        let operation: DecodeOperation
        let sequence: Int
        var subscribers: [UUID: (CGImage?, Bool) -> Void] = [:]

        init(key: ImageCache.Key, url: URL, sequence: Int) {
            self.key = key
            operation = DecodeOperation(url: url, maxPixels: key.maxPixels)
            self.sequence = sequence
        }
    }

    private let queue: OperationQueue
    private var works: [ImageCache.Key: Work] = [:]
    private var requestKeys: [UUID: ImageCache.Key] = [:]
    private var sequence = 0

    init(maxConcurrent: Int = 2, startSuspended: Bool = false) {
        queue = OperationQueue()
        queue.name = "Zephyr image decode"
        queue.maxConcurrentOperationCount = maxConcurrent
        queue.isSuspended = startSuspended
    }

    var pendingCount: Int { works.count }

    func request(_ key: ImageCache.Key, url: URL, completion: @escaping (CGImage?, Bool) -> Void) -> UUID? {
        if let image = ImageCache.shared.image(for: key) {
            completion(image, true)
            return nil
        }
        let id = UUID()
        if let work = works[key] {
            work.subscribers[id] = completion
            requestKeys[id] = key
            return id
        }

        sequence += 1
        let work = Work(key: key, url: url, sequence: sequence)
        work.subscribers[id] = completion
        requestKeys[id] = key
        let token = work.token
        work.operation.consume = { [weak self, weak operation = work.operation, key, token] image in
            guard operation?.isCancelled != true else { return }
            self?.finish(key, token: token, image: image)
        }
        works[key] = work
        queue.addOperation(work.operation)
        trimQueuedWork()
        return id
    }

    func cancel(_ id: UUID) {
        guard let key = requestKeys.removeValue(forKey: id), let work = works[key] else { return }
        work.subscribers.removeValue(forKey: id)
        guard work.subscribers.isEmpty else { return }
        work.operation.cancel()
        works.removeValue(forKey: key)
    }

    private func finish(_ key: ImageCache.Key, token: UUID, image: CGImage?) {
        guard let work = works[key], work.token == token else { return }
        works.removeValue(forKey: key)
        let subscribers = work.subscribers
        for id in subscribers.keys { requestKeys.removeValue(forKey: id) }
        if let image { ImageCache.shared.insert(image, for: key) }
        for completion in subscribers.values { completion(image, true) }
    }

    private func trimQueuedWork() {
        var queued = works.values.filter { !$0.operation.isExecuting && !$0.operation.isFinished }
        while queued.count > Self.maximumQueued, let work = queued.min(by: { $0.sequence < $1.sequence }) {
            queued.removeAll { $0 === work }
            work.operation.cancel()
            works.removeValue(forKey: work.key)
            for (id, completion) in work.subscribers {
                requestKeys.removeValue(forKey: id)
                completion(nil, false)
            }
        }
    }
}
