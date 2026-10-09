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
}
