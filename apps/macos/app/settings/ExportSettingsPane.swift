import AppKit
import ZephyrCore
import ZephyrRender

/// Settings shared by File → Export and `zephyr export`. These choices change output only; they
/// never alter the reader's selected theme or its appearance files.
final class ExportSettingsPane: SettingsPage {
    private var export = MarkdownExport.Settings()

    override func loadView() {
        build(title: String(localized: "Export"), subtitle: String(localized: "Choose how Zephyr exports documents by default."))
        do { export = try MarkdownExport.Settings.load() }
        catch { NSApp.presentError(error); return }

        addSection(String(localized: "Default output"))
        let formats = MarkdownExport.Format.allCases
        let format = SegmentedPicker(items: formats.map(\.displayName))
        format.selectedIndex = formats.firstIndex(of: export.format) ?? 0
        format.onChange = { [weak self] index in
            guard let self else { return }
            self.update { $0.format = formats[index] }
        }
        addRow(String(localized: "Format"), String(localized: "File → Export As starts with these choices and keeps changes made there."), control: format)

        let theme = FlatPopUpButton()
        for choice in ExportOptionsView.themeChoices(keeping: export.themeID) {
            guard let (title, id) = choice else { theme.menu?.addItem(.separator()); continue }
            theme.addItem(withTitle: title)
            theme.lastItem?.representedObject = id
        }
        if let item = theme.itemArray.first(where: { ($0.representedObject as? String) == (export.themeID ?? "") }) { theme.select(item) }
        let themeTarget = ClosureTarget { [weak self, weak theme] in
            guard let self, let value = theme?.selectedItem?.representedObject as? String else { return }
            self.update { $0.themeID = value.isEmpty ? nil : value }
        }
        theme.target = themeTarget
        theme.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(theme, &ClosureTarget.key, themeTarget, .OBJC_ASSOCIATION_RETAIN)
        theme.widthAnchor.constraint(equalToConstant: 220).isActive = true
        addRow(String(localized: "Theme"), String(localized: "Use the selected reader theme, or keep one theme for exports."), control: theme)

        // What every visual format shares: the text and the room around it.
        addSection(String(localized: "Page"))
        let size = optionPopUp(ExportOptionsView.textSizes(keeping: export.textSize), selected: export.textSize) { [weak self] value in self?.update { $0.textSize = value } }
        addRow(String(localized: "Text size"), String(localized: "For PDF, HTML and images; headings, code and tables keep their proportions."), control: size)
        let height = optionPopUp(ExportOptionsView.lineHeights(keeping: export.lineHeight), selected: export.lineHeight) { [weak self] value in self?.update { $0.lineHeight = value } }
        addRow(String(localized: "Line height"), nil, control: height)
        var margins: [CGFloat] = [0, 36, 54, 72]
        if !margins.contains(export.margin) { margins.append(export.margin); margins.sort() }
        let margin = SegmentedPicker(items: margins.map { $0 == 0 ? String(localized: "None") : "\(Int($0)) pt" })
        margin.selectedIndex = margins.firstIndex(of: export.margin) ?? 1
        margin.onChange = { [weak self] index in
            guard let self else { return }
            self.update { $0.margin = margins[index] }
        }
        addRow(String(localized: "Margins"), String(localized: "On each side of PDF pages and exported images."), control: margin)

        addSection(String(localized: "PDF"))
        let papers = MarkdownExport.Settings.Paper.allCases
        let paper = SegmentedPicker(items: [String(localized: "Letter"), String(localized: "A4")])
        paper.selectedIndex = papers.firstIndex(of: export.paper) ?? 0
        paper.onChange = { [weak self] index in
            guard let self else { return }
            self.update { $0.paper = papers[index] }
        }
        addRow(String(localized: "Paper size"), nil, control: paper)


        addSection(String(localized: "PNG and JPEG"))
        var widths: [CGFloat] = [480, 612, 768, 1024]
        if !widths.contains(export.rasterWidth) { widths.append(export.rasterWidth); widths.sort() }
        let width = FlatPopUpButton()
        for value in widths {
            width.addItem(withTitle: "\(Int(value)) pt")
            width.lastItem?.representedObject = value
        }
        width.selectItem(at: widths.firstIndex(of: export.rasterWidth) ?? 0)
        let widthTarget = ClosureTarget { [weak self, weak width] in
            guard let self, let value = width?.selectedItem?.representedObject as? CGFloat else { return }
            self.update { $0.rasterWidth = value }
        }
        width.target = widthTarget
        width.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(width, &ClosureTarget.key, widthTarget, .OBJC_ASSOCIATION_RETAIN)
        addRow(String(localized: "Page width"), String(localized: "The width before resolution scaling."), control: width)

        let scales: [CGFloat] = [1, 2, 3]
        let scale = SegmentedPicker(items: scales.map { "\(Int($0))×" })
        scale.selectedIndex = scales.firstIndex(of: export.rasterScale) ?? 1
        scale.onChange = { [weak self] index in
            guard let self else { return }
            self.update { $0.rasterScale = scales[index] }
        }
        addRow(String(localized: "Scale"), String(localized: "Higher scale makes larger, sharper image files."), control: scale)
    }

    /// A pop-up of optional numbers: the first item (nil) follows the theme.
    private func optionPopUp(_ choices: [(title: String, value: CGFloat?)], selected: CGFloat?, onChange: @escaping (CGFloat?) -> Void) -> FlatPopUpButton {
        let popUp = FlatPopUpButton()
        for choice in choices {
            popUp.addItem(withTitle: choice.title)
            popUp.lastItem?.representedObject = choice.value.map { NSNumber(value: Double($0)) }
        }
        popUp.selectItem(at: choices.firstIndex { $0.value == selected } ?? 0)
        let target = ClosureTarget { [weak popUp] in
            guard let popUp else { return }
            onChange((popUp.selectedItem?.representedObject as? NSNumber).map { CGFloat($0.doubleValue) })
        }
        popUp.target = target
        popUp.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(popUp, &ClosureTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        popUp.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return popUp
    }

    /// One choice changed, applied to the settings as saved now: the export panel edits the same file.
    private func update(_ change: (inout MarkdownExport.Settings) -> Void) {
        do {
            var current = try MarkdownExport.Settings.load()
            change(&current)
            export = MarkdownExport.Settings(format: current.format, themeID: current.themeID, paper: current.paper, margin: current.margin, rasterWidth: current.rasterWidth, rasterScale: current.rasterScale,
                                             textSize: current.textSize, lineHeight: current.lineHeight)
            try export.save()
        } catch {
            NSApp.presentError(error)
        }
    }
}
