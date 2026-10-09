import Foundation
import Testing
@testable import ZephyrCore

/// The atomic appearance settings (design §21.7): one checked key per value, shared by the
/// settings window, `zephyr config`, MCP and the built-in assistant.
@Suite struct AppearanceSettingsTests {
    @Test func defaultsAndOverrides() throws {
        var s = AppearanceSettings()
        #expect(s.number("text.size") == 16)
        #expect(s.number("h2.size") == nil, "auto: follows the heading scale")
        #expect(s.string("palette") == "zephyr")
        #expect(s.string("image.align") == "center")
        try s.set("text.size", "18 pt")
        try s.set("h2.size", "1.6")
        try s.set("table.lines", "Grid")
        try s.set("image.align", "left")
        try s.set("table.stripes", "yes")
        try s.set("color.dark.accent", "4db")
        #expect(s.number("text.size") == 18 && s.number("h2.size") == 1.6)
        #expect(s.string("table.lines") == "grid" && s.string("image.align") == "left" && s.flag("table.stripes"))
        #expect(s.string("color.dark.accent") == "#44DDBB")
        try s.set("text.size", "default")
        #expect(!s.isSet("text.size") && s.number("text.size") == 16)
        try s.set("table.lines", "rows")
        #expect(!s.isSet("table.lines"), "setting the default stores nothing")
        s.reset(prefix: "h2.")
        #expect(s.number("h2.size") == nil)
    }

    /// The header's one choice of earlier versions reads as today's two switches.
    @Test func earlierHeaderChoiceMigrates() {
        let bold = AppearanceSettings.parse(object: ["table.header": "bold"])
        #expect(bold.problems.isEmpty && !bold.settings.flag("table.headerShade") && bold.settings.flag("table.headerBold"))
        let plain = AppearanceSettings.parse(object: ["table.header": "plain"]).settings
        #expect(!plain.flag("table.headerShade") && !plain.flag("table.headerBold"))
        #expect(AppearanceSettings.parse(object: ["table.header": "shaded"]).settings.overrides.isEmpty, "both on: the defaults")
    }

    @Test func refusesWhatItCannotTakeAndSaysWhy() {
        var s = AppearanceSettings()
        #expect(throws: AppearanceSettings.SettingError.self) { try s.set("text.size", "40") }
        #expect(throws: AppearanceSettings.SettingError.self) { try s.set("text.size", "big") }
        #expect(throws: AppearanceSettings.SettingError.self) { try s.set("table.lines", "dotted") }
        #expect(throws: AppearanceSettings.SettingError.self) { try s.set("color.light.text", "red") }
        #expect(throws: AppearanceSettings.SettingError.self) { try s.set("font.body", "body") }
        do { try s.set("heading.size", "2") } catch let e as AppearanceSettings.SettingError {
            #expect(e.message.contains("Unknown setting heading.size"))
        } catch { Issue.record("wrong error") }
        do { try s.set("text.size", "40") } catch let e as AppearanceSettings.SettingError {
            #expect(e.message.contains("11–28"), "the range is in the message: \(e.message)")
        } catch { Issue.record("wrong error") }
        #expect(s.overrides.isEmpty)
    }

    @Test func roundTripsThroughTheFileAndReportsBadEntries() throws {
        var s = AppearanceSettings()
        try s.set("paragraph.indent", "2")
        try s.set("palette", "anthology")
        try s.set("font.body", "'Newsreader',  serif")
        #expect(s.string("font.body") == "Newsreader, serif")
        try s.set("diagram.render", "false")
        try s.set("css", "h1 { font-weight: 800 }")
        let back = AppearanceSettings.parse(json: s.json())
        #expect(back.settings == s && back.problems.isEmpty)
        let (loaded, problems) = AppearanceSettings.parse(json: Data(#"{"text.size": 99, "nope": 1, "palette": "readme"}"#.utf8))
        #expect(loaded.string("palette") == "readme" && loaded.number("text.size") == 16)
        #expect(problems.count == 2)
    }

    @Test func describesEveryKeyForAgents() {
        var s = AppearanceSettings()
        try? s.set("h1.weight", "800")
        let text = s.describe(prefix: "h1.")
        #expect(text.contains("h1.weight = 800  (default 700)"))
        #expect(text.contains("h1.size = auto"))
        #expect(AppearanceSettings.specs.allSatisfy { !$0.help.isEmpty })
        #expect(Set(AppearanceSettings.specs.map(\.key)).count == AppearanceSettings.specs.count)
    }

    @Test func builtInsKeepChangesAsOverrides() throws {
        var state = AppearanceState(active: "anthology")
        #expect(state.settings().string("palette") == "anthology")
        #expect(state.settings().string("font.body").hasPrefix("Newsreader"), "open-source first")
        #expect(!state.isModified("anthology"))
        _ = try state.change { try $0.set("zoom", "1.2") }
        _ = try state.change { try $0.set("font.body", "system") }
        _ = try state.change { try $0.set("table.lines", "grid") }
        #expect(state.settings().number("zoom") == 1.2 && state.settings().string("table.lines") == "grid")
        #expect(state.settings().string("font.body") == "system", "choosing the global default in a built-in sticks")
        #expect(state.isModified("anthology"))
        let back = AppearanceState.parse(json: state.json())
        #expect(back == state)
        state.active = "readme"
        #expect(state.settings().number("zoom") == 1, "overrides belong to one built-in")
        try state.restore("anthology")
        state.active = "anthology"
        #expect(state.settings().string("table.lines") == "rows" && !state.isModified("anthology"))
        #expect(throws: AppearanceSettings.SettingError.self) { try state.restore("Mine") }
        #expect(AppearanceState(active: "Zephyr").settings().string("code.style") == "card", "Zephyr is built in")
        #expect(AppearanceState.parse(json: Data(#"{"active":"Zephyr"}"#.utf8)).active == "Zephyr", "as written, for the migration to follow")
    }

    @Test func customThemesAreFilesInAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var state = AppearanceState(active: "Mine", themesFolder: folder.path)
        _ = try state.change { try $0.set("h2.size", "1.6"); try $0.set("table.stripes", "true") }
        #expect(ThemeLibrary.names(in: folder) == ["Mine"])
        #expect(try ThemeLibrary.load("Mine", in: folder).number("h2.size") == 1.6)
        #expect(throws: AppearanceSettings.SettingError.self) { _ = try ThemeLibrary.check(name: "Readme", in: folder) }
        #expect(throws: AppearanceSettings.SettingError.self) { _ = try ThemeLibrary.check(name: "mine", in: folder) }
        #expect(try ThemeLibrary.check(name: " Essay ", in: folder) == "Essay")
        try ThemeLibrary.rename("Mine", to: "Essay", in: folder)
        #expect(ThemeLibrary.names(in: folder) == ["Essay"])
        // The custom "Zephyr" every library had steps aside for the built-in; an empty one goes.
        var old = AppearanceSettings()
        try old.set("text.size", "18")
        try ThemeLibrary.save(old, as: "Zephyr", in: folder)
        try ThemeLibrary.save(AppearanceSettings(), as: "readme", in: folder)
        var stale = AppearanceState(active: "Zephyr", themesFolder: folder.path)
        stale.migrate()
        #expect(stale.active == "Zephyr Custom", "the active theme follows its file")
        #expect(ThemeLibrary.migrate(in: folder).isEmpty)
        #expect(ThemeLibrary.names(in: folder) == ["Essay", "Zephyr Custom"])
        #expect(ThemeLibrary.suggestedName(from: "zephyr", in: folder) == "Zephyr Custom 2")
        #expect(ThemeLibrary.suggestedName(from: "Essay", in: folder) == "Essay Custom")
    }

    @Test func commandsAndToolsEditTheFilesTheAppWatches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("appearance.json")
        let themes = dir.appendingPathComponent("Themes")
        try AppearanceState(themesFolder: themes.path).save(to: url)
        func run(_ words: String...) throws -> String { try AppearanceCommands.run(words, url: url) }
        func active() -> AppearanceSettings { AppearanceState.load(from: url)!.settings() }

        _ = try run("config", "set", "table.lines", "grid", "h2.size=1.6")
        #expect(active().string("table.lines") == "grid" && active().number("h2.size") == 1.6)
        #expect(throws: AppearanceSettings.SettingError.self) { _ = try run("config", "set", "table.stripes", "true", "h2.size", "9") }
        #expect(!active().flag("table.stripes"), "one refused value refuses the whole command")
        _ = try run("config", "reset", "table.")
        #expect(active().string("table.lines") == "rows")

        _ = try run("theme", "use", "Anthology")
        _ = try run("config", "set", "zoom", "1.2", "table.lines", "grid")
        #expect(active().string("table.lines") == "grid")
        _ = try run("config", "reset", "zoom", "table.lines")
        #expect(AppearanceState.load(from: url)!.adjustments["anthology"] == nil, "a reset in a built-in returns to its own value")

        _ = try run("theme", "new", "Essay", "--from", "anthology")
        #expect(AppearanceState.load(from: url)!.active == "Essay")
        #expect(active().string("palette") == "anthology")
        #expect(try run("config", "get", "h2.size", "--theme", "zephyr").hasPrefix("h2.size = 1.6"))

        let (text, isError) = AppearanceTools.run("set_appearance", arguments: ["set": ["text.size": 17, "table.stripes": true], "theme": "Zephyr"], url: url)
        #expect(!isError, "\(text)")
        #expect(AppearanceState.load(from: url)!.adjustments["zephyr"]?["text.size"] == .number(17))
        #expect(try run("theme", "list").contains("Zephyr (modified)"))
        _ = try run("theme", "restore", "zephyr")
        #expect(AppearanceState.load(from: url)!.adjustments["zephyr"] == nil)
        #expect(throws: AppearanceSettings.SettingError.self) { _ = try run("theme", "delete", "zephyr") }
        #expect(ThemeLibrary.names(in: themes) == ["Essay"])
        #expect(AppearanceTools.run("set_appearance", arguments: ["set": ["text.size": [1]]], url: url).isError)
        #expect(AppearanceTools.run("set_appearance", arguments: [:], url: url).isError)
    }

    @Test func previewAppearanceUsesOneBoundedFlattenedSnapshot() throws {
        let domain = "\(PreviewAppearance.domain).tests.\(UUID().uuidString)"
        let previous = CFPreferencesCopyAppValue(PreviewAppearance.settingsKey as CFString, domain as CFString)
        defer {
            CFPreferencesSetAppValue(PreviewAppearance.settingsKey as CFString, previous, domain as CFString)
            _ = CFPreferencesAppSynchronize(domain as CFString)
            if previous == nil { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        }

        var snapshots = ThemeLibrary.presets.map { ($0.id, AppearanceSettings(overrides: $0.keys)) }
        var cssSettings = AppearanceSettings(overrides: ThemeLibrary.preset("anthology")!.keys)
        try cssSettings.set("appearance", "dark")
        try cssSettings.set("css", "body { font-size: 18px; color: teal }")
        snapshots.append(("css", cssSettings))
        for (name, settings) in snapshots {
            try PreviewAppearance.publish(settings, domain: domain)
            let loaded = try #require(try PreviewAppearance.load(domain: domain))
            for spec in AppearanceSettings.specs {
                #expect(loaded.value(spec.key) == settings.value(spec.key), "\(name): \(spec.key) keeps its effective value")
            }
        }

        let oversized = Data(repeating: 0, count: PreviewAppearance.maximumDataSize + 1)
        CFPreferencesSetAppValue(PreviewAppearance.settingsKey as CFString, oversized as CFData, domain as CFString)
        _ = CFPreferencesAppSynchronize(domain as CFString)
        #expect(throws: PreviewAppearance.SnapshotError.self) { _ = try PreviewAppearance.load(domain: domain) }
    }
}
