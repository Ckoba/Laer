import Foundation

/// A one-page document assembled from the first section of a linearized PDF.
/// The caller still downloads and validates the original document in full.
public enum LinearizedPDFPreview {
    public struct Header: Sendable {
        public let byteCount: Int
        fileprivate let object: Int
        fileprivate let objectRange: Range<Int>
        fileprivate let page: Int
    }

    private struct Entry {
        let offset: Int
        let generation: Int
    }

    public static func header(in prefix: Data, length: Int) -> Header? {
        guard prefix.starts(with: Data("%PDF-".utf8)) else { return nil }
        let front = ascii(prefix.prefix(4096))
        guard let (whole, parts) = groups(#"(?s)\b(\d+)\s+(\d+)\s+obj\b\s*<<([^>]*)>>\s*endobj"#, in: front),
              let object = Int(parts[0]), parts[2].contains("/Linearized"),
              let sourceLength = number("L", in: parts[2]), sourceLength == length,
              let end = number("E", in: parts[2]), (1024...1_500_000).contains(end), end < length,
              let page = number("O", in: parts[2]), (1...100_000).contains(page),
              (number("P", in: parts[2]) ?? 0) == 0 else { return nil }
        return Header(byteCount: end, object: object,
                      objectRange: whole.location..<whole.location + whole.length, page: page)
    }

    public static func page(from data: Data, header: Header) -> Data? {
        guard data.count >= header.byteCount, header.objectRange.upperBound < header.byteCount else { return nil }
        let prefix = data.prefix(header.byteCount)
        let indexText = ascii(prefix.prefix(65_536))
        guard let (xref, _) = groups(#"\bxref\s"#, in: indexText, start: header.objectRange.upperBound),
              let (trailer, parts) = groups(#"(?s)\btrailer\s*<<(.*?)>>"#, in: indexText, start: xref.location + xref.length),
              !parts[0].contains("/Encrypt"),
              let catalog = reference("Root", in: parts[0]),
              var entries = directory(from: (indexText as NSString).substring(with: NSRange(
                location: xref.location + xref.length, length: trailer.location - (xref.location + xref.length)
              )), end: prefix.count), let entry = entries[header.page],
              let catalogEntry = entries[catalog.id], catalogEntry.generation == catalog.generation else { return nil }
        let pageText = objectText(prefix, entry: entry)
        let catalogText = objectText(prefix, entry: catalogEntry)
        guard let (_, pageIdentity) = groups(#"^\s*(\d+)\s+(\d+)\s+obj\b"#, in: pageText),
              Int(pageIdentity[0]) == header.page, Int(pageIdentity[1]) == entry.generation,
              groups(#"/Type\s*/Page\b"#, in: pageText) != nil,
              groups(#"/Type\s*/Catalog\b"#, in: catalogText) != nil,
              pageText.contains("/Resources"), pageText.contains("/MediaBox"),
              ["/Annots", "/AA"].allSatisfy({ !pageText.contains($0) }),
              ["/OCProperties", "/OutputIntents", "/AcroForm"].allSatisfy({ !catalogText.contains($0) }),
              let parent = reference("Parent", in: pageText),
              Set([parent.id, catalog.id, header.page, header.object]).count == 4 else { return nil }

        entries[header.object] = nil
        var out = Data(prefix)
        out.replaceSubrange(header.objectRange, with: repeatElement(UInt8(32), count: header.objectRange.count))
        out.append(10)
        func appendObject(_ id: (id: Int, generation: Int), _ value: String) {
            entries[id.id] = Entry(offset: out.count, generation: id.generation)
            out.append(contentsOf: "\(id.id) \(id.generation) obj\n<< \(value) >>\nendobj\n".utf8)
        }
        appendObject(catalog, "/Type /Catalog /Pages \(parent.id) \(parent.generation) R")
        appendObject(parent, "/Type /Pages /Kids [\(header.page) \(entry.generation) R] /Count 1")

        let finalXRef = out.count
        var runs: [[Int]] = []
        for id in entries.keys.sorted() where id > 0 {
            if let last = runs.last?.last, last + 1 == id { runs[runs.count - 1].append(id) }
            else { runs.append([id]) }
        }
        out.append(contentsOf: "xref\n0 1\n0000000000 65535 f \n".utf8)
        for run in runs {
            guard let id = run.first else { continue }
            out.append(contentsOf: "\(id) \(run.count)\n".utf8)
            for key in run {
                guard let value = entries[key] else { return nil }
                out.append(contentsOf: String(format: "%010lld %05d n \n", Int64(value.offset), value.generation).utf8)
            }
        }
        guard let last = runs.last?.last else { return nil }
        out.append(contentsOf: "trailer\n<< /Size \(last + 1) /Root \(catalog.id) \(catalog.generation) R >>\nstartxref\n\(finalXRef)\n%%EOF\n".utf8)
        return out
    }

    private static func directory(from text: String, end: Int) -> [Int: Entry]? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }.filter { !$0.isEmpty }
        var cursor = 0
        var table: [Int: Entry] = [:]
        while cursor < lines.count {
            let range = lines[cursor]
            guard range.count == 2, let first = Int(range[0]), let count = Int(range[1]), (1...10_000).contains(count),
                  (0...100_000).contains(first), first + count <= 100_000, cursor + count < lines.count else { return nil }
            cursor += 1
            for id in first..<first + count {
                let row = lines[cursor]
                cursor += 1
                guard row.count == 3, row[0].count == 10, row[1].count == 5 else { return nil }
                if row[2] == "f" { continue }
                guard row[2] == "n", let offset = Int(row[0]), (1..<end).contains(offset),
                      let gen = Int(row[1]), (0...65535).contains(gen), table[id] == nil else { return nil }
                table[id] = Entry(offset: offset, generation: gen)
            }
        }
        return table
    }

    private static func objectText(_ source: Data, entry: Entry) -> String {
        let bytes = source[entry.offset..<min(entry.offset + 8192, source.count)]
        let end = bytes.range(of: Data("endobj".utf8))?.lowerBound ?? bytes.endIndex
        return ascii(bytes[..<end])
    }

    private static func ascii<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        String(decoding: bytes.map { $0 < 128 ? $0 : 32 }, as: UTF8.self)
    }

    private static func groups(_ pattern: String, in text: String, start: Int = 0) -> (NSRange, [String])? {
        let value = text as NSString
        guard start <= value.length, let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: start, length: value.length - start)) else { return nil }
        return (match.range, (1..<match.numberOfRanges).map { value.substring(with: match.range(at: $0)) })
    }

    private static func number(_ name: String, in text: String) -> Int? {
        groups("/" + name + #"\s+(\d+)\b"#, in: text).flatMap { Int($0.1[0]) }
    }

    private static func reference(_ name: String, in text: String) -> (id: Int, generation: Int)? {
        guard let (_, parts) = groups("/" + name + #"\s+(\d+)\s+(\d+)\s+R\b"#, in: text),
              let id = Int(parts[0]), (1...100_000).contains(id),
              let generation = Int(parts[1]), (0...65535).contains(generation) else { return nil }
        return (id, generation)
    }
}
