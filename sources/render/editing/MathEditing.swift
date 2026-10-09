import AppKit
import ZephyrCore

/// Renders a formula scaled to fit, for the attached editor's live preview.
final class MathPreviewView: NSView {
    var tex = "" { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 19
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let formula = MathRenderer.shared.formula(tex, display: true)
        let area = bounds.insetBy(dx: 16, dy: 12)
        if tex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        if let error = formula.error {
            let text = NSAttributedString(string: error, attributes: [.font: Tokens.font(12), .foregroundColor: Tokens.danger])
            text.draw(with: area, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        }
        let size = formula.size(fontSize: fontSize)
        let height = size.ascent + size.descent
        let scale = min(1, area.width / max(size.width, 1), area.height / max(height, 1))
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: area.midX - size.width * scale / 2, y: area.midY - height * scale / 2)
        ctx.scaleBy(x: scale, y: scale)
        MathRenderer.shared.draw(formula, at: .zero, fontSize: fontSize, color: Tokens.ink, in: ctx)
        ctx.restoreGState()
    }
}

/// The attached formula editor: a floating card under the display math with a live preview and the
/// TeX source. The formula in the document keeps its size until the edit is committed (design §8):
/// ⌘↩ or clicking outside commits, Escape cancels.
final class MathEditorController: NSViewController, NSTextViewDelegate {
    let source: NSTextView
    private let preview = MathPreviewView()
    private let scroll = NSScrollView()
    private var cancelled = false
    var commit: ((String) -> Void)?

    init(tex: String) {
        source = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 80))
        super.init(nibName: nil, bundle: nil)
        source.string = tex
        preview.tex = tex
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        source.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        source.textColor = Tokens.ink
        source.insertionPointColor = Tokens.accent
        source.isRichText = false
        source.allowsUndo = true
        source.isAutomaticQuoteSubstitutionEnabled = false
        source.isAutomaticDashSubstitutionEnabled = false
        source.isAutomaticTextReplacementEnabled = false
        source.isAutomaticSpellingCorrectionEnabled = false
        source.textContainerInset = NSSize(width: 8, height: 8)
        source.drawsBackground = false
        source.delegate = self
        source.isVerticallyResizable = true
        source.autoresizingMask = [.width]
        source.setAccessibilityLabel(String(localized: "Formula source"))
        scroll.documentView = source
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let rule = SurfaceView(fill: Tokens.line, border: nil, radius: 0)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let hint = flatLabel(String(localized: "⌘↩ to apply · Esc to cancel"), size: 11, color: Tokens.ink3)
        let done = FlatButton(title: String(localized: "Done"), style: .primary)
        done.target = self
        done.action = #selector(done(_:))
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = [.command]

        let bar = NSStackView(views: [hint, NSView(), done])
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        let stack = NSStackView(views: [preview, rule, scroll, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.setHuggingPriority(.required, for: .vertical)
        for v in [preview, scroll, bar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        // Preferred sizes, not fixed ones: on a small screen the card shrinks, the source first
        // (it scrolls), then the preview.
        func preferred(_ c: NSLayoutConstraint, _ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
            c.priority = priority
            return c
        }
        NSLayoutConstraint.activate([
            preferred(stack.widthAnchor.constraint(equalToConstant: 460), .defaultHigh),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            preferred(preview.heightAnchor.constraint(equalToConstant: previewHeight()), .defaultHigh - 1),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            preferred(scroll.heightAnchor.constraint(equalToConstant: min(180, max(64, CGFloat(source.string.components(separatedBy: "\n").count) * 17 + 18))), .defaultHigh - 2),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            bar.heightAnchor.constraint(equalToConstant: 42),
        ])
        view = stack
    }

    private func previewHeight() -> CGFloat {
        let formula = MathRenderer.shared.formula(preview.tex, display: true)
        guard formula.error == nil else { return 56 }
        let size = formula.size(fontSize: preview.fontSize)
        return min(160, max(56, ceil(size.ascent + size.descent) + 24))
    }

    func textDidChange(_ notification: Notification) {
        preview.tex = source.string
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelled = true
        card?.close()
        return true
    }

    @objc private func done(_ sender: Any?) {
        card?.close()
    }

    weak var card: FloatingCard?

    func cardDidClose() {
        if !cancelled { commit?(source.string) }
        commit = nil
    }
}

extension MarkdownEditor {
    /// The display formula on the row under `point`: on it or beside it (a formula is narrow and
    /// centered; a click next to it means it too).
    func mathBlock(at point: NSPoint) -> MathBlockBox? {
        guard isEditable else { return nil }
        if let (box, _) = blockComponent(at: point) { return box as? MathBlockBox }
        guard let unit = blockCanvas.unit(at: point), let box = unit.layout.content.component as? MathBlockBox,
              point.y >= box.drawnRect.minY - 4, point.y <= box.drawnRect.maxY + 4 else { return nil }
        return box
    }

    /// The formula's TeX as edited, and the container prefix its lines carry.
    func mathSource(_ box: MathBlockBox) -> (tex: String, prefix: String)? {
        guard let range = source(of: box) else { return nil }
        let ns = source
        let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let prefix = ns.substring(with: NSRange(location: line.location, length: range.location - line.location))
        return MathEdit.tex(in: ns.substring(with: range), prefix: prefix).map { ($0, prefix) }
    }

    /// Write `tex` inside the formula's delimiters as one undoable minimal edit.
    func commitMath(_ box: MathBlockBox, tex: String, prefix: String) {
        guard let range = source(of: box) else { return }
        let old = source.substring(with: range)
        guard let replaced = MathEdit.replacingTeX(in: old, with: tex, prefix: prefix, newline: newline),
              let patch = TextPatch.minimal(from: old, to: replaced) else { return }
        // The caret stays where it was, outside the formula, which stays drawn.
        let kept = selection
        replace(NSRange(location: range.location + patch.range.location, length: patch.range.length), with: patch.replacement)
        let delta = (replaced as NSString).length - range.length
        if NSMaxRange(kept) <= range.location { selection = kept } else if kept.location >= NSMaxRange(range) { selection = NSRange(location: kept.location + delta, length: kept.length) }
    }

    /// Open the attached editor under a display formula.
    func editMath(_ box: MathBlockBox) {
        guard let (tex, prefix) = mathSource(box) else { return }
        let controller = MathEditorController(tex: tex)
        controller.commit = { [weak self, weak box] new in
            guard let self, let box, new != tex else { return }
            self.commitMath(box, tex: new, prefix: prefix)
        }
        let card = FloatingCard(content: controller.view)
        controller.card = card
        // The card keeps its controller alive until it closes.
        card.onClose = { controller.cardDidClose() }
        card.show(below: box.drawnRect.insetBy(dx: 0, dy: -4), in: surface)
        card.makeFirstResponder(controller.source)
        controller.source.selectAll(nil)
    }

    func mathMenu(_ box: MathBlockBox) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: String(localized: "Edit Formula…")) { [weak self, weak box] in
            if let self, let box { self.editMath(box) }
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "Edit as Markdown")) { [weak self, weak box] in
            guard let self, let box, let range = self.source(of: box) else { return }
            self.selection = NSRange(location: range.location, length: 0)
            self.surface.window?.makeFirstResponder(self.surface)
        })
        return menu
    }
}
