import Foundation
import Testing
@testable import Laer

struct OfficePDFConverterTests {
    @Test(.timeLimit(.minutes(1)), arguments: [true, false]) @MainActor
    func handlesXPCWarmupCallbacksOffMain(acceptsConnection: Bool) async {
        let listener = NSXPCListener.anonymous()
        let service = PreviewService(acceptsConnection: acceptsConnection)
        listener.delegate = service
        listener.resume()

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: QuickLookPreviewing.self)
        connection.resume()
        defer {
            connection.invalidate()
            listener.invalidate()
            withExtendedLifetime(service) {}
        }

        let (prepared, offMain) = await withCheckedContinuation { continuation in
            OfficePDFConverter.prepareService(on: connection) { prepared in
                continuation.resume(returning: (prepared, !Thread.isMainThread))
            }
        }
        #expect(prepared == acceptsConnection)
        #expect(offMain)
    }
}

private final class PreviewService: NSObject, NSXPCListenerDelegate, QuickLookPreviewing {
    let acceptsConnection: Bool

    init(acceptsConnection: Bool) { self.acceptsConnection = acceptsConnection }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard acceptsConnection else { return false }
        connection.exportedInterface = NSXPCInterface(with: QuickLookPreviewing.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func preparePreview(reply: @escaping () -> Void) { reply() }
    func writePreview(sourcePath: String, outputPath: String, reply: @escaping (Bool) -> Void) { reply(false) }
}
