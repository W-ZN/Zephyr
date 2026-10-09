import AppKit
import Testing
@testable import ZephyrRender

@MainActor
@Suite struct LinkPreviewSourceTests {
    @Test func sourceTextAndSelectionStayExact() {
        let source = "3  func greet(_ name: String) -> String { return \"Hi \\(name)\" }"
        let view = LinkPreviewSourceView(frame: .zero)
        view.setSource(source, filename: "Greeting.swift", typography: Typography())
        view.setSelectedRange(NSRange(location: 3, length: 4))
        view.setSource(source, filename: "Greeting.swift", typography: Typography())

        #expect(view.string == source)
        #expect(view.selectedRange() == NSRange(location: 3, length: 4))
        #expect(view.isEditable == false)
        #expect(view.isSelectable)
    }

    @Test func pairsNestButStringsAndCommentsDoNotParticipate() {
        let source = "let ignored = \"[not a pair]\" // (also ignored)\nlet value = { nested: [1] }"
        let view = LinkPreviewSourceView(frame: .zero)
        view.setSource(source, filename: "sample.swift", typography: Typography())
        let text = source as NSString

        let quotedBracket = text.range(of: "[not a pair]").location
        view.setSelectedRange(NSRange(location: quotedBracket, length: 1))
        #expect(temporaryBackground(in: view, at: quotedBracket) == nil)
        let commentBracket = text.range(of: "(also ignored)").location
        view.setSelectedRange(NSRange(location: commentBracket, length: 1))
        #expect(temporaryBackground(in: view, at: commentBracket) == nil)

        let opening = text.range(of: "[1]").location
        let closing = opening + 2
        let foregroundBefore = foreground(in: view, at: opening)
        view.setSelectedRange(NSRange(location: opening, length: 1))
        #expect(temporaryBackground(in: view, at: opening) != nil)
        #expect(temporaryBackground(in: view, at: closing) != nil)
        #expect(temporaryUnderline(in: view, at: opening) != nil)
        #expect(background(in: view, at: opening) == nil)
        #expect(underline(in: view, at: opening) == nil, "pair emphasis must not mutate attributed storage")
        #expect(foreground(in: view, at: opening)?.isEqual(foregroundBefore) == true)

        let outer = text.range(of: "{ nested").location
        view.setSelectedRanges([NSValue(range: NSRange(location: outer, length: 1))], affinity: .downstream, stillSelecting: false)
        #expect(temporaryBackground(in: view, at: outer) != nil, "the native multi-range path updates the active pair")

        let outerClose = (source as NSString).length - 1
        #expect(temporaryBackground(in: view, at: outerClose) != nil)

        view.setSelectedRange(NSRange(location: closing + 1, length: 0))
        #expect(temporaryBackground(in: view, at: opening) != nil, "a caret immediately after a bracket still finds its pair")

        let xml = "<!-- [not a pair] --><node>[shown]</node>"
        view.setSource(xml, filename: "sample.xml", typography: Typography())
        let xmlText = xml as NSString
        let hidden = xmlText.range(of: "[not a pair]").location
        view.setSelectedRange(NSRange(location: hidden, length: 1))
        #expect(temporaryBackground(in: view, at: hidden) == nil)
    }

    @Test func truncatedSourceAndClearingLeaveNoTemporaryPairState() {
        let source = "{\n  \"unfinished\": [1"
        let view = LinkPreviewSourceView(frame: .zero)
        view.setSource(source, filename: "data.json", typography: Typography())
        let opening = (source as NSString).range(of: "[").location
        view.setSelectedRange(NSRange(location: opening, length: 1))
        #expect(view.string == source)
        #expect(temporaryBackground(in: view, at: opening) == nil)

        view.setSource("<item id=\"7\"", filename: "truncated.xml", typography: Typography())
        #expect(view.string == "<item id=\"7\"")

        view.setSource("func f() {}", filename: "sample.swift", typography: Typography())
        let pair = (view.string as NSString).range(of: "()")
        view.setSelectedRange(NSRange(location: pair.location, length: 1))
        #expect(temporaryBackground(in: view, at: pair.location) != nil)
        view.clearSourceHighlighting()
        #expect(temporaryBackground(in: view, at: pair.location) == nil)
        #expect(view.string == "func f() {}")
    }

    @Test func jsonAndXMLGetStructuredColorsWhileTextStaysPlain() {
        let view = LinkPreviewSourceView(frame: .zero)
        let json = "{\"name\": \"Zephyr\", \"count\": 3, \"ok\": true}"
        view.setSource(json, filename: "preview.json", typography: Typography())
        let jsonText = json as NSString
        #expect(foreground(in: view, at: jsonText.range(of: "\"name\"").location)?.isEqual(Palette.syntax(.property)) == true)
        #expect(foreground(in: view, at: jsonText.range(of: "\"Zephyr\"").location)?.isEqual(Palette.syntax(.string)) == true)
        #expect(foreground(in: view, at: jsonText.range(of: "3").location)?.isEqual(Palette.syntax(.number)) == true)

        let xml = "<item id=\"7\">text</item>"
        view.setSource(xml, filename: "preview.xml", typography: Typography())
        let xmlText = xml as NSString
        #expect(foreground(in: view, at: xmlText.range(of: "item").location)?.isEqual(Palette.syntax(.keyword)) == true)
        #expect(foreground(in: view, at: xmlText.range(of: "id").location)?.isEqual(Palette.syntax(.property)) == true)
        #expect(foreground(in: view, at: xmlText.range(of: "\"7\"").location)?.isEqual(Palette.syntax(.string)) == true)

        let plain = "let value = 3 // prose sample"
        view.setSource(plain, filename: "Example.txt", typography: Typography())
        #expect(foreground(in: view, at: 0)?.isEqual(Tokens.ink) == true)
        #expect(foreground(in: view, at: (plain as NSString).range(of: "3").location)?.isEqual(Tokens.ink) == true)

        view.setSource("value = \"fallback\"", filename: "Makefile", typography: Typography())
        #expect(foreground(in: view, at: (view.string as NSString).range(of: "\"fallback\"").location)?.isEqual(Palette.syntax(.string)) == true)
    }

    @Test func commentsFollowThePreviewLanguage() {
        let view = LinkPreviewSourceView(frame: .zero)
        let python = "value = 5 // 2 # comment"
        view.setSource(python, filename: "sample.py", typography: Typography())
        let pythonText = python as NSString
        #expect(foreground(in: view, at: pythonText.range(of: "//").location)?.isEqual(Tokens.ink) == true)
        #expect(foreground(in: view, at: pythonText.range(of: "# comment").location)?.isEqual(Palette.syntax(.comment)) == true)

        let swift = "let value = 5 // comment"
        view.setSource(swift, filename: "sample.swift", typography: Typography())
        #expect(foreground(in: view, at: (swift as NSString).range(of: "//").location)?.isEqual(Palette.syntax(.comment)) == true)

        let ini = "name=value ; comment"
        view.setSource(ini, filename: "sample.ini", typography: Typography())
        #expect(foreground(in: view, at: (ini as NSString).range(of: "; comment").location)?.isEqual(Palette.syntax(.comment)) == true)
    }

    /// Every built-in palette's code colors stay readable on its code background, light and dark,
    /// and the hues of strings, numbers and functions stay apart from the accent and each other.
    @Test func syntaxColorsRemainReadableInEveryPalette() {
        for theme in Palette.Theme.allCases {
            for dark in [false, true] {
                let scheme = Palette.scheme(theme, dark: dark, overrides: [:])
                let background = scheme[.codeBackground].usingColorSpace(.sRGB)!
                let page = scheme[.background].usingColorSpace(.sRGB)!
                // Translucent code backgrounds sit on the page.
                let fill = Palette.mix(page, background.withAlphaComponent(1), background.alphaComponent)
                for role in [Palette.Role.syntaxKeyword, .syntaxString, .syntaxNumber, .syntaxFunction, .syntaxType, .syntaxInserted, .syntaxComment] {
                    let color = scheme[role].usingColorSpace(.sRGB)!
                    #expect(contrast(color, fill) >= (role == .syntaxComment ? 3.5 : 4.4), "\(theme) \(dark ? "dark" : "light") \(role): \(contrast(color, fill))")
                }
                let hues = [Palette.Role.syntaxKeyword, .syntaxString, .syntaxNumber, .syntaxFunction].map { role -> CGFloat in
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    scheme[role].usingColorSpace(.sRGB)!.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                    return h * 360
                }
                for i in hues.indices { for j in hues.indices where j > i {
                    let d = abs(hues[i] - hues[j]).truncatingRemainder(dividingBy: 360)
                    #expect(min(d, 360 - d) > 25, "\(theme) \(dark ? "dark" : "light") hues \(i) \(j)")
                } }
            }
        }
    }

    private func foreground(in view: NSTextView, at index: Int) -> NSColor? {
        view.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func background(in view: NSTextView, at index: Int) -> NSColor? {
        view.textStorage?.attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func temporaryBackground(in view: NSTextView, at index: Int) -> NSColor? {
        view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    private func underline(in view: NSTextView, at index: Int) -> Int? {
        view.textStorage?.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int
    }

    private func temporaryUnderline(in view: NSTextView, at index: Int) -> Int? {
        view.layoutManager?.temporaryAttribute(.underlineStyle, atCharacterIndex: index, effectiveRange: nil) as? Int
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func bracketsInsideQuotedKeysDoNotPair() {
        let json = "{\"(\": 1}"
        let view = LinkPreviewSourceView(frame: .zero)
        view.setSource(json, filename: "keys.json", typography: Typography())
        view.setSelectedRange(NSRange(location: 0, length: 1))
        #expect(temporaryBackground(in: view, at: (json as NSString).length - 1) != nil)
    }
}
