import AppKit
import Foundation
import Testing
@testable import ZephyrRender
import ZephyrCore

/// The block canvas (design §4): Zephyr's own layout over Core Text for text TextKit 1 cannot lay
/// out in budget. Edits must be exact and undoable, and the text on screen must stay put while
/// estimated heights turn into measured ones.
@MainActor
@Suite struct BlockCanvasSourceTests {
    /// A window hosting a canvas over `text` (forced onto the block canvas), drawn once.
    func open(_ text: String, size: NSSize = NSSize(width: 900, height: 700)) -> (MarkdownEditor, BlockCanvas, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: true, canvas: .source)
        let canvas = editor.blockCanvas
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: 0), size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        window.displayIfNeeded()
        window.makeFirstResponder(canvas.view)
        return (editor, canvas, window)
    }

    /// One long paragraph of mixed Chinese and English, plus a few short lines.
    static let long = "# 标题\n\n" + String(repeating: "Zephyr 打开已有的 Markdown 文件，按需渲染，只写回你改动的字节。 ", count: 3000) + "\n\n最后一行\n"

    @Test func routing() {
        #expect(BlockCanvas.prefers(Self.long as NSString))
        #expect(!BlockCanvas.prefers(String(repeating: "short line\n", count: 5000) as NSString))
        let mixed = String(repeating: "normal line of text\n", count: 4000) + String(repeating: "x", count: 30_000) + "\n"
        #expect(!BlockCanvas.prefers(mixed as NSString), "one long line in a normal document keeps the rendered canvas")
        #expect(MarkdownEditor(text: Self.long, typography: Typography(), baseURL: nil).blockCanvas.mode == .source)
        #expect(MarkdownEditor(text: "# Short\n", typography: Typography(), baseURL: nil).blockCanvas.mode == .rendered)
    }

    @Test func theTextFillsTheVisibleWidth() {
        let (_, canvas, window) = open(Self.long)
        #expect(canvas.view.frame.width == canvas.scrollView.contentView.bounds.width, "the view starts narrower than the window")
        window.setContentSize(NSSize(width: 640, height: 700))
        #expect(canvas.view.frame.width == canvas.scrollView.contentView.bounds.width)
    }

    @Test func typingIsOneUndoStepAndExact() {
        let (editor, canvas, window) = open(Self.long)
        let original = editor.string
        let at = (original as NSString).length / 2
        editor.select(NSRange(location: at, length: 0))
        for c in "你好 abc" { editor.type(String(c)) }
        #expect((editor.string as NSString).substring(with: NSRange(location: at, length: 6)) == "你好 abc")
        #expect(canvas.selection == NSRange(location: at + 6, length: 0))
        canvas.view.deleteBackward(nil)
        #expect((editor.string as NSString).substring(with: NSRange(location: at, length: 5)) == "你好 ab")
        window.undoManager?.undo()
        #expect(editor.string == original, "typing and its backspace undo as one step")
        window.undoManager?.redo()
        #expect((editor.string as NSString).substring(with: NSRange(location: at, length: 5)) == "你好 ab")
    }

    @Test func sourceSyntaxKeepsTheTextAndIdentityMapExact() {
        let attributes: [NSAttributedString.Key: Any] = [.font: Typography().bodyFont, .foregroundColor: Palette.text]
        let sourceLine = "- [x] **bold** [link](https://example.com) `code` $x$ <tag> | cell |"
        let styled = SourceSyntax.highlight(sourceLine, attributes: attributes)
        #expect(styled.string == sourceLine)
        #expect((styled.attribute(.foregroundColor, at: (styled.string as NSString).range(of: "link").location, effectiveRange: nil) as? NSColor)?.isEqual(Palette.link) == true)
        let line = styled.string as NSString
        #expect((styled.attribute(.foregroundColor, at: line.range(of: "x").location, effectiveRange: nil) as? NSColor)?.isEqual(Palette.accent) == true)
        #expect((styled.attribute(.foregroundColor, at: line.range(of: "**").location, effectiveRange: nil) as? NSColor)?.isEqual(Palette.faint) == true)
        #expect((styled.attribute(.foregroundColor, at: line.range(of: "code").location, effectiveRange: nil) as? NSColor)?.isEqual(Palette.muted) == true)
        #expect((styled.attribute(.foregroundColor, at: line.range(of: "$x$").location, effectiveRange: nil) as? NSColor)?.isEqual(Palette.faint) == true)
        #expect((styled.attribute(.foregroundColor, at: line.range(of: "<tag>").location, effectiveRange: nil) as? NSColor)?.isEqual(Palette.muted) == true)
        #expect((styled.attribute(.foregroundColor, at: line.range(of: "|").location, effectiveRange: nil) as? NSColor)?.isEqual(Palette.faint) == true)

        let source = "# One\n## Two\n- [x] **bold** [link](https://example.com) `code` $x$ <tag> | cell |\n```swift\n"
        let (editor, canvas, window) = open(source + Self.long)
        let content = canvas.layout(0).content
        #expect(content.string.string == "# One")
        #expect(content.map.sourceLength == content.map.displayLength)
        editor.select(NSRange(location: 2, length: 0))
        editor.type("!")
        window.undoManager?.undo()
        #expect(editor.string == source + Self.long)
        editor.setPlainText(false)
        editor.setPlainText(true)
        #expect(editor.string == source + Self.long)
    }

    @Test func sourceSyntaxHeadingsAreDistinctAndReadableInBothAppearances() {
        let attributes: [NSAttributedString.Key: Any] = [.font: Typography().bodyFont, .foregroundColor: Palette.text]
        let headings = (1...6).map { SourceSyntax.highlight(String(repeating: "#", count: $0) + " heading", attributes: attributes) }
        for (dark, appearance) in [(false, NSAppearance(named: .aqua)!), (true, NSAppearance(named: .darkAqua)!)] {
            let colors = headings.map { heading -> NSColor in
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = (heading.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor).usingColorSpace(.sRGB)
                }
                return resolved!
            }
            let body = Palette.resolved(.text, dark: dark).usingColorSpace(.sRGB)!
            let background = Palette.resolved(.background, dark: dark).usingColorSpace(.sRGB)!
            for color in colors {
                #expect(!color.isEqual(body))
                #expect(contrast(color, background) >= 4.5)
            }
            for i in 1..<colors.count { #expect(!colors[i - 1].isEqual(colors[i])) }
        }

        let quote = SourceSyntax.highlight("> ## Two", attributes: attributes)
        #expect(quote.string == "> ## Two")
        let quoteMarker = quote.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        let headingMarker = quote.attribute(.foregroundColor, at: 2, effectiveRange: nil) as! NSColor
        for (dark, appearance) in [(false, NSAppearance(named: .aqua)!), (true, NSAppearance(named: .darkAqua)!)] {
            for marker in [quoteMarker, headingMarker] {
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance { resolved = marker.usingColorSpace(.sRGB) }
                #expect(!resolved!.isEqual(Palette.resolved(.text, dark: dark).usingColorSpace(.sRGB)!))
                #expect(contrast(resolved!, Palette.resolved(.background, dark: dark).usingColorSpace(.sRGB)!) >= 4.5)
            }
        }
    }

    @Test func sourceSyntaxLeavesLongLinesPlain() {
        let attributes: [NSAttributedString.Key: Any] = [.font: Typography().bodyFont, .foregroundColor: Palette.text]
        let source = String(repeating: "*x", count: SourceSyntax.maximumStyledLength / 2 + 1)
        let styled = SourceSyntax.highlight(source, attributes: attributes)
        #expect(styled.string == source)
        #expect((styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.isEqual(Palette.text) == true)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func returnFollowsTheFileAndCRLFStaysWhole() {
        let (editor, canvas, _) = open("a\r\nb\r\n" + Self.long.replacingOccurrences(of: "\n", with: "\r\n"))
        editor.newline = "\r\n"
        editor.select(NSRange(location: 1, length: 0))
        editor.pressReturn()
        #expect(editor.string.hasPrefix("a\r\n\r\nb"), "\(Array(editor.string.utf16.prefix(6)))")
        // Backspace after a CRLF removes both characters.
        editor.select(NSRange(location: 3, length: 0))
        canvas.view.deleteBackward(nil)
        #expect(editor.string.hasPrefix("a\r\nb"), "\(Array(editor.string.utf16.prefix(6)))")
    }

    @Test func externalEditsMoveTheSelection() {
        let (editor, canvas, _) = open(Self.long)
        editor.select(NSRange(location: 500, length: 10))
        editor.applyExternal(TextPatch(range: NSRange(location: 10, length: 0), replacement: "插入"))
        #expect(canvas.selection == NSRange(location: 502, length: 10))
        editor.applyExternal(TextPatch(range: NSRange(location: 2000, length: 5), replacement: ""))
        #expect(canvas.selection == NSRange(location: 502, length: 10))
    }

    @Test func caretAndHitTestingAgree() {
        let (_, canvas, window) = open(Self.long)
        canvas.scroll(toCharacter: 40_000)
        window.displayIfNeeded()
        for i in stride(from: 40_000, to: 41_000, by: 37) {
            let rect = canvas.caretRect(at: i)
            let back = canvas.characterIndex(at: NSPoint(x: rect.midX, y: rect.midY))
            // A position at a wrap point may come back as the same place on the next line.
            #expect(abs(back - i) <= 1, "position \(i) came back as \(back)")
        }
    }

    @Test func theTopLineStaysWhileHeightsResolve() {
        let (editor, canvas, window) = open(Self.long + Self.long + Self.long)
        let target = (editor.string as NSString).length * 2 / 3
        canvas.scroll(toCharacter: target)
        window.displayIfNeeded()
        let first = canvas.firstVisibleCharacter()
        // Scrolling up a little lays out units above, replacing their estimates.
        let clip = canvas.scrollView.contentView
        for _ in 0..<20 {
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - 40))
            canvas.scrollView.reflectScrolledClipView(clip)
            window.displayIfNeeded()
        }
        for _ in 0..<20 {
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 40))
            canvas.scrollView.reflectScrolledClipView(clip)
            window.displayIfNeeded()
        }
        #expect(abs(canvas.firstVisibleCharacter() - first) < 80, "back where it was, within a line")
        #expect(abs(first - target) < 80)
    }

    @Test func compositionCommitsAsOneStepAndCancelRestores() {
        let (editor, canvas, window) = open(Self.long)
        let original = editor.string
        editor.select(NSRange(location: 100, length: 3))
        let replaced = (original as NSString).substring(with: NSRange(location: 100, length: 3))
        canvas.view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(canvas.view.hasMarkedText())
        canvas.view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!canvas.view.hasMarkedText())
        #expect((editor.string as NSString).substring(with: NSRange(location: 100, length: 1)) == "你")
        window.undoManager?.undo()
        #expect(editor.string == original)

        editor.select(NSRange(location: 100, length: 3))
        canvas.view.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == original, "a cancelled composition puts back what it replaced")
        #expect(canvas.selection == NSRange(location: 100, length: (replaced as NSString).length))
    }

    /// An outside change before a composition moves it: the commit lands where the reader typed.
    @Test func compositionFollowsAnOutsideChangeBeforeIt() {
        let (editor, canvas, window) = open(Self.long)
        editor.select(NSRange(location: 100, length: 0))
        canvas.view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.replaceExternally(NSRange(location: 10, length: 0), with: "ABCDE")
        let merged = editor.string
        canvas.view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        let ns = editor.string as NSString
        #expect(ns.substring(with: NSRange(location: 10, length: 5)) == "ABCDE")
        #expect(ns.substring(with: NSRange(location: 105, length: 1)) == "你")
        #expect(ns.length == (merged as NSString).length - 1, "the composition's two letters became one character")
        window.undoManager?.undo()
        #expect(editor.string == (merged as NSString).replacingCharacters(in: NSRange(location: 105, length: 2), with: ""))
    }

    @Test func outlineAndWords() {
        let (editor, canvas, _) = open("# One\n\n```\n# not a heading\n```\n\n## Two ##\n" + Self.long)
        #expect(editor.headings().map(\.title) == ["One", "Two", "标题"])
        let ns = editor.string as NSString
        let at = ns.range(of: "heading").location + 2
        #expect(ns.substring(with: canvas.wordRange(at: at)) == "heading")
        #expect(canvas.nextWord(from: at, forward: true) == ns.range(of: "heading").location + 7)
    }
}
