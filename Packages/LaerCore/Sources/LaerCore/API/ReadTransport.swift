import Foundation

/// A read request against the signed-in site. `routeTemplate` is the only form that may be logged.
public struct ReadRequest: Sendable, Hashable {
    public var path: String
    public var query: [URLQueryItem]
    public var routeTemplate: String

    public init(path: String, query: [URLQueryItem] = [], routeTemplate: String) {
        self.path = path
        self.query = query
        self.routeTemplate = routeTemplate
    }

    /// Path and query, relative to the site origin.
    public var relativeURLString: String {
        var components = URLComponents()
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.string ?? path
    }
}

public struct ReadResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var retryAfter: TimeInterval?
    public var finalURL: URL?
    public var body: Data

    public init(status: Int, contentType: String, retryAfter: TimeInterval? = nil, finalURL: URL? = nil, body: Data) {
        self.status = status
        self.contentType = contentType
        self.retryAfter = retryAfter
        self.finalURL = finalURL
        self.body = body
    }
}

/// The one seam between native HTTP, WebKit execution and test fixtures.
public protocol ReadTransport: Sendable {
    func send(_ request: ReadRequest) async throws -> ReadResponse
}

public enum APIError: Error, Equatable, Sendable {
    /// The session is missing or expired, including a login page returned with HTTP 200.
    case signedOut
    case forbidden
    case notFound
    case throttled(retryAfter: TimeInterval?)
    case server(status: Int)
    case unexpectedStatus(Int)
    /// The response was not the JSON the route promises.
    case notJSON
    case schema(String)
    case offline

    public var isTransient: Bool {
        switch self {
        case .server, .offline: true
        default: false
        }
    }
}

extension ReadResponse {
    /// Validates status and content type. HTTP 200 alone is not success.
    public func validatedJSON() throws -> Data {
        switch status {
        case 200..<300: break
        case 300..<400, 401: throw APIError.signedOut
        case 403: throw APIError.forbidden
        case 404: throw APIError.notFound
        case 429: throw APIError.throttled(retryAfter: retryAfter)
        case 500..<600: throw APIError.server(status: status)
        default: throw APIError.unexpectedStatus(status)
        }
        let type = contentType.lowercased()
        if type.contains("text/html") { throw APIError.signedOut }
        guard type.contains("json") else { throw APIError.notJSON }
        return body
    }
}
