import Foundation
import SQLite3

public enum SearchDatabaseError: Error, Equatable, Sendable {
    case sqlite(Int32)
    case incompatibleSchema(Int64)
    case unavailable
}

/// One account's metadata index. Source collections refresh in independent transactions.
public actor SearchDatabase {
    private let db: SearchConnection

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SearchConnection(url: url)
        try db.migrate()
        self.db = db
    }

    public func update(group: String, hits: [SearchHit], complete: Bool) throws {
        try write(group: group, hits: hits, complete: complete)
    }

    public func hasDocument(resourceKey: String, version: String) throws -> Bool {
        try db.withStatement("SELECT revision FROM search_versions WHERE collection = ?") { statement in
            try db.bind([.text("document-" + resourceKey)], to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return false }
            try db.check(status, expected: SQLITE_ROW)
            return String(decoding: db.data(statement, column: 0), as: UTF8.self) == version
        }
    }

    public func replaceDocument(asset: LocalAsset, resource: Resource?, pages: [DocumentSearchPage]) throws {
        let group = "document-" + asset.id
        var bodies: [String: String] = [:]
        let hits = pages.map { page -> SearchHit in
            let id = "\(group)-\(page.index ?? 0)"
            bodies[id] = page.text
            var hit = SearchHit(id: id, kind: .material, title: resource?.title ?? asset.displayName,
                                detail: resource?.path, courseId: resource?.courseId,
                                fileExtension: SearchHit.fileExtension(of: asset.displayName), resource: resource)
            hit.document = SearchDocumentPosition(resourceKey: asset.id, version: asset.relativePath, page: page.index)
            return hit
        }
        try write(group: group, hits: hits, complete: true, bodies: bodies, version: asset.relativePath)
    }

    public func removeDocument(resourceKey: String) throws {
        let key = "document-" + resourceKey
        try db.transaction {
            try db.run("DELETE FROM search_records WHERE collection = ?", [.text(key)])
            try db.run("DELETE FROM search_versions WHERE collection = ?", [.text(key)])
        }
    }

    /// A complete, authenticated course listing can invalidate entries for a formerly visible course.
    public func retainCourses(_ courseIds: Set<Int>) throws {
        let encoded = String(decoding: try JSONEncoder().encode(courseIds), as: UTF8.self)
        let removed = "course IS NOT NULL AND course NOT IN (SELECT value FROM json_each(?))"
        try db.transaction {
            try db.run("DELETE FROM search_versions WHERE collection IN (SELECT collection FROM search_records WHERE \(removed))", [.text(encoded)])
            try db.run("DELETE FROM search_records WHERE \(removed)", [.text(encoded)])
        }
    }

    private func write(group: String, hits: [SearchHit], complete: Bool, bodies: [String: String] = [:], version: String? = nil) throws {
        try db.transaction {
            var hits = SearchHit.unique(hits)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let ids = String(decoding: try encoder.encode(hits.map(\.id)), as: UTF8.self)
            if complete {
                try db.run("""
                    DELETE FROM search_records WHERE collection = ?
                    AND hit_id NOT IN (SELECT value FROM json_each(?))
                    """, [.text(group), .text(ids)])
            } else if !hits.isEmpty {
                let retained = try db.withStatement("""
                    SELECT payload FROM search_records WHERE collection = ?
                    AND hit_id IN (SELECT value FROM json_each(?))
                    """) { statement in
                    try db.bind([.text(group), .text(ids)], to: statement)
                    let decoder = JSONDecoder()
                    var previous: [SearchHit] = []
                    while true {
                        let status = sqlite3_step(statement)
                        if status == SQLITE_DONE { return previous }
                        try db.check(status, expected: SQLITE_ROW)
                        previous.append(try decoder.decode(SearchHit.self, from: db.data(statement, column: 0)))
                    }
                }
                hits = SearchHit.unique(hits + retained)
            }
            try db.withStatement("""
                INSERT INTO search_records(collection, hit_id, kind, course, format, title, detail, payload, body)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(collection, hit_id) DO UPDATE SET
                    kind = excluded.kind, course = excluded.course, format = excluded.format,
                    title = excluded.title, detail = excluded.detail, payload = excluded.payload, body = excluded.body
                WHERE payload != excluded.payload OR body IS NOT excluded.body
                """) { statement in
                for hit in hits {
                    try Task.checkCancellation()
                    let body = bodies[hit.id]
                    let detail = ([hit.detail ?? ""] + (hit.contexts ?? []) + [body ?? ""]).joined(separator: " ")
                    try db.bind([
                        .text(group), .text(hit.id), .text(hit.kind.rawValue),
                        hit.courseId.map { .integer(Int64($0)) } ?? .null,
                        hit.fileExtension.map { .text($0.lowercased()) } ?? .null,
                        .text(SearchIndex.normalize(hit.title)), .text(SearchIndex.normalize(detail)),
                        .text(String(decoding: try encoder.encode(hit), as: UTF8.self)),
                        body.map { .text($0.replacingOccurrences(of: "\0", with: " ")) } ?? .null,
                    ], to: statement)
                    try db.check(sqlite3_step(statement), expected: SQLITE_DONE)
                    try db.check(sqlite3_reset(statement))
                }
            }
            if let version {
                try db.run("INSERT OR REPLACE INTO search_versions VALUES (?, ?)", [.text(group), .text(version)])
            }
        }
    }

    public func search(
        _ text: String, scope: SearchScope, activeCourseIds: Set<Int>,
        kinds: Set<SearchKind> = [], fileExtension: String? = nil, limit: Int = 60
    ) throws -> [SearchHit] {
        let input = String(text.prefix(512))
        let match = Self.ftsQuery(input)
        guard match != nil || fileExtension != nil else { return [] }
        let limit = min(max(0, limit), 501)
        guard limit > 0 else { return [] }

        var clauses: [String] = []
        var bindings: [SearchBinding] = []
        let from: String
        let relevance: String
        if let match {
            from = "search_text JOIN search_records r ON r.rowid = search_text.rowid"
            relevance = "search_text.rank, "
            clauses.append("search_text MATCH ?")
            bindings.append(.text(match))
        } else {
            from = "search_records r"
            relevance = ""
        }
        if !kinds.isEmpty {
            clauses.append("r.kind IN (\(Self.parameters(kinds.count)))")
            bindings += kinds.map { .text($0.rawValue) }
        }
        if let fileExtension {
            clauses.append("r.format = ?")
            bindings.append(.text(fileExtension.lowercased()))
        }
        switch scope {
        case .everywhere: break
        case .course(let id):
            clauses.append("r.course = ?")
            bindings.append(.integer(Int64(id)))
        case .activeCourses:
            guard !activeCourseIds.isEmpty else { return [] }
            clauses.append("r.course IN (SELECT value FROM json_each(?))")
            bindings.append(.text(String(decoding: try JSONEncoder().encode(activeCourseIds), as: UTF8.self)))
        }
        bindings.append(.text(SearchIndex.normalize(input)))
        let selection = """
            SELECT r.payload, r.body FROM \(from)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY (r.title = ?) DESC, \(relevance)r.title, r.hit_id, r.collection
            """
        let decoder = JSONDecoder()
        let ranked = try db.withStatement(selection) { statement in
            try db.bind(bindings, to: statement)
            var seen = Set<String>()
            var results: [SearchHit] = []
            while results.count < limit {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                try db.check(status, expected: SQLITE_ROW)
                var hit = try decoder.decode(SearchHit.self, from: db.data(statement, column: 0))
                if hit.document != nil {
                    let body = String(decoding: db.data(statement, column: 1), as: UTF8.self)
                    Self.addExcerpt(to: &hit, from: body, query: input)
                }
                if seen.insert(hit.id).inserted { results.append(hit) }
            }
            return results
        }
        guard !ranked.isEmpty else { return [] }
        let variants = try db.withStatement("""
            SELECT payload FROM search_records WHERE hit_id IN (\(Self.parameters(ranked.count)))
            ORDER BY hit_id, collection
            """) { statement in
            try db.bind(ranked.map { .text($0.id) }, to: statement)
            var hits: [SearchHit] = []
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return hits }
                try db.check(status, expected: SQLITE_ROW)
                hits.append(try decoder.decode(SearchHit.self, from: db.data(statement, column: 0)))
            }
        }
        return SearchHit.unique(ranked + variants)
    }

    public func count() throws -> Int {
        Int(try db.scalar("SELECT COUNT(DISTINCT hit_id) FROM search_records"))
    }

    func close() throws { try db.close() }

    static func ftsQuery(_ text: String) -> String? {
        let terms = text.split(separator: "\"", omittingEmptySubsequences: false).enumerated().flatMap { index, part in
            let folded = SearchIndex.normalize(String(part))
            if index.isMultiple(of: 2) {
                return folded.split(separator: " ").map { "\"\($0)\"*" }
            }
            return folded.isEmpty ? [] : ["\"\(folded)\""]
        }
        return terms.isEmpty ? nil : terms.prefix(24).joined(separator: " AND ")
    }

    static func addExcerpt(to hit: inout SearchHit, from body: String, query: String) {
        let phrases = query.split(separator: "\"", omittingEmptySubsequences: false).enumerated().compactMap { index, part in
            index.isMultiple(of: 2) || part.isEmpty ? nil : String(part)
        }
        let words = query.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let found = (phrases + words).prefix(24).lazy.compactMap { word in
            body.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
        }.first
        let start = found.map { body.index($0.lowerBound, offsetBy: -48, limitedBy: body.startIndex) ?? body.startIndex } ?? body.startIndex
        let end = body.index(start, offsetBy: 160, limitedBy: body.endIndex) ?? body.endIndex
        hit.excerpt = (start == body.startIndex ? "" : "…") + String(body[start..<end]) + (end == body.endIndex ? "" : "…")
        if let found { hit.matchedText = String(body[found]) }
    }

    private static func parameters(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

private enum SearchBinding {
    case text(String)
    case integer(Int64)
    case null
}

/// Owned exclusively by the index actor once initialized.
private final class SearchConnection {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw SearchDatabaseError.sqlite(result)
        }
        handle = database
    }

    deinit { sqlite3_close(handle) }

    func close() throws {
        guard let handle else { return }
        try check(sqlite3_close(handle))
        self.handle = nil
    }

    func migrate() throws {
        let version = try scalar("PRAGMA user_version")
        guard version <= 2 else { throw SearchDatabaseError.incompatibleSchema(version) }
        guard version < 2 else { return }
        try transaction {
            if version == 0 {
                try exec("""
                CREATE TABLE search_records (
                    collection TEXT NOT NULL, hit_id TEXT NOT NULL, kind TEXT NOT NULL,
                    course INTEGER, format TEXT, title TEXT NOT NULL, detail TEXT NOT NULL, payload TEXT NOT NULL,
                    UNIQUE(collection, hit_id)
                );
                CREATE INDEX search_records_id ON search_records(hit_id);
                CREATE INDEX search_records_format ON search_records(format);
                CREATE VIRTUAL TABLE search_text USING fts5(
                    title, detail, hit_id, content='search_records', content_rowid='rowid',
                    tokenize='unicode61', prefix='2 3'
                );
                INSERT INTO search_text(search_text, rank) VALUES ('rank', 'bm25(8.0, 1.0, 4.0)');
                CREATE TRIGGER search_records_insert AFTER INSERT ON search_records BEGIN
                    INSERT INTO search_text(rowid, title, detail, hit_id) VALUES (new.rowid, new.title, new.detail, new.hit_id);
                END;
                CREATE TRIGGER search_records_delete AFTER DELETE ON search_records BEGIN
                    INSERT INTO search_text(search_text, rowid, title, detail, hit_id)
                    VALUES ('delete', old.rowid, old.title, old.detail, old.hit_id);
                END;
                CREATE TRIGGER search_records_update AFTER UPDATE ON search_records BEGIN
                    INSERT INTO search_text(search_text, rowid, title, detail, hit_id)
                    VALUES ('delete', old.rowid, old.title, old.detail, old.hit_id);
                    INSERT INTO search_text(rowid, title, detail, hit_id) VALUES (new.rowid, new.title, new.detail, new.hit_id);
                END;
                """)
            }
            try exec("""
                ALTER TABLE search_records ADD COLUMN body TEXT;
                CREATE TABLE search_versions(collection TEXT PRIMARY KEY, revision TEXT NOT NULL);
                PRAGMA user_version = 2;
                """)
        }
    }

    func withStatement<T>(_ query: String, _ work: (OpaquePointer) throws -> T) throws -> T {
        guard let handle else { throw SearchDatabaseError.unavailable }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, query, -1, &statement, nil))
        guard let statement else { throw SearchDatabaseError.sqlite(SQLITE_ERROR) }
        defer { sqlite3_finalize(statement) }
        return try work(statement)
    }

    func bind(_ values: [SearchBinding], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            switch value {
            case .text(let text):
                try check(sqlite3_bind_text(statement, slot, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
            case .integer(let number): try check(sqlite3_bind_int64(statement, slot, number))
            case .null: try check(sqlite3_bind_null(statement, slot))
            }
        }
    }

    func scalar(_ query: String) throws -> Int64 {
        try withStatement(query) { statement in
            try check(sqlite3_step(statement), expected: SQLITE_ROW)
            return sqlite3_column_int64(statement, 0)
        }
    }

    func run(_ query: String, _ bindings: [SearchBinding]) throws {
        try withStatement(query) { statement in
            try bind(bindings, to: statement)
            try check(sqlite3_step(statement), expected: SQLITE_DONE)
        }
    }

    func data(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_text(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    func transaction(_ work: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try work()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func check(_ result: Int32, expected: Int32 = SQLITE_OK) throws {
        guard result == expected else { throw SearchDatabaseError.sqlite(result) }
    }

    private func exec(_ query: String) throws {
        guard let handle else { throw SearchDatabaseError.unavailable }
        try check(sqlite3_exec(handle, query, nil, nil, nil))
    }
}
