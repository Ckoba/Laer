import Foundation

/// Reads lecture-prep notes from a folder the user picked. Never writes, moves or deletes.
public enum LectureNoteScanner {
    /// Larger files are not lecture notes.
    public static let maxBytes = 1_000_000

    /// Every `Courses/<course>/Lectures/*.md` below `folder` that parses as a lecture-prep note.
    /// Unreadable files are skipped, so one bad note never hides the rest.
    public static func scan(_ folder: URL, fileManager: FileManager = .default) -> [LectureNote] {
        let courses = folder.appendingPathComponent("Courses", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = fileManager.enumerator(at: courses, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        let rootPath = folder.standardizedFileURL.path
        var notes: [LectureNote] = []
        for case let url as URL in walker {
            guard url.pathExtension.lowercased() == "md",
                  url.deletingLastPathComponent().lastPathComponent == "Lectures" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= maxBytes,
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            var path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") { path.removeFirst(rootPath.count + 1) }
            if let note = LectureNoteParser.parse(text, path: path) { notes.append(note) }
        }
        return notes.sorted { $0.path < $1.path }
    }
}
