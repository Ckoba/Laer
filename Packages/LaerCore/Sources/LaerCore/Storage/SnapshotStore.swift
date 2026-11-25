import Foundation

/// How much of a collection the last successful fetch covered.
public enum Coverage: String, Codable, Sendable {
    case complete
    case recentWindow
    case incomplete
}

/// The on-disk envelope for one cached collection.
public struct Snapshot<Record: Codable & Sendable>: Codable, Sendable {
    public var schemaVersion: Int
    public var accountKey: String
    public var collectionKey: String
    public var records: [Record]
    public var lastSuccess: Date
    public var coverage: Coverage
    public var checkpoint: String?
}

/// Cached collections for one account. Only successful fetches are saved, so a failed refresh
/// never replaces what is on disk.
public actor SnapshotStore {
    public static let schemaVersion = 1

    private let accountKey: String
    private let directory: URL
    private var index: SearchDatabase?
    private var indexCleanup: Task<Void, Error>?
    private var isRetired = false

    public init(rootDirectory: URL, accountKey: String) {
        self.accountKey = accountKey
        self.directory = AccountDirectory.url(root: rootDirectory, accountKey: accountKey)
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    public func searchDatabase() throws -> SearchDatabase {
        guard indexCleanup == nil, !isRetired else { throw SearchDatabaseError.unavailable }
        if let index { return index }
        let opened = try SearchDatabase(url: directory.appendingPathComponent("search.sqlite"))
        index = opened
        return opened
    }

    /// Clears the derived search index and its crawl markers. Source snapshots remain readable.
    public func removeSearchIndex(courseIds: [Int]) async throws {
        guard indexCleanup == nil, !isRetired else { throw SearchDatabaseError.unavailable }
        let databaseFiles = ["search.sqlite", "search.sqlite-journal", "search.sqlite-wal", "search.sqlite-shm"]
        let paths = databaseFiles.map { directory.appendingPathComponent($0) } + [fileURL(for: "search-coverage")]
            + courseIds.map { fileURL(for: "search-folders-\($0)") }
        try await closeIndexAndRemove(paths)
    }

    private func closeIndexAndRemove(_ paths: [URL]) async throws {
        let cleanup = Task {
            defer { indexCleanup = nil }
            try await index?.close()
            index = nil
            for url in paths where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        indexCleanup = cleanup
        try await cleanup.value
    }

    /// Replaces the collection atomically. If encoding or writing fails, the previous snapshot,
    /// including its checkpoint, stays in place.
    public func save<R: Codable & Sendable>(
        _ records: [R], collection: String, coverage: Coverage, checkpoint: String?, at date: Date
    ) throws {
        guard !isRetired else { throw CancellationError() }
        let snapshot = Snapshot(
            schemaVersion: Self.schemaVersion, accountKey: accountKey, collectionKey: collection,
            records: records, lastSuccess: date, coverage: coverage, checkpoint: checkpoint)
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: collection), options: .atomic)
    }

    /// A partial page can seed the cache, but it cannot displace a complete collection.
    @discardableResult
    public func savePage<Record: Codable & Sendable>(
        _ page: PagedResult<Record>, collection: String, at date: Date
    ) throws -> Bool {
        if !page.isComplete, load(Record.self, collection: collection)?.coverage == .complete { return false }
        try save(page.items, collection: collection, coverage: page.isComplete ? .complete : .incomplete, checkpoint: nil, at: date)
        return true
    }

    /// Returns nil for a missing, corrupt, foreign or outdated snapshot. The caller refetches.
    public func load<R: Codable & Sendable>(_ type: R.Type, collection: String) -> Snapshot<R>? {
        guard let data = try? Data(contentsOf: fileURL(for: collection)),
              let header = try? JSONDecoder().decode(Header.self, from: data),
              header.schemaVersion == Self.schemaVersion,
              header.accountKey == accountKey,
              header.collectionKey == collection
        else { return nil }
        return try? JSONDecoder().decode(Snapshot<R>.self, from: data)
    }

    /// Closes this account's index while keeping the offline data for the next session.
    public func retire() async throws {
        isRetired = true
        while let indexCleanup { _ = try? await indexCleanup.value }
        try await closeIndexAndRemove([])
    }

    /// Deletes every cached collection for this account. Downloads live elsewhere.
    /// Retiring the store prevents old tasks from recreating snapshots or reopening the database.
    public func removeAllMetadata(retire: Bool = false) async throws {
        if retire { isRetired = true }
        while let indexCleanup { _ = try? await indexCleanup.value }
        try await closeIndexAndRemove([directory])
    }

    func fileURL(for collection: String) -> URL {
        directory.appendingPathComponent(StableHash.hex("collection:" + collection, length: 32) + ".json")
    }

    private struct Header: Decodable {
        var schemaVersion: Int
        var accountKey: String
        var collectionKey: String
    }
}
