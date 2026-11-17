import Foundation
import LaerCore
import WebKit

/// Owns the persistent website session and the one web view used for sign-in and same-origin reads.
@MainActor
final class WebSession: NSObject {
    let site: Site
    /// Created on first use. A signed-in launch never needs a browser engine.
    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        #if DEBUG
        view.isInspectable = true
        #endif
        return view
    }()
    private let dataStore = WKWebsiteDataStore.default()
    private var navigationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called after each finished navigation, so sign-in can notice the return to the site.
    var onNavigationFinished: (() -> Void)?
    /// Called with the OAuth redirect. The custom scheme never leaves this view.
    var onOAuthRedirect: ((URL) -> Void)?
    var onLoadFailed: (() -> Void)?

    init(site: Site) {
        self.site = site
        super.init()
    }

    var isOnSiteOrigin: Bool {
        webView.url?.host() == site.baseURL.host() && webView.url?.scheme == "https"
    }

    func loadSite() {
        webView.load(URLRequest(url: site.baseURL))
    }

    /// Loads the site and waits for navigation to settle, including sign-on redirects.
    func loadSiteAndWait(timeout: Duration = .seconds(20)) async {
        loadSite()
        await waitForNavigation(timeout: timeout)
    }

    func waitForNavigation(timeout: Duration) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.releaseWaiters() }
        }
        await withCheckedContinuation { navigationWaiters.append($0) }
        timer.cancel()
    }

    private func releaseWaiters() {
        let waiters = navigationWaiters
        navigationWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// A small same-origin page, so reads don't keep a full dashboard running.
    func loadLightPage() async {
        webView.load(URLRequest(url: site.baseURL.appending(path: "robots.txt")))
        await waitForNavigation(timeout: .seconds(15))
    }

    var cookieStore: WKHTTPCookieStore { dataStore.httpCookieStore }

    /// Runs one fixed same-origin GET. The path is passed as an argument, never interpolated into script.
    func read(_ request: ReadRequest) async throws -> ReadResponse {
        guard isOnSiteOrigin else { throw APIError.signedOut }
        let script = """
        const response = await fetch(path, {
            credentials: 'same-origin',
            redirect: 'follow',
            headers: { 'Accept': 'application/json' }
        });
        return {
            status: response.status,
            contentType: response.headers.get('content-type') || '',
            retryAfter: response.headers.get('retry-after') || '',
            finalURL: response.url,
            body: await response.text()
        };
        """
        let result = try await webView.callAsyncJavaScript(
            script,
            arguments: ["path": request.relativeURLString],
            contentWorld: .defaultClient
        )
        guard let fields = result as? [String: Any], let status = fields["status"] as? Int else {
            throw APIError.notJSON
        }
        return ReadResponse(
            status: status,
            contentType: fields["contentType"] as? String ?? "",
            retryAfter: (fields["retryAfter"] as? String).flatMap(TimeInterval.init),
            finalURL: (fields["finalURL"] as? String).flatMap(URL.init(string:)),
            body: Data((fields["body"] as? String ?? "").utf8)
        )
    }

    func allCookies() async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies()
    }

    /// Removes this app's website data, which ends its session. Saved files are not touched.
    func clearWebsiteData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        await dataStore.removeData(ofTypes: types, for: records)
    }
}

extension WebSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url, url.scheme == OAuthClient.redirectScheme {
            onOAuthRedirect?(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        releaseWaiters()
        onNavigationFinished?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        releaseWaiters()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        releaseWaiters()
        // Cancelling happens on every OAuth redirect, and that isn't a failure.
        let code = (error as? URLError)?.code
        if code == .notConnectedToInternet || code == .networkConnectionLost || code == .timedOut || code == .cannotFindHost {
            onLoadFailed?()
        }
    }
}

extension WebSession: WKUIDelegate {
    /// Sign-in pages may open pop-ups. Keep them in this view so the session stays together.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// Same-origin reads inside the app's WebKit session.
struct WebKitTransport: ReadTransport {
    let session: WebSession

    func send(_ request: ReadRequest) async throws -> ReadResponse {
        try await session.read(request)
    }
}
