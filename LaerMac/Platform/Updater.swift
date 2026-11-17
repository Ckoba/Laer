import Foundation
import Observation
import Sparkle

/// Finds new Laer releases and installs one when the person asks. Sparkle does the checking, the signature
/// checks and the install through its sandbox installer service; this type only turns its callbacks into
/// state for the rail button, so the update shows in Laer's own interface rather than Sparkle's windows.
@MainActor @Observable
final class Updater {
    enum Phase: Equatable {
        /// Nothing to show: no update known, or the last check found none.
        case idle
        case checking
        case available(version: String)
        /// `fraction` is nil until the download reports its size.
        case downloading(version: String, fraction: Double?)
        case extracting(version: String, fraction: Double)
        case installing(version: String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Set while Sparkle waits for the person to choose the update it found.
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private(set) var expectedBytes: UInt64 = 0
    private(set) var receivedBytes: UInt64 = 0
    private var version = ""
    /// A check the person started, so "no update" and errors are shown instead of staying quiet.
    private var isUserCheck = false

    private var updater: SPUUpdater?
    private var driver: Driver?

    /// The rail shows the button only while there is something to act on or watch.
    var isVisible: Bool {
        switch phase {
        case .idle, .checking: false
        default: true
        }
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .extracting, .installing: true
        default: false
        }
    }

    init() {
        // Tests and debug runs from Xcode carry no feed and must never replace the app under test.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !ProcessInfo.processInfo.arguments.contains("-LaerUITestReset") else { return }
        let driver = Driver(owner: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try updater.start()
        } catch {
            return
        }
        self.driver = driver
        self.updater = updater
        updater.checkForUpdatesInBackground()
    }

    /// One click: installs an update already found, or checks for one and installs what it finds.
    func update() {
        switch phase {
        case .available:
            install()
        case .failed:
            phase = .idle
            checkNow()
        default:
            break
        }
    }

    /// The menu command. A found update stays one click away on the rail.
    func checkNow() {
        guard let updater, updater.canCheckForUpdates else { return }
        isUserCheck = true
        updater.checkForUpdates()
    }

    private func install() {
        guard let choice = pendingChoice else { return }
        pendingChoice = nil
        phase = .downloading(version: version, fraction: nil)
        choice(.install)
    }

    // MARK: - Sparkle callbacks, already on the main actor

    fileprivate func found(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.version = version
        pendingChoice = reply
        isUserCheck = false
        phase = .available(version: version)
    }

    fileprivate func checkStarted() {
        if phase == .idle { phase = .checking }
    }

    fileprivate func noUpdate() {
        isUserCheck = false
        if phase == .checking { phase = .idle }
    }

    fileprivate func failed(_ error: Error) {
        let shown = isUserCheck || isBusy
        isUserCheck = false
        pendingChoice = nil
        // A quiet background check that fails, such as when offline, leaves the rail as it was.
        phase = shown ? .failed(Self.message(for: error)) : .idle
    }

    fileprivate func downloadStarted() {
        expectedBytes = 0
        receivedBytes = 0
        phase = .downloading(version: version, fraction: nil)
    }

    fileprivate func expect(_ bytes: UInt64) {
        expectedBytes = bytes
        receivedBytes = 0
        phase = .downloading(version: version, fraction: bytes > 0 ? 0 : nil)
    }

    fileprivate func received(_ bytes: UInt64) {
        receivedBytes += bytes
        guard expectedBytes > 0 else { return }
        phase = .downloading(version: version, fraction: min(Double(receivedBytes) / Double(expectedBytes), 1))
    }

    fileprivate func extracting(_ fraction: Double) {
        phase = .extracting(version: version, fraction: fraction)
    }

    fileprivate func installing() {
        phase = .installing(version: version)
    }

    fileprivate func dismissed() {
        if case .failed = phase { return }
        if pendingChoice == nil { phase = .idle }
    }

    private static func message(for error: Error) -> String {
        let code = (error as NSError).code
        if code == Int(SUError.downloadError.rawValue) {
            return "The download failed. Check your connection and try again."
        }
        if code == Int(SUError.signatureError.rawValue) || code == Int(SUError.validationError.rawValue) {
            return "The update could not be verified, so it was not installed."
        }
        if code == Int(SUError.noUpdateError.rawValue) {
            return "Laer is up to date."
        }
        return "The update could not be installed. Try again later."
    }
}

/// Sparkle's user interface protocol, answered by `Updater` state instead of windows.
private final class Driver: NSObject, SPUUserDriver {
    private weak var owner: Updater?

    init(owner: Updater) {
        self.owner = owner
    }

    private func onOwner(_ body: @escaping @MainActor (Updater) -> Void) {
        MainActor.assumeIsolated {
            if let owner { body(owner) }
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Checking is the point of the feature; no system profile is ever sent.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        onOwner { $0.checkStarted() }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        onOwner { $0.found(version: version, reply: reply) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        onOwner { $0.noUpdate() }
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        onOwner { $0.failed(error) }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        onOwner { $0.downloadStarted() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        onOwner { $0.expect(expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        onOwner { $0.received(length) }
    }

    func showDownloadDidStartExtractingUpdate() {
        onOwner { $0.extracting(0) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        onOwner { $0.extracting(progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // The person already chose to update with one click, so install and relaunch straight away.
        onOwner { $0.installing() }
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        onOwner { $0.installing() }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        onOwner { $0.dismissed() }
    }
}
