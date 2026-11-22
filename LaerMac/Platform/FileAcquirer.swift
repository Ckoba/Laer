import Foundation
import LaerCore
import WebKit

enum FileAcquirerError: Error {
    case websiteOnly
}

/// Resolves a material's actual bytes through its signed-in viewer page. The viewer names the
/// real file URL. Metadata is not a file, so a viewer page is never reported as a download.
@MainActor
final class FileAcquirer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    typealias PDFPageReady = @MainActor @Sendable (Data) -> Void

    struct Staged {
        var file: URL
        var suggestedName: String?
        var contentType: String?
    }

    private static let script = """
    (function() {
        const find = () => {
            const here = new URL(location.href);
            const direct = here.searchParams.get('FileDownloadUrl');
            if (direct) { return new URL(direct, location.href).href; }
            for (const a of document.querySelectorAll('a[href]')) {
                if (/download/i.test(a.href) && !/PdfViewer/i.test(a.href)) { return a.href; }
            }
            for (const f of document.querySelectorAll('form[action]')) {
                if (/download/i.test(f.action)) { return f.action; }
            }
            return null;
        };
        let reportedURL = null;
        const report = () => {
            const url = find();
            if (url && url !== reportedURL) {
                reportedURL = url;
                window.webkit.messageHandlers.file.postMessage(url);
            }
        };
        // Some viewers add the download control after the page finishes loading.
        new MutationObserver(report).observe(document, {
            subtree: true, childList: true, attributes: true, attributeFilter: ['href', 'action']
        });
        report();
        setTimeout(report, 1000);
        setTimeout(report, 3000);
    })();
    """

    // The element's HTML often includes the signed viewer frame. Reading that link
    // can skip rendering the surrounding course page. Swift picks the frame out of the page.
    private static let viewerLaunchScript = """
    const response = await fetch(entry, {
        credentials: 'same-origin', redirect: 'manual', headers: {'Accept': 'text/html'},
        signal: AbortSignal.timeout(1500)
    });
    if (!response.ok || !response.headers.get('Content-Type')?.toLowerCase().startsWith('text/html')) {
        return null;
    }
    return await response.text();
    """

    private let session: WebSession
    private let client: ItslearningClient
    private let onPDFPage: PDFPageReady?
    private weak var resolverView: WKWebView?
    private var resolverNavigation: WKNavigation?
    private var usingExistingSession = false
    /// The resolver web view was sent to the website's sign-in page, so the session has ended.
    private var sawSignInPage = false
    private var waiting: CheckedContinuation<URL?, Never>?
    private static var blockList: WKContentRuleList?
    /// Signed links can reuse connections across downloads. The session carries no account state.
    private static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init(session: WebSession, client: ItslearningClient, onPDFPage: PDFPageReady? = nil) {
        self.session = session
        self.client = client
        self.onPDFPage = onPDFPage
    }

    static func canAttempt(_ resource: Resource) -> Bool {
        !resource.isFolder && resource.elementType.caseInsensitiveCompare("LearningToolElement") == .orderedSame
    }

    /// `tryExistingSession` is false when a lookup for this file just ran the same chain and found nothing,
    /// so the click signs in instead of repeating it.
    func acquire(_ resource: Resource, tryExistingSession: Bool = true) async throws -> Staged {
        guard Self.canAttempt(resource),
              let element = Self.elementURL(for: resource, on: session.site) else { throw FileAcquirerError.websiteOnly }
        let revision = session.fileSessionRevision

        // A link found while the pointer rested on the row leaves only the bytes to fetch.
        if let ahead = session.takeResolvedLink(for: resource.id) {
            Perf.mark("file link resolved ahead")
            if let staged = try await fetchCourseFile(ahead.url, cookies: ahead.cookies) { return staged }
        }

        if session.hasFileSession, !tryExistingSession {
            session.invalidateFileSession(ifCurrent: revision)
        } else if session.hasFileSession {
            // Plain HTTP off the main thread first: no web view, so a busy window doesn't slow it.
            if let found = await resolveNatively(element, elementId: resource.elementId),
               session.fileSessionRevision == revision,
               let staged = try await fetchCourseFile(found.link, cookies: found.cookies) {
                return staged
            }
            if let staged = try await resolveInWebKit(
                element, elementId: resource.elementId, revision: revision, use: { try await fetchCourseFile($0) }
            ) {
                return staged
            }
            session.invalidateFileSession(ifCurrent: revision)
        }

        let signedRevision = session.fileSessionRevision
        async let signedLink = client.ssoURL(for: element)
        let view = await takeResolver()
        let link = try await signedLink
        Perf.mark("file sign-in link ready")
        usingExistingSession = false
        guard let url = try await resolveFileURL(viewer: link, in: view, timeout: .seconds(20)),
              let staged = try await fetchCourseFile(url) else { throw FileAcquirerError.websiteOnly }
        session.noteFileSession(ifCurrent: signedRevision)
        return staged
    }

    /// Finds the download link without fetching the file, so a click right after only moves bytes.
    /// Works only inside an existing website session and never signs in. The link stays in memory.
    /// True when the whole chain ran uncancelled, whether or not it found a link. A lookup that lands on
    /// the sign-in page ends the file session, so the next click signs in straight away.
    @discardableResult
    func resolveAhead(_ resource: Resource) async -> Bool {
        guard Self.canAttempt(resource), session.hasFileSession,
              session.resolvedLink(for: resource.id) == nil,
              let element = Self.elementURL(for: resource, on: session.site) else { return false }
        let revision = session.fileSessionRevision
        if let found = await resolveNatively(element, elementId: resource.elementId) {
            // Following the link to the file's host now leaves one request for the click, on a warm connection.
            let target = await Self.followToFile(found.link, cookies: found.cookies, origin: session.site.baseURL)
            guard !Task.isCancelled else { return false }
            session.storeResolvedLink(target ?? .init(url: found.link, cookies: found.cookies),
                                      for: resource.id, revision: revision)
            Perf.mark("file link resolved ahead of click")
            return true
        }
        let link = try? await resolveInWebKit(element, elementId: resource.elementId, revision: revision, use: { $0 })
        guard !Task.isCancelled else { return false }
        guard let link else {
            if sawSignInPage { session.invalidateFileSession(ifCurrent: revision) }
            return true
        }
        session.storeResolvedLink(.init(url: link, cookies: nil), for: resource.id, revision: revision)
        Perf.mark("file link resolved ahead of click")
        return true
    }

    /// Inside the existing website session: a freshly signed viewer frame read from the element page,
    /// then the element page itself, each loaded in the resolver web view. Returns the first result `use` gives.
    private func resolveInWebKit<T>(
        _ element: URL, elementId: Int, revision: Int, use: (URL) async throws -> T?
    ) async throws -> T? {
        usingExistingSession = true
        if let launch = try await viewerLaunch(for: element, elementId: elementId), session.fileSessionRevision == revision,
           let url = try await resolveFileURL(viewer: launch, in: await takeResolver(), timeout: .seconds(2)),
           let result = try await use(url) {
            return result
        }
        guard session.fileSessionRevision == revision,
              let url = try await resolveFileURL(viewer: element, in: await takeResolver(), timeout: .seconds(3))
        else { return nil }
        return try await use(url)
    }

    private func resolveNatively(_ element: URL, elementId: Int) async -> NativeFileLink.Found? {
        guard !Task.isCancelled else { return nil }
        let cookies = await session.allCookies()
        let found = await NativeFileLink.resolve(
            element: element, elementId: elementId, siteCookies: cookies, using: session.fileLinkClient)
        if found != nil { Perf.mark("file link resolved natively") }
        return found
    }

    /// Where the download link leads, read from the response headers only; the body is not fetched.
    /// Cookies go along only while the target stays on the link's own host.
    private static func followToFile(_ link: URL, cookies: [HTTPCookie], origin: URL) async -> WebSession.ResolvedLink? {
        let redirects = FileDownloadCookies(source: link, cookies: cookies)
        guard let (bytes, response) = try? await downloadSession.bytes(
            for: redirects.request(for: URLRequest(url: link)), delegate: redirects) else { return nil }
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/html") == false,
              let target = http.url, canAcquireAttachment(at: target, origin: origin) else { return nil }
        let sameHost = AvatarSession.sameOrigin(target, link)
        return .init(url: target, cookies: sameHost ? cookies : [])
    }

    private static func elementURL(for resource: Resource, on site: Site) -> URL? {
        var components = URLComponents(url: site.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/LearningToolElement/ViewLearningToolElement.aspx"
        components?.queryItems = [URLQueryItem(name: "LearningToolElementId", value: String(resource.elementId))]
        return components?.url
    }

    private func viewerLaunch(for element: URL, elementId: Int) async throws -> URL? {
        try Task.checkCancellation()
        guard let page = session.webView.url, AvatarSession.sameOrigin(page, session.site.baseURL) else { return nil }
        let result = try? await session.webView.callAsyncJavaScript(
            Self.viewerLaunchScript,
            arguments: ["entry": element.absoluteString, "elementId": String(elementId)],
            contentWorld: .defaultClient
        )
        try Task.checkCancellation()
        guard let page = result as? String,
              let url = NativeFileLink.viewerFrame(in: page, base: element, elementId: elementId),
              Self.canAcquireAttachment(at: url, origin: session.site.baseURL) else { return nil }
        Perf.mark("file signed viewer frame found")
        return url
    }

    /// `cookies` come with a link plain HTTP found; without them the link came through WebKit.
    private func fetchCourseFile(_ url: URL, cookies: [HTTPCookie]? = nil) async throws -> Staged? {
        Perf.mark("file download link ready")
        if let cookies {
            return try await Self.fetchReusingConnections(url, cookies: cookies, onPDFPage: onPDFPage)
        }
        // WebKit found this one, so the next lookup will likely want a warm resolver too.
        Self.prepareResolver(for: session)
        let host = url.host()?.lowercased() ?? ""
        let cookies = await session.allCookies().filter {
            let domain = $0.domain.lowercased()
            return domain.hasPrefix(".") ? host == domain.dropFirst() || host.hasSuffix(domain) : host == domain
        }
        if let staged = try await Self.fetchReusingConnections(url, cookies: cookies, onPDFPage: onPDFPage) {
            return staged
        }
        return try await Self.fetch(url, session: session)
    }

    nonisolated static func canAcquireAttachment(at url: URL, origin: URL) -> Bool {
        guard url.scheme == "https", url.user() == nil, url.password() == nil,
              let host = url.host()?.lowercased() else { return false }
        return AvatarSession.sameOrigin(url, origin)
            || ((url.port ?? 443) == 443 && host.hasSuffix(".itslearning.com"))
    }

    /// Message attachments include signed links to separate itslearning download hosts.
    static func acquireAttachment(at url: URL, origin: URL, session: WebSession?) async throws -> Staged? {
        guard canAcquireAttachment(at: url, origin: origin) else { return nil }
        let usesCookies = AvatarSession.sameOrigin(url, origin)
            || (url.host()?.lowercased() == "resource.itslearning.com" && (url.port ?? 443) == 443)
        let redirects = AttachmentRedirects(origin: origin)
        if usesCookies, let session {
            return try await fetch(url, session: session, redirects: redirects)
        }
        return try await download(url, using: downloadSession, redirects: redirects)
    }

    private final class AttachmentRedirects: NSObject, URLSessionTaskDelegate {
        let origin: URL

        init(origin: URL) {
            self.origin = origin
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let destination = request.url,
                  FileAcquirer.canAcquireAttachment(at: destination, origin: origin) else { return nil }
            guard let source = task.originalRequest?.url,
                  AvatarSession.sameOrigin(source, destination) else {
                var redirected = request
                redirected.httpShouldHandleCookies = false
                redirected.setValue(nil, forHTTPHeaderField: "Cookie")
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
                return redirected
            }
            return request
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let resolverView, message.webView === resolverView,
              let text = message.body as? String, let url = URL(string: text) else { return }
        finish(with: url)
    }

    /// The PDF viewer's address names the file, so the viewer itself never needs to load.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard webView === resolverView, let url = action.request.url else { return .allow }
        if usingExistingSession, action.targetFrame?.isMainFrame == true,
           AvatarSession.sameOrigin(url, session.site.baseURL),
           url.lastPathComponent.caseInsensitiveCompare("Login.aspx") == .orderedSame {
            sawSignInPage = true
            finish(with: nil)
            return .cancel
        }
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "FileDownloadUrl" })?.value,
              let file = URL(string: value, relativeTo: url)?.absoluteURL,
              Self.canAcquireAttachment(at: file, origin: session.site.baseURL) else { return .allow }
        finish(with: file)
        return .cancel
    }

    private func finish(with url: URL?) {
        guard let waiting else { return }
        if let url, !Self.canAcquireAttachment(at: url, origin: session.site.baseURL) { return }
        self.waiting = nil
        resolverView = nil
        waiting.resume(returning: url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === resolverView else { return }
        // A new request can cancel the standby view's empty page.
        if (error as? URLError)?.code == .cancelled, navigation !== resolverNavigation { return }
        finish(with: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === resolverView { finish(with: nil) }
    }

    /// Images, styles and fonts aren't needed to find a file, and skipping them saves most of the load.
    private static func loadBlockList() async -> WKContentRuleList? {
        if let blockList { return blockList }
        let rules = #"[{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","font","media"]},"action":{"type":"block"}}]"#
        guard let store = WKContentRuleListStore.default() else { return nil }
        // Change the identifier if the rules change so WebKit discards the old list.
        let identifier = "LaerFileResolver.v1"
        let list: WKContentRuleList?
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
            list = cached
        } else {
            list = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
        }
        blockList = list
        return list
    }

    /// Start the next resolver's web process without making any website request.
    static func prepareResolver(for session: WebSession) {
        guard session.standbyFileResolver == nil else { return }
        session.standbyFileResolver = Task(priority: .utility) {
            let view = await makeResolverView()
            if !Task.isCancelled { view.loadHTMLString("", baseURL: nil) }
            return view
        }
    }

    private func takeResolver() async -> WKWebView {
        if let standby = session.standbyFileResolver {
            session.standbyFileResolver = nil
            return await standby.value
        }
        return await Self.makeResolverView()
    }

    private static func makeResolverView() async -> WKWebView {
        let world = WKContentWorld.world(name: "LaerFileResolver")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if let list = await Self.loadBlockList() {
            configuration.userContentController.add(list)
        }
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
    }

    /// Loads the viewer off screen in an isolated script world and waits for a file URL.
    private func resolveFileURL(viewer: URL, in view: WKWebView, timeout: Duration) async throws -> URL? {
        try Task.checkCancellation()
        let world = WKContentWorld.world(name: "LaerFileResolver")
        let controller = view.configuration.userContentController
        controller.add(self, contentWorld: world, name: "file")
        view.navigationDelegate = self
        resolverView = view
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.finish(with: nil) }
        }
        defer {
            expiry.cancel()
            view.navigationDelegate = nil
            resolverNavigation = nil
            view.stopLoading()
            controller.removeScriptMessageHandler(forName: "file", contentWorld: world)
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                Perf.mark("file resolver navigation started")
                resolverNavigation = view.load(URLRequest(url: viewer))
                if resolverNavigation == nil { finish(with: nil) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(with: nil) }
        }
        try Task.checkCancellation()
        return result
    }

    /// Returns nil when the answer is a page rather than a file. Only cookies for the file's host travel.
    private static func fetch(
        _ url: URL, session: WebSession, redirects: (any URLSessionTaskDelegate)? = nil
    ) async throws -> Staged? {
        guard let host = url.host() else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        let cookies = CookieScope.filter(await session.allCookies(), forHosts: [host])
        cookies.forEach { configuration.httpCookieStorage?.setCookie($0) }
        if redirects != nil { configuration.urlCredentialStorage = nil }
        let downloads = URLSession(configuration: configuration)
        defer { downloads.finishTasksAndInvalidate() }
        return try await download(url, using: downloads, redirects: redirects)
    }

    private static func fetchReusingConnections(_ url: URL, cookies: [HTTPCookie], onPDFPage: PDFPageReady?) async throws -> Staged? {
        guard url.host() != nil else { return nil }
        let redirects = FileDownloadCookies(source: url, cookies: cookies)
        let request = redirects.request(for: URLRequest(url: url))
        if let onPDFPage {
            return try await PDFPreviewTransfer.fetch(request, using: downloadSession,
                                                      redirect: redirects.redirectedRequest(for:), onPage: onPDFPage)
        }
        return try await download(request, using: downloadSession, redirects: redirects)
    }

    private final class FileDownloadCookies: NSObject, URLSessionTaskDelegate {
        let source: URL
        let cookies: [HTTPCookie]

        init(source: URL, cookies: [HTTPCookie]) {
            self.source = source
            self.cookies = cookies
        }

        func request(for request: URLRequest) -> URLRequest {
            var result = request
            result.httpShouldHandleCookies = false
            result.setValue(nil, forHTTPHeaderField: "Cookie")
            if let target = request.url, AvatarSession.sameOrigin(source, target) {
                let now = Date()
                let requestedPath = target.path(percentEncoded: true)
                let path = requestedPath.isEmpty ? "/" : requestedPath
                let scoped = cookies.filter {
                    let cookiePath = $0.path
                    return ($0.expiresDate.map { $0 > now } ?? true)
                        && (path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/"))
                }
                if !scoped.isEmpty {
                    result.setValue(HTTPCookie.requestHeaderFields(with: scoped)["Cookie"], forHTTPHeaderField: "Cookie")
                }
            }
            return result
        }

        func redirectedRequest(for redirect: URLRequest) -> URLRequest? {
            guard let target = redirect.url, target.scheme == "https",
                  target.user() == nil, target.password() == nil else { return nil }
            return request(for: redirect)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest redirect: URLRequest
        ) async -> URLRequest? {
            redirectedRequest(for: redirect)
        }
    }

    private static func download(
        _ url: URL, using session: URLSession, redirects: (any URLSessionTaskDelegate)?
    ) async throws -> Staged? {
        try await download(URLRequest(url: url), using: session, redirects: redirects)
    }

    private static func download(
        _ request: URLRequest, using session: URLSession, redirects: (any URLSessionTaskDelegate)?
    ) async throws -> Staged? {
        try Task.checkCancellation()
        let (temporary, response) = try await session.download(for: request, delegate: redirects)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        if (try? DownloadStore.validate(fileAt: temporary, contentType: contentType)) == nil {
            return nil
        }
        let staged = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: staged)
        return Staged(file: staged, suggestedName: http.suggestedFilename, contentType: contentType)
    }
}
