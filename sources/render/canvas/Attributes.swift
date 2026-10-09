import AppKit
import ZephyrCore

extension NSAttributedString.Key {
    /// Syntax marker removed from display text unless the caret reveals it.
    static let zHide = NSAttributedString.Key("zephyr.hide")
    /// Container prefix (`>`, list indentation): replaced by indents.
    static let zStructural = NSAttributedString.Key("zephyr.structural")
    /// List bullet / number / checkbox: drawn by the canvas.
    static let zListMarker = NSAttributedString.Key("zephyr.listMarker")
    /// Rendered component (math, table, image, rule, front matter).
    static let zComponent = NSAttributedString.Key("zephyr.component")
    static let zCodeBlock = NSAttributedString.Key("zephyr.codeBlock")
    static let zInlineCode = NSAttributedString.Key("zephyr.inlineCode")
    static let zLink = NSAttributedString.Key("zephyr.link")
    /// Per-line vertical metrics and decoration (`LineMetrics`).
    static let zLine = NSAttributedString.Key("zephyr.line")
}

/// Vertical metrics of one source line. The canvas centers glyphs within these line boxes,
/// keeping a paragraph's rhythm consistent across Latin and CJK fallback fonts.
public final class LineMetrics: NSObject {
    public enum Kind: Equatable { case body, heading, code, blank, fence, setextUnderline, component }

    public let kind: Kind
    public let lineHeight: CGFloat
    /// Padding inside a block (indented code), added to the block gap of design §8.1.
    public let spacingBefore: CGFloat
    public let spacingAfter: CGFloat
    /// Heading level for heading lines and setext underlines, 0 otherwise.
    public let headingLevel: Int
    /// First line of a Markdown block: block spacing goes above it (or onto the blank line before it).
    public let startsBlock: Bool
    public let isListItem: Bool
    public let startsList: Bool
    /// Primary font ascent and descent (descent positive).
    public let ascent: CGFloat
    public let descent: CGFloat
    /// Height kept by a collapsed line: fences keep the code block padding, setext underlines vanish.
    public let collapsedHeight: CGFloat
    public let quoteDepth: Int
    public let listDepth: Int
    /// Left indent of the text, used to place bullets and quote bars.
    public let indent: CGFloat

    init(kind: Kind, font: NSFont, lineHeight: CGFloat, spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0,
         collapsedHeight: CGFloat = 0, quoteDepth: Int, listDepth: Int, indent: CGFloat,
         headingLevel: Int = 0, startsBlock: Bool = false, isListItem: Bool = false, startsList: Bool = false) {
        self.kind = kind
        self.lineHeight = lineHeight
        self.spacingBefore = spacingBefore
        self.spacingAfter = spacingAfter
        self.headingLevel = headingLevel
        self.startsBlock = startsBlock
        self.isListItem = isListItem
        self.startsList = startsList
        ascent = font.ascender
        descent = -font.descender
        self.collapsedHeight = collapsedHeight
        self.quoteDepth = quoteDepth
        self.listDepth = listDepth
        self.indent = indent
    }

    /// Code, fences, HTML and block components: separated from neighbours by the block gap.
    var isBlockLike: Bool { kind == .code || kind == .fence || kind == .component }

    // Value equality: restyling compares attributes and leaves equal runs untouched.
    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? LineMetrics else { return false }
        return kind == o.kind && lineHeight == o.lineHeight && spacingBefore == o.spacingBefore && spacingAfter == o.spacingAfter
            && headingLevel == o.headingLevel && startsBlock == o.startsBlock && isListItem == o.isListItem && startsList == o.startsList
            && ascent == o.ascent && descent == o.descent && collapsedHeight == o.collapsedHeight
            && quoteDepth == o.quoteDepth && listDepth == o.listDepth && indent == o.indent
    }

    public override var hash: Int { Int(lineHeight * 64) ^ (headingLevel << 8) ^ (listDepth << 12) ^ (quoteDepth << 16) }
}

extension NSRange {
    /// This range after a text edit (`editedRange` in new coordinates, `delta` the change in
    /// length), or nil when the edit touched it or the range was already unknown.
    func shifted(byEdit editedRange: NSRange, delta: Int) -> NSRange? {
        guard location != NSNotFound else { return nil }
        if NSMaxRange(self) <= editedRange.location { return self }
        if location >= NSMaxRange(editedRange) - delta { return NSRange(location: location + delta, length: length) }
        return nil
    }
}

/// Menu item that runs a closure, for menus built on the fly.
public final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    public init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    public required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

final class ListMarkerBox: NSObject {
    enum Kind: Hashable { case bullet(depth: Int), ordinal(String), checkbox(checked: Bool) }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    override func isEqual(_ object: Any?) -> Bool { (object as? ListMarkerBox)?.kind == kind }
    override var hash: Int { kind.hashValue }
}

final class CodeBlockBox: NSObject {
    let language: String?
    let isFenced: Bool
    init(language: String?, isFenced: Bool) {
        self.language = language
        self.isFenced = isFenced
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CodeBlockBox else { return false }
        return language == o.language && isFenced == o.isFenced
    }
    override var hash: Int { language.hashValue ^ (isFenced ? 1 : 0) }

    /// A code block's background in the theme's style, the same in both canvases: a tint, a tint
    /// with a hairline border (card), a hairline outline, or nothing.
    static func drawBackground(_ rect: NSRect, style: Typography.CodeStyle, scale: CGFloat) {
        let radius: CGFloat = style == .card ? 8 : 6
        if style == .shaded || style == .card {
            Palette.codeBackground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        guard style == .card || style == .outline else { return }
        let width = style == .card ? 1 : 1 / scale
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), xRadius: radius - width / 2, yRadius: radius - width / 2)
        border.lineWidth = width
        (style == .card ? Palette.codeBorder : Palette.rule).setStroke()
        border.stroke()
    }
}
