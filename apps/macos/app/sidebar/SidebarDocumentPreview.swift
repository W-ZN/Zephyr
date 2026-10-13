import AppKit
import ZephyrRender

/// A sidebar document's opening, drawn as the document draws it (headings, lists, tables,
/// formulas, diagrams), once the pointer has rested on its row: the link preview's quiet card,
/// read-only, without remote images or a scroller. It takes no pointer or keyboard events, so the
/// text keeps its focus and the window its document. Only the opening is laid out (`opening`),
/// once per rest; the card goes with the pointer.
final class SidebarDocumentPreview: SurfaceView {
    static let width: CGFloat = 340
    static let maximumHeight: CGFloat = 280
    private static let inset: CGFloat = 12

    var onHeightChanged: (() -> Void)?
    private let title = flatLabel("", size: 13, weight: .semibold)
    private let path = flatLabel("", size: 11, color: Tokens.ink3)
    private let body = PreviewClip()
    private var snippet: MarkdownSnippet?

    init() {
        super.init(fill: Tokens.raised, border: Tokens.line, radius: 8)
        path.lineBreakMode = .byTruncatingMiddle
        body.clipsToBounds = true
        for view in [title, path, body] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The text at a smaller size than the document's, in its theme, as a page's text blocks.
    private static var typography: Typography {
        var settings = AppearanceStore.shared.typography.settings
        _ = try? settings.set("text.size", "13")
        _ = try? settings.set("zoom", "1")
        return Typography(settings, css: AppearanceStore.shared.typography.css)
    }

    /// At most 4,000 characters, ended at a paragraph break where one falls in their second half,
    /// so a long document costs no more than a short one.
    static func opening(of ns: NSString) -> String {
        guard ns.length > 4000 else { return ns as String }
        let head = ns.substring(to: ns.rangeOfComposedCharacterSequence(at: 4000).location) as NSString
        let paragraph = head.range(of: "\n\n", options: .backwards)
        return paragraph.location != NSNotFound && paragraph.location > 2000 ? head.substring(to: paragraph.location) : head as String
    }

    /// `width` wide, as tall as the opening needs up to `maximumHeight`.
    func show(name: String, path: String?, markdown: String, baseURL: URL?, width: CGFloat) {
        title.stringValue = name
        self.path.stringValue = path ?? ""
        self.path.isHidden = path == nil
        snippet?.removeFromSuperview()
        let snippet = MarkdownSnippet(text: markdown, typography: Self.typography, baseURL: baseURL)
        // Diagrams and images settle after the first layout.
        snippet.onContentSizeChanged = { [weak self] in
            self?.measure()
            self?.onHeightChanged?()
        }
        body.addSubview(snippet)
        self.snippet = snippet
        setFrameSize(NSSize(width: width, height: frame.height))
        measure()
    }

    func clear() {
        snippet?.removeFromSuperview()
        snippet = nil
    }

    private func measure() {
        guard let snippet else { return }
        let inset = Self.inset, width = bounds.width - 2 * inset
        title.frame = NSRect(x: inset, y: inset, width: width, height: ceil(title.fittingSize.height))
        var top = title.frame.maxY
        if !path.isHidden {
            path.frame = NSRect(x: inset, y: top + 1, width: width, height: ceil(path.fittingSize.height))
            top = path.frame.maxY
        }
        top += 8
        snippet.frame = NSRect(x: 0, y: 0, width: width, height: max(snippet.frame.height, 1))
        snippet.needsLayout = true
        snippet.layoutSubtreeIfNeeded()
        let height = snippet.intrinsicContentSize.height
        snippet.setFrameSize(NSSize(width: width, height: height))
        body.frame = NSRect(x: inset, y: top, width: width, height: min(height, Self.maximumHeight - top - inset))
        setFrameSize(NSSize(width: bounds.width, height: body.frame.maxY + inset))
    }
}

/// Shows the opening from its top, whatever falls below the card is cut.
private final class PreviewClip: NSView {
    override var isFlipped: Bool { true }
}
