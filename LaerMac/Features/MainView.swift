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

    /// The person's dragged sidebar width, kept between launches.
    @AppStorage("sidebarWidth") private var sidebarWidth = Double(Size.sidebar)

    private var clampedSidebarWidth: CGFloat {
        min(max(CGFloat(sidebarWidth), Size.sidebarMin), Size.sidebarMax)
    }

    var body: some View {
        GeometryReader { _ in
            // An open file keeps the sidebar, so a student never loses their place; only the
            // full-width reader, or the person's own toggle, hides it.
            let shows = prefersSidebar && !(model.viewerItem != nil && model.viewerIsFull && !keepsSidebarWithFile)
            VStack(spacing: 0) {
                topBar(showsSidebar: shows)
                shell(showsSidebar: shows)
            }
            .background(Color.rail)
            .background(WindowButtonAligner(firstButtonCenterX: Size.rail / 2, centerY: Size.topBar / 2 + Space.s2))
            .background(WindowButtonWatch(centerY: Size.topBar / 2 + Space.s2))
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(navigation)
        .overlay {
            if navigation.isPaletteOpen {
                CommandPalette(restoring: navigation.restoresSearch ? navigation.searchReturn : nil)
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
        .onChange(of: model.snapshots.map(ObjectIdentifier.init)) {
            navigation.searchTarget = nil
            navigation.searchReturn = nil
            navigation.restoresSearch = false
            navigation.isPaletteOpen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            model.updateSearchOCR()
        }
        .focusedSceneValue(\.openPalette, PaletteAction { navigation.isPaletteOpen = true })
        .alert("Make lecture briefs on this Mac?", isPresented: Binding(
            get: { model.briefs.shouldAsk },
            set: { _ in }
        )) {
            Button("Turn On") { Task { await model.setOnDeviceBriefs(true) } }
            Button("Not Now", role: .cancel) { Task { await model.setOnDeviceBriefs(false) } }
        } message: {
            Text("Laer can use Apple Intelligence to write a short brief for upcoming lectures from the readings you save. It runs on this Mac and nothing is sent anywhere. You can change this later in the Laer menu.")
        }
        // A file opened from the menu bar shows its course on Plans, where the file lives.
        .onAppear(perform: takePlansTabRequest)
        .onChange(of: model.plansTabRequest) { _, _ in takePlansTabRequest() }
    }

    private func takePlansTabRequest() {
        guard let id = model.plansTabRequest else { return }
        navigation.courseTabs[id] = .plans
        model.plansTabRequest = nil
    }

    /// The wider top edge of the frame: room for the window buttons, then the sidebar toggle.
    private func topBar(showsSidebar: Bool) -> some View {
        HStack(spacing: Space.s4) {
            IconButton(Symbol.sidebar, label: showsSidebar ? "Hide sidebar" : "Show sidebar", symbolSize: 16) {
                if showsSidebar {
                    prefersSidebar = false
                    keepsSidebarWithFile = false
                } else {
                    prefersSidebar = true
                    keepsSidebarWithFile = model.viewerIsFull
                }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .accessibilityIdentifier("topbar.sidebar")
            Spacer(minLength: 0)
            if navigation.searchReturn != nil && !navigation.isPaletteOpen {
                IconButton(Symbol.back, label: "Back to search", symbolSize: 15) { returnToSearch() }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .accessibilityIdentifier("search.return")
            }
            // The same items in the same places with or without the sidebar.
            SearchFieldButton { navigation.isPaletteOpen = true }
            RefreshButton()
            if ParityGate.notifications {
                NotificationsButton()
                    // Room for the unread count beside the bell.
                    .padding(.trailing, Space.s16)
            }
        }
        // 2pt down, so the bell's count badge, which rides above the icon, clears the window's top edge.
        .offset(y: Space.s2)
        // Clears the window's close, minimise and zoom buttons.
        .padding(.leading, 84)
        .frame(height: Size.topBar)
        .background(TitleBarArea())
    }

    private func returnToSearch() {
        guard let state = navigation.searchReturn else { return }
        navigation.searchTarget = nil
        navigation.courseTabs = state.courseTabs
        navigation.expandedCourses = state.expandedCourses
        model.selection = state.previousSelection
        model.viewerItem = state.previousFile
        navigation.restoresSearch = true
        navigation.isPaletteOpen = true
    }

    /// The rail on the frame's wider left edge, then the sidebar on the frame, then one
    /// rounded container holding the screen and the file.
    private func shell(showsSidebar: Bool) -> some View {
        HStack(spacing: 0) {
            if !showsSidebar {
                Rail()
                    .transition(.opacity)
            }
            if showsSidebar {
                Sidebar()
                    .frame(width: clampedSidebarWidth)
                    .overlay(alignment: .trailing) { SidebarResizeHandle(width: $sidebarWidth) }
                    .transition(.offset(x: -40).combined(with: .opacity))
            }
            // Only the page and the file reader sit in the rounded container; the sidebar
            // shares the frame's colour, like Mail's.
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
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            // The same 8pt of frame on every side: right and bottom here, the left from the
            // sidebar's own row inset (or the rail's tile margin, topped up below), the top from
            // the top bar under its controls.
            .padding([.trailing, .bottom], Size.frameEdge)
            .padding(.leading, showsSidebar ? 0 : Size.frameEdge - Size.railMargin)
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

/// Keeps the window buttons on the top bar's row on every screen. AppKit puts them back at its own
/// height, about 4pt higher, at moments with no window notification, such as the first click after
/// launch, so Home (placed at launch) and every screen after it disagreed. When a button's frame
/// moves off the top bar's row this asks `WindowButtonAligner` to run again, through the window
/// notification it already listens to.
private struct WindowButtonWatch: NSViewRepresentable {
    var centerY: CGFloat

    func makeNSView(context: Context) -> WatchView {
        let view = WatchView()
        view.centerY = centerY
        return view
    }

    func updateNSView(_ view: WatchView, context: Context) {
        view.centerY = centerY
        view.check()
    }

    final class WatchView: NSView {
        var centerY: CGFloat = 0
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            var watched: [NSView] = []
            for type in types {
                guard let button = window.standardWindowButton(type) else { continue }
                watched.append(button)
                if let container = button.superview, !watched.contains(container) { watched.append(container) }
            }
            for view in watched {
                view.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check() }
                })
            }
            check()
        }

        func check() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let button = window.standardWindowButton(.closeButton), let container = button.superview else { return }
            let expected = container.frame.height - centerY - button.frame.height / 2
            guard abs(button.frame.origin.y - expected) > 0.5 else { return }
            // After AppKit's layout pass, not during it.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
            }
        }
    }
}

/// A thin strip on the sidebar's right edge: drag to resize between `Size.sidebarMin` and
/// `Size.sidebarMax`, double-click to go back to `Size.sidebar`.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?
    @State private var isInside = false

    var body: some View {
        Color.clear
            .frame(width: Space.s8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering, !isInside {
                    isInside = true
                    NSCursor.resizeLeftRight.push()
                } else if !hovering, isInside {
                    isInside = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isInside {
                    isInside = false
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(max(start + Double(value.translation.width), Double(Size.sidebarMin)), Double(Size.sidebarMax))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { width = Double(Size.sidebar) }
            .accessibilityElement()
            .accessibilityLabel("Resize sidebar")
            .accessibilityIdentifier("sidebar.resize")
    }
}

private struct Sidebar: View {
    /// Space between the sidebar's edges and its row fills.
    static let sidebarInset: CGFloat = Space.s8
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeAction = WriteAction()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The app's own places stay put; only the courses scroll.
            VStack(alignment: .leading, spacing: Space.s2) { destinations }
                .padding(.horizontal, Self.sidebarInset)
                .padding(.top, Space.s8)
            ScrollViewReader { proxy in
                ScrollView {
                    // A 2pt gap keeps neighbouring highlights from touching.
                    LazyVStack(alignment: .leading, spacing: Space.s2) {
                        Text("Courses")
                            .font(Type.section)
                            .foregroundStyle(Color.textMuted)
                            .padding(.horizontal, Space.s8)
                            .padding(.top, Space.s16)
                            .padding(.bottom, Space.s4)
                            .accessibilityAddTraits(.isHeader)
                        if model.courses.isEmpty {
                            courseListState
                                .padding(.horizontal, Space.s8)
                        }
                        ForEach(model.activeCourses) { course in courseRow(course) }
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
            footer
        }
        // Source-list density: 26pt rows, 13pt labels, 16pt symbol slots.
        .environment(\.rowsCompact, true)
        .environment(\.rowVerticalPadding, 5)
        // Rows sit on the frame colour, so their fills are the stronger sidebar pair over it.
        .environment(\.rowSurface, Color.rail)
        .environment(\.rowSelectedFill, Color.sidebarSelected)
        .environment(\.rowHoverFill, Color.sidebarHover)
        .background(Color.rail)
    }

    /// The app's own places, labelled, above the courses.
    @ViewBuilder private var destinations: some View {
        DestinationRow(symbol: Symbol.home, title: "Home", identifier: "rail.home", selection: .home)
        DestinationRow(symbol: Symbol.task, title: "Assignments", identifier: "rail.upcoming", selection: .upcoming, count: dueSoon)
        if ParityGate.personalCalendar {
            DestinationRow(symbol: Symbol.plan, title: "Calendar", identifier: "rail.calendar", selection: .calendar)
        }
        if ParityGate.messages {
            MessagesDestinationRow()
        }
    }

    private var dueSoon: Int {
        let sections = UpcomingList.sections(
            model.tasks, activeCourseIds: Set(model.activeCourses.map(\.courseId)), now: currentMinute(), calendar: .current
        )
        return sections.overdue.count + sections.today.count + sections.thisWeek.count
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if updater.isVisible {
                HStack(spacing: Space.s4) {
                    UpdateRailButton()
                    Text("Update available")
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                }
                .padding(.horizontal, Space.s4)
            }
            if !model.archivedCourses.isEmpty {
                RowButton(selected: navigation.isArchiveOpen, action: { navigation.isArchiveOpen.toggle() }) {
                    HStack(spacing: Space.s8) {
                        Image(systemName: Symbol.archive)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Color.textMuted)
                            .frame(width: Size.icon)
                            .accessibilityHidden(true)
                        Text("Archived courses")
                            .font(Type.t13)
                            .foregroundStyle(Color.textMuted)
                        Spacer(minLength: 0)
                        Text("\(model.archivedCourses.count)")
                            .font(Type.t12)
                            .monospacedDigit()
                            .foregroundStyle(Color.textFaint)
                    }
                }
                .accessibilityIdentifier("rail.archive")
                .popover(isPresented: Bindable(navigation).isArchiveOpen, arrowEdge: .trailing) {
                    ArchiveList()
                        .environment(navigation)
                }
                .padding(.horizontal, Self.sidebarInset)
            }
            FreshnessLine(state: model.coursesState)
                .padding(.horizontal, Space.s16)
                .padding(.vertical, Space.s4)
        }
        .padding(.bottom, Space.s4)
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
                    Circle()
                        .fill(Color.course(course.courseId))
                        .frame(width: 8, height: 8)
                        .frame(width: Size.icon)
                        .accessibilityHidden(true)
                    Text(course.shortTitle)
                        .font(Type.t13)
                        .foregroundStyle(Color.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // No reserved gap for the hover chevron: it overlays the row's end, so
                    // names only cut off when they are longer than the row itself.
                    Spacer(minLength: 0)
                }
            }
            .help(course.displayTitle)
            .accessibilityLabel(course.displayTitle)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("sidebar.course.\(course.courseId)")
            .overlay(alignment: .trailing) { chevron }
            if isExpanded {
                ForEach(CourseTab.available(grades: GradesAvailability.shared.isAvailable(courseId: course.courseId, model: model)), id: \.self) { tab in
                    let tabSelected = isSelected && navigation.tab(for: course.courseId) == tab
                    RowButton(selected: tabSelected, action: { open(tab) }) {
                        HStack(spacing: Space.s8) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 14, weight: .regular))
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
        // Only on hover, so a selected row looks the same on every tab: a fill and no chevron.
        .opacity(isHovering ? 1 : 0)
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

/// One of the app's own places in the source list: icon, label and an optional count.
private struct DestinationRow: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    let title: String
    let identifier: String
    let selection: AppModel.Selection
    var count: Int = 0

    var body: some View {
        let isSelected = model.selection == selection || (selection == .home && model.selection == nil)
        RowButton(selected: isSelected, action: { model.selection = selection }) {
            HStack(spacing: Space.s8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.textMuted)
                    .frame(width: Size.icon)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(Type.t12)
                        .monospacedDigit()
                        .foregroundStyle(Color.textMuted)
                }
            }
        }
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityIdentifier(identifier)
    }
}

private struct MessagesDestinationRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DestinationRow(
            symbol: Symbol.message, title: "Messages", identifier: "rail.messages", selection: .messages,
            count: model.unreadThreadCount ?? 0
        )
        .task(id: model.selection) { await model.refreshUnreadThreadCount() }
    }
}

/// Refresh everything, then the screen in front. Lives in the top bar beside Search.
private struct RefreshButton: View {
    @Environment(AppModel.self) private var model
    @FocusedValue(\.refreshCurrent) private var refreshCurrent

    var body: some View {
        IconButton(Symbol.refresh, label: "Refresh", help: "Refresh") {
            let current = refreshCurrent
            Task {
                await model.refreshAll()
                await current?.run()
            }
        }
        .accessibilityIdentifier("topbar.refresh")
    }
}

/// Looks like a search field and opens the palette, so a new student sees where search is.
private struct SearchFieldButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s6) {
                Image(systemName: Symbol.search)
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)
                Text("Search")
                    .font(Type.t12)
                    .lineLimit(1)
                Spacer(minLength: Space.s8)
                Text("⌘K")
                    .font(Type.t11)
                    .foregroundStyle(Color.textFaint)
            }
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, Space.s8)
            .frame(width: 280, height: Size.controlSmall)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(isHovering ? Color.selected : Color.hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Search (⌘K)")
        .accessibilityLabel("Search")
        .accessibilityIdentifier("topbar.search")
    }
}
