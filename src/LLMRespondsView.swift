import AppKit

/// The "LLM Responds" side panel: asks an OpenAI-compatible model a saved prompt about the note.
///
/// It is deliberately not a chat. Every request carries only the prompt and the current
/// note, so the same question can be asked again whenever the note has changed, and each
/// answer replaces the previous one.
final class LLMRespondsView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    static let defaultWidth: CGFloat = 320
    static let minWidth: CGFloat = 240
    static let maxWidth: CGFloat = 640

    /// Returns the note that is sent as context with every request.
    var noteProvider: (() -> String)?

    /// Base size of the rendered answer, kept in step with the editor's font size.
    var fontSize: CGFloat {
        didSet { renderResponse() }
    }

    private(set) var isResponding = false

    private let defaults = UserDefaults.standard
    private let promptKey = "llmPrompt"
    private let endpointKey = "llmEndpoint"
    private let modelKey = "llmModel"
    private let responseKey = "llmResponse"
    private let responseDateKey = "llmResponseDate"
    private let keychainService = "Scratchpad LLM Responds"
    private let keychainAccount = "API key"

    private let headerHeight: CGFloat = 32
    private let margin: CGFloat = 12
    private let spacing: CGFloat = 8
    private let labelWidth: CGFloat = 56
    private let promptHeight: CGFloat = 72

    private var background: NSVisualEffectView!
    private var titleLabel: NSTextField!
    private var connectionButton: NSButton!
    private var endpointField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var modelField: NSTextField!
    private var connectionRows: [(label: NSTextField, field: NSTextField)] = []
    private var connectionHint: NSTextField!
    private var promptField: NSTextField!
    private var respondButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var separator: NSBox!
    private var responseScrollView: NSScrollView!
    private var responseTextView: NSTextView!

    private var showsConnection = false
    private var connectionLoaded = false
    private var storedAPIKey: String?

    private var responseText = ""
    private var responseStarted = false
    private var responseTask: Task<Void, Never>?
    private var pendingRender: Task<Void, Never>?

    override var isFlipped: Bool { true }

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        super.init(frame: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 480))
        buildContent()

        responseText = defaults.string(forKey: responseKey) ?? ""
        renderResponse()
        if !responseText.isEmpty, let date = defaults.object(forKey: responseDateKey) as? Date {
            showStatus(answeredStatus(date))
        }
        // Nothing can be asked until there is an endpoint, so start with the connection open.
        setConnectionVisible((defaults.string(forKey: endpointKey) ?? "").isEmpty)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    private func buildContent() {
        let background = NSVisualEffectView(frame: bounds)
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        addSubview(background)
        self.background = background

        let title = NSTextField(labelWithString: "LLM Responds")
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.sizeToFit()
        addSubview(title)
        self.titleLabel = title

        let gear = NSButton(title: "", target: self, action: #selector(toggleConnection(_:)))
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Connection settings")
        gear.imagePosition = .imageOnly
        gear.isBordered = false
        gear.toolTip = "Endpoint, API key and model"
        gear.sizeToFit()
        addSubview(gear)
        self.connectionButton = gear

        endpointField = addConnectionRow("Endpoint", field: NSTextField(), placeholder: "https://api.openai.com/v1")
        apiKeyField = addConnectionRow("API key", field: NSSecureTextField(), placeholder: "Optional for local servers")
        modelField = addConnectionRow("Model", field: NSTextField(), placeholder: "e.g. gpt-4o-mini")

        let hint = NSTextField(wrappingLabelWithString: "Any OpenAI-compatible API. The key is stored in your Keychain.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        addSubview(hint)
        self.connectionHint = hint

        let prompt = NSTextField()
        prompt.stringValue = defaults.string(forKey: promptKey) ?? ""
        prompt.placeholderString = "Ask something about your note…"
        prompt.font = NSFont.systemFont(ofSize: 13)
        prompt.usesSingleLineMode = false
        prompt.cell?.wraps = true
        prompt.cell?.isScrollable = false
        prompt.cell?.truncatesLastVisibleLine = true
        prompt.toolTip = "Return asks, Shift-Return starts a new line"
        prompt.delegate = self
        addSubview(prompt)
        self.promptField = prompt

        // The panel is added after the window has worked out its key view loop, so Tab
        // needs an explicit order. Hidden fields are skipped automatically.
        endpointField.nextKeyView = apiKeyField
        apiKeyField.nextKeyView = modelField
        modelField.nextKeyView = prompt
        prompt.nextKeyView = endpointField

        // Sized for the longer of its two titles so it doesn't jump while responding.
        let button = NSButton(title: "Stop", target: self, action: #selector(respondButtonClicked(_:)))
        button.sizeToFit()
        let stopWidth = button.frame.width
        button.title = "Get Response"
        button.sizeToFit()
        button.frame.size.width = max(button.frame.width, stopWidth)
        button.toolTip = "Ask again about the current note (⌘↩)"
        addSubview(button)
        self.respondButton = button

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.sizeToFit()
        addSubview(spinner)
        self.spinner = spinner

        let status = NSTextField(wrappingLabelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        addSubview(status)
        self.statusLabel = status

        let separator = NSBox()
        separator.boxType = .separator
        addSubview(separator)
        self.separator = separator

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: 240))
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.isRichText = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        // Lines up the text (after the 5 pt line fragment padding) with the controls above.
        textView.textContainerInset = NSSize(width: margin - 5, height: 12)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel("Response")

        scrollView.documentView = textView
        addSubview(scrollView)
        self.responseScrollView = scrollView
        self.responseTextView = textView
    }

    private func addConnectionRow<Field: NSTextField>(_ title: String, field: Field, placeholder: String) -> Field {
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 12)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.sizeToFit()
        addSubview(field)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.sizeToFit()
        addSubview(label)

        connectionRows.append((label, field))
        return field
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutContent()
    }

    /// Stacks the sections from the top; the answer takes whatever height is left.
    private func layoutContent() {
        let width = bounds.width
        let innerWidth = max(width - 2 * margin, 0)
        background.frame = bounds

        // Same 32 pt band as the editor's top bar.
        titleLabel.frame.origin = NSPoint(x: margin, y: (headerHeight - titleLabel.frame.height) / 2)
        connectionButton.frame.origin = NSPoint(
            x: width - margin - connectionButton.frame.width,
            y: (headerHeight - connectionButton.frame.height) / 2
        )
        var y = headerHeight

        if showsConnection {
            let fieldX = margin + labelWidth + 6
            let fieldWidth = max(width - margin - fieldX, 0)
            for (label, field) in connectionRows {
                field.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: field.frame.height)
                label.frame = NSRect(
                    x: margin,
                    y: y + (field.frame.height - label.frame.height) / 2,
                    width: labelWidth,
                    height: label.frame.height
                )
                y += field.frame.height + 6
            }
            let hintHeight = height(of: connectionHint, width: fieldWidth)
            connectionHint.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: hintHeight)
            y += hintHeight + 2 * spacing
        }

        promptField.frame = NSRect(x: margin, y: y, width: innerWidth, height: promptHeight)
        y += promptHeight + spacing

        respondButton.frame.origin = NSPoint(x: margin, y: y)
        spinner.frame.origin = NSPoint(
            x: respondButton.frame.maxX + spacing,
            y: y + (respondButton.frame.height - spinner.frame.height) / 2
        )
        y += respondButton.frame.height + 4

        let statusHeight = height(of: statusLabel, width: innerWidth)
        statusLabel.frame = NSRect(x: margin, y: y, width: innerWidth, height: statusHeight)
        y += statusHeight + spacing

        separator.frame = NSRect(x: 0, y: y, width: width, height: 1)
        y += 1
        responseScrollView.frame = NSRect(x: 0, y: y, width: width, height: max(bounds.height - y, 0))
    }

    private func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        guard !label.stringValue.isEmpty, let cell = label.cell else { return 0 }
        let bounds = NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)
        return ceil(cell.cellSize(forBounds: bounds).height)
    }

    /// Puts the cursor where the panel still needs input, if anywhere.
    func focusMissingInput() {
        if showsConnection, endpointField.stringValue.isEmpty {
            window?.makeFirstResponder(endpointField)
        } else if promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            window?.makeFirstResponder(promptField)
        }
    }

    // MARK: - Connection

    @objc private func toggleConnection(_ sender: Any?) {
        setConnectionVisible(!showsConnection)
    }

    private func setConnectionVisible(_ visible: Bool) {
        if visible {
            loadConnectionFieldsIfNeeded()
        } else {
            // Stop editing a field before it disappears.
            if connectionRows.contains(where: { $0.field.currentEditor() != nil }) {
                window?.makeFirstResponder(promptField)
            }
            commitConnectionFields()
        }

        showsConnection = visible
        for (label, field) in connectionRows {
            label.isHidden = !visible
            field.isHidden = !visible
        }
        connectionHint.isHidden = !visible
        connectionButton.contentTintColor = visible ? .controlAccentColor : .secondaryLabelColor
        layoutContent()
    }

    private func loadConnectionFieldsIfNeeded() {
        guard !connectionLoaded else { return }
        connectionLoaded = true
        endpointField.stringValue = defaults.string(forKey: endpointKey) ?? ""
        modelField.stringValue = defaults.string(forKey: modelKey) ?? ""
        apiKeyField.stringValue = apiKey
    }

    /// The API key lives in the Keychain and is only read once it's actually needed,
    /// since reading it may show a Keychain access prompt.
    private var apiKey: String {
        if let storedAPIKey { return storedAPIKey }
        let key = Keychain.string(service: keychainService, account: keychainAccount) ?? ""
        storedAPIKey = key
        return key
    }

    /// Saves the connection fields. Until they have been shown there is nothing to save.
    func commitConnectionFields() {
        guard connectionLoaded else { return }
        defaults.set(endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: endpointKey)
        defaults.set(modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelKey)

        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key != storedAPIKey {
            storedAPIKey = key
            Keychain.set(key, service: keychainService, account: keychainAccount)
        }
    }

    private func configuration() -> LLMConfiguration {
        commitConnectionFields()
        return LLMConfiguration(
            endpoint: defaults.string(forKey: endpointKey) ?? "",
            apiKey: apiKey,
            model: defaults.string(forKey: modelKey) ?? ""
        )
    }

    // MARK: - Asking

    @objc private func respondButtonClicked(_ sender: Any?) {
        if isResponding {
            stop()
        } else {
            respond()
        }
    }

    /// Sends the prompt together with the note as it is right now.
    func respond() {
        guard !isResponding else { return }
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            showStatus("Write a prompt first.", isError: true)
            window?.makeFirstResponder(promptField)
            return
        }

        let request: URLRequest
        do {
            request = try LLMClient.makeRequest(
                prompt: prompt,
                note: noteProvider?() ?? "",
                configuration: configuration()
            )
        } catch {
            showStatus(error.localizedDescription, isError: true)
            setConnectionVisible(true)
            window?.makeFirstResponder(endpointField)
            return
        }

        responseStarted = false
        setResponding(true)
        showStatus("Responding…")
        responseTask = Task { [weak self] in
            var answer = ""
            do {
                for try await text in LLMClient.streamResponse(for: request) {
                    answer += text
                    self?.showPartialResponse(answer)
                }
                try Task.checkCancellation()
                self?.finishResponse(answer, error: nil)
            } catch {
                self?.finishResponse(answer, error: error)
            }
        }
    }

    func stop() {
        responseTask?.cancel()
    }

    private func setResponding(_ responding: Bool) {
        isResponding = responding
        respondButton.title = responding ? "Stop" : "Get Response"
        respondButton.toolTip = responding ? "Stop (⌘.)" : "Ask again about the current note (⌘↩)"
        if responding {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    /// The previous answer stays visible until the first piece of the new one arrives,
    /// so a failed request never leaves the panel empty.
    private func showPartialResponse(_ answer: String) {
        responseText = answer
        if !responseStarted {
            responseStarted = true
            renderResponse()
            responseTextView.scroll(.zero)
            return
        }

        // Re-rendering the Markdown for every token is wasteful; batch them instead.
        guard pendingRender == nil else { return }
        pendingRender = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            self.pendingRender = nil
            self.renderResponse()
        }
    }

    private func finishResponse(_ answer: String, error: Error?) {
        responseTask = nil
        pendingRender?.cancel()
        pendingRender = nil
        setResponding(false)
        if responseStarted {
            renderResponse()
        }

        guard let error else {
            let date = Date()
            defaults.set(answer, forKey: responseKey)
            defaults.set(date, forKey: responseDateKey)
            showStatus(answeredStatus(date))
            return
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            showStatus(responseStarted ? "Stopped before the answer was complete." : "Stopped.")
        } else {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func renderResponse() {
        guard let storage = responseTextView?.textStorage else { return }
        if responseText.isEmpty {
            storage.setAttributedString(NSAttributedString(
                string: "Answers appear here. Ask again with ⌘↩ whenever the note changes.",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        } else {
            storage.setAttributedString(MarkdownRenderer.render(responseText, baseSize: fontSize))
        }
    }

    private func showStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        layoutContent()
    }

    private func answeredStatus(_ date: Date) -> String {
        "Answered \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === promptField {
            defaults.set(promptField.stringValue, forKey: promptKey)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitConnectionFields()
    }

    /// Return in the prompt asks; Shift-Return (or Option-Return) inserts a line break.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === promptField, commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
            respond()
        }
        return true
    }

    // MARK: - NSTextViewDelegate

    /// Answers are model output, so only web links in them are opened.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = link as? URL ?? (link as? String).flatMap { URL(string: $0) }
        if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}
