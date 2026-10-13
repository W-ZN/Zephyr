import Foundation
import Testing
@testable import ZephyrCore

/// Mermaid blocks Zephyr draws itself (design §8.1): the parser's subset, and a layout whose
/// boxes never overlap.
@Suite struct MermaidTests {
    static func measure(_ text: String) -> DiagramSize {
        let lines = text.components(separatedBy: "\n")
        return DiagramSize(width: Double(lines.map(\.count).max() ?? 0) * 8, height: Double(lines.count) * 16)
    }

    static func chip(_ rect: DiagramRect, fontSize: Double) -> DiagramRect {
        let dx = fontSize * 6 / 14, dy = fontSize * 3 / 14
        return DiagramRect(x: rect.x - dx, y: rect.y - dy, width: rect.width + dx * 2, height: rect.height + dy * 2)
    }

    static func overlaps(_ a: DiagramRect, _ b: DiagramRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    static func pointIsOnLine(_ point: DiagramPoint, segments: [DiagramScene.Segment], horizontal: Bool) -> Bool {
        var start: DiagramPoint?
        for segment in segments {
            switch segment {
            case let .move(point): start = point
            case let .line(end):
                guard let begin = start else { continue }
                let pointMain = horizontal ? point.x : point.y, pointCross = horizontal ? point.y : point.x
                let beginMain = horizontal ? begin.x : begin.y, beginCross = horizontal ? begin.y : begin.x
                let endMain = horizontal ? end.x : end.y, endCross = horizontal ? end.y : end.x
                if abs(beginCross - endCross) < 0.001 && abs(pointCross - beginCross) < 0.001 && pointMain >= min(beginMain, endMain) && pointMain <= max(beginMain, endMain) { return true }
                start = end
            case let .curve(_, _, end):
                // A flowing return meets its track at the junction of its two curves.
                if hypot(point.x - end.x, point.y - end.y) < 0.5 { return true }
                start = end
            }
        }
        return false
    }

    static func minimumCross(_ segments: [DiagramScene.Segment], horizontal: Bool) -> Double {
        -maximumCross(segments, horizontal: horizontal, sign: -1)
    }

    static func maximumCross(_ segments: [DiagramScene.Segment], horizontal: Bool, sign: Double = 1) -> Double {
        var maximum = -Double.infinity
        for segment in segments {
            let points: [DiagramPoint]
            switch segment {
            case let .move(point), let .line(point): points = [point]
            case let .curve(a, b, end): points = [a, b, end]
            }
            for point in points { maximum = max(maximum, sign * (horizontal ? point.y : point.x)) }
        }
        return maximum
    }

    @Test func parsesFlowchartLinksShapesAndLabels() throws {
        let source = """
        flowchart LR
          A[Start] -->|yes| B{Check}; B -- no --> C((Done))
          B -.-> D([Later]) & E[(Store)]
          C ==> A
          classDef hot fill:#f00
          subgraph inner
            E --- F
          end
        """
        guard case let .flowchart(c) = try #require(MermaidDiagram.parse(source)) else { Issue.record("not a flowchart"); return }
        #expect(c.direction == .right)
        #expect(c.nodes.map(\.id) == ["A", "B", "C", "D", "E", "F"])
        #expect(c.nodes.map(\.shape) == [.rectangle, .diamond, .circle, .stadium, .database, .rectangle])
        #expect(c.edges.count == 6)
        #expect(c.edges[0].label == "yes" && c.edges[0].arrow)
        #expect(c.edges[1].label == "no" && c.edges[1].arrow && c.edges[1].from == "B" && c.edges[1].to == "C")
        #expect(c.edges[2].stroke == .dotted && c.edges[3].to == "E")
        #expect(c.edges[4].stroke == .thick)
        #expect(!c.edges[5].arrow)
    }

    @Test func parsesSequenceDiagrams() throws {
        let source = """
        sequenceDiagram
          autonumber
          participant U as You
          U->>Z: open
          loop every edit
            Z-->>U: diff
          else
            U-xZ: drop
          end
          Note over U,Z: the file is the source
        """
        guard case let .sequence(d) = try #require(MermaidDiagram.parse(source)) else { Issue.record("not a sequence diagram"); return }
        #expect(d.autonumber)
        #expect(d.participants.map(\.label) == ["You", "Z"])
        #expect(d.steps.count == 7)
        #expect(d.steps[0] == .message(from: "U", to: "Z", text: "open", line: .solid, head: .arrow))
        #expect(d.steps[2] == .message(from: "Z", to: "U", text: "diff", line: .dashed, head: .arrow))
        #expect(d.steps[4] == .message(from: "U", to: "Z", text: "drop", line: .solid, head: .cross))
    }

    @Test func otherDiagramsStayCode() {
        #expect(MermaidDiagram.parse("pie title Pets\n \"Dogs\" : 386") == nil)
        #expect(MermaidDiagram.parse("sequenceDiagram\n loop x\n A->>B: hi") == nil, "an unclosed block")
        #expect(MermaidDiagram.parse("graph TD\n A[unclosed --> B") == nil)
    }

    @Test func flowchartBoxesDoNotOverlap() throws {
        let source = "graph TD\n A --> B & C & D\n B --> E\n C --> E\n D --> F --> A\n A --> F"
        let scene = DiagramLayout.layout(try #require(MermaidDiagram.parse(source)), style: DiagramStyle(fontSize: 14, spacing: 1, lines: .curved), measure: Self.measure)
        let boxes = scene.items.compactMap { item -> DiagramRect? in
            if case let .node(r, _, _) = item { return r }
            return nil
        }
        #expect(boxes.count == 6)
        for (i, a) in boxes.enumerated() {
            #expect(a.minX >= 0 && a.minY >= 0 && a.maxX <= scene.size.width && a.maxY <= scene.size.height)
            for b in boxes[(i + 1)...] {
                #expect(a.maxX <= b.minX || b.maxX <= a.minX || a.maxY <= b.minY || b.maxY <= a.minY, "boxes overlap")
            }
        }
    }

    @Test func tallEdgeLabelsStayInTheScene() throws {
        let source = "graph LR\n A -->|first line<br>second line<br>third line<br>fourth line| B"
        let scene = DiagramLayout.layout(try #require(MermaidDiagram.parse(source)), style: DiagramStyle(fontSize: 14, spacing: 1, lines: .curved), measure: Self.measure)
        let label = try #require(scene.items.compactMap { item -> DiagramRect? in if case let .text(r, _, true) = item { r } else { nil } }.first)
        #expect(label.height == 64)
        #expect(label.minY > 0 && label.maxY < scene.size.height && label.minX > 0 && label.maxX < scene.size.width)
    }

    @Test func cyclicFlowchartEdgeChipsUseSeparateRows() throws {
        let chart = """
        A[引文定位<br>来源分级<br>冲突仲裁] --> B[更新候选—线索对照表]
        B --> C[Verifier 全链核验]
        C -->|全部有支持| D[答案定型并提交]
        C -->|剩余时间不足| D
        B -->|仍有未确认的格| A
        C -->|缺证据或有冲突| A
        D -->|通过| A
        """
        for direction in ["TB", "BT", "LR", "RL"] {
            let diagram = try #require(MermaidDiagram.parse("graph \(direction)\n\(chart)"))
            for lines in [DiagramStyle.Lines.straight, .curved, .angled] {
                let scene = DiagramLayout.layout(diagram, style: DiagramStyle(fontSize: 14, spacing: 1, lines: lines), measure: Self.measure)
                let chips = scene.items.compactMap { item -> DiagramRect? in if case let .text(rect, _, true) = item { Self.chip(rect, fontSize: 14) } else { nil } }
                let nodes = scene.items.compactMap { item -> DiagramRect? in if case let .node(rect, _, _) = item { rect } else { nil } }
                let paths = scene.items.compactMap { item -> [DiagramScene.Segment]? in if case let .path(segments, _, _, _, _) = item { segments } else { nil } }
                let horizontal = direction == "LR" || direction == "RL"
                #expect(chips.count == 5)
                #expect(paths.count == 7)
                let spine = nodes.prefix(4).map { horizontal ? $0.midY : $0.midX }
                #expect((spine.max() ?? 0) - (spine.min() ?? 0) < 1)
                for (i, chip) in chips.enumerated() {
                    #expect(chip.minX >= 0 && chip.minY >= 0 && chip.maxX <= scene.size.width && chip.maxY <= scene.size.height)
                    for other in chips.dropFirst(i + 1) { #expect(!Self.overlaps(chip, other), "edge chips overlap") }
                    for node in nodes { #expect(!Self.overlaps(chip, node), "edge chip overlaps a node") }
                }
                let nodeHigh = nodes.map { horizontal ? $0.maxY : $0.maxX }.max() ?? 0
                let nodeLow = nodes.map { horizontal ? $0.minY : $0.minX }.min() ?? 0
                for (path, chip) in zip(paths.suffix(3), chips.suffix(3)) {
                    // A return loops outside the boxes, on whichever side it took.
                    #expect(Self.maximumCross(path, horizontal: horizontal) > nodeHigh || Self.minimumCross(path, horizontal: horizontal) < nodeLow)
                    #expect(Self.pointIsOnLine(DiagramPoint(x: chip.midX, y: chip.midY), segments: path, horizontal: horizontal), "return label is not on its track")
                }
            }
        }
    }

    @Test func singleEdgeChipKeepsTheBaseGap() throws {
        let style = DiagramStyle(fontSize: 14, spacing: 1, lines: .curved)
        let plain = DiagramLayout.layout(try #require(MermaidDiagram.parse("graph TB\n A --> B")), style: style, measure: Self.measure)
        let labelled = DiagramLayout.layout(try #require(MermaidDiagram.parse("graph TB\n A -->|yes| B")), style: style, measure: Self.measure)
        #expect(labelled.size == plain.size)
    }

    @Test func returnTracksClearForwardLongEdges() throws {
        let source = "graph TB\n A --> B --> Z\n" + (0..<12).map { "A -->|route \($0)| Z" }.joined(separator: "\n") + "\n Z --> A"
        let scene = DiagramLayout.layout(try #require(MermaidDiagram.parse(source)), style: DiagramStyle(fontSize: 14, spacing: 1, lines: .curved), measure: Self.measure)
        let paths = scene.items.compactMap { item -> [DiagramScene.Segment]? in if case let .path(segments, _, _, _, _) = item { segments } else { nil } }
        let forwardHigh = paths.dropLast().map { Self.maximumCross($0, horizontal: false) }.max()!
        let forwardLow = paths.dropLast().map { Self.minimumCross($0, horizontal: false) }.min()!
        #expect(Self.maximumCross(paths.last!, horizontal: false) > forwardHigh + 14 || Self.minimumCross(paths.last!, horizontal: false) < forwardLow - 14)
    }

    @Test func returnPortsTouchCurvedAndAngledShapes() throws {
        for shape in ["C{C}", "C((C))", "C([C])", "C{{C}}"] {
            for direction in ["TB", "BT", "LR", "RL"] {
                let source = "graph \(direction)\n A --> B --> \(shape)\n C --> A\n C --> B"
                let scene = DiagramLayout.layout(try #require(MermaidDiagram.parse(source)), style: DiagramStyle(fontSize: 14, spacing: 1, lines: .curved), measure: Self.measure)
                let node = try #require(scene.items.compactMap { item -> DiagramRect? in if case let .node(rect, _, "C") = item { rect } else { nil } }.first)
                let paths = scene.items.compactMap { item -> [DiagramScene.Segment]? in if case let .path(segments, _, _, _, _) = item { segments } else { nil } }
                let horizontal = direction == "LR" || direction == "RL"
                let high = DiagramPoint(x: horizontal ? node.midX : node.maxX, y: horizontal ? node.maxY : node.midY)
                let low = DiagramPoint(x: horizontal ? node.midX : node.minX, y: horizontal ? node.minY : node.midY)
                for path in paths.suffix(2) { #expect(path.first == .move(high) || path.first == .move(low), "return port detached from the node outline") }
            }
        }
    }

    static let multihop = """
    flowchart TD
        Q[原题] --> P[Navigator: 解析变量和约束 提出候选 写首轮查询]
        P --> R[Runtime: 并行检索 摘要预筛 抓取 切段]
        R --> M[Reranker: 段落 x 陈述 支持度矩阵]
        M --> X[Extractor: 判断支持并给出引文]
        X --> T[Runtime: 引文检查 来源分级 冲突仲裁 更新对照表]
        T -->|有候选全部有支持| V[Verifier: 全链核验]
        T -->|仍有未确认的格| S[Runtime: 按优先级选格]
        S --> N[Navigator: 为选中的格写查询 提出新候选]
        N --> R
        V -->|通过| A[Runtime: 答案定型并提交]
        V -->|不通过| S
        T -->|剩余时间不足 60 秒| A
    """

    /// A return from a node on the chart's left loops on the left, beside the nodes it passes, and
    /// with round corners when lines are curved (the multihop README's retrieval loop).
    @Test func returnsLoopOnTheNearerSide() throws {
        let scene = DiagramLayout.layout(try #require(MermaidDiagram.parse(Self.multihop)), style: DiagramStyle(fontSize: 14, spacing: 1, lines: .curved), measure: Self.measure)
        let nodes = scene.items.compactMap { item -> (DiagramRect, String)? in if case let .node(rect, _, label) = item { (rect, label) } else { nil } }
        let paths = scene.items.compactMap { item -> [DiagramScene.Segment]? in if case let .path(segments, _, _, _, _) = item { segments } else { nil } }
        let navigator = try #require(nodes.first { $0.1.hasPrefix("Navigator: 为选中") }?.0)
        let runtime = try #require(nodes.first { $0.1.hasPrefix("Runtime: 并行检索") }?.0)
        let loop = paths[8]   // N --> R
        #expect(navigator.midX < runtime.midX, "the sample's lower Navigator sits left of the loop's target")
        #expect(Self.minimumCross(loop, horizontal: false) < runtime.minX, "the return does not loop on the left")
        #expect(Self.maximumCross(loop, horizontal: false) <= max(navigator.maxX, runtime.maxX), "the return crosses to the right")
        #expect(loop.filter { if case .curve = $0 { true } else { false } }.count == 2, "a curved return turns with two round corners")
        #expect(scene.items.allSatisfy { item in
            if case let .node(rect, _, _) = item { return rect.minX >= 0 }
            return true
        })
    }

    /// A label covers only its own line: one on a long link sits on the link's middle point, which
    /// takes room in its rank, and a row of labels moves to where the lines fanning out of a box
    /// have spread apart.
    @Test(arguments: [DiagramStyle.Lines.curved, .straight, .angled])
    func labelsCoverOnlyTheirOwnLine(lines: DiagramStyle.Lines) throws {
        let scene = DiagramLayout.layout(try #require(MermaidDiagram.parse(Self.multihop)), style: DiagramStyle(fontSize: 14, spacing: 1, lines: lines), measure: Self.measure)
        let labels = scene.items.compactMap { item -> DiagramRect? in if case let .text(rect, _, true) = item { rect } else { nil } }
        let paths = scene.items.compactMap { item -> [DiagramScene.Segment]? in if case let .path(segments, _, _, _, _) = item { segments } else { nil } }
        func samples(_ segments: [DiagramScene.Segment]) -> [DiagramPoint] {
            var out: [DiagramPoint] = [], last = DiagramPoint(x: 0, y: 0)
            for segment in segments {
                for i in 1...40 {
                    let t = Double(i) / 40, u = 1 - t
                    switch segment {
                    case .move: break
                    case let .line(p): out.append(DiagramPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t))
                    case let .curve(a, b, p):
                        out.append(DiagramPoint(x: u * u * u * last.x + 3 * u * u * t * a.x + 3 * u * t * t * b.x + t * t * t * p.x,
                                                y: u * u * u * last.y + 3 * u * u * t * a.y + 3 * u * t * t * b.y + t * t * t * p.y))
                    }
                }
                last = segment.end
            }
            return out
        }
        #expect(labels.count == 5)
        for label in labels {
            let chip = Self.chip(label, fontSize: 14)
            let crossing = paths.filter { path in samples(path).contains { chip.minX < $0.x && $0.x < chip.maxX && chip.minY < $0.y && $0.y < chip.maxY } }
            #expect(crossing.count == 1, "\(lines): a label is crossed by \(crossing.count) lines at \(label)")
        }
    }
}
