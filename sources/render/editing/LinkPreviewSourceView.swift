import AppKit
import ZephyrCore

/// Read-only source text for a link preview, colored like fenced code (`CodeSyntax`, design
/// §8.1), with the bracket that matches the one at the caret marked.
@MainActor
final class LinkPreviewSourceView: NSTextView, NSTextViewDelegate {
    var onCancel: (() -> Void)?
    var onResignFirstResponder: (() -> Void)?

    private var bracketPairs: [Int: Int] = [:]
    private var pairRanges: [NSRange] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = NSSize(width: 2, height: 2)
        textContainer?.widthTracksTextView = false
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSource(_ text: String, filename: String, typography: Typography) {
        clearSourceHighlighting()
        let previous = selectedRange()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let lineHeight = typography.lineHeight(for: typography.codeFont, kind: .code)
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.paragraphSpacing = 0

        let storage = NSMutableAttributedString(string: text, attributes: [
            .font: typography.codeFont,
            .foregroundColor: Tokens.ink,
            .paragraphStyle: paragraph,
        ])
        // Strings and comments hold no brackets that pair.
        var skipped: [NSRange] = []
        if let language = CodeSyntax.language(Self.languageName(for: filename)) {
            for token in CodeSyntax.tokens(text, language: language) {
                storage.addAttribute(.foregroundColor, value: Palette.syntax(token.role), range: token.range)
                let quoted = token.role == .property && [0x22, 0x27].contains((text as NSString).character(at: token.range.location))
                if token.role == .string || token.role == .comment || quoted { skipped.append(token.range) }
            }
        }
        if !Self.plainExtensions.contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) { pairBrackets(text as NSString, skipping: skipped) }
        textStorage?.setAttributedString(storage)

        let location = min(previous.location, storage.length)
        let length = min(previous.length, storage.length - location)
        setSelectedRange(NSRange(location: location, length: length))
    }

    func clearSourceHighlighting() {
        removePairHighlight()
        bracketPairs.removeAll(keepingCapacity: true)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() }
        else { super.cancelOperation(sender) }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignFirstResponder?() }
        return resigned
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updatePairHighlight(for: selectedRange())
    }

    private static let plainExtensions: Set<String> = ["txt", "text", "log", "md", "markdown"]

    /// The name `CodeSyntax` knows a file's language by: its extension, or its name without one
    /// (`Dockerfile`, `.env`).
    static func languageName(for filename: String) -> String {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty { return ext == "pyw" ? "py" : ext }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix(".") ? String(name.dropFirst()) : name
    }

    /// Opening and closing brackets that belong together, outside strings and comments.
    private func pairBrackets(_ text: NSString, skipping skipped: [NSRange]) {
        var open: [(unichar, Int)] = []
        var k = 0
        var index = 0
        while index < text.length {
            while k < skipped.count, NSMaxRange(skipped[k]) <= index { k += 1 }
            if k < skipped.count, skipped[k].location <= index {
                index = NSMaxRange(skipped[k])
                continue
            }
            let character = text.character(at: index)
            switch character {
            case 0x28, 0x5B, 0x7B:
                open.append((character, index))
            case 0x29, 0x5D, 0x7D:
                if let last = open.last, closes(character, last.0) {
                    open.removeLast()
                    bracketPairs[last.1] = index
                    bracketPairs[index] = last.1
                }
            default: break
            }
            index += 1
        }
    }

    private func updatePairHighlight(for selection: NSRange) {
        removePairHighlight()
        guard textStorage != nil, !bracketPairs.isEmpty else { return }
        let candidates: [Int]
        if selection.length == 1 {
            candidates = [selection.location]
        } else if selection.length == 0 {
            candidates = [selection.location, selection.location - 1]
        } else {
            return
        }
        guard let location = candidates.first(where: { bracketPairs[$0] != nil }), let mate = bracketPairs[location] else { return }
        pairRanges = [NSRange(location: location, length: 1), NSRange(location: mate, length: 1)]
        for range in pairRanges {
            layoutManager?.addTemporaryAttribute(.backgroundColor, value: Tokens.accentSoft, forCharacterRange: range)
            layoutManager?.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: range)
            layoutManager?.addTemporaryAttribute(.underlineColor, value: Tokens.accent, forCharacterRange: range)
        }
    }

    private func removePairHighlight() {
        for range in pairRanges {
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            layoutManager?.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        }
        pairRanges.removeAll(keepingCapacity: true)
    }

    private func closes(_ closing: unichar, _ opening: unichar) -> Bool { (closing == 0x29 && opening == 0x28) || (closing == 0x5D && opening == 0x5B) || (closing == 0x7D && opening == 0x7B) }
}
