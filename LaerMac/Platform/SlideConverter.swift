import AppKit
import Foundation
import OSLog
import PDFKit
import WebKit

enum SlideConverterError: Error {
    case previewUnavailable
    case printFailed
}

/// Turns slides into a PDF with what macOS already has: Quick Look writes an HTML preview,
/// and WebKit captures each slide. Results are kept beside the app's caches and rebuilt when missing.
@MainActor
final class SlideConverter: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Error>?

    static func cachedPDF(for id: String) -> URL? {
        let url = cacheURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func removeCached(for id: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: id))
    }

    private static func cacheURL(for id: String) -> URL {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let safe = id.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
        return caches.appending(path: "ConvertedSlides", directoryHint: .isDirectory).appending(path: "\(safe).pdf")
    }

    func convert(_ source: URL, id: String) async throws -> URL {
        if let cached = Self.cachedPDF(for: id) { return cached }
        let work = FileManager.default.temporaryDirectory.appending(path: "LaerSlides-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let log = Logger(subsystem: "app.laer.Laer", category: "convert")
        let preview = try await Self.quickLookHTML(for: source, in: work)
        log.notice("preview written")
        let destination = Self.cacheURL(for: id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = work.appending(path: "output.pdf")
        let document = try await renderSlides(preview)
        log.notice("rendered \(document.pageCount) pages")
        guard document.pageCount > 0, document.write(to: staged) else { throw SlideConverterError.printFailed }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
    }

    /// Asks the helper service to run Quick Look. Its sandbox rules forbid running it from this app.
    private nonisolated static func quickLookHTML(for source: URL, in directory: URL) async throws -> URL {
        let connection = NSXPCConnection(serviceName: "app.laer.Laer.QuickLookService")
        connection.remoteObjectInterface = NSXPCInterface(with: QuickLookPreviewing.self)
        connection.resume()
        defer { connection.invalidate() }
        let succeeded: Bool = await withCheckedContinuation { continuation in
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
        let html = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "Preview.html" }
        guard succeeded, let html else { throw SlideConverterError.previewUnavailable }
        return html
    }

    /// Captures each slide of the preview as one PDF page.
    private func renderSlides(_ html: URL) async throws -> PDFDocument {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        Logger(subsystem: "app.laer.Laer", category: "convert").notice("preview loaded")
        let script = """
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
        let result = try await view.callAsyncJavaScript(script, contentWorld: .page)
        guard let boxes = result as? [[Double]], !boxes.isEmpty else { throw SlideConverterError.printFailed }
        Logger(subsystem: "app.laer.Laer", category: "convert").notice("found \(boxes.count) slides")
        let document = PDFDocument()
        for box in boxes where box.count == 4 && box[2] > 0 && box[3] > 0 {
            let capture = WKPDFConfiguration()
            capture.rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
            let data = try await view.pdf(configuration: capture)
            if let page = PDFDocument(data: data)?.page(at: 0) {
                document.insert(page, at: document.pageCount)
            }
        }
        return document
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
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
