import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage

/// Near neighbours of a query's words from the system's own word vectors (English and Chinese
/// ship with macOS and iOS, so Zephyr carries no model). Loaded for one search and released with
/// it: the vectors are not kept between queries. A neighbour must be close and weighs little, so it
/// can add a file that says `retrieval` where the query said `search`, never outvote what was typed.
public struct NeighborExpander: RelatedTermExpander {
    public var neighborsPerWord = 3
    public var maximumDistance = 0.9
    public var weight: Float = 0.2
    public var maximumWords = 4

    public init() {}

    public func expansions(for query: String) -> [(word: String, weight: Float)] {
        var out: [(String, Float)] = []
        for (language, text) in segments(of: query) {
            guard let embedding = NLEmbedding.wordEmbedding(for: language) else { continue }
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            tokenizer.setLanguage(language)
            var words: [String] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let word = text[range].lowercased()
                // Single Chinese characters and short or numeric Latin words carry too little.
                if (language == .english ? word.count >= 4 : word.count >= 2), word.rangeOfCharacter(from: .decimalDigits) == nil { words.append(word) }
                return true
            }
            for word in words.prefix(maximumWords) {
                for (neighbor, distance) in embedding.neighbors(for: word, maximumCount: neighborsPerWord) where distance < maximumDistance && neighbor != word {
                    out.append((neighbor, weight * Float(1 - distance / 2)))
                }
            }
        }
        return out
    }

    /// The query's Chinese and Latin parts, each with its language.
    private func segments(of query: String) -> [(NLLanguage, String)] {
        var han = "", latin = ""
        for scalar in query.unicodeScalars {
            if (0x3400...0x9FFF).contains(scalar.value) || (0x3000...0x303F).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value) { han.unicodeScalars.append(scalar) }
            else if scalar.isASCII { latin.unicodeScalars.append(scalar) }
            else { han.unicodeScalars.append(" ") }
        }
        var result: [(NLLanguage, String)] = []
        if han.contains(where: { $0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } }) { result.append((.simplifiedChinese, han)) }
        if latin.contains(where: \.isLetter) { result.append((.english, latin)) }
        return result
    }
}
#endif
