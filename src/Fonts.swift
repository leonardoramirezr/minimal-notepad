import AppKit
import CoreText

enum PlexSerif {
    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let name: String
        switch (bold, italic) {
        case (true, true): name = "IBMPlexSerif-BoldItalic"
        case (true, false): name = "IBMPlexSerif-Bold"
        case (false, true): name = "IBMPlexSerif-Italic"
        case (false, false): name = "IBMPlexSerif-Regular"
        }
        if let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
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
