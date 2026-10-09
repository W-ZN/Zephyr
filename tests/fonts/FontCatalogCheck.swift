import AppKit
import CoreText

@main
struct FontCatalogCheck {
    static func main() {
        let wenkai = FontCatalog.Entry(family: "LXGW WenKai", name: "霞鹜文楷", installed: false, chinese: true, monospaced: false)
        for query in ["霞鹜", "霞骛文楷", "文楷", "LXGW WenKai", "lxgwwenkai", "wen kai", "xia wu wen kai", "xiáwù", "ＬＸＧＷ"] {
            precondition(wenkai.matches(query), "Missing search alias: \(query)")
        }
        precondition(!wenkai.matches("LXGW Mono"), "Search must match every query term")
        precondition(wenkai.family == "LXGW WenKai", "Display names must not replace canonical family names")
        precondition(FontCatalog.familyNames(in: Data([0, 0])).isEmpty)
        precondition(FontCatalog.familyNames(in: Data([0, 0, 255, 255, 0, 6])).isEmpty)
        let started = Date()
        let catalog = FontCatalog()
        print(String(format: "Font catalog: %d entries in %.3f s", catalog.entries.count, Date().timeIntervalSince(started)))
        let chinese = catalog.search("", scope: .chinese)
        precondition(!chinese.isEmpty && chinese.allSatisfy(\.chinese))
        precondition(catalog.search("苹方", scope: .chinese).contains(where: { $0.family == "PingFang SC" }), "Chinese metadata aliases must work in an English UI")
        precondition(catalog.search("", scope: .monospaced).allSatisfy(\.monospaced))
        for entry in catalog.entries where entry.installed {
            precondition(NSFontManager.shared.font(withFamily: entry.family, traits: [], weight: 5, size: 16) != nil)
            precondition(catalog.search(entry.family, scope: .all).contains(where: { $0.family == entry.family }))
            precondition(catalog.search(entry.name, scope: .all).contains(where: { $0.family == entry.family }))
        }
        let result = catalog.search("霞骛文楷", scope: .chinese)
        precondition(result.contains(where: { $0.family == "LXGW WenKai" }))
        if NSFontManager.shared.font(withFamily: "LXGW WenKai", traits: [], weight: 5, size: 16) == nil {
            let missing = result.first(where: { $0.family == "LXGW WenKai" })!
            precondition(!missing.installed && missing.page?.host == "github.com")
        }
        let start = Date()
        for _ in 0..<100 { _ = catalog.search("文楷", scope: .chinese) }
        print(String(format: "100 cached Chinese searches: %.3f s", Date().timeIntervalSince(start)))
        print("Font catalog checks passed: aliases, real family resolution, CJK/mono filtering, missing-font state.")
        if let path = CommandLine.arguments.first(where: { $0.hasSuffix(".ttf") }) {
            let url = URL(fileURLWithPath: path) as CFURL
            precondition(CTFontManagerRegisterFontsForURL(url, .process, nil))
            defer { CTFontManagerUnregisterFontsForURL(url, .process, nil) }
            let refreshed = FontCatalog()
            let installed = refreshed.search("霞骛文楷", scope: .chinese).first(where: { $0.family == "LXGW WenKai" })!
            precondition(installed.installed, "Refreshing must find the newly registered family")
            precondition(refreshed.search("xia wu wen kai", scope: .chinese).contains(where: { $0.family == installed.family }))
            let font = NSFontManager.shared.font(withFamily: installed.family, traits: [], weight: 5, size: 23)!
            let ct = CTFontCreateWithName(font.fontName as CFString, 23, nil)
            let characters = Array("霞鹜文楷".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            precondition(CTFontGetGlyphsForCharacters(ct, characters, &glyphs, characters.count))
            print("Process-only installation and refresh passed: \(installed.family), actual Chinese glyphs present.")
        }
    }
}
