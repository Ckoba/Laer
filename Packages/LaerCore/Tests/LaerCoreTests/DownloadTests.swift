import Foundation
import Testing
@testable import LaerCore

func stageFile(in root: URL, bytes: Data) throws -> URL {
    let staging = root.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let url = staging.appendingPathComponent(UUID().uuidString)
    try bytes.write(to: url)
    return url
}

@Suite struct DownloadStoreTests {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let pdf = Data("%PDF-1.7 synthetic".utf8)

    @Test func commitStoresFileUnderOpaquePath() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let staged = try stageFile(in: root, bytes: pdf)
        let asset = try await store.commit(stagedFile: staged, resourceKey: "r1", suggestedName: "Week 1 Notes.PDF", contentType: "application/pdf", at: date)

        #expect(asset.displayName == "Week 1 Notes.PDF")
        #expect(asset.relativePath.hasSuffix(".pdf"))
        #expect(!asset.relativePath.contains("Week"))
        #expect(asset.byteCount == Int64(pdf.count))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try Data(contentsOf: await store.fileURL(for: asset)) == pdf)

        let reopened = DownloadStore(rootDirectory: root, accountKey: "a")
        #expect(await reopened.asset(for: "r1") == asset)
    }

    @Test func loginHTMLIsRejected() throws {
        let root = try makeTemporaryRoot()
        let login = try stageFile(in: root, bytes: Data("\u{FEFF}\n  <!DOCTYPE html><html><body><form action=\"/login\"></form></body></html>".utf8))
        #expect(throws: DownloadError.notADocument) {
            try DownloadStore.validate(fileAt: login, contentType: "application/octet-stream")
        }
        #expect(throws: DownloadError.notADocument) {
            try DownloadStore.validate(fileAt: login, contentType: nil)
        }
        let pdfFile = try stageFile(in: root, bytes: pdf)
        #expect(throws: DownloadError.notADocument) {
            try DownloadStore.validate(fileAt: pdfFile, contentType: "text/html; charset=utf-8")
        }
        let empty = try stageFile(in: root, bytes: Data())
        #expect(throws: DownloadError.invalidResponse) {
            try DownloadStore.validate(fileAt: empty, contentType: "application/pdf")
        }
        try DownloadStore.validate(fileAt: pdfFile, contentType: "application/pdf")
    }

    @Test func rejectedCommitLeavesStateAndStagedFile() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let staged = try stageFile(in: root, bytes: Data("<html><head><title>Sign in</title></head></html>".utf8))
        await #expect(throws: DownloadError.notADocument) {
            try await store.commit(stagedFile: staged, resourceKey: "r1", suggestedName: "a.pdf", contentType: "application/pdf", at: date)
        }
        #expect(await store.asset(for: "r1") == nil)
        #expect(FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func duplicateNamesGetSeparateFiles() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let first = try await store.commit(stagedFile: try stageFile(in: root, bytes: pdf), resourceKey: "r1", suggestedName: "Notes.pdf", contentType: nil, at: date)
        let second = try await store.commit(stagedFile: try stageFile(in: root, bytes: Data("%PDF-2".utf8)), resourceKey: "r2", suggestedName: "Notes.pdf", contentType: nil, at: date)
        #expect(first.displayName == second.displayName)
        #expect(first.relativePath != second.relativePath)
        #expect(try Data(contentsOf: await store.fileURL(for: first)) == pdf)
        #expect(await store.allAssets().count == 2)
    }

    @Test func pathTraversalIsSanitized() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let asset = try await store.commit(stagedFile: try stageFile(in: root, bytes: pdf), resourceKey: "r1", suggestedName: "../../etc/passwd", contentType: nil, at: date)
        #expect(!asset.displayName.contains("/"))
        #expect(!asset.displayName.hasPrefix("."))
        let url = await store.fileURL(for: asset).standardizedFileURL
        #expect(url.deletingLastPathComponent().lastPathComponent == "Downloads")
        #expect(url.path.hasPrefix(root.standardizedFileURL.path))

        #expect(DownloadStore.sanitizedDisplayName("..") == "Download")
        #expect(DownloadStore.sanitizedDisplayName("a\\b:c\u{0}d") == "a-b-c-d")
        #expect(DownloadStore.safeExtension(name: "run.command", contentType: nil) == nil)
        #expect(DownloadStore.safeExtension(name: "file", contentType: "application/pdf; q=1") == "pdf")
    }

    @Test func manifestEntryWithUnsafePathIsIgnored() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        _ = try await store.commit(stagedFile: try stageFile(in: root, bytes: pdf), resourceKey: "r1", suggestedName: "a.pdf", contentType: nil, at: date)
        let manifestURL = AccountDirectory.url(root: root, accountKey: "a").appendingPathComponent("download-manifest.json")
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
        let tampered = text.replacingOccurrences(of: #""relativePath":""#, with: #""relativePath":"..\/"#)
        try Data(tampered.utf8).write(to: manifestURL)
        #expect(await DownloadStore(rootDirectory: root, accountKey: "a").asset(for: "r1") == nil)
    }

    @Test func replacementDeletesOldRevisionAfterManifest() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let old = try await store.commit(stagedFile: try stageFile(in: root, bytes: pdf), resourceKey: "r1", suggestedName: "a.pdf", contentType: nil, at: date)
        let new = try await store.commit(stagedFile: try stageFile(in: root, bytes: Data("%PDF-new".utf8)), resourceKey: "r1", suggestedName: "a.pdf", contentType: nil, at: date)
        #expect(!FileManager.default.fileExists(atPath: await store.fileURL(for: old).path))
        #expect(await store.asset(for: "r1") == new)
        #expect(await store.allAssets().count == 1)
    }

    @Test func interruptedReplacementKeepsOldFile() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let old = try await store.commit(stagedFile: try stageFile(in: root, bytes: pdf), resourceKey: "r1", suggestedName: "a.pdf", contentType: nil, at: date)

        // The account directory holds the manifest; making it read-only fails the manifest write
        // while the Downloads directory itself stays writable.
        let accountDirectory = AccountDirectory.url(root: root, accountKey: "a")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: accountDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: accountDirectory.path) }

        let staged = try stageFile(in: root, bytes: Data("%PDF-new".utf8))
        await #expect(throws: DownloadError.writeFailed) {
            try await store.commit(stagedFile: staged, resourceKey: "r1", suggestedName: "a.pdf", contentType: nil, at: date)
        }
        #expect(await store.asset(for: "r1") == old)
        #expect(try Data(contentsOf: await store.fileURL(for: old)) == pdf)
        let downloads = accountDirectory.appendingPathComponent("Downloads")
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path) == [old.relativePath])

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: accountDirectory.path)
        #expect(await DownloadStore(rootDirectory: root, accountKey: "a").asset(for: "r1") == old)
    }

    @Test func concurrentCommitsLoseNoEntries() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let staged = try (0..<40).map { _ in try stageFile(in: root, bytes: pdf) }
        let date = self.date
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, url) in staged.enumerated() {
                group.addTask {
                    _ = try await store.commit(stagedFile: url, resourceKey: "r\(index)", suggestedName: "f\(index).pdf", contentType: nil, at: date)
                }
            }
            try await group.waitForAll()
        }
        #expect(await DownloadStore(rootDirectory: root, accountKey: "a").allAssets().count == 40)
    }

    @Test func missingFileMeansNoAsset() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let asset = try await store.commit(stagedFile: try stageFile(in: root, bytes: pdf), resourceKey: "r1", suggestedName: "a.pdf", contentType: nil, at: date)
        try FileManager.default.removeItem(at: await store.fileURL(for: asset))
        #expect(await store.asset(for: "r1") == nil)
        #expect(await store.allAssets().isEmpty)
    }

    @Test func unreadableManifestIsPreservedAside() async throws {
        let root = try makeTemporaryRoot()
        let accountDirectory = AccountDirectory.url(root: root, accountKey: "a")
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        let garbage = Data("{broken".utf8)
        try garbage.write(to: accountDirectory.appendingPathComponent("download-manifest.json"))

        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        #expect(await store.allAssets().isEmpty)
        _ = try await store.commit(stagedFile: try stageFile(in: root, bytes: pdf), resourceKey: "r1", suggestedName: "a.pdf", contentType: nil, at: date)

        let names = try FileManager.default.contentsOfDirectory(atPath: accountDirectory.path)
        let aside = try #require(names.first { $0.hasPrefix("download-manifest.unreadable-") })
        #expect(try Data(contentsOf: accountDirectory.appendingPathComponent(aside)) == garbage)
    }

    @Test func removeDeletesFileAndEntry() async throws {
        let root = try makeTemporaryRoot()
        let store = DownloadStore(rootDirectory: root, accountKey: "a")
        let asset = try await store.commit(stagedFile: try stageFile(in: root, bytes: pdf), resourceKey: "r1", suggestedName: "a.pdf", contentType: nil, at: date)
        try await store.remove(resourceKey: "r1")
        #expect(await store.asset(for: "r1") == nil)
        #expect(!FileManager.default.fileExists(atPath: await store.fileURL(for: asset).path))
        #expect(await DownloadStore(rootDirectory: root, accountKey: "a").allAssets().isEmpty)
    }

    @Test func accountsAreIsolated() async throws {
        let root = try makeTemporaryRoot()
        let first = DownloadStore(rootDirectory: root, accountKey: "first")
        _ = try await first.commit(stagedFile: try stageFile(in: root, bytes: pdf), resourceKey: "r1", suggestedName: "a.pdf", contentType: nil, at: date)
        #expect(await DownloadStore(rootDirectory: root, accountKey: "second").asset(for: "r1") == nil)
    }
}
