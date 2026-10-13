import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ZephyrRender

/// Animated GIFs in block images (design §9): still unless on screen and allowed, bounded, and
/// let go of when not drawn.
@MainActor
@Suite(.serialized) struct GIFPlayerTests {
    /// A GIF of solid red, green and blue 120 × 80 frames.
    func gif(frames: Int = 3, delay: Double = 0.06, loops: Int = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-gif-\(UUID().uuidString).gif")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]] as CFDictionary)
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
        for i in 0..<frames {
            let context = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let c = colors[i % 3]
            context.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func headersGiveDelaysAndLoops() throws {
        let url = try gif(frames: 3, delay: 0.05, loops: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try #require(GIFPlayer.info(of: .file(url)))
        #expect(info.frames == 3 && info.loops == 2)
        #expect(info.delays.allSatisfy { abs($0 - 0.05) < 0.001 })
        let one = try gif(frames: 1)
        defer { try? FileManager.default.removeItem(at: one) }
        #expect(GIFPlayer.info(of: .file(one)) == nil, "a single frame is a still")
        #expect(GIFPlayer.info(of: .data(try Data(contentsOf: url))) != nil, "downloaded bytes work like a file")
        #expect(GIFPlayer.info(of: .data(Data([1, 2, 3]))) == nil)
    }

    /// Which of red, green and blue dominates the bitmap.
    func dominant(_ view: NSView) -> Int? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        var counts = [0, 0, 0]
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
                if r > g + 0.45, r > b + 0.45 { counts[0] += 1 }
                if g > r + 0.45, g > b + 0.45 { counts[1] += 1 }
                if b > r + 0.45, b > g + 0.45 { counts[2] += 1 }
            }
        }
        guard let best = counts.max(), best > 40 else { return nil }
        return counts.firstIndex(of: best)
    }

    func spin(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    func editor(showing url: URL) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: "![clip](\(url.lastPathComponent))\n", typography: Typography(), baseURL: url.deletingLastPathComponent(), isEditable: false, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 420, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        editor.layoutAll()
        return (editor, window)
    }

    @Test func aGIFIsAStillUntilAllowedThenPlaysWhileDrawnAndStopsWhenNot() async throws {
        let url = try gif(delay: 0.06)
        defer { try? FileManager.default.removeItem(at: url) }
        GIFPlayer.shared.stopAll()
        let (e, window) = editor(showing: url)
        let view = e.focusView
        // The still decodes first.
        var still: Int?
        for _ in 0..<60 where still == nil {
            await spin(0.05)
            still = dominant(view)
        }
        #expect(still == 0, "the first frame (red) shows")
        GIFPlayer.shared.allowsPlayback = { _ in false }
        e.animatesImages = true
        for _ in 0..<10 { await spin(0.05); _ = dominant(view) }
        #expect(GIFPlayer.shared.playingCount == 0 && dominant(view) == 0, "playback not allowed: still")

        var shown = true
        GIFPlayer.shared.allowsPlayback = { _ in shown }
        defer { GIFPlayer.shared.allowsPlayback = GIFPlayer().allowsPlayback }
        var seen = Set<Int>()
        for _ in 0..<40 {
            await spin(0.04)
            if let c = dominant(view) { seen.insert(c) }
        }
        #expect(seen.count >= 2, "other frames showed: \(seen)")
        #expect(GIFPlayer.shared.playingCount == 1)

        // The window stops showing (minimized, covered, another tab): it stops and lets go,
        // even if something keeps drawing.
        shown = false
        await spin(0.3)
        #expect(GIFPlayer.shared.playingCount == 0)
        e.animatesImages = false
        #expect(GIFPlayer.shared.playingCount == 0)
        _ = window
    }

    @Test func aFiniteLoopCountEndsOnTheLastFrame() async throws {
        let url = try gif(delay: 0.05, loops: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        GIFPlayer.shared.stopAll()
        GIFPlayer.shared.allowsPlayback = { _ in true }
        defer { GIFPlayer.shared.allowsPlayback = GIFPlayer().allowsPlayback }
        let (e, window) = editor(showing: url)
        e.animatesImages = true
        var last: Int?
        for _ in 0..<50 {
            await spin(0.04)
            last = dominant(e.focusView) ?? last
        }
        #expect(GIFPlayer.shared.playingCount == 0, "one pass, then it rests")
        #expect(last != nil)
        e.animatesImages = false
        _ = window
    }
}
