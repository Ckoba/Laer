import AppKit
import PDFKit

/// Saving a copy where the person chose. The new file replaces an existing one only once it is
/// complete, so a failed save never leaves them with less than they had, and a failure is shown.
/// Reading, encoding and writing run off the main actor, so a large file or a slow disk never
/// freezes the window.
@MainActor
enum FileExport {
    static func copy(_ source: URL, to destination: URL) async {
        await place(destination) { try Data(contentsOf: source, options: .mappedIfSafe) }
    }

    /// Saves `source` with the page rotations shown in `document`. The on-screen document is only
    /// read here, on the main actor; a fresh copy of the file is opened and encoded in the background.
    static func write(_ document: PDFDocument, from source: URL, to destination: URL) async {
        let rotations = (0..<document.pageCount).map { document.page(at: $0)?.rotation ?? 0 }
        let encoded: Data? = await Task.detached(priority: .userInitiated) {
            guard let copy = PDFDocument(url: source), copy.pageCount == rotations.count else { return nil }
            for (index, rotation) in rotations.enumerated() { copy.page(at: index)?.rotation = rotation }
            return copy.dataRepresentation()
        }.value
        // The shown pages no longer match the file on disk: encode what is on screen instead.
        guard let data = encoded ?? document.dataRepresentation() else {
            show(CocoaError(.fileWriteUnknown), for: destination)
            return
        }
        await place(destination) { data }
    }

    private static func place(_ destination: URL, bytes: @escaping @Sendable () throws -> Data) async {
        let failure: Error? = await Task.detached(priority: .userInitiated) {
            do {
                try bytes().write(to: destination, options: .atomic)
                return nil
            } catch {
                return error
            }
        }.value
        if let failure { show(failure, for: destination) }
    }

    private static func show(_ error: Error, for destination: URL) {
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn’t save “\(destination.lastPathComponent)”"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
