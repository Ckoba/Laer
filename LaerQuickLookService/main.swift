import Foundation

/// Runs the system's Quick Look tool for the sandboxed app, which can't start it itself.
/// It accepts a file and an output folder and does nothing else.
final class Service: NSObject, QuickLookPreviewing {
    func writePreview(sourcePath: String, outputPath: String, reply: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", "-o", outputPath, sourcePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            reply(false)
            return
        }
        let deadline = Date().addingTimeInterval(90)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning { process.terminate() }
        reply(process.terminationStatus == 0)
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: QuickLookPreviewing.self)
        connection.exportedObject = Service()
        connection.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
