import Foundation

/// In-memory structure of one document: the chunk index plus lazily computed analyses
/// (design §5: the structure layer lives only in memory and never touches disk).
public final class DocumentStructure {
    public private(set) var index: ChunkIndex
    private var analyses: [ChunkAnalysis?]
    private var definitions: [(label: String, line: String)]

    public init(text: NSString) {
        index = ChunkIndex(text: text)
        analyses = Array(repeating: nil, count: index.chunks.count)
        definitions = MarkdownAnalyzer.referenceDefinitions(in: text)
    }

    public var chunks: [Chunk] { index.chunks }

    public func analysis(_ i: Int, text: NSString) -> ChunkAnalysis {
        if let a = analyses[i] { return a }
        let chunk = index.chunks[i]
        let source = text.substring(with: chunk.range)
        let a = chunk.kind == .frontMatter
            ? FrontMatterParser.analyze(source)
            : MarkdownAnalyzer.analyze(source, references: MarkdownAnalyzer.references(for: source, from: definitions))
        analyses[i] = a
        return a
    }

    /// Drop one chunk's analysis; it is made again when needed (the block canvas keeps only the
    /// chunks near what it shows).
    public func discardAnalysis(_ i: Int) {
        analyses[i] = nil
    }

    /// Apply a text edit. Returns the indices of chunks whose analysis was discarded.
    @discardableResult
    public func edit(text: NSString, editedRange: NSRange, delta: Int) -> Range<Int> {
        let (replaced, fresh) = index.update(text: text, editedRange: editedRange, delta: delta)
        analyses.replaceSubrange(replaced, with: repeatElement(nil, count: fresh.count))
        // A definition may have been written, changed or removed (a deletion, or a replacement of
        // more than a keystroke where definitions exist).
        let lineRange = text.lineRange(for: NSRange(location: min(editedRange.location, text.length), length: 0))
        if text.range(of: "]:", options: .literal, range: lineRange).location != NSNotFound || !definitions.isEmpty && (delta < 0 || editedRange.length > 1) {
            let old = definitions
            definitions = MarkdownAnalyzer.referenceDefinitions(in: text)
            // Links anywhere resolve against them: every chunk is analyzed again.
            if !old.elementsEqual(definitions, by: { $0.label == $1.label && $0.line == $1.line }) {
                analyses = Array(repeating: nil, count: index.chunks.count)
                return 0..<index.chunks.count
            }
        }
        return fresh
    }
}
