import AppKit
import CoreText
import ZephyrCore

/// An HTML block in the safe subset (design §9), laid out by Zephyr instead of a web view. The
/// rules are a small part of CSS's normal flow: block elements stack with collapsing margins taken
/// from the theme, inline content (text runs and images) is broken into lines by Core Text and
/// placed as its `align` asks, and images sit centered on the text's x-height. Links, keycaps,
/// code, marks, sub- and superscripts are drawn; everything else about styling is the theme's.
final class HTMLBox: ComponentBox {
    let fragment: HTMLFragment
    private var images: [String: DocumentImage] = [:]
    private var cached: (width: CGFloat, dark: Bool, generation: Int, typography: ObjectIdentifier?, layout: HTMLLayout)?
    /// Bumped when an image's size becomes known, so the next measure lays out again.
    private var generation = 0
    /// Where links and images were drawn last, in view coordinates.
    private(set) var links: [(rect: NSRect, href: String)] = []
    private(set) var placed: [(rect: NSRect, image: DocumentImage)] = []

    init(fragment: HTMLFragment, kind: ComponentKind, context: RenderContext) {
        self.fragment = fragment
        super.init(kind: kind, context: context)
    }

    private func image(_ source: String, alt: String) -> DocumentImage {
        let key = source + "\u{0}" + alt
        if let image = images[key] { return image }
        let image = DocumentImage(source: source, alt: alt, baseURL: context?.baseURL)
        images[key] = image
        return image
    }

    func layout(width: CGFloat) -> HTMLLayout {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // A new theme is a new `Typography`: lay out again with its fonts and spacing.
        let typography = context?.typography
        let theme = typography.map(ObjectIdentifier.init)
        if let c = cached, c.width == width, c.dark == dark, c.generation == generation, c.typography == theme { return c.layout }
        var builder = HTMLLayout.Builder(typography: typography ?? Typography(), width: width, dark: dark) { [unowned self] in self.image($0, alt: $1) }
        let layout = builder.build(fragment.nodes)
        cached = (width, dark, generation, theme, layout)
        return layout
    }

    override func height(in space: BlockSpace) -> CGFloat { ceil(layout(width: space.column).height) }

    override func draw(in frame: BlockFrame, context ctx: CGContext) {
        let width = frame.column.width
        let l = layout(width: width)
        let origin = frame.column.origin
        drawnRect = NSRect(x: origin.x, y: origin.y, width: width, height: l.height)
        let fontSize = context?.typography.fontSize ?? 16
        l.draw(at: origin, context: ctx, allowRemote: context?.loadsRemoteImages ?? false, fontSize: fontSize) { [weak self] sizeChanged, rect in
            guard let self else { return }
            if sizeChanged {
                self.generation += 1
                self.context?.componentNeedsLayout(self)
            } else {
                self.context?.componentNeedsDisplay(self, in: rect)
            }
        }
        links = l.links.map { ($0.rect.offsetBy(dx: origin.x, dy: origin.y), $0.href) }
        placed = l.images.map { ($0.rect.offsetBy(dx: origin.x, dy: origin.y), $0.image) }
    }

    override func prepareForOutput() {
        for image in images.values { image.forOutput = true }
    }

    func link(at point: NSPoint) -> String? {
        links.last { $0.rect.insetBy(dx: -1, dy: -1).contains(point) }?.href
    }

    /// A remote image here waits for the document to allow remote images.
    func blockedImage(at point: NSPoint) -> Bool {
        let allow = context?.loadsRemoteImages ?? false
        return placed.contains { $0.rect.contains(point) && $0.image.isBlocked(allowRemote: allow) }
    }
}

private extension NSAttributedString.Key {
    static let htmlImage = NSAttributedString.Key("zephyr.html.image")
    static let htmlLink = NSAttributedString.Key("zephyr.html.link")
    static let htmlBox = NSAttributedString.Key("zephyr.html.box")
    static let htmlLine = NSAttributedString.Key("zephyr.html.line")
}

/// One fragment laid out at one width, relative to its top-left corner (flipped coordinates).
struct HTMLLayout {
    struct Line {
        var line: CTLine
        var origin: CGPoint
    }

    enum Mark {
        /// A filled rectangle (rules, quote bars, underlines, strikethroughs).
        case fill(CGRect, NSColor)
        /// A rounded box behind text: inline code, keycaps (outlined), highlights.
        case box(CGRect, fill: NSColor, stroke: NSColor?)
    }

    var lines: [Line] = []
    var images: [(rect: CGRect, image: DocumentImage)] = []
    var marks: [Mark] = []
    var links: [(rect: CGRect, href: String)] = []
    var height: CGFloat = 0

    /// `changed(sizeChanged, rect)`: an image finished loading where it was drawn.
    func draw(at origin: CGPoint, context ctx: CGContext, allowRemote: Bool, fontSize: CGFloat, changed: @escaping (Bool, NSRect) -> Void) {
        for mark in marks {
            switch mark {
            case let .fill(r, color):
                color.setFill()
                r.offsetBy(dx: origin.x, dy: origin.y).fill(using: .sourceOver)
            case let .box(r, fill, stroke):
                let path = NSBezierPath(roundedRect: r.offsetBy(dx: origin.x, dy: origin.y), xRadius: 4, yRadius: 4)
                fill.setFill()
                path.fill()
                if let stroke {
                    stroke.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for l in lines {
            ctx.textPosition = CGPoint(x: origin.x + l.origin.x, y: origin.y + l.origin.y)
            CTLineDraw(l.line, ctx)
        }
        ctx.restoreGState()
        // Only images in the area being drawn: asking for the others would decode or download
        // images nobody sees, and evict the ones on screen.
        let clip = ctx.boundingBoxOfClipPath
        for placed in images {
            let rect = placed.rect.offsetBy(dx: origin.x, dy: origin.y)
            guard rect.intersects(clip) else { continue }
            placed.image.draw(in: rect, context: ctx, allowRemote: allowRemote, fontSize: fontSize) { changed($0, rect) }
        }
    }

    enum Align { case left, center, right }

    /// Walks the fragment once: block elements end the current flow of inline content and open a
    /// new one; each flow is set in lines when it ends.
    struct Builder {
        let typography: Typography
        let width: CGFloat
        let dark: Bool
        let image: (String, String) -> DocumentImage

        private var out = HTMLLayout()
        private var y: CGFloat = 0
        /// Margin owed before the next block (adjoining margins collapse to the larger one).
        private var margin: CGFloat = 0
        private var started = false
        private var flow = NSMutableAttributedString()
        private var flowImages: [(image: DocumentImage, size: CGSize, ascent: CGFloat)] = []
        private var afterSpace = true
        private var block = Block()
        private var boxes = 0

        struct Block {
            var align: Align = .left
            var indent: CGFloat = 0
            var heading = 0
        }

        struct Style {
            var font: NSFont
            var color: NSColor
            var link: String?
            /// Tells adjacent keycaps and marks apart, so each draws its own box.
            var box = 0
            var bold = false, italic = false, code = false, keycap = false, mark = false
            var underline = false, strike = false, small = false
            var script = 0
        }

        init(typography: Typography, width: CGFloat, dark: Bool, image: @escaping (String, String) -> DocumentImage) {
            self.typography = typography
            self.width = width
            self.dark = dark
            self.image = image
        }

        mutating func build(_ nodes: [HTMLFragment.Node]) -> HTMLLayout {
            walk(nodes, Style(font: typography.bodyFont, color: Palette.text))
            endFlow()
            out.height = ceil(y)
            return out
        }

        private func em(_ key: String) -> CGFloat { round(typography.fontSize * CGFloat(typography.settings.number(key) ?? 0)) }

        // MARK: Walk

        private mutating func walk(_ nodes: [HTMLFragment.Node], _ style: Style) {
            for node in nodes {
                switch node {
                case let .text(t): text(t, style)
                case let .element(e): element(e, style)
                }
            }
        }

        private mutating func element(_ e: HTMLFragment.Element, _ style: Style) {
            var s = style
            switch e.name {
            case "br":
                flow.append(NSAttributedString(string: "\u{2028}", attributes: attributes(style)))
                afterSpace = true
                return
            case "wbr", "source":
                return
            case "img":
                return addImage(e, style)
            case "picture":
                if let img = picture(e) { addImage(img, style) }
                return
            case "hr":
                endFlow()
                open(margin: typography.fontSize)
                place()
                out.marks.append(.fill(CGRect(x: block.indent, y: y, width: width - block.indent, height: 1), Palette.rule))
                y += 1
                margin = max(margin, typography.fontSize)
                return
            case "a":
                s.link = e["href"]
                s.color = Palette.link
            case "b", "strong": s.bold = true
            case "i", "em": s.italic = true
            case "code", "tt": s.code = true
            case "kbd":
                s.keycap = true
                boxes += 1
                s.box = boxes
                walk(e.children, s)
                return
            case "sub": s.script = -1
            case "sup": s.script = 1
            case "s", "del", "strike": s.strike = true
            case "u", "ins": s.underline = true
            case "mark":
                s.mark = true
                boxes += 1
                s.box = boxes
            case "small": s.small = true
            case "span": break
            default:
                return blockElement(e, style)
            }
            walk(e.children, s)
        }

        private mutating func blockElement(_ e: HTMLFragment.Element, _ style: Style) {
            endFlow()
            let saved = block
            var s = style
            switch e["align"]?.lowercased() {
            case "center": block.align = .center
            case "right": block.align = .right
            case "left", "justify": block.align = .left
            default: if e.name == "center" { block.align = .center }
            }
            var above: CGFloat = 0, below: CGFloat = 0
            switch e.name {
            case "p":
                above = em("paragraph.spacing")
                below = above
            case let h where h.count == 2 && h.hasPrefix("h"):
                let level = Int(h.dropFirst()) ?? 1
                block.heading = level
                s.font = typography.headingFont(level: level)
                s.color = Palette.heading(level: level)
                above = em("h\(level).spaceAbove")
                below = em("h\(level).spaceBelow")
            case "blockquote":
                block.indent += typography.quoteIndent
                s.color = Palette.muted
                above = em("paragraph.spacing")
                below = above
            case "summary":
                s.bold = true
            default:
                break
            }
            open(margin: above)
            let top = y
            if e.name == "summary" {
                flow.append(NSAttributedString(string: "\u{25BE} ", attributes: attributes(Style(font: s.font, color: Palette.muted))))
                afterSpace = true
            }
            walk(e.children, s)
            endFlow()
            if block.heading > 0, typography.headingRule(level: block.heading), y > top {
                let gap = round(typography.fontSize * 0.3)
                out.marks.append(.fill(CGRect(x: block.indent, y: y + gap, width: width - block.indent, height: 1), Palette.rule))
                y += gap + 1
            }
            if e.name == "blockquote", y > top {
                out.marks.append(.fill(CGRect(x: saved.indent, y: top, width: 3, height: y - top), Palette.quote))
            }
            margin = max(margin, below)
            block = saved
        }

        /// Starts a block: the collapsed margin before it. Nothing is owed before the first content,
        /// however deeply it is nested (a first child's margin collapses through its parents).
        private mutating func open(margin above: CGFloat) {
            if started { margin = max(margin, above) }
        }

        /// Content goes at `y`: the owed margin is paid first.
        private mutating func place() {
            if started { y += margin }
            margin = 0
            started = true
        }

        // MARK: Inline content

        private mutating func text(_ t: String, _ style: Style) {
            var collapsed = ""
            for c in t {
                if c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\u{0C}" {
                    if !afterSpace { collapsed.append(" ") }
                    afterSpace = true
                } else {
                    collapsed.append(c)
                    afterSpace = false
                }
            }
            guard !collapsed.isEmpty else { return }
            flow.append(NSAttributedString(string: collapsed, attributes: attributes(style)))
        }

        private func font(_ s: Style) -> NSFont {
            var f = s.font
            if s.bold || s.italic { f = typography.withTraits(f, bold: s.bold, italic: s.italic) }
            if s.code || s.keycap { f = typography.inlineCodeFont(for: f) }
            if s.small { f = Typography.resize(f, round(f.pointSize * 0.85 * 2) / 2) }
            if s.script != 0 { f = Typography.resize(f, round(f.pointSize * 0.75 * 2) / 2) }
            return f
        }

        private func attributes(_ s: Style) -> [NSAttributedString.Key: Any] {
            let f = font(s)
            var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: s.color]
            if let link = s.link { a[.htmlLink] = link }
            if s.script != 0 {
                // Drawn with a flipped text matrix: a negative offset raises the glyphs.
                a[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] = s.script > 0 ? -round(s.font.pointSize * 0.35) : round(s.font.pointSize * 0.15)
            }
            if s.code || s.keycap || s.mark { a[.htmlBox] = (s.keycap ? "keycap:" : (s.code ? "code:" : "mark:")) + String(s.box) }
            if s.underline || s.strike { a[.htmlLine] = s.strike ? "strike" : "underline" }
            if s.keycap || s.code { a[.kern] = 0.5 }
            return a
        }

        /// `<picture>`: the `<source>` for the current appearance, else its `<img>`.
        private func picture(_ e: HTMLFragment.Element) -> HTMLFragment.Element? {
            let children = e.children.compactMap { node -> HTMLFragment.Element? in
                if case let .element(c) = node { return c }
                return nil
            }
            guard var img = children.first(where: { $0.name == "img" }) else { return nil }
            let scheme = dark ? "dark" : "light"
            if let source = children.first(where: { $0.name == "source" && ($0["media"] ?? "").replacingOccurrences(of: " ", with: "").contains("prefers-color-scheme:" + scheme) }),
               let first = source["srcset"]?.split(separator: ",").first?.split(separator: " ").first {
                img.attributes["src"] = String(first)
            }
            return img
        }

        private mutating func addImage(_ e: HTMLFragment.Element, _ style: Style) {
            guard let source = e["src"], !source.isEmpty else { return }
            let alt = e["alt"] ?? ""
            let picture = image(source, alt)
            let available = max(20, width - block.indent)
            let size = Self.size(of: e, picture, available: available, fontSize: typography.fontSize)
            // Centered on the x-height of the text around it (CSS `vertical-align: middle`).
            let f = font(style)
            let ascent = min(size.height, round(size.height / 2 + f.xHeight / 2))
            flowImages.append((picture, size, ascent))
            var a = attributes(style)
            a[.htmlImage] = flowImages.count - 1
            a[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = RunSize.delegate(width: size.width, ascent: ascent, descent: size.height - ascent)
            flow.append(NSAttributedString(string: "\u{FFFC}", attributes: a))
            afterSpace = false
        }

        /// `width` and `height` in points or percent of the line; one of them follows the image's
        /// aspect ratio; nothing known yet gives the placeholder; never wider than the line.
        static func size(of e: HTMLFragment.Element, _ image: DocumentImage, available: CGFloat, fontSize: CGFloat) -> CGSize {
            func length(_ raw: String?, percentOf base: CGFloat?) -> CGFloat? {
                guard var v = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return nil }
                if v.hasSuffix("%") {
                    guard let base, let p = Double(v.dropLast()), p.isFinite, p > 0 else { return nil }
                    return min(base * CGFloat(p) / 100, ImageCache.maximumSide)
                }
                if v.hasSuffix("px") { v.removeLast(2) }
                guard let n = Double(v), n.isFinite, n > 0 else { return nil }
                return min(CGFloat(n), ImageCache.maximumSide)
            }
            let w = length(e["width"], percentOf: available), h = length(e["height"], percentOf: nil)
            let natural = image.naturalSize
            let placeholder = image.placeholderSize(fontSize: fontSize)
            var size: CGSize
            switch (w, h, natural) {
            case let (w?, h?, _): size = CGSize(width: w, height: h)
            case let (w?, nil, n?): size = CGSize(width: w, height: w * n.height / n.width)
            case let (nil, h?, n?): size = CGSize(width: h * n.width / n.height, height: h)
            case let (nil, nil, n?): size = n
            case let (w?, nil, nil): size = CGSize(width: w, height: placeholder.height)
            case let (nil, h?, nil): size = CGSize(width: placeholder.width, height: h)
            case (nil, nil, nil): size = placeholder
            }
            if size.width > available { size = CGSize(width: available, height: size.height * available / size.width) }
            size = ImageCache.capped(size)
            return CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        }

        // MARK: Lines

        /// Sets the current flow in lines: hard breaks first, then Core Text's line breaks.
        private mutating func endFlow() {
            defer {
                flow = NSMutableAttributedString()
                flowImages = []
                afterSpace = true
            }
            keyRoom()
            let string = flow.string as NSString
            var end = string.length
            while end > 0, string.character(at: end - 1) == 0x20 { end -= 1 }
            guard end > 0 else { return }
            place()
            let available = max(20, width - block.indent)
            var start = 0
            var previousHadImage: Bool?
            while start <= end {
                var stop = string.range(of: "\u{2028}", range: NSRange(location: start, length: end - start)).location
                if stop == NSNotFound { stop = end }
                let segment = flow.attributedSubstring(from: NSRange(location: start, length: stop - start))
                if segment.length == 0 {
                    let f = (start < flow.length ? flow.attribute(.font, at: start, effectiveRange: nil) as? NSFont : nil) ?? typography.bodyFont
                    y += typography.lineHeight(for: f, kind: block.heading > 0 ? .heading : .body)
                } else {
                    setLines(segment, available: available, previousHadImage: &previousHadImage)
                }
                start = stop + 1
            }
        }

        /// `previousHadImage` is nil before a flow's first line: rows of images get a little room
        /// between them, the first row none above it.
        /// Keys get their padding as kerning, as on the canvas (`MarkdownStyler.keyRoom`): after a
        /// space before the key, after its last character, wider when another key follows at once.
        private mutating func keyRoom() {
            let string = flow.string as NSString
            var keys: [(range: NSRange, value: String)] = []
            flow.enumerateAttribute(.htmlBox, in: NSRange(location: 0, length: flow.length)) { value, range, _ in
                if let v = value as? String, v.hasPrefix("keycap") { keys.append((range, v)) }
            }
            for (i, key) in keys.enumerated() {
                let adjacent = i + 1 < keys.count && keys[i + 1].range.location == NSMaxRange(key.range)
                let padding = MarkdownStyler.keyPadding
                flow.addAttribute(.kern, value: padding + (adjacent ? padding + MarkdownStyler.keyGap : 0), range: NSRange(location: NSMaxRange(key.range) - 1, length: 1))
                if key.range.location > 0, string.character(at: key.range.location - 1) == 0x20 {
                    flow.addAttribute(.kern, value: padding, range: NSRange(location: key.range.location - 1, length: 1))
                }
            }
        }

        private mutating func setLines(_ segment: NSAttributedString, available: CGFloat, previousHadImage: inout Bool?) {
            let typesetter = CTTypesetterCreateWithAttributedString(segment)
            var start = 0
            let n = segment.length
            while start < n {
                // A space a break leaves at the start of a line is not set.
                while start < n, (segment.string as NSString).character(at: start) == 0x20 { start += 1 }
                guard start < n else { break }
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(available))
                if count <= 0 { count = 1 }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let full = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                let lineWidth = full - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                let characters = (segment.string as NSString).substring(with: NSRange(location: start, length: count))
                let hasImage = characters.contains("\u{FFFC}")
                let hasText = characters.contains { $0 != "\u{FFFC}" && !$0.isWhitespace }
                let f = segment.attribute(.font, at: start, effectiveRange: nil) as? NSFont ?? typography.bodyFont
                let textBox = hasText ? typography.lineHeight(for: f, kind: block.heading > 0 ? .heading : .body) : 0
                let natural = ascent + descent
                let box = max(natural, textBox)
                if let previous = previousHadImage, previous || hasImage { y += 4 }
                previousHadImage = hasImage
                let x: CGFloat
                switch block.align {
                case .left: x = block.indent
                case .center: x = block.indent + max(0, (available - lineWidth) / 2).rounded()
                case .right: x = block.indent + max(0, available - lineWidth)
                }
                let baseline = (y + (box - natural) / 2 + ascent).rounded()
                out.lines.append(Line(line: line, origin: CGPoint(x: x, y: baseline)))
                collect(runs, line: line, x: x, baseline: baseline, top: y, height: box)
                y += box
                start += count
            }
        }

        /// Images, link areas and drawn decorations of one line.
        private mutating func collect(_ runs: [CTRun], line: CTLine, x: CGFloat, baseline: CGFloat, top: CGFloat, height: CGFloat) {
            var boxes: [(value: String, rect: CGRect)] = []
            defer {
                for box in boxes {
                    switch box.value.split(separator: ":").first {
                    case "keycap": out.marks.append(.box(box.rect, fill: Palette.inlineCodeBackground, stroke: Palette.rule))
                    case "code": out.marks.append(.box(box.rect, fill: Palette.inlineCodeBackground, stroke: nil))
                    default: out.marks.append(.box(box.rect, fill: Palette.accent.withAlphaComponent(0.18), stroke: nil))
                    }
                }
            }
            for run in runs {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let runWidth = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                let href = attrs[NSAttributedString.Key.htmlLink] as? String
                if let index = attrs[NSAttributedString.Key.htmlImage] as? Int, index < flowImages.count {
                    let item = flowImages[index]
                    let rect = CGRect(x: x + position.x, y: baseline - item.ascent, width: item.size.width, height: item.size.height)
                    out.images.append((rect, item.image))
                    if let href { out.links.append((rect, href)) }
                    continue
                }
                let f = attrs[NSAttributedString.Key.font] as? NSFont ?? typography.bodyFont
                let left = x + position.x
                if let href { out.links.append((CGRect(x: left, y: top, width: runWidth, height: height), href)) }
                if let value = attrs[NSAttributedString.Key.htmlBox] as? String {
                    // The kerning after a key's last character is room outside its box.
                    let room = value.hasPrefix("keycap") ? (attrs[NSAttributedString.Key.kern] as? CGFloat ?? 0) : 0
                    let rect = CGRect(x: left - 3, y: baseline - f.ascender - 1.5, width: runWidth - room + 6, height: f.ascender - f.descender + 3)
                    if let k = boxes.firstIndex(where: { $0.value == value }) { boxes[k].rect = boxes[k].rect.union(rect) } else { boxes.append((value, rect)) }
                }
                if let kind = attrs[NSAttributedString.Key.htmlLine] as? String {
                    let color = attrs[NSAttributedString.Key.foregroundColor] as? NSColor ?? Palette.text
                    let yLine = kind == "strike" ? (baseline - f.xHeight * 0.55).rounded() : baseline + max(1, round(-f.descender * 0.4))
                    out.marks.append(.fill(CGRect(x: left, y: yLine, width: runWidth, height: 1), color))
                }
            }
        }
    }
}
