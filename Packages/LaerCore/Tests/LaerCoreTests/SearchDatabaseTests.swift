import Foundation
import SQLite3
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
        try await db.update(group: "plans", hits: [first], complete: false)

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

    @Test func completeCourseListRemovesOnlyEntriesWithRevokedCourseAccess() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await SnapshotStore(rootDirectory: root, accountKey: "a").searchDatabase()
        try await db.update(group: "mixed", hits: [
            SearchHit(id: "revoked", kind: .plan, title: "Notes", courseId: 1),
            SearchHit(id: "allowed", kind: .plan, title: "Notes", courseId: 2),
            SearchHit(id: "personal", kind: .message, title: "Notes"),
        ], complete: true)
        try await db.retainCourses([2])
        let results = try await db.search("notes", scope: .everywhere, activeCourseIds: [])
        #expect(Set(results.map(\.id)) == ["allowed", "personal"])
    }

    @Test func rebuildingClosesTheOldIndexAndKeepsSourceSnapshots() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = SnapshotStore(rootDirectory: root, accountKey: "a")
        let index = try await snapshots.searchDatabase()
        let records = [SearchHit(id: "saved", kind: .course, title: "Cached course")]
        try await snapshots.save(records, collection: "course-source", coverage: .complete, checkpoint: nil, at: .now)
        try await index.update(group: "courses", hits: records, complete: true)
        try await snapshots.removeSearchIndex(courseIds: [])

        await #expect(throws: SearchDatabaseError.unavailable) { try await index.count() }
        let reopened = try await snapshots.searchDatabase()
        #expect(try await reopened.count() == 0)
        #expect(await snapshots.load(SearchHit.self, collection: "course-source")?.records == records)
    }

    @Test func ocrCheckpointSurvivesReopeningAndOldRevisionsCannotOverwriteIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try await SnapshotStore(rootDirectory: root, accountKey: "a").searchDatabase()
        var asset = LocalAsset(id: "file-1", relativePath: "v1.pdf", displayName: "Scan.pdf",
                               byteCount: 1, contentType: "application/pdf", downloadedAt: .distantPast)
        try await index.replaceDocument(asset: asset, resource: nil, pages: [DocumentSearchPage(index: 0, text: "Embedded textbook")])
        let first = DocumentOCRBatch(startPage: 0, pages: [DocumentSearchPage(index: 1, text: "Field observations")], nextPage: 2)
        try await index.appendOCRBatch(first, asset: asset, resource: nil)

        let reopened = try await SnapshotStore(rootDirectory: root, accountKey: "a").searchDatabase()
        #expect(try await reopened.nextOCRPage(resourceKey: asset.id, version: asset.relativePath) == 2)
        try await reopened.appendOCRBatch(DocumentOCRBatch(startPage: 2, pages: [], nextPage: nil), asset: asset, resource: nil)
        #expect(try await reopened.nextOCRPage(resourceKey: asset.id, version: asset.relativePath) == nil)
        try await reopened.appendOCRBatch(first, asset: asset, resource: nil)
        #expect(try await reopened.nextOCRPage(resourceKey: asset.id, version: asset.relativePath) == nil)
        let hits = try await reopened.search("field observations", scope: .everywhere, activeCourseIds: [])
        #expect(hits.first?.document?.page == 1)
        #expect(hits.first?.document?.recognizedText == true)
        #expect(try await reopened.search("embedded textbook", scope: .everywhere, activeCourseIds: []).first?.document?.page == 0)

        try await reopened.removeRecognizedText()
        #expect(try await reopened.nextOCRPage(resourceKey: asset.id, version: asset.relativePath) == 0)
        #expect(try await reopened.search("field observations", scope: .everywhere, activeCourseIds: []).isEmpty)
        #expect(try await reopened.search("embedded textbook", scope: .everywhere, activeCourseIds: []).first?.document?.page == 0)
        try await reopened.appendOCRBatch(first, asset: asset, resource: nil)

        let original = asset
        asset.relativePath = "v2.pdf"
        try await reopened.replaceDocument(asset: asset, resource: nil, pages: [])
        try await reopened.appendOCRBatch(first, asset: original, resource: nil)
        #expect(try await reopened.nextOCRPage(resourceKey: asset.id, version: asset.relativePath) == 0)
        #expect(try await reopened.search("field observations", scope: .everywhere, activeCourseIds: []).isEmpty)
    }

    @Test func addingOCRToTheExistingSchemaPreservesIndexedText() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("search.sqlite")
        let current = try SearchDatabase(url: url)
        try await current.update(group: "courses", hits: [SearchHit(id: "old", kind: .course, title: "Archived reading")], complete: true)
        try await current.close()

        // Version 3 had the same search tables and ranking index, without the OCR table.
        do {
            var database: OpaquePointer?
            let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
            defer { sqlite3_close(database) }
            try #require(opened == SQLITE_OK)
            let restoredV3 = sqlite3_exec(database, "DROP TABLE search_ocr; PRAGMA user_version = 3;", nil, nil, nil)
            try #require(restoredV3 == SQLITE_OK)
        }

        let migrated = try SearchDatabase(url: url)
        #expect(try await migrated.search("archived reading", scope: .everywhere, activeCourseIds: []).map(\.id) == ["old"])
        #expect(try await migrated.nextOCRPage(resourceKey: "file", version: "original.pdf") == 0)
    }
}
