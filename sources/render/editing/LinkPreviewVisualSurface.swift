import AppKit

/// A bounded first-page/image preview. The source document is never embedded or made editable.
@MainActor
final class LinkPreviewVisualSurface: NSView {
    private let imageView = NSImageView()
    private let textView = NSTextView()
    private let hasText: Bool

    init(image: NSImage, text: String, typography: Typography) {
        hasText = !text.isEmpty
        super.init(frame: .zero)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = typography.lineHeight(for: typography.bodyFont, kind: .body)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: typography.bodyFont, .foregroundColor: Tokens.ink, .paragraphStyle: paragraph,
        ]))
        addSubview(imageView)
        if hasText { addSubview(textView) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func imageHeight(for width: CGFloat) -> CGFloat {
        guard let image = imageView.image else { return 0 }
        return min(320, ceil(width * image.size.height / max(1, image.size.width)))
    }

    func height(for width: CGFloat) -> CGFloat {
        guard hasText, let container = textView.textContainer else { return imageHeight(for: width) }
        container.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: container)
        let textHeight = ceil(textView.layoutManager?.usedRect(for: container).height ?? 0)
        return imageHeight(for: width) + 12 + textHeight
    }

    override func layout() {
        super.layout()
        let imageHeight = imageHeight(for: bounds.width)
        imageView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: imageHeight)
        if hasText {
            textView.frame = NSRect(x: 0, y: imageHeight + 12, width: bounds.width, height: max(0, height(for: bounds.width) - imageHeight - 12))
        }
    }
}
