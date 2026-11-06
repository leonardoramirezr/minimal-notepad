import Foundation

/// An element, or a run of text, of a parsed HTML document.
final class HTMLNode {
    /// The lowercased tag name; `#text` for text and `#document` for the root.
    let name: String
    var attributes: [String: String]
    var children: [HTMLNode]
    /// The decoded text of a text node.
    var text: String

    init(name: String, attributes: [String: String] = [:], children: [HTMLNode] = []) {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = ""
    }

    init(text: String) {
        self.name = "#text"
        self.attributes = [:]
        self.children = []
        self.text = text
    }

    var isText: Bool { name == "#text" }

    subscript(attribute: String) -> String? { attributes[attribute] }
}

/// A forgiving HTML parser for what apps put on the pasteboard: fragments from browsers,
/// Word, Google Docs and the like.
///
/// It follows the parts of the HTML rules those fragments rely on (void elements, raw
/// text, character references, implied end tags) without being a complete HTML5 parser.
enum HTMLParser {
    static func parse(_ html: String) -> HTMLNode {
        var tokenizer = HTMLTokenizer(html)
        var builder = HTMLTreeBuilder()
        while let token = tokenizer.next() {
            builder.process(token)
        }
        return builder.root
    }
}

private enum HTMLToken {
    case startTag(name: String, attributes: [String: String], selfClosing: Bool)
    case endTag(name: String)
    case text(String)
}

private struct HTMLTokenizer {
    /// Elements whose content is text up to their end tag, never markup.
    private static let rawTextElements: Set<String> = [
        "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "noscript",
    ]

    private let bytes: [UInt8]
    private var position = 0
    /// Set right after the start tag of a raw text element.
    private var rawTextElement: String?

    init(_ html: String) {
        bytes = Array(html.utf8)
    }

    mutating func next() -> HTMLToken? {
        while position < bytes.count {
            if let element = rawTextElement {
                rawTextElement = nil
                let start = position
                position = endTagPosition(of: element) ?? bytes.count
                if position > start {
                    return .text(string(from: start, to: position))
                }
                continue
            }

            guard bytes[position] == Byte.lessThan else {
                return .text(textRun())
            }
            let next = byte(at: position + 1)
            if next == Byte.exclamation {
                skipDeclaration()
            } else if next == Byte.question {
                skip(past: Byte.greaterThan)
            } else if next == Byte.slash {
                if isLetter(byte(at: position + 2)) {
                    return endTag()
                }
                skip(past: Byte.greaterThan)
            } else if isLetter(next) {
                return startTag()
            } else {
                position += 1
                return .text("<")
            }
        }
        return nil
    }

    private mutating func textRun() -> String {
        let start = position
        while position < bytes.count, bytes[position] != Byte.lessThan {
            position += 1
        }
        return HTMLEntities.decode(string(from: start, to: position))
    }

    /// Comments, the doctype and Word's conditional comments (`<![if !supportLists]>`).
    private mutating func skipDeclaration() {
        if byte(at: position + 2) == Byte.hyphen, byte(at: position + 3) == Byte.hyphen {
            var index = position + 4
            while index + 2 < bytes.count {
                if bytes[index] == Byte.hyphen, bytes[index + 1] == Byte.hyphen, bytes[index + 2] == Byte.greaterThan {
                    position = index + 3
                    return
                }
                index += 1
            }
            position = bytes.count
        } else {
            skip(past: Byte.greaterThan)
        }
    }

    private mutating func startTag() -> HTMLToken {
        position += 1
        let name = readName()
        var attributes: [String: String] = [:]
        var selfClosing = false

        while position < bytes.count {
            skipWhitespace()
            guard position < bytes.count else { break }
            if bytes[position] == Byte.greaterThan {
                position += 1
                break
            }
            if bytes[position] == Byte.slash {
                position += 1
                if byte(at: position) == Byte.greaterThan {
                    selfClosing = true
                    position += 1
                    break
                }
                continue
            }

            let nameStart = position
            // The first character can be anything, even "=".
            position += 1
            while position < bytes.count, !isWhitespace(bytes[position]),
                  bytes[position] != Byte.slash, bytes[position] != Byte.greaterThan, bytes[position] != Byte.equals {
                position += 1
            }
            let attributeName = string(from: nameStart, to: position).lowercased()
            skipWhitespace()

            var value = ""
            if byte(at: position) == Byte.equals {
                position += 1
                skipWhitespace()
                let quote = byte(at: position)
                if quote == Byte.quotationMark || quote == Byte.apostrophe {
                    position += 1
                    let valueStart = position
                    while position < bytes.count, bytes[position] != quote {
                        position += 1
                    }
                    value = string(from: valueStart, to: position)
                    position = min(position + 1, bytes.count)
                } else {
                    let valueStart = position
                    while position < bytes.count, !isWhitespace(bytes[position]), bytes[position] != Byte.greaterThan {
                        position += 1
                    }
                    value = string(from: valueStart, to: position)
                }
            }
            if attributes[attributeName] == nil {
                attributes[attributeName] = HTMLEntities.decode(value, inAttribute: true)
            }
        }

        if !selfClosing, Self.rawTextElements.contains(name) {
            rawTextElement = name
        }
        return .startTag(name: name, attributes: attributes, selfClosing: selfClosing)
    }

    private mutating func endTag() -> HTMLToken {
        position += 2
        let name = readName()
        skip(past: Byte.greaterThan)
        return .endTag(name: name)
    }

    private mutating func readName() -> String {
        let start = position
        while position < bytes.count, !isWhitespace(bytes[position]),
              bytes[position] != Byte.slash, bytes[position] != Byte.greaterThan {
            position += 1
        }
        return string(from: start, to: position).lowercased()
    }

    /// Where `</name` starts, compared without regard to case.
    private func endTagPosition(of name: String) -> Int? {
        let nameBytes = Array(name.utf8)
        var index = position
        while index + 1 < bytes.count {
            if bytes[index] == Byte.lessThan, bytes[index + 1] == Byte.slash {
                let nameStart = index + 2
                let after = nameStart + nameBytes.count
                // Tag names are ASCII letters, so setting bit 0x20 lowercases them.
                if after <= bytes.count,
                   nameBytes.indices.allSatisfy({ bytes[nameStart + $0] | 0x20 == nameBytes[$0] }),
                   after == bytes.count || isWhitespace(bytes[after])
                    || bytes[after] == Byte.slash || bytes[after] == Byte.greaterThan {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private mutating func skip(past byte: UInt8) {
        while position < bytes.count, bytes[position] != byte {
            position += 1
        }
        position = min(position + 1, bytes.count)
    }

    private mutating func skipWhitespace() {
        while position < bytes.count, isWhitespace(bytes[position]) {
            position += 1
        }
    }

    private func byte(at index: Int) -> UInt8 {
        index < bytes.count ? bytes[index] : 0
    }

    private func string(from start: Int, to end: Int) -> String {
        String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    private func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private enum Byte {
        static let lessThan = UInt8(ascii: "<")
        static let greaterThan = UInt8(ascii: ">")
        static let slash = UInt8(ascii: "/")
        static let exclamation = UInt8(ascii: "!")
        static let question = UInt8(ascii: "?")
        static let hyphen = UInt8(ascii: "-")
        static let equals = UInt8(ascii: "=")
        static let quotationMark = UInt8(ascii: "\"")
        static let apostrophe = UInt8(ascii: "'")
    }
}

/// Builds the tree, closing the elements HTML lets authors leave open (`<p>`, `<li>`, `<td>`…).
private struct HTMLTreeBuilder {
    private static let voidElements: Set<String> = [
        "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img",
        "input", "keygen", "link", "meta", "param", "source", "track", "wbr",
    ]
    private static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div",
        "dl", "dd", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hgroup", "hr", "li", "main", "menu", "nav", "ol", "p", "pre",
        "section", "summary", "table", "ul",
    ]
    private static let headElements: Set<String> = [
        "base", "link", "meta", "noscript", "script", "style", "template", "title",
    ]
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private static let tableElements: Set<String> = [
        "caption", "table", "tbody", "td", "tfoot", "th", "thead", "tr",
    ]
    private static let defaultScope: Set<String> = [
        "applet", "caption", "html", "marquee", "object", "table", "td", "template", "th",
    ]
    private static let buttonScope = defaultScope.union(["button"])
    private static let listItemScope = defaultScope.union(["ol", "ul"])
    private static let tableScope: Set<String> = ["html", "table", "template"]
    /// Deeper elements are added to their parent instead, so malformed input can't nest forever.
    private static let maximumDepth = 512

    let root = HTMLNode(name: "#document")
    private var stack: [HTMLNode]

    init() {
        stack = [root]
    }

    private var current: HTMLNode { stack[stack.count - 1] }

    mutating func process(_ token: HTMLToken) {
        switch token {
        case let .text(text):
            appendText(text)
        case let .startTag(name, attributes, selfClosing):
            startTag(name, attributes: attributes, selfClosing: selfClosing)
        case let .endTag(name):
            endTag(name)
        }
    }

    private mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        if current.name == "head", text.contains(where: { !$0.isWhitespace }) {
            stack.removeLast()
        }
        if let last = current.children.last, last.isText {
            last.text += text
        } else {
            current.children.append(HTMLNode(text: text))
        }
    }

    private mutating func startTag(_ name: String, attributes: [String: String], selfClosing: Bool) {
        switch name {
        case "html":
            return
        case "body":
            close(["head"], scope: [])
            return
        default:
            break
        }
        // Content that can't be in the head starts the body.
        if current.name == "head", !Self.headElements.contains(name) {
            stack.removeLast()
        }

        if Self.closesParagraph.contains(name) {
            close(["p"], scope: Self.buttonScope)
        }
        switch name {
        case "li":
            close(["li"], scope: Self.listItemScope)
        case "dd", "dt":
            close(["dd", "dt"], scope: Self.defaultScope.union(["dl"]))
        case "tr":
            close(["tr"], scope: Self.tableScope)
        case "td", "th":
            close(["td", "th"], scope: Self.tableScope.union(["tr"]))
        case "thead", "tbody", "tfoot":
            close(["thead", "tbody", "tfoot"], scope: Self.tableScope)
        case "a":
            close(["a"], scope: Self.defaultScope)
        case "option":
            if current.name == "option" { stack.removeLast() }
        default:
            if Self.headings.contains(name), Self.headings.contains(current.name) {
                stack.removeLast()
            }
        }

        let node = HTMLNode(name: name, attributes: attributes)
        current.children.append(node)
        if !selfClosing, !Self.voidElements.contains(name), stack.count < Self.maximumDepth {
            stack.append(node)
        }
    }

    private mutating func endTag(_ name: String) {
        switch name {
        case "html", "body":
            return
        case "br":
            // Browsers read `</br>` as `<br>`.
            startTag("br", attributes: [:], selfClosing: true)
        case "p":
            close(["p"], scope: Self.buttonScope)
        case "li":
            close(["li"], scope: Self.listItemScope)
        default:
            close([name], scope: Self.tableElements.contains(name) ? Self.tableScope : Self.defaultScope)
        }
    }

    /// Closes the innermost open element named one of `names`, unless an element of `scope`
    /// (such as the table cell the end tag is in) comes first.
    private mutating func close(_ names: Set<String>, scope: Set<String>) {
        for index in stride(from: stack.count - 1, to: 0, by: -1) {
            let name = stack[index].name
            if names.contains(name) {
                stack.removeSubrange(index...)
                return
            }
            if scope.contains(name) {
                return
            }
        }
    }
}

/// Decodes character references such as `&amp;`, `&eacute;` and `&#8217;`.
enum HTMLEntities {
    static func decode(_ text: String, inAttribute: Bool = false) -> String {
        guard text.utf8.contains(UInt8(ascii: "&")) else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] == "&", let (scalar, length) = reference(in: scalars, at: index, inAttribute: inAttribute) {
                result.append(scalar)
                index += length
            } else {
                result.append(scalars[index])
                index += 1
            }
        }
        return String(result)
    }

    /// The character a reference starting at `start` stands for, and the reference's length.
    private static func reference(
        in scalars: [Unicode.Scalar],
        at start: Int,
        inAttribute: Bool
    ) -> (Unicode.Scalar, Int)? {
        var index = start + 1
        guard index < scalars.count else { return nil }

        if scalars[index] == "#" {
            index += 1
            var radix: UInt32 = 10
            if index < scalars.count, scalars[index] == "x" || scalars[index] == "X" {
                radix = 16
                index += 1
            }
            let digitsStart = index
            var value: UInt32 = 0
            while index < scalars.count, let digit = digitValue(scalars[index], radix: radix) {
                value = min(value * radix + digit, 0x110000)
                index += 1
            }
            guard index > digitsStart else { return nil }
            if index < scalars.count, scalars[index] == ";" {
                index += 1
            }
            return (scalar(forCodePoint: value), index - start)
        }

        let nameStart = index
        while index < scalars.count, index - nameStart < 32, scalars[index].isASCII,
              scalars[index].properties.isAlphabetic || ("0"..."9").contains(scalars[index]) {
            index += 1
        }
        guard index > nameStart else { return nil }
        let name = String(String.UnicodeScalarView(scalars[nameStart..<index]))
        if index < scalars.count, scalars[index] == ";", let scalar = named[name] {
            return (scalar, index + 1 - start)
        }
        // Old pages leave the semicolon off the most common ones.
        if !inAttribute, ["amp", "lt", "gt", "quot", "nbsp"].contains(name), let scalar = named[name] {
            return (scalar, index - start)
        }
        return nil
    }

    private static func digitValue(_ scalar: Unicode.Scalar, radix: UInt32) -> UInt32? {
        switch scalar {
        case "0"..."9": return scalar.value - 48
        case "a"..."f" where radix == 16: return scalar.value - 87
        case "A"..."F" where radix == 16: return scalar.value - 55
        default: return nil
        }
    }

    private static func scalar(forCodePoint value: UInt32) -> Unicode.Scalar {
        let replacement: Unicode.Scalar = "\u{FFFD}"
        if (0x80...0x9F).contains(value) {
            // Pages written for Windows mean the Windows-1252 characters, as browsers assume.
            let mapped = windows1252[Int(value - 0x80)]
            return Unicode.Scalar(mapped == 0 ? value : mapped) ?? replacement
        }
        guard value != 0 else { return replacement }
        return Unicode.Scalar(value) ?? replacement
    }

    private static let windows1252: [UInt32] = [
        0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    ]

    /// The named references of HTML 4, which cover nearly everything apps write.
    private static let named: [String: Unicode.Scalar] = {
        var table: [String: Unicode.Scalar] = [:]
        func add(_ names: String, from first: UInt32) {
            for (offset, name) in names.split(separator: " ").enumerated() where name != "_" {
                table[String(name)] = Unicode.Scalar(first + UInt32(offset))
            }
        }
        add("""
            nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg \
            plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 \
            iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml \
            Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave \
            Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig ccedil \
            egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute ocirc otilde \
            ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
            """, from: 160)
        add("""
            Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda Mu Nu Xi Omicron Pi \
            Rho _ Sigma Tau Upsilon Phi Chi Psi Omega
            """, from: 913)
        add("""
            alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi \
            rho sigmaf sigma tau upsilon phi chi psi omega
            """, from: 945)

        let others = """
            quot 34 amp 38 apos 39 lt 60 gt 62 OElig 338 oelig 339 Scaron 352 scaron 353 Yuml 376 \
            fnof 402 circ 710 tilde 732 thetasym 977 upsih 978 piv 982 ensp 8194 emsp 8195 \
            thinsp 8201 zwnj 8204 zwj 8205 lrm 8206 rlm 8207 ndash 8211 mdash 8212 lsquo 8216 \
            rsquo 8217 sbquo 8218 ldquo 8220 rdquo 8221 bdquo 8222 dagger 8224 Dagger 8225 \
            bull 8226 hellip 8230 permil 8240 prime 8242 Prime 8243 lsaquo 8249 rsaquo 8250 \
            oline 8254 frasl 8260 euro 8364 image 8465 weierp 8472 real 8476 trade 8482 \
            alefsym 8501 larr 8592 uarr 8593 rarr 8594 darr 8595 harr 8596 crarr 8629 lArr 8656 \
            uArr 8657 rArr 8658 dArr 8659 hArr 8660 forall 8704 part 8706 exist 8707 empty 8709 \
            nabla 8711 isin 8712 notin 8713 ni 8715 prod 8719 sum 8721 minus 8722 lowast 8727 \
            radic 8730 prop 8733 infin 8734 ang 8736 and 8743 or 8744 cap 8745 cup 8746 int 8747 \
            there4 8756 sim 8764 cong 8773 asymp 8776 ne 8800 equiv 8801 le 8804 ge 8805 \
            sub 8834 sup 8835 nsub 8836 sube 8838 supe 8839 oplus 8853 otimes 8855 perp 8869 \
            sdot 8901 lceil 8968 rceil 8969 lfloor 8970 rfloor 8971 lang 10216 rang 10217 \
            loz 9674 spades 9824 clubs 9827 hearts 9829 diams 9830
            """.split(separator: " ")
        for index in stride(from: 0, to: others.count - 1, by: 2) {
            if let value = UInt32(others[index + 1]) {
                table[String(others[index])] = Unicode.Scalar(value)
            }
        }
        return table
    }()
}
