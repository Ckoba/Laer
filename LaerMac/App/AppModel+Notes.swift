import Foundation
import LaerCore

extension AppModel {
    /// Wikilinks in briefs open through this scheme. It never leaves the app.
    static let noteLinkScheme = "laer-note"

    /// Reads the picked notes folder again, at most once a minute unless forced, off the main thread.
    func loadLectureNotes(force: Bool = false) async {
        guard let folder = notesFolder.restore() else {
            lectureNotes = []
            notesFolderName = nil
            return
        }
        notesFolderName = folder.lastPathComponent
        if !force, let last = notesReadAt, Date().timeIntervalSince(last) < 60 { return }
        notesReadAt = Date()
        lectureNotes = await Task.detached(priority: .utility) { LectureNoteScanner.scan(folder) }.value
    }

    func chooseNotesFolder() async {
        guard notesFolder.choose() != nil else { return }
        await loadLectureNotes(force: true)
    }

    func forgetNotesFolder() {
        notesFolder.forget()
        lectureNotes = []
        notesFolderName = nil
        notesReadAt = nil
    }

    func lectureNote(for plan: PlanPreview, course: Course?) -> LectureNote? {
        guard !lectureNotes.isEmpty else { return nil }
        return LectureNoteMatcher.note(for: plan, course: course, in: lectureNotes)
    }

    /// Opens a brief's wikilink in the viewer when it names a file inside the notes folder.
    func openNoteLink(_ url: URL) -> Bool {
        guard url.scheme == Self.noteLinkScheme, let folder = notesFolder.url else { return false }
        let target = String(url.absoluteString.dropFirst(Self.noteLinkScheme.count + 1)).removingPercentEncoding ?? ""
        guard let file = WikiLink.candidates(target, in: folder).first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
            return false
        }
        viewerItem = ViewerItem(id: "note:\(file.path)", title: file.deletingPathExtension().lastPathComponent, fileURL: file)
        return true
    }
}
