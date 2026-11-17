import Foundation
import OSLog

/// Timing marks for tuning, readable with `log show`. Names only, no account data.
enum Perf {
    private static let log = Logger(subsystem: "app.laer.Laer", category: "perf")
    private static let start = ProcessInfo.processInfo.systemUptime

    static func begin() { _ = start }

    static func mark(_ name: StaticString) {
        let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        log.notice("\(name, privacy: .public) \(ms)ms")
    }
}
