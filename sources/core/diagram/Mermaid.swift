import Foundation

/// The Mermaid diagrams Zephyr draws itself (design §8.1): flowcharts and sequence diagrams, in
/// the subset people write by hand. Anything else (other diagram types, a header it does not
/// know) parses to nil, and the block stays code.
public enum MermaidDiagram: Sendable, Equatable {
    case flowchart(Flowchart)
    case sequence(SequenceDiagram)

    public static func parse(_ source: String) -> MermaidDiagram? {
        var lines = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        lines.removeAll { $0.isEmpty || $0.hasPrefix("%%") }
        guard let header = lines.first?.split(separator: " ", omittingEmptySubsequences: true) else { return nil }
        let body = Array(lines.dropFirst())
        switch header.first.map(String.init) {
        case "graph", "flowchart":
            return Flowchart.parse(direction: header.count > 1 ? String(header[1]) : "TD", body).map { .flowchart($0) }
        case "sequenceDiagram":
            return SequenceDiagram.parse(body).map { .sequence($0) }
        default:
            return nil
        }
    }

    /// Mermaid labels: surrounding quotes go, `<br>` breaks a line.
    static func label(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") { text = String(text.dropFirst().dropLast()) }
        return text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
    }
}

// MARK: - Flowchart

public struct Flowchart: Sendable, Equatable {
    public enum Direction: Sendable, Equatable { case down, up, right, left }
    public enum Shape: Sendable, Equatable { case rectangle, rounded, stadium, subroutine, database, circle, diamond, hexagon, flag }
    public enum Stroke: Sendable, Equatable { case solid, dotted, thick }

    public struct Node: Sendable, Equatable {
        public var id: String
        public var label: String
        public var shape: Shape
    }

    public struct Edge: Sendable, Equatable {
        public var from: String
        public var to: String
        public var label: String?
        public var stroke: Stroke
        public var arrow: Bool
        public var arrowBack: Bool
    }

    public var direction: Direction
    public var nodes: [Node]
    public var edges: [Edge]

    /// Openers and closers of node shapes, longest first.
    static let shapes: [(open: String, close: String, shape: Shape)] = [
        ("([", "])", .stadium), ("[[", "]]", .subroutine), ("[(", ")]", .database), ("((", "))", .circle),
        ("{{", "}}", .hexagon), ("[/", "/]", .rectangle), ("[\\", "\\]", .rectangle), ("[", "]", .rectangle),
        ("(", ")", .rounded), ("{", "}", .diamond), (">", "]", .flag),
    ]

    static func parse(direction raw: String, _ lines: [String]) -> Flowchart? {
        let direction: Direction = switch raw.uppercased() {
        case "LR": .right
        case "RL": .left
        case "BT": .up
        default: .down
        }
        var chart = Flowchart(direction: direction, nodes: [], edges: [])
        var index: [String: Int] = [:]
        func node(_ id: String, _ label: String?, _ shape: Shape?) {
            if let i = index[id] {
                if let label { chart.nodes[i].label = label }
                if let shape { chart.nodes[i].shape = shape }
            } else {
                index[id] = chart.nodes.count
                chart.nodes.append(Node(id: id, label: label ?? id, shape: shape ?? .rectangle))
            }
        }
        let skipped = ["classDef", "class", "style", "linkStyle", "click", "direction", "end", "accTitle", "accDescr"]
        for line in lines.flatMap({ $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }) where !line.isEmpty {
            let word = line.split(separator: " ").first.map(String.init) ?? ""
            if word == "subgraph" || skipped.contains(word) { continue }
            var scanner = Scan(line)
            guard var group = scanner.nodes() else { return nil }
            for n in group { node(n.id, n.label, n.shape) }
            while !scanner.atEnd {
                guard let link = scanner.link(), let next = scanner.nodes() else { return nil }
                for n in next { node(n.id, n.label, n.shape) }
                for a in group {
                    for b in next {
                        chart.edges.append(Edge(from: a.id, to: b.id, label: link.label, stroke: link.stroke, arrow: link.arrow, arrowBack: link.arrowBack))
                    }
                }
                group = next
            }
        }
        return chart.nodes.isEmpty ? nil : chart
    }

    /// Reads one statement: node groups (`A & B`) joined by links.
    struct Scan {
        let s: [Character]
        var i = 0
        init(_ line: String) { s = Array(line) }

        var atEnd: Bool {
            mutating get {
                skipSpace()
                return i >= s.count
            }
        }

        mutating func skipSpace() { while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 } }

        func starts(_ text: String, at j: Int) -> Bool {
            let t = Array(text)
            return j + t.count <= s.count && Array(s[j..<j + t.count]) == t
        }

        mutating func nodes() -> [(id: String, label: String?, shape: Shape?)]? {
            var result: [(id: String, label: String?, shape: Shape?)] = []
            repeat {
                skipSpace()
                guard let n = node() else { return nil }
                result.append(n)
                skipSpace()
            } while consume("&")
            return result
        }

        mutating func consume(_ text: String) -> Bool {
            guard starts(text, at: i) else { return false }
            i += text.count
            return true
        }

        mutating func node() -> (id: String, label: String?, shape: Shape?)? {
            let start = i
            while i < s.count, s[i].isLetter || s[i].isNumber || s[i] == "_" || (s[i] == "-" && !starts("--", at: i) && !starts("-.", at: i)) || s[i] == "." && i > start && !starts(".-", at: i) {
                i += 1
            }
            guard i > start else { return nil }
            let id = String(s[start..<i])
            for (open, close, shape) in Flowchart.shapes where starts(open, at: i) {
                let from = i + open.count
                var j = from
                var quoted = false
                while j < s.count {
                    if s[j] == "\"" { quoted.toggle() }
                    if !quoted, starts(close, at: j) { break }
                    j += 1
                }
                guard j < s.count else { return nil }
                i = j + close.count
                if starts(":::", at: i) { while i < s.count, s[i] != " " { i += 1 } }
                return (id, MermaidDiagram.label(String(s[from..<j])), shape)
            }
            if starts(":::", at: i) { while i < s.count, s[i] != " " { i += 1 } }
            return (id, nil, nil)
        }

        /// `-->`, `---`, `-.->`, `==>`, `<-->`, with `|label|` after or `-- label -->` around.
        mutating func link() -> (label: String?, stroke: Stroke, arrow: Bool, arrowBack: Bool)? {
            skipSpace()
            let back = consume("<")
            let start = i
            while i < s.count, "-=.".contains(s[i]) { i += 1 }
            let body = String(s[start..<i])
            guard body.count >= 2 else { return nil }
            let stroke: Stroke = body.contains("=") ? .thick : body.contains(".") ? .dotted : .solid
            var arrow = false
            // `x` and `o` heads only when they end the link (`--x B`), not when they start a name.
            if i < s.count, s[i] == ">" || "xo".contains(s[i]) && (i + 1 == s.count || " |".contains(s[i + 1])) {
                arrow = true
                i += 1
            }
            skipSpace()
            if consume("|") {
                let from = i
                while i < s.count, s[i] != "|" { i += 1 }
                guard i < s.count else { return nil }
                let text = String(s[from..<i])
                i += 1
                return (MermaidDiagram.label(text), stroke, arrow, back)
            }
            if !arrow, body.count <= 2 {
                // `-- label -->`: the text runs to the closing half of the link.
                let closers = ["-->", "---", "==>", "===", ".->", "-.-", "--x", "--o"]
                var j = i
                while j < s.count, !closers.contains(where: { starts($0, at: j) }) { j += 1 }
                guard j < s.count, j > i else { return nil }
                let text = String(s[i..<j])
                i = j
                let rest = link()
                return (MermaidDiagram.label(text), rest?.stroke ?? stroke, rest?.arrow ?? false, back)
            }
            return (nil, stroke, arrow, back)
        }
    }
}

// MARK: - Sequence diagram

public struct SequenceDiagram: Sendable, Equatable {
    public struct Participant: Sendable, Equatable {
        public var id: String
        public var label: String
        public var isActor: Bool
    }

    public enum Line: Sendable, Equatable { case solid, dashed }
    public enum Head: Sendable, Equatable { case arrow, open, cross, async }
    public enum NotePlace: Sendable, Equatable { case left, right, over }

    public enum Step: Sendable, Equatable {
        case message(from: String, to: String, text: String, line: Line, head: Head)
        case note(place: NotePlace, participants: [String], text: String)
        /// `loop`, `alt`, `opt`, `par`, `critical`, `break`, `rect` with their label.
        case begin(kind: String, label: String)
        /// `else` and `and` inside a block.
        case divider(label: String)
        case end
    }

    public var participants: [Participant]
    public var steps: [Step]
    public var autonumber: Bool

    static func parse(_ lines: [String]) -> SequenceDiagram? {
        var d = SequenceDiagram(participants: [], steps: [], autonumber: false)
        func participant(_ id: String, label: String? = nil, actor: Bool = false) {
            if let i = d.participants.firstIndex(where: { $0.id == id }) {
                if let label { d.participants[i].label = label }
                return
            }
            d.participants.append(Participant(id: id, label: label ?? id, isActor: actor))
        }
        let arrows: [(String, Line, Head)] = [("-->>", .dashed, .arrow), ("->>", .solid, .arrow), ("--x", .dashed, .cross), ("-x", .solid, .cross),
                                               ("--)", .dashed, .async), ("-)", .solid, .async), ("-->", .dashed, .open), ("->", .solid, .open)]
        var depth = 0
        for line in lines {
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            let first = words.first ?? ""
            let rest = words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : ""
            switch first {
            case "participant", "actor":
                let parts = rest.components(separatedBy: " as ")
                participant(parts[0].trimmingCharacters(in: .whitespaces), label: parts.count > 1 ? MermaidDiagram.label(parts[1]) : nil, actor: first == "actor")
            case "autonumber":
                d.autonumber = true
            case "activate", "deactivate", "title", "box", "create", "destroy", "links", "link", "properties", "details":
                continue
            case "loop", "alt", "opt", "par", "critical", "break", "rect":
                depth += 1
                d.steps.append(.begin(kind: first, label: first == "rect" ? "" : MermaidDiagram.label(rest)))
            case "else", "and", "option":
                d.steps.append(.divider(label: MermaidDiagram.label(rest)))
            case "end":
                guard depth > 0 else { return nil }
                depth -= 1
                d.steps.append(.end)
            default:
                if first.lowercased() == "note" {
                    guard let colon = rest.firstIndex(of: ":") else { return nil }
                    let place = rest[..<colon].trimmingCharacters(in: .whitespaces)
                    let text = MermaidDiagram.label(String(rest[rest.index(after: colon)...]))
                    let kind: NotePlace = place.hasPrefix("left of") ? .left : place.hasPrefix("right of") ? .right : .over
                    let names = place.replacingOccurrences(of: #"^(left of|right of|over)\s+"#, with: "", options: .regularExpression)
                        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    for n in names { participant(n) }
                    d.steps.append(.note(place: kind, participants: names, text: text))
                    continue
                }
                guard let (arrow, kind, head) = arrows.first(where: { line.contains($0.0) }), let colonRange = line.range(of: ":"),
                      let arrowRange = line.range(of: arrow), arrowRange.upperBound <= colonRange.lowerBound else { return nil }
                let from = line[..<arrowRange.lowerBound].trimmingCharacters(in: .whitespaces)
                var to = line[arrowRange.upperBound..<colonRange.lowerBound].trimmingCharacters(in: .whitespaces)
                if to.hasPrefix("+") || to.hasPrefix("-") { to = String(to.dropFirst()).trimmingCharacters(in: .whitespaces) }
                guard !from.isEmpty, !to.isEmpty else { return nil }
                participant(from)
                participant(to)
                d.steps.append(.message(from: from, to: to, text: MermaidDiagram.label(String(line[colonRange.upperBound...])), line: kind, head: head))
            }
        }
        return d.participants.isEmpty || depth != 0 ? nil : d
    }
}
