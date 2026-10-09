import Foundation

/// Colors for code in fenced blocks (design §8.1): one left-to-right pass over a block that marks
/// keywords, strings, numbers, comments, function names, types and keys, from a small table per
/// language family. It is not a parser: what it does not recognize stays the text's color, and a
/// block never costs more than one scan of its characters. Portable (no AppKit), so the CLI and
/// tests can read the same tokens the editor colors.
public enum CodeSyntax {
    public enum Role: Sendable, Equatable {
        case keyword, string, number, comment, function, type, property, inserted, deleted
    }

    public struct Token: Sendable, Equatable {
        public var role: Role
        /// UTF-16 range in the scanned text.
        public var range: NSRange
    }

    public struct Language: Sendable {
        enum Kind: Sendable { case code, markup, config, diff, css }
        var kind = Kind.code
        var lineComments: [String] = []
        var blockComments: [(open: String, close: String)] = []
        /// Longest first: `"""` before `"`.
        var quotes: [String] = ["\"", "'"]
        var keywords: Set<String> = []
        var literals: Set<String> = []
        var types: Set<String> = []
        /// Names colored as functions without parentheses (`puts`, `echo`).
        var builtins: Set<String> = []
        /// Words after which a name is being defined: `func name`, `def name`.
        var definers: Set<String> = []
        var caseInsensitive = false
        /// A capitalized name is a type (Swift, Java, Rust, …).
        var capitalizedTypes = true
        /// Capitalized names before `(` are calls, not types (C#'s and Go's methods).
        var capitalizedCalls = false
        /// A quoted string or word right before `:` is a key (JSON, object literals).
        var keys = false
        /// A sigil and the word after it, and the role they take: `$name`, `@decorator`, `#include`.
        var sigils: [UInt16: Role] = [:]
        /// `#` starts a comment only at the start of a word (shells: `a#b` is one word).
        var commentNeedsSpace = false
        /// `/* /* */ */` nests (Swift, Rust, Kotlin).
        var nestedComments = false
        /// The first word of a command is the command (shells), and `-f`, `--force` are options.
        var commands = false
        /// `name!(` and `name!` are macros (Rust).
        var macros = false
        /// Letters that may prefix a string: `f"…"`, `r'…'`, `b"…"`.
        var stringPrefixes: Set<String> = []
    }

    /// The language a fence's info string names (`json`, `py`, `bash`, …), or nil.
    public static func language(_ info: String?) -> Language? {
        guard let word = info?.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first?.lowercased() else { return nil }
        return aliases[word].flatMap { languages[$0] }
    }

    public static func supports(_ info: String?) -> Bool { language(info) != nil }

    public static func tokens(_ code: String, language: Language) -> [Token] {
        var scanner = Scanner(Array(code.utf16), language)
        scanner.run()
        return scanner.tokens
    }

    // MARK: Languages

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    private static let cComments: (line: [String], block: [(open: String, close: String)]) = (["//"], [("/*", "*/")])

    static let languages: [String: Language] = {
        var l: [String: Language] = [:]
        l["json"] = Language(lineComments: cComments.line, blockComments: cComments.block, quotes: ["\""], literals: words("true false null"), capitalizedTypes: false, keys: true)
        l["swift"] = Language(lineComments: cComments.line, blockComments: cComments.block, quotes: ["\"\"\"", "\""],
                              keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as is try await async throws some any self Self super actor nonisolated isolated mutating nonmutating override required convenience final lazy weak unowned dynamic indirect get set willSet didSet consuming borrowing package macro"),
                              literals: words("true false nil"), definers: words("func"), sigils: [0x40: .type, 0x23: .keyword], nestedComments: true)
        l["c"] = Language(lineComments: cComments.line, blockComments: cComments.block,
                          keywords: words("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool class namespace template typename public private protected virtual override final new delete this throw try catch using operator friend explicit mutable constexpr consteval noexcept static_cast dynamic_cast reinterpret_cast const_cast decltype co_await co_return co_yield concept requires import module self super id instancetype"),
                          literals: words("true false NULL nullptr nil YES NO"), sigils: [0x23: .keyword, 0x40: .keyword])
        l["java"] = Language(lineComments: cComments.line, blockComments: cComments.block, quotes: ["\"\"\"", "\"", "'"],
                             keywords: words("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while var record sealed permits yield"),
                             literals: words("true false null"), sigils: [0x40: .type])
        l["kotlin"] = Language(lineComments: cComments.line, blockComments: cComments.block, quotes: ["\"\"\"", "\"", "'"],
                               keywords: words("as break class continue do else for fun if in interface is object package return super this throw try typealias typeof val var when while by catch constructor finally get import init set where abstract annotation companion const data enum expect external final infix inline inner internal lateinit open operator out override private protected public reified sealed suspend tailrec vararg"),
                               literals: words("true false null"), definers: words("fun"), sigils: [0x40: .type], nestedComments: true)
        l["csharp"] = Language(lineComments: cComments.line, blockComments: cComments.block,
                               keywords: words("abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw try typeof uint ulong unchecked unsafe ushort using virtual void volatile while var async await dynamic get set value yield record init required"),
                               literals: words("true false null"), capitalizedCalls: true, sigils: [0x23: .keyword])
        l["go"] = Language(lineComments: cComments.line, blockComments: cComments.block, quotes: ["\"", "'", "`"],
                           keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
                           literals: words("true false nil iota"), types: words("int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 float64 complex64 complex128 string bool byte rune error any"),
                           definers: words("func"), capitalizedCalls: true)
        l["rust"] = Language(lineComments: cComments.line, blockComments: cComments.block, quotes: ["\""],
                             keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while"),
                             literals: words("true false"), types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
                             definers: words("fn"), sigils: [0x23: .type], nestedComments: true, macros: true)
        l["javascript"] = Language(lineComments: cComments.line, blockComments: cComments.block, quotes: ["\"", "'", "`"],
                                   keywords: words("break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield async await of static get set from as interface type enum implements namespace declare readonly abstract private protected public keyof infer satisfies"),
                                   literals: words("true false null undefined NaN Infinity"), types: words("string number boolean any unknown never object symbol bigint"),
                                   definers: words("function"), keys: true, sigils: [0x40: .type])
        l["python"] = Language(lineComments: ["#"], quotes: ["\"\"\"", "'''", "\"", "'"],
                               keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"),
                               literals: words("True False None"), types: words("int float str bool list dict set tuple bytes object type"),
                               definers: words("def"), sigils: [0x40: .type], stringPrefixes: words("f r b u rb br fr rf F R B U"))
        l["ruby"] = Language(lineComments: ["#"],
                             keywords: words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield"),
                             literals: words("true false nil"), builtins: words("puts print p require require_relative attr_accessor attr_reader attr_writer include extend raise"),
                             definers: words("def"), sigils: [0x40: .property, 0x3A: .number])
        l["php"] = Language(lineComments: ["//", "#"], blockComments: cComments.block,
                            keywords: words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield"),
                            literals: words("true false null TRUE FALSE NULL"), definers: words("function"), caseInsensitive: false, sigils: [0x24: .property])
        l["shell"] = Language(lineComments: ["#"],
                              keywords: words("if then else elif fi case esac for while until do done in function select time return exit export local readonly declare unset shift break continue source alias set"),
                              literals: words("true false"), capitalizedTypes: false, sigils: [0x24: .property], commentNeedsSpace: true, commands: true)
        l["sql"] = Language(lineComments: ["--"], blockComments: cComments.block, quotes: ["'"],
                            keywords: words("SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE ALTER DROP INDEX VIEW JOIN INNER LEFT RIGHT FULL OUTER CROSS ON AS AND OR NOT IS IN EXISTS BETWEEN LIKE ILIKE GROUP BY ORDER HAVING LIMIT OFFSET UNION ALL DISTINCT CASE WHEN THEN ELSE END PRIMARY KEY FOREIGN REFERENCES DEFAULT CONSTRAINT UNIQUE CHECK WITH RETURNING ASC DESC IF BEGIN COMMIT ROLLBACK TRANSACTION GRANT REVOKE TRIGGER FUNCTION PROCEDURE RETURNS DECLARE REPLACE"),
                            literals: words("TRUE FALSE NULL"), types: words("INT INTEGER BIGINT SMALLINT TINYINT DECIMAL NUMERIC FLOAT REAL DOUBLE CHAR VARCHAR TEXT DATE TIME TIMESTAMP BOOLEAN BOOL BLOB JSON JSONB UUID SERIAL"),
                            caseInsensitive: true, capitalizedTypes: false)
        l["lua"] = Language(lineComments: ["--"], blockComments: [("--[[", "]]")],
                            keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
                            literals: words("true false nil"), definers: words("function"), capitalizedTypes: false)
        l["dockerfile"] = Language(lineComments: ["#"],
                                   keywords: words("FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS"),
                                   caseInsensitive: true, capitalizedTypes: false, sigils: [0x24: .property], commentNeedsSpace: true)
        l["config"] = Language(kind: .config, lineComments: ["#", ";"], literals: words("true false null yes no on off ~"), capitalizedTypes: false, commentNeedsSpace: true)
        l["markup"] = Language(kind: .markup)
        l["css"] = Language(kind: .css, blockComments: cComments.block, keywords: words("!important"), capitalizedTypes: false, sigils: [0x40: .keyword])
        l["diff"] = Language(kind: .diff)
        return l
    }()

    static let aliases: [String: String] = {
        var a: [String: String] = [:]
        let table: [String: String] = [
            "json": "json jsonc json5 geojson jsonl ndjson webmanifest",
            "swift": "swift",
            "c": "c h cpp c++ cc cxx hpp hh objc objective-c objectivec objc++ m mm cuda arduino ino",
            "java": "java groovy scala",
            "kotlin": "kotlin kt kts",
            "csharp": "csharp cs c# fsharp",
            "go": "go golang",
            "rust": "rust rs",
            "javascript": "javascript js jsx mjs cjs typescript ts tsx mts cts node deno",
            "python": "python py python3 py3 pyi gyp ipython",
            "ruby": "ruby rb gemfile podfile rake",
            "php": "php",
            "shell": "bash sh zsh shell console shellsession terminal fish ksh",
            "sql": "sql mysql postgresql postgres psql sqlite plsql tsql",
            "lua": "lua",
            "dockerfile": "dockerfile docker containerfile",
            "config": "yaml yml toml ini conf cfg properties env dotenv editorconfig gitconfig makefile mk",
            "markup": "html htm xml svg xhtml plist vue svelte xaml rss atom",
            "css": "css scss sass less",
            "diff": "diff patch",
        ]
        for (language, names) in table { for name in names.split(separator: " ") { a[String(name)] = language } }
        return a
    }()

    // MARK: Scanning

    private struct Scanner {
        let u: [UInt16]
        let n: Int
        let l: Language
        var tokens: [Token] = []
        /// The previous word, for `func name`.
        var previousWord = ""
        /// At the start of a shell command (a line, or after `|`, `;`, `&&`, `(`).
        var commandStart = true
        /// Inside `{ … }` in CSS: declarations, not selectors.
        var depth = 0
        /// The last selector lookahead: positions `from..<to` share its answer.
        var selectorSpan: (from: Int, to: Int, isSelector: Bool) = (0, 0, false)
        /// Shell keywords after which a command follows: `then echo`, `do make`.
        static let commandKeywords: Set<String> = ["then", "do", "else", "elif", "if", "while", "until", "time", "exec", "sudo"]

        init(_ u: [UInt16], _ l: Language) {
            self.u = u
            n = u.count
            self.l = l
        }

        mutating func run() {
            switch l.kind {
            case .code, .css: code(0, n)
            case .markup: markup()
            case .config: config()
            case .diff: diff()
            }
        }

        mutating func add(_ role: Role, _ start: Int, _ end: Int) {
            guard end > start else { return }
            tokens.append(Token(role: role, range: NSRange(location: start, length: end - start)))
        }

        func matches(_ s: String, at i: Int) -> Bool {
            var k = i
            for c in s.utf16 {
                guard k < n, u[k] == c else { return false }
                k += 1
            }
            return true
        }

        func find(_ s: String, from i: Int, before end: Int) -> Int? {
            var k = i
            while k < end {
                if matches(s, at: k) { return k }
                k += 1
            }
            return nil
        }

        func lineEnd(_ i: Int) -> Int {
            var k = i
            while k < n, u[k] != 0x0A, u[k] != 0x0D { k += 1 }
            return k
        }

        static func isWordStart(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
        static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
        static func isWord(_ c: UInt16) -> Bool { isWordStart(c) || isDigit(c) }
        static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 }

        func isWordChar(_ c: UInt16) -> Bool { Self.isWord(c) || (l.kind == .css && c == 0x2D) }

        /// The next character that is not a space or tab, from `i`.
        func next(_ i: Int, _ end: Int) -> UInt16? {
            var k = i
            while k < end, Self.isSpace(u[k]) { k += 1 }
            return k < end ? u[k] : nil
        }

        func word(_ start: Int, _ end: Int) -> String { String(utf16CodeUnits: Array(u[start..<end]), count: end - start) }

        /// A quoted string from `i` (at its quote); its end, past the closing quote.
        func string(_ i: Int, _ quote: String, _ end: Int) -> Int {
            let q = Array(quote.utf16)
            var k = i + q.count
            let multiline = q.count == 3 || q == [0x60]
            while k < end {
                let c = u[k]
                if c == 0x5C { k += 2; continue }
                if !multiline, c == 0x0A || c == 0x0D { return k }
                if matches(quote, at: k) { return k + q.count }
                k += 1
            }
            return end
        }

        // The general scanner, also used for the values of config files.
        mutating func code(_ start: Int, _ end: Int) {
            var i = start
            while i < end {
                let c = u[i]
                if c == 0x0A || c == 0x0D {
                    commandStart = true
                    i += 1
                    continue
                }
                if Self.isSpace(c) { i += 1; continue }
                // Comments.
                if l.lineComments.contains(where: { matches($0, at: i) }),
                   !l.commentNeedsSpace || i == start || Self.isSpace(u[i - 1]) || [0x0A, 0x0D, 0x3B, 0x7C, 0x26, 0x28].contains(u[i - 1]),
                   !l.blockComments.contains(where: { matches($0.open, at: i) }) {
                    let e = min(lineEnd(i), end)
                    add(.comment, i, e)
                    i = e
                    continue
                }
                if let block = l.blockComments.first(where: { matches($0.open, at: i) }) {
                    let e = l.nestedComments ? nestedCommentEnd(i, block, end) : (find(block.close, from: i + block.open.utf16.count, before: end).map { $0 + block.close.utf16.count } ?? end)
                    add(.comment, i, e)
                    i = e
                    continue
                }
                // Strings.
                if let quote = l.quotes.first(where: { matches($0, at: i) }) {
                    let e = string(i, quote, end)
                    let isKey = (l.keys || l.kind == .css) && next(e, end) == 0x3A && quote.utf16.count == 1
                    add(isKey ? .property : .string, i, e)
                    i = e
                    commandStart = false
                    continue
                }
                // Numbers: digits, then letters and dots (hex, exponents, units: `0x1F`, `1e-3`, `12px`).
                if Self.isDigit(c) || (c == 0x2E && i + 1 < end && Self.isDigit(u[i + 1]) && (i == start || !Self.isWord(u[i - 1]))) {
                    // Not the tail of a word: `x1`, `macos-15`.
                    guard i == start || (!isWordChar(u[i - 1]) && !(u[i - 1] == 0x2D && i - 1 > start && Self.isWord(u[i - 2]))) else {
                        while i < end, Self.isWord(u[i]) || u[i] == 0x2E { i += 1 }
                        continue
                    }
                    var k = i + 1
                    while k < end {
                        let d = u[k]
                        if Self.isWord(d) || d == 0x2E || d == 0x25 { k += 1; continue }
                        if (d == 0x2B || d == 0x2D), u[k - 1] == 0x65 || u[k - 1] == 0x45, !(i + 1 < n && (u[i + 1] == 0x78 || u[i + 1] == 0x58)) { k += 1; continue }
                        break
                    }
                    if l.kind == .css || !l.commands || !commandStart { add(.number, i, k) }
                    i = k
                    commandStart = false
                    continue
                }
                // Sigils: `$name`, `${name}`, `@decorator`, `#include`, `:symbol`.
                if let role = l.sigils[c], i + 1 < end, Self.isWordStart(u[i + 1]) || (c == 0x24 && (u[i + 1] == 0x7B || Self.isDigit(u[i + 1]))) {
                    // `a:b` in Ruby is not a symbol.
                    if c == 0x3A, i > start, Self.isWord(u[i - 1]) || u[i - 1] == 0x3A { i += 1; continue }
                    var k = i + 1
                    if u[k] == 0x7B, let close = find("}", from: k, before: min(end, k + 128)) { k = close + 1 }
                    else { while k < end, isWordChar(u[k]) || (l.kind == .css && u[k] == 0x2D) { k += 1 } }
                    add(role, i, k)
                    i = k
                    commandStart = false
                    continue
                }
                // A shell command: the whole word (`./build.sh`, `git`), or an assignment before it.
                if l.commands, commandStart, Self.isWordStart(c) || c == 0x2E || c == 0x2F || c == 0x7E {
                    var k = i + 1
                    while k < end, !Self.isSpace(u[k]), ![0x3B, 0x7C, 0x26, 0x28, 0x29, 0x3C, 0x3E, 0x0A, 0x0D, 0x3D].contains(u[k]) { k += 1 }
                    let w = word(i, k)
                    previousWord = w
                    if k < end, u[k] == 0x3D, w.utf16.allSatisfy(Self.isWord) {
                        // `NAME=value command`: the command still follows.
                        add(.property, i, k)
                        k += 1
                        if k < end, let quote = l.quotes.first(where: { matches($0, at: k) }) {
                            let e = string(k, quote, end)
                            add(.string, k, e)
                            k = e
                        } else {
                            while k < end, !Self.isSpace(u[k]), u[k] != 0x0A, u[k] != 0x0D { k += 1 }
                        }
                        i = k
                        continue
                    }
                    if l.keywords.contains(w) {
                        add(.keyword, i, k)
                        commandStart = Self.commandKeywords.contains(w)
                    } else {
                        add(.function, i, k)
                        commandStart = Self.commandKeywords.contains(w)
                    }
                    i = k
                    continue
                }
                // Shell options: `-f`, `--force`.
                if l.commands, c == 0x2D, i == start || Self.isSpace(u[i - 1]), i + 1 < end, Self.isWordStart(u[i + 1]) || u[i + 1] == 0x2D {
                    var k = i + 1
                    while k < end, Self.isWord(u[k]) || u[k] == 0x2D { k += 1 }
                    add(.type, i, k)
                    i = k
                    continue
                }
                if Self.isWordStart(c) || (l.kind == .css && c == 0x2D && i + 1 < end && (Self.isWordStart(u[i + 1]) || u[i + 1] == 0x2D)) {
                    var k = i + 1
                    while k < end, isWordChar(u[k]) { k += 1 }
                    // `defined?` and `!important`-like endings belong to the word only for keywords.
                    if k < end, u[k] == 0x3F, l.keywords.contains(word(i, k + 1)) { k += 1 }
                    let w = word(i, k)
                    // A prefixed string: `f"…"`.
                    if l.stringPrefixes.contains(w), k < end, let quote = l.quotes.first(where: { matches($0, at: k) }) {
                        let e = string(k, quote, end)
                        add(.string, i, e)
                        i = e
                        continue
                    }
                    if let role = role(of: w, start: i, end: k, limit: end) { add(role, i, k) }
                    previousWord = w
                    i = k
                    continue
                }
                if l.commands { commandStart = c == 0x7C || c == 0x3B || c == 0x26 || c == 0x28 }
                if l.kind == .css {
                    if c == 0x7B { depth += 1 } else if c == 0x7D { depth = max(0, depth - 1) }
                    // Colors in declarations: `#0f4a55`.
                    if c == 0x23, depth > 0, !selector(from: i, end) {
                        var k = i + 1
                        while k < end, Self.isWord(u[k]) { k += 1 }
                        add(.number, i, k)
                        i = k
                        continue
                    }
                    if c == 0x21, matches("!important", at: i) { add(.keyword, i, i + 10); i += 10; continue }
                }
                i += 1
            }
        }

        /// The end of a comment that may hold others: each opening needs its own close.
        func nestedCommentEnd(_ i: Int, _ block: (open: String, close: String), _ end: Int) -> Int {
            var depth = 0, k = i
            while k < end {
                if matches(block.open, at: k) { depth += 1; k += block.open.utf16.count; continue }
                if matches(block.close, at: k) {
                    depth -= 1
                    k += block.close.utf16.count
                    if depth == 0 { return k }
                    continue
                }
                k += 1
            }
            return end
        }

        /// In CSS, text before the next `{` (and not before a `;` or `}`) is a selector, even
        /// inside braces (`@media print { body { … } }`).
        /// The answer holds for every position up to the delimiter found, so each stretch of text is
        /// read once however many words it holds.
        mutating func selector(from i: Int, _ limit: Int) -> Bool {
            if i >= selectorSpan.from, i < selectorSpan.to { return selectorSpan.isSelector }
            var k = i
            while k < limit, u[k] != 0x7B, u[k] != 0x3B, u[k] != 0x7D { k += 1 }
            selectorSpan = (i, k, k < limit && u[k] == 0x7B)
            return selectorSpan.isSelector
        }

        mutating func role(of w: String, start: Int, end: Int, limit: Int) -> Role? {
            commandStart = false
            let key = l.caseInsensitive ? w.uppercased() : w
            let after = next(end, limit)
            if l.kind == .css {
                if depth == 0 || selector(from: end, limit) { return .keyword }
                return after == 0x3A ? .property : after == 0x28 ? .function : nil
            }
            if l.keywords.contains(key) { return .keyword }
            if l.literals.contains(key) { return .number }
            if l.types.contains(key) { return .type }
            if l.definers.contains(previousWord) { return .function }
            if ["class", "struct", "interface", "protocol", "enum", "trait", "type"].contains(previousWord) { return .type }
            if l.keys, after == 0x3A, !(end + 1 < limit && u[end + 1] == 0x3A) { return .property }
            // `Name(…)` builds a value of a type, except where methods are capitalized too.
            let capitalized = l.capitalizedTypes && w.utf16.count > 1 && (0x41...0x5A).contains(w.utf16.first!) && w.utf16.contains { $0 >= 0x61 && $0 <= 0x7A }
            if capitalized, !l.capitalizedCalls { return .type }
            if after == 0x28 { return .function }
            if l.macros, end < limit, u[end] == 0x21 { return .function }
            if l.builtins.contains(w) { return .function }
            return capitalized ? .type : nil
        }

        // HTML, XML, SVG: tags, attributes and their values, comments, entities.
        mutating func markup() {
            var i = 0
            while i < n {
                if matches("<!--", at: i) {
                    let e = find("-->", from: i + 4, before: n).map { $0 + 3 } ?? n
                    add(.comment, i, e)
                    i = e
                    continue
                }
                if u[i] == 0x3C, i + 1 < n, Self.isWordStart(u[i + 1]) || u[i + 1] == 0x2F || u[i + 1] == 0x3F || u[i + 1] == 0x21 {
                    var k = i + 1
                    if u[k] == 0x2F || u[k] == 0x3F || u[k] == 0x21 { k += 1 }
                    let nameStart = k
                    while k < n, Self.isWord(u[k]) || u[k] == 0x2D || u[k] == 0x3A || u[k] == 0x2E { k += 1 }
                    add(.keyword, nameStart, k)
                    // Attributes until `>`.
                    while k < n, u[k] != 0x3E {
                        let c = u[k]
                        if c == 0x22 || c == 0x27 {
                            let e = string(k, c == 0x22 ? "\"" : "'", n)
                            add(.string, k, e)
                            k = e
                        } else if Self.isWordStart(c) {
                            let s = k
                            while k < n, Self.isWord(u[k]) || u[k] == 0x2D || u[k] == 0x3A || u[k] == 0x2E { k += 1 }
                            add(.property, s, k)
                        } else {
                            k += 1
                        }
                    }
                    i = min(n, k + 1)
                    continue
                }
                if u[i] == 0x26, let semi = find(";", from: i + 1, before: min(n, i + 12)), semi > i + 1 {
                    add(.number, i, semi + 1)
                    i = semi + 1
                    continue
                }
                i += 1
            }
        }

        // YAML, TOML, INI, properties: keys, `[sections]`, comments, and values scanned as code.
        mutating func config() {
            var i = 0
            while i < n {
                let e = lineEnd(i)
                var k = i
                while k < e, Self.isSpace(u[k]) { k += 1 }
                if k < e, u[k] == 0x23 || u[k] == 0x3B {
                    add(.comment, k, e)
                } else if k < e, u[k] == 0x5B {
                    let close = find("]", from: k, before: e).map { $0 + 1 } ?? e
                    add(.type, k, close)
                    code(close, e)
                } else {
                    if matches("- ", at: k) { k += 2 }
                    // A key: up to `:` (then a space or the line's end) or `=`, before any quote or comment.
                    var s = k, keyEnd: Int?
                    while s < e {
                        let c = u[s]
                        if c == 0x22 || c == 0x27 || c == 0x23 { break }
                        if c == 0x3D || (c == 0x3A && (s + 1 == e || Self.isSpace(u[s + 1]))) { keyEnd = s; break }
                        s += 1
                    }
                    if let keyEnd, keyEnd > k {
                        var trimmed = keyEnd
                        while trimmed > k, Self.isSpace(u[trimmed - 1]) { trimmed -= 1 }
                        add(.property, k, trimmed)
                        code(keyEnd + 1, e)
                    } else {
                        code(k, e)
                    }
                }
                i = e < n ? e + 1 : n
            }
        }

        // Unified diffs: added and removed lines, hunk headers, file headers.
        mutating func diff() {
            var i = 0
            while i < n {
                let e = lineEnd(i)
                if matches("+++", at: i) || matches("---", at: i) || matches("diff ", at: i) || matches("index ", at: i) { add(.comment, i, e) }
                else if matches("@@", at: i) { add(.keyword, i, e) }
                else if i < e, u[i] == 0x2B { add(.inserted, i, e) }
                else if i < e, u[i] == 0x2D { add(.deleted, i, e) }
                i = e < n ? e + 1 : n
            }
        }
    }
}
