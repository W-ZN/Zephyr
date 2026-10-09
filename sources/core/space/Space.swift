import Foundation

/// Zephyr's own space (design §8.3): the app-level panels, Today, Goals and Overview, read and
/// write plain Markdown in a folder Zephyr owns. Nothing here is a database: every figure comes
/// from the text, every change is a minimal patch of it, so the assistant, the CLI and MCP read
/// and propose changes to these notes with the same tools as any file (design §21.6), and the
/// user can open, move or sync them like any notes.
public enum Space {
    /// A task line, `- [ ] text` or `- [x] text`, whose text may start with a time (`09:30`) or a
    /// time range (`09:30–10:15`): timed tasks are the day's schedule.
    public struct Item: Equatable, Sendable {
        public var text: String
        public var done: Bool
        /// Minutes after midnight.
        public var start: Int?
        public var end: Int?
        /// The line, without its line break (UTF-16).
        public var line: NSRange
        /// The character between the brackets: what checking the box changes.
        public var box: Int
    }

    /// A goal: a heading of the goals note, its tasks below it, and an optional `due: 2026-12-31`
    /// (or `截止：2026-12-31`) line.
    public struct Goal: Equatable, Sendable {
        public var title: String
        public var location: Int
        public var due: String?
        public var done: Int
        public var total: Int

        public var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    // MARK: Reading

    private static let task = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+\[([ xX])\][ \t]+(.*)$"#)
    private static let time = try! NSRegularExpression(pattern: #"^(\d{1,2})[:：](\d{2})(?:\s*[-–—~至]\s*(\d{1,2})[:：](\d{2}))?\s+(.+)$"#)

    /// The task lines of a note, outside front matter and fenced code.
    public static func items(in text: NSString) -> [Item] {
        var result: [Item] = []
        lines(of: text) { range, line in
            guard let m = task.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return }
            let ns = line as NSString
            var item = Item(text: ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces), done: ns.substring(with: m.range(at: 1)) != " ",
                            start: nil, end: nil, line: range, box: range.location + m.range(at: 1).location)
            let body = item.text as NSString
            if let t = time.firstMatch(in: item.text, range: NSRange(location: 0, length: body.length)) {
                func minutes(_ h: Int, _ m: Int) -> Int? {
                    let hour = Int(body.substring(with: t.range(at: h))) ?? 99, minute = Int(body.substring(with: t.range(at: m))) ?? 99
                    return hour < 24 && minute < 60 ? hour * 60 + minute : nil
                }
                if let start = minutes(1, 2) {
                    item.start = start
                    item.end = t.range(at: 3).location == NSNotFound ? nil : minutes(3, 4)
                    item.text = body.substring(with: t.range(at: 5))
                }
            }
            result.append(item)
        }
        return result
    }

    /// The goals note: its second-level headings (first-level when it has none) with the tasks
    /// under each until the next such heading.
    public static func goals(in text: NSString) -> [Goal] {
        let headings = Outline.headings(in: text)
        let level = headings.contains { $0.level == 2 } ? 2 : 1
        let marks = headings.filter { $0.level <= level }
        let items = items(in: text)
        return marks.indices.compactMap { i in
            let h = marks[i]
            guard h.level == level else { return nil }
            let end = i + 1 < marks.count ? marks[i + 1].location : text.length
            let section = NSRange(location: h.location, length: end - h.location)
            let own = items.filter { NSLocationInRange($0.line.location, section) }
            var due: String?
            if let m = try? NSRegularExpression(pattern: #"(?im)^\s*(?:due|截止)\s*[:：]\s*(\d{4}-\d{2}-\d{2})"#).firstMatch(in: text as String, range: section) {
                due = text.substring(with: m.range(at: 1))
            }
            return Goal(title: h.title, location: h.location, due: due, done: own.filter(\.done).count, total: own.count)
        }
    }

    /// Lines outside front matter and fenced code, without their line breaks.
    private static func lines(of text: NSString, _ body: (NSRange, String) -> Void) {
        var pos = ChunkIndex.frontMatterEnd(text) ?? 0
        var fence: Fence?
        var start = 0, end = 0, contents = 0
        while pos < text.length {
            text.getLineStart(&start, end: &end, contentsEnd: &contents, for: NSRange(location: pos, length: 0))
            pos = end
            let range = NSRange(location: start, length: contents - start)
            // Fences as the canvas and the outline see them (`Fence`).
            if Outline.mayFence(text, start, range.length) {
                let units = Outline.units(text, start, range.length)
                if let open = fence {
                    if open.isClosed(by: units) { fence = nil }
                    continue
                }
                if let opening = Fence(opening: units) {
                    fence = opening
                    continue
                }
            }
            if fence == nil { body(range, text.substring(with: range)) }
        }
    }

    /// `item` as it is in `text` now: at the same place if it is still there, else the nearest
    /// item with the same text and state; nil when it is gone. A page shows what it read last;
    /// the note may have changed since (an editor, the assistant, another app), so a change made
    /// from the page is made against the item found here, never against old offsets.
    public static func locate(_ item: Item, in text: NSString) -> Item? {
        let same = items(in: text).filter { $0.text == item.text && $0.done == item.done && $0.start == item.start && $0.end == item.end }
        return same.min { abs($0.line.location - item.line.location) < abs($1.line.location - item.line.location) }
    }

    // MARK: Changing

    /// Checking or clearing an item's box: one character.
    public static func toggle(_ item: Item) -> TextPatch {
        TextPatch(range: NSRange(location: item.box, length: 1), replacement: item.done ? " " : "x")
    }

    /// A new task from what was typed: `10:00 Review` joins the schedule in time order, anything
    /// else follows the last task. Nothing else in the note moves. `section` keeps it among the
    /// tasks of one part of the note (a block of a page, `Board`).
    public static func addition(_ entry: String, to text: String, within section: NSRange? = nil) -> TextPatch {
        let ns = text as NSString
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let entry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "- [ ] " + entry
        let existing = items(in: ns).filter { item in section.map { NSLocationInRange(item.line.location, $0) } ?? true }
        let start = items(in: line as NSString).first?.start
        func before(_ item: Item) -> TextPatch { TextPatch(range: NSRange(location: item.line.location, length: 0), replacement: line + newline) }
        func after(_ item: Item) -> TextPatch { TextPatch(range: NSRange(location: NSMaxRange(item.line), length: 0), replacement: newline + line) }
        if let start {
            if let later = existing.first(where: { ($0.start ?? -1) > start }) { return before(later) }
            if let last = existing.last(where: { $0.start != nil }) { return after(last) }
            if let first = existing.first { return before(first) }
        } else if let last = existing.last {
            return after(last)
        }
        // The first task: after a blank line at the end of the note, or of the section's text.
        if let section {
            var end = NSMaxRange(section)
            while end > section.location, [0x0A, 0x0D].contains(ns.character(at: end - 1)) { end -= 1 }
            return TextPatch(range: NSRange(location: end, length: 0), replacement: newline + newline + line)
        }
        let lead = ns.length == 0 ? "" : text.hasSuffix(newline + newline) ? "" : text.hasSuffix(newline) ? newline : newline + newline
        return TextPatch(range: NSRange(location: ns.length, length: 0), replacement: lead + line + newline)
    }

    /// A new goal: a heading at the end of the goals note, after a blank line.
    public static func goalAddition(_ title: String, to text: String) -> TextPatch {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lead = text.isEmpty ? "" : text.hasSuffix(newline + newline) ? "" : text.hasSuffix(newline) ? newline : newline + newline
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return TextPatch(range: NSRange(location: (text as NSString).length, length: 0), replacement: lead + "## " + title + newline)
    }

    // MARK: Files

    /// `~/Library/Application Support/Zephyr/Space`: the app's own notes, beside its settings.
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zephyr/Space", isDirectory: true)
    }

    public static func dailyURL(_ date: Date = Date()) -> URL {
        folder.appendingPathComponent("Today", isDirectory: true).appendingPathComponent(dailyName(for: date))
    }

    public static var goalsURL: URL { folder.appendingPathComponent("Goals.md") }

    /// App-owned activity aggregates live beside, rather than inside, the user-editable Space
    /// notes. It never creates a file in a reading scope.
    public static var activityURL: URL { folder.deletingLastPathComponent().appendingPathComponent("Activity.json") }

    /// `2026-10-03.md`: one note a day in `Today/`, named by the local date.
    public static func dailyName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.md", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The date a daily note's name stands for.
    public static func date(ofDaily name: String, calendar: Calendar = .current) -> Date? {
        let parts = (name as NSString).deletingPathExtension.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Done and all tasks per day, for the days given (newest last), from the daily notes' texts.
    public static func history(days: [Date], notes: [String: String], calendar: Calendar = .current) -> [(date: Date, done: Int, total: Int)] {
        days.map { day in
            let found = notes[dailyName(for: day, calendar: calendar)].map { items(in: $0 as NSString) } ?? []
            return (day, found.filter(\.done).count, found.count)
        }
    }

    /// Days in a row, ending today (or yesterday, when today has nothing done yet), with at least
    /// one task done.
    public static func streak(_ history: [(date: Date, done: Int, total: Int)]) -> Int {
        var days = history.reversed().map(\.done)
        if days.first == 0 { days.removeFirst() }
        return days.prefix { $0 > 0 }.count
    }
}
