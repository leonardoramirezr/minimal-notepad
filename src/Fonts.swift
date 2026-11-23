import AppKit
import CoreText

/// The bundled typeface the Markdown preview and LLM answers are set in.
enum Typeface: String, CaseIterable {
    case serif
    case sans

    var displayName: String {
        switch self {
        case .serif: return "IBM Plex Serif"
        case .sans: return "IBM Plex Sans"
        }
    }

    func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        if let font = NSFont(name: postScriptName(bold: bold, italic: italic), size: size) {
            return font
        }
        switch self {
        case .serif:
            return NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
        case .sans:
            let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            guard italic else { return base }
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        }
    }

    private func postScriptName(bold: Bool, italic: Bool) -> String {
        let family: String
        switch self {
        case .serif: family = "IBMPlexSerif"
        case .sans: family = "IBMPlexSans"
        }
        switch (bold, italic) {
        case (true, true): return "\(family)-BoldItalic"
        case (true, false): return "\(family)-Bold"
        case (false, true): return "\(family)-Italic"
        // IBM Plex Sans names its regular face without a style suffix.
        case (false, false): return self == .sans ? family : "\(family)-Regular"
        }
    }
}

func registerBundledFonts() {
    guard let fontsURL = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
          let files = try? FileManager.default.contentsOfDirectory(
            at: fontsURL,
            includingPropertiesForKeys: nil
          )
    else { return }

    for url in files where url.pathExtension.lowercased() == "ttf" {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
