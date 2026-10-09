import Foundation

/// UTF-16 view of a chunk with line starts, used to turn cmark's (line, UTF-8 column)
/// positions into the UTF-16 offsets AppKit works with (design §5, "位置与编码").
struct TextLines {
    let units: [UInt16]
    /// Offset of the first unit of each line. A trailing newline yields a final empty line.
    let lineStarts: [Int]
    /// Sparse (UTF-16 offset, UTF-8 bytes from line start) checkpoints for long lines,
    /// so lookups stay cheap on 20 MB single paragraphs.
    private var checkpoints: [Int: [(u16: Int, u8: Int)]] = [:]
    private static let checkpointStride = 1024

    init(_ string: String) {
        units = Array(string.utf16)
        var starts = [0]
        var i = 0
        let n = units.count
        while i < n {
            let c = units[i]
            if c == 0x0A {
                starts.append(i + 1)
            } else if c == 0x0D {
                if i + 1 < n, units[i + 1] == 0x0A { i += 1 }
                starts.append(i + 1)
            }
            i += 1
        }
        lineStarts = starts
    }

    var lineCount: Int { lineStarts.count }

    /// End of line content, excluding the line terminator.
    func contentEnd(ofLine line: Int) -> Int {
        var end = line + 1 < lineStarts.count ? lineStarts[line + 1] : units.count
        if end > lineStarts[line], units[end - 1] == 0x0A { end -= 1 }
        if end > lineStarts[line], units[end - 1] == 0x0D { end -= 1 }
        return end
    }

    /// End of line including its terminator.
    func fullEnd(ofLine line: Int) -> Int {
        line + 1 < lineStarts.count ? lineStarts[line + 1] : units.count
    }

    func line(containing offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func isBlank(line: Int) -> Bool {
        var i = lineStarts[line]
        let end = contentEnd(ofLine: line)
        while i < end {
            let c = units[i]
            if c != 0x20 && c != 0x09 { return false }
            i += 1
        }
        return true
    }

    /// cmark positions: 1-based line, 1-based column counted in UTF-8 bytes.
    mutating func offset(line: Int, utf8Column: Int) -> Int {
        let l = min(max(line - 1, 0), lineStarts.count - 1)
        let start = lineStarts[l]
        let end = fullEnd(ofLine: l)
        var remaining = utf8Column - 1
        var i = start
        if end - start > Self.checkpointStride * 2 {
            let table = checkpointTable(line: l, start: start, end: end)
            var k = 0, hi = table.count - 1
            while k < hi {
                let mid = (k + hi + 1) / 2
                if table[mid].u8 <= remaining { k = mid } else { hi = mid - 1 }
            }
            remaining -= table[k].u8
            i = table[k].u16
        }
        while remaining > 0 && i < end {
            let c = units[i]
            if c < 0x80 {
                remaining -= 1; i += 1
            } else if c < 0x800 {
                remaining -= 2; i += 1
            } else if UTF16.isLeadSurrogate(c) {
                remaining -= 4; i += 2
            } else {
                remaining -= 3; i += 1
            }
        }
        return min(i, end)
    }

    private mutating func checkpointTable(line: Int, start: Int, end: Int) -> [(u16: Int, u8: Int)] {
        if let t = checkpoints[line] { return t }
        var table: [(u16: Int, u8: Int)] = [(start, 0)]
        var bytes = 0
        var i = start
        var next = start + Self.checkpointStride
        while i < end {
            if i >= next {
                // `i` always sits on a code point boundary because pairs advance by two.
                table.append((i, bytes))
                next = i + Self.checkpointStride
            }
            let c = units[i]
            if c < 0x80 { bytes += 1; i += 1 }
            else if c < 0x800 { bytes += 2; i += 1 }
            else if UTF16.isLeadSurrogate(c) { bytes += 4; i += 2 }
            else { bytes += 3; i += 1 }
        }
        checkpoints[line] = table
        return table
    }
}

/// Line numbers for hosts (agent context, search results): LF, CRLF and CR all end a line.
public enum LineNumbers {
    /// UTF-16 offsets where lines start.
    public static func starts(of text: String) -> [Int] { TextLines(text).lineStarts }

    /// 1-based line of a UTF-16 offset.
    public static func line(at offset: Int, starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }
}
