import AppKit
import Foundation
import Testing
@testable import ZephyrRender

/// The document's Find and Replace bar (design §8): matches, navigation, replacing as one undo step.
@MainActor
@Suite struct FindTests {
    func editor(_ text: String, editable: Bool = true) -> (MarkdownEditor, NSWindow) {
        let editor = MarkdownEditor(text: text, typography: Typography(), baseURL: nil, isEditable: editable, canvas: .block)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.scrollView
        editor.select(NSRange(location: 0, length: 0))
        editor.layoutAll()
        editor.find.use(defaults: UserDefaults(suiteName: "zephyr-find-\(UUID().uuidString)")!, pasteboard: NSPasteboard.withUniqueName())
        return (editor, window)
    }

    func substrings(_ e: MarkdownEditor) -> [String] { e.find.matches.map { (e.string as NSString).substring(with: $0) } }

    @Test func typingFindsAndSelectsTheFirstMatchFromTheCaret() {
        let (e, _) = editor("one two\nTwo three two\n")
        e.find.show()
        #expect(e.find.isOpen)
        e.find.queryChanged("two")
        #expect(substrings(e) == ["two", "Two", "two"] && e.find.current == 0)
        #expect(e.selectedRange == NSRange(location: 4, length: 3))
        e.find.queryChanged("two t")
        #expect(substrings(e) == ["Two t"], "the search follows the field")
        e.find.queryChanged("")
        #expect(e.find.matches.isEmpty)
    }

    @Test func showSeedsFromTheSelection() {
        let (e, _) = editor("alpha beta alpha")
        e.select(NSRange(location: 6, length: 4))
        e.find.show()
        #expect(e.find.search.query == "beta")
        e.find.close()
        #expect(!e.find.isOpen)
    }

    @Test func nextAndPreviousWrapAround() {
        let (e, _) = editor("a x a x a")
        e.find.show()
        e.find.queryChanged("a")
        #expect(e.selectedRange.location == 0)
        e.find.next()
        #expect(e.selectedRange.location == 4)
        e.find.next()
        #expect(e.selectedRange.location == 8)
        e.find.next()
        #expect(e.selectedRange.location == 0, "after the last match comes the first")
        e.find.previous()
        #expect(e.selectedRange.location == 8, "and before the first, the last")
    }

    @Test func replaceOneMovesOnAndAllIsOneUndoStep() throws {
        let (e, window) = editor("cat dog cat bird cat\n")
        e.find.show(replace: true)
        e.find.queryChanged("cat")
        let bar = try #require(window.contentView?.subviews.compactMap { $0 as? FindBar }.first)
        bar.replaceBox.field.stringValue = "fox"
        #expect(e.selectedRange == NSRange(location: 0, length: 3), "typing selects the first match")
        e.find.replaceCurrent()
        #expect(e.string == "fox dog cat bird cat\n")
        #expect(e.selectedRange == NSRange(location: 8, length: 3), "the next match is selected")
    }

    @Test func replaceAllIsOneUndoStep() throws {
        let (e, window) = editor("cat dog cat bird cat\n")
        e.find.show(replace: true)
        e.find.queryChanged("cat")
        let bar = try #require(window.contentView?.subviews.compactMap { $0 as? FindBar }.first)
        bar.replaceBox.field.stringValue = "fox"
        e.find.replaceAll()
        #expect(e.string == "fox dog fox bird fox\n")
        e.focusView.undoManager?.undo()
        #expect(e.string == "cat dog cat bird cat\n", "all three come back with one undo")
        e.focusView.undoManager?.redo()
        #expect(e.string == "fox dog fox bird fox\n")
    }

    @Test func regularExpressionsReplaceWithGroups() throws {
        let (e, window) = editor("Smith, John\nDoe, Jane\n")
        e.find.show(replace: true)
        let bar = try #require(window.contentView?.subviews.compactMap { $0 as? FindBar }.first)
        bar.regex.isOn = true
        bar.regex.sendAction(bar.regex.action, to: bar.regex.target)
        e.find.queryChanged(#"(\w+), (\w+)"#)
        bar.replaceBox.field.stringValue = "$2 $1"
        e.find.replaceAll()
        #expect(e.string == "John Smith\nJane Doe\n")
    }

    @Test func returnAndEscapeInTheFieldsNavigateAndClose() throws {
        let (e, window) = editor("a x a x a")
        e.find.show(replace: true)
        e.find.queryChanged("a")
        let bar = try #require(window.contentView?.subviews.compactMap { $0 as? FindBar }.first)
        let editorView = NSTextView()
        #expect(e.find.control(bar.findBox.field, textView: editorView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(e.selectedRange.location == 4, "Return in the find field goes to the next match")
        bar.replaceBox.field.stringValue = "b"
        #expect(e.find.control(bar.replaceBox.field, textView: editorView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(e.string == "a x b x a", "Return in the replace field replaces the selected match")
        #expect(!e.find.control(bar.findBox.field, textView: editorView, doCommandBy: #selector(NSResponder.moveLeft(_:))), "other keys are the field's own")
        #expect(e.find.control(bar.findBox.field, textView: editorView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!e.find.isOpen && bar.superview == nil)
    }

    @Test func aReadOnlyDocumentCannotBeReplaced() {
        let (e, _) = editor("cat cat", editable: false)
        e.find.show(replace: true)
        e.find.queryChanged("cat")
        e.find.replaceAll()
        #expect(e.string == "cat cat")
        #expect(e.find.matches.count == 2, "it can still be searched")
    }

    @Test func matchesFollowEditsAndTheBarLeavesNothingBehind() async {
        let (e, _) = editor("x y x")
        e.find.show()
        e.find.queryChanged("x")
        e.type("x")
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(e.find.matches.count >= 2)
        e.find.close()
        #expect(e.find.matches.isEmpty && e.blockCanvas.findMatches.isEmpty)
    }
}
