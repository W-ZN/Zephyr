import AppKit
import SwaTex
import SwaTexRender

/// Vector formula drawing with SwaTex `DisplayList` + Core Graphics (design §9). The cache is owned
/// by the app and metered in bytes across all windows, instead of SwaTex's count-based
/// `FormulaCache.shared`.
final class MathRenderer {
    static let shared = MathRenderer(budget: 16 << 20)
    /// Hostile-input guard: longer sources stay as text with an error.
    static let maxSourceLength = 8_000

    final class Formula {
        let list: DisplayList?
        let error: String?
        fileprivate(set) var recolored: (color: SwaTex.Color, list: DisplayList)?
        fileprivate var bytes: Int
        fileprivate var stamp: UInt64 = 0

        init(list: DisplayList?, error: String?, bytes: Int) {
            self.list = list
            self.error = error
            self.bytes = bytes
        }

        /// Size in points for a font size (em = font size).
        func size(fontSize: CGFloat) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
            guard let list else { return (0, 0, 0) }
            return (CGFloat(list.width) * fontSize, CGFloat(list.height) * fontSize, CGFloat(list.depth) * fontSize)
        }
    }

    private struct Key: Hashable {
        let tex: String
        let display: Bool
    }

    private var entries: [Key: Formula] = [:]
    private(set) var bytes = 0
    private var clock: UInt64 = 0
    let budget: Int

    init(budget: Int) { self.budget = budget }

    func formula(_ tex: String, display: Bool) -> Formula {
        let key = Key(tex: tex, display: display)
        clock += 1
        if let f = entries[key] {
            f.stamp = clock
            return f
        }
        let formula: Formula
        if tex.utf16.count > Self.maxSourceLength {
            formula = Formula(list: nil, error: "Formula too long", bytes: tex.utf8.count)
        } else {
            do {
                let list = try SwaTexEngine.displayList(for: tex, style: display ? .display : .text, color: .black)
                formula = Formula(list: list, error: nil, bytes: Self.estimate(list) + tex.utf8.count)
            } catch {
                formula = Formula(list: nil, error: "\(error)", bytes: tex.utf8.count + 64)
            }
        }
        formula.stamp = clock
        entries[key] = formula
        bytes += formula.bytes
        if bytes > budget { evict() }
        return formula
    }

    /// Draw with the top-left corner at `origin` in a flipped (y-down) context.
    func draw(_ formula: Formula, at origin: CGPoint, fontSize: CGFloat, color: NSColor, in ctx: CGContext) {
        guard let list = colored(formula, color) else { return }
        let options = RenderOptions(fontSize: fontSize, padding: 0)
        let height = CGFloat(list.totalHeight) * fontSize
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y + height)
        ctx.scaleBy(x: 1, y: -1)
        DisplayListRenderer.draw(list, in: ctx, options: options)
        ctx.restoreGState()
    }

    /// Formulas are laid out in black; other colors (dark mode) get one recolored copy each,
    /// keeping explicit `\color{…}` intact.
    private func colored(_ formula: Formula, _ color: NSColor) -> DisplayList? {
        guard let list = formula.list else { return nil }
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let target = SwaTex.Color(r: Float(rgb.redComponent), g: Float(rgb.greenComponent), b: Float(rgb.blueComponent), a: Float(rgb.alphaComponent))
        if target == .black { return list }
        if let r = formula.recolored, r.color == target { return r.list }
        func map(_ c: SwaTex.Color) -> SwaTex.Color { c == .black ? target : c }
        var copy = list
        copy.items = list.items.map { item in
            switch item {
            case let .glyphPath(x, y, scale, font, code, c): .glyphPath(x: x, y: y, scale: scale, font: font, charCode: code, color: map(c))
            case let .line(x, y, w, t, c, d): .line(x: x, y: y, width: w, thickness: t, color: map(c), dashed: d)
            case let .rect(x, y, w, h, c): .rect(x: x, y: y, width: w, height: h, color: map(c))
            case let .path(x, y, cmds, fill, c): .path(x: x, y: y, commands: cmds, fill: fill, color: map(c))
            }
        }
        if formula.recolored == nil {
            formula.bytes *= 2
            bytes += formula.bytes / 2
        }
        formula.recolored = (target, copy)
        if bytes > budget { evict() }
        return copy
    }

    private static func estimate(_ list: DisplayList) -> Int {
        var total = 96 + list.items.count * MemoryLayout<DisplayItem>.stride
        for item in list.items {
            if case let .path(_, _, commands, _, _) = item { total += commands.count * MemoryLayout<PathCommand>.stride + 32 }
            if case let .glyphPath(_, _, _, font, _, _) = item { total += font.utf8.count > 15 ? font.utf8.count : 0 }
        }
        return total
    }

    /// Drop least recently used formulas until the cache is at 75 % of its budget.
    private func evict() {
        let target = budget * 3 / 4
        for (key, f) in entries.sorted(by: { $0.value.stamp < $1.value.stamp }) {
            guard bytes > target else { break }
            entries[key] = nil
            bytes -= f.bytes
        }
    }
}

/// Read-only view of the shared formula cache, for measurements.
public enum MathRendererProbe {
    @MainActor public static var bytes: Int { MathRenderer.shared.bytes }
}
