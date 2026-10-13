import AppKit

/// Typing shortcuts: paired `$` and `*`, closing HTML tags, `$$` and ``` blocks on Return, and
/// the image suggestion after `!`. Each produces the Markdown a person would type by hand.
extension MarkdownEditor {
    /// Before or after a run of markers: what lets a run open (line start, space, opening
    /// punctuation) and what lets a pair close after the caret (line end, space, punctuation).
    private static func opens(_ c: unichar?) -> Bool {
        guard let c else { return true }
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespaces.contains(scalar) || "([{\"'“‘（【「《".unicodeScalars.contains(scalar)
    }
    private static func closes(_ c: unichar?) -> Bool {
        guard let c else { return true }
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
    }

    /// The caret's line is prose (not code, a fence or a component).
    private func inProse(_ location: Int) -> Bool {
        guard let kind = lineMetrics(at: location)?.kind else { return true }
        return kind != .code && kind != .fence
    }

    /// `$` and `*` typed with nothing selected come in pairs, the caret between: typed again in an
    /// empty pair they nest (`$$`, `**`, `***` at most); after text, the closing one is stepped
    /// over. A `*` at the start of a line stays single (it may start a bullet), and a second one
    /// there opens `**`. With a selection, the selection is wrapped. Returns false to type it plainly.
    func typePaired(_ text: String) -> Bool {
        guard isEditable, text == "$" || text == "*", inProse(selection.location) else { return false }
        let ns = source, sel = selection
        if sel.length > 0 {
            guard !ns.substring(with: sel).contains(where: \.isNewline) else { return false }
            toggleWrap(text)
            return true
        }
        let mark = (text as NSString).character(at: 0), most = text == "$" ? 2 : 3
        let i = sel.location
        let line = ns.lineRange(for: NSRange(location: i, length: 0))
        var l = 0, r = 0
        while i - l > line.location, ns.character(at: i - l - 1) == mark { l += 1 }
        while i + r < ns.length, ns.character(at: i + r) == mark { r += 1 }
        let before: unichar? = i - l > line.location ? ns.character(at: i - l - 1) : nil
        let after: unichar? = i + r < ns.length ? ns.character(at: i + r) : nil
        let opening = Self.opens(before)
        // After text, a closing marker: step over it.
        if r > 0, !opening {
            selection = NSRange(location: i + 1, length: 0)
            return true
        }
        guard opening, Self.closes(after), l < most else { return false }
        if l == r, l >= 1 {
            typeText(text + text, replacing: sel)
            selection = NSRange(location: i + 1, length: 0)
            return true
        }
        guard r == 0 else { return false }
        let head = ns.substring(with: NSRange(location: line.location, length: i - l - line.location))
        let atLineStart = head.allSatisfy { $0 == " " || $0 == "\t" || $0 == ">" }
        if l == 0 {
            if mark == 0x2A, atLineStart { return false }
            typeText(text + text, replacing: sel)
        } else {
            // A single `*` left at the start of a line: the second opens a pair of `**`.
            guard mark == 0x2A, atLineStart else { return false }
            typeText(text + String(repeating: text, count: l + 1), replacing: sel)
        }
        selection = NSRange(location: i + 1, length: 0)
        return true
    }

    /// Backspace in an empty pair of `$` or `*` takes both halves.
    func deleteEmptyPair() -> Bool {
        let ns = source, sel = selection, i = sel.location
        guard isEditable, sel.length == 0, i > 0, i < ns.length else { return false }
        let mark = ns.character(at: i - 1)
        guard mark == 0x24 || mark == 0x2A, ns.character(at: i) == mark, inProse(i) else { return false }
        let line = ns.lineRange(for: NSRange(location: i, length: 0))
        var l = 0, r = 0
        while i - l > line.location, ns.character(at: i - l - 1) == mark { l += 1 }
        while i + r < ns.length, ns.character(at: i + r) == mark { r += 1 }
        let before: unichar? = i - l > line.location ? ns.character(at: i - l - 1) : nil
        guard l == r, Self.opens(before) else { return false }
        replace(NSRange(location: i - 1, length: 2), with: "")
        selection = NSRange(location: i - 1, length: 0)
        return true
    }

    private static let openTag = try! NSRegularExpression(pattern: #"<([A-Za-z][A-Za-z0-9-]*)(?:\s[^<>]*)?>$"#)
    private static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

    /// A `>` that ends an opening HTML tag (`<sup>`, `<span class="x">`) adds its closing tag
    /// after the caret; empty elements (`<br>`, `<img …>`) and `<…/>` get none.
    func closeTagTyped() {
        let ns = source, i = selection.location
        guard isEditable, selection.length == 0, i > 0, ns.character(at: i - 1) == 0x3E, inProse(i) else { return }
        let line = ns.lineRange(for: NSRange(location: i, length: 0))
        let head = ns.substring(with: NSRange(location: line.location, length: i - line.location))
        guard !head.hasSuffix("/>"), let m = Self.openTag.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) else { return }
        let name = (head as NSString).substring(with: m.range(at: 1)).lowercased()
        let closing = "</\(name)>"
        guard !Self.voidTags.contains(name), !ns.substring(from: i).hasPrefix(closing) else { return }
        typeText(closing, replacing: NSRange(location: i, length: 0))
        selection = NSRange(location: i, length: 0)
    }

    private static let fenceLine = try! NSRegularExpression(pattern: #"^([ \t>]*)(`{3,}|~{3,})([A-Za-z0-9+#._-]*)$"#)

    /// Whether the fence that opens on `line` has its closing fence below (the same character,
    /// at least as many, nothing after).
    func fenceIsClosed(after line: NSRange, marks: String) -> Bool {
        let ns = source
        var at = NSMaxRange(line)
        while at < ns.length {
            let next = ns.lineRange(for: NSRange(location: at, length: 0))
            let body = ns.substring(with: Self.withoutTerminator(next, in: ns)).drop { $0 == " " || $0 == "\t" || $0 == ">" }.trimmingCharacters(in: .whitespaces)
            if let c = marks.first, body.count >= marks.count, body.allSatisfy({ $0 == c }) { return true }
            at = NSMaxRange(next)
        }
        return false
    }

    /// Return at the end of `$$` (or between `$$` and `$$`) opens a formula block, and at the end
    /// of an opening fence left open (``` or ```lang) a code block: the closing line follows,
    /// the caret on the empty line between. Quote markers and indentation carry over.
    func quickBlockOnReturn() -> Bool {
        let ns = source, sel = selection
        guard isEditable, sel.length == 0 else { return false }
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let content = Self.withoutTerminator(line, in: ns)
        let text = ns.substring(with: content)
        let prefix = String(text.prefix { $0 == " " || $0 == "\t" || $0 == ">" })
        let body = String(text.dropFirst(prefix.count))
        let caret = sel.location - content.location - (prefix as NSString).length
        let opening: String, closing: String
        if (body == "$$" && caret == 2) || (body == "$$$$" && caret == 2) {
            // A `$$` line after an odd number of them closes a block instead.
            let above = ns.substring(to: line.location).components(separatedBy: .newlines)
            let delimiters = above.filter { $0.drop { $0 == " " || $0 == "\t" || $0 == ">" }.trimmingCharacters(in: .whitespaces) == "$$" }.count
            guard body == "$$$$" || delimiters % 2 == 0 else { return false }
            (opening, closing) = ("$$", "$$")
        } else if caret == (body as NSString).length, inProse(sel.location) || lineMetrics(at: sel.location)?.kind == .fence,
                  let m = Self.fenceLine.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let marks = (text as NSString).substring(with: m.range(at: 2))
            guard !fenceIsClosed(after: line, marks: marks) else { return false }
            (opening, closing) = (body, marks)
        } else {
            return false
        }
        let block = prefix + opening + newline + prefix + newline + prefix + closing
        replace(content, with: block)
        selection = NSRange(location: content.location + ((prefix + opening + newline + prefix) as NSString).length, length: 0)
        scrollSelectionToVisible()
        return true
    }

    // MARK: Image suggestion

    /// A `!` typed at the start of a line or after a space offers an image under the caret. Nothing
    /// is chosen until an arrow or the pointer picks a row, so Return still breaks the line.
    func bangTyped(at location: Int) {
        let ns = source
        guard isEditable, location < ns.length, ns.character(at: location) == 0x21, inProse(location) else { return }
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let before: unichar? = location > line.location ? ns.character(at: location - 1) : nil
        guard Self.opens(before), let window = surface.window else { return }
        closeImageMenu()
        let items = [
            SlashItem(title: String(localized: "Image"), keywords: [], symbol: "photo", hint: "![]()", kind: .inline("![‸]()")),
            SlashItem(title: String(localized: "Image…"), keywords: [], symbol: "folder", hint: String(localized: "Choose a file"), kind: .image),
        ]
        let menu = SlashMenu(anchor: location, items: items)
        menu.waitsForChoice = true
        menu.choose = { [weak self] item in self?.insertImageItem(item) }
        _ = menu.update(query: "")
        imageMenu = menu
        menu.show(at: screenRect(for: NSRange(location: location, length: 1)), in: window)
    }

    /// The suggestion lasts while the caret stays right after its `!`.
    func updateImageMenu() {
        guard let menu = imageMenu else { return }
        let ns = source
        if selection != NSRange(location: menu.anchor + 1, length: 0) || menu.anchor >= ns.length || ns.character(at: menu.anchor) != 0x21 { closeImageMenu() }
    }

    func closeImageMenu() {
        imageMenu?.close()
        imageMenu = nil
    }

    private func insertImageItem(_ item: SlashItem) {
        guard let menu = imageMenu else { return }
        closeImageMenu()
        let bang = NSRange(location: menu.anchor, length: 1)
        switch item.kind {
        case let .inline(template):
            let caret = (template as NSString).range(of: SlashItem.caret).location
            replace(bang, with: template.replacingOccurrences(of: SlashItem.caret, with: ""))
            selection = NSRange(location: bang.location + caret, length: 0)
        case .image:
            chooseImage { [weak self] markdown in
                guard let self, let markdown else { return }
                self.replace(bang, with: markdown)
                self.selection = NSRange(location: bang.location + (markdown as NSString).length, length: 0)
            }
        default:
            return
        }
        scrollSelectionToVisible()
    }
}
