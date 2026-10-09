import Foundation

/// Cell-level edits of a GFM pipe table (design §8: editing a table writes a minimal patch). Each
/// operation takes the table's source (header line through last row, no final line break) and
/// returns the new source; callers diff the two, so untouched cells keep their bytes and padding.
/// Rows are numbered as displayed: 0 is the header, 1… are body rows (the delimiter line is skipped).
public enum TableEdit {
    public enum Alignment: Sendable { case none, left, center, right }

    struct Line {
        var range: NSRange       // without the line break
        var body: Int            // after the container prefix (quote markers, indentation)
        var leadingPipe: Bool
        var trailingPipe: Bool
        var cells: [NSRange]     // between pipes, untrimmed
    }

    static func lines(_ table: String) -> [Line] {
        let t = TextLines(table)
        let u = t.units
        var result: [Line] = []
        for l in 0..<t.lineCount {
            let start = t.lineStarts[l], end = t.contentEnd(ofLine: l)
            if start == end, l == t.lineCount - 1, l > 0 { break }
            var body = start
            while body < end, [0x20, 0x09, 0x3E].contains(u[body]) { body += 1 }   // spaces, tabs, `>`
            var cells: [NSRange] = []
            var cellStart = body
            var leading = false, trailing = false
            var i = body
            while i < end {
                if u[i] == 0x5C { i += 2; continue }   // `\|` stays in the cell
                if u[i] == 0x7C {
                    if i == body { leading = true } else { cells.append(NSRange(location: cellStart, length: i - cellStart)) }
                    cellStart = i + 1
                }
                i += 1
            }
            let rest = NSRange(location: cellStart, length: max(0, end - cellStart))
            if cellStart > body, (table as NSString).substring(with: rest).allSatisfy({ $0 == " " || $0 == "\t" }) {
                trailing = true
            } else {
                cells.append(rest)
            }
            result.append(Line(range: NSRange(location: start, length: end - start), body: body, leadingPipe: leading, trailingPipe: trailing, cells: cells))
        }
        return result
    }

    /// Source line index of a displayed row.
    static func lineIndex(_ row: Int) -> Int { row == 0 ? 0 : row + 1 }

    static func trimmed(_ r: NSRange, in ns: NSString) -> NSRange {
        var a = r.location, b = NSMaxRange(r)
        while a < b, [0x20, 0x09].contains(ns.character(at: a)) { a += 1 }
        while b > a, [0x20, 0x09].contains(ns.character(at: b - 1)) { b -= 1 }
        return NSRange(location: a, length: b - a)
    }

    /// The cell's source (inline Markdown, escapes included), or nil outside the table.
    public static func cell(_ table: String, row: Int, column: Int) -> String? {
        let ls = lines(table)
        let i = lineIndex(row)
        guard i < ls.count, row >= 0, column >= 0 else { return nil }
        guard column < ls[i].cells.count else { return column < (ls.first?.cells.count ?? 0) ? "" : nil }
        let ns = table as NSString
        return ns.substring(with: trimmed(ls[i].cells[column], in: ns))
    }

    /// One line of a cell: pipes are escaped, line breaks become spaces.
    static func escaped(_ value: String) -> String {
        var out = ""
        var previous: Character?
        for c in value {
            if c == "|", previous != "\\" { out.append("\\") }
            out.append(c.isNewline ? " " : c)
            previous = c
        }
        return out
    }

    public static func setting(_ table: String, row: Int, column: Int, to value: String) -> String? {
        let ls = lines(table)
        let i = lineIndex(row)
        guard row >= 0, i < ls.count, column >= 0, column < max(ls[0].cells.count, ls[i].cells.count) else { return nil }
        let ns = table as NSString
        let line = ls[i]
        let text = escaped(value)
        if column >= line.cells.count {
            // A short row: add the missing cells, the last one holding the value.
            let added = Array(repeating: "", count: column - line.cells.count) + [text]
            let insertion = line.trailingPipe ? " " + added.joined(separator: " | ") + " |" : " | " + added.joined(separator: " | ")
            return ns.replacingCharacters(in: NSRange(location: NSMaxRange(line.range), length: 0), with: insertion)
        }
        let raw = line.cells[column]
        let content = trimmed(raw, in: ns)
        if content.length > 0 { return ns.replacingCharacters(in: content, with: text) }
        return text.isEmpty ? table : ns.replacingCharacters(in: raw, with: " \(text) ")
    }

    /// A new empty body row; `before` is a body row (1…) or nil for the end.
    public static func insertingRow(_ table: String, before row: Int?, newline: String = "\n") -> String? {
        let ls = lines(table)
        guard ls.count >= 2 else { return nil }
        let ns = table as NSString
        let header = ls[0]
        let prefix = ns.substring(with: NSRange(location: header.range.location, length: header.body - header.range.location))
        let line = prefix + "|" + Array(repeating: "  ", count: header.cells.count).joined(separator: "|") + "|"
        if let row {
            let i = lineIndex(row)
            guard row >= 1, i < ls.count else { return nil }
            return ns.replacingCharacters(in: NSRange(location: ls[i].range.location, length: 0), with: line + newline)
        }
        return ns.replacingCharacters(in: NSRange(location: NSMaxRange(ls[ls.count - 1].range), length: 0), with: newline + line)
    }

    public static func deletingRow(_ table: String, _ row: Int) -> String? {
        let ls = lines(table)
        let i = lineIndex(row)
        guard row >= 1, i < ls.count else { return nil }
        let ns = table as NSString
        // The line and its own break; the last line takes the break before it.
        let range = i + 1 < ls.count
            ? NSRange(location: ls[i].range.location, length: ls[i + 1].range.location - ls[i].range.location)
            : NSRange(location: NSMaxRange(ls[i - 1].range), length: NSMaxRange(ls[i].range) - NSMaxRange(ls[i - 1].range))
        return ns.replacingCharacters(in: range, with: "")
    }

    /// A new empty column before `column` (0…count; count appends).
    public static func insertingColumn(_ table: String, before column: Int) -> String? {
        let ls = lines(table)
        guard ls.count >= 2, column >= 0, column <= ls[0].cells.count else { return nil }
        let ns = table as NSString
        var edits: [(Int, String)] = []
        for (i, line) in ls.enumerated() {
            let cell = i == 1 ? "---" : " "
            if column < line.cells.count {
                let at = line.cells[column].location
                // Without a leading pipe an empty first cell needs one, or the row loses a cell.
                edits.append(at > line.body ? (at, " \(cell) |") : (at, i == 1 ? "\(cell) | " : "| \(cell) | "))
            } else if line.trailingPipe || line.cells.isEmpty {
                edits.append((NSMaxRange(line.range), " \(cell) |"))
            } else {
                edits.append((NSMaxRange(line.range), " | \(cell)"))
            }
        }
        let out = NSMutableString(string: ns)
        for (at, text) in edits.reversed() { out.insert(text, at: at) }
        return out as String
    }

    public static func deletingColumn(_ table: String, _ column: Int) -> String? {
        let ls = lines(table)
        guard ls.count >= 2, ls[0].cells.count > 1, column >= 0, column < ls[0].cells.count else { return nil }
        // One column without outer pipes would leave `b` over `--`: a setext heading, not a table.
        if ls[0].cells.count == 2, !ls[0].leadingPipe, !ls[0].trailingPipe { return nil }
        var removals: [NSRange] = []
        for line in ls where column < line.cells.count {
            let cell = line.cells[column]
            if column + 1 < line.cells.count || line.trailingPipe {
                removals.append(NSRange(location: cell.location, length: cell.length + 1))   // the cell and the pipe after it
            } else {
                removals.append(NSRange(location: cell.location - 1, length: cell.length + 1))   // the pipe before it and the cell
            }
        }
        let out = NSMutableString(string: table)
        for r in removals.reversed() { out.deleteCharacters(in: r) }
        return out as String
    }

    public static func aligning(_ table: String, column: Int, _ alignment: Alignment) -> String? {
        let ls = lines(table)
        guard ls.count >= 2, column >= 0, column < ls[1].cells.count else { return nil }
        let ns = table as NSString
        let content = trimmed(ls[1].cells[column], in: ns)
        let dashes = String(repeating: "-", count: max(3, ns.substring(with: content).filter { $0 == "-" }.count))
        let spec = switch alignment {
        case .none: dashes
        case .left: ":" + dashes
        case .center: ":" + dashes + ":"
        case .right: dashes + ":"
        }
        return ns.replacingCharacters(in: content, with: spec)
    }
}
