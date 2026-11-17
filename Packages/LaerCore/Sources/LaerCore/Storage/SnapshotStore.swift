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

    public init(rootDirectory: URL, accountKey: String) {
        self.accountKey = accountKey
        self.directory = AccountDirectory.url(root: rootDirectory, accountKey: accountKey)
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    /// Replaces the collection atomically. If encoding or writing fails, the previous snapshot,
    /// including its checkpoint, stays in place.
    public func save<R: Codable & Sendable>(
        _ records: [R], collection: String, coverage: Coverage, checkpoint: String?, at date: Date
    ) throws {
        let snapshot = Snapshot(
            schemaVersion: Self.schemaVersion, accountKey: accountKey, collectionKey: collection,
            records: records, lastSuccess: date, coverage: coverage, checkpoint: checkpoint)
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: collection), options: .atomic)
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

    /// Deletes every cached collection for this account. Downloads live elsewhere and are kept.
    public func removeAllMetadata() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
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
