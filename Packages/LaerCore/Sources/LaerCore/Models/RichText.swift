import Foundation

/// A styled stretch of text inside a block.
public struct RichRun: Hashable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var link: String?

    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.link = link
    }
}

/// Course text reduced to blocks a native view can draw. Scripts, styles, forms and frames are dropped.
public enum RichBlock: Hashable, Sendable {
    case heading(level: Int, runs: [RichRun])
    case paragraph([RichRun])
    case listItem(ordered: Bool, number: Int, depth: Int, runs: [RichRun])
    case quote([RichRun])
    case code(String)
    case image(source: String, alt: String?)
    case embed(source: String)
    case rule
}

/// A small HTML reader for course text. It is not a browser: unknown tags are ignored and their text kept.
public enum RichText {
    public static func blocks(fromHTML html: String) -> [RichBlock] {
        var reader = Reader()
        reader.read(html)
        return reader.finish()
    }

    /// Plain text with paragraph breaks, for previews and accessibility.
    public static func plainText(_ blocks: [RichBlock]) -> String {
        blocks.compactMap { block -> String? in
            switch block {
            case .heading(_, let runs), .paragraph(let runs), .quote(let runs), .listItem(_, _, _, let runs):
                return runs.map(\.text).joined()
            case .code(let text): return text
            case .image(_, let alt): return alt
            case .embed, .rule: return nil
            }
        }.joined(separator: "\n\n")
    }

    // MARK: - Reader

    private struct ListContext {
        var ordered: Bool
        var counter = 0
    }

    private struct Reader {
        var blocks: [RichBlock] = []
        var runs: [RichRun] = []
        var bold = 0
        var italic = 0
        var code = 0
        var links: [String?] = []
        var lists: [ListContext] = []
        var headingLevel: Int?
        var quoteDepth = 0
        var preText: String?
        var skipDepth = 0
        var itemNumber: Int?

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
            let run = RichRun(text: text, bold: bold > 0, italic: italic > 0, code: code > 0, link: links.last ?? nil)
            if var last = runs.last, last.bold == run.bold, last.italic == run.italic, last.code == run.code, last.link == run.link {
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

            if ["script", "style", "noscript", "template", "form", "select", "button", "textarea", "svg"].contains(name) {
                if raw.hasSuffix("/") { return }
                skipDepth += isClosing ? (skipDepth > 0 ? -1 : 0) : 1
                return
            }
            guard skipDepth == 0 else { return }

            switch (name, isClosing) {
            case ("b", false), ("strong", false): bold += 1
            case ("b", true), ("strong", true): bold = max(0, bold - 1)
            case ("i", false), ("em", false): italic += 1
            case ("i", true), ("em", true): italic = max(0, italic - 1)
            case ("code", false) where preText == nil: code += 1
            case ("code", true) where preText == nil: code = max(0, code - 1)
            case ("a", false): links.append(attributes["href"].flatMap(Self.safeLink))
            case ("a", true): if !links.isEmpty { links.removeLast() }
            case ("br", _):
                if preText != nil { preText! += "\n" } else { append("\n") }
            case ("p", _), ("div", _), ("section", _), ("article", _), ("tr", _), ("table", _), ("figure", _), ("figcaption", _):
                flush()
            case ("td", true), ("th", true):
                append("  ")
            case ("h1", false), ("h2", false), ("h3", false), ("h4", false), ("h5", false), ("h6", false):
                flush()
                headingLevel = Int(name.dropFirst()) ?? 1
            case ("h1", true), ("h2", true), ("h3", true), ("h4", true), ("h5", true), ("h6", true):
                flush()
                headingLevel = nil
            case ("ul", false), ("ol", false):
                flush()
                lists.append(ListContext(ordered: name == "ol"))
            case ("ul", true), ("ol", true):
                flush()
                if !lists.isEmpty { lists.removeLast() }
            case ("li", false):
                flush()
                if !lists.isEmpty {
                    lists[lists.count - 1].counter += 1
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
                    blocks.append(.code(text.trimmingCharacters(in: .newlines)))
                }
                preText = nil
            case ("hr", _):
                flush()
                blocks.append(.rule)
            case ("img", _):
                if let source = attributes["src"].flatMap(Self.safeLink) {
                    flush()
                    blocks.append(.image(source: source, alt: attributes["alt"].map(Entities.decode)))
                }
            case ("iframe", false), ("video", false), ("audio", false), ("embed", false), ("object", false):
                if let source = (attributes["src"] ?? attributes["data"]).flatMap(Self.safeLink) {
                    flush()
                    blocks.append(.embed(source: source))
                }
            default:
                break
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

            if let headingLevel {
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

        /// Only web and mail links survive. `javascript:` and data URLs are dropped.
        static func safeLink(_ value: String) -> String? {
            let link = Entities.decode(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty else { return nil }
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
        static let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
            "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "rsquo": "\u{2019}", "lsquo": "\u{2018}",
            "rdquo": "\u{201D}", "ldquo": "\u{201C}", "bull": "\u{2022}", "copy": "\u{00A9}", "shy": "",
        ]

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
            return named[entity.lowercased()]
        }
    }
}
