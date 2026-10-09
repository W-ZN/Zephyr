import AppKit
import ZephyrCore

/// Draws a static shields.io badge as vectors (design §9), with the service's own metrics: Verdana
/// at 11 pt, 5 pt of padding on each side of a part, 20 pt high (18 for plastic, 28 for the
/// uppercase for-the-badge style), so a drawn badge matches the one a web page would load.
enum BadgeRenderer {
    private struct Metrics {
        var height: CGFloat
        var padding: CGFloat
        var radius: CGFloat
        var baseline: CGFloat
        var font: NSFont
        var messageFont: NSFont
        var kern: CGFloat
        var shadow: Bool
    }

    private static func metrics(_ style: Badge.Style) -> Metrics {
        let verdana = NSFont(name: "Verdana", size: 11) ?? NSFont.systemFont(ofSize: 11)
        switch style {
        case .flat: return Metrics(height: 20, padding: 5, radius: 3, baseline: 14, font: verdana, messageFont: verdana, kern: 0, shadow: true)
        case .flatSquare: return Metrics(height: 20, padding: 5, radius: 0, baseline: 14, font: verdana, messageFont: verdana, kern: 0, shadow: false)
        case .plastic: return Metrics(height: 18, padding: 5, radius: 4, baseline: 13, font: verdana, messageFont: verdana, kern: 0, shadow: true)
        case .forTheBadge:
            let small = NSFont(name: "Verdana", size: 10) ?? NSFont.systemFont(ofSize: 10)
            let bold = NSFont(name: "Verdana-Bold", size: 10) ?? NSFont.boldSystemFont(ofSize: 10)
            return Metrics(height: 28, padding: 9, radius: 0, baseline: 18, font: small, messageFont: bold, kern: 1.25, shadow: false)
        }
    }

    private static func text(_ badge: Badge) -> (label: String, message: String) {
        badge.style == .forTheBadge ? (badge.label.uppercased(), badge.message.uppercased()) : (badge.label, badge.message)
    }

    private static func width(_ string: String, _ font: NSFont, kern: CGFloat) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return ceil(NSAttributedString(string: string, attributes: [.font: font, .kern: kern]).size().width)
    }

    /// The parts' widths: an empty label has no part.
    private static func parts(_ badge: Badge) -> (label: CGFloat, message: CGFloat) {
        let m = metrics(badge.style)
        let (label, message) = text(badge)
        let l = label.isEmpty ? 0 : width(label, m.font, kern: m.kern) + m.padding * 2
        return (l, width(message, m.messageFont, kern: m.kern) + m.padding * 2)
    }

    static func size(_ badge: Badge) -> CGSize {
        let p = parts(badge)
        return CGSize(width: p.label + p.message, height: metrics(badge.style).height)
    }

    /// Draws `badge` scaled into `rect` (view coordinates, flipped).
    static func draw(_ badge: Badge, in rect: NSRect) {
        let m = metrics(badge.style)
        let natural = size(badge)
        guard natural.width > 0, rect.width > 0, rect.height > 0 else { return }
        let p = parts(badge)
        let (label, message) = text(badge)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / natural.width, yBy: rect.height / natural.height)
        transform.concat()
        let whole = NSRect(origin: .zero, size: natural)
        NSBezierPath(roundedRect: whole, xRadius: m.radius, yRadius: m.radius).addClip()
        if p.label > 0 {
            color(badge.labelColor).setFill()
            NSRect(x: 0, y: 0, width: p.label, height: m.height).fill()
        }
        color(badge.color).setFill()
        NSRect(x: p.label, y: 0, width: p.message, height: m.height).fill()
        switch badge.style {
        case .flat:
            NSGradient(starting: NSColor(white: 0.73, alpha: 0.1), ending: NSColor(white: 0, alpha: 0.1))?.draw(in: whole, angle: 90)
        case .plastic:
            NSGradient(colors: [NSColor(white: 1, alpha: 0.7), NSColor(white: 0.67, alpha: 0.1), NSColor(white: 0, alpha: 0.3), NSColor(white: 0, alpha: 0.5)],
                       atLocations: [0, 0.1, 0.9, 1], colorSpace: .sRGB)?.draw(in: whole, angle: 90)
        case .flatSquare, .forTheBadge:
            break
        }
        if p.label > 0 { drawText(label, font: m.font, background: badge.labelColor, center: p.label / 2, m: m) }
        drawText(message, font: m.messageFont, background: badge.color, center: p.label + p.message / 2, m: m)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// White text on a dark part, dark text on a light one (shields.io's brightness rule).
    private static func drawText(_ string: String, font: NSFont, background: UInt32, center: CGFloat, m: Metrics) {
        let r = CGFloat((background >> 16) & 0xFF), g = CGFloat((background >> 8) & 0xFF), b = CGFloat(background & 0xFF)
        let light = (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.69
        let ink = light ? Self.color(0x333333) : .white
        let shade = light ? NSColor(white: 0.8, alpha: 0.3) : NSColor(white: 0.004, alpha: 0.3)
        func draw(_ color: NSColor, dy: CGFloat) {
            let s = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: m.kern])
            let w = s.size().width
            s.draw(at: NSPoint(x: center - w / 2, y: m.baseline + dy - font.ascender))
        }
        if m.shadow { draw(shade, dy: 1) }
        draw(ink, dy: 0)
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
