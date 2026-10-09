import AppKit
import ZephyrCore
import ZephyrRender

/// Review of a proposed change, the only place where AI or agent edits are approved (design §10,
/// §11): who proposed it, its summary, and each edit as removed and added lines with a line of
/// context. Apply runs the recoverable transaction; Discard leaves the file alone.
@MainActor
final class ProposalReview: NSObject {
    private static var open: [ProposalReview] = []
    private let panel: NSPanel
    private let proposal: EditProposal
    private weak var document: MarkdownDocument?
    private let decided: (Result<RecoveryRecord, Error>?) -> Void
    private var finished = false
    /// Set while an accepted proposal is applied and saved: the sheet stays up until then, and a
    /// second Apply (a double click) must not resolve the edits again against the changed text.
    private var applying = false
    /// The text revision the diff shows: Apply changes exactly that, or shows the diff again.
    private var shownRevision: String
    private let diffView = NSTextView()
    private let notice = flatLabel("", size: 12, color: Tokens.ink2, wraps: true)

    /// `decided` gets the applied record, nil when discarded, or the error that stopped applying.
    static func present(_ proposal: EditProposal, for document: MarkdownDocument, decided: @escaping (Result<RecoveryRecord, Error>?) -> Void) {
        // A document waiting in a window's sidebar comes forward for its review.
        let host = DocumentWindowController.hosting(document)
        host?.reveal(document)
        guard let editor = document.editor, let window = host?.window else { return decided(.failure(TransactionError.untitled)) }
        let patches: [TextPatch]
        do {
            patches = try ProposalResolver.patches(for: proposal.edits, in: editor.string, newline: editor.newline)
        } catch {
            return decided(.failure(error))
        }
        let review = ProposalReview(proposal: proposal, patches: patches, text: editor.string, document: document, decided: decided)
        open.append(review)
        window.beginSheet(review.panel)
    }

    private init(proposal: EditProposal, patches: [TextPatch], text: String, document: MarkdownDocument, decided: @escaping (Result<RecoveryRecord, Error>?) -> Void) {
        self.proposal = proposal
        self.document = document
        self.decided = decided
        shownRevision = TextRevision.of(text)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        panel.minSize = NSSize(width: 480, height: 320)
        build(patches: patches, text: text)
        if proposal.baseRevision != shownRevision {
            show(notice: String(localized: "This proposal was written against an earlier version of the document. The changes below are placed in the current text."))
        }
    }

    private func show(notice text: String) {
        notice.stringValue = text
        notice.isHidden = false
    }

    private func build(patches: [TextPatch], text: String) {
        let title = flatLabel(String(localized: "Changes proposed by \(proposal.origin)"), size: 15, weight: .semibold)
        let summary = flatLabel(proposal.summary, size: 13, color: Tokens.ink2, wraps: true)
        summary.isHidden = proposal.summary.isEmpty

        let diff = diffView
        diff.isEditable = false
        diff.isSelectable = true
        diff.drawsBackground = false
        diff.textContainerInset = NSSize(width: 8, height: 10)
        diff.textStorage?.setAttributedString(Self.diff(patches, in: text))
        diff.autoresizingMask = [.width]
        diff.setAccessibilityLabel(String(localized: "Proposed changes"))
        let scroll = NSScrollView()
        scroll.documentView = diff
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        diff.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        diff.minSize = NSSize(width: 0, height: 0)
        diff.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diff.isVerticallyResizable = true
        let box = SurfaceView(fill: Tokens.sunken, border: Tokens.line, radius: Tokens.Radius.menu)
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])

        let note = flatLabel(String(localized: "Applied changes can be withdrawn from the AI panel."), size: 11.5, color: Tokens.ink3)
        let discard = FlatButton(title: String(localized: "Discard"), style: .secondary)
        discard.target = self
        discard.action = #selector(discard(_:))
        discard.keyEquivalent = "\u{1b}"
        let apply = FlatButton(title: String(localized: "Apply"), style: .primary)
        apply.target = self
        apply.action = #selector(apply(_:))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [note, NSView(), discard, apply])
        buttons.spacing = 8

        notice.isHidden = true
        let stack = NSStackView(views: [title, summary, notice, box, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: box)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        for v in [box, buttons, summary, notice] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            notice.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        let root = CanvasRootView()
        root.wantsLayer = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
    }

    /// Each edit as its whole lines: one line of context, removed lines, added lines.
    static func diff(_ patches: [TextPatch], in text: String) -> NSAttributedString {
        let ns = text as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        func line(_ s: String, _ mark: String, color: NSColor, background: NSColor?) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let background { attrs[.backgroundColor] = background }
            out.append(NSAttributedString(string: mark + " " + s + "\n", attributes: attrs))
        }
        func lines(_ s: String) -> [String] {
            var parts = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        for (i, p) in patches.enumerated() {
            let whole = ns.lineRange(for: p.range)
            let lineNumber = ns.substring(to: whole.location).filter { $0 == "\n" || $0 == "\r\n" }.count + 1
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: String(localized: "Line \(lineNumber)") + "\n", attributes: [.font: Tokens.font(11, .semibold), .foregroundColor: Tokens.ink3]))
            if whole.location > 0 {
                let above = ns.lineRange(for: NSRange(location: whole.location - 1, length: 0))
                lines(ns.substring(with: above)).forEach { line($0, " ", color: Tokens.ink3, background: nil) }
            }
            let old = ns.substring(with: whole)
            let local = NSRange(location: p.range.location - whole.location, length: p.range.length)
            let new = (old as NSString).replacingCharacters(in: local, with: p.replacement)
            lines(old).forEach { line($0, "−", color: Tokens.ink, background: Tokens.removed) }
            lines(new).forEach { line($0, "+", color: Tokens.ink, background: Tokens.added) }
            if NSMaxRange(whole) < ns.length {
                let below = ns.lineRange(for: NSRange(location: NSMaxRange(whole), length: 0))
                lines(ns.substring(with: below)).forEach { line($0, " ", color: Tokens.ink3, background: nil) }
            }
        }
        return out
    }

    private func finish(_ result: Result<RecoveryRecord, Error>?) {
        guard !finished else { return }
        finished = true
        panel.sheetParent?.endSheet(panel)
        Self.open.removeAll { $0 === self }
        decided(result)
    }

    @objc private func discard(_ sender: Any?) {
        guard !applying else { return }
        finish(nil)
    }

    @objc private func apply(_ sender: Any?) {
        guard !applying, !finished else { return }
        guard let document, let editor = document.editor else { return finish(.failure(TransactionError.untitled)) }
        // Resolved again: the text may have changed while the sheet was open.
        let text = editor.string
        let patches: [TextPatch]
        do {
            patches = try ProposalResolver.patches(for: proposal.edits, in: text, newline: editor.newline)
        } catch {
            return finish(.failure(error))
        }
        // Apply only what the user saw: if the text moved on, show the diff against it first.
        let revision = TextRevision.of(text)
        guard revision == shownRevision else {
            shownRevision = revision
            diffView.textStorage?.setAttributedString(Self.diff(patches, in: text))
            show(notice: String(localized: "The document changed while this was open. Review the updated changes, then apply again."))
            return
        }
        applying = true
        Transactions.apply(patches, to: document, origin: proposal.origin, summary: proposal.summary) { [weak self] result in
            self?.finish(result)
        }
    }
}
