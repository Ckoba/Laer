import AppKit
import QuartzCore
import SwiftUI

/// Keeps the window buttons pinned to the top bar's row on every screen. Switching screens updates
/// `NSWindow.title` via `.navigationTitle` (and updates scene/toolbar state), which causes AppKit
/// to re-tile the titlebar and reset the buttons ~4pt higher. Correcting their origins synchronously
/// (`queue: nil`) with implicit Core Animation actions disabled puts them back inside the same
/// layout pass before the frame commits, so they never visibly jump.
struct WindowButtonWatch: NSViewRepresentable {
    var firstButtonCenterX: CGFloat
    var centerY: CGFloat

    func makeNSView(context: Context) -> WatchView {
        let view = WatchView()
        view.firstButtonCenterX = firstButtonCenterX
        view.centerY = centerY
        return view
    }

    func updateNSView(_ view: WatchView, context: Context) {
        view.firstButtonCenterX = firstButtonCenterX
        view.centerY = centerY
        view.align()
    }

    static func dismantleNSView(_ view: WatchView, coordinator: ()) { view.stop() }

    final class WatchView: NSView {
        private static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var firstButtonCenterX: CGFloat = 0
        var centerY: CGFloat = 0
        private var observers: [NSObjectProtocol] = []
        private var titleObservation: NSKeyValueObservation?
        private weak var watchedContainer: NSView?
        private var isAligning = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
            align()
            DispatchQueue.main.async { [weak self] in self?.align() }
        }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            titleObservation?.invalidate()
            titleObservation = nil
            watchedContainer = nil
        }

        private func attach() {
            stop()
            guard let window else { return }
            var watched: [NSView] = []
            for type in Self.buttonTypes {
                guard let button = window.standardWindowButton(type) else { continue }
                watched.append(button)
                if let container = button.superview, !watched.contains(container) {
                    watched.append(container)
                    if watchedContainer == nil { watchedContainer = container }
                }
                if let superContainer = button.superview?.superview, !watched.contains(superContainer) {
                    watched.append(superContainer)
                }
            }
            for view in watched {
                view.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { @Sendable [weak self] _ in
                    guard Thread.isMainThread else { return }
                    MainActor.assumeIsolated { self?.align() }
                })
            }
            let windowNames: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                NSWindow.didUpdateNotification,
            ]
            for name in windowNames {
                let isFullScreenExit = name == NSWindow.didExitFullScreenNotification
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { @Sendable [weak self] _ in
                    guard Thread.isMainThread else { return }
                    MainActor.assumeIsolated {
                        self?.align()
                        if isFullScreenExit {
                            DispatchQueue.main.async { self?.align() }
                        }
                    }
                })
            }
            titleObservation = window.observe(\.title, options: [.new]) { @Sendable [weak self] _, _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.align() }
            }
        }

        func align() {
            guard !isAligning, let window, !window.styleMask.contains(.fullScreen) else { return }
            if let currentContainer = window.standardWindowButton(.closeButton)?.superview,
               currentContainer !== watchedContainer {
                attach()
            }
            // Match the spacing set for the window frame.
            let spacing: CGFloat = 22
            let themeFrame = window.contentView?.superview
            var moves: [(NSButton, NSPoint)] = []
            for (index, type) in Self.buttonTypes.enumerated() {
                guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
                if !button.postsFrameChangedNotifications { button.postsFrameChangedNotifications = true }
                let target: NSPoint
                if let themeFrame {
                    let centerInTheme = NSPoint(
                        x: firstButtonCenterX + CGFloat(index) * spacing,
                        y: themeFrame.isFlipped ? centerY : themeFrame.bounds.maxY - centerY
                    )
                    let centerInContainer = container.convert(centerInTheme, from: themeFrame)
                    target = NSPoint(
                        x: centerInContainer.x - button.frame.width / 2,
                        y: centerInContainer.y - button.frame.height / 2
                    )
                } else {
                    target = NSPoint(
                        x: firstButtonCenterX - button.frame.width / 2 + CGFloat(index) * spacing,
                        y: container.frame.height - centerY - button.frame.height / 2
                    )
                }
                if abs(button.frame.origin.x - target.x) > 0.5 || abs(button.frame.origin.y - target.y) > 0.5 {
                    moves.append((button, target))
                }
            }
            guard !moves.isEmpty else { return }
            isAligning = true
            defer { isAligning = false }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            for (button, target) in moves {
                button.setFrameOrigin(target)
            }
        }
    }
}

/// The top bar: drags the window, and a double click does what System Settings says it should.
struct TitleBarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ nsView: AreaView, context: Context) {}

    final class AreaView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
