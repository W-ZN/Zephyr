import Foundation
import Testing
@testable import ZephyrCore

/// The app-level panels read and patch plain Markdown (design §8.3).
@Suite struct SpaceTests {
    static let day = """
    # 10月3日

    - [ ] 09:30 站会
    - [x] 11:00–12:00 Review the PR
    - [ ] 回复邮件
    * [X] Tidy the outline
    - [ ] 25:00 not a time

    ```
    - [ ] 14:00 inside code
    ```
    """

    @Test func readsTasksAndTimes() {
        let items = Space.items(in: Self.day as NSString)
        #expect(items.map(\.text) == ["站会", "Review the PR", "回复邮件", "Tidy the outline", "25:00 not a time"])
        #expect(items.map(\.done) == [false, true, false, true, false])
        #expect(items.map(\.start) == [570, 660, nil, nil, nil])
        #expect(items[1].end == 720)
    }

    @Test func togglingChangesOneCharacter() {
        let text = Self.day
        let item = Space.items(in: text as NSString)[0]
        let patch = Space.toggle(item)
        #expect(patch.range.length == 1)
        let after = patch.applied(to: text)
        #expect(Space.items(in: after as NSString)[0].done)
        #expect(Space.toggle(Space.items(in: after as NSString)[0]).applied(to: after) == text)
    }

    @Test func addingKeepsTheScheduleInOrder() {
        var text = Self.day
        text = Space.addition("10:15 设计评审", to: text).applied(to: text)
        text = Space.addition("Buy milk", to: text).applied(to: text)
        let items = Space.items(in: text as NSString)
        #expect(items.compactMap(\.start) == [570, 615, 660])
        #expect(items.last?.text == "Buy milk")
        #expect(text.hasPrefix("# 10月3日\n\n- [ ] 09:30 站会\n- [ ] 10:15 设计评审\n"))
    }

    @Test func firstTaskAfterABlankLineAndLineBreaksKept() {
        #expect(Space.addition("08:00 Run", to: "# Today\n").applied(to: "# Today\n") == "# Today\n\n- [ ] 08:00 Run\n")
        let crlf = "# Today\r\n\r\n- [ ] One\r\n"
        #expect(Space.addition("Two", to: crlf).applied(to: crlf) == "# Today\r\n\r\n- [ ] One\r\n- [ ] Two\r\n")
    }

    @Test func goalsWithProgressAndDates() {
        let text = """
        # 目标

        ## Ship Zephyr 1.0
        due: 2026-12-31

        - [x] Block canvas
        - [x] Outline
        - [ ] Quick Look

        ## 读完 12 本书
        截止：2026-12-01
        - [x] 第一本
        - [ ] 第二本
        """
        let goals = Space.goals(in: text as NSString)
        #expect(goals.map(\.title) == ["Ship Zephyr 1.0", "读完 12 本书"])
        #expect(goals.map(\.done) == [2, 1])
        #expect(goals.map(\.total) == [3, 2])
        #expect(goals.map(\.due) == ["2026-12-31", "2026-12-01"])
    }

    @Test func fencesFollowTheCanvasRules() {
        // Indented and quoted fences, and a long fence that a shorter run does not close.
        let text = "  ```\n- [ ] in code\n  ```\n> ~~~\n> - [ ] quoted code\n> ~~~\n````\n```\n- [ ] still code\n````\n- [ ] real\n"
        #expect(Space.items(in: text as NSString).map(\.text) == ["real"])
    }

    @Test func itemsAreFoundAgainAfterTheNoteChanged() throws {
        let old = "# P\n\n## T\n- [ ] a\n- [ ] b\n"
        let b = try #require(Space.items(in: old as NSString).last)
        // Someone removed the title: the same length, so the old offsets would hit the wrong place.
        let new = "## T\n- [ ] a\n- [ ] b\n" + "\n\n\n\n\n"
        let found = try #require(Space.locate(b, in: new as NSString))
        #expect(Space.toggle(found).applied(to: new).hasPrefix("## T\n- [ ] a\n- [x] b\n"))
        // Gone, or already checked elsewhere: nothing to change.
        #expect(Space.locate(b, in: "## T\n- [ ] a\n" as NSString) == nil)
        #expect(Space.locate(b, in: "## T\n- [ ] a\n- [x] b\n" as NSString) == nil)
    }

    @Test func dailyNames() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3))!
        #expect(Space.dailyName(for: date, calendar: calendar) == "2026-10-03.md")
        #expect(Space.date(ofDaily: "2026-10-03.md", calendar: calendar) == date)
    }

    @Test func activityDeduplicatesVisitsAndKeepsTheFirstScopeScanAsBaseline() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let activity = try ActivityStore(url: file, calendar: calendar)
        try activity.recordOpen("/work/a.md", on: date)
        try activity.recordOpen("/work/a.md", on: date)
        try activity.recordModified("/work/a.md", on: date)
        try activity.recordModified("/work/a.md", on: date)
        #expect(activity.history(days: 1, ending: date)[0].opened.count == 1)
        #expect(activity.history(days: 1, ending: date)[0].modified.count == 1)

        let root = URL(fileURLWithPath: "/work")
        #expect(try activity.observe(scopeRoot: root, files: ["/work/a.md": .init(modified: 1, size: 10)], on: date) == nil)
        let observed = try activity.observe(scopeRoot: root, files: ["/work/a.md": .init(modified: 2, size: 10), "/work/b.md": .init(modified: 1, size: 4)], on: date)
        let diff = try #require(observed)
        #expect(diff == .init(added: 1, removed: 0, modified: 1))
        let day = activity.history(days: 1, ending: date)[0]
        #expect(day.added.count == 1)
        #expect(day.modified.count == 1)

        let secondRoot = URL(fileURLWithPath: "/other")
        #expect(try activity.observe(scopeRoot: secondRoot, files: ["/other/a.md": .init(modified: 1, size: 10)], on: date) == nil)
        _ = try activity.observe(scopeRoot: secondRoot, files: ["/other/a.md": .init(modified: 2, size: 10)], on: date)
        #expect(activity.history(days: 1, ending: date)[0].modified.count == 2, "different folders' same file name stays distinct")
    }

    @Test func activityRetainsAtMostAYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let activity = try ActivityStore(url: file, calendar: calendar)
        for offset in 0...ActivityStore.maximumDays {
            try activity.recordOpen("/work/\(offset).md", on: calendar.date(byAdding: .day, value: -offset, to: end)!)
        }
        #expect(activity.days.count == ActivityStore.maximumDays)
    }

    @Test func activityBoundsOneVeryBusyDay() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let activity = try ActivityStore(url: file)
        for i in 0...ActivityStore.maximumIdentifiersPerDay {
            try activity.recordOpen("/work/\(i).md")
        }
        let day = try #require(activity.days.last)
        #expect(day.opened.count == ActivityStore.maximumIdentifiersPerDay)
        #expect(day.saturated)
        #expect(try Data(contentsOf: file).count <= ActivityStore.maximumBytes)
    }

    @Test func activityIgnoresAnOutOfOrderScopeScan() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let activity = try ActivityStore(url: file)
        let root = URL(fileURLWithPath: "/work")
        #expect(try activity.observe(scopeRoot: root, files: ["/work/a.md": .init(modified: 2, size: 2), "/work/b.md": .init(modified: 2, size: 2)], sequence: 2) == nil)
        #expect(try activity.observe(scopeRoot: root, files: ["/work/a.md": .init(modified: 1, size: 1)], sequence: 1) == nil)
        #expect(try activity.observe(scopeRoot: root, files: ["/work/a.md": .init(modified: 2, size: 2), "/work/b.md": .init(modified: 2, size: 2)], sequence: 3) == .init(added: 0, removed: 0, modified: 0))
    }

    @Test func activityDeduplicatesSymlinkAliases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = directory.appendingPathComponent("note.md")
        let alias = directory.appendingPathComponent("alias.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("note".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = try ActivityStore(url: directory.appendingPathComponent("Activity.json"))
        try activity.recordOpen(target.path)
        try activity.recordOpen(alias.path)
        #expect(try #require(activity.days.last).opened.count == 1)
    }
}
