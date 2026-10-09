import Foundation

/// A page of Zephyr's space made of blocks (design §8.3): an ordinary Markdown note, read as a
/// layout. Its title is the first-level heading, the text under the title is its description, and
/// each second-level section is a block whose kind follows from what it holds: tasks, a list of
/// links (documents to follow), a list of `Label: value` figures, or anything else as text. An
/// HTML comment under a heading, invisible in other apps, can say more: `<!-- zephyr: wide -->`
/// for the full width, a kind for a section still empty (`tasks`, `links`, `numbers`, `text`), or
/// one of Zephyr's live blocks (`today`, `goals`, `activity`, `recent`). Every change from the
/// page is a minimal patch of the note, so other apps, the assistant and agents see a plain
/// document, and what they write shows up as blocks.
public enum Board {
    public enum Kind: String, Sendable, CaseIterable { case tasks, links, numbers, text }

    /// Blocks drawn from the rest of the space rather than from their own text.
    public enum Live: String, Sendable, CaseIterable { case today, goals, activity, recent }

    public struct Link: Equatable, Sendable {
        public var title: String
        public var destination: String
        public var line: NSRange
    }

    public struct Metric: Equatable, Sendable {
        public var label: String
        public var value: String
        /// 0...1 when the value reads as a share: `3/10` or `40%`.
        public var progress: Double?
    }

    public enum Content: Equatable, Sendable {
        case tasks([Space.Item])
        case links([Link])
        case numbers([Metric])
        case text
        case live(Live)
    }

    public struct Block: Equatable, Sendable {
        public var title: String
        public var content: Content
        public var wide: Bool
        /// From the heading to the next section: what moving or removing the block takes.
        public var range: NSRange
        /// The heading's line (or lines, for a setext heading) with the line break.
        public var heading: NSRange
        /// The hint comment's line without its line break, if there is one, and its words.
        public var hint: NSRange?
        public var words: [String]
        /// The section's own text: after the heading and the hint.
        public var body: NSRange
    }

    public struct Page: Equatable, Sendable {
        public var title: String?
        /// An SF Symbol name from the front matter's `icon:`.
        public var symbol: String?
        /// The text between the title and the first block.
        public var intro: String
        public var blocks: [Block]
    }

    // MARK: Reading

    private static let hintPattern = try! NSRegularExpression(pattern: #"^[ \t]*<!--[ \t]*zephyr[ \t]*:([^>]*?)-->[ \t]*$"#, options: [.caseInsensitive])
    private static let linkPattern = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+\[([^\]]+)\]\([ \t]*(<[^>]*>|[^)\s]+)(?:[ \t]+"[^"]*")?[ \t]*\)[ \t]*$"#)
    private static let metricPattern = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+([^:：\[\]()]{1,40}?)[ \t]*[:：][ \t]*(\S.{0,39})$"#)
    private static let ratioPattern = try! NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)(?!\d)"#)
    private static let percentPattern = try! NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)\s*%$"#)
    private static let iconPattern = try! NSRegularExpression(pattern: #"(?m)^icon[ \t]*:[ \t]*([A-Za-z0-9.]+)[ \t]*$"#)

    public static func page(in text: NSString) -> Page {
        let headings = Outline.headings(in: text)
        let title = headings.first { $0.level == 1 }
        // A first-level heading also ends a section.
        let marks = headings.filter { $0.level <= 2 }
        let tasks = Space.items(in: text)
        var blocks: [Block] = []
        for (i, mark) in marks.enumerated() where mark.level == 2 {
            let end = i + 1 < marks.count ? marks[i + 1].location : text.length
            blocks.append(block(mark, end: end, in: text, tasks: tasks))
        }
        var symbol: String?
        let front = ChunkIndex.frontMatterEnd(text)
        if let front, let m = iconPattern.firstMatch(in: text as String, range: NSRange(location: 0, length: front)) {
            symbol = text.substring(with: m.range(at: 1))
        }
        let introStart = title.map { headingLines(at: $0.location, in: text).upperBound } ?? front ?? 0
        let introEnd = blocks.first?.range.location ?? text.length
        let intro = introEnd > introStart ? text.substring(with: NSRange(location: introStart, length: introEnd - introStart)) : ""
        return Page(title: title?.title, symbol: symbol, intro: strippingHints(intro).trimmingCharacters(in: .whitespacesAndNewlines), blocks: blocks)
    }

    private static func block(_ mark: Outline.Heading, end: Int, in text: NSString, tasks: [Space.Item]) -> Block {
        let heading = headingLines(at: mark.location, in: text)
        let headingRange = NSRange(location: mark.location, length: heading.upperBound - mark.location)
        var bodyStart = heading.upperBound
        var hint: NSRange?
        var words: [String] = []
        var lines: [NSRange] = []
        var pos = bodyStart, lineStart = 0, lineEnd = 0, contents = 0
        while pos < end {
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contents, for: NSRange(location: pos, length: 0))
            pos = lineEnd
            let line = NSRange(location: lineStart, length: min(contents, end) - lineStart)
            let string = text.substring(with: line)
            if string.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if hint == nil, lines.isEmpty, let m = hintPattern.firstMatch(in: string, range: NSRange(location: 0, length: line.length)) {
                hint = line
                words = (string as NSString).substring(with: m.range(at: 1)).lowercased()
                    .components(separatedBy: CharacterSet(charactersIn: ", \t")).filter { !$0.isEmpty }
                bodyStart = min(lineEnd, end)
                continue
            }
            lines.append(line)
        }
        let body = NSRange(location: bodyStart, length: max(0, end - bodyStart))
        let own = tasks.filter { NSLocationInRange($0.line.location, body) }
        let declared = words.lazy.compactMap(Kind.init(rawValue:)).first
        let strings = lines.map { text.substring(with: $0) }
        let content: Content
        if let live = words.lazy.compactMap(Live.init(rawValue:)).first {
            content = .live(live)
        } else if declared == .tasks || declared == nil && !lines.isEmpty && own.count == lines.count {
            content = .tasks(own)
        } else if declared == .links || declared == nil && !lines.isEmpty && strings.allSatisfy({ matches(linkPattern, $0) }) {
            content = .links(zip(lines, strings).compactMap { link($1, line: $0) })
        } else if declared == .numbers || declared == nil && !lines.isEmpty && strings.allSatisfy({ matches(metricPattern, $0) }) {
            content = .numbers(strings.compactMap(metric))
        } else {
            content = .text
        }
        let wide = words.contains("wide") || !words.contains("half") && defaultWide(content)
        return Block(title: mark.title, content: content, wide: wide, range: NSRange(location: mark.location, length: end - mark.location),
                     heading: headingRange, hint: hint, words: words, body: body)
    }

    /// Text and the day's activity take the full width unless a hint says otherwise; the rest
    /// pair up side by side.
    public static func defaultWide(_ content: Content) -> Bool {
        switch content {
        case .text, .live(.activity): true
        default: false
        }
    }

    /// The heading's line, and a setext underline after it.
    private static func headingLines(at location: Int, in text: NSString) -> Range<Int> {
        var line = text.lineRange(for: NSRange(location: location, length: 0))
        if NSMaxRange(line) < text.length {
            let next = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
            let underline = text.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines)
            let atx = text.substring(with: line).hasPrefix("#")
            if !atx, !underline.isEmpty, underline.allSatisfy({ $0 == "=" }) || underline.allSatisfy({ $0 == "-" }) {
                line = NSUnionRange(line, next)
            }
        }
        return line.location..<NSMaxRange(line)
    }

    private static func matches(_ pattern: NSRegularExpression, _ string: String) -> Bool {
        pattern.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }

    private static func link(_ string: String, line: NSRange) -> Link? {
        let ns = string as NSString
        guard let m = linkPattern.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var destination = ns.substring(with: m.range(at: 2))
        if destination.hasPrefix("<"), destination.hasSuffix(">") { destination = String(destination.dropFirst().dropLast()) }
        return Link(title: ns.substring(with: m.range(at: 1)), destination: destination, line: line)
    }

    private static func metric(_ string: String) -> Metric? {
        let ns = string as NSString
        guard let m = metricPattern.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let value = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
        let v = value as NSString
        var progress: Double?
        if let r = ratioPattern.firstMatch(in: value, range: NSRange(location: 0, length: v.length)),
           let a = Double(v.substring(with: r.range(at: 1))), let b = Double(v.substring(with: r.range(at: 2))), b > 0 {
            progress = min(max(a / b, 0), 1)
        } else if let p = percentPattern.firstMatch(in: value, range: NSRange(location: 0, length: v.length)), let a = Double(v.substring(with: p.range(at: 1))) {
            progress = min(max(a / 100, 0), 1)
        }
        return Metric(label: ns.substring(with: m.range(at: 1)), value: value, progress: progress)
    }

    private static func strippingHints(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !matches(hintPattern, $0.trimmingCharacters(in: .newlines)) }.joined(separator: "\n")
    }

    // MARK: Changing

    /// A block swapped with the one before (`up`) or after it; what lies between them stays.
    /// Each section moves as written; only the line breaks between them are made whole (a blank
    /// line before the next heading), and the note keeps its own ending.
    public static func moving(_ block: Block, up: Bool, in page: Page, text: String) -> TextPatch? {
        guard let i = page.blocks.firstIndex(of: block) else { return nil }
        let j = up ? i - 1 : i + 1
        guard page.blocks.indices.contains(j) else { return nil }
        let (a, b) = (page.blocks[min(i, j)].range, page.blocks[max(i, j)].range)
        let ns = text as NSString
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        func section(_ r: NSRange) -> String { trimmedBreaks(ns.substring(with: r)) + newline + newline }
        let union = NSRange(location: a.location, length: NSMaxRange(b) - a.location)
        let between = ns.substring(with: NSRange(location: NSMaxRange(a), length: b.location - NSMaxRange(a)))
        var replacement = section(b) + between + section(a)
        if NSMaxRange(union) == ns.length {
            let ending = String(text.reversed().prefix { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }.reversed())
            replacement = trimmedBreaks(replacement) + ending
        }
        guard var patch = TextPatch.minimal(from: ns.substring(with: union), to: replacement) else { return nil }
        patch.range.location += union.location
        return patch
    }

    /// The block at the full width or beside another: the hint says so only when it differs from
    /// the kind's own width, and goes when it has nothing left to say.
    public static func setting(wide: Bool, of block: Block, in text: String) -> TextPatch {
        let ns = text as NSString
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var words = block.words.filter { $0 != "wide" && $0 != "half" }
        if wide != defaultWide(block.content) { words.append(wide ? "wide" : "half") }
        let comment = "<!-- zephyr: " + words.joined(separator: ", ") + " -->"
        if let hint = block.hint {
            if words.isEmpty { return TextPatch(range: ns.lineRange(for: hint), replacement: "") }
            return TextPatch(range: hint, replacement: comment)
        }
        guard !words.isEmpty else { return TextPatch(range: NSRange(location: NSMaxRange(block.heading), length: 0), replacement: "") }
        let end = NSMaxRange(block.heading)
        let broken = end > 0 && [0x0A, 0x0D].contains(ns.character(at: end - 1))
        return TextPatch(range: NSRange(location: end, length: 0), replacement: broken ? comment + newline : newline + comment)
    }

    public static func removing(_ block: Block) -> TextPatch {
        TextPatch(range: block.range, replacement: "")
    }

    /// A new section at the end of the page: its heading, a hint when it has words, and its text.
    public static func appending(title: String, words: [String] = [], body: String = "", to text: String) -> TextPatch {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lead = text.isEmpty ? "" : text.hasSuffix(newline + newline) ? "" : text.hasSuffix(newline) ? newline : newline + newline
        var section = "## " + title.trimmingCharacters(in: .whitespacesAndNewlines) + newline
        if !words.isEmpty { section += "<!-- zephyr: " + words.joined(separator: ", ") + " -->" + newline }
        let body = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if !body.isEmpty { section += newline + body.replacingOccurrences(of: "\n", with: newline) + (body.hasSuffix("\n") ? "" : newline) }
        return TextPatch(range: NSRange(location: (text as NSString).length, length: 0), replacement: lead + section)
    }

    /// A link at the end of a links block.
    public static func linkAddition(title: String, destination: String, to block: Block, in text: String) -> TextPatch {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        // Angle brackets keep spaces and parentheses inside the destination.
        let target = destination.contains(where: { " ()".contains($0) }) ? "<" + destination + ">" : destination
        let line = "- [" + title.replacingOccurrences(of: "]", with: "") + "](" + target + ")"
        if case let .links(links) = block.content, let last = links.last {
            return TextPatch(range: NSRange(location: NSMaxRange(last.line), length: 0), replacement: newline + line)
        }
        let ns = text as NSString
        var end = NSMaxRange(block.range)
        while end > block.range.location, [0x0A, 0x0D].contains(ns.character(at: end - 1)) { end -= 1 }
        return TextPatch(range: NSRange(location: end, length: 0), replacement: newline + newline + line)
    }

    /// The page's title: its first-level heading, changed or put at the top.
    public static func retitling(_ title: String, in text: String) -> TextPatch {
        let ns = text as NSString
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let h = Outline.headings(in: ns).first(where: { $0.level == 1 }) {
            // The heading's line, or both lines of a setext heading, without the last break.
            let lines = headingLines(at: h.location, in: ns)
            var end = lines.upperBound
            while end > lines.lowerBound, [0x0A, 0x0D].contains(ns.character(at: end - 1)) { end -= 1 }
            return TextPatch(range: NSRange(location: lines.lowerBound, length: end - lines.lowerBound), replacement: "# " + title)
        }
        let at = ChunkIndex.frontMatterEnd(ns) ?? 0
        let broken = at == 0 || [0x0A, 0x0D].contains(ns.character(at: at - 1))
        return TextPatch(range: NSRange(location: at, length: 0), replacement: (broken ? "" : newline) + "# " + title + newline + newline)
    }

    /// Without its trailing line breaks (spaces at the end of a line stay: they can be a hard
    /// break or code).
    private static func trimmedBreaks(_ s: String) -> String {
        var s = Substring(s)
        while let last = s.last, last == "\n" || last == "\r" || last == "\r\n" { s = s.dropLast() }
        return String(s)
    }

    // MARK: Files

    /// `Space/Pages`: one note per page.
    public static var folder: URL { Space.folder.appendingPathComponent("Pages", isDirectory: true) }

    /// A file name for a new page: the title without path characters, numbered when taken.
    public static func fileName(for title: String, taken: Set<String>) -> String {
        var stem = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if stem.isEmpty || stem.hasPrefix(".") { stem = "Page" }
        var name = stem + ".md", n = 2
        let lower = Set(taken.map { $0.lowercased() })
        while lower.contains(name.lowercased()) {
            name = "\(stem) \(n).md"
            n += 1
        }
        return name
    }
}
