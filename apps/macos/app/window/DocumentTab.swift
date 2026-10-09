import AppKit
import ZephyrRender

/// One of a window's places (design §7.8): a document with its canvas — or none, while a window
/// without documents shows an app page alone — an app page possibly over the document, and the
/// place's own back/forward history. The sidebar's Open section lists the places with documents.
@MainActor
final class DocumentTab {
    var document: MarkdownDocument?
    /// The document's canvas. A tab in the background keeps it, with its undo history and place.
    var editor: MarkdownEditor?
    /// The app page shown over the document, if any.
    var panel: SpacePanel?
    var history: [DocumentWindowController.Page] = []
    var historyIndex = -1
    var readingPositions: [URL: Int] = [:]
    /// The assistant's chat while the tab is in the background.
    var assistant: (panel: AIPanelController, open: Bool)?
    /// The notice over its text (read-only, merged changes, a conflict to settle), kept until it is
    /// dismissed: a tab in the background shows it when it comes forward.
    var banner: (text: String, symbol: String, actions: [(String, () -> Void)])?

    init(document: MarkdownDocument?) {
        self.document = document
    }

    /// Its name in the sidebar and the quick switcher: a file's name without its extension, an
    /// untitled document's name (the document's, also while a page is over it).
    var shortTitle: String {
        document.map { $0.fileURL == nil ? $0.displayName : ($0.displayName as NSString).deletingPathExtension } ?? panel?.title ?? String(localized: "Empty")
    }

    /// An untitled document with text: it exists nowhere else, so nothing replaces it in place.
    var holdsUnsavedText: Bool { document.map { $0.fileURL == nil && !$0.isEmptyUntitled } ?? false }

    /// Ends what runs in it when the tab closes.
    func discard() {
        assistant?.panel.stop()
        assistant = nil
    }
}
