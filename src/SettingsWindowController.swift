import AppKit

final class SettingsWindowController: NSWindowController {
    static let minFontSize: CGFloat = 10
    static let maxFontSize: CGFloat = 32
    static let defaultFontSize: CGFloat = 14

    private var slider: NSSlider!
    private var valueLabel: NSTextField!
    private var typefacePopUp: NSPopUpButton!

    /// Called continuously while the slider moves, with the rounded font size.
    var onFontSizeChange: ((CGFloat) -> Void)?

    /// Called when a different typeface is picked for rendered Markdown.
    var onTypefaceChange: ((Typeface) -> Void)?

    convenience init(fontSize: CGFloat, typeface: Typeface) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 204),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent(fontSize: fontSize, typeface: typeface)
    }

    private func buildContent(fontSize: CGFloat, typeface: Typeface) {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Font size")
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.frame = NSRect(x: 20, y: 164, width: 200, height: 18)
        contentView.addSubview(title)

        let value = NSTextField(labelWithString: "")
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: 220, y: 165, width: 120, height: 16)
        contentView.addSubview(value)
        self.valueLabel = value

        let slider = NSSlider(
            value: Double(fontSize),
            minValue: Double(Self.minFontSize),
            maxValue: Double(Self.maxFontSize),
            target: self,
            action: #selector(sliderChanged(_:))
        )
        slider.isContinuous = true
        slider.numberOfTickMarks = Int(Self.maxFontSize - Self.minFontSize) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.frame = NSRect(x: 20, y: 124, width: 320, height: 20)
        contentView.addSubview(slider)
        self.slider = slider

        let hint = NSTextField(labelWithString: "Applies to the editor, the preview and LLM answers.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 92, width: 320, height: 15)
        contentView.addSubview(hint)

        let typefaceTitle = NSTextField(labelWithString: "Markdown font")
        typefaceTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        typefaceTitle.frame = NSRect(x: 20, y: 52, width: 140, height: 18)
        contentView.addSubview(typefaceTitle)

        let popUp = NSPopUpButton(frame: NSRect(x: 160, y: 47, width: 182, height: 25), pullsDown: false)
        for option in Typeface.allCases {
            popUp.addItem(withTitle: option.displayName)
            popUp.lastItem?.representedObject = option.rawValue
        }
        popUp.target = self
        popUp.action = #selector(typefaceChanged(_:))
        contentView.addSubview(popUp)
        self.typefacePopUp = popUp

        let typefaceHint = NSTextField(labelWithString: "Used by the Markdown preview and LLM answers.")
        typefaceHint.font = NSFont.systemFont(ofSize: 11)
        typefaceHint.textColor = .secondaryLabelColor
        typefaceHint.frame = NSRect(x: 20, y: 20, width: 320, height: 15)
        contentView.addSubview(typefaceHint)

        showFontSize(fontSize)
        showTypeface(typeface)
    }

    /// Syncs the controls with the size currently in use.
    func showFontSize(_ size: CGFloat) {
        slider?.doubleValue = Double(size)
        valueLabel?.stringValue = "\(Int(size.rounded())) pt"
    }

    /// Syncs the pop-up with the typeface currently in use.
    func showTypeface(_ typeface: Typeface) {
        typefacePopUp?.selectItem(at: Typeface.allCases.firstIndex(of: typeface) ?? 0)
    }

    @objc private func typefaceChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let typeface = Typeface(rawValue: raw)
        else { return }
        onTypefaceChange?(typeface)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let size = CGFloat(sender.doubleValue.rounded())
        valueLabel.stringValue = "\(Int(size)) pt"
        onFontSizeChange?(size)
    }
}
