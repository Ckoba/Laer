import Foundation

/// Briefs generated on this Mac, one JSON file per account beside its snapshots and downloads.
/// An unreadable file is treated as empty and replaced on the next save; briefs can be made again.
public actor GeneratedBriefStore {
    private let fileURL: URL
    private var entries: [Int: GeneratedBrief]?

    public init(rootDirectory: URL, accountKey: String) {
        fileURL = AccountDirectory.url(root: rootDirectory, accountKey: accountKey).appendingPathComponent("generated-briefs.json")
    }

    public func all() -> [Int: GeneratedBrief] {
        load()
    }

    public func save(_ brief: GeneratedBrief) throws {
        var current = load()
        current[brief.planId] = brief
        try write(current)
    }

    /// Removes every generated brief, for when the user turns the feature off.
    public func removeAll() throws {
        entries = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func load() -> [Int: GeneratedBrief] {
        if let entries { return entries }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([GeneratedBrief].self, from: $0) } ?? []
        let map = Dictionary(loaded.map { ($0.planId, $0) }, uniquingKeysWith: { _, last in last })
        entries = map
        return map
    }

    private func write(_ map: [Int: GeneratedBrief]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(map.values.sorted { $0.planId < $1.planId })
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        entries = map
    }
}
