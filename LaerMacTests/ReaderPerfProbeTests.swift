import AppKit
import Foundation
import OSLog
import PDFKit
import QuickLookThumbnailing
import Testing
import WebKit
@testable import Laer
@testable import LaerCore

/// Live timing against the signed-in account in the Debug app's container. Reads only.
private var liveProbeRequested: Bool {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
    return FileManager.default.fileExists(atPath: caches.appending(path: "LaerLiveProbe").path)
}

/// A number written on a line `name=value` in the marker file, for narrowing a run.
private func liveProbeOption(_ name: String) -> Int? {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
          let text = try? String(contentsOf: caches.appending(path: "LaerLiveProbe"), encoding: .utf8) else { return nil }
    return text.split(separator: "\n").compactMap { line -> Int? in
        let parts = line.split(separator: "=")
        return parts.count == 2 && parts[0] == name ? Int(parts[1]) : nil
    }.first
}

/// Off unless asked for: create an empty `LaerLiveProbe` file in the Debug app's Caches folder,
/// run with `-only-testing:LaerMacTests/ReaderPerfProbeTests`, then remove the file.
@Suite(.serialized, .enabled(if: liveProbeRequested))
@MainActor
struct ReaderPerfProbeTests {
    private let log = Logger(subsystem: "app.laer.Laer", category: "perfprobe")

    private func emit(_ line: String) {
        print("[PERF_PROBE] \(line)")
        log.notice("\(line, privacy: .public)")
    }

    // MARK: - URL & Error Sanitization

    private struct Sanitizer: Sendable {
        let siteHost: String

        init(site: Site) {
            self.siteHost = site.baseURL.host()?.lowercased() ?? ""
        }

        func hostCategory(_ url: URL?) -> String {
            guard let host = url?.host()?.lowercased(), !host.isEmpty else { return "nohost" }
            if host == siteHost { return "site" }
            if host == "resource.itslearning.com" { return "resource" }
            if host.hasSuffix(".blob.core.windows.net") { return "cdn-blob" }
            if host.hasSuffix(".cloudfront.net") { return "cdn-cf" }
            if host.hasSuffix(".itslearning.com") { return "itsl-other" }
            let parts = host.split(separator: ".")
            if parts.count >= 2 {
                return "ext-\(parts.suffix(2).joined(separator: "."))"
            }
            return "ext-other"
        }

        func urlTemplate(_ url: URL?) -> String {
            guard let url else { return "nil" }
            let host = hostCategory(url)
            let segments = url.path().split(separator: "/").map { seg -> String in
                let text = String(seg)
                let isRoute = text.range(
                    of: #"^(?:[A-Za-z]{1,28}(?:\.(?:aspx|ashx|txt|html|js))?|v[0-9]+)$"#,
                    options: .regularExpression
                ) != nil
                if isRoute { return text }
                let ext = (text as NSString).pathExtension.lowercased()
                if !ext.isEmpty, ext.count <= 6, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    return "{file.\(ext)}"
                }
                return "{id}"
            }
            let keys = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map(\.name)
                .sorted()
            let path = "/" + segments.joined(separator: "/")
            return keys.isEmpty ? "\(host) \(path)" : "\(host) \(path) ?\(keys.joined(separator: ","))"
        }

        func urlTemplate(string: String, relativeTo base: URL) -> String {
            urlTemplate(URL(string: string, relativeTo: base)?.absoluteURL)
        }

        func errorTag(_ error: Error) -> String {
            if let api = error as? APIError { return "APIError.\(String(describing: api).split(separator: "(").first ?? "other")" }
            if let urlErr = error as? URLError { return "URLError(\(urlErr.code.rawValue))" }
            return "\(type(of: error))"
        }
    }

    // MARK: - Timing & Trace Delegate

    nonisolated private static func msSince(_ start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1e15
        return String(format: "%.1f", ms)
    }

    nonisolated private static func ms(_ start: Date?, _ end: Date?) -> String {
        guard let start, let end else { return "-" }
        return String(format: "%.1f", end.timeIntervalSince(start) * 1000.0)
    }

    private struct HopRecord: Sendable {
        let status: Int
        let fromTemplate: String
        let toTemplate: String
        let setCookieCount: Int
        let elapsedMs: String
    }

    private struct StreamStats: Sendable {
        var headersMs: String = "-"
        var firstByteMs: String = "-"
        var bytes64KMs: String = "-"
        var bytes256KMs: String = "-"
        var completeMs: String = "-"
        var totalBytes: Int = 0
        var statusCode: Int = 0
        var contentType: String = "-"
        var expectedLength: Int64 = -1
        var acceptRanges: String = "-"
        var hasETag: Bool = false
        var cacheControl: String = "-"
        var finalTemplate: String = "-"
        var magic: String = "none"
        var errorTag: String?
    }

    private final class TaskTraceDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let sanitizer: Sanitizer
        let startedAt: ContinuousClock.Instant
        let followMode: FollowMode
        let destinationFile: URL?

        enum FollowMode {
            case followAll(maxHops: Int)
            case stopOnRedirect
            case stepUntilFileDownloadOrBinary(maxHops: Int)
        }

        private let lock = NSLock()
        private var hops: [HopRecord] = []
        private var transactionSummaries: [String] = []
        private var bodyData = Data()
        private var fileHandle: FileHandle?
        private var streamStats = StreamStats()
        private var firstBytes = Data()
        private var capturedFileDownloadURL: URL?
        private var directBinaryURL: URL?
        private var finalURL: URL?
        private var completionError: Error?
        private var continuation: CheckedContinuation<Void, Never>?
        private var completed = false

        init(sanitizer: Sanitizer, followMode: FollowMode, destinationFile: URL? = nil) {
            self.sanitizer = sanitizer
            self.startedAt = .now
            self.followMode = followMode
            self.destinationFile = destinationFile
            super.init()
        }

        func wait() async {
            await withCheckedContinuation { cont in
                lock.lock()
                if completed {
                    lock.unlock()
                    cont.resume()
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }

        func snapshot() -> (
            hops: [HopRecord],
            metrics: [String],
            stats: StreamStats,
            body: Data,
            capturedFileDownloadURL: URL?,
            directBinaryURL: URL?,
            finalURL: URL?
        ) {
            lock.withLock {
                (hops, transactionSummaries, streamStats, bodyData, capturedFileDownloadURL, directBinaryURL, finalURL)
            }
        }

        private static func setCookieCount(in response: HTTPURLResponse) -> Int {
            guard let url = response.url,
                  let fields = response.allHeaderFields as? [String: String] else { return 0 }
            return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).count
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            let fromTpl = sanitizer.urlTemplate(task.currentRequest?.url ?? task.originalRequest?.url)
            let toTpl = sanitizer.urlTemplate(request.url)
            let cookieCount = Self.setCookieCount(in: response)
            let elapsed = ReaderPerfProbeTests.msSince(startedAt)

            return lock.withLock {
                hops.append(HopRecord(
                    status: response.statusCode,
                    fromTemplate: fromTpl,
                    toTemplate: toTpl,
                    setCookieCount: cookieCount,
                    elapsedMs: elapsed
                ))
                switch followMode {
                case .stopOnRedirect:
                    return nil
                case .followAll(let maxHops):
                    return hops.count >= maxHops ? nil : request
                case .stepUntilFileDownloadOrBinary(let maxHops):
                    if let target = request.url,
                       let direct = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems?
                           .first(where: { $0.name == "FileDownloadUrl" })?.value,
                       let fileURL = URL(string: direct, relativeTo: target)?.absoluteURL {
                        capturedFileDownloadURL = fileURL
                        return nil
                    }
                    if hops.count >= maxHops { return nil }
                    return request
                }
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse
        ) async -> URLSession.ResponseDisposition {
            let elapsed = ReaderPerfProbeTests.msSince(startedAt)
            guard let http = response as? HTTPURLResponse else { return .cancel }
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "-")
                .split(separator: ";").first.map(String.init) ?? "-"
            let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges") ?? "-"
            let hasETag = http.value(forHTTPHeaderField: "ETag") != nil
            let cacheControl = http.value(forHTTPHeaderField: "Cache-Control") ?? "-"
            let tpl = sanitizer.urlTemplate(http.url)

            var shouldCancelForBinary = false
            lock.withLock {
                streamStats.headersMs = elapsed
                streamStats.statusCode = http.statusCode
                streamStats.contentType = ct
                streamStats.expectedLength = http.expectedContentLength
                streamStats.acceptRanges = acceptRanges
                streamStats.hasETag = hasETag
                streamStats.cacheControl = cacheControl
                streamStats.finalTemplate = tpl
                finalURL = http.url

                if case .stepUntilFileDownloadOrBinary = followMode {
                    let isHTML = ct.lowercased().contains("html")
                    if (200..<300).contains(http.statusCode), !isHTML, let url = http.url {
                        directBinaryURL = url
                        shouldCancelForBinary = true
                    }
                }
                if !shouldCancelForBinary, let destinationFile {
                    FileManager.default.createFile(atPath: destinationFile.path(), contents: nil)
                    fileHandle = try? FileHandle(forWritingTo: destinationFile)
                }
            }
            return shouldCancelForBinary ? .cancel : .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let elapsed = ReaderPerfProbeTests.msSince(startedAt)
            lock.withLock {
                if streamStats.firstByteMs == "-" { streamStats.firstByteMs = elapsed }
                if firstBytes.count < 16 {
                    firstBytes.append(data.prefix(16 - firstBytes.count))
                }
                streamStats.totalBytes += data.count
                if streamStats.bytes64KMs == "-", streamStats.totalBytes >= 65_536 {
                    streamStats.bytes64KMs = elapsed
                }
                if streamStats.bytes256KMs == "-", streamStats.totalBytes >= 262_144 {
                    streamStats.bytes256KMs = elapsed
                }
                if let fileHandle {
                    try? fileHandle.write(contentsOf: data)
                } else if bodyData.count < 4 * 1024 * 1024 {
                    bodyData.append(data)
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let lines = metrics.transactionMetrics.enumerated().map { idx, tx in
                let tpl = sanitizer.urlTemplate(tx.request.url)
                let status = (tx.response as? HTTPURLResponse)?.statusCode ?? 0
                let dns = ReaderPerfProbeTests.ms(tx.domainLookupStartDate, tx.domainLookupEndDate)
                let tcp = ReaderPerfProbeTests.ms(tx.connectStartDate, tx.secureConnectionStartDate ?? tx.connectEndDate)
                let tls = ReaderPerfProbeTests.ms(tx.secureConnectionStartDate, tx.secureConnectionEndDate)
                let ttfb = ReaderPerfProbeTests.ms(tx.requestStartDate, tx.responseStartDate)
                let xfer = ReaderPerfProbeTests.ms(tx.responseStartDate, tx.responseEndDate)
                let proto = tx.networkProtocolName ?? "-"
                return "tx[\(idx)] status=\(status) proto=\(proto) reused=\(tx.isReusedConnection) dns=\(dns)ms tcp=\(tcp)ms tls=\(tls)ms ttfb=\(ttfb)ms xfer=\(xfer)ms url=\(tpl)"
            }
            lock.withLock { transactionSummaries = lines }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let elapsed = ReaderPerfProbeTests.msSince(startedAt)
            let cont: CheckedContinuation<Void, Never>? = lock.withLock {
                streamStats.completeMs = elapsed
                try? fileHandle?.close()
                fileHandle = nil
                if let error, (error as? URLError)?.code != .cancelled {
                    streamStats.errorTag = sanitizer.errorTag(error)
                }
                streamStats.magic = Self.magicCategory(firstBytes)
                completed = true
                defer { continuation = nil }
                return continuation
            }
            cont?.resume()
        }

        private static func magicCategory(_ head: Data) -> String {
            let bytes = [UInt8](head)
            if bytes.starts(with: Array("%PDF".utf8)) { return "pdf" }
            if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }
            if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return "ole" }
            if bytes.contains(UInt8(ascii: "<")) { return "html/xml" }
            return bytes.isEmpty ? "empty" : "other"
        }
    }

    private func perform(
        _ request: URLRequest,
        on session: URLSession,
        sanitizer: Sanitizer,
        followMode: TaskTraceDelegate.FollowMode,
        destinationFile: URL? = nil
    ) async -> (
        hops: [HopRecord],
        metrics: [String],
        stats: StreamStats,
        body: Data,
        capturedFileDownloadURL: URL?,
        directBinaryURL: URL?,
        finalURL: URL?
    ) {
        let trace = TaskTraceDelegate(sanitizer: sanitizer, followMode: followMode, destinationFile: destinationFile)
        let task = session.dataTask(with: request)
        task.delegate = trace
        task.resume()
        await trace.wait()
        return trace.snapshot()
    }

    // MARK: - Main Probe

    /// Office conversion of files already saved on this Mac: when the cover, the first page and the whole file appear.
    @Test func measureSavedOfficeConversion() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let files = (FileManager.default.enumerator(at: support.appending(path: "Laer"), includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { ["pptx", "docx"].contains($0.pathExtension.lowercased()) && $0.path.contains("/Downloads/") }
            .prefix(6)
        let work = FileManager.default.temporaryDirectory.appending(path: "LaerOfficeProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        OfficePDFConverter.prepareRenderer()
        try? await Task.sleep(for: .milliseconds(500))
        for (index, file) in files.enumerated() {
            let copy = work.appending(path: "\(index).\(file.pathExtension.lowercased())")
            try FileManager.default.copyItem(at: file, to: copy)
            let id = "officeprobe-\(index)-\(UUID().uuidString.prefix(6))"
            defer { OfficePDFConverter.removeCached(for: id) }
            let kb = ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1024
            let start = ContinuousClock.now
            let job = OfficePDFConverter.conversion(for: copy, id: id)
            var cover: Duration?
            var first: Duration?
            let deadline = start + .seconds(45)
            while !job.isFinished, ContinuousClock.now < deadline {
                if cover == nil, job.coverPDF != nil { cover = ContinuousClock.now - start }
                if first == nil, !job.capturedPages.isEmpty { first = ContinuousClock.now - start }
                try? await Task.sleep(for: .milliseconds(5))
            }
            let pages = (try? await job.result()).flatMap { PDFDocument(url: $0)?.pageCount } ?? 0
            emit("OFFICE [\(file.pathExtension.lowercased())#\(index)] kb=\(kb) coverMs=\(cover.map(Self.ms) ?? "-") firstPageMs=\(first.map(Self.ms) ?? "-") fullMs=\(Self.ms(ContinuousClock.now - start)) pages=\(pages)")
        }
    }

    @Test func measureOfficeCover() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let files = (FileManager.default.enumerator(at: support.appending(path: "Laer"), includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension.lowercased() == "pptx" && $0.path.contains("/Downloads/") }
            .prefix(6)
        for (index, file) in files.enumerated() {
            let kb = ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1024
            for run in 1...2 {
                let start = ContinuousClock.now
                let page = await OfficePDFConverter.coverPage(for: file)
                let size = page.flatMap { PDFDocument(data: $0)?.page(at: 0)?.bounds(for: .mediaBox).size }
                emit("COVER [pptx#\(index) r\(run)] kb=\(kb) ms=\(Self.ms(ContinuousClock.now - start)) ok=\(page != nil) size=\(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-")")
            }
        }
    }

    /// The pointer-rest path: find the link first, then time the click on its own against a cold open.
    @Test func measurePointerRestThenClick() async throws {
        let defaults = UserDefaults.standard
        guard let siteData = defaults.data(forKey: "selectedSite"),
              let site = try? JSONDecoder().decode(Site.self, from: siteData),
              var tokens = TokenVault(site: site).load() else {
            emit("BLOCKED: missing selectedSite or OAuthTokens in test host")
            return
        }
        if tokens.expiresAt < Date().addingTimeInterval(45) {
            tokens = try await OAuthTokenClient(baseURL: site.baseURL).refresh(tokens.refreshToken)
            TokenVault(site: site).save(tokens)
        }
        let client = ItslearningClient(transport: BearerTransport(baseURL: site.baseURL, box: TokenBox(tokens: tokens)))
        let sanitizer = Sanitizer(site: site)

        let all = try await client.allCourses().items
        let starredIds = Set(((try? await client.starredCourses().items) ?? []).filter { $0.isFavourite != false }.map(\.courseId))
        let active = starredIds.isEmpty ? all : all.filter { starredIds.contains($0.courseId) }
        var byExt: [String: [Resource]] = [:]
        var budget = 16
        for course in active.prefix(6) {
            var queue: [Int?] = [nil]
            while let folder = queue.first, budget > 0 {
                queue.removeFirst()
                budget -= 1
                let listing: PagedResult<Resource>? = if let folder {
                    try? await client.folderResources(courseId: course.courseId, folderId: folder)
                } else {
                    try? await client.rootResources(courseId: course.courseId)
                }
                for var item in listing?.items ?? [] {
                    item.courseId = item.courseId ?? course.courseId
                    if item.isFolder { queue.append(item.elementId); continue }
                    guard FileAcquirer.canAttempt(item) else { continue }
                    let ext = (item.title as NSString).pathExtension.lowercased()
                    if ["pdf", "pptx", "docx"].contains(ext) { byExt[ext, default: []].append(item) }
                }
            }
        }
        let pdfCount = liveProbeOption("pdf") ?? 6
        let samples = Array((byExt["pdf"] ?? []).shuffled().prefix(pdfCount)) + Array((byExt["pptx"] ?? []).shuffled().prefix(2)) + Array((byExt["docx"] ?? []).prefix(2))
        emit("REST corpus pdf=\(byExt["pdf"]?.count ?? 0) pptx=\(byExt["pptx"]?.count ?? 0) docx=\(byExt["docx"]?.count ?? 0) samples=\(samples.count)")

        let session = WebSession(site: site)
        await session.prepareFileSession(client: client)
        FileAcquirer.prepareResolver(for: session)
        guard session.hasFileSession else {
            emit("BLOCKED: no website session")
            return
        }
        try? await Task.sleep(for: .milliseconds(300))

        final class FirstPage: @unchecked Sendable { var after: Duration? }
        func click(_ resource: Resource, label: String) async {
            let ext = (resource.title as NSString).pathExtension.lowercased()
            let start = ContinuousClock.now
            let box = FirstPage()
            var onPage: FileAcquirer.PDFPageReady?
            if ext == "pdf" {
                onPage = { _ in
                    if box.after == nil { box.after = ContinuousClock.now - start }
                }
            }
            do {
                let staged = try await FileAcquirer(session: session, client: client, onPDFPage: onPage).acquire(resource)
                defer { try? FileManager.default.removeItem(at: staged.file) }
                let acquired = ContinuousClock.now - start
                var usable = acquired
                if ext == "pdf" {
                    let doc = PDFDocument(url: staged.file)
                    _ = doc?.page(at: 0)?.thumbnail(of: CGSize(width: 800, height: 600), for: .mediaBox)
                    usable = min(box.after ?? .seconds(99), ContinuousClock.now - start)
                }
                let bytes = (try? staged.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                emit("REST \(label) ext=\(ext) kb=\(bytes / 1024) acquireMs=\(Self.ms(acquired)) usableMs=\(Self.ms(usable))")
            } catch {
                emit("REST \(label) ext=\(ext) error=\(type(of: error)) ms=\(Self.ms(ContinuousClock.now - start))")
            }
        }

        for (index, resource) in samples.enumerated() {
            let ext = (resource.title as NSString).pathExtension.lowercased()
            let restStart = ContinuousClock.now
            await FileAcquirer(session: session, client: client).resolveAhead(resource)
            let link = session.resolvedLink(for: resource.id)
            emit("REST [\(ext)#\(index)] lookup found=\(link != nil) native=\(link?.cookies != nil) ms=\(Self.ms(ContinuousClock.now - restStart)) link=\(sanitizer.urlTemplate(link?.url))")
            try? await Task.sleep(for: .milliseconds(200))
            await click(resource, label: "[\(ext)#\(index)] afterRest")
            try? await Task.sleep(for: .milliseconds(200))
            await click(resource, label: "[\(ext)#\(index)] cold")
        }
    }

    nonisolated private static func ms(_ duration: Duration) -> String {
        let c = duration.components
        return String(format: "%.0f", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
    }

    @Test func measureReaderPipelineAndRoutes() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appending(path: "LaerPerfProbe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        var officeProbeIDs: [String] = []
        defer {
            OfficePDFConverter.cancelConversions()
            for id in officeProbeIDs { OfficePDFConverter.removeCached(for: id) }
            try? FileManager.default.removeItem(at: tempRoot)
        }

        // 1. Auth
        let defaults = UserDefaults.standard
        guard let siteData = defaults.data(forKey: "selectedSite"),
              let site = try? JSONDecoder().decode(Site.self, from: siteData),
              var tokens = TokenVault(site: site).load() else {
            emit("BLOCKED: missing selectedSite or OAuthTokens in test host")
            Issue.record("Missing selectedSite or OAuthTokens")
            return
        }

        let sanitizer = Sanitizer(site: site)
        if tokens.expiresAt < Date().addingTimeInterval(45) {
            let t0 = ContinuousClock.now
            tokens = try await OAuthTokenClient(baseURL: site.baseURL).refresh(tokens.refreshToken)
            TokenVault(site: site).save(tokens)
            emit("AUTH refreshed token in \(Self.msSince(t0))ms")
        } else {
            emit("AUTH token valid (remaining \(Int(tokens.expiresAt.timeIntervalSinceNow))s)")
        }

        let box = TokenBox(tokens: tokens)
        let bearer = BearerTransport(baseURL: site.baseURL, box: box)
        let client = ItslearningClient(transport: bearer)

        // 1b. Corpus discovery
        let allCourses = try await client.allCourses().items
        let starred = (try? await client.starredCourses().items) ?? []
        let starredIds = Set(starred.filter { $0.isFavourite != false }.map(\.courseId))
        let activeCourses = starredIds.isEmpty ? allCourses : allCourses.filter { starredIds.contains($0.courseId) }
        emit("CORPUS courses total=\(allCourses.count) active=\(activeCourses.count)")

        var candidatesById: [String: Resource] = [:]
        var fromFolders: Set<String> = []
        var folderBudget = 25

        for course in activeCourses.prefix(8) {
            guard folderBudget > 0 else { break }
            var queue: [Int?] = [nil]
            while let folder = queue.first, folderBudget > 0 {
                queue.removeFirst()
                folderBudget -= 1
                let listing: PagedResult<Resource>? = if let folder {
                    try? await client.folderResources(courseId: course.courseId, folderId: folder)
                } else {
                    try? await client.rootResources(courseId: course.courseId)
                }
                for var item in listing?.items ?? [] {
                    item.courseId = item.courseId ?? course.courseId
                    if item.isFolder {
                        queue.append(item.elementId)
                    } else if FileAcquirer.canAttempt(item) {
                        candidatesById[item.id] = item
                        fromFolders.insert(item.id)
                    }
                }
            }
        }

        for course in activeCourses.prefix(4) {
            if let plans = try? await client.plans(courseId: course.courseId).items {
                for plan in plans {
                    for el in plan.elements ?? [] where el.isFolder != true && el.isResource != false {
                        let res = Resource(planElement: el, courseId: course.courseId)
                        if FileAcquirer.canAttempt(res), candidatesById[res.id] == nil {
                            candidatesById[res.id] = res
                        }
                    }
                }
            }
        }

        let allCandidates = Array(candidatesById.values)
        var extCounts: [String: Int] = [:]
        var withLoIds = 0
        var withUrl = 0
        var withContentUrl = 0
        var urlTemplates: Set<String> = []
        var contentUrlTemplates: Set<String> = []

        for r in allCandidates {
            let ext = (r.title as NSString).pathExtension.lowercased()
            extCounts[ext.isEmpty ? "<none>" : ext, default: 0] += 1
            if r.learningObjectId != nil && r.learningObjectInstanceId != nil { withLoIds += 1 }
            if let u = r.url, !u.isEmpty {
                withUrl += 1
                urlTemplates.insert(sanitizer.urlTemplate(string: u, relativeTo: site.baseURL))
            }
            if let cu = r.contentUrl, !cu.isEmpty {
                withContentUrl += 1
                contentUrlTemplates.insert(sanitizer.urlTemplate(string: cu, relativeTo: site.baseURL))
            }
        }

        emit("CORPUS candidates=\(allCandidates.count) fromFolders=\(fromFolders.count) withLoIds=\(withLoIds) withUrl=\(withUrl) withContentUrl=\(withContentUrl)")
        emit("CORPUS extCounts=\(extCounts.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: ","))")
        emit("CORPUS urlTemplates=\(urlTemplates.sorted().joined(separator: " | "))")
        emit("CORPUS contentUrlTemplates=\(contentUrlTemplates.sorted().joined(separator: " | "))")

        func pickCandidates(exts: Set<String>, limit: Int) -> [Resource] {
            let matching = allCandidates.filter { exts.contains(($0.title as NSString).pathExtension.lowercased()) }
            // Prefer folder-sourced (which carry learningObjectId/InstanceId) and spread across courses
            let sorted = matching.sorted { lhs, rhs in
                let lFolder = fromFolders.contains(lhs.id) ? 0 : 1
                let rFolder = fromFolders.contains(rhs.id) ? 0 : 1
                if lFolder != rFolder { return lFolder < rFolder }
                return (lhs.courseId ?? 0) < (rhs.courseId ?? 0)
            }
            var chosen: [Resource] = []
            var seenCourses: Set<Int> = []
            for r in sorted where chosen.count < limit {
                if let cid = r.courseId, !seenCourses.contains(cid) {
                    seenCourses.insert(cid)
                    chosen.append(r)
                }
            }
            for r in sorted where chosen.count < limit {
                if !chosen.contains(where: { $0.id == r.id }) { chosen.append(r) }
            }
            return chosen
        }

        let pdfSample = pickCandidates(exts: ["pdf"], limit: 6)
        let pptxSample = pickCandidates(exts: ["pptx"], limit: 5)
        let docxSample = pickCandidates(exts: ["docx"], limit: 3)
        let legacySample = pickCandidates(exts: ["doc", "ppt"], limit: 2)
        emit("SAMPLE pdf=\(pdfSample.count) pptx=\(pptxSample.count) docx=\(docxSample.count) legacy=\(legacySample.count)")

        // 2. Alternative / Shorter REST API Route Discovery
        let routeSample: [(String, Resource)] = [
            ("pdf", pdfSample.first),
            ("pptx", pptxSample.first),
            ("docx", docxSample.first),
        ].compactMap { label, res in res.map { (label, $0) } }

        for (label, res) in routeSample {
            // 2a. courses/resources/{id}/v1
            do {
                let t0 = ContinuousClock.now
                let resp = try await bearer.send(ReadRequest(
                    path: "/restapi/personal/courses/resources/\(res.elementId)/v1",
                    routeTemplate: "courses/resources/{id}/v1"
                ))
                let elapsed = Self.msSince(t0)
                let mime = resp.contentType.split(separator: ";").first.map(String.init) ?? "-"
                let shape = ShapeReport.describe(json: resp.body)?.replacingOccurrences(of: "\n", with: " ") ?? "(not-json)"
                let urls = extractSanitizedJSONURLs(from: resp.body, base: site.baseURL, sanitizer: sanitizer)
                emit("ALT_ROUTE [\(label)] courses/resources/{id}/v1 status=\(resp.status) mime=\(mime) ms=\(elapsed) urls=[\(urls.joined(separator: "; "))] shape=\(shape)")
            } catch {
                emit("ALT_ROUTE [\(label)] courses/resources/{id}/v1 err=\(sanitizer.errorTag(error))")
            }

            // 2b. pageurl/viewLearningToolElement
            do {
                let t0 = ContinuousClock.now
                let resp = try await bearer.send(ReadRequest(
                    path: "/restapi/pageurl/viewLearningToolElement",
                    query: [URLQueryItem(name: "elementId", value: String(res.elementId))],
                    routeTemplate: "pageurl/viewLearningToolElement"
                ))
                let elapsed = Self.msSince(t0)
                let mime = resp.contentType.split(separator: ";").first.map(String.init) ?? "-"
                let urls = extractSanitizedJSONURLs(from: resp.body, base: site.baseURL, sanitizer: sanitizer)
                let strBody = String(data: resp.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let directUrl = (strBody.hasPrefix("http") || strBody.hasPrefix("\"http")) ?
                    sanitizer.urlTemplate(string: strBody.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), relativeTo: site.baseURL) : "-"
                emit("ALT_ROUTE [\(label)] pageurl/viewLearningToolElement status=\(resp.status) mime=\(mime) ms=\(elapsed) directUrl=\(directUrl) urls=[\(urls.joined(separator: "; "))]")
            } catch {
                emit("ALT_ROUTE [\(label)] pageurl/viewLearningToolElement err=\(sanitizer.errorTag(error))")
            }

            // 2c. sso/url/v1
            if let elURL = elementURL(for: res, base: site.baseURL) {
                do {
                    let t0 = ContinuousClock.now
                    let sso = try await client.ssoURL(for: elURL)
                    emit("ALT_ROUTE [\(label)] sso/url/v1 ms=\(Self.msSince(t0)) tpl=\(sanitizer.urlTemplate(sso))")
                } catch {
                    emit("ALT_ROUTE [\(label)] sso/url/v1 err=\(sanitizer.errorTag(error))")
                }
            }
        }

        // 3. Native URLSession Trace
        let nativeConfig = URLSessionConfiguration.ephemeral
        nativeConfig.httpShouldSetCookies = true
        nativeConfig.httpCookieAcceptPolicy = .always
        nativeConfig.urlCache = nil
        nativeConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        let cookieStorage = nativeConfig.httpCookieStorage
        let nativeSession = URLSession(configuration: nativeConfig)
        defer { nativeSession.invalidateAndCancel() }

        // 3a. Session bootstrap
        let robotsURL = site.baseURL.appending(path: "robots.txt")
        let ssoBootT0 = ContinuousClock.now
        let bootSSO = try await client.ssoURL(for: robotsURL)
        let ssoBootMs = Self.msSince(ssoBootT0)
        let bootRes = await perform(URLRequest(url: bootSSO), on: nativeSession, sanitizer: sanitizer, followMode: .followAll(maxHops: 10))
        let cookieCounts = Dictionary(grouping: cookieStorage?.cookies ?? []) { cookie -> String in
            let d = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return sanitizer.hostCategory(URL(string: "https://\(d)"))
        }.mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        emit("NATIVE_BOOT ssoMs=\(ssoBootMs) fetchMs=\(bootRes.stats.completeMs) hops=\(bootRes.hops.count) finalStatus=\(bootRes.stats.statusCode) finalTpl=\(bootRes.stats.finalTemplate) cookies={\(cookieCounts)}")
        for h in bootRes.hops {
            emit("NATIVE_BOOT hop \(h.status) \(h.fromTemplate) -> \(h.toTemplate) setCookies=\(h.setCookieCount) @\(h.elapsedMs)ms")
        }
        for tx in bootRes.metrics { emit("NATIVE_BOOT \(tx)") }

        // 3b. Full native chain on sampled files (Run 1 + Run 2)
        struct DownloadedSample {
            let label: String
            let resource: Resource
            let fileURL: URL
            let size: Int
            let ext: String
        }
        var downloadedSamples: [DownloadedSample] = []

        let traceTargets: [(String, Resource)] =
            pdfSample.enumerated().map { ("pdf#\($0.offset)", $0.element) }
            + pptxSample.enumerated().map { ("pptx#\($0.offset)", $0.element) }
            + docxSample.enumerated().map { ("docx#\($0.offset)", $0.element) }
            + legacySample.enumerated().map { ("legacy#\($0.offset)", $0.element) }

        var observedResourcePathPattern: String?

        for (label, res) in traceTargets {
            guard let elURL = elementURL(for: res, base: site.baseURL) else { continue }
            var savedFileForMicrobench: URL?
            var savedSize = 0
            for run in 1...2 {
                let totalStart = ContinuousClock.now
                // Hop 1: ViewLearningToolElement.aspx
                let hop1 = await perform(URLRequest(url: elURL), on: nativeSession, sanitizer: sanitizer, followMode: .stopOnRedirect)
                let hop1HTML = String(data: hop1.body, encoding: .utf8) ?? ""
                let loginSSO = extractLoginSSOURL(in: hop1HTML, base: elURL, elementId: res.elementId)
                let hasFileDlText = hop1HTML.range(of: "FileDownloadUrl", options: .caseInsensitive) != nil
                let hasDlRedirectText = hop1HTML.range(of: "DownloadRedirect", options: .caseInsensitive) != nil
                let offsetDesc = loginSSO.map { "\($0.byteOffset)/\(hop1.body.count)" } ?? "-/\(hop1.body.count)"
                let loginTpl = loginSSO.map { sanitizer.urlTemplate($0.url) } ?? "none"
                let hop1Loc = hop1.hops.first?.toTemplate ?? "-"
                emit("TRACE [\(label) run\(run)] HOP1 status=\(hop1.stats.statusCode) ms=\(hop1.stats.completeMs) bytes=\(hop1.body.count) setCookies=\(hop1.hops.first?.setCookieCount ?? 0) loc=\(hop1Loc) foundLoginSSO=\(loginSSO != nil) offset=\(offsetDesc) hasFileDl=\(hasFileDlText) hasDlRedirect=\(hasDlRedirectText) ssoTpl=\(loginTpl)")
                for tx in hop1.metrics { emit("TRACE [\(label) run\(run)] HOP1 \(tx)") }

                guard let loginURL = loginSSO?.url else {
                    emit("TRACE [\(label) run\(run)] ABORT_NO_LOGINSSO totalMs=\(Self.msSince(totalStart))")
                    continue
                }

                // Hop 2: loginsso.aspx
                let hop2 = await perform(URLRequest(url: loginURL), on: nativeSession, sanitizer: sanitizer, followMode: .stepUntilFileDownloadOrBinary(maxHops: 10))
                emit("TRACE [\(label) run\(run)] HOP2 status=\(hop2.stats.statusCode) ms=\(hop2.stats.completeMs) hops=\(hop2.hops.count) finalTpl=\(hop2.stats.finalTemplate) capFileDl=\(hop2.capturedFileDownloadURL != nil) directBin=\(hop2.directBinaryURL != nil)")
                for h in hop2.hops {
                    emit("TRACE [\(label) run\(run)] HOP2 hop \(h.status) \(h.fromTemplate) -> \(h.toTemplate) setCookies=\(h.setCookieCount) @\(h.elapsedMs)ms")
                }
                for tx in hop2.metrics { emit("TRACE [\(label) run\(run)] HOP2 \(tx)") }

                var downloadURL = hop2.capturedFileDownloadURL ?? hop2.directBinaryURL
                if downloadURL == nil, (200..<300).contains(hop2.stats.statusCode), !hop2.body.isEmpty {
                    let hop2HTML = String(data: hop2.body, encoding: .utf8) ?? ""
                    let hop2Base = hop2.finalURL ?? loginURL
                    let scan = scanHop2HTML(hop2HTML, base: hop2Base, sanitizer: sanitizer)
                    emit("TRACE [\(label) run\(run)] HOP2_HTML bytes=\(hop2.body.count) matches=[\(scan.findings.joined(separator: "; "))]")
                    downloadURL = scan.resolvedDownloadURL
                    if downloadURL == nil, let iframeURL = scan.firstIframeURL {
                        var iframeReq = URLRequest(url: iframeURL)
                        iframeReq.setValue(hop2Base.absoluteString, forHTTPHeaderField: "Referer")
                        let hop2b = await perform(iframeReq, on: nativeSession, sanitizer: sanitizer, followMode: .stepUntilFileDownloadOrBinary(maxHops: 10))
                        emit("TRACE [\(label) run\(run)] HOP2B status=\(hop2b.stats.statusCode) ms=\(hop2b.stats.completeMs) hops=\(hop2b.hops.count) finalTpl=\(hop2b.stats.finalTemplate) capFileDl=\(hop2b.capturedFileDownloadURL != nil) directBin=\(hop2b.directBinaryURL != nil)")
                        for h in hop2b.hops {
                            emit("TRACE [\(label) run\(run)] HOP2B hop \(h.status) \(h.fromTemplate) -> \(h.toTemplate) setCookies=\(h.setCookieCount) @\(h.elapsedMs)ms")
                        }
                        for tx in hop2b.metrics { emit("TRACE [\(label) run\(run)] HOP2B \(tx)") }
                        downloadURL = hop2b.capturedFileDownloadURL ?? hop2b.directBinaryURL
                        if downloadURL == nil, (200..<300).contains(hop2b.stats.statusCode), !hop2b.body.isEmpty {
                            let hop2bHTML = String(data: hop2b.body, encoding: .utf8) ?? ""
                            let scanB = scanHop2HTML(hop2bHTML, base: hop2b.finalURL ?? iframeURL, sanitizer: sanitizer)
                            emit("TRACE [\(label) run\(run)] HOP2B_HTML bytes=\(hop2b.body.count) matches=[\(scanB.findings.joined(separator: "; "))]")
                            downloadURL = scanB.resolvedDownloadURL
                        }
                    }
                }

                guard let dlURL = downloadURL else {
                    emit("TRACE [\(label) run\(run)] ABORT_NO_DL_URL totalMs=\(Self.msSince(totalStart))")
                    continue
                }

                if observedResourcePathPattern == nil,
                   dlURL.host()?.lowercased() == "resource.itslearning.com" {
                    observedResourcePathPattern = dlURL.path()
                }

                // Hop 3: Download file
                let dlDest = tempRoot.appending(path: "\(label.replacingOccurrences(of: "#", with: "_"))_r\(run).\( (res.title as NSString).pathExtension.lowercased() )")
                var dlReq = URLRequest(url: dlURL)
                dlReq.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let hop3 = await perform(dlReq, on: nativeSession, sanitizer: sanitizer, followMode: .followAll(maxHops: 10), destinationFile: dlDest)
                emit("TRACE [\(label) run\(run)] HOP3 status=\(hop3.stats.statusCode) ct=\(hop3.stats.contentType) expLen=\(hop3.stats.expectedLength) gotBytes=\(hop3.stats.totalBytes) magic=\(hop3.stats.magic) acceptRanges=\(hop3.stats.acceptRanges) etag=\(hop3.stats.hasETag) cache=\(hop3.stats.cacheControl) hdrMs=\(hop3.stats.headersMs) 1stBMs=\(hop3.stats.firstByteMs) 64KMs=\(hop3.stats.bytes64KMs) 256KMs=\(hop3.stats.bytes256KMs) doneMs=\(hop3.stats.completeMs) totalMs=\(Self.msSince(totalStart)) tpl=\(hop3.stats.finalTemplate)")
                for h in hop3.hops {
                    emit("TRACE [\(label) run\(run)] HOP3 hop \(h.status) \(h.fromTemplate) -> \(h.toTemplate) setCookies=\(h.setCookieCount) @\(h.elapsedMs)ms")
                }
                for tx in hop3.metrics { emit("TRACE [\(label) run\(run)] HOP3 \(tx)") }

                if run == 1, hop3.stats.totalBytes > 0 {
                    if label.hasPrefix("pdf#"), hop3.stats.magic == "pdf" {
                        let diag = diagnosePDF(at: dlDest)
                        emit("PDF_DIAG [\(label)] \(diag)")
                    }
                    savedFileForMicrobench = dlDest
                    savedSize = hop3.stats.totalBytes
                } else {
                    try? FileManager.default.removeItem(at: dlDest)
                }
            }
            if let file = savedFileForMicrobench {
                let ext = (res.title as NSString).pathExtension.lowercased()
                downloadedSamples.append(DownloadedSample(label: label, resource: res, fileURL: file, size: savedSize, ext: ext))
            }
        }

        // 3c. Direct resource.itslearning.com cookie shortcut test
        let tracedIDs = Set(traceTargets.map(\.1.id))
        if let untouched = allCandidates.first(where: {
            !tracedIDs.contains($0.id) && $0.learningObjectId != nil && $0.learningObjectInstanceId != nil
        }), let oid = untouched.learningObjectId, let iid = untouched.learningObjectInstanceId {
            var comps = URLComponents(string: "https://resource.itslearning.com/Proxy/DownloadRedirect.ashx")!
            comps.queryItems = [
                URLQueryItem(name: "LearningObjectId", value: String(oid)),
                URLQueryItem(name: "LearningObjectInstanceId", value: String(iid)),
            ]
            let scRes = await perform(URLRequest(url: comps.url!), on: nativeSession, sanitizer: sanitizer, followMode: .stopOnRedirect)
            let loc = scRes.hops.first?.toTemplate ?? "-"
            emit("SHORTCUT untouched DownloadRedirect.ashx status=\(scRes.stats.statusCode) ms=\(scRes.stats.completeMs) hops=\(scRes.hops.count) loc=\(loc) ct=\(scRes.stats.contentType)")
            for tx in scRes.metrics { emit("SHORTCUT \(tx)") }

            var refReq = URLRequest(url: comps.url!)
            refReq.setValue("https://resource.itslearning.com/File/View.aspx", forHTTPHeaderField: "Referer")
            let scRef = await perform(refReq, on: nativeSession, sanitizer: sanitizer, followMode: .stopOnRedirect)
            emit("SHORTCUT untouched+Referer DownloadRedirect.ashx status=\(scRef.stats.statusCode) ms=\(scRef.stats.completeMs) loc=\(scRef.hops.first?.toTemplate ?? "-")")

            if let viewedPPTX = pptxSample.first, let voidOid = viewedPPTX.learningObjectId, let voidIid = viewedPPTX.learningObjectInstanceId {
                var compsViewed = URLComponents(string: "https://resource.itslearning.com/Proxy/DownloadRedirect.ashx")!
                compsViewed.queryItems = [
                    URLQueryItem(name: "LearningObjectId", value: String(voidOid)),
                    URLQueryItem(name: "LearningObjectInstanceId", value: String(voidIid)),
                ]
                let scViewed = await perform(URLRequest(url: compsViewed.url!), on: nativeSession, sanitizer: sanitizer, followMode: .stopOnRedirect)
                emit("SHORTCUT viewedPPTX DownloadRedirect.ashx status=\(scViewed.stats.statusCode) ms=\(scViewed.stats.completeMs) loc=\(scViewed.hops.first?.toTemplate ?? "-")")
            }

            if let pat = observedResourcePathPattern, pat != "/Proxy/DownloadRedirect.ashx" {
                var comps2 = URLComponents(string: "https://resource.itslearning.com")!
                comps2.path = pat
                comps2.queryItems = [
                    URLQueryItem(name: "LearningObjectId", value: String(oid)),
                    URLQueryItem(name: "LearningObjectInstanceId", value: String(iid)),
                ]
                let scRes2 = await perform(URLRequest(url: comps2.url!), on: nativeSession, sanitizer: sanitizer, followMode: .stopOnRedirect)
                emit("SHORTCUT observedPattern(\(pat)) status=\(scRes2.stats.statusCode) ms=\(scRes2.stats.completeMs) loc=\(scRes2.hops.first?.toTemplate ?? "-")")
            }

            if let checkEl = elementURL(for: untouched, base: site.baseURL) {
                let recheck = await perform(URLRequest(url: checkEl), on: nativeSession, sanitizer: sanitizer, followMode: .stopOnRedirect)
                emit("SHORTCUT recheck_ViewLearningToolElement status=\(recheck.stats.statusCode) ms=\(recheck.stats.completeMs)")
            }
        } else {
            emit("SHORTCUT skipped (no untouched resource with learningObjectId/InstanceId)")
        }

        // 4. Baseline Current Production Pipeline
        let webSession = WebSession(site: site)
        await webSession.prepareFileSession(client: client)
        FileAcquirer.prepareResolver(for: webSession)
        OfficePDFConverter.prepareRenderer()
        try? await Task.sleep(for: .milliseconds(300))

        // Pick up to 3 PDFs (mix of sizes if possible), up to 3 PPTXs (largest first), up to 2 DOCXs
        let pdfSubs = downloadedSamples.filter { $0.ext == "pdf" }
        var basePDFs: [DownloadedSample] = []
        if let small = pdfSubs.min(by: { $0.size < $1.size }) { basePDFs.append(small) }
        if let large = pdfSubs.max(by: { $0.size < $1.size }), !basePDFs.contains(where: { $0.label == large.label }) { basePDFs.append(large) }
        for p in pdfSubs where basePDFs.count < 3 && !basePDFs.contains(where: { $0.label == p.label }) { basePDFs.append(p) }

        var basePPTXs = Array(downloadedSamples.filter { $0.ext == "pptx" }.sorted { $0.size > $1.size }.prefix(3))
        if basePPTXs.isEmpty {
            basePPTXs = pptxSample.prefix(3).enumerated().map {
                DownloadedSample(label: "pptx#\($0.offset)", resource: $0.element, fileURL: tempRoot, size: -1, ext: "pptx")
            }
        }
        var baseDOCXs = Array(downloadedSamples.filter { $0.ext == "docx" }.prefix(2))
        if baseDOCXs.isEmpty {
            baseDOCXs = docxSample.prefix(2).enumerated().map {
                DownloadedSample(label: "docx#\($0.offset)", resource: $0.element, fileURL: tempRoot, size: -1, ext: "docx")
            }
        }
        if basePDFs.isEmpty {
            basePDFs = pdfSample.prefix(3).enumerated().map {
                DownloadedSample(label: "pdf#\($0.offset)", resource: $0.element, fileURL: tempRoot, size: -1, ext: "pdf")
            }
        }
        let baselineTargets = basePDFs + basePPTXs + baseDOCXs

        for target in baselineTargets {
            for run in 1...2 {
                OfficePDFConverter.prepareRenderer()
                try? await Task.sleep(for: .milliseconds(50))
                let probeId = "perfprobe-\(target.label)-\(run)-\(UUID().uuidString.prefix(6))"
                officeProbeIDs.append(probeId)
                defer { OfficePDFConverter.removeCached(for: probeId) }

                final class CallbackTime: @unchecked Sendable {
                    var ms: String?
                }
                struct PDFDocBox: @unchecked Sendable {
                    let doc: PDFDocument?
                }
                let t0 = ContinuousClock.now
                let firstPageCallback = CallbackTime()
                let onPDFPage: FileAcquirer.PDFPageReady?
                if target.ext == "pdf" {
                    onPDFPage = { data in
                        MainActor.assumeIsolated {
                            if firstPageCallback.ms == nil {
                                firstPageCallback.ms = Self.msSince(t0)
                                let doc = PDFDocument(data: data)
                                let p0 = doc?.page(at: 0)
                                _ = p0?.thumbnail(of: CGSize(width: 800, height: 600), for: .mediaBox)
                            }
                        }
                    }
                } else {
                    onPDFPage = nil
                }

                do {
                    let staged = try await FileAcquirer(session: webSession, client: client, onPDFPage: onPDFPage).acquire(target.resource)
                    defer { try? FileManager.default.removeItem(at: staged.file) }
                    let acquireMs = Self.msSince(t0)

                    if target.ext == "pdf" {
                        let docLoadStart = ContinuousClock.now
                        let stagedURL = staged.file
                        let doc = await Task.detached(priority: .userInitiated) {
                            PDFDocBox(doc: PDFDocument(url: stagedURL))
                        }.value.doc
                        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
                        pdfView.autoScales = true
                        pdfView.document = doc
                        _ = doc?.page(at: 0)?.thumbnail(of: CGSize(width: 800, height: 600), for: .mediaBox)
                        let totalMs = Self.msSince(t0)
                        let renderMs = Self.msSince(docLoadStart)
                        emit("BASELINE [\(target.label) run\(run)] ext=pdf bytes=\(target.size) onPDFPageMs=\(firstPageCallback.ms ?? "-") acquireMs=\(acquireMs) docRenderMs=\(renderMs) totalUsableMs=\(totalMs) pages=\(doc?.pageCount ?? 0)")
                    } else {
                        let convStart = ContinuousClock.now
                        // The converter picks its route from the extension, and staged files have none.
                        let named = tempRoot.appending(path: "\(probeId).\(target.ext)")
                        try? FileManager.default.removeItem(at: named)
                        try FileManager.default.copyItem(at: staged.file, to: named)
                        let job = OfficePDFConverter.conversion(for: named, id: probeId)
                        var coverMs: String?
                        var firstCapturedMs: String?
                        let deadline = ContinuousClock.now + .seconds(45)
                        while !job.isFinished, ContinuousClock.now < deadline {
                            if coverMs == nil, job.coverPDF != nil {
                                coverMs = Self.msSince(t0)
                            }
                            if firstCapturedMs == nil, !job.capturedPages.isEmpty {
                                firstCapturedMs = Self.msSince(t0)
                            }
                            if job.isFinished { break }
                            try? await Task.sleep(for: .milliseconds(2))
                        }
                        let finalURL = try await job.result()
                        if firstCapturedMs == nil, !job.capturedPages.isEmpty { firstCapturedMs = Self.msSince(t0) }
                        let doc = PDFDocument(url: finalURL)
                        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
                        pdfView.autoScales = true
                        pdfView.document = doc
                        _ = doc?.page(at: 0)?.thumbnail(of: CGSize(width: 800, height: 600), for: .mediaBox)
                        let fullMs = Self.msSince(t0)
                        let convOnlyMs = Self.msSince(convStart)
                        emit("BASELINE [\(target.label) run\(run)] ext=\(target.ext) bytes=\(target.size) acquireMs=\(acquireMs) coverMs=\(coverMs ?? "-") firstPageMs=\(firstCapturedMs ?? "-") fullMs=\(fullMs) convOnlyMs=\(convOnlyMs) pages=\(doc?.pageCount ?? 0)")
                    }
                } catch {
                    emit("BASELINE [\(target.label) run\(run)] ERROR=\(sanitizer.errorTag(error)) ms=\(Self.msSince(t0))")
                }
            }
        }

        // 5. Office Conversion & QuickLook Micro-Benchmark
        for sample in downloadedSamples where sample.ext == "pptx" || sample.ext == "docx" {
            let file = sample.fileURL
            // 5a. QuickLook XPC micro-benchmark
            if sample.ext == "pptx" {
                for firstOnly in [false] {
                    for run in 1...2 {
                        let outDir = tempRoot.appending(path: "ql-\(sample.label)-first\(firstOnly)-r\(run)", directoryHint: .isDirectory)
                        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                        let qlStart = ContinuousClock.now
                        let ok = await runQuickLookXPC(source: file, output: outDir)
                        let qlMs = Self.msSince(qlStart)
                        let info = inspectQuickLookOutput(in: outDir)
                        emit("MICRO_QL [\(sample.label) firstOnly=\(firstOnly) r\(run)] ok=\(ok) ms=\(qlMs) htmlBytes=\(info.htmlBytes) files=\(info.fileCount) imgs=\(info.imageCount)")
                        if firstOnly == false, run == 2, let htmlURL = info.htmlURL {
                            await benchmarkWKWebViewRender(label: sample.label, html: htmlURL, isWord: false)
                        }
                    }
                }
            } else {
                for run in 1...2 {
                    let outDir = tempRoot.appending(path: "ql-\(sample.label)-r\(run)", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                    let qlStart = ContinuousClock.now
                    let ok = await runQuickLookXPC(source: file, output: outDir)
                    let qlMs = Self.msSince(qlStart)
                    let info = inspectQuickLookOutput(in: outDir)
                    emit("MICRO_QL [\(sample.label) r\(run)] ok=\(ok) ms=\(qlMs) htmlBytes=\(info.htmlBytes) files=\(info.fileCount) imgs=\(info.imageCount)")
                    if run == 2, let htmlURL = info.htmlURL {
                        await benchmarkWKWebViewRender(label: sample.label, html: htmlURL, isWord: true)
                    }
                }
            }

            // 5b. QLThumbnailGenerator
            for repTypeLabel in ["thumbnail", "all"] {
                let types: QLThumbnailGenerator.Request.RepresentationTypes = repTypeLabel == "thumbnail" ? .thumbnail : .all
                let thumbStart = ContinuousClock.now
                let req = QLThumbnailGenerator.Request(
                    fileAt: file,
                    size: CGSize(width: 1600, height: 1200),
                    scale: 2.0,
                    representationTypes: types
                )
                do {
                    let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: req)
                    let ms = Self.msSince(thumbStart)
                    emit("MICRO_QLTHUMB [\(sample.label) type=\(repTypeLabel)] ms=\(ms) px=\(Int(rep.cgImage.width))x\(Int(rep.cgImage.height))")
                } catch {
                    emit("MICRO_QLTHUMB [\(sample.label) type=\(repTypeLabel)] err=\(sanitizer.errorTag(error)) ms=\(Self.msSince(thumbStart))")
                }
            }
        }

        // 5c. PDFView local load + page 0 draw on real PDFs
        for sample in downloadedSamples where sample.ext == "pdf" {
            let t0 = ContinuousClock.now
            let doc = PDFDocument(url: sample.fileURL)
            let docMs = Self.msSince(t0)
            let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            pdfView.autoScales = true
            pdfView.document = doc
            let installMs = Self.msSince(t0)
            let thumb = doc?.page(at: 0)?.thumbnail(of: CGSize(width: 800, height: 600), for: .mediaBox)
            let drawMs = Self.msSince(t0)
            emit("MICRO_PDF [\(sample.label)] bytes=\(sample.size) pages=\(doc?.pageCount ?? 0) docMs=\(docMs) installMs=\(installMs) drawP0Ms=\(drawMs) thumbOk=\(thumb != nil)")
        }
    }

    // MARK: - Helpers

    private func elementURL(for resource: Resource, base: URL) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/LearningToolElement/ViewLearningToolElement.aspx"
        components?.queryItems = [URLQueryItem(name: "LearningToolElementId", value: String(resource.elementId))]
        return components?.url
    }

    private func extractSanitizedJSONURLs(from data: Data, base: URL, sanitizer: Sanitizer) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        var results: [String] = []
        func walk(_ val: Any, path: String) {
            if let str = val as? String {
                if str.hasPrefix("http://") || str.hasPrefix("https://") || str.hasPrefix("/") {
                    results.append("\(path)=\(sanitizer.urlTemplate(string: str, relativeTo: base))")
                }
            } else if let dict = val as? [String: Any] {
                for key in dict.keys.sorted() {
                    walk(dict[key]!, path: path.isEmpty ? key : "\(path).\(key)")
                }
            } else if let arr = val as? [Any] {
                for (idx, item) in arr.prefix(3).enumerated() {
                    walk(item, path: "\(path)[\(idx)]")
                }
            }
        }
        walk(obj, path: "")
        return results
    }

    private func extractLoginSSOURL(in html: String, base: URL, elementId: Int) -> (url: URL, byteOffset: Int)? {
        let pattern = #"(?i)<(?:i?frame)\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = html as NSString
        let targetId = String(elementId)
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: raw, relativeTo: base)?.absoluteURL else { continue }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if url.path().lowercased().hasSuffix("/loginsso.aspx"),
               let sig = comps?.queryItems?.first(where: { $0.name == "Signature" })?.value, !sig.isEmpty,
               comps?.queryItems?.first(where: { $0.name == "ElementId" })?.value == targetId {
                return (url, match.range.location)
            }
        }
        return nil
    }

    private func scanHop2HTML(_ html: String, base: URL, sanitizer: Sanitizer) -> (findings: [String], resolvedDownloadURL: URL?, firstIframeURL: URL?) {
        var findings: Set<String> = []
        var resolved: URL?
        var firstIframe: URL?
        let ns = html as NSString

        let attrPatterns: [(String, String)] = [
            ("iframe", #"(?i)<iframe\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#),
            ("form", #"(?i)<form\b[^>]*\baction\s*=\s*["']([^"']+)["']"#),
            ("a", #"(?i)<a\b[^>]*\bhref\s*=\s*["']([^"']+)["']"#),
            ("url-match", #"(?i)(?:https?:\/\/|\/)[^\s"'<>]*(?:FileDownloadUrl|download|PdfViewer|wopi|officeapps|\.pdf)[^\s"'<>]*"#),
        ]
        for (kind, pat) in attrPatterns {
            guard let regex = try? NSRegularExpression(pattern: pat) else { continue }
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let capIndex = match.numberOfRanges > 1 ? 1 : 0
                let raw = ns.substring(with: match.range(at: capIndex)).replacingOccurrences(of: "&amp;", with: "&")
                guard let url = URL(string: raw, relativeTo: base)?.absoluteURL else { continue }
                let lower = raw.lowercased()
                if kind == "iframe", firstIframe == nil {
                    firstIframe = url
                }
                let interesting = kind == "iframe" || kind == "form"
                    || lower.contains("filedownloadurl") || lower.contains("download")
                    || lower.contains("pdfviewer") || lower.contains("wopi") || lower.contains("officeapps")
                if interesting {
                    findings.insert("\(kind):\(sanitizer.urlTemplate(url))")
                }
                if resolved == nil {
                    if let direct = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "FileDownloadUrl" })?.value,
                       let directURL = URL(string: direct, relativeTo: url)?.absoluteURL {
                        resolved = directURL
                    } else if kind == "a", lower.contains("download"), !lower.contains("pdfviewer") {
                        resolved = url
                    } else if kind == "form", lower.contains("download") {
                        resolved = url
                    }
                }
            }
        }
        return (findings.sorted(), resolved, firstIframe)
    }

    private func diagnosePDF(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "unreadable" }
        let len = data.count
        let headerVer = String(decoding: data.prefix(10), as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? "?"
        let front = String(decoding: data.prefix(4096).map { $0 < 128 ? $0 : 32 }, as: UTF8.self)
        let isLinearized = front.contains("/Linearized")
        var eVal = "-"
        if let range = front.range(of: #"/E\s+(\d+)"#, options: .regularExpression) {
            eVal = String(front[range]).replacingOccurrences(of: "/E", with: "").trimmingCharacters(in: .whitespaces)
        }
        let doc = PDFDocument(url: url)
        let pageCount = doc?.pageCount ?? 0
        let p0Ok = doc?.page(at: 0) != nil

        // Check tail startxref
        let tailLen = min(len, 4096)
        let tail = String(decoding: data.suffix(tailLen).map { $0 < 128 ? $0 : 32 }, as: UTF8.self)
        var startXrefFromEOF = "-"
        if let m = tail.range(of: #"startxref\s+(\d+)"#, options: [.regularExpression, .backwards]),
           let numRange = tail[m].range(of: #"\d+"#, options: .regularExpression),
           let off = Int(tail[numRange]) {
            startXrefFromEOF = "\(len - off)"
        }
        let first64K = String(decoding: data.prefix(65_536).map { $0 < 128 ? $0 : 32 }, as: UTF8.self)
        let xrefKind = first64K.contains("\nxref") || first64K.contains("\rxref") || tail.contains("xref\n") || tail.contains("xref\r")
            ? (tail.contains("/Type/XRef") || tail.contains("/Type /XRef") ? "mixed/stream" : "ascii-xref")
            : (first64K.contains("/XRef") || tail.contains("/XRef") ? "xref-stream" : "unknown")

        var previewOutcome = "ok"
        if len < 2_000_000 {
            previewOutcome = "skipped(size<2MB)"
            if let hdr = LinearizedPDFPreview.header(in: data, length: len) {
                let pg = LinearizedPDFPreview.page(from: data, header: hdr)
                previewOutcome += "|wouldPreview=\(pg != nil ? "ok" : explainPageFailure(data: data, header: hdr))"
            } else {
                previewOutcome += "|hdrFail=\(explainHeaderFailure(data: data, length: len))"
            }
        } else if let hdr = LinearizedPDFPreview.header(in: data, length: len) {
            if LinearizedPDFPreview.page(from: data, header: hdr) == nil {
                previewOutcome = "pageFail(\(explainPageFailure(data: data, header: hdr)))"
            }
        } else {
            previewOutcome = "hdrFail(\(explainHeaderFailure(data: data, length: len)))"
        }

        return "ver=\(headerVer) bytes=\(len) lin=\(isLinearized) E=\(eVal) xref=\(xrefKind) startxrefFromEOF=\(startXrefFromEOF) pages=\(pageCount) p0=\(p0Ok) preview=\(previewOutcome)"
    }

    private func explainHeaderFailure(data: Data, length: Int) -> String {
        guard data.starts(with: Data("%PDF-".utf8)) else { return "not-pdf" }
        let front = String(decoding: data.prefix(4096).map { $0 < 128 ? $0 : 32 }, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"(?s)\b(\d+)\s+(\d+)\s+obj\b\s*<<([^>]*)>>\s*endobj"#),
              let match = regex.firstMatch(in: front, range: NSRange(location: 0, length: (front as NSString).length)) else {
            return "no-obj-in-4k"
        }
        let dict = (front as NSString).substring(with: match.range(at: 3))
        if !dict.contains("/Linearized") { return "no-linearized" }
        func num(_ name: String) -> Int? {
            guard let r = try? NSRegularExpression(pattern: "/" + name + #"\s+(\d+)\b"#),
                  let m = r.firstMatch(in: dict, range: NSRange(location: 0, length: (dict as NSString).length)) else { return nil }
            return Int((dict as NSString).substring(with: m.range(at: 1)))
        }
        if num("L") != length { return "L-mismatch(\(num("L") ?? -1)vs\(length))" }
        guard let e = num("E") else { return "no-E" }
        if !(1024...1_500_000).contains(e) || e >= length { return "E-range(\(e))" }
        guard let o = num("O"), (1...100_000).contains(o) else { return "bad-O" }
        if (num("P") ?? 0) != 0 { return "P-nonzero" }
        return "other-hdr"
    }

    private func explainPageFailure(data: Data, header: LinearizedPDFPreview.Header) -> String {
        let prefix = data.prefix(header.byteCount)
        let indexText = String(decoding: prefix.prefix(65_536).map { $0 < 128 ? $0 : 32 }, as: UTF8.self)
        if !indexText.contains("xref") { return "no-ascii-xref-in-64k" }
        if !indexText.contains("trailer") { return "no-trailer-in-64k" }
        if indexText.contains("/Encrypt") { return "encrypt" }
        if prefix.contains(Data("/Annots".utf8)) { return "annots-possible" }
        if prefix.contains(Data("/OCProperties".utf8)) { return "ocProperties-possible" }
        if prefix.contains(Data("/OutputIntents".utf8)) { return "outputIntents-possible" }
        if prefix.contains(Data("/AcroForm".utf8)) { return "acroForm-possible" }
        return "xref-or-page-dict-check"
    }

    private func runQuickLookXPC(source: URL, output: URL) async -> Bool {
        let connection = NSXPCConnection(serviceName: "app.laer.Laer.QuickLookService")
        connection.remoteObjectInterface = NSXPCInterface(with: QuickLookPreviewing.self)
        connection.resume()
        defer { connection.invalidate() }
        return await withCheckedContinuation { cont in
            let lock = NSLock()
            var claimed = false
            func finish(_ ok: Bool) {
                let first = lock.withLock {
                    defer { claimed = true }
                    return !claimed
                }
                if first { cont.resume(returning: ok) }
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(false) }) as? QuickLookPreviewing else {
                finish(false)
                return
            }
            proxy.writePreview(sourcePath: source.path, outputPath: output.path) { ok in
                finish(ok)
            }
        }
    }

    private func inspectQuickLookOutput(in dir: URL) -> (htmlURL: URL?, htmlBytes: Int, fileCount: Int, imageCount: Int) {
        let items = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])?.allObjects as? [URL]) ?? []
        var htmlURL: URL?
        var htmlBytes = 0
        var fileCount = 0
        var imageCount = 0
        let imgExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "tif", "tiff"]
        for u in items {
            let vals = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard vals?.isRegularFile == true else { continue }
            fileCount += 1
            if u.lastPathComponent == "Preview.html" {
                htmlURL = u
                htmlBytes = vals?.fileSize ?? 0
            } else if imgExts.contains(u.pathExtension.lowercased()) {
                imageCount += 1
            }
        }
        return (htmlURL, htmlBytes, fileCount, imageCount)
    }

    private final class NavWaiter: NSObject, WKNavigationDelegate {
        var onFinish: ((Error?) -> Void)?
        var nav: WKNavigation?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if navigation === nav { onFinish?(nil); onFinish = nil }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if navigation === nav { onFinish?(error); onFinish = nil }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if navigation === nav { onFinish?(error); onFinish = nil }
        }
    }

    private func benchmarkWKWebViewRender(label: String, html: URL, isWord: Bool) async {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
        let navDelegate = NavWaiter()
        view.navigationDelegate = navDelegate

        let t0 = ContinuousClock.now
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navDelegate.onFinish = { _ in cont.resume() }
            navDelegate.nav = view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
            if navDelegate.nav == nil { cont.resume() }
        }
        let loadMs = Self.msSince(t0)

        let jsStart = ContinuousClock.now
        let script = isWord ? Self.wordBoxesJS : Self.slideBoxesJS
        let rawBoxes = (try? await view.callAsyncJavaScript(script, contentWorld: .defaultClient)) as? [[Double]] ?? []
        let jsMs = Self.msSince(jsStart)

        var p1Ms = "-"
        var restMs = "-"
        if let first = rawBoxes.first, first.count == 4 {
            let p1Start = ContinuousClock.now
            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(x: first[0], y: first[1], width: first[2], height: first[3])
            _ = try? await view.pdf(configuration: cfg)
            p1Ms = Self.msSince(p1Start)
        }
        if rawBoxes.count > 1 {
            let restStart = ContinuousClock.now
            for box in rawBoxes.dropFirst() where box.count == 4 {
                let cfg = WKPDFConfiguration()
                cfg.rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
                _ = try? await view.pdf(configuration: cfg)
            }
            restMs = Self.msSince(restStart)
        }
        emit("MICRO_WK [\(label) isWord=\(isWord)] pages=\(rawBoxes.count) loadMs=\(loadMs) jsMs=\(jsMs) pdfP1Ms=\(p1Ms) pdfRestMs=\(restMs) totalMs=\(Self.msSince(t0))")
    }

    private static let slideBoxesJS = """
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

    private static let wordBoxesJS = """
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
        if (width > (count - 1) * stride + 505 || layout.scrollHeight > 685) { return []; }
        return Array.from({length: count}, (_, page) => [page * stride, 0, stride, height]);
        """
}
