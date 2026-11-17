import AppKit
import SwiftUI

/// Places the window's close, minimise and zoom buttons so red lines up with the rail's icons
/// and all three sit on the top bar's row. AppKit lays them out again after most window changes.
struct WindowButtonAligner: NSViewRepresentable {
    /// The centre of the rail's icons.
    var firstButtonCenterX: CGFloat
    /// The centre of the top bar's row, from the window's top.
    var centerY: CGFloat

    func makeNSView(context: Context) -> AlignerView {
        let view = AlignerView()
        view.firstButtonCenterX = firstButtonCenterX
        view.centerY = centerY
        return view
    }

    func updateNSView(_ view: AlignerView, context: Context) {
        view.apply()
    }

    final class AlignerView: NSView {
        var firstButtonCenterX: CGFloat = 0
        var centerY: CGFloat = 0
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.apply()
                        DispatchQueue.main.async { self?.apply() }
                    }
                }
            }
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
                // Slightly wider than the system 20, so green sits over the sidebar's icons.
                let spacing: CGFloat = 22
                let x = firstButtonCenterX - button.frame.width / 2 + CGFloat(index) * spacing
                let y = container.frame.height - centerY - button.frame.height / 2
                button.setFrameOrigin(NSPoint(x: x, y: y))
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
