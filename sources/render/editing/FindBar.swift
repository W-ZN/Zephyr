import AppKit

/// One of the Find bar's three switches: match case, whole word, regular expression. A small
/// rounded key that stays filled while it is on, drawn like the rest of the chrome (no system
/// checkbox, no system bar).
final class FindOption: NSControl {
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } }
    private let title: String
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, label: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 22))
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
        setAccessibilityValue(0)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 26), heightAnchor.constraint(equalToConstant: 22)])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        if isOn {
            Tokens.accentSoft.setFill()
            path.fill()
        } else if hovering {
            Tokens.hover.setFill()
            path.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium), .foregroundColor: isOn ? Tokens.accent : Tokens.ink2]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        isOn.toggle()
        sendAction(action, to: target)
        return true
    }
}

/// The document's Find and Replace bar: a floating flat card at the reading area's top right,
/// built from the same controls as the sidebar's search (design §8.2). It only shows state and
/// reports what the person did; `FindController` owns the search.
@MainActor
final class FindBar: SurfaceView {
    let findBox = FieldBox(placeholder: String(localized: "Find"))
    let replaceBox = FieldBox(placeholder: String(localized: "Replace"))
    let matchCase = FindOption(title: "Aa", label: String(localized: "Match Case"))
    let wholeWord = FindOption(title: "ab", label: String(localized: "Whole Word"))
    let regex = FindOption(title: ".*", label: String(localized: "Regular Expression"))
    private let count = NSTextField(labelWithString: "")
    let previous = FlatButton(symbol: "chevron.up", style: .icon)
    let next = FlatButton(symbol: "chevron.down", style: .icon)
    let close = FlatButton(symbol: "xmark", style: .icon)
    let disclosure = FlatButton(symbol: "chevron.right", style: .icon)
    let replaceOne = FlatButton(title: String(localized: "Replace"), style: .secondary)
    let replaceAll = FlatButton(title: String(localized: "All"), style: .secondary)
    private let replaceRow = NSStackView()
    private let stack = NSStackView()
    static let width: CGFloat = 440

    var isReplacing = false {
        didSet {
            replaceRow.isHidden = !isReplacing
            disclosure.symbolName = isReplacing ? "chevron.down" : "chevron.right"
            setFrameSize(NSSize(width: frame.width, height: fittingSize.height))
        }
    }

    init() {
        super.init(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.panel, elevated: true)
        pointer = .arrow
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Find and Replace"))

        let options = NSStackView(views: [matchCase, wholeWord, regex])
        options.spacing = 1
        findBox.setAccessory(options)
        findBox.field.setAccessibilityLabel(String(localized: "Find"))
        replaceBox.field.setAccessibilityLabel(String(localized: "Replace"))

        count.font = Tokens.font(12)
        count.textColor = Tokens.ink3
        count.alignment = .right
        count.lineBreakMode = .byTruncatingHead
        count.translatesAutoresizingMaskIntoConstraints = false
        count.widthAnchor.constraint(equalToConstant: 66).isActive = true
        count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        disclosure.toolTip = String(localized: "Show Replace")
        disclosure.setAccessibilityLabel(String(localized: "Show Replace"))
        previous.toolTip = String(localized: "Previous Match") + " (⇧⌘G)"
        previous.setAccessibilityLabel(String(localized: "Previous Match"))
        next.toolTip = String(localized: "Next Match") + " (⌘G)"
        next.setAccessibilityLabel(String(localized: "Next Match"))
        close.toolTip = String(localized: "Close") + " (Esc)"
        close.setAccessibilityLabel(String(localized: "Close"))
        replaceOne.toolTip = String(localized: "Replace this match")
        replaceAll.toolTip = String(localized: "Replace All")
        replaceAll.setAccessibilityLabel(String(localized: "Replace All"))

        let findRow = NSStackView(views: [disclosure, findBox, count, previous, next, close])
        findRow.spacing = 2
        findRow.alignment = .centerY
        // The replace row lines up under the find field, past the disclosure.
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 28).isActive = true
        replaceRow.setViews([indent, replaceBox, replaceOne, replaceAll], in: .leading)
        replaceRow.spacing = 4
        replaceRow.alignment = .centerY
        replaceRow.isHidden = true
        for button in [replaceOne, replaceAll] { button.setContentHuggingPriority(.required, for: .horizontal) }

        stack.setViews([findRow, replaceRow], in: .leading)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            findRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -8), findRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 8),
            replaceRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -8), replaceRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 8),
        ])
        setFrameSize(NSSize(width: Self.width, height: fittingSize.height))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// "3 of 12", "No results", or the reason the pattern fails.
    func showCount(_ text: String, problem: Bool = false) {
        count.stringValue = text
        count.textColor = problem ? Tokens.danger : Tokens.ink3
        count.setAccessibilityLabel(text)
    }

    func enableReplace(_ on: Bool) {
        disclosure.isHidden = !on
        if !on { isReplacing = false }
        replaceOne.isEnabled = on
        replaceAll.isEnabled = on
    }
}
