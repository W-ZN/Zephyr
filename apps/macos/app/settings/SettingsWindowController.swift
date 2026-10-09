import AppKit
import ZephyrCore
import ZephyrRender

/// Settings (design §8, §8.2): a web-style page with section navigation on the left and, on the
/// right, one row per setting: title and a sentence on the left, the control on the right. Changes
/// apply live; nothing needs an Apply button. Sections: General, Theme (the whole look: typefaces,
/// typography, colors and details, design §21.7), Export, and Agents (the built-in assistant and
/// terminal agents, design §10–§11).
final class SettingsWindowController: NSWindowController, NSMenuItemValidation {
    static let shared = SettingsWindowController()
    enum Tab: String, CaseIterable {
        case general, theme, export, agents

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .theme: String(localized: "Theme")
            case .export: String(localized: "Export")
            case .agents: String(localized: "Agents")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .theme: "circle.lefthalf.filled"
            case .export: "square.and.arrow.up"
            case .agents: "sparkles"
            }
        }
    }

    private let nav = NSStackView()
    private var navButtons: [Tab: SettingsNavItem] = [:]
    private let content = NSView()
    private var panes: [Tab: NSViewController] = [:]
    private var current: Tab?

    static func name(of width: Typography.TableWidth) -> String {
        switch width {
        case .fit: String(localized: "Fit Content")
        case .column: String(localized: "Column Width")
        case .window: String(localized: "Window Width")
        }
    }

    static func name(of alignment: Typography.BlockAlignment) -> String {
        switch alignment {
        case .center: String(localized: "Centered")
        case .left: String(localized: "Left")
        }
    }

    /// A family as people know it: the macOS presets by their real names.
    static func displayFamily(_ family: String) -> String {
        switch family {
        case "system": "SF Pro"
        case "serif": "New York"
        case "mono": "SF Mono"
        default: family
        }
    }

    static func name(of preset: Typography.Preset) -> String {
        switch preset {
        case .system: String(localized: "Default (SF Pro + PingFang)")
        case .serif: String(localized: "Serif (New York + Songti)")
        case .mono: String(localized: "Monospace (SF Mono)")
        }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.animationBehavior = .documentWindow
        window.title = String(localized: "Settings")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 760, height: 480)
        // Tab moves through the section list, then the page's controls (design §2 principle 6).
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        build()
        show(.general)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        if current == .export { show(.export, refresh: true) }
        super.showWindow(sender)
    }

    private func build() {
        let root = CanvasRootView()
        root.wantsLayer = true
        let side = SurfaceView(fill: Tokens.sidebar, border: nil, radius: 0)
        let sideLine = SurfaceView(fill: Tokens.line, border: nil, radius: 0)
        for v in [side, sideLine, content] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 2
        nav.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(nav)
        nav.setAccessibilityElement(true)
        nav.setAccessibilityRole(.list)
        nav.setAccessibilityLabel(String(localized: "Settings sections"))
        for tab in Tab.allCases {
            let item = SettingsNavItem(title: tab.title, symbol: tab.symbol) { [weak self] in self?.show(tab) }
            navButtons[tab] = item
            nav.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor), side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor), side.widthAnchor.constraint(equalToConstant: 200),
            sideLine.leadingAnchor.constraint(equalTo: side.trailingAnchor), sideLine.topAnchor.constraint(equalTo: root.topAnchor),
            sideLine.bottomAnchor.constraint(equalTo: root.bottomAnchor), sideLine.widthAnchor.constraint(equalToConstant: 1),
            nav.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 10), nav.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -10),
            nav.topAnchor.constraint(equalTo: side.topAnchor, constant: 52), nav.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -14),
            content.leadingAnchor.constraint(equalTo: sideLine.trailingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root
    }

    private func pane(_ tab: Tab) -> NSViewController {
        // Export choices are saved immediately; rebuild on entry to reflect theme additions or removal.
        if tab != .export, let p = panes[tab] { return p }
        let p: NSViewController
        switch tab {
        case .general: p = GeneralSettingsPane()
        case .theme: p = ThemeSettingsPane()
        case .export: p = ExportSettingsPane()
        case .agents: p = AgentsSettingsPane()
        }
        panes[tab] = p
        return p
    }

    private func show(_ tab: Tab, refresh: Bool = false) {
        guard tab != current || refresh else { return }
        current = tab
        for (t, item) in navButtons { item.selected = t == tab }
        content.subviews.forEach { $0.removeFromSuperview() }
        let view = pane(tab).view
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // A page fades in when chosen in the sidebar (not when the window opens on it).
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        view.wantsLayer = true
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            view.animator().alphaValue = 1
        }
    }

    func show(tab: Tab) {
        show(tab)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu commands (Format → Typeface, text size)

    @objc func selectTypeface(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? String else { return }
        AppearanceStore.shared.set("font.body", preset)
    }

    // ⌘+ / ⌘− zoom the active theme; each theme keeps its own zoom.
    @objc func makeTextBigger(_ sender: Any?) { adjustZoom(0.1) }
    @objc func makeTextSmaller(_ sender: Any?) { adjustZoom(-0.1) }
    @objc func makeTextStandardSize(_ sender: Any?) { AppearanceStore.shared.set("zoom", "default") }

    private func adjustZoom(_ delta: Double) {
        let current = AppearanceStore.shared.settings.number("zoom") ?? 1
        AppearanceStore.shared.set("zoom", number: min(max(current + delta, 0.75), 1.6))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTypeface(_:)) {
            menuItem.state = (menuItem.representedObject as? String) == AppearanceStore.shared.settings.string("font.body") ? .on : .off
        }
        return true
    }
}

/// One entry of the settings navigation: icon and title, hover and selected states.
final class SettingsNavItem: NSView {
    var selected = false { didSet { needsDisplay = true; restyle() } }
    private var hovering = false { didSet { needsDisplay = true } }
    private let icon = NSImageView()
    private let label: NSTextField
    private let symbol: String
    private let action: () -> Void

    init(title: String, symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
        label = flatLabel(title, size: 13)
        super.init(frame: .zero)
        let row = NSStackView(views: [icon, label])
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 32),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        icon.image = Tokens.symbol(symbol, size: 13, weight: selected ? .semibold : .regular, color: selected ? Tokens.accent : Tokens.ink2)
        label.textColor = selected ? Tokens.ink : Tokens.ink2
        label.font = Tokens.font(13, selected ? .semibold : .regular)
        setAccessibilitySelected(selected)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    // Keyboard: Tab reaches each section, Space or Return opens it, ↑ ↓ move to the neighbor.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        guard FocusRing.isKeyboard else { return }
        NSBezierPath(roundedRect: bounds, xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?, .downArrow?:
            let items = superview?.subviews.compactMap { $0 as? SettingsNavItem } ?? []
            guard let i = items.firstIndex(of: self) else { return }
            let next = items[(i + (event.specialKey == .upArrow ? items.count - 1 : 1)) % items.count]
            window?.makeFirstResponder(next)
            next.action()
        case .carriageReturn?, .enter?: action()
        default:
            if event.charactersIgnoringModifiers == " " { action() } else { super.keyDown(with: event) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Tokens.sidebar.setFill()
        bounds.fill()
        guard hovering else { return }
        Tokens.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Tokens.Radius.control + 1, yRadius: Tokens.Radius.control + 1).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

// MARK: - Page layout

/// A settings page: a title and a short description, then sections of rows separated by
/// hairlines, in a scroll view so long sections stay usable on small screens. Controls made by
/// the `…Control` builders are bound to one appearance key each: they write it on change and
/// read it back whenever the settings change, from here or from outside (`zephyr config`).
class SettingsPage: NSViewController {
    var rowPadding: CGFloat { 13 }
    var sectionSpacing: CGFloat { 34 }
    let rows = NSStackView()
    private var syncers: [() -> Void] = []
    private var scroll: NSScrollView?
    private var ruleBeforeNextRow = false
    private var groupRows: NSStackView?
    private var destination: NSStackView { groupRows ?? rows }
    var store: AppearanceStore { .shared }

    func build(title: String, subtitle: String? = nil) {
        let heading = flatLabel(title, size: 22, weight: .bold)
        let sub = flatLabel(subtitle ?? "", size: 13, color: Tokens.ink2, wraps: true)
        sub.isHidden = subtitle == nil
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        let column = NSStackView(views: [heading, sub, rows])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.setCustomSpacing(10, after: sub)
        column.edgeInsets = NSEdgeInsets(top: 46, left: 40, bottom: 40, right: 40)
        column.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor), column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor), column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            rows.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -80),
            sub.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -80),
        ])
        view = scroll
        self.scroll = scroll
        NotificationCenter.default.addObserver(self, selector: #selector(syncAll), name: AppearanceStore.didChange, object: nil)
    }

    /// Rebuild the rows with `content`, keeping the scroll position (a page whose rows depend on
    /// a choice, such as preset or custom theme).
    func rebuild(_ content: () -> Void) {
        let origin = scroll?.contentView.bounds.origin
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        syncers = []
        ruleBeforeNextRow = false
        content()
        view.layoutSubtreeIfNeeded()
        if let origin, let scroll {
            let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// A quiet label that splits a group into parts (Tables, Diagrams); rows below it start without
    /// a rule.
    func addSubheading(_ title: String) {
        let label = flatLabel(title, size: 12, weight: .semibold, color: Tokens.ink2)
        let stack = NSStackView(views: [label])
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 2, right: 0)
        destination.addArrangedSubview(stack)
        stack.widthAnchor.constraint(equalTo: destination.widthAnchor).isActive = true
        ruleBeforeNextRow = false
    }

    /// A group of rows under a heading. The first row of a section has no rule above it.
    func addSection(_ title: String, _ detail: String? = nil) {
        let rows = destination
        let label = flatLabel(title, size: 15, weight: .semibold)
        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        if let detail {
            let d = flatLabel(detail, size: 12, color: Tokens.ink3, wraps: true)
            stack.addArrangedSubview(d)
            d.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        stack.edgeInsets = NSEdgeInsets(top: rows.arrangedSubviews.isEmpty ? 14 : sectionSpacing, left: 0, bottom: 4, right: 0)
        rows.addArrangedSubview(stack)
        stack.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        ruleBeforeNextRow = false
    }

    /// A row: title and description on the left, the control on the right. `below` puts a wide
    /// control under the text instead.
    @discardableResult
    func addRow(_ title: String, _ detail: String?, detailLabel: NSTextField? = nil, control: NSView?, below: NSView? = nil) -> NSView {
        let rows = destination
        let name = flatLabel(title, size: 13, weight: .medium)
        let text = NSStackView(views: [name])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        // A label the page keeps and rewrites (an example that follows the provider).
        if detail != nil || detailLabel != nil {
            let d = detailLabel ?? flatLabel(detail ?? "", size: 12, color: Tokens.ink2, wraps: true)
            // Beside a small control (a Copy button) the sentence may take more of the row.
            d.preferredMaxLayoutWidth = control.map { min(440, max(180, 548 - $0.fittingSize.width)) } ?? 600
            text.addArrangedSubview(d)
        }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [text])
        line.alignment = .centerY
        line.spacing = 24
        if let control {
            // Every control sits on the row's right edge, whatever the length of its title.
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            line.addArrangedSubview(spacer)
            control.setContentHuggingPriority(.required, for: .horizontal)
            line.addArrangedSubview(control)
            Self.label(control, title: title, help: detail)
        }
        let block = NSStackView(views: [line])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 12
        block.edgeInsets = NSEdgeInsets(top: rowPadding, left: 0, bottom: rowPadding, right: 0)
        line.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        if let below {
            block.addArrangedSubview(below)
            below.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        }
        // The rule above a row belongs to it, so hiding a row (a provider's fields) hides its rule too.
        var row: NSView = block
        if ruleBeforeNextRow {
            let rule = SurfaceView(fill: Tokens.line, border: nil, radius: 0)
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
            let stack = NSStackView(views: [rule, block])
            stack.orientation = .vertical
            stack.spacing = 0
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            block.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row = stack
        }
        ruleBeforeNextRow = true
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        return row
    }

    /// Build a group's controls only when first opened; collapsing keeps edits and focus order.
    func addDisclosure(_ title: String, expanded: Bool, onToggle: @escaping (Bool) -> Void, content: @escaping () -> Void) {
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.isHidden = !expanded
        var toggle: (() -> Void)?
        let button = FlatButton(title: title, symbol: expanded ? "chevron.down" : "chevron.right", style: .heading) { toggle?() }
        button.alignment = .left
        button.titleFont = Tokens.font(14, .semibold)
        button.setAccessibilityLabel(title)
        button.setAccessibilityExpanded(expanded)
        let group = NSStackView(views: [button, body])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        group.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 12, right: 0)
        for child in [button, body] { child.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
        let rule = SurfaceView(fill: Tokens.line, border: nil, radius: 0)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rows.addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        rows.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        var built = false
        let populate = { [weak self, weak body] in
            guard let self, let body, !built else { return }
            built = true
            let previous = self.groupRows, rule = self.ruleBeforeNextRow
            self.groupRows = body
            self.ruleBeforeNextRow = false
            content()
            self.groupRows = previous
            self.ruleBeforeNextRow = rule
        }
        toggle = { [weak self, weak body, weak button] in
            guard let self, let body, let button else { return }
            let open = body.isHidden
            if open { populate() }
            body.isHidden = !open
            button.symbolName = open ? "chevron.down" : "chevron.right"
            button.setAccessibilityExpanded(open)
            onToggle(open)
            self.view.layoutSubtreeIfNeeded()
        }
        if expanded { populate() }
        ruleBeforeNextRow = false
    }

    /// The interactive leaves under `view` take the row's title as their name (VoiceOver reads
    /// "Minimal mode, checkbox", not an unnamed control) and its sentence as help.
    static func label(_ view: NSView, title: String, help: String?) {
        if let field = view as? NSTextField, !field.isEditable { return }   // a value readout, not the control
        if view is NSControl || view.isAccessibilityElement() {
            if (view.accessibilityLabel() ?? "").isEmpty { view.setAccessibilityLabel(title) }
            if let help { view.setAccessibilityHelp(help) }
            return
        }
        view.subviews.forEach { label($0, title: title, help: help) }
    }

    // MARK: Bound controls

    /// Run `sync` now and after every settings change.
    func bind(_ sync: @escaping () -> Void) {
        syncers.append(sync)
        sync()
    }

    @objc func syncAll() { syncers.forEach { $0() } }

    /// A slider and its value for a number key. `auto` gives the value shown while the key is unset.
    func numberControl(_ key: @escaping () -> String, auto: (() -> Double)? = nil, width: CGFloat = 180) -> NSView {
        let slider = NSSlider.flat(value: 0, min: 0, max: 1)
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = Tokens.ink2
        label.alignment = .right
        slider.widthAnchor.constraint(equalToConstant: width).isActive = true
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let action = ClosureTarget { [weak self, weak slider] in
            guard let self, let slider, let spec = AppearanceSettings.spec(key()), case let .number(_, _, step, _) = spec.kind else { return }
            self.store.set(key(), number: (slider.doubleValue / step).rounded() * step)
        }
        slider.target = action
        slider.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(slider, &ClosureTarget.key, action, .OBJC_ASSOCIATION_RETAIN)
        bind { [weak self, weak slider, weak label] in
            guard let self, let slider, let label, let spec = AppearanceSettings.spec(key()), case let .number(min, max, _, unit) = spec.kind else { return }
            slider.minValue = min
            slider.maxValue = max
            let set = self.store.settings.number(key())
            let value = set ?? auto?() ?? min
            slider.doubleValue = value
            label.stringValue = (key() == "zoom" ? "\(Int((value * 100).rounded()))%" : Self.format(value, unit: unit)) + (set == nil && spec.defaultValue == nil ? " · " + String(localized: "auto") : "")
        }
        let box = NSStackView(views: [slider, label])
        box.spacing = 10
        return box
    }

    /// Segments for a choice key, in the order and with the titles given. `number` keys are
    /// whole numbers shown as choices (the first numbered heading level).
    func choiceControl(_ key: @escaping () -> String, _ choices: [(value: String, title: String)], number: Bool = false) -> SegmentedPicker {
        let picker = SegmentedPicker(items: choices.map(\.title))
        picker.onChange = { [weak self] i in self?.store.set(key(), choices[i].value) }
        bind { [weak self, weak picker] in
            guard let self, let picker else { return }
            let current = number ? self.store.settings.number(key()).map { String(Int($0)) } ?? "" : self.store.settings.string(key())
            picker.selectedIndex = choices.firstIndex { $0.value == current } ?? 0
        }
        return picker
    }

    func flagControl(_ key: String) -> FlatToggle {
        let toggle = FlatToggle()
        toggle.onChange = { [weak self] on in self?.store.set(key, on ? "true" : "false") }
        bind { [weak self, weak toggle] in toggle?.isOn = self?.store.settings.flag(key) ?? false }
        return toggle
    }

    /// A pop-up of the font presets and the installed families for a font key.
    func fontControl(_ key: String, presets: [(value: String, title: String)], families: [String] = NSFontManager.shared.availableFontFamilies, resolved: (() -> String)? = nil) -> FlatPopUpButton {
        let popup = FlatPopUpButton()
        let search = ClosureMenuItem(title: String(localized: "Search Fonts…", table: "Fonts")) { [weak self, weak popup] in
            guard let self, let popup else { return }
            let value = self.store.settings.string(key)
            let shown = resolved?() ?? AppearanceSettings.families(value).first(where: { families.contains($0) }) ?? value
            // Opening search is not a font choice; cancellation keeps the original menu selection.
            if let item = popup.itemArray.first(where: { $0.representedObject as? String == value }) ?? popup.itemArray.first(where: { $0.representedObject as? String == shown }) ?? popup.itemArray.first(where: { $0.representedObject is String }) { popup.select(item) }
            let scope: FontCatalog.Scope = key == "font.cjk" ? .chinese : key == "font.code" ? .monospaced : .all
            FontChooser.present(from: popup, scope: scope, selected: shown) { [weak self, weak popup] family in
                if popup?.itemArray.contains(where: { $0.representedObject as? String == family }) == false {
                    popup?.addItem(withTitle: FontCatalog.displayName(for: family))
                    popup?.lastItem?.representedObject = family
                }
                self?.store.set(key, family)
            }
        }
        popup.menu?.addItem(search)
        popup.menu?.addItem(.separator())
        for p in presets { popup.addItem(withTitle: p.title); popup.lastItem?.representedObject = p.value }
        popup.menu?.addItem(.separator())
        for family in families where !family.hasPrefix(".") {
            popup.addItem(withTitle: FontCatalog.displayName(for: family))
            popup.lastItem?.representedObject = family
        }
        let action = ClosureTarget { [weak self, weak popup] in
            guard let value = popup?.selectedItem?.representedObject as? String else { return }
            self?.store.set(key, value)
        }
        popup.target = action
        popup.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(popup, &ClosureTarget.key, action, .OBJC_ASSOCIATION_RETAIN)
        popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        bind { [weak self, weak popup] in
            guard let self, let popup else { return }
            // A list ("Newsreader, Charter, serif") shows the family in use.
            let value = self.store.settings.string(key)
            let shown = resolved?() ?? AppearanceSettings.families(value).first(where: { families.contains($0) }) ?? value
            if let item = popup.itemArray.first(where: { $0.representedObject as? String == value }) ?? popup.itemArray.first(where: { $0.representedObject as? String == shown }) ?? popup.itemArray.first(where: { $0.representedObject is String }) {
                popup.select(item)
            }
            popup.needsDisplay = true
        }
        return popup
    }

    static func format(_ value: Double, unit: String) -> String {
        let trimmed = value == value.rounded() ? String(Int(value)) : String(format: value * 100 == (value * 100).rounded() ? "%g" : "%.2f", value)
        switch unit {
        case "pt": return "\(trimmed) pt"
        case "em": return "\(trimmed) em"
        case "×": return String(format: "%.2f", value)
        case "characters": return String(localized: "\(Int(value)) characters")
        case "": return trimmed
        default: return "\(trimmed) \(unit)"
        }
    }
}

/// A closure as a target/action pair, for controls built in loops.
final class ClosureTarget: NSObject {
    nonisolated(unsafe) static var key = 0
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run() { body() }
}

/// A read-only live sample of the canvas inside a settings page. It never takes the mouse, so the
/// page scrolls over it.
final class PreviewBox: SurfaceView {
    let editor: MarkdownEditor

    init(_ markdown: String, height: CGFloat) {
        editor = MarkdownEditor(text: markdown, typography: AppearanceStore.shared.typography, baseURL: nil, isEditable: false)
        // A framed window onto a document: set apart from the controls below it at a glance.
        super.init(fill: Tokens.canvas, border: Tokens.ink3.withAlphaComponent(0.45), radius: 8)
        let scroll = editor.scrollView
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            heightAnchor.constraint(equalToConstant: height),
        ])
        layer?.masksToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AppearanceStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func refresh() { editor.apply(typography: AppearanceStore.shared.typography) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - General

final class GeneralSettingsPane: SettingsPage {
    override var rowPadding: CGFloat { 8 }
    override var sectionSpacing: CGFloat { 20 }
    /// The language of menus and windows: the system's, or one Zephyr is translated into.
    static let languages: [(code: String?, title: String)] = [(nil, String(localized: "Same as System")), ("en", "English"), ("zh-Hans", "简体中文")]

    /// The app's own choice (`AppleLanguages` in its domain), nil when it follows the system.
    static var language: String? {
        get { (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first }
        set { if let newValue { UserDefaults.standard.set([newValue], forKey: "AppleLanguages") } else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") } }
    }

    override func loadView() {
        build(title: String(localized: "General"))
        let d = UserDefaults.standard
        addSection(String(localized: "Window"))
        addRow(String(localized: "Minimal mode"), String(localized: "Hide everything but the text. ⌃⌘M"),
               control: FlatToggle(isOn: d.bool(forKey: Preferences.minimalMode)) { on in
                   d.set(on, forKey: Preferences.minimalMode)
                   DocumentWindowController.applyMinimalMode()
               })
        addRow(String(localized: "Assistant button"), String(localized: "⌘J opens the assistant either way."),
               control: FlatToggle(isOn: !d.bool(forKey: Preferences.aiButtonHidden)) { on in
                   d.set(!on, forKey: Preferences.aiButtonHidden)
                   DocumentWindowController.applyAIButton()
               })
        addRow(String(localized: "Quick switcher"), String(localized: "With the sidebar hidden, a window's open documents show as dots on its left edge; point at them to switch or close."),
               control: FlatToggle(isOn: d.bool(forKey: Preferences.quickSwitcher)) { on in
                   d.set(on, forKey: Preferences.quickSwitcher)
                   DocumentWindowController.applyQuickSwitcher()
               })

        addSection(String(localized: "Outline"))
        let place = SegmentedPicker(items: [String(localized: "Beside the Text"), String(localized: "In the Top Bar")])
        place.selectedIndex = Preferences.outlineBesideText ? 0 : 1
        place.onChange = { i in
            Preferences.outlineBesideText = i == 0
            DocumentWindowController.applyOutline()
        }
        addRow(String(localized: "Position"), nil, control: place)
        let depth = SegmentedPicker(items: (1...6).map(String.init))
        depth.selectedIndex = Preferences.outlineDepth - 1
        depth.onChange = { i in
            Preferences.outlineDepth = i + 1
            DocumentWindowController.applyOutline()
        }
        addRow(String(localized: "Levels"), nil, control: depth)

        addSection(String(localized: "Documents"))
        let defaultStatus = flatLabel(MarkdownIntegration.defaultDescription, size: 12, color: Tokens.ink2, wraps: true)
        let defaultButton = FlatButton(title: String(localized: "Set as Default"), style: .secondary)
        defaultButton.isEnabled = !MarkdownIntegration.isDefault
        let defaultAction = ClosureTarget { [weak defaultButton, weak defaultStatus] in
            defaultButton?.isEnabled = false
            Task { @MainActor in
                do {
                    try await MarkdownIntegration.setDefault()
                    try await MarkdownIntegration.enablePreview()
                } catch { NSApp.presentError(error) }
                defaultStatus?.stringValue = MarkdownIntegration.defaultDescription
                defaultButton?.isEnabled = !MarkdownIntegration.isDefault
            }
        }
        defaultButton.target = defaultAction
        defaultButton.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(defaultButton, &ClosureTarget.key, defaultAction, .OBJC_ASSOCIATION_RETAIN)
        addRow(String(localized: "Default Markdown editor"), nil, detailLabel: defaultStatus, control: defaultButton)
        let previewStatus = flatLabel(String(localized: "Finder's Space-bar preview uses the Zephyr Quick Look extension."), size: 12, color: Tokens.ink2, wraps: true)
        let previewButton = FlatButton(title: String(localized: "Enable Preview"), style: .secondary)
        let previewAction = ClosureTarget { [weak previewButton, weak previewStatus] in
            previewButton?.isEnabled = false
            Task { @MainActor in
                do {
                    try await MarkdownIntegration.enablePreview()
                    previewStatus?.stringValue = String(localized: "Zephyr preview enabled. Select a Markdown file in Finder and press Space.")
                } catch { NSApp.presentError(error) }
                previewButton?.isEnabled = true
            }
        }
        previewButton.target = previewAction
        previewButton.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(previewButton, &ClosureTarget.key, previewAction, .OBJC_ASSOCIATION_RETAIN)
        addRow(String(localized: "Finder preview"), nil, detailLabel: previewStatus, control: previewButton)
        addRow(String(localized: "Collapse properties"), String(localized: "The YAML front matter at the top."),
               control: FlatToggle(isOn: d.bool(forKey: Preferences.frontMatterCollapsed)) { on in
                   d.set(on, forKey: Preferences.frontMatterCollapsed)
                   NotificationCenter.default.post(name: Preferences.frontMatterDidChange, object: nil)
               })
        addRow(String(localized: "Remote images"), String(localized: "Show images from the web, such as a README's badges. Off, click an image to show a document's."),
               control: FlatToggle(isOn: d.bool(forKey: Preferences.remoteImages)) { on in
                   d.set(on, forKey: Preferences.remoteImages)
                   NotificationCenter.default.post(name: Preferences.remoteImagesDidChange, object: nil)
               })
        addRow(String(localized: "Link previews"), String(localized: "Pause over a link to preview Markdown, PDF or a web page."),
               control: FlatToggle(isOn: d.bool(forKey: Preferences.linkPreviews)) { on in d.set(on, forKey: Preferences.linkPreviews) })
        let delay = FlatPopUpButton()
        for seconds in [0.5, 0.8, 1.5, 2.0] {
            delay.addItem(withTitle: String(localized: "\(seconds.formatted()) seconds"))
            delay.lastItem?.representedObject = seconds
        }
        delay.selectItem(at: [0.5, 0.8, 1.5, 2.0].firstIndex(of: d.double(forKey: Preferences.linkPreviewDelay)) ?? 1)
        let delayTarget = ClosureTarget { [weak delay] in
            if let seconds = delay?.selectedItem?.representedObject as? Double { d.set(seconds, forKey: Preferences.linkPreviewDelay) }
        }
        delay.target = delayTarget
        delay.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(delay, &ClosureTarget.key, delayTarget, .OBJC_ASSOCIATION_RETAIN)
        addRow(String(localized: "Preview delay"), nil, control: delay)

        addSection(String(localized: "App"))
        let language = FlatPopUpButton()
        for choice in Self.languages {
            language.addItem(withTitle: choice.title)
            language.lastItem?.representedObject = choice.code
        }
        language.selectItem(at: Self.languages.firstIndex { $0.code == Self.language } ?? 0)
        let restart = FlatButton(title: String(localized: "Restart Now"), style: .secondary) { Self.restart() }
        restart.isHidden = true
        let pick = ClosureTarget { [weak language] in
            Self.language = language?.selectedItem?.representedObject as? String
            restart.isHidden = false
        }
        language.target = pick
        language.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(language, &ClosureTarget.key, pick, .OBJC_ASSOCIATION_RETAIN)
        let languageControls = NSStackView(views: [restart, language])
        languageControls.spacing = 8
        addRow(String(localized: "Language"), String(localized: "Applies after a restart."), control: languageControls)
        addRow(String(localized: "Quit with the last window"), nil,
               control: FlatToggle(isOn: d.bool(forKey: Preferences.quitWithLastWindow)) { on in d.set(on, forKey: Preferences.quitWithLastWindow) })
    }

    /// Quits (documents are saved or reviewed as usual) and opens Zephyr again once it has gone;
    /// if the quit is cancelled, nothing reopens.
    static func restart() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "for i in $(seq 1 150); do kill -0 \(pid) 2>/dev/null || exec /usr/bin/open \"$0\"; sleep 0.2; done", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// A typeface choice shown in its own face: "Aa 文字" above the name.
final class TypefaceCard: NSView {
    var selected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private let preset: Typography.Preset
    private let action: () -> Void

    init(preset: Typography.Preset, action: @escaping () -> Void) {
        self.preset = preset
        self.action = action
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 92).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(SettingsWindowController.name(of: preset))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        (hovering && !selected ? Tokens.sunken : Tokens.raised).setFill()
        path.fill()
        (selected ? Tokens.accent : Tokens.line).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
        var settings = AppearanceSettings()
        _ = try? settings.set("font.body", preset.rawValue)
        _ = try? settings.set("text.size", "22")
        let font = Typography(settings).bodyFont
        let sample = NSAttributedString(string: "Aa 文字", attributes: [.font: font, .foregroundColor: Tokens.ink])
        let s = sample.size()
        sample.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.maxY - 22 - s.height))
        let name = NSAttributedString(string: SettingsWindowController.name(of: preset), attributes: [.font: Tokens.font(11), .foregroundColor: selected ? Tokens.accent : Tokens.ink2])
        let n = name.size()
        name.draw(with: NSRect(x: max(8, bounds.midX - n.width / 2), y: 12, width: min(n.width, bounds.width - 16), height: n.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
    override func accessibilityValue() -> Any? { selected ? 1 : 0 }

    // Keyboard: Space chooses, ← → move to the neighboring typeface.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        guard FocusRing.isKeyboard else { return }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?, .rightArrow?:
            let cards = superview?.subviews.compactMap { $0 as? TypefaceCard } ?? []
            guard let i = cards.firstIndex(of: self) else { return }
            let j = i + (event.specialKey == .leftArrow ? -1 : 1)
            guard cards.indices.contains(j) else { return }
            window?.makeFirstResponder(cards[j])
            cards[j].action()
        case .carriageReturn?, .enter?: action()
        default:
            if event.charactersIgnoringModifiers == " " { action() } else { super.keyDown(with: event) }
        }
    }
}
