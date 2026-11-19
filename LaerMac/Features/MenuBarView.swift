import AppKit
import LaerCore
import SwiftUI

/// The menu bar panel: the next two lectures, each opening to its readings. Everything it shows
/// is already in memory, so it draws complete at once; a stale refresh runs behind it.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var expanded: Set<Int> = []

    var body: some View {
        let lectures = model.upcomingLectures()
        VStack(alignment: .leading, spacing: 0) {
            header
            content(lectures)
                .padding(.horizontal, Space.s8)
            footer
        }
        .frame(width: 340)
        .background(Color.chrome)
        .onAppear {
            model.menuBarOpened()
            // The soonest lecture opens to its readings the first time.
            if expanded.isEmpty, let first = lectures.first { expanded = [first.id] }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Next lectures")
                .font(Type.t13)
                .foregroundStyle(Color.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s8)
            Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(Type.t12)
                .foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, Space.s16)
        .padding(.top, Space.s12)
        .padding(.bottom, Space.s8)
    }

    @ViewBuilder private func content(_ lectures: [UpcomingLecture]) -> some View {
        switch model.authState {
        case .ready:
            if lectures.isEmpty {
                EmptyLine(model.activeCourses.isEmpty ? "No active courses" : "No upcoming lectures")
                    .padding(Space.s8)
            } else {
                VStack(spacing: Space.s8) {
                    ForEach(lectures) { lecture in
                        MenuLectureCard(
                            lecture: lecture,
                            isExpanded: expanded.contains(lecture.id),
                            toggle: { toggle(lecture.id) },
                            openLecture: { show { model.openLectureFromMenuBar(lecture) } },
                            openReading: { element in show { model.openFromMenuBar(element, in: lecture) } }
                        )
                    }
                }
            }
        default:
            EmptyLine("Sign in to Laer to see your lectures")
                .padding(Space.s8)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if !model.studyLinks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s4) {
                        ForEach(model.studyLinks) { link in
                            LinkIconButton(symbol: link.icon, label: link.title) { model.open(link) }
                                .help(link.title)
                        }
                    }
                }
                .padding(.horizontal, Space.s8)
                .padding(.top, Space.s8)
            }
            actions
        }
    }

    private var actions: some View {
        HStack(spacing: Space.s8) {
            TextButton("Open Laer") { show {} }
            Spacer(minLength: 0)
            TextButton("Quit") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, Space.s12)
        .padding(.vertical, Space.s8)
        .padding(.top, Space.s4)
    }

    private func toggle(_ id: Int) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Closes the panel, brings the main window forward and then applies the change, so the
    /// window's first frame already shows it.
    private func show(_ change: () -> Void) {
        change()
        NSApp.windows.first { $0.className.contains("MenuBarExtra") && $0.isVisible }?.orderOut(nil)
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct MenuLectureCard: View {
    @Environment(AppModel.self) private var model
    let lecture: UpcomingLecture
    let isExpanded: Bool
    let toggle: () -> Void
    let openLecture: () -> Void
    let openReading: (PlanPreview.Element) -> Void
    @State private var isHovering = false

    /// Concentric with the panel: its corner radius less the cards' inset from the panel's edge.
    private static let radius = Radius.panel - Space.s8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: openLecture) { summary }
                .buttonStyle(FocusRingButtonStyle(cornerRadius: Self.radius))
                .focusEffectDisabled()
                .onHover { isHovering = $0 }
            if !lecture.readings.isEmpty {
                disclosure
                if isExpanded {
                    VStack(spacing: Space.s2) {
                        ForEach(lecture.readings) { element in
                            LectureReadingRow(element: element, courseId: lecture.course.courseId) { openReading(element) }
                        }
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s6)
                    .environment(\.rowSurface, .raised)
                }
            }
        }
        .background(ZStack { shape.fill(Color.raised); shape.fill(isHovering ? Color.hover : Color.clear) })
        .clipShape(shape)
        .motion(Motion.fast, value: isExpanded)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                Text(lecture.plan.name ?? "Untitled plan")
                    .font(Type.t15)
                    .foregroundStyle(Color.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let when = Self.when(lecture) {
                    Text(when)
                        .font(Type.t12.weight(.regular))
                        .foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: Space.s6) {
                Circle()
                    .fill(Color.course(lecture.course.courseId))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(lecture.course.shortTitle).lineLimit(1)
            }
            .font(Type.t12.weight(.regular))
            .foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, Space.s12)
        .padding(.top, Space.s12)
        .padding(.bottom, lecture.readings.isEmpty ? Space.s12 : Space.s6)
        .contentShape(Rectangle())
    }

    private var disclosure: some View {
        Button(action: toggle) {
            HStack(spacing: Space.s4) {
                Image(systemName: Symbol.disclosure)
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Size.iconSmall)
                Text(lecture.readings.count == 1 ? "1 reading" : "\(lecture.readings.count) readings")
                Spacer(minLength: 0)
            }
            .font(Type.t11)
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, Space.s12)
            .padding(.vertical, Space.s6)
            .contentShape(Rectangle())
        }
        .buttonStyle(FocusRingButtonStyle())
        .focusEffectDisabled()
        .accessibilityLabel(isExpanded ? "Hide readings" : "Show readings")
    }

    /// A plan of a day or less: when it starts, as lists say it ("Today 10:15 AM"). A week-long plan
    /// is "This week" while it runs, else its range. A start at midnight has no time to show.
    private static func when(_ lecture: UpcomingLecture, now: Date = .now) -> String? {
        guard let start = lecture.start else { return nil }
        let calendar = Calendar.current
        let stop = StudyDates.usable(lecture.plan.stop)
        if let stop, stop.timeIntervalSince(start) > 24 * 3600 {
            return start <= now && now <= stop
                ? String(localized: "This week")
                : StudyDates.weekRange(start, stop)
        }
        if calendar.startOfDay(for: start) == start {
            return start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return StudyDates.relative(start, now: now)
    }
}

/// A plan file with its saved or website-only state. Shared by the menu bar and Home.
struct LectureReadingRow: View {
    @Environment(AppModel.self) private var model
    let element: PlanPreview.Element
    let courseId: Int
    let action: () -> Void

    private var resource: Resource { Resource(planElement: element, courseId: courseId) }
    private var opensInApp: Bool { element.isResource != false }

    var body: some View {
        RowButton(action: action) {
            HStack(spacing: Space.s6) {
                Image(systemName: opensInApp ? Symbol.file(extension: (element.title.map { ($0 as NSString).pathExtension }).flatMap { $0.isEmpty ? nil : $0 }) : Symbol.link)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.textMuted)
                    .frame(width: Size.icon)
                    .accessibilityHidden(true)
                Text(element.title ?? "Material")
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.s8)
                status
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        if model.downloadStates[resource.id] == .downloading {
            Spinner()
        } else if model.savedAssets[resource.id] != nil {
            Image(systemName: Symbol.saved)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.textMuted)
                .help("Saved on this Mac")
                .accessibilityLabel("Saved")
        } else if !opensInApp {
            WebsiteMark()
        }
    }
}
