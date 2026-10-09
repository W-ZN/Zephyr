import Foundation
import ZephyrCore

/// `zephyr mcp`: a Model Context Protocol server on stdio (design §11), newline-delimited JSON-RPC.
/// Four document tools over the same GUI channel as the CLI, and two appearance tools on the
/// theme files; descriptions stay short so the initial tool context is well under 2,000 tokens
/// (design §10).
enum MCPServer {
    static var clientName = "MCP client"

    /// The shared document tools (design §21.6), with the session argument for several shares.
    static let tools: [[String: Any]] = DocumentTools.Name.allCases.map { name in
        let (description, schema) = DocumentTools.definition(name, session: true)
        return ["name": name.rawValue, "description": description, "inputSchema": schema]
    } + AppearanceTools.names.map { name in
        let (description, schema) = AppearanceTools.definition(name)
        return ["name": name, "description": description, "inputSchema": schema]
    }

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            let id = message["id"]
            let params = message["params"] as? [String: Any] ?? [:]
            guard let method = message["method"] as? String else { continue }
            guard let id else { continue }  // notifications (initialized, cancelled) need no answer
            switch method {
            case "initialize":
                if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String { clientName = "\(name) (MCP)" }
                let version = params["protocolVersion"] as? String ?? "2025-06-18"
                respond(id, ["protocolVersion": version, "capabilities": ["tools": [:]], "serverInfo": ["name": "zephyr", "version": "0.1.1"],
                             "instructions": "Work on the Markdown document the user shared from Zephyr. Edits are proposals the user approves in Zephyr. get_appearance and set_appearance read and change how Zephyr shows documents, never the files."])
            case "ping":
                respond(id, [:])
            case "tools/list":
                respond(id, ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let (text, isError) = call(name, arguments)
                respond(id, ["content": [["type": "text", "text": text]], "isError": isError])
            default:
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
        exit(0)
    }

    static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        // The appearance tools edit the theme files directly; the app shows the change with Undo.
        if AppearanceTools.names.contains(name) { return AppearanceTools.run(name, arguments: args) }
        var request: AgentRequest
        switch DocumentTools.request(name, arguments: args) {
        case let .success(r): request = r
        case let .failure(error): return (error.message, true)
        }
        if request.op == .propose { request.wait = true }
        request.client = clientName
        guard let response = AgentChannel.call(request, timeout: request.op == .propose ? AgentCommands.reviewTimeout : nil) else {
            return ("pending: the user has not decided yet; the review stays open in Zephyr.", false)
        }
        return (DocumentTools.result(of: response, for: request.op), response.error != nil)
    }

    static func respond(_ id: Any, _ result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
