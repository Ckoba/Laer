import AppKit
import PDFKit

/// Saving a copy where the person chose. The new file replaces an existing one only once it is
/// complete, so a failed save never leaves them with less than they had, and a failure is shown.
@MainActor
enum FileExport {
    static func copy(_ source: URL, to destination: URL) {
        place(destination) { try Data(contentsOf: source, options: .mappedIfSafe) }
    }

    static func write(_ document: PDFDocument, to destination: URL) {
        place(destination) {
            guard let data = document.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
    }

    private static func place(_ destination: URL, bytes: () throws -> Data) {
        do {
            try bytes().write(to: destination, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t save “\(destination.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
