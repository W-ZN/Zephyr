import AppKit
import Testing
import ZephyrCore
@testable import ZephyrRender

@MainActor
@Suite struct ComponentMenuTests {
    @Test func imageAndDiagramMenusKeepOnlyCopyAndSaveActions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-component-menu-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = try #require(NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("photo.png"))

        let imageSource = "# Image\n\n![A](photo.png)\n"
        let imageEditor = MarkdownEditor(text: imageSource, typography: Typography(), baseURL: folder, isEditable: true, canvas: .block)
        let imageWindow = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        imageWindow.isReleasedWhenClosed = false
        imageWindow.contentView = imageEditor.scrollView
        imageEditor.select(NSRange(location: 0, length: 0))
        imageEditor.layoutAll()
        let imageView = imageEditor.blockCanvas.view
        if let rep = imageView.bitmapImageRepForCachingDisplay(in: imageView.bounds) { imageView.cacheDisplay(in: imageView.bounds, to: rep) }
        let imageLocation = (imageSource as NSString).range(of: "!").location
        let image = try #require(imageEditor.componentBox(at: imageLocation) as? ImageBox)
        let imageMenu = imageEditor.contextMenu(at: NSPoint(x: image.drawnRect.midX, y: image.drawnRect.midY), base: nil)
        #expect(imageMenu?.items.map(\.title) == [String(localized: "Copy image Markdown"), String(localized: "Save image…")])

        let diagramSource = "# Diagram\n\n```mermaid\nflowchart TD\n  A --> B\n```\n"
        let diagramEditor = MarkdownEditor(text: diagramSource, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let diagramWindow = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        diagramWindow.isReleasedWhenClosed = false
        diagramWindow.contentView = diagramEditor.scrollView
        diagramEditor.select(NSRange(location: 0, length: 0))
        diagramEditor.layoutAll()
        let diagramView = diagramEditor.blockCanvas.view
        if let rep = diagramView.bitmapImageRepForCachingDisplay(in: diagramView.bounds) { diagramView.cacheDisplay(in: diagramView.bounds, to: rep) }
        let diagramLocation = (diagramSource as NSString).range(of: "```").location
        let diagram = try #require(diagramEditor.componentBox(at: diagramLocation) as? DiagramBox)
        let diagramMenu = diagramEditor.contextMenu(at: NSPoint(x: diagram.drawnRect.midX, y: diagram.drawnRect.midY), base: nil)
        #expect(diagramMenu?.items.map(\.title) == [String(localized: "Copy Mermaid source"), String(localized: "Save image…")])
    }
}
