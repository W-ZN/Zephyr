import Foundation

public struct Chunk: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case frontMatter, markdown }
    public var range: NSRange
    public var kind: Kind
}

/// Splits a document into independently parseable chunks: runs of lines that end at blank lines,
/// never inside a fence, a `$$` block or an HTML comment, never before an indented line (list
/// continuations and indented code keep their context), and never between items of one list. Chunks tile the whole text;
/// trailing blank lines belong to the preceding chunk. Edits re-split only until the new
/// boundaries line up with the old ones again (design §5, "局部更新").
public struct ChunkIndex: Sendable {
    public private(set) var chunks: [Chunk] = []

    public init(text: NSString) {
        chunks = Self.scan(text, from: 0) { _ in false }
    }

    public func index(containing location: Int) -> Int {
        guard !chunks.isEmpty else { return 0 }
        var lo = 0, hi = chunks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if chunks[mid].range.location <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Update after the text changed in `editedRange` (new coordinates) by `delta` characters.
    /// Returns the old chunk indices that were replaced and the new indices to re-analyze.
    @discardableResult
    public mutating func update(text: NSString, editedRange: NSRange, delta: Int) -> (replaced: Range<Int>, fresh: Range<Int>) {
        if chunks.isEmpty {
            chunks = Self.scan(text, from: 0) { _ in false }
            return (0..<0, 0..<chunks.count)
        }
        let editEndNew = NSMaxRange(editedRange)
        let editEndOld = editEndNew - delta
        // Start one character early: deleting a separating blank line merges with the previous chunk.
        let first = index(containing: max(0, editedRange.location - 1))
        let restart = chunks[first].range.location
        let old = chunks
        // Old chunk starts at or after the edit, shifted into new coordinates, are resync points.
        let tailFrom = Self.firstStart(old, atOrAfter: editEndOld)
        let fresh = Self.scan(text, from: restart) { end in
            end >= editEndNew && Self.exactStart(old, from: tailFrom, value: end - delta) != nil
        }
        let freshEnd = fresh.last.map { NSMaxRange($0.range) } ?? restart
        // A scan that ran to the end of the text consumed everything; otherwise it stopped on a resync point.
        let resume = freshEnd < text.length ? Self.exactStart(old, from: tailFrom, value: freshEnd - delta)! : old.count
        var tail = Array(old[resume...])
        if delta != 0 { for i in tail.indices { tail[i].range.location += delta } }
        chunks = Array(old[..<first]) + fresh + tail
        return (first..<resume, first..<(first + fresh.count))
    }

    private static func firstStart(_ chunks: [Chunk], atOrAfter value: Int) -> Int {
        var lo = 0, hi = chunks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if chunks[mid].range.location < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func exactStart(_ chunks: [Chunk], from: Int, value: Int) -> Int? {
        var lo = from, hi = chunks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let v = chunks[mid].range.location
            if v == value { return mid }
            if v < value { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    // MARK: - Scanning

    static func scan(_ text: NSString, from start: Int, stop: (Int) -> Bool) -> [Chunk] {
        let length = text.length
        var chunks: [Chunk] = []
        var pos = start
        if start == 0, let end = frontMatterEnd(text) {
            chunks.append(Chunk(range: NSRange(location: 0, length: end), kind: .frontMatter))
            pos = end
            if stop(end) { return chunks }
        }
        var chunkStart = pos
        var sawBlankAfterContent = false
        var hasContent = false
        var inList = false
        var fence: Fence?
        var inMath = false
        var inComment = false
        /// An aligned HTML container whose content is Markdown (`<div align="center">` … `</div>`):
        /// one chunk, so the analyzer can draw it as one block. Left open after `containerLimit` lines.
        var container: (name: String, lines: Int)?
        var buffer = [UInt16](repeating: 0, count: 256)

        while pos < length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: pos, length: 0))
            let len = min(contentsEnd - lineStart, buffer.count)
            buffer.withUnsafeMutableBufferPointer { p in
                text.getCharacters(p.baseAddress!, range: NSRange(location: lineStart, length: len))
            }
            let head = buffer[0..<len]
            let blank = head.allSatisfy { $0 == 0x20 || $0 == 0x09 } && len == contentsEnd - lineStart

            if let f = fence {
                if f.isClosed(by: head) { fence = nil }
            } else if inMath {
                if contains(text, lineStart, contentsEnd, "$$") { inMath = false }
            } else if inComment {
                if contains(text, lineStart, contentsEnd, "-->") { inComment = false }
            } else if let open = container {
                let line = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
                if HTMLContainer.closes(line, open.name) || open.lines >= containerLimit {
                    container = nil
                } else {
                    container?.lines += 1
                }
            } else if blank {
                if hasContent { sawBlankAfterContent = true }
            } else {
                let indented = head.first == 0x20 || head.first == 0x09
                let item = startsListItem(head)
                if sawBlankAfterContent && !indented && !(item && inList) {
                    chunks.append(Chunk(range: NSRange(location: chunkStart, length: lineStart - chunkStart), kind: .markdown))
                    if stop(lineStart) { return chunks }
                    chunkStart = lineStart
                }
                sawBlankAfterContent = false
                hasContent = true
                if item { inList = true } else if !indented { inList = false }
                if let f = Fence(opening: head) {
                    fence = f
                } else if let open = Fence.opensMathBlock(head) {
                    inMath = !contains(text, lineStart + open + 2, contentsEnd, "$$")
                } else if contains(text, lineStart, contentsEnd, "<!--") && !contains(text, lineStart, contentsEnd, "-->") {
                    inComment = true
                } else if head.drop(while: { $0 == 0x20 }).first == 0x3C, let open = HTMLContainer.opening(text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))) {
                    container = (open.name, 0)
                }
            }
            pos = lineEnd
        }
        if chunkStart < length || chunks.isEmpty {
            chunks.append(Chunk(range: NSRange(location: chunkStart, length: length - chunkStart), kind: .markdown))
        }
        return chunks
    }

    static let containerLimit = 200

    /// `- `, `* `, `+ `, `1. ` or `1) ` after at most three spaces.
    static func startsListItem(_ line: ArraySlice<UInt16>) -> Bool {
        var i = line.startIndex
        var spaces = 0
        while i < line.endIndex, line[i] == 0x20, spaces < 3 { i += 1; spaces += 1 }
        guard i < line.endIndex else { return false }
        func followedBySpace(_ j: Int) -> Bool { j == line.endIndex || line[j] == 0x20 || line[j] == 0x09 }
        if line[i] == 0x2D || line[i] == 0x2A || line[i] == 0x2B { return followedBySpace(i + 1) }
        var digits = 0
        while i < line.endIndex, (0x30...0x39).contains(line[i]), digits < 9 { i += 1; digits += 1 }
        guard digits > 0, i < line.endIndex, line[i] == 0x2E || line[i] == 0x29 else { return false }
        return followedBySpace(i + 1)
    }

    /// YAML front matter: `---` alone on the first line, closed by `---` or `...`.
    public static func frontMatterEnd(_ text: NSString) -> Int? {
        guard text.hasPrefix("---") else { return nil }
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: 0, length: 0))
        guard isOnly(text, lineStart, contentsEnd, "---") else { return nil }
        var pos = lineEnd
        while pos < text.length {
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: pos, length: 0))
            if isOnly(text, lineStart, contentsEnd, "---") || isOnly(text, lineStart, contentsEnd, "...") { return lineEnd }
            pos = lineEnd
        }
        return nil
    }

    private static func isOnly(_ text: NSString, _ start: Int, _ end: Int, _ token: String) -> Bool {
        guard end - start >= 3, text.character(at: start) == token.utf16.first! else { return false }
        return text.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces) == token
    }

    private static func contains(_ text: NSString, _ start: Int, _ end: Int, _ needle: String) -> Bool {
        guard end > start else { return false }
        return text.range(of: needle, options: .literal, range: NSRange(location: start, length: end - start)).location != NSNotFound
    }
}
