import Foundation

/// Translates rich text, as an HTML tree, into the Markdown someone would have typed for it:
/// headings, bold, italic, strikethrough, code, links, images, lists, quotes, code blocks,
/// tables and rules.
///
/// Line structure follows what the text looks like, as a browser's plain text does:
/// paragraphs are separated by a blank line, lines in `<div>`s and `<br>`s by a newline.
enum MarkdownConverter {
    /// The Markdown for `html`, or nil when plain text says it just as well: there's no
    /// formatting Markdown can express, or everything is code (from an editor or a terminal),
    /// which reads best as it is.
    static func markdown(fromHTML html: String, baseURL: URL? = nil) -> String? {
        var html = Substring(html)
        // The Windows clipboard format starts with a header of offsets: "Version:0.9 StartHTML:…".
        if html.hasPrefix("Version:"), let start = html.firstIndex(of: "<") {
            html = html[start...]
        }
        return markdown(from: HTMLParser.parse(String(html)), baseURL: baseURL)
    }

    static func markdown(from document: HTMLNode, baseURL: URL? = nil) -> String? {
        let converter = Converter(baseURL: baseURL ?? Self.baseURL(in: document))
        converter.convertChildren(of: document, Context())
        let writer = converter.writer
        let lines = writer.finish()
        guard writer.addedMarkup, writer.hasTextOutsideCode, !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Whether a font family (a CSS `font-family` list, or a font's family name) is fixed-width.
    static func isMonospaceFamily(_ family: String) -> Bool {
        let name = family.lowercased()
        guard !name.includes("monotype"), !name.includes("monoton") else { return false }
        return ["mono", "courier", "menlo", "monaco", "consolas", "inconsolata", "lucida console",
                "source code", "fira code", "cascadia code", "iosevka", "typewriter"]
            .contains { name.includes($0) }
    }

    private static func baseURL(in node: HTMLNode) -> URL? {
        if node.name == "base", let href = node["href"], let url = URL(string: href), url.scheme != nil {
            return url
        }
        for child in node.children where !child.isText {
            if let url = baseURL(in: child) { return url }
        }
        return nil
    }
}

// MARK: - Inline content

private struct InlineStyle: Equatable {
    var bold = false
    var italic = false
    var strikethrough = false
    var code = false
    var link: String?
}

private struct Run {
    var text: String
    var style: InlineStyle
}

private enum InlineMarkdown {
    private static let spaces: Set<Character> = [" ", "\t", "\u{00A0}"]

    /// Nests the delimiters as link › bold › italic › strikethrough › code, so bold text with an
    /// italic word in it comes out as one bold span (`**a *b* c**`) rather than three.
    static func serialize(_ runs: ArraySlice<Run>, level: Int = 0) -> String {
        guard level <= 4 else { return runs.map(\.text).joined() }
        var result = ""
        var start = runs.startIndex
        while start < runs.endIndex {
            let value = key(of: runs[start].style, level: level)
            var end = runs.index(after: start)
            while end < runs.endIndex, key(of: runs[end].style, level: level) == value {
                end = runs.index(after: end)
            }
            let inner = serialize(runs[start..<end], level: level + 1)
            result += value.map { wrap(inner, level: level, value: $0) } ?? inner
            start = end
        }
        return result
    }

    private static func key(of style: InlineStyle, level: Int) -> String? {
        switch level {
        case 0: return style.link
        case 1: return style.bold ? "" : nil
        case 2: return style.italic ? "" : nil
        case 3: return style.strikethrough ? "" : nil
        default: return style.code ? "" : nil
        }
    }

    /// Delimiters go around the text itself: Markdown doesn't allow `** bold**`.
    private static func wrap(_ inner: String, level: Int, value: String) -> String {
        let leading = inner.prefix(while: { spaces.contains($0) })
        let rest = inner.dropFirst(leading.count)
        let trailingCount = rest.reversed().prefix(while: { spaces.contains($0) }).count
        let core = String(rest.dropLast(trailingCount))
        guard !core.isEmpty else { return inner }

        let wrapped: String
        switch level {
        case 0: wrapped = link(core, url: value)
        case 1: wrapped = "**" + core + "**"
        case 2: wrapped = "*" + core + "*"
        case 3: wrapped = "~~" + core + "~~"
        default: wrapped = codeSpan(core)
        }
        return leading + wrapped + String(rest.suffix(trailingCount))
    }

    private static func link(_ text: String, url: String) -> String {
        // A link that shows its own address reads best as the address alone.
        if text == url || text + "/" == url || "mailto:" + text == url {
            return text
        }
        return "[\(text)](\(url))"
    }

    private static func codeSpan(_ code: String) -> String {
        let fence = String(repeating: "`", count: longestRun(of: "`", in: code) + 1)
        let padding = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
        return fence + padding + code + padding + fence
    }

    static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0
        var current = 0
        for ch in text {
            current = ch == character ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}

// MARK: - Writer

/// Collects the Markdown line by line: inline text accumulates as runs until a block ends,
/// and every line gets the prefixes of the blocks it's in (`> ` for quotes, indentation and
/// the marker for list items).
private final class MarkdownWriter {
    private static let bullets: Set<Character> = ["•", "◦", "▪", "▫", "‣", "⁃", "●", "○", "■", "□", "·"]

    private(set) var lines: [String] = []
    private var runs: [Run] = []
    /// Line breaks owed before the next line: 1 starts a new line, 2 leaves a blank one.
    private var pendingBreaks = 0
    private var prefixes: [String] = []
    private var lastPrefixes: [String] = []
    /// The marker of a list item whose first line hasn't been written yet, and the prefix it replaces.
    private var marker: (text: String, level: Int)?

    private(set) var addedMarkup = false
    private(set) var hasTextOutsideCode = false

    func absorb(_ other: MarkdownWriter) {
        addedMarkup = addedMarkup || other.addedMarkup
        hasTextOutsideCode = hasTextOutsideCode || other.hasTextOutsideCode
    }

    func noteContent(markup: Bool = true) {
        if markup { addedMarkup = true }
        hasTextOutsideCode = true
    }

    func text(_ text: String, style: InlineStyle, collapsesSpaces: Bool) {
        var text = text
        // Collapsed whitespace never starts a line or doubles a space.
        if collapsesSpaces, text.first == " ",
           runs.last.map({ $0.text.last == " " || $0.text.last == "\n" }) ?? true {
            text.removeFirst()
        }
        guard !text.isEmpty else { return }
        if text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) {
            if !style.code { hasTextOutsideCode = true }
            if style != InlineStyle() { addedMarkup = true }
        }
        if let last = runs.last, last.style == style {
            runs[runs.count - 1].text += text
        } else {
            runs.append(Run(text: text, style: style))
        }
    }

    func lineBreak() {
        text("\n", style: InlineStyle(), collapsesSpaces: false)
    }

    /// Ends the current block and asks for at least `breaks` line breaks before the next one.
    func boundary(_ breaks: Int) {
        flush()
        pendingBreaks = max(pendingBreaks, breaks)
    }

    func pushPrefix(_ prefix: String) {
        flush()
        prefixes.append(prefix)
    }

    func popPrefix() {
        flush()
        prefixes.removeLast()
    }

    func startItem(_ text: String) {
        flush()
        // The enclosing item had no text of its own before this nested one.
        if marker != nil {
            emit([""], verbatim: true)
        }
        marker = (text, prefixes.count)
        prefixes.append(String(repeating: " ", count: text.count))
    }

    func endItem() {
        flush()
        prefixes.removeLast()
        // An item that never had any text is dropped.
        if let item = marker, item.level >= prefixes.count {
            marker = nil
        }
    }

    /// Writes lines as they are: headings, code blocks, tables, rules.
    func block(_ blockLines: [String], breaks: Int) {
        boundary(breaks)
        emit(blockLines, verbatim: true)
        pendingBreaks = breaks
        addedMarkup = true
    }

    func finish() -> [String] {
        flush()
        return lines
    }

    private func flush() {
        guard !runs.isEmpty else { return }
        let serialized = InlineMarkdown.serialize(runs[...])
            .replacingScalars(["\u{00A0}": " ", "\u{200B}": "", "\u{FEFF}": ""])
        runs.removeAll()

        var content = serialized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.trimmingTrailingSpaces(String($0)) }
        let leading = content.prefix(while: \.isEmpty).count
        guard leading < content.count else {
            // A block with nothing but line breaks, such as `<div><br></div>`, is an empty line.
            pendingBreaks = max(pendingBreaks, 1) + content.count - 1
            return
        }
        let trailing = content.reversed().prefix(while: \.isEmpty).count
        content = Array(content[leading..<(content.count - trailing)])
        if leading > 0 {
            pendingBreaks = max(pendingBreaks, 1) + leading
        }
        emit(content, verbatim: false)
        // A block's last line break doesn't show; any before it leave empty lines.
        if trailing > 1 {
            pendingBreaks = trailing
        }
    }

    private func emit(_ newLines: [String], verbatim: Bool) {
        if !lines.isEmpty {
            let blankLines = min(max(pendingBreaks, 1), 2) - 1
            if blankLines > 0 {
                // A blank line between two paragraphs of a quote stays in the quote.
                let shared = zip(lastPrefixes, prefixes).prefix(while: { $0 == $1 }).map(\.0)
                let blank = Self.trimmingTrailingSpaces(shared.joined())
                lines.append(contentsOf: repeatElement(blank, count: blankLines))
            }
        }
        pendingBreaks = 0

        for (index, text) in newLines.enumerated() {
            var line = text
            var prefix = prefixes.joined()
            if index == 0, let item = marker {
                prefix = prefixes[..<item.level].joined() + item.text
                marker = nil
                noteContent()
            } else if !verbatim, let bulleted = Self.replacingBullet(in: line) {
                line = bulleted
                noteContent()
            }
            lines.append(line.isEmpty ? Self.trimmingTrailingSpaces(prefix) : prefix + line)
        }
        if prefixes.contains(where: { $0.hasPrefix(">") }) {
            noteContent()
        }
        lastPrefixes = prefixes
    }

    /// A line that starts with a bullet character, as in text copied from a list rendered as
    /// plain paragraphs, becomes a Markdown list item.
    private static func replacingBullet(in line: String) -> String? {
        guard let first = line.first, bullets.contains(first) else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let item = rest.drop(while: { $0 == " " || $0 == "\t" })
        return item.isEmpty ? nil : "- " + item
    }

    static func trimmingTrailingSpaces(_ text: String) -> String {
        var text = text
        while let last = text.last, last == " " || last == "\t" {
            text.removeLast()
        }
        return text
    }
}

// MARK: - Converter

private struct Context {
    var style = InlineStyle()
    /// Whether `style.code` comes from an element such as `<code>` rather than from a font.
    var codeFromElement = false
    var collapsesSpaces = true
    var keepsNewlines = false
    /// Headings and header cells are bold already, so bold inside them adds nothing.
    var boldIsImplicit = false
    var inListItem = false
    var codeLanguage: String?
}

private struct ListState {
    var ordered: Bool
    var next: Int
    var markerWidth: Int
}

private final class Converter {
    /// Elements that never hold content worth pasting.
    private static let ignoredElements: Set<String> = [
        "audio", "base", "button", "canvas", "col", "colgroup", "datalist", "embed", "head",
        "iframe", "link", "map", "math", "meta", "noscript", "object", "option", "script",
        "select", "style", "svg", "template", "textarea", "title", "video", "xml",
    ]
    /// Elements that start a new line, but have no Markdown of their own.
    private static let blockElements: Set<String> = [
        "address", "article", "aside", "caption", "center", "details", "dialog", "div", "dl", "dd",
        "dt", "fieldset", "figcaption", "figure", "footer", "form", "header", "hgroup", "legend",
        "main", "nav", "p", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th",
        "thead", "tr",
    ]
    private static let markdownBlocks: Set<String> = [
        "blockquote", "dir", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "li", "listing", "menu",
        "ol", "pre", "ul", "xmp",
    ]
    private static let blockDisplays: Set<String> = [
        "block", "flex", "flow-root", "grid", "list-item", "table", "table-cell", "table-row",
    ]
    private static let inlineDisplays: Set<String> = [
        "contents", "inline", "inline-block", "inline-flex", "inline-grid", "inline-table",
    ]
    /// Content that makes a table a layout grid (as in emails) rather than data.
    private static let layoutContent: Set<String> = [
        "blockquote", "dl", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "li", "ol", "pre", "table", "ul",
    ]

    let writer = MarkdownWriter()
    private var lists: [ListState] = []
    private let baseURL: URL?

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func convertChildren(of node: HTMLNode, _ context: Context) {
        let children = node.children
        for (index, child) in children.enumerated() {
            // Whitespace that only lays out the markup, between blocks.
            if child.isText, child.text.unicodeScalars.contains("\n"), child.text.allSatisfy(\.isWhitespace),
               (index > 0 && Self.isStructural(children[index - 1]))
                || (index + 1 < children.count && Self.isStructural(children[index + 1])) {
                continue
            }
            convert(child, context, parent: node)
        }
    }

    private static func isStructural(_ node: HTMLNode) -> Bool {
        !node.isText && (blockElements.contains(node.name) || markdownBlocks.contains(node.name))
    }

    private func convert(_ node: HTMLNode, _ context: Context, parent: HTMLNode) {
        if node.isText {
            addText(node.text, context)
            return
        }
        let name = node.name
        guard !Self.ignoredElements.contains(name) else { return }
        let css = Self.declarations(node["style"])
        // Word's own list markers (`mso-list: Ignore`) are replaced by Markdown ones.
        if css["display"] == "none" || css["mso-list"] == "ignore"
            || node["hidden"] != nil || node["aria-hidden"] == "true" {
            return
        }

        var context = context
        applyStyle(of: node, css: css, to: &context)

        switch name {
        case "br":
            writer.lineBreak()
        case "img":
            image(node, context)
        case "input":
            checkbox(node, context)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            heading(node, level: Int(String(name.dropFirst())) ?? 1, context)
        case "ul", "ol", "menu", "dir":
            list(node, ordered: name == "ol", context, parent: parent)
        case "li":
            listItem(node, context)
        case "blockquote":
            blockquote(node, context)
        case "pre", "xmp", "listing":
            codeBlock(node, context)
        case "hr":
            writer.block(["---"], breaks: blockBreaks(context))
            writer.noteContent()
        case "table":
            table(node, context)
        default:
            if let level = Self.wordListLevel(css) {
                wordListItem(node, level: level, context)
                return
            }
            let display = css["display"]
            let isBlock = display.flatMap { display in
                Self.blockDisplays.contains(display) ? true : Self.inlineDisplays.contains(display) ? false : nil
            } ?? Self.blockElements.contains(name)
            guard isBlock else {
                convertChildren(of: node, context)
                return
            }
            if !context.collapsesSpaces, context.style.code {
                // Preformatted, fixed-width text, as code editors put on the pasteboard.
                codeBlock(node, context)
            } else if name == "p", node["class"]?.includes("MsoTitle") == true {
                heading(node, level: 1, context)
            } else {
                let breaks = name == "p" ? blockBreaks(context) : 1
                writer.boundary(breaks)
                convertChildren(of: node, context)
                writer.boundary(breaks)
            }
        }
    }

    /// Markdown blocks are set apart by a blank line, except inside list items, where it
    /// would make the list loose.
    private func blockBreaks(_ context: Context) -> Int {
        context.inListItem ? 1 : 2
    }

    // MARK: Text

    private func addText(_ raw: String, _ context: Context) {
        var text = raw.normalizingNewlines
        if context.collapsesSpaces {
            text = Self.collapsingWhitespace(text, keepingNewlines: context.keepsNewlines)
        }
        guard context.keepsNewlines else {
            writer.text(text, style: context.style, collapsesSpaces: context.collapsesSpaces)
            return
        }
        for (index, part) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { writer.lineBreak() }
            writer.text(String(part), style: context.style, collapsesSpaces: context.collapsesSpaces)
        }
    }

    private static func collapsingWhitespace(_ text: String, keepingNewlines: Bool) -> String {
        var result = String.UnicodeScalarView()
        var inWhitespace = false
        var newlines = 0
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\u{0C}" {
                inWhitespace = true
                if scalar == "\n" { newlines += 1 }
                continue
            }
            if inWhitespace {
                if keepingNewlines, newlines > 0 {
                    result.append(contentsOf: repeatElement("\n", count: newlines))
                } else {
                    result.append(" ")
                }
                inWhitespace = false
                newlines = 0
            }
            result.append(scalar)
        }
        if inWhitespace {
            result.append(contentsOf: keepingNewlines && newlines > 0 ? Array(repeating: "\n", count: newlines) : [" "])
        }
        return String(result)
    }

    private func applyStyle(of node: HTMLNode, css: [String: String], to context: inout Context) {
        switch node.name {
        case "b", "strong":
            context.style.bold = true
        case "i", "em", "cite", "dfn":
            context.style.italic = true
        case "s", "strike", "del":
            context.style.strikethrough = true
        case "code", "kbd", "samp", "tt":
            context.style.code = true
            context.codeFromElement = true
        case "a":
            if let href = node["href"], let url = linkURL(href) {
                context.style.link = url
            }
        case "font":
            if let face = node["face"], MarkdownConverter.isMonospaceFamily(face) {
                context.style.code = true
            }
        case "th":
            context.style.bold = true
        default:
            break
        }

        // Inline styles override the element: Google Docs wraps everything in `<b style="font-weight:normal">`.
        if let weight = css["font-weight"] {
            switch weight {
            case "bold", "bolder": context.style.bold = true
            case "normal", "lighter": context.style.bold = false
            default: if let value = Int(weight) { context.style.bold = value >= 600 }
            }
        }
        if let fontStyle = css["font-style"] {
            if fontStyle.hasPrefix("italic") || fontStyle.hasPrefix("oblique") {
                context.style.italic = true
            } else if fontStyle == "normal" {
                context.style.italic = false
            }
        }
        if [css["text-decoration"], css["text-decoration-line"]].contains(where: { $0?.includes("line-through") == true }) {
            context.style.strikethrough = true
        }
        if let family = css["font-family"],
           let first = family.split(separator: ",").first?.filter({ $0 != "\"" && $0 != "'" }).trimmed,
           !["", "inherit", "initial", "unset", "revert"].contains(first) {
            if MarkdownConverter.isMonospaceFamily(first) {
                context.style.code = true
            } else if !context.codeFromElement {
                context.style.code = false
            }
        }
        switch css["white-space"] {
        case "pre", "pre-wrap", "break-spaces":
            context.collapsesSpaces = false
            context.keepsNewlines = true
        case "pre-line":
            context.collapsesSpaces = true
            context.keepsNewlines = true
        case "normal", "nowrap":
            context.collapsesSpaces = true
            context.keepsNewlines = false
        default:
            break
        }

        if context.boldIsImplicit {
            context.style.bold = false
        }
        if let language = Self.codeLanguage(of: node) {
            context.codeLanguage = language
        }
    }

    // MARK: Inline elements

    private func image(_ node: HTMLNode, _ context: Context) {
        let alt = Self.collapsingWhitespace(node["alt"] ?? "", keepingNewlines: false).trimmed
        var style = context.style
        style.code = false
        if let src = node["src"], let url = resolvedURL(src), url.hasPrefix("http://") || url.hasPrefix("https://") {
            writer.text("![\(alt)](\(url))", style: style, collapsesSpaces: false)
            writer.noteContent()
        } else if !alt.isEmpty {
            writer.text(alt, style: style, collapsesSpaces: false)
        }
    }

    private func checkbox(_ node: HTMLNode, _ context: Context) {
        guard context.inListItem, node["type"]?.lowercased() == "checkbox" else { return }
        writer.text(node["checked"] != nil ? "[x] " : "[ ] ", style: InlineStyle(), collapsesSpaces: false)
        writer.noteContent()
    }

    private func linkURL(_ href: String) -> String? {
        let trimmed = href.trimmed
        let lowercased = trimmed.lowercased()
        // Links within the page, or to scripts, mean nothing outside it.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              !["javascript:", "vbscript:", "data:"].contains(where: { lowercased.hasPrefix($0) })
        else { return nil }
        return resolvedURL(trimmed)
    }

    private func resolvedURL(_ reference: String) -> String? {
        var url = reference.trimmed
        guard !url.isEmpty else { return nil }
        if let baseURL, let parsed = URL(string: url), parsed.scheme == nil,
           let absolute = URL(string: url, relativeTo: baseURL)?.absoluteURL {
            url = absolute.absoluteString
        }
        // Characters that would end the Markdown link early.
        return url.replacingScalars([
            "\n": "", "\r": "", "\t": "", " ": "%20", "(": "%28", ")": "%29", "<": "%3C", ">": "%3E",
        ])
    }

    // MARK: Blocks

    private func heading(_ node: HTMLNode, level: Int, _ context: Context) {
        var inner = context
        inner.boldIsImplicit = true
        inner.style.bold = false
        let text = renderLines(of: node, inner).joined(separator: " ")
        guard !text.isEmpty else { return }
        writer.block([String(repeating: "#", count: level) + " " + text], breaks: blockBreaks(context))
        writer.noteContent()
    }

    private func list(_ node: HTMLNode, ordered: Bool, _ context: Context, parent: HTMLNode) {
        let breaks = lists.isEmpty && !context.inListItem ? 2 : 1
        writer.boundary(breaks)
        // Google Docs nests a list directly in its parent list rather than in an item.
        let nestedInList = ["ul", "ol", "menu", "dir"].contains(parent.name)
        if nestedInList {
            writer.pushPrefix(String(repeating: " ", count: lists.last?.markerWidth ?? 2))
        }
        let start = node["start"].flatMap { Int($0.trimmed) } ?? 1
        lists.append(ListState(ordered: ordered, next: start, markerWidth: ordered ? 3 : 2))
        convertChildren(of: node, context)
        lists.removeLast()
        if nestedInList {
            writer.popPrefix()
        }
        writer.boundary(breaks)
    }

    private func listItem(_ node: HTMLNode, _ context: Context) {
        var marker = "- "
        if let index = lists.indices.last {
            if lists[index].ordered {
                let number = node["value"].flatMap { Int($0.trimmed) } ?? lists[index].next
                lists[index].next = number + 1
                marker = "\(number). "
            }
            lists[index].markerWidth = marker.count
        }
        item(node, marker: marker, context)
    }

    private func item(_ node: HTMLNode, marker: String, _ context: Context) {
        writer.boundary(1)
        writer.startItem(marker)
        var inner = context
        inner.inListItem = true
        convertChildren(of: node, inner)
        writer.endItem()
        writer.boundary(1)
    }

    /// Word writes lists as paragraphs styled `mso-list: l0 level2 lfo1`, each with its own
    /// marker text in a `mso-list: Ignore` span.
    private static func wordListLevel(_ css: [String: String]) -> Int? {
        guard let value = css["mso-list"] else { return nil }
        let words = value.split(separator: " ")
        guard let word = words.first(where: { $0.hasPrefix("level") }), let level = Int(word.dropFirst(5)) else {
            return nil
        }
        return min(max(level, 1), 9)
    }

    private func wordListItem(_ node: HTMLNode, level: Int, _ context: Context) {
        let markerText = Self.wordListMarker(in: node) ?? ""
        let number = Int(markerText.prefix(while: \.isNumber))
        for _ in 1..<level {
            writer.pushPrefix("   ")
        }
        item(node, marker: number.map { "\($0). " } ?? "- ", context)
        for _ in 1..<level {
            writer.popPrefix()
        }
    }

    private static func wordListMarker(in node: HTMLNode) -> String? {
        for child in node.children where !child.isText {
            if declarations(child["style"])["mso-list"] == "ignore" {
                return plainText(of: child).trimmed
            }
            if let marker = wordListMarker(in: child) {
                return marker
            }
        }
        return nil
    }

    private func blockquote(_ node: HTMLNode, _ context: Context) {
        let breaks = blockBreaks(context)
        writer.boundary(breaks)
        writer.pushPrefix("> ")
        var inner = context
        inner.inListItem = false
        convertChildren(of: node, inner)
        writer.popPrefix()
        writer.boundary(breaks)
    }

    private func codeBlock(_ node: HTMLNode, _ context: Context) {
        // ChatGPT and others put a header and a copy button in `<pre>`, around the `<code>`.
        let codeElements = Self.descendants(of: node, named: "code")
        let source = codeElements.count == 1 ? codeElements[0] : node
        let code = Self.plainText(of: source).normalizingNewlines.replacingScalars(["\u{00A0}": " "])

        var codeLines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = codeLines.first, first.allSatisfy(\.isWhitespace) {
            codeLines.removeFirst()
        }
        while let last = codeLines.last, last.allSatisfy(\.isWhitespace) {
            codeLines.removeLast()
        }
        guard !codeLines.isEmpty else { return }

        let language = Self.codeLanguage(of: source) ?? context.codeLanguage ?? ""
        let fence = String(repeating: "`", count: max(3, InlineMarkdown.longestRun(of: "`", in: code) + 1))
        writer.block([fence + language] + codeLines + [fence], breaks: blockBreaks(context))
    }

    private static let languageCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+#-_."))

    private static func codeLanguage(of node: HTMLNode) -> String? {
        guard node["class"] != nil || node["data-lang"] != nil || node["data-language"] != nil else { return nil }
        var candidates: [Substring] = []
        if let language = node["data-lang"] ?? node["data-language"] {
            candidates.append(Substring(language))
        }
        for name in (node["class"] ?? "").split(separator: " ") {
            for prefix in ["language-", "lang-", "highlight-source-"] where name.hasPrefix(prefix) {
                candidates.append(name.dropFirst(prefix.count))
            }
        }
        return candidates.first { !$0.isEmpty && $0.unicodeScalars.allSatisfy(languageCharacters.contains) }
            .map(String.init)
    }

    // MARK: Tables

    private func table(_ node: HTMLNode, _ context: Context) {
        let rows = Self.tableRows(of: node)
        let columns = rows.map { row in row.reduce(0) { $0 + Self.columnSpan(of: $1) } }.max() ?? 0
        let isLayout = node["role"] == "presentation" || columns < 2
            || rows.joined().contains { Self.contains(Self.layoutContent, in: $0) }
        guard !rows.isEmpty, !isLayout else {
            writer.boundary(1)
            convertChildren(of: node, context)
            writer.boundary(1)
            return
        }

        var cells: [[String]] = []
        var alignments: [String] = []
        for (rowIndex, row) in rows.enumerated() {
            var rendered: [String] = []
            for cell in row {
                var inner = context
                inner.inListItem = false
                if rowIndex == 0 {
                    // Markdown tables have exactly one header row: the first.
                    inner.boldIsImplicit = true
                    inner.style.bold = false
                } else if cell.name == "th" {
                    inner.style.bold = true
                }
                applyStyle(of: cell, css: Self.declarations(cell["style"]), to: &inner)
                let text = renderLines(of: cell, inner)
                    .joined(separator: "<br>")
                    .replacingScalars(["|": "\\|"])
                let span = Self.columnSpan(of: cell)
                rendered.append(text)
                rendered += Array(repeating: "", count: span - 1)
                if rowIndex == 0 {
                    alignments += Array(repeating: Self.alignment(of: cell), count: span)
                }
            }
            cells.append(rendered)
        }

        var lines: [String] = []
        if let caption = node.children.first(where: { $0.name == "caption" }) {
            lines += renderLines(of: caption, context)
            lines.append("")
        }
        for (index, row) in cells.enumerated() {
            let padded = row + Array(repeating: "", count: columns - row.count)
            lines.append("| " + padded.joined(separator: " | ") + " |")
            if index == 0 {
                let delimiters = (0..<columns).map { $0 < alignments.count ? alignments[$0] : "---" }
                lines.append("| " + delimiters.joined(separator: " | ") + " |")
            }
        }
        writer.block(lines, breaks: blockBreaks(context))
        writer.noteContent()
    }

    private static func tableRows(of table: HTMLNode) -> [[HTMLNode]] {
        var rows: [[HTMLNode]] = []
        func collect(_ node: HTMLNode) {
            for child in node.children {
                switch child.name {
                case "tr":
                    let cells = child.children.filter { $0.name == "td" || $0.name == "th" }
                    if !cells.isEmpty { rows.append(cells) }
                case "thead", "tbody", "tfoot":
                    collect(child)
                default:
                    break
                }
            }
        }
        collect(table)
        return rows
    }

    private static func columnSpan(of cell: HTMLNode) -> Int {
        min(max(Int(cell["colspan"] ?? "") ?? 1, 1), 64)
    }

    private static func alignment(of cell: HTMLNode) -> String {
        switch cell["align"]?.lowercased() ?? declarations(cell["style"])["text-align"] {
        case "center": return ":---:"
        case "right": return "---:"
        case "left": return ":---"
        default: return "---"
        }
    }

    // MARK: Helpers

    /// The Markdown of a node's content on its own, one entry per line, for headings and cells.
    private func renderLines(of node: HTMLNode, _ context: Context) -> [String] {
        let converter = Converter(baseURL: baseURL)
        var inner = context
        inner.inListItem = false
        converter.convertChildren(of: node, inner)
        let lines = converter.writer.finish()
        writer.absorb(converter.writer)
        return lines.map(\.trimmed).filter { !$0.isEmpty }
    }

    /// The text of a node with its line structure, as code keeps it.
    private static func plainText(of node: HTMLNode) -> String {
        var text = ""
        var needsNewline = false
        func visit(_ node: HTMLNode) {
            if node.isText {
                if needsNewline {
                    text += "\n"
                    needsNewline = false
                }
                text += node.text
                return
            }
            guard !ignoredElements.contains(node.name), declarations(node["style"])["display"] != "none" else { return }
            if node.name == "br" {
                if needsNewline {
                    text += "\n"
                    needsNewline = false
                }
                text += "\n"
                return
            }
            let isBlock = blockElements.contains(node.name) || markdownBlocks.contains(node.name)
            if isBlock, !text.isEmpty, !text.hasSuffix("\n") { needsNewline = true }
            node.children.forEach(visit)
            if isBlock, !text.isEmpty, !text.hasSuffix("\n") { needsNewline = true }
        }
        visit(node)
        return text
    }

    private static func descendants(of node: HTMLNode, named name: String) -> [HTMLNode] {
        node.children.flatMap { child -> [HTMLNode] in
            child.name == name ? [child] : descendants(of: child, named: name)
        }
    }

    private static func contains(_ names: Set<String>, in node: HTMLNode) -> Bool {
        node.children.contains { names.contains($0.name) || contains(names, in: $0) }
    }

    /// The declarations of a `style` attribute, with lowercased names and values.
    private static func declarations(_ style: String?) -> [String: String] {
        guard let style, !style.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for declaration in style.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let name = declaration[..<colon].trimmed.lowercased()
            var value = declaration[declaration.index(after: colon)...].trimmed.lowercased()
            if value.hasSuffix("!important") {
                value = value.dropLast("!important".count).trimmed
            }
            result[name] = value
        }
        return result
    }
}

// MARK: - String helpers

private extension StringProtocol {
    /// The text without whitespace at either end; cheaper than Foundation's trimming.
    var trimmed: String {
        let start = firstIndex { !$0.isWhitespace } ?? endIndex
        let end = lastIndex { !$0.isWhitespace }.map { index(after: $0) } ?? start
        return String(self[start..<end])
    }

    /// The text with `\r\n` and `\r` line endings turned into `\n`.
    var normalizingNewlines: String {
        guard unicodeScalars.contains("\r") else { return String(self) }
        var result = String.UnicodeScalarView()
        var afterCarriageReturn = false
        for scalar in unicodeScalars {
            if scalar == "\n", afterCarriageReturn {
                afterCarriageReturn = false
                continue
            }
            afterCarriageReturn = scalar == "\r"
            result.append(afterCarriageReturn ? "\n" : scalar)
        }
        return String(result)
    }

    /// Whether `other` appears in the text, compared exactly.
    func includes(_ other: String) -> Bool {
        let text = Array(utf8)
        let needle = Array(other.utf8)
        guard !needle.isEmpty else { return true }
        guard text.count >= needle.count else { return false }
        return (0...(text.count - needle.count)).contains { start in
            needle.indices.allSatisfy { text[start + $0] == needle[$0] }
        }
    }

    /// The text with each of the characters in `replacements` replaced, in a single pass.
    func replacingScalars(_ replacements: [Unicode.Scalar: String]) -> String {
        guard unicodeScalars.contains(where: { replacements[$0] != nil }) else { return String(self) }
        var result = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            if let replacement = replacements[scalar] {
                result.append(contentsOf: replacement.unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }
}
