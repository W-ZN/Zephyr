import Foundation

/// The document operations every agent uses (design §21.6): the built-in AI, `zephyr` and
/// `zephyr mcp` share these tools, arguments and text results. Running them belongs to the GUI's
/// document session; this type only defines them, parses arguments and renders results, so a new
/// capability added here reaches every entry at once.
public enum DocumentTools {
    public enum Name: String, CaseIterable, Sendable {
        case getContext = "get_context", search, read, proposePatch = "propose_patch"

        public var op: AgentRequest.Op {
            switch self {
            case .getContext: .context
            case .read: .read
            case .search: .search
            case .proposePatch: .propose
            }
        }
    }

    public struct ToolError: Error, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Description and JSON schema of a tool. `session` adds the session argument the
    /// out-of-process transports need when several documents are shared.
    public static func definition(_ name: Name, session: Bool) -> (description: String, schema: [String: Any]) {
        var properties: [String: Any]
        var required: [String] = []
        let description: String
        switch name {
        case .getContext:
            description = "The document the user shared from Zephyr: path, revision, line count, unsaved state, the user's selection (text and lines), headings with line numbers, and its folder scope. Call this first."
            properties = [:]
        case .read:
            description = "Read the document as currently edited (unsaved changes included), or a file inside its folder scope via path. Lines come numbered; lines=[first, last] reads a range, for example one section from the outline."
            properties = ["path": ["type": "string", "description": "Relative to the folder scope; omit for the document."],
                          "lines": ["type": "array", "items": ["type": "integer"], "minItems": 2, "maxItems": 2]]
        case .search:
            description = "Find literal text (case-insensitive) in the document, or with folder=true in the Markdown files of its folder scope. Returns file:line: text."
            properties = ["query": ["type": "string"], "folder": ["type": "boolean"]]
            required = ["query"]
        case .proposePatch:
            description = "Propose edits to the document. Each edit replaces the only occurrence of `find` (exact current text; include enough context to be unique) with `replace`. The user reviews it in Zephyr and applies or discards it; nothing changes without approval."
            properties = ["edits": ["type": "array", "items": ["type": "object", "properties": ["find": ["type": "string"], "replace": ["type": "string"]],
                                                              "required": ["find", "replace"], "additionalProperties": false]],
                          "summary": ["type": "string", "description": "One sentence shown to the user."],
                          "base_revision": ["type": "string", "description": "Revision from get_context or read."]]
            required = ["summary", "edits"]
        }
        if session { properties["session"] = ["type": "string", "description": "Only when several documents are shared."] }
        return (description, ["type": "object", "properties": properties, "required": required])
    }

    /// The request a tool call stands for, after a strict check of its arguments (model output
    /// is untrusted: wrong types are refused, never coerced).
    public static func request(_ tool: String, arguments a: [String: Any]) -> Result<AgentRequest, ToolError> {
        guard let name = Name(rawValue: tool) else { return .failure(ToolError("Unknown tool \(tool).")) }
        var request = AgentRequest(op: name.op)
        if let session = a["session"] {
            guard let s = session as? String else { return .failure(ToolError("session must be a string.")) }
            request.session = s
        }
        switch name {
        case .getContext:
            break
        case .read:
            if let path = a["path"] {
                guard let p = path as? String else { return .failure(ToolError("path must be a string.")) }
                request.path = p
            }
            if let lines = a["lines"] {
                guard let l = lines as? [Any], l.count == 2, let first = integer(l[0]), let last = integer(l[1]), first >= 1, last >= first else {
                    return .failure(ToolError("lines must be [first, last]: whole numbers, 1 or more, first not after last."))
                }
                request.lines = [first, last]
            }
        case .search:
            guard let query = a["query"] as? String, !query.isEmpty else { return .failure(ToolError("query must be a non-empty string.")) }
            request.query = query
            if let folder = a["folder"] {
                guard let f = folder as? Bool else { return .failure(ToolError("folder must be true or false.")) }
                request.folder = f
            }
        case .proposePatch:
            guard let summary = a["summary"] as? String, let raw = a["edits"] as? [[String: Any]], !raw.isEmpty else {
                return .failure(ToolError("propose_patch needs a summary and a non-empty edits array of {find, replace}."))
            }
            var edits: [ProposedEdit] = []
            for e in raw {
                guard let find = e["find"] as? String, let replace = e["replace"] as? String, !find.isEmpty else {
                    return .failure(ToolError("Each edit needs a non-empty string find and a string replace."))
                }
                edits.append(ProposedEdit(find: find, replace: replace))
            }
            request.edits = edits
            request.summary = summary
            if let base = a["base_revision"] {
                guard let b = base as? String else { return .failure(ToolError("base_revision must be a string.")) }
                request.baseRevision = b
            }
        }
        return .success(request)
    }

    /// A JSON whole number: not a boolean, not a fraction, within Int.
    static func integer(_ value: Any) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: n.doubleValue)
    }

    /// The text a tool call returns (the same for the built-in AI, the CLI and MCP).
    public static func result(of response: AgentResponse, for op: AgentRequest.Op) -> String {
        if let error = response.error { return error }
        switch op {
        case .context: return response.context.map(describe) ?? ""
        case .search:
            let matches = response.matches ?? []
            return matches.isEmpty ? "No matches." : matches.map { "\($0.file):\($0.line): \($0.text)" }.joined(separator: "\n")
        case .read:
            let body = numbered(response.text ?? "", from: response.firstLine ?? 1)
            return response.revision.map { "revision: \($0)\n" + body } ?? body
        case .propose: return response.status ?? "pending"
        case .sessions: return (response.sessions ?? []).map { "\($0.id)  \($0.document)" }.joined(separator: "\n")
        }
    }

    /// The context card: what an agent needs to start, without the text itself.
    public static func describe(_ c: AgentContext) -> String {
        var out = ["document: \(c.document)", "revision: \(c.revision)", "lines: \(c.lineCount)\(c.unsaved ? " (unsaved changes)" : "")"]
        if !c.scopeRoot.isEmpty { out.append("scope: \(c.scopeRoot)") }
        if let i = c.instructions, !i.isEmpty { out.append("user instructions (follow them):\n\(i)") }
        if let s = c.selection, let lines = c.selectionLines { out.append("selection (lines \(lines[0])–\(lines[1])):\n\(s)") }
        if !c.headings.isEmpty {
            out.append("outline (line, heading):")
            out += c.headings.map { String(repeating: "  ", count: $0.level - 1) + "\($0.line)  \($0.title)" }
        }
        return out.joined(separator: "\n")
    }

    /// Lines prefixed with their numbers, starting at `first`.
    public static func numbered(_ text: String, from first: Int) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: CharacterSet(charactersIn: "\n\r"))
        if lines.last == "" { lines.removeLast() }
        return lines.enumerated().map { "\($0.offset + first)\t\($0.element)" }.joined(separator: "\n")
    }
}
