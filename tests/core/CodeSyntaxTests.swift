import Foundation
import Testing
@testable import ZephyrCore

/// Code colors (design §8.1): one pass per block, a table per language family.
@Suite struct CodeSyntaxTests {
    /// `role:text` for every token, in order.
    func marks(_ code: String, _ info: String) throws -> [String] {
        let language = try #require(CodeSyntax.language(info))
        return CodeSyntax.tokens(code, language: language).map { "\($0.role):" + (code as NSString).substring(with: $0.range) }
    }

    @Test func jsonKeysValuesAndLiterals() throws {
        let m = try marks(#"{"name": "Zephyr", "size": 1.5e3, "tags": ["a"], "open": true, "parent": null}"#, "json")
        #expect(m == ["property:\"name\"", "string:\"Zephyr\"", "property:\"size\"", "number:1.5e3", "property:\"tags\"", "string:\"a\"",
                      "property:\"open\"", "number:true", "property:\"parent\"", "number:null"])
    }

    @Test func pythonCallsDefinitionsAndComments() throws {
        let m = try marks("@cache\ndef greet(name):\n    # say hello\n    print(f\"hi {name}\", 42)\n    return None\n", "py")
        #expect(m == ["type:@cache", "keyword:def", "function:greet", "comment:# say hello", "function:print", "string:f\"hi {name}\"", "number:42",
                      "keyword:return", "number:None"])
    }

    @Test func swiftTypesAndCalls() throws {
        let m = try marks("let title: String = \"Zephyr\" // name\nprint(title.count)\nlet box = Box(width: 2)", "swift")
        #expect(m == ["keyword:let", "type:String", "string:\"Zephyr\"", "comment:// name", "function:print", "keyword:let", "type:Box", "number:2"])
    }

    @Test func shellCommandsOptionsAndVariables() throws {
        let m = try marks("# install\nbrew install --cask zephyr\nexport PATH=\"$HOME/bin:$PATH\"\nif [ -f a#b ]; then echo $1; fi\n", "bash")
        #expect(m == ["comment:# install", "function:brew", "type:--cask", "keyword:export", "string:\"$HOME/bin:$PATH\"",
                      "keyword:if", "type:-f", "keyword:then", "function:echo", "property:$1", "keyword:fi"])
    }

    @Test func markupTagsAttributesAndComments() throws {
        let m = try marks("<!-- top --><p align=\"center\">A &amp; B</p>", "html")
        #expect(m == ["comment:<!-- top -->", "keyword:p", "property:align", "string:\"center\"", "number:&amp;", "keyword:p"])
    }

    @Test func configKeysSectionsAndValues() throws {
        let yaml = try marks("name: zephyr # app\nversion: 0.1\nlist:\n  - id: 3\n    on: true\n    runs-on: macos-15\n", "yaml")
        #expect(yaml == ["property:name", "comment:# app", "property:version", "number:0.1", "property:list", "property:id", "number:3", "property:on", "number:true", "property:runs-on"])
        let toml = try marks("[package]\nname = \"zephyr\"\n", "toml")
        #expect(toml == ["type:[package]", "property:name", "string:\"zephyr\""])
    }

    @Test func cssDiffAndSQL() throws {
        #expect(try marks("@media print { body { color: #333; margin: 12px !important } }", "css")
                == ["keyword:@media", "keyword:print", "keyword:body", "property:color", "number:#333", "property:margin", "number:12px", "keyword:!important"])
        #expect(try marks("@@ -1 +1 @@\n-old\n+new\n same", "diff") == ["keyword:@@ -1 +1 @@", "deleted:-old", "inserted:+new"])
        #expect(try marks("select count(*) from notes where id = 'a' -- one", "sql") == ["keyword:select", "function:count", "keyword:from", "keyword:where", "string:'a'", "comment:-- one"])
    }

    /// Every scanner from a block's first character: nothing reads before it or past the end.
    @Test func blocksMayStartAnywhere() throws {
        #expect(try marks("42", "json") == ["number:42"])
        #expect(try marks("1: a", "yaml") == ["property:1"])
        let starts = ["", "1", "-", "\"", "#", "<", "@", "$", "${", "/*", "<!--", "'''", "[", "-- ", "a:", "\\", ".5", "f\"", "<a", "&"]
        for info in ["json", "py", "bash", "swift", "yaml", "html", "css", "diff", "sql", "rust", "ruby", "lua", "go"] {
            for code in starts { _ = try marks(code, info) }
        }
    }

    @Test func unknownLanguagesAreNotColored() {
        #expect(CodeSyntax.language("text") == nil)
        #expect(CodeSyntax.language(nil) == nil)
        #expect(CodeSyntax.language("mermaid") == nil)
        #expect(CodeSyntax.supports("TypeScript"))
        #expect(CodeSyntax.supports("js {.numberLines}"))
    }

    @Test func aLargeBlockIsOnePass() throws {
        let line = #"{"id": 12345, "name": "row", "ok": false},"#
        let code = "[\n" + Array(repeating: line, count: 20_000).joined(separator: "\n") + "\n]"
        let start = Date()
        let tokens = CodeSyntax.tokens(code, language: try #require(CodeSyntax.language("json")))
        #expect(tokens.count == 20_000 * 6)
        #expect(Date().timeIntervalSince(start) < 2)
        // Words with no `{`, `;` or `}` after them: one lookahead for all of them.
        let css = "a{" + String(repeating: "word ", count: 100_000)
        let cssStart = Date()
        _ = CodeSyntax.tokens(css, language: try #require(CodeSyntax.language("css")))
        #expect(Date().timeIntervalSince(cssStart) < 2)
    }

    @Test func nestedCommentsAndShellSeparators() throws {
        #expect(try marks("/* a /* b */ (c) */ let", "swift") == ["comment:/* a /* b */ (c) */", "keyword:let"])
        // C comments do not nest: the first close ends it.
        #expect(try marks("/* a /* b */ c */", "c") == ["comment:/* a /* b */"])
        #expect(try marks("echo ok;# (note)\na#b", "bash") == ["function:echo", "comment:# (note)", "function:a#b"])
    }
}
