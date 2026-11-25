import AppKit
import Foundation
import Observation
import OSLog
import PDFKit
import QuickLookThumbnailing
import WebKit

enum OfficePDFConverterError: Error {
    case previewUnavailable
    case printFailed
}

/// Quick Look produces the local HTML preview. WebKit captures it as PDF pages.
@MainActor
@Observable
final class OfficePDFConverter: NSObject, WKNavigationDelegate {
    private static var conversions: [String: OfficePDFConverter] = [:]
    private static let websiteData = WKWebsiteDataStore.nonPersistent()
    private struct Preparation {
        let view: WKWebView
        // Keeps the helper running until the conversion opens its own connection.
        let connection: NSXPCConnection
    }
    private static var preparation: Preparation?

    @ObservationIgnored private var loaded: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var previewNavigation: WKNavigation?
    @ObservationIgnored private var task: Task<URL, Error>?
    let source: URL
    private(set) var coverPDF: Data?
    private(set) var capturedPages: [Data] = []
    var hasPreview: Bool { coverPDF != nil || !capturedPages.isEmpty }
    private(set) var isFinished = false

    private init(source: URL) {
        self.source = source
        super.init()
    }

    static func cachedPDF(for source: URL, id: String) -> URL? {
        let url = cacheDirectory(for: id).appending(path: source.lastPathComponent + ".pdf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func removeCached(for id: String) {
        conversions.removeValue(forKey: id)?.task?.cancel()
        try? FileManager.default.removeItem(at: cacheDirectory(for: id))
    }

    static func prepareRenderer() {
        guard preparation == nil else { return }
        let view = makeRenderView()
        view.loadHTMLString("", baseURL: nil)
        let connection = makeConnection()
        let service = connection.remoteObjectProxyWithErrorHandler { _ in } as? QuickLookPreviewing
        service?.preparePreview {}
        preparation = Preparation(view: view, connection: connection)
        Perf.mark("office renderer preparation started")
    }

    static func cancelConversions() {
        preparation?.connection.invalidate()
        preparation = nil
        for conversion in conversions.values { conversion.task?.cancel() }
        conversions.removeAll()
    }

    private static var cacheRoot: URL {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "ConvertedOffice", directoryHint: .isDirectory)
    }

    private static func cacheDirectory(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
        return cacheRoot.appending(path: safe, directoryHint: .isDirectory)
    }

    /// Converted copies hold course content, so they go with the account.
    static func removeCachedFiles() {
        cancelConversions()
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    static func convert(_ source: URL, id: String) async throws -> URL {
        try Task.checkCancellation()
        if let cached = cachedPDF(for: source, id: id) { return cached }
        return try await conversion(for: source, id: id).result()
    }

    static func conversion(for source: URL, id: String) -> OfficePDFConverter {
        if let existing = conversions[id], existing.source == source { return existing }
        conversions.removeValue(forKey: id)?.task?.cancel()
        let conversion = OfficePDFConverter(source: source)
        conversion.task = Task {
            defer {
                if conversions[id] === conversion { conversions[id] = nil }
            }
            return try await conversion.convertUncached(source, id: id)
        }
        conversions[id] = conversion
        return conversion
    }

    func result() async throws -> URL {
        guard let task else { throw OfficePDFConverterError.previewUnavailable }
        return try await task.value
    }

    private func convertUncached(_ source: URL, id: String) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appending(path: "LaerOffice-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let log = Logger(subsystem: "app.laer.Laer", category: "convert")
        let prepared = Self.preparation
        Self.preparation = nil
        defer { prepared?.connection.invalidate() }
        let view = prepared?.view ?? Self.makeRenderView()
        if prepared == nil {
            // Start WebKit while the helper generates HTML.
            view.loadHTMLString("", baseURL: nil)
        } else {
            Perf.mark("office prepared renderer used")
        }
        let folder = Self.cacheDirectory(for: id)
        let destination = folder.appending(path: source.lastPathComponent + ".pdf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = work.appending(path: "output.pdf")
        let pages = try await renderOfficeFile(source, in: work, using: view)
        log.notice("rendered \(pages.count) pages")
        guard !pages.isEmpty else { throw OfficePDFConverterError.printFailed }
        try Task.checkCancellation()
        // Encode a separate document off the UI thread while the reader uses its own pages.
        let written = await Task.detached(priority: .userInitiated) { Self.write(pages, to: staged) }.value
        try Task.checkCancellation()
        guard written else { throw OfficePDFConverterError.printFailed }
        do {
            try FileManager.default.moveItem(at: staged, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // A second Laer process can finish the same file while this one is saving it.
            guard Self.cachedPDF(for: source, id: id) != nil else { throw error }
        }
        isFinished = true
        Perf.mark("office full PDF ready")
        return destination
    }

    private func renderOfficeFile(_ source: URL, in work: URL, using view: WKWebView) async throws -> [Data] {
        let ext = source.pathExtension.lowercased()
        let complete = work.appendingPathComponent("Complete", isDirectory: true)
        try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: false)
        // The helper only reads files inside this scratch folder; on APFS the copy is a clone.
        let input = work.appendingPathComponent("Document." + ext, isDirectory: false)
        try FileManager.default.copyItem(at: source, to: input)
        // The system's own picture of the first slide shows while Quick Look writes the whole deck.
        let cover = ViewerItem.slideExtensions.contains(ext) ? Task { [weak self] in
            guard let page = await Self.coverPage(for: source), !Task.isCancelled,
                  let self, self.capturedPages.isEmpty else { return }
            self.coverPDF = page
            Perf.mark("office first page rendered")
        } : nil
        defer { cover?.cancel() }
        let preview = try await Self.quickLookHTML(for: input, in: complete)
        return try await render(preview, in: view, isWord: ViewerItem.wordExtensions.contains(ext))
    }

    /// A one-page PDF of the file's Quick Look thumbnail, or nil if the system has none.
    nonisolated static func coverPage(for source: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: source, size: CGSize(width: 960, height: 960), scale: 2, representationTypes: .thumbnail)
        guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = thumbnail.cgImage
        let size = NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        guard size.width > 0, size.height > 0, let page = PDFPage(image: NSImage(cgImage: image, size: size)) else { return nil }
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document.dataRepresentation()
    }

    private nonisolated static func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: "app.laer.Laer.QuickLookService")
        connection.remoteObjectInterface = NSXPCInterface(with: QuickLookPreviewing.self)
        connection.resume()
        return connection
    }

    /// Asks the helper service to run Quick Look. Its sandbox rules forbid running it from this app.
    /// Cancelling the task closes the connection, which stops Quick Look in the helper at once,
    /// and removes the partial output instead of waiting for the helper's own time limit.
    private nonisolated static func quickLookHTML(for source: URL, in directory: URL) async throws -> URL {
        try Task.checkCancellation()
        let connection = makeConnection()
        defer { connection.invalidate() }
        let closer = ConnectionCloser(connection)
        let succeeded: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let once = OnceFlag()
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    if once.claim() { continuation.resume(returning: false) }
                } as? QuickLookPreviewing
                guard let proxy else {
                    if once.claim() { continuation.resume(returning: false) }
                    return
                }
                proxy.writePreview(sourcePath: source.path, outputPath: directory.path) { result in
                    if once.claim() { continuation.resume(returning: result) }
                }
            }
        } onCancel: {
            // Invalidation also fires the error handler above, which ends the wait.
            closer.close()
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
        let html = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "Preview.html" }
        guard succeeded, let html else { throw OfficePDFConverterError.previewUnavailable }
        try Task.checkCancellation()
        Perf.mark("office full HTML ready")
        return html
    }

    private static func makeRenderView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.websiteData
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
    }

    private func render(_ html: URL, in view: WKWebView, isWord: Bool) async throws -> [Data] {
        // Office files can reference remote images and links; none of them may load.
        guard let rules = await Self.localOnlyRules() else { throw OfficePDFConverterError.previewUnavailable }
        view.configuration.userContentController.removeAllContentRuleLists()
        view.configuration.userContentController.add(rules)
        view.navigationDelegate = self
        // A preview that never finishes loading fails the conversion instead of leaving a spinner.
        let timeout = Task { [weak self] in
            try await Task.sleep(for: Self.loadTimeout)
            view.stopLoading()
            self?.finishLoading(.failure(OfficePDFConverterError.previewUnavailable))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loaded = continuation
                previewNavigation = view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
                if previewNavigation == nil { finishLoading(.failure(OfficePDFConverterError.previewUnavailable)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishLoading(.failure(CancellationError())) }
        }
        Logger(subsystem: "app.laer.Laer", category: "convert").notice("preview loaded")
        let script = isWord ? Self.wordPageBoxes : Self.slidePageBoxes
        let result = try await view.callAsyncJavaScript(script, contentWorld: .defaultClient)
        guard let boxes = result as? [[Double]], !boxes.isEmpty else { throw OfficePDFConverterError.printFailed }

        for box in boxes {
            try Task.checkCancellation()
            guard box.count == 4, box.allSatisfy(\.isFinite), box[2] > 0, box[3] > 0 else {
                throw OfficePDFConverterError.printFailed
            }
            let capture = WKPDFConfiguration()
            capture.rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
            capturedPages.append(try await view.pdf(configuration: capture))
            if coverPDF != nil { coverPDF = nil }
        }
        return capturedPages
    }

    /// Draws each captured page straight into the output file, so only one parsed page is held at a time.
    /// Web links on a page are carried over; other annotations do not exist in WebKit captures.
    private nonisolated static func write(_ pages: [Data], to url: URL) -> Bool {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else { return false }
        var complete = true
        for bytes in pages {
            let drawn: Bool = autoreleasepool {
                guard let provider = CGDataProvider(data: bytes as CFData),
                      let page = CGPDFDocument(provider)?.page(at: 1) else { return false }
                var box = page.getBoxRect(.mediaBox)
                context.beginPage(mediaBox: &box)
                context.drawPDFPage(page)
                for (link, rect) in webLinks(on: page) { context.setURL(link as CFURL, for: rect) }
                context.endPage()
                return true
            }
            guard drawn else {
                complete = false
                break
            }
        }
        context.closePDF()
        if !complete { try? FileManager.default.removeItem(at: url) }
        return complete
    }

    /// The `http`, `https` and `mailto` link annotations on a page, in page coordinates.
    private nonisolated static func webLinks(on page: CGPDFPage) -> [(URL, CGRect)] {
        guard let dictionary = page.dictionary else { return [] }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return [] }
        var links: [(URL, CGRect)] = []
        for index in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            var subtype: UnsafePointer<CChar>?
            var action: CGPDFDictionaryRef?
            var uri: CGPDFStringRef?
            var corners: CGPDFArrayRef?
            guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation,
                  CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype, String(cString: subtype) == "Link",
                  CGPDFDictionaryGetDictionary(annotation, "A", &action), let action,
                  CGPDFDictionaryGetString(action, "URI", &uri), let uri,
                  let text = CGPDFStringCopyTextString(uri) as String?, let link = URL(string: text),
                  ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? ""),
                  CGPDFDictionaryGetArray(annotation, "Rect", &corners), let corners,
                  CGPDFArrayGetCount(corners) == 4 else { continue }
            var values = [CGPDFReal](repeating: 0, count: 4)
            guard (0..<4).allSatisfy({ CGPDFArrayGetNumber(corners, $0, &values[$0]) }) else { continue }
            let rect = CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                              width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
            links.append((link, rect))
        }
        return links
    }

    private static let slidePageBoxes = """
        document.body.style.background = 'white';
        for (let tries = 0; tries < 100; tries++) {
            if ([...document.images].every(image => image.complete)) { break; }
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        const style = document.createElement('style');
        style.textContent = 'div.slide { -webkit-box-shadow: none !important; }';
        document.head.appendChild(style);
        return [...document.querySelectorAll('div.slide')].map(slide => {
            const box = slide.getBoundingClientRect();
            return [box.left + window.scrollX, box.top + window.scrollY, box.width, box.height];
        });
        """

    // CSS columns paginate the Quick Look preview at line boundaries.
    private static let wordPageBoxes = """
    const style = document.createElement('style');
    style.textContent = `
        html { margin: 0; background: white; }
        body { margin: 0 !important; padding: 54px !important; }
        #laer-word-pages {
            width: 504px; height: 684px;
            column-width: 504px; column-gap: 108px; column-fill: auto;
        }
        img { max-width: 100%; max-height: 684px; object-fit: contain; }
    `;
    document.head.appendChild(style);
    const layout = document.createElement('div');
    layout.id = 'laer-word-pages';
    while (document.body.firstChild) { layout.append(document.body.firstChild); }
    document.body.append(layout);
    const stride = 612, height = 792;
    const width = layout.scrollWidth;
    const count = Math.max(1, Math.ceil(width / stride));
    // Fall back to Quick Look when a fixed-size object overflows a page.
    if (width > (count - 1) * stride + 505 || layout.scrollHeight > 685) { return []; }
    return Array.from({length: count}, (_, page) => [page * stride, 0, stride, height]);
    """

    private static let loadTimeout = Duration.seconds(30)

    /// Blocks every load that is not a local file or inline data. Compiled once per launch.
    private static var localOnlyRuleList: WKContentRuleList?
    private static let localOnlyRuleSource = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^(file|data|about|blob):"},"action":{"type":"ignore-previous-rules"}}]
        """

    private static func localOnlyRules() async -> WKContentRuleList? {
        if let localOnlyRuleList { return localOnlyRuleList }
        let store = WKContentRuleListStore.default()
        let identifier = "LaerOfficeLocalOnly-1"
        guard let store else { return nil }
        let list = await withCheckedContinuation { (continuation: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: localOnlyRuleSource) { list, _ in
                continuation.resume(returning: list)
            }
        }
        localOnlyRuleList = list
        return list
    }

    /// Only the local preview and the blank standby page may load in the render view.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let scheme = action.request.url?.scheme?.lowercased() else { return .cancel }
        return scheme == "file" || scheme == "about" ? .allow : .cancel
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        previewNavigation = nil
        loaded?.resume(with: result)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === previewNavigation { finishLoading(.success(())) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === previewNavigation { finishLoading(.failure(error)) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === previewNavigation { finishLoading(.failure(error)) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(.failure(OfficePDFConverterError.previewUnavailable))
    }
}

/// Lets exactly one of several callbacks finish a continuation.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// Lets a cancellation handler close an XPC connection; invalidating is safe from any thread.
private final class ConnectionCloser: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) { self.connection = connection }

    func close() { connection.invalidate() }
}
