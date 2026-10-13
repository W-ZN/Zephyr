import AppKit
import ZephyrCore

/// Find and Replace for one document (⌘F, ⌥⌘F, ⌘G): Zephyr's own bar and highlights rather than the
/// system's, so the bar looks like the rest of the interface and matches show on the rendered
/// canvas. The search itself is `TextSearch`; this connects it to the text, the selection and undo.
@MainActor
public final class FindController: NSObject, NSTextFieldDelegate {
    private unowned let editor: MarkdownEditor
    private var bar: FindBar?
    public private(set) var search = TextSearch(query: "")
    public private(set) var matches: [NSRange] = []
    public private(set) var current: Int?
    private var invalid = false, truncated = false
    /// Where an incremental search starts from: the caret when the bar opened or the last match.
    private var anchor = 0
    private var refreshPending = false
    /// Where the last search string is shared with other apps, and where the switches are kept.
    var pasteboard = NSPasteboard(name: .find)
    var defaults = UserDefaults.standard

    private enum Defaults {
        static let matchCase = "findMatchCase", wholeWord = "findWholeWord", regex = "findRegex"
    }

    init(editor: MarkdownEditor) {
        self.editor = editor
        super.init()
        search.matchCase = defaults.bool(forKey: Defaults.matchCase)
        search.wholeWord = defaults.bool(forKey: Defaults.wholeWord)
        search.regex = defaults.bool(forKey: Defaults.regex)
    }

    /// Takes the switches saved so far (and later saves into `defaults`).
    func use(defaults: UserDefaults, pasteboard: NSPasteboard) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        search.matchCase = defaults.bool(forKey: Defaults.matchCase)
        search.wholeWord = defaults.bool(forKey: Defaults.wholeWord)
        search.regex = defaults.bool(forKey: Defaults.regex)
    }

    private var canvas: BlockCanvas { editor.blockCanvas }
    public var isOpen: Bool { bar?.superview != nil }
    public var replacement: String { bar?.replaceBox.field.stringValue ?? "" }

    // MARK: Showing

    /// ⌘F (or ⌥⌘F with `replace`): the bar, with the selection or the last search in the field.
    public func show(replace: Bool = false) {
        guard let scroll = canvas.scrollView as NSScrollView?, scroll.window != nil else { return }
        let selection = canvas.selection
        let bar = self.bar ?? makeBar()
        if bar.superview == nil {
            scroll.addSubview(bar)
            scroll.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(hostResized), name: NSView.frameDidChangeNotification, object: scroll)
            anchor = selection.location
        }
        if let seeded = selectedText() {
            search.query = seeded
            writePasteboard()
        } else if search.query.isEmpty, let last = pasteboard.string(forType: .string), !last.isEmpty {
            search.query = last
        }
        bar.findBox.field.stringValue = search.query
        bar.findBox.textDidChangeProgrammatically()
        bar.enableReplace(canvas.isEditable)
        if replace, canvas.isEditable { bar.isReplacing = true }
        sync(options: bar)
        layoutBar()
        refresh(from: anchor, selecting: false)
        bar.window?.makeFirstResponder(bar.findBox.field)
        bar.findBox.field.selectText(nil)
    }

    private func makeBar() -> FindBar {
        let bar = FindBar()
        self.bar = bar
        for box in [bar.findBox, bar.replaceBox] { box.field.delegate = self }
        bar.findBox.field.nextKeyView = bar.replaceBox.field
        bar.replaceBox.field.nextKeyView = bar.findBox.field
        for option in [bar.matchCase, bar.wholeWord, bar.regex] {
            option.target = self
            option.action = #selector(optionChanged(_:))
        }
        bar.next.target = self
        bar.next.action = #selector(nextPressed)
        bar.previous.target = self
        bar.previous.action = #selector(previousPressed)
        bar.close.target = self
        bar.close.action = #selector(closePressed)
        bar.disclosure.target = self
        bar.disclosure.action = #selector(disclosurePressed)
        bar.replaceOne.target = self
        bar.replaceOne.action = #selector(replacePressed)
        bar.replaceAll.target = self
        bar.replaceAll.action = #selector(replaceAllPressed)
        return bar
    }

    private func sync(options bar: FindBar) {
        bar.matchCase.isOn = search.matchCase
        bar.wholeWord.isOn = search.wholeWord
        bar.regex.isOn = search.regex
    }

    @objc private func hostResized() { layoutBar() }

    /// Top right of the reading area, clear of the outline rail and the scroller.
    func layoutBar() {
        guard let bar, let scroll = bar.superview else { return }
        let width = min(FindBar.width, max(260, scroll.bounds.width - 24))
        bar.setFrameSize(NSSize(width: width, height: bar.fittingSize.height))
        let x = max(10, scroll.bounds.maxX - canvas.trailingInset - 14 - width)
        let y = scroll.isFlipped ? 10 : scroll.bounds.maxY - bar.frame.height - 10
        bar.setFrameOrigin(NSPoint(x: x, y: y))
    }

    public func close() {
        guard let bar, bar.superview != nil else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: bar.superview)
        bar.removeFromSuperview()
        matches = []
        current = nil
        canvas.findMatches = []
        canvas.findCurrent = nil
        editor.focusView.window?.makeFirstResponder(editor.focusView)
    }

    private func selectedText() -> String? {
        let r = canvas.selection
        guard r.length > 0, r.length <= 200 else { return nil }
        let s = canvas.text.substring(with: r)
        return s.contains(where: \.isNewline) ? nil : s
    }

    // MARK: Searching

    /// ⌘E: the selection becomes the search string, without opening the bar.
    public func useSelection() {
        guard let text = selectedText() else { return }
        search.query = text
        writePasteboard()
        if isOpen {
            bar?.findBox.field.stringValue = text
            bar?.findBox.textDidChangeProgrammatically()
            refresh(from: canvas.selection.location, selecting: false)
        }
    }

    private func writePasteboard() {
        pasteboard.clearContents()
        pasteboard.setString(search.query, forType: .string)
    }

    /// Searches again and moves `current` to the first match at or after `location`.
    private func refresh(from location: Int, selecting: Bool) {
        let result = search.find(in: canvas.text)
        matches = result.matches
        invalid = result.invalidPattern
        truncated = result.truncated
        current = matches.firstIndex { $0.location >= location } ?? (matches.isEmpty ? nil : 0)
        // A match the caret sits inside counts as the current one while editing.
        if !selecting, let i = matches.firstIndex(where: { NSLocationInRange(location, $0) || $0 == canvas.selection }) { current = i }
        canvas.findMatches = matches
        canvas.findCurrent = current
        showCount()
        if selecting, let current { go(to: current) }
    }

    private func showCount() {
        guard let bar else { return }
        if invalid { return bar.showCount(String(localized: "Invalid pattern"), problem: true) }
        if search.query.isEmpty { return bar.showCount("") }
        if matches.isEmpty { return bar.showCount(String(localized: "No results")) }
        let total = truncated ? "\(matches.count)+" : "\(matches.count)"
        bar.showCount(current.map { String(localized: "\($0 + 1) of \(total)") } ?? String(localized: "\(total) results"))
    }

    private func go(to index: Int) {
        guard matches.indices.contains(index) else { return }
        current = index
        anchor = matches[index].location
        canvas.findCurrent = index
        editor.select(matches[index])
        showCount()
    }

    public func next() { step(1) }
    public func previous() { step(-1) }

    private func step(_ direction: Int) {
        if !isOpen { show() }
        guard !search.query.isEmpty else { return }
        let selection = canvas.selection
        if matches.isEmpty || refreshPending { refresh(from: selection.location, selecting: false) }
        guard !matches.isEmpty else { return NSSound.beep() }
        let onMatch = current.flatMap { matches.indices.contains($0) && matches[$0] == selection ? $0 : nil }
        let index: Int
        if let onMatch {
            index = (onMatch + direction + matches.count) % matches.count
        } else if direction > 0 {
            index = matches.firstIndex { $0.location >= NSMaxRange(selection) || ($0.location >= selection.location && selection.length == 0) } ?? 0
        } else {
            index = matches.lastIndex { NSMaxRange($0) <= selection.location } ?? matches.count - 1
        }
        go(to: index)
    }

    /// The text changed (a replacement, typing in the document, undo): the matches follow it.
    func documentChanged() {
        guard isOpen, !refreshPending else { return }
        refreshPending = true
        // A long document is searched again after a pause, not on every key.
        let delay: TimeInterval = canvas.text.length > 1_000_000 ? 0.15 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            guard self.isOpen else { return }
            self.refresh(from: self.canvas.selection.location, selecting: false)
        }
    }

    // MARK: Replacing

    /// Replaces the current match (the next one when none is selected), then moves on.
    public func replaceCurrent() {
        guard canvas.isEditable, !matches.isEmpty else { return NSSound.beep() }
        let selection = canvas.selection
        guard let i = matches.firstIndex(of: selection) else { return step(1) }
        let text = search.replacements(for: [matches[i]], in: canvas.text, template: replacement)[0]
        canvas.replace(matches[i], with: text, actionName: String(localized: "Replace"))
        refresh(from: canvas.selection.location, selecting: true)
    }

    /// Every match at once, as one undo step.
    public func replaceAll() {
        guard canvas.isEditable, let first = matches.first, let last = matches.last else { return NSSound.beep() }
        let replaced = search.replacements(for: matches, in: canvas.text, template: replacement)
        var out = ""
        var at = first.location
        for (range, text) in zip(matches, replaced) {
            out += canvas.text.substring(with: NSRange(location: at, length: range.location - at)) + text
            at = NSMaxRange(range)
        }
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let count = matches.count
        canvas.replace(span, with: out, actionName: String(localized: "Replace All"))
        refresh(from: canvas.selection.location, selecting: false)
        bar?.showCount(String(localized: "Replaced \(count)"))
    }

    // MARK: Bar events

    @objc private func nextPressed() { step(1) }
    @objc private func previousPressed() { step(-1) }
    @objc private func closePressed() { close() }
    @objc private func replacePressed() { replaceCurrent() }
    @objc private func replaceAllPressed() { replaceAll() }

    @objc private func disclosurePressed() {
        guard let bar else { return }
        bar.isReplacing.toggle()
        layoutBar()
        if bar.isReplacing { bar.window?.makeFirstResponder(bar.replaceBox.field) }
    }

    @objc private func optionChanged(_ sender: FindOption) {
        guard let bar else { return }
        search.matchCase = bar.matchCase.isOn
        search.wholeWord = bar.wholeWord.isOn
        search.regex = bar.regex.isOn
        defaults.set(search.matchCase, forKey: Defaults.matchCase)
        defaults.set(search.wholeWord, forKey: Defaults.wholeWord)
        defaults.set(search.regex, forKey: Defaults.regex)
        refresh(from: anchor, selecting: true)
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let bar, obj.object as? NSTextField === bar.findBox.field else { return }
        queryChanged(bar.findBox.field.stringValue)
    }

    public func setReplacement(_ text: String) { bar?.replaceBox.field.stringValue = text }

    /// The search string changed (typed in the field): search again from where this search began.
    public func queryChanged(_ text: String) {
        if let field = bar?.findBox.field, field.stringValue != text {
            field.stringValue = text
            bar?.findBox.textDidChangeProgrammatically()
        }
        search.query = text
        writePasteboard()
        refresh(from: anchor, selecting: true)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let bar else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if control === bar.replaceBox.field {
                replaceCurrent()
            } else {
                step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
            }
            return true
        default:
            return false
        }
    }
}
