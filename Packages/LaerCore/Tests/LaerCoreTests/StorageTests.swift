import Foundation
import Testing
@testable import LaerCore

/// A fresh, empty directory under the system temporary directory.
func makeTemporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaerCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct SampleRecord: Codable, Sendable, Equatable {
    var id: Int
    var title: String
    var failsToEncode = false

    init(id: Int, title: String, failsToEncode: Bool = false) {
        self.id = id
        self.title = title
        self.failsToEncode = failsToEncode
    }

    func encode(to encoder: any Encoder) throws {
        if failsToEncode { throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "test")) }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
    }

    private enum CodingKeys: String, CodingKey { case id, title }
}

@Suite struct StableHashTests {
    @Test func matchesKnownVectors() {
        #expect(StableHash.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(StableHash.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(StableHash.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}

@Suite struct SnapshotStoreTests {
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func savesAndLoads() async throws {
        let store = SnapshotStore(rootDirectory: try makeTemporaryRoot(), accountKey: "example.itslearning.com#1")
        try await store.save([SampleRecord(id: 1, title: "A")], collection: "courses", coverage: .complete, checkpoint: "c1", at: date)
        let snapshot = try #require(await store.load(SampleRecord.self, collection: "courses"))
        #expect(snapshot.records == [SampleRecord(id: 1, title: "A")])
        #expect(snapshot.coverage == .complete)
        #expect(snapshot.checkpoint == "c1")
        #expect(snapshot.lastSuccess == date)
        #expect(await store.load(SampleRecord.self, collection: "other") == nil)
    }

    @Test func pathsDoNotContainKeys() async throws {
        let root = try makeTemporaryRoot()
        let store = SnapshotStore(rootDirectory: root, accountKey: "example.itslearning.com#42")
        try await store.save([SampleRecord(id: 1, title: "A")], collection: "courses", coverage: .complete, checkpoint: nil, at: date)
        let path = await store.fileURL(for: "courses").path
        #expect(!path.contains("example"))
        #expect(!path.contains("courses"))
        #expect(path.hasPrefix(root.path))
    }

    @Test func failedEncodeKeepsPriorSnapshotAndCheckpoint() async throws {
        let store = SnapshotStore(rootDirectory: try makeTemporaryRoot(), accountKey: "a")
        try await store.save([SampleRecord(id: 1, title: "old")], collection: "c", coverage: .complete, checkpoint: "old", at: date)
        await #expect(throws: (any Error).self) {
            try await store.save([SampleRecord(id: 2, title: "new", failsToEncode: true)], collection: "c", coverage: .incomplete, checkpoint: "new", at: date)
        }
        let snapshot = try #require(await store.load(SampleRecord.self, collection: "c"))
        #expect(snapshot.records.map(\.title) == ["old"])
        #expect(snapshot.checkpoint == "old")
    }

    @Test func failedWriteKeepsPriorSnapshot() async throws {
        let store = SnapshotStore(rootDirectory: try makeTemporaryRoot(), accountKey: "a")
        try await store.save([SampleRecord(id: 1, title: "old")], collection: "c", coverage: .complete, checkpoint: "old", at: date)
        let directory = await store.fileURL(for: "c").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        await #expect(throws: (any Error).self) {
            try await store.save([SampleRecord(id: 2, title: "new")], collection: "c", coverage: .complete, checkpoint: "new", at: date)
        }
        let snapshot = try #require(await store.load(SampleRecord.self, collection: "c"))
        #expect(snapshot.records.map(\.title) == ["old"])
        #expect(snapshot.checkpoint == "old")
    }

    @Test func otherAccountIsIsolated() async throws {
        let root = try makeTemporaryRoot()
        let first = SnapshotStore(rootDirectory: root, accountKey: "first")
        let second = SnapshotStore(rootDirectory: root, accountKey: "second")
        try await first.save([SampleRecord(id: 1, title: "A")], collection: "c", coverage: .complete, checkpoint: nil, at: date)
        #expect(await second.load(SampleRecord.self, collection: "c") == nil)

        // A file copied into another account's directory is still refused.
        let source = await first.fileURL(for: "c")
        let target = await second.fileURL(for: "c")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        #expect(await second.load(SampleRecord.self, collection: "c") == nil)
    }

    @Test func schemaMismatchIsDiscarded() async throws {
        let store = SnapshotStore(rootDirectory: try makeTemporaryRoot(), accountKey: "a")
        try await store.save([SampleRecord(id: 1, title: "A")], collection: "c", coverage: .complete, checkpoint: nil, at: date)
        let url = await store.fileURL(for: "c")
        let json = #"{"schemaVersion":999,"accountKey":"a","collectionKey":"c","records":[],"lastSuccess":0,"coverage":"complete"}"#
        try Data(json.utf8).write(to: url)
        #expect(await store.load(SampleRecord.self, collection: "c") == nil)
    }

    @Test func corruptFileIsDiscarded() async throws {
        let store = SnapshotStore(rootDirectory: try makeTemporaryRoot(), accountKey: "a")
        try await store.save([SampleRecord(id: 1, title: "A")], collection: "c", coverage: .complete, checkpoint: nil, at: date)
        try Data("{not json".utf8).write(to: await store.fileURL(for: "c"))
        #expect(await store.load(SampleRecord.self, collection: "c") == nil)
    }

    @Test func removeAllMetadataKeepsDownloads() async throws {
        let root = try makeTemporaryRoot()
        let snapshots = SnapshotStore(rootDirectory: root, accountKey: "a")
        let downloads = DownloadStore(rootDirectory: root, accountKey: "a")
        try await snapshots.save([SampleRecord(id: 1, title: "A")], collection: "c", coverage: .complete, checkpoint: nil, at: date)
        let staged = try stageFile(in: root, bytes: Data("%PDF-1.7 synthetic".utf8))
        let asset = try await downloads.commit(stagedFile: staged, resourceKey: "r1", suggestedName: "notes.pdf", contentType: "application/pdf", at: date)

        try await snapshots.removeAllMetadata()
        #expect(await snapshots.load(SampleRecord.self, collection: "c") == nil)
        #expect(await downloads.asset(for: "r1") == asset)
        #expect(FileManager.default.fileExists(atPath: await downloads.fileURL(for: asset).path))
    }
}
