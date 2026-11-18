import Foundation
import Testing
@testable import LaerCore

@Suite struct SearchDatabaseTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func persistsAndIsolatesAccounts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await SnapshotStore(rootDirectory: root, accountKey: "north:42").searchDatabase()
        try await a.update(group: "courses", hits: [SearchHit(id: "1", kind: .course, title: "Økonomi")], complete: true)
        let reopened = try await SnapshotStore(rootDirectory: root, accountKey: "north:42").searchDatabase()
        let b = try await SnapshotStore(rootDirectory: root, accountKey: "south:42").searchDatabase()

        #expect(try await reopened.search("okono", scope: .everywhere, activeCourseIds: []).map(\.id) == ["1"])
        #expect(try await b.search("okono", scope: .everywhere, activeCourseIds: []).isEmpty)
    }

    @Test func partialRefreshPreservesOlderHitsAndContexts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await SnapshotStore(rootDirectory: root, accountKey: "a").searchDatabase()
        let resource = Resource(elementId: 9, elementType: "LearningToolElement", title: "Notes.pdf")
        let first = SearchHit(resource: resource, courseId: 12, context: "Week 3")
        let second = SearchHit(resource: resource, courseId: 12, context: "Week 4")
        let other = SearchHit(id: "material-second", kind: .material, title: "Notes.pdf", courseId: 12)
        try await db.update(group: "plans", hits: [first, second, other], complete: true)
        try await db.update(group: "folder", hits: [SearchHit(resource: resource, courseId: 12, context: "Archive")], complete: true)
        try await db.update(group: "plans", hits: [], complete: false)

        let hits = try await db.search("notes", scope: .activeCourses, activeCourseIds: [12])
        #expect(hits.count == 2)
        #expect(hits.first(where: { $0.id == first.id })?.contexts == ["Archive", "Week 3", "Week 4"])
        try await db.update(group: "plans", hits: [], complete: true)
        #expect(try await db.count() == 1)
    }

    @Test func phrasesMatchWholeWordsAndOperatorInputIsLiteral() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await SnapshotStore(rootDirectory: root, accountKey: "a").searchDatabase()
        try await db.update(group: "plans", hits: [
            SearchHit(id: "1", kind: .plan, title: "Lineær regression"),
            SearchHit(id: "2", kind: .plan, title: "Lineær og multipel regression"),
            SearchHit(id: "3", kind: .plan, title: "Lineær regressionsmodel"),
        ], complete: true)
        #expect(try await db.search("\"lineær regression\"", scope: .everywhere, activeCourseIds: []).map(\.id) == ["1"])
        #expect(try await db.search("lineær OR regression*", scope: .everywhere, activeCourseIds: []).isEmpty)
        #expect(try await db.count() == 3)
    }

    @Test func savedDocumentVersionsReplaceTheirTextAndRetainPagePositions() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await SnapshotStore(rootDirectory: root, accountKey: "a").searchDatabase()
        var asset = LocalAsset(id: "LearningToolElement-7", relativePath: "original.pdf", displayName: "Notes.pdf",
                               byteCount: 1, contentType: "application/pdf", downloadedAt: .distantPast)
        try await db.replaceDocument(asset: asset, resource: nil, pages: [
            DocumentSearchPage(index: 3, text: "Læs om lineær regression i dette afsnit.")
        ])
        let hits = try await db.search("lineær regression", scope: .everywhere, activeCourseIds: [])
        #expect(hits.first?.document == SearchDocumentPosition(resourceKey: asset.id, version: "original.pdf", page: 3))
        #expect(hits.first?.excerpt?.contains("Læs om lineær regression") == true)
        #expect(try await db.hasDocument(resourceKey: asset.id, version: "original.pdf"))

        asset.relativePath = "updated.pdf"
        try await db.replaceDocument(asset: asset, resource: nil, pages: [DocumentSearchPage(index: 0, text: "Korrelation")])
        #expect(try await db.search("regression", scope: .everywhere, activeCourseIds: []).isEmpty)
        #expect(try await db.search("korrelation", scope: .everywhere, activeCourseIds: []).first?.document?.page == 0)
        try await db.removeDocument(resourceKey: asset.id)
        #expect(try await db.count() == 0)
        #expect(!(try await db.hasDocument(resourceKey: asset.id, version: "updated.pdf")))
    }

    @Test func readsPlainTextAndReportsUnsupportedFiles() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("notes.txt")
        try Data("Æble, øvelse og årstal 2026".utf8).write(to: text)
        #expect(try DocumentSearchText.extract(from: text) == .readable([
            DocumentSearchPage(index: nil, text: "Æble, øvelse og årstal 2026")
        ], partial: false))
        #expect(try DocumentSearchText.extract(from: root.appendingPathComponent("notes.docx")) == .unsupported)
    }
}
