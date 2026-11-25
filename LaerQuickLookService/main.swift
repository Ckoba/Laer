import Foundation
import Security

// Runs the system's Quick Look tool for the sandboxed app, which can't start it itself.
// It accepts one Office file and one empty output folder, both inside a `LaerOffice-` scratch
// folder in the app's temporary directory, and does nothing else.
//
// The service is deliberately not sandboxed: `qlmanage` must be launched as a separate process
// and must reach the Quick Look daemon, which the app sandbox forbids (the reason this helper
// exists). Instead its reach is narrowed here: only Laer may connect (when signed with a team),
// paths are canonicalised and confined to the scratch folder, only Office extensions are
// accepted, and `qlmanage -x` always renders in the system's own sandboxed Quick Look daemon
// rather than loading generators into an unsandboxed process.

/// Where the app's scratch folders may live, already canonicalised.
enum ScratchRoots {
    static let all: [String] = {
        var roots: [String] = []
        // A sandboxed Laer keeps its temporary files in its data container.
        if let home = homeDirectory(), let app = containingAppIdentifier() {
            roots.append(home + "/Library/Containers/" + app + "/Data/tmp")
        }
        // An unsandboxed Laer shares this service's temporary directory.
        roots.append(NSTemporaryDirectory())
        return roots.compactMap(PathRules.canonical)
    }()

    private static func homeDirectory() -> String? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }

    /// The bundle identifier of the app this service is embedded in (`…/X.app/Contents/XPCServices/Y.xpc`).
    static func containingAppIdentifier() -> String? {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent() // XPCServices
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // X.app
        guard app.pathExtension == "app" else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }
}

enum PathRules {
    static let officeExtensions: Set<String> = [
        "doc", "docx", "ppt", "pptx", "pps", "ppsx", "xls", "xlsx", "rtf",
        "odt", "odp", "ods", "key", "pages", "numbers",
    ]

    /// The fully resolved path, or nil when it does not exist.
    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Rejects option-like, relative and traversing paths before anything touches the disk.
    static func isPlainAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return !parts.contains { $0 == ".." || $0 == "." || $0.hasPrefix("-") }
    }

    static func fileType(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    /// Both paths after validation, or nil when either falls outside the rules.
    static func validate(source: String, output: String, roots: [String]) -> (source: String, output: String)? {
        // Neither path as given may itself be a symbolic link.
        guard isPlainAbsolute(source), isPlainAbsolute(output),
              fileType(source) == S_IFREG, fileType(output) == S_IFDIR,
              let source = canonical(source), let output = canonical(output) else { return nil }
        // Resolved, they are still a regular file and a real directory.
        guard fileType(source) == S_IFREG, fileType(output) == S_IFDIR,
              officeExtensions.contains((source as NSString).pathExtension.lowercased()) else { return nil }
        // Both sit directly inside the same `LaerOffice-` scratch folder under an allowed root.
        let scratch = (source as NSString).deletingLastPathComponent
        guard (output as NSString).deletingLastPathComponent == scratch,
              (scratch as NSString).lastPathComponent.hasPrefix("LaerOffice-"),
              roots.contains((scratch as NSString).deletingLastPathComponent) else { return nil }
        // The output folder is this user's and still empty.
        var info = stat()
        guard lstat(output, &info) == 0, info.st_uid == getuid(),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: output),
              contents.isEmpty else { return nil }
        return (source, output)
    }
}

/// One per connection. Closing the connection stops a running conversion at once.
final class Service: NSObject, QuickLookPreviewing, @unchecked Sendable {
    private static let timeout = DispatchTimeInterval.seconds(90)
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func preparePreview(reply: @escaping () -> Void) { reply() }

    func writePreview(sourcePath: String, outputPath: String, reply: @escaping (Bool) -> Void) {
        guard let paths = PathRules.validate(source: sourcePath, output: outputPath, roots: ScratchRoots.all) else {
            reply(false)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        // `-x` renders in the Quick Look daemon. Both paths are absolute, so neither reads as an option.
        process.arguments = ["-x", "-p", "-o", paths.output, paths.source]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let once = ReplyOnce(reply)
        process.terminationHandler = { [weak self] finished in
            self?.clear(finished)
            once.send(finished.terminationReason == .exit && finished.terminationStatus == 0)
        }
        let started: Bool = lock.withLock {
            guard !cancelled, self.process == nil else { return false }
            do {
                try process.run()
            } catch {
                return false
            }
            self.process = process
            return true
        }
        guard started else {
            once.send(false)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
    }

    /// Called when the app closes or loses the connection.
    func cancel() {
        let running: Process? = lock.withLock {
            cancelled = true
            return process
        }
        if let running, running.isRunning { running.terminate() }
    }

    private func clear(_ finished: Process) {
        lock.withLock { if process === finished { process = nil } }
    }
}

/// Lets exactly one outcome reach the app.
final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Bool) -> Void)?

    init(_ reply: @escaping (Bool) -> Void) { self.reply = reply }

    func send(_ value: Bool) {
        let pending: ((Bool) -> Void)? = lock.withLock {
            defer { reply = nil }
            return reply
        }
        pending?(value)
    }
}

enum CallerRequirement {
    /// Only Laer, signed by the same team as this service, may connect. Nil for ad-hoc and unsigned
    /// local builds, which have no team to compare against.
    static let current: String? = {
        guard let team = ownTeamIdentifier(), isPlainToken(team),
              let app = ScratchRoots.containingAppIdentifier(), isPlainToken(app) else { return nil }
        return "anchor apple generic and identifier \"\(app)\" and certificate leaf[subject.OU] = \"\(team)\""
    }()

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func isPlainToken(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement = CallerRequirement.current {
            connection.setCodeSigningRequirement(requirement)
        }
        let service = Service()
        connection.exportedInterface = NSXPCInterface(with: QuickLookPreviewing.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.cancel() }
        connection.interruptionHandler = { service.cancel() }
        connection.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
