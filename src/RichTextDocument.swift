import Foundation

/// A paragraph of an attributed string (RTF from TextEdit, Pages, Notes…), reduced to what
/// Markdown can express. `RichTextPaste` reads these out of AppKit.
struct RichTextParagraph {
    struct Run {
        var text: String
        var isBold = false
        var isItalic = false
        var isStrikethrough = false
        var isMonospaced = false
        var link: String?
    }

    /// A list the paragraph is an item of.
    struct List: Equatable {
        var isOrdered: Bool
        /// Tells apart lists nested in one another, such as `{disc}` in `{decimal}`.
        var format: String
        var startingNumber = 1
    }

    struct TableCell {
        var table: Int
        var row: Int
        var column: Int
    }

    /// The text, without a list item's marker; `\u{2028}` is a line break.
    var runs: [Run] = []
    /// The size most of the text is in.
    var fontSize: Double = 12
    /// One per level of nesting, outermost first.
    var lists: [List] = []
    var tableCell: TableCell?

    var text: String { runs.map(\.text).joined() }
}

/// Lays rich text paragraphs out as HTML, for `MarkdownConverter` to translate.
///
/// Rich text has no headings or code blocks as such, only fonts, so they're inferred: text
/// noticeably larger than the body is a heading (the largest size `#`, the next `##`…), and
/// paragraphs entirely in a fixed-width font are code.
enum RichTextDocument {
    static func markdown(from paragraphs: [RichTextParagraph]) -> String? {
        MarkdownConverter.markdown(from: document(from: paragraphs))
    }

    static func document(from paragraphs: [RichTextParagraph]) -> HTMLNode {
        // Spaces and tabs in rich text are as typed, so they're kept.
        let body = HTMLNode(name: "div", attributes: ["style": "white-space: pre-wrap"])
        let headingLevels = self.headingLevels(of: paragraphs)
        var openLists: [(list: RichTextParagraph.List, node: HTMLNode)] = []

        var index = 0
        while index < paragraphs.count {
            let paragraph = paragraphs[index]

            if let cell = paragraph.tableCell {
                openLists.removeAll()
                var end = index + 1
                while end < paragraphs.count, paragraphs[end].tableCell?.table == cell.table {
                    end += 1
                }
                body.children.append(table(from: paragraphs[index..<end]))
                index = end
                continue
            }

            if !paragraph.lists.isEmpty {
                appendListItem(paragraph, to: body, openLists: &openLists)
                index += 1
                continue
            }
            openLists.removeAll()

            if isCode(paragraph) {
                // Blank lines between code paragraphs belong to the code.
                var lastCode = index
                var end = index + 1
                while end < paragraphs.count, isCode(paragraphs[end]) || isBlank(paragraphs[end]) {
                    if isCode(paragraphs[end]) { lastCode = end }
                    end += 1
                }
                let code = paragraphs[index...lastCode]
                    .map { $0.text.replacingOccurrences(of: "\u{2028}", with: "\n") }
                    .joined(separator: "\n")
                body.children.append(HTMLNode(name: "pre", children: [HTMLNode(text: code)]))
                index = lastCode + 1
                continue
            }

            if let level = headingLevels[index] {
                body.children.append(HTMLNode(name: "h\(level)", children: inlineNodes(paragraph.runs)))
            } else if isRule(paragraph) {
                body.children.append(HTMLNode(name: "hr"))
            } else if isBlank(paragraph) {
                body.children.append(HTMLNode(name: "div", children: [HTMLNode(name: "br")]))
            } else {
                body.children.append(HTMLNode(name: "div", children: inlineNodes(paragraph.runs)))
            }
            index += 1
        }
        return HTMLNode(name: "#document", children: [body])
    }

    // MARK: - Inference

    /// The heading level of each paragraph that is one, by index.
    private static func headingLevels(of paragraphs: [RichTextParagraph]) -> [Int: Int] {
        func rounded(_ size: Double) -> Double { (size * 2).rounded() / 2 }

        var characters: [Double: Int] = [:]
        for paragraph in paragraphs {
            characters[rounded(paragraph.fontSize), default: 0] += paragraph.text.count
        }
        // The body is the size most text is in; on a tie, the smaller one.
        guard let bodySize = characters.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key,
              bodySize > 0
        else { return [:] }

        var sizes: [Int: Double] = [:]
        for (index, paragraph) in paragraphs.enumerated()
        where paragraph.lists.isEmpty && paragraph.tableCell == nil && !isCode(paragraph) {
            let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let size = rounded(paragraph.fontSize)
            if !text.isEmpty, text.count <= 200, size >= bodySize * 1.15 {
                sizes[index] = size
            }
        }
        let ranked = Set(sizes.values).sorted(by: >)
        return sizes.mapValues { size in min((ranked.firstIndex(of: size) ?? 0) + 1, 6) }
    }

    private static func isCode(_ paragraph: RichTextParagraph) -> Bool {
        guard paragraph.lists.isEmpty, paragraph.tableCell == nil else { return false }
        let visible = paragraph.runs.filter { $0.text.contains { !$0.isWhitespace } }
        return !visible.isEmpty && visible.allSatisfy(\.isMonospaced)
    }

    private static func isBlank(_ paragraph: RichTextParagraph) -> Bool {
        paragraph.lists.isEmpty && paragraph.tableCell == nil && paragraph.text.allSatisfy(\.isWhitespace)
    }

    /// A line drawn with dashes, such as the Markdown preview's horizontal rules.
    private static func isRule(_ paragraph: RichTextParagraph) -> Bool {
        let text = paragraph.text.filter { !$0.isWhitespace }
        return text.count >= 3 && text.allSatisfy { "—–-_─━".contains($0) }
    }

    // MARK: - Building

    private static func appendListItem(
        _ paragraph: RichTextParagraph,
        to body: HTMLNode,
        openLists: inout [(list: RichTextParagraph.List, node: HTMLNode)]
    ) {
        var depth = 0
        while depth < openLists.count, depth < paragraph.lists.count, openLists[depth].list == paragraph.lists[depth] {
            depth += 1
        }
        openLists.removeSubrange(depth...)

        while openLists.count < paragraph.lists.count {
            let list = paragraph.lists[openLists.count]
            let node = HTMLNode(
                name: list.isOrdered ? "ol" : "ul",
                attributes: list.isOrdered ? ["start": String(list.startingNumber)] : [:]
            )
            // A nested list goes in the item before it, or in its parent list if there's none.
            let parent = openLists.last.map { open in open.node.children.last { $0.name == "li" } ?? open.node } ?? body
            parent.children.append(node)
            openLists.append((list, node))
        }

        var runs = paragraph.runs
        while let first = runs.first, first.text.allSatisfy(\.isWhitespace) {
            runs.removeFirst()
        }
        if !runs.isEmpty {
            runs[0].text = String(runs[0].text.drop(while: \.isWhitespace))
        }
        openLists[openLists.count - 1].node.children.append(HTMLNode(name: "li", children: inlineNodes(runs)))
    }

    private static func table(from paragraphs: ArraySlice<RichTextParagraph>) -> HTMLNode {
        var rows: [Int: [Int: [RichTextParagraph]]] = [:]
        for paragraph in paragraphs {
            guard let cell = paragraph.tableCell else { continue }
            rows[cell.row, default: [:]][cell.column, default: []].append(paragraph)
        }

        let table = HTMLNode(name: "table")
        for row in rows.keys.sorted() {
            let columns = rows[row] ?? [:]
            let tr = HTMLNode(name: "tr")
            for column in 0...(columns.keys.max() ?? 0) {
                let td = HTMLNode(name: "td")
                for (index, paragraph) in (columns[column] ?? []).enumerated() {
                    if index > 0 { td.children.append(HTMLNode(name: "br")) }
                    td.children += inlineNodes(paragraph.runs)
                }
                tr.children.append(td)
            }
            table.children.append(tr)
        }
        return table
    }

    private static func inlineNodes(_ runs: [RichTextParagraph.Run]) -> [HTMLNode] {
        runs.flatMap { run -> [HTMLNode] in
            var nodes: [HTMLNode] = []
            for (index, part) in run.text.components(separatedBy: "\u{2028}").enumerated() {
                if index > 0 { nodes.append(HTMLNode(name: "br")) }
                if !part.isEmpty { nodes.append(HTMLNode(text: part)) }
            }
            if run.isMonospaced { nodes = [HTMLNode(name: "code", children: nodes)] }
            if run.isStrikethrough { nodes = [HTMLNode(name: "s", children: nodes)] }
            if run.isItalic { nodes = [HTMLNode(name: "i", children: nodes)] }
            if run.isBold { nodes = [HTMLNode(name: "b", children: nodes)] }
            if let link = run.link { nodes = [HTMLNode(name: "a", attributes: ["href": link], children: nodes)] }
            return nodes
        }
    }
}
