import AppKit
import Security
import ZephyrCore
import ZephyrRender

/// A credential the GUI grants for one document (design §11): agents may read it and propose
/// changes to it, until the user revokes it, the document closes, the app quits, or eight hours
/// pass. Grants live only in memory, so an update or relaunch ends them.
@MainActor
final class AgentGrant {
    let id: String
    weak var document: MarkdownDocument?
    let expires = Date().addingTimeInterval(8 * 3600)
    /// The folder agents may also read and search: the folder scope the window showed when the
    /// user shared, or nil for the document alone. It can only shrink afterwards (design §7.6).
    var root: URL?

    init(document: MarkdownDocument, root: URL?) {
        self.document = document
        self.root = root
        id = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    var isValid: Bool { document?.editor != nil && Date() < expires }
}

/// The local IPC endpoint for `zephyr` and `zephyr mcp`. It listens only while some document is
/// shared (principle 5), answers only the `zephyr` tool bundled with this app (checked by code
/// signature), and never applies anything itself: proposals go to the review sheet.
@MainActor
final class AgentAccess {
    static let shared = AgentAccess()
    static let didChange = Notification.Name("ZephyrAgentAccessDidChange")
    private(set) var grants: [AgentGrant] = []
    private var socket: Int32 = -1

    func grant(for document: MarkdownDocument?) -> AgentGrant? {
        grants.first { $0.document === document && $0.isValid }
    }

    func toggle(_ document: MarkdownDocument) {
        if grant(for: document) != nil { revoke(document) } else { share(document) }
    }

    func share(_ document: MarkdownDocument) {
        guard document.fileURL != nil, grant(for: document) == nil else { return }
        grants.append(AgentGrant(document: document, root: windowScope(of: document)))
        startIfNeeded()
        NotificationCenter.default.post(name: Self.didChange, object: document)
    }

    /// The window's folder scope changed: the share keeps only the part the window still shows
    /// (sharing never grows by itself).
    func scopeChanged(for document: MarkdownDocument, to root: URL?) {
        guard let grant = grant(for: document), let shared = grant.root else { return }
        let kept = ScopeResolver.narrowed(shared, to: root)
        guard kept?.path != shared.resolvingSymlinksInPath().path else { return }
        grant.root = kept
        NotificationCenter.default.post(name: Self.didChange, object: document)
    }

    func revoke(_ document: MarkdownDocument) {
        grants.removeAll { $0.document === document || !$0.isValid }
        stopIfIdle()
        NotificationCenter.default.post(name: Self.didChange, object: document)
    }

    // MARK: Socket

    private func startIfNeeded() {
        guard socket < 0, let fd = AgentChannel.listening(at: AgentChannel.socketPath()) else { return }
        socket = fd
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }   // the listening socket was closed
                AgentChannel.ignoreBrokenPipe(client)
                guard Self.peerIsBundledCLI(client), let request = AgentChannel.receive(AgentRequest.self, from: client) else {
                    _ = AgentChannel.send(AgentResponse(error: "Only the zephyr tool inside Zephyr.app may connect."), on: client)
                    close(client)
                    continue
                }
                DispatchQueue.main.async {
                    AgentAccess.shared.handle(request) { response in
                        DispatchQueue.global(qos: .userInitiated).async {
                            _ = AgentChannel.send(response, on: client)
                            close(client)
                        }
                    }
                }
            }
        }
    }

    private func stopIfIdle() {
        grants.removeAll { !$0.isValid }
        guard grants.isEmpty, socket >= 0 else { return }
        close(socket)
        socket = -1
        unlink(AgentChannel.socketPath())
    }

    /// The `zephyr` executable embedded in this app, as its designated requirement: with a local
    /// signing identity that is identifier + certificate; ad hoc, the exact binary.
    nonisolated private static let cliRequirement: SecRequirement? = {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zephyr")
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    /// The connected process is the bundled `zephyr`: identified by its audit token, not its path or pid.
    nonisolated private static func peerIsBundledCLI(_ fd: Int32) -> Bool {
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }   // same macOS user only
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0, let requirement = cliRequirement else { return false }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // MARK: Requests

    private func handle(_ request: AgentRequest, reply: @escaping (AgentResponse) -> Void) {
        grants.removeAll { !$0.isValid }
        if request.op == .sessions {
            var response = AgentResponse()
            response.sessions = grants.compactMap { g in
                g.document.flatMap { doc in doc.fileURL.map { AgentSession(id: g.id, document: $0.path, title: doc.displayName, expires: g.expires) } }
            }
            return reply(response)
        }
        let grant: AgentGrant?
        if let id = request.session { grant = grants.first { $0.id == id } } else { grant = grants.count == 1 ? grants[0] : nil }
        guard let grant, let document = grant.document, document.fileURL != nil else {
            return reply(AgentResponse(error: grants.isEmpty ? "No document allows agent access."
                                       : request.session == nil ? "Several documents allow agent access; pass a session id (zephyr sessions)." : "Unknown or expired session."))
        }
        // A folder search runs in the background: access revoked or narrowed meanwhile withholds it.
        let root = grant.root
        perform(request, on: document, root: root) { [weak self] response in
            guard let self, self.grants.contains(where: { $0 === grant && $0.isValid }), grant.root == root else {
                return reply(AgentResponse(error: "Agent access to this document changed while the request ran."))
            }
            reply(response)
        }
    }

    /// The document operations (design §21.6) on an open document, for external agents and the
    /// built-in AI alike. `root` is the folder scope they may read and search; nil limits them to
    /// the document.
    func perform(_ request: AgentRequest, on document: MarkdownDocument, root: URL?, reply: @escaping (AgentResponse) -> Void) {
        guard let editor = document.editor, let url = document.fileURL else { return reply(AgentResponse(error: "The document has no file yet.")) }
        let text = editor.string
        let starts = LineNumbers.starts(of: text)
        switch request.op {
        case .sessions:
            reply(AgentResponse())
        case .context:
            var response = AgentResponse()
            response.context = context(of: document, root: root)
            reply(response)
        case .read:
            reply(read(request, document: url, text: text, root: root))
        case .search:
            search(request, document: url, text: text, starts: starts, root: root, reply: reply)
        case .propose:
            let proposal = EditProposal(document: url.path, baseRevision: request.baseRevision ?? TextRevision.of(text), edits: request.edits ?? [],
                                        summary: request.summary ?? "", origin: request.client ?? "zephyr")
            var response = AgentResponse()
            response.proposal = proposal.id
            var answered = false
            NSApp.requestUserAttention(.informationalRequest)
            ProposalReview.present(proposal, for: document) { result in
                var final = response
                switch result {
                case .success: final.status = "applied"
                case nil: final.status = "discarded"
                case let .failure(error): final.error = String(describing: error)
                }
                if !answered || request.wait == true {
                    answered = true
                    reply(final)
                }
            }
            if request.wait != true, !answered {
                answered = true
                response.status = "pending"
                reply(response)
            }
        }
    }

    /// The context card: path, revision, selection and outline with line numbers.
    func context(of document: MarkdownDocument, root: URL?) -> AgentContext? {
        guard let editor = document.editor, let url = document.fileURL else { return nil }
        let text = editor.string
        let starts = LineNumbers.starts(of: text)
        let sel = editor.selectedRange
        let headings = editor.headings().map { AgentHeading(level: $0.level, title: $0.title, line: LineNumbers.line(at: $0.location, starts: starts)) }
        return AgentContext(document: url.path, title: document.displayName, revision: TextRevision.of(text), lineCount: starts.count,
                            unsaved: document.isDocumentEdited,
                            selection: sel.length > 0 ? (text as NSString).substring(with: sel) : nil,
                            selectionLines: [LineNumbers.line(at: sel.location, starts: starts), LineNumbers.line(at: max(sel.location, NSMaxRange(sel) - 1), starts: starts)],
                            headings: headings, scopeRoot: root?.path ?? "", instructions: Preferences.agentInstructions)
    }

    /// The folder scope the document's window shows, if the user opened one (design §7).
    func windowScope(of document: MarkdownDocument) -> URL? {
        DocumentWindowController.hosting(document)?.scopeRoot
    }

    /// The document as edited now, or a file inside the folder scope (symbolic links resolved first,
    /// nothing outside the root, design §7).
    private func read(_ request: AgentRequest, document url: URL, text: String, root: URL?) -> AgentResponse {
        var source = text
        var response = AgentResponse()
        if let path = request.path, !path.isEmpty {
            guard let root else { return AgentResponse(error: "No folder scope is open in Zephyr, so only the document itself can be read.") }
            let target = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
            let base = root.resolvingSymlinksInPath().path
            guard target.path.hasPrefix(base + "/") else { return AgentResponse(error: "\(path) is outside the folder scope \(root.path).") }
            if target.path != url.resolvingSymlinksInPath().path {
                guard let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 << 20,
                      let data = try? Data(contentsOf: target) else { return AgentResponse(error: "Cannot read \(path) (missing, or larger than 4 MB).") }
                let (decoded, encoding) = SourceDecoder.decode(data)
                guard encoding.isValidUTF8 else { return AgentResponse(error: "\(path) is not UTF-8 text.") }
                source = decoded
            } else {
                response.revision = TextRevision.of(text)
            }
        } else {
            response.revision = TextRevision.of(text)
        }
        let starts = LineNumbers.starts(of: source)
        let ns = source as NSString
        var first = 1, last = starts.count
        if let lines = request.lines, lines.count == 2 {
            first = max(1, lines[0])
            last = min(starts.count, max(first, lines[1]))
        }
        guard first <= starts.count else { return AgentResponse(error: "The file has \(starts.count) lines.") }
        let a = starts[first - 1], b = last < starts.count ? starts[last] : ns.length
        response.text = ns.substring(with: NSRange(location: a, length: b - a))
        response.firstLine = first
        return response
    }

    private func search(_ request: AgentRequest, document url: URL, text: String, starts: [Int], root: URL?, reply: @escaping (AgentResponse) -> Void) {
        guard let query = request.query, !query.isEmpty else { return reply(AgentResponse(error: "Empty query.")) }
        guard request.folder != true || root != nil else { return reply(AgentResponse(error: "No folder scope is open in Zephyr, so only the document itself can be searched.")) }
        if request.folder != true {
            let ns = text as NSString
            var matches: [AgentMatch] = []
            var at = NSRange(location: 0, length: ns.length)
            while matches.count < 200 {
                let found = ns.range(of: query, options: [.caseInsensitive, .literal], range: at)
                guard found.location != NSNotFound else { break }
                let line = LineNumbers.line(at: found.location, starts: starts)
                if matches.last?.line != line {
                    let lineRange = ns.lineRange(for: found)
                    matches.append(AgentMatch(file: url.lastPathComponent, line: line, text: String(ns.substring(with: lineRange).trimmingCharacters(in: .newlines).prefix(240))))
                }
                at = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
            }
            var response = AgentResponse()
            response.matches = matches
            return reply(response)
        }
        guard let root else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var limits = FolderScanner.Limits()
            limits.maxResults = 200
            var matches: [AgentMatch] = []
            FolderScanner.search(query, in: FolderScanner.markdownFiles(in: root), limits: limits, isCancelled: { false }) { batch in
                matches += batch.map { AgentMatch(file: $0.file.relativePath, line: $0.line, text: $0.snippet) }
            }
            var response = AgentResponse()
            response.matches = matches
            DispatchQueue.main.async { reply(response) }
        }
    }
}
