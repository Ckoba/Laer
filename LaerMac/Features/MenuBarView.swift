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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: openLecture) { summary }
                .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: Space.s6) {
            HStack(spacing: Space.s6) {
                Image(systemName: Symbol.course)
                    .font(.system(size: 12, weight: .regular))
                    .accessibilityHidden(true)
                Text(lecture.course.shortTitle).lineLimit(1)
                Spacer(minLength: Space.s8)
                if let start = lecture.start {
                    Text(Self.when(start))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .font(Type.t12)
            .foregroundStyle(Color.textMuted)
            Text(lecture.plan.name ?? "Untitled plan")
                .font(Type.t15)
                .foregroundStyle(Color.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(isExpanded ? "Hide readings" : "Show readings")
    }

    /// "Today 10:15", "Tomorrow 08:00" or "Thu 20 Nov 10:15", in the person's locale.
    private static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(date) { return "\(String(localized: "Today")) \(time)" }
        if calendar.isDateInTomorrow(date) { return "\(String(localized: "Tomorrow")) \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
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
                RowTrailing(date: nil, chevron: true)
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
            Image(systemName: Symbol.open)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.textMuted)
                .help("Opens on the website")
                .accessibilityLabel("Opens on the website")
        }
    }
}
