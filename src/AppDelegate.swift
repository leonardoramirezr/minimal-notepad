import AppKit
import Foundation

class LineMovableTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
        if modifiers.contains(.option), modifiers.isDisjoint(with: [.shift, .command, .control]),
            event.keyCode == 126 || event.keyCode == 125
        {
            moveLine(up: event.keyCode == 126)
            return
        }
        super.keyDown(with: event)
    }

    private func splitTerminator(_ text: String) -> (content: String, terminator: String) {
        for term in ["\r\n", "\n", "\r"] {
            if text.hasSuffix(term) {
                return (String(text.dropLast(term.count)), term)
            }
        }
        return (text, "")
    }

    private func moveLine(up: Bool) {
        guard let textStorage = self.textStorage else { return }
        let nsString = textStorage.string as NSString
        let selectedRange = self.selectedRange()
        let lineRange = nsString.lineRange(for: selectedRange)

        if up {
            guard lineRange.location > 0 else {
                NSSound.beep()
                return
            }
            let prevLineRange = nsString.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            let (prevContent, prevTerm) = splitTerminator(nsString.substring(with: prevLineRange))
            let (curContent, curTerm) = splitTerminator(nsString.substring(with: lineRange))
            let newBlock = curContent + prevTerm + prevContent + curTerm
            let combinedRange = NSRange(
                location: prevLineRange.location,
                length: prevLineRange.length + lineRange.length
            )

            guard shouldChangeText(in: combinedRange, replacementString: newBlock) else { return }
            textStorage.replaceCharacters(in: combinedRange, with: newBlock)
            didChangeText()

            let offsetInLine = selectedRange.location - lineRange.location
            let newRange = NSRange(location: prevLineRange.location + offsetInLine, length: selectedRange.length)
            setSelectedRange(newRange)
            scrollRangeToVisible(newRange)
        } else {
            guard lineRange.location + lineRange.length < nsString.length else {
                NSSound.beep()
                return
            }
            let nextLineRange = nsString.lineRange(
                for: NSRange(location: lineRange.location + lineRange.length, length: 0)
            )
            let (curContent, curTerm) = splitTerminator(nsString.substring(with: lineRange))
            let (nextContent, nextTerm) = splitTerminator(nsString.substring(with: nextLineRange))
            let newBlock = nextContent + curTerm + curContent + nextTerm
            let combinedRange = NSRange(
                location: lineRange.location,
                length: lineRange.length + nextLineRange.length
            )

            guard shouldChangeText(in: combinedRange, replacementString: newBlock) else { return }
            textStorage.replaceCharacters(in: combinedRange, with: newBlock)
            didChangeText()

            let offsetInLine = selectedRange.location - lineRange.location
            let prefixLength = (nextContent as NSString).length + (curTerm as NSString).length
            let newRange = NSRange(location: lineRange.location + prefixLength + offsetInLine, length: selectedRange.length)
            setSelectedRange(newRange)
            scrollRangeToVisible(newRange)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    var window: NSWindow!
    let defaults = UserDefaults.standard
    let key = "scratchText"

    /// Holds the optional LLM Responds panel on the left and the editor on the right.
    var splitView: NSSplitView!
    var llmPanel: LLMRespondsView?
    let llmPanelWidthKey = "llmPanelWidth"
    let minEditorWidth: CGFloat = 320

    var isLLMPanelVisible: Bool { llmPanel?.superview != nil }

    var editScrollView: NSScrollView!
    var textView: NSTextView!

    var previewScrollView: NSScrollView!
    var previewTextView: NSTextView!

    var markdownSwitch: NSSwitch!
    var centerSwitch: NSSwitch!
    var bodyContainer: NSView!

    let topBarHeight: CGFloat = 32

    var isCentered = false
    let pageWidth: CGFloat = 1000
    let centerMinMargin: CGFloat = 24

    let editBaseInset = NSSize(width: 20, height: 20)
    let previewBaseInset = NSSize(width: 32, height: 24)

    let fontSizeKey = "editorFontSize"
    var fontSize = SettingsWindowController.defaultFontSize
    var settingsWindowController: SettingsWindowController?

    /// The Markdown preview reads one point larger than the editor,
    /// keeping the proportion the app shipped with.
    var previewBaseSize: CGFloat { fontSize + 1 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        fontSize = storedFontSize()

        let windowWidth: CGFloat = 600
        let windowHeight: CGFloat = 432

        let container = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        container.autoresizesSubviews = true

        let topBar = makeTopBar(width: windowWidth, containerHeight: windowHeight)
        container.addSubview(topBar)

        let body = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight - topBarHeight))
        body.autoresizingMask = [.width, .height]
        body.autoresizesSubviews = true
        container.addSubview(body)
        self.bodyContainer = body

        setUpEditView(in: body)
        setUpPreviewView()

        let splitView = NSSplitView(frame: container.frame)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addSubview(container)
        self.splitView = splitView

        // A single-window app: keeps AppKit from adding tab items to the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false

        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())

        let servicesMenu = NSMenu()
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApplication.shared.servicesMenu = servicesMenu

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit Scratchpad",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        fileMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.target = nil
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.target = nil
        editMenu.addItem(redoItem)

        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        let llmPanelItem = NSMenuItem(
            title: "Show LLM Responds",
            action: #selector(toggleLLMPanel(_:)),
            keyEquivalent: "L"
        )
        llmPanelItem.target = self
        viewMenu.addItem(llmPanelItem)
        viewMenu.addItem(NSMenuItem.separator())

        let respondItem = NSMenuItem(
            title: "Get Response",
            action: #selector(requestLLMResponse(_:)),
            keyEquivalent: "\r"
        )
        respondItem.target = self
        viewMenu.addItem(respondItem)

        let stopItem = NSMenuItem(
            title: "Stop Response",
            action: #selector(stopLLMResponse(_:)),
            keyEquivalent: "."
        )
        stopItem.target = self
        viewMenu.addItem(stopItem)

        NSApplication.shared.mainMenu = mainMenu

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scratchpad"
        window.contentView = splitView
        window.center()
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    private func makeTopBar(width: CGFloat, containerHeight: CGFloat) -> NSView {
        let topBar = NSView(frame: NSRect(x: 0, y: containerHeight - topBarHeight, width: width, height: topBarHeight))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.autoresizesSubviews = true

        let margin: CGFloat = 16
        let spacing: CGFloat = 6
        let groupSpacing: CGFloat = 18

        func makeToggleGroup(title: String, action: Selector) -> (NSSwitch, NSTextField) {
            let toggle = NSSwitch()
            toggle.frame.size = toggle.intrinsicContentSize
            toggle.target = self
            toggle.action = action

            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.sizeToFit()

            return (toggle, label)
        }

        let (markdownToggle, markdownLabel) = makeToggleGroup(
            title: "Markdown",
            action: #selector(toggleMarkdownPreview(_:))
        )
        self.markdownSwitch = markdownToggle

        markdownToggle.frame.origin = NSPoint(
            x: width - margin - markdownToggle.frame.width,
            y: (topBarHeight - markdownToggle.frame.height) / 2
        )
        markdownToggle.autoresizingMask = [.minXMargin]

        markdownLabel.frame.origin = NSPoint(
            x: markdownToggle.frame.minX - spacing - markdownLabel.frame.width,
            y: (topBarHeight - markdownLabel.frame.height) / 2
        )
        markdownLabel.autoresizingMask = [.minXMargin]

        let (centerToggle, centerLabel) = makeToggleGroup(
            title: "Center",
            action: #selector(toggleCenteredLayout(_:))
        )
        self.centerSwitch = centerToggle

        centerToggle.frame.origin = NSPoint(
            x: markdownLabel.frame.minX - groupSpacing - centerToggle.frame.width,
            y: (topBarHeight - centerToggle.frame.height) / 2
        )
        centerToggle.autoresizingMask = [.minXMargin]

        centerLabel.frame.origin = NSPoint(
            x: centerToggle.frame.minX - spacing - centerLabel.frame.width,
            y: (topBarHeight - centerLabel.frame.height) / 2
        )
        centerLabel.autoresizingMask = [.minXMargin]

        topBar.addSubview(markdownLabel)
        topBar.addSubview(markdownToggle)
        topBar.addSubview(centerLabel)
        topBar.addSubview(centerToggle)

        return topBar
    }

    private func setUpEditView(in body: NSView) {
        let scrollView = NSScrollView(frame: body.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView = LineMovableTextView(frame: scrollView.bounds)
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = editBaseInset
        textView.string = defaults.string(forKey: key) ?? ""
        textView.autoresizingMask = [.width, .height]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.allowsUndo = true

        scrollView.documentView = textView
        self.editScrollView = scrollView
        self.textView = textView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        body.addSubview(scrollView)
    }

    private func setUpPreviewView() {
        let scrollView = NSScrollView(frame: bodyContainer.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isRichText = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.textContainerInset = previewBaseInset
        textView.autoresizingMask = [.width, .height]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        self.previewScrollView = scrollView
        self.previewTextView = textView
    }

    @objc func toggleMarkdownPreview(_ sender: NSSwitch) {
        if sender.state == .on {
            previewTextView.textStorage?.setAttributedString(
                MarkdownRenderer.render(textView.string, baseSize: previewBaseSize)
            )
            editScrollView.removeFromSuperview()
            previewScrollView.frame = bodyContainer.bounds
            bodyContainer.addSubview(previewScrollView)
        } else {
            previewScrollView.removeFromSuperview()
            editScrollView.frame = bodyContainer.bounds
            bodyContainer.addSubview(editScrollView)
            window.makeFirstResponder(textView)
        }
        updateCenteringInsets()
    }

    @objc func toggleCenteredLayout(_ sender: NSSwitch) {
        isCentered = sender.state == .on
        updateCenteringInsets()
    }

    @objc func windowDidResize(_ notification: Notification) {
        guard isCentered else { return }
        updateCenteringInsets()
    }

    private func updateCenteringInsets() {
        applyCentering(to: textView, baseInset: editBaseInset)
        applyCentering(to: previewTextView, baseInset: previewBaseInset)
    }

    private func applyCentering(to textView: NSTextView, baseInset: NSSize) {
        guard let clipWidth = textView.enclosingScrollView?.contentView.bounds.width, clipWidth > 0 else { return }

        if isCentered {
            let inset = max((clipWidth - pageWidth) / 2, centerMinMargin)
            textView.textContainerInset = NSSize(width: inset, height: baseInset.height)
        } else {
            textView.textContainerInset = baseInset
        }
    }

    // MARK: - Settings

    @objc func openSettings(_ sender: Any?) {
        let controller: SettingsWindowController
        if let existing = settingsWindowController {
            controller = existing
        } else {
            controller = SettingsWindowController(fontSize: fontSize)
            controller.onFontSizeChange = { [weak self] size in
                self?.applyFontSize(size)
            }
            settingsWindowController = controller
        }

        controller.showFontSize(fontSize)
        if controller.window?.isVisible != true {
            controller.window?.center()
        }
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func storedFontSize() -> CGFloat {
        let stored = CGFloat(defaults.double(forKey: fontSizeKey))
        guard stored > 0 else { return SettingsWindowController.defaultFontSize }
        return min(max(stored, SettingsWindowController.minFontSize), SettingsWindowController.maxFontSize)
    }

    private func applyFontSize(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        defaults.set(Double(size), forKey: fontSizeKey)

        textView.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if markdownSwitch.state == .on {
            previewTextView.textStorage?.setAttributedString(
                MarkdownRenderer.render(textView.string, baseSize: previewBaseSize)
            )
        }
        llmPanel?.fontSize = size
    }

    // MARK: - LLM Responds

    @objc func toggleLLMPanel(_ sender: Any?) {
        if isLLMPanelVisible {
            hideLLMPanel()
        } else {
            showLLMPanel()
        }
    }

    @objc func requestLLMResponse(_ sender: Any?) {
        if !isLLMPanelVisible {
            showLLMPanel()
        }
        llmPanel?.respond()
    }

    @objc func stopLLMResponse(_ sender: Any?) {
        llmPanel?.stop()
    }

    private func showLLMPanel() {
        let panel = llmPanel ?? makeLLMPanel()
        let storedWidth = CGFloat(defaults.double(forKey: llmPanelWidthKey))
        let preferredWidth = storedWidth > 0 ? storedWidth : LLMRespondsView.defaultWidth
        let width = min(max(preferredWidth, LLMRespondsView.minWidth), maxLLMPanelWidth)

        panel.frame = NSRect(x: 0, y: 0, width: width, height: splitView.bounds.height)
        splitView.insertArrangedSubview(panel, at: 0)
        splitView.adjustSubviews()
        splitView.setPosition(width, ofDividerAt: 0)
        updateCenteringInsets()
        panel.focusMissingInput()
    }

    private func hideLLMPanel() {
        guard let panel = llmPanel else { return }
        saveLLMPanelState()
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: panel) {
            window.makeFirstResponder(markdownSwitch.state == .on ? previewTextView : textView)
        }
        panel.removeFromSuperview()
        splitView.adjustSubviews()
        updateCenteringInsets()
    }

    private func makeLLMPanel() -> LLMRespondsView {
        let panel = LLMRespondsView(fontSize: fontSize)
        panel.noteProvider = { [weak self] in
            self?.textView.string ?? ""
        }
        llmPanel = panel
        return panel
    }

    private func saveLLMPanelState() {
        guard let panel = llmPanel else { return }
        panel.commitConnectionFields()
        if isLLMPanelVisible {
            defaults.set(Double(panel.frame.width), forKey: llmPanelWidthKey)
        }
    }

    private var maxLLMPanelWidth: CGFloat {
        max(min(LLMRespondsView.maxWidth, splitView.bounds.width - minEditorWidth), LLMRespondsView.minWidth)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, LLMRespondsView.minWidth)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, maxLLMPanelWidth)
    }

    /// When the window resizes, the editor takes up the difference and the panel keeps its width.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== llmPanel
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isCentered else { return }
        updateCenteringInsets()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleLLMPanel(_:)):
            menuItem.title = isLLMPanelVisible ? "Hide LLM Responds" : "Show LLM Responds"
            return true
        case #selector(requestLLMResponse(_:)):
            return llmPanel?.isResponding != true
        case #selector(stopLLMResponse(_:)):
            return llmPanel?.isResponding == true
        default:
            return true
        }
    }

    @objc func textDidChange(_ notification: Notification) {
        if let textView = notification.object as? NSTextView {
            defaults.set(textView.string, forKey: key)
            defaults.synchronize()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        defaults.set(textView.string, forKey: key)
        saveLLMPanelState()
        defaults.synchronize()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
