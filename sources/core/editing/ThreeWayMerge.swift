import Foundation

/// Line-based three-way merge for external changes (design §5 "外部修改"): the version Zephyr last
/// read or wrote (`base`), the text being edited (`local`) and the new disk version (`remote`).
/// Changes that touch different lines combine; overlapping changes that differ are conflicts and
/// are never resolved silently (principle 3).
public enum ThreeWayMerge {
    public struct Result: Sendable, Equatable {
        /// The merged text, or nil when a conflict needs a decision.
        public var merged: String?
        /// Line ranges of `local` involved in conflicts.
        public var conflicts: [Range<Int>]
    }

    public static func merge(base: String, local: String, remote: String) -> Result {
        // Bytes, not Unicode equivalence: a change between composed and decomposed forms is a change.
        func same(_ x: String, _ y: String) -> Bool { x.utf8.elementsEqual(y.utf8) }
        if same(local, base) { return Result(merged: remote, conflicts: []) }
        if same(remote, base) || same(remote, local) { return Result(merged: local, conflicts: []) }
        let o = lines(base), a = lines(local), b = lines(remote)
        // Lines are compared by number: equal bytes, equal number.
        var numbers: [[UInt8]: Int] = [:]
        func numbered(_ x: [Substring]) -> [Int] {
            x.map { line in
                let key = Array(line.utf8)
                if let n = numbers[key] { return n }
                numbers[key] = numbers.count
                return numbers.count - 1
            }
        }
        let no = numbered(o), na = numbered(a), nb = numbered(b)
        // Too far apart to compare cheaply: the writer decides, as for a conflict.
        guard let ha = hunks(no, na), let hb = hunks(no, nb) else { return Result(merged: nil, conflicts: [0..<a.count]) }
        var out: [Substring] = []
        var conflicts: [Range<Int>] = []
        var pos = 0              // next base line to copy
        var ia = 0, ib = 0
        var shiftA = 0           // local line index = base index + shiftA (outside hunks)
        while ia < ha.count || ib < hb.count {
            // Take the earliest hunk; hunks from either side that overlap or touch it form one region
            // (touching changes from both sides count as a conflict: never guess an order).
            var start = Int.max, end = 0
            if ia < ha.count { start = min(start, ha[ia].base.lowerBound) }
            if ib < hb.count { start = min(start, hb[ib].base.lowerBound) }
            end = start
            var takeA: [Hunk] = [], takeB: [Hunk] = []
            var grew = true
            while grew {
                grew = false
                while ia < ha.count, ha[ia].base.lowerBound <= end { end = max(end, ha[ia].base.upperBound); takeA.append(ha[ia]); ia += 1; grew = true }
                while ib < hb.count, hb[ib].base.lowerBound <= end { end = max(end, hb[ib].base.upperBound); takeB.append(hb[ib]); ib += 1; grew = true }
            }
            out += o[pos..<start]
            let localStart = start + shiftA
            let localText = replaced(o, start..<end, with: takeA, from: a)
            let remoteText = replaced(o, start..<end, with: takeB, from: b)
            if takeA.isEmpty {
                out += remoteText
            } else if takeB.isEmpty || replaced(no, start..<end, with: takeA, from: na) == replaced(no, start..<end, with: takeB, from: nb) {
                out += localText
            } else {
                conflicts.append(localStart..<(localStart + localText.count))
                out += localText
            }
            shiftA += localText.count - (end - start)
            pos = end
        }
        out += o[pos...]
        return Result(merged: conflicts.isEmpty ? out.joined() : nil, conflicts: conflicts)
    }

    // MARK: - Lines and hunks

    /// Lines including their terminators, so joining them gives the text back exactly.
    static func lines(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            i = text.index(after: i)
            if c == "\n" || c == "\r\n" || c == "\r" {
                result.append(text[start..<i])
                start = i
            }
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    struct Hunk {
        var base: Range<Int>
        var other: Range<Int>
    }

    /// The region `range` of `base` with the given hunks applied, using lines from `other`.
    private static func replaced<T>(_ base: [T], _ range: Range<Int>, with hunks: [Hunk], from other: [T]) -> [T] {
        var result: [T] = []
        var pos = range.lowerBound
        for h in hunks {
            result += base[pos..<h.base.lowerBound]
            result += other[h.other]
            pos = h.base.upperBound
        }
        result += base[pos..<range.upperBound]
        return result
    }

    /// Differences between line numbers `o` and `x` as hunks; nil when they differ in more than
    /// `limit` lines.
    static func hunks(_ o: [Int], _ x: [Int], limit: Int = 1_000) -> [Hunk]? {
        // Trim the common prefix and suffix first: external edits are usually small.
        var p = 0
        while p < o.count, p < x.count, o[p] == x[p] { p += 1 }
        var s = 0
        while s < o.count - p, s < x.count - p, o[o.count - 1 - s] == x[x.count - 1 - s] { s += 1 }
        let oo = Array(o[p..<(o.count - s)]), xx = Array(x[p..<(x.count - s)])
        guard let pairs = matches(oo, xx, limit: limit) else { return nil }
        var result: [Hunk] = []
        var i = 0, j = 0
        for (pi, pj) in pairs + [(oo.count, xx.count)] {
            if pi > i || pj > j { result.append(Hunk(base: (p + i)..<(p + pi), other: (p + j)..<(p + pj))) }
            i = pi + 1
            j = pj + 1
        }
        return result
    }

    /// Matched index pairs along a shortest edit script (Myers' greedy algorithm): time
    /// O((n + m) · d) and memory O(d²) for d differing lines, so a few changes in a long file stay
    /// cheap. Nil when d would exceed `limit`.
    static func matches(_ a: [Int], _ b: [Int], limit: Int) -> [(Int, Int)]? {
        let n = a.count, m = b.count
        let offset = n + m + 1
        var v = [Int](repeating: 0, count: 2 * offset + 1)
        // trace[d]: v[k] for k in -d...d before step d (what step d - 1 reached).
        var trace: [[Int]] = []
        var end: Int?
        search: for d in 0...min(n + m, limit) {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { end = d; break search }
            }
        }
        guard let last = end else { return nil }
        // Walk back from (n, m), collecting the diagonal (matched) steps.
        var pairs: [(Int, Int)] = []
        var x = n, y = m
        for d in stride(from: last, through: 0, by: -1) {
            let k = x - y
            let previous = trace[d]
            func at(_ k: Int) -> Int { previous[k + d] }
            var startX = 0, startY = 0
            if d > 0 {
                let down = k == -d || (k != d && at(k - 1) < at(k + 1))
                let pk = down ? k + 1 : k - 1
                let px = at(pk), py = px - pk
                (startX, startY) = down ? (px, py + 1) : (px + 1, py)
                while x > startX, y > startY { x -= 1; y -= 1; pairs.append((x, y)) }
                x = px
                y = py
            } else {
                while x > 0, y > 0 { x -= 1; y -= 1; pairs.append((x, y)) }
            }
        }
        return pairs.reversed()
    }
}
