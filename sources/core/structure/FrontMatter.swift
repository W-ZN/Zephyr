import Foundation

/// YAML front matter shown as a compact property list. Only top-level `key: value` lines and
/// simple `- item` sequences are understood; anything else stays visible as source when revealed
/// (design §9: front matter edits touch top-level single-line scalars only).
public enum FrontMatterParser {
    public static func analyze(_ text: String) -> ChunkAnalysis {
        let t = TextLines(text)
        let length = t.units.count
        var count = t.lineCount
        if count > 1, t.lineStarts[count - 1] == length { count -= 1 }
        var lines: [LineInfo] = []
        var entries: [FrontMatterModel.Entry] = []
        for l in 0..<count {
            let start = t.lineStarts[l]
            lines.append(LineInfo(range: NSRange(location: start, length: t.fullEnd(ofLine: l) - start), kind: .component,
                                  quoteDepth: 0, listDepth: 0, isListItemStart: false, listMarkerWidth: 0, startsBlock: l == 0))
            guard l > 0, l < count - 1 else { continue }
            let end = t.contentEnd(ofLine: l)
            let line = String(decoding: t.units[start..<end], as: UTF16.self)
            if let first = line.first, first != " ", first != "\t", first != "#", let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let raw = line[line.index(after: colon)...]
                let leading = raw.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let value = scalar(String(raw.dropFirst(leading)))
                let valueStart = start + line[...colon].utf16.count + leading
                // Only plain or quoted single-line scalars are editable; flow collections, block
                // scalars, anchors and tags stay source-only. An empty value can be filled in.
                let editable = value.isEmpty || !"[{|>&*!".contains(value.first!)
                let range = editable ? NSRange(location: valueStart, length: value.utf16.count) : NSRange(location: NSNotFound, length: 0)
                entries.append(.init(key: key, value: unquote(value), valueRange: range))
            } else if let first = line.first, first == " " || first == "\t", !entries.isEmpty,
                      line.contains(where: { !$0.isWhitespace }) {
                // An indented line continues the entry above (nested map, folded scalar): source only.
                entries[entries.count - 1].valueRange = NSRange(location: NSNotFound, length: 0)
                if let item = sequenceItem(line) {
                    let last = entries.count - 1
                    entries[last].value = entries[last].value.isEmpty ? item : entries[last].value + ", " + item
                }
            } else if let item = sequenceItem(line), !entries.isEmpty {
                let last = entries.count - 1
                entries[last].value = entries[last].value.isEmpty ? item : entries[last].value + ", " + item
                entries[last].valueRange = NSRange(location: NSNotFound, length: 0)
            }
        }
        let end = count > 0 ? t.contentEnd(ofLine: count - 1) : 0
        let component = ComponentToken(kind: .frontMatter(FrontMatterModel(entries: entries)), range: NSRange(location: 0, length: end))
        return ChunkAnalysis(length: length, lines: lines, markers: [], inlines: [], components: [component], codeBlocks: [])
    }

    private static func sequenceItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else { return nil }
        return unquote(trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// The value's own text: a quoted scalar through its closing quote, a plain one up to a comment.
    static func scalar(_ s: String) -> String {
        guard let q = s.first else { return s }
        if q == "\"" || q == "'" {
            var i = s.index(after: s.startIndex)
            while i < s.endIndex {
                let c = s[i]
                if q == "\"", c == "\\" { i = s.index(after: i) } else if c == q {
                    let next = s.index(after: i)
                    if q == "'", next < s.endIndex, s[next] == "'" { i = next } else { return String(s[...i]) }
                }
                if i < s.endIndex { i = s.index(after: i) }
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
        let plain = s.range(of: " #").map { String(s[..<$0.lowerBound]) } ?? s
        return plain.trimmingCharacters(in: .whitespaces)
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, s.first == "'", s.last == "'" { return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        if s.count >= 2, s.first == "\"", s.last == "\"" {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if s.hasPrefix("["), s.hasSuffix("]") {
            return s.dropFirst().dropLast().split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: ", ")
        }
        return s
    }
}
