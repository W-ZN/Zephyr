import AppKit
import ImageIO
import ZephyrCore

/// What a component needs from its document: typography, where relative paths resolve, and a way to
/// ask for layout or pixel updates when something loads asynchronously.
public protocol RenderContext: AnyObject {
    var typography: Typography { get }
    /// Directory of the document, for relative image paths. `nil` for unsaved documents.
    var baseURL: URL? { get }
    /// Front matter shows as a one-line summary (a global preference, design §8.1).
    var frontMatterCollapsed: Bool { get }
    /// Remote images load only while this is on (a preference, or allowed for one document; design
    /// §9). Badges Zephyr draws itself and local images never need it.
    var loadsRemoteImages: Bool { get }
    func componentNeedsLayout(_ box: ComponentBox)
    func componentNeedsDisplay(_ box: ComponentBox)
    /// Part of a component changed its pixels (one image of an HTML block).
    func componentNeedsDisplay(_ box: ComponentBox, in rect: NSRect)
}

/// Horizontal room for a block component (design §8.1): the reading column, which every component
/// keeps to (one wider scrolls sideways inside it, fading where it continues), and the wider band
/// up to the window's margins that only a table explicitly set to the window's width uses.
struct BlockSpace: Equatable {
    var column: CGFloat
    var wide: CGFloat
}

/// Where a block component draws, in view coordinates; both rects start at the component's top.
struct BlockFrame {
    var column: NSRect
    var wide: NSRect

    var space: BlockSpace { BlockSpace(column: column.width, wide: wide.width) }

    /// Left edge for content `width` wide: aligned in the column when it fits; otherwise centered
    /// in the wide band, or kept as close to the column's left edge as the band allows.
    func originX(width: CGFloat, alignment: Typography.BlockAlignment) -> CGFloat {
        if width <= column.width + 0.5 {
            return alignment == .center ? (column.midX - width / 2).rounded() : column.minX
        }
        if alignment == .left { return max(wide.minX, min(column.minX, wide.maxX - width)) }
        return max(wide.minX, (wide.midX - width / 2).rounded())
    }
}

/// A rendered stand-in for a source range (design §9 component contract: measure, draw,
/// hit-test via the source range, accessibility label).
public class ComponentBox: NSObject {
    let kind: ComponentKind
    weak var context: RenderContext?
    /// Last range the box was found at, so async loads can find it again cheaply.
    var lastKnownRange = NSRange(location: NSNotFound, length: 0)

    init(kind: ComponentKind, context: RenderContext) {
        self.kind = kind
        self.context = context
    }

    var isBlock: Bool { kind.isBlock }
    /// Where the block was last drawn (view coordinates), for hit testing and menus.
    var drawnRect = NSRect.zero

    /// Block components: content height; the block gap around it comes from the layout manager.
    func height(in space: BlockSpace) -> CGFloat { 0 }
    func draw(in frame: BlockFrame, context ctx: CGContext) {}
    /// Components that can be inspected outside the document provide their natural drawing size
    /// and draw into a local, unscaled graphics context.
    func viewerNaturalSize() -> CGSize? { nil }
    func drawViewer(in ctx: CGContext) {}
    /// A viewer asks image-backed components to reload a bounded cache entry without blocking its
    /// drawing pass. Vector components have nothing to load.
    func viewerNeedsLoad() -> Bool { false }
    func requestViewerLoad(_ completion: @escaping (Bool) -> Void) -> UUID? { nil }
    func cancelViewerLoad(_ request: UUID) {}
    /// Output is a one-shot, synchronous operation. Components that ordinarily finish work after a
    /// screen draw can make their local pixels ready before a print or image export starts.
    func prepareForOutput() {}

    /// A block wider than the band stays in the band and scrolls sideways inside it (a two-finger
    /// swipe, or Shift with a mouse wheel): how far it can, 0 when it fits, and how far it has.
    var scrollWidth: CGFloat = 0 { didSet { scrollX = min(max(scrollX, 0), scrollWidth) } }
    var scrollX: CGFloat = 0

    /// The sides of `rect` that hide content fade into the canvas.
    func drawScrollFades(_ rect: NSRect) {
        guard scrollWidth > 0 else { return }
        let fade = min(36, rect.width / 6)
        let clear = Tokens.canvas.withAlphaComponent(0)
        if scrollX > 0.5 {
            NSGradient(starting: Tokens.canvas, ending: clear)?.draw(in: NSRect(x: rect.minX, y: rect.minY, width: fade, height: rect.height), angle: 0)
        }
        if scrollX < scrollWidth - 0.5 {
            NSGradient(starting: clear, ending: Tokens.canvas)?.draw(in: NSRect(x: rect.maxX - fade, y: rect.minY, width: fade, height: rect.height), angle: 0)
        }
    }

    static func make(_ kind: ComponentKind, fontSize: CGFloat, context: RenderContext) -> ComponentBox {
        switch kind {
        case let .displayMath(tex): MathBlockBox(tex: tex, kind: kind, context: context)
        case let .inlineMath(tex, display): InlineMathBox(tex: tex, display: display, fontSize: fontSize, kind: kind, context: context)
        case let .table(model): TableBox(model: model, kind: kind, context: context)
        case let .image(source, alt, width, alignment): ImageBox(source: source, alt: alt, requestedWidth: width, alignment: alignment, kind: kind, context: context)
        case .thematicBreak: RuleBox(kind: kind, context: context)
        case let .frontMatter(model): FrontMatterBox(model: model, kind: kind, context: context)
        case let .diagram(diagram): DiagramBox(diagram: diagram, kind: kind, context: context)
        case let .html(fragment): HTMLBox(fragment: fragment, kind: kind, context: context)
        case let .inlineImage(source, alt, width, height): InlineImageBox(source: source, alt: alt, width: width, height: height, fontSize: fontSize, kind: kind, context: context)
        }
    }
}

/// A component inside a line of text: Core Text leaves room for it (a run delegate on one
/// placeholder character) and the canvas draws it there.
protocol InlineComponent: ComponentBox {
    var advance: CGFloat { get }
    var metrics: (width: CGFloat, ascent: CGFloat, descent: CGFloat) { get }
    /// `baseline` is the y of the text baseline in the flipped view; `width` is the room the line
    /// gave the object, less than its advance when it was scaled down to fit the column.
    func draw(atX x: CGFloat, baseline: CGFloat, width: CGFloat, color: NSColor, context ctx: CGContext)
}

// MARK: - Math

final class InlineMathBox: ComponentBox, InlineComponent {
    let tex: String
    let display: Bool
    let fontSize: CGFloat
    private(set) var metrics: (width: CGFloat, ascent: CGFloat, descent: CGFloat) = (0, 0, 0)
    private(set) var error: String?

    init(tex: String, display: Bool, fontSize: CGFloat, kind: ComponentKind, context: RenderContext) {
        self.tex = tex
        self.display = display
        self.fontSize = fontSize
        super.init(kind: kind, context: context)
        let formula = MathRenderer.shared.formula(tex, display: display)
        error = formula.error
        if formula.error == nil {
            metrics = formula.size(fontSize: mathSize)
        } else {
            let w = (tex as NSString).size(withAttributes: [.font: errorFont]).width
            metrics = (w + 6, fontSize * 0.8, fontSize * 0.25)
        }
    }

    /// KaTeX glyphs read slightly small next to SF Pro; match x-heights.
    var mathSize: CGFloat { fontSize * 1.08 * (context?.typography.mathScale ?? 1) }
    var errorFont: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize * 0.85, weight: .regular) }
    let padding: CGFloat = 1.5

    var advance: CGFloat { metrics.width + padding * 2 }

    func draw(atX x: CGFloat, baseline: CGFloat, width: CGFloat, color: NSColor, context ctx: CGContext) {
        if let error {
            let attrs: [NSAttributedString.Key: Any] = [.font: errorFont, .foregroundColor: NSColor.systemRed]
            (tex as NSString).draw(at: CGPoint(x: x + 3, y: baseline - errorFont.ascender), withAttributes: attrs)
            _ = error
            return
        }
        let formula = MathRenderer.shared.formula(tex, display: display)
        MathRenderer.shared.draw(formula, at: CGPoint(x: x + padding, y: baseline - metrics.ascent), fontSize: mathSize, color: color, in: ctx)
    }
}

final class MathBlockBox: ComponentBox {
    let tex: String
    init(tex: String, kind: ComponentKind, context: RenderContext) {
        self.tex = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        super.init(kind: kind, context: context)
    }

    private var fontSize: CGFloat { (context?.typography.fontSize ?? 16) * 1.2 * (context?.typography.mathScale ?? 1) }

    override func height(in space: BlockSpace) -> CGFloat {
        let formula = MathRenderer.shared.formula(tex, display: true)
        if formula.error != nil { return errorText.boundingRect(with: CGSize(width: space.column, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height + 8 }
        let size = formula.size(fontSize: fontSize)
        return (size.ascent + size.descent) * scale(size.width, space.column)
    }

    /// A formula wider than the column shrinks to 80 % at most; past that it scrolls.
    private func scale(_ natural: CGFloat, _ width: CGFloat) -> CGFloat { natural > width ? max(width / natural, 0.8) : 1 }

    private var errorText: NSAttributedString {
        NSAttributedString(string: tex, attributes: [.font: NSFont.monospacedSystemFont(ofSize: (context?.typography.fontSize ?? 16) * 0.85, weight: .regular), .foregroundColor: NSColor.systemRed])
    }

    override func draw(in frame: BlockFrame, context ctx: CGContext) {
        let formula = MathRenderer.shared.formula(tex, display: true)
        if formula.error != nil {
            let rect = NSRect(x: frame.column.minX, y: frame.column.minY, width: frame.column.width, height: height(in: frame.space))
            errorText.draw(with: rect.insetBy(dx: 0, dy: 4), options: [.usesLineFragmentOrigin])
            drawnRect = rect
            return
        }
        let size = formula.size(fontSize: fontSize)
        let s = scale(size.width, frame.column.width)
        let width = size.width * s, visible = min(width, frame.column.width)
        scrollWidth = width - visible
        let x = frame.originX(width: visible, alignment: .center)
        drawnRect = NSRect(x: x, y: frame.column.minY, width: visible, height: (size.ascent + size.descent) * s)
        ctx.saveGState()
        ctx.clip(to: drawnRect.insetBy(dx: 0, dy: -4))
        ctx.translateBy(x: x - scrollX, y: frame.column.minY)
        ctx.scaleBy(x: s, y: s)
        MathRenderer.shared.draw(formula, at: .zero, fontSize: fontSize, color: Palette.text, in: ctx)
        ctx.restoreGState()
        drawScrollFades(drawnRect.insetBy(dx: 0, dy: -4))
    }
}

// MARK: - Thematic break

final class RuleBox: ComponentBox {
    override func height(in space: BlockSpace) -> CGFloat { round((context?.typography.fontSize ?? 16) * 0.5) }
    override func draw(in frame: BlockFrame, context ctx: CGContext) {
        Palette.rule.setFill()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let mid = frame.column.minY + height(in: frame.space) / 2
        drawnRect = NSRect(x: frame.column.minX, y: mid - 1, width: frame.column.width, height: 2)
        // Text views draw backgrounds with copy compositing: blend, or a translucent line turns solid.
        NSRect(x: frame.column.minX, y: (mid * scale).rounded() / scale, width: frame.column.width, height: 1 / scale).fill(using: .sourceOver)
    }
}

// MARK: - Table

final class TableBox: ComponentBox {
    let model: TableModel
    /// Choices from the table's context menu. They last while the document is open (design §8.1).
    var widthOverride: Typography.TableWidth?
    var alignmentOverride: Typography.BlockAlignment?

    private struct Layout {
        var key: String
        var columns: [CGFloat]
        var rows: [CGFloat]
        var cells: [[NSAttributedString]]
    }
    private var layout: Layout?
    private var remoteRequests: Set<URL> = []
    /// Cell padding from the theme (table.padding), a little less above and below than beside.
    var padX: CGFloat { context?.typography.tablePadding ?? 12 }
    var padY: CGFloat { round(padX * 0.55) }
    /// The cell being typed in and its text so far: the table lays it out as it grows, and the
    /// field over it draws the text.
    var editing: (row: Int, column: Int, text: String)? { didSet { layout = nil } }

    init(model: TableModel, kind: ComponentKind, context: RenderContext) {
        self.model = model
        super.init(kind: kind, context: context)
    }

    var widthMode: Typography.TableWidth { widthOverride ?? context?.typography.tableWidth ?? .fit }
    var alignment: Typography.BlockAlignment { alignmentOverride ?? context?.typography.tableAlignment ?? .center }

    var columnCount: Int { max(model.header.count, model.alignments.count) }

    /// A remote image in a cell loads like any other (when the document allows it); the table
    /// lays out again once it has.
    private func loadRemote(_ url: URL) {
        guard context?.loadsRemoteImages == true, !remoteRequests.contains(url) else { return }
        remoteRequests.insert(url)
        _ = MainActor.assumeIsolated {
            RemoteImages.shared.load(url) { [weak self] ok in
                guard let self else { return }
                self.remoteRequests.remove(url)
                guard ok else { return }
                self.layout = nil
                self.context?.componentNeedsLayout(self)
            }
        }
    }

    /// Column widths like a browser's: each column between its longest word and its whole text
    /// on one line, the room in between shared by how much each wants. Fit takes the natural width
    /// up to the reading column; column and window widths stretch to the column or the band.
    /// Words never break: a table whose words do not fit scrolls sideways in its room (the column,
    /// unless set to the window's width), and since it scrolls anyway, each column takes its whole
    /// text up to 16 em, so rows stay short.
    private func makeLayout(_ space: BlockSpace) -> Layout {
        let dark = NSAppearance.currentDrawing().isDark
        guard let typography = context?.typography else { return Layout(key: "", columns: [], rows: [], cells: []) }
        let key = "\(space.column)|\(space.wide)|\(widthMode)|\(dark)|\(typography.tableFont.fontName)|\(typography.tableFont.pointSize)|\(padX)|\(typography.tableHeaderBold)|\(context?.loadsRemoteImages == true)"
        if let l = layout, l.key == key { return l }
        let n = columnCount
        var cells: [[NSAttributedString]] = []
        for (r, row) in ([model.header] + model.rows).enumerated() {
            let font = cellFont(row: r) ?? typography.tableFont
            cells.append((0..<n).map { c in
                if let editing, editing.row == r, editing.column == c { return NSAttributedString(string: editing.text, attributes: [.font: font]) }
                let text = c < row.count ? row[c] : ""
                let alignment = c < model.alignments.count ? model.alignments[c] : .left
                return InlineRenderer.attributedString(text, font: font, typography: typography, alignment: alignment, baseURL: context?.baseURL) { [weak self] in self?.loadRemote($0) }
            })
        }
        var most = [CGFloat](repeating: 40, count: n), least = [CGFloat](repeating: 40, count: n)
        for row in cells {
            for (c, cell) in row.enumerated() {
                most[c] = max(most[c], ceil(cell.size().width) + padX * 2)
                least[c] = max(least[c], ceil(Self.longestWord(cell, cap: typography.fontSize * 14)) + padX * 2)
            }
        }
        let total = most.reduce(0, +), floor = least.reduce(0, +)
        let target: CGFloat = switch widthMode {
        case .fit: min(total, space.column)
        case .column: space.column
        case .window: space.wide
        }
        var columns = most
        if floor >= target {
            columns = (0..<n).map { min(most[$0], max(least[$0], typography.fontSize * 16)) }
        } else if total > target {
            let share = (target - floor) / (total - floor)
            columns = (0..<n).map { (least[$0] + (most[$0] - least[$0]) * share).rounded(.down) }
        } else if total < target, total > 0 {
            columns = most.map { ($0 * target / total).rounded(.down) }
        }
        let rows = cells.map { row in
            row.enumerated().map { c, cell in
                ceil(cell.boundingRect(with: CGSize(width: columns[c] - padX * 2, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + padY * 2
            }.max() ?? 0
        }
        let result = Layout(key: key, columns: columns, rows: rows, cells: cells)
        layout = result
        return result
    }

    /// The widest run the text cannot break inside: a word, or (in Chinese and Japanese) one
    /// character. Up to `cap`, so a long link may still break.
    static func longestWord(_ text: NSAttributedString, cap: CGFloat) -> CGFloat {
        let ns = text.string as NSString
        var longest: CGFloat = 0, start = 0, i = 0
        func measure(_ end: Int) {
            if end > start { longest = max(longest, text.attributedSubstring(from: NSRange(location: start, length: end - start)).size().width) }
        }
        while i < ns.length, longest < cap {
            let range = ns.rangeOfComposedCharacterSequence(at: i)
            let scalar = ns.substring(with: range).unicodeScalars.first?.value ?? 0
            if scalar == 0x20 || scalar == 0x09 || scalar == 0x0A {
                measure(i)
                start = NSMaxRange(range)
            } else if TextStatistics.isHan(scalar) || (0x3040...0x30FF).contains(scalar) || (0xAC00...0xD7AF).contains(scalar) {
                measure(i)
                start = i
                measure(NSMaxRange(range))
                start = NSMaxRange(range)
            }
            i = NSMaxRange(range)
        }
        measure(ns.length)
        return min(longest, cap)
    }

    override func height(in space: BlockSpace) -> CGFloat {
        makeLayout(space).rows.reduce(0, +)
    }

    /// Where the table's content starts: the visible box less how far it has scrolled.
    private var contentX: CGFloat { drawnRect.minX - scrollX }

    /// The theme's table style (design §8.1): lines between rows, a grid or none; a shaded, bold or
    /// plain header; optional stripes; only the grid has an outer outline (the lines between rows
    /// end with one under the last row). Text views
    /// draw backgrounds with copy compositing, so every fill here blends explicitly.
    override func draw(in blockFrame: BlockFrame, context ctx: CGContext) {
        guard let typography = context?.typography else { return }
        let l = makeLayout(blockFrame.space)
        let room = widthMode == .window ? blockFrame.wide.width : blockFrame.column.width
        let tableWidth = l.columns.reduce(0, +), visible = min(tableWidth, room)
        scrollWidth = tableWidth - visible
        let box = NSRect(x: blockFrame.originX(width: visible, alignment: alignment), y: blockFrame.column.minY, width: visible, height: l.rows.reduce(0, +))
        drawnRect = box
        let frame = NSRect(x: box.minX - scrollX, y: box.minY, width: tableWidth, height: box.height)
        let hair = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        let lines = typography.tableLines
        let radius = min(typography.tableRadius, box.height / 2)
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: hair / 2, dy: hair / 2), xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        var y = frame.minY
        for (r, h) in l.rows.enumerated() {
            let band = NSRect(x: frame.minX, y: y, width: frame.width, height: h)
            if r == 0, typography.tableHeaderShade {
                Palette.tableHeader.setFill()
                band.fill(using: .sourceOver)
            } else if r > 0, r % 2 == 0, typography.tableStripes {
                Palette.tableStripe.setFill()
                band.fill(using: .sourceOver)
            }
            y += h
        }
        if let editing, let cell = cellRect(row: editing.row, column: editing.column) {
            // The cell being typed in: a quiet wash of the accent, no box around it.
            Palette.color(.accent).withAlphaComponent(0.08).setFill()
            cell.fill(using: .sourceOver)
        }
        // Under the last row too: the table's extent shows, an empty new row included.
        y = frame.minY
        for (r, h) in l.rows.enumerated() {
            y += h
            // The grid's outline is its last line.
            if r == l.rows.count - 1, lines == .grid { break }
            if r == 0, lines != .none {
                // The header's rule is a full point: the header reads as one band (darker without its shade).
                (typography.tableHeaderShade ? Palette.rule : Palette.faint).setFill()
                NSRect(x: frame.minX, y: y - 1, width: frame.width, height: 1).fill(using: .sourceOver)
            } else if lines != .none {
                // The last one clears the clip's half-hair inset, so it shows whole.
                Palette.rule.setFill()
                NSRect(x: frame.minX, y: y - hair - (r == l.rows.count - 1 ? hair / 2 : 0), width: frame.width, height: hair).fill(using: .sourceOver)
            }
        }
        if lines == .grid {
            Palette.rule.setFill()
            var x = frame.minX
            for w in l.columns.dropLast() {
                x += w
                NSRect(x: x - hair, y: frame.minY, width: hair, height: frame.height).fill(using: .sourceOver)
            }
        }
        y = frame.minY
        for (r, h) in l.rows.enumerated() {
            var x = frame.minX
            for (c, w) in l.columns.enumerated() {
                if editing?.row != r || editing?.column != c {
                    l.cells[r][c].draw(with: NSRect(x: x + padX, y: y + padY, width: w - padX * 2, height: h - padY * 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
                }
                x += w
            }
            y += h
        }
        drawScrollFades(box)
        NSGraphicsContext.restoreGraphicsState()
        if lines == .grid {
            Palette.rule.setStroke()
            outline.lineWidth = hair
            outline.stroke()
        }
    }

    var rowCount: Int { 1 + model.rows.count }

    /// The cell under `point`, from the last drawn frame (view coordinates). Row 0 is the header.
    func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        guard let l = layout, drawnRect.contains(point) else { return nil }
        var y = drawnRect.minY, row = l.rows.count - 1
        for (r, h) in l.rows.enumerated() {
            if point.y < y + h { row = r; break }
            y += h
        }
        var x = contentX, column = l.columns.count - 1
        for (c, w) in l.columns.enumerated() {
            if point.x < x + w { column = c; break }
            x += w
        }
        return (row, column)
    }

    func cellRect(row: Int, column: Int) -> NSRect? {
        guard let l = layout, l.rows.indices.contains(row), l.columns.indices.contains(column) else { return nil }
        return NSRect(x: contentX + l.columns[..<column].reduce(0, +), y: drawnRect.minY + l.rows[..<row].reduce(0, +), width: l.columns[column], height: l.rows[row])
    }

    /// Scrolls sideways so the cell is in view (one being typed in, or reached with Tab).
    func scrollToCell(row: Int, column: Int) {
        guard scrollWidth > 0, let rect = cellRect(row: row, column: column) else { return }
        if rect.minX < drawnRect.minX { scrollX -= drawnRect.minX - rect.minX } else if rect.maxX > drawnRect.maxX { scrollX += min(rect.maxX - drawnRect.maxX, rect.minX - drawnRect.minX) }
        scrollX = min(max(scrollX, 0), scrollWidth)
    }

    func cellFont(row: Int) -> NSFont? {
        guard let typography = context?.typography else { return nil }
        guard row == 0, typography.tableHeaderBold else { return typography.tableFont }
        return typography.withTraits(typography.tableFont, bold: true, italic: false)
    }

    func alignment(ofColumn column: Int) -> NSTextAlignment {
        guard column < model.alignments.count else { return .left }
        switch model.alignments[column] {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

// MARK: - Front matter

final class FrontMatterBox: ComponentBox {
    let model: FrontMatterModel
    private let rowGap: CGFloat = 3
    /// Disclosure chevron in the left gutter (view coordinates), set when drawn.
    private(set) var toggleRect = NSRect.zero
    /// Where each entry's value was drawn (view coordinates), for in-place editing; empty when collapsed.
    private(set) var valueRects: [NSRect] = []
    /// The editable value under the pointer, drawn with a hover background.
    var hoveredEntry: Int?

    init(model: FrontMatterModel, kind: ComponentKind, context: RenderContext) {
        self.model = model
        super.init(kind: kind, context: context)
    }

    private var fontSize: CGFloat { context?.typography.fontSize ?? 16 }
    private var keyFont: NSFont { NSFont.systemFont(ofSize: round(fontSize * 0.8125), weight: .medium) }
    var valueFont: NSFont { NSFont.systemFont(ofSize: round(fontSize * 0.875)) }
    private var collapsed: Bool { context?.frontMatterCollapsed ?? false }
    private var rowHeight: CGFloat { ceil(valueFont.ascender - valueFont.descender + valueFont.leading) }

    private func keyColumn() -> CGFloat {
        let widest = model.entries.map { ($0.key as NSString).size(withAttributes: [.font: keyFont]).width }.max() ?? 0
        return min(ceil(widest) + 16, 160)
    }

    private func value(_ e: FrontMatterModel.Entry) -> NSAttributedString {
        NSAttributedString(string: e.value.isEmpty ? "—" : e.value, attributes: [.font: valueFont, .foregroundColor: e.value.isEmpty ? Palette.faint : Palette.muted])
    }

    private func valueHeight(_ e: FrontMatterModel.Entry, width: CGFloat) -> CGFloat {
        max(ceil(value(e).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height), rowHeight)
    }

    private var summary: NSAttributedString {
        let text = model.entries.isEmpty ? String(localized: "Properties")
            : model.entries.map { $0.value.isEmpty ? $0.key : "\($0.key): \($0.value)" }.joined(separator: "  ·  ")
        return NSAttributedString(string: text, attributes: [.font: valueFont, .foregroundColor: Palette.muted])
    }

    override func height(in space: BlockSpace) -> CGFloat {
        guard !collapsed, !model.entries.isEmpty else { return rowHeight }
        let valueWidth = space.column - keyColumn()
        let rows = model.entries.map { valueHeight($0, width: valueWidth) }
        return rows.reduce(0, +) + rowGap * CGFloat(rows.count - 1)
    }

    override func draw(in frame: BlockFrame, context ctx: CGContext) {
        let x = frame.column.minX
        let height = height(in: frame.space)
        drawnRect = NSRect(x: x, y: frame.column.minY, width: frame.column.width, height: height)
        let chevronSize = round(fontSize * 0.625)
        toggleRect = NSRect(x: x - chevronSize - 12, y: frame.column.minY, width: chevronSize + 10, height: rowHeight)
        valueRects = []
        let symbol = collapsed ? "chevron.right" : "chevron.down"
        // The disclosure is a control: it stays off paper.
        if NSGraphicsContext.current?.isDrawingToScreen != false, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: collapsed ? String(localized: "Expand properties") : String(localized: "Collapse properties"))?
            .withSymbolConfiguration(.init(pointSize: chevronSize, weight: .semibold)) {
            let tinted = image.tinted(Palette.faint)
            tinted.draw(in: NSRect(x: toggleRect.midX - tinted.size.width / 2, y: toggleRect.midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height))
        }
        if collapsed || model.entries.isEmpty {
            summary.draw(with: NSRect(x: x, y: frame.column.minY, width: frame.column.width, height: rowHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        }
        let keyWidth = keyColumn()
        let valueWidth = frame.column.width - keyWidth
        var y = frame.column.minY
        for (i, e) in model.entries.enumerated() {
            let h = valueHeight(e, width: valueWidth)
            let valueRect = NSRect(x: x + keyWidth, y: y, width: valueWidth, height: h)
            valueRects.append(valueRect)
            if hoveredEntry == i {
                Palette.codeBackground.setFill()
                NSBezierPath(roundedRect: valueRect.insetBy(dx: -6, dy: -1), xRadius: 4, yRadius: 4).fill()
            }
            // Align key and value baselines.
            let keyY = y + (valueFont.ascender - keyFont.ascender)
            (e.key as NSString).draw(with: NSRect(x: x, y: keyY, width: keyWidth - 12, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: keyFont, .foregroundColor: Palette.faint])
            value(e).draw(with: valueRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += h + rowGap
        }
    }
}

// MARK: - Image

final class ImageBox: ComponentBox {
    let source: String
    let alt: String
    let requestedWidth: CGFloat?
    /// An HTML image's own `align` attribute. Nil inherits the theme.
    let explicitAlignment: ImageAlignment?
    var alignment: ImageAlignment {
        explicitAlignment ?? (context?.typography.imageAlignment == .left ? .left : .center)
    }
    private var previewWidth: CGFloat?
    private var availableWidth: CGFloat = 0
    private(set) var resizeHandleVisible = false
    private(set) var resizeRect = NSRect.zero
    private(set) var displayedWidth: CGFloat = 0
    private struct Resolved {
        let url: URL
        let naturalSize: CGSize
        let cacheKey: ImageCache.Key
    }
    /// A badge Zephyr draws itself; a remote image loads when the document allows it (design §9).
    private enum State { case unresolved, badge(Badge), remote(URL), missing(String), ready(Resolved) }
    private var state: State = .unresolved
    private var requestID: UUID?
    private var remoteRequest: UUID?
    /// Output preflight runs on the isolated print/export canvas. Its later draws must not fall
    /// back to an asynchronous placeholder if the bounded cache evicts an earlier image.
    private(set) var preparingOutput = false

    init(source: String, alt: String, requestedWidth: CGFloat?, alignment: ImageAlignment?, kind: ComponentKind, context: RenderContext) {
        self.source = source
        self.alt = alt
        self.requestedWidth = requestedWidth
        explicitAlignment = alignment
        super.init(kind: kind, context: context)
    }

    deinit {
        guard let requestID else { return }
        Task { @MainActor in ImageDecodeQueue.shared.cancel(requestID) }
    }

    private func resolve() {
        guard case .unresolved = state else { return }
        // Header-only read gives the aspect ratio now, so layout is stable before pixels decode.
        switch DocumentImage.resolve(source, baseURL: context?.baseURL) {
        case let .file(url, key, natural): state = .ready(Resolved(url: url, naturalSize: natural, cacheKey: key))
        case let .badge(badge): state = .badge(badge)
        case let .remote(url): state = .remote(url)
        case .missing: state = .missing(source.removingPercentEncoding ?? source)
        }
    }

    /// The natural size and pixels of a badge or a loaded remote image (nil pixels for a badge).
    private var drawnSource: (size: CGSize, image: CGImage?)? {
        switch state {
        case let .badge(badge): return (BadgeRenderer.size(badge), nil)
        case let .remote(url):
            return MainActor.assumeIsolated {
                guard let size = RemoteImages.shared.size(of: url), let image = RemoteImages.shared.image(for: url) else { return nil }
                return (size, image)
            }
        default: return nil
        }
    }

    private func displaySize(_ natural: CGSize, width: CGFloat) -> CGSize {
        let w = min(previewWidth ?? requestedWidth ?? natural.width, width)
        let size = ImageCache.capped(CGSize(width: w, height: natural.height * w / natural.width))
        return CGSize(width: size.width, height: size.height.rounded())
    }

    func previewResize(to width: CGFloat) { previewWidth = max(48, width) }
    func finishResize() { previewWidth = nil }
    func committedWidth() -> CGFloat { min(previewWidth ?? displayedWidth, availableWidth) }
    func resizeHit(at point: NSPoint) -> Bool { resizeRect.insetBy(dx: -5, dy: -5).contains(point) }
    func setResizeHandleVisible(_ visible: Bool) {
        guard resizeHandleVisible != visible else { return }
        resizeHandleVisible = visible
        context?.componentNeedsDisplay(self)
    }
    func shouldDrawResizeGrip(drawingToScreen: Bool) -> Bool { resizeHandleVisible && drawingToScreen }

    override func viewerNaturalSize() -> CGSize? {
        resolve()
        if case let .remote(url) = state { return MainActor.assumeIsolated { RemoteImages.shared.size(of: url) } }
        if let drawn = drawnSource { return drawn.size }
        guard case let .ready(source) = state else { return nil }
        return source.naturalSize
    }

    /// A remote image waiting for the document to allow remote images.
    var isBlocked: Bool {
        resolve()
        guard case let .remote(url) = state, context?.loadsRemoteImages != true else { return false }
        return MainActor.assumeIsolated { RemoteImages.shared.image(for: url) == nil && !RemoteImages.shared.hasFailed(url) }
    }

    func isSourceImage(at url: URL) -> Bool {
        resolve()
        guard case let .ready(source) = state else { return false }
        return source.url.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
    }

    override func drawViewer(in ctx: CGContext) {
        resolve()
        if case let .badge(badge) = state { return BadgeRenderer.draw(badge, in: NSRect(origin: .zero, size: BadgeRenderer.size(badge))) }
        if let drawn = drawnSource, let image = drawn.image { return DocumentImage.draw(image, in: NSRect(origin: .zero, size: drawn.size), context: ctx) }
        guard case let .ready(source) = state else { return }
        guard let image = MainActor.assumeIsolated({ ImageCache.shared.image(for: source.cacheKey) }) else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: source.naturalSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: source.naturalSize))
        ctx.restoreGState()
    }

    override func viewerNeedsLoad() -> Bool {
        resolve()
        if case let .remote(url) = state { return MainActor.assumeIsolated { RemoteImages.shared.image(for: url) == nil && !RemoteImages.shared.hasFailed(url) } }
        guard case let .ready(source) = state else { return false }
        return MainActor.assumeIsolated { ImageCache.shared.image(for: source.cacheKey) == nil }
    }

    override func requestViewerLoad(_ completion: @escaping (Bool) -> Void) -> UUID? {
        resolve()
        if case let .remote(url) = state {
            return MainActor.assumeIsolated { RemoteImages.shared.load(url, completion: completion) }
        }
        guard case let .ready(source) = state else { return nil }
        return MainActor.assumeIsolated {
            ImageDecodeQueue.shared.request(source.cacheKey, url: source.url) { [weak self] image, completed in
                guard let self else { return completion(false) }
                if completed && image == nil { self.state = .missing(source.url.path) }
                completion(completed && image != nil)
            }
        }
    }

    override func cancelViewerLoad(_ request: UUID) {
        MainActor.assumeIsolated {
            ImageDecodeQueue.shared.cancel(request)
            RemoteImages.shared.cancel(request)
        }
    }

    override func height(in space: BlockSpace) -> CGFloat {
        resolve()
        availableWidth = space.column
        if let drawn = drawnSource { return displaySize(drawn.size, width: space.column).height }
        if case let .remote(url) = state, let size = MainActor.assumeIsolated({ RemoteImages.shared.size(of: url) }) {
            return displaySize(size, width: space.column).height
        }
        switch state {
        case let .ready(source): return displaySize(source.naturalSize, width: space.column).height
        default: return 44
        }
    }

    override func draw(in blockFrame: BlockFrame, context ctx: CGContext) {
        resolve()
        let rect = blockFrame.column
        availableWidth = rect.width
        switch state {
        case let .ready(source):
            let size = displaySize(source.naturalSize, width: blockFrame.column.width)
            let alignment: Typography.BlockAlignment = self.alignment == .center ? .center : .left
            let frame = NSRect(x: blockFrame.originX(width: size.width, alignment: alignment), y: rect.minY, width: size.width, height: size.height)
            drawnRect = frame
            displayedWidth = size.width
            resizeRect = NSRect(x: frame.maxX - 10, y: frame.maxY - 10, width: 10, height: 10)
            if let image = MainActor.assumeIsolated({ ImageCache.shared.image(for: source.cacheKey) }) {
                draw(image, in: frame, context: ctx)
            } else if preparingOutput || NSGraphicsContext.current?.isDrawingToScreen == false, let image = ImageCache.decode(source.url) {
                MainActor.assumeIsolated { ImageCache.shared.insert(image, for: source.cacheKey) }
                draw(image, in: frame, context: ctx)
            } else {
                Palette.codeBackground.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
                load(source)
            }
            if shouldDrawResizeGrip(drawingToScreen: NSGraphicsContext.current?.isDrawingToScreen == true) {
                let grip = NSBezierPath()
                grip.move(to: NSPoint(x: resizeRect.minX + 2, y: resizeRect.maxY - 2))
                grip.line(to: NSPoint(x: resizeRect.maxX - 2, y: resizeRect.minY + 2))
                grip.lineWidth = 1.5
                Palette.faint.setStroke()
                grip.stroke()
            }
        case let .badge(badge):
            let size = displaySize(BadgeRenderer.size(badge), width: rect.width)
            let frame = NSRect(x: blockFrame.originX(width: size.width, alignment: self.alignment == .center ? .center : .left), y: rect.minY, width: size.width, height: size.height)
            drawnRect = frame
            displayedWidth = size.width
            BadgeRenderer.draw(badge, in: frame)
        case let .remote(url):
            if let drawn = drawnSource, let image = drawn.image {
                let size = displaySize(drawn.size, width: rect.width)
                let frame = NSRect(x: blockFrame.originX(width: size.width, alignment: self.alignment == .center ? .center : .left), y: rect.minY, width: size.width, height: size.height)
                drawnRect = frame
                displayedWidth = size.width
                draw(image, in: frame, context: ctx)
                return
            }
            let allowed = context?.loadsRemoteImages ?? false
            let failed = MainActor.assumeIsolated { RemoteImages.shared.hasFailed(url) }
            if allowed, !failed, !preparingOutput, remoteRequest == nil, NSGraphicsContext.current?.isDrawingToScreen != false {
                remoteRequest = MainActor.assumeIsolated {
                    RemoteImages.shared.load(url) { [weak self] ok in
                        guard let self else { return }
                        self.remoteRequest = nil
                        if ok { self.context?.componentNeedsLayout(self) }
                    }
                }
            }
            let note = failed ? String(localized: "Image unavailable") : (allowed ? String(localized: "Loading remote image") : String(localized: "Remote image not loaded"))
            placeholder(rect, symbol: failed ? "exclamationmark.triangle" : "photo", text: alt.isEmpty ? source : alt, note: note)
        case let .missing(path):
            placeholder(rect, symbol: "exclamationmark.triangle", text: alt.isEmpty ? path : alt, note: String(localized: "Image unavailable"))
        case .unresolved:
            break
        }
    }

    override func prepareForOutput() {
        preparingOutput = true
        resolve()
        guard case let .ready(source) = state, MainActor.assumeIsolated({ ImageCache.shared.image(for: source.cacheKey) }) == nil else { return }
        if let image = ImageCache.decode(source.url) { MainActor.assumeIsolated { ImageCache.shared.insert(image, for: source.cacheKey) } }
        else { state = .missing(source.url.path) }
    }

    private func draw(_ image: CGImage, in frame: NSRect, context ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).addClip()
        ctx.saveGState()
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: frame.size))
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func placeholder(_ rect: NSRect, symbol: String, text: String, note: String) {
        let box = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 44)
        drawnRect = box
        Palette.codeBackground.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let tinted = image.tinted(Palette.muted)
            tinted.draw(in: NSRect(x: box.minX + 12, y: box.midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height))
        }
        let line = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.muted])
        line.append(NSAttributedString(string: "  " + note, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.faint]))
        line.draw(with: NSRect(x: box.minX + 36, y: box.midY - 8, width: box.width - 48, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func load(_ source: Resolved) {
        guard requestID == nil else { return }
        requestID = MainActor.assumeIsolated {
            ImageDecodeQueue.shared.request(source.cacheKey, url: source.url) { [weak self] image, completed in
                guard let self else { return }
                self.requestID = nil
                guard completed else {
                    // Dropped while too many waited: draw again soon, which asks again if still shown.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self else { return }
                        self.context?.componentNeedsDisplay(self)
                    }
                    return
                }
                if image == nil {
                    self.state = .missing(source.url.path)
                    self.context?.componentNeedsLayout(self)
                } else {
                    self.context?.componentNeedsDisplay(self)
                }
            }
        }
    }
}

extension NSImage {
    /// A symbol image in `color`, translucency included. The color is part of the symbol's
    /// configuration, so it draws as vectors anywhere: compositing a fill through the glyph
    /// (`.destinationIn`) leaves a solid box in a PDF or print context, and so does a palette of
    /// one color; one color per layer prints as drawn.
    func tinted(_ color: NSColor) -> NSImage {
        withSymbolConfiguration(symbolConfiguration.applying(.init(paletteColors: [color, color, color]))) ?? self
    }
}
