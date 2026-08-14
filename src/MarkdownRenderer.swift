import AppKit

enum MarkdownRenderer {
    static func render(_ markdown: String, baseSize: CGFloat = 15) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let text = paragraphBuffer.joined(separator: " ")
            paragraphBuffer.removeAll()
            appendParagraph(text, to: result, baseSize: baseSize)
        }

        while i < lines.count {
            let rawLine = lines[i]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                appendHorizontalRule(to: result)
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1
                appendCodeBlock(codeLines.joined(separator: "\n"), to: result, baseSize: baseSize)
                continue
            }

            if let level = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                appendHeading(text, level: level, to: result, baseSize: baseSize)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoteLines.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                appendBlockquote(quoteLines.joined(separator: " "), to: result, baseSize: baseSize)
                continue
            }

            if let firstItem = unorderedListItem(trimmed) {
                flushParagraph()
                var items = [firstItem]
                i += 1
                while i < lines.count, let item = unorderedListItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    i += 1
                }
                appendUnorderedList(items, to: result, baseSize: baseSize)
                continue
            }

            if let firstItem = orderedListItem(trimmed) {
                flushParagraph()
                var items = [firstItem]
                i += 1
                while i < lines.count, let item = orderedListItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    i += 1
                }
                appendOrderedList(items, to: result, baseSize: baseSize)
                continue
            }

            paragraphBuffer.append(trimmed)
            i += 1
        }
        flushParagraph()

        return result
    }

    // MARK: - Block detection

    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let afterHashes = line.index(line.startIndex, offsetBy: level)
        guard afterHashes < line.endIndex, line[afterHashes] == " " else { return nil }
        return level
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        let chars = Set(compact)
        guard chars.count == 1, let c = chars.first else { return false }
        return c == "-" || c == "*" || c == "_"
    }

    private static func unorderedListItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] {
            if line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
        }
        return nil
    }

    private static func orderedListItem(_ line: String) -> (Int, String)? {
        guard let dotRange = line.range(of: ". ") else { return nil }
        let numberPart = line[line.startIndex..<dotRange.lowerBound]
        guard !numberPart.isEmpty, numberPart.allSatisfy(\.isNumber), let number = Int(numberPart) else {
            return nil
        }
        return (number, String(line[dotRange.upperBound...]))
    }

    // MARK: - Block rendering

    private static func appendParagraph(_ text: String, to result: NSMutableAttributedString, baseSize: CGFloat) {
        let font = PlexSerif.font(size: baseSize)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = baseSize * 0.9

        let attr = inlineAttributedString(text, font: font, color: .textColor)
        attr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attr.length))
        result.append(attr)
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendHeading(_ text: String, level: Int, to result: NSMutableAttributedString, baseSize: CGFloat) {
        let sizes: [Int: CGFloat] = [1: 28, 2: 24, 3: 20, 4: 17, 5: 15, 6: 14]
        let size = sizes[level] ?? baseSize
        let font = PlexSerif.font(size: size, bold: true)

        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = level == 1 ? 4 : baseSize * 0.8
        style.paragraphSpacing = baseSize * 0.5

        let attr = inlineAttributedString(text, font: font, color: .textColor)
        attr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attr.length))
        result.append(attr)
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendBlockquote(_ text: String, to result: NSMutableAttributedString, baseSize: CGFloat) {
        let font = PlexSerif.font(size: baseSize, italic: true)
        let style = NSMutableParagraphStyle()
        style.headIndent = 20
        style.firstLineHeadIndent = 20
        style.paragraphSpacingBefore = baseSize * 0.4
        style.paragraphSpacing = baseSize * 0.8

        let attr = inlineAttributedString(text, font: font, color: .secondaryLabelColor)
        attr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attr.length))
        result.append(attr)
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendCodeBlock(_ code: String, to result: NSMutableAttributedString, baseSize: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.headIndent = 16
        style.firstLineHeadIndent = 16
        style.paragraphSpacingBefore = baseSize * 0.4
        style.paragraphSpacing = baseSize * 0.8

        let attr = NSAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .backgroundColor: NSColor.textColor.withAlphaComponent(0.06),
            .paragraphStyle: style
        ])
        result.append(attr)
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendHorizontalRule(to result: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 10
        style.paragraphSpacing = 10
        let line = NSAttributedString(
            string: String(repeating: "—", count: 40) + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.separatorColor,
                .paragraphStyle: style
            ]
        )
        result.append(line)
    }

    private static func appendUnorderedList(_ items: [String], to result: NSMutableAttributedString, baseSize: CGFloat) {
        let font = PlexSerif.font(size: baseSize)
        for item in items {
            let style = NSMutableParagraphStyle()
            style.headIndent = 20
            style.firstLineHeadIndent = 0
            style.paragraphSpacing = baseSize * 0.3

            let line = NSMutableAttributedString(
                string: "\u{2022}  ",
                attributes: [.font: font, .foregroundColor: NSColor.textColor]
            )
            line.append(inlineAttributedString(item, font: font, color: .textColor))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            result.append(line)
            result.append(NSAttributedString(string: "\n"))
        }
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendOrderedList(_ items: [(Int, String)], to result: NSMutableAttributedString, baseSize: CGFloat) {
        let font = PlexSerif.font(size: baseSize)
        for (number, text) in items {
            let style = NSMutableParagraphStyle()
            style.headIndent = 24
            style.firstLineHeadIndent = 0
            style.paragraphSpacing = baseSize * 0.3

            let line = NSMutableAttributedString(
                string: "\(number).  ",
                attributes: [.font: font, .foregroundColor: NSColor.textColor]
            )
            line.append(inlineAttributedString(text, font: font, color: .textColor))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            result.append(line)
            result.append(NSAttributedString(string: "\n"))
        }
        result.append(NSAttributedString(string: "\n"))
    }

    // MARK: - Inline rendering

    private static let inlineRegex = try? NSRegularExpression(
        pattern: "(?<code>`[^`]+`)"
            + "|(?<boldItalic>\\*\\*\\*[^*]+\\*\\*\\*)"
            + "|(?<bold>\\*\\*[^*]+\\*\\*|__[^_]+__)"
            + "|(?<italic>\\*[^*]+\\*|_[^_]+_)"
            + "|(?<link>\\[[^\\]]+\\]\\([^)]+\\))"
    )

    private static let linkPartsRegex = try? NSRegularExpression(pattern: "^\\[(.*)\\]\\((.*)\\)$")

    private static func inlineAttributedString(_ text: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        guard let regex = inlineRegex else {
            return NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }

        let nsText = text as NSString
        var lastIndex = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        func appendPlain(_ range: NSRange) {
            guard range.length > 0 else { return }
            result.append(NSAttributedString(
                string: nsText.substring(with: range),
                attributes: [.font: font, .foregroundColor: color]
            ))
        }

        for match in matches {
            appendPlain(NSRange(location: lastIndex, length: match.range.location - lastIndex))

            if let r = Range(match.range(withName: "code"), in: text) {
                let content = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                let codeFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                result.append(NSAttributedString(string: content, attributes: [
                    .font: codeFont,
                    .foregroundColor: color,
                    .backgroundColor: NSColor.textColor.withAlphaComponent(0.08)
                ]))
            } else if let r = Range(match.range(withName: "boldItalic"), in: text) {
                let content = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                result.append(NSAttributedString(string: content, attributes: [
                    .font: PlexSerif.font(size: font.pointSize, bold: true, italic: true),
                    .foregroundColor: color
                ]))
            } else if let r = Range(match.range(withName: "bold"), in: text) {
                let content = String(String(text[r]).dropFirst(2).dropLast(2))
                result.append(NSAttributedString(string: content, attributes: [
                    .font: PlexSerif.font(size: font.pointSize, bold: true),
                    .foregroundColor: color
                ]))
            } else if let r = Range(match.range(withName: "italic"), in: text) {
                let content = String(String(text[r]).dropFirst(1).dropLast(1))
                result.append(NSAttributedString(string: content, attributes: [
                    .font: PlexSerif.font(size: font.pointSize, italic: true),
                    .foregroundColor: color
                ]))
            } else if let r = Range(match.range(withName: "link"), in: text) {
                let raw = String(text[r])
                if let linkRegex = linkPartsRegex,
                   let m = linkRegex.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)),
                   let textRange = Range(m.range(at: 1), in: raw),
                   let urlRange = Range(m.range(at: 2), in: raw) {
                    let linkText = String(raw[textRange])
                    let urlString = String(raw[urlRange])
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                    if let url = URL(string: urlString) {
                        attrs[.link] = url
                    }
                    result.append(NSAttributedString(string: linkText, attributes: attrs))
                } else {
                    appendPlain(match.range)
                }
            }

            lastIndex = match.range.location + match.range.length
        }

        appendPlain(NSRange(location: lastIndex, length: nsText.length - lastIndex))

        if result.length == 0 {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }

        return result
    }
}
