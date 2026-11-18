import Foundation
import PDFKit

public struct DocumentSearchPage: Sendable, Equatable {
    public var index: Int?
    public var text: String

    public init(index: Int?, text: String) {
        self.index = index
        self.text = text
    }
}

public enum DocumentSearchText {
    public static let formats: Set<String> = ["pdf", "txt", "md", "markdown"]
    static let maxFileSize = 24 * 1024 * 1024
    static let maxPDFPages = 400
    private static let maxTextSize = 400_000

    public enum Result: Sendable, Equatable {
        case readable([DocumentSearchPage], partial: Bool)
        case unsupported, tooLarge, encrypted, unreadable, noText
    }

    /// Reads the saved original only. The caller runs this on a background executor.
    public static func extract(from url: URL) throws -> Result {
        try Task.checkCancellation()
        let format = url.pathExtension.lowercased()
        guard formats.contains(format) else { return .unsupported }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let fileSize = values.fileSize else { return .unreadable }
        guard fileSize <= maxFileSize else { return .tooLarge }

        if format == "pdf" {
            guard let document = PDFDocument(url: url) else { return .unreadable }
            guard !document.isLocked else { return .encrypted }
            var pages: [DocumentSearchPage] = []
            var remaining = maxTextSize
            let pageLimit = min(document.pageCount, maxPDFPages)
            var partial = pageLimit < document.pageCount
            for index in 0..<pageLimit {
                try Task.checkCancellation()
                guard remaining > 0 else { partial = true; break }
                let text = autoreleasepool { document.page(at: index)?.string }
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    partial = true
                    continue
                }
                let clipped = String(text.prefix(min(remaining, 24_000)))
                partial = partial || clipped != text
                remaining -= clipped.count
                pages.append(DocumentSearchPage(index: index, text: clipped))
            }
            return pages.isEmpty ? .noText : .readable(pages, partial: partial)
        }

        // UTF-8 text only. Read a bounded prefix, allowing up to four bytes per scalar.
        guard let input = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? input.close() }
        guard let bytes = try? input.read(upToCount: maxTextSize * 4), !bytes.isEmpty else { return .noText }
        let utf8 = fileSize > bytes.count ? bytes.dropLast(3) : bytes[...]
        guard let text = String(data: Data(utf8), encoding: .utf8) ?? (fileSize > bytes.count ? String(decoding: bytes, as: UTF8.self) : nil)
        else { return .unreadable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noText }
        let bounded = String(text.prefix(maxTextSize))
        return .readable([DocumentSearchPage(index: nil, text: bounded)], partial: fileSize > bytes.count || bounded != text)
    }
}
