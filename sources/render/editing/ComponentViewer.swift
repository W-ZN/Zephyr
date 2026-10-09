import AppKit

/// A single native inspection surface for decoded local images and Zephyr-drawn diagrams. It keeps
/// only the component's bounded image cache entry or vector scene; it never creates a second bitmap.
@MainActor
final class ComponentViewer: NSView {
    var onClose: (() -> Void)?
    private let box: ComponentBox
    private let naturalSize: CGSize
    private let enterSource: () -> Void
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var dragOrigin: CGPoint?
    private var panOrigin = CGPoint.zero
    private var viewerLoad: UUID?
    private let allowsSourceEditing: Bool
    let backdrop: NSVisualEffectView = ComponentViewerBackdrop()
    private let content = ComponentViewerContent()

    var zoomScale: CGFloat { zoom }
    var panOffset: CGPoint { pan }

    init(box: ComponentBox, frame: NSRect, allowsSourceEditing: Bool = true, enterSource: @escaping () -> Void) {
        self.box = box
        naturalSize = box.viewerNaturalSize() ?? .zero
        self.enterSource = enterSource
        self.allowsSourceEditing = allowsSourceEditing
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.blendingMode = .withinWindow
        backdrop.material = .hudWindow
        backdrop.state = .active
        backdrop.alphaValue = 0.78
        addSubview(backdrop)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        content.viewer = self
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    var contentAlpha: CGFloat { content.alphaValue }

    func show(in host: NSView) {
        frame = host.bounds
        host.addSubview(self)
        host.window?.makeFirstResponder(self)
        fit()
        requestViewerLoad()
    }

    override func layout() {
        super.layout()
        zoom = max(zoom, minimumZoom)
        clampPan()
    }

    fileprivate func drawContent() {
        guard naturalSize.width > 0, naturalSize.height > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let origin = contentOrigin()
        ctx.saveGState()
        ctx.clip(to: viewportRect)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: zoom, y: zoom)
        box.drawViewer(in: ctx)
        ctx.restoreGState()
        requestViewerLoad()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard contentRect.contains(point) else { dismiss(); return }
        if event.clickCount >= 2, allowsSourceEditing {
            enterSource()
            dismiss()
            return
        }
        dragOrigin = point
        panOrigin = pan
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        pan = CGPoint(x: panOrigin.x + point.x - dragOrigin.x, y: panOrigin.y + point.y - dragOrigin.y)
        clampPan()
        content.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard viewportRect.contains(point) else { return }
        let factor = Self.scrollFactor(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, inverted: event.isDirectionInvertedFromDevice)
        zoom(to: zoom * factor, anchoredAt: point)
    }

    static func scrollFactor(deltaY: CGFloat, precise: Bool, inverted: Bool) -> CGFloat {
        // Natural scrolling reverses content deltas; zoom follows the physical gesture instead.
        let delta = inverted ? -deltaY : deltaY
        return pow(1.0015, delta * (precise ? 1 : 12))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismiss()
            return
        }
        super.keyDown(with: event)
    }

    private func fit() {
        zoom = minimumZoom
        pan = .zero
        content.needsDisplay = true
    }

    @objc func dismiss() {
        cancelViewerLoad()
        removeFromSuperview()
        onClose?()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { cancelViewerLoad() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    private func requestViewerLoad() {
        guard viewerLoad == nil, box.viewerNeedsLoad() else { return }
        viewerLoad = box.requestViewerLoad { [weak self] _ in
            guard let self else { return }
            self.viewerLoad = nil
            guard self.superview != nil else { return }
            self.content.needsDisplay = true
        }
    }

    private func cancelViewerLoad() {
        guard let viewerLoad else { return }
        box.cancelViewerLoad(viewerLoad)
        self.viewerLoad = nil
    }

    func zoom(to value: CGFloat, anchoredAt point: CGPoint) {
        let oldOrigin = contentOrigin()
        let local = CGPoint(x: (point.x - oldOrigin.x) / zoom, y: (point.y - oldOrigin.y) / zoom)
        zoom = min(max(value, minimumZoom), 8)
        let centered = centeredOrigin()
        pan = CGPoint(x: point.x - local.x * zoom - centered.x, y: point.y - local.y * zoom - centered.y)
        clampPan()
        content.needsDisplay = true
    }

    func pan(by delta: CGPoint) {
        pan = CGPoint(x: pan.x + delta.x, y: pan.y + delta.y)
        clampPan()
        content.needsDisplay = true
    }

    private func centeredOrigin() -> CGPoint {
        CGPoint(x: viewportRect.midX - naturalSize.width * zoom / 2, y: viewportRect.midY - naturalSize.height * zoom / 2)
    }

    var viewportRect: NSRect {
        NSRect(x: 24, y: 24, width: max(1, bounds.width - 48), height: max(1, bounds.height - 48))
    }

    /// The actual visible component. The surrounding visual-effect view is only the blurred
    /// document backdrop; there is no panel between it and the image or diagram.
    var contentRect: NSRect {
        NSRect(origin: contentOrigin(), size: CGSize(width: naturalSize.width * zoom, height: naturalSize.height * zoom)).intersection(viewportRect)
    }

    private var minimumZoom: CGFloat {
        min(1, min(viewportRect.width / naturalSize.width, viewportRect.height / naturalSize.height))
    }

    private func contentOrigin() -> CGPoint {
        let centered = centeredOrigin()
        return CGPoint(x: centered.x + pan.x, y: centered.y + pan.y)
    }

    private func clampPan() {
        let size = CGSize(width: naturalSize.width * zoom, height: naturalSize.height * zoom)
        let x = max(0, (size.width - viewportRect.width) / 2)
        let y = max(0, (size.height - viewportRect.height) / 2)
        pan.x = min(max(pan.x, -x), x)
        pan.y = min(max(pan.y, -y), y)
    }
}

/// A user-requested component export is a bounded, one-shot bitmap. It is separate from the
/// viewer, which only ever references the shared image cache entry.
@MainActor
enum ComponentPNG {
    static let maximumPixels = 2_048

    enum Error: LocalizedError {
        case unsupported, sourceImage

        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "This component cannot be saved as an image.")
            case .sourceImage: String(localized: "Choose a different file from the source image.")
            }
        }
    }

    static func png(for box: ComponentBox) throws -> Data {
        guard let renderContext = box.context else { throw Error.unsupported }
        let snapshot = ComponentBox.make(box.kind, fontSize: renderContext.typography.fontSize, context: renderContext)
        snapshot.prepareForOutput()
        guard let natural = snapshot.viewerNaturalSize(), natural.width > 0, natural.height > 0, !snapshot.viewerNeedsLoad() else { throw Error.unsupported }
        let scale = min(1, CGFloat(maximumPixels) / max(natural.width, natural.height))
        let width = max(1, Int((natural.width * scale).rounded(.up)))
        let height = max(1, Int((natural.height * scale).rounded(.up)))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { throw Error.unsupported }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let graphicsContext = graphics.cgContext
        graphicsContext.translateBy(x: 0, y: CGFloat(height))
        graphicsContext.scaleBy(x: 1, y: -1)
        graphicsContext.scaleBy(x: scale, y: scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: graphicsContext, flipped: true)
        snapshot.drawViewer(in: graphicsContext)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Error.unsupported }
        return data
    }

    static func write(_ box: ComponentBox, to output: URL) throws {
        if let image = box as? ImageBox, image.isSourceImage(at: output) { throw Error.sourceImage }
        try png(for: box).write(to: output, options: .atomic)
    }
}

/// The backdrop and direct component drawing pass events through to the viewer, whose coordinates
/// match this full-size surface.
@MainActor
private final class ComponentViewerBackdrop: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class ComponentViewerContent: NSView {
    weak var viewer: ComponentViewer?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { viewer?.drawContent() }
}
