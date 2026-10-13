import AppKit
import Foundation
import Testing
@testable import ZephyrRender

/// Block components (display math, tables, rules) must reserve their drawn height in the text
/// layout, so the next block starts below them instead of underneath (design §16 D2–3).
@MainActor
@Suite struct BlockLayoutTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../fixtures/sample.md").standardizedFileURL

    /// Vertical extent of a source line: from the top of its first fragment to the bottom of its last.
    func span(of needle: String, in editor: MarkdownEditor) -> ClosedRange<CGFloat> {
        let range = (editor.string as NSString).range(of: needle)
        #expect(range.location != NSNotFound, "missing \(needle)")
        let top = editor.lineRect(at: range.location)
        let bottom = editor.lineRect(at: NSMaxRange(range) - 1)
        return top.minY...bottom.maxY
    }

    func layout(_ text: String) -> MarkdownEditor {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: false, canvas: .block)
        editor.layoutAll()
        return editor
    }

    @Test func blocksDoNotOverlapFollowingText() throws {
        let editor = layout(try String(contentsOf: Self.fixture, encoding: .utf8))
        let math = span(of: "$$\n\\int", in: editor)
        let afterMath = span(of: "## 列表与任务", in: editor)
        #expect(math.upperBound - math.lowerBound > 40, "display math reserves its height")
        #expect(afterMath.lowerBound >= math.upperBound)

        let table = span(of: "| 场景 | 目标 |", in: editor)
        let afterTable = span(of: "最后一段", in: editor)
        #expect(table.upperBound - table.lowerBound > 3 * 20, "three table rows reserve their height")
        #expect(afterTable.lowerBound >= table.upperBound)
    }

    /// Baseline of the line holding `needle`.
    func baseline(of needle: String, in editor: MarkdownEditor) -> CGFloat {
        let index = (editor.string as NSString).range(of: needle).location
        let canvas = editor.blockCanvas, p = canvas.place(index)
        return canvas.top(of: p.unit) + p.layout.baselines[p.line]
    }

    @Test func spacingIgnoresBlankLineCount() {
        let tight = layout("Para one\n## Head\nPara two\n- item\n- item two\n")
        let loose = layout("Para one\n\n\n\n## Head\n\nPara two\n\n- item\n\n\n- item two\n")
        for needle in ["Head", "Para two", "item two"] {
            #expect(baseline(of: needle, in: tight) == baseline(of: needle, in: loose), "\(needle)")
        }
    }

    @Test func headingGapFollowsTheSpec() {
        let editor = layout("Para one\n\n## Head\n")
        let typography = editor.typography
        let para = editor.lineRect(at: 0)
        let headStart = (editor.string as NSString).range(of: "## Head").location
        let head = editor.lineRect(at: headStart)
        #expect(head.minY - para.maxY == round(typography.fontSize * 2), "H2 sits 2 em below the paragraph")
    }

    /// Wide tables and the front matter chevron extend outside the reading column.
    @Test func blocksDrawOutsideTheColumn() {
        let text = "---\ntitle: X\n---\n\n| a | b |\n|---|---|\n| one | two |\n"
        let editor = MarkdownEditor(text: text, typography: CustomStyleTests.typography(["text.width": "30", "table.width": "window"]), baseURL: nil, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        editor.layoutAll()
        let view = editor.blockCanvas.view
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { Issue.record("no bitmap"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        func ink(_ xs: ClosedRange<CGFloat>, _ ys: ClosedRange<CGFloat>) -> Int {
            var n = 0
            for y in stride(from: ys.lowerBound, through: ys.upperBound, by: 1) {
                for x in stride(from: xs.lowerBound, through: xs.upperBound, by: 1) {
                    if let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale)), c.alphaComponent > 0, c.brightnessComponent < 0.85 { n += 1 }
                }
            }
            return n
        }
        let column = editor.blockCanvas.columnX
        #expect(ink(column - 30...column - 2, 30...70) > 0, "front matter chevron in the gutter")
        #expect(ink(40...column - 5, 60...200) > 0, "window-width table left of the column")
    }

    @Test func tableMenuChangesWidthForThisTableOnly() {
        let text = "| a | b |\n|---|---|\n| one | two |\n\n| c |\n|---|\n| three |\n"
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        editor.layoutAll()
        let view = editor.blockCanvas.view
        func render() {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
        }
        render()
        let boxes = [0, (editor.string as NSString).range(of: "| c |").location].compactMap {
            editor.componentBox(at: $0) as? TableBox
        }
        #expect(boxes.count == 2)
        let first = boxes[0], second = boxes[1]
        let narrow = first.drawnRect
        let column = editor.blockCanvas.columnWidth
        #expect(narrow.width < column / 2, "small tables fit their content by default")
        #expect(abs(narrow.midX - (editor.blockCanvas.columnX + editor.blockCanvas.columnWidth / 2)) < 6, "centered by default")

        let menu = editor.contextMenu(at: NSPoint(x: narrow.midX, y: narrow.midY), base: nil)
        let item = menu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == String(localized: "Column Width") }
        #expect(item != nil)
        _ = item.map { NSApp.sendAction($0.action!, to: $0.target, from: $0) }
        editor.layoutAll()
        render()
        #expect(abs(first.drawnRect.width - column) < 2, "this table uses the reading column")
        #expect(second.drawnRect.width < column / 2, "the other table keeps the fit-content default")
    }

    @Test func caretInsideFormulaRevealsItsSource() throws {
        let editor = MarkdownEditor(text: try String(contentsOf: Self.fixture, encoding: .utf8), typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let tex = (editor.string as NSString).range(of: "\\int")
        editor.select(NSRange(location: tex.location + 1, length: 0))
        editor.layoutAll()
        let line = span(of: "\\int", in: editor)
        #expect(line.upperBound - line.lowerBound > 10, "revealed source lines are laid out, not collapsed")
        #expect(editor.blockCanvas.place(tex.location).layout.content.string.string.contains("\\int"))
    }
}
