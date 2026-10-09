import AppKit
import Testing
@testable import ZephyrRender

@MainActor
@Suite struct ImageCacheTests {
    private func image(_ width: Int = 4, _ height: Int = 4) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private func key(_ name: String) -> ImageCache.Key {
        ImageCache.Key(url: URL(fileURLWithPath: "/tmp/zephyr-image-cache-\(name)"), modificationDate: nil, fileSize: nil)
    }

    private func writeImage(_ url: URL, color: NSColor) throws {
        let context = CGContext(data: nil, width: 2_048, height: 1_025, bitsPerComponent: 8,
                                bytesPerRow: 2_048 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2_048, height: 1_025))
        let data = try #require(NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    @Test func byteBudgetEvictsLeastRecentlyUsedImage() {
        let cache = ImageCache(byteLimit: 128)
        let first = key("first"), second = key("second"), third = key("third")
        cache.insert(image(), for: first)
        cache.insert(image(), for: second)
        _ = cache.image(for: first)
        cache.insert(image(), for: third)

        #expect(cache.byteCost <= 128)
        #expect(cache.image(for: first) != nil)
        #expect(cache.image(for: second) == nil, "evicted images are not retained by the cache")
        #expect(cache.image(for: third) != nil)
    }

    @Test func oversizeImageIsNeverCached() {
        let cache = ImageCache(byteLimit: 64)
        let oversized = image(5, 4)
        cache.insert(oversized, for: key("oversized"))

        #expect(ImageCache.cost(of: oversized) > 64)
        #expect(cache.count == 0)
        #expect(ImageCache.thumbnailMaxPixels == 2_048)
    }

    @Test func cancellingLastSubscriberAllowsFreshDecodeForTheSameKey() throws {
        let queue = ImageDecodeQueue(maxConcurrent: 1, startSuspended: true)
        var delivered = false
        let imageKey = key("cancel-\(UUID())")
        let id = try #require(queue.request(imageKey, url: URL(fileURLWithPath: "/tmp/not-read")) { _, _ in delivered = true })
        queue.cancel(id)
        let retry = try #require(queue.request(imageKey, url: URL(fileURLWithPath: "/tmp/not-read")) { _, _ in delivered = true })

        #expect(queue.pendingCount == 1, "a cancelled work item cannot absorb a later request for the same image")
        #expect(!delivered)
        queue.cancel(retry)
        #expect(queue.pendingCount == 0)
    }

    @Test func printedImageCacheMissDrawsSynchronously() throws {
        ImageCache.shared.removeAll()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-image-output-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            ImageCache.shared.removeAll()
            try? FileManager.default.removeItem(at: directory)
        }
        for i in 0..<3 { try writeImage(directory.appendingPathComponent("image-\(i).png"), color: .systemRed) }

        let text = (0..<3).map { "![](image-\($0).png)" }.joined(separator: "\n\n")
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: directory, isEditable: false)
        let sheet = try #require(editor.printView as? PrintSheet)
        sheet.paginate(size: NSSize(width: 500, height: 1_200))
        #expect(ImageCache.shared.byteCost <= ImageCache.byteLimit)
        let rep = try #require(sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds))
        sheet.cacheDisplay(in: sheet.bounds, to: rep)

        for i in 0..<3 {
            let location = (text as NSString).range(of: "image-\(i).png").location
            let box = try #require(sheet.editor.componentBox(at: location) as? ImageBox)
            let rect = box.drawnRect.offsetBy(dx: 0, dy: -BlockCanvas.topInset)
            let x = Int(rect.midX * CGFloat(rep.pixelsWide) / sheet.bounds.width)
            let y = rep.pixelsHigh - 1 - Int(rect.midY * CGFloat(rep.pixelsHigh) / sheet.bounds.height)
            let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent > color.greenComponent + 0.5 && color.redComponent > color.blueComponent + 0.5,
                    "printing redraws an LRU-evicted local image synchronously")
        }
    }

    @Test func pixelUpdatePreservesLayoutAndSkipsUndamagedEvictedImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-image-redraw-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            ImageCache.shared.removeAll()
            try? FileManager.default.removeItem(at: directory)
        }
        for i in 0..<2 { try writeImage(directory.appendingPathComponent("image-\(i).png"), color: .systemRed) }
        let text = "<img src=\"image-0.png\" width=\"120\">\n\n<img src=\"image-1.png\" width=\"120\">\n"
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: directory, isEditable: false)
        let canvas = editor.blockCanvas
        canvas.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        canvas.view.frame.size.width = 600
        canvas.widthChanged()
        canvas.layoutAll()
        let first = try #require(editor.componentBox(at: 0) as? ImageBox)
        let secondLocation = (text as NSString).range(of: "<img", options: .backwards).location
        let second = try #require(editor.componentBox(at: secondLocation) as? ImageBox)
        let unit = canvas.units.unit(containing: secondLocation)
        let layout = canvas.layout(unit)
        let bounds = NSRect(x: 0, y: canvas.top(of: unit) + layout.content.gap, width: 600, height: layout.height - layout.content.gap)
        let bitmap = try #require(canvas.view.bitmapImageRepForCachingDisplay(in: canvas.view.bounds))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Bitmap contexts report drawing-to-screen on this SDK; output preparation makes the
        // selected image's cache miss synchronous for this dirty-region regression.
        second.prepareForOutput()
        ImageCache.shared.removeAll()
        canvas.draw(canvas.view.bounds, in: graphics.cgContext, needsToDraw: { $0.intersects(bounds) })

        #expect(first.drawnRect.isEmpty, "the dirty bounding box must not decode an undamaged neighboring image")
        #expect(!second.drawnRect.isEmpty)
        #expect(ImageCache.shared.count == 1)
        #expect(ImageCache.shared.byteCost <= ImageCache.byteLimit)
        var updated: NSRect?
        var geometryChanges = 0
        canvas.componentPixelsChanged = { updated = $0 }
        canvas.componentChanged = { geometryChanges += 1 }
        editor.componentNeedsDisplay(second)
        #expect(updated == second.drawnRect && geometryChanges == 0)
        #expect(canvas.layout(unit) === layout, "pixel arrival preserves the already measured layout")
    }

    @Test func remoteDocumentBaseNeverResolvesItsImagesLocally() throws {
        let editor = MarkdownEditor(text: "![A](file:///private/tmp/photo.png)\n", typography: Typography(), baseURL: URL(string: "https://example.com/docs/")!, isEditable: false, canvas: .block)
        editor.layoutAll()
        let box = try #require(editor.componentBox(at: 0) as? ImageBox)
        #expect(box.viewerNaturalSize() == nil)
        #expect(box.height(in: BlockSpace(column: 400, wide: 400)) == 44)
    }
}
