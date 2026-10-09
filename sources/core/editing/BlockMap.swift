import Foundation
import Markdown

/// A movable block (design §8 "拖动块"): a top-level block, or a list item together with its
/// nested content. Blocks with the same `group` are siblings and can be reordered.
public struct MarkdownBlock: Sendable, Equatable {
    /// Whole lines, including the last line's terminator when there is one.
    public var range: NSRange
    /// -1 for top-level blocks; otherwise the start offset of the list the item belongs to.
    public var group: Int
    public var isListItem: Bool

    public init(range: NSRange, group: Int, isListItem: Bool) {
        self.range = range
        self.group = group
        self.isListItem = isListItem
    }
}

public enum BlockMap {
    /// Movable blocks in document order. Front matter is not a block: it always stays first.
    /// `text` may be a run of whole chunks from inside a document; only the document start may
    /// hold front matter (`atDocumentStart`), elsewhere a leading `---` is a thematic break.
    public static func blocks(in text: String, atDocumentStart: Bool = true) -> [MarkdownBlock] {
        let ns = text as NSString
        let start = atDocumentStart ? ChunkIndex.frontMatterEnd(ns) ?? 0 : 0
        let body = ns.substring(from: start)
        let lines = TextLines(body)
        let masked = MathScanner.mask(body, spans: MathScanner.scan(lines))
        let document = Document(parsing: masked, options: [.disableSmartOpts])
        var result: [MarkdownBlock] = []

        func lineRange(_ node: Markup) -> NSRange? {
            guard let r = node.range else { return nil }
            let first = r.lowerBound.line - 1
            var last = r.upperBound.line - 1
            // cmark ends some blocks at column 1 of the following line, and a setext heading on
            // the line after its underline when text follows directly.
            if last > first, r.upperBound.column == 1 { last -= 1 }
            guard first >= 0, first < lines.lineCount else { return nil }
            last = min(last, lines.lineCount - 1)
            if node is Heading, last > first,
               let underline = (first + 1...last).first(where: { MarkdownAnalyzer.isSetextUnderline(lines.units[lines.lineStarts[$0]..<lines.contentEnd(ofLine: $0)]) }) {
                last = underline
            }
            let a = lines.lineStarts[first]
            let b = lines.fullEnd(ofLine: last)
            return NSRange(location: start + a, length: b - a)
        }

        func items(of list: Markup) {
            guard let listRange = lineRange(list) else { return }
            for item in list.children {
                guard let r = lineRange(item) else { continue }
                result.append(MarkdownBlock(range: r, group: listRange.location, isListItem: true))
                for child in item.children where child is UnorderedList || child is OrderedList { items(of: child) }
            }
        }

        for node in document.children {
            guard let r = lineRange(node) else { continue }
            if node is UnorderedList || node is OrderedList {
                items(of: node)
            } else {
                result.append(MarkdownBlock(range: r, group: -1, isListItem: false))
            }
        }
        return result
    }

    /// Checked on UTF-16 units: Swift treats "\r\n" as one Character, so `hasSuffix("\n")` misses it.
    static func endsWithLineBreak(_ s: String) -> Bool {
        guard let last = s.utf16.last else { return false }
        return last == 0x0A || last == 0x0D
    }

    /// The innermost block containing `location`.
    public static func block(at location: Int, in blocks: [MarkdownBlock]) -> MarkdownBlock? {
        blocks.filter { NSLocationInRange(location, $0.range) }.min { $0.range.length < $1.range.length }
    }

    /// Siblings of `block`, in order.
    public static func siblings(of block: MarkdownBlock, in blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        blocks.filter { $0.group == block.group }
    }

    /// Move `block` so it sits before `target` (a sibling), or after the last sibling when `target`
    /// is nil. Only the moved lines and the separators next to them change (principle 9).
    public static func move(_ block: MarkdownBlock, before target: MarkdownBlock?, in text: String, newline: String = "\n") -> String? {
        moved(block, before: target, siblings: siblings(of: block, in: blocks(in: text)), in: text, newline: newline)?.text
    }

    /// `move` with the siblings already known (e.g. from the chunks around the block); also returns
    /// where the moved block now starts.
    public static func moved(_ block: MarkdownBlock, before target: MarkdownBlock?, siblings group: [MarkdownBlock], in text: String, newline: String = "\n") -> (text: String, location: Int)? {
        guard let index = group.firstIndex(of: block) else { return nil }
        if let target, target == block || group.firstIndex(of: target) == index + 1 { return nil }
        if target == nil, index == group.count - 1 { return nil }
        let ns = text as NSString

        // Separator between siblings (e.g. one blank line between paragraphs, nothing in a tight list).
        func gap(after i: Int) -> NSRange {
            let end = NSMaxRange(group[i].range)
            return NSRange(location: end, length: group[i + 1].range.location - end)
        }
        var moved = ns.substring(with: block.range)
        if !endsWithLineBreak(moved) { moved += newline }
        let separator: String
        var removal = block.range
        if index + 1 < group.count {
            let g = gap(after: index)
            separator = ns.substring(with: g)
            removal.length += g.length
        } else {
            let g = gap(after: index - 1)
            separator = ns.substring(with: g)
            removal = NSRange(location: g.location, length: NSMaxRange(block.range) - g.location)
        }

        let removed = ns.replacingCharacters(in: removal, with: "") as NSString
        func shifted(_ location: Int) -> Int { location > removal.location ? location - removal.length : location }
        if let target {
            let at = shifted(target.range.location)
            return (removed.replacingCharacters(in: NSRange(location: at, length: 0), with: moved + separator), at)
        }
        // After the last sibling.
        let last = group[group.count - 1]
        var at = shifted(NSMaxRange(last.range))
        var prefix = separator
        let lastText = ns.substring(with: last.range)
        if !endsWithLineBreak(lastText) { prefix = newline + separator }
        at = min(at, removed.length)
        var insertion = prefix + moved
        if at == removed.length, !endsWithLineBreak(text), insertion.hasSuffix(newline) { insertion.removeLast(newline.count) }
        return (removed.replacingCharacters(in: NSRange(location: at, length: 0), with: insertion), at + (prefix as NSString).length)
    }
}
