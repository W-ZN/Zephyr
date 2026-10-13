import Foundation

/// Splits UTF-8 text into the terms `RelatedSearch` matches on, the same way for the query and for
/// the files, so no index has to be built or kept (design §12): Latin and other alphabetic words
/// (lowercased, lightly stemmed, stop words dropped), and Han, kana and Hangul as overlapping pairs
/// of characters (a lone character stands for itself). Pairs need no dictionary and, unlike single
/// characters, keep a Chinese query from matching every sentence that shares one common character.
enum RelatedLexer {
    private static let seed: UInt64 = 0xcbf29ce484222325
    private static let prime: UInt64 = 0x100000001b3
    private static let longestWord = 40

    private static let stopWords = TermTable([
        "the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "is", "are", "was", "were", "be", "it", "this", "that",
        "how", "do", "does", "what", "when", "where", "which", "who", "why", "can", "i", "my", "from", "with", "by", "at", "as",
        "not", "if", "so", "there", "into", "about",
    ].map { hash(Array($0.utf8)) })

    private static let suffixes: [[UInt8]] = ["ations", "ation", "ings", "ing", "edly", "ed", "ies", "es", "ly", "s"].map { Array($0.utf8) }

    /// 0 separator, 1 ASCII letter or digit.
    private static let ascii: [UInt8] = (0..<128).map { c in
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ? 1 : 0
    }

    private enum Kind { case separator, word, cjk }

    private static func kind(of v: UInt32) -> Kind {
        switch v {
        case 0x3000...0x303F, 0xFE30...0xFE4F, 0xFF00...0xFFEF: .separator
        case 0x2E80...0xA4CF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x3FFFF: .cjk
        case 0x80...0xBF: v == 0xAA || v == 0xB5 || v == 0xBA ? .word : .separator
        case 0xD7, 0xF7, 0x2000...0x2BFF, 0xE000...0xF8FF, 0x1F000...0x1FAFF: .separator
        default: .word
        }
    }

    static func hash(_ bytes: [UInt8]) -> UInt64 {
        var h = seed
        for b in bytes { h = (h ^ UInt64(b)) &* prime }
        return h
    }

    /// A character pair (or a lone character, `second` 0). The salt keeps the pairs apart from words.
    private static func hash(_ first: UInt32, _ second: UInt32) -> UInt64 {
        var h = seed ^ 0x9e3779b97f4a7c15
        h = (h ^ UInt64(first)) &* prime
        h = (h ^ UInt64(second)) &* prime
        return h
    }

    /// Plural and verb endings, so `searching` and `searches` meet `search`. Applied to the
    /// query and the text alike, so whatever it does wrong is the same on both sides.
    private static func stem(_ w: inout [UInt8]) {
        guard w.count > 3 else { return }
        for s in suffixes {
            let n = w.count - s.count
            guard n >= 3 else { continue }
            var same = true
            for k in 0..<s.count where w[n + k] != s[k] { same = false; break }
            guard same else { continue }
            w.removeLast(s.count)
            if s.count == 3, s[0] == UInt8(ascii: "i"), s[1] == UInt8(ascii: "e") { w.append(UInt8(ascii: "y")) }
            return
        }
    }

    /// Calls `emit(term, start, end)` for each term of `bytes[lo..<hi]`; `start..<end` is the source
    /// text the term came from. `scratch` is reused between calls to avoid allocating per line.
    static func scan(_ bytes: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int, scratch word: inout [UInt8], emit: (UInt64, Int, Int) -> Void) {
        word.removeAll(keepingCapacity: true)
        var wordStart = 0
        var previous: UInt32 = 0, previousStart = 0, run = 0
        var runLast: UInt32 = 0, runLastStart = 0, runLastEnd = 0

        func endWord(_ at: Int) {
            defer { word.removeAll(keepingCapacity: true) }
            guard !word.isEmpty, word.count <= longestWord else { return }
            var plain = true
            for byte in word where byte >= 0x80 { plain = false; break }
            if plain {
                if stopWords.contains(hash(word)) { return }
                stem(&word)
            }
            emit(hash(word), wordStart, at)
        }
        func endRun() {
            if run == 1 { emit(hash(runLast, 0), runLastStart, runLastEnd) }
            run = 0
            previous = 0
        }

        var i = lo
        while i < hi {
            let b = bytes[i]
            if b < 0x80 {
                if ascii[Int(b)] == 1 {
                    if run > 0 { endRun() }
                    if word.isEmpty { wordStart = i }
                    word.append(b | (b >= 0x41 && b <= 0x5A ? 0x20 : 0))
                } else {
                    endWord(i)
                    if run > 0 { endRun() }
                }
                i += 1
                continue
            }
            let length = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 0
            guard length > 0, i + length <= hi else {
                endWord(i)
                if run > 0 { endRun() }
                i += 1
                continue
            }
            var v = UInt32(b) & (0xFF >> (length + 1))
            for k in 1..<length { v = v << 6 | UInt32(bytes[i + k] & 0x3F) }
            switch kind(of: v) {
            case .separator:
                endWord(i)
                if run > 0 { endRun() }
            case .cjk:
                endWord(i)
                if previous != 0 { emit(hash(previous, v), previousStart, i + length) }
                previous = v
                previousStart = i
                run += 1
                (runLast, runLastStart, runLastEnd) = (v, i, i + length)
            case .word:
                if run > 0 { endRun() }
                if word.isEmpty { wordStart = i }
                // Latin-1 and Cyrillic capitals fold to lowercase, as ASCII does.
                var folded = v
                if (0xC0...0xDE).contains(v), v != 0xD7 { folded = v + 0x20 }
                else if (0x410...0x42F).contains(v) { folded = v + 0x20 }
                else if (0x400...0x40F).contains(v) { folded = v + 0x50 }
                if folded == v { word.append(contentsOf: bytes[i..<(i + length)]) }
                else if folded < 0x800 { word.append(UInt8(0xC0 | folded >> 6)); word.append(UInt8(0x80 | folded & 0x3F)) }
            }
            i += length
        }
        endWord(hi)
        if run > 0 { endRun() }
    }

    /// The terms of a query string (normalized the way a person would expect: full-width forms
    /// folded, case ignored), each with how often it occurs in the query.
    static func terms(of query: String) -> [(term: UInt64, count: Int)] {
        let bytes = Array(query.precomposedStringWithCompatibilityMapping.lowercased().utf8)
        var scratch = [UInt8]()
        var counts: [UInt64: Int] = [:]
        var order: [UInt64] = []
        bytes.withUnsafeBufferPointer { p in
            scan(p, 0, p.count, scratch: &scratch) { term, _, _ in
                if counts[term] == nil { order.append(term) }
                counts[term, default: 0] += 1
            }
        }
        return order.map { ($0, counts[$0]!) }
    }
}

/// Term hashes (already well mixed) in a small open-addressing table: the lookup that runs for
/// every word of every file, so it avoids the general-purpose dictionary's hashing.
struct TermTable {
    private var keys: [UInt64]
    private var values: [Int32]
    private let mask: Int

    init(_ terms: [UInt64]) {
        self.init(terms.enumerated().map { ($1, $0) })
    }

    init(_ entries: [(UInt64, Int)]) {
        var size = 16
        while size < entries.count * 3 { size <<= 1 }
        keys = [UInt64](repeating: 0, count: size)
        values = [Int32](repeating: -1, count: size)
        mask = size - 1
        for (key, value) in entries {
            var i = Int(truncatingIfNeeded: key) & mask
            while keys[i] != 0, keys[i] != key { i = (i + 1) & mask }
            keys[i] = key
            values[i] = Int32(value)
        }
    }

    func contains(_ key: UInt64) -> Bool { self[key] != nil }

    subscript(key: UInt64) -> Int? {
        var i = Int(truncatingIfNeeded: key) & mask
        while true {
            let k = keys[i]
            if k == key { return Int(values[i]) }
            if k == 0 { return nil }
            i = (i + 1) & mask
        }
    }
}
