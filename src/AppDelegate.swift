import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let defaults = UserDefaults.standard
    let key = "scratchText"

    var editScrollView: NSScrollView!
    var textView: NSTextView!

    var previewScrollView: NSScrollView!
    var previewTextView: NSTextView!

    var markdownSwitch: NSSwitch!
    var bodyContainer: NSView!

    let topBarHeight: CGFloat = 32

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()

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

        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
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

        NSApplication.shared.mainMenu = mainMenu

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scratchpad"
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeTopBar(width: CGFloat, containerHeight: CGFloat) -> NSView {
        let topBar = NSView(frame: NSRect(x: 0, y: containerHeight - topBarHeight, width: width, height: topBarHeight))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.autoresizesSubviews = true

        let toggle = NSSwitch()
        toggle.frame.size = toggle.intrinsicContentSize
        toggle.target = self
        toggle.action = #selector(toggleMarkdownPreview(_:))
        self.markdownSwitch = toggle

        let label = NSTextField(labelWithString: "Markdown")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()

        let margin: CGFloat = 16
        let spacing: CGFloat = 6

        toggle.frame.origin = NSPoint(
            x: width - margin - toggle.frame.width,
            y: (topBarHeight - toggle.frame.height) / 2
        )
        toggle.autoresizingMask = [.minXMargin]

        label.frame.origin = NSPoint(
            x: toggle.frame.minX - spacing - label.frame.width,
            y: (topBarHeight - label.frame.height) / 2
        )
        label.autoresizingMask = [.minXMargin]

        topBar.addSubview(label)
        topBar.addSubview(toggle)

        return topBar
    }

    private func setUpEditView(in body: NSView) {
        let scrollView = NSScrollView(frame: body.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 20)
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
        textView.textContainerInset = NSSize(width: 32, height: 24)
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
                MarkdownRenderer.render(textView.string)
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
    }

    @objc func textDidChange(_ notification: Notification) {
        if let textView = notification.object as? NSTextView {
            defaults.set(textView.string, forKey: key)
            defaults.synchronize()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        defaults.set(textView.string, forKey: key)
        defaults.synchronize()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
