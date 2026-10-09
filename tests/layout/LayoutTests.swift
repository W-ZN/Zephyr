import Foundation
import Testing
@testable import ZephyrLayout

@Suite struct PrefixSumTests {
    @Test func sumsAndLookups() {
        var p = PrefixSum([3, 0, 5, 2])
        #expect(p.total == 10)
        #expect((0...4).map { p.prefix($0) } == [0, 3, 3, 8, 10])
        #expect([0, 2, 3, 7, 8, 9, 10, 99].map { p.index(containing: $0) } == [0, 0, 2, 2, 3, 3, 3, 3])
        p.set(1, 4)
        #expect(p.prefix(2) == 7 && p.index(containing: 5) == 1)
        p.replaceSubrange(1..<3, with: [1, 1, 1])
        #expect(p.values == [3, 1, 1, 1, 2] && p.total == 8 && p.index(containing: 4) == 2)
    }

    @Test func randomAgainstNaive() {
        var rng = SystemRandomNumberGenerator()
        var values = (0..<200).map { _ in Double(Int.random(in: 1...40, using: &rng)) }
        var p = PrefixSum(values)
        for _ in 0..<500 {
            let i = Int.random(in: 0..<values.count, using: &rng)
            values[i] = Double(Int.random(in: 1...40, using: &rng))
            p.set(i, values[i])
            let y = Double.random(in: 0..<values.reduce(0, +), using: &rng)
            var acc = 0.0, expected = 0
            for (k, v) in values.enumerated() { if acc + v > y { expected = k; break }; acc += v }
            #expect(p.index(containing: y) == expected)
        }
    }
}

@Suite struct TextUnitsTests {
    /// Every unit is non-empty except an empty last line, holds no line break except at its end,
    /// stays within the maximum, and `startsLine` follows the previous unit's end.
    func check(_ u: TextUnits, _ text: NSString, _ note: Comment? = nil) {
        #expect(u.length == text.length, note)
        var problems: [String] = []
        var location = 0
        for (i, unit) in u.units.enumerated() {
            if unit.length > TextUnits.maximum { problems.append("unit \(i) too long") }
            if unit.length == 0, i != u.count - 1 { problems.append("empty unit \(i)") }
            for k in location..<max(location, location + unit.length - 1) {
                let c = text.character(at: k)
                if TextUnits.isTerminator(c), !(c == 0x0D && text.character(at: k + 1) == 0x0A) { problems.append("break inside unit \(i)") }
            }
            let startsLine = i == 0 || TextUnits.isTerminator(text.character(at: location - 1))
            if unit.startsLine != startsLine { problems.append("startsLine of unit \(i)") }
            if location > 0, location < text.length {
                if text.character(at: location - 1) == 0x0D, text.character(at: location) == 0x0A { problems.append("CRLF split at \(location)") }
                if (0xD800...0xDBFF).contains(text.character(at: location - 1)) { problems.append("surrogate pair split at \(location)") }
            }
            location += unit.length
        }
        #expect(problems.isEmpty, "\(problems.prefix(5))")
    }

    @Test func linesAndTheEmptyLastLine() {
        let u = TextUnits(text: "a\nbc\r\nd\re\n")
        #expect(u.units.map(\.length) == [2, 4, 2, 2, 0])
        #expect(u.lineCount == 5 && u.line(ofUnit: 3) == 3 && u.firstUnit(ofLine: 4) == 4)
        #expect(TextUnits(text: "").units.map(\.length) == [0])
        #expect(TextUnits(text: "abc").units.map(\.length) == [3])
        check(u, "a\nbc\r\nd\re\n")
    }

    @Test func longLinesAreCutAtSpacesOrSafeBoundaries() {
        let words = String(repeating: "lorem ipsum dolor ", count: 2000) as NSString
        let u = TextUnits(text: words)
        #expect(u.count > 1)
        check(u, words)
        for i in 0..<(u.count - 1) {
            let r = u.range(of: i)
            #expect(words.character(at: NSMaxRange(r) - 1) == 0x20, "cut after a space")
            #expect(r.length >= TextUnits.target && r.length < TextUnits.target + 20, "at the first pause past the target")
        }
        let emoji = String(repeating: "中文😀👍🏽e\u{301}", count: 3000) as NSString
        check(TextUnits(text: emoji), emoji)
    }

    @Test func editsKeepDistantUnitsAndInvariants() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("ab 中\n\r😀")
        for round in 0..<60 {
            let base = round % 2 == 0
                ? (0..<400).map { _ in String(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]) }.joined()
                : String(repeating: "word 中文 ", count: 1200) + "\n" + String(repeating: "x", count: 9000)
            let text = NSMutableString(string: base)
            var u = TextUnits(text: text)
            for _ in 0..<25 {
                let at = Int.random(in: 0...text.length, using: &rng)
                let length = Int.random(in: 0...min(6, text.length - at), using: &rng)
                var range = NSRange(location: at, length: length)
                range = text.rangeOfComposedCharacterSequences(for: range)
                if range.location > 0, range.location < text.length, text.character(at: range.location - 1) == 0x0D, text.character(at: range.location) == 0x0A {
                    range = NSRange(location: range.location - 1, length: range.length + 1)
                }
                let insert = (0..<Int.random(in: 0...4, using: &rng)).map { _ in String(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]) }.joined()
                let before = u.units
                text.replaceCharacters(in: range, with: insert)
                let (old, new, removed) = u.edit(replacing: range, with: (insert as NSString).length, in: text)
                #expect(removed == Array(before[old]).map(\.id))
                let breaks = (0..<text.length).filter { k in
                    let c = text.character(at: k)
                    return c == 0x0A || (c == 0x0D && !(k + 1 < text.length && text.character(at: k + 1) == 0x0A))
                }.count
                #expect(u.lineCount == breaks + 1, "line count")
                check(u, text, "round \(round)")
                // Units before the region keep their ids; so do those after it.
                #expect(Array(before[..<old.lowerBound]).map(\.id) == Array(u.units[..<new.lowerBound]).map(\.id))
                #expect(Array(before[old.upperBound...]).map(\.id) == Array(u.units[new.upperBound...]).map(\.id))
                #expect(new.count <= 8 || round % 2 == 0, "a keystroke re-cuts a few units, not a whole long line")
            }
        }
    }

    @Test func joiningShortLinesGivesOneUnit() {
        let text = NSMutableString(string: "foo\nbar\n")
        var u = TextUnits(text: text)
        text.replaceCharacters(in: NSRange(location: 3, length: 1), with: "")
        u.edit(replacing: NSRange(location: 3, length: 1), with: 0, in: text)
        #expect(u.units.map(\.length) == [7, 0])
    }
}

@Suite struct HeightMapTests {
    @Test func anchorsSurviveMeasurementAbove() {
        var map = HeightMap(estimates: [100, 100, 100, 100])
        let anchor = LayoutAnchor(y: 250, in: map)
        #expect(anchor == LayoutAnchor(unit: 2, offset: 50))
        #expect(map.setMeasured(0, 160) == 60)
        #expect(anchor.y(in: map) == 310, "the anchored text moves with the unit above it")
        #expect(map.unit(at: 310) == 2)
        map.replace(1..<2, with: [40, 40])
        #expect(map.count == 5 && map.total == 160 + 80 + 200)
    }
}
