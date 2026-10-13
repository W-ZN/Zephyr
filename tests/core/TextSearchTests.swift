import Foundation
import Testing
@testable import ZephyrCore

@Suite struct TextSearchTests {
    func find(_ query: String, in text: String, case matchCase: Bool = false, word: Bool = false, regex: Bool = false) -> [String] {
        let ns = text as NSString
        return TextSearch(query: query, matchCase: matchCase, wholeWord: word, regex: regex).find(in: ns).matches.map { ns.substring(with: $0) }
    }

    @Test func literalSearchIgnoresCaseWidthAndAccentsUnlessAsked() {
        #expect(find("hello", in: "Hello HELLO hello") == ["Hello", "HELLO", "hello"])
        #expect(find("hello", in: "Hello HELLO hello", case: true) == ["hello"])
        #expect(find("cafe", in: "Café cafe") == ["Café", "cafe"])
        #expect(find("ABC", in: "ＡＢＣ abc") == ["ＡＢＣ", "abc"], "full-width letters match")
        #expect(find("知识", in: "知识库里的知识") == ["知识", "知识"])
    }

    @Test func matchesAreNonOverlappingAndInOrder() {
        let ns = "aaaa" as NSString
        #expect(TextSearch(query: "aa").find(in: ns).matches == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
        #expect(TextSearch(query: "").find(in: ns).matches.isEmpty)
    }

    @Test func wholeWordKeepsLatinWordsWholeButNotNextToCJK() {
        #expect(find("cat", in: "cat concat cat_x cat. Cat", word: true) == ["cat", "cat", "Cat"])
        #expect(find("cat", in: "使用cat工具 concat", word: true) == ["cat"], "CJK neighbours do not join a Latin word")
        #expect(find("a.b", in: "a.b axb", word: true) == ["a.b"], "the query is literal, not a pattern")
        #expect(find("知识", in: "知识库", word: true) == ["知识"], "Chinese has no word boundary to respect")
    }

    @Test func regularExpressionsAndTheirErrors() {
        #expect(find(#"\d+"#, in: "a1 b22 c333", regex: true) == ["1", "22", "333"])
        #expect(find("^# ", in: "# a\nb\n# c", regex: true).count == 2, "^ matches at each line")
        #expect(find("A.", in: "ab AB", regex: true, ) == ["ab", "AB"])
        #expect(find("A.", in: "ab AB", case: true, regex: true) == ["AB"])
        #expect(TextSearch(query: "(", regex: true).find(in: "a(" as NSString).invalidPattern)
        #expect(find("x*", in: "ab", regex: true).isEmpty, "empty matches are skipped")
    }

    @Test func limitMarksTruncation() {
        let text = String(repeating: "a ", count: 50) as NSString
        let result = TextSearch(query: "a").find(in: text, limit: 10)
        #expect(result.matches.count == 10 && result.truncated)
    }

    @Test func replacementTemplates() {
        let ns = "John Smith, Jane Doe" as NSString
        let search = TextSearch(query: #"(\w+) (\w+)"#, regex: true)
        let found = search.find(in: ns).matches
        #expect(search.replacements(for: found, in: ns, template: "$2, $1") == ["Smith, John", "Doe, Jane"])
        #expect(search.replacements(for: found, in: ns, template: #"$1\n$2"#) == ["John\nSmith", "Jane\nDoe"])
        #expect(search.replacements(for: found, in: ns, template: #"\$1"#) == ["$1", "$1"], "an escaped dollar stays literal")
        let literal = TextSearch(query: "John")
        #expect(literal.replacements(for: literal.find(in: ns).matches, in: ns, template: "$1\\n") == ["$1\\n"], "no template outside regex mode")
        let look = TextSearch(query: "(?<=a)b", regex: true)
        let t = "ab cb ab" as NSString
        #expect(look.replacements(for: look.find(in: t).matches, in: t, template: "X") == ["X", "X"], "lookbehind sees its context")
    }
}
