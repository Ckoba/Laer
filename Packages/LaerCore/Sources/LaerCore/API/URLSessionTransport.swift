import Foundation

/// Native HTTP reads using an in-memory cookie jar that belongs to this transport.
public final class URLSessionTransport: ReadTransport, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage

    public init(baseURL: URL, cookies: [HTTPCookie]) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let storage = configuration.httpCookieStorage ?? HTTPCookieStorage()
        cookies.forEach { storage.setCookie($0) }
        cookieStorage = storage
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

    /// Session cookies as they stand now, including any the server rotated.
    public var currentCookies: [HTTPCookie] {
        cookieStorage.cookies ?? []
    }
}

/// An API read that redirects off its origin is a login redirect, so it is returned rather than followed.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let source = task.originalRequest?.url, let target = request.url,
              SameOriginPortRedirects.isSameOrigin(source, target) else { return nil }
        return request
    }
}

extension URLError {
    public var isConnectivityFailure: Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            true
        default:
            false
        }
    }
}

/// Decides which cookies a native session may carry: only those for the given hosts, never the identity provider's.
public enum CookieScope {
    public static func filter(_ cookies: [HTTPCookie], forHosts hosts: [String]) -> [HTTPCookie] {
        cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return hosts.contains { $0 == domain || $0.hasSuffix("." + domain) }
        }
    }
}
