import Foundation

public enum SearchKind: String, Codable, Sendable, Hashable, CaseIterable {
    case course, plan, material, task, message, event, announcement
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
    public var contexts: [String]?
    public var destination: SearchDestination?
    public var document: SearchDocumentPosition?
    public var excerpt: String?
    public var matchedText: String?

    public init(id: String, kind: SearchKind, title: String, detail: String? = nil, courseId: Int? = nil, fileExtension: String? = nil, resource: Resource? = nil, date: Date? = nil, url: String? = nil, contexts: [String]? = nil, destination: SearchDestination? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.courseId = courseId
        self.fileExtension = fileExtension ?? Self.fileExtension(of: title)
        self.resource = resource
        self.date = date
        self.url = url
        self.contexts = contexts
        self.destination = destination
    }

    public init(resource: Resource, courseId: Int, context: String?, destination: SearchDestination? = nil) {
        self.init(
            id: "material-\(courseId)-\(resource.id.lowercased())", kind: .material, title: resource.title,
            detail: context, courseId: courseId, resource: resource, url: resource.url ?? resource.contentUrl,
            contexts: context.map { [$0] }, destination: destination
        )
    }

    /// Keeps the input's rank order and retains the contexts of duplicate objects.
    public static func unique(_ hits: [Self]) -> [Self] {
        var positions: [String: Int] = [:]
        var result: [Self] = []
        for hit in hits {
            guard let position = positions[hit.id] else {
                positions[hit.id] = result.count
                result.append(hit)
                continue
            }
            var first = result[position]
            let contexts = Set((first.contexts ?? []) + (hit.contexts ?? []))
            if !contexts.isEmpty { first.contexts = contexts.sorted() }
            if first.resource?.learningObjectId == nil, first.resource?.contentUrl == nil,
               let resource = hit.resource, resource.learningObjectId != nil || resource.contentUrl != nil {
                first.resource = resource
            }
            first.destination = first.destination ?? hit.destination
            first.url = first.url ?? hit.url
            result[position] = first
        }
        return result
    }

    /// A short trailing extension in a title, such as "Slides week 3.PPTX".
    public static func fileExtension(of title: String) -> String? {
        guard let range = title.range(of: #"\.[A-Za-z0-9]{1,5}$"#, options: .regularExpression) else { return nil }
        let value = title[range].dropFirst().lowercased()
        return value.allSatisfy(\.isNumber) ? nil : value
    }
}

public struct SearchDocumentPosition: Codable, Sendable, Hashable {
    public let resourceKey: String
    public let version: String
    public let page: Int?

    public init(resourceKey: String, version: String, page: Int?) {
        self.resourceKey = resourceKey
        self.version = version
        self.page = page
    }
}

public enum SearchDestination: Codable, Sendable, Hashable {
    case plan(courseId: Int, planId: Int)
    case folder(courseId: Int, folderId: Int, title: String)
    case task(Int)
    case thread(Int)
    case event(Int)
    case announcement(courseId: Int, bulletinId: Int)
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

    public mutating func update(group: String, with hits: [SearchHit], complete: Bool) {
        let previous: [SearchHit] = complete ? [] : (groups[group] ?? []).map(\.hit)
        replace(group: group, with: SearchHit.unique(hits + previous))
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
        let ranked = scored.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let title = lhs.hit.title.localizedStandardCompare(rhs.hit.title)
                if title != .orderedSame { return title == .orderedAscending }
                return lhs.hit.id < rhs.hit.id
            }
        return Array(SearchHit.unique(ranked.map(\.hit)).prefix(max(0, limit)))
    }

    private static func score(_ entry: Entry, words: [String]) -> Int? {
        var total = entry.title == words.joined(separator: " ") ? 1000 : 0
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
        case .event, .message, .announcement: break
        }
        return total
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "æ", with: "ae")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}
