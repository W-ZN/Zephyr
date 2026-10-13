import AppKit
import ZephyrCore
import ZephyrRender

/// Settings → Theme (design §8, §21.7). A theme is the whole look, and each one keeps all of its
/// settings: typefaces, light or dark, zoom, typography, colors, and the details of code,
/// formulas, numbering, tables and diagrams. Every setting below changes the theme selected
/// above. A built-in theme keeps the changes on top of what it ships with (marked Modified, with
/// Restore Defaults); Save as New Theme turns the look into a theme of the reader's own, a file
/// in a folder of their choice.
final class ThemeSettingsPane: SettingsPage, NSTextViewDelegate {
    /// The heading level the level controls edit, and the appearance the color chips edit
    /// (view state, not settings).
    private var level = 2
    private var colorMode = "light"
    private var shownTheme: String?
    private var shownNames: [String] = []
    private let cssEditor = NSTextView()
    private let cssSummary = flatLabel("", size: 12, weight: .medium)
    private let cssDetails = flatLabel("", size: 11.5, color: Tokens.ink2, wraps: true)
    private var cssPending: DispatchWorkItem?
    /// Disclosure state belongs to this settings window, not to the saved theme.
    private var expandedGroups = Set<String>()
    private var installedFontFamilies: [String]?
    private var chineseFontFamilies: [String]?

    static let headingScales: [(String, Double)] = [(String(localized: "Compact"), 0.7), (String(localized: "Standard"), 1.0), (String(localized: "Prominent"), 1.3)]

    static let cssExample = """
    body { line-height: 1.75; }
    p { text-indent: 2em; }
    h1 { font-size: 2.2em; margin-top: 3em; }
    th { background: #eef6f6; }
    a { color: #0a6e73; }

    @media (prefers-color-scheme: dark) {
      a { color: #5cc8c8; }
      th { background: #1d2a2a; }
    }
    """

    /// Open-source families the presets name first, and where to get them.
    static let fontPages: [String: String] = [
        "Newsreader": "https://fonts.google.com/specimen/Newsreader",
        "Source Serif 4": "https://fonts.google.com/specimen/Source+Serif+4",
        "Noto Serif SC": "https://fonts.google.com/noto/specimen/Noto+Serif+SC",
        "IBM Plex Mono": "https://fonts.google.com/specimen/IBM+Plex+Mono",
        "JetBrains Mono": "https://www.jetbrains.com/lp/mono/",
        "Fira Code": "https://github.com/tonsky/FiraCode",
        "Source Code Pro": "https://fonts.google.com/specimen/Source+Code+Pro",
        "Cascadia Code": "https://github.com/microsoft/cascadia-code",
    ]

    /// Open-source code families offered for code even before they are installed.
    static let codeFamilies = ["JetBrains Mono", "IBM Plex Mono", "Fira Code", "Source Code Pro", "Cascadia Code"]

    override func loadView() {
        build(title: String(localized: "Theme"))
        colorMode = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        compose()
        NotificationCenter.default.addObserver(self, selector: #selector(themeMaybeChanged), name: AppearanceStore.didChange, object: nil)
    }

    /// The page is rebuilt when the theme or the list of themes changes; values sync in place.
    @objc private func themeMaybeChanged() {
        guard store.state.active != shownTheme || store.customThemes != shownNames else { return }
        rebuild { compose() }
    }

    private func compose() {
        shownTheme = store.state.active
        shownNames = store.customThemes
        themes()
        manage()
        display()
        text()
        group("fonts", String(localized: "Fonts and colors")) { [weak self] in
            self?.preview(String(localized: "Aa 文字\n\nClear type, quiet colors. 清晰的文字，舒适的阅读。\n\nA [link](https://example.com), **bold text** and *emphasis*."), height: 200, editingColors: true)
            self?.typefaces()
            self?.addRow(String(localized: "Palette"), nil, control: self?.choiceControl({ "palette" }, Palette.Theme.allCases.map { ($0.rawValue, ThemeCard.displayName($0.rawValue)) }))
            self?.colors(["background", "text", "muted", "link", "accent", "selection"])
        }
        group("paragraphs", String(localized: "Paragraphs and lists")) { [weak self] in self?.paragraphs() }
        group("headings", String(localized: "Headings")) { [weak self] in self?.headings() }
        group("code", String(localized: "Code and formulas")) { [weak self] in self?.code() }
        group("charts", String(localized: "Charts and images")) { [weak self] in self?.charts() }
        group("sidebar", String(localized: "Interface")) { [weak self] in self?.interface() }
        group("advanced", String(localized: "Advanced")) { [weak self] in
            self?.preview(String(localized: "# Release plan\n\nThe text below a heading, for comparing sizes and spacing.\n\n> A short quote.\n\n| Stage | Status |\n|---|---|\n| Draft | Done |"), height: 320)
            self?.css(); self?.folder()
        }
    }

    private func group(_ id: String, _ title: String, content: @escaping () -> Void) {
        addDisclosure(title, expanded: expandedGroups.contains(id), onToggle: { [weak self] open in
            if open { self?.expandedGroups.insert(id) } else { self?.expandedGroups.remove(id) }
        }, content: content)
    }

    private func preview(_ markdown: String, height: CGFloat, editingColors: Bool = false) {
        let sample = PreviewBox(markdown, height: height)
        addRow(String(localized: "Preview"), nil, control: nil, below: sample)
        if editingColors {
            bind { [weak self, weak sample] in
                sample?.appearance = NSAppearance(named: self?.colorMode == "dark" ? .darkAqua : .aqua)
            }
        }
    }

    // MARK: Themes

    private func themes() {
        let builtIns = ThemeLibrary.presets.map { p in ThemeCard(theme: p.id, name: p.name) { [weak self] in self?.store.use(p.id) } }
        let customs = store.customThemes.map { name in ThemeCard(theme: name, name: name) { [weak self] in self?.store.use(name) } }
        let add = NewThemeCard { [weak self] in self?.askForNewTheme(from: nil) }
        addRow(String(localized: "Built-in"), nil,
               control: nil, below: Self.grid(builtIns, columns: 4))
        addRow(String(localized: "Your themes"), nil, control: nil, below: Self.grid(customs + [add], columns: 4))
        bind { [weak self] in
            guard let self else { return }
            for card in builtIns + customs {
                card.selected = card.theme == self.store.state.active
                card.modified = ThemeLibrary.preset(card.theme) != nil && self.store.state.isModified(card.theme)
                card.refresh()
            }
        }
    }

    /// Cards in rows of equal columns; a short row keeps its cards at that width.
    static func grid(_ cards: [NSView], columns: Int = 3) -> NSView {
        let rows = stride(from: 0, to: cards.count, by: columns).map { start -> NSStackView in
            let row = NSStackView(views: Array(cards[start..<min(start + columns, cards.count)]))
            while row.arrangedSubviews.count < columns { row.addArrangedSubview(NSView()) }
            row.distribution = .fillEqually
            row.spacing = 12
            return row
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.spacing = 12
        for row in rows { row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
        return grid
    }

    private func askForNewTheme(from source: String?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = source == nil ? String(localized: "A new theme") : String(localized: "Save as a new theme")
        alert.informativeText = source == nil ? String(localized: "Starts from Zephyr's design.")
            : String(localized: "Starts from \(ThemeCard.displayName(source!)) as it looks now.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = ThemeLibrary.suggestedName(from: source ?? ThemeLibrary.defaultTheme, in: store.folder)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.store.newTheme(named: field.stringValue, from: source) } catch { self.report(error) }
        }
    }

    private func report(_ error: Error) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = (error as? AppearanceSettings.SettingError)?.message ?? error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: Typefaces, light or dark, zoom

    private func typefaces() {
        let latin = lazyFontControl("font.body", presets: Typography.Preset.allCases.map { ($0.rawValue, SettingsWindowController.name(of: $0)) },
                                    families: { [weak self] in self?.fontFamilies().filter { !(self?.chineseFamilies().contains($0) ?? false) } ?? [] },
                                    resolved: { [weak self] in self?.store.typography.latinFamily ?? "" })
        let chinese = lazyFontControl("font.cjk", presets: [("auto", String(localized: "Automatic"))], families: { [weak self] in self?.chineseFamilies() ?? [] },
                                      resolved: { [weak self] in self?.store.typography.cjkFamily ?? "" })
        let note = flatLabel("", size: 11.5, color: Tokens.ink3, wraps: true)
        // Opens the font's page in the browser; installing it stays the reader's choice.
        final class Page { var url: URL? }
        let page = Page()
        let get = FlatButton(title: String(localized: "Get the Font"), style: .plain) { page.url.map { _ = NSWorkspace.shared.open($0) } }
        get.titleFont = Tokens.font(11.5, .medium)
        let pickers = NSStackView(views: [Self.labeled(String(localized: "Latin"), latin), Self.labeled(String(localized: "Chinese"), chinese), note, get])
        pickers.orientation = .vertical
        pickers.alignment = .leading
        pickers.spacing = 10
        addRow(String(localized: "Text"), nil, control: nil, below: pickers)
        bind { [weak self] in
            guard let self else { return }
            // The first choice of the list, when it is not installed: say so and where it comes from.
            let wanted = AppearanceSettings.families(self.store.settings.string("font.body")).first ?? ""
            let wantedCJK = AppearanceSettings.families(self.store.settings.string("font.cjk")).first ?? ""
            let missing = [wanted, wantedCJK].first { family in
                guard !family.isEmpty && !["auto", "system", "serif", "mono"].contains(family) else { return false }
                if let installedFontFamilies = self.installedFontFamilies { return !installedFontFamilies.contains(family) }
                return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) == nil
            }
            if let missing {
                note.stringValue = String(localized: "\(missing) is not installed; a fallback is used.")
                page.url = Self.fontPages[missing].flatMap(URL.init(string:))
            } else {
                note.stringValue = ""
                page.url = nil
            }
            note.isHidden = missing == nil
            get.isHidden = page.url == nil
        }
    }

    /// The system's monospaced face first, then the open-source code families (marked when not
    /// installed) and every other installed fixed-pitch family.
    private func codeFontControl(families: @escaping () -> [String]) -> NSView {
        let popup = lazyFontControl("font.code", presets: [("mono", String(localized: "System Monospaced"))], families: {
            let installed = families()
            let mono = installed.filter { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 12)?.isFixedPitch == true }
            return Self.codeFamilies.filter(installed.contains) + mono.filter { !Self.codeFamilies.contains($0) }
        }, extraItems: { _ in
            Self.codeFamilies.filter { !families().contains($0) }.map { (title: String(localized: "\($0) — Not installed"), toolTip: Self.fontPages[$0]) }
        })
        popup.autoenablesItems = false
        return popup
    }

    private func fontFamilies() -> [String] {
        if let installedFontFamilies { return installedFontFamilies }
        let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        installedFontFamilies = families
        return families
    }

    private func chineseFamilies() -> [String] {
        if let chineseFontFamilies { return chineseFontFamilies }
        let families = fontFamilies().filter(Self.coversChinese)
        chineseFontFamilies = families
        return families
    }

    static func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = flatLabel(title, size: 12, color: Tokens.ink2)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let row = NSStackView(views: [label, control])
        row.spacing = 8
        return row
    }

    /// Whether a family can set Chinese text (it has 中 and 文).
    static func coversChinese(_ family: String) -> Bool {
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
        let set = font.coveredCharacterSet
        return set.contains(Unicode.Scalar(0x4E2D)!) && set.contains(Unicode.Scalar(0x6587)!)
    }

    private func display() {
        addSection(String(localized: "Reading comfort"))
        preview(String(localized: "## A quiet place to read\n\nGood reading starts with comfortable type and line spacing. 好的阅读，从清晰的文字和舒适的行距开始。\n\nThe column leaves room on both sides."), height: 240)
        addRow(String(localized: "Light or dark"), nil, control: choiceControl({ "appearance" }, [("system", String(localized: "Follow System")), ("light", String(localized: "Light")), ("dark", String(localized: "Dark"))]))
    }

    /// The selected theme: its name (Modified for a changed built-in) and what can be done with it.
    private func manage() {
        let saveAs = FlatButton(title: String(localized: "Save as New Theme…"), style: .secondary) { [weak self] in
            guard let self else { return }
            self.askForNewTheme(from: self.store.state.active)
        }
        if let preset = store.state.activePreset {
            let restore = FlatButton(title: String(localized: "Restore Defaults"), style: .plain) { [weak self] in self?.restoreDefaults() }
            let buttons = NSStackView(views: [restore, saveAs])
            buttons.spacing = 6
            let detail = flatLabel("", size: 11.5, color: Tokens.ink2, wraps: true)
            addRow(preset.name, nil, detailLabel: detail, control: buttons)
            bind { [weak self] in
                guard let self else { return }
                let modified = self.store.isModified
                restore.isEnabled = modified
                detail.stringValue = String(localized: "Modified")
                detail.isHidden = !modified
            }
        } else {
            let rename = FlatButton(title: String(localized: "Rename…"), style: .secondary) { [weak self] in self?.askToRename() }
            let delete = FlatButton(title: String(localized: "Move to Trash"), style: .plain) { [weak self] in self?.askToDelete() }
            let buttons = NSStackView(views: [delete, rename, saveAs])
            buttons.spacing = 6
            addRow(store.state.active, nil, control: buttons)
        }
        let edit = FlatButton(title: String(localized: "Edit Theme File"), style: .secondary) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(ThemeLibrary.themeFile(self.store.state.active, in: self.store.folder))
        }
        let fileDetail = flatLabel("", size: 11.5, color: Tokens.ink2, wraps: true)
        addRow(String(localized: "Theme file"), nil, detailLabel: fileDetail, control: edit)
        bind { [weak self] in
            guard let self else { return }
            fileDetail.stringValue = self.store.fileError ?? String(localized: "Changes apply when you save. App updates keep your theme files.")
        }
    }

    /// Clears the built-in theme's changes; Edit › Undo puts them back.
    private func restoreDefaults() {
        let theme = store.state.active
        let previous = store.overrides
        store.setOverrides(nil)
        let undo = view.window?.undoManager
        undo?.registerUndo(withTarget: store) { store in
            guard store.state.active == theme else { return }
            store.setOverrides(previous)
        }
        undo?.setActionName(String(localized: "Restore Defaults"))
    }

    private func askToRename() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename the theme")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = store.state.active
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.store.renameActive(to: field.stringValue) } catch { self.report(error) }
        }
    }

    private func askToDelete() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Move \(store.state.active) to the Trash?")
        alert.informativeText = String(localized: "You can restore it from the Trash.")
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.store.deleteActive() } catch { self.report(error) }
        }
    }

    // MARK: Custom theme settings

    private func text() {
        addRow(String(localized: "Size"), String(localized: "Before zoom."), control: numberControl { "text.size" })
        addRow(String(localized: "Line height"), String(localized: "As a multiple of the text size."), control: numberControl { "text.lineHeight" })
        addRow(String(localized: "Reading width"), String(localized: "In characters."), control: numberControl { "text.width" })
    }

    private func paragraphs() {
        preview(String(localized: "A paragraph with enough text to show alignment, line spacing and the first-line indent. 段落里的中英文可以一起展示对齐、行距和首行缩进的效果。\n\nA second paragraph shows the space between paragraphs.\n\n- Read the draft\n- Review the layout\n  - Check the details\n\n> Keep the important words in view."), height: 350, editingColors: true)
        addRow(String(localized: "Alignment"), nil, control: choiceControl({ "text.align" }, [("left", String(localized: "Left")), ("justify", String(localized: "Justified"))]))
        addRow(String(localized: "Zoom"), String(localized: "⌘+ and ⌘−"), control: numberControl { "zoom" })
        addRow(String(localized: "Paragraph spacing"), String(localized: "In em."), control: numberControl { "paragraph.spacing" })
        addRow(String(localized: "First-line indent"), String(localized: "2 em is common for Chinese."), control: numberControl { "paragraph.indent" })
        addRow(String(localized: "List indent"), nil, control: numberControl { "list.indent" })
        addRow(String(localized: "List item spacing"), nil, control: numberControl { "list.spacing" })
        colors(["quote"])
    }

    private func headings() {
        let sample = String(localized: "# Release plan\n\nThe text below a heading, for comparing sizes and spacing.\n\n## Goals\n\nReading, editing and working with agents.\n\n### Details\n\nOne more paragraph.")
        preview(sample, height: 360, editingColors: true)
        addRow(String(localized: "Typeface"), nil, control: lazyFontControl("font.heading", presets: [("body", String(localized: "Same as Text"))] + Typography.Preset.allCases.map { ($0.rawValue, SettingsWindowController.name(of: $0)) }, families: { [weak self] in self?.fontFamilies() ?? [] }))
        let contrast = SegmentedPicker(items: Self.headingScales.map(\.0))
        contrast.onChange = { [weak self] i in self?.store.set("headings.scale", number: Self.headingScales[i].1) }
        bind { [weak self, weak contrast] in
            let scale = self?.store.settings.number("headings.scale") ?? 1
            contrast?.selectedIndex = Self.headingScales.firstIndex { abs($0.1 - scale) < 0.01 } ?? 1
        }
        addRow(String(localized: "Contrast"), String(localized: "How much larger headings are than the text."), control: contrast)
        addRow(String(localized: "Line height"), String(localized: "For headings that wrap."), control: numberControl { "headings.lineHeight" })
        addRow(String(localized: "Numbering"), String(localized: "Display only; the file is unchanged."),
               control: choiceControl({ "headings.numbering" }, [("none", String(localized: "None")), ("decimal", "1.1"), ("chinese", "一、（一）")]))
        addRow(String(localized: "Number from"), nil, control: choiceControl({ "headings.numberFrom" }, [("1", "H1"), ("2", "H2"), ("3", "H3")], number: true))
        let levelPicker = SegmentedPicker(items: (1...6).map { "H\($0)" })
        levelPicker.onChange = { [weak self] i in
            self?.level = i + 1
            self?.syncAll()
        }
        bind { [weak self] in levelPicker.selectedIndex = (self?.level ?? 1) - 1 }
        let reset = FlatButton(title: String(localized: "Reset Level"), style: .plain) { [weak self] in
            guard let self else { return }
            try? self.store.update { $0.reset(prefix: "h\(self.level).") }
        }
        let levelRow = NSStackView(views: [reset, levelPicker])
        levelRow.spacing = 8
        addRow(String(localized: "Level"), nil, control: levelRow)
        addRow(String(localized: "Size"), String(localized: "Relative to the text; auto follows Contrast."),
               control: numberControl({ [unowned self] in "h\(self.level).size" }, auto: { [unowned self] in
                   Double(self.store.typography.headingSize(level: self.level) / self.store.typography.fontSize)
               }))
        let weights: [(value: Double, title: String)] = [(400, String(localized: "Regular")), (500, String(localized: "Medium")), (600, String(localized: "Semibold")), (700, String(localized: "Bold")), (800, String(localized: "Heavy"))]
        let weight = SegmentedPicker(items: weights.map(\.title))
        weight.onChange = { [weak self] i in
            guard let self else { return }
            self.store.set("h\(self.level).weight", number: weights[i].value)
        }
        bind { [weak self, weak weight] in
            guard let self, let weight else { return }
            let value = self.store.settings.number("h\(self.level).weight") ?? 600
            weight.selectedIndex = weights.firstIndex { $0.value == value } ?? 2
        }
        addRow(String(localized: "Weight"), nil, control: weight)
        addRow(String(localized: "Space above"), nil, control: numberControl { [unowned self] in "h\(self.level).spaceAbove" })
        addRow(String(localized: "Space below"), nil, control: numberControl { [unowned self] in "h\(self.level).spaceBelow" })
        let rule = FlatToggle()
        rule.onChange = { [weak self] on in
            guard let self else { return }
            self.store.set("h\(self.level).rule", on ? "true" : "false")
        }
        bind { [weak self, weak rule] in
            guard let self else { return }
            rule?.isOn = self.store.settings.flag("h\(self.level).rule")
        }
        addRow(String(localized: "Rule below"), nil, control: rule)
        colors(["heading"])
    }

    private func code() {
        preview("```python\n# Greet the reader\ndef greet(name):\n    print(f\"Hello, {name}\", 3)\n```\n\n```json\n{\"name\": \"Zephyr\", \"open\": true}\n```\n\n$$\nE = mc^2\n$$", height: 360, editingColors: true)
        addRow(String(localized: "Typeface"), nil, control: codeFontControl { [weak self] in self?.fontFamilies() ?? [] })
        addRow(String(localized: "Code blocks"), nil, control: choiceControl({ "code.style" }, [("card", String(localized: "Card")), ("shaded", String(localized: "Shaded")), ("outline", String(localized: "Outlined")), ("plain", String(localized: "Plain"))]))
        addRow(String(localized: "Line numbers"), nil, control: flagControl("code.lineNumbers"))
        addRow(String(localized: "Syntax colors"), nil, control: flagControl("code.syntax"))
        addRow(String(localized: "Code size"), String(localized: "Relative to the text."), control: numberControl { "code.size" })
        addRow(String(localized: "Code line height"), nil, control: numberControl { "code.lineHeight" })
        addRow(String(localized: "Draw formulas"), String(localized: "Off shows the TeX source."), control: flagControl("math.render"))
        addRow(String(localized: "Formula size"), String(localized: "Relative to the text."), control: numberControl { "math.size" })
        colors(["codeBackground"])
    }

    /// Pictures are placed like tables and diagrams: their one setting sits with them.
    private func images() {
        addRow(String(localized: "Position"), nil,
               control: choiceControl({ "image.align" }, [("center", String(localized: "Centered")), ("left", String(localized: "Left"))]))
    }

    /// The app's own text: its typeface (the system's by default), and the sidebar's size and
    /// row height. The open windows follow at once.
    private func interface() {
        addRow(String(localized: "Typeface"), nil, control: lazyFontControl("font.interface", presets: Typography.Preset.allCases.map { ($0.rawValue, SettingsWindowController.name(of: $0)) }, families: { [weak self] in self?.fontFamilies() ?? [] }))
        addRow(String(localized: "Sidebar text size"), nil, control: numberControl { "sidebar.size" })
        addRow(String(localized: "Sidebar row spacing"), nil, control: choiceControl({ "sidebar.spacing" }, [("compact", String(localized: "Compact")), ("standard", String(localized: "Standard")), ("roomy", String(localized: "Roomy"))]))
    }

    /// Tables, diagrams and images: one section, one preview of the first two, then each one's settings.
    private func charts() {
        let table = String(localized: "| Stage | Owner | Due | Status |\n|---|---|---|:---:|\n| Design review | Mira | 10-04 | Done |\n| Layout engine | Leo | 10-09 | In progress |\n| Public beta | Everyone | 10-16 | Not started |")
        let diagram = "```mermaid\ngraph LR\n  A[" + String(localized: "Draft") + "] --> B{" + String(localized: "Review") + "}\n  B -->|" + String(localized: "OK") + "| C[" + String(localized: "Publish") + "]\n  B -->|" + String(localized: "Changes") + "| A\n```"
        preview(table + "\n\n" + diagram, height: 404, editingColors: true)
        addSubheading(String(localized: "Tables"))
        tables()
        addSubheading(String(localized: "Diagrams"))
        diagrams()
        addSubheading(String(localized: "Images"))
        images()
    }

    private func tables() {
        addRow(String(localized: "Shaded header"), nil, control: flagControl("table.headerShade"))
        addRow(String(localized: "Bold header"), nil, control: flagControl("table.headerBold"))
        addRow(String(localized: "Rules"), nil, control: choiceControl({ "table.lines" }, [("none", String(localized: "None")), ("rows", String(localized: "Between Rows")), ("grid", String(localized: "Grid"))]))
        addRow(String(localized: "Striped rows"), nil, control: flagControl("table.stripes"))
        addRow(String(localized: "Width"), nil, control: choiceControl({ "table.width" }, Typography.TableWidth.allCases.map { ($0.rawValue, SettingsWindowController.name(of: $0)) }))
        addRow(String(localized: "Position"), String(localized: "For tables narrower than the column."),
               control: choiceControl({ "table.align" }, Typography.BlockAlignment.allCases.map { ($0.rawValue, SettingsWindowController.name(of: $0)) }))
        addRow(String(localized: "Text size"), String(localized: "Relative to the text."), control: numberControl { "table.textSize" })
        addRow(String(localized: "Cell padding"), nil, control: numberControl { "table.padding" })
        addRow(String(localized: "Corner radius"), nil, control: numberControl { "table.radius" })
        colors(["tableBorder", "tableHeader"])
    }

    private func diagrams() {
        addRow(String(localized: "Draw diagrams"), String(localized: "Off shows the Mermaid source."), control: flagControl("diagram.render"))
        addRow(String(localized: "Lines"), nil, control: choiceControl({ "diagram.lines" }, [("curved", String(localized: "Curved")), ("straight", String(localized: "Straight")), ("angled", String(localized: "Angled"))]))
        addRow(String(localized: "Shapes"), nil, control: choiceControl({ "diagram.style" }, [("filled", String(localized: "Filled")), ("outline", String(localized: "Outlined"))]))
        addRow(String(localized: "Colors"), nil, control: choiceControl({ "diagram.colors" }, [("accent", String(localized: "Accent")), ("neutral", String(localized: "Neutral"))]))
        addRow(String(localized: "Spacing"), nil, control: choiceControl({ "diagram.spacing" }, [("compact", String(localized: "Compact")), ("standard", String(localized: "Standard")), ("roomy", String(localized: "Roomy"))]))
        addRow(String(localized: "Text size"), String(localized: "Relative to the text."), control: numberControl { "diagram.textSize" })
    }

    private func colors(_ roles: [String]) {
        let modePicker = SegmentedPicker(items: [String(localized: "Light"), String(localized: "Dark")])
        modePicker.onChange = { [weak self] i in
            self?.colorMode = i == 0 ? "light" : "dark"
            self?.syncAll()
        }
        let reset = FlatButton(title: String(localized: "Reset Colors"), style: .plain) { [weak self] in
            try? self?.store.update { settings in
                for mode in ["light", "dark"] {
                    for role in roles { settings.reset(prefix: "color.\(mode).\(role)") }
                }
            }
        }
        let controls = NSStackView(views: [reset, modePicker])
        controls.spacing = 8
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 10
        grid.rowSpacing = 6
        var chips: [ColorChip] = []
        for pair in stride(from: 0, to: roles.count, by: 2) {
            let views = roles[pair..<min(pair + 2, roles.count)].map { role -> NSView in
                let chip = ColorChip(role: role, title: Self.name(ofRole: role)) { [weak self] in "color.\(self?.colorMode ?? "light").\(role)" }
                chips.append(chip)
                return chip
            }
            grid.addRow(with: views.count == 2 ? views : views + [NSGridCell.emptyContentView])
            if views.count == 2 { views[0].widthAnchor.constraint(equalTo: views[1].widthAnchor).isActive = true }
        }
        for column in 0..<2 { grid.column(at: column).xPlacement = .fill }
        addRow(String(localized: "Section colors"), nil, control: controls, below: grid)
        bind { [weak self] in
            guard let self else { return }
            modePicker.selectedIndex = self.colorMode == "light" ? 0 : 1
            for chip in chips { chip.sync(dark: self.colorMode == "dark") }
        }
    }

    static func name(ofRole role: String) -> String {
        switch role {
        case "background": String(localized: "Background")
        case "text": String(localized: "Text")
        case "muted": String(localized: "Secondary text")
        case "accent": String(localized: "Accent")
        case "link": String(localized: "Links")
        case "heading": String(localized: "Headings")
        case "quote": String(localized: "Quote bar")
        case "codeBackground": String(localized: "Code background")
        case "tableBorder": String(localized: "Table rules")
        case "tableHeader": String(localized: "Table header")
        case "selection": String(localized: "Selection")
        default: role
        }
    }

    private func css() {
        addSection(String(localized: "Custom CSS"),
                   String(localized: "Overrides the settings above."))
        cssEditor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cssEditor.textColor = Tokens.ink
        cssEditor.insertionPointColor = Tokens.accent
        cssEditor.drawsBackground = false
        cssEditor.isRichText = false
        cssEditor.isAutomaticQuoteSubstitutionEnabled = false
        cssEditor.isAutomaticDashSubstitutionEnabled = false
        cssEditor.isAutomaticSpellingCorrectionEnabled = false
        cssEditor.allowsUndo = true
        cssEditor.textContainerInset = NSSize(width: 8, height: 10)
        cssEditor.delegate = self
        cssEditor.isVerticallyResizable = true
        cssEditor.autoresizingMask = [.width]
        cssEditor.setAccessibilityLabel(String(localized: "Custom CSS"))
        cssEditor.string = store.settings.string("css")   // a new theme's own, even mid-edit
        let scroll = NSScrollView()
        scroll.documentView = cssEditor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let box = SurfaceView(fill: Tokens.sunken, border: Tokens.line, radius: Tokens.Radius.control)
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            box.heightAnchor.constraint(equalToConstant: 200),
        ])
        let example = FlatButton(title: String(localized: "Insert Example"), style: .secondary) { [weak self] in
            guard let self else { return }
            self.cssEditor.string = Self.cssExample
            self.saveCSS(Self.cssExample, for: self.store.state.active)
        }
        let clear = FlatButton(title: String(localized: "Clear"), style: .plain) { [weak self] in
            guard let self else { return }
            self.cssEditor.string = ""
            self.saveCSS("", for: self.store.state.active)
        }
        let buttons = NSStackView(views: [clear, example])
        buttons.spacing = 6
        let report = NSStackView(views: [box, cssSummary, cssDetails])
        report.orientation = .vertical
        report.alignment = .leading
        report.spacing = 6
        box.widthAnchor.constraint(equalTo: report.widthAnchor).isActive = true
        addRow(String(localized: "Style sheet"), nil, control: buttons, below: report)
        bind { [weak self] in
            guard let self else { return }
            let css = self.store.settings.string("css")
            if self.cssEditor.string != css, self.view.window?.firstResponder !== self.cssEditor { self.cssEditor.string = css }
            self.reportCSS()
        }
    }

    private func folder() {
        addSection(String(localized: "Theme folder"),
                   String(localized: "One JSON file per theme. Updates keep your edits."))
        let path = flatLabel("", size: 11.5, color: Tokens.ink3)
        path.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        path.isSelectable = true
        path.lineBreakMode = .byTruncatingMiddle
        let choose = FlatButton(title: String(localized: "Choose Folder…"), style: .secondary) { [weak self] in self?.chooseFolder() }
        let open = FlatButton(title: String(localized: "Show in Finder"), style: .plain) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([ThemeLibrary.themeFile(self.store.state.active, in: self.store.folder)])
        }
        let reset = FlatButton(title: String(localized: "Use Default"), style: .plain) { [weak self] in self?.store.setFolder(nil) }
        let buttons = NSStackView(views: [reset, open, choose])
        buttons.spacing = 6
        addRow(String(localized: "Folder"), nil, control: buttons, below: path)
        bind { [weak self] in
            guard let self else { return }
            path.stringValue = self.store.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            reset.isHidden = self.store.state.themesFolder == nil
        }
    }

    private func chooseFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Use Folder")
        panel.message = String(localized: "Choose a folder for your themes.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.store.setFolder(url)
        }
    }

    // MARK: CSS

    /// Saved a moment after typing stops, into the theme it was typed for: a switch in between
    /// drops it rather than writing it into the next theme.
    func textDidChange(_ notification: Notification) {
        cssPending?.cancel()
        let theme = store.state.active, css = cssEditor.string
        let work = DispatchWorkItem { [weak self] in self?.saveCSS(css, for: theme) }
        cssPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveCSS(_ css: String, for theme: String) {
        cssPending?.cancel()
        guard store.state.active == theme else { return }
        try? store.update { try $0.set("css", value: .text(css)) }
        reportCSS()
    }

    private func reportCSS() {
        let (_, applied, ignored) = CustomStyle.parse(cssEditor.string, baseSize: store.settings.number("text.size") ?? 16)
        let rules = applied.filter { $0.contains("{") }
        cssSummary.stringValue = cssEditor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No custom CSS")
            : String(localized: "\(rules.count) applied · \(ignored.count) ignored")
        let notes = applied.filter { !$0.contains("{") } + ignored.map { String(localized: "Ignored: \($0)") }
        cssDetails.stringValue = notes.joined(separator: "\n")
        cssDetails.isHidden = notes.isEmpty
    }
}

// MARK: - Theme cards

/// A theme shown as itself: a rounded page split on a steep diagonal, light on the left and dark
/// on the right. The sample runs across the split, so each glyph, line and the accent show the
/// mode they sit in. The name sits below in the theme's italic.
final class ThemeCard: NSView {
    let theme: String
    var selected = false { didSet { needsDisplay = true } }
    /// A built-in theme with the reader's changes: a dot after its name.
    var modified = false {
        didSet {
            guard modified != oldValue else { return }
            toolTip = [ThemeLibrary.preset(theme)?.summary, modified ? String(localized: "Modified") : nil].compactMap { $0 }.joined(separator: "\n")
            setAccessibilityLabel(modified ? String(localized: "\(name), modified") : name)
            needsDisplay = true
        }
    }
    private var hovering = false { didSet { needsDisplay = true } }
    private let name: String
    private let action: () -> Void
    /// The theme's look, read when the card first draws and again after a change.
    private var cachedLook: (typography: Typography, colors: AppearanceSettings)?
    private var look: (typography: Typography, colors: AppearanceSettings) {
        if let cachedLook { return cachedLook }
        var state = AppearanceStore.shared.state
        state.active = theme
        let settings = state.settings()
        let css = CustomStyle.parse(settings.string("css"), baseSize: settings.number("text.size") ?? 16).style
        let value = (Typography(settings, css: css), settings)
        cachedLook = value
        return value
    }

    /// The theme may have changed (its colors or typefaces): draw it again from its settings.
    func refresh() {
        cachedLook = nil
        needsDisplay = true
    }

    static func displayName(_ theme: String) -> String {
        if let preset = ThemeLibrary.preset(theme) { return preset.name }
        return theme == "zephyr" ? "Zephyr" : theme
    }

    init(theme: String, name: String, action: @escaping () -> Void) {
        self.theme = theme
        self.name = name
        self.action = action
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 132).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(name)
        toolTip = ThemeLibrary.preset(theme)?.summary
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The theme's color for `role` on one side, with its own color keys applied.
    private func color(_ role: Palette.Role, dark: Bool) -> NSColor {
        return Palette.preview(look.colors, role, css: look.typography.css, dark: dark)
    }

    override func draw(_ dirtyRect: NSRect) {
        let page = NSRect(x: 1, y: 30, width: bounds.width - 2, height: bounds.height - 31)
        let outline = NSBezierPath(roundedRect: page, xRadius: 12, yRadius: 12)
        let latin = Typography.resize(look.typography.headingFont(level: 1), 28)
        let chinese = NSFontManager.shared.font(withFamily: look.typography.cjkFamily, traits: [], weight: 5, size: 24) ?? Typography.resize(look.typography.bodyFont, 24)
        let lean = page.width * 0.1
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        for dark in [false, true] {
            NSGraphicsContext.saveGraphicsState()
            // The split leans from the top right of center to the bottom left of it.
            let half = NSBezierPath()
            half.move(to: NSPoint(x: page.midX + lean, y: page.maxY))
            half.line(to: NSPoint(x: page.midX - lean, y: page.minY))
            half.line(to: NSPoint(x: dark ? page.maxX : page.minX, y: page.minY))
            half.line(to: NSPoint(x: dark ? page.maxX : page.minX, y: page.maxY))
            half.close()
            half.addClip()
            color(.background, dark: dark).setFill()
            page.fill()
            let text = color(.text, dark: dark), muted = color(.muted, dark: dark), accent = color(.accent, dark: dark)
            let aa = NSAttributedString(string: "Aa", attributes: [.font: latin, .foregroundColor: text])
            let zi = NSAttributedString(string: "文字", attributes: [.font: chinese, .foregroundColor: text])
            let a = aa.size(), z = zi.size(), gap: CGFloat = 10
            let x = page.midX - (a.width + gap + z.width) / 2, top = page.maxY - 16
            aa.draw(at: NSPoint(x: x, y: top - a.height))
            zi.draw(at: NSPoint(x: x + a.width + gap, y: top - a.height + (latin.descender - chinese.descender)))
            let lines = page.width * 0.68
            for (i, width) in [1.0, 0.82, 0.9].enumerated() {
                (i == 0 ? text : muted).withAlphaComponent(i == 0 ? 0.5 : 0.38).setFill()
                NSBezierPath(roundedRect: NSRect(x: page.midX - lines / 2, y: top - a.height - 14 - CGFloat(i) * 8, width: lines * width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            }
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: page.midX - 18, y: page.minY + 10, width: 36, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        (selected ? Tokens.accent : hovering ? Tokens.ink3 : Tokens.line).setStroke()
        let border = NSBezierPath(roundedRect: page.insetBy(dx: selected ? 0 : 0.5, dy: selected ? 0 : 0.5), xRadius: 12, yRadius: 12)
        border.lineWidth = selected ? 2 : 1
        border.stroke()
        let italic = NSFontManager.shared.convert(Typography.resize(look.typography.bodyFont, 13), toHaveTrait: .italicFontMask)
        let label = NSAttributedString(string: name, attributes: [.font: italic, .foregroundColor: selected ? Tokens.accent : Tokens.ink])
        let size = label.size()
        let dot: CGFloat = modified ? 8 : 0
        let x = max(4, bounds.midX - (size.width + dot) / 2), width = min(size.width, bounds.width - 8 - dot)
        label.draw(with: NSRect(x: x, y: 6, width: width, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if modified {
            Tokens.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + width + 4, y: 6 + size.height / 2 - 2, width: 4, height: 4)).fill()
        }
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
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        guard FocusRing.isKeyboard else { return }
        NSBezierPath(roundedRect: NSRect(x: 1, y: 30, width: bounds.width - 2, height: bounds.height - 31), xRadius: 12, yRadius: 12).fill()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.specialKey == .carriageReturn { action() } else { super.keyDown(with: event) }
    }
}

/// The last card among the reader's themes: a new one from Zephyr's design.
final class NewThemeCard: NSView {
    private var hovering = false { didSet { needsDisplay = true } }
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 132).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "New Theme"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let page = NSRect(x: 1, y: 30, width: bounds.width - 2, height: bounds.height - 31)
        let path = NSBezierPath(roundedRect: page.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        (hovering ? Tokens.hover : Tokens.sunken.withAlphaComponent(0.5)).setFill()
        path.fill()
        Tokens.line.setStroke()
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.stroke()
        if let plus = Tokens.symbol("plus", size: 18, weight: .medium, color: Tokens.ink2) {
            plus.draw(in: NSRect(x: page.midX - plus.size.width / 2, y: page.midY - plus.size.height / 2, width: plus.size.width, height: plus.size.height))
        }
        let label = NSAttributedString(string: String(localized: "New Theme"), attributes: [.font: NSFontManager.shared.convert(Tokens.font(13), toHaveTrait: .italicFontMask), .foregroundColor: Tokens.ink2])
        let size = label.size()
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 6))
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
}

/// One color role: its swatch, name and value. Click picks a color in the system color panel;
/// right-click returns to the palette's color.
final class ColorChip: NSView {
    private let role: String
    private let key: () -> String
    private let swatch = SurfaceView(fill: .clear, border: Tokens.line, radius: 5)
    private let title: NSTextField
    private let value = flatLabel("", size: 11.5, color: Tokens.ink3)
    private var hovering: Bool {
        window.map { NSApp.isActive && !isHiddenOrHasHiddenAncestor && visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }
    private var dark = false
    private static weak var editing: ColorChip?

    init(role: String, title: String, key: @escaping () -> String) {
        self.role = role
        self.key = key
        self.title = flatLabel(title, size: 12.5)
        super.init(frame: .zero)
        value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        swatch.widthAnchor.constraint(equalToConstant: 20).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let row = NSStackView(views: [swatch, self.title, NSView(), value])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 34),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    func sync(dark: Bool) {
        self.dark = dark
        let color = Palette.resolved(Palette.Role(rawValue: role) ?? .text, dark: dark)
        swatch.fill = color
        let custom = AppearanceStore.shared.settings.isSet(key())
        value.stringValue = color.hexString + (custom ? " •" : "")
        value.textColor = custom ? Tokens.accent : Tokens.ink3
        setAccessibilityValue(value.stringValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: Tokens.Radius.control + 1, yRadius: Tokens.Radius.control + 1)
        (hovering ? Tokens.hover : Tokens.sunken.withAlphaComponent(0.6)).setFill()
        path.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)) }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { pick() }
    override func accessibilityPerformPress() -> Bool {
        pick()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: String(localized: "Use the Palette's Color")) { [weak self] in
            guard let self else { return }
            AppearanceStore.shared.set(self.key(), "auto")
        })
        return menu
    }

    private func pick() {
        Self.editing = self
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.setTarget(nil)
        panel.color = Palette.resolved(Palette.Role(rawValue: role) ?? .text, dark: dark)
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorPicked(_ sender: NSColorPanel) {
        guard Self.editing === self else { return }
        AppearanceStore.shared.set(key(), sender.color.hexString)
    }
}
