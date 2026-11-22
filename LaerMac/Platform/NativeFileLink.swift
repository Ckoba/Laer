import Foundation
import LaerCore

/// Finds a course file's download link with plain HTTP, off the main thread, inside the website
/// session WebKit already holds. Same chain as the viewer: element page, its signed sign-on frame,
/// then the file page on the resource host. Nil when any step looks different; WebKit then takes over.
enum NativeFileLink {
    struct Found: Sendable {
        var link: URL
        /// Cookies the chain set for the link's host. They stay in memory with the link.
        var cookies: [HTTPCookie]
    }

    /// One per website session, so lookups reuse open connections. Its cookies stay in memory.
    final class Client: @unchecked Sendable {
        let origin: URL
        fileprivate let session: URLSession
        fileprivate let storage: HTTPCookieStorage?

        init(origin: URL) {
            self.origin = origin
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 4
            storage = configuration.httpCookieStorage
            session = URLSession(configuration: configuration, delegate: Redirects(origin: origin), delegateQueue: nil)
        }

        func invalidate() {
            session.invalidateAndCancel()
        }
    }

    static func resolve(element: URL, elementId: Int, siteCookies: [HTTPCookie], using client: Client) async -> Found? {
        let origin = client.origin
        guard let originHost = origin.host()?.lowercased() else { return nil }
        // The website's current cookies, so a renewed session is the one used.
        let storage = client.storage
        CookieScope.filter(siteCookies, forHosts: [originHost]).forEach { storage?.setCookie($0) }
        let session = client.session

        // The element page names its signed viewer frame. A redirect here means the session ended.
        guard let page = await html(URLRequest(url: element), session: session, followRedirects: false),
              let launch = viewerFrame(in: page.text, base: element, elementId: elementId),
              FileAcquirer.canAcquireAttachment(at: launch, origin: origin) else { return nil }
        Perf.mark("file signed viewer frame found")

        // The frame signs in on the resource host and lands on the file page.
        guard let filePage = await html(URLRequest(url: launch), session: session, followRedirects: true),
              let link = downloadLink(in: filePage.text, page: filePage.url),
              FileAcquirer.canAcquireAttachment(at: link, origin: origin) else { return nil }
        return Found(link: link, cookies: storage?.cookies(for: link) ?? [])
    }

    /// The one sign-on frame for this element, as the viewer would load it.
    static func viewerFrame(in html: String, base: URL, elementId: Int) -> URL? {
        var launches = Set<URL>()
        for source in attributes(src, in: html) {
            guard let url = URL(string: source, relativeTo: base)?.absoluteURL,
                  url.path.lowercased().hasSuffix("/loginsso.aspx") else { continue }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.contains(where: { $0.name == "Signature" && !($0.value ?? "").isEmpty }),
                  items.first(where: { $0.name == "ElementId" })?.value == String(elementId) else { continue }
            launches.insert(url)
        }
        return launches.count == 1 ? launches.first : nil
    }

    /// The file page links its download for PDFs. Office pages build the same link in script from
    /// the ids in the page's own address, so it is rebuilt from those.
    static func downloadLink(in html: String, page: URL) -> URL? {
        for href in attributes(href, in: html) {
            guard let url = URL(string: href, relativeTo: page)?.absoluteURL,
                  url.path.lowercased().hasSuffix("/proxy/downloadredirect.ashx") else { continue }
            return url
        }
        guard page.path.lowercased().hasSuffix("/file/view.aspx") else { return nil }
        let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value.flatMap { Int($0) }.map(String.init)
        }
        guard let object = value("LearningObjectId"), let instance = value("LearningObjectInstanceId") else { return nil }
        var components = URLComponents()
        components.scheme = page.scheme
        components.host = page.host()
        components.port = page.port
        components.path = "/Proxy/DownloadRedirect.ashx"
        components.queryItems = [
            URLQueryItem(name: "LearningObjectId", value: object),
            URLQueryItem(name: "LearningObjectInstanceId", value: instance),
        ]
        return components.url
    }

    private static let src = attributePattern("src")
    private static let href = attributePattern("href")

    private static func attributePattern(_ name: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive])
    }

    private static func attributes(_ expression: NSRegularExpression?, in html: String) -> [String] {
        guard let expression else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            for group in 1...2 {
                if let found = Range(match.range(at: group), in: html) { return unescape(String(html[found])) }
            }
            return nil
        }
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func html(
        _ request: URLRequest, session: URLSession, followRedirects: Bool
    ) async -> (text: String, url: URL)? {
        var request = request
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let delegate: Redirects.Stop? = followRedirects ? nil : Redirects.Stop()
        guard let (data, response) = try? await session.data(for: request, delegate: delegate),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/html") == true,
              let url = http.url, url.scheme == "https",
              url.lastPathComponent.caseInsensitiveCompare("Login.aspx") != .orderedSame,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, url)
    }

    /// Redirects stay on https itslearning hosts.
    private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
        let origin: URL

        init(origin: URL) {
            self.origin = origin
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let target = request.url, FileAcquirer.canAcquireAttachment(at: target, origin: origin) else { return nil }
            return request
        }

        /// For the element page, where any redirect means the session is gone.
        final class Stop: NSObject, URLSessionTaskDelegate, Sendable {
            func urlSession(
                _ session: URLSession, task: URLSessionTask,
                willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
            ) async -> URLRequest? { nil }
        }
    }
}
