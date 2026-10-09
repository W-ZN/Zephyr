import AppKit
import CoreText

/// Font names shown to people are separate from the canonical family saved in a theme.
/// Build once when opening/refreshing the chooser; searching never enumerates system fonts.
struct FontCatalog {
    enum Scope { case all, chinese, monospaced }

    struct Entry {
        let family: String
        let name: String
        let installed: Bool
        let chinese: Bool
        let monospaced: Bool
        let page: URL?
        private let searchText: String

        init(family: String, name: String, installed: Bool, chinese: Bool, monospaced: Bool, aliases: [String] = [], page: URL? = nil) {
            self.family = family
            self.name = name
            self.installed = installed
            self.chinese = chinese
            self.monospaced = monospaced
            self.page = page
            let names = ([family, name] + aliases).joined(separator: " ")
            let pinyin = names.applyingTransform(.toLatin, reverse: false) ?? names
            searchText = FontCatalog.normalized("\(names) \(pinyin)")
        }

        var title: String { name == family ? family : "\(name) · \(family)" }
        func matches(_ query: String) -> Bool {
            query.split(whereSeparator: \.isWhitespace).allSatisfy { searchText.contains(FontCatalog.normalized(String($0))) }
        }
    }

    let entries: [Entry]

    init() {
        let manager = NSFontManager.shared
        let families = CTFontManagerCopyAvailableFontFamilyNames() as! [String]
        var list = families.filter { !$0.hasPrefix(".") }.map { family in
            let font = manager.font(withFamily: family, traits: [], weight: 5, size: 14)
            let chinese = font.map { $0.coveredCharacterSet.contains("中".unicodeScalars.first!) && $0.coveredCharacterSet.contains("文".unicodeScalars.first!) } ?? false
            var aliases: [String] = []
            if let font, chinese {
                let ct = CTFontCreateWithName(font.fontName as CFString, 14, nil)
                if let names = CTFontCopyTable(ct, CTFontTableTag(kCTFontTableName), []) { aliases = Self.familyNames(in: names as Data) }
            }
            if family.hasPrefix("LXGW WenKai") { aliases.append(family.replacingOccurrences(of: "LXGW WenKai", with: "霞鹜文楷")) }
            return Entry(family: family, name: Self.localizedName(for: family), installed: font != nil, chinese: chinese, monospaced: font?.isFixedPitch == true, aliases: aliases)
        }
        // A searched-for font should explain its absence, never silently preview a substitute.
        if !list.contains(where: { $0.family.caseInsensitiveCompare("LXGW WenKai") == .orderedSame }) {
            list.append(Entry(family: "LXGW WenKai", name: "霞鹜文楷", installed: false, chinese: true, monospaced: false,
                              page: URL(string: "https://github.com/lxgw/LxgwWenKai")))
        }
        entries = list.sorted {
            if $0.installed != $1.installed { return $0.installed }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func search(_ query: String, scope: Scope) -> [Entry] {
        entries.filter { entry in
            let included: Bool
            switch scope {
            case .all: included = true
            case .chinese: included = entry.chinese
            case .monospaced: included = entry.monospaced
            }
            return included && entry.matches(query)
        }
    }

    static func localizedName(for family: String) -> String {
        NSFontManager.shared.localizedName(forFamily: family, face: nil)
    }

    static func displayName(for family: String) -> String {
        let name = localizedName(for: family)
        return name == family ? family : "\(name) · \(family)"
    }

    /// Unicode family-name records retain Chinese search aliases even in an English UI.
    /// Only family IDs 1/16 are indexed: face names such as Regular must not match every font.
    static func familyNames(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { return [] }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        let count = u16(2), storage = u16(4)
        guard count <= (bytes.count - 6) / 12, storage <= bytes.count else { return [] }
        var names = Set<String>()
        for index in 0..<count {
            let record = 6 + index * 12
            let platform = u16(record), encoding = u16(record + 2), nameID = u16(record + 6)
            guard nameID == 1 || nameID == 16 else { continue }
            guard platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10)) else { continue }
            let length = u16(record + 8), start = storage + u16(record + 10)
            guard start <= bytes.count, length <= bytes.count - start, length.isMultiple(of: 2) else { continue }
            if let name = String(bytes: bytes[start..<(start + length)], encoding: .utf16BigEndian), !name.isEmpty { names.insert(name) }
        }
        return names.sorted()
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.replacingOccurrences(of: "霞骛", with: "霞鹜")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
