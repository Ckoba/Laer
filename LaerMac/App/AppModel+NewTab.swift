import Foundation
import LaerCore

/// A file opened in the viewer, kept so the New tab page can reopen it.
struct RecentFile: Codable, Hashable, Identifiable {
    var resource: Resource
    var openedAt: Date

    var id: String { resource.id }
}

extension AppModel {
    /// Enough for "Show more"; older files drop off the end.
    static let recentFileLimit = 10

    /// Opens a New tab in the viewer, or shows the one already open.
    func openNewTab() {
        if let open = viewerTabs.first(where: \.isNewTab) {
            viewerItem = open
        } else {
            viewerItem = .newTab()
        }
    }

    /// Closes the New tab after one of its buttons took the person elsewhere.
    func closeNewTab() {
        if let tab = viewerTabs.first(where: \.isNewTab) { closeTab(tab) }
    }

    func noteRecent(_ resource: Resource) {
        recentFiles.removeAll { $0.id == resource.id }
        recentFiles.insert(RecentFile(resource: resource, openedAt: Date()), at: 0)
        if recentFiles.count > Self.recentFileLimit { recentFiles.removeLast(recentFiles.count - Self.recentFileLimit) }
        saveRecentFiles()
    }

    /// Per person, so one account never sees another's files.
    func loadRecentFiles(personId: Int) {
        recentFilesPersonId = personId
        guard let data = UserDefaults.standard.data(forKey: Self.recentFilesKey(personId)),
              let saved = try? JSONDecoder().decode([RecentFile].self, from: data) else {
            recentFiles = []
            return
        }
        recentFiles = saved
    }

    /// Signing out removes the list from disk as well as from screen.
    func forgetRecentFiles() {
        if let personId = recentFilesPersonId {
            UserDefaults.standard.removeObject(forKey: Self.recentFilesKey(personId))
        }
        recentFiles = []
    }

    private func saveRecentFiles() {
        guard let personId = recentFilesPersonId, let data = try? JSONEncoder().encode(recentFiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentFilesKey(personId))
    }

    private static func recentFilesKey(_ personId: Int) -> String { "recentFiles-\(personId)" }
}
