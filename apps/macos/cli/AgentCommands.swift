import Foundation
import ZephyrCore

/// `zephyr` commands that go through the GUI (design §11): they see only documents the user shared
/// (File → Allow Agent Access), read the text as currently edited, and can only propose changes.
enum AgentCommands {
    /// How long a waiting proposal keeps the connection before reporting it as still pending.
    static let reviewTimeout: TimeInterval = 120

    static func request(_ op: AgentRequest.Op, session: String?) -> AgentRequest {
        var r = AgentRequest(op: op)
        r.session = session
        r.client = "zephyr CLI"
        return r
    }

    /// The answer, or exit with its error.
    static func call(_ request: AgentRequest, timeout: TimeInterval? = nil) -> AgentResponse {
        guard let response = AgentChannel.call(request, timeout: timeout) else {
            var pending = AgentResponse()
            pending.status = "pending"
            return pending
        }
        if let error = response.error { fail(error) }
        return response
    }

    static func run(_ command: String, _ args: [String]) {
        var rest = args
        func option(_ name: String) -> String? {
            guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
            defer { rest.removeSubrange(i...(i + 1)) }
            return rest[i + 1]
        }
        func flag(_ name: String) -> Bool {
            guard let i = rest.firstIndex(of: name) else { return false }
            rest.remove(at: i)
            return true
        }
        let session = option("--session")
        switch command {
        case "sessions":
            let sessions = call(request(.sessions, session: nil)).sessions ?? []
            if sessions.isEmpty { print("No document allows agent access. In Zephyr, choose File → Allow Agent Access.") }
            for s in sessions { print("\(s.id)  \(s.document)") }
        case "context":
            guard let context = call(request(.context, session: session)).context else { fail("No context.") }
            print(DocumentTools.describe(context))
        case "read":
            var r = request(.read, session: session)
            if let lines = option("--lines") {
                let parts = lines.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { fail("--lines takes FIRST:LAST") }
                r.lines = parts
            }
            r.path = rest.first
            let response = call(r)
            print(DocumentTools.numbered(response.text ?? "", from: response.firstLine ?? 1))
        case "find":
            var r = request(.search, session: session)
            r.folder = flag("--folder")
            r.related = flag("--related") ? true : nil
            guard let query = rest.first else { fail(usage) }
            r.query = query
            for m in call(r).matches ?? [] { print("\(m.file):\(m.line): \(m.text)") }
        case "propose":
            var r = request(.propose, session: session)
            r.wait = flag("--wait")
            r.summary = option("--summary")
            if let json = option("--json") {
                let data = json == "-" ? FileHandle.standardInput.readDataToEndOfFile() : (FileManager.default.contents(atPath: json) ?? Data())
                struct Body: Decodable { var summary: String?; var edits: [ProposedEdit] }
                guard let body = try? JSONDecoder().decode(Body.self, from: data) else { fail(#"--json expects {"summary": "...", "edits": [{"find": "...", "replace": "..."}]}"#) }
                r.edits = body.edits
                r.summary = r.summary ?? body.summary
            } else {
                var edits: [ProposedEdit] = []
                while let find = option("--find") {
                    guard let replace = option("--replace") else { fail("each --find needs a --replace") }
                    edits.append(ProposedEdit(find: find, replace: replace))
                }
                r.edits = edits
            }
            let response = call(r, timeout: r.wait == true ? reviewTimeout : nil)
            print("\(response.status ?? "pending")\(response.proposal.map { "  \($0)" } ?? "")")
        default:
            fail(usage)
        }
    }
}
