import Foundation

/// One edit of a proposal: replace the only occurrence of `find` with `replace`. Anchoring on
/// exact text (not offsets) lets a proposal made against one revision be checked against another.
public struct ProposedEdit: Codable, Sendable, Equatable {
    public var find: String
    public var replace: String

    public init(find: String, replace: String) {
        self.find = find
        self.replace = replace
    }
}

/// A change to one document that only the GUI may apply (design §10, §11): document + base
/// revision + edits + origin + id. AI, CLI and MCP all submit these; the user reviews them.
public struct EditProposal: Codable, Sendable, Equatable {
    public var id: String
    public var document: String
    public var baseRevision: String
    public var edits: [ProposedEdit]
    public var summary: String
    /// Who proposed it ("Zephyr AI", "zephyr CLI", an MCP client's name): shown, never trusted.
    public var origin: String

    public init(id: String = UUID().uuidString, document: String, baseRevision: String, edits: [ProposedEdit], summary: String, origin: String) {
        self.id = id
        self.document = document
        self.baseRevision = baseRevision
        self.edits = edits
        self.summary = summary
        self.origin = origin
    }
}

public enum ProposalError: Error, Equatable, CustomStringConvertible {
    case empty
    case notFound(Int)
    case ambiguous(Int)
    case overlapping(Int)

    public var description: String {
        switch self {
        case .empty: "The proposal has no edits."
        case let .notFound(i): "Edit \(i + 1): the text to replace is not in the document."
        case let .ambiguous(i): "Edit \(i + 1): the text to replace occurs more than once; include more context."
        case let .overlapping(i): "Edit \(i + 1) overlaps another edit."
        }
    }
}

/// An applied patch, remembered so it can be withdrawn later: where the new text now is, and what it replaced.
public struct AppliedPatch: Codable, Sendable, Equatable {
    public var location: Int
    public var inserted: String
    public var removed: String
}

public enum ProposalResolver {
    /// Patches for `edits` in `text`, in document order. Each `find` must occur exactly once;
    /// line breaks in the edits follow the document's (`newline`), so a CRLF file stays CRLF.
    public static func patches(for edits: [ProposedEdit], in text: String, newline: String = "\n") throws -> [TextPatch] {
        guard !edits.isEmpty else { throw ProposalError.empty }
        let ns = text as NSString
        func local(_ s: String) -> String {
            guard newline != "\n" else { return s }
            return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: newline)
        }
        var patches: [(index: Int, patch: TextPatch)] = []
        for (i, edit) in edits.enumerated() {
            let find = local(edit.find)
            guard !find.isEmpty else { throw ProposalError.notFound(i) }
            let first = ns.range(of: find, options: .literal)
            guard first.location != NSNotFound else { throw ProposalError.notFound(i) }
            if ns.range(of: find, options: .literal, range: NSRange(location: first.location + 1, length: ns.length - first.location - 1)).location != NSNotFound {
                throw ProposalError.ambiguous(i)
            }
            patches.append((i, TextPatch(range: first, replacement: local(edit.replace))))
        }
        patches.sort { $0.patch.range.location < $1.patch.range.location }
        for k in patches.indices.dropFirst() where patches[k].patch.range.location < NSMaxRange(patches[k - 1].patch.range) {
            throw ProposalError.overlapping(patches[k].index)
        }
        return patches.map(\.patch)
    }

    /// What `patches` (document order, against `text`) leave behind, for withdrawing them later.
    public static func applied(_ patches: [TextPatch], to text: String) -> [AppliedPatch] {
        let ns = text as NSString
        var shift = 0
        return patches.map { p in
            defer { shift += (p.replacement as NSString).length - p.range.length }
            return AppliedPatch(location: p.range.location + shift, inserted: p.replacement, removed: ns.substring(with: p.range))
        }
    }

    /// Patches (document order) that withdraw `applied` from `text`, or nil when any of that text has
    /// changed since: then the withdrawal goes to conflict review instead of overwriting (design §10).
    /// Positions are in the text after all patches, so `apply` (last first) keeps them valid.
    public static func withdrawal(of applied: [AppliedPatch], in text: String) -> [TextPatch]? {
        let ns = text as NSString
        var result: [TextPatch] = []
        for a in applied {
            let range = NSRange(location: a.location, length: (a.inserted as NSString).length)
            guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == a.inserted else { return nil }
            result.append(TextPatch(range: range, replacement: a.removed))
        }
        return result
    }

    /// Apply document-ordered patches to `text` (last first, so earlier ranges stay valid).
    public static func apply(_ patches: [TextPatch], to text: String) -> String {
        let out = NSMutableString(string: text)
        for p in patches.reversed() { out.replaceCharacters(in: p.range, with: p.replacement) }
        return out as String
    }
}

/// A short fingerprint of a text, naming a revision (FNV-1a over UTF-8). It detects change; it is
/// not a security measure.
public enum TextRevision {
    public static func of(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + "-" + String(text.utf8.count)
    }
}
