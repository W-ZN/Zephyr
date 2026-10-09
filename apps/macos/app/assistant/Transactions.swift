import AppKit
import ZephyrCore
import ZephyrRender

/// What is needed to undo one AI or agent write across sessions (design §10): written before the
/// file changes, kept in the app's own data folder (§3.3), never next to the user's files.
struct RecoveryRecord: Codable, Identifiable {
    enum State: String, Codable { case prepared, applied, withdrawn, abandoned }
    var id: String
    var document: String
    var origin: String
    var summary: String
    var created: Date
    var before: String
    var after: String
    /// The system version holding the file as it was before (archived persistent identifier).
    var checkpoint: Data
    var applied: [AppliedPatch]
    var state: State
    /// Set on a withdrawal: the record it withdraws.
    var withdraws: String?
}

enum TransactionError: LocalizedError {
    case untitled, readOnly, noVersions, full, changed

    var errorDescription: String? {
        switch self {
        case .untitled: String(localized: "Save the document first: changes from AI and agents need a file with system versions.")
        case .readOnly: String(localized: "This document is read-only.")
        case .noVersions: String(localized: "macOS could not keep a version of this file, so Zephyr will not let AI or agents change it.")
        case .full: String(localized: "Zephyr's change history is full. Clear it in Settings, then try again.")
        case .changed: String(localized: "The document changed while the edit was prepared. Review it again.")
        }
    }
}

@MainActor
enum Transactions {
    /// Default cap of the app's own data (design §3.3).
    static let limit = 50 << 20

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zephyr/recovery", isDirectory: true)
    }

    private static func url(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }

    static func save(_ record: RecoveryRecord) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url(record.id), options: .atomic)
    }

    static func all() -> [RecoveryRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(RecoveryRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    static func records(for document: URL) -> [RecoveryRecord] {
        all().filter { $0.document == document.path }
    }

    /// One-click clear (design §3.3). Records of edits not yet saved by their document stay.
    static func clear() {
        for record in all() where record.state != .prepared { try? FileManager.default.removeItem(at: url(record.id)) }
    }

    /// Withdrawn and abandoned records go first; applied ones are never evicted silently, so when
    /// they alone exceed the cap new transactions are refused (§3.3).
    static func makeRoom() throws {
        func size() -> Int {
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        guard size() > limit else { return }
        for record in all().reversed() where record.state == .withdrawn || record.state == .abandoned {
            try? FileManager.default.removeItem(at: url(record.id))
            if size() <= limit { return }
        }
        throw TransactionError.full
    }

    /// A crash between writing the record and saving the file leaves it `prepared`; the file on disk
    /// says which side of the write it stopped on.
    static func reconcile(_ document: URL, diskText: String) {
        let revision = TextRevision.of(diskText)
        for var record in records(for: document) where record.state == .prepared {
            if revision == record.after { record.state = .applied } else if revision == record.before { record.state = .abandoned } else { continue }
            try? save(record)
        }
    }

    /// Apply `patches` (document order, against the editor's current text) as one undoable edit:
    /// save pending edits, keep a system version, persist the record, then change and save the file.
    static func apply(_ patches: [TextPatch], to document: MarkdownDocument, origin: String, summary: String, withdraws: String? = nil,
                      completion: @escaping (Result<RecoveryRecord, Error>) -> Void) {
        guard let url = document.fileURL, let editor = document.editor else { return completion(.failure(TransactionError.untitled)) }
        guard !document.isReadOnly else { return completion(.failure(TransactionError.readOnly)) }
        let expected = TextRevision.of(editor.string)
        write(document, to: url) { error in
            if let error { return completion(.failure(error)) }
            do {
                guard TextRevision.of(editor.string) == expected else { throw TransactionError.changed }
                try makeRoom()
                var version: NSFileVersion?
                var coordinationError: NSError?
                NSFileCoordinator(filePresenter: document).coordinate(writingItemAt: url, options: [], error: &coordinationError) { u in
                    version = try? NSFileVersion.addOfItem(at: u, withContentsOf: u, options: [])
                }
                guard let version else { throw TransactionError.noVersions }
                let checkpoint = try NSKeyedArchiver.archivedData(withRootObject: version.persistentIdentifier, requiringSecureCoding: false)
                let before = editor.string
                let after = ProposalResolver.apply(patches, to: before)
                var record = RecoveryRecord(id: UUID().uuidString, document: url.path, origin: origin, summary: summary, created: Date(),
                                            before: TextRevision.of(before), after: TextRevision.of(after), checkpoint: checkpoint,
                                            applied: ProposalResolver.applied(patches, to: before), state: .prepared, withdraws: withdraws)
                try save(record)
                editor.apply(patches, actionName: withdraws == nil ? String(localized: "Apply Proposed Change") : String(localized: "Withdraw Change"))
                write(document, to: url) { error in
                    if let error { return completion(.failure(error)) }
                    record.state = .applied
                    try? save(record)
                    completion(.success(record))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Save now, whatever the change count says: an edit made inside the current event's undo group
    /// is not counted yet, so an autosave would skip it.
    private static func write(_ document: MarkdownDocument, to url: URL, completion: @escaping (Error?) -> Void) {
        document.save(to: url, ofType: document.fileType ?? "net.daringfireball.markdown", for: .saveOperation, completionHandler: completion)
    }

    /// Withdraw an applied change with its inverse patches, as a recoverable transaction of its own.
    /// If the text it wrote has changed since, nothing is overwritten: the user gets the version
    /// from before the change to compare (design §10).
    static func withdraw(_ record: RecoveryRecord, in document: MarkdownDocument, window: NSWindow?, completion: @escaping () -> Void) {
        guard let editor = document.editor else { return }
        guard let patches = ProposalResolver.withdrawal(of: record.applied, in: editor.string) else {
            let alert = NSAlert()
            alert.messageText = String(localized: "This change can't be withdrawn automatically")
            alert.informativeText = String(localized: "The text it wrote has been edited since. Zephyr won't overwrite those edits; you can open the version from before the change and compare.")
            alert.addButton(withTitle: String(localized: "Open Earlier Version"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let open = {
                let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: record.checkpoint)
                unarchiver?.requiresSecureCoding = false
                guard let id = unarchiver?.decodeObject(forKey: NSKeyedArchiveRootObjectKey),
                      let version = NSFileVersion.version(itemAt: URL(fileURLWithPath: record.document), forPersistentIdentifier: id) else { return NSSound.beep() }
                NSDocumentController.shared.openDocument(withContentsOf: version.url, display: true) { _, _, _ in }
            }
            if let window {
                alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { open() } }
            } else if alert.runModal() == .alertFirstButtonReturn {
                open()
            }
            return
        }
        apply(patches, to: document, origin: record.origin, summary: record.summary, withdraws: record.id) { result in
            switch result {
            case .success:
                var withdrawn = record
                withdrawn.state = .withdrawn
                try? save(withdrawn)
                completion()
            case let .failure(error):
                if let window { NSAlert(error: error).beginSheetModal(for: window) }
            }
        }
    }
}
