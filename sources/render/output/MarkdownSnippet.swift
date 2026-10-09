import AppKit

/// A piece of Markdown drawn by the block canvas, read-only, as tall as its text and as wide as
/// it is placed (the text blocks of a page, design §8.3): tables, formulas, diagrams and lists look
/// as they do in a document, without a scroll view of their own.
@MainActor
public final class MarkdownSnippet: NSView {
    public var onContentSizeChanged: (() -> Void)?
    private let editor: MarkdownEditor
    private var laidOut: CGFloat = -1
    private var height: CGFloat = 0

    public init(text: String, typography: Typography, baseURL: URL?) {
        editor = MarkdownEditor(text: text, typography: typography, baseURL: baseURL, isEditable: false, canvas: .block)
        super.init(frame: .zero)
        editor.blockCanvas.fillsWidth = true
        // Geometry changes need measurement; decoded image pixels only need their own region.
        editor.blockCanvas.componentChanged = { [weak self] in
            guard let self else { return }
            laidOut = -1
            needsLayout = true
            needsDisplay = true
            onContentSizeChanged?()
        }
        editor.blockCanvas.componentPixelsChanged = { [weak self] rect in
            self?.setNeedsDisplay(rect.offsetBy(dx: 0, dy: -BlockCanvas.topInset))
        }
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    public override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, abs(width - laidOut) > 0.5 else { return }
        laidOut = width
        let canvas = editor.blockCanvas
        canvas.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        canvas.view.frame.size.width = width
        canvas.widthChanged()
        canvas.layoutAll()
        let measured = ceil(CGFloat(canvas.heights.total))
        if abs(measured - height) > 0.5 {
            height = measured
            invalidateIntrinsicContentSize()
        }
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: -BlockCanvas.topInset)
        editor.blockCanvas.draw(dirtyRect.offsetBy(dx: 0, dy: BlockCanvas.topInset), in: context, fillsBackground: false,
                               needsToDraw: { self.needsToDraw($0.offsetBy(dx: 0, dy: -BlockCanvas.topInset)) })
        context.restoreGState()
    }
}
