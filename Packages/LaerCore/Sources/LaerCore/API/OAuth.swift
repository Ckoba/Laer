import CryptoKit
import Foundation
import OSLog
import Security

/// The public OAuth client Laer signs in with. This is the identifier other open-source clients
/// use, not one issued to Laer, so the website session stays available as a fallback.
public enum OAuthClient {
    /// The public client registered for itslearning's own mobile app. It is shared by every
    /// installation and is not a secret; it identifies the app type, not a person or Laer.
    public static let clientId = "10ae9d30-1853-48ff-81cb-47b58a325685"
    public static let redirectScheme = "itsl-itslearning"
    public static let redirectHost = "login"
    public static let redirectURI = "itsl-itslearning://login"
    /// The literal string the mobile client sends. itslearning grants the client's fixed scope
    /// whatever is asked for, so this is a placeholder by design rather than a missing value.
    public static let scope = "SCOPE"

    /// `pkce` adds an S256 code challenge; pass the same pair's verifier to `exchange`.
    public static func authorizeURL(site: Site, state: String, pkce: OAuthPKCE? = nil) -> URL? {
        var components = URLComponents(url: site.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/oauth2/authorize.aspx"
        var items = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        if let pkce {
            items.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: OAuthPKCE.method))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Returns the code from a redirect, only when it is exactly this app's callback and its state
    /// matches this sign-in attempt.
    public static func code(fromRedirect url: URL, expectedState: String) -> String? {
        try? parseCallback(url, expectedState: expectedState)
    }

    /// Accepts only `itsl-itslearning://login` (optionally with a `/` path) carrying exactly one
    /// `state` equal to `expectedState` and exactly one non-empty `code`.
    public static func parseCallback(_ url: URL, expectedState: String) throws(OAuthCallbackError) -> String {
        guard url.scheme == redirectScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == redirectHost,
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty || components.path == "/",
              components.fragment == nil else { throw .notCallback }
        let items = components.queryItems ?? []
        if items.contains(where: { $0.name == "error" }) { throw .denied }
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        guard states.count <= 1, codes.count <= 1 else { throw .duplicateParameter }
        guard !expectedState.isEmpty, let state = states.first?.value,
              constantTimeEqual(state, expectedState) else { throw .stateMismatch }
        guard let code = codes.first?.value, !code.isEmpty else { throw .missingCode }
        return code
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public enum OAuthCallbackError: Error, Equatable, Sendable {
    /// Not this app's sign-in callback (wrong scheme, host, path or extra parts).
    case notCallback
    /// The sign-in page reported an error, such as the person cancelling.
    case denied
    case duplicateParameter
    case stateMismatch
    case missingCode
}

/// Proof Key for Code Exchange (RFC 7636) with the S256 method.
public struct OAuthPKCE: Sendable, Equatable {
    public static let method = "S256"
    /// 43 base64url characters from 32 random bytes.
    public let verifier: String
    /// base64url(SHA-256(verifier)), without padding.
    public let challenge: String

    /// A fresh pair from the system's secure random generator.
    public init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw APIError.unexpectedStatus(Int(status)) }
        self.init(verifier: Self.base64URL(Data(bytes)))
    }

    /// The pair for a known verifier, for checking against published test vectors.
    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.challenge(for: verifier)
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
/// Requests never follow a redirect, so a code or refresh token is only ever sent to `baseURL`.
public struct OAuthTokenClient: Sendable {
    let baseURL: URL
    let session: URLSession

    /// Ephemeral (no cookies, cache or credentials on disk) and refusing every redirect.
    public static let defaultSession = makeSession()

    /// A token session on `configuration` (made ephemeral-safe) that refuses every redirect.
    public static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public init(baseURL: URL, session: URLSession = OAuthTokenClient.defaultSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `pkceVerifier` is the verifier of the pair whose challenge went into `authorizeURL`.
    public func exchange(code: String, pkceVerifier: String? = nil) async throws -> OAuthTokens {
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": OAuthClient.clientId,
            "redirect_uri": OAuthClient.redirectURI,
        ]
        if let pkceVerifier { fields["code_verifier"] = pkceVerifier }
        return try await post(fields)
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
            // A refused redirect ends here: nothing was sent to the new location.
            case 300..<400: throw APIError.unexpectedStatus(http.statusCode)
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

/// Token requests carry codes and refresh tokens in their bodies, so they never follow a redirect.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Follows a redirect only to the same scheme, host and port as the original request, over HTTPS,
/// so the bearer header can never reach another origin.
final class SameOriginPortRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let source = task.originalRequest?.url, let target = request.url else { return nil }
        return Self.isSameOrigin(source, target) ? request : nil
    }

    static func isSameOrigin(_ source: URL, _ target: URL) -> Bool {
        guard source.scheme?.lowercased() == "https", target.scheme?.lowercased() == "https",
              let sourceHost = source.host()?.lowercased(), let targetHost = target.host()?.lowercased() else { return false }
        return sourceHost == targetHost && (source.port ?? 443) == (target.port ?? 443)
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
        session = URLSession(configuration: configuration, delegate: SameOriginPortRedirects(), delegateQueue: nil)
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
