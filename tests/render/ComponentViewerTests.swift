import AppKit
import Testing
import ZephyrCore
@testable import ZephyrRender

@MainActor
@Suite struct ComponentViewerTests {
    private func image(at url: URL, width: Int = 800, height: Int = 400) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = try #require(NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func thumbnail() -> CGImage {
        let context = CGContext(data: nil, width: 2_048, height: 2_048, bitsPerComponent: 8,
                                bytesPerRow: 2_048 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private func editor(_ text: String, folder: URL, typography: Typography = Typography()) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: typography, baseURL: folder, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        editor.layoutAll()
        let view = editor.blockCanvas.view
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
        return (editor, window)
    }

    private func rendersComponent(_ editor: MarkdownEditor, at location: Int) -> Bool {
        let unit = editor.blockCanvas.units.unit(containing: location)
        if case .component = editor.blockCanvas.layout(unit).content.body { return true }
        return false
    }

    @Test func resizeConvertsMarkdownThenUndoRedoRestoresExactSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("photo.png")
        try image(at: imageURL)
        let originalBytes = try Data(contentsOf: imageURL)
        let original = "# Top\n\n![A photo](photo.png)\n\nafter\n"
        let (editor, window) = editor(original, folder: folder)
        let imageLocation = (original as NSString).range(of: "!").location
        let box = try #require(editor.componentBox(at: imageLocation) as? ImageBox)
        editor.select(NSRange(location: 0, length: 0))

        let initialWidth = box.displayedWidth
        editor.previewImageResize(box, width: 240)
        let view = editor.blockCanvas.view
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
        editor.commitImageResize(box, initialWidth: initialWidth)
        #expect(editor.string == "# Top\n\n<img src=\"photo.png\" alt=\"A photo\" width=\"240\">\n\nafter\n")
        #expect(editor.blockCanvas.focusedComponent?.location == imageLocation && rendersComponent(editor, at: imageLocation))
        window.undoManager?.undo()
        #expect(editor.string == original)
        #expect(!editor.showsPlainText && editor.blockCanvas.focusedComponent?.location == imageLocation && rendersComponent(editor, at: imageLocation))
        window.undoManager?.redo()
        #expect(editor.string.contains("width=\"240\""))
        #expect(!editor.showsPlainText && editor.blockCanvas.focusedComponent?.location == imageLocation && rendersComponent(editor, at: imageLocation))
        #expect(try Data(contentsOf: imageURL) == originalBytes, "resizing changes only the in-memory Markdown until a document save")
    }

    @Test func resizePreservesAHardLineBreakImageAltAsAnImageComponent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))
        let (editor, _) = editor("![foo  \nbar](photo.png)\n", folder: folder)
        let box = try #require(editor.componentBox(at: 0) as? ImageBox)
        let alt = box.alt

        let initialWidth = box.displayedWidth
        editor.previewImageResize(box, width: 180)
        editor.commitImageResize(box, initialWidth: initialWidth)
        let image = try #require(MarkdownAnalyzer.safeHTMLImage(editor.string))
        #expect(image.alt == alt && image.width == 180)
        #expect(MarkdownAnalyzer.analyze(editor.string).components.contains { $0.kind == .image(source: "photo.png", alt: alt, width: 180) })
    }

    @Test func resizeUndoRedoKeepsTheShiftedImageRenderedAfterAnExternalEdit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))
        let original = "![A](photo.png)\n"
        let (editor, window) = editor(original, folder: folder)
        let image = try #require(editor.componentBox(at: 0) as? ImageBox)
        editor.previewImageResize(image, width: 180)
        editor.commitImageResize(image, initialWidth: image.displayedWidth)
        let prefix = "before\n\n"
        editor.blockCanvas.replaceExternally(NSRange(location: 0, length: 0), with: prefix)

        window.undoManager?.undo()
        #expect(editor.string == prefix + original)
        #expect(editor.blockCanvas.focusedComponent?.location == (prefix as NSString).length && rendersComponent(editor, at: (prefix as NSString).length))
        window.undoManager?.redo()
        #expect(editor.string == prefix + "<img src=\"photo.png\" alt=\"A\" width=\"180\">\n")
        #expect(editor.blockCanvas.focusedComponent?.location == (prefix as NSString).length && rendersComponent(editor, at: (prefix as NSString).length))
    }

    @Test func clickingTheResizeGripDoesNotChangeSourceOrUndo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))
        let original = "![A](photo.png)\n"
        let (editor, window) = editor(original, folder: folder)
        let box = try #require(editor.componentBox(at: 0) as? ImageBox)
        let view = editor.blockCanvas.view
        let point = CGPoint(x: box.resizeRect.midX, y: box.resizeRect.midY)
        let location = view.convert(point, to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))

        view.mouseDown(with: down)
        view.mouseUp(with: up)
        #expect(editor.string == original)
        window.undoManager?.undo()
        #expect(editor.string == original)

        let tiny = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: location.x + 0.25, y: location.y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        let tinyUp = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: location.x + 0.25, y: location.y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0))
        view.mouseDown(with: down)
        view.mouseDragged(with: tiny)
        view.mouseUp(with: tinyUp)
        #expect(editor.string == original)
        #expect(box.height(in: BlockSpace(column: 1_000, wide: 1_000)) == 400)

        let wider = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: location.x + 20, y: location.y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 1))
        let back = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        view.mouseDragged(with: wider)
        view.mouseDragged(with: back)
        view.mouseUp(with: up)
        #expect(editor.string == original)
    }

    @Test func resizingCommitsAnOpenTableCellBeforeTakingTheImage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))
        let original = "| a |\n|---|\n| 1 |\n\n<img src=\"photo.png\" alt=\"A\" width=\"120\">\n"
        let (editor, window) = editor(original, folder: folder)
        let table = try #require(editor.componentBox(at: 0) as? TableBox)
        let imageLocation = (original as NSString).range(of: "<img").location
        editor.beginCellEdit(table, row: 1, column: 0)
        editor.cellField?.stringValue = "edited"
        editor.layoutAll()
        let view = editor.blockCanvas.view
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
        let image = try #require(editor.componentBox(at: imageLocation) as? ImageBox)

        let point = CGPoint(x: image.resizeRect.midX, y: image.resizeRect.midY)
        let resize = try #require(editor.beginImageResize(at: point))
        editor.previewImageResize(resize.image, width: resize.width + 20)
        editor.commitImageResize(resize.image, initialWidth: resize.width)
        #expect(editor.string.contains("edited"))
        #expect(editor.string.contains("width=\"140\""))
        window.undoManager?.undo()
        #expect(!(editor.string.contains("edited") && editor.string.contains("width=\"140\"")))
        window.undoManager?.undo()
        #expect(editor.string.contains("| 1 |") && editor.string.contains("width=\"120\""))
    }

    @Test func sourceIdentityKeepsTheFirstOfDuplicateImagesAfterALaterFieldEdit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))
        let markup = "<img src=\"photo.png\" alt=\"A\" width=\"120\">"
        let original = "\(markup)\n\n\(markup)\n\n| a |\n|---|\n| 1 |\n"
        let (editor, _) = editor(original, folder: folder)
        let first = try #require(editor.componentBox(at: 0) as? ImageBox)
        let tableLocation = (original as NSString).range(of: "| a |").location
        let table = try #require(editor.componentBox(at: tableLocation) as? TableBox)
        editor.beginCellEdit(table, row: 1, column: 0)
        editor.cellField?.stringValue = String(repeating: "later ", count: 100)

        let resize = try #require(editor.beginImageResize(at: CGPoint(x: first.resizeRect.midX, y: first.resizeRect.midY)))
        editor.previewImageResize(resize.image, width: resize.width + 20)
        editor.commitImageResize(resize.image, initialWidth: resize.width)
        let firstRange = (editor.string as NSString).range(of: markup.replacingOccurrences(of: "120", with: "140"))
        #expect(firstRange.location == 0)
        let secondStart = NSMaxRange(firstRange)
        let secondRange = (editor.string as NSString).range(of: markup, options: [], range: NSRange(location: secondStart, length: (editor.string as NSString).length - secondStart))
        #expect(secondRange.location != NSNotFound)
    }

    @Test func viewerZoomAndPanStayBounded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))
        let (editor, _) = editor("![A](photo.png)\n", folder: folder)
        let box = try #require(editor.componentBox(at: 0) as? ImageBox)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let viewer = ComponentViewer(box: box, frame: host.bounds, enterSource: {})
        viewer.show(in: host)
        let initial = viewer.zoomScale
        viewer.zoom(to: 1, anchoredAt: NSPoint(x: 200, y: 150))
        viewer.pan(by: NSPoint(x: 10_000, y: 10_000))

        #expect(viewer.zoomScale > initial)
        #expect(viewer.viewportRect.size == NSSize(width: 352, height: 252))
        #expect(viewer.panOffset == NSPoint(x: 224, y: 74))
    }

    @Test func resizeOnlyChangesWidthInStrictHTMLImage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))
        let original = "<img alt=\"width='old'\" src='photo.png' width='120' />\n"
        let (editor, _) = editor(original, folder: folder)
        let box = try #require(editor.componentBox(at: 0) as? ImageBox)

        let initialWidth = box.displayedWidth
        editor.previewImageResize(box, width: 180)
        editor.commitImageResize(box, initialWidth: initialWidth)
        #expect(editor.string == "<img alt=\"width='old'\" src='photo.png' width='180' />\n")
    }

    @Test func resizeInsertsWidthBeforeASelfClosingSlash() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))
        let (editor, _) = editor("<img src='photo.png' alt='A' />\n", folder: folder)
        let box = try #require(editor.componentBox(at: 0) as? ImageBox)

        let initialWidth = box.displayedWidth
        editor.previewImageResize(box, width: 180)
        editor.commitImageResize(box, initialWidth: initialWidth)
        #expect(editor.string == "<img src='photo.png' alt='A' width=\"180\"/>\n")
    }

    @Test func resizeKeepsBalancedAndPercentEncodedMarkdownDestinations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo (1).png"))
        let (editor, _) = editor("![photo (1)](photo%20(1).png)\n", folder: folder)
        let box = try #require(editor.componentBox(at: 0) as? ImageBox)

        let initialWidth = box.displayedWidth
        editor.previewImageResize(box, width: 180)
        editor.commitImageResize(box, initialWidth: initialWidth)
        #expect(editor.string == "<img src=\"photo%20(1).png\" alt=\"photo (1)\" width=\"180\">\n")
    }

    @Test func viewerQueuesReloadOfAnImageEvictedFromTheBoundedCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.png")
        let second = folder.appendingPathComponent("second.png")
        try image(at: first)
        try image(at: second)
        let firstValues = try first.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let secondValues = try second.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let firstKey = ImageCache.Key(url: first, modificationDate: firstValues.contentModificationDate, fileSize: firstValues.fileSize)
        let secondKey = ImageCache.Key(url: second, modificationDate: secondValues.contentModificationDate, fileSize: secondValues.fileSize)
        ImageCache.shared.removeAll()
        defer { ImageCache.shared.removeAll() }
        ImageCache.shared.insert(thumbnail(), for: firstKey)
        ImageCache.shared.insert(thumbnail(), for: secondKey)
        #expect(ImageCache.shared.image(for: firstKey) == nil)

        let (editor, _) = editor("![A](first.png)\n", folder: folder)
        let box = try #require(editor.componentBox(at: 0) as? ImageBox)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let viewer = ComponentViewer(box: box, frame: host.bounds, enterSource: {})
        viewer.show(in: host)
        let rep = try #require(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
        for _ in 0..<600 where ImageCache.shared.image(for: firstKey) == nil {
            viewer.cacheDisplay(in: viewer.bounds, to: rep)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(ImageCache.shared.image(for: firstKey) != nil)
        viewer.cacheDisplay(in: viewer.bounds, to: rep)
    }

    @Test func failedViewerDecodeMarksTheImageMissingWithoutRetrying() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("photo.png")
        try image(at: url)
        let (editor, _) = editor("![A](photo.png)\n", folder: folder)
        let box = try #require(editor.componentBox(at: 0) as? ImageBox)
        #expect(box.viewerNaturalSize() != nil)
        ImageCache.shared.removeAll()
        try FileManager.default.removeItem(at: url)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let viewer = ComponentViewer(box: box, frame: host.bounds, enterSource: {})
        viewer.show(in: host)
        for _ in 0..<100 where box.viewerNeedsLoad() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(!box.viewerNeedsLoad())
        let rep = try #require(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
        viewer.cacheDisplay(in: viewer.bounds, to: rep)
        #expect(!box.viewerNeedsLoad())
    }

    @Test func readonlyAndTitledImagesDoNotOfferAResizeGrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))

        let readonly = MarkdownEditor(text: "![A](photo.png)\n", typography: Typography(), baseURL: folder, isEditable: false, canvas: .block)
        readonly.layoutAll()
        let readonlyBox = try #require(readonly.componentBox(at: 0) as? ImageBox)
        readonly.updateImageResizeHover(at: CGPoint(x: readonlyBox.resizeRect.midX, y: readonlyBox.resizeRect.midY))
        #expect(!readonlyBox.resizeHandleVisible)

        let (titled, _) = editor("![A](photo.png \"caption\")\n", folder: folder)
        let titledBox = try #require(titled.componentBox(at: 0) as? ImageBox)
        titled.updateImageResizeHover(at: CGPoint(x: titledBox.resizeRect.midX, y: titledBox.resizeRect.midY))
        #expect(titled.imageResize(at: CGPoint(x: titledBox.resizeRect.midX, y: titledBox.resizeRect.midY)) == nil)
        #expect(!titledBox.resizeHandleVisible)
        titledBox.setResizeHandleVisible(true)
        #expect(!titledBox.shouldDrawResizeGrip(drawingToScreen: false))
    }

    @Test func viewerReturnsFocusToTheCanvasForEscapeAndSourceEditing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))
        let original = "![A](photo.png)\n"
        let (editor, window) = editor(original, folder: folder)
        let first = try #require(editor.componentBox(at: 0) as? ImageBox)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!editor.handleClick(at: CGPoint(x: first.drawnRect.midX, y: first.drawnRect.midY), event: event))
        #expect(window.contentView?.subviews.contains { $0 is ComponentViewer } == false)
        #expect(editor.openComponentViewer(first))
        let escaped = try #require(window.contentView?.subviews.compactMap { $0 as? ComponentViewer }.last)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        escaped.keyDown(with: escape)
        #expect(window.firstResponder === editor.focusView)
        #expect(editor.componentBox(at: 0) is ImageBox)

        #expect(editor.openComponentViewer(first))
        let inspected = try #require(window.contentView?.subviews.compactMap { $0 as? ComponentViewer }.last)
        let center = inspected.convert(NSPoint(x: inspected.viewportRect.midX, y: inspected.viewportRect.midY), to: nil)
        let doubleClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        inspected.mouseDown(with: doubleClick)
        #expect(editor.selectedRange.location == NSMaxRange(first.lastKnownRange))
        #expect(window.firstResponder === editor.focusView)
        editor.type(" ")
        #expect(editor.string == "![A](photo.png) \n")
        window.undoManager?.undo()
        #expect(editor.string == original)
    }

    @Test func explicitViewerFitsAPartialRegionAndBackdropClickDismisses() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"))
        let original = "![A](photo.png)\n"
        let (editor, window) = editor(original, folder: folder)
        let box = try #require(editor.componentBox(at: 0) as? ImageBox)
        let view = editor.blockCanvas.view
        let center = NSPoint(x: box.drawnRect.midX, y: box.drawnRect.midY)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(center, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        #expect(editor.blockCanvas.focusedComponent == box.lastKnownRange)
        #expect(window.contentView?.subviews.contains { $0 is ComponentViewer } == false)
        #expect(editor.openSelectedComponentViewer())
        let viewer = try #require(window.contentView?.subviews.compactMap { $0 as? ComponentViewer }.last)
        #expect(viewer.backdrop.blendingMode == .withinWindow && viewer.backdrop.state == .active)
        #expect(viewer.backdrop.alphaValue == 0.78 && viewer.contentAlpha == 1)
        #expect(viewer.viewportRect.width < viewer.bounds.width && viewer.viewportRect.height < viewer.bounds.height)
        let target = NSPoint(x: viewer.viewportRect.midX, y: viewer.viewportRect.midY)
        viewer.zoom(to: 2, anchoredAt: target)
        viewer.pan(by: NSPoint(x: 100, y: 80))
        #expect(viewer.zoomScale == 2 && viewer.panOffset != .zero)
        let outside = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: viewer.convert(NSPoint(x: 2, y: 2), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        viewer.mouseDown(with: outside)
        #expect(viewer.superview == nil)
        #expect(window.firstResponder === editor.focusView)
        #expect(editor.string == original && rendersComponent(editor, at: 0))
    }

    @Test func imageAlignmentPersistsThroughUndoRedoAndChangesInlineGeometry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"), width: 200, height: 100)
        let original = "![A](photo.png)\n"
        var settings = AppearanceSettings()
        try settings.set("image.align", "left")
        let (editor, window) = editor(original, folder: folder, typography: Typography(settings))
        let image = try #require(editor.componentBox(at: 0) as? ImageBox)
        let leftEdge = image.drawnRect.minX

        editor.setImageAlignment(image, to: .center)
        #expect(editor.string == "<img src=\"photo.png\" alt=\"A\" align=\"center\">\n")
        editor.layoutAll()
        let view = editor.blockCanvas.view
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
        let centered = try #require(editor.componentBox(at: 0) as? ImageBox)
        #expect(centered.explicitAlignment == .center && centered.alignment == .center && centered.drawnRect.minX > leftEdge)
        window.undoManager?.undo()
        #expect(editor.string == original)
        window.undoManager?.redo()
        #expect(editor.string.contains("align=\"center\"") && editor.componentBox(at: 0) is ImageBox)
    }

    @Test func imageThemeDefaultCentersMarkdownTitlesAndHTMLOverridesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"), width: 200, height: 100)
        let source = "![Titled](photo.png \"Cover\")\n\n<img src=\"photo.png\" alt=\"Left\" align=\"left\">\n"
        let (centered, centerWindow) = editor(source, folder: folder)
        defer { centerWindow.close() }
        let markdownImage = try #require(centered.componentBox(at: 0) as? ImageBox)
        let htmlImage = try #require(centered.componentBox(at: (source as NSString).range(of: "<img").location) as? ImageBox)
        #expect(markdownImage.explicitAlignment == nil && markdownImage.alignment == .center)
        #expect(markdownImage.drawnRect.minX > centered.blockCanvas.columnX)
        #expect(htmlImage.explicitAlignment == .left && htmlImage.drawnRect.minX == centered.blockCanvas.columnX)

        var leftSettings = AppearanceSettings()
        try leftSettings.set("image.align", "left")
        let (left, leftWindow) = editor(source, folder: folder, typography: Typography(leftSettings))
        defer { leftWindow.close() }
        let leftMarkdownImage = try #require(left.componentBox(at: 0) as? ImageBox)
        #expect(leftMarkdownImage.explicitAlignment == nil && leftMarkdownImage.alignment == .left)
        #expect(leftMarkdownImage.drawnRect.minX == left.blockCanvas.columnX)
        #expect(left.string == source)
    }

    @Test func componentPNGIsBoundedToTheSharedImageLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try image(at: folder.appendingPathComponent("photo.png"), width: 4_096, height: 2_048)
        let (editor, _) = editor("![A](photo.png)\n", folder: folder)
        let image = try #require(editor.componentBox(at: 0) as? ImageBox)
        let data = try ComponentPNG.png(for: image)
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == ComponentPNG.maximumPixels && rep.pixelsHigh == ComponentPNG.maximumPixels / 2)
    }

    @Test func componentPNGSavesDiagramPixelsAndKeepsLiveImagesOutOfOutputMode() throws {
        let diagramEditor = MarkdownEditor(text: "```mermaid\nflowchart TD\n  A --> B\n```\n", typography: Typography(), baseURL: nil, isEditable: false, canvas: .block)
        diagramEditor.layoutAll()
        let diagram = try #require(diagramEditor.componentBox(at: 0) as? DiagramBox)
        let diagramData = try ComponentPNG.png(for: diagram)
        let diagramRep = try #require(NSBitmapImageRep(data: diagramData))
        var hasVisiblePixel = false
        for y in stride(from: 0, to: diagramRep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: diagramRep.pixelsWide, by: 4) {
                if (diagramRep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                    hasVisiblePixel = true
                    break
                }
            }
            if hasVisiblePixel { break }
        }
        #expect(hasVisiblePixel)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo.png")
        try image(at: source)
        let (editor, _) = editor("![A](photo.png)\n", folder: folder)
        let image = try #require(editor.componentBox(at: 0) as? ImageBox)
        #expect(!image.preparingOutput)
        _ = try ComponentPNG.png(for: image)
        #expect(!image.preparingOutput)
        #expect(throws: ComponentPNG.Error.self) { try ComponentPNG.write(image, to: source) }
    }

    @Test func componentPNGRejectsAnImageWhosePixelsBecomeUnavailableAfterHeaderRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-viewer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo.png")
        try image(at: source)
        ImageCache.shared.removeAll()
        defer { ImageCache.shared.removeAll() }
        let (editor, _) = editor("![A](photo.png)\n", folder: folder)
        let image = try #require(editor.componentBox(at: 0) as? ImageBox)
        #expect(image.viewerNaturalSize() != nil)
        try FileManager.default.removeItem(at: source)
        #expect(ImageCache.decode(source) == nil)
        #expect(throws: ComponentPNG.Error.self) { try ComponentPNG.png(for: image) }
    }

}
