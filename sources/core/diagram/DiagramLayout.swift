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

        // Vertices: the nodes, then one virtual point per rank crossed by a long edge.
        var cross = sizes.map { horizontal ? $0.height : $0.width }
        var main = sizes.map { horizontal ? $0.width : $0.height }
        var vRank = rank
        var chains: [[Int]] = []
        for (k, e) in edges.enumerated() {
            if e.0 == e.1 {
                chains.append([e.0])
                continue
            }
            let (lo, hi) = back.contains(k) ? (e.1, e.0) : e
            var chain = [lo]
            for r in stride(from: vRank[lo] + 1, to: vRank[hi], by: 1) {
                cross.append(em * 0.6)
                main.append(0)
                vRank.append(r)
                chain.append(cross.count - 1)
            }
            chain.append(hi)
            chains.append(back.contains(k) ? chain.reversed() : chain)
        }
        let count = cross.count
        let ranks = (vRank.max() ?? 0) + 1
        var layers = [[Int]](repeating: [], count: ranks)
        for v in 0..<count { layers[vRank[v]].append(v) }
        var above = [[Int]](repeating: [], count: count), below = [[Int]](repeating: [], count: count)
        for chain in chains where chain.count > 1 {
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
        func separation(_ a: Int, _ b: Int) -> Double { (cross[a] + cross[b]) / 2 + (a < n && b < n ? gap : gap * 0.4) }
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

        // Main positions: each rank as deep as its deepest node, gaps wide enough for labels.
        var rankDepth = [Double](repeating: 0, count: ranks)
        for v in 0..<count { rankDepth[vRank[v]] = max(rankDepth[vRank[v]], main[v]) }
        var rankGap = [Double](repeating: em * 3.4 * st.spacing, count: ranks)
        var labelSizes = [DiagramSize?](repeating: nil, count: edges.count)
        for (k, edge) in c.edges.enumerated() {
            guard let label = edge.label, !label.isEmpty else { continue }
            let size = measure(label)
            labelSizes[k] = size
            let chain = chains[k]
            guard chain.count > 1 else { continue }
            let r = min(vRank[chain[0]], vRank[chain[1]])
            rankGap[r] = max(rankGap[r], (horizontal ? size.width : size.height) + em * 1.6)
        }
        let margin = em * 0.75
        var y = [Double](repeating: 0, count: ranks)
        var cursor = margin
        for r in 0..<ranks {
            y[r] = cursor + rankDepth[r] / 2
            cursor += rankDepth[r] + rankGap[r]
        }
        let totalMain = cursor - rankGap[ranks - 1] + margin
        let minCross = (0..<count).map { x[$0] - cross[$0] / 2 }.min() ?? 0
        for v in 0..<count { x[v] += margin - minCross }
        let totalCross = ((0..<count).map { x[$0] + cross[$0] / 2 }.max() ?? 0) + margin
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

        // Ports: several links leaving or entering one side of a box spread along it.
        var ports: [[Int: Double]] = Array(repeating: [:], count: chains.count)
        for v in 0..<n where ![.diamond, .circle].contains(c.nodes[v].shape) {
            for sideBelow in [true, false] {
                var ends: [(chain: Int, toward: Double, start: Bool)] = []
                for (k, chain) in chains.enumerated() where chain.count > 1 {
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
            // Points on the main and cross axes: out of the first box, through the virtual points, into the last.
            var points: [(m: Double, c: Double)] = []
            for (i, v) in chain.enumerated() {
                let r = vRank[v]
                if i == 0 || i == chain.count - 1 {
                    let other = i == 0 ? chain[1] : chain[chain.count - 2]
                    let toward: Double = vRank[other] > r ? 1 : -1
                    points.append((y[r] + toward * main[v] / 2, x[v] + (ports[k][i == 0 ? 0 : 1] ?? 0)))
                } else {
                    points.append((y[r], x[v]))
                }
            }
            var segments: [DiagramScene.Segment] = [.move(place(points[0].m, points[0].c))]
            for (p, q) in zip(points, points.dropFirst()) {
                switch st.lines {
                case .straight:
                    segments.append(.line(place(q.m, q.c)))
                case .curved:
                    let half = (q.m - p.m) / 2
                    segments.append(.curve(place(p.m + half, p.c), place(q.m - half, q.c), place(q.m, q.c)))
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
            if let size = labelSizes[k] {
                let center = place((points[0].m + points[1].m) / 2, (points[0].c + points[1].c) / 2)
                labels.append(.text(DiagramRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), edge.label!, boxed: true))
            }
        }
        for v in 0..<n {
            let center = place(y[vRank[v]], x[v])
            items.append(.node(DiagramRect(x: center.x - sizes[v].width / 2, y: center.y - sizes[v].height / 2, width: sizes[v].width, height: sizes[v].height), c.nodes[v].shape, c.nodes[v].label))
        }
        let crossExtent = max(totalCross, loopReach + margin)
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
