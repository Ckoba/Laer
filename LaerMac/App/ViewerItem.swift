import Foundation
import LaerCore

/// A saved file open in the right panel.
struct ViewerItem: Identifiable, Hashable {
    var id: String
    var title: String
    /// Nil while the file is on its way, so the tab can open at once.
    var fileURL: URL?
    /// A PDF page to show first, zero-based, such as a course's rows in an exam plan.
    var startPage: Int?
    var searchMatch: String?
    /// Identifies this open while the preview gives way to the downloaded file.
    var openingID: UUID? = nil
    var firstPDFPage: Data? = nil

    /// A New tab page rather than a file.
    var isNewTab: Bool { id.hasPrefix(Self.newTabPrefix) }

    private static let newTabPrefix = "newtab:"

    static func newTab() -> ViewerItem {
        ViewerItem(id: newTabPrefix + UUID().uuidString, title: "New tab", fileURL: nil)
    }

    static let slideExtensions: Set<String> = ["ppt", "pptx", "key", "pps", "ppsx"]
    static let wordExtensions: Set<String> = ["doc", "docx"]
    private static let pdfConvertibleExtensions = slideExtensions.union(wordExtensions)

    var isPDF: Bool { fileURL?.pathExtension.lowercased() == "pdf" }
    var isWord: Bool { Self.wordExtensions.contains(fileURL?.pathExtension.lowercased() ?? "") }
    var supportsPDFConversion: Bool { Self.pdfConvertibleExtensions.contains(fileURL?.pathExtension.lowercased() ?? "") }

    static func mayNeedPDFConversion(named filename: String) -> Bool {
        pdfConvertibleExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    /// Such as "PDF · 567 KB".
    var typeAndSize: String {
        guard let fileURL else { return "Opening" }
        let kind = fileURL.pathExtension.uppercased()
        let bytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(kind) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }
}
