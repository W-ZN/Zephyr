import AppKit
import Foundation
import Testing
@testable import ZephyrRender

/// Typing shortcuts: paired `$` and `*`, closing HTML tags, `$$` and ``` blocks on Return, and
/// the image suggestion after `!`.
@MainActor
@Suite struct QuickInputTests {
    func editor(_ text: String) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        editor.select(NSRange(location: (text as NSString).length, length: 0))
        editor.layoutAll()
        return (editor, window)
    }

    func caret(_ e: MarkdownEditor) -> Int { e.selectedRange.location }

    @Test func dollarsPairNestAndStepOver() {
        let (e, _) = editor("Sum ")
        e.type("$")
        #expect(e.string == "Sum $$" && caret(e) == 5)
        e.type("x")
        e.type("$")
        #expect(e.string == "Sum $x$" && caret(e) == 7, "the closing $ is stepped over")
        let (block, _) = editor("")
        block.type("$")
        block.type("$")
        #expect(block.string == "$$$$" && caret(block) == 2, "a second $ in an empty pair nests")
        block.type("$")
        #expect(block.string == "$$$$$" || block.string == "$$$$", "no third pair of dollars")
        let (price, _) = editor("costs 5")
        price.type("$")
        #expect(price.string == "costs 5$", "after a digit a $ stays single")
    }

    @Test func starsPairUpToThreeAndKeepBullets() {
        let (e, _) = editor("a ")
        e.type("*")
        e.type("*")
        #expect(e.string == "a ****" && caret(e) == 4)
        e.type("*")
        #expect(e.string == "a ******" && caret(e) == 5)
        e.type("*")
        #expect(e.string.count <= 9, "three stars at most")
        let (bold, _) = editor("a ")
        bold.type("*")
        bold.type("*")
        bold.type("b")
        bold.type("*")
        bold.type("*")
        #expect(bold.string == "a **b**" && caret(bold) == 7, "the closing stars are stepped over")
        let (bullet, _) = editor("")
        bullet.type("*")
        #expect(bullet.string == "**" && caret(bullet) == 1, "one star at the start of a line pairs too")
        bullet.type(" ")
        #expect(bullet.string == "* " && caret(bullet) == 2, "a space inside that pair makes it a bullet")
        let (quoted, _) = editor("> ")
        quoted.type("*")
        quoted.type(" ")
        #expect(quoted.string == "> * ")
        let (start, _) = editor("")
        start.type("*")
        start.type("*")
        #expect(start.string == "****" && caret(start) == 2, "two stars at the start of a line open bold")
        start.type("*")
        #expect(start.string == "******" && caret(start) == 3, "three stars at most")
        let (plain, _) = editor("")
        plain.type(" ")
        #expect(plain.string == " ", "a space elsewhere is plain")
    }

    @Test func starsPairBesideChineseText() {
        let (e, _) = editor("这是")
        e.type("*")
        #expect(e.string == "这是**" && caret(e) == 3, "no space is needed before CJK text")
        e.type("*")
        #expect(e.string == "这是****" && caret(e) == 4)
        let (mid, _) = editor("前文后文")
        mid.select(NSRange(location: 2, length: 0))
        mid.type("*")
        #expect(mid.string == "前文**后文" && caret(mid) == 3, "a pair opens between CJK characters")
        let (word, _) = editor("2")
        word.type("*")
        #expect(word.string == "2*", "after a Latin digit a star stays single")
    }

    @Test func backspaceTakesAnEmptyPair() {
        let (e, window) = editor("a ")
        e.type("*")
        e.type("*")
        e.blockCanvas.view.deleteBackward(nil)
        #expect(e.string == "a **" && caret(e) == 3)
        e.blockCanvas.view.deleteBackward(nil)
        #expect(e.string == "a ")
        _ = window
    }

    @Test func selectionIsWrapped() {
        let (e, _) = editor("word")
        e.select(NSRange(location: 0, length: 4))
        e.type("*")
        #expect(e.string == "*word*")
    }

    @Test func openingTagsClose() {
        let (e, _) = editor("x ")
        for c in "<sup>" { e.type(String(c)) }
        #expect(e.string == "x <sup></sup>" && caret(e) == 7)
        let (br, _) = editor("x ")
        for c in "<br>" { br.type(String(c)) }
        #expect(br.string == "x <br>")
        let (link, _) = editor("")
        for c in "<https://example.com>" { link.type(String(c)) }
        #expect(link.string == "<https://example.com>", "an autolink is no tag")
    }

    @Test func returnMakesFormulaAndCodeBlocks() {
        let (e, _) = editor("$$")
        e.blockCanvas.view.insertNewline(nil)
        #expect(e.string == "$$\n\n$$" && caret(e) == 3)
        let (paired, _) = editor("")
        paired.type("$")
        paired.type("$")
        paired.blockCanvas.view.insertNewline(nil)
        #expect(paired.string == "$$\n\n$$" && caret(paired) == 3)
        let (code, _) = editor("> ```py")
        code.closeLanguageMenu()
        code.blockCanvas.view.insertNewline(nil)
        #expect(code.string == "> ```py\n> \n> ```" && caret(code) == 10)
        let (closed, _) = editor("$$\nx\n$$")
        closed.blockCanvas.view.insertNewline(nil)
        #expect(closed.string.components(separatedBy: "$$").count == 3 && closed.string.hasPrefix("$$\nx\n$$\n"), "a closing $$ opens no block: \(closed.string.debugDescription)")
    }

    @Test func bangOffersAnImageWithoutTakingReturn() {
        let (e, window) = editor("")
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        e.type("!")
        let menu = try! #require(e.imageMenu)
        #expect(menu.selected == -1)
        e.blockCanvas.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e.string == "!\n" && e.imageMenu == nil, "Return breaks the line when nothing is chosen")
        let (chosen, other) = editor("")
        other.orderBack(nil)
        defer { other.orderOut(nil) }
        chosen.type("!")
        chosen.blockCanvas.view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        chosen.blockCanvas.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(chosen.string == "![]()" && caret(chosen) == 2)
    }
}
