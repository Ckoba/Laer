import Foundation

/// A page of results as the list routes return it.
public struct Page<Element: Decodable & Sendable>: Decodable, Sendable {
    public var items: [Element]
    public var total: Int?
    public var pageIndex: Int?
    public var pageSize: Int?

    enum CodingKeys: String, CodingKey {
        case items = "EntityArray"
        case total = "Total"
        case pageIndex = "CurrentPageIndex"
        case pageSize = "PageSize"
    }

    init(items: [Element], total: Int?, pageIndex: Int?, pageSize: Int?) {
        self.items = items
        self.total = total
        self.pageIndex = pageIndex
        self.pageSize = pageSize
    }
}

/// Typed reads for the routes Laer uses. Every route here is read-only.
public struct ItslearningClient: Sendable {
    public static let maxPageSize = 100
    /// Guards against a route that never reports its end. Hitting it means incomplete, never complete.
    public static let pageLimit = 50

    let transport: any ReadTransport

    public init(transport: any ReadTransport) {
        self.transport = transport
    }

    public func person() async throws -> Person {
        try await get(ReadRequest(path: "/restapi/personal/person/v1", routeTemplate: "person/v1"))
    }

    /// True when the session is accepted. The identity route refuses website sessions, so this
    /// reads a route that does accept them and validates its envelope. An empty list is still valid.
    public func sessionIsValid() async throws -> Bool {
        let _: Page<Course> = try await get(ReadRequest(
            path: "/restapi/personal/courses/v4",
            query: pageQuery(index: 0, size: 1),
            routeTemplate: "courses/v4"
        ))
        return true
    }

    public func allCourses() async throws -> PagedResult<Course> {
        try await allPages(path: "/restapi/personal/courses/v4", routeTemplate: "courses/v4")
    }

    public func updates(courseId: Int, pageSize: Int = 30) async throws -> [CourseUpdate] {
        let page: Page<CourseUpdate> = try await get(ReadRequest(
            path: "/restapi/personal/courses/\(courseId)/stream/v1",
            query: pageQuery(index: 0, size: pageSize),
            routeTemplate: "courses/{id}/stream/v1"
        ))
        return page.items
    }

    public func rootResources(courseId: Int) async throws -> PagedResult<Resource> {
        try await allResourcePages(
            path: "/restapi/personal/courses/\(courseId)/resources/v1",
            routeTemplate: "courses/{id}/resources/v1"
        )
    }

    public func folderResources(courseId: Int, folderId: Int) async throws -> PagedResult<Resource> {
        try await allResourcePages(
            path: "/restapi/personal/courses/\(courseId)/folders/\(folderId)/resources/v1",
            routeTemplate: "courses/{id}/folders/{id}/resources/v1"
        )
    }

    /// The course search route accepts a single course and does not document paging parameters.
    public func searchResources(courseId: Int, text: String) async throws -> PagedResult<Resource> {
        let response: ResourceEnvelope = try await get(ReadRequest(
            path: "/restapi/personal/courses/\(courseId)/resources/search/v1",
            query: [URLQueryItem(name: "locationType", value: "1"), URLQueryItem(name: "searchText", value: text)],
            routeTemplate: "courses/{id}/resources/search/v1"
        ))
        let page = response.resources
        let complete = page.total.map { page.items.count >= $0 } ?? false
        return PagedResult(items: page.items, isComplete: complete && (page.pageIndex ?? 0) == 0)
    }

    public func tasks() async throws -> PagedResult<StudyTask> {
        try await allPages(path: "/restapi/personal/tasks/v1", routeTemplate: "tasks/v1")
    }

    /// The full plan history for a course. `planner/v1` refuses website sessions.
    public func plans(courseId: Int) async throws -> PagedResult<PlanPreview> {
        struct CamelPage: Decodable, Sendable {
            let entityArray: [PlanPreview]
            let total: Int?
            let currentPageIndex: Int?
            let pageSize: Int?
        }
        return try await collect { index in
            let page: CamelPage = try await get(ReadRequest(
                path: "/restapi/personal/course/\(courseId)/plans/all/v1",
                query: pageQuery(index: index, size: Self.maxPageSize),
                routeTemplate: "course/{id}/plans/all/v1"
            ))
            return Page(items: page.entityArray, total: page.total, pageIndex: page.currentPageIndex, pageSize: page.pageSize)
        }
    }

    /// Exchanges a site URL for a signed-in link. The result expires, so it is never stored.
    public func ssoURL(for url: URL) async throws -> URL {
        struct Response: Decodable { let Url: URL }
        let response: Response = try await get(ReadRequest(
            path: "/restapi/personal/sso/url/v1",
            query: [URLQueryItem(name: "url", value: url.absoluteString)],
            routeTemplate: "sso/url/v1"
        ))
        return response.Url
    }

    // MARK: - Helpers

    func pageQuery(index: Int, size: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "PageIndex", value: String(index)), URLQueryItem(name: "PageSize", value: String(size))]
    }

    func get<T: Decodable>(_ request: ReadRequest) async throws -> T {
        let response = try await transport.send(request)
        let data = try response.validatedJSON()
        return try Self.decode(T.self, from: data, route: request.routeTemplate)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, route: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = APIDate.decoding
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            // Only field paths go into the error, never values.
            throw APIError.schema("\(route): \(Self.describe(error))")
        }
    }

    static func describe(_ error: DecodingError) -> String {
        let path: ([CodingKey]) -> String = { $0.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, let context): return "missing \(path(context.codingPath + [key]))"
        case .typeMismatch(_, let context): return "type mismatch at \(path(context.codingPath))"
        case .valueNotFound(_, let context): return "null at \(path(context.codingPath))"
        case .dataCorrupted(let context): return "invalid value at \(path(context.codingPath))"
        @unknown default: return "decoding failed"
        }
    }

    func allPages<Element: Decodable & Sendable>(path: String, routeTemplate: String) async throws -> PagedResult<Element> {
        try await collect { index in
            let page: Page<Element> = try await get(ReadRequest(
                path: path, query: pageQuery(index: index, size: Self.maxPageSize), routeTemplate: routeTemplate
            ))
            return page
        }
    }

    private struct ResourceEnvelope: Decodable, Sendable {
        let resources: Page<Resource>
        enum CodingKeys: String, CodingKey { case resources = "Resources" }
    }

    func allResourcePages(path: String, routeTemplate: String) async throws -> PagedResult<Resource> {
        return try await collect { index in
            let envelope: ResourceEnvelope = try await get(ReadRequest(
                path: path, query: pageQuery(index: index, size: Self.maxPageSize), routeTemplate: routeTemplate
            ))
            return envelope.resources
        }
    }

    /// Reads pages until the reported total is met or a short page arrives. Any failed page fails the whole read.
    func collect<Element>(fetch: (Int) async throws -> Page<Element>) async throws -> PagedResult<Element> {
        var items: [Element] = []
        for index in 0..<Self.pageLimit {
            try Task.checkCancellation()
            let page = try await fetch(index)
            if let reportedIndex = page.pageIndex, reportedIndex != index {
                return PagedResult(items: items, isComplete: false)
            }
            items.append(contentsOf: page.items)
            if let total = page.total {
                if items.count >= total { return PagedResult(items: items, isComplete: true) }
                if page.items.isEmpty { return PagedResult(items: items, isComplete: false) }
            } else if page.items.isEmpty || page.items.count < (page.pageSize ?? Self.maxPageSize) {
                return PagedResult(items: items, isComplete: true)
            }
        }
        return PagedResult(items: items, isComplete: false)
    }
}

public struct PagedResult<Element: Sendable>: Sendable {
    public var items: [Element]
    /// False when the safety cap stopped the read before the listing ended.
    public var isComplete: Bool

    public init(items: [Element], isComplete: Bool) {
        self.items = items
        self.isComplete = isComplete
    }
}

/// Resolves an institution through the public, unauthenticated site lookup.
public struct SiteDirectory: Sendable {
    public static let lookupHost = URL(string: "https://www.itslearning.com")!

    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func site(shortName: String) async throws -> Site {
        let trimmed = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics), !encoded.isEmpty else {
            throw APIError.notFound
        }
        let data = try await read(path: "restapi/sites/shortnames/\(encoded)/v1")
        let site = try ItslearningClient.decode(Site.self, from: data, route: "sites/shortnames/{name}/v1")
        guard Self.isItslearningHost(site) else {
            throw APIError.schema("site base URL is not an itslearning host")
        }
        return site
    }

    /// Every institution the public lookup lists, for searching by name as the person types.
    /// Entries whose base URL is not an itslearning host are dropped, as in `site(shortName:)`.
    public func allSites() async throws -> [Site] {
        let data = try await read(path: "restapi/sites/all/v1")
        let page = try ItslearningClient.decode(Page<Site>.self, from: data, route: "sites/all/v1")
        return page.items.filter(Self.isItslearningHost)
    }

    /// Sites whose name or short name contains every word of the query, ignoring case and accents.
    /// Name and short name prefixes rank first, then alphabetical by name.
    public static func search(_ query: String, in sites: [Site], limit: Int = 8) -> [Site] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let first = words[0]
        let ranked: [(rank: Int, site: Site)] = sites.compactMap { site in
            let title = fold(site.title)
            let short = fold(site.shortName)
            let haystack = title + " " + short
            guard words.allSatisfy(haystack.contains) else { return nil }
            let titleWords = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            let rank: Int
            if short == first { rank = 0 }
            else if short.hasPrefix(first) || title.hasPrefix(first) { rank = 1 }
            else if titleWords.contains(where: { $0.hasPrefix(first) }) { rank = 2 }
            else { rank = 3 }
            return (rank, site)
        }
        return ranked
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.site.title.localizedStandardCompare($1.site.title) == .orderedAscending }
            .prefix(limit)
            .map(\.site)
    }

    /// Letters that diacritic folding keeps whole, so "o" finds "ø" and "ae" finds "æ".
    private static let letterFolds: [Character: String] = ["ø": "o", "æ": "ae", "œ": "oe", "ß": "ss", "ł": "l", "đ": "d", "þ": "th"]

    private static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.reduce(into: "") { result, character in
            result += letterFolds[character] ?? String(character)
        }
    }

    static func isItslearningHost(_ site: Site) -> Bool {
        site.baseURL.scheme == "https" && site.baseURL.host()?.hasSuffix(".itslearning.com") == true
    }

    private func read(path: String) async throws -> Data {
        var request = URLRequest(url: Self.lookupHost.appending(path: path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.notJSON }
        let read = ReadResponse(
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
            finalURL: http.url,
            body: data
        )
        // The lookup is public, so an HTML answer means no such site rather than a lost session.
        guard read.status == 200, read.contentType.lowercased().contains("json") else { throw APIError.notFound }
        return data
    }
}
