import Foundation
import LaerCore

/// A saved file open in the right panel.
struct ViewerItem: Identifiable, Hashable {
    var id: String
    var title: String
    /// Nil while the file is on its way, so the tab can open at once.
    var fileURL: URL?

    var isPDF: Bool { fileURL?.pathExtension.lowercased() == "pdf" }
    var isSlides: Bool { ["ppt", "pptx", "key", "pps", "ppsx"].contains(fileURL?.pathExtension.lowercased() ?? "") }

    /// Such as "PDF · 567 KB".
    var typeAndSize: String {
        guard let fileURL else { return "Opening" }
        let kind = fileURL.pathExtension.uppercased()
        let bytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(kind) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }
}
