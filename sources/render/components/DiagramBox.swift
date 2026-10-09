import AppKit
import ZephyrCore

/// A Mermaid flowchart or sequence diagram, drawn by Zephyr (design §8.1) in the theme's
/// diagram settings: label size, spacing, curved, straight or angled lines, filled or outlined
/// shapes, accent or neutral colors. It sits on a card like a code block's (the look of diagrams
/// in coding tools, not Mermaid's own): light nodes with a quiet outline, thin edges, labels on
/// chips. Wider than the column, the card takes the window's width; wider than that, it scales
/// down like a formula. The caret inside the block shows its source.
final class DiagramBox: ComponentBox {
    let diagram: MermaidDiagram
    private var scene: (key: String, value: DiagramScene)?

    init(diagram: MermaidDiagram, kind: ComponentKind, context: RenderContext) {
        self.diagram = diagram
        super.init(kind: kind, context: context)
    }

    private func layout() -> DiagramScene? {
        guard let typography = context?.typography else { return nil }
        let font = typography.diagramFont
        let key = "\(font.fontName)|\(font.pointSize)|\(typography.diagram.spacing)|\(typography.diagram.lines)"
        if let scene, scene.key == key { return scene.value }
        // Long labels wrap at about 240 pt (at a 14 pt label) instead of stretching their node.
        let wrap = 240 * font.pointSize / 14
        let medium = Painter.medium(font)
        let value = DiagramLayout.layout(diagram, style: typography.diagram) { text in
            let size = (text as NSString).boundingRect(with: NSSize(width: wrap, height: 10_000), options: [.usesLineFragmentOrigin], attributes: [.font: medium]).size
            return DiagramSize(width: ceil(size.width), height: ceil(size.height))
        }
        scene = (key, value)
        return value
    }

    /// The card's padding around the drawing.
    static let padding: CGFloat = 24

    /// The card is the column's width; a wider drawing scales down into it (the expanded view shows
    /// it at full size).
    private func fit(_ scene: DiagramScene, _ space: BlockSpace) -> (width: CGFloat, scale: CGFloat) {
        (space.column, min(1, (space.column - 2 * Self.padding) / scene.size.width))
    }

    override func height(in space: BlockSpace) -> CGFloat {
        guard let scene = layout() else { return 0 }
        return ceil(scene.size.height * fit(scene, space).scale + 2 * Self.padding)
    }

    override func viewerNaturalSize() -> CGSize? {
        guard let scene = layout() else { return nil }
        return CGSize(width: scene.size.width, height: scene.size.height)
    }

    override func drawViewer(in ctx: CGContext) {
        guard let scene = layout(), let typography = context?.typography else { return }
        Painter(typography: typography).draw(scene)
    }

    override func draw(in frame: BlockFrame, context ctx: CGContext) {
        guard let scene = layout(), let typography = context?.typography else { return }
        let (width, s) = fit(scene, frame.space)
        let card = NSRect(x: frame.originX(width: width, alignment: .left), y: frame.column.minY, width: width, height: ceil(scene.size.height * s + 2 * Self.padding))
        drawnRect = card
        let hair = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        let outline = NSBezierPath(roundedRect: card.insetBy(dx: hair / 2, dy: hair / 2), xRadius: 10, yRadius: 10)
        Palette.codeBackground.setFill()
        outline.fill()
        outline.lineWidth = hair
        Palette.codeBorder.setStroke()
        outline.stroke()
        ctx.saveGState()
        ctx.translateBy(x: card.midX - scene.size.width * s / 2, y: card.minY + Self.padding)
        ctx.scaleBy(x: s, y: s)
        Painter(typography: typography).draw(scene)
        ctx.restoreGState()
    }

}

/// Draws a scene in the current (flipped) graphics context, on the card's background. Sizes are
/// in points at a 14 pt label and scale with it.
private struct Painter {
    let typography: Typography
    var em: CGFloat { typography.diagramFont.pointSize }
    var unit: CGFloat { em / 14 }
    var hair: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }
    var stroke: NSColor { typography.diagramAccent ? Palette.accent.withAlphaComponent(0.55) : Palette.color(.diagramStroke) }
    var lines: NSColor { typography.diagramAccent ? Palette.muted : Palette.color(.diagramLine) }

    /// The diagram font at medium weight, for node and participant names.
    static func medium(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.medium]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    func draw(_ scene: DiagramScene) {
        for item in scene.items {
            switch item {
            case let .frame(r, kind, label): frame(rect(r), kind: kind, label: label)
            case let .divider(y, from, to, label): divider(y: y, from: from, to: to, label: label)
            case let .lifeline(x, top, bottom):
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x, y: top))
                path.line(to: NSPoint(x: x, y: bottom))
                path.lineWidth = 1
                path.setLineDash([3 * unit, 4 * unit], count: 2, phase: 0)
                stroke.setStroke()
                path.stroke()
            case let .participant(r, label, actor):
                let box = rect(r)
                let radius = actor ? box.height / 2 : 6 * unit
                shape(box, path: NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius), extra: nil)
                text(label, in: box, color: Palette.text, weight: .medium)
            case let .node(r, kind, label):
                let box = rect(r)
                let (outline, extra) = Self.outline(kind, box, unit: unit)
                shape(box, path: outline, extra: extra)
                text(label, in: box, color: Palette.text, weight: .medium)
            case let .path(segments, dashed, thick, head, tail): path(segments, dashed: dashed, thick: thick, head: head, tail: tail)
            case let .text(r, label, boxed):
                let box = rect(r)
                // Labels on lines sit on a chip of the raised surface, 6 × 3 pt around them.
                if boxed {
                    Tokens.raised.setFill()
                    NSBezierPath(roundedRect: box.insetBy(dx: -6 * unit, dy: -3 * unit), xRadius: 5 * unit, yRadius: 5 * unit).fill()
                }
                text(label, in: box, color: Palette.muted, weight: .regular, size: round(em * 12 / 14 * 2) / 2)
            case let .note(r, label):
                let box = rect(r)
                let path = NSBezierPath(roundedRect: box.insetBy(dx: hair / 2, dy: hair / 2), xRadius: 6 * unit, yRadius: 6 * unit)
                Tokens.raised.setFill()
                path.fill()
                path.lineWidth = hair
                Palette.codeBorder.setStroke()
                path.stroke()
                text(label, in: box, color: Palette.text, weight: .regular)
            case let .number(p, n):
                let d = em * 1.15
                let circle = NSRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
                Palette.accent.setFill()
                NSBezierPath(ovalIn: circle).fill()
                text("\(n)", in: circle, color: Tokens.onAccent, weight: .semibold, size: em * 0.7)
            }
        }
    }

    private func rect(_ r: DiagramRect) -> NSRect { NSRect(x: r.x, y: r.y, width: r.width, height: r.height) }
    private func point(_ p: DiagramPoint) -> NSPoint { NSPoint(x: p.x, y: p.y) }

    /// A node: its fill (the card's own color when outlined, so lines never show through), the
    /// accent's tint on top in accent colors, the outline.
    private func shape(_ box: NSRect, path: NSBezierPath, extra: NSBezierPath?) {
        (typography.diagramFilled ? Palette.color(.diagramNode) : Palette.codeBackground).setFill()
        path.fill()
        if typography.diagramAccent {
            Tokens.accentSoft.setFill()
            path.fill()
        }
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
        if let extra {
            extra.lineWidth = 1
            extra.stroke()
        }
    }

    static func outline(_ kind: Flowchart.Shape, _ r: NSRect, unit: CGFloat) -> (NSBezierPath, NSBezierPath?) {
        let r = r.insetBy(dx: 0.5, dy: 0.5)
        switch kind {
        case .rectangle: return (NSBezierPath(roundedRect: r, xRadius: 6 * unit, yRadius: 6 * unit), nil)
        case .rounded: return (NSBezierPath(roundedRect: r, xRadius: min(10 * unit, r.height / 2), yRadius: min(10 * unit, r.height / 2)), nil)
        case .stadium: return (NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2), nil)
        case .circle: return (NSBezierPath(ovalIn: r), nil)
        case .subroutine:
            let inner = NSBezierPath()
            for x in [r.minX + 7, r.maxX - 7] {
                inner.move(to: NSPoint(x: x, y: r.minY))
                inner.line(to: NSPoint(x: x, y: r.maxY))
            }
            return (NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3), inner)
        case .diamond:
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.midX, y: r.minY))
            p.line(to: NSPoint(x: r.maxX, y: r.midY))
            p.line(to: NSPoint(x: r.midX, y: r.maxY))
            p.line(to: NSPoint(x: r.minX, y: r.midY))
            p.close()
            p.lineJoinStyle = .round
            return (p, nil)
        case .hexagon:
            let inset = min(r.height / 2, r.width / 4)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX + inset, y: r.minY))
            p.line(to: NSPoint(x: r.maxX - inset, y: r.minY))
            p.line(to: NSPoint(x: r.maxX, y: r.midY))
            p.line(to: NSPoint(x: r.maxX - inset, y: r.maxY))
            p.line(to: NSPoint(x: r.minX + inset, y: r.maxY))
            p.line(to: NSPoint(x: r.minX, y: r.midY))
            p.close()
            p.lineJoinStyle = .round
            return (p, nil)
        case .flag:
            let notch = min(r.height / 2, 10)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX, y: r.minY))
            p.line(to: NSPoint(x: r.maxX, y: r.minY))
            p.line(to: NSPoint(x: r.maxX, y: r.maxY))
            p.line(to: NSPoint(x: r.minX, y: r.maxY))
            p.line(to: NSPoint(x: r.minX + notch, y: r.midY))
            p.close()
            return (p, nil)
        case .database:
            let lid = min(r.height * 0.18, 8)
            let body = NSBezierPath()
            body.move(to: NSPoint(x: r.minX, y: r.minY + lid))
            body.line(to: NSPoint(x: r.minX, y: r.maxY - lid))
            body.curve(to: NSPoint(x: r.maxX, y: r.maxY - lid), controlPoint1: NSPoint(x: r.minX, y: r.maxY + lid / 3), controlPoint2: NSPoint(x: r.maxX, y: r.maxY + lid / 3))
            body.line(to: NSPoint(x: r.maxX, y: r.minY + lid))
            body.curve(to: NSPoint(x: r.minX, y: r.minY + lid), controlPoint1: NSPoint(x: r.maxX, y: r.minY - lid / 3), controlPoint2: NSPoint(x: r.minX, y: r.minY - lid / 3))
            body.close()
            let top = NSBezierPath()
            top.move(to: NSPoint(x: r.minX, y: r.minY + lid))
            top.curve(to: NSPoint(x: r.maxX, y: r.minY + lid), controlPoint1: NSPoint(x: r.minX, y: r.minY + lid * 7 / 3), controlPoint2: NSPoint(x: r.maxX, y: r.minY + lid * 7 / 3))
            return (body, top)
        }
    }

    private func path(_ segments: [DiagramScene.Segment], dashed: Bool, thick: Bool, head: DiagramScene.Head?, tail: DiagramScene.Head?) {
        let path = NSBezierPath()
        var points: [NSPoint] = []
        for s in segments {
            switch s {
            case let .move(p):
                path.move(to: point(p))
                points.append(point(p))
            case let .line(p):
                path.line(to: point(p))
                points.append(point(p))
            case let .curve(a, b, p):
                path.curve(to: point(p), controlPoint1: point(a), controlPoint2: point(b))
                points.append(point(b))
                points.append(point(p))
            }
        }
        guard points.count > 1 else { return }
        let width: CGFloat = (thick ? 2.25 : 1.25) * unit
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if dashed { path.setLineDash([4 * unit, 3 * unit], count: 2, phase: 0) }
        lines.setStroke()
        path.stroke()
        // Arrowheads 7 pt long and 6 pt wide.
        let size = 7 * unit + (thick ? 1 : 0)
        if let head { arrow(head, at: points[points.count - 1], from: points[points.count - 2], size: size) }
        if let tail { arrow(tail, at: points[0], from: points[1], size: size) }
    }

    private func arrow(_ head: DiagramScene.Head, at tip: NSPoint, from: NSPoint, size: CGFloat) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        func at(_ back: CGFloat, _ side: CGFloat) -> NSPoint {
            NSPoint(x: tip.x - back * cos(angle) - side * sin(angle), y: tip.y - back * sin(angle) + side * cos(angle))
        }
        let p = NSBezierPath()
        p.lineJoinStyle = .round
        p.lineCapStyle = .round
        switch head {
        case .filled:
            p.move(to: tip)
            p.line(to: at(size, size * 3 / 7))
            p.line(to: at(size, -size * 3 / 7))
            p.close()
            lines.setFill()
            p.fill()
            p.lineWidth = 1
            lines.setStroke()
            p.stroke()
        case .chevron:
            p.move(to: at(size, size * 0.5))
            p.line(to: tip)
            p.line(to: at(size, -size * 0.5))
            p.lineWidth = 1.15
            lines.setStroke()
            p.stroke()
        case .cross:
            let c = at(size * 0.5, 0), d = size * 0.35
            p.move(to: NSPoint(x: c.x - d, y: c.y - d))
            p.line(to: NSPoint(x: c.x + d, y: c.y + d))
            p.move(to: NSPoint(x: c.x - d, y: c.y + d))
            p.line(to: NSPoint(x: c.x + d, y: c.y - d))
            p.lineWidth = 1.3
            lines.setStroke()
            p.stroke()
        }
    }

    private func frame(_ r: NSRect, kind: String, label: String) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: hair / 2, dy: hair / 2), xRadius: 8 * unit, yRadius: 8 * unit)
        path.lineWidth = 1
        stroke.setStroke()
        path.stroke()
        let tagFont = Typography.resize(typography.withTraits(typography.diagramFont, bold: true, italic: false), round(em * 0.8))
        let tag = NSAttributedString(string: kind, attributes: [.font: tagFont, .foregroundColor: Palette.muted])
        let size = tag.size()
        let tagRect = NSRect(x: r.minX, y: r.minY, width: ceil(size.width) + em, height: ceil(size.height) + em * 0.4)
        let corner = NSBezierPath()
        corner.move(to: NSPoint(x: tagRect.minX, y: tagRect.minY + 8 * unit))
        corner.appendArc(from: NSPoint(x: tagRect.minX, y: tagRect.minY), to: NSPoint(x: tagRect.minX + 8 * unit, y: tagRect.minY), radius: 8 * unit)
        corner.line(to: NSPoint(x: tagRect.maxX, y: tagRect.minY))
        corner.line(to: NSPoint(x: tagRect.maxX, y: tagRect.maxY - 6))
        corner.line(to: NSPoint(x: tagRect.maxX - 6, y: tagRect.maxY))
        corner.line(to: NSPoint(x: tagRect.minX, y: tagRect.maxY))
        corner.close()
        Tokens.raised.setFill()
        corner.fill()
        stroke.setStroke()
        corner.lineWidth = hair
        corner.stroke()
        tag.draw(at: NSPoint(x: tagRect.minX + em / 2, y: tagRect.minY + em * 0.2))
        if !label.isEmpty {
            let text = NSAttributedString(string: "[\(label)]", attributes: [.font: Typography.resize(typography.diagramFont, round(em * 0.85)), .foregroundColor: Palette.muted])
            text.draw(at: NSPoint(x: tagRect.maxX + em * 0.5, y: tagRect.minY + (tagRect.height - text.size().height) / 2))
        }
    }

    private func divider(y: CGFloat, from: CGFloat, to: CGFloat, label: String) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: from, y: y))
        path.line(to: NSPoint(x: to, y: y))
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        Palette.rule.setStroke()
        path.stroke()
        if !label.isEmpty {
            let text = NSAttributedString(string: "[\(label)]", attributes: [.font: Typography.resize(typography.diagramFont, round(em * 0.85)), .foregroundColor: Palette.muted])
            text.draw(at: NSPoint(x: from + em * 0.6, y: y + em * 0.25))
        }
    }

    /// Centered lines of `label` in `box`.
    private func text(_ label: String, in box: NSRect, color: NSColor, weight: NSFont.Weight, size: CGFloat? = nil) {
        var font = typography.diagramFont
        if let size { font = Typography.resize(font, size) }
        if weight == .medium { font = Self.medium(font) } else if weight != .regular { font = typography.withTraits(font, bold: true, italic: false) }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let bounds = text.boundingRect(with: NSSize(width: max(box.width, 1), height: 10_000), options: [.usesLineFragmentOrigin])
        text.draw(with: NSRect(x: box.minX, y: box.midY - ceil(bounds.height) / 2, width: box.width, height: ceil(bounds.height)), options: [.usesLineFragmentOrigin])
    }
}
