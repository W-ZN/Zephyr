import Foundation
import Markdown

/// Turns one chunk of Markdown into presentation tokens (design §5 structure layer). Math is found
/// and masked first, the masked text goes through cmark, and every cmark position is mapped back
/// to UTF-16 offsets of the original chunk text.
public enum MarkdownAnalyzer {
    /// - Parameter references: link reference definitions from the whole document. They are appended
    ///   after the chunk (where they produce no nodes) so `[text][ref]` resolves across chunks.
    public static func analyze(_ text: String, references: String = "") -> ChunkAnalysis {
        var builder: Builder
        switch parse(text, references: references) {
        case let .plain(analysis): return analysis
        case let .parsed(parsed): builder = parsed
        }
        return builder.finish()
    }

    /// The text with the emphasis cmark leaves literal (`**差异A：**内容`, see `LooseEmphasis`) turned
    /// into `<strong>`, `<em>` and `<del>` tags, for outputs that go through cmark again (exports).
    public static func rewritingLooseEmphasis(_ text: String) -> String {
        guard text.contains(where: { $0 == "*" || $0 == "_" || $0 == "~" }), case let .parsed(builder) = parse(text, references: "") else { return text }
        guard !builder.loose.isEmpty else { return text }
        var units = Array(text.utf16)
        var edits: [(range: Range<Int>, tag: String)] = []
        for pair in builder.loose {
            let name = switch pair.style {
            case .strong: "strong"
            case .strikethrough: "del"
            default: "em"
            }
            edits.append((pair.open, "<\(name)>"))
            edits.append((pair.close, "</\(name)>"))
        }
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            units.replaceSubrange(edit.range, with: Array(edit.tag.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    private enum Parsed {
        case plain(ChunkAnalysis)
        case parsed(Builder)
    }

    private static func parse(_ text: String, references: String) -> Parsed {
        let lines = TextLines(text)
        if (0..<lines.lineCount).contains(where: { lines.contentEnd(ofLine: $0) - lines.lineStarts[$0] > maximumLineLength }) {
            return .plain(plain(lines))
        }
        let math = MathScanner.scan(lines)
        var source = MathScanner.mask(text, spans: math)
        if !references.isEmpty { source += "\n\n" + references }
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var builder = Builder(lines: lines, math: math)
        let children = Array(document.children)
        var i = 0
        while i < children.count {
            if let next = builder.container(children, at: i) { i = next; continue }
            builder.walk(children[i], quote: 0, list: 0)
            i += 1
        }
        return .parsed(builder)
    }

    /// Chunks with a longer line are shown as plain source, as VS Code stops tokenizing at the same
    /// length. Such lines are data (base64, minified JSON); parsing and styling them inline would
    /// cost the whole line on every keystroke (design §3.2: responsiveness over rendering).
    public static let maximumLineLength = 20_000

    static func plain(_ t: TextLines) -> ChunkAnalysis {
        var lines: [LineInfo] = []
        var previousBlank = true
        for l in 0..<t.lineCount {
            let start = t.lineStarts[l], end = t.fullEnd(ofLine: l)
            if start == end, l > 0 { break }  // the empty "line" after a final terminator
            let blank = t.units[start..<t.contentEnd(ofLine: l)].allSatisfy { $0 == 0x20 || $0 == 0x09 }
            lines.append(LineInfo(range: NSRange(location: start, length: end - start), kind: blank ? .blank : .paragraph,
                                  quoteDepth: 0, listDepth: 0, isListItemStart: false, listMarkerWidth: 0, startsBlock: !blank && previousBlank))
            previousBlank = blank
        }
        return ChunkAnalysis(length: t.units.count, lines: lines, markers: [], inlines: [], components: [], codeBlocks: [], isPlain: true)
    }

    /// Link reference definition lines (`[label]: destination`) of a whole document.
    public static func referenceDefinitions(in text: String) -> [(label: String, line: String)] {
        referenceDefinitions(in: text as NSString)
    }

    /// The same over UTF-16 text: only lines holding `]:` are read, so a 20 MB document without
    /// definitions costs one search, not a pass over every line.
    public static func referenceDefinitions(in text: NSString) -> [(label: String, line: String)] {
        var result: [(String, String)] = []
        var from = 0
        while from < text.length {
            let hit = text.range(of: "]:", options: .literal, range: NSRange(location: from, length: text.length - from))
            guard hit.location != NSNotFound else { break }
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: hit)
            from = max(end, NSMaxRange(hit))
            let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
            let trimmed = line.drop { $0 == " " }
            guard line.count - trimmed.count <= 3, trimmed.first == "[",
                  let close = trimmed.firstIndex(of: "]"), trimmed[trimmed.index(after: close)...].hasPrefix(":") else { continue }
            let label = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            guard !label.isEmpty else { continue }
            result.append((label.lowercased(), line))
        }
        return result
    }

    /// The definitions a chunk may refer to, so each parse only carries what it needs.
    public static func references(for chunk: String, from definitions: [(label: String, line: String)]) -> String {
        guard !definitions.isEmpty, chunk.contains("]") else { return "" }
        let lower = chunk.lowercased()
        return definitions.filter { lower.contains("[" + $0.label + "]") }.map(\.line).joined(separator: "\n")
    }

    /// A line of only `=` or only `-` after its container prefix (trailing spaces allowed).
    static func isSetextUnderline(_ line: ArraySlice<UInt16>) -> Bool {
        let body = line.dropFirst(Fence.prefixLength(line)).reversed().drop { $0 == 0x20 || $0 == 0x09 }
        guard let c = body.first, c == 0x3D || c == 0x2D else { return false }
        return body.allSatisfy { $0 == c }
    }

    /// A line of a single `-` after its quote prefix: cmark reads it as a setext underline, but
    /// under a line of text it is a list being started ("- " after a line break, or an empty item
    /// moved in with Tab). `nil` when the line is something else; `true` when a space follows the dash.
    static func loneDash(_ line: ArraySlice<UInt16>) -> Bool? {
        let body = line.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x3E }
        guard body.first == 0x2D else { return nil }
        let rest = body.dropFirst()
        guard rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return nil }
        return !rest.isEmpty
    }

    /// The portable HTML image subset Zephyr accepts as an interactive component. All other HTML
    /// remains literal source; this is deliberately not a general HTML parser.
    public struct SafeHTMLImage: Sendable, Equatable {
        public var source: String
        public var alt: String
        /// A requested point width. Renderers still clamp it to their available column.
        public var width: CGFloat?
        /// Missing `align` follows the active theme's image default.
        public var alignment: ImageAlignment?

        public init(source: String, alt: String, width: CGFloat?, alignment: ImageAlignment? = nil) {
            self.source = source
            self.alt = alt
            self.width = width
            self.alignment = alignment
        }
    }

    /// Inline HTML tags Zephyr styles, and the style each gives the text between its pair.
    static let inlineTagStyles: [String: InlineStyle] = [
        "b": .strong, "strong": .strong, "i": .emphasis, "em": .emphasis, "s": .strikethrough, "del": .strikethrough,
        "strike": .strikethrough, "code": .code, "tt": .code, "kbd": .keycap, "sup": .superscript, "sub": .subscript,
        "u": .underline, "ins": .underline, "mark": .highlight, "small": .small,
    ]
    private static let inlineTag = try! NSRegularExpression(pattern: #"^<(/?)([A-Za-z]+)(?:\s[^<>]*)?>$"#)

    /// The name of a styled inline tag and whether it closes, for one `InlineHTML` node.
    public static func styledTag(_ raw: String) -> (name: String, closing: Bool)? {
        let ns = raw as NSString
        guard let m = inlineTag.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: m.range(at: 2)).lowercased()
        guard inlineTagStyles[name] != nil else { return nil }
        return (name, m.range(at: 1).length == 1)
    }

    /// Parses exactly one standalone `<img>` tag. Only quoted `src`, `alt`, `align`, and finite
    /// positive numeric `width` attributes are allowed; duplicates and every other attribute are rejected.
    public static func safeHTMLImage(_ raw: String) -> SafeHTMLImage? {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.contains(where: \.isNewline), source.hasPrefix("<img"), source.dropFirst(4).first?.isWhitespace == true else { return nil }
        var index = source.index(source.startIndex, offsetBy: 4)
        var attributes: [String: String] = [:]
        while index < source.endIndex {
            while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }
            if source[index...].hasPrefix(">") {
                index = source.index(after: index)
                break
            }
            if source[index...].hasPrefix("/>") {
                index = source.index(index, offsetBy: 2)
                break
            }
            let nameStart = index
            while index < source.endIndex, source[index].isLetter { index = source.index(after: index) }
            guard nameStart != index else { return nil }
            let name = source[nameStart..<index].lowercased()
            guard ["src", "alt", "width", "align"].contains(name), attributes[name] == nil else { return nil }
            while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }
            guard index < source.endIndex, source[index] == "=" else { return nil }
            index = source.index(after: index)
            while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }
            guard index < source.endIndex, source[index] == "\"" || source[index] == "'" else { return nil }
            let quote = source[index]
            index = source.index(after: index)
            let valueStart = index
            while index < source.endIndex, source[index] != quote { index = source.index(after: index) }
            guard index < source.endIndex else { return nil }
            attributes[name] = decodeHTMLEntities(String(source[valueStart..<index]))
            index = source.index(after: index)
        }
        guard index == source.endIndex, let imageSource = attributes["src"], !imageSource.isEmpty, HTMLFragment.isSafeURL(imageSource) else { return nil }
        let width: CGFloat?
        if let rawWidth = attributes["width"] {
            guard let value = Double(rawWidth), value.isFinite, value > 0 else { return nil }
            width = CGFloat(min(value, 20_000))
        } else {
            width = nil
        }
        let alignment: ImageAlignment?
        if let rawAlignment = attributes["align"] {
            guard let value = ImageAlignment(rawValue: rawAlignment.lowercased()) else { return nil }
            alignment = value
        } else {
            alignment = nil
        }
        return SafeHTMLImage(source: imageSource, alt: attributes["alt"] ?? "", width: width, alignment: alignment)
    }

    /// A portable representation for an explicit image resize. The return value is nil for an
    /// invalid source or width, leaving callers to preserve their original Markdown untouched.
    public static func safeHTMLImageMarkup(source: String, alt: String, width: CGFloat? = nil, alignment: ImageAlignment? = nil) -> String? {
        guard !source.isEmpty, !source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("javascript:") else { return nil }
        if let width, (!width.isFinite || width <= 0) { return nil }
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\r", with: "&#13;")
                .replacingOccurrences(of: "\n", with: "&#10;")
        }
        let widthAttribute: String
        if let width {
            let description = String(Double(width))
            let serialized = description.hasSuffix(".0") ? String(description.dropLast(2)) : description
            widthAttribute = " width=\"" + serialized + "\""
        } else {
            widthAttribute = ""
        }
        let alignmentAttribute = alignment.map { " align=\"\($0.rawValue)\"" } ?? ""
        return "<img src=\"\(escape(source))\" alt=\"\(escape(alt))\"\(widthAttribute)\(alignmentAttribute)>"
    }

    /// A block image becomes an ImageBox only when cmark recognizes it as one image. Resizing can
    /// serialize its source and alt text, but must preserve a Markdown title that HTML conversion
    /// cannot represent in the current component contract.
    public static func standaloneMarkdownImageHasTitle(_ raw: String) -> Bool {
        let document = Document(parsing: raw, options: [.disableSmartOpts])
        guard document.childCount == 1, let paragraph = document.child(at: 0) as? Paragraph else { return true }
        let meaningful = paragraph.children.filter { child in
            if child is SoftBreak { return false }
            if let text = child as? Text { return !text.string.allSatisfy(\.isWhitespace) }
            return true
        }
        guard meaningful.count == 1, let image = meaningful.first as? Image else { return true }
        return image.title != nil
    }

    private static func decodeHTMLEntities(_ string: String) -> String {
        var output = ""
        var index = string.startIndex
        while index < string.endIndex {
            guard string[index] == "&", let end = string[index...].firstIndex(of: ";") else {
                output.append(string[index])
                index = string.index(after: index)
                continue
            }
            let entity = String(string[string.index(after: index)..<end])
            let value: Character?
            switch entity {
            case "amp": value = "&"
            case "lt": value = "<"
            case "gt": value = ">"
            case "quot": value = "\""
            case "apos": value = "'"
            default:
                let digits: String
                let radix: Int
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    digits = String(entity.dropFirst(2)); radix = 16
                } else if entity.hasPrefix("#") {
                    digits = String(entity.dropFirst()); radix = 10
                } else {
                    digits = ""; radix = 10
                }
                value = UInt32(digits, radix: radix).flatMap(UnicodeScalar.init).map(Character.init)
            }
            if let value { output.append(value) } else { output += "&" + entity + ";" }
            index = string.index(after: end)
        }
        return output
    }
}

private struct Builder {
    var t: TextLines
    let math: [MathSpan]
    let length: Int
    /// Lines of the chunk proper (cmark line numbers beyond this belong to appended references).
    let lineCount: Int
    var lines: [LineInfo]
    var markers: [Marker] = []
    var inlines: [InlineToken] = []
    /// Pairs found by `LooseEmphasis` (already in `inlines`), kept for exports.
    var loose: [LooseEmphasis.Pair] = []
    var components: [ComponentToken] = []
    var codeBlocks: [CodeBlockToken] = []
    /// Line → offset where its list marker starts, for lines that open a list item.
    var itemMarkerStart: [Int: Int] = [:]
    /// Line → container prefix width that fenced code lines drop.
    var codeIndent: [Int: Int] = [:]

    init(lines t: TextLines, math: [MathSpan]) {
        self.t = t
        self.math = math
        length = t.units.count
        var count = t.lineCount
        if count > 1, t.lineStarts[count - 1] == length { count -= 1 }
        lineCount = count
        lines = (0..<count).map { i in
            let start = t.lineStarts[i]
            return LineInfo(range: NSRange(location: start, length: t.fullEnd(ofLine: i) - start),
                            kind: t.isBlank(line: i) ? .blank : .paragraph,
                            quoteDepth: 0, listDepth: 0, isListItemStart: false, listMarkerWidth: 0)
        }
    }

    // MARK: Positions

    mutating func span(_ node: Markup) -> Range<Int>? {
        guard let r = node.range, r.lowerBound.line <= lineCount else { return nil }
        let a = t.offset(line: r.lowerBound.line, utf8Column: r.lowerBound.column)
        let b = r.upperBound.line > lineCount ? length : t.offset(line: r.upperBound.line, utf8Column: r.upperBound.column)
        guard a < length || (a == length && length == 0) else { return nil }
        return a..<min(max(a, b), length)
    }

    /// Union of the children's spans, clamped to `parent`: cmark positions are occasionally
    /// inconsistent between a node and its children (seen with CRLF input in fuzzing).
    mutating func childrenSpan(_ node: Markup, within parent: Range<Int>) -> Range<Int>? {
        var lower: Int?
        var upper: Int?
        for child in node.children {
            guard let r = span(child) else { continue }
            if lower == nil { lower = r.lowerBound }
            upper = r.upperBound
        }
        guard let lower, let upper else { return nil }
        let a = min(max(lower, parent.lowerBound), parent.upperBound)
        return a..<min(max(a, upper), parent.upperBound)
    }

    func lineRange(_ r: Range<Int>) -> ClosedRange<Int> {
        let first = min(t.line(containing: r.lowerBound), lineCount - 1)
        let last = min(t.line(containing: max(r.lowerBound, r.upperBound - 1)), lineCount - 1)
        return first...max(first, last)
    }

    func contentEnd(_ line: Int) -> Int { t.contentEnd(ofLine: line) }

    func slice(_ line: Int) -> ArraySlice<UInt16> { t.units[t.lineStarts[line]..<t.contentEnd(ofLine: line)] }

    func string(_ r: Range<Int>) -> String { String(decoding: t.units[r], as: UTF16.self) }

    static func ns(_ r: Range<Int>) -> NSRange { NSRange(location: r.lowerBound, length: r.count) }

    mutating func hide(_ r: Range<Int>, reveal: Range<Int>) {
        guard !r.isEmpty else { return }
        markers.append(Marker(range: Self.ns(r), style: .hide, revealRange: Self.ns(reveal)))
    }

    // MARK: Walk

    mutating func walk(_ node: Markup, quote: Int, list: Int) {
        guard let r = span(node) else { return }
        if node is Paragraph || node is Heading || node is CodeBlock || node is HTMLBlock || node is ThematicBreak || node is Table {
            lines[lineRange(r).lowerBound].startsBlock = true
        }
        switch node {
        case is BlockQuote:
            for l in lineRange(r) { lines[l].quoteDepth = quote + 1 }
            for child in node.children { walk(child, quote: quote + 1, list: list) }
        case let item as ListItem:
            for l in lineRange(r) { lines[l].listDepth = list + 1 }
            listItem(item, r, depth: list + 1)
            for child in item.children { walk(child, quote: quote, list: list + 1) }
        case let heading as Heading:
            self.heading(heading, r)
            inlineChildren(heading)
        case let paragraph as Paragraph:
            if !blockImage(paragraph, r) { inlineChildren(paragraph) }
        case let code as CodeBlock:
            codeBlock(code, r)
        case let html as HTMLBlock:
            if let image = htmlImage(r) {
                let line = lineRange(r).lowerBound
                lines[line].kind = .component
                components.append(ComponentToken(kind: .image(source: image.source, alt: image.alt, width: image.width, alignment: image.alignment), range: Self.ns(t.lineStarts[line]..<contentEnd(line))))
            } else if let fragment = HTMLFragment.parse(html.rawHTML) {
                // The safe subset draws as a block; anything else stays visible source (design §9).
                let block = lineRange(r)
                for l in block { lines[l].kind = .component }
                components.append(ComponentToken(kind: .html(fragment), range: Self.ns(r.lowerBound..<contentEnd(block.upperBound))))
            } else {
                for l in lineRange(r) { lines[l].kind = .html }
            }
        case is ThematicBreak:
            let l = lineRange(r).lowerBound
            lines[l].kind = .component
            components.append(ComponentToken(kind: .thematicBreak, range: Self.ns(r.lowerBound..<contentEnd(l))))
        case let table as Table:
            self.table(table, r)
        default:
            for child in node.children { walk(child, quote: quote, list: list) }
        }
    }

    /// An aligned container starting at `children[i]` (`HTMLContainer`), drawn as one HTML block
    /// from its opening to its closing tag. Returns the index after the closing tag, or nil.
    mutating func container(_ children: [Markup], at i: Int) -> Int? {
        guard children[i] is HTMLBlock, let start = span(children[i]),
              let (element, close) = HTMLContainer.container(in: children, at: i), let end = span(children[close]) else { return nil }
        // Formulas belong to the math scanner, not to the HTML subset.
        guard !math.contains(where: { $0.range.overlaps(start.lowerBound..<end.upperBound) }) else { return nil }
        let block = lineRange(start.lowerBound..<end.upperBound)
        for l in block { lines[l].kind = .component }
        lines[block.lowerBound].startsBlock = true
        components.append(ComponentToken(kind: .html(HTMLFragment(nodes: [.element(element)])), range: Self.ns(start.lowerBound..<contentEnd(block.upperBound))))
        return close + 1
    }

    mutating func inlineChildren(_ node: Markup) {
        for child in node.children { inline(child) }
        pairInlineTags(node.children)
        pairLooseEmphasis(node)
    }

    /// `**差异A：**内容`: delimiters cmark left as text (it wants a space or a letter beside the
    /// closing run), paired by `LooseEmphasis` among one parent's literal text.
    mutating func pairLooseEmphasis(_ node: Markup) {
        var texts: [Range<Int>] = []
        for child in node.children where child is Text {
            if let r = span(child) { texts.append(r) }
        }
        guard !texts.isEmpty else { return }
        for pair in LooseEmphasis.pairs(in: t.units, texts: texts, blocked: math.map(\.range)) {
            let whole = pair.open.lowerBound..<pair.close.upperBound
            hide(pair.open, reveal: whole)
            hide(pair.close, reveal: whole)
            inlines.append(InlineToken(style: pair.style, range: Self.ns(whole)))
            loose.append(pair)
        }
    }

    /// `<kbd>⌘</kbd>`: a pair of styled tags among one parent's inline nodes. The tags hide like
    /// Markdown delimiters (shown with the caret in the element) and the text between is styled.
    mutating func pairInlineTags(_ children: some Sequence<Markup>) {
        // One stack per tag name and one pass over the tokens at the end: linear in the tags.
        var open: [String: [Range<Int>]] = [:]
        var paired: Set<NSRange> = []
        for child in children {
            guard let html = child as? InlineHTML, let r = span(child), let tag = MarkdownAnalyzer.styledTag(html.rawHTML) else { continue }
            guard tag.closing else { open[tag.name, default: []].append(r); continue }
            guard let start = open[tag.name]?.popLast(), let style = MarkdownAnalyzer.inlineTagStyles[tag.name] else { continue }
            let whole = start.lowerBound..<r.upperBound
            hide(start, reveal: whole)
            hide(r, reveal: whole)
            paired.insert(Self.ns(start))
            paired.insert(Self.ns(r))
            if start.upperBound < r.lowerBound { inlines.append(InlineToken(style: style, range: Self.ns(start.upperBound..<r.lowerBound))) }
        }
        if !paired.isEmpty { inlines.removeAll { $0.style == .html && paired.contains($0.range) } }
    }

    mutating func inline(_ node: Markup) {
        guard let r = span(node) else { return }
        switch node {
        case is Strong:
            delimited(node, r, .strong)
        case is Emphasis:
            delimited(node, r, .emphasis)
        case is Strikethrough:
            delimited(node, r, .strikethrough)
        case is InlineCode:
            var run = 0
            while r.lowerBound + run < r.upperBound, t.units[r.lowerBound + run] == 0x60 { run += 1 }
            guard run > 0, r.count >= run * 2 else { return }
            hide(r.lowerBound..<(r.lowerBound + run), reveal: r)
            hide((r.upperBound - run)..<r.upperBound, reveal: r)
            inlines.append(InlineToken(style: .code, range: Self.ns(r)))
        case let link as Link:
            wrapped(node, r, .link(destination: link.destination))
        case let image as Image:
            // Revealed, the source reads like a link; otherwise the image stands in for it.
            wrapped(node, r, .link(destination: image.source))
            if let source = image.source, !source.isEmpty {
                components.append(ComponentToken(kind: .inlineImage(source: source, alt: image.plainText), range: Self.ns(r)))
            }
        case let html as InlineHTML:
            inlines.append(InlineToken(style: .html, range: Self.ns(r)))
            if let image = Self.inlineHTMLImage(html.rawHTML) {
                components.append(ComponentToken(kind: image, range: Self.ns(r)))
            }
        default:
            inlineChildren(node)
        }
    }

    /// `**x**`, `*x*`, `~~x~~`: delimiters are whatever the node covers beyond its children.
    mutating func delimited(_ node: Markup, _ r: Range<Int>, _ style: InlineStyle) {
        if let inner = childrenSpan(node, within: r) {
            hide(r.lowerBound..<inner.lowerBound, reveal: r)
            hide(inner.upperBound..<r.upperBound, reveal: r)
        }
        inlines.append(InlineToken(style: style, range: Self.ns(r)))
        inlineChildren(node)
    }

    /// Links and inline images: `[` / `![` before the text and `](…)` or `][ref]` after it.
    mutating func wrapped(_ node: Markup, _ r: Range<Int>, _ style: InlineStyle) {
        guard let inner = childrenSpan(node, within: r), !inner.isEmpty else {
            inlines.append(InlineToken(style: style, range: Self.ns(r)))
            return
        }
        hide(r.lowerBound..<inner.lowerBound, reveal: r)
        hide(inner.upperBound..<r.upperBound, reveal: r)
        inlines.append(InlineToken(style: style, range: Self.ns(inner)))
        inlineChildren(node)
    }

    // MARK: Blocks

    mutating func heading(_ heading: Heading, _ r: Range<Int>) {
        let span = lineRange(r)
        let first = span.lowerBound
        let underline = span.upperBound
        let atx = t.units[r.lowerBound] == 0x23  // '#'
        if atx {
            lines[first].kind = .heading(level: heading.level)
            let end = max(r.lowerBound, contentEnd(first))
            let reveal = r.lowerBound..<end
            if let inner = childrenSpan(heading, within: r.lowerBound..<max(r.lowerBound, end)) {
                hide(r.lowerBound..<inner.lowerBound, reveal: reveal)
                if t.units[inner.upperBound..<end].contains(0x23) { hide(inner.upperBound..<end, reveal: reveal) }
            } else {
                hide(r.lowerBound..<end, reveal: reveal)
            }
        } else {
            // cmark ends a setext heading on the line after its underline when text follows directly.
            let underline = (first + 1...max(first + 1, underline)).first { $0 < lineCount && MarkdownAnalyzer.isSetextUnderline(slice($0)) } ?? underline
            // A lone dash keeps the text above a paragraph: typed text, or with a space an empty
            // bullet (design §8.1), never a heading that flips back on the next keystroke.
            if let item = MarkdownAnalyzer.loneDash(slice(underline)) {
                if item { emptyItem(underline) }
                return
            }
            for l in first..<underline { lines[l].kind = .heading(level: heading.level) }
            lines[underline].kind = .setextUnderline
            let start = t.lineStarts[underline] + Fence.prefixLength(slice(underline))
            hide(start..<contentEnd(underline), reveal: r.lowerBound..<contentEnd(underline))
        }
    }

    mutating func listItem(_ item: ListItem, _ r: Range<Int>, depth: Int) {
        let line = lineRange(r).lowerBound
        let lineEnd = contentEnd(line)
        var content = lineEnd
        if let first = item.child(at: 0), let c = span(first), c.lowerBound <= lineEnd { content = c.lowerBound }
        var markerEnd = content
        if item.checkbox != nil {
            // The paragraph starts after the checkbox: split "- [ ] " into bullet and box.
            var box = r.lowerBound
            while box < content, t.units[box] != 0x5B { box += 1 }  // '['
            if box < content {
                markerEnd = box
                markers.append(Marker(range: Self.ns(box..<content), style: .checkbox(checked: item.checkbox == .checked), revealRange: Self.ns(box..<content)))
            }
        }
        let ordered = item.parent is OrderedList
        let marker = r.lowerBound..<markerEnd
        markers.append(Marker(range: Self.ns(marker), style: ordered ? .ordinal : .bullet(depth: depth), revealRange: Self.ns(marker)))
        lines[line].isListItemStart = true
        lines[line].startsList = item.indexInParent == 0
        lines[line].listMarkerWidth = content - r.lowerBound
        itemMarkerStart[line] = r.lowerBound
    }

    /// An empty bullet item one level inside the line's container, where cmark saw an underline.
    mutating func emptyItem(_ line: Int) {
        let end = contentEnd(line)
        var dash = t.lineStarts[line]
        while t.units[dash] != 0x2D { dash += 1 }
        let depth = lines[line].listDepth + 1
        markers.append(Marker(range: Self.ns(dash..<end), style: .bullet(depth: depth), revealRange: Self.ns(dash..<end)))
        lines[line].listDepth = depth
        lines[line].isListItemStart = true
        lines[line].startsList = true
        lines[line].listMarkerWidth = end - dash
        itemMarkerStart[line] = dash
    }

    mutating func codeBlock(_ code: CodeBlock, _ r: Range<Int>) {
        let span = lineRange(r)
        let fence = Fence(opening: slice(span.lowerBound))
        if let fence {
            lines[span.lowerBound].kind = .codeFence(language: code.language)
            for l in span where l > span.lowerBound {
                lines[l].kind = .code
                codeIndent[l] = fence.indent
            }
            if span.upperBound > span.lowerBound, fence.isClosed(by: slice(span.upperBound)) {
                lines[span.upperBound].kind = .codeFence(language: nil)
            }
            for l in span {
                if case .codeFence = lines[l].kind {
                    let start = t.lineStarts[l] + Fence.prefixLength(slice(l))
                    hide(start..<contentEnd(l), reveal: r)
                }
            }
        } else {
            for l in span { lines[l].kind = .code }
        }
        codeBlocks.append(CodeBlockToken(range: Self.ns(r), language: code.language, isFenced: fence != nil))
        if fence != nil, code.language?.lowercased() == "mermaid", let diagram = MermaidDiagram.parse(code.code) {
            components.append(ComponentToken(kind: .diagram(diagram), range: Self.ns(r)))
        }
    }

    /// A paragraph that is a single image renders as a block image.
    mutating func blockImage(_ paragraph: Paragraph, _ r: Range<Int>) -> Bool {
        let meaningful = paragraph.children.filter { child in
            if child is SoftBreak { return false }
            if let text = child as? Text { return !text.string.allSatisfy(\.isWhitespace) }
            return true
        }
        guard meaningful.count == 1 else { return false }
        let kind: ComponentKind
        if let image = meaningful.first as? Image, let source = image.source, !source.isEmpty {
            kind = .image(source: source, alt: image.plainText)
        } else if let html = meaningful.first as? InlineHTML, let image = MarkdownAnalyzer.safeHTMLImage(html.rawHTML) {
            kind = .image(source: image.source, alt: image.alt, width: image.width, alignment: image.alignment)
        } else {
            return false
        }
        for l in lineRange(r) { lines[l].kind = .component }
        components.append(ComponentToken(kind: kind, range: Self.ns(r)))
        return true
    }

    /// An inline `<img>` tag in the safe subset, with its point sizes (percentages are left to
    /// the image's own size inside a line).
    static func inlineHTMLImage(_ raw: String) -> ComponentKind? {
        guard raw.hasPrefix("<img"), let fragment = HTMLFragment.parse(raw), fragment.nodes.count == 1,
              case let .element(img) = fragment.nodes[0], img.name == "img", let source = img["src"], !source.isEmpty else { return nil }
        func points(_ value: String?) -> CGFloat? {
            guard let value, let n = Double(value.hasSuffix("px") ? String(value.dropLast(2)) : value), n.isFinite, n > 0 else { return nil }
            return CGFloat(min(n, 20_000))
        }
        return .inlineImage(source: source, alt: img["alt"] ?? "", width: points(img["width"]), height: points(img["height"]))
    }

    /// The only HTML that becomes an active component is the public strict standalone-image
    /// subset. Everything else stays literal HTML.
    func htmlImage(_ r: Range<Int>) -> (source: String, alt: String, width: CGFloat?, alignment: ImageAlignment?)? {
        let line = lineRange(r)
        guard line.lowerBound == line.upperBound else { return nil }
        guard let image = MarkdownAnalyzer.safeHTMLImage(string(t.lineStarts[line.lowerBound]..<contentEnd(line.lowerBound))) else { return nil }
        return (image.source, image.alt, image.width, image.alignment)
    }

    mutating func table(_ table: Table, _ r: Range<Int>) {
        let block = lineRange(r)
        for l in block { lines[l].kind = .component }
        func cells(_ row: Markup) -> [String] {
            row.children.map { cell in
                // An empty cell has no children; cmark gives it the range of its pipe.
                guard cell.childCount > 0, let c = span(cell) else { return "" }
                return string(c).trimmingCharacters(in: .whitespaces)
            }
        }
        let header = cells(table.head)
        let rows = table.body.children.map { cells($0) }
        let alignments: [TableModel.Alignment] = table.columnAlignments.map {
            switch $0 {
            case .center: .center
            case .right: .right
            default: .left
            }
        }
        let model = TableModel(header: header, rows: rows, alignments: alignments)
        components.append(ComponentToken(kind: .table(model), range: Self.ns(r.lowerBound..<contentEnd(block.upperBound))))
    }

    // MARK: Finish

    mutating func finish() -> ChunkAnalysis {
        applyMath()
        structuralPrefixes()
        containerOnlyLinesAreBlank()
        emptyQuoteLines()
        markers.sort { $0.range.location < $1.range.location }
        inlines.sort { $0.range.location < $1.range.location }
        components.sort { $0.range.location < $1.range.location }
        return ChunkAnalysis(length: length, lines: lines, markers: markers, inlines: inlines, components: components, codeBlocks: codeBlocks)
    }

    mutating func applyMath() {
        guard !math.isEmpty else { return }
        let codeSpans = inlines.filter { $0.style == .code }.map { $0.range.location..<NSMaxRange($0.range) }
        // An image already stands for its whole source, alt text included: components never overlap.
        let images = components.compactMap { c -> Range<Int>? in
            switch c.kind {
            case .inlineImage, .image: return c.range.location..<NSMaxRange(c.range)
            default: return nil
            }
        }
        for m in math {
            let first = t.line(containing: m.range.lowerBound)
            guard first < lineCount else { continue }
            switch lines[first].kind {
            case .code, .codeFence, .html: continue
            default: break
            }
            if codeSpans.contains(where: { $0.overlaps(m.range) }) || images.contains(where: { $0.overlaps(m.range) }) { continue }
            let tex = string(m.content)
            if m.isBlock {
                let span = lineRange(m.range)
                for l in span { lines[l].kind = .component }
                lines[span.lowerBound].startsBlock = true
                markers.removeAll { m.range.contains($0.range.location) && $0.style == .hide }
                inlines.removeAll { m.range.contains($0.range.location) }
                components.append(ComponentToken(kind: .displayMath(tex: tex), range: Self.ns(m.range)))
            } else {
                components.append(ComponentToken(kind: .inlineMath(tex: tex, display: m.display), range: Self.ns(m.range)))
            }
        }
    }

    /// A line holding only container prefixes (`>`, `> >`) separates blocks inside a quote: it is
    /// presented as a blank line (its prefix stays hidden) so spacing follows the block rules.
    mutating func containerOnlyLinesAreBlank() {
        for l in 0..<lineCount where lines[l].kind == .paragraph && !lines[l].isListItemStart && !lines[l].startsBlock {
            if slice(l).allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x3E }) { lines[l].kind = .blank }
        }
    }

    /// A line of only `>` that is no gap between two lines of its quote (a quote just begun with
    /// `> `, or one that ends in an empty line while typing) is an empty line of the quote: it has
    /// its height and its bar, and its markers hide like any quote line's.
    mutating func emptyQuoteLines() {
        for l in 0..<lineCount where lines[l].kind == .blank && lines[l].quoteDepth > 0 && slice(l).contains(0x3E) {
            let depth = lines[l].quoteDepth
            func content(_ i: Int) -> Bool { i >= 0 && i < lineCount && lines[i].kind != .blank && lines[i].quoteDepth >= depth }
            guard !(content(l - 1) && content(l + 1)) else { continue }
            lines[l].kind = .paragraph
            // A quote begun here starts a block, with its space above.
            lines[l].startsBlock = !content(l - 1)
            let start = t.lineStarts[l], end = contentEnd(l)
            guard end > start else { continue }
            markers.append(Marker(range: NSRange(location: start, length: end - start), style: .structural, revealRange: NSRange(location: start, length: end - start)))
        }
    }

    /// Container prefixes (`>` and list indentation) are hidden and replaced by paragraph indents.
    mutating func structuralPrefixes() {
        for l in 0..<lineCount {
            let info = lines[l]
            guard info.quoteDepth > 0 || info.listDepth > 0, info.kind != .blank else { continue }
            let start = t.lineStarts[l]
            let end = contentEnd(l)
            var content: Int
            if let marker = itemMarkerStart[l] {
                content = marker
            } else if case .codeFence = info.kind {
                continue
            } else if info.kind == .code {
                var i = start
                let limit = start + (codeIndent[l] ?? 0)
                if codeIndent[l] == nil {
                    // Indented code inside a quote: drop only the quote markers.
                    var lastQuote = start
                    while i < end, t.units[i] == 0x20 || t.units[i] == 0x3E { if t.units[i] == 0x3E { lastQuote = i + 1 }; i += 1 }
                    content = lastQuote < end && t.units[lastQuote] == 0x20 ? lastQuote + 1 : lastQuote
                } else {
                    while i < min(limit, end), t.units[i] == 0x20 || t.units[i] == 0x09 || t.units[i] == 0x3E { i += 1 }
                    content = i
                }
            } else {
                var i = start
                while i < end, t.units[i] == 0x20 || t.units[i] == 0x09 || t.units[i] == 0x3E { i += 1 }
                content = i
            }
            guard content > start else { continue }
            markers.append(Marker(range: NSRange(location: start, length: content - start), style: .structural, revealRange: NSRange(location: start, length: content - start)))
        }
    }
}
