import AppKit
import ZephyrCore
import ZephyrRender

/// Keep in step with MARKETING_VERSION in apps/macos/project.yml.
let zephyrVersion = "0.1.3"

/// `zephyr` command-line tool. Local commands read files directly; agent commands go through the
/// running app and see only documents the user shared, as currently edited. Document changes are
/// proposals the user approves in Zephyr; `export` is the explicit output-file exception.
let usage = """
usage: zephyr open <file.md>...         open files in Zephyr
       zephyr files [folder]            list Markdown files in the folder scope
       zephyr search <text> [folder]    literal search (ASCII case-insensitive)
       zephyr outline <file.md> [--depth N]   the headings as Zephyr's outline shows them
       zephyr stats <file.md>           characters, words, paragraphs, as Zephyr counts them
       zephyr export <file.md> --output path [--format pdf|html|png|jpg|txt] [--theme selected|THEME]
                     [--text-size theme|points] [--line-height theme|N]
                     [--paper letter|a4] [--margin points] [--raster-width points] [--scale 1|2|3] [--overwrite]
       zephyr home [folder]             folder home: Markdown files and home notes
       zephyr activity [--days N]       daily opens and observed changes (1–365 days)

     Markdown pages and legacy notes:
       zephyr today [YYYY-MM-DD]        the day's schedule and tasks
       zephyr goals                     goals with their progress
       zephyr pages                     the pages you made, with their tasks done
       zephyr page <name|file.md>       a page's blocks as Zephyr lays them out
       zephyr space                     the folder of these notes

     shared documents (Allow Agent Access from a document's top bar in Zephyr):
       zephyr sessions                  list shared documents
       zephyr context                   path, revision, selection and outline
       zephyr read [path] [--lines A:B] the document as edited, or a file in its folder scope
       zephyr find <text> [--folder]    search the document or its folder scope
       zephyr propose --find TEXT --replace TEXT [...] [--summary S] [--wait]
       zephyr propose --json FILE|-     {"summary": "...", "edits": [{"find": "...", "replace": "..."}]}
       zephyr mcp                       MCP server on stdio (get_context, search, read, propose_patch,
                                        get_appearance, set_appearance)
       (add --session ID when several documents are shared)

     how documents look (themes and their settings; the running app follows, and can undo):
       zephyr config list|get|set|reset ...   zephyr theme list|use|new|rename|delete|folder ...
       (zephyr config or zephyr theme alone prints their usage)
       zephyr --version
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func scopeRoot(_ argument: String?) -> URL {
    if let argument { return URL(fileURLWithPath: argument).standardizedFileURL }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return ScopeResolver.root(for: cwd.appendingPathComponent(".zephyr-probe"), registeredRoots: [])
}

/// The app bundle that contains this tool (Zephyr.app/Contents/Helpers/zephyr).
func appBundle() -> URL? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.zephyr.Zephyr")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()

switch command {
case "open":
    guard !args.isEmpty else { fail(usage) }
    guard let app = appBundle() else { fail("Zephyr.app not found") }
    let urls = args.map { URL(fileURLWithPath: $0).standardizedFileURL }
    let configuration = NSWorkspace.OpenConfiguration()
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
        if let error { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)) }
        done.signal()
    }
    done.wait()
case "files":
    let root = scopeRoot(args.first)
    for file in FolderScanner.markdownFiles(in: root) { print(file.relativePath) }
case "home":
    guard args.count <= 1 else { fail(usage) }
    let root = scopeRoot(args.first)
    guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { fail("No folder at \(root.path)") }
    let files = FolderScanner.markdownFiles(in: root)
    let homeNames = Set(["readme.md", "index.md"])
    let homes = files.filter { !$0.relativePath.contains("/") && homeNames.contains($0.name.lowercased()) }
    print("\(root.lastPathComponent) · \(files.count) Markdown files")
    if !homes.isEmpty {
        print("\nHome notes")
        for file in homes { print("  \(file.relativePath)") }
    }
    let grouped = Dictionary(grouping: files.filter { !homes.contains($0) }) { file in
        let folder = (file.relativePath as NSString).deletingLastPathComponent
        return folder == "." ? "Files" : folder
    }
    for group in grouped.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
        print("\n\(group)")
        for file in grouped[group]! { print("  \(file.relativePath)") }
    }
    print("(\(root.path))")
case "activity":
    var days = 30
    if !args.isEmpty {
        guard args.count == 2, args[0] == "--days", let count = Int(args[1]), (1...ActivityStore.maximumDays).contains(count) else { fail("zephyr activity --days takes 1 to 365") }
        days = count
    }
    do {
        let store = try ActivityStore(url: Space.activityURL)
        for day in store.history(days: days) {
            print("\(day.date)  opened \(day.opened.count)  added \(day.added.count)  changed \(day.modified.count)  removed \(day.removed.count)\(day.saturated ? "  +" : "")")
        }
    } catch { fail(error.localizedDescription) }
case "search":
    guard let query = args.first else { fail(usage) }
    let root = scopeRoot(args.dropFirst().first)
    let files = FolderScanner.markdownFiles(in: root)
    FolderScanner.search(query, in: files, isCancelled: { false }) { batch in
        for m in batch { print("\(m.file.relativePath):\(m.line): \(m.snippet)") }
    }
case "outline":
    var depth = 6
    if let i = args.firstIndex(of: "--depth") {
        guard i + 1 < args.count, let n = Int(args[i + 1]), (1...6).contains(n) else { fail("--depth takes 1 to 6") }
        depth = n
        args.removeSubrange(i...(i + 1))
    }
    guard let path = args.first, let data = FileManager.default.contents(atPath: path) else { fail(usage) }
    let headings = Outline.headings(in: SourceDecoder.decode(data).0 as NSString)
    // Levels count from the document's top one, as in the app (Settings › General › Outline).
    let top = headings.map(\.level).min() ?? 1
    for h in headings where h.level < top + depth { print(String(repeating: "  ", count: h.level - top) + h.title) }
case "stats":
    guard let path = args.first, let data = FileManager.default.contents(atPath: path) else { fail(usage) }
    let s = TextStatistics.count(SourceDecoder.decode(data).0 as NSString)
    print("characters \(s.characters)  (with spaces \(s.charactersWithSpaces))")
    print("words      \(s.words)  (Chinese and Japanese characters \(s.hanUnits), other words \(s.otherWords))")
    print("paragraphs \(s.paragraphs)  headings \(s.headings)")
    print("reading    \(max(1, Int(s.readingMinutes.rounded()))) min")
    print("(prose only: code, formulas, diagrams and front matter are not counted)")
case "export":
    guard let input = args.first else { fail(usage) }
    let exportOptions: Set<String> = ["--format", "--theme", "--text-size", "--line-height", "--paper", "--margin", "--raster-width", "--scale", "--output", "--overwrite"]
    if let unknown = args.first(where: { $0.hasPrefix("--") && !exportOptions.contains($0) }) { fail("Unknown export option: \(unknown)") }
    var export: MarkdownExport.Settings
    do { export = try MainActor.assumeIsolated { try MarkdownExport.Settings.load() } }
    catch { fail(error.localizedDescription) }
    if let formatAt = args.firstIndex(of: "--format") {
        guard formatAt + 1 < args.count, !args[formatAt + 1].hasPrefix("--"), let format = MarkdownExport.Format(rawValue: args[formatAt + 1]) else { fail("--format takes pdf, html, png, jpg or txt") }
        export.format = format
    }
    if let themeAt = args.firstIndex(of: "--theme") {
        guard themeAt + 1 < args.count, !args[themeAt + 1].hasPrefix("--") else { fail("--theme takes selected or a theme name") }
        export.themeID = args[themeAt + 1] == "selected" ? nil : args[themeAt + 1]
    }
    if let sizeAt = args.firstIndex(of: "--text-size") {
        guard sizeAt + 1 < args.count, !args[sizeAt + 1].hasPrefix("--") else { fail("--text-size takes theme or 11 to 28 points") }
        if args[sizeAt + 1] == "theme" { export.textSize = nil }
        else {
            guard let size = Double(args[sizeAt + 1]), MarkdownExport.Settings.textSizes.contains(CGFloat(size)) else { fail("--text-size takes theme or 11 to 28 points") }
            export.textSize = CGFloat(size)
        }
    }
    if let heightAt = args.firstIndex(of: "--line-height") {
        guard heightAt + 1 < args.count, !args[heightAt + 1].hasPrefix("--") else { fail("--line-height takes theme or 1.2 to 2.4") }
        if args[heightAt + 1] == "theme" { export.lineHeight = nil }
        else {
            guard let height = Double(args[heightAt + 1]), MarkdownExport.Settings.lineHeights.contains(CGFloat(height)) else { fail("--line-height takes theme or 1.2 to 2.4") }
            export.lineHeight = CGFloat(height)
        }
    }
    if let paperAt = args.firstIndex(of: "--paper") {
        guard paperAt + 1 < args.count, !args[paperAt + 1].hasPrefix("--"), let paper = MarkdownExport.Settings.Paper(rawValue: args[paperAt + 1]) else { fail("--paper takes letter or a4") }
        export.paper = paper
    }
    if let marginAt = args.firstIndex(of: "--margin") {
        guard marginAt + 1 < args.count, !args[marginAt + 1].hasPrefix("--"), let margin = Double(args[marginAt + 1]), (0...144).contains(margin) else { fail("--margin takes 0 to 144 points") }
        export.margin = CGFloat(margin)
    }
    if let widthAt = args.firstIndex(of: "--raster-width") {
        guard widthAt + 1 < args.count, !args[widthAt + 1].hasPrefix("--"), let width = Double(args[widthAt + 1]), (320...1440).contains(width) else { fail("--raster-width takes 320 to 1440 points") }
        export.rasterWidth = CGFloat(width)
    }
    if let scaleAt = args.firstIndex(of: "--scale") {
        guard scaleAt + 1 < args.count, !args[scaleAt + 1].hasPrefix("--"), let scale = Double(args[scaleAt + 1]), [1, 2, 3].contains(scale) else { fail("--scale takes 1, 2 or 3") }
        export.rasterScale = CGFloat(scale)
    }
    guard let outputAt = args.firstIndex(of: "--output"), outputAt + 1 < args.count, !args[outputAt + 1].hasPrefix("--") else { fail(usage) }
    let source = URL(fileURLWithPath: input).standardizedFileURL
    guard let data = FileManager.default.contents(atPath: source.path) else { fail("No file at \(source.path)") }
    let decoded = SourceDecoder.decode(data)
    guard decoded.encoding.isValidUTF8 else { fail("This file is not valid UTF-8 and cannot be exported.") }
    let requested = URL(fileURLWithPath: args[outputAt + 1]).standardizedFileURL
    let output = requested
    var appearance = AppearanceState.load() ?? AppearanceState()
    appearance.migrate()
    do {
        let written = try MainActor.assumeIsolated {
            _ = NSApplication.shared
            let collapsed = UserDefaults(suiteName: "dev.zephyr.Zephyr")?.bool(forKey: "frontMatterCollapsed") ?? false
            let typography = try MarkdownExport.typography(for: export, appearance: appearance)
            return try MarkdownExport.write(text: decoded.text, typography: typography, baseURL: source.deletingLastPathComponent(), format: export.format, output: output, inputURL: source, frontMatterCollapsed: collapsed, settings: export, overwrite: args.contains("--overwrite"))
        }
        for url in written { print(url.path) }
    } catch {
        fail(error.localizedDescription)
    }
case "today":
    var date = Date()
    if let day = args.first {
        guard let parsed = Space.date(ofDaily: day + ".md") else { fail("zephyr today takes a date as YYYY-MM-DD") }
        date = parsed
    }
    let url = Space.dailyURL(date)
    let items = Space.items(in: ((try? Data(contentsOf: url)).map { SourceDecoder.decode($0).text } ?? "") as NSString)
    let time: (Int) -> String = { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
    print("\(date.formatted(.dateTime.weekday(.wide).month(.wide).day())) · \(items.filter(\.done).count) of \(items.count) done")
    for item in items.filter({ $0.start != nil }).sorted(by: { $0.start! < $1.start! }) {
        let when = time(item.start!) + (item.end.map { "–" + time($0) } ?? "")
        print("  [\(item.done ? "x" : " ")] \(when.padding(toLength: 12, withPad: " ", startingAt: 0)) \(item.text)")
    }
    for item in items where item.start == nil { print("  [\(item.done ? "x" : " ")] \(item.text)") }
    print("(\(url.path))")
case "goals":
    let url = Space.goalsURL
    let goals = Space.goals(in: ((try? Data(contentsOf: url)).map { SourceDecoder.decode($0).text } ?? "") as NSString)
    if goals.isEmpty { print("No goals yet.") }
    for goal in goals {
        print("\(goal.title)  \(goal.done)/\(goal.total) (\(Int((goal.progress * 100).rounded()))%)\(goal.due.map { "  due \($0)" } ?? "")")
    }
    print("(\(url.path))")
case "pages":
    let files = (try? FileManager.default.contentsOfDirectory(at: Board.folder, includingPropertiesForKeys: nil)) ?? []
    let pages = files.filter { $0.pathExtension.lowercased() == "md" }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    if pages.isEmpty { print("No pages yet.") }
    for url in pages {
        let text = (try? Data(contentsOf: url)).map { SourceDecoder.decode($0).text } ?? ""
        let page = Board.page(in: text as NSString)
        let items = Space.items(in: text as NSString)
        let tasks = items.isEmpty ? "" : "  \(items.filter(\.done).count)/\(items.count) done"
        print("\(page.title ?? url.deletingPathExtension().lastPathComponent)  \(page.blocks.count) blocks\(tasks)")
    }
    print("(\(Board.folder.path))")
case "page":
    guard let name = args.first else { fail(usage) }
    let url = name.contains("/") ? URL(fileURLWithPath: name) : Board.folder.appendingPathComponent(name.hasSuffix(".md") ? name : name + ".md")
    guard let data = FileManager.default.contents(atPath: url.path) else { fail("No page at \(url.path)") }
    let text = SourceDecoder.decode(data).text as NSString
    let page = Board.page(in: text)
    print(page.title ?? url.deletingPathExtension().lastPathComponent)
    if let line = page.intro.components(separatedBy: "\n").first, !line.isEmpty { print(line) }
    for block in page.blocks {
        let kind: String
        switch block.content {
        case .tasks: kind = "tasks"
        case .links: kind = "links"
        case .numbers: kind = "numbers"
        case .text: kind = "text"
        case let .live(live): kind = "live: " + live.rawValue
        }
        print("\n## \(block.title)  [\(kind)\(block.wide ? ", wide" : "")]")
        switch block.content {
        case let .tasks(items):
            for item in items {
                let when = item.start.map { String(format: "%02d:%02d ", $0 / 60, $0 % 60) } ?? ""
                print("  [\(item.done ? "x" : " ")] \(when)\(item.text)")
            }
        case let .links(links):
            for link in links { print("  \(link.title) → \(link.destination)") }
        case let .numbers(numbers):
            for n in numbers { print("  \(n.label): \(n.value)\(n.progress.map { "  (\(Int(($0 * 100).rounded()))%)" } ?? "")") }
        case .text:
            let lines = text.substring(with: block.body).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            for line in lines.prefix(4) { print("  " + line) }
            if lines.count > 4 { print("  …") }
        case .live:
            break
        }
    }
    print("(\(url.path))")
case "space":
    print(Space.folder.path)
case "sessions", "context", "read", "find", "propose":
    AgentCommands.run(command, args)
case "config", "theme":
    // Bare `zephyr config` / `zephyr theme` explain themselves rather than listing.
    guard !args.isEmpty else { print(AppearanceCommands.usage); exit(0) }
    do { print(try AppearanceCommands.run([command] + args)) } catch let error as AppearanceSettings.SettingError { fail(error.message) } catch { fail(error.localizedDescription) }
case "mcp":
    MCPServer.run()
case "--version", "-v":
    print("zephyr \(zephyrVersion)")
default:
    fail(usage)
}
