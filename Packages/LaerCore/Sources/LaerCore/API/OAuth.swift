import Foundation
import OSLog

/// The public OAuth client Laer signs in with. This is the identifier other open-source clients
/// use, not one issued to Laer, so the website session stays available as a fallback.
public enum OAuthClient {
    public static let clientId = "10ae9d30-1853-48ff-81cb-47b58a325685"
    public static let redirectScheme = "itsl-itslearning"
    public static let redirectURI = "itsl-itslearning://login"
    public static let scope = "SCOPE"

    public static func authorizeURL(site: Site, state: String) -> URL? {
        var components = URLComponents(url: site.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/oauth2/authorize.aspx"
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        return components?.url
    }

    /// Returns the code from a redirect, only when its state matches this sign-in attempt.
    public static func code(fromRedirect url: URL, expectedState: String) -> String? {
        guard url.scheme == redirectScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == expectedState else { return nil }
        return items.first { $0.name == "code" }?.value
    }
}

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Exchanges codes and refresh tokens. A rejected refresh token means an interactive sign-in is needed.
public struct OAuthTokenClient: Sendable {
    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func exchange(code: String) async throws -> OAuthTokens {
        try await post([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": OAuthClient.clientId,
            "redirect_uri": OAuthClient.redirectURI,
        ])
    }

    public func refresh(_ refreshToken: String) async throws -> OAuthTokens {
        try await post([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": OAuthClient.clientId,
        ])
    }

    private func post(_ fields: [String: String]) async throws -> OAuthTokens {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Double?
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/:")
        var request = URLRequest(url: baseURL.appending(path: "restapi/oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.notJSON }
            Logger(subsystem: "app.laer.Laer", category: "session").notice("token route status \(http.statusCode)")
            switch http.statusCode {
            case 200..<300: break
            case 400, 401, 403: throw APIError.signedOut
            case 429: throw APIError.throttled(retryAfter: nil)
            case 500..<600: throw APIError.server(status: http.statusCode)
            default: throw APIError.unexpectedStatus(http.statusCode)
            }
            let decoded = try ItslearningClient.decode(Response.self, from: data, route: "oauth2/token")
            return OAuthTokens(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token,
                expiresAt: Date().addingTimeInterval(decoded.expires_in ?? 3600)
            )
        } catch let error as URLError where error.isConnectivityFailure {
            throw APIError.offline
        }
    }
}

/// Holds the current tokens, so a refresh is seen by every in-flight and later request.
public actor TokenBox {
    public private(set) var tokens: OAuthTokens

    public init(tokens: OAuthTokens) {
        self.tokens = tokens
    }

    public func update(_ tokens: OAuthTokens) {
        self.tokens = tokens
    }
}

/// Native HTTP with a bearer token. The token goes in a header only, never in a URL, and never to another host.
public final class BearerTransport: WriteTransport, @unchecked Sendable {
    private let baseURL: URL
    private let box: TokenBox
    private let session: URLSession

    public init(baseURL: URL, box: TokenBox) {
        self.baseURL = baseURL
        self.box = box
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: ReadRequest) async throws -> ReadResponse {
        guard let url = URL(string: request.relativeURLString, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.unexpectedStatus(0)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(await box.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        return try await perform(urlRequest)
    }

    /// One attempt only. Writes are never retried or replayed here.
    public func sendWrite(_ request: WriteRequest) async throws -> ReadResponse {
        var components = URLComponents()
        components.path = request.path
        if !request.query.isEmpty { components.queryItems = request.query }
        guard let relative = components.string, let url = URL(string: relative, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.unexpectedStatus(0)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(await box.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let encoded = request.encodedBody()
        if let encoded {
            urlRequest.setValue(encoded.contentType, forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = encoded.data
        }
        return try await perform(urlRequest)
    }

    private func perform(_ urlRequest: URLRequest) async throws -> ReadResponse {
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw APIError.notJSON }
            return ReadResponse(
                status: http.statusCode,
                contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init),
                finalURL: http.url,
                body: data
            )
        } catch let error as URLError where error.isConnectivityFailure {
            throw APIError.offline
        }
    }
}
