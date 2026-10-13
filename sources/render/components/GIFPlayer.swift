import AppKit
import ImageIO

/// Plays an animated GIF in a block image (design §9) without making the reader pay for it.
/// A GIF is a still (its first frame, decoded and cached like any image) until it is drawn on
/// screen in an active app; then at most `maximumPlaying` of them run, each holding two frames
/// at the drawn size and decoding the next one on a background queue. One that is not drawn for
/// a moment (scrolled away, another document, a minimized window) stops and lets go of its
/// frames; Reduce Motion, Low Power Mode and the Settings switch keep every GIF still. Print and
/// export never ask: they draw the first frame.
@MainActor
final class GIFPlayer {
    static let shared = GIFPlayer()
    nonisolated static let maximumPlaying = 2
    /// Longer GIFs stay stills: decoding runs strictly in order, so a long one costs the most.
    nonisolated static let maximumFrames = 600
    /// Frames decode no larger than this on the long side, whatever the screen.
    nonisolated static let maximumPixels = 1024
    /// A GIF that was not drawn for this long is not on screen any more.
    nonisolated static let idleLimit: TimeInterval = 0.6

    enum Source {
        case file(URL)
        case data(Data)
    }

    struct Info: Equatable {
        var delays: [TimeInterval]
        /// How many times it plays; 0 is forever.
        var loops: Int
        var frames: Int { delays.count }
    }

    /// Whether `box`'s GIF may move right now: the app is active and its window shows (not
    /// minimized, covered or hidden), and neither Reduce Motion nor Low Power Mode is on.
    /// Replaced in tests.
    var allowsPlayback: (ComponentBox) -> Bool = { box in
        NSApp.isActive && box.context?.isShowing != false
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Reads frames with one decoder at a time, in order (random access re-decodes from the
    /// start). Used only on the player's queue.
    private final class FrameDecoder: @unchecked Sendable {
        private var source: CGImageSource?
        private var next = 0
        private let make: () -> CGImageSource?

        init(_ make: @escaping () -> CGImageSource?) { self.make = make }

        func frame(_ index: Int, pixels: Int) -> CGImage? {
            // Back to the first frame: a new source decodes it at once instead of rewinding.
            if source == nil || index != next { source = make(); next = 0 }
            guard let source else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            // A frame in sequence continues the decoder; one out of order starts over from the first.
            var image: CGImage?
            while next <= index {
                image = CGImageSourceCreateThumbnailAtIndex(source, next, options as CFDictionary)
                next += 1
            }
            return image
        }
    }

    private final class Session {
        let info: Info
        let pixels: Int
        let decoder: FrameDecoder
        weak var box: ComponentBox?
        var index = 0
        var loops = 0
        var current: CGImage?
        var prefetched: CGImage?
        var decoding = false
        var lastDrawn = Date()
        var timer: Timer?
        /// The loop count ran out: the last frame stays.
        var finished = false

        init(info: Info, pixels: Int, decoder: FrameDecoder, box: ComponentBox) {
            self.info = info
            self.pixels = pixels
            self.decoder = decoder
            self.box = box
        }
    }

    private var sessions: [ObjectIdentifier: Session] = [:]
    private var stills: Set<String> = []
    private let queue = DispatchQueue(label: "Zephyr GIF frames", qos: .utility)

    var playingCount: Int { sessions.values.filter { !$0.finished }.count }

    // MARK: Reading

    /// Frame delays and loop count of an animated GIF; nil for anything that is not one (a still,
    /// another format, too many frames). Reads only the headers.
    nonisolated static func info(of source: Source) -> Info? {
        guard let image = makeSource(source), CGImageSourceGetCount(image) > 1, CGImageSourceGetCount(image) <= maximumFrames,
              let type = CGImageSourceGetType(image), (type as String) == "com.compuserve.gif" else { return nil }
        let loops = ((CGImageSourceCopyProperties(image, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int ?? 0
        let delays = (0..<CGImageSourceGetCount(image)).map { i -> TimeInterval in
            let gif = (CGImageSourceCopyPropertiesAtIndex(image, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
            // Browsers treat a delay under 20 ms as 100 ms: such files expect it.
            return delay < 0.02 ? 0.1 : delay
        }
        return Info(delays: delays, loops: loops)
    }

    private nonisolated static func makeSource(_ source: Source) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        switch source {
        case let .file(url): return CGImageSourceCreateWithURL(url as CFURL, options)
        case let .data(data): return CGImageSourceCreateWithData(data as CFData, options)
        }
    }

    // MARK: Drawing side

    /// The frame to draw now for `box`, or nil to draw the still. Drawing counts as being seen:
    /// it starts a GIF that is not running (when allowed) and keeps a running one alive.
    func frame(for box: ComponentBox, key: String, source: @autoclosure () -> Source, drawn size: CGSize) -> CGImage? {
        let id = ObjectIdentifier(box)
        if let session = sessions[id] {
            session.lastDrawn = Date()
            return session.current
        }
        guard !stills.contains(key), allowsPlayback(box), playingCount < Self.maximumPlaying else { return nil }
        let source = source()
        guard let info = Self.info(of: source) else {
            if stills.count > 512 { stills.removeAll() }
            stills.insert(key)
            return nil
        }
        let pixels = min(ImageCache.pixels(for: size), Self.maximumPixels)
        let decoder = FrameDecoder { Self.makeSource(source) }
        let session = Session(info: info, pixels: pixels, decoder: decoder, box: box)
        sessions[id] = session
        prune()
        prefetch(session, id: id)
        schedule(session, id: id)
        return nil
    }

    /// Lets go of what a closed or edited-away document left behind.
    private func prune() {
        for (id, session) in sessions where session.box == nil { stop(id) }
    }

    // MARK: Running

    private func schedule(_ session: Session, id: ObjectIdentifier, after delay: TimeInterval? = nil) {
        session.timer?.invalidate()
        let wait = delay ?? session.info.delays[session.index]
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(id) }
        }
        // Common modes: scrolling the document must not freeze the picture.
        RunLoop.main.add(timer, forMode: .common)
        session.timer = timer
    }

    private func prefetch(_ session: Session, id: ObjectIdentifier) {
        guard !session.decoding else { return }
        session.decoding = true
        let target = (session.index + 1) % session.info.frames
        let decoder = session.decoder, pixels = session.pixels
        queue.async { [weak self] in
            let image = decoder.frame(target, pixels: pixels)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let session = self?.sessions[id] else { return }
                    session.decoding = false
                    session.prefetched = image
                }
            }
        }
    }

    private func tick(_ id: ObjectIdentifier) {
        guard let session = sessions[id], let box = session.box,
              Date().timeIntervalSince(session.lastDrawn) < Self.idleLimit, allowsPlayback(box) else { return stop(id) }
        guard let next = session.prefetched else {
            // The decoder is behind: try again shortly rather than skip ahead.
            return schedule(session, id: id, after: 0.03)
        }
        session.prefetched = nil
        session.index = (session.index + 1) % session.info.frames
        if session.index == 0 {
            session.loops += 1
            if session.info.loops > 0, session.loops >= session.info.loops {
                session.finished = true
                session.timer = nil
                session.current = next
                box.context?.componentNeedsDisplay(box)
                return
            }
        }
        session.current = next
        prefetch(session, id: id)
        box.context?.componentNeedsDisplay(box)
        schedule(session, id: id)
    }

    func stop(_ id: ObjectIdentifier) {
        sessions.removeValue(forKey: id)?.timer?.invalidate()
    }

    func stopAll() {
        for id in Array(sessions.keys) { stop(id) }
    }
}
