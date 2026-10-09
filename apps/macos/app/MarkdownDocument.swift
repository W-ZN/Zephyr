import AppKit
import UniformTypeIdentifiers
import ZephyrCore
import ZephyrRender

/// A Markdown file. The disk file is the only truth (design §5): bytes are decoded once,
/// edited as text, and written back byte-exactly through NSDocument (autosave in place +
/// versions). Invalid UTF-8 opens read-only and is never re-encoded.
final class MarkdownDocument: NSDocument {
    static let exportCommand = ExportCommand()
    private(set) var loadedText = ""
    private(set) var encoding = SourceEncoding(hasBOM: false, isValidUTF8: true, lineEnding: .lf)
    /// The text last read from or written to disk: the common ancestor of a three-way merge.
    private var diskText = ""
    private var writingText: String?
    /// The canvas showing this document, attached by the window controller.
    weak var editor: MarkdownEditor?

    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { true }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    /// Invalid UTF-8, or an earlier version opened from the system's version store.
    var isReadOnly: Bool { !encoding.isValidUTF8 || isStoredVersion }
    var isStoredVersion: Bool { fileURL?.path.contains("/.DocumentRevisions-V100/") == true }

    override func close() {
        AgentAccess.shared.revoke(self)
        DocumentWindowController.hosting(self)?.documentClosed(self)
        super.close()
    }

    /// An untitled document holding no text has nothing to keep: closing it never asks whether to
    /// save, even after text was typed and deleted again.
    var isEmptyUntitled: Bool { fileURL == nil && (editor?.string ?? loadedText).isEmpty }

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        if isEmptyUntitled, isDocumentEdited { updateChangeCount(.changeCleared) }
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    /// A window of its own, or a place among the open documents of the window in front: when the
    /// reader asked for that (New in This Window), or as the system's tab preference says for
    /// documents opened from the Finder or Open… (design §7.8). Restored windows are always their own.
    override func makeWindowControllers() {
        if Self.restoring == 0, let host = DocumentWindowController.hostForNewDocument() {
            host.adopt(self)
        } else {
            addWindowController(DocumentWindowController(document: self))
        }
    }

    private static var restoring = 0

    override func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        Self.restoring += 1
        defer { Self.restoring -= 1 }
        super.restoreWindow(withIdentifier: identifier, state: state, completionHandler: completionHandler)
    }

    /// Opened again while it waits in a window's sidebar: that window shows it.
    override func showWindows() {
        if windowControllers.isEmpty, let host = DocumentWindowController.hosting(self) { return host.reveal(self) }
        if windowControllers.isEmpty { makeWindowControllers() }
        super.showWindows()
    }

    /// Counts reads. The editor shows read `editorGeneration`; a reload queued by an older read
    /// (the first read of a concurrent open finishes off the main thread) must not replace text
    /// the user has typed since.
    private var readGeneration = 0
    var editorGeneration = 0

    override func read(from data: Data, ofType typeName: String) throws {
        let (text, encoding) = SourceDecoder.decode(data)
        loadedText = text
        diskText = text
        self.encoding = encoding
        readGeneration += 1
        let generation = readGeneration
        if Thread.isMainThread {
            reloadEditor(generation)
        } else {
            DispatchQueue.main.async { self.reloadEditor(generation) }
        }
    }

    /// The editor is being created from `loadedText`.
    func editorDidLoad() {
        editorGeneration = readGeneration
        if let url = fileURL { Transactions.reconcile(url, diskText: loadedText) }
    }

    private func reloadEditor(_ generation: Int) {
        guard let editor, generation > editorGeneration else { return }
        editorGeneration = generation
        let visible = editor.firstVisibleCharacter()
        editor.newline = encoding.newline
        editor.load(loadedText)
        editor.isEditable = !isReadOnly
        editor.scrollToCharacter(visible)
    }

    override func data(ofType typeName: String) throws -> Data {
        guard !isStoredVersion else { throw CocoaError(.fileWriteNoPermission) }
        guard encoding.isValidUTF8 else {
            throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSLocalizedDescriptionKey: String(localized: "This file is not valid UTF-8 and was opened read-only.")])
        }
        let text = editor?.string ?? loadedText
        writingText = text
        return SourceDecoder.encode(text, encoding: encoding)
    }

    /// Saving over the file swaps in the new bytes without NSDocument's `name~.md` backup: the
    /// backup sits in the user's folder until a deferred cleanup, and a quit or crash before then
    /// would leave it behind (principle 2). The swap keeps the file's metadata and extended attributes.
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        guard saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation, FileManager.default.fileExists(atPath: url.path) else {
            return try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        }
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let staged = folder.appendingPathComponent(url.lastPathComponent)
        try data(ofType: typeName).write(to: staged)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staged, backupItemName: nil, options: [])
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping ((any Error)?) -> Void) {
        // Typing after this save starts a new undo step, so it marks the document edited again.
        editor?.breakUndoCoalescing()
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, saveOperation != .autosaveElsewhereOperation, let self, let written = self.writingText {
                self.diskText = written
                do { try SpaceStore.shared.recordActivityModified(url) }
                catch { self.presentError(error) }
            }
            self?.writingText = nil
            completionHandler(error)
        }
    }

    /// External edits (design §5): without local changes the file simply reloads. With local
    /// changes, edits to different lines merge three-way; overlapping edits are never resolved
    /// silently — the window asks which version to keep (principle 3).
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in self?.externalChange() }
    }

    private func externalChange() {
        // An input method composing in the editor finishes first: a merge must not cut into it.
        if editor?.isComposing == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.externalChange() }
            return
        }
        guard let url = fileURL, let editor,
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              let known = fileModificationDate, modified > known else { return }
        var data: Data?
        NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: url, options: [], error: nil) { data = try? Data(contentsOf: $0) }
        guard let data else { return }
        let (remote, remoteEncoding) = SourceDecoder.decode(data)
        let typeName = fileType ?? "net.daringfireball.markdown"
        if !isDocumentEdited || remote == editor.string {
            try? revert(toContentsOf: url, ofType: typeName)
            return
        }
        let local = editor.string
        bannerGeneration += 1
        let generation = bannerGeneration
        if remoteEncoding.isValidUTF8, let merged = ThreeWayMerge.merge(base: diskText, local: local, remote: remote).merged {
            if let patch = TextPatch.minimal(from: local, to: merged) { editor.applyExternal(patch) }
            diskText = remote
            // The disk's bytes are the base now, byte-order mark included.
            encoding = remoteEncoding
            fileModificationDate = modified
            windowController?.showBanner(String(localized: "Merged changes made in another app."), symbol: "arrow.triangle.merge", for: self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.bannerGeneration == generation, let self { self.windowController?.showBanner(nil, for: self) }
            }
            return
        }
        windowController?.showBanner(String(localized: "Another app changed this file where you are editing."), symbol: "exclamationmark.triangle", for: self, actions: [
            (String(localized: "Keep Mine"), { [weak self] in
                // The next save overwrites the other version; NSFileVersion keeps it (design §10).
                self?.diskText = remote
                self?.fileModificationDate = modified
                self?.updateChangeCount(.changeDone)
                if let self { self.windowController?.showBanner(nil, for: self) }
            }),
            (String(localized: "Use Other Version"), { [weak self] in
                if let self { self.windowController?.showBanner(nil, for: self) }
                try? self?.revert(toContentsOf: url, ofType: typeName)
            }),
        ])
    }

    private var bannerGeneration = 0

    /// The window holding it, shown or not; its notices go to its own tab there.
    private var windowController: DocumentWindowController? { DocumentWindowController.hosting(self) }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let editor else { throw CocoaError(.featureUnsupported) }
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        info.isVerticallyCentered = false
        let operation = NSPrintOperation(view: editor.printView, printInfo: info)
        operation.jobTitle = displayName
        return operation
    }

    /// One command (design §8.4): the save panel carries the format, theme and the format's options,
    /// starting from the export settings; an export made keeps its choices as those settings.
    @objc func exportDocument(_ sender: Any?) {
        guard editor != nil else { return }
        let initial: MarkdownExport.Settings
        do { initial = try MarkdownExport.Settings.load() }
        catch { presentError(error); return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export")
        panel.prompt = String(localized: "Export")
        panel.canCreateDirectories = true
        let options = ExportOptionsView(settings: initial)
        panel.accessoryView = options
        let show = { [weak panel] (format: MarkdownExport.Format) in
            guard let panel else { return }
            panel.allowedContentTypes = [format.contentType]
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + format.fileExtension
        }
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension
        show(initial.format)
        options.onChange = { show($0.format) }
        let finish = { [weak self, weak panel, weak options] (response: NSApplication.ModalResponse) in
            guard response == .OK, let self, let selected = panel?.url, let settings = options?.settings else { return }
            do { try settings.save() } catch { self.presentError(error) }
            self.export(settings: settings, output: selected)
        }
        if let window = windowForSheet { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// A theme other than the reader's lays the text out again, read-only, in that theme.
    private func export(settings: MarkdownExport.Settings, output: URL) {
        guard let editor else { return }
        let exportEditor: MarkdownEditor
        do {
            if settings.themeID == nil, settings.textSize == nil, settings.lineHeight == nil {
                exportEditor = editor
            } else {
                exportEditor = MarkdownEditor(text: editor.string, typography: try MarkdownExport.typography(for: settings, appearance: AppearanceStore.shared.state), baseURL: editor.baseURL, isEditable: false, canvas: editor.blockCanvas.mode == .source ? .source : .block)
                exportEditor.frontMatterCollapsed = editor.frontMatterCollapsed
            }
        } catch {
            presentError(error)
            return
        }
        export(editor: exportEditor, format: settings.format, output: output, settings: settings, approved: [output])
    }

    private func export(editor: MarkdownEditor, format: MarkdownExport.Format, output: URL, settings: MarkdownExport.Settings, approved: Set<URL>) {
        do {
            _ = try MarkdownExport.write(editor: editor, format: format, output: output, inputURL: fileURL, settings: settings, approvedOutputs: approved)
        } catch let error as MarkdownExport.Error {
            guard case let .outputsExist(collisions) = error else { presentError(error); return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Replace exported files?")
            alert.informativeText = collisions.map(\.path).joined(separator: "\n")
            alert.addButton(withTitle: String(localized: "Replace"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            export(editor: editor, format: format, output: output, settings: settings, approved: approved.union(collisions))
        } catch {
            presentError(error)
        }
    }
}

final class ExportCommand: NSObject {
    @objc func exportDocument(_ sender: Any?) {
        (NSDocumentController.shared.currentDocument as? MarkdownDocument)?.exportDocument(sender)
    }
}
