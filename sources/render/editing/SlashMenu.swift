import AppKit
import UniformTypeIdentifiers
import ZephyrCore

/// A block template offered by the slash menu (design §8): choosing it inserts plain Markdown.
struct SlashItem {
    enum Kind {
        /// Inserted lines; `‸` marks where the caret goes. Later lines take the container prefix.
        case lines([String])
        /// Asks for an image file, then links it.
        case image
        /// A code block's language, written after its opening fence.
        case language(String)
        /// Text in the line in place of `/query`; `‸` marks the caret.
        case inline(String)
        /// A new item one level under the line's item, with this marker.
        case child(String)
    }

    var title: String
    /// Matched by prefix: English and Chinese names and common aliases, whatever the interface language.
    var keywords: [String]
    /// SF Symbol name, or a short label drawn as text ("H1": heading symbols localize to 大/小).
    var symbol: String
    /// The Markdown it produces, shown on the right.
    var hint: String
    var kind: Kind
    /// Needs a blank line above, or the line above would absorb it (setext heading, table row).
    var separated = false
    var allowedInList = true

    static let caret = "‸"

    static var all: [SlashItem] {
        [
            SlashItem(title: String(localized: "Heading 1"), keywords: ["heading1", "h1", "title", "标题", "一级标题"], symbol: "H1", hint: "#", kind: .lines(["# ‸"])),
            SlashItem(title: String(localized: "Heading 2"), keywords: ["heading2", "h2", "标题", "二级标题"], symbol: "H2", hint: "##", kind: .lines(["## ‸"])),
            SlashItem(title: String(localized: "Heading 3"), keywords: ["heading3", "h3", "标题", "三级标题"], symbol: "H3", hint: "###", kind: .lines(["### ‸"])),
            SlashItem(title: String(localized: "Bulleted List"), keywords: ["bulleted", "list", "ul", "bullet", "列表", "无序列表"], symbol: "list.bullet", hint: "-", kind: .lines(["- ‸"])),
            SlashItem(title: String(localized: "Numbered List"), keywords: ["numbered", "list", "ol", "ordered", "列表", "有序列表", "编号"], symbol: "list.number", hint: "1.", kind: .lines(["1. ‸"])),
            SlashItem(title: String(localized: "To-do List"), keywords: ["todo", "to-do", "task", "checkbox", "待办", "任务"], symbol: "checklist", hint: "- [ ]", kind: .lines(["- [ ] ‸"])),
            SlashItem(title: String(localized: "Quote"), keywords: ["quote", "blockquote", "引用"], symbol: "text.quote", hint: ">", kind: .lines(["> ‸"])),
            SlashItem(title: String(localized: "Code Block"), keywords: ["code", "codeblock", "fence", "代码"], symbol: "chevron.left.forwardslash.chevron.right", hint: "```", kind: .lines(["```‸", "", "```"])),
            SlashItem(title: String(localized: "Math Block"), keywords: ["math", "equation", "formula", "latex", "tex", "公式", "数学"], symbol: "function", hint: "$$", kind: .lines(["$$", "‸", "$$"])),
            SlashItem(title: String(localized: "Table"), keywords: ["table", "grid", "表格"], symbol: "tablecells", hint: "| |", kind: .lines(["| ‸ |  |", "| --- | --- |", "|  |  |"]), separated: true),
            SlashItem(title: String(localized: "Divider"), keywords: ["divider", "rule", "hr", "line", "separator", "分隔线", "分割线"], symbol: "minus", hint: "---", kind: .lines(["---", "‸"]), separated: true, allowedInList: false),
            SlashItem(title: String(localized: "Image…"), keywords: ["image", "picture", "photo", "img", "图片"], symbol: "photo", hint: "![]()", kind: .image),
        ] + formatting
    }

    /// Offered for a slash typed after text (after a space): what goes into the line, and under a
    /// list item what goes one level below it.
    static func inline(inItem: Bool) -> [SlashItem] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let children = [
            SlashItem(title: String(localized: "Sub-task"), keywords: ["subtask", "task", "todo", "child", "子任务", "待办", "任务", "目标"], symbol: "checklist", hint: "  - [ ]", kind: .child("- [ ] ")),
            SlashItem(title: String(localized: "Sub-item"), keywords: ["subitem", "item", "bullet", "child", "子项", "子列表", "列表"], symbol: "list.bullet.indent", hint: "  -", kind: .child("- ")),
        ]
        let inline = [
            SlashItem(title: String(localized: "Today’s Date"), keywords: ["date", "today", "日期", "今天"], symbol: "calendar", hint: today, kind: .inline(today)),
            SlashItem(title: String(localized: "Link"), keywords: ["link", "url", "链接"], symbol: "link", hint: "[]()", kind: .inline("[‸]()")),
            SlashItem(title: String(localized: "Inline Code"), keywords: ["code", "inline", "代码"], symbol: "chevron.left.forwardslash.chevron.right", hint: "``", kind: .inline("`‸`")),
            SlashItem(title: String(localized: "Inline Formula"), keywords: ["math", "formula", "equation", "公式", "数学"], symbol: "function", hint: "$$", kind: .inline("$‸$")),
        ] + formatting
        return (inItem ? children : []) + inline
    }

    /// Text styles, offered after text and at the start of a line alike.
    static var formatting: [SlashItem] {
        [
            SlashItem(title: String(localized: "Underline"), keywords: ["underline", "u", "下划线"], symbol: "underline", hint: "<u></u>", kind: .inline("<u>‸</u>")),
            SlashItem(title: String(localized: "Strikethrough"), keywords: ["strikethrough", "strike", "delete", "删除线"], symbol: "strikethrough", hint: "~~", kind: .inline("~~‸~~")),
            SlashItem(title: String(localized: "Highlight"), keywords: ["highlight", "mark", "高亮", "标记"], symbol: "highlighter", hint: "<mark>", kind: .inline("<mark>‸</mark>")),
        ]
    }

    /// Languages offered after a code block's opening fence: id, name, other names it is typed as.
    static let languages: [(id: String, name: String, aliases: [String])] = [
        ("python", "Python", ["py"]), ("swift", "Swift", []), ("javascript", "JavaScript", ["js", "node"]),
        ("typescript", "TypeScript", ["ts"]), ("bash", "Bash", ["sh", "shell", "zsh", "console"]), ("json", "JSON", []),
        ("markdown", "Markdown", ["md"]), ("html", "HTML", []), ("css", "CSS", []), ("sql", "SQL", []), ("yaml", "YAML", ["yml"]),
        ("toml", "TOML", []), ("r", "R", []), ("stata", "Stata", ["do"]), ("matlab", "MATLAB", []), ("julia", "Julia", []),
        ("latex", "LaTeX", ["tex"]), ("c", "C", []), ("cpp", "C++", ["c++", "cxx"]), ("csharp", "C#", ["cs", "c#"]),
        ("go", "Go", ["golang"]), ("rust", "Rust", ["rs"]), ("java", "Java", []), ("kotlin", "Kotlin", ["kt"]),
        ("objectivec", "Objective-C", ["objc"]), ("ruby", "Ruby", ["rb"]), ("php", "PHP", []), ("lua", "Lua", []),
        ("scala", "Scala", []), ("haskell", "Haskell", ["hs"]), ("dart", "Dart", []), ("xml", "XML", []),
        ("graphql", "GraphQL", ["gql"]), ("powershell", "PowerShell", ["ps1"]), ("dockerfile", "Dockerfile", ["docker"]),
        ("makefile", "Makefile", ["make"]), ("diff", "Diff", ["patch"]), ("mermaid", "Mermaid", ["diagram", "图表"]), ("text", "Plain Text", ["plain", "txt"]),
    ]

    /// A language row: its name, the info string it writes on the right.
    static func language(_ id: String) -> SlashItem {
        let known = languages.first { $0.id == id }
        return SlashItem(title: known?.name ?? id, keywords: [id] + (known?.aliases ?? []), symbol: "chevron.left.forwardslash.chevron.right", hint: id, kind: .language(id))
    }

    /// 0 for a prefix match, 1 when the title merely contains the query, nil for no match.
    func rank(_ query: String) -> Int? {
        let q = query.lowercased()
        if q.isEmpty || keywords.contains(where: { $0.hasPrefix(q) }) || title.lowercased().hasPrefix(q) { return 0 }
        return title.lowercased().contains(q) ? 1 : nil
    }
}

/// The floating list under the caret. It never takes key focus: typing keeps going to the text
/// view, which filters the list; arrows, Return, Tab and Escape are routed here while it is open.
@MainActor
final class SlashMenu {
    /// Offset of the `/` that opened the menu.
    let anchor: Int
    private(set) var items: [SlashItem] = []
    private(set) var selected = 0
    /// Nothing is chosen until an arrow or the pointer picks a row (a suggestion, not a menu
    /// asked for): Return then goes on to the text.
    var waitsForChoice = false {
        didSet { if waitsForChoice { selected = -1 } }
    }
    private let panel: NSPanel
    private let list: SlashMenuView
    private let all: [SlashItem]
    var choose: ((SlashItem) -> Void)?

    init(anchor: Int, items: [SlashItem]) {
        self.anchor = anchor
        all = items
        list = SlashMenuView()
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = Self.background(containing: list)
        list.owner = self
    }

    /// A solid raised surface (design §8.2); the window shadow follows its rounded shape.
    private static func background(containing view: NSView) -> NSView {
        let surface = SurfaceView(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.menu)
        view.frame = surface.bounds
        view.autoresizingMask = [.width, .height]
        surface.addSubview(view)
        return surface
    }

    var isVisible: Bool { panel.isVisible }

    /// At most this many rows show (the best matches): languages are many.
    var limit = Int.max

    /// Filter by the text typed after the slash; false when nothing matches.
    func update(query: String) -> Bool {
        items = Array(all.compactMap { item in item.rank(query).map { (item, $0) } }.enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0).prefix(limit))
        selected = min(selected, items.count - 1)
        if selected < 0, !waitsForChoice { selected = 0 }
        list.needsDisplay = true
        return !items.isEmpty
    }

    /// Below the caret line, or above it when the screen has no room below.
    func show(at caret: NSRect, in window: NSWindow) {
        let size = NSSize(width: SlashMenuView.width, height: list.height(rows: items.count))
        let screen = window.screen?.visibleFrame ?? window.frame
        var origin = NSPoint(x: caret.minX - 12, y: caret.minY - 6 - size.height)
        if origin.y < screen.minY { origin.y = caret.maxY + 6 }
        // Horizontally it stays inside its window, as a menu of that window.
        origin.x = min(max(origin.x, window.frame.minX + 4), window.frame.maxX - size.width - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        announceSelection()
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = selected < 0 ? (delta > 0 ? 0 : items.count - 1) : (selected + delta + items.count) % items.count
        list.needsDisplay = true
        announceSelection()
    }

    func select(_ index: Int) {
        guard index != selected, items.indices.contains(index) else { return }
        selected = index
        list.needsDisplay = true
    }

    /// False when no row is chosen.
    @discardableResult func chooseSelected() -> Bool {
        guard items.indices.contains(selected) else { return false }
        choose?(items[selected])
        return true
    }

    private func announceSelection() {
        guard items.indices.contains(selected) else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: items[selected].title, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Rows: a symbol tile, the title, and the Markdown the item inserts (design §21.7: the menu shows
/// what goes into the file).
final class SlashMenuView: NSView {
    weak var owner: SlashMenu?
    static let width: CGFloat = 280
    private let rowHeight: CGFloat = 34
    private let inset: CGFloat = 6

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func height(rows: Int) -> CGFloat { CGFloat(rows) * rowHeight + inset * 2 }

    private func row(at point: NSPoint) -> Int? {
        let index = Int(floor((point.y - inset) / rowHeight))
        return (owner?.items.indices.contains(index) ?? false) ? index : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)) { owner?.select(i) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = row(at: convert(event.locationInWindow, from: nil)) else { return }
        owner?.select(i)
        owner?.chooseSelected()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let menu = owner else { return }
        let titleFont = Tokens.font(13)
        let hintFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let labelFont = Tokens.font(11, .bold)
        for (i, item) in menu.items.enumerated() {
            let rect = NSRect(x: inset, y: inset + CGFloat(i) * rowHeight, width: bounds.width - inset * 2, height: rowHeight)
            guard rect.intersects(dirtyRect) else { continue }
            let hot = i == menu.selected
            if hot {
                Tokens.accentSoft.setFill()
                NSBezierPath(roundedRect: rect, xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control).fill()
            }
            let tile = NSRect(x: rect.minX + 6, y: rect.midY - 12, width: 24, height: 24)
            let tilePath = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            Tokens.raised.setFill()
            tilePath.fill()
            Tokens.line.setStroke()
            tilePath.stroke()
            let iconColor = hot ? Tokens.accent : Tokens.ink2
            if let image = Tokens.symbol(item.symbol, size: 12, color: iconColor) {
                image.draw(in: NSRect(x: tile.midX - image.size.width / 2, y: tile.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
            } else {
                let label = NSAttributedString(string: item.symbol, attributes: [.font: labelFont, .foregroundColor: iconColor])
                label.draw(at: NSPoint(x: tile.midX - label.size().width / 2, y: tile.midY - label.size().height / 2))
            }
            let hint = NSAttributedString(string: item.hint, attributes: [.font: hintFont, .foregroundColor: Tokens.ink3])
            let hintWidth = ceil(hint.size().width)
            hint.draw(at: NSPoint(x: rect.maxX - 10 - hintWidth, y: rect.midY - hint.size().height / 2))
            let title = NSAttributedString(string: item.title, attributes: [.font: titleFont, .foregroundColor: Tokens.ink])
            let titleX = tile.maxX + 10
            title.draw(with: NSRect(x: titleX, y: rect.midY - title.size().height / 2, width: rect.maxX - 20 - hintWidth - titleX, height: title.size().height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

// MARK: - Editor side

extension MarkdownEditor {
    /// Container prefix allowed before a slash: indentation, quote markers, one list marker.
    private static let slashHead = try! NSRegularExpression(pattern: #"^(?:[ \t]*>[ \t]?)*[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?$"#)

    /// A slash typed at the start of an otherwise empty line, outside code and math, opens the menu
    /// of blocks; after text and a space, the menu of what goes in a line (and, in a list item,
    /// under it). A slash right after text stays a slash (paths, URLs, fractions). `、` counts too:
    /// Chinese input methods type it for the slash key.
    func slashTyped(at location: Int) {
        let ns = source
        guard isEditable, location < ns.length, ["/", "、"].contains(ns.substring(with: NSRange(location: location, length: 1))) else { return }
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let head = ns.substring(with: NSRange(location: line.location, length: location - line.location))
        let tail = ns.substring(with: NSRange(location: location + 1, length: NSMaxRange(line) - location - 1))
        guard let m = lineMetrics(at: location), m.kind == .body || m.kind == .blank else { return }
        let items: [SlashItem]
        if tail.allSatisfy(\.isNewline), Self.slashHead.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) != nil {
            let inList = head.contains { "-*+.)".contains($0) }
            items = SlashItem.all.filter { !inList || $0.allowedInList }
        } else if let before = head.last, before == " " || before == "\t" || before == "\u{3000}", tail.first.map({ $0.isWhitespace }) ?? true {
            items = SlashItem.inline(inItem: listPrefix(at: location).map { location > $0.contentStart } ?? false)
        } else {
            return
        }
        let menu = SlashMenu(anchor: location, items: items)
        menu.choose = { [weak self] item in self?.insertSlashItem(item) }
        slashMenu?.close()
        slashMenu = menu
        updateSlashMenu()
    }

    /// Follows the caret: the query is the text between the slash and the caret.
    func updateSlashMenu() {
        // While an input method composes, the marked text is not the query yet.
        guard let menu = slashMenu, !surfaceHasMarkedText else { return }
        let ns = source
        let sel = selection
        guard sel.length == 0, sel.location > menu.anchor, menu.anchor < ns.length,
              ["/", "、"].contains(ns.substring(with: NSRange(location: menu.anchor, length: 1))) else { return closeSlashMenu() }
        let query = ns.substring(with: NSRange(location: menu.anchor + 1, length: sel.location - menu.anchor - 1))
        guard !query.contains(where: { $0.isWhitespace || $0.isNewline }), query.count <= 24, menu.update(query: query),
              let window = surface.window else { return closeSlashMenu() }
        menu.show(at: screenRect(for: NSRange(location: menu.anchor, length: 1)), in: window)
    }

    func closeSlashMenu() {
        slashMenu?.close()
        slashMenu = nil
        closeLanguageMenu()
    }

    /// Arrow keys, Return, Tab and Escape while a menu (blocks or languages) is open.
    func slashMenuHandles(_ selector: Selector) -> Bool {
        guard let menu = slashMenu ?? languageMenu ?? imageMenu else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): menu.move(-1)
        case #selector(NSResponder.moveDown(_:)): menu.move(1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            // An image suggestion nobody picked from lets Return and Tab through.
            if !menu.chooseSelected() {
                closeImageMenu()
                return false
            }
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            if menu === imageMenu { closeImageMenu() } else if slashMenu != nil { closeSlashMenu() } else {
                languageDismissed = source.lineRange(for: NSRange(location: menu.anchor, length: 0)).location
                closeLanguageMenu()
            }
        default: return false
        }
        return true
    }

    // MARK: Code block languages

    private static let fenceInfo = try! NSRegularExpression(pattern: #"^[ \t>]*(?:`{3,}|~{3,})([A-Za-z0-9+#._-]*)$"#)

    /// Languages for a code block opening at `location`: the one of the nearest block above first
    /// (a new block most likely continues it), then the others the document uses, then the rest.
    func languageChoices(before location: Int) -> [String] {
        let ns = source
        var used: [String] = []
        let above = ns.substring(to: location).components(separatedBy: CharacterSet.newlines)
        let below = ns.substring(from: location).components(separatedBy: CharacterSet.newlines)
        for line in above.reversed() + below {
            if let m = Self.fenceInfo.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let id = (line as NSString).substring(with: m.range(at: 1)).lowercased()
                if !id.isEmpty, !used.contains(id) { used.append(id) }
            }
        }
        return used + SlashItem.languages.map(\.id).filter { !used.contains($0) }
    }

    /// With the caret after an opening fence (```, then what is typed of the language), the
    /// languages that match follow it. Escape keeps them away until the caret leaves the line.
    func updateLanguageMenu() {
        guard isEditable, !surfaceHasMarkedText, slashMenu == nil, blockCanvas.presenter != nil else { return closeLanguageMenu() }
        let ns = source, sel = selection
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let content = Self.withoutTerminator(line, in: ns)
        guard sel.length == 0, sel.location == NSMaxRange(content), languageDismissed != line.location,
              blockCanvas.place(line.location).layout.content.code?.isFirst == true,
              let m = Self.fenceInfo.firstMatch(in: ns.substring(with: content), range: NSRange(location: 0, length: content.length)),
              let window = surface.window else {
            if languageDismissed != line.location { languageDismissed = nil }
            return closeLanguageMenu()
        }
        let info = NSRange(location: content.location + m.range(at: 1).location, length: m.range(at: 1).length)
        if languageMenu?.anchor != info.location {
            closeLanguageMenu()
            // No language first: Return right after the fence makes a plain block.
            let none = SlashItem(title: String(localized: "No Language"), keywords: ["none", "plain", "无"], symbol: "chevron.left.forwardslash.chevron.right", hint: "```", kind: .language(""))
            let menu = SlashMenu(anchor: info.location, items: [none] + languageChoices(before: line.location).map(SlashItem.language))
            menu.limit = 8
            menu.choose = { [weak self] item in
                guard case let .language(id) = item.kind else { return }
                self?.chooseLanguage(id)
            }
            languageMenu = menu
        }
        guard let menu = languageMenu, menu.update(query: ns.substring(with: info)) else { return closeLanguageMenu() }
        menu.show(at: screenRect(for: NSRange(location: max(content.location, info.location - 3), length: 3)), in: window)
    }

    func closeLanguageMenu() {
        languageMenu?.close()
        languageMenu = nil
    }

    /// The language written after the fence, then the caret on the block's first line of code (a
    /// block left open gets its line and closing fence).
    func chooseLanguage(_ id: String) {
        guard let menu = languageMenu else { return }
        closeLanguageMenu()
        let ns = source
        let line = ns.lineRange(for: NSRange(location: menu.anchor, length: 0))
        let content = Self.withoutTerminator(line, in: ns)
        let typed = NSRange(location: menu.anchor, length: NSMaxRange(content) - menu.anchor)
        let fence = ns.substring(with: NSRange(location: content.location, length: menu.anchor - content.location))
        let prefix = String(fence.prefix { $0 == " " || $0 == "\t" || $0 == ">" })
        let marks = fence.dropFirst(prefix.count)
        if fenceIsClosed(after: line, marks: String(marks)) {
            replace(typed, with: id)
            let shift = (id as NSString).length - typed.length
            selection = NSRange(location: NSMaxRange(line) + shift, length: 0)
        } else {
            // A fence left open: the block gets its body and its close.
            replace(typed, with: id + newline + prefix + newline + prefix + marks)
            selection = NSRange(location: typed.location + (id as NSString).length + (newline as NSString).length + (prefix as NSString).length, length: 0)
        }
        scrollSelectionToVisible()
    }

    /// Replace `/query` with the item's Markdown as one undoable edit.
    func insertSlashItem(_ item: SlashItem) {
        guard let menu = slashMenu else { return }
        closeSlashMenu()
        let ns = source
        let typed = NSRange(location: menu.anchor, length: max(1, selection.location - menu.anchor))
        let line = ns.lineRange(for: NSRange(location: menu.anchor, length: 0))
        let head = ns.substring(with: NSRange(location: line.location, length: menu.anchor - line.location))
        // Later lines continue the container: quote markers stay, list markers become spaces.
        let continuation = String(head.map { $0 == ">" || $0 == " " || $0 == "\t" ? $0 : " " })
        switch item.kind {
        case .language:
            return
        case let .inline(template):
            let caret = (template as NSString).range(of: SlashItem.caret)
            let text = template.replacingOccurrences(of: SlashItem.caret, with: "")
            replace(typed, with: text)
            selection = NSRange(location: typed.location + (caret.location == NSNotFound ? (text as NSString).length : caret.location), length: 0)
        case let .child(marker):
            // The item's line keeps its text, the `/query` (and the space before it) goes, and a
            // new item opens one level under it: at the item's content column, after any quote.
            guard let p = listPrefix(at: menu.anchor) else { return }
            let content = Self.withoutTerminator(line, in: ns)
            var cut = typed
            if cut.location > p.contentStart, ns.character(at: cut.location - 1) == 0x20 { cut = NSRange(location: cut.location - 1, length: cut.length + 1) }
            let rest = ns.substring(with: NSRange(location: NSMaxRange(cut), length: NSMaxRange(content) - NSMaxRange(cut)))
            let child = p.indent + String(repeating: " ", count: ((p.marker + p.spacing) as NSString).length) + marker
            let inserted = rest + newline + child
            replace(NSRange(location: cut.location, length: NSMaxRange(content) - cut.location), with: inserted)
            selection = NSRange(location: cut.location + (inserted as NSString).length, length: 0)
        case .image:
            chooseImage { [weak self] markdown in
                guard let self else { return }
                self.replace(typed, with: markdown ?? "")
                self.selection = NSRange(location: typed.location + ((markdown ?? "") as NSString).length, length: 0)
            }
        case let .lines(lines):
            var text = lines.joined(separator: newline + continuation)
            if item.separated {
                func hasContent(_ r: NSRange) -> Bool { ns.substring(with: r).contains { !$0.isWhitespace && $0 != ">" } }
                if line.location > 0, hasContent(ns.lineRange(for: NSRange(location: line.location - 1, length: 0))) {
                    text = newline + continuation + text
                }
                if NSMaxRange(line) < ns.length, hasContent(ns.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))), !text.hasSuffix(SlashItem.caret) {
                    text += newline + continuation.trimmingCharacters(in: .whitespaces)
                }
            }
            let caret = (text as NSString).range(of: SlashItem.caret)
            text = text.replacingOccurrences(of: SlashItem.caret, with: "")
            replace(typed, with: text)
            selection = NSRange(location: typed.location + caret.location, length: 0)
        }
        scrollSelectionToVisible()
    }

    /// Links an existing image chosen by the user (design §9: new attachments go where the user
    /// says; Zephyr never copies files into the folder). Paths are relative to the document.
    func chooseImage(_ done: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = baseURL
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return done(nil) }
            done(self?.markdownReference(to: url))
        }
        if let window = surface.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// A Markdown reference to a file where it is, relative to the document: an image shows,
    /// anything else links.
    func markdownReference(to url: URL) -> String {
        let path = (baseURL.map { url.path(relativeTo: $0) } ?? url.path).replacingOccurrences(of: " ", with: "%20")
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return "[\(url.lastPathComponent)](\(path))" }
        return "![\(url.deletingPathExtension().lastPathComponent)](\(path))"
    }
}

extension URL {
    /// `self` as a path relative to the directory `base`, with `..` where needed.
    func path(relativeTo base: URL) -> String {
        let a = standardizedFileURL.pathComponents, b = base.standardizedFileURL.pathComponents
        var common = 0
        while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        guard common > 1 else { return standardizedFileURL.path }
        return (Array(repeating: "..", count: b.count - common) + a[common...]).joined(separator: "/")
    }
}
