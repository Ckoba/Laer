import Foundation
import LaerCore

/// Writes the original file as it arrives and extracts a provisional page from supported PDFs.
/// Memory stays bounded: the network task pauses while too many bytes wait to be written, and a
/// transfer that still outruns the buffer fails rather than silently losing bytes.
final class PDFPreviewTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Bytes waiting for the file write before the network task pauses, and when it resumes.
    private static let pauseAbove = 8 * 1024 * 1024
    private static let resumeBelow = 2 * 1024 * 1024
    /// Far more chunks than can arrive between a pause request and the task actually pausing.
    static let bufferedEvents = 4096

    private enum Event: Sendable {
        case response(HTTPURLResponse?)
        case bytes(Data)
    }

    private enum Preview {
        case header
        case page(LinearizedPDFPreview.Header)
        case complete
    }

    private let output: AsyncThrowingStream<Event, Error>.Continuation
    private let redirect: @Sendable (URLRequest) -> URLRequest?
    private let lock = NSLock()
    private var pendingBytes = 0
    private var paused = false

    private init(output: AsyncThrowingStream<Event, Error>.Continuation, redirect: @escaping @Sendable (URLRequest) -> URLRequest?) {
        self.output = output
        self.redirect = redirect
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        redirect(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let accepted = (response as? HTTPURLResponse).flatMap { (200..<300).contains($0.statusCode) ? $0 : nil }
        output.yield(.response(accepted))
        return accepted == nil ? .cancel : .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let shouldPause: Bool = lock.withLock {
            pendingBytes += data.count
            guard !paused, pendingBytes > Self.pauseAbove else { return false }
            paused = true
            return true
        }
        if shouldPause { dataTask.suspend() }
        if case .dropped = output.yield(.bytes(data)) {
            dataTask.cancel()
            output.finish(throwing: URLError(.dataLengthExceedsMaximum))
        }
    }

    /// The reader wrote a chunk to disk; resumes the network task once the backlog is small again.
    private func consumed(_ count: Int, task: URLSessionDataTask) {
        let shouldResume: Bool = lock.withLock {
            pendingBytes -= count
            guard paused, pendingBytes < Self.resumeBelow else { return false }
            paused = false
            return true
        }
        if shouldResume { task.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        output.finish(throwing: error)
    }

    static func fetch(_ request: URLRequest, using session: URLSession,
                      redirect: @escaping @Sendable (URLRequest) -> URLRequest?,
                      onPage: @MainActor @Sendable (Data) -> Void) async throws -> FileAcquirer.Staged? {
        try Task.checkCancellation()
        let (events, output) = AsyncThrowingStream<Event, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(bufferedEvents))
        let receiver = PDFPreviewTransfer(output: output, redirect: redirect)
        // The linearization offsets describe the original bytes, and HTTP supplies the encoded length.
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        task.delegate = receiver
        defer { task.cancel() }

        let staged = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        guard FileManager.default.createFile(atPath: staged.path(), contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        var keepFile = false
        defer { if !keepFile { try? FileManager.default.removeItem(at: staged) } }
        let file = try FileHandle(forWritingTo: staged)
        defer { try? file.close() }

        var response: HTTPURLResponse?
        var preview: Preview = .complete
        var prefix = Data()
        task.resume()
        try await withTaskCancellationHandler {
            for try await event in events {
                switch event {
                case .response(let http):
                    guard let http else { return }
                    response = http
                    if http.expectedContentLength >= 2_000_000 { preview = .header }
                case .bytes(let bytes):
                    try file.write(contentsOf: bytes)
                    receiver.consumed(bytes.count, task: task)
                    let limit: Int
                    switch preview {
                    case .header: limit = 4096
                    case .page(let header): limit = header.byteCount
                    case .complete: continue
                    }
                    let accepted = bytes.prefix(max(0, limit - prefix.count))
                    prefix.append(accepted)
                    guard prefix.count >= limit else { continue }
                    if case .header = preview, let response, let length = Int(exactly: response.expectedContentLength),
                       let header = LinearizedPDFPreview.header(in: prefix, length: length) {
                        preview = .page(header)
                        let remainder = bytes.dropFirst(accepted.count)
                        // The first network chunk can already contain enough data for the page.
                        prefix.append(remainder.prefix(max(0, header.byteCount - prefix.count)))
                        if prefix.count < header.byteCount { continue }
                    }
                    if case .page(let header) = preview, let page = LinearizedPDFPreview.page(from: prefix, header: header) {
                        try Task.checkCancellation()
                        await onPage(page)
                    }
                    preview = .complete
                    prefix = Data()
                }
            }
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard let response else { return nil }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        guard (try? DownloadStore.validate(fileAt: staged, contentType: contentType)) != nil else { return nil }
        keepFile = true
        return FileAcquirer.Staged(file: staged, suggestedName: response.suggestedFilename, contentType: contentType)
    }
}
