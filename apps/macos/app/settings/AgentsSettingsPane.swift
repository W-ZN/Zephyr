import AppKit
import ZephyrCore
import ZephyrRender

/// Settings → Agents (design §10, §11): everyone who works on the text besides you. The built-in
/// assistant (provider, model, key), the instructions every agent follows, and how terminal agents
/// reach Zephyr: the same document tools, and `zephyr config` for the look.
final class AgentsSettingsPane: SettingsPage, NSTextViewDelegate {
    private let provider = SegmentedPicker(items: AIEndpoint.Kind.allCases.map(AgentsSettingsPane.name))
    private let endpointBox = FieldBox(placeholder: "https://")
    private let modelBox = FieldBox(placeholder: String(localized: "Model name"))
    private let tools = FlatToggle()
    private var toolsRow: NSView!
    private let keyBox = FieldBox(field: NSSecureTextField(), placeholder: String(localized: "Paste an API key"))
    private let keyState = flatLabel("", size: 12, color: Tokens.ink2)
    private let removeKey = FlatButton(title: String(localized: "Remove"), style: .plain)
    private let instructions = NSTextView()
    private var instructionsPending: DispatchWorkItem?
    /// Models each endpoint offered when last asked (by key account), and what went wrong.
    private static var models: [String: (ids: [String], at: Date)] = [:]
    private static var modelErrors: [String: String] = [:]
    private var loadingModels: Set<String> = []
    private var modelMenu: NSMenu?
    private let modelState = flatLabel("", size: 12, color: Tokens.ink2)
    private let modelSpinner = NSProgressIndicator()
    private let replaceKey = FlatButton(title: String(localized: "Replace"), style: .plain)
    private let endpointExample = flatLabel("", size: 12, color: Tokens.ink2, wraps: true)
    /// Every control in the assistant section shares this column, so their edges line up.
    static let controlWidth: CGFloat = 280

    override func loadView() {
        build(title: String(localized: "Agents"))
        assistant()
        guidance()
        terminal()
        history()
        sync()
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: Preferences.aiDidChange, object: nil)
    }

    static func name(_ kind: AIEndpoint.Kind) -> String {
        switch kind {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .compatible: String(localized: "Compatible")
        }
    }

    // MARK: Sections

    private func assistant() {
        addSection(String(localized: "Assistant"), String(localized: "A document is sent only when you ask. Keys are stored encrypted on this Mac."))
        provider.onChange = { [weak self] i in
            Preferences.endpoint = .preset(AIEndpoint.Kind.allCases[i])
            self?.sync()
        }
        addRow(String(localized: "Provider"), String(localized: "OpenAI-compatible covers local servers such as Ollama."), control: provider)
        for box in [endpointBox, modelBox] {
            box.field.target = self
            box.field.action = #selector(fieldsChanged)
        }
        endpointBox.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        let chooser = FlatButton(symbol: "chevron.down", style: .icon) { [weak self] in self?.showModels() }
        chooser.toolTip = String(localized: "Models this endpoint offers")
        chooser.setAccessibilityLabel(String(localized: "Choose a model"))
        modelBox.setAccessory(chooser)
        let refresh = FlatButton(symbol: "arrow.clockwise", style: .icon) { [weak self] in self?.loadModels(force: true) }
        refresh.toolTip = String(localized: "Ask the endpoint for its models again")
        refresh.setAccessibilityLabel(String(localized: "Refresh models"))
        refresh.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let modelControls = NSStackView(views: [modelBox, refresh])
        modelControls.spacing = 6
        modelControls.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        modelSpinner.style = .spinning
        modelSpinner.controlSize = .small
        modelSpinner.isDisplayedWhenStopped = false
        let modelStatus = NSStackView(views: [modelSpinner, modelState])
        modelStatus.spacing = 6
        addRow(String(localized: "API base URL"), nil, detailLabel: endpointExample, control: endpointBox)
        addRow(String(localized: "Model"), nil, control: Self.column(modelControls, modelStatus))
        tools.onChange = { [weak self] _ in self?.fieldsChanged() }
        toolsRow = addRow(String(localized: "Tool calls"), String(localized: "Needed to read documents and propose edits."), control: tools)

        // Return or Save stores the key at once; field and button together fill the control column.
        keyBox.field.target = self
        keyBox.field.action = #selector(saveKey)
        let save = FlatButton(title: String(localized: "Save"), style: .primary) { [weak self] in self?.saveKey() }
        save.setContentHuggingPriority(.required, for: .horizontal)
        removeKey.target = self
        removeKey.action = #selector(deleteKey)
        replaceKey.target = self
        replaceKey.action = #selector(focusKey)
        let keyControls = NSStackView(views: [keyBox, save])
        keyControls.spacing = 8
        keyControls.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        let keyStatus = NSStackView(views: [keyState, replaceKey, removeKey])
        keyStatus.spacing = 4
        addRow(String(localized: "API key"), nil, control: Self.column(keyControls, keyStatus))
    }

    private func guidance() {
        addSection(String(localized: "Instructions"))
        instructions.font = Tokens.font(13)
        instructions.textColor = Tokens.ink
        instructions.insertionPointColor = Tokens.accent
        instructions.drawsBackground = false
        instructions.isRichText = false
        instructions.allowsUndo = true
        instructions.textContainerInset = NSSize(width: 8, height: 9)
        instructions.isVerticallyResizable = true
        instructions.autoresizingMask = [.width]
        instructions.delegate = self
        instructions.string = Preferences.agentInstructions ?? ""
        instructions.setAccessibilityLabel(String(localized: "Instructions"))
        let scroll = NSScrollView()
        scroll.documentView = instructions
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let box = FieldSurface()
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            box.heightAnchor.constraint(equalToConstant: 110),
        ])
        let hint = flatLabel(String(localized: "For example: Answer in Chinese. Keep my headings."), size: 12, color: Tokens.ink3, wraps: true)
        let stack = NSStackView(views: [box, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addRow(String(localized: "For all agents"), nil, control: nil, below: stack)
    }

    private func terminal() {
        addSection(String(localized: "Terminal agents"))
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zephyr").path
        addRow(String(localized: "Command-line tool"), String(localized: "Reads and proposes edits only in a document you share with File → Allow Agent Access."),
               control: copyButton(cli), below: code(cli))
        let mcp = "{\n  \"mcpServers\": {\n    \"zephyr\": { \"command\": \"\(cli)\", \"args\": [\"mcp\"] }\n  }\n}"
        addRow(String(localized: "MCP server"), nil,
               control: copyButton(mcp), below: code(mcp))
        let example = "zephyr theme use anthology\nzephyr config list table.\nzephyr config set h2.size 1.6 table.lines grid"
        addRow(String(localized: "Appearance from the terminal"), nil,
               control: copyButton(example), below: code(example))
    }

    private func history() {
        addSection(String(localized: "History"))
        let clear = FlatButton(title: String(localized: "Clear…"), style: .secondary) { [weak self] in self?.clearHistory() }
        addRow(String(localized: "Change history"), String(localized: "Kept so changes from the assistant and agents can be withdrawn."), control: clear)
    }

    // MARK: State

    @objc private func sync() {
        let e = Preferences.endpoint
        provider.selectedIndex = AIEndpoint.Kind.allCases.firstIndex(of: e.kind) ?? 0
        endpointBox.field.stringValue = e.baseURL
        modelBox.field.stringValue = e.model
        tools.isOn = e.supportsTools
        toolsRow.isHidden = e.kind != .compatible
        let stored = CredentialStore.hasKey(for: e.keyAccount)
        keyState.stringValue = stored ? String(localized: "Saved, encrypted on this Mac.")
            : e.needsKey ? String(localized: "No key saved for this endpoint.") : String(localized: "Optional: local servers usually need no key.")
        removeKey.isHidden = !stored
        replaceKey.isHidden = !stored
        endpointExample.stringValue = Self.example(e.kind)
        showModelState()
    }

    /// Where each provider's API lives, as an example under the base URL.
    private static func example(_ kind: AIEndpoint.Kind) -> String {
        switch kind {
        case .anthropic: String(localized: "For example https://api.anthropic.com")
        case .openAI: String(localized: "For example https://api.openai.com/v1")
        case .compatible: String(localized: "With the version path, for example http://localhost:11434/v1 for Ollama")
        }
    }

    /// Opening Settings never reads a secret: only a local server without a saved key is asked
    /// here; keyed endpoints are asked when the list is opened, refreshed, or a key is saved.
    override func viewDidAppear() {
        super.viewDidAppear()
        let e = Preferences.endpoint
        if !e.needsKey, !CredentialStore.hasKey(for: e.keyAccount) { loadModels(force: false) }
    }

    @objc private func focusKey() {
        view.window?.makeFirstResponder(keyBox.field)
    }

    @objc private func fieldsChanged() {
        let before = Preferences.endpoint.keyAccount
        var e = Preferences.endpoint
        e.baseURL = endpointBox.field.stringValue.trimmingCharacters(in: .whitespaces)
        e.model = modelBox.field.stringValue.trimmingCharacters(in: .whitespaces)
        e.supportsTools = e.kind != .compatible || tools.isOn
        Preferences.endpoint = e
        sync()
        if e.keyAccount != before, !e.needsKey, !CredentialStore.hasKey(for: e.keyAccount) { loadModels(force: false) }
    }

    @objc private func saveKey() {
        fieldsChanged()
        let value = keyBox.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            view.window?.makeFirstResponder(keyBox.field)
            return
        }
        let account = Preferences.endpoint.keyAccount
        guard CredentialStore.setKey(value, for: account) else {
            keyState.stringValue = String(localized: "The key could not be saved: credentials.json in ~/Library/Application Support/Zephyr is unreadable or the folder is not writable.")
            return NSSound.beep()
        }
        keyBox.field.stringValue = ""
        view.window?.makeFirstResponder(nil)
        sync()
        // A new key may open up the endpoint's models.
        Self.modelErrors[account] = nil
        loadModels(force: true, key: value)
        NotificationCenter.default.post(name: Preferences.aiDidChange, object: nil)
    }

    // MARK: Models

    /// The models the endpoint listed, in a menu under the field. Typing any ID stays possible.
    private func showModels() {
        loadModels(force: false)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = modelBox.bounds.width
        fillModelMenu(menu)
        modelMenu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modelBox.isFlipped ? modelBox.bounds.maxY + 4 : -4), in: modelBox)
        modelMenu = nil
    }

    private func fillModelMenu(_ menu: NSMenu) {
        let e = Preferences.endpoint
        menu.removeAllItems()
        guard let models = Self.models[e.keyAccount]?.ids, !models.isEmpty else {
            let item = NSMenuItem(title: modelState.stringValue.isEmpty ? String(localized: "No models listed yet") : modelState.stringValue, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        for id in models {
            let item = ClosureMenuItem(title: id) { [weak self] in
                self?.modelBox.field.stringValue = id
                self?.fieldsChanged()
            }
            item.state = id == e.model ? .on : .off
            menu.addItem(item)
        }
    }

    /// Asks the endpoint for its models with the key saved for it (or the one just saved), unless
    /// a list newer than 30 minutes is at hand. A failed refresh keeps the last list; the model in the field never changes.
    private func loadModels(force: Bool, key given: String? = nil) {
        let e = Preferences.endpoint
        guard !loadingModels.contains(e.keyAccount) else { return }
        if !force, let cached = Self.models[e.keyAccount], Date().timeIntervalSince(cached.at) < 30 * 60 { return showModelState() }
        let key = given ?? CredentialStore.key(for: e.keyAccount)
        guard key != nil || !e.needsKey else {
            Self.modelErrors[e.keyAccount] = String(localized: "Save a key to list this endpoint's models.")
            return showModelState()
        }
        loadingModels.insert(e.keyAccount)
        showModelState()
        Task { @MainActor [weak self] in
            do {
                Self.models[e.keyAccount] = (try await AIModels.fetch(e, apiKey: key), Date())
                Self.modelErrors[e.keyAccount] = nil
            } catch {
                Self.modelErrors[e.keyAccount] = Self.describe(error)
            }
            guard let self else { return }
            self.loadingModels.remove(e.keyAccount)
            self.showModelState()
            if let menu = self.modelMenu { self.fillModelMenu(menu) }
        }
    }

    private static func describe(_ error: Error) -> String {
        let code = (error as? URLError)?.errorCode ?? 0
        switch code {
        case 401, 403: return String(localized: "Authentication rejected. Check the key.")
        case 404, 405, 501: return String(localized: "This endpoint does not list models. Enter an ID.")
        case URLError.badURL.rawValue: return String(localized: "The base URL is not valid (HTTPS, or a server on this Mac).")
        default: return String(localized: "Endpoint unreachable. Enter an ID, or try again.")
        }
    }

    private func showModelState() {
        let e = Preferences.endpoint
        let loading = loadingModels.contains(e.keyAccount)
        if loading { modelSpinner.startAnimation(nil) } else { modelSpinner.stopAnimation(nil) }
        if loading {
            modelState.stringValue = String(localized: "Loading models…")
        } else if let error = Self.modelErrors[e.keyAccount] {
            modelState.stringValue = error
        } else if let ids = Self.models[e.keyAccount]?.ids {
            modelState.stringValue = ids.isEmpty ? String(localized: "No models returned.") : String(localized: "\(ids.count) models listed.")
        } else {
            modelState.stringValue = ""
        }
        modelState.textColor = Self.modelErrors[e.keyAccount] != nil && !loading ? Tokens.danger : Tokens.ink2
        modelState.superview?.isHidden = modelState.stringValue.isEmpty
    }

    @objc private func deleteKey() {
        guard CredentialStore.removeKey(for: Preferences.endpoint.keyAccount) else {
            keyState.stringValue = String(localized: "The key could not be removed: credentials.json in ~/Library/Application Support/Zephyr is unreadable or the folder is not writable.")
            return NSSound.beep()
        }
        sync()
        NotificationCenter.default.post(name: Preferences.aiDidChange, object: nil)
    }

    func textDidChange(_ notification: Notification) {
        instructionsPending?.cancel()
        let work = DispatchWorkItem { [weak self] in Preferences.agentInstructions = self?.instructions.string }
        instructionsPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear the change history?")
        alert.informativeText = String(localized: "Changes from the assistant and agents can no longer be withdrawn. Your documents are not affected.")
        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { Transactions.clear() }
        }
    }

    // MARK: Pieces

    /// A control with its status line beneath it, in the control column.
    private static func column(_ control: NSView, _ status: NSView) -> NSStackView {
        let stack = NSStackView(views: [control, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.detachesHiddenViews = true
        return stack
    }

    private func code(_ text: String) -> NSView {
        let box = SurfaceView(fill: Tokens.sunken, border: nil, radius: Tokens.Radius.control + 2)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        label.textColor = Tokens.ink
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        return box
    }

    private func copyButton(_ text: String) -> FlatButton {
        let button = FlatButton(title: String(localized: "Copy"), symbol: "doc.on.doc", style: .secondary) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return button
    }
}

/// An outlined box for a multi-line field; its border turns accent while the text inside is edited.
final class FieldSurface: SurfaceView {
    init() { super.init(fill: Tokens.raised, border: Tokens.line, radius: Tokens.Radius.control) }
    required init?(coder: NSCoder) { fatalError() }
}
