import AppKit
import SwiftUI

@main
enum LaerEntryPoint {
    @MainActor
    static func main() {
        if NSClassFromString("XCTestCase") != nil {
            TestHostApp.main()
        } else {
            LaerApp.main()
        }
    }
}

/// Empty host when Xcode injects the unit test bundle (`LaerMacTests`), skipping windows and startup side effects.
private struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct LaerApp: App {
    @State private var model = AppModel()
    @State private var updater = Updater()
    /// The Laer menu turns the menu bar icon on and off; removing it from the menu bar turns this off too.
    @AppStorage(LaerApp.showsMenuBarKey) private var showsMenuBarExtra = true

    static let showsMenuBarKey = "showsMenuBarExtra"

    var body: some Scene {
        Window("Laer", id: "main") {
            RootView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 860, minHeight: 520)
                .background(UITestWindowSize())
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.refreshIfStale() }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: RunLoop.main)) { _ in
                    Task { await model.refreshIfStale() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            LaerCommands(model: model)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkNow() }
                    .disabled(updater.isBusy)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            MenuBarView()
                .environment(model)
                .tint(Color.accent)
        } label: {
            Image(systemName: Symbol.course)
                .accessibilityLabel("Laer")
        }
        .menuBarExtraStyle(.window)
    }
}

/// UI tests only: `-LaerUITestWindowSize 1180x760` (with `-LaerUITestReset`) sets the window's
/// content size once, limited by the space available on the test display.
private struct UITestWindowSize: NSViewRepresentable {
    func makeNSView(context: Context) -> SizerView { SizerView() }
    func updateNSView(_ nsView: SizerView, context: Context) {}

    final class SizerView: NSView {
        private var applied = false

        override func viewDidMoveToWindow() {
            guard !applied, let window, let size = Self.requestedSize else { return }
            applied = true
            DispatchQueue.main.async {
                guard let screen = window.screen ?? NSScreen.main else {
                    window.setContentSize(size)
                    return
                }
                let visibleFrame = screen.visibleFrame
                let contentBounds = window.contentRect(forFrameRect: visibleFrame)
                window.setContentSize(NSSize(
                    width: min(size.width, contentBounds.width),
                    height: min(size.height, contentBounds.height)
                ))
                if !visibleFrame.contains(window.frame) {
                    window.setFrameOrigin(NSPoint(
                        x: visibleFrame.midX - window.frame.width / 2,
                        y: visibleFrame.midY - window.frame.height / 2
                    ))
                }
            }
        }

        private static var requestedSize: NSSize? {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-LaerUITestReset"),
                  let flag = arguments.firstIndex(of: "-LaerUITestWindowSize"),
                  arguments.indices.contains(flag + 1) else { return nil }
            let parts = arguments[flag + 1].lowercased().split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { return nil }
            return NSSize(width: parts[0], height: parts[1])
        }
    }
}
