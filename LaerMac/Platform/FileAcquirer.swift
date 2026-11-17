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
        const report = () => {
            const url = find();
            if (url) { window.webkit.messageHandlers.file.postMessage(url); }
        };
        report();
        setTimeout(report, 1000);
        setTimeout(report, 3000);
    })();
    """

    private let session: WebSession
    private let client: ItslearningClient
    private var found: URL?
    private var waiting: CheckedContinuation<URL?, Never>?
    private static var blockList: WKContentRuleList?

    init(session: WebSession, client: ItslearningClient) {
        self.session = session
        self.client = client
    }

    static func canAttempt(_ resource: Resource) -> Bool {
        !resource.isFolder && resource.elementType.caseInsensitiveCompare("LearningToolElement") == .orderedSame
    }

    func acquire(_ resource: Resource) async throws -> Staged {
        guard Self.canAttempt(resource) else { throw FileAcquirerError.websiteOnly }
        var components = URLComponents(url: session.site.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/LearningToolElement/ViewLearningToolElement.aspx"
        components?.queryItems = [URLQueryItem(name: "LearningToolElementId", value: String(resource.elementId))]
        guard let element = components?.url else { throw FileAcquirerError.websiteOnly }
        let link = try await client.ssoURL(for: element)
        guard let fileURL = await resolveFileURL(viewer: link), let staged = try await fetch(fileURL) else {
            throw FileAcquirerError.websiteOnly
        }
        return staged
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, let url = URL(string: text) else { return }
        finish(with: url)
    }

    /// The PDF viewer's address names the file, so the viewer itself never needs to load.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "FileDownloadUrl" })?.value,
              let file = URL(string: value, relativeTo: url)?.absoluteURL else { return .allow }
        finish(with: file)
        return .cancel
    }

    private func finish(with url: URL?) {
        if let url {
            guard url.scheme == "https", url.host()?.hasSuffix(".itslearning.com") == true else { return }
        }
        found = url
        waiting?.resume(returning: url)
        waiting = nil
    }

    /// Images, styles and fonts aren't needed to find a file, and skipping them saves most of the load.
    private static func loadBlockList() async -> WKContentRuleList? {
        if let blockList { return blockList }
        let rules = #"[{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","font","media"]},"action":{"type":"block"}}]"#
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "LaerFileResolver", encodedContentRuleList: rules)
        blockList = list
        return list
    }

    /// Loads the viewer off screen in an isolated script world and waits for a file URL.
    private func resolveFileURL(viewer: URL) async -> URL? {
        let world = WKContentWorld.world(name: "LaerFileResolver")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if let list = await Self.loadBlockList() {
            configuration.userContentController.add(list)
        }
        configuration.userContentController.add(self, contentWorld: world, name: "file")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        view.navigationDelegate = self
        view.load(URLRequest(url: viewer))
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { self?.finish(with: nil) }
        }
        let result: URL? = await withCheckedContinuation { continuation in
            if let found {
                continuation.resume(returning: found)
            } else {
                waiting = continuation
            }
        }
        timeout.cancel()
        view.stopLoading()
        configuration.userContentController.removeScriptMessageHandler(forName: "file", contentWorld: world)
        return result
    }

    /// Returns nil when the answer is a page rather than a file. Only cookies for the file's host travel.
    private func fetch(_ url: URL) async throws -> Staged? {
        guard let host = url.host() else { return nil }
        let cookies = CookieScope.filter(await session.allCookies(), forHosts: [host])
        let configuration = URLSessionConfiguration.ephemeral
        cookies.forEach { configuration.httpCookieStorage?.setCookie($0) }
        let downloads = URLSession(configuration: configuration)
        defer { downloads.finishTasksAndInvalidate() }

        let (temporary, response) = try await downloads.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        if (try? DownloadStore.validate(fileAt: temporary, contentType: contentType)) == nil {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
        let staged = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: staged)
        return Staged(file: staged, suggestedName: http.suggestedFilename, contentType: contentType)
    }
}
