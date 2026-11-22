import Foundation

/// Runs the system's Quick Look tool for the sandboxed app, which can't start it itself.
/// It accepts a file and an output folder and does nothing else.
final class Service: NSObject, QuickLookPreviewing {
    func preparePreview(reply: @escaping () -> Void) { reply() }

    func writePreview(sourcePath: String, outputPath: String, reply: @escaping (Bool) -> Void) {
        let source = URL(fileURLWithPath: sourcePath)
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        reply(writeFullPreview(source: source, output: output))
    }

    private func writeFullPreview(source: URL, output: URL) -> Bool {
        let deadline = DispatchTime.now() + .seconds(90)
        if source.pathExtension.lowercased() == "docx" {
            let daemonOutput = output.appendingPathComponent("DaemonPreview", isDirectory: true)
            let files = FileManager.default
            if (try? files.createDirectory(at: daemonOutput, withIntermediateDirectories: false)) != nil {
                let ran = run("/usr/bin/qlmanage", ["-x", "-p", "-o", daemonOutput.path, source.path], deadline: deadline)
                if ran, files.enumerator(at: daemonOutput, includingPropertiesForKeys: nil)?
                    .contains(where: { ($0 as? URL)?.lastPathComponent == "Preview.html" }) == true {
                    return true
                }
                try? files.removeItem(at: daemonOutput)
            }
        }
        return run("/usr/bin/qlmanage", ["-p", "-o", output.path, source.path], deadline: deadline)
    }
}

func run(_ executable: String, _ arguments: [String], deadline: DispatchTime) -> Bool {
    guard DispatchTime.now() < deadline else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
        try process.run()
    } catch {
        return false
    }
    if finished.wait(timeout: deadline) == .timedOut {
        if process.isRunning { process.terminate() }
        return false
    }
    return process.terminationStatus == 0
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
