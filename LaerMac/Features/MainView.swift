import LaerCore
import SwiftUI

/// Main window: the rail, the course sidebar, the selected screen in a rounded panel and,
/// when a file is open, the file in a second panel on the right.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var navigation = Navigation()

    /// The person's own choice, kept between launches.
    @AppStorage("showsSidebar") private var prefersSidebar = true
    /// Set when they ask for the sidebar while an open file would hide it.
    @State private var keepsSidebarWithFile = false

    /// Below this width an open file hides the sidebar, so neither panel gets cramped.
    private let roomForSidebarWithFile: CGFloat = 1180

    var body: some View {
        GeometryReader { proxy in
            let shows = prefersSidebar && (model.viewerItem == nil || keepsSidebarWithFile || proxy.size.width >= roomForSidebarWithFile)
            VStack(spacing: 0) {
                topBar(showsSidebar: shows)
                shell(showsSidebar: shows)
            }
            .background(Color.rail)
            .background(WindowButtonAligner(firstButtonCenterX: Size.rail / 2, centerY: Size.topBar / 2))
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(navigation)
        .overlay {
            if navigation.isPaletteOpen {
                CommandPalette()
                    .environment(navigation)
                    .transition(.opacity)
            }
        }
        .motion(Motion.base, value: navigation.isPaletteOpen)
        .motion(Motion.base, value: model.viewerItem == nil)
        .motion(Motion.base, value: prefersSidebar)
        .motion(Motion.base, value: keepsSidebarWithFile)
        .onChange(of: model.viewerItem == nil) { _, closed in
            if closed { keepsSidebarWithFile = false }
        }
        .focusedSceneValue(\.openPalette, PaletteAction { navigation.isPaletteOpen = true })
    }

    /// The wider top edge of the frame: room for the window buttons, then the sidebar toggle.
    private func topBar(showsSidebar: Bool) -> some View {
        HStack(spacing: Space.s4) {
            IconButton(Symbol.sidebar, label: showsSidebar ? "Hide sidebar" : "Show sidebar") {
                if showsSidebar {
                    prefersSidebar = false
                    keepsSidebarWithFile = false
                } else {
                    prefersSidebar = true
                    keepsSidebarWithFile = true
                }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .accessibilityIdentifier("topbar.sidebar")
            Spacer(minLength: 0)
            if ParityGate.notifications {
                NotificationsButton()
                    // Room for the unread count beside the bell.
                    .padding(.trailing, Space.s16)
            }
        }
        // Clears the window's close, minimise and zoom buttons.
        .padding(.leading, 84)
        .frame(height: Size.topBar)
        .background(TitleBarArea())
    }

    /// The rail on the frame's wider left edge, then one rounded container holding the
    /// sidebar, the screen and the file, each in its own shade.
    private func shell(showsSidebar: Bool) -> some View {
        HStack(spacing: 0) {
            Rail()
            HStack(spacing: 0) {
                if showsSidebar {
                    Sidebar()
                        .frame(width: 248)
                        .transition(.offset(x: -40).combined(with: .opacity))
                }
                ViewerSplit {
                    VStack(spacing: 0) {
                        if let notice = model.sessionNotice {
                            SessionBanner(message: notice)
                        }
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .background(Color.stage)
                }
                .frame(minWidth: 260, maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .padding([.trailing, .bottom], Size.frameEdge)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .home, nil:
            HomeView()
        case .upcoming:
            UpcomingView()
        case .messages:
            MessagesView()
        case .calendar:
            PersonalCalendarView()
        case .course(let id):
            if let course = model.courses.first(where: { $0.courseId == id }) {
                CourseDetailView(course: course)
                    .id(id)
            } else {
                PageScroll { EmptyLine("This course is no longer in your list") }
            }
        }
    }
}

private struct Sidebar: View {
    /// Space between the sidebar's edges and its row fills.
    static let sidebarInset: CGFloat = Space.s8
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeAction = WriteAction()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // A 2pt gap keeps neighbouring highlights from touching.
                    LazyVStack(alignment: .leading, spacing: Space.s2) {
                        let archivedIds = Set(model.archivedCourses.map(\.courseId))
                        let activeIds = Set(model.activeCourses.map(\.courseId))
                        let others = model.courses.filter { !activeIds.contains($0.courseId) && !archivedIds.contains($0.courseId) }
                        if model.courses.isEmpty {
                            courseListState
                                .padding(.horizontal, Space.s8)
                        }
                        ForEach(model.activeCourses + others) { course in courseRow(course) }
                        if case .failed(let message) = activeAction.phase {
                            ErrorLine(message).padding(.horizontal, Space.s8)
                        }
                    }
                    .undividedRows()
                    // Fills sit `sidebarInset` in from both edges, so a highlight never looks clipped.
                    .padding(.horizontal, Self.sidebarInset)
                    .padding(.top, Space.s8)
                    // The last row keeps clear of the bottom edge and the freshness line.
                    .padding(.bottom, Space.s8)
                }
                // Keyboard moves (Go menu) keep the chosen row in view.
                .onChange(of: model.selection) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }
            FreshnessLine(state: model.coursesState)
                .padding(.horizontal, Space.s12)
                .padding(.vertical, Space.s4)
        }
        .background(Color.chrome)
    }

    private func courseRow(_ course: Course) -> some View {
        CourseSidebarRow(course: course)
            .contextMenu {
                if ParityGate.writes {
                    // A child view reads the active list itself, because macOS keeps a context menu
                    // built for a row's first state.
                    ActiveMenuItem(courseId: course.courseId, action: activeAction) {
                        await toggleActive(course)
                    }
                }
                if let url = model.absoluteURL(course.url) {
                    Button("Open on the website") { NSWorkspace.shared.open(url) }
                }
            }
            .id(AppModel.Selection.course(course.courseId))
    }

    private func toggleActive(_ course: Course) async {
        _ = await activeAction.run { await model.toggleActive(course) }
    }

    private var courseListState: some View {
        EmptyState(state: model.coursesState, empty: "This account has no courses")
    }
}

/// A course: the name opens it; the chevron on the right shows its sections.
private struct CourseSidebarRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let course: Course
    @State private var isHovering = false

    private var isExpanded: Bool { navigation.expandedCourses.contains(course.courseId) }

    var body: some View {
        let isSelected = model.selection == .course(course.courseId)
        VStack(alignment: .leading, spacing: Space.s2) {
            RowButton(selected: isSelected && !isExpanded, action: { open(nil) }) {
                HStack(spacing: Space.s8) {
                    Image(systemName: Symbol.course)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(isSelected ? Color.text : Color.textMuted)
                        .frame(width: Size.icon)
                        .accessibilityHidden(true)
                    Text(course.shortTitle)
                        .font(Type.t13)
                        .foregroundStyle(Color.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Size.controlSmall)
                }
            }
            .accessibilityLabel(course.shortTitle)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("sidebar.course.\(course.courseId)")
            .overlay(alignment: .trailing) { chevron }
            if isExpanded {
                ForEach(CourseTab.available(grades: GradesAvailability.shared.isAvailable(courseId: course.courseId, model: model)), id: \.self) { tab in
                    let tabSelected = isSelected && navigation.tab(for: course.courseId) == tab
                    RowButton(selected: tabSelected, action: { open(tab) }) {
                        HStack(spacing: Space.s8) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 12, weight: .regular))
                                .frame(width: Size.icon)
                                .accessibilityHidden(true)
                            Text(tab.title)
                                .font(Type.t13)
                                .lineLimit(1)
                        }
                        .foregroundStyle(tabSelected ? Color.text : Color.textMuted)
                    }
                    .padding(.leading, Space.s16)
                    .accessibilityIdentifier("sidebar.course.\(course.courseId).\(tab.title)")
                }
            }
        }
        .onHover { isHovering = $0 }
    }

    private var chevron: some View {
        Button {
            withMotion(Motion.base, reduceMotion: reduceMotion) {
                if isExpanded {
                    navigation.expandedCourses.remove(course.courseId)
                } else {
                    navigation.expandedCourses.insert(course.courseId)
                }
            }
        } label: {
            Image(systemName: Symbol.disclosure)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textMuted)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: Size.controlSmall, height: Size.controlSmall)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.trailing, Space.s4)
        // Shown on hover and while open, so a resting list stays quiet.
        .opacity(isHovering || isExpanded ? 1 : 0)
        .accessibilityLabel(isExpanded ? "Hide sections of \(course.shortTitle)" : "Show sections of \(course.shortTitle)")
        .accessibilityIdentifier("sidebar.expand.\(course.courseId)")
    }

    private func open(_ tab: CourseTab?) {
        if let tab { navigation.courseTabs[course.courseId] = tab }
        model.selection = .course(course.courseId)
    }
}

struct ActiveMenuItem: View {
    @Environment(AppModel.self) private var model
    let courseId: Int
    let action: WriteAction
    let toggle: () async -> Void

    var body: some View {
        // With nothing starred every course counts as active, but none has been made active.
        let isActive = !model.archivedCourses.isEmpty && model.activeCourses.contains { $0.courseId == courseId }
        Button(isActive ? "Remove from active" : "Make active") { Task { await toggle() } }
            .disabled(action.isRunning)
    }
}
