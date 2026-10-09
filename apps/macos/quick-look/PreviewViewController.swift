import AppKit
import OSLog
import Quartz
import ZephyrCore
import ZephyrRender

/// Finder preview for .md files: the same read-only canvas as the app (design §13). No editing,
/// AI or folder scanning; the first screen is laid out before the preview is shown.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private static let log = Logger(subsystem: "dev.zephyr.Zephyr.QuickLook", category: "preview")
    private var editor: MarkdownEditor?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let start = CACurrentMediaTime()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (text, _) = SourceDecoder.decode(data)
        let settings: AppearanceSettings
        let source: String
        do {
            if let snapshot = try PreviewAppearance.load() {
                settings = snapshot
                source = "snapshot"
            } else {
                settings = AppearanceSettings(overrides: ThemeLibrary.preset(ThemeLibrary.defaultTheme)!.keys)
                source = "default"
            }
        } catch {
            Self.log.error("preview appearance snapshot is invalid")
            throw error
        }
        let css = CustomStyle.parse(settings.string("css"), baseSize: settings.number("text.size") ?? 16).style
        Palette.configure(settings, css: css)
        let mode = settings.string("appearance")
        view.appearance = mode == "light" ? NSAppearance(named: .aqua) : mode == "dark" ? NSAppearance(named: .darkAqua) : nil
        let palette = settings.string("palette")
        Self.log.notice("preview appearance source=\(source, privacy: .public) bytes=\(settings.json().count) mode=\(mode, privacy: .public) palette=\(palette, privacy: .public)")
        let editor = MarkdownEditor(text: text, typography: Typography(settings, css: css), baseURL: url.deletingLastPathComponent(), isEditable: false)
        editor.scrollView.frame = view.bounds
        editor.scrollView.autoresizingMask = [.width, .height]
        self.editor?.scrollView.removeFromSuperview()
        view.addSubview(editor.scrollView)
        self.editor = editor
        // Full first screen before returning: never a truncated or half-styled preview. The block
        // canvas shapes only that first screen, even of a 20 MB file.
        editor.blockCanvas.view.frame.size.width = view.bounds.width
        editor.blockCanvas.prepareVisible()
        let ms = (CACurrentMediaTime() - start) * 1000
        Self.log.notice("preview ready: \(url.lastPathComponent, privacy: .public) bytes=\(data.count) first_screen_ms=\(ms, format: .fixed(precision: 1))")
    }
}
