import AppKit

final class SettingsWindowController: NSWindowController {
    static let minFontSize: CGFloat = 10
    static let maxFontSize: CGFloat = 32
    static let defaultFontSize: CGFloat = 14

    private var slider: NSSlider!
    private var valueLabel: NSTextField!

    /// Called continuously while the slider moves, with the rounded font size.
    var onFontSizeChange: ((CGFloat) -> Void)?

    convenience init(fontSize: CGFloat) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 132),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent(fontSize: fontSize)
    }

    private func buildContent(fontSize: CGFloat) {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Font size")
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.frame = NSRect(x: 20, y: 92, width: 200, height: 18)
        contentView.addSubview(title)

        let value = NSTextField(labelWithString: "")
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: 220, y: 93, width: 120, height: 16)
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
        slider.frame = NSRect(x: 20, y: 52, width: 320, height: 20)
        contentView.addSubview(slider)
        self.slider = slider

        let hint = NSTextField(labelWithString: "Applies to the editor, the preview and LLM answers.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 20, width: 320, height: 15)
        contentView.addSubview(hint)

        showFontSize(fontSize)
    }

    /// Syncs the controls with the size currently in use.
    func showFontSize(_ size: CGFloat) {
        slider?.doubleValue = Double(size)
        valueLabel?.stringValue = "\(Int(size.rounded())) pt"
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let size = CGFloat(sender.doubleValue.rounded())
        valueLabel.stringValue = "\(Int(size)) pt"
        onFontSizeChange?(size)
    }
}
