import LaerCore
import Observation
import SwiftUI

/// Window-level view state that several screens share: the open course tab per course,
/// which sidebar rows are expanded and whether the command palette is open.
@MainActor
@Observable
final class Navigation {
    var courseTabs: [Int: CourseTab] = [:]
    var expandedCourses: Set<Int> = []
    var isArchiveOpen = false
    var isPaletteOpen = false

    func tab(for courseId: Int) -> CourseTab { courseTabs[courseId] ?? .plans }

    func tabBinding(for courseId: Int) -> Binding<CourseTab> {
        Binding(get: { self.tab(for: courseId) }, set: { self.courseTabs[courseId] = $0 })
    }
}

/// The thin icon strip at the window's left edge.
struct Rail: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @Environment(Navigation.self) private var navigation
    @FocusedValue(\.refreshCurrent) private var refreshCurrent

    var body: some View {
        VStack(spacing: Space.s4) {
            RailButton(symbol: Symbol.search, label: "Search", identifier: "rail.search", isSelected: navigation.isPaletteOpen) {
                navigation.isPaletteOpen = true
            }
            RailButton(symbol: Symbol.home, label: "Home", identifier: "rail.home", isSelected: model.selection == .home) {
                model.selection = .home
            }
            RailButton(symbol: Symbol.task, label: "Upcoming", identifier: "rail.upcoming", isSelected: model.selection == .upcoming) {
                model.selection = .upcoming
            }
            if ParityGate.personalCalendar {
                RailButton(symbol: Symbol.plan, label: "Calendar", identifier: "rail.calendar", isSelected: model.selection == .calendar) {
                    model.selection = .calendar
                }
            }
            if ParityGate.messages {
                RailButton(symbol: Symbol.message, label: "Messages", identifier: "rail.messages", isSelected: model.selection == .messages) {
                    model.selection = .messages
                }
            }
            Spacer(minLength: 0)
            if updater.isVisible {
                UpdateRailButton()
            }
            if !model.archivedCourses.isEmpty {
                RailButton(symbol: Symbol.archive, label: "Archived courses", identifier: "rail.archive", isSelected: navigation.isArchiveOpen) {
                    navigation.isArchiveOpen.toggle()
                }
                .popover(isPresented: Bindable(navigation).isArchiveOpen, arrowEdge: .trailing) {
                    ArchiveList()
                        .environment(navigation)
                }
            }
            IconButton(Symbol.refresh, label: "Refresh") {
                let current = refreshCurrent
                Task {
                    await model.refreshAll()
                    await current?.run()
                }
            }
            .frame(width: Size.control + Space.s4, height: Size.control + Space.s4)
        }
        .padding(.bottom, Space.s8)
        .padding(.top, Space.s8)
        .frame(width: Size.rail)
        .frame(maxHeight: .infinity)
        .background(Color.rail)
    }
}

private struct RailButton: View {
    let symbol: String
    let label: String
    let identifier: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        IconButton(symbol, label: label, action: action)
            .frame(width: Size.control + Space.s4, height: Size.control + Space.s4)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(isSelected ? Color.selected : Color.clear))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier(identifier)
    }
}

/// Shown above Archived while a new version is out. One click starts the update; the popover shows its progress.
private struct UpdateRailButton: View {
    @Environment(Updater.self) private var updater
    @State private var isOpen = false

    var body: some View {
        IconButton(Symbol.appUpdate, label: label) {
            isOpen = true
            updater.update()
        }
        .frame(width: Size.control + Space.s4, height: Size.control + Space.s4)
        .overlay { ring }
        .overlay(alignment: .topTrailing) {
            if case .available = updater.phase {
                Circle().fill(Color.accentFill).frame(width: 7, height: 7).offset(x: -3, y: 3)
            }
        }
        .accessibilityIdentifier("rail.update")
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            UpdateProgressView()
        }
    }

    private var label: String {
        switch updater.phase {
        case .available(let version): "Update to Laer \(version)"
        case .failed: "Update failed"
        default: "Updating Laer"
        }
    }

    /// Progress drawn round the icon, so it reads even with the popover closed.
    @ViewBuilder private var ring: some View {
        if let fraction = UpdateProgressView.fraction(updater.phase) {
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.accentFill, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
                .animation(.linear(duration: 0.2), value: fraction)
                .allowsHitTesting(false)
        }
    }
}

private struct UpdateProgressView: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(title)
                .font(Type.t13.weight(.semibold))
                .foregroundStyle(Color.text)
                .accessibilityAddTraits(.isHeader)
            switch updater.phase {
            case .available:
                Text("Laer downloads the update, installs it and restarts.")
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                TextButton("Update now", role: .primary) { updater.update() }
            case .failed(let message):
                ErrorLine(message)
                TextButton("Try again", role: .primary) { updater.update() }
            default:
                if let fraction = Self.fraction(updater.phase) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Color.accentFill)
                        .accessibilityLabel("Update progress")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.accentFill)
                        .accessibilityLabel("Update progress")
                }
                HStack {
                    Text(detail)
                    Spacer(minLength: Space.s8)
                    if let fraction = Self.fraction(updater.phase) {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                }
                .font(Type.t11)
                .foregroundStyle(Color.textMuted)
            }
        }
        .padding(Space.s12)
        .frame(width: 280, alignment: .leading)
    }

    private var title: String {
        switch updater.phase {
        case .available(let version): "Laer \(version) is available"
        case .downloading(let version, _), .extracting(let version, _), .installing(let version): "Updating to Laer \(version)"
        case .failed: "Update failed"
        case .checking: "Checking for updates"
        case .idle: "Laer is up to date"
        }
    }

    private var detail: String {
        switch updater.phase {
        case .downloading:
            guard updater.expectedBytes > 0 else { return "Downloading…" }
            let style = ByteCountFormatStyle(style: .file)
            return "Downloading \(Int64(updater.receivedBytes).formatted(style)) of \(Int64(updater.expectedBytes).formatted(style))"
        case .extracting: return "Preparing the update…"
        case .installing: return "Installing. Laer restarts in a moment."
        default: return ""
        }
    }

    /// Download is the first 80 percent of the bar, unpacking the rest, so it only ever moves forward.
    static func fraction(_ phase: Updater.Phase) -> Double? {
        switch phase {
        case .downloading(_, let fraction): fraction.map { $0 * 0.8 }
        case .extracting(_, let fraction): 0.8 + 0.2 * fraction
        case .installing: 1
        default: nil
        }
    }
}

/// Courses that aren't active, from the rail. A pick opens the course and closes the list.
private struct ArchiveList: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var action = WriteAction()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Archived courses")
                .font(Type.t13.weight(.semibold))
                .foregroundStyle(Color.text)
                .padding(.horizontal, Space.s8)
                .padding(.top, Space.s4)
                .padding(.bottom, Space.s6)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(model.archivedCourses) { course in
                        RowButton(selected: model.selection == .course(course.courseId), action: { open(course) }) {
                            HStack(spacing: Space.s8) {
                                Image(systemName: Symbol.course)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(Color.textMuted)
                                    .frame(width: Size.icon)
                                    .accessibilityHidden(true)
                                Text(course.shortTitle)
                                    .font(Type.t13)
                                    .foregroundStyle(Color.text)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: Size.control)
                            }
                        }
                        .accessibilityLabel(course.shortTitle)
                        .accessibilityIdentifier("archive.course.\(course.courseId)")
                        .overlay(alignment: .trailing) {
                            if ParityGate.writes {
                                IconButton(Symbol.star, label: "Make active") {
                                    Task { _ = await action.run { await model.toggleActive(course) } }
                                }
                                .disabled(action.isRunning)
                                .padding(.trailing, Space.s4)
                            }
                        }
                        .contextMenu {
                            if ParityGate.writes {
                                ActiveMenuItem(courseId: course.courseId, action: action) {
                                    _ = await action.run { await model.toggleActive(course) }
                                }
                            }
                        }
                    }
                }
                .undividedRows()
                .environment(\.rowSurface, .raised)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.s4)
        .frame(width: 300)
        .background(Color.raised)
    }

    private func open(_ course: Course) {
        navigation.isArchiveOpen = false
        model.selection = .course(course.courseId)
    }
}
