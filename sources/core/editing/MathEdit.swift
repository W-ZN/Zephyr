import Foundation

/// Display math edits (design §8 "编辑公式"): the attached editor shows the TeX without delimiters
/// or container prefixes and writes it back inside the original delimiters. `source` is the math
/// component's text, from the opening `$$` / `\[` through the closing one; `prefix` is what stands
/// before it on its first line (quote markers, list indentation), repeated on every new line.
public enum MathEdit {
    static func delimiters(_ source: String) -> (open: String, close: String)? {
        if source.hasPrefix("$$"), source.hasSuffix("$$"), source.utf16.count >= 4 { return ("$$", "$$") }
        if source.hasPrefix("\\["), source.hasSuffix("\\]"), source.utf16.count >= 4 { return ("\\[", "\\]") }
        return nil
    }

    /// The TeX as the user edits it: no delimiters, no prefixes, no blank first or last line.
    public static func tex(in source: String, prefix: String) -> String? {
        guard let (open, close) = delimiters(source) else { return nil }
        let ns = source as NSString
        let inner = ns.substring(with: NSRange(location: (open as NSString).length, length: ns.length - (open as NSString).length - (close as NSString).length))
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        var lines = inner.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for i in lines.indices.dropFirst() where !prefix.isEmpty {
            if lines[i].hasPrefix(prefix) { lines[i].removeFirst(prefix.count) } else if lines[i].trimmingCharacters(in: .whitespaces) == trimmedPrefix { lines[i] = "" }
        }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The source with `tex` inside the original delimiters. A one-line formula stays on one line;
    /// otherwise each delimiter gets its own line and every line carries the prefix.
    public static func replacingTeX(in source: String, with tex: String, prefix: String, newline: String = "\n") -> String? {
        guard let (open, close) = delimiters(source) else { return nil }
        let lines = tex.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: CharacterSet(charactersIn: "\n\r"))
        if !source.contains(where: \.isNewline), lines.count == 1 { return open + tex + close }
        return open + lines.map { newline + prefix + $0 }.joined() + newline + prefix + close
    }
}
