import Foundation

/// A styled stretch of text inside a block. A line break inside a block is a "\n" in `text`.
public struct RichRun: Hashable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var link: String?
    public var underline = false
    public var strikethrough = false

    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil,
                underline: Bool = false, strikethrough: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.link = link
        self.underline = underline
        self.strikethrough = strikethrough
    }

    fileprivate func sameStyle(as other: RichRun) -> Bool {
        bold == other.bold && italic == other.italic && code == other.code && link == other.link
            && underline == other.underline && strikethrough == other.strikethrough
    }
}

/// One cell of a simple table. Spans are ignored; every cell takes one column.
public struct RichTableCell: Hashable, Sendable {
    public var runs: [RichRun]
    public var isHeader: Bool

    public init(runs: [RichRun], isHeader: Bool = false) {
        self.runs = runs
        self.isHeader = isHeader
    }
}

/// Course text reduced to blocks a native view can draw. Scripts, styles, forms and frames are
/// dropped, and so are the author's colours, fonts and sizes, so text follows the app's theme.
public enum RichBlock: Hashable, Sendable {
    case heading(level: Int, runs: [RichRun])
    case paragraph([RichRun])
    case listItem(ordered: Bool, number: Int, depth: Int, runs: [RichRun])
    case quote([RichRun])
    case code(String)
    case image(source: String, alt: String?)
    case embed(source: String)
    case table(rows: [[RichTableCell]])
    case rule
}

/// A small HTML reader for course text. It is not a browser: unknown tags are ignored and their text kept.
public enum RichText {
    public static func blocks(fromHTML html: String) -> [RichBlock] {
        guard containsMarkup(html) else { return plainBlocks(html) }
        var reader = Reader()
        reader.read(html)
        return reader.finish()
    }

    /// Plain text with paragraph breaks, for accessibility and copying.
    public static func plainText(_ blocks: [RichBlock]) -> String {
        lines(blocks).joined(separator: "\n\n")
    }

    /// Plain text with one line per block, for search and stored text.
    public static func lines(_ blocks: [RichBlock]) -> [String] {
        blocks.compactMap { block -> String? in
            switch block {
            case .heading(_, let runs), .paragraph(let runs), .quote(let runs), .listItem(_, _, _, let runs):
                return runs.map(\.text).joined()
            case .code(let text): return text
            case .image(_, let alt): return alt.flatMap { $0.isEmpty ? nil : $0 }
            case .table(let rows):
                return rows.map { $0.map { $0.runs.map(\.text).joined() }.joined(separator: "\t") }.joined(separator: "\n")
            case .embed, .rule: return nil
            }
        }
    }

    /// One line for a row's preview: every break and run of spaces becomes a single space.
    public static func preview(_ blocks: [RichBlock]) -> String {
        lines(blocks).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Plain text

    /// True when the text has at least one tag. Messages and some descriptions arrive as plain
    /// text, where line breaks are the author's and must not be collapsed as HTML would.
    static func containsMarkup(_ text: String) -> Bool {
        text.range(of: #"<[A-Za-z/!?]"#, options: .regularExpression) != nil
    }

    /// Plain text as paragraphs at blank lines, keeping single line breaks, with web and mail
    /// addresses made into links.
    static func plainBlocks(_ text: String) -> [RichBlock] {
        let decoded = Entities.decode(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return decoded.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { RichBlock.paragraph(linkified($0.joined(separator: "\n"))) }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func linkified(_ text: String) -> [RichRun] {
        guard let detector, text.contains(".") else { return [RichRun(text: text)] }
        var runs: [RichRun] = []
        var cursor = text.startIndex
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let url = match.url,
                  let link = Reader.safeLink(url.absoluteString), link.contains(":") else { continue }
            if cursor < range.lowerBound { runs.append(RichRun(text: String(text[cursor..<range.lowerBound]))) }
            runs.append(RichRun(text: String(text[range]), link: link))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { runs.append(RichRun(text: String(text[cursor...]))) }
        return runs.isEmpty ? [RichRun(text: text)] : runs
    }

    // MARK: - Reader

    private struct ListContext {
        var ordered: Bool
        var counter = 0
    }

    /// Inline styling an open tag adds; nil leaves the outer style alone.
    private struct InlineFrame {
        var tag: String
        var bold: Bool?
        var italic: Bool?
        var underline: Bool?
        var strikethrough: Bool?
        var code: Bool?
    }

    private struct Reader {
        var blocks: [RichBlock] = []
        var runs: [RichRun] = []
        var inline: [InlineFrame] = []
        var links: [String?] = []
        var lists: [ListContext] = []
        var headingLevel: Int?
        var quoteDepth = 0
        var preText: String?
        var skipDepth = 0
        var itemNumber: Int?
        var tableDepth = 0
        var tableRows: [[RichTableCell]] = []
        var tableRow: [RichTableCell]?
        var cell: RichTableCell?

        mutating func read(_ html: String) {
            var index = html.startIndex
            while index < html.endIndex {
                if html[index] == "<", let close = html[index...].firstIndex(of: ">") {
                    let tag = String(html[html.index(after: index)..<close])
                    handle(tag: tag)
                    index = html.index(after: close)
                } else {
                    let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                    if next == index {
                        // A lone "<" with no closing ">": keep it as text.
                        text("<")
                        index = html.index(after: index)
                    } else {
                        text(String(html[index..<next]))
                        index = next
                    }
                }
            }
        }

        mutating func finish() -> [RichBlock] {
            if tableDepth > 0 {
                tableDepth = 1
                closeTable()
            }
            flush()
            return blocks
        }

        mutating func text(_ raw: String) {
            guard skipDepth == 0 else { return }
            let decoded = Entities.decode(raw)
            if preText != nil {
                preText! += decoded
                return
            }
            let collapsed = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard !collapsed.isEmpty else { return }
            if collapsed == " ", runs.isEmpty { return }
            append(collapsed)
        }

        mutating func append(_ text: String) {
            var run = RichRun(text: text, link: links.last ?? nil)
            for frame in inline {
                if let value = frame.bold { run.bold = value }
                if let value = frame.italic { run.italic = value }
                if let value = frame.underline { run.underline = value }
                if let value = frame.strikethrough { run.strikethrough = value }
                if let value = frame.code { run.code = value }
            }
            if var last = runs.last, last.sameStyle(as: run) {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                runs.append(run)
            }
        }

        mutating func handle(tag raw: String) {
            if raw.hasPrefix("!") || raw.hasPrefix("?") { return }
            let isClosing = raw.hasPrefix("/")
            let body = isClosing ? String(raw.dropFirst()) : raw
            let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            let attributes = Attributes(body)

            if ["script", "style", "noscript", "template", "form", "select", "button", "textarea", "svg", "head", "title"].contains(name) {
                if raw.hasSuffix("/") { return }
                skipDepth += isClosing ? (skipDepth > 0 ? -1 : 0) : 1
                return
            }
            guard skipDepth == 0 else { return }

            if let frame = Self.inlineFrame(name, attributes: attributes, inPre: preText != nil) {
                if isClosing {
                    if let index = inline.lastIndex(where: { $0.tag == name }) { inline.remove(at: index) }
                } else if !raw.hasSuffix("/") {
                    inline.append(frame)
                }
                return
            }

            switch (name, isClosing) {
            case ("a", false): links.append(attributes["href"].flatMap(Self.safeLink))
            case ("a", true): if !links.isEmpty { links.removeLast() }
            case ("br", _):
                if preText != nil { preText! += "\n" } else { append("\n") }
            case ("table", false):
                flush()
                tableDepth += 1
                if tableDepth == 1 {
                    tableRows = []
                    tableRow = nil
                    cell = nil
                }
            case ("table", true):
                if tableDepth == 1 { closeTable() } else { flush() }
                tableDepth = max(0, tableDepth - 1)
            case ("tr", _) where tableDepth == 1:
                closeRow()
                if !isClosing { tableRow = [] }
            case ("td", false) where tableDepth == 1, ("th", false) where tableDepth == 1:
                closeCell()
                if tableRow == nil { tableRow = [] }
                cell = RichTableCell(runs: [], isHeader: name == "th")
            case ("td", true) where tableDepth == 1, ("th", true) where tableDepth == 1:
                closeCell()
            case ("td", true), ("th", true):
                append(" ")
            case ("p", _), ("div", _), ("section", _), ("article", _), ("header", _), ("footer", _), ("main", _),
                 ("aside", _), ("nav", _), ("center", _), ("address", _), ("details", _), ("summary", _),
                 ("tr", _), ("figure", _), ("figcaption", _), ("caption", _), ("dl", _), ("dt", _), ("dd", _):
                flush()
            case ("h1", false), ("h2", false), ("h3", false), ("h4", false), ("h5", false), ("h6", false):
                flush()
                headingLevel = Int(name.dropFirst()) ?? 1
            case ("h1", true), ("h2", true), ("h3", true), ("h4", true), ("h5", true), ("h6", true):
                flush()
                headingLevel = nil
            case ("ul", false), ("ol", false):
                flush()
                let start = attributes["start"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
                lists.append(ListContext(ordered: name == "ol", counter: start - 1))
            case ("ul", true), ("ol", true):
                flush()
                if !lists.isEmpty { lists.removeLast() }
            case ("li", false):
                flush()
                if !lists.isEmpty {
                    if let value = attributes["value"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                        lists[lists.count - 1].counter = value
                    } else {
                        lists[lists.count - 1].counter += 1
                    }
                    itemNumber = lists[lists.count - 1].counter
                } else {
                    itemNumber = 1
                }
            case ("li", true):
                flush()
                itemNumber = nil
            case ("blockquote", false):
                flush()
                quoteDepth += 1
            case ("blockquote", true):
                flush()
                quoteDepth = max(0, quoteDepth - 1)
            case ("pre", false):
                flush()
                preText = ""
            case ("pre", true):
                if let text = preText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let code = text.trimmingCharacters(in: .newlines)
                    if cell != nil { runs.append(RichRun(text: code, code: true)) } else { blocks.append(.code(code)) }
                }
                preText = nil
            case ("hr", _):
                flush()
                if cell == nil { blocks.append(.rule) }
            case ("img", _):
                let alt = attributes["alt"].map(Entities.decode).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let source = attributes["src"].flatMap(Self.safeLink), cell == nil {
                    flush()
                    blocks.append(.image(source: source, alt: alt))
                } else if let alt, !alt.isEmpty {
                    // An image the app cannot open (inline data, or inside a table) keeps its description.
                    append(alt)
                }
            case ("iframe", false), ("video", false), ("audio", false), ("embed", false), ("object", false):
                if let source = (attributes["src"] ?? attributes["data"]).flatMap(Self.safeLink), cell == nil {
                    flush()
                    blocks.append(.embed(source: source))
                }
            default:
                break
            }
        }

        /// The inline styling a tag stands for, or nil when the tag is not an inline style tag.
        /// The `style` attribute counts only for weight, slant and decoration.
        static func inlineFrame(_ name: String, attributes: Attributes, inPre: Bool) -> InlineFrame? {
            var frame = InlineFrame(tag: name)
            switch name {
            case "b", "strong": frame.bold = true
            case "i", "em", "cite", "dfn", "var": frame.italic = true
            case "u", "ins": frame.underline = true
            case "s", "strike", "del": frame.strikethrough = true
            case "code", "kbd", "samp", "tt": frame.code = inPre ? nil : true
            case "span", "font", "mark", "small", "big", "sup", "sub", "abbr", "q", "label", "time": break
            default: return nil
            }
            if let style = attributes["style"] { apply(style: style, to: &frame) }
            return frame
        }

        static func apply(style: String, to frame: inout InlineFrame) {
            for declaration in style.lowercased().split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let value = parts[1].replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
                switch parts[0] {
                case "font-weight":
                    if value == "bold" || value == "bolder" { frame.bold = true }
                    else if value == "normal" || value == "lighter" { frame.bold = false }
                    else if let weight = Int(value) { frame.bold = weight >= 600 }
                case "font-style":
                    if value.hasPrefix("italic") || value.hasPrefix("oblique") { frame.italic = true }
                    else if value == "normal" { frame.italic = false }
                case "text-decoration", "text-decoration-line":
                    if value.contains("underline") { frame.underline = true }
                    if value.contains("line-through") { frame.strikethrough = true }
                    if value == "none" {
                        frame.underline = false
                        frame.strikethrough = false
                    }
                default:
                    // Colours, fonts and sizes are the author's; the app's theme decides those.
                    break
                }
            }
        }

        mutating func closeCell() {
            guard cell != nil else { return }
            flush()
            tableRow = (tableRow ?? []) + [cell!]
            cell = nil
        }

        mutating func closeRow() {
            closeCell()
            if let row = tableRow, !row.isEmpty { tableRows.append(row) }
            tableRow = nil
        }

        mutating func closeTable() {
            closeRow()
            flush()
            let rows = tableRows.filter { $0.contains { !$0.runs.isEmpty } }
            tableRows = []
            guard !rows.isEmpty else { return }
            if rows.count == 1, rows[0].count == 1 {
                // A one-cell table is layout, not data: its text reads as a paragraph.
                blocks.append(.paragraph(rows[0][0].runs))
            } else {
                blocks.append(.table(rows: rows))
            }
        }

        mutating func flush() {
            var trimmed = runs
            while let first = trimmed.first, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                trimmed.removeFirst()
            }
            while let last = trimmed.last, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                trimmed.removeLast()
            }
            runs = []
            guard !trimmed.isEmpty else { return }
            trimmed[0].text = String(trimmed[0].text.drop { $0 == " " || $0 == "\n" })
            trimmed[trimmed.count - 1].text = String(trimmed[trimmed.count - 1].text.reversed().drop { $0 == " " || $0 == "\n" }.reversed())

            if cell != nil {
                // Paragraphs inside a cell become lines of that cell.
                if !cell!.runs.isEmpty { cell!.runs.append(RichRun(text: "\n")) }
                cell!.runs += trimmed
            } else if let headingLevel {
                blocks.append(.heading(level: headingLevel, runs: trimmed))
            } else if let itemNumber {
                let ordered = lists.last?.ordered ?? false
                blocks.append(.listItem(ordered: ordered, number: itemNumber, depth: max(0, lists.count - 1), runs: trimmed))
            } else if quoteDepth > 0 {
                blocks.append(.quote(trimmed))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }

        /// Only web and mail links survive. `javascript:`, data URLs and in-page anchors are dropped.
        static func safeLink(_ value: String) -> String? {
            let link = Entities.decode(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty, !link.hasPrefix("#") else { return nil }
            let lower = link.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || lower.hasPrefix("/") {
                return link
            }
            if lower.contains(":") { return nil }
            return link
        }
    }

    private struct Attributes {
        private var values: [String: String] = [:]

        init(_ tag: String) {
            guard tag.contains("=") else { return }
            let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(tag.startIndex..., in: tag)
            for match in regex.matches(in: tag, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
                let value = [3, 4, 5].lazy.compactMap { Range(match.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
                values[tag[nameRange].lowercased()] = value
            }
        }

        subscript(name: String) -> String? { values[name] }
    }

    enum Entities {
        static let named: [String: String] = {
            var table: [String: String] = [
                "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
                "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "rsquo": "\u{2019}", "lsquo": "\u{2018}",
                "rdquo": "\u{201D}", "ldquo": "\u{201C}", "sbquo": "\u{201A}", "bdquo": "\u{201E}", "bull": "\u{2022}",
                "euro": "\u{20AC}", "trade": "\u{2122}", "larr": "\u{2190}", "rarr": "\u{2192}", "uarr": "\u{2191}",
                "darr": "\u{2193}", "le": "\u{2264}", "ge": "\u{2265}", "ne": "\u{2260}", "minus": "\u{2212}",
                "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "zwnj": "", "zwj": "",
                "OElig": "\u{0152}", "oelig": "\u{0153}", "Scaron": "\u{0160}", "scaron": "\u{0161}",
            ]
            // Latin-1, in code point order from U+00A0.
            let latin1 = """
            nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 \
            acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde \
            Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc \
            Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring \
            aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute ocirc otilde ouml \
            divide oslash ugrave uacute ucirc uuml yacute thorn yuml
            """
            for (offset, name) in latin1.split(separator: " ").enumerated() {
                table[String(name)] = String(Character(Unicode.Scalar(UInt8(0xA0 + offset))))
            }
            table["shy"] = ""
            return table
        }()

        static func decode(_ text: String) -> String {
            guard text.contains("&") else { return text }
            var output = ""
            var index = text.startIndex
            while index < text.endIndex {
                if text[index] == "&",
                   let end = text[index...].prefix(12).firstIndex(of: ";") {
                    let entity = text[text.index(after: index)..<end]
                    if let value = value(for: entity) {
                        output += value
                        index = text.index(after: end)
                        continue
                    }
                }
                output.append(text[index])
                index = text.index(after: index)
            }
            return output
        }

        private static func value(for entity: Substring) -> String? {
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
            if entity.hasPrefix("#") {
                return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
            // Case matters for letters (Æ and æ); fall back to lowercase for "&AMP;" and friends.
            return named[String(entity)] ?? named[entity.lowercased()]
        }
    }
}
