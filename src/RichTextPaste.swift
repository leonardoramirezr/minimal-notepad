import AppKit

/// Reads the rich text on a pasteboard (from a browser, Word, Google Docs, Pages, Notes…)
/// as Markdown.
@MainActor
enum RichTextPaste {
    private static let webArchiveTypes = [
        NSPasteboard.PasteboardType("com.apple.webarchive"),
        NSPasteboard.PasteboardType("Apple Web Archive pasteboard type"),
    ]

    /// The Markdown for the rich text on `pasteboard`, or nil when it's better pasted as plain
    /// text: there's no rich text, it has no formatting Markdown can express, or it's all code.
    static func markdown(from pasteboard: NSPasteboard) -> String? {
        let types = pasteboard.types ?? []
        let hasRTF = types.contains(.rtfd) || types.contains(.rtf)

        if types.contains(.html), let data = pasteboard.data(forType: .html), let html = decodeHTML(data),
           // AppKit's own HTML (from TextEdit, Notes…) loses the font sizes that make headings;
           // its RTF keeps them.
           !(hasRTF && html.prefix(2048).contains("Cocoa HTML Writer")) {
            return MarkdownConverter.markdown(fromHTML: html)
        }
        for type in webArchiveTypes where types.contains(type) {
            if let data = pasteboard.data(forType: type), let archive = webArchive(data) {
                return MarkdownConverter.markdown(fromHTML: archive.html, baseURL: archive.url)
            }
        }
        if let text = attributedString(from: pasteboard, types: types) {
            return RichTextDocument.markdown(from: paragraphs(of: text))
        }
        return nil
    }

    // MARK: - HTML

    /// Safari and Mail put the copied HTML in a web archive.
    private static func webArchive(_ data: Data) -> (html: String, url: URL?)? {
        guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let resource = archive["WebMainResource"] as? [String: Any],
              (resource["WebResourceMIMEType"] as? String)?.contains("html") ?? true,
              let content = resource["WebResourceData"] as? Data,
              let html = decodeHTML(content, encodingName: resource["WebResourceTextEncodingName"] as? String)
        else { return nil }
        return (html, (resource["WebResourceURL"] as? String).flatMap(URL.init(string:)))
    }

    /// Pasteboard HTML is almost always UTF-8, but nothing guarantees it.
    private static func decodeHTML(_ data: Data, encodingName: String? = nil) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        // UTF-16 without a byte order mark: every other byte of ASCII markup is zero.
        if bytes.count >= 2, bytes[0] == 0 || bytes[1] == 0 {
            return String(data: data, encoding: bytes[0] == 0 ? .utf16BigEndian : .utf16LittleEndian)
        }
        if let html = String(data: data, encoding: .utf8) {
            return html
        }
        if let name = encodingName ?? declaredCharset(in: data) {
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let html = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return html
            }
        }
        return String(data: data, encoding: .windowsCP1252)
    }

    /// The charset in `<meta charset="…">` or `<meta content="text/html; charset=…">`.
    private static func declaredCharset(in data: Data) -> String? {
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        guard let range = head.range(of: "charset=") else { return nil }
        let name = head[range.upperBound...]
            .drop(while: { $0 == "\"" || $0 == "'" })
            .prefix(while: { $0.isLetter || $0.isNumber || "-_.:".contains($0) })
        return name.isEmpty ? nil : String(name)
    }

    // MARK: - Rich text

    private static func attributedString(
        from pasteboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> NSAttributedString? {
        if types.contains(.rtfd), let data = pasteboard.data(forType: .rtfd),
           let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
            return text
        }
        if types.contains(.rtf), let data = pasteboard.data(forType: .rtf),
           let text = NSAttributedString(rtf: data, documentAttributes: nil) {
            return text
        }
        return nil
    }

    /// TextEdit and others write a list item's marker into the text: "\t•\tItem".
    private static let listMarker = try? NSRegularExpression(pattern: "^\\t?[^\\t\\n]{1,12}\\t")

    private static func paragraphs(of text: NSAttributedString) -> [RichTextParagraph] {
        let string = text.string as NSString
        var paragraphs: [RichTextParagraph] = []
        var tables: [ObjectIdentifier: Int] = [:]

        var location = 0
        while location < string.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            location = end

            var paragraph = RichTextParagraph()
            var contentStart = start
            if let style = text.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle {
                paragraph.lists = style.textLists.map { list(from: $0) }
                if let block = style.textBlocks.last as? NSTextTableBlock {
                    let id = ObjectIdentifier(block.table)
                    let table = tables[id] ?? tables.count
                    tables[id] = table
                    paragraph.tableCell = .init(table: table, row: block.startingRow, column: block.startingColumn)
                }
                if !paragraph.lists.isEmpty, let listMarker {
                    let range = NSRange(location: start, length: contentsEnd - start)
                    contentStart += listMarker.firstMatch(in: text.string, range: range)?.range.length ?? 0
                }
            }

            var sizes: [CGFloat: Int] = [:]
            let contents = NSRange(location: contentStart, length: contentsEnd - contentStart)
            text.enumerateAttributes(in: contents, options: []) { attributes, range, _ in
                let font = attributes[.font] as? NSFont
                sizes[font?.pointSize ?? 12, default: 0] += range.length
                paragraph.runs.append(run(string.substring(with: range), attributes: attributes, font: font))
            }
            let font = text.attribute(.font, at: start, effectiveRange: nil) as? NSFont
            let size = sizes.max { $0.value < $1.value }?.key ?? font?.pointSize ?? 12
            paragraph.fontSize = Double(size)
            paragraphs.append(paragraph)
        }
        return paragraphs
    }

    private static func list(from list: NSTextList) -> RichTextParagraph.List {
        let format = list.markerFormat.rawValue
        let isOrdered = ["decimal", "octal", "hexadecimal", "alpha", "latin", "roman"]
            .contains { format.lowercased().contains($0) }
        return .init(isOrdered: isOrdered, format: format, startingNumber: list.startingItemNumber)
    }

    private static func run(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        font: NSFont?
    ) -> RichTextParagraph.Run {
        // Attachments, such as images in RTFD, have no text.
        var run = RichTextParagraph.Run(text: text.replacingOccurrences(of: "\u{FFFC}", with: ""))
        if let font {
            let traits = font.fontDescriptor.symbolicTraits
            run.isBold = traits.contains(.bold)
            run.isItalic = traits.contains(.italic)
            run.isMonospaced = traits.contains(.monoSpace) || MarkdownConverter.isMonospaceFamily(font.familyName ?? "")
        }
        run.isStrikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        if let url = attributes[.link] as? URL {
            run.link = url.absoluteString
        } else if let link = attributes[.link] as? String {
            run.link = link
        }
        return run
    }
}
