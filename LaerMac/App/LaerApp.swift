import AppKit
import SwiftUI

@main
struct LaerApp: App {
    @State private var model = AppModel()
    @State private var updater = Updater()

    var body: some Scene {
        Window("Laer", id: "main") {
            RootView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 860, minHeight: 520)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.refreshIfStale() }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
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
    }
}
