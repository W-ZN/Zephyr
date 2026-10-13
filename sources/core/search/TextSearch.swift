import Foundation

/// Find and replace inside one document (the Find bar's engine): a literal or regular-expression
/// query over UTF-16 text, with case, whole-word and pattern options. Pure and synchronous; the
/// document is the only input and nothing is kept between calls.
public struct TextSearch: Equatable, Sendable {
    public var query: String
    public var matchCase = false
    public var wholeWord = false
    public var regex = false

    public init(query: String, matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.query = query
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.regex = regex
    }

    public struct Result: Sendable {
        /// Non-overlapping matches in document order; empty matches are skipped.
        public var matches: [NSRange] = []
        /// More matches exist than `limit` allowed.
        public var truncated = false
        /// The regular expression is malformed.
        public var invalidPattern = false
    }

    /// Letters and digits that join a word, CJK excluded: Chinese and Japanese have no spaces, so
    /// a Latin word next to them still stands alone.
    private static let wordCharacter = #"[\p{L}\p{N}_&&[^⺀-꓏가-힯]]"#

    /// The ICU pattern for this query, or nil when a plain string search does the job.
    private func pattern() -> String? {
        if regex { return query }
        guard wholeWord else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: query)
        let scalars = query.unicodeScalars
        func joins(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return scalar == "_" || (CharacterSet.alphanumerics.contains(scalar) && !(0x2E80...0xA4CF).contains(scalar.value) && !(0xAC00...0xD7AF).contains(scalar.value))
        }
        return (joins(scalars.first) ? "(?<!\(Self.wordCharacter))" : "") + escaped + (joins(scalars.last) ? "(?!\(Self.wordCharacter))" : "")
    }

    private func compiled() throws -> NSRegularExpression? {
        guard let pattern = pattern() else { return nil }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !matchCase { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: options)
    }

    public func find(in text: NSString, limit: Int = 50_000) -> Result {
        var result = Result()
        guard !query.isEmpty else { return result }
        let whole = NSRange(location: 0, length: text.length)
        let expression: NSRegularExpression?
        do { expression = try compiled() } catch {
            result.invalidPattern = true
            return result
        }
        if let expression {
            expression.enumerateMatches(in: text as String, options: [], range: whole) { match, _, stop in
                guard let range = match?.range, range.length > 0 else { return }
                if result.matches.count >= limit { result.truncated = true; stop.pointee = true; return }
                result.matches.append(range)
            }
            return result
        }
        let options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var at = 0
        while at < text.length {
            let found = text.range(of: query, options: options, range: NSRange(location: at, length: text.length - at))
            guard found.location != NSNotFound, found.length > 0 else { break }
            if result.matches.count >= limit { result.truncated = true; break }
            result.matches.append(found)
            at = NSMaxRange(found)
        }
        return result
    }

    /// What each match becomes when replaced with `template`. A regular expression's template
    /// reads `$1` for a group and `\n`, `\t` for a line break and a tab; otherwise it is literal.
    public func replacements(for matches: [NSRange], in text: NSString, template: String) -> [String] {
        guard regex, let expression = try? compiled() else { return matches.map { _ in template } }
        let template = Self.unescaped(template)
        let string = text as String
        return matches.map { range in
            let rest = NSRange(location: range.location, length: text.length - range.location)
            guard let match = expression.firstMatch(in: string, options: [.withTransparentBounds, .withoutAnchoringBounds], range: rest), match.range == range else {
                return text.substring(with: range)
            }
            return expression.replacementString(for: match, in: string, offset: 0, template: template)
        }
    }

    private static func unescaped(_ template: String) -> String {
        var out = "", pending = false
        for c in template {
            if pending {
                pending = false
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append("\\"); out.append(c)
                }
            } else if c == "\\" {
                pending = true
            } else {
                out.append(c)
            }
        }
        if pending { out.append("\\") }
        return out
    }
}
