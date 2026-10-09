import Foundation

/// A replacement of one UTF-16 range (design §5 text layer: edits are byte patches; ranges here are
/// UTF-16 because that is what the text system edits).
public struct TextPatch: Sendable, Equatable {
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// The smallest single patch turning `old` into `new`: common prefix and suffix stay untouched,
    /// so unrelated bytes are never rewritten (principle 9). Never splits a surrogate pair or CRLF.
    public static func minimal(from old: String, to new: String) -> TextPatch? {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if prefix == a.count, prefix == b.count { return nil }
        // Back off so the patch starts and ends on whole characters and whole CRLF pairs.
        func splits(_ units: [UInt16], _ i: Int) -> Bool {
            guard i > 0, i < units.count else { return false }
            return UTF16.isTrailSurrogate(units[i]) || (units[i - 1] == 0x0D && units[i] == 0x0A)
        }
        while prefix > 0, splits(a, prefix) || splits(b, prefix) { prefix -= 1 }
        while suffix > 0, splits(a, a.count - suffix) || splits(b, b.count - suffix) { suffix -= 1 }
        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return TextPatch(range: NSRange(location: prefix, length: a.count - suffix - prefix), replacement: replacement)
    }

    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}
