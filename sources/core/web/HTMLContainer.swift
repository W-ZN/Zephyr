import Foundation
import Markdown

/// An aligned HTML element alone on its line with Markdown between it and its closing tag, as
/// README headers write it (`<div align="center">`, a blank line, a heading and badges, a blank
/// line, `</div>`). GitHub centers the Markdown inside; Zephyr converts it to the HTML subset and
/// draws the whole container as one block (design §9). Content the subset cannot hold (a list, a
/// table, code, a formula) leaves the container as it was: its tags as source, the Markdown as
/// Markdown.
public enum HTMLContainer {
    private static let openingTag = try! NSRegularExpression(pattern: #"^\s{0,3}<(div|p|center)(?:\s+align\s*=\s*(?:"([^"]*)"|'([^']*)'|([A-Za-z]+)))?\s*>\s*$"#, options: [.caseInsensitive])

    /// The element a line opens and its alignment, when the line is only that start tag and the
    /// alignment changes something (center or right).
    static func opening(_ line: String) -> (name: String, align: String)? {
        let ns = line as NSString
        guard line.hasPrefix("<") || line.hasPrefix(" "), let m = openingTag.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: m.range(at: 1)).lowercased()
        let value = (2...4).map { m.range(at: $0) }.first { $0.location != NSNotFound }.map { ns.substring(with: $0).lowercased() }
        let align = name == "center" ? "center" : (value ?? "")
        guard align == "center" || align == "right" else { return nil }
        return (name, align)
    }

    static func closes(_ line: String, _ name: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).lowercased() == "</" + name + ">"
    }

    /// The container `children[i]` opens: one element holding the converted Markdown, and the
    /// index of its closing tag. Shared by the editor and the HTML export.
    public static func container(in children: [Markup], at i: Int) -> (element: HTMLFragment.Element, close: Int)? {
        guard let open = children[i] as? HTMLBlock, let tag = opening(open.rawHTML.trimmingCharacters(in: .newlines)) else { return nil }
        guard let close = children[(i + 1)...].firstIndex(where: { ($0 as? HTMLBlock).map { closes($0.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines), tag.name) } ?? false }) else { return nil }
        let blocks = Array(children[(i + 1)..<close])
        // Formulas belong to the math scanner, not to the HTML subset.
        guard MathScanner.scan(TextLines(blocks.map { $0.format() }.joined(separator: "\n\n"))).isEmpty,
              let inner = nodes(blocks) else { return nil }
        return (HTMLFragment.Element(name: tag.name, attributes: tag.name == "center" ? [:] : ["align": tag.align], children: inner), close)
    }

    /// The Markdown blocks as fragment nodes, or nil when one of them has no counterpart.
    static func nodes(_ blocks: [Markup]) -> [HTMLFragment.Node]? {
        var out: [HTMLFragment.Node] = []
        for block in blocks {
            switch block {
            case let heading as Heading:
                guard let children = inline(heading.children) else { return nil }
                out.append(.element(.init(name: "h\(min(max(heading.level, 1), 6))", children: children)))
            case let paragraph as Paragraph:
                guard let children = inline(paragraph.children) else { return nil }
                out.append(.element(.init(name: "p", children: children)))
            case is ThematicBreak:
                out.append(.element(.init(name: "hr")))
            case let html as HTMLBlock:
                guard let fragment = HTMLFragment.parse(html.rawHTML) else { return nil }
                out += fragment.nodes
            default:
                return nil
            }
        }
        return out.contains(where: \.isVisible) ? out : nil
    }

    /// Inline Markdown and inline HTML together, through the subset's own parser: paired tags
    /// (`<kbd>⌘</kbd>`, `<sup>2</sup>`) nest as they would in the browser, and a tag outside the
    /// subset leaves the container as source.
    private static func inline(_ children: some Sequence<Markup>) -> [HTMLFragment.Node]? {
        guard let html = source(children) else { return nil }
        if html.allSatisfy(\.isWhitespace) { return [] }
        // Wrapped, so plain text parses too; the wrapper is dropped again.
        guard let fragment = HTMLFragment.parse("<span>" + html + "</span>"), fragment.nodes.count == 1,
              case let .element(span) = fragment.nodes[0], span.name == "span" else { return nil }
        return span.children
    }

    private static func source(_ children: some Sequence<Markup>) -> String? {
        var out = ""
        func text(_ s: String) -> String { HTMLFragment.escape(s, quote: false) }
        func attribute(_ s: String) -> String { HTMLFragment.escape(s, quote: true) }
        for child in children {
            switch child {
            case let node as Text: out += text(node.string)
            case is SoftBreak: out += "\n"
            case is LineBreak: out += "<br>"
            case let code as InlineCode: out += "<code>" + text(code.code) + "</code>"
            case let node as Emphasis: guard let c = source(node.children) else { return nil }; out += "<em>" + c + "</em>"
            case let node as Strong: guard let c = source(node.children) else { return nil }; out += "<strong>" + c + "</strong>"
            case let node as Strikethrough: guard let c = source(node.children) else { return nil }; out += "<del>" + c + "</del>"
            case let link as Link:
                guard let c = source(link.children) else { return nil }
                let href = link.destination ?? ""
                guard HTMLFragment.isSafeURL(href) else { return nil }
                out += (href.isEmpty ? "<a>" : "<a href=\"" + attribute(href) + "\">") + c + "</a>"
            case let image as Image:
                guard let source = image.source, !source.isEmpty, HTMLFragment.isSafeURL(source) else { return nil }
                out += "<img src=\"" + attribute(source) + "\" alt=\"" + attribute(image.plainText) + "\">"
            case let html as InlineHTML:
                out += html.rawHTML
            default:
                return nil
            }
        }
        return out
    }
}
