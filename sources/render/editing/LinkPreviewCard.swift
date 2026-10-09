import AppKit

@MainActor
final class LinkPreviewCard: NSView {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var onAsk: ((String) -> Void)?
    var onOpen: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onSourceResigned: (() -> Void)?
    var onContentSizeChanged: (() -> Void)?
    var onPagePreview: ((URL) -> Void)?
    var onPageCancel: (() -> Void)?
    var pageURL: URL?
    var sourceDescription = ""
    private let typography: Typography
    private let title = NSTextField(labelWithString: String(localized: "Loading preview…"))
    private let detail = NSTextField(labelWithString: "")
    private let bodyScroll = NSScrollView()
    private let bodyText = LinkPreviewSourceView(frame: .zero)
    private var snippet: MarkdownSnippet?
    private var visual: LinkPreviewVisualSurface?
    private var pageSurface: LinkPreviewPageSurface?
    private var showingPage = false
    private var textContent: LinkPreviewContent?
    private var tracking: NSTrackingArea?
    private var previewContext = ""
    private var readableContent = false
    private var measuredWidth: CGFloat?
    private var measuredHeight: CGFloat = 0
    private lazy var askButton = FlatButton(title: String(localized: "Ask AI"), style: .secondary) { [weak self] in
        guard let self, !previewContext.isEmpty else { return }
        onAsk?(previewContext)
    }
    private lazy var openButton = FlatButton(title: String(localized: "Open"), style: .secondary) { [weak self] in self?.onOpen?() }
    private lazy var pageButton = FlatButton(title: String(localized: "Page snapshot"), style: .secondary) { [weak self] in
        guard let self else { return }
        if showingPage {
            onPageCancel?()
            if let textContent { show(textContent) }
        } else if let pageURL { onPagePreview?(pageURL) }
    }

    var pointerInside = false
    private static let inset: CGFloat = 14
    private static let footerHeight: CGFloat = 28
    private static let minimumHeight: CGFloat = 112
    private var titleHeight: CGFloat { ceil(max(18, title.font!.ascender - title.font!.descender + title.font!.leading)) }
    private var detailHeight: CGFloat { detail.stringValue.isEmpty ? 0 : ceil(detail.font!.ascender - detail.font!.descender + detail.font!.leading) + 4 }
    private var chromeHeight: CGFloat { Self.inset * 2 + titleHeight + detailHeight + 16 + Self.footerHeight }
    var preferredWidth: CGFloat { readableContent ? min(640, max(420, ceil(typography.bodyFont.pointSize * 34) + Self.inset * 2)) : 420 }
    var preferredMaximumHeight: CGFloat { chromeHeight + typography.lineHeight(for: typography.bodyFont, kind: .body) * 16 }

    init(size: NSSize, typography: Typography) {
        self.typography = typography
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        title.font = NSFontManager.shared.convert(typography.bodyFont, toHaveTrait: .boldFontMask)
        title.textColor = Tokens.ink
        title.lineBreakMode = .byTruncatingTail
        detail.font = NSFont(descriptor: typography.bodyFont.fontDescriptor, size: max(11, min(13, typography.bodyFont.pointSize * 0.8)))
        detail.textColor = Tokens.ink2
        detail.lineBreakMode = .byTruncatingMiddle
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.hasVerticalScroller = false
        bodyScroll.autohidesScrollers = false
        bodyText.isEditable = false
        bodyText.isSelectable = true
        bodyText.drawsBackground = false
        bodyText.textContainerInset = NSSize(width: 2, height: 2)
        bodyText.textContainer?.widthTracksTextView = false
        bodyText.onCancel = { [weak self] in self?.onDismiss?() }
        bodyText.onResignFirstResponder = { [weak self] in self?.onSourceResigned?() }
        addSubview(title)
        addSubview(detail)
        addSubview(bodyScroll)
        addSubview(askButton)
        addSubview(openButton)
        addSubview(pageButton)
        pageButton.isHidden = true
        askButton.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = Tokens.raised.cgColor
            layer.borderColor = Tokens.line.cgColor
        }
        layer.borderWidth = 1
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        title.textColor = Tokens.ink
        detail.textColor = Tokens.ink2
        updateLayer()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        onPointerEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        onPointerExited?()
    }

    func show(_ content: LinkPreviewContent) {
        textContent = content
        showingPage = false
        pageSurface = nil
        visual = nil
        bodyText.clearSourceHighlighting()
        pageButton.title = String(localized: "Page snapshot")
        pageButton.isEnabled = true
        snippet?.removeFromSuperview()
        snippet = nil
        previewContext = ""
        measuredWidth = nil
        readableContent = true
        var kind = String(localized: "Text preview")
        switch content {
        case let .markdown(name, text, baseURL, context):
            pageURL = nil
            kind = String(localized: "Rendered preview")
            title.stringValue = name
            previewContext = context
            let snippet = MarkdownSnippet(text: text, typography: typography, baseURL: baseURL)
            snippet.onContentSizeChanged = { [weak self] in
                guard let self else { return }
                measuredWidth = nil
                needsLayout = true
                onContentSizeChanged?()
            }
            self.snippet = snippet
            let host = LinkPreviewSnippetHost()
            host.addSubview(snippet)
            bodyScroll.documentView = host
        case let .website(name, text, url, summary):
            sourceDescription = url.host ?? url.absoluteString
            pageURL = url
            kind = summary ? String(localized: "Website summary") : String(localized: "Text preview")
            title.stringValue = name
            previewContext = String(text.prefix(8 << 10))
            showText(text, code: false)
        case let .visual(name, text, image, context, description):
            pageURL = nil
            title.stringValue = name
            previewContext = context
            kind = description
            showVisual(image, text: text)
        case let .text(name, text):
            pageURL = nil
            kind = String(localized: "Source excerpt")
            title.stringValue = name
            previewContext = String(text.prefix(8 << 10))
            showText(text, code: true)
        case let .file(name, message):
            pageURL = nil
            title.stringValue = name
            kind = String(localized: "File")
            readableContent = false
            showText(message, code: false)
        case let .failure(name, message):
            title.stringValue = name
            kind = ""
            readableContent = false
            showText(message, code: false)
        }
        setDetail(kind)
        title.toolTip = title.stringValue
        pageButton.isHidden = pageURL == nil
        bodyScroll.hasVerticalScroller = readableContent
        bodyScroll.contentView.scroll(to: .zero)
        askButton.isEnabled = !previewContext.isEmpty
        needsLayout = true
        onContentSizeChanged?()
    }

    func beginPageSnapshot() -> NSView {
        showingPage = true
        visual = nil
        snippet?.removeFromSuperview()
        snippet = nil
        let surface = LinkPreviewPageSurface(message: String(localized: "Rendering page…"), typography: typography)
        pageSurface = surface
        bodyScroll.documentView = surface
        bodyScroll.hasVerticalScroller = false
        readableContent = true
        measuredWidth = nil
        pageButton.title = String(localized: "Text preview")
        pageButton.isEnabled = true
        setDetail(String(localized: "Rendering page…"))
        needsLayout = true
        onContentSizeChanged?()
        superview?.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        return surface
    }

    func showPageSnapshot(_ snapshot: LinkPreviewPageRenderer.Snapshot) {
        guard let pageSurface else { return }
        pageSurface.show(snapshot.image)
        setDetail(String(localized: "Static page snapshot"))
        if !snapshot.title.isEmpty { title.stringValue = snapshot.title; title.toolTip = snapshot.title }
        if !snapshot.text.isEmpty { previewContext = snapshot.text }
        askButton.isEnabled = !previewContext.isEmpty
        pageButton.isEnabled = true
        measuredWidth = nil
        needsLayout = true
        onContentSizeChanged?()
    }

    func showPageFailure(_ message: String) {
        pageSurface?.removeFromSuperview()
        // Retain the text-mode payload, so returning from a failed render restores useful content.
        pageSurface = nil
        setDetail("")
        readableContent = false
        bodyScroll.documentView = bodyText
        showText(message, code: false)
        pageButton.isEnabled = true
        measuredWidth = nil
        needsLayout = true
        onContentSizeChanged?()
    }

    func fittingHeight(forWidth width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let limit = max(0, maxHeight)
        guard bodyScroll.documentView != nil else { return min(Self.minimumHeight, limit) }
        let frameSize = NSSize(width: max(0, width - Self.inset * 2), height: limit)
        let contentSize = NSScrollView.contentSize(forFrameSize: frameSize, horizontalScrollerClass: nil, verticalScrollerClass: bodyScroll.hasVerticalScroller ? NSScroller.self : nil, borderType: .noBorder, controlSize: .regular, scrollerStyle: bodyScroll.scrollerStyle)
        let bodyHeight = measureBody(at: contentSize.width)
        return min(limit, max(Self.minimumHeight, chromeHeight + bodyHeight))
    }

    private func measureBody(at width: CGFloat) -> CGFloat {
        if measuredWidth == width { return measuredHeight }
        measuredWidth = width
        if pageSurface != nil, readableContent {
            measuredHeight = ceil(width * 0.625)
        } else if let visual {
            measuredHeight = visual.height(for: width)
        } else if let snippet {
            snippet.frame.size.width = width
            snippet.layoutSubtreeIfNeeded()
            measuredHeight = ceil(snippet.intrinsicContentSize.height)
        } else {
            bodyText.textContainer?.containerSize = NSSize(width: max(0, width - bodyText.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
            if let container = bodyText.textContainer {
                bodyText.layoutManager?.ensureLayout(for: container)
                measuredHeight = ceil(bodyText.layoutManager?.usedRect(for: container).height ?? 0) + bodyText.textContainerInset.height * 2
            } else {
                measuredHeight = 0
            }
        }
        return measuredHeight
    }

    private func setDetail(_ kind: String) {
        detail.stringValue = [sourceDescription, kind].filter { !$0.isEmpty }.joined(separator: " · ")
        detail.toolTip = detail.stringValue
    }

    private func showVisual(_ image: NSImage, text: String) {
        let visual = LinkPreviewVisualSurface(image: image, text: text, typography: typography)
        self.visual = visual
        bodyScroll.documentView = visual
    }

    private func showText(_ text: String, code: Bool) {
        if code {
            bodyText.setSource(text, filename: title.stringValue, typography: typography)
            bodyScroll.documentView = bodyText
            return
        }
        bodyText.clearSourceHighlighting()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let font = typography.bodyFont
        let lineHeight = typography.lineHeight(for: font, kind: .body)
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.paragraphSpacing = lineHeight * 0.5
        let body = NSMutableAttributedString()
        body.append(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: Tokens.ink,
            .paragraphStyle: paragraph,
        ]))
        bodyText.textStorage?.setAttributedString(body)
        bodyScroll.documentView = bodyText
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - Self.inset * 2)
        title.frame = NSRect(x: Self.inset, y: Self.inset, width: width, height: titleHeight)
        detail.frame = NSRect(x: Self.inset, y: title.frame.maxY + 4, width: width, height: max(0, detailHeight - 4))
        let footerY = bounds.maxY - Self.inset - Self.footerHeight
        if !pageButton.isHidden {
            pageButton.frame = NSRect(x: Self.inset, y: footerY, width: min(pageButton.intrinsicContentSize.width, max(0, width - openButton.intrinsicContentSize.width - 8)), height: Self.footerHeight)
        }
        openButton.frame = NSRect(x: bounds.maxX - Self.inset - openButton.intrinsicContentSize.width, y: footerY, width: openButton.intrinsicContentSize.width, height: Self.footerHeight)
        let askLeft = pageButton.isHidden ? Self.inset : pageButton.frame.maxX + 8
        let askWidth = min(askButton.intrinsicContentSize.width, max(0, openButton.frame.minX - 8 - askLeft))
        askButton.frame = NSRect(x: openButton.frame.minX - 8 - askWidth, y: footerY, width: askWidth, height: Self.footerHeight)
        let bodyTop = title.frame.maxY + detailHeight + 8
        bodyScroll.frame = NSRect(x: Self.inset, y: bodyTop, width: width, height: max(0, footerY - bodyTop - 8))
        if let pageSurface, readableContent {
            pageSurface.frame = NSRect(origin: .zero, size: bodyScroll.contentSize)
        } else if let visual {
            visual.frame = NSRect(origin: .zero, size: NSSize(width: bodyScroll.contentSize.width, height: max(bodyScroll.contentSize.height, measureBody(at: bodyScroll.contentSize.width))))
        } else if let snippet {
            let bodyWidth = bodyScroll.contentSize.width
            let height = max(bodyScroll.contentSize.height, measureBody(at: bodyWidth))
            snippet.frame = NSRect(x: 0, y: 0, width: bodyWidth, height: height)
            bodyScroll.documentView?.frame = NSRect(x: 0, y: 0, width: bodyWidth, height: height)
        } else if bodyScroll.documentView === bodyText {
            let bodyWidth = bodyScroll.contentSize.width
            bodyText.frame = NSRect(x: 0, y: 0, width: bodyWidth, height: max(bodyScroll.contentSize.height, measureBody(at: bodyWidth)))
        }
    }
}

@MainActor
private final class LinkPreviewPageSurface: NSView {
    private let cover = NSBox()
    private let imageView = NSImageView()
    private let message: NSTextField

    init(message: String, typography: Typography) {
        self.message = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Tokens.raised.cgColor
        layer?.masksToBounds = true
        cover.boxType = .custom
        cover.borderWidth = 0
        cover.titlePosition = .noTitle
        cover.fillColor = Tokens.raised
        addSubview(cover)
        self.message.font = typography.bodyFont
        self.message.textColor = Tokens.ink
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isHidden = true
        addSubview(imageView)
        addSubview(self.message)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    // Consume input without forwarding it to either the temporary browser or the document below.
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    func show(_ image: NSImage) { imageView.image = image; imageView.isHidden = false; message.isHidden = true }
    override func layout() {
        super.layout()
        cover.frame = bounds
        imageView.frame = bounds
        message.frame = bounds.insetBy(dx: 10, dy: 10)
    }
}

@MainActor
private final class LinkPreviewSnippetHost: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class LinkPreviewOverlay: NSView {
    let card: LinkPreviewCard
    private var anchor: NSPoint

    init(frame: NSRect, card: LinkPreviewCard, anchor: NSPoint) {
        self.card = card
        self.anchor = anchor
        super.init(frame: frame)
        addSubview(card)
        placeCard(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setAnchor(_ anchor: NSPoint) {
        self.anchor = anchor
        needsLayout = true
    }

    func contentChanged() {
        placeCard(animated: true)
    }

    func animateIn() {
        layoutSubtreeIfNeeded()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            card.alphaValue = 1
            return
        }
        card.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            card.animator().alphaValue = 1
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard card.frame.contains(local) else { return nil }
        return card.hitTest(local) ?? card
    }

    override func layout() {
        super.layout()
        placeCard(animated: false)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let end: NSPoint
        if anchor.x < card.frame.minX {
            end = NSPoint(x: card.frame.minX, y: min(max(anchor.y, card.frame.minY + 10), card.frame.maxY - 10))
        } else if anchor.x > card.frame.maxX {
            end = NSPoint(x: card.frame.maxX, y: min(max(anchor.y, card.frame.minY + 10), card.frame.maxY - 10))
        } else {
            end = NSPoint(x: min(max(anchor.x, card.frame.minX + 10), card.frame.maxX - 10), y: anchor.y < card.frame.minY ? card.frame.minY : card.frame.maxY)
        }
        let line = NSBezierPath()
        line.move(to: anchor)
        line.line(to: end)
        line.lineWidth = 1
        Tokens.line.setStroke()
        line.stroke()
    }

    private func placeCard(animated: Bool) {
        let maximum = LinkPreviewLayout.cardSize(for: bounds.size, preferredWidth: card.preferredWidth, preferredHeight: card.preferredMaximumHeight)
        let availableHeight = LinkPreviewLayout.availableHeight(forWidth: maximum.width, in: bounds, anchor: anchor)
        let height = card.fittingHeight(forWidth: maximum.width, maxHeight: min(maximum.height, availableHeight))
        let size = NSSize(width: maximum.width, height: height)
        let frame = LinkPreviewLayout.cardFrame(size: size, in: bounds, anchor: anchor, flipped: isFlipped)
        let change = max(abs(frame.height - card.frame.height), abs(frame.minY - card.frame.minY))
        if animated, change >= 4, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Lay out at the final width once; only height/position change during the animation.
            card.setFrameSize(NSSize(width: frame.width, height: card.frame.height))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.animator().frame = frame
            }
        } else {
            card.frame = frame
        }
        needsDisplay = true
    }
}
