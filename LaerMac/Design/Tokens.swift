import AppKit
import SwiftUI

// The only place in the app that holds colour, size, type and motion values.
// docs/ui-reference.md lists the same values; change both together.

enum Space {
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s6: CGFloat = 6
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    /// The one inset between a screen's edge and its title, cards and row text.
    static let page: CGFloat = 24
}

/// Circles use `Circle()`, never a radius.
enum Radius {
    static let s: CGFloat = 5
    static let m: CGFloat = 8
    static let l: CGFloat = 14
    /// The inner container and the palette.
    static let panel: CGFloat = 16
}

enum Size {
    static let control: CGFloat = 28
    static let controlSmall: CGFloat = 24
    static let icon: CGFloat = 16
    static let iconSmall: CGFloat = 12
    static let readingColumn: CGFloat = 720
    /// The one content column: every page's titles, cards and rows share its leading edge and this
    /// maximum width. Trailing header actions sit at its trailing edge.
    static let contentMax: CGFloat = 880
    /// The widest a list or reading page grows (`PageScroll(width: .reading)`): the column is
    /// left-aligned at the content inset and its metadata sits at its right edge, not the window's.
    static let readingMax: CGFloat = 760
    /// The one inset between a screen's edge and its title, cards and row text.
    static let contentInset: CGFloat = Space.page
    /// Icons centre at 20, under the red window button. The sidebar starts here, so with
    /// `Sidebar.sidebarInset` 8 and a row's own 8, its icons centre at 64, under green.
    static let rail: CGFloat = 40
    static let topBar: CGFloat = 40
    /// The source list's default width; the person can drag it between `sidebarMin` and `sidebarMax`.
    static let sidebar: CGFloat = 220
    static let sidebarMin: CGFloat = 180
    static let sidebarMax: CGFloat = 280
    /// A list row's minimum height (`ListRow`).
    static let listRow: CGFloat = 44
    /// The one height of a page title's row, so every page's title sits on the same baseline.
    static let pageHeader: CGFloat = 32
    /// The frame's inset round the content card: the strip along the window's right and bottom
    /// edges, equal to the sidebar's row inset on the left.
    static let frameEdge: CGFloat = 8
    /// Space between a rail tile and the rail's own edge (tiles are `rail - 2 * railMargin` wide).
    static let railMargin: CGFloat = 2
    /// A rail tile: a nav icon's selection fill, and a course's monogram tile.
    static let railTile: CGFloat = rail - 2 * railMargin
    /// The circle holding a course's two-letter monogram in the rail.
    static let monogram: CGFloat = 28
    static let palette: CGFloat = 560
}

/// Interface text is 500, titles (15 and 18) 600, course text 400 (`body`).
enum Type {
    /// The two letters in a course's rail monogram.
    static let rail: Font = .system(size: 11, weight: .semibold)
    static let t11: Font = .system(size: 11, weight: .medium)
    static let t12: Font = .system(size: 12, weight: .medium)
    static let t13: Font = .system(size: 13, weight: .medium)
    /// Course text and messages: what people read rather than scan.
    static let body: Font = .system(size: 13)
    static let t15: Font = .system(size: 15, weight: .semibold)
    static let t18: Font = .system(size: 18, weight: .semibold)
    /// A screen's own title (Home's date, Upcoming, a course name).
    static let title: Font = .system(size: 22, weight: .bold)
    /// Small uppercase-free group labels over sections, in the source list and on screens.
    static let section: Font = .system(size: 11, weight: .semibold)
    /// A list group's or page section's header, and the count after it (same size, regular).
    static let group: Font = .system(size: 15, weight: .semibold)
    static let groupCount: Font = .system(size: 15)
    static let mono12: Font = .system(size: 12, design: .monospaced)

    /// Extra spacing that brings 13pt text to a 1.45 line height.
    static let bodyLineSpacing: CGFloat = 3
}

extension Color {
    static let stage = dynamic(light: 0xFFFFFF, dark: 0x191919)
    static let chrome = dynamic(light: 0xF3F3F3, dark: 0x222222)
    /// The outer frame: the rail and top bar, and the thin strip along the right and bottom.
    static let rail = dynamic(light: 0xE2E2E2, dark: 0x2C2C2C)
    /// The right panel.
    static let viewerPanel = dynamic(light: 0xFAFAFA, dark: 0x1F1F1F)
    static let raised = dynamic(light: 0xF7F7F7, dark: 0x303030)
    static let border = dynamic(light: 0xE3E3E3, dark: 0x2E2E2E)
    static let borderStrong = dynamic(light: 0xCCCCCC, dark: 0x404040)
    static let text = dynamic(light: 0x1F1F1F, dark: 0xEDEDED)
    static let textMuted = dynamic(light: 0x6B6B6B, dark: 0x9E9E9E)

    static let hover = dynamic(light: (0x000000, 0.05), dark: (0xFFFFFF, 0.06))
    static let selected = dynamic(light: (0x000000, 0.08), dark: (0xFFFFFF, 0.10))
    /// The source list and rail sit on the frame colour, where `selected` is faint: a clearly
    /// darker (lighter in dark) neutral wash for the chosen row, and a lighter one for hover.
    static let sidebarSelected = dynamic(light: (0x000000, 0.13), dark: (0xFFFFFF, 0.15))
    static let sidebarHover = dynamic(light: (0x000000, 0.06), dark: (0xFFFFFF, 0.07))
    static let pressed = dynamic(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.14))

    // Decision 0015: the person's system accent marks selection, focus, links, today and the
    // primary button; each course has its own hue; red stays for danger and overdue.
    /// Focus rings, links and the today marker.
    static let accent = Color(nsColor: .controlAccentColor)
    /// The primary button.
    static let accentFill = Color(nsColor: .controlAccentColor)
    /// A light neutral wash: today's column, quiet blocks.
    static let accentTint = dynamic(light: (0x000000, 0.05), dark: (0xFFFFFF, 0.07))
    /// Text on `accentFill`.
    static let onAccent = Color.white
    /// A disabled primary button's fill and label: the native disabled look.
    static let disabledFill = Color(nsColor: .quaternaryLabelColor)
    static let disabledLabel = Color(nsColor: .tertiaryLabelColor)
    /// The chosen segment in a segmented control, clearly lifted off its track in both themes.
    static let segmentSelected = dynamic(light: 0xFFFFFF, dark: 0x4A4A4A)
    /// A third text level, below `textMuted`: ended events, hints.
    static let textFaint = dynamic(light: 0x9A9A9A, dark: 0x6E6E6E)

    /// One hue per course, picked by course id so it stays the same between launches.
    static func course(_ id: Int) -> Color { coursePalette[((id % coursePalette.count) + coursePalette.count) % coursePalette.count] }

    /// Eight hues at 40 to 60 degrees apart on the colour wheel (HSL hue 28, 70, 128, 168, 208,
    /// 248, 288, 328), at one perceived lightness and chroma per theme (OKLCH 0.56 / 0.15 in light,
    /// 0.76 / 0.13 in dark), so they read as one calm family and keep at least 4:1 against the
    /// stage. Listed in steps of three round the wheel, so courses with neighbouring ids differ by
    /// 120 degrees or more, and no two entries are close. Red is left to danger.
    private static let coursePalette: [Color] = [
        dynamic(light: 0xB65500, dark: 0xF2985F), // orange, 28
        dynamic(light: 0x008F73, dark: 0x32CCAF), // teal, 168
        dynamic(light: 0x9953AB, dark: 0xD495E5), // purple, 288
        dynamic(light: 0x6A8000, dark: 0xA7BD58), // olive, 70
        dynamic(light: 0x1B77C8, dark: 0x6FB6FF), // blue, 208
        dynamic(light: 0xB24981, dark: 0xEE8DBD), // pink, 328
        dynamic(light: 0x2B8A36, dark: 0x79C77C), // green, 128
        dynamic(light: 0x7163C7, dark: 0xACA4FF), // indigo, 248
    ]

    static let scrim = dynamic(light: (0x000000, 0.35), dark: (0x000000, 0.55))
    static let shadowPopup = dynamic(light: (0x000000, 0.12), dark: (0x000000, 0.40))

    static let success = dynamic(light: 0x1E7F3C, dark: 0x4CC26B)
    static let danger = dynamic(light: 0xC62828, dark: 0xFF6B60)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        dynamic(light: (light, 1), dark: (dark, 1))
    }

    private static func dynamic(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (rgb, alpha) = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: alpha)
        })
    }
}

enum Motion {
    static let fast: Animation = .timingCurve(0.2, 0, 0, 1, duration: 0.12)
    static let base: Animation = .timingCurve(0.2, 0, 0, 1, duration: 0.18)
    static let slow: Animation = .timingCurve(0.2, 0, 0, 1, duration: 0.32)
    /// One spinner turn, in seconds. Linear; nothing else uses it.
    static let loopDuration: Double = 0.8
    /// How long a spinner waits before it shows.
    static let spinnerDelay: Duration = .milliseconds(180)
}

/// Runs `body` animated, or without animation when Reduce Motion is on.
@MainActor
func withMotion(_ animation: Animation, reduceMotion: Bool, _ body: () -> Void) {
    if reduceMotion {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    } else {
        withAnimation(animation, body)
    }
}

/// A hover ending: out over `Motion.fast`, or at once under Reduce Motion.
@MainActor
func hoverEnded(_ body: () -> Void) {
    withMotion(Motion.fast, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, body)
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that turns off under Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// The one shadow, for floating surfaces only.
    func floatShadow() -> some View {
        shadow(color: .shadowPopup, radius: 12, x: 0, y: 8)
    }
}
