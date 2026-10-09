import AppKit
import PDFKit
import Testing
@testable import ZephyrRender

@MainActor
@Suite struct PresentationTests {
    @Test(arguments: ["\n", "\r\n"])
    func returnHasRoomBeforeAndAfterTyping(_ newline: String) {
        let editor = MarkdownEditor(text: "第一行 First line", typography: Typography(), baseURL: nil)
        editor.newline = newline
        editor.select(NSRange(location: editor.length, length: 0))
        let first = editor.lineRect(at: 0)
        editor.pressReturn()
        let fresh = editor.lineRect(at: editor.selectedRange.location)
        #expect(fresh.minY - first.maxY >= 8, "manual Return leaves at least half an em beyond the line box")
        let caret = editor.blockCanvas.caretRect(at: editor.selectedRange.location)
        editor.type("第二行 Second line")
        #expect(editor.blockCanvas.caretRect(at: editor.selectedRange.location).minY == caret.minY)
        #expect(editor.string == "第一行 First line" + newline + "第二行 Second line")
        editor.select(NSRange(location: 0, length: 0))
        #expect(editor.lineRect(at: editor.length).minY == fresh.minY, "moving the caret away retains the spacing")
    }

    /// Compare the actual pixels of the three choices, including the shaded header's last row.
    @Test func tableRulesMatchTheirNames() throws {
        let text = "| A | B |\n|---|---|\n| x | y |\n| z | w |\n"
        func render(_ rules: String) throws -> (NSBitmapImageRep, NSRect, NSRect) {
            let typography = CustomStyleTests.typography(["table.lines": rules, "table.headerShade": "true", "table.radius": "0", "table.stripes": "false"])
            let editor = MarkdownEditor(text: text, typography: typography, baseURL: nil, isEditable: false)
            let sheet = try #require(editor.printView as? PrintSheet)
            sheet.paginate(size: NSSize(width: 500, height: 700))
            let rep = try #require(sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds))
            sheet.cacheDisplay(in: sheet.bounds, to: rep)
            let table = try #require(sheet.editor.componentBox(at: 0) as? TableBox)
            let header = try #require(table.cellRect(row: 0, column: 0))
            return (rep, table.drawnRect.offsetBy(dx: 0, dy: -BlockCanvas.topInset), header.offsetBy(dx: 0, dy: -BlockCanvas.topInset))
        }
        let none = try render("none"), rows = try render("rows"), grid = try render("grid")
        func brightness(_ image: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let scale = CGFloat(image.pixelsWide) / 500
            return image.colorAt(x: Int(x * scale), y: Int(y * scale))!.usingColorSpace(.deviceRGB)!.brightnessComponent
        }
        let x = none.1.minX + 3, y = none.2.maxY - 0.5
        #expect(brightness(none.0, x, y) > brightness(rows.0, x, y) + 0.03, "None removes the header rule")
        let edge = none.1.minX + 0.25, middle = (none.2.maxY + none.1.maxY) / 2 + 4
        #expect(abs(brightness(none.0, edge, middle) - brightness(rows.0, edge, middle)) < 0.01, "row rules have no outside border")
        #expect(brightness(rows.0, edge, middle) > brightness(grid.0, edge, middle) + 0.03, "only Grid has the outer border")
    }

    @Test func printedPagesContainTheWholeDocument() throws {
        let text = "# Print proof\n\n" + (1...65).map { "Paragraph \($0): Native canvas, **bold**, mixed 中文 text.\n\n" }.joined() + "| Name | Value |\n|---|---|\n| Tail marker | 123 |\n"
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil)
        let sheet = try #require(editor.printView as? PrintSheet)
        sheet.paginate(size: NSSize(width: 420, height: 500))
        #expect(sheet.pages.count > 3)
        for pair in zip(sheet.pages, sheet.pages.dropFirst()) { #expect(pair.0.maxY == pair.1.minY) }
        #expect(sheet.pages.last?.maxY == sheet.bounds.maxY)
        for page in sheet.pages.dropLast() {
            let canvas = sheet.editor.blockCanvas
            for i in 0..<canvas.units.count {
                let layout = canvas.layout(i), top = CGFloat(canvas.heights.y(of: i))
                for k in layout.tops.indices where layout.content.component == nil && layout.heights[k] > 0 {
                    let lineTop = top + layout.tops[k]
                    #expect(page.maxY <= lineTop || page.maxY >= lineTop + layout.heights[k], "a page never bisects a text line")
                }
            }
        }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build.noindex/output/test-results")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("print-proof.pdf")
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 500, height: 600)
        info.leftMargin = 40
        info.rightMargin = 40
        info.topMargin = 50
        info.bottomMargin = 50
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = NSPrintOperation(view: sheet, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        #expect(operation.run())
        let pdf = try #require(PDFDocument(url: output))
        #expect(pdf.pageCount == sheet.pages.count)
        let printed = pdf.string ?? ""
        #expect(printed.contains("Print proof") && printed.contains("Paragraph 65") && printed.contains("Tail marker"))
        #expect(!printed.contains("**"), "PDF uses rendered text")
        #expect(editor.string == text, "printing never changes the document")
    }
}
