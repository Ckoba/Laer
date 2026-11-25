import Foundation

/// A file whose bytes are on disk. `id` is the caller's resource key.
public struct LocalAsset: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// A single opaque file name inside the account's Downloads directory.
    public var relativePath: String
    public var displayName: String
    public var byteCount: Int64
    public var contentType: String?
    public var downloadedAt: Date
    /// Fetched ahead of time by Laer rather than saved by the person. Only these may be evicted
    /// to stay within a space limit; a file the person saved is never removed automatically.
    public var isAutoPrefetched: Bool = false
}

extension LocalAsset {
    private enum CodingKeys: String, CodingKey {
        case id, relativePath, displayName, byteCount, contentType, downloadedAt, isAutoPrefetched
    }

    /// Manifests written before `isAutoPrefetched` existed decode as person-saved files.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        displayName = try container.decode(String.self, forKey: .displayName)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        downloadedAt = try container.decode(Date.self, forKey: .downloadedAt)
        isAutoPrefetched = try container.decodeIfPresent(Bool.self, forKey: .isAutoPrefetched) ?? false
    }
}

public enum DownloadError: Error, Equatable, Sendable {
    /// The bytes look like a web page, usually a login page, rather than the requested file.
    case notADocument
    case invalidResponse
    case writeFailed
}

/// Saved files for one account, tracked by a manifest beside the Downloads directory.
/// Files are only removed by `remove(resourceKey:)`, `removeAllDownloadedFiles()`, when a newer
/// revision has been committed, or (for files Laer fetched ahead itself) by
/// `evictAutoPrefetchedIfNeeded(maxBytes:)`.
public actor DownloadStore {
    private let accountDirectory: URL
    private let downloadsDirectory: URL
    private let manifestURL: URL
    private var entries: [String: LocalAsset]?
    /// Set when an unreadable manifest could not be moved aside; writing would destroy it.
    private var manifestBlocked = false
    private var isRetired = false

    public init(rootDirectory: URL, accountKey: String) {
        accountDirectory = AccountDirectory.url(root: rootDirectory, accountKey: accountKey)
        downloadsDirectory = accountDirectory.appendingPathComponent("Downloads", isDirectory: true)
        manifestURL = accountDirectory.appendingPathComponent("download-manifest.json")
    }

    /// Validates the staged file, moves it to a new opaque path and records it.
    /// The previous revision is deleted only after the manifest has been written.
    /// If validation fails the staged file is left where it is.
    /// `isAutoPrefetched` marks a file Laer fetched on its own; a newer revision of a file the person
    /// saved stays person-saved.
    public func commit(
        stagedFile: URL, resourceKey: String, suggestedName: String, contentType: String?, at date: Date,
        isAutoPrefetched: Bool = false
    ) throws -> LocalAsset {
        guard !isRetired else { throw CancellationError() }
        try Self.validate(fileAt: stagedFile, contentType: contentType)
        var current = loadEntries()
        guard !manifestBlocked else { throw DownloadError.writeFailed }

        let fileManager = FileManager.default
        let displayName = Self.sanitizedDisplayName(suggestedName)
        let ext = Self.safeExtension(name: displayName, contentType: contentType)
        let relativePath = UUID().uuidString.lowercased() + (ext.map { "." + $0 } ?? "")
        let destination = downloadsDirectory.appendingPathComponent(relativePath)
        do {
            try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: stagedFile, to: destination)
        } catch {
            throw DownloadError.writeFailed
        }

        let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        let previous = current[resourceKey]
        let asset = LocalAsset(
            id: resourceKey, relativePath: relativePath, displayName: displayName,
            byteCount: size, contentType: contentType, downloadedAt: date,
            isAutoPrefetched: isAutoPrefetched && (previous?.isAutoPrefetched ?? true))
        current[resourceKey] = asset
        do {
            try writeManifest(current)
        } catch {
            if (try? fileManager.moveItem(at: destination, to: stagedFile)) == nil {
                try? fileManager.removeItem(at: destination)
            }
            throw DownloadError.writeFailed
        }
        entries = current
        if let previous, previous.relativePath != relativePath {
            try? fileManager.removeItem(at: fileURL(for: previous))
        }
        return asset
    }

    /// Returns nil when the asset is unknown or its file is no longer on disk.
    public func asset(for resourceKey: String) -> LocalAsset? {
        guard let asset = loadEntries()[resourceKey], isOnDisk(asset) else { return nil }
        return asset
    }

    public func allAssets() -> [LocalAsset] {
        loadEntries().values.filter(isOnDisk).sorted { $0.downloadedAt > $1.downloadedAt }
    }

    public func fileURL(for asset: LocalAsset) -> URL {
        downloadsDirectory.appendingPathComponent(asset.relativePath)
    }

    /// The same location without a hop onto the actor, for opening a known file in the current frame.
    /// Nil when the bytes are no longer on disk.
    public nonisolated func fileURLIfPresent(for asset: LocalAsset) -> URL? {
        let url = downloadsDirectory.appendingPathComponent(asset.relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Explicit user removal. The manifest is updated first so a failure leaves the file usable.
    public func remove(resourceKey: String) throws {
        var current = loadEntries()
        guard let asset = current.removeValue(forKey: resourceKey) else { return }
        guard !manifestBlocked else { throw DownloadError.writeFailed }
        do {
            try writeManifest(current)
        } catch {
            throw DownloadError.writeFailed
        }
        entries = current
        try? FileManager.default.removeItem(at: fileURL(for: asset))
    }

    /// The person chose to keep a file Laer fetched ahead, so it is no longer evictable.
    public func markKept(resourceKey: String) throws {
        var current = loadEntries()
        guard var asset = current[resourceKey], asset.isAutoPrefetched else { return }
        guard !manifestBlocked else { throw DownloadError.writeFailed }
        asset.isAutoPrefetched = false
        current[resourceKey] = asset
        do {
            try writeManifest(current)
        } catch {
            throw DownloadError.writeFailed
        }
        entries = current
    }

    /// Removes files Laer fetched ahead, oldest first, until together they take at most `maxBytes`.
    /// Files the person saved are never touched and do not count towards the limit.
    /// Returns the resource keys that were removed.
    @discardableResult
    public func evictAutoPrefetchedIfNeeded(maxBytes: UInt64) throws -> [String] {
        var current = loadEntries()
        let prefetched = current.values.filter(\.isAutoPrefetched)
        var total = prefetched.reduce(UInt64(0)) { $0 + UInt64(max(0, $1.byteCount)) }
        guard total > maxBytes else { return [] }
        guard !manifestBlocked else { throw DownloadError.writeFailed }
        var evicted: [LocalAsset] = []
        for asset in prefetched.sorted(by: { ($0.downloadedAt, $0.id) < ($1.downloadedAt, $1.id) }) {
            guard total > maxBytes else { break }
            current.removeValue(forKey: asset.id)
            evicted.append(asset)
            total -= UInt64(max(0, asset.byteCount))
        }
        // The manifest goes first, so a failure leaves every file usable.
        do {
            try writeManifest(current)
        } catch {
            throw DownloadError.writeFailed
        }
        entries = current
        for asset in evicted { try? FileManager.default.removeItem(at: fileURL(for: asset)) }
        return evicted.map(\.id)
    }

    /// Explicit user action (signing out and removing local data): deletes every saved file and
    /// the manifest, including any unreadable manifest kept aside.
    public func removeAllDownloadedFiles(retire: Bool = false) throws {
        if retire { isRetired = true }
        let fileManager = FileManager.default
        var failed = false
        if fileManager.fileExists(atPath: downloadsDirectory.path) {
            do { try fileManager.removeItem(at: downloadsDirectory) } catch { failed = true }
        }
        let leftovers = (try? fileManager.contentsOfDirectory(atPath: accountDirectory.path)) ?? []
        for name in leftovers where name.hasPrefix("download-manifest") {
            do {
                try fileManager.removeItem(at: accountDirectory.appendingPathComponent(name))
            } catch {
                failed = true
            }
        }
        entries = failed ? nil : [:]
        manifestBlocked = false
        if failed { throw DownloadError.writeFailed }
    }

    // MARK: - Opening

    /// Formats that are safe to hand to the default app: documents, text, raster images and media.
    /// Anything else (disk images, archives, installers, scripts, profiles, web pages, SVG, web
    /// archives) is only shown in Finder, where macOS applies its own checks before opening.
    private static let directlyOpenableExtensions: Set<String> = [
        "pdf",
        "doc", "docx", "dot", "dotx", "rtf", "xls", "xlsx", "xlt", "xltx", "ppt", "pptx", "pps", "ppsx", "pot", "potx",
        "pages", "numbers", "key",
        "odt", "ods", "odp", "odg",
        "txt", "text", "md", "markdown", "csv", "tsv", "json",
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp",
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg",
        "mp4", "m4v", "mov",
    ]

    public static func canOpenDirectlyInDefaultApp(pathExtension: String) -> Bool {
        directlyOpenableExtensions.contains(pathExtension.lowercased())
    }

    /// Rejects web pages served in place of a file, judged by content type and leading bytes.
    /// This catches login and error pages; it does not check that a file is well formed.
    public static func validate(fileAt url: URL, contentType: String?) throws {
        if let type = contentType?.lowercased(),
           type.contains("text/html") || type.contains("application/xhtml") {
            throw DownloadError.notADocument
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw DownloadError.invalidResponse }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024), !head.isEmpty else {
            throw DownloadError.invalidResponse
        }
        var bytes = head[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        bytes = bytes.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        let text = String(decoding: bytes, as: UTF8.self).lowercased()
        let markupPrefixes = ["<!doctype html", "<html", "<head", "<body", "<meta", "<title", "<script", "<form"]
        if markupPrefixes.contains(where: text.hasPrefix) { throw DownloadError.notADocument }
        if text.hasPrefix("<?xml") || text.hasPrefix("<!--"), text.contains("<html") {
            throw DownloadError.notADocument
        }
    }

    // MARK: - Names

    static func sanitizedDisplayName(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.illegalCharacters)
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { unsafe.contains($0) ? "-" : $0 }))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 200 { cleaned = String(cleaned.suffix(200)) }
        return cleaned.isEmpty ? "Download" : cleaned
    }

    private static let blockedExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "workflow", "scpt",
        "pkg", "mpkg", "webloc", "inetloc", "fileloc", "html", "htm", "xhtml", "shtml",
    ]

    private static let extensionsByType: [String: String] = [
        "application/pdf": "pdf",
        "application/msword": "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/zip": "zip",
        "text/plain": "txt",
        "text/csv": "csv",
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/gif": "gif",
        "video/mp4": "mp4",
        "audio/mpeg": "mp3",
    ]

    static func safeExtension(name: String, contentType: String?) -> String? {
        let fromName = (name as NSString).pathExtension.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        if (1...10).contains(fromName.count),
           fromName.unicodeScalars.allSatisfy(allowed.contains),
           !blockedExtensions.contains(fromName) {
            return fromName
        }
        guard let type = contentType?.lowercased().split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        return extensionsByType[type]
    }

    // MARK: - Manifest

    private struct Manifest: Codable {
        var version: Int
        var assets: [LocalAsset]
    }

    private func loadEntries() -> [String: LocalAsset] {
        guard !isRetired else { return [:] }
        if let entries { return entries }
        var loaded: [String: LocalAsset] = [:]
        if let data = try? Data(contentsOf: manifestURL) {
            if let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
                for asset in manifest.assets where Self.isSafeRelativePath(asset.relativePath) {
                    loaded[asset.id] = asset
                }
            } else {
                preserveUnreadableManifest()
            }
        } else if FileManager.default.fileExists(atPath: manifestURL.path) {
            preserveUnreadableManifest()
        }
        entries = loaded
        return loaded
    }

    private func preserveUnreadableManifest() {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = accountDirectory.appendingPathComponent("download-manifest.unreadable-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        if (try? FileManager.default.moveItem(at: manifestURL, to: aside)) == nil {
            manifestBlocked = true
        }
    }

    private func writeManifest(_ entries: [String: LocalAsset]) throws {
        let manifest = Manifest(version: 1, assets: entries.values.sorted { $0.id < $1.id })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix(".") && !path.contains("/") && !path.contains("\\")
    }

    private func isOnDisk(_ asset: LocalAsset) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: asset).path)
    }
}
