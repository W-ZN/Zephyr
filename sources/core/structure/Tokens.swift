import Foundation

// All ranges in a `ChunkAnalysis` are UTF-16 offsets relative to the start of the chunk, so
// analyses of untouched chunks stay valid when earlier text changes.

/// How a source line is presented. One entry per line of a chunk (TextKit paragraphs are source lines).
public struct LineInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case blank
        case paragraph
        case heading(level: Int)
        /// Setext underline (`===` / `---` under a heading): hidden and collapsed while reading.
        case setextUnderline
        case codeFence(language: String?)
        case code
        case html
        /// Lines that belong to a block component (table, display math, rule, front matter).
        case component
    }

    public var range: NSRange          // whole line including terminator
    public var kind: Kind
    public var quoteDepth: Int
    public var listDepth: Int
    /// First line of a list item (carries the bullet / number).
    public var isListItemStart: Bool
    /// Width in characters of the list marker incl. trailing spaces, for hanging indents.
    public var listMarkerWidth: Int
    /// First line of a Markdown block (paragraph, heading, list item, code block, component…).
    /// Later lines of the same block are soft continuations and get no block spacing.
    public var startsBlock: Bool = false
    /// First item of a list: a new list gets block spacing, later items stay tight.
    public var startsList: Bool = false
}

/// A syntax marker presentation decided by the structure layer, applied by the render layer.
public struct Marker: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        /// Null glyphs while the caret is outside `revealRange`.
        case hide
        /// Container prefixes (quote `>`, list indentation): always hidden, replaced by indents.
        case structural
        /// List bullet shown as a typographic bullet glyph.
        case bullet(depth: Int)
        /// Ordered list number kept as-is but styled as a marker.
        case ordinal
        /// `[ ]` / `[x]` drawn as a checkbox.
        case checkbox(checked: Bool)
    }

    public var range: NSRange
    public var style: Style
    /// Caret positions (inclusive bounds) that reveal the raw syntax.
    public var revealRange: NSRange
}

public enum InlineStyle: Sendable, Equatable {
    case strong, emphasis, strikethrough, code, html
    case link(destination: String?)
    /// Paired inline HTML tags (design §9): `<kbd>`, `<sup>`, `<sub>`, `<u>`/`<ins>`, `<mark>`,
    /// `<small>`. `<b>`, `<i>`, `<s>`, `<code>` use the Markdown styles above.
    case keycap, superscript, `subscript`, underline, highlight, small
}

public struct InlineToken: Sendable, Equatable {
    public var style: InlineStyle
    public var range: NSRange
}

public struct TableModel: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable { case left, center, right }
    public var header: [String]
    public var rows: [[String]]
    public var alignments: [Alignment]
}

public struct FrontMatterModel: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var key: String
        public var value: String
        /// Exact source range of the value, for minimal edits of top-level single-line scalars.
        public var valueRange: NSRange
    }
    public var entries: [Entry]
}

public enum ImageAlignment: String, Sendable, Equatable {
    case left, center
}

public enum ComponentKind: Sendable, Equatable {
    case displayMath(tex: String)
    case inlineMath(tex: String, display: Bool)
    case table(TableModel)
    /// A Markdown image has no requested width. A strict standalone HTML `<img>` may carry a
    /// positive point width; the renderer clamps it to its available column.
    /// `alignment` is an explicit HTML `align` attribute. Nil follows the active theme.
    case image(source: String, alt: String, width: CGFloat? = nil, alignment: ImageAlignment? = nil)
    case thematicBreak
    case frontMatter(FrontMatterModel)
    /// A ```mermaid block Zephyr can draw; its lines stay code while the caret is inside.
    case diagram(MermaidDiagram)
    /// An HTML block in the safe subset (design §9), drawn by Zephyr's own HTML layout.
    case html(HTMLFragment)
    /// An image inside a line of text: `![alt](src)` among other text or in a link, or an inline
    /// `<img>`. `width` and `height` are an HTML image's requested point sizes.
    case inlineImage(source: String, alt: String, width: CGFloat? = nil, height: CGFloat? = nil)

    /// Block components occupy whole lines; inline ones sit inside a paragraph line.
    public var isBlock: Bool {
        switch self {
        case .inlineMath, .inlineImage: false
        default: true
        }
    }
}

public struct ComponentToken: Sendable, Equatable {
    public var kind: ComponentKind
    /// Source range rendered as the component while the caret is outside it.
    public var range: NSRange
}

/// A fenced or indented code block, drawn on a shared background.
public struct CodeBlockToken: Sendable, Equatable {
    public var range: NSRange
    public var language: String?
    public var isFenced: Bool
}

/// Everything the render layer needs to present one chunk.
public struct ChunkAnalysis: Sendable {
    public var length: Int
    public var lines: [LineInfo]
    public var markers: [Marker]
    public var inlines: [InlineToken]
    public var components: [ComponentToken]
    public var codeBlocks: [CodeBlockToken]
    /// Shown as plain source: the chunk has a line longer than `MarkdownAnalyzer.maximumLineLength`.
    public var isPlain = false
}
