import AppKit

/// Printing owns a read-only copy of the document. Layout, glyphs and components come from the
/// same canvas as the screen; pagination only chooses cuts between its measured visual lines.
@MainActor
final class PrintSheet: NSView {
    let editor: MarkdownEditor
    /// Printing defaults to white paper; themed exports set this to their page color.
    var pageBackground = NSColor.white
    private(set) var pages: [NSRect] = []

    init(_ source: MarkdownEditor) {
        editor = MarkdownEditor(text: source.string, typography: source.typography, baseURL: source.baseURL,
                                isEditable: false, canvas: source.blockCanvas.mode == .source ? .source : .block)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        editor.blockCanvas.view.appearance = appearance
        editor.blockCanvas.isPrinting = true
        editor.frontMatterCollapsed = source.frontMatterCollapsed
        paginate(size: NSSize(width: source.typography.readableWidth, height: 720))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        let scale = info.scalingFactor
        paginate(size: NSSize(width: (info.paperSize.width - info.leftMargin - info.rightMargin) / scale,
                              height: (info.paperSize.height - info.topMargin - info.bottomMargin) / scale))
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }
    override func rectForPage(_ page: Int) -> NSRect { pages[page - 1] }

    override func drawPageBorder(with borderSize: NSSize) {
        appearance?.performAsCurrentDrawingAppearance {
            pageBackground.setFill()
            NSRect(origin: .zero, size: borderSize).fill()
        }
    }

    func paginate(size: NSSize) {
        let canvas = editor.blockCanvas
        appearance?.performAsCurrentDrawingAppearance {
            canvas.scrollView.frame = NSRect(origin: .zero, size: size)
            canvas.view.frame.size.width = size.width
            canvas.widthChanged()
            canvas.layoutAll()
            canvas.prepareForOutput()
            let total = max(1, CGFloat(canvas.heights.total))
            frame = NSRect(x: 0, y: 0, width: size.width, height: total)
            pages = []
            var start: CGFloat = 0
            while start < total {
                let limit = min(start + size.height, total)
                var end = limit
                if limit < total {
                    let i = canvas.heights.unit(at: Double(limit))
                    let layout = canvas.layout(i)
                    let top = CGFloat(canvas.heights.y(of: i))
                    // Move a component intact if it can fit on a fresh page. Ordinary paragraphs
                    // may span pages, but none of their text lines is cut in half.
                    if layout.content.component != nil, layout.height <= size.height, top > start {
                        // Its gap above stays at the foot of this page.
                        end = min(top + layout.content.gap, limit)
                    } else {
                        for k in layout.tops.indices {
                            let lineTop = top + layout.tops[k]
                            if lineTop < limit, lineTop + layout.heights[k] > limit, lineTop > start {
                                end = lineTop
                                break
                            }
                        }
                    }
                }
                pages.append(NSRect(x: 0, y: start, width: size.width, height: end - start))
                start = end
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        appearance?.performAsCurrentDrawingAppearance {
            context.setFillColor(pageBackground.cgColor)
            context.fill(dirtyRect)
            context.saveGState()
            context.translateBy(x: 0, y: -BlockCanvas.topInset)
            editor.blockCanvas.draw(dirtyRect.offsetBy(dx: 0, dy: BlockCanvas.topInset), in: context)
            context.restoreGState()
        }
    }
}
