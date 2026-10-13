import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The local channel between the GUI and `zephyr` / `zephyr mcp` (design §11): a Unix socket in the
/// app's own data folder, one JSON request and one JSON response per connection, each a line.
/// Clients can only read what the GUI has granted and submit proposals; approval stays in the GUI.
public struct AgentRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable { case sessions, context, read, search, propose }
    public var op: Op
    /// The grant the request uses; may be omitted when exactly one is active.
    public var session: String?
    /// `read`: a file in the session's folder scope (default: the granted document, as currently edited).
    public var path: String?
    /// `read`: first and last line, 1-based and inclusive.
    public var lines: [Int]?
    /// `search`: literal text; `folder` searches the folder scope instead of the document.
    public var query: String?
    public var folder: Bool?
    /// `search`: rank passages of the folder scope by relevance to the words of `query` instead
    /// of matching its text literally.
    public var related: Bool?
    /// `propose`
    public var edits: [ProposedEdit]?
    public var summary: String?
    public var baseRevision: String?
    /// `propose`: answer when the user has decided instead of right away.
    public var wait: Bool?
    /// Who is asking (shown in the review, never trusted).
    public var client: String?

    public init(op: Op) { self.op = op }
}

public struct AgentSession: Codable, Sendable {
    public var id: String
    public var document: String
    public var title: String
    public var expires: Date
    public init(id: String, document: String, title: String, expires: Date) {
        self.id = id
        self.document = document
        self.title = title
        self.expires = expires
    }
}

public struct AgentHeading: Codable, Sendable {
    public var level: Int
    public var title: String
    public var line: Int
    public init(level: Int, title: String, line: Int) {
        self.level = level
        self.title = title
        self.line = line
    }
}

public struct AgentContext: Codable, Sendable {
    public var document: String
    public var title: String
    public var revision: String
    public var lineCount: Int
    public var unsaved: Bool
    public var selection: String?
    /// First and last selected line, 1-based.
    public var selectionLines: [Int]?
    public var headings: [AgentHeading]
    public var scopeRoot: String
    /// The user's standing instructions for every agent (Settings → Agents), if any.
    public var instructions: String?
    public init(document: String, title: String, revision: String, lineCount: Int, unsaved: Bool, selection: String?, selectionLines: [Int]?, headings: [AgentHeading], scopeRoot: String, instructions: String? = nil) {
        self.document = document
        self.title = title
        self.revision = revision
        self.lineCount = lineCount
        self.unsaved = unsaved
        self.selection = selection
        self.selectionLines = selectionLines
        self.headings = headings
        self.scopeRoot = scopeRoot
        self.instructions = instructions
    }
}

public struct AgentMatch: Codable, Sendable {
    public var file: String
    public var line: Int
    public var text: String
    public init(file: String, line: Int, text: String) {
        self.file = file
        self.line = line
        self.text = text
    }
}

public struct AgentResponse: Codable, Sendable {
    public var error: String?
    public var sessions: [AgentSession]?
    public var context: AgentContext?
    /// `read`: the text, starting at line `firstLine`.
    public var text: String?
    public var firstLine: Int?
    public var revision: String?
    public var matches: [AgentMatch]?
    public var proposal: String?
    /// `propose`: pending, applied or discarded.
    public var status: String?

    public init(error: String? = nil) { self.error = error }
}

public enum AgentChannel {
    /// `~/Library/Application Support/Zephyr/agent.sock` (the app's own data folder, design §3.3).
    public static func socketPath() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Zephyr/agent.sock").path
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// A listening socket only this user can connect to; a stale socket file is replaced.
    public static func listening(at path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        // The folder is private to this user, so nobody else can reach the socket even before chmod.
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard chmod(folder, 0o700) == 0 else { return nil }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    public static func connecting(to path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if ok != 0 {
            close(fd)
            return nil
        }
        ignoreBrokenPipe(fd)
        return fd
    }

    /// A peer that hangs up must not end the process with SIGPIPE.
    public static func ignoreBrokenPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Write one JSON line.
    public static func send<T: Encodable>(_ value: T, on fd: Int32) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(value) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Read one JSON line (at most `limit` bytes).
    public static func receive<T: Decodable>(_ type: T.Type, from fd: Int32, limit: Int = 16 << 20) -> T? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[n - 1] == 0x0A { break }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    /// One request and its response (the client side). An error response when Zephyr cannot be
    /// reached; nil when it did not answer within `timeout` (a proposal still under review).
    public static func call(_ request: AgentRequest, timeout: TimeInterval? = nil, path: String = socketPath()) -> AgentResponse? {
        guard let fd = connecting(to: path) else { return AgentResponse(error: "Zephyr is not running, or no document allows agent access.") }
        defer { close(fd) }
        if let timeout {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        guard send(request, on: fd) else { return AgentResponse(error: "Could not reach Zephyr.") }
        return receive(AgentResponse.self, from: fd)
    }
}
