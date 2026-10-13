import Foundation

/// Geometry in points (ZephyrCore stays Foundation only; the renderer converts).
public struct DiagramPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct DiagramSize: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct DiagramRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    func union(_ r: DiagramRect) -> DiagramRect {
        let x0 = min(minX, r.minX), y0 = min(minY, r.minY)
        return DiagramRect(x: x0, y: y0, width: max(maxX, r.maxX) - x0, height: max(maxY, r.maxY) - y0)
    }
}

/// A diagram as geometry, ready to draw: shapes, paths and text in points, origin at the top left.
public struct DiagramScene: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case move(DiagramPoint)
        case line(DiagramPoint)
        case curve(DiagramPoint, DiagramPoint, DiagramPoint)

        var end: DiagramPoint {
            switch self {
            case let .move(p), let .line(p), let .curve(_, _, p): p
            }
        }
    }

    public enum Head: Sendable, Equatable { case filled, chevron, cross }

    public enum Item: Sendable, Equatable {
        case node(DiagramRect, Flowchart.Shape, String)
        case participant(DiagramRect, String, actor: Bool)
        /// A link or message; `head` at its end, `tail` at its start.
        case path([Segment], dashed: Bool, thick: Bool, head: Head?, tail: Head?)
        /// A label; boxed labels sit on lines and cover them.
        case text(DiagramRect, String, boxed: Bool)
        case lifeline(x: Double, top: Double, bottom: Double)
        case note(DiagramRect, String)
        case frame(DiagramRect, kind: String, label: String)
        case divider(y: Double, from: Double, to: Double, label: String)
        case number(DiagramPoint, Int)
    }

    public var size: DiagramSize
    public var items: [Item]
}

/// How diagrams look in the active theme (diagram.* settings).
public struct DiagramStyle: Sendable, Equatable {
    public enum Lines: String, Sendable { case curved, straight, angled }
    /// Label size in points; every distance scales with it.
    public var fontSize: Double
    /// 0.75 compact, 1 standard, 1.35 roomy.
    public var spacing: Double
    public var lines: Lines

    public init(fontSize: Double, spacing: Double, lines: Lines) {
        self.fontSize = fontSize
        self.spacing = spacing
        self.lines = lines
    }
}

public enum DiagramLayout {
    /// `measure` gives the size of a label set in the diagram font (lines split at "\n").
    public static func layout(_ diagram: MermaidDiagram, style: DiagramStyle, measure: (String) -> DiagramSize) -> DiagramScene {
        switch diagram {
        case let .flowchart(c): flowchart(c, style, measure)
        case let .sequence(d): sequence(d, style, measure)
        }
    }

    // MARK: Flowchart

    /// A layered layout: cycles broken by reversing back edges, ranks by longest path, a virtual
    /// point per rank on long edges, crossings reduced by barycenter sweeps, positions pulled
    /// toward neighbours. Computed with a main axis (rank to rank) and a cross axis, then turned
    /// to the chart's direction.
    static func flowchart(_ c: Flowchart, _ st: DiagramStyle, _ measure: (String) -> DiagramSize) -> DiagramScene {
        let em = st.fontSize
        let horizontal = c.direction == .right || c.direction == .left
        let n = c.nodes.count
        var index: [String: Int] = [:]
        for (i, node) in c.nodes.enumerated() { index[node.id] = i }
        let sizes = c.nodes.map { node -> DiagramSize in
            let t = measure(node.label)
            switch node.shape {
            case .diamond:
                // A rhombus holds the label box when its half axes are 1.7× and 2.4× the box's.
                let hx = t.width / 2 + em * 0.4, hy = t.height / 2 + em * 0.25
                return DiagramSize(width: (hx * 3.4).rounded(), height: (hy * 4.8).rounded())
            case .circle:
                let d = (max(t.width, t.height) + em * 1.4).rounded()
                return DiagramSize(width: d, height: d)
            case .hexagon: return DiagramSize(width: (t.width + em * 2.8).rounded(), height: max(t.height + em * 1.43, em * 2.86).rounded())
            // 16 × 10 pt of padding around a 14 pt label, at least 40 pt tall.
            default: return DiagramSize(width: max(t.width + em * 2.3, em * 3).rounded(), height: max(t.height + em * 1.43, em * 2.86).rounded())
            }
        }
        let edges = c.edges.map { (index[$0.from]!, index[$0.to]!) }

        // Back edges, in source order, so the chart reads the way it was written.
        var out = [[Int]](repeating: [], count: n)
        for (k, e) in edges.enumerated() { out[e.0].append(k) }
        var state = [Int](repeating: 0, count: n)
        var back = Set<Int>()
        func visit(_ v: Int) {
            state[v] = 1
            for k in out[v] where edges[k].1 != v {
                let w = edges[k].1
                if state[w] == 1 { back.insert(k) } else if state[w] == 0 { visit(w) }
            }
            state[v] = 2
        }
        for v in 0..<n where state[v] == 0 { visit(v) }

        // Ranks: longest path over the acyclic edges; a node that only feeds others sits just above them.
        var succ = [[Int]](repeating: [], count: n), pred = [[Int]](repeating: [], count: n)
        for (k, e) in edges.enumerated() where e.0 != e.1 {
            let (a, b) = back.contains(k) ? (e.1, e.0) : e
            succ[a].append(b)
            pred[b].append(a)
        }
        var rank = [Int](repeating: 0, count: n)
        var indegree = pred.map(\.count)
        var queue = (0..<n).filter { indegree[$0] == 0 }
        var head = 0
        while head < queue.count {
            let v = queue[head]
            head += 1
            for w in succ[v] {
                rank[w] = max(rank[w], rank[v] + 1)
                indegree[w] -= 1
                if indegree[w] == 0 { queue.append(w) }
            }
        }
        for v in queue.reversed() where pred[v].isEmpty && !succ[v].isEmpty {
            rank[v] = succ[v].map { rank[$0] }.min()! - 1
        }

        // Vertices: the nodes, then one virtual point per rank crossed by a long edge. A long edge's
        // label is the virtual point in its middle rank, as large as the label: it takes its place
        // in the rank like a node, so neighbouring lines pass beside it instead of under it.
        let chipX = em * 6 / 14
        let chipY = em * 3 / 14
        var cross = sizes.map { horizontal ? $0.height : $0.width }
        var main = sizes.map { horizontal ? $0.width : $0.height }
        var vRank = rank
        var chains: [[Int]] = []
        var labelVertex = [Int?](repeating: nil, count: edges.count)
        for (k, e) in edges.enumerated() {
            if e.0 == e.1 {
                chains.append([e.0])
                continue
            }
            if back.contains(k) {
                // Return edges stay outside the layered graph instead of adding virtual vertices
                // and pulling the forward spine sideways.
                chains.append([e.0, e.1])
                continue
            }
            let (lo, hi) = e
            var chain = [lo]
            let middle = (vRank[lo] + vRank[hi]) / 2
            let label = c.edges[k].label.flatMap { $0.isEmpty ? nil : measure($0) }
            for r in stride(from: vRank[lo] + 1, to: vRank[hi], by: 1) {
                if let size = label, r == middle {
                    cross.append(horizontal ? size.height + chipY * 2 : size.width + chipX * 2)
                    main.append(horizontal ? size.width + chipX * 2 : size.height + chipY * 2)
                    labelVertex[k] = cross.count - 1
                } else {
                    cross.append(em * 0.6)
                    main.append(0)
                }
                vRank.append(r)
                chain.append(cross.count - 1)
            }
            chain.append(hi)
            chains.append(chain)
        }
        let count = cross.count
        let ranks = (vRank.max() ?? 0) + 1
        var layers = [[Int]](repeating: [], count: ranks)
        for v in 0..<count { layers[vRank[v]].append(v) }
        var above = [[Int]](repeating: [], count: count), below = [[Int]](repeating: [], count: count)
        for (k, chain) in chains.enumerated() where chain.count > 1 && !back.contains(k) {
            for (a, b) in zip(chain, chain.dropFirst()) {
                let (top, bottom) = vRank[a] < vRank[b] ? (a, b) : (b, a)
                below[top].append(bottom)
                above[bottom].append(top)
            }
        }

        // Order within ranks: barycenter sweeps, down then up.
        var pos = [Double](repeating: 0, count: count)
        for layer in layers { for (i, v) in layer.enumerated() { pos[v] = Double(i) } }
        for sweep in 0..<8 {
            let down = sweep % 2 == 0
            for r in down ? Array(1..<ranks) : Array((0..<max(ranks - 1, 0)).reversed()) {
                let key = layers[r].map { v -> Double in
                    let ns = down ? above[v] : below[v]
                    return ns.isEmpty ? pos[v] : ns.map { pos[$0] }.reduce(0, +) / Double(ns.count)
                }
                layers[r] = layers[r].indices.sorted { (key[$0], $0) < (key[$1], $1) }.map { layers[r][$0] }
                for (i, v) in layers[r].enumerated() { pos[v] = Double(i) }
            }
        }

        // Cross positions: packed, then pulled toward neighbours while keeping order and gaps.
        let gap = em * 2.3 * st.spacing
        let labelVertices = Set(labelVertex.compactMap { $0 })
        func separation(_ a: Int, _ b: Int) -> Double {
            let solid = (a < n || labelVertices.contains(a)) && (b < n || labelVertices.contains(b))
            return (cross[a] + cross[b]) / 2 + (solid ? gap : gap * 0.4)
        }
        var x = [Double](repeating: 0, count: count)
        for layer in layers {
            var cursor: Double = 0
            for v in layer {
                x[v] = cursor + cross[v] / 2
                cursor += cross[v] + gap
            }
        }
        for iteration in 0..<16 {
            let down = iteration % 2 == 0
            for r in down ? Array(0..<ranks) : Array((0..<ranks).reversed()) {
                let layer = layers[r]
                guard !layer.isEmpty else { continue }
                let want = layer.map { v -> Double in
                    let ns = iteration >= 12 ? above[v] + below[v] : down ? above[v] : below[v]
                    return ns.isEmpty ? x[v] : ns.map { x[$0] }.reduce(0, +) / Double(ns.count)
                }
                // The mean of the two one-sided packings keeps every gap and stays near the wishes.
                var left = want, right = want
                for i in 1..<max(layer.count, 1) { left[i] = max(want[i], left[i - 1] + separation(layer[i - 1], layer[i])) }
                for i in stride(from: layer.count - 2, through: 0, by: -1) { right[i] = min(want[i], right[i + 1] - separation(layer[i], layer[i + 1])) }
                for (i, v) in layer.enumerated() { x[v] = (left[i] + right[i]) / 2 }
            }
        }

        let margin = em * 0.75
        let minCross = (0..<count).map { x[$0] - cross[$0] / 2 }.min() ?? 0
        for v in 0..<count { x[v] += margin - minCross }
        var totalCross = ((0..<count).map { x[$0] + cross[$0] / 2 }.max() ?? 0) + margin

        // Ports: several links leaving or entering one side of a box spread along it.
        var ports: [[Int: Double]] = Array(repeating: [:], count: chains.count)
        for v in 0..<n where ![.diamond, .circle].contains(c.nodes[v].shape) {
            for sideBelow in [true, false] {
                var ends: [(chain: Int, toward: Double, start: Bool)] = []
                for (k, chain) in chains.enumerated() where chain.count > 1 && !back.contains(k) {
                    if chain[0] == v, (vRank[chain[1]] > vRank[v]) == sideBelow { ends.append((k, x[chain[1]], true)) }
                    if chain.last == v, (vRank[chain[chain.count - 2]] > vRank[v]) == sideBelow { ends.append((k, x[chain[chain.count - 2]], false)) }
                }
                guard ends.count > 1 else { continue }
                ends.sort { $0.toward < $1.toward }
                let step = min(cross[v] * 0.6 / Double(ends.count - 1), em * 1.2)
                for (i, end) in ends.enumerated() {
                    ports[end.chain][end.start ? 0 : 1] = (Double(i) - Double(ends.count - 1) / 2) * step
                }
            }
        }

        // Main positions: each rank as deep as its deepest node. Labels sharing a rank gap
        // occupy rows whose conservative cross-axis intervals do not overlap.
        var rankDepth = [Double](repeating: 0, count: ranks)
        for v in 0..<count { rankDepth[vRank[v]] = max(rankDepth[vRank[v]], main[v]) }
        var rankGap = [Double](repeating: em * 3.4 * st.spacing, count: ranks)
        var labelSizes = [DiagramSize?](repeating: nil, count: edges.count)
        var labelOffsets = [Double?](repeating: nil, count: edges.count)
        var labelRanks = [Int?](repeating: nil, count: edges.count)
        var labelRows = [Int?](repeating: nil, count: edges.count)
        var rowIntervals = [[[ (lower: Double, upper: Double) ]]](repeating: [], count: ranks)
        var rowDepths = [[Double]](repeating: [], count: ranks)
        let rowPadding = em * 0.4
        for (k, edge) in c.edges.enumerated() {
            guard let label = edge.label, !label.isEmpty else { continue }
            let size = measure(label)
            labelSizes[k] = size
            let chain = chains[k]
            guard chain.count > 1 && !back.contains(k) && labelVertex[k] == nil else { continue }
            let r = min(vRank[chain[0]], vRank[chain[1]])
            labelRanks[k] = r
            let start = x[chain[0]] + (ports[k][0] ?? 0)
            let end = x[chain[1]] + (chain.count == 2 ? (ports[k][1] ?? 0) : 0)
            let crossSize = horizontal ? size.height + chipY * 2 : size.width + chipX * 2
            let interval = (lower: min(start, end) - crossSize / 2, upper: max(start, end) + crossSize / 2)
            var row = 0
            while row < rowIntervals[r].count && rowIntervals[r][row].contains(where: { !(interval.upper <= $0.lower || $0.upper <= interval.lower) }) { row += 1 }
            if row == rowIntervals[r].count {
                rowIntervals[r].append([])
                rowDepths[r].append(0)
            }
            rowIntervals[r][row].append(interval)
            rowDepths[r][row] = max(rowDepths[r][row], horizontal ? size.width + chipX * 2 : size.height + chipY * 2)
            labelRows[k] = row
        }
        for r in 0..<ranks where !rowDepths[r].isEmpty {
            let usedDepth = rowDepths[r].reduce(0, +) + rowPadding * Double(rowDepths[r].count + 1)
            rankGap[r] = max(rankGap[r], usedDepth)
            var offset = (rankGap[r] - usedDepth) / 2 + rowPadding
            for (row, depth) in rowDepths[r].enumerated() {
                for k in 0..<edges.count where labelRanks[k] == .some(r) && labelRows[k] == .some(row) {
                    labelOffsets[k] = offset + depth / 2
                }
                offset += depth + rowPadding
            }
        }
        // Back edges loop on the side that keeps their run shortest, just outside what lies between
        // their ranks (nodes, long edges' points, labels), not around the whole chart. Shorter
        // returns take the inner lanes; each lane is as deep as its label.
        let lane = em * 1.2
        var returnSide = [Double](repeating: 1, count: chains.count)
        var returnTracks = [Double?](repeating: nil, count: chains.count)
        var returnDepth = [Double](repeating: 0, count: chains.count)
        var taken: [(side: Double, lo: Int, hi: Int, outer: Double)] = []
        func span(_ k: Int) -> (lo: Int, hi: Int) {
            let a = vRank[chains[k][0]], b = vRank[chains[k][1]]
            return (min(a, b), max(a, b))
        }
        for k in edges.indices.filter({ back.contains($0) }).sorted(by: { (span($0).hi - span($0).lo, $0) < (span($1).hi - span($1).lo, $1) }) {
            let (lo, hi) = span(k)
            let a = chains[k][0], b = chains[k][1]
            let depth = max(labelSizes[k].map { horizontal ? $0.height + chipY * 2 : $0.width + chipX * 2 } ?? 0, lane)
            returnDepth[k] = depth
            var best: (side: Double, track: Double, cost: Double)?
            for side in [-1.0, 1.0] {
                var edge = side > 0 ? -Double.infinity : Double.infinity
                func reach(_ value: Double) { edge = side > 0 ? max(edge, value) : min(edge, value) }
                for v in 0..<count where vRank[v] >= lo && vRank[v] <= hi { reach(x[v] + side * cross[v] / 2) }
                for r in lo..<hi { for row in rowIntervals[r] { for interval in row { reach(side > 0 ? interval.upper : interval.lower) } } }
                for other in taken where other.side == side && other.lo <= hi && lo <= other.hi { reach(other.outer) }
                let track = edge + side * (lane + depth / 2)
                let cost = abs(track - x[a]) + abs(track - x[b])
                if best == nil || cost < best!.cost - 0.5 { best = (side, track, cost) }
            }
            returnSide[k] = best!.side
            returnTracks[k] = best!.track
            taken.append((best!.side, lo, hi, best!.track + best!.side * depth / 2))
        }
        // Returns on the leading side move the chart over to make room.
        let leadingReturns = edges.indices.compactMap { k in returnTracks[k].flatMap { returnSide[k] < 0 ? $0 - returnDepth[k] / 2 : nil } }
        if let low = leadingReturns.min(), low < margin {
            let shift = margin - low
            for v in 0..<count { x[v] += shift }
            for k in edges.indices { returnTracks[k] = returnTracks[k].map { $0 + shift } }
            totalCross += shift
        }
        let returnReach = edges.indices.compactMap { k in returnTracks[k].flatMap { returnSide[k] > 0 ? $0 + returnDepth[k] / 2 : nil } }.max() ?? 0

        var y = [Double](repeating: 0, count: ranks)
        func placeRanks() -> Double {
            var cursor = margin
            for r in 0..<ranks {
                y[r] = cursor + rankDepth[r] / 2
                cursor += rankDepth[r] + rankGap[r]
            }
            return cursor - rankGap[ranks - 1] + margin
        }
        _ = placeRanks()

        // A forward link's points on the main and cross axes: out of the first box, through the
        // virtual points, into the last; and where it crosses a main-axis position.
        func points(_ k: Int) -> [(m: Double, c: Double)] {
            let chain = chains[k]
            return chain.enumerated().map { i, v in
                let r = vRank[v]
                guard i == 0 || i == chain.count - 1 else { return (y[r], x[v]) }
                let other = i == 0 ? chain[1] : chain[chain.count - 2]
                let toward: Double = vRank[other] > r ? 1 : -1
                return (y[r] + toward * main[v] / 2, x[v] + (ports[k][i == 0 ? 0 : 1] ?? 0))
            }
        }
        // Curved links are one smooth curve through their points: at each virtual point the slope
        // follows its neighbours (the harmonic mean of the two runs, flat where they turn back, so
        // the curve never swings past a point toward a box); out of and into boxes it runs along
        // the main axis. Each run is a cubic whose main coordinate is linear in t.
        func slopes(_ pts: [(m: Double, c: Double)]) -> [Double] {
            pts.indices.map { i in
                guard i > 0, i < pts.count - 1 else { return 0 }
                let a = (pts[i].c - pts[i - 1].c) / (pts[i].m - pts[i - 1].m), b = (pts[i + 1].c - pts[i].c) / (pts[i + 1].m - pts[i].m)
                return a * b <= 0 ? 0 : 2 * a * b / (a + b)
            }
        }
        func crossAt(_ pts: [(m: Double, c: Double)], _ i: Int, _ m: Double) -> Double {
            let p = pts[i], q = pts[i + 1]
            switch st.lines {
            case .straight:
                return p.c + (q.c - p.c) * (m - p.m) / (q.m - p.m)
            case .curved:
                let s = slopes(pts), h = q.m - p.m
                let t = min(max((m - p.m) / h, 0), 1), u = 1 - t
                let c1 = p.c + s[i] * h / 3, c2 = q.c - s[i + 1] * h / 3
                return u * u * u * p.c + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * q.c
            case .angled:
                let midpoint = (p.m + q.m) / 2
                if abs(p.c - q.c) <= 0.5 { return p.c + (q.c - p.c) * (m - p.m) / (q.m - p.m) }
                if abs(m - midpoint) < 0.0001 { return (p.c + q.c) / 2 }
                return (m - p.m) / (q.m - p.m) < 0.5 ? p.c : q.c
            }
        }

        // A label's place across its link's first run: on an angled link whose turn its band
        // holds, the middle of the turn, so it covers its own line there and not a neighbour's.
        func labelCross(_ k: Int, _ center: Double) -> Double {
            let size = labelSizes[k]!, pk = points(k)
            let depth = horizontal ? size.width + chipX * 2 : size.height + chipY * 2
            if st.lines == .angled, abs((pk[0].m + pk[1].m) / 2 - center) <= depth / 2 { return (pk[0].c + pk[1].c) / 2 }
            return crossAt(pk, 0, center)
        }

        // Rows of labels in a rank gap move to where the other links are furthest from them (lines
        // fanning out of one box are close at the box and spread toward the next rank), deepening
        // the gap by up to 3 em when no position clears them.
        let forward = chains.indices.filter { chains[$0].count > 1 && !back.contains($0) }
        for r in 0..<ranks where !rowDepths[r].isEmpty {
            let block = edges.indices.filter { labelRanks[$0] == r }
            let crossing = forward.filter { k in chains[k].contains { vRank[$0] == r } && chains[k].contains { vRank[$0] == r + 1 } }
            let usedDepth = rowDepths[r].reduce(0, +) + rowPadding * Double(rowDepths[r].count + 1)
            let original = rankGap[r]
            // Each row's centre in the gap, the rows stacked in `order` around the gap's middle.
            func offsets(_ order: [Int]) -> [Int: Double] {
                var result: [Int: Double] = [:], offset = (rankGap[r] - usedDepth) / 2 + rowPadding
                for row in order {
                    result[row] = offset + rowDepths[r][row] / 2
                    offset += rowDepths[r][row] + rowPadding
                }
                return result
            }
            func clearance() -> Double {
                var worst = Double.infinity
                for k in block {
                    let size = labelSizes[k]!
                    let (half, depth) = horizontal ? (size.height / 2 + chipY, size.width + chipX * 2) : (size.width / 2 + chipX, size.height + chipY * 2)
                    let center = y[r] + rankDepth[r] / 2 + labelOffsets[k]!
                    let c = labelCross(k, center)
                    for j in crossing where j != k {
                        let pj = points(j)
                        guard let i = pj.indices.dropLast().first(where: { vRank[chains[j][$0]] == r }) else { continue }
                        // The cross range the line takes within the label's band (an angled
                        // line's run between ranks spans its whole turn), against the label's.
                        let (p, q) = (pj[i], pj[i + 1]), low = center - depth / 2, high = center + depth / 2
                        var reach = [low, center, high].map { crossAt(pj, i, $0) }
                        if st.lines == .angled, (low...high).contains((p.m + q.m) / 2) { reach += [p.c, q.c] }
                        worst = min(worst, max(reach.min()! - (c + half), (c - half) - reach.max()!))
                    }
                }
                return worst
            }
            var best: (score: Double, gap: Double, offsets: [Int: Double])?
            let rows = Array(rowDepths[r].indices)
            for extra in stride(from: 0.0, through: em * 3, by: em * 0.5) {
                rankGap[r] = original + extra
                _ = placeRanks()
                let slack = rankGap[r] - usedDepth
                for order in rows.count > 1 ? [rows, rows.reversed()] : [rows] {
                    let centred = offsets(order)
                    for step in 0...12 {
                        let shift = slack * (Double(step) / 12 - 0.5)
                        for k in block { labelOffsets[k] = centred[labelRows[k]!]! + shift }
                        // Clear by a little more than a line's width; past that, prefer centred,
                        // shallow and in the first order.
                        let score = min(clearance(), em * 0.5) - abs(shift) * 0.01 - extra * 0.02 - (order == rows ? 0 : 0.001)
                        if best == nil || score > best!.score + 0.0001 { best = (score, rankGap[r], centred.mapValues { $0 + shift }) }
                    }
                }
            }
            rankGap[r] = best!.gap
            for k in block { labelOffsets[k] = best!.offsets[labelRows[k]!]! }
            _ = placeRanks()
        }
        let totalMain = placeRanks()
        // Self loops reach past their node on the cross side.
        var loopReach: Double = 0
        for (k, chain) in chains.enumerated() where chain.count == 1 {
            let label: Double = labelSizes[k].map { horizontal ? $0.height : $0.width } ?? 0
            loopReach = max(loopReach, x[chain[0]] + cross[chain[0]] / 2 + em * 1.6 + label)
        }

        func place(_ m: Double, _ cr: Double) -> DiagramPoint {
            switch c.direction {
            case .down: DiagramPoint(x: cr, y: m)
            case .up: DiagramPoint(x: cr, y: totalMain - m)
            case .right: DiagramPoint(x: m, y: cr)
            case .left: DiagramPoint(x: totalMain - m, y: cr)
            }
        }

        // Several returns leaving or entering one side of a box spread along it.
        var returnPorts: [[Int: Double]] = Array(repeating: [:], count: chains.count)
        for v in 0..<n where [.rectangle, .rounded, .subroutine, .flag].contains(c.nodes[v].shape) {
            for side in [-1.0, 1.0] {
                var ends: [(chain: Int, start: Bool)] = []
                for (k, chain) in chains.enumerated() where back.contains(k) && returnSide[k] == side {
                    if chain[0] == v { ends.append((k, true)) }
                    if chain[1] == v { ends.append((k, false)) }
                }
                guard ends.count > 1 else { continue }
                let step = min(main[v] * 0.6 / Double(ends.count - 1), em * 1.2)
                for (i, end) in ends.enumerated() {
                    returnPorts[end.chain][end.start ? 0 : 1] = (Double(i) - Double(ends.count - 1) / 2) * step
                }
            }
        }

        var items: [DiagramScene.Item] = []
        var labels: [DiagramScene.Item] = []
        for (k, chain) in chains.enumerated() {
            let edge = c.edges[k]
            if chain.count == 1 {
                let v = chain[0]
                let side = x[v] + cross[v] / 2
                let reach = em * 1.4
                let p0 = place(y[vRank[v]] - main[v] / 4, side), p1 = place(y[vRank[v]] + main[v] / 4, side)
                let c0 = place(y[vRank[v]] - main[v] / 2, side + reach), c1 = place(y[vRank[v]] + main[v] / 2, side + reach)
                items.append(.path([.move(p0), .curve(c0, c1, p1)], dashed: edge.stroke == .dotted, thick: edge.stroke == .thick, head: edge.arrow ? .filled : nil, tail: nil))
                if let size = labelSizes[k] {
                    let center = place(y[vRank[v]], side + reach + (horizontal ? size.height : size.width) / 2 + em * 0.2)
                    labels.append(.text(DiagramRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), edge.label!, boxed: true))
                }
                continue
            }
            if back.contains(k) {
                let source = chain[0], target = chain[1], side = returnSide[k]
                var p = (m: y[vRank[source]] + (returnPorts[k][0] ?? 0), c: x[source] + side * cross[source] / 2)
                var q = (m: y[vRank[target]] + (returnPorts[k][1] ?? 0), c: x[target] + side * cross[target] / 2)
                let track = returnTracks[k]!
                var segments: [DiagramScene.Segment] = []
                switch st.lines {
                case .straight, .angled:
                    segments = [.move(place(p.m, p.c)), .line(place(p.m, track)), .line(place(q.m, track)), .line(place(q.m, q.c))]
                case .curved:
                    // One flowing curve: out of the source, through the middle of the track, into
                    // the target, as two cubics meeting on the track along the main axis, with no
                    // straight run and no corner. A box between an end and the track in its own
                    // rank is not crossed: that end uses the face toward the other end instead of
                    // its side. Where the curve would cut a box on the way, it keeps to the track
                    // longer, step by step.
                    let dir = q.m >= p.m ? 1.0 : -1.0
                    func blocked(_ v: Int) -> Bool {
                        (0..<n).contains { w in
                            w != v && vRank[w] == vRank[v] && (x[w] - x[v]) * side > 0 && ((x[w] - side * cross[w] / 2) - track) * side < 0
                        }
                    }
                    // Directions the curve leaves the source and enters the target along.
                    var out = (m: 0.0, c: side), into = (m: 0.0, c: side)
                    if blocked(source) {
                        p = (m: y[vRank[source]] + dir * main[source] / 2, c: x[source] + side * cross[source] * 0.3)
                        out = (m: dir, c: 0)
                    }
                    if blocked(target) {
                        q = (m: y[vRank[target]] - dir * main[target] / 2, c: x[target] + side * cross[target] * 0.3)
                        into = (m: -dir, c: 0)
                    }
                    let middle = (m: (p.m + q.m) / 2, c: track)
                    let half = abs(middle.m - p.m)
                    let lead = (out.c != 0 ? abs(track - p.c) : half * 0.5), tail = (into.c != 0 ? abs(track - q.c) : half * 0.5)
                    func path(_ hold: Double) -> [DiagramScene.Segment] {
                        [.move(place(p.m, p.c)),
                         .curve(place(p.m + out.m * lead, p.c + out.c * lead), place(middle.m - dir * half * hold, track), place(middle.m, track)),
                         .curve(place(middle.m + dir * half * hold, track), place(q.m + into.m * tail, q.c + into.c * tail), place(q.m, q.c))]
                    }
                    // Boxes other than the two ends, a little larger, in main/cross terms.
                    let pad = em * 0.3
                    let boxes = (0..<n).filter { $0 != source && $0 != target }.map { v in
                        (m: y[vRank[v]] - main[v] / 2 - pad, mm: y[vRank[v]] + main[v] / 2 + pad, c: x[v] - cross[v] / 2 - pad, cc: x[v] + cross[v] / 2 + pad)
                    }
                    func cuts(_ hold: Double) -> Bool {
                        let a = (p.m, p.c), b = (p.m + out.m * lead, p.c + out.c * lead), c = (middle.m - dir * half * hold, track), d = (middle.m, track)
                        let e = (middle.m + dir * half * hold, track), f = (q.m + into.m * tail, q.c + into.c * tail), g = (q.m, q.c)
                        for (s0, s1, s2, s3) in [(a, b, c, d), (d, e, f, g)] {
                            for i in 1..<24 {
                                let t = Double(i) / 24, u = 1 - t
                                let m = u * u * u * s0.0 + 3 * u * u * t * s1.0 + 3 * u * t * t * s2.0 + t * t * t * s3.0
                                let cr = u * u * u * s0.1 + 3 * u * u * t * s1.1 + 3 * u * t * t * s2.1 + t * t * t * s3.1
                                if boxes.contains(where: { m > $0.m && m < $0.mm && cr > $0.c && cr < $0.cc }) { return true }
                            }
                        }
                        return false
                    }
                    let hold = stride(from: 0.55, through: 0.95, by: 0.1).first { !cuts($0) } ?? 0.95
                    segments = path(hold)
                }
                items.append(.path(segments, dashed: edge.stroke == .dotted, thick: edge.stroke == .thick, head: edge.arrow ? .filled : nil, tail: edge.arrowBack ? .filled : nil))
                if let size = labelSizes[k] {
                    let center = place((p.m + q.m) / 2, track)
                    labels.append(.text(DiagramRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), edge.label!, boxed: true))
                }
                continue
            }
            let points = points(k), slope = slopes(points)
            var segments: [DiagramScene.Segment] = [.move(place(points[0].m, points[0].c))]
            for (i, (p, q)) in zip(points, points.dropFirst()).enumerated() {
                switch st.lines {
                case .straight:
                    segments.append(.line(place(q.m, q.c)))
                case .curved:
                    let h = q.m - p.m
                    segments.append(.curve(place(p.m + h / 3, p.c + slope[i] * h / 3), place(q.m - h / 3, q.c - slope[i + 1] * h / 3), place(q.m, q.c)))
                case .angled:
                    let mid = (p.m + q.m) / 2
                    if abs(p.c - q.c) > 0.5 {
                        segments.append(.line(place(mid, p.c)))
                        segments.append(.line(place(mid, q.c)))
                    }
                    segments.append(.line(place(q.m, q.c)))
                }
            }
            items.append(.path(segments, dashed: edge.stroke == .dotted, thick: edge.stroke == .thick, head: edge.arrow ? .filled : nil, tail: edge.arrowBack ? .filled : nil))
            if let size = labelSizes[k], let v = labelVertex[k] {
                let center = place(y[vRank[v]], x[v])
                labels.append(.text(DiagramRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), edge.label!, boxed: true))
            } else if let size = labelSizes[k] {
                let r = labelRanks[k]!
                let labelMain = y[r] + rankDepth[r] / 2 + labelOffsets[k]!
                let cross = labelCross(k, labelMain)
                let center = place(labelMain, cross)
                labels.append(.text(DiagramRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), edge.label!, boxed: true))
            }
        }
        for v in 0..<n {
            let center = place(y[vRank[v]], x[v])
            items.append(.node(DiagramRect(x: center.x - sizes[v].width / 2, y: center.y - sizes[v].height / 2, width: sizes[v].width, height: sizes[v].height), c.nodes[v].shape, c.nodes[v].label))
        }
        let crossExtent = max(totalCross, loopReach + margin, returnReach + margin)
        var size = horizontal ? DiagramSize(width: totalMain, height: crossExtent) : DiagramSize(width: crossExtent, height: totalMain)
        // A label may reach past the nodes (a tall one on a left-to-right edge): the scene grows,
        // and moves over, to hold it with its chip.
        var all = items + labels
        let pad = em * 0.5
        if let reach = labels.compactMap({ item -> DiagramRect? in if case let .text(r, _, _) = item { r } else { nil } }).reduce(nil, { $0?.union($1) ?? $1 }) {
            let dx = max(0, pad - reach.minX), dy = max(0, pad - reach.minY)
            size = DiagramSize(width: max(size.width, reach.maxX + pad) + dx, height: max(size.height, reach.maxY + pad) + dy)
            if dx > 0 || dy > 0 {
                func moved(_ p: DiagramPoint) -> DiagramPoint { DiagramPoint(x: p.x + dx, y: p.y + dy) }
                func moved(_ r: DiagramRect) -> DiagramRect { DiagramRect(x: r.x + dx, y: r.y + dy, width: r.width, height: r.height) }
                all = all.map { item in
                    switch item {
                    case let .node(r, shape, label): .node(moved(r), shape, label)
                    case let .text(r, label, boxed): .text(moved(r), label, boxed: boxed)
                    case let .path(segments, dashed, thick, head, tail):
                        .path(segments.map { segment in
                            switch segment {
                            case let .move(p): .move(moved(p))
                            case let .line(p): .line(moved(p))
                            case let .curve(a, b, c): .curve(moved(a), moved(b), moved(c))
                            }
                        }, dashed: dashed, thick: thick, head: head, tail: tail)
                    default: item
                    }
                }
            }
        }
        return DiagramScene(size: DiagramSize(width: size.width.rounded(.up), height: size.height.rounded(.up)), items: all)
    }

    // MARK: Sequence diagram

    /// Participants in columns wide enough for the messages between them, one row per step;
    /// blocks (loop, alt, opt…) frame the rows they hold.
    static func sequence(_ d: SequenceDiagram, _ st: DiagramStyle, _ measure: (String) -> DiagramSize) -> DiagramScene {
        let em = st.fontSize
        let n = d.participants.count
        var index: [String: Int] = [:]
        for (i, p) in d.participants.enumerated() { index[p.id] = i }
        let boxes = d.participants.map { p -> DiagramSize in
            let t = measure(p.label)
            return DiagramSize(width: max(t.width + em * 2.3, em * 5).rounded(), height: max(t.height + em * 1.43, em * 2.86).rounded())
        }
        let boxHeight = boxes.map(\.height).max() ?? 0
        let badge = d.autonumber ? em * 1.6 : 0

        // Distances between neighbouring columns: their boxes, then the labels that span them.
        var need = [Double](repeating: 0, count: n)
        for i in 1..<max(n, 1) { need[i] = boxes[i - 1].width / 2 + boxes[i].width / 2 + em * 4 * st.spacing }
        for step in d.steps {
            switch step {
            case let .message(from, to, text, _, _):
                guard let a = index[from], let b = index[to] else { continue }
                let width = measure(text).width + em * 2 + badge
                if a == b {
                    if a + 1 < n { need[a + 1] = max(need[a + 1], width + em * 2) }
                    continue
                }
                let lo = min(a, b), hi = max(a, b)
                let current = need[(lo + 1)...hi].reduce(0, +)
                if current < width { need[hi] += width - current }
            case let .note(.over, names, text):
                let ids = names.compactMap { index[$0] }
                guard let lo = ids.min(), let hi = ids.max(), hi > lo else { continue }
                let width = measure(text).width + em * 1.6
                let current = need[(lo + 1)...hi].reduce(0, +) + em * 2.4
                if current < width { need[hi] += width - current }
            default: continue
            }
        }
        var center = [Double](repeating: 0, count: n)
        for i in 0..<n { center[i] = i == 0 ? 0 : center[i - 1] + need[i] }

        var items: [DiagramScene.Item] = []
        var frames: [DiagramScene.Item] = []
        var open: [(kind: String, label: String, top: Double, dividers: [(Double, String)])] = []
        var row = boxHeight + em * 1.4
        var number = 0
        let left = (center.first ?? 0) - (boxes.first?.width ?? 0) / 2, right = (center.last ?? 0) + (boxes.last?.width ?? 0) / 2
        for step in d.steps {
            switch step {
            case let .message(from, to, text, line, kind):
                guard let a = index[from], let b = index[to] else { continue }
                let size = measure(text)
                let head: DiagramScene.Head? = switch kind {
                case .arrow: .filled
                case .async: .chevron
                case .cross: .cross
                case .open: nil
                }
                number += 1
                if a == b {
                    let x0 = center[a]
                    items.append(.text(DiagramRect(x: x0 + em * 0.7 + badge, y: row, width: size.width, height: size.height), text, boxed: false))
                    row += size.height + em * 0.35
                    let w = em * 1.8, h = em * 1.3
                    items.append(.path([.move(DiagramPoint(x: x0, y: row)), .line(DiagramPoint(x: x0 + w, y: row)), .line(DiagramPoint(x: x0 + w, y: row + h)), .line(DiagramPoint(x: x0 + 1, y: row + h))],
                                       dashed: line == .dashed, thick: false, head: head, tail: nil))
                    if d.autonumber { items.append(.number(DiagramPoint(x: x0, y: row), number)) }
                    row += h + em * 1.1 * st.spacing
                } else {
                    let mid = (center[a] + center[b]) / 2
                    items.append(.text(DiagramRect(x: mid - size.width / 2 + badge / 2, y: row, width: size.width, height: size.height), text, boxed: false))
                    row += size.height + em * 0.35
                    let toward: Double = b > a ? 1 : -1
                    items.append(.path([.move(DiagramPoint(x: center[a], y: row)), .line(DiagramPoint(x: center[b] - toward, y: row))], dashed: line == .dashed, thick: false, head: head, tail: nil))
                    if d.autonumber { items.append(.number(DiagramPoint(x: center[a], y: row), number)) }
                    row += em * 1.25 * st.spacing
                }
            case let .note(place, names, text):
                let ids = names.compactMap { index[$0] }
                guard let first = ids.min(), let last = ids.max() else { continue }
                let size = measure(text)
                let width = size.width + em * 1.6, height = size.height + em * 0.9
                var rect: DiagramRect
                switch place {
                case .left: rect = DiagramRect(x: center[first] - em * 0.6 - width, y: row, width: width, height: height)
                case .right: rect = DiagramRect(x: center[first] + em * 0.6, y: row, width: width, height: height)
                case .over:
                    let span = center[last] - center[first] + (last > first ? em * 2.4 : 0)
                    let w = max(width, span)
                    rect = DiagramRect(x: (center[first] + center[last]) / 2 - w / 2, y: row, width: w, height: height)
                }
                items.append(.note(rect, text))
                row += height + em * 1.0 * st.spacing
            case let .begin(kind, label):
                open.append((kind, label, row, []))
                // Room for the block's tag (0.8 em type) above its first row.
                row += em * 1.75
            case let .divider(label):
                guard !open.isEmpty else { continue }
                open[open.count - 1].dividers.append((row, label))
                row += label.isEmpty ? em * 0.9 : em * 2
            case .end:
                guard let block = open.popLast() else { continue }
                let inset = Double(open.count) * em * 0.6
                let rect = DiagramRect(x: left - em * 0.9 + inset, y: block.top - em * 0.3, width: right - left + em * 1.8 - inset * 2, height: row - block.top + em * 0.1)
                frames.append(.frame(rect, kind: block.kind, label: block.label))
                for (y, label) in block.dividers { frames.append(.divider(y: y - em * 0.3, from: rect.minX, to: rect.maxX, label: label)) }
                row += em * 0.9
            }
        }
        let bottom = row
        var scene = frames
        for (i, p) in d.participants.enumerated() {
            scene.append(.lifeline(x: center[i], top: boxHeight, bottom: bottom))
            scene.append(.participant(DiagramRect(x: center[i] - boxes[i].width / 2, y: 0, width: boxes[i].width, height: boxHeight), p.label, actor: p.isActor))
        }
        scene += items
        return normalized(scene, margin: em * 0.75)
    }

    /// Moves the items so their bounds start at `margin`, and sizes the scene around them.
    static func normalized(_ items: [DiagramScene.Item], margin: Double) -> DiagramScene {
        var bounds: DiagramRect?
        func add(_ r: DiagramRect) { bounds = bounds.map { $0.union(r) } ?? r }
        for item in items {
            switch item {
            case let .node(r, _, _), let .participant(r, _, _), let .text(r, _, _), let .note(r, _), let .frame(r, _, _): add(r)
            case let .path(segments, _, _, _, _):
                for s in segments {
                    add(DiagramRect(x: s.end.x, y: s.end.y, width: 0, height: 0))
                    if case let .curve(a, b, _) = s {
                        add(DiagramRect(x: a.x, y: a.y, width: 0, height: 0))
                        add(DiagramRect(x: b.x, y: b.y, width: 0, height: 0))
                    }
                }
            case let .lifeline(x, top, bottom): add(DiagramRect(x: x, y: top, width: 0, height: bottom - top))
            case let .divider(y, from, to, _): add(DiagramRect(x: from, y: y, width: to - from, height: 0))
            case let .number(p, _): add(DiagramRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16))
            }
        }
        guard let bounds else { return DiagramScene(size: DiagramSize(width: 0, height: 0), items: []) }
        let dx = margin - bounds.minX, dy = margin - bounds.minY
        func t(_ p: DiagramPoint) -> DiagramPoint { DiagramPoint(x: p.x + dx, y: p.y + dy) }
        func t(_ r: DiagramRect) -> DiagramRect { DiagramRect(x: r.x + dx, y: r.y + dy, width: r.width, height: r.height) }
        let moved: [DiagramScene.Item] = items.map { item in
            switch item {
            case let .node(r, shape, label): .node(t(r), shape, label)
            case let .participant(r, label, actor): .participant(t(r), label, actor: actor)
            case let .text(r, label, boxed): .text(t(r), label, boxed: boxed)
            case let .note(r, label): .note(t(r), label)
            case let .frame(r, kind, label): .frame(t(r), kind: kind, label: label)
            case let .path(segments, dashed, thick, head, tail):
                .path(segments.map { s -> DiagramScene.Segment in
                    switch s {
                    case let .move(p): .move(t(p))
                    case let .line(p): .line(t(p))
                    case let .curve(a, b, p): .curve(t(a), t(b), t(p))
                    }
                }, dashed: dashed, thick: thick, head: head, tail: tail)
            case let .lifeline(x, top, bottom): .lifeline(x: x + dx, top: top + dy, bottom: bottom + dy)
            case let .divider(y, from, to, label): .divider(y: y + dy, from: from + dx, to: to + dx, label: label)
            case let .number(p, n): .number(t(p), n)
            }
        }
        return DiagramScene(size: DiagramSize(width: (bounds.width + margin * 2).rounded(.up), height: (bounds.height + margin * 2).rounded(.up)), items: moved)
    }
}
