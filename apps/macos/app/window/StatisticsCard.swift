import AppKit
import ZephyrCore
import ZephyrRender

/// The count in the top bar (design §8): characters by default, words or paragraphs by choice
/// (an app preference); a selection shows its own count. Prose only: code, formulas and diagrams
/// are not counted (`TextStatistics`).
enum StatisticsMetric: String, CaseIterable {
    case characters, words, paragraphs

    static var current: StatisticsMetric {
        get { UserDefaults.standard.string(forKey: Preferences.statisticsMetric).flatMap(Self.init) ?? .characters }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Preferences.statisticsMetric) }
    }

    func value(_ s: TextStatistics) -> Int {
        switch self {
        case .characters: s.characters
        case .words: s.words
        case .paragraphs: s.paragraphs
        }
    }

    func label(_ n: Int) -> String {
        let count = StatisticsCard.number(n)
        switch self {
        case .characters: return n == 1 ? String(localized: "1 char") : String(localized: "\(count) chars")
        case .words: return n == 1 ? String(localized: "1 word") : String(localized: "\(count) words")
        case .paragraphs: return n == 1 ? String(localized: "1 paragraph") : String(localized: "\(count) paragraphs")
        }
    }

    /// The top bar's text: the document's count, or the selection's.
    static func chip(document: TextStatistics, selection: TextStatistics?) -> String {
        let metric = current
        guard let selection else { return metric.label(metric.value(document)) }
        return String(localized: "Selected \(metric.label(metric.value(selection)))")
    }
}

/// The card under the count. On top, the three counts the top bar can show, as choices: the one it
/// shows is checked, a click on another puts that one there. Below a line, figures to read only.
/// A selection's figures sit beside the document's.
final class StatisticsCard: NSView {
    private let rows = NSStackView()
    private var document = TextStatistics()
    private var selection: TextStatistics?
    var onChoose: (() -> Void)?

    static func number(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    static func minutes(_ m: Double) -> String {
        if m <= 0 { return "0" }
        if m < 1 { return String(localized: "<1 min") }
        return String(localized: "\(Int(m.rounded(.up))) min")
    }

    init() {
        super.init(frame: .zero)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        let title = flatLabel(String(localized: "Show in the top bar"), size: 11, weight: .medium, color: Tokens.ink3)
        let note = flatLabel(String(localized: "Excludes code, formulas and diagrams."), size: 11, color: Tokens.ink3)
        let stack = NSStackView(views: [title, rows, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 6, bottom: 12, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for v in [title, note, rows] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            title.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            note.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(document: TextStatistics, selection: TextStatistics?) {
        self.document = document
        self.selection = selection
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let chosen = StatisticsMetric.current
        if selection != nil {
            rows.addArrangedSubview(StatisticsRow(title: "", values: [String(localized: "Selection"), String(localized: "Document")], header: true))
        }
        let choices: [(String, StatisticsMetric, (TextStatistics) -> String)] = [
            (String(localized: "Characters"), .characters, { Self.number($0.characters) }),
            (String(localized: "Words"), .words, { Self.number($0.words) }),
            (String(localized: "Paragraphs"), .paragraphs, { Self.number($0.paragraphs) }),
        ]
        let figures: [(String, (TextStatistics) -> String)] = [
            (String(localized: "Characters with spaces"), { Self.number($0.charactersWithSpaces) }),
            (String(localized: "Headings"), { Self.number($0.headings) }),
            (String(localized: "Reading time"), { Self.minutes($0.readingMinutes) }),
        ]
        let counted = [selection].compactMap { $0 } + [document]
        for (name, metric, value) in choices {
            let row = StatisticsRow(title: name, values: counted.map(value), checked: metric == chosen)
            row.action = { [weak self] in
                StatisticsMetric.current = metric
                self?.onChoose?()
                if let self { self.show(document: self.document, selection: self.selection) }
            }
            rows.addArrangedSubview(row)
        }
        let rule = SurfaceView(fill: Tokens.line, border: nil, radius: 0)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let ruleRow = NSView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        ruleRow.addSubview(rule)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: ruleRow.leadingAnchor, constant: 8), rule.trailingAnchor.constraint(equalTo: ruleRow.trailingAnchor, constant: -8),
            rule.centerYAnchor.constraint(equalTo: ruleRow.centerYAnchor), ruleRow.heightAnchor.constraint(equalToConstant: 13),
        ])
        rows.addArrangedSubview(ruleRow)
        for (name, value) in figures { rows.addArrangedSubview(StatisticsRow(title: name, values: counted.map(value))) }
        for row in rows.arrangedSubviews { row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
    }
}

/// One line of the card: the name and right-aligned figures in fixed columns. A choice has a radio
/// mark (filled when the top bar shows it) and highlights under the pointer; a figure has none and
/// a quieter name.
private final class StatisticsRow: NSView {
    var action: (() -> Void)? {
        didSet {
            setAccessibilityRole(action == nil ? .group : .radioButton)
            // Tinted as a template, so the check stays cut out of the filled circle.
            check.image = Tokens.symbol(checked ? "checkmark.circle.fill" : "circle", size: 12, weight: .regular)
            check.contentTintColor = checked ? Tokens.accent : Tokens.ink3
            name.textColor = Tokens.ink
        }
    }
    private var hovering = false { didSet { needsDisplay = true } }
    private let check = NSImageView()
    private let name: NSTextField
    private let checked: Bool
    static let column: CGFloat = 76

    init(title: String, values: [String], checked: Bool = false, header: Bool = false) {
        self.checked = checked
        name = flatLabel(title, size: 13, color: header ? Tokens.ink : Tokens.ink2)
        super.init(frame: .zero)
        var views: [NSView] = [check, name]
        var trailing = trailingAnchor
        var constraints = [
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 4), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: header ? 20 : 28),
        ]
        for (k, value) in values.reversed().enumerated() {
            let field = header ? flatLabel(value, size: 11, weight: .medium, color: Tokens.ink3) : flatLabel(value, size: 13, color: Tokens.ink)
            if !header { field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular) }
            field.alignment = .right
            views.append(field)
            constraints += [field.trailingAnchor.constraint(equalTo: trailing, constant: k == 0 ? -10 : -12),
                            field.widthAnchor.constraint(equalToConstant: Self.column), field.centerYAnchor.constraint(equalTo: centerYAnchor)]
            trailing = field.leadingAnchor
        }
        constraints.append(name.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -12))
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(!header)
        setAccessibilityRole(.group)
        setAccessibilityLabel(([title] + values).joined(separator: ", "))
        if checked { setAccessibilityValue(1) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, action != nil else { return }
        Tokens.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { action?() }
    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        action()
        return true
    }
}
