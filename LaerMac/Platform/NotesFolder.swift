import AppKit
import Foundation

/// The notes folder the user picked once, kept as a read-only security-scoped bookmark.
/// Access stays open while a folder is set, so linked readings can open in the viewer.
@MainActor
final class NotesFolder {
    private static let key = "notesFolderBookmark"
    private(set) var url: URL?

    /// The saved folder with access open. Nil when none is saved or it no longer resolves.
    func restore() -> URL? {
        if let url { return url }
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return nil }
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale),
              resolved.startAccessingSecurityScopedResource() else { return nil }
        url = resolved
        // A moved or renamed folder still resolves; save a fresh bookmark while access is open.
        if isStale, let fresh = try? Self.bookmark(resolved) {
            UserDefaults.standard.set(fresh, forKey: Self.key)
        }
        return resolved
    }

    /// Shows an open panel for a folder and saves the choice for later launches.
    func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder with your lecture notes. Laer only reads it."
        guard panel.runModal() == .OK, let picked = panel.url,
              let data = try? Self.bookmark(picked) else { return nil }
        forget()
        UserDefaults.standard.set(data, forKey: Self.key)
        return restore()
    }

    func forget() {
        url?.stopAccessingSecurityScopedResource()
        url = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
