import Foundation

public enum SearchKind: String, Codable, Sendable, Hashable, CaseIterable {
    case course, plan, material, task, message, event
}

public enum SearchScope: Sendable, Hashable {
    case everywhere
    case activeCourses
    case course(Int)
}

public struct SearchHit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: SearchKind
    public var title: String
    public var detail: String?
    public var courseId: Int?
    public var fileExtension: String?
    public var resource: Resource?
    public var date: Date?
    public var url: String?

    public init(id: String, kind: SearchKind, title: String, detail: String? = nil, courseId: Int? = nil, fileExtension: String? = nil, resource: Resource? = nil, date: Date? = nil, url: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.courseId = courseId
        self.fileExtension = fileExtension ?? Self.fileExtension(of: title)
        self.resource = resource
        self.date = date
        self.url = url
    }

    /// A short trailing extension in a title, such as "Slides week 3.PPTX".
    public static func fileExtension(of title: String) -> String? {
        guard let range = title.range(of: #"\.[A-Za-z0-9]{1,5}$"#, options: .regularExpression) else { return nil }
        let value = title[range].dropFirst().lowercased()
        return value.allSatisfy(\.isNumber) ? nil : value
    }
}

/// An in-memory index with accent- and case-insensitive word matching. Records replace by group,
/// so one failed refresh leaves that group's earlier records in place.
public struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        let hit: SearchHit
        let title: String
        let detail: String
    }

    private var groups: [String: [Entry]] = [:]

    public init() {}

    public var count: Int { groups.values.reduce(0) { $0 + $1.count } }

    /// All hits, for saving to disk, keyed by group.
    public var records: [String: [SearchHit]] { groups.mapValues { $0.map(\.hit) } }

    public init(records: [String: [SearchHit]]) {
        for (group, hits) in records { replace(group: group, with: hits) }
    }

    public mutating func replace(group: String, with hits: [SearchHit]) {
        groups[group] = hits.map { Entry(hit: $0, title: Self.normalize($0.title), detail: Self.normalize($0.detail ?? "")) }
    }

    public func search(
        _ text: String,
        scope: SearchScope,
        activeCourseIds: Set<Int>,
        kinds: Set<SearchKind> = [],
        fileExtension: String? = nil,
        limit: Int = 60
    ) -> [SearchHit] {
        let words = Self.normalize(text).split(separator: " ").map(String.init)
        let wanted = fileExtension?.lowercased()
        guard !words.isEmpty || wanted != nil else { return [] }
        var scored: [(hit: SearchHit, score: Int)] = []
        for entries in groups.values {
            for entry in entries {
                guard kinds.isEmpty || kinds.contains(entry.hit.kind) else { continue }
                if let wanted, entry.hit.fileExtension != wanted { continue }
                switch scope {
                case .everywhere: break
                case .activeCourses:
                    guard let course = entry.hit.courseId, activeCourseIds.contains(course) else { continue }
                case .course(let id):
                    guard entry.hit.courseId == id else { continue }
                }
                if let score = Self.score(entry, words: words) {
                    scored.append((entry.hit, score))
                }
            }
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.hit.title.localizedStandardCompare(rhs.hit.title) == .orderedAscending
            }
            .prefix(limit)
            .map(\.hit)
    }

    private static func score(_ entry: Entry, words: [String]) -> Int? {
        var total = 0
        for word in words {
            if entry.title.hasPrefix(word) {
                total += 100
            } else if entry.title.contains(" " + word) {
                total += 60
            } else if entry.title.contains(word) {
                total += 30
            } else if entry.detail.contains(word) {
                total += 10
            } else {
                return nil
            }
        }
        // Things a student opens most rank first among equal matches.
        switch entry.hit.kind {
        case .material: total += 3
        case .plan: total += 2
        case .course: total += 2
        case .task: total += 1
        case .event, .message: break
        }
        return total
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "æ", with: "ae")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: #"[_\-\.,/]+"#, with: " ", options: .regularExpression)
    }
}
