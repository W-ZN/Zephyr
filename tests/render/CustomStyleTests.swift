import AppKit
import Testing
import ZephyrCore
@testable import ZephyrRender

/// Custom CSS (design §8, the advanced tier): whitelisted properties land on the same atomic
/// settings as the settings window, colors on theme roles split by appearance, and the rest is
/// reported.
@MainActor @Suite struct CustomStyleTests {
    static func typography(_ pairs: [String: String], css: String = "") -> Typography {
        var s = AppearanceSettings()
        for (key, value) in pairs { try! s.set(key, value) }
        return Typography(s, css: CustomStyle.parse(css).style)
    }

    @Test func mapsWhitelistedPropertiesAndReportsTheRest() {
        let css = """
        /* reading */
        body { font-family: "No Such Font", Georgia, serif; font-size: 17px; line-height: 1.8; max-width: 38em; color: #222; }
        h1, h2 { font-weight: 600; color: rgb(20, 60, 120) }
        h1 { font-size: 2em; margin-top: 3em; text-transform: uppercase; }
        p { margin: 0 0 1em; text-indent: 2em }
        a { color: teal } code { font-size: 0.9em }
        table { font-size: 14px } th { background: #eee }
        blockquote { border-left-color: #c00 }
        @media print { body { color: black } }
        @media (prefers-color-scheme: dark) { body { color: #ddd; font-size: 30px } }
        """
        let (style, applied, ignored) = CustomStyle.parse(css)
        let o = style.overrides(baseSize: 16)
        #expect(o["font.body"] == .text("Georgia"), "the first installed family wins")
        #expect(o["text.size"] == .number(17))
        #expect(o["text.lineHeight"] == .number(1.8))
        #expect(o["text.width"] == .number(38))
        #expect(o["h1.weight"] == .number(600) && o["h2.weight"] == .number(600))
        #expect(o["h1.size"] == .number(2) && o["h1.spaceAbove"] == .number(3))
        #expect(o["paragraph.spacing"] == .number(1) && o["paragraph.indent"] == .number(2))
        #expect(o["code.size"] == .number(0.9))
        if case let .number(t)? = o["table.textSize"] { #expect(abs(t - 14.0 / 17) < 0.001, "lengths are relative to the CSS body size") } else { Issue.record("table size") }
        #expect(style.colors[.text]?.light != nil && style.colors[.text]?.dark != nil)
        #expect(style.colors[.link]?.light != nil && style.colors[.quote]?.light != nil && style.colors[.tableHeader]?.light != nil)
        #expect(style.headings[1]?.color.light != nil)
        #expect(ignored.contains { $0.contains("text-transform") })
        #expect(ignored.contains("@media print"))
        #expect(ignored.contains { $0.contains("font-size: 30px") }, "only colors inside the dark block")
        #expect(!applied.contains { $0.contains("light mode") }, "dark colors were given")
    }

    @Test func valuesOutsideTheSettingsRangesAreRefused() {
        let (style, applied, ignored) = CustomStyle.parse("h2 { font-size: 400px; font-weight: 700 }")
        #expect(style.typography["h2.size"] == nil)
        #expect(style.typography["h2.weight"] == .number(700))
        #expect(ignored.contains { $0.contains("h2.size") })
        #expect(!applied.contains { $0.contains("400px") })
    }

    @Test func typographyUsesSettingsThenCSS() {
        let t = Self.typography(["text.size": "18", "h2.size": "1.5"], css: "body { line-height: 27px } h3 { font-size: 30px }")
        #expect(t.fontSize == 18)
        #expect(abs(t.lineSpacing - 1.5) < 0.001, "27 px over an 18 pt body")
        #expect(t.headingFont(level: 2).pointSize == 27)
        #expect(t.headingFont(level: 3).pointSize == 30)
        let flat = Self.typography(["headings.scale": "0.5"])
        #expect(flat.headingFont(level: 1).pointSize < Typography().headingFont(level: 1).pointSize)
        #expect(Self.typography(["text.align": "justify"]).alignment == .justified)
        #expect(Self.typography(["paragraph.indent": "2"]).paragraphIndent == 32)
    }

    @Test func palettesAndColorOverridesFollowTheAppearance() {
        let lightLook = NSAppearance(named: .aqua)!, darkLook = NSAppearance(named: .darkAqua)!
        var s = AppearanceSettings()
        try! s.set("palette", "anthology")
        try! s.set("color.dark.link", "#ffff00")
        Palette.configure(s)
        defer { Palette.configure(AppearanceSettings()) }
        let dark = Palette.link.resolved(for: darkLook)
        #expect(abs(dark.redComponent - 1) < 0.01 && abs(dark.blueComponent) < 0.01)
        #expect(Palette.link.resolved(for: lightLook).hexString == Palette.preview(.anthology, .accent, dark: false).hexString, "light mode keeps the palette's link color")
        #expect(Tokens.canvas.resolved(for: lightLook).hexString == "#FAF9F5", "chrome follows the theme")
        let css = CustomStyle.parse("@media (prefers-color-scheme: dark) { body { background: #000 } }").style
        Palette.configure(AppearanceSettings(), css: css)
        #expect(Tokens.canvas.resolved(for: darkLook).hexString == "#000000")
        #expect(Tokens.sidebar.resolved(for: darkLook).hexString != "#000000", "surfaces derive from an overridden background")
        let before = Tokens.canvas.resolved(for: darkLook).hexString
        let previewCSS = CustomStyle.parse("body { background: #ffeecc } @media (prefers-color-scheme: dark) { body { background: #223344 } }").style
        #expect(Palette.preview(s, .background, css: previewCSS, dark: false).hexString == "#FFEECC")
        #expect(Palette.preview(s, .background, css: previewCSS, dark: true).hexString == "#223344")
        #expect(Tokens.canvas.resolved(for: darkLook).hexString == before, "previewing a theme must not change the active palette")
    }

    @Test func headingNumbersFollowTheScheme() {
        let decimal = Self.typography(["headings.numbering": "decimal"])
        #expect(decimal.headingNumber(level: 1, counts: [0, 1, 0, 0, 0, 0, 0]) == nil, "numbering starts at H2 by default")
        #expect(decimal.headingNumber(level: 3, counts: [0, 1, 2, 3, 0, 0, 0]) == "2.3")
        #expect(decimal.numberSlot(level: 2) > 0 && decimal.numberSlot(level: 1) == 0)
        let chinese = Self.typography(["headings.numbering": "chinese", "headings.numberFrom": "1"])
        #expect(chinese.headingNumber(level: 1, counts: [0, 12, 0, 0, 0, 0, 0]) == "十二、")
        #expect(chinese.headingNumber(level: 2, counts: [0, 1, 20, 0, 0, 0, 0]) == "（二十）")
        #expect(chinese.headingNumber(level: 3, counts: [0, 1, 1, 3, 0, 0, 0]) == "3.")
        #expect(chinese.headingNumber(level: 5, counts: [0, 1, 1, 1, 1, 2, 0]) == "②")
        #expect(Typography().headingNumber(level: 2, counts: [0, 0, 1, 0, 0, 0, 0]) == nil)
    }

    @Test func fontListsTakeTheFirstInstalledFamily() {
        let t = Self.typography(["font.body": "No Such Font, Charter, serif", "font.cjk": "No Such CJK, Kaiti SC", "zoom": "1.25"])
        #expect(t.latinFamily == "Charter")
        #expect(t.cjkFamily == "Kaiti SC")
        #expect(t.fontSize == 20, "zoom scales the text size")
        #expect(Self.typography(["font.body": "serif"]).cjkFamily == "Songti SC", "serif text pairs with Songti")
        #expect(Typography().cjkFamily == "PingFang SC")
    }
}
