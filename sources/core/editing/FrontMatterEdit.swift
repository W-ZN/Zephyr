import Foundation

/// Property edits (design §6, §8): only top-level single-line scalars change, and only the value's
/// own bytes; key, comments, order and every other byte stay as they are.
public enum FrontMatterEdit {
    /// The patch that sets `entry` to `value`, or nil when the entry is not an editable scalar
    /// (sequences, multi-line values: those are edited as source) or nothing changes. An empty
    /// `value` removes the value's bytes, leaving `key:` (null), as other editors write it.
    public static func patch(setting entry: FrontMatterModel.Entry, to value: String, in text: String) -> TextPatch? {
        guard entry.valueRange.location != NSNotFound, !value.contains("\n"), !value.contains("\r") else { return nil }
        let ns = text as NSString
        let old = ns.substring(with: entry.valueRange)
        if value.isEmpty { return old.isEmpty ? nil : TextPatch(range: entry.valueRange, replacement: "") }
        let quote = old.first.flatMap { $0 == "\"" || $0 == "'" ? $0 : nil }
        let raw: String
        switch quote {
        case "'": raw = "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        case "\"": raw = doubleQuoted(value)
        default:
            // Reserved words are quoted to stay strings, unless the old value was not a string
            // (empty, boolean, null, number): typing `false` into `draft:` means the boolean.
            let wasString = !old.isEmpty && !reserved.contains(old.lowercased()) && Double(old) == nil
            let keepsKind = !wasString && reserved.contains(value.lowercased())
            raw = needsQuotes(value) && !keepsKind ? doubleQuoted(value) : value
        }
        // `key:` with nothing after the colon needs the separating space.
        let start = entry.valueRange.location
        let spaced = old.isEmpty && start > 0 && ns.character(at: start - 1) == 0x3A ? " " + raw : raw
        return raw == old ? nil : TextPatch(range: entry.valueRange, replacement: spaced)
    }

    static func doubleQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Whether a plain YAML scalar would change meaning or fail to parse.
    static func needsQuotes(_ value: String) -> Bool {
        guard let first = value.first, let last = value.last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) { return true }
        if value.contains(": ") || value.contains(" #") || value.hasSuffix(":") { return true }
        return reserved.contains(value.lowercased())
    }

    static let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~"]
}
