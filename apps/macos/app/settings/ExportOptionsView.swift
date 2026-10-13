import AppKit
import ZephyrCore
import ZephyrRender

/// The choices under File → Export As's save panel (design §8.4): format, theme, and the options
/// of the chosen format. They edit the same export settings as Settings → Export, so the panel
/// opens with the last choice and `zephyr export` keeps matching the GUI. Inside the system panel
/// they are the system's own pop-up buttons, like every other export panel on the Mac.
final class ExportOptionsView: NSView {
    private(set) var settings: MarkdownExport.Settings
    /// After every change, with the settings as they are now.
    var onChange: ((MarkdownExport.Settings) -> Void)?

    private let grid = NSGridView()
    private let format = NSPopUpButton()
    private let theme = NSPopUpButton()
    private let paper = NSPopUpButton()
    private let margin = NSPopUpButton()
    private let width = NSPopUpButton()
    private let scale = NSPopUpButton()
    private let size = NSPopUpButton()
    private let height = NSPopUpButton()

    init(settings: MarkdownExport.Settings) {
        self.settings = settings
        super.init(frame: .zero)
        for format in MarkdownExport.Format.allCases { add(format.displayName, format.rawValue, to: self.format) }
        for choice in Self.themeChoices(keeping: settings.themeID) {
            guard let (title, id) = choice else { theme.menu?.addItem(.separator()); continue }
            add(title, id, to: theme)
        }
        for paper in MarkdownExport.Settings.Paper.allCases { add(paper == .letter ? String(localized: "Letter") : String(localized: "A4"), paper.rawValue, to: self.paper) }
        for value in Self.including(settings.margin, in: [0, 36, 54, 72]) { add(value == 0 ? String(localized: "None") : "\(Int(value)) pt", value, to: margin) }
        for value in Self.including(settings.rasterWidth, in: [480, 612, 768, 1024]) { add("\(Int(value)) pt", value, to: width) }
        for value: CGFloat in [1, 2, 3] { add("\(Int(value))×", value, to: scale) }
        for choice in Self.textSizes(keeping: settings.textSize) { add(choice.title, choice.value.map { NSNumber(value: Double($0)) } ?? NSNull(), to: size) }
        for choice in Self.lineHeights(keeping: settings.lineHeight) { add(choice.title, choice.value.map { NSNumber(value: Double($0)) } ?? NSNull(), to: height) }
        select(settings.format.rawValue, in: format)
        select(settings.themeID ?? "", in: theme)
        select(settings.paper.rawValue, in: paper)
        select(settings.margin, in: margin)
        select(settings.rasterWidth, in: width)
        select(settings.rasterScale, in: scale)
        selectOptional(settings.textSize, in: size)
        selectOptional(settings.lineHeight, in: height)
        for popUp in [format, theme, size, height, paper, margin, width, scale] {
            popUp.target = self
            popUp.action = #selector(changed)
        }

        let rows: [(String, NSPopUpButton)] = [(String(localized: "Format"), format), (String(localized: "Theme"), theme),
                                               (String(localized: "Text size"), size), (String(localized: "Line height"), height),
                                               (String(localized: "Paper size"), paper), (String(localized: "Margins"), margin),
                                               (String(localized: "Page width"), width), (String(localized: "Scale"), scale)]
        for (title, popUp) in rows {
            let label = NSTextField(labelWithString: title + ":")
            label.alignment = .right
            grid.addRow(with: [label, popUp])
            popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
        ])
        showRows()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The reader's theme, the built-in themes, the reader's own themes; a theme chosen earlier and
    /// since removed stays listed as missing, so the choice is never silently replaced.
    static func themeChoices(keeping selected: String?) -> [(title: String, id: String)?] {
        var choices: [(title: String, id: String)?] = [(String(localized: "Use selected theme"), ""), nil]
        choices += ThemeLibrary.presets.map { ($0.name, $0.id) }
        let custom = AppearanceStore.shared.customThemes
        if !custom.isEmpty { choices.append(nil) }
        choices += custom.map { ($0, $0) }
        if let selected, !choices.contains(where: { $0?.id == selected }) {
            choices += [nil, (selected + " — " + String(localized: "Missing"), selected)]
        }
        return choices
    }

    /// The theme's own size first, then common sizes (and a size set elsewhere, kept).
    static func textSizes(keeping value: CGFloat?) -> [(title: String, value: CGFloat?)] {
        [(String(localized: "Same as theme"), nil)] + including(value, in: [11, 12, 13, 14, 15, 16, 18, 20, 24]).map { size in
            (size == MarkdownExport.Settings.defaultTextSize ? String(localized: "\(Int(size)) pt (Default)") : "\(Int(size)) pt", size)
        }
    }

    static func lineHeights(keeping value: CGFloat?) -> [(title: String, value: CGFloat?)] {
        [(String(localized: "Same as theme"), nil)] + including(value, in: [1.3, 1.4, 1.5, 1.65, 1.8, 2]).map { (Double($0).formatted(.number.precision(.fractionLength(0...2))) + "×", $0) }
    }

    private static func including(_ value: CGFloat?, in values: [CGFloat]) -> [CGFloat] {
        guard let value else { return values }
        return including(value, in: values)
    }

    private static func including(_ value: CGFloat, in values: [CGFloat]) -> [CGFloat] {
        values.contains(value) ? values : (values + [value]).sorted()
    }

    private func add(_ title: String, _ value: Any, to popUp: NSPopUpButton) {
        popUp.addItem(withTitle: title)
        popUp.lastItem?.representedObject = value
    }

    private func select(_ value: String, in popUp: NSPopUpButton) {
        if let item = popUp.itemArray.first(where: { $0.representedObject as? String == value }) { popUp.select(item) }
    }

    /// Numbers come back from a menu item as `NSNumber`: compared by value.
    private func select(_ value: CGFloat, in popUp: NSPopUpButton) {
        if let item = popUp.itemArray.first(where: { ($0.representedObject as? NSNumber)?.doubleValue == Double(value) }) { popUp.select(item) }
    }

    private func value<T>(_ popUp: NSPopUpButton) -> T? { popUp.selectedItem?.representedObject as? T }

    /// nil is the first item, "Same as theme".
    private func selectOptional(_ value: CGFloat?, in popUp: NSPopUpButton) {
        guard let value else { return popUp.selectItem(at: 0) }
        select(value, in: popUp)
    }

    private func optional(_ popUp: NSPopUpButton) -> CGFloat? {
        (popUp.selectedItem?.representedObject as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    @objc private func changed() {
        let theme: String? = value(theme)
        settings = MarkdownExport.Settings(format: value(format).flatMap(MarkdownExport.Format.init(rawValue:)) ?? settings.format,
                                           themeID: theme, paper: value(paper).flatMap(MarkdownExport.Settings.Paper.init(rawValue:)) ?? settings.paper,
                                           margin: value(margin) ?? settings.margin, rasterWidth: value(width) ?? settings.rasterWidth,
                                           rasterScale: value(scale) ?? settings.rasterScale, textSize: optional(size), lineHeight: optional(height))
        showRows()
        onChange?(settings)
    }

    /// Only the chosen format's options: paper for PDF, width and scale for images, margins for
    /// both; plain text has no theme and no text settings.
    private func showRows() {
        let format = settings.format
        for row in [1, 2, 3] { grid.row(at: row).isHidden = format == .txt }
        grid.row(at: 4).isHidden = format != .pdf
        grid.row(at: 5).isHidden = format != .pdf && format != .png && format != .jpg
        for row in [6, 7] { grid.row(at: row).isHidden = format != .png && format != .jpg }
        // The save panel keeps the width it first gave the options: a narrower fit would leave
        // them off center under the panel, so the width only grows; the height follows the rows.
        let fit = fittingSize
        setFrameSize(NSSize(width: max(frame.width, fit.width), height: fit.height))
    }
}
