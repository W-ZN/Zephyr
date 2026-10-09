import Foundation

/// The HTML Zephyr draws itself (design §9): a small, safe subset that README files use for
/// centered headers, badges, banners and side-by-side images. Elements and attributes come from an
/// allowlist; comments are dropped and entities decoded. A fragment with any other element, an
/// unsafe URL or nothing to show does not parse, and its source shows as it is.
///
/// Parsing is lenient where browsers are (unclosed elements close at the end, a block element
/// closes an open `<p>`, stray end tags are ignored) and strict about what may appear.
public struct HTMLFragment: Sendable, Equatable {
    public indirect enum Node: Sendable, Equatable {
        case text(String)
        case element(Element)
    }

    public struct Element: Sendable, Equatable {
        public var name: String
        public var attributes: [String: String]
        public var children: [Node]

        public init(name: String, attributes: [String: String] = [:], children: [Node] = []) {
            self.name = name
            self.attributes = attributes
            self.children = children
        }

        public subscript(attribute: String) -> String? { attributes[attribute] }
        public var isBlock: Bool { HTMLFragment.blockElements.contains(name) }
    }

    public var nodes: [Node]

    public init(nodes: [Node]) { self.nodes = nodes }

    /// Elements that start a block of their own.
    public static let blockElements: Set<String> = ["p", "div", "center", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "hr", "details", "summary"]
    /// Elements that flow with text.
    public static let inlineElements: Set<String> = ["a", "img", "br", "b", "strong", "i", "em", "code", "tt", "kbd", "sub", "sup", "s", "del", "strike", "u", "ins", "mark", "small", "span", "picture", "source", "wbr"]
    static let voidElements: Set<String> = ["br", "hr", "img", "source", "wbr"]
    /// Attributes kept per element; any other attribute (style, class, event handlers) is dropped.
    static func allowedAttributes(_ element: String) -> Set<String> {
        switch element {
        case "a": ["href", "title"]
        case "img": ["src", "alt", "width", "height", "align", "title"]
        case "source": ["srcset", "media"]
        case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6": ["align"]
        case "details": ["open"]
        default: []
        }
    }

    static let maximumLength = 64 << 10
    static let maximumDepth = 32

    /// Parses `raw` (an HTML block, or one inline tag sequence), or nil when it holds anything the
    /// subset does not allow or nothing to show.
    public static func parse(_ raw: String) -> HTMLFragment? {
        guard raw.utf16.count <= maximumLength, raw.contains("<") else { return nil }
        var parser = Parser(Array(raw.unicodeScalars))
        guard let nodes = parser.run(), nodes.contains(where: \.isVisible) else { return nil }
        return HTMLFragment(nodes: nodes)
    }

    /// `href` and `src` values Zephyr follows or loads: web, mail, relative and file paths;
    /// never `javascript:`, `data:` or other schemes that run or embed content.
    public static func isSafeURL(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let colon = v.firstIndex(of: ":") else { return true }
        // A colon after a slash, `?` or `#` is part of a relative path, not a scheme.
        if v[..<colon].contains(where: { "/?#".contains($0) }) { return true }
        return ["http", "https", "mailto", "file"].contains(String(v[..<colon]))
    }

    /// Writes the fragment back as HTML: only the allowed elements and attributes, text escaped.
    /// `url` may rewrite a `src`, `srcset` or `href` value, or drop it (nil): an image without a
    /// source becomes its alt text, a link without a target its content.
    public func serialized(url: (_ attribute: String, _ value: String) -> String? = { $1 }) -> String {
        var out = ""
        func write(_ nodes: [Node]) {
            for node in nodes {
                switch node {
                case let .text(text):
                    out += Self.escape(text, quote: false)
                case let .element(e):
                    var attributes: [(String, String)] = []
                    var dropped = false
                    for key in e.attributes.keys.sorted() {
                        guard var value = e.attributes[key] else { continue }
                        if ["src", "srcset", "href"].contains(key) {
                            guard let rewritten = url(key, value) else { dropped = true; continue }
                            value = rewritten
                        }
                        attributes.append((key, value))
                    }
                    if dropped {
                        if e.name == "img" { out += Self.escape(e["alt"] ?? "", quote: false); continue }
                        if e.name == "source" { continue }
                        if e.name == "a" { write(e.children); continue }
                    }
                    out += "<" + e.name + attributes.map { " " + $0.0 + "=\"" + Self.escape($0.1, quote: true) + "\"" }.joined() + ">"
                    guard !Self.voidElements.contains(e.name) else { continue }
                    write(e.children)
                    out += "</" + e.name + ">"
                }
            }
        }
        write(nodes)
        return out
    }

    /// The text a reader sees, image descriptions included: one line per block, spaces collapsed.
    public var plainText: String {
        var out = ""
        func walk(_ nodes: [Node]) {
            for node in nodes {
                switch node {
                case let .text(t): out += t.components(separatedBy: .newlines).joined(separator: " ")
                case let .element(e):
                    if e.name == "img", let alt = e["alt"], !alt.isEmpty { out += " " + alt + " " }
                    if e.isBlock || e.name == "br" { out += "\n" }
                    walk(e.children)
                    if e.isBlock { out += "\n" }
                }
            }
        }
        walk(nodes)
        return out.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func escape(_ s: String, quote: Bool) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        if quote { out = out.replacingOccurrences(of: "\"", with: "&quot;") }
        return out
    }

    // MARK: Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "middot": "·", "bull": "•", "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "times": "×", "divide": "÷", "deg": "°", "plusmn": "±",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "hearts": "♥",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
    ]

    /// Decodes named (a common set) and numeric character references; others stay as written.
    public static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var output = ""
        var index = string.startIndex
        while index < string.endIndex {
            guard string[index] == "&", let end = string[index...].prefix(12).firstIndex(of: ";") else {
                output.append(string[index])
                index = string.index(after: index)
                continue
            }
            let entity = String(string[string.index(after: index)..<end])
            var value: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                value = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                value = UInt32(entity.dropFirst(), radix: 10).flatMap(UnicodeScalar.init).map { String(Character($0)) }
            } else {
                value = namedEntities[entity]
            }
            guard let value else {
                output.append(string[index])
                index = string.index(after: index)
                continue
            }
            output += value
            index = string.index(after: end)
        }
        return output
    }

    // MARK: Parser

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        /// Open elements, innermost last; the root collects top-level nodes.
        var stack: [Element] = [Element(name: "#root")]

        init(_ scalars: [Unicode.Scalar]) { s = scalars }

        mutating func run() -> [Node]? {
            var text = ""
            func flush() {
                guard !text.isEmpty else { return }
                append(.text(HTMLFragment.decodeEntities(text)))
                text = ""
            }
            while i < s.count {
                guard s[i] == "<" else {
                    text.unicodeScalars.append(s[i])
                    i += 1
                    continue
                }
                if starts(with: "<!--") {
                    flush()
                    guard let end = find("-->", from: i + 4) else { return nil }
                    i = end + 3
                } else if i + 1 < s.count, s[i + 1] == "!" || s[i + 1] == "?" {
                    return nil
                } else if i + 1 < s.count, s[i + 1] == "/" {
                    flush()
                    guard let name = endTag() else { return nil }
                    close(name)
                } else if i + 1 < s.count, s[i + 1].properties.isAlphabetic {
                    flush()
                    guard let (element, selfClosing) = startTag() else { return nil }
                    guard open(element, selfClosing: selfClosing) else { return nil }
                } else {
                    text.unicodeScalars.append("<")
                    i += 1
                }
            }
            flush()
            while stack.count > 1 { pop() }
            return stack[0].children
        }

        func starts(with prefix: String) -> Bool {
            let p = Array(prefix.unicodeScalars)
            guard i + p.count <= s.count else { return false }
            return (0..<p.count).allSatisfy { s[i + $0] == p[$0] }
        }

        func find(_ needle: String, from start: Int) -> Int? {
            let n = Array(needle.unicodeScalars)
            var j = start
            while j + n.count <= s.count {
                if (0..<n.count).allSatisfy({ s[j + $0] == n[$0] }) { return j }
                j += 1
            }
            return nil
        }

        mutating func skipSpace() { while i < s.count, s[i].properties.isWhitespace { i += 1 } }

        mutating func name() -> String {
            var out = ""
            while i < s.count, s[i].properties.isAlphabetic || ("0"..."9").contains(s[i]) || s[i] == "-" || s[i] == "_" || s[i] == ":" {
                out.unicodeScalars.append(s[i])
                i += 1
            }
            return out.lowercased()
        }

        /// `</name>`; the cursor is on `<`.
        mutating func endTag() -> String? {
            i += 2
            let n = name()
            skipSpace()
            guard !n.isEmpty, i < s.count, s[i] == ">" else { return nil }
            i += 1
            return n
        }

        /// `<name attr="v" …>` or `…/>`; the cursor is on `<`. Unknown elements fail the fragment.
        mutating func startTag() -> (Element, Bool)? {
            i += 1
            let n = name()
            guard HTMLFragment.blockElements.contains(n) || HTMLFragment.inlineElements.contains(n) else { return nil }
            let allowed = HTMLFragment.allowedAttributes(n)
            var attributes: [String: String] = [:]
            while true {
                skipSpace()
                guard i < s.count else { return nil }
                if s[i] == ">" { i += 1; return (Element(name: n, attributes: attributes), false) }
                if s[i] == "/", i + 1 < s.count, s[i + 1] == ">" { i += 2; return (Element(name: n, attributes: attributes), true) }
                let key = name()
                guard !key.isEmpty else { return nil }
                skipSpace()
                var value = ""
                if i < s.count, s[i] == "=" {
                    i += 1
                    skipSpace()
                    guard i < s.count else { return nil }
                    if s[i] == "\"" || s[i] == "'" {
                        let quote = s[i]
                        i += 1
                        while i < s.count, s[i] != quote { value.unicodeScalars.append(s[i]); i += 1 }
                        guard i < s.count else { return nil }
                        i += 1
                    } else {
                        while i < s.count, !s[i].properties.isWhitespace, s[i] != ">" { value.unicodeScalars.append(s[i]); i += 1 }
                    }
                }
                value = HTMLFragment.decodeEntities(value)
                if ["src", "srcset", "href"].contains(key), !HTMLFragment.isSafeURL(value) { return nil }
                if allowed.contains(key), attributes[key] == nil { attributes[key] = value }
            }
        }

        mutating func append(_ node: Node) { stack[stack.count - 1].children.append(node) }

        mutating func pop() {
            let e = stack.removeLast()
            append(.element(e))
        }

        mutating func open(_ e: Element, selfClosing: Bool) -> Bool {
            // A block element ends an open paragraph, as in browsers.
            if e.isBlock, stack.last?.name == "p" { pop() }
            if HTMLFragment.voidElements.contains(e.name) || selfClosing {
                append(.element(e))
                return true
            }
            guard stack.count <= HTMLFragment.maximumDepth else { return false }
            stack.append(e)
            return true
        }

        mutating func close(_ name: String) {
            guard let k = stack.lastIndex(where: { $0.name == name }), k > 0 else { return }
            while stack.count > k { pop() }
        }
    }
}

extension HTMLFragment.Node {
    /// Text that is not only whitespace, an image or a rule somewhere in the node.
    public var isVisible: Bool {
        switch self {
        case let .text(t): !t.allSatisfy(\.isWhitespace)
        case let .element(e): e.name == "img" || e.name == "hr" || e.children.contains(where: \.isVisible)
        }
    }
}
