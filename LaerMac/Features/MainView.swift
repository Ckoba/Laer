import LaerCore
import SwiftUI

/// Main window: the collapsible sidebar, the selected screen in a rounded panel and,
/// when a file is open, the file in a second panel on the right.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var navigation = Navigation()

    /// The person's own choice, kept between launches.
    @AppStorage("showsSidebar") private var savedSidebarPreference = true
    /// Fixtures start expanded and keep changes local to the window.
    @State private var testSidebarPreference: Bool? =
        UserDefaults.standard.bool(forKey: "LaerUITestReset") ? true : nil
    /// Set when they ask for the sidebar while an open file would hide it.
    @State private var keepsSidebarWithFile = false

    /// The person's dragged sidebar width, kept between launches.
    @AppStorage("sidebarWidth") private var sidebarWidth = Double(Size.sidebar)

    private var prefersSidebar: Bool {
        get { testSidebarPreference ?? savedSidebarPreference }
        nonmutating set {
            if testSidebarPreference != nil {
                testSidebarPreference = newValue
            } else {
                savedSidebarPreference = newValue
            }
        }
    }

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
            .background(WindowButtonWatch(firstButtonCenterX: Size.firstWindowButtonCenter, centerY: Size.topBar / 2))
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(navigation)
        .overlay {
            if navigation.isPaletteOpen {
                CommandPalette(restoring: navigation.paletteRestore)
                    .id(navigation.paletteID)
                    .environment(navigation)
                    .transition(.opacity)
            }
        }
        .motion(Motion.base, value: navigation.isPaletteOpen)
        .motion(Motion.base, value: model.viewerItem == nil)
        .onChange(of: model.viewerItem == nil) { _, closed in
            if closed { keepsSidebarWithFile = false }
        }
        // Every change of place is one history entry; another account starts with none.
        .onAppear { navigation.start(model) }
        .onChange(of: navigation.place(model)) { navigation.record() }
        .onChange(of: model.snapshots.map(ObjectIdentifier.init)) { navigation.start(model) }
        .onPreferenceChange(UnsentDraftKey.self) { [navigation] hasDraft in
            MainActor.assumeIsolated { navigation.hasDraft = hasDraft }
        }
        .alert(
            "Discard your draft?",
            isPresented: Binding(get: { navigation.pendingMove != nil }, set: { if !$0 { navigation.pendingMove = nil } }),
            presenting: navigation.pendingMove
        ) { move in
            Button(move == .back ? "Discard and Go Back" : "Discard and Go Forward", role: .destructive) {
                navigation.move(move, confirmed: true)
            }
            Button("Keep Editing", role: .cancel) {}
        } message: { _ in
            Text("What you have written here has not been sent.")
        }
        .background(HistoryEventMonitor(
            canGoBack: navigation.canGoBack,
            canGoForward: navigation.canGoForward,
            isSuspended: navigation.isPaletteOpen || navigation.pendingMove != nil,
            onBack: { navigation.goBack() },
            onForward: { navigation.goForward() },
            onSwipeProgress: { navigation.swipeFeedback = $0 }
        ))
        .focusedSceneValue(\.history, HistoryActions(
            canGoBack: navigation.canGoBack, canGoForward: navigation.canGoForward,
            back: { navigation.goBack() }, forward: { navigation.goForward() }
        ))
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            model.updateSearchOCR()
        }
        .focusedSceneValue(\.openPalette, PaletteAction { openPalette() })
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
        .onAppear(perform: takeSiteLinkRequest)
        .onChange(of: model.siteLinkRequest) { _, _ in takeSiteLinkRequest() }
        // Settings removes recognized text without access to this window's navigation.
        .onChange(of: model.searchOCRIsClearing) { _, clearing in if clearing { navigation.forgetRecognizedText() } }
    }

    private func openPalette() {
        navigation.paletteRestore = nil
        navigation.isPaletteOpen = true
    }

    private func takeSiteLinkRequest() {
        guard let request = model.siteLinkRequest else { return }
        model.siteLinkRequest = nil
        if !navigation.openSiteLink(request.url, courseId: request.courseId) {
            if let courseId = request.courseId {
                model.selection = .course(courseId)
                navigation.courseTabs[courseId] = .plans
            }
            NSWorkspace.shared.open(request.url)
        }
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
            // ⌘[ and ⌘] live on the Go menu's Back and Forward, which call the same moves.
            IconButton(Symbol.back, label: "Back", help: "Back (⌘[)", symbolSize: 15) { navigation.goBack() }
                .disabled(!navigation.canGoBack)
                .accessibilityIdentifier("topbar.back")
            IconButton(Symbol.forward, label: "Forward", help: "Forward (⌘])", symbolSize: 15) { navigation.goForward() }
                .disabled(!navigation.canGoForward)
                .accessibilityIdentifier("topbar.forward")
            Spacer(minLength: 0)
            // The same items in the same places with or without the sidebar.
            SearchFieldButton { openPalette() }
            RefreshButton()
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

    /// The sidebar and the rounded container holding the screen and the file.
    private func shell(showsSidebar: Bool) -> some View {
        ViewerSplit {
            VStack(spacing: 0) {
                if let notice = model.sessionNotice {
                    SessionBanner(message: notice)
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color.stage)
            .modifier(HistorySwipeShift())
        }
        .overlay { HistorySwipeOverlay() }
        .modifier(SidebarSplit(
            width: showsSidebar ? clampedSidebarWidth : Sidebar.compactWidth,
            expandedWidth: clampedSidebarWidth
        ) {
            Sidebar(showsLabels: showsSidebar, expandedWidth: clampedSidebarWidth)
                .overlay(alignment: .trailing) {
                    if showsSidebar {
                        SidebarResizeHandle(width: $sidebarWidth)
                            .transition(.identity)
                    }
                }
        })
        .motion(showsSidebar ? Motion.sidebarExpand : Motion.sidebarCollapse, value: showsSidebar)
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

/// Re-lays out both panes at the interpolated width so the page follows the sidebar's edge.
private struct SidebarSplit<SidebarContent: View>: ViewModifier, Animatable {
    nonisolated var width: CGFloat
    let expandedWidth: CGFloat
    @ViewBuilder var sidebar: () -> SidebarContent

    nonisolated var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func body(content: Content) -> some View {
        let visibleWidth = min(max(width, Sidebar.compactWidth), expandedWidth)
        let hasDetailsRoom = visibleWidth >= Sidebar.compactWidth + Size.sidebarIconSlot
        GeometryReader { geometry in
            let panelWidth = max(0, geometry.size.width - visibleWidth - Size.frameEdge)
            let panelHeight = max(0, geometry.size.height - Size.frameEdge)
            HStack(alignment: .top, spacing: 0) {
                sidebar()
                    .environment(\.sidebarHasDetailsRoom, hasDetailsRoom)
                    .frame(width: visibleWidth, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
                content
                    .frame(width: panelWidth, height: panelHeight)
                    // Mask the exact panel bounds at every sample of the sidebar animation.
                    .mask { RoundedRectangle(cornerRadius: Radius.panel, style: .continuous) }
            }
        }
        // The interpolated width is already an animation frame.
        .animation(nil, value: width)
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
    private static let inset = Space.s8
    // The same gutters and leading icon column fit in the compact sidebar.
    static let compactWidth = 2 * (inset + Space.s8) + Size.sidebarIconSlot

    let showsLabels: Bool
    let expandedWidth: CGFloat

    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @Environment(Navigation.self) private var navigation
    @State private var activeAction = WriteAction()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The app's own places stay put; only the courses scroll.
            VStack(alignment: .leading, spacing: Space.s8) { destinations }
                .environment(\.rowVerticalPadding, Space.s6)
                .padding(.horizontal, Self.inset)
                .padding(.top, Space.s8)
            if !model.activeCourses.isEmpty {
                Rectangle()
                    .fill(Color.borderStrong)
                    .frame(height: 1)
                    .padding(.horizontal, Self.inset)
                    .padding(.top, Space.s12)
                    .accessibilityHidden(true)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.s4) {
                        if model.courses.isEmpty {
                            courseListState
                                .padding(.horizontal, Space.s8)
                                .sidebarDetails(showsLabels)
                        }
                        ForEach(model.activeCourses) { course in courseRow(course) }
                        if case .failed(let message) = activeAction.phase {
                            ErrorLine(message)
                                .padding(.horizontal, Space.s8)
                                .sidebarDetails(showsLabels)
                        }
                    }
                    .undividedRows()
                    .padding(.horizontal, Self.inset)
                    .padding(.top, Space.s8)
                    // The last row keeps clear of the bottom edge and the freshness line.
                    .padding(.bottom, Space.s8)
                }
                .scrollIndicators(showsLabels ? .automatic : .hidden)
                .scrollBounceBehavior(.basedOnSize)
                // Keyboard moves (Go menu) keep the chosen row in view.
                .onChange(of: model.selection) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }
            footer
        }
        // The icon slot sets the height, even when the text is hidden.
        .environment(\.rowsCompact, true)
        .environment(\.rowVerticalPadding, Space.s4)
        // Rows sit on the frame colour, so their fills are the stronger sidebar pair over it.
        .environment(\.rowSurface, Color.rail)
        .environment(\.rowSelectedFill, Color.sidebarSelected)
        .environment(\.rowHoverFill, Color.sidebarHover)
        .environment(\.sidebarClosingLabelWidth, showsLabels ? nil : expandedWidth - Self.compactWidth)
        .background(Color.rail)
    }

    /// The app's own places, labelled, above the courses.
    @ViewBuilder private var destinations: some View {
        DestinationRow(symbol: Symbol.home, title: "Home", identifier: "rail.home", selection: .home, showsLabel: showsLabels)
        DestinationRow(symbol: Symbol.task, title: "Assignments", identifier: "rail.upcoming", selection: .upcoming, showsLabel: showsLabels, count: dueSoon)
        if ParityGate.personalCalendar {
            DestinationRow(symbol: Symbol.plan, title: "Calendar", identifier: "rail.calendar", selection: .calendar, showsLabel: showsLabels)
        }
        if ParityGate.messages {
            MessagesDestinationRow(showsLabel: showsLabels)
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
                HStack(spacing: 0) {
                    UpdateRailButton()
                    Text("Update available")
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                        .fixedSize(horizontal: !showsLabels, vertical: false)
                        .padding(.leading, Space.s4)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .clipped()
                        .sidebarDetails(showsLabels)
                }
                .padding(.horizontal, Self.inset + Space.s4)
            }
            if !model.archivedCourses.isEmpty {
                RowButton(selected: navigation.isArchiveOpen, action: { navigation.isArchiveOpen.toggle() }) {
                    SidebarRowLabel(showsLabel: showsLabels) {
                        SidebarSymbol(name: Symbol.archive)
                    } label: {
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
                .help("Archived courses")
                .accessibilityLabel("Archived courses, \(model.archivedCourses.count)")
                .accessibilityIdentifier("rail.archive")
                .environment(\.rowVerticalPadding, Space.s6)
                .popover(isPresented: Bindable(navigation).isArchiveOpen, arrowEdge: .trailing) {
                    ArchiveList()
                        .environment(navigation)
                }
                .padding(.horizontal, Self.inset)
            }
            FreshnessLine(state: model.coursesState)
                .frame(width: expandedWidth - Space.s32, alignment: .leading)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s16)
                .padding(.vertical, Space.s4)
                .sidebarDetails(showsLabels)
        }
        // The last row ends where the content's bottom corner starts to curve, not beside the curve.
        .padding(.bottom, Size.frameEdge + Radius.panel)
    }

    private func courseRow(_ course: Course) -> some View {
        CourseSidebarRow(course: course, showsLabels: showsLabels)
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
    let showsLabels: Bool
    @State private var isHovering = false

    private var isExpanded: Bool { navigation.expandedCourses.contains(course.courseId) }

    private var monogram: String {
        guard let word = course.shortTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first else { return "" }
        return word.prefix(1).uppercased() + word.dropFirst().prefix(1)
    }

    var body: some View {
        let isSelected = model.selection == .course(course.courseId)
        let colour = Color.course(course.courseId)
        VStack(alignment: .leading, spacing: Space.s2) {
            RowButton(selected: isSelected && !isExpanded, action: { open(nil) }) {
                SidebarRowLabel(showsLabel: showsLabels) {
                    Text(monogram)
                        .font(Type.courseMonogram)
                        .foregroundStyle(colour)
                        .lineLimit(1)
                        .frame(width: Size.courseMonogram, height: Size.courseMonogram)
                        .background(Circle().fill(colour.opacity(isSelected ? 0.34 : 0.16)))
                } label: {
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
            .accessibilityIdentifier("\(showsLabels ? "sidebar" : "rail").course.\(course.courseId)")
            .overlay(alignment: .trailing) {
                chevron.sidebarDetails(showsLabels)
            }
            if isExpanded {
                ForEach(CourseTab.available(grades: GradesAvailability.shared.isAvailable(courseId: course.courseId, model: model)), id: \.self) { tab in
                    let tabSelected = isSelected && navigation.tab(for: course.courseId) == tab
                    RowButton(selected: tabSelected, action: { open(tab) }) {
                        SidebarRowLabel(showsLabel: showsLabels) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 14, weight: .regular))
                                .offset(x: Space.s4)
                        } label: {
                            Text(tab.title)
                                .font(Type.t13)
                                .lineLimit(1)
                                .padding(.leading, Space.s4)
                        }
                        .foregroundStyle(tabSelected ? Color.text : Color.textMuted)
                    }
                    .help(tab.title)
                    .accessibilityLabel(tab.title)
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
        .buttonStyle(FocusRingButtonStyle())
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

/// Opening lets the label reflow. Closing clips its expanded layout at the moving edge.
private struct SidebarRowLabel<Icon: View, Label: View>: View {
    @Environment(\.sidebarClosingLabelWidth) private var closingLabelWidth
    let showsLabel: Bool
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var label: () -> Label

    var body: some View {
        HStack(spacing: 0) {
            icon()
                .frame(width: Size.sidebarIconSlot, height: Size.sidebarIconSlot)
                .accessibilityHidden(true)
            Color.clear
                .frame(height: Size.sidebarIconSlot)
                .overlay(alignment: .leading) {
                    HStack(spacing: Space.s8, content: label)
                        .padding(.leading, Space.s8)
                        .frame(width: closingLabelWidth, alignment: .leading)
                        .allowsHitTesting(showsLabel)
                        .accessibilityHidden(!showsLabel)
                }
                .clipped()
        }
    }
}

private struct SidebarSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: Size.sidebarSymbol, weight: .regular))
            .foregroundStyle(Color.textMuted)
    }
}

private extension EnvironmentValues {
    @Entry var sidebarHasDetailsRoom = true
    @Entry var sidebarClosingLabelWidth: CGFloat? = nil
}

private struct SidebarDetails: ViewModifier {
    @Environment(\.sidebarHasDetailsRoom) private var hasDetailsRoom
    let visible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hasDetailsRoom ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

private extension View {
    func sidebarDetails(_ visible: Bool) -> some View {
        modifier(SidebarDetails(visible: visible))
    }
}

/// One of the app's own places in the source list: icon, label and an optional count.
private struct DestinationRow: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    let title: String
    let identifier: String
    let selection: AppModel.Selection
    let showsLabel: Bool
    var count: Int = 0

    var body: some View {
        let isSelected = model.selection == selection || (selection == .home && model.selection == nil)
        RowButton(selected: isSelected, action: { model.selection = selection }) {
            SidebarRowLabel(showsLabel: showsLabel) {
                SidebarSymbol(name: symbol)
            } label: {
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
        .help(title)
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityIdentifier(identifier)
    }
}

private struct MessagesDestinationRow: View {
    @Environment(AppModel.self) private var model
    let showsLabel: Bool

    var body: some View {
        DestinationRow(
            symbol: Symbol.message, title: "Messages", identifier: "rail.messages", selection: .messages,
            showsLabel: showsLabel, count: model.unreadThreadCount ?? 0
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
            .padding(.horizontal, Space.s2)
            .frame(width: 280, height: Size.controlSmall)
            // Round ends, concentric with the window's corner 10pt away, as toolbar search fields are drawn.
            .background(Capsule().fill(isHovering ? Color.selected : Color.hover))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Search (⌘K)")
        .accessibilityLabel("Search")
        .accessibilityIdentifier("topbar.search")
    }
}
