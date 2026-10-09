/// A fenced code block opener (``` or ~~~), shared by the chunker and the math scanner so both
/// treat fenced code as opaque in exactly the same way.
struct Fence: Equatable {
    var char: UInt16
    var count: Int
    /// Length of the container prefix before the fence, which code lines also drop.
    var indent: Int

    /// Container prefix: indentation, `>` quote markers and list markers.
    static func prefixLength(_ line: ArraySlice<UInt16>) -> Int {
        var i = line.startIndex
        let n = line.endIndex
        while i < n {
            let c = line[i]
            if c == 0x20 || c == 0x09 || c == 0x3E { i += 1; continue }
            if c == 0x2D || c == 0x2A || c == 0x2B, i + 1 < n, line[i + 1] == 0x20 { i += 2; continue }
            if c >= 0x30 && c <= 0x39 {
                var j = i
                while j < n, line[j] >= 0x30 && line[j] <= 0x39 { j += 1 }
                if j + 1 < n, line[j] == 0x2E || line[j] == 0x29, line[j + 1] == 0x20 { i = j + 2; continue }
            }
            break
        }
        return i - line.startIndex
    }

    init?(opening line: ArraySlice<UInt16>) {
        let s = line.startIndex + Self.prefixLength(line)
        guard s < line.endIndex else { return nil }
        let c = line[s]
        guard c == 0x60 || c == 0x7E else { return nil }
        var e = s
        while e < line.endIndex, line[e] == c { e += 1 }
        guard e - s >= 3 else { return nil }
        // A backtick fence's info string may not contain backticks (that would be inline code).
        if c == 0x60, line[e...].contains(0x60) { return nil }
        char = c
        count = e - s
        indent = s - line.startIndex
    }

    func isClosed(by line: ArraySlice<UInt16>) -> Bool {
        let s = line.startIndex + Self.prefixLength(line)
        var e = s
        while e < line.endIndex, line[e] == char { e += 1 }
        guard e - s >= count else { return false }
        return line[e...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    /// `$$` at the start of a line (after container prefixes) opens a math block.
    static func opensMathBlock(_ line: ArraySlice<UInt16>) -> Int? {
        let s = line.startIndex + prefixLength(line)
        guard s + 1 < line.endIndex, line[s] == 0x24, line[s + 1] == 0x24 else { return nil }
        return s
    }
}
