import AppKit

/// Formatting commands. Each one is a minimal, undoable text edit (design §8: interactions
/// produce the smallest possible change to the Markdown source).
extension MarkdownEditor {
    /// Wrap the selection in `marker` (`**`, `*`, `~~`, `` ` ``) or unwrap it when already wrapped.
    public func toggleWrap(_ marker: String) {
        guard isEditable else { return }
        let ns = source
        let sel = selection
        let m = (marker as NSString).length
        let before = NSRange(location: sel.location - m, length: m)
        let after = NSRange(location: NSMaxRange(sel), length: m)
        if before.location >= 0, NSMaxRange(after) <= ns.length,
           ns.substring(with: before) == marker, ns.substring(with: after) == marker {
            editUndo?.beginUndoGrouping()
            replace(after, with: "")
            replace(before, with: "")
            editUndo?.endUndoGrouping()
            selection = NSRange(location: sel.location - m, length: sel.length)
            return
        }
        let selected = ns.substring(with: sel)
        if selected.hasPrefix(marker), selected.hasSuffix(marker), sel.length >= 2 * m {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
            replace(sel, with: inner)
            selection = NSRange(location: sel.location, length: (inner as NSString).length)
            return
        }
        replace(sel, with: marker + selected + marker)
        selection = NSRange(location: sel.location + m, length: sel.length)
    }

    public func insertLink() {
        guard isEditable else { return }
        let ns = source
        let sel = selection
        let text = ns.substring(with: sel)
        let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = pasted.hasPrefix("http://") || pasted.hasPrefix("https://") ? pasted : ""
        replace(sel, with: "[\(text)](\(url))")
        if text.isEmpty {
            selection = NSRange(location: sel.location + 1, length: 0)
        } else {
            selection = NSRange(location: sel.location + (text as NSString).length + 3, length: (url as NSString).length)
        }
    }

    /// Lines touched by the selection, as (range without terminator) pairs.
    private func selectedLines() -> [NSRange] {
        let ns = source
        let sel = selection
        let all = ns.lineRange(for: sel)
        var lines: [NSRange] = []
        var pos = all.location
        repeat {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: pos, length: 0))
            lines.append(NSRange(location: start, length: contentsEnd - start))
            pos = end
        } while pos < NSMaxRange(all)
        return lines
    }

    /// Set the heading level of the selected lines (0 = body text).
    public func setHeading(_ level: Int) {
        guard isEditable else { return }
        let ns = source
        let regex = try! NSRegularExpression(pattern: #"^(\s{0,3})(#{1,6}[ \t]+|#{1,6}$)?"#)
        editUndo?.beginUndoGrouping()
        for line in selectedLines().reversed() {
            let text = ns.substring(with: line)
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { continue }
            let existing = match.range(at: 2)
            let prefix = level > 0 ? String(repeating: "#", count: level) + " " : ""
            let target = existing.location == NSNotFound
                ? NSRange(location: line.location + match.range(at: 1).length, length: 0)
                : NSRange(location: line.location + existing.location, length: existing.length)
            replace(target, with: prefix)
        }
        editUndo?.endUndoGrouping()
    }

    /// Toggle a line prefix (`- `, `1. `, `- [ ] `, `> `) on the selected lines.
    public func toggleLinePrefix(_ kind: String) {
        guard isEditable else { return }
        let ns = source
        let lines = selectedLines()
        let pattern: String
        switch kind {
        case "quote": pattern = #"^(\s*)> ?"#
        case "task": pattern = #"^(\s*)[-*+] \[[ xX]\] "#
        case "number": pattern = #"^(\s*)\d+[.)] "#
        default: pattern = #"^(\s*)[-*+] (?!\[[ xX]\] )"#
        }
        let regex = try! NSRegularExpression(pattern: pattern)
        let allHave = lines.allSatisfy { line in
            let text = ns.substring(with: line)
            return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
        editUndo?.beginUndoGrouping()
        for (offset, line) in lines.enumerated().reversed() {
            let text = ns.substring(with: line)
            let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            if allHave, let match {
                let indent = match.range(at: 1).length
                replace(NSRange(location: line.location + indent, length: match.range.length - indent), with: "")
            } else if match == nil {
                let indent = text.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let prefix: String
                switch kind {
                case "quote": prefix = "> "
                case "task": prefix = "- [ ] "
                case "number": prefix = "\(offset + 1). "
                default: prefix = "- "
                }
                replace(NSRange(location: line.location + indent, length: 0), with: prefix)
            }
        }
        editUndo?.endUndoGrouping()
    }

    public func insertCodeBlock() {
        guard isEditable else { return }
        let sel = selection
        let ns = source
        let body = ns.substring(with: sel)
        let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let lead = sel.location > lineStart ? newline : ""
        replace(sel, with: lead + "```" + newline + body + newline + "```" + newline)
        selection = NSRange(location: sel.location + (lead as NSString).length + 3, length: 0)
    }
}
