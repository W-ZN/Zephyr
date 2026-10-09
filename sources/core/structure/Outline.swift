import Foundation

/// The headings of a document, in order (design §21.2: structure comes from the source). One
/// scanner serves every reader, so they all agree: the outline beside the text and its card,
/// drawn heading numbers, agents' context and `zephyr outline`. ATX headings, and setext ones
/// when rendered; none inside fenced code or front matter. Rendered titles also lose the bold and
/// code marks, as the canvas shows them.
public enum Outline {
    public struct Heading: Equatable, Sendable {
        public var level: Int
        public var title: String
        /// Where its line starts, in UTF-16 units.
        public var location: Int

        public init(level: Int, title: String, location: Int) {
            self.level = level
            self.title = title
            self.location = location
        }
    }

    /// The whole text, line by line.
    public static func headings(in text: NSString, rendered: Bool = true) -> [Heading] {
        var scanner = Scanner(text: text, rendered: rendered)
        var pos = 0, lineStart = 0, lineEnd = 0, contentsEnd = 0
        while pos < text.length {
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: pos, length: 0))
            scanner.line(at: lineStart, length: lineEnd - lineStart)
            pos = lineEnd
        }
        return scanner.headings
    }

    /// A backtick or tilde within the line's first 16 units: the only lines a fence can be.
    static func mayFence(_ text: NSString, _ start: Int, _ length: Int) -> Bool {
        for k in 0..<min(length, 16) {
            let c = text.character(at: start + k)
            if c == 0x60 || c == 0x7E { return true }
        }
        return false
    }

    /// The line's UTF-16 units without its line break.
    static func units(_ text: NSString, _ start: Int, _ length: Int) -> ArraySlice<UInt16> {
        var end = start + length
        while end > start, text.character(at: end - 1) == 0x0A || text.character(at: end - 1) == 0x0D { end -= 1 }
        return Array(text.substring(with: NSRange(location: start, length: end - start)).utf16)[...]
    }

    /// Fed the start of every line in order, for callers that already hold the lines (the canvas's
    /// layout units), so a long document is not scanned twice.
    public struct Scanner {
        public private(set) var headings: [Heading] = []
        private let text: NSString
        private let rendered: Bool
        /// Front matter is properties: its closing `---` is no setext underline, a `# ` no heading.
        private let body: Int
        private var fence: Fence?
        private var previousLine: Int?

        public init(text: NSString, rendered: Bool = true) {
            self.text = text
            self.rendered = rendered
            body = ChunkIndex.frontMatterEnd(text) ?? 0
        }

        /// The line starting at `start`, `length` units long with or without its line break.
        public mutating func line(at start: Int, length: Int) {
            defer { previousLine = start }
            guard length > 0, start >= body else { return }
            // Fences by the canvas's rules (`Fence`): after quote and list prefixes, closed only by
            // a run at least as long. Lines without a backtick or tilde near the start skip it.
            if Outline.mayFence(text, start, length) {
                let units = Outline.units(text, start, length)
                if let open = fence {
                    if open.isClosed(by: units) { fence = nil }
                    return
                }
                if let opening = Fence(opening: units) {
                    fence = opening
                    return
                }
            }
            guard fence == nil else { return }
            let c = text.character(at: start)
            if rendered, c == 0x3D || c == 0x2D, let heading = setext(underline: start, length: length) {
                headings.append(heading)
                return
            }
            guard c == 0x23 else { return }
            let line = text.substring(with: NSRange(location: start, length: min(length, 300)))
            guard let match = line.range(of: #"^#{1,6}[ \t]+"#, options: .regularExpression) else { return }
            let level = line[match].filter { $0 == "#" }.count
            var title = String(line[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            title = title.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            headings.append(Heading(level: level, title: rendered ? Self.plain(title) : title, location: start))
        }

        /// A line of only `=` or `-` under a paragraph line makes that line a heading (not under a
        /// list item, quote, table, heading, fence or indented code). A lone `-` is a list being
        /// started, as in the analyzer.
        private func setext(underline start: Int, length: Int) -> Heading? {
            let underline = text.substring(with: NSRange(location: start, length: min(length, 200))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let mark = underline.first, underline != "-", underline.allSatisfy({ $0 == mark }), let above = previousLine, above >= body,
                  above != headings.last?.location else { return nil }
            let title = text.substring(with: NSRange(location: above, length: min(start - above, 300))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.range(of: #"^([-*+>|#]|\d+[.)])(\s|$)|^\s{4}"#, options: .regularExpression) == nil,
                  !title.hasPrefix("```"), !title.hasPrefix("~~~") else { return nil }
            return Heading(level: mark == "=" ? 1 : 2, title: Self.plain(title), location: above)
        }

        private static func plain(_ title: String) -> String {
            title.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
        }
    }
}
