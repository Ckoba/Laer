import AppKit
import LaerCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything at a glance on a customizable grid: each section scales across grid footprints to
/// reveal progressively richer content and actions, and rearranges smoothly in edit mode.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var events: [CalendarEvent] = []
    @State private var eventsLoaded = false
    @State private var upcomingMemo = Memo<UpcomingKey, UpcomingSections>()
    @State private var lectureMemo = Memo<LectureKey, [UpcomingLecture]>()
    @State private var weekMemo = Memo<TodayKey, [ScheduleDay]>()
    @State private var width: CGFloat = 0
    @State private var isEditingLinks = false
    @State private var isComposingMessage = false
    @State private var isShowingGallery = false
    @State private var layout = HomeLayout.load()
    @State private var isEditing = false
    @State private var lift: HomeLift?
    /// Each tile's frame in the grid, for picking the slot a dragged tile lands in.
    @State private var tileFrames: [HomeBlock: CGRect] = [:]
    @State private var threads = CollectionLoader<MessageThread>(key: "message-threads", coverage: .recentWindow) { client in
        let list = try await client.messageThreads()
        return PagedResult(items: list.threads, isComplete: true)
    }

    private let editUnitHeight: CGFloat = 152

    private var innerWidth: CGFloat { max(width - 2 * Size.contentInset, 1) }

    /// 4 columns on a wide pane, 2 on medium, 1 on narrow.
    private var gridColumns: Int {
        if innerWidth >= 760 { return 4 }
        if innerWidth >= 460 { return 2 }
        return 1
    }

    private var columnSpacing: CGFloat { isEditing ? Space.s16 : Space.s32 }
    private var rowSpacing: CGFloat { isEditing ? Space.s16 : Space.s32 }

    var body: some View {
        let now = Date()
        let days = weekMemo.value(for: TodayKey(events: events, day: Calendar.current.startOfDay(for: now))) {
            WeekSchedule.days(events: events, weekContaining: now, calendar: .current)
        }
        let sections = dueSections()
        let classes = upcomingClasses(now: now, days: days)
        let messages = inboxItems()
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(now: now)
                    homeGrid(now: now, days: days, sections: sections, classes: classes, messages: messages)
                }
                .padding(Size.contentInset)
                .padding(.bottom, Space.s32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.stage
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.45) {
                            guard !isEditing else { return }
                            withMotion(Motion.base, reduceMotion: reduceMotion) { isEditing = true }
                        }
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color.stage)
        .undividedRows()
        .environment(\.homeEditing, isEditing)
        .onChange(of: layout) { _, new in new.save() }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                lift = nil
                isShowingGallery = false
            }
        }
        .onExitCommand {
            if isShowingGallery {
                isShowingGallery = false
            } else if isEditing {
                withMotion(Motion.base, reduceMotion: reduceMotion) { isEditing = false }
            }
        }
        .sheet(isPresented: $isComposingMessage) {
            NewMessageView(onClose: { isComposingMessage = false }) { threadId in
                isComposingMessage = false
                await threads.refresh(using: model)
                await model.refreshUnreadThreadCount()
                navigation.selectedThread = threadId
                model.selection = .messages
            }
            .environment(model)
            .environment(navigation)
            .frame(minWidth: 520, minHeight: 380)
        }
        .navigationTitle("Home")
        .task { await load() }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await load(force: true) })
    }

    private func load(force: Bool = false) async {
        if ParityGate.personalCalendar, !eventsLoaded {
            let cached = await model.cachedEvents(weekContaining: Date())
            if !cached.isEmpty {
                events = cached
                eventsLoaded = true
            }
        }
        async let week: [CalendarEvent] = ParityGate.personalCalendar ? model.events(weekContaining: Date()) : []
        async let exams: Void = model.loadExamPlan(force: force)
        await model.loadTasks()
        if ParityGate.messages {
            async let unread: Void = model.refreshUnreadThreadCount()
            if force { await threads.refresh(using: model) } else { await threads.load(using: model) }
            await unread
        }
        await withTaskGroup(of: Void.self) { group in
            for course in model.activeCourses.prefix(16) {
                let id = course.courseId
                group.addTask { await model.loadPlans(courseId: id) }
            }
        }
        await model.loadActiveUpdates()
        events = await week
        eventsLoaded = true
        await exams
    }

    // MARK: Grid

    /// Sections that can appear on Home for this account.
    private var availableBlocks: [HomeBlock] {
        HomeBlock.allCases.filter { block in
            switch block {
            case .schedule: ParityGate.personalCalendar
            case .messages: ParityGate.messages
            case .exams: model.examPlanAddress != nil
            default: true
            }
        }
    }

    private func hasContent(
        _ block: HomeBlock, now: Date, sections: UpcomingSections, classes: [ScheduleBlock], messages: [InboxItem]
    ) -> Bool {
        switch block {
        case .due: !(isSignedOut && Self.dueItems(sections).isEmpty)
        case .schedule: !(isSignedOut && classes.isEmpty)
        case .messages: !(isSignedOut && messages.isEmpty)
        case .updates: !model.recentAnnouncements(limit: 1).isEmpty
        case .plans: !isSignedOut || !model.upcomingLectures(limit: 1, now: now).isEmpty
        case .exams:
            model.examPlan.phase == .loading || !model.examPlan.matches.isEmpty
                || { if case .failed = model.examPlan.phase { true } else { false } }()
        }
    }

    @ViewBuilder
    private func homeGrid(
        now: Date, days: [ScheduleDay], sections: UpcomingSections, classes: [ScheduleBlock], messages: [InboxItem]
    ) -> some View {
        let available = availableBlocks
        let visibleItems = layout.items.filter { item in
            available.contains(item.block)
                && (isEditing || hasContent(item.block, now: now, sections: sections, classes: classes, messages: messages))
        }
        let placements = HomeLayout.arrange(lift?.preview ?? visibleItems, columns: gridColumns)
        let hidden = layout.hidden(among: available)

        VStack(alignment: .leading, spacing: Space.s24) {
            HomeGridLayout(
                columns: gridColumns,
                columnSpacing: columnSpacing,
                rowSpacing: rowSpacing,
                minRowHeight: isEditing ? editUnitHeight : 0
            ) {
                ForEach(placements) { placement in
                    let block = placement.item.block
                    HomeTileChrome(
                        placement: placement,
                        isEditing: isEditing,
                        isLifted: lift?.block == block,
                        isResizing: lift?.block == block && lift?.kind == .resize,
                        gridColumns: gridColumns,
                        onRemove: {
                            withMotion(Motion.base, reduceMotion: reduceMotion) {
                                layout.update(with: HomeLayout.pinned(visibleItems, columns: gridColumns))
                                layout.remove(block)
                            }
                        },
                        onSetSize: { size in setSize(size, of: block, visible: visibleItems) },
                        onMoveChanged: { value in moveChanged(block, value, visible: visibleItems) },
                        onResizeChanged: { value in resizeChanged(block, value, visible: visibleItems) },
                        onEnded: { value in liftEnded(value, visible: visibleItems) },
                        onReset: { liftReset(block) }
                    ) {
                        sectionContent(
                            for: placement, now: now, days: days,
                            sections: sections, classes: classes, messages: messages
                        )
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("homeGrid")) } action: {
                        tileFrames[block] = $0
                    }
                    .layoutValue(key: HomePlacementKey.self, value: placement)
                }
            }
            .coordinateSpace(name: "homeGrid")
            .overlay(alignment: .topLeading) {
                if let lift, let placement = placements.first(where: { $0.item.block == lift.block }) {
                    // The held tile itself, drawn live above the grid rather than as a snapshot.
                    let frame = liftFrame(lift)
                    HomeTileFace(isLifted: !lift.isSettling) {
                        sectionContent(
                            for: placement, now: now, days: days,
                            sections: sections, classes: classes, messages: messages
                        )
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if lift.kind == .resize {
                            CornerArcShape(radius: Radius.m)
                                .stroke(Color.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 14, height: 14)
                                .padding(Space.s6)
                        }
                    }
                    .scaleEffect(lift.kind == .move && !lift.isSettling ? 1.03 : 1)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
                    .transaction { if !lift.isSettling { $0.animation = nil } }
                }
            }
            // Only edits animate; arriving, resizing the window and data loading place tiles at once.
            .motion(Motion.base, value: isEditing ? placements : nil)

            if isEditing, !hidden.isEmpty {
                addSectionBar(hidden: hidden)
            }
        }
    }

    // MARK: Moving and resizing

    private var columnWidth: CGFloat {
        let cols = CGFloat(max(1, gridColumns))
        return max((innerWidth - (cols - 1) * columnSpacing) / cols, 1)
    }

    /// Starts a lift on the first movement, from where the tile is shown now.
    private func beginLift(_ kind: HomeLift.Kind, _ block: HomeBlock, _ value: DragGesture.Value, visible: [HomeLayout.Item]) -> HomeLift? {
        if let lift {
            if lift.isSettling { return nil }
            // The same drag continues; anything else means the last drag never reported its end.
            if lift.block == block, lift.kind == kind, lift.startLocation == value.startLocation { return lift }
        }
        guard let frame = tileFrames[block] else { return nil }
        let start = HomeLayout.pinned(visible, columns: gridColumns)
        var rowTops: [Int: CGFloat] = [:]
        for placement in HomeLayout.arrange(start, columns: gridColumns) {
            guard let tile = tileFrames[placement.item.block] else { continue }
            rowTops[placement.row] = min(rowTops[placement.row] ?? .infinity, tile.minY)
        }
        let session = HomeLift(
            kind: kind, block: block, start: start, startFrame: frame, rowTops: rowTops,
            grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY),
            startLocation: value.startLocation, pointer: value.location, translation: value.translation,
            preview: start
        )
        lift = session
        return session
    }

    /// The top of grid row `row` as the tiles stood when the lift began.
    private func top(of row: Int, in lift: HomeLift) -> CGFloat {
        let step = editUnitHeight + rowSpacing
        if let y = lift.rowTops[row] { return y }
        if let known = lift.rowTops.keys.filter({ $0 < row }).max(), let y = lift.rowTops[known] {
            return y + CGFloat(row - known) * step
        }
        return CGFloat(row) * step
    }

    /// Where the held tile is drawn: under the pointer when moving, its corner on the pointer when
    /// resizing, always within the grid's width so the pane's edges never cut it off.
    private func liftFrame(_ lift: HomeLift) -> CGRect {
        if let settle = lift.settleFrame { return settle }
        let start = lift.startFrame
        switch lift.kind {
        case .move:
            let x = lift.pointer.x - lift.grab.width
            let y = lift.pointer.y - lift.grab.height
            return CGRect(
                x: min(max(x, 0), max(innerWidth - start.width, 0)), y: max(y, -Space.s16),
                width: start.width, height: start.height
            )
        case .resize:
            let width = min(max(start.width + lift.translation.width, columnWidth * 0.75), innerWidth)
            let height = max(start.height + lift.translation.height, editUnitHeight * 0.6)
            return CGRect(x: min(start.minX, innerWidth - width), y: start.minY, width: width, height: height)
        }
    }

    private func moveChanged(_ block: HomeBlock, _ value: DragGesture.Value, visible: [HomeLayout.Item]) {
        let cols = max(1, gridColumns)
        guard var session = beginLift(.move, block, value, visible: visible) else { return }
        let startPlacements = HomeLayout.arrange(session.start, columns: cols)
        guard let startPlacement = startPlacements.first(where: { $0.item.block == block }) else { return }
        session.pointer = value.location
        let frame = liftFrame(session)
        let column = min(max(Int((frame.minX / (columnWidth + columnSpacing)).rounded()), 0), cols - startPlacement.columnSpan)
        let lastRow = startPlacements.map { $0.row + $0.rowSpan }.max() ?? 0
        let row = (0...lastRow).min { abs(top(of: $0, in: session) - frame.minY) < abs(top(of: $1, in: session) - frame.minY) } ?? 0
        let preview = HomeLayout.placing(
            block, at: HomeGridCell(column: column, row: row), size: nil, in: session.start, columns: cols
        )
        update(session, preview: preview)
    }

    private func resizeChanged(_ block: HomeBlock, _ value: DragGesture.Value, visible: [HomeLayout.Item]) {
        guard var session = beginLift(.resize, block, value, visible: visible) else { return }
        session.translation = value.translation
        let frame = liftFrame(session)
        let size = block.snapSize(
            targetColumns: Double((frame.width + columnSpacing) / (columnWidth + columnSpacing)),
            targetRows: Double((frame.height + rowSpacing) / (editUnitHeight + rowSpacing)),
            maxColumns: gridColumns
        )
        let preview = HomeLayout.placing(block, at: nil, size: size, in: session.start, columns: gridColumns)
        update(session, preview: preview)
    }

    /// The held tile follows at once; the others glide when the spot it would land in changes.
    private func update(_ session: HomeLift, preview: [HomeLayout.Item]) {
        var session = session
        if preview == session.preview {
            lift = session
        } else {
            session.preview = preview
            withMotion(Motion.base, reduceMotion: reduceMotion) { lift = session }
        }
    }

    /// Saves where the tile landed and lets it settle into its slot. A click on the corner steps
    /// to the next size.
    private func liftEnded(_ value: DragGesture.Value, visible: [HomeLayout.Item]) {
        guard var session = lift, !session.isSettling else { return }
        if session.kind == .resize, hypot(value.translation.width, value.translation.height) < 4 {
            lift = nil
            if let item = visible.first(where: { $0.block == session.block }) {
                setSize(session.block.nextSize(after: item.size, maxColumns: gridColumns), of: session.block, visible: visible)
            }
            return
        }
        let edited = session.preview
        guard !reduceMotion, let slot = tileFrames[session.block] else {
            layout.update(with: edited)
            lift = nil
            return
        }
        session.settleFrame = slot
        withAnimation(Motion.base) {
            lift = session
            layout.update(with: edited)
        } completion: {
            if lift?.isSettling == true { lift = nil }
        }
    }

    /// A drag SwiftUI cancelled without reporting its end puts the tile back where it was.
    private func liftReset(_ block: HomeBlock) {
        if let lift, lift.block == block, !lift.isSettling { self.lift = nil }
    }

    private func setSize(_ size: HomeTileSize, of block: HomeBlock, visible: [HomeLayout.Item]) {
        withMotion(Motion.base, reduceMotion: reduceMotion) {
            layout.update(with: HomeLayout.placing(block, at: nil, size: size, in: visible, columns: gridColumns))
        }
    }

    @ViewBuilder
    private func sectionContent(
        for placement: HomeGridPlacement,
        now: Date,
        days: [ScheduleDay],
        sections: UpcomingSections,
        classes: [ScheduleBlock],
        messages: [InboxItem]
    ) -> some View {
        let size = placement.item.size
        let spanW = placement.columnSpan
        switch placement.item.block {
        case .due:
            due(now: now, sections: sections, size: size, effectiveColumns: spanW)
        case .schedule:
            schedule(now: now, days: days, classes: classes, size: size, effectiveColumns: spanW)
        case .updates:
            courseNews(size: size, effectiveColumns: spanW)
        case .messages:
            inbox(messages, size: size, effectiveColumns: spanW)
        case .plans:
            upNext(now: now, size: size, effectiveColumns: spanW)
        case .exams:
            examRows(size: size, effectiveColumns: spanW)
        }
    }

    private func addSectionBar(hidden: [HomeBlock]) -> some View {
        HStack {
            Spacer(minLength: 0)
            AddSectionButton(isPresented: $isShowingGallery, hidden: hidden) { block in
                withMotion(Motion.base, reduceMotion: reduceMotion) { layout.add(block) }
                if layout.hidden(among: availableBlocks).isEmpty { isShowingGallery = false }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Space.s8)
    }

    private func header(now: Date) -> some View {
        PageHeader(title: now.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
            HStack(spacing: Space.s16) {
                editButton
                if !isEditing { linkStrip }
            }
        }
    }

    private var editButton: some View {
        Button {
            withMotion(Motion.base, reduceMotion: reduceMotion) { isEditing.toggle() }
        } label: {
            Text(isEditing ? "Done" : "Edit")
                .font(isEditing ? Type.t13.weight(.semibold) : Type.t13)
                .foregroundStyle(isEditing ? Color.accent : Color.textMuted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .keyboardShortcut(isEditing ? .defaultAction : nil)
        .accessibilityIdentifier("home.edit")
    }

    private static func dueItems(_ sections: UpcomingSections) -> [StudyTask] {
        sections.overdue + sections.today + sections.thisWeek
    }

    /// The person's own links, such as exam, mail and sign-in sites, in one labelled menu.
    private var linkStrip: some View {
        Group {
            if model.studyLinks.isEmpty {
                LinkChip(title: "Add links", symbol: Symbol.edit) { isEditingLinks = true }
            } else {
                Menu {
                    ForEach(model.studyLinks) { link in
                        Button { model.open(link) } label: { Label(link.title, systemImage: link.icon) }
                    }
                    Divider()
                    Button { isEditingLinks = true } label: { Label("Edit links…", systemImage: Symbol.edit) }
                } label: {
                    HStack(spacing: Space.s4) {
                        Image(systemName: Symbol.website)
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("School links")
                            .font(Type.t13)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.textMuted)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(Color.textMuted)
                .fixedSize()
                .padding(.trailing, -4)
                .help("Your school's links")
                .accessibilityLabel("School links")
            }
        }
        .popover(isPresented: $isEditingLinks, arrowEdge: .bottom) {
            LinksEditor().environment(model)
        }
    }

    // MARK: - Schedule

    private func isTimed(_ block: ScheduleBlock) -> Bool {
        block.end.timeIntervalSince(block.start) < 23 * 3600
    }

    /// Classes still to come this week, soonest first. All-day entries are not classes.
    private func upcomingClasses(now: Date, days: [ScheduleDay]) -> [ScheduleBlock] {
        days.flatMap(\.blocks)
            .filter { isTimed($0) && $0.end > now }
            .sorted { $0.start < $1.start }
    }

    private func course(of block: ScheduleBlock) -> Course? {
        if let id = block.event.courseId, let match = model.courses.first(where: { $0.courseId == id }) {
            return match
        }
        let names = [block.event.title, block.event.displayLocation].compactMap { $0 }.map(Course.shortName)
        return model.courses.first { names.contains($0.shortTitle) }
    }

    private func classTitle(for block: ScheduleBlock) -> String {
        course(of: block)?.shortTitle
            ?? block.event.title.map(Course.shortName).flatMap(\.nonEmpty)
            ?? String(localized: "Untitled event")
    }

    private func classRoom(for block: ScheduleBlock) -> String? {
        guard let room = block.event.displayLocation, !room.isEmpty else { return nil }
        let title = classTitle(for: block)
        return Course.shortName(room) == title ? nil : room
    }

    private func matchingPlan(for block: ScheduleBlock) -> (plan: PlanPreview, courseId: Int)? {
        guard let courseId = block.event.courseId ?? course(of: block)?.courseId,
              let plan = model.plan(for: block.event, courseId: courseId) else { return nil }
        return (plan, courseId)
    }

    @ViewBuilder
    private func schedule(
        now: Date, days: [ScheduleDay], classes: [ScheduleBlock], size: HomeTileSize, effectiveColumns: Int
    ) -> some View {
        if ParityGate.personalCalendar, !(isSignedOut && classes.isEmpty) {
            let showAction = size != .s1x1
            HomeSection(
                title: "Schedule",
                action: showAction ? ("Open calendar", { model.selection = .calendar }) : nil
            ) {
                switch size {
                case .s1x1:
                    scheduleNextClass(now: now, classes: classes)
                case .s2x1:
                    scheduleCompactList(now: now, classes: classes)
                case .s2x2:
                    scheduleDetailedList(now: now, classes: classes)
                default:
                    if effectiveColumns >= 3 {
                        scheduleWeekStrip(now: now, days: days)
                    } else if effectiveColumns == 2 {
                        scheduleTwoDayStrip(now: now, days: days)
                    } else {
                        scheduleDetailedList(now: now, classes: classes)
                    }
                }
            }
        }
    }

    /// 1×1: focus on the single next (or current) class.
    @ViewBuilder
    private func scheduleNextClass(now: Date, classes: [ScheduleBlock]) -> some View {
        let calendar = Calendar.current
        if let next = classes.first(where: { calendar.isDateInToday($0.start) || calendar.isDateInTomorrow($0.start) }) {
            let courseId = next.event.courseId ?? course(of: next)?.courseId
            let room = classRoom(for: next)
            let isToday = calendar.isDateInToday(next.start)
            RowButton(action: { openClass(next.event) }) {
                VStack(alignment: .leading, spacing: Space.s4) {
                    HStack(spacing: Space.s6) {
                        if let courseId { CourseDot(courseId: courseId) }
                        Text(classTitle(for: next))
                            .font(Type.t13)
                            .foregroundStyle(Color.text)
                            .lineLimit(2)
                    }
                    Text(isToday
                         ? classTimeRange(next, now: now)
                         : "\(Self.dayWord.string(from: next.start)) · \(StudyDates.time(next.start))")
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                    if let room {
                        Text(room)
                            .font(Type.t12)
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, -Space.s8)
            .accessibilityElement(children: .combine)
        } else if eventsLoaded {
            HomeEmpty("No more classes")
        } else {
            Spinner()
        }
    }

    /// 2×1: compact single-line rows for today and tomorrow's next classes.
    @ViewBuilder
    private func scheduleCompactList(now: Date, classes: [ScheduleBlock]) -> some View {
        let calendar = Calendar.current
        let coming = Array(classes
            .filter { calendar.isDateInToday($0.start) || calendar.isDateInTomorrow($0.start) }
            .prefix(3))
        let times = coming.map { classTime($0, now: now) }
        if coming.isEmpty {
            if eventsLoaded { HomeEmpty("No more classes today or tomorrow") } else { Spinner() }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(coming) { block in
                    let courseId = block.event.courseId ?? course(of: block)?.courseId
                    let room = classRoom(for: block)
                    RowButton(action: { openClass(block.event) }) {
                        HStack(spacing: Space.s6) {
                            timeColumn(classTime(block, now: now), among: times)
                                .font(Type.t12)
                                .padding(.trailing, Space.s4)
                            if let courseId { CourseDot(courseId: courseId) }
                            Text(classTitle(for: block))
                                .font(Type.t13)
                                .foregroundStyle(Color.text)
                                .lineLimit(1)
                            Spacer(minLength: Space.s8)
                            if let room {
                                Text(room)
                                    .font(Type.t12)
                                    .foregroundStyle(Color.textMuted)
                                    .lineLimit(1)
                            } else if !calendar.isDateInToday(block.start) {
                                Text(Self.dayWord.string(from: block.start))
                                    .font(Type.t12)
                                    .foregroundStyle(Color.textMuted)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .environment(\.rowsCompact, true)
            .padding(.horizontal, -Space.s8)
        }
    }

    /// 2×2: today's and tomorrow's classes with full time ranges, rooms, and the plan each covers.
    @ViewBuilder
    private func scheduleDetailedList(now: Date, classes: [ScheduleBlock]) -> some View {
        let calendar = Calendar.current
        let coming = Array(classes
            .filter { calendar.isDateInToday($0.start) || calendar.isDateInTomorrow($0.start) }
            .prefix(5))
        let groupedDays = Dictionary(grouping: coming) { calendar.startOfDay(for: $0.start) }.keys.sorted()
        let ranges = coming.map { classTimeRange($0, now: now) }

        if coming.isEmpty {
            if eventsLoaded { HomeEmpty("No more classes today or tomorrow") } else { Spinner() }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groupedDays, id: \.self) { day in
                    if !calendar.isDateInToday(day) {
                        Text(Self.dayWord.string(from: day))
                            .font(Type.t12)
                            .foregroundStyle(Color.textMuted)
                            .padding(.horizontal, Space.s8)
                            .padding(.top, day == groupedDays.first ? 0 : Space.s8)
                            .padding(.bottom, Space.s2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(coming.filter { calendar.isDate($0.start, inSameDayAs: day) }) { block in
                        scheduleDetailedRow(block, now: now, ranges: ranges)
                    }
                }
            }
            .environment(\.rowsCompact, true)
            .padding(.horizontal, -Space.s8)
        }
    }

    private func scheduleDetailedRow(_ block: ScheduleBlock, now: Date, ranges: [String]) -> some View {
        let courseId = block.event.courseId ?? course(of: block)?.courseId
        let room = classRoom(for: block)
        let match = matchingPlan(for: block)
        return VStack(alignment: .leading, spacing: 0) {
            RowButton(action: {
                if let match {
                    navigation.open(match.plan, courseId: match.courseId)
                } else {
                    openClass(block.event)
                }
            }) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                    timeColumn(classTimeRange(block, now: now), among: ranges)
                        .font(Type.t12)
                    VStack(alignment: .leading, spacing: Space.s2) {
                        HStack(spacing: Space.s6) {
                            if let courseId { CourseDot(courseId: courseId) }
                            Text(classTitle(for: block))
                                .font(Type.t13)
                                .foregroundStyle(Color.text)
                                .lineLimit(1)
                            Spacer(minLength: Space.s4)
                            if let room {
                                Text(room)
                                    .font(Type.t12)
                                    .foregroundStyle(Color.textMuted)
                                    .lineLimit(1)
                            }
                        }
                        if let planName = match?.plan.name?.nonEmpty {
                            HStack(spacing: Space.s4) {
                                Image(systemName: Symbol.plan)
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundStyle(Color.textMuted)
                                    .accessibilityHidden(true)
                                Text(planName)
                                    .font(Type.t12)
                                    .foregroundStyle(Color.textMuted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 4×2: working-week strip with one column per day and course-coloured schedule blocks.
    @ViewBuilder
    private func scheduleWeekStrip(now: Date, days: [ScheduleDay]) -> some View {
        let calendar = Calendar.current
        let visible = days.filter { day in
            !calendar.isDateInWeekend(day.date) || !day.blocks.filter(isTimed).isEmpty
        }
        if !eventsLoaded && visible.flatMap(\.blocks).isEmpty {
            Spinner()
        } else if visible.isEmpty {
            HomeEmpty("No classes this week")
        } else {
            HStack(alignment: .top, spacing: Space.s12) {
                ForEach(visible) { day in
                    scheduleDayColumn(day: day, now: now, showPlans: calendar.isDateInToday(day.date))
                }
            }
        }
    }

    /// Medium-pane fallback for 4×2 Schedule: Today + Tomorrow side-by-side columns.
    @ViewBuilder
    private func scheduleTwoDayStrip(now: Date, days: [ScheduleDay]) -> some View {
        let calendar = Calendar.current
        let pair = days.filter { calendar.isDateInToday($0.date) || calendar.isDateInTomorrow($0.date) }
        if pair.isEmpty {
            scheduleDetailedList(now: now, classes: upcomingClasses(now: now, days: days))
        } else {
            HStack(alignment: .top, spacing: Space.s16) {
                ForEach(pair) { day in
                    scheduleDayColumn(day: day, now: now, showPlans: true)
                }
            }
        }
    }

    private func scheduleDayColumn(day: ScheduleDay, now: Date, showPlans: Bool) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day.date)
        let timed = day.blocks.filter(isTimed)
        return VStack(alignment: .leading, spacing: Space.s6) {
            HStack(spacing: Space.s4) {
                Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(Type.t12)
                    .foregroundStyle(isToday ? Color.text : Color.textMuted)
                    .lineLimit(1)
                Text(day.date.formatted(.dateTime.day()))
                    .font(isToday ? Type.t12.weight(.semibold) : Type.t12)
                    .foregroundStyle(isToday ? Color.onAccent : Color.textMuted)
                    .monospacedDigit()
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Circle().fill(isToday ? Color.accentFill : Color.clear))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Rectangle().fill(Color.border).frame(height: 1).accessibilityHidden(true)

            if timed.isEmpty {
                Spacer(minLength: Space.s12)
            } else {
                VStack(alignment: .leading, spacing: Space.s6) {
                    ForEach(timed) { block in
                        scheduleStripBlock(block, now: now, showPlan: showPlans)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func scheduleStripBlock(_ block: ScheduleBlock, now: Date, showPlan: Bool) -> some View {
        let courseId = block.event.courseId ?? course(of: block)?.courseId
        let tint = courseId.map(Color.course)
        let room = classRoom(for: block)
        let match = showPlan ? matchingPlan(for: block) : nil
        let isPast = block.end < now
        let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)

        return Button {
            if let match {
                navigation.open(match.plan, courseId: match.courseId)
            } else {
                openClass(block.event)
            }
        } label: {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(classTimeRange(block, now: now))
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(classTitle(for: block))
                    .font(Type.t12.weight(.semibold))
                    .foregroundStyle(isPast ? Color.textMuted : Color.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let room {
                    Text(room)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
                if let planName = match?.plan.name?.nonEmpty {
                    Text(planName)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(.leading, Space.s6 + (tint == nil ? 0 : 4))
            .padding(.trailing, Space.s6)
            .padding(.vertical, Space.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(alignment: .leading) {
                if let tint {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tint.opacity(isPast ? 0.45 : 1))
                        .frame(width: 3)
                        .padding(.vertical, Space.s4)
                        .padding(.leading, Space.s2)
                }
            }
            .background(shape.fill(tint.map { $0.opacity(isPast ? 0.06 : 0.12) } ?? Color.accentTint))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
    }

    private func classTime(_ block: ScheduleBlock, now: Date) -> String {
        block.start <= now ? String(localized: "Now") : StudyDates.time(block.start)
    }

    private func classTimeRange(_ block: ScheduleBlock, now: Date) -> String {
        if block.start <= now, block.end > now {
            return "\(String(localized: "Now"))–\(StudyDates.time(block.end))"
        }
        return block.end > block.start ? StudyDates.timeRange(block.start, block.end) : StudyDates.time(block.start)
    }

    private static let dayWord: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    private var isSignedOut: Bool { model.sessionNotice != nil }

    private func timeColumn(_ time: String, among times: [String]) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Array(times.enumerated()), id: \.offset) { _, other in
                Text(other).hidden()
            }
            Text(time)
        }
        .foregroundStyle(Color.textMuted)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(1)
    }

    // MARK: - Next plan

    @ViewBuilder
    private func upNext(now: Date, size: HomeTileSize, effectiveColumns: Int) -> some View {
        let courses = model.activeCourses
        let plans = courses.map { model.plans[$0.courseId] ?? [] }
        let lectures = lectureMemo.value(for: LectureKey(courses: courses, plans: plans, minute: currentMinute())) {
            model.upcomingLectures(limit: 24, now: now)
        }
        let weekEnd = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.end ?? now
        let rest = Array(lectures.dropFirst())
        let thisWeek = rest.filter { ($0.start ?? .distantFuture) < weekEnd }

        if !(isSignedOut && lectures.isEmpty) {
            HomeSection(title: "Next plan") {
                if let first = lectures.first {
                    switch size {
                    case .s1x1:
                        upNextCompact(first, now: now)
                    case .s2x1:
                        UpNextCard(
                            lecture: first,
                            topic: PlanTopics.displayName(of: first.plan, topics: model.topics[first.course.courseId] ?? []),
                            note: nil,
                            readingLimit: 2,
                            now: now,
                            openLecture: { openPlan(first) },
                            openReading: { openReading($0, courseId: first.course.courseId) }
                        )
                    case .s2x2:
                        VStack(alignment: .leading, spacing: 0) {
                            UpNextCard(
                                lecture: first,
                                topic: PlanTopics.displayName(of: first.plan, topics: model.topics[first.course.courseId] ?? []),
                                note: model.lectureNote(for: first.plan, course: first.course),
                                readingLimit: 3,
                                now: now,
                                openLecture: { openPlan(first) },
                                openReading: { openReading($0, courseId: first.course.courseId) }
                            )
                            if !thisWeek.isEmpty {
                                HomeList {
                                    ForEach(thisWeek.prefix(3)) { entry in
                                        lectureRow(entry, label: planWhenLabel(entry, now: now))
                                    }
                                }
                                .padding(.top, Space.s8)
                            }
                        }
                    default:
                        let secondary = thisWeek.isEmpty ? Array(rest.prefix(3)) : Array(thisWeek.prefix(3))
                        if effectiveColumns >= 2, !secondary.isEmpty {
                            HStack(alignment: .top, spacing: Space.s24) {
                                UpNextCard(
                                    lecture: first,
                                    topic: PlanTopics.displayName(of: first.plan, topics: model.topics[first.course.courseId] ?? []),
                                    note: model.lectureNote(for: first.plan, course: first.course),
                                    readingLimit: 5,
                                    now: now,
                                    openLecture: { openPlan(first) },
                                    openReading: { openReading($0, courseId: first.course.courseId) }
                                )
                                .frame(maxWidth: .infinity, alignment: .topLeading)

                                VStack(alignment: .leading, spacing: Space.s12) {
                                    ForEach(secondary) { entry in
                                        UpNextCard(
                                            lecture: entry,
                                            topic: PlanTopics.displayName(of: entry.plan, topics: model.topics[entry.course.courseId] ?? []),
                                            note: model.lectureNote(for: entry.plan, course: entry.course),
                                            readingLimit: 2,
                                            now: now,
                                            openLecture: { openPlan(entry) },
                                            openReading: { openReading($0, courseId: entry.course.courseId) }
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else {
                            UpNextCard(
                                lecture: first,
                                topic: PlanTopics.displayName(of: first.plan, topics: model.topics[first.course.courseId] ?? []),
                                note: model.lectureNote(for: first.plan, course: first.course),
                                readingLimit: 5,
                                now: now,
                                openLecture: { openPlan(first) },
                                openReading: { openReading($0, courseId: first.course.courseId) }
                            )
                        }
                    }
                } else {
                    HomeEmpty(model.activeCourses.isEmpty ? "No active courses" : "No upcoming plans")
                }
            }
        }
    }

    /// 1×1: title, course, and when only.
    private func upNextCompact(_ lecture: UpcomingLecture, now: Date) -> some View {
        RowButton(action: { openPlan(lecture) }) {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(lecture.plan.name ?? "Untitled plan")
                    .font(Type.t13.weight(.semibold))
                    .foregroundStyle(Color.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: Space.s6) {
                    CourseDot(courseId: lecture.course.courseId)
                    Text(lecture.course.shortTitle)
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
                if let when = planWhenLabel(lecture, now: now) {
                    Text(when)
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, -Space.s8)
        .accessibilityElement(children: .combine)
    }

    private func planWhenLabel(_ lecture: UpcomingLecture, now: Date) -> String? {
        guard let start = lecture.start else { return nil }
        if start > now { return StudyDates.relative(start, now: now) }
        let stop = StudyDates.usable(lecture.plan.stop)
        if let stop, stop < now { return String(localized: "Ended") }
        if let stop, stop.timeIntervalSince(start) <= 24 * 3600 { return String(localized: "Now") }
        return String(localized: "This week")
    }

    private func lectureRow(_ entry: UpcomingLecture, label: String?) -> some View {
        ListRow(
            title: entry.plan.name ?? "Untitled plan",
            subtitle: entry.course.shortTitle,
            subtitleDot: Color.course(entry.course.courseId),
            action: { openPlan(entry) },
            meta: { RowTrailing(date: label) }
        )
    }

    private func openPlan(_ lecture: UpcomingLecture) {
        navigation.open(lecture.plan, courseId: lecture.course.courseId)
    }

    // MARK: - Messages

    private var unreadCount: Int {
        guard ParityGate.messages else { return 0 }
        return model.unreadThreadCount ?? threads.records.filter(\.hasUnread).count
    }

    @ViewBuilder
    private func inbox(_ items: [InboxItem], size: HomeTileSize, effectiveColumns: Int) -> some View {
        if !(isSignedOut && items.isEmpty) {
            let showsCompose = (size == .s2x2 || size == .s4x2) && ParityGate.writes
            let showsOpenLink = size != .s1x1 && ParityGate.messages
            HomeSection(
                title: "Messages",
                count: items.isEmpty ? nil : unreadCount,
                trailing: {
                    HStack(spacing: Space.s12) {
                        if showsCompose {
                            Button {
                                isComposingMessage = true
                            } label: {
                                HStack(spacing: Space.s4) {
                                    Image(systemName: Symbol.compose)
                                        .font(.system(size: 11, weight: .regular))
                                        .accessibilityHidden(true)
                                    Text("New message")
                                        .font(Type.t12)
                                        .lineLimit(1)
                                }
                                .foregroundStyle(Color.accent)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help("New message")
                            .accessibilityLabel("New message")
                        }
                        if showsOpenLink {
                            SectionLink("Open messages") { model.selection = .messages }
                        }
                    }
                }
            ) {
                if items.isEmpty {
                    HomeEmpty("No recent messages")
                } else {
                    switch size {
                    case .s1x1:
                        inboxSummary(items)
                    case .s2x1:
                        HomeList {
                            ForEach(items.prefix(3)) { item in messageRow(item, previewLines: 1) }
                        }
                    case .s2x2:
                        HomeList {
                            ForEach(items.prefix(5)) { item in messageRow(item, previewLines: 1) }
                        }
                    default:
                        if effectiveColumns >= 2, items.count >= 2 {
                            let unread = items.filter(\.isUnread)
                            let read = items.filter { !$0.isUnread }
                            let split = Self.splitInbox(unread: unread, read: read, all: items)
                            HStack(alignment: .top, spacing: Space.s24) {
                                HomeList {
                                    ForEach(split.0) { item in messageRow(item, previewLines: 2) }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                HomeList {
                                    ForEach(split.1) { item in messageRow(item, previewLines: 2) }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else {
                            HomeList {
                                ForEach(items.prefix(6)) { item in messageRow(item, previewLines: 2) }
                            }
                        }
                    }
                }
            }
        }
    }


    /// 1×1: unread count and latest thread sender.
    private func inboxSummary(_ items: [InboxItem]) -> some View {
        let unread = unreadCount
        let latest = items.first(where: \.isUnread) ?? items.first
        return VStack(alignment: .leading, spacing: Space.s4) {
            RowButton(action: { model.selection = .messages }) {
                HStack(spacing: Space.s6) {
                    Circle()
                        .fill(unread > 0 ? Color.accent : Color.borderStrong)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(unread > 0 ? "\(unread) unread" : "All read")
                        .font(Type.t13)
                        .foregroundStyle(Color.text)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            if let latest {
                RowButton(action: { openThread(latest.threadId) }) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(latest.place)
                            .font(latest.isUnread ? Type.t13.weight(.semibold) : Type.t13)
                            .foregroundStyle(Color.text)
                            .lineLimit(1)
                        if let date = latest.date {
                            Text(StudyDates.relative(date))
                                .font(Type.t12)
                                .foregroundStyle(Color.textMuted)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .environment(\.rowsCompact, true)
        .padding(.horizontal, -Space.s8)
    }

    private func messageRow(_ item: InboxItem, previewLines: Int) -> some View {
        RowButton(action: { openThread(item.threadId) }) {
            HStack(alignment: .center, spacing: Space.s8) {
                Avatar(name: item.senderName, imageURL: item.imageURL, size: 28)
                    .overlay(alignment: .leading) {
                        if item.isUnread {
                            Circle().fill(Color.accent).frame(width: 6, height: 6)
                                .offset(x: -Space.s8 + 1)
                                .accessibilityHidden(true)
                        }
                    }
                HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(item.place)
                            .font(item.isUnread ? Type.t13.weight(.semibold) : Type.t13)
                            .foregroundStyle(Color.text)
                            .lineLimit(1)
                        Text(item.title)
                            .font(Type.t12)
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(previewLines)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    RowTrailing(date: item.date.map { StudyDates.relative($0) })
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isUnread ? "Unread" : "")
    }

    private func openThread(_ threadId: Int) {
        navigation.selectedThread = threadId
        model.selection = .messages
    }

    private func inboxItems() -> [InboxItem] {
        guard ParityGate.messages else { return [] }
        return threads.records.prefix(10).map { thread in
            let preview = RichTextCache.preview(thread.lastMessage?.text ?? "")
            return InboxItem(
                id: "thread-\(thread.threadId)",
                threadId: thread.threadId,
                date: thread.lastMessage?.created,
                title: preview.isEmpty ? (thread.name ?? "Conversation") : preview,
                place: thread.name ?? thread.lastMessage?.createdByName ?? String(localized: "Conversation"),
                senderName: thread.lastMessage?.createdByName ?? thread.name,
                imageURL: thread.lastMessage.flatMap { thread.senderImageURLString(for: $0) },
                isUnread: thread.hasUnread
            )
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: - Updates

    @ViewBuilder
    private func courseNews(size: HomeTileSize, effectiveColumns: Int) -> some View {
        let limit: Int = switch size {
        case .s1x1: 1
        case .s2x1: 3
        case .s2x2: 4
        default: 6
        }
        let items = model.recentAnnouncements(limit: limit)
        if !items.isEmpty || isEditing {
            HomeSection(title: "Updates") {
                if items.isEmpty {
                    HomeEmpty("No recent updates")
                } else {
                    switch size {
                    case .s1x1:
                        if let entry = items.first {
                            RowButton(action: { openCourse(entry.course.courseId, tab: .updates) }) {
                                VStack(alignment: .leading, spacing: Space.s4) {
                                    Text(entry.update.displayText.isEmpty ? String(localized: "Update") : entry.update.displayText)
                                        .font(Type.body)
                                        .foregroundStyle(Color.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    HStack(spacing: Space.s6) {
                                        CourseDot(courseId: entry.course.courseId)
                                        Text(entry.course.shortTitle)
                                            .font(Type.t12)
                                            .foregroundStyle(Color.textMuted)
                                            .lineLimit(1)
                                    }
                                    if let published = entry.update.published {
                                        Text(StudyDates.relative(published))
                                            .font(Type.t12)
                                            .foregroundStyle(Color.textMuted)
                                            .monospacedDigit()
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, -Space.s8)
                            .accessibilityElement(children: .combine)
                        }
                    case .s2x1:
                        // One-line compact headlines.
                        HomeList {
                            ForEach(items, id: \.update.notificationId) { entry in
                                RowButton(action: { openCourse(entry.course.courseId, tab: .updates) }) {
                                    HStack(alignment: .firstTextBaseline, spacing: Space.s6) {
                                        CourseDot(courseId: entry.course.courseId)
                                        Text(entry.update.displayText.isEmpty ? String(localized: "Update") : entry.update.displayText)
                                            .font(Type.body)
                                            .foregroundStyle(Color.text)
                                            .lineLimit(1)
                                        Spacer(minLength: Space.s8)
                                        RowTrailing(date: entry.update.published.map { StudyDates.relative($0) })
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .environment(\.rowsCompact, true)
                    case .s2x2:
                        HomeList {
                            ForEach(items, id: \.update.notificationId) { entry in
                                updateRichRow(entry, bodyLines: 2)
                            }
                        }
                    default:
                        if effectiveColumns >= 2, items.count >= 2 {
                            let mid = (items.count + 1) / 2
                            HStack(alignment: .top, spacing: Space.s24) {
                                HomeList {
                                    ForEach(Array(items.prefix(mid)), id: \.update.notificationId) { entry in
                                        updateRichRow(entry, bodyLines: 3)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                HomeList {
                                    ForEach(Array(items.dropFirst(mid)), id: \.update.notificationId) { entry in
                                        updateRichRow(entry, bodyLines: 3)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else {
                            HomeList {
                                ForEach(items, id: \.update.notificationId) { entry in
                                    updateRichRow(entry, bodyLines: 3)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func updateRichRow(_ entry: (course: Course, update: CourseUpdate), bodyLines: Int) -> some View {
        let subtitle = [entry.course.shortTitle.nonEmpty, entry.update.publishedBy?.fullName?.nonEmpty]
            .compactMap { $0 }
            .joined(separator: " · ")
        return RowButton(action: { openCourse(entry.course.courseId, tab: .updates) }) {
            HStack(alignment: .top, spacing: Space.s8) {
                Avatar(
                    name: entry.update.publishedBy?.fullName,
                    imageURL: entry.update.publishedBy?.imageURLString,
                    size: 28
                )
                .padding(.top, Space.s2)
                HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(entry.update.displayText.isEmpty ? String(localized: "Update") : entry.update.displayText)
                            .font(Type.body)
                            .foregroundStyle(Color.text)
                            .lineLimit(bodyLines)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: Space.s6) {
                            CourseDot(courseId: entry.course.courseId)
                            Text(subtitle)
                                .font(Type.t12)
                                .foregroundStyle(Color.textMuted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    RowTrailing(date: entry.update.published.map { StudyDates.relative($0) })
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Due

    private func dueSections() -> UpcomingSections {
        let activeIds = Set(model.activeCourses.map(\.courseId))
        return upcomingMemo.value(for: UpcomingKey(tasks: model.tasks, activeIds: activeIds, minute: currentMinute())) {
            UpcomingList.sections(model.tasks, activeCourseIds: activeIds, now: currentMinute(), calendar: .current)
        }
    }

    @ViewBuilder
    private func due(now: Date, sections: UpcomingSections, size: HomeTileSize, effectiveColumns: Int) -> some View {
        let items = Self.dueItems(sections)
        if !(isSignedOut && items.isEmpty) {
            HomeSection(
                title: "Due",
                count: items.count,
                action: size != .s1x1 ? ("All assignments", { model.selection = .upcoming }) : nil
            ) {
                if items.isEmpty {
                    EmptyState(state: model.tasksState, empty: "Nothing due in the next 7 days")
                        .padding(.vertical, Space.s6)
                } else {
                    switch size {
                    case .s1x1:
                        dueCounts(sections)
                    case .s2x1:
                        HomeList {
                            ForEach(items.prefix(3)) { task in dueCompactRow(task, now: now) }
                        }
                        .environment(\.rowsCompact, true)
                    case .s2x2:
                        HomeList {
                            ForEach(items.prefix(6)) { task in dueRow(task, now: now) }
                        }
                    default:
                        dueGrouped(now: now, sections: sections, effectiveColumns: effectiveColumns)
                    }
                }
            }
        }
    }

    /// 1×1: calm count breakdown (Overdue, Today, This week).
    private func dueCounts(_ sections: UpcomingSections) -> some View {
        let rows: [(String, Int, Bool)] = [
            (String(localized: "Overdue"), sections.overdue.count, true),
            (String(localized: "Today"), sections.today.count, false),
            (String(localized: "This week"), sections.thisWeek.count, false),
        ].filter { $0.1 > 0 }

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.0) { label, count, critical in
                RowButton(action: { model.selection = .upcoming }) {
                    HStack(spacing: Space.s8) {
                        Text(label)
                            .font(Type.t13)
                            .foregroundStyle(critical ? Color.danger : Color.text)
                            .lineLimit(1)
                        Spacer(minLength: Space.s8)
                        Text(count.formatted())
                            .font(Type.t13.weight(.semibold))
                            .foregroundStyle(critical ? Color.danger : Color.textMuted)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .environment(\.rowsCompact, true)
        .padding(.horizontal, -Space.s8)
    }

    private func dueCompactRow(_ task: StudyTask, now: Date) -> some View {
        let deadline = StudyDates.usable(task.deadline)
        let isOverdue = (deadline ?? .distantFuture) < now
        return RowButton(action: { openTask(task) }) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s6) {
                if let courseId = task.courseId { CourseDot(courseId: courseId) }
                Text(task.title)
                    .font(Type.body)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                Spacer(minLength: Space.s8)
                RowTrailing(date: deadline.map { StudyDates.relative($0, now: now) }, isOverdue: isOverdue)
            }
        }
        .help(StudyDates.deadline(task.deadline))
        .accessibilityElement(children: .combine)
    }

    /// 4×2: grouped into side-by-side columns with explicit submission states.
    @ViewBuilder
    private func dueGrouped(now: Date, sections: UpcomingSections, effectiveColumns: Int) -> some View {
        let rawGroups: [DueGroup] = [
            DueGroup(id: "overdue", title: String(localized: "Overdue"), tasks: sections.overdue, isCritical: true),
            DueGroup(id: "today", title: String(localized: "Today"), tasks: sections.today, isCritical: false),
            DueGroup(id: "week", title: String(localized: "This week"), tasks: sections.thisWeek, isCritical: false),
        ].filter { !$0.tasks.isEmpty }

        if effectiveColumns >= 2, rawGroups.count >= 2 {
            let maxColumns = effectiveColumns >= 3 ? min(rawGroups.count, 3) : 2
            let visibleGroups = Array(rawGroups.prefix(maxColumns))
            HStack(alignment: .top, spacing: Space.s24) {
                ForEach(visibleGroups) { group in
                    dueGroupColumn(group, now: now, limit: 5)
                }
            }
        } else if effectiveColumns >= 2, let single = rawGroups.first, single.tasks.count >= 4 {
            let shown = Array(single.tasks.prefix(8))
            let mid = (shown.count + 1) / 2
            VStack(alignment: .leading, spacing: Space.s6) {
                dueGroupHeader(title: single.title, count: single.tasks.count, isCritical: single.isCritical)
                HStack(alignment: .top, spacing: Space.s24) {
                    HomeList {
                        ForEach(Array(shown.prefix(mid))) { task in dueStateRow(task, now: now) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    HomeList {
                        ForEach(Array(shown.dropFirst(mid))) { task in dueStateRow(task, now: now) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Space.s12) {
                ForEach(rawGroups) { group in
                    dueGroupColumn(group, now: now, limit: 5)
                }
            }
        }
    }

    private func dueGroupColumn(_ group: DueGroup, now: Date, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            dueGroupHeader(title: group.title, count: group.tasks.count, isCritical: group.isCritical)
            HomeList {
                ForEach(group.tasks.prefix(limit)) { task in dueStateRow(task, now: now) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func dueGroupHeader(title: String, count: Int, isCritical: Bool) -> some View {
        HStack(spacing: Space.s4) {
            Text(title)
                .font(Type.t12.weight(.semibold))
                .foregroundStyle(isCritical ? Color.danger : Color.textMuted)
            Text(count.formatted())
                .font(Type.t12)
                .foregroundStyle(isCritical ? Color.danger : Color.textFaint)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func dueRow(_ task: StudyTask, now: Date) -> some View {
        let deadline = StudyDates.usable(task.deadline)
        let isOverdue = (deadline ?? .distantFuture) < now
        let course = model.courses.first(where: { $0.courseId == task.courseId })?.shortTitle ?? task.courseTitle
        return ListRow(
            title: task.title,
            subtitle: StudyDates.taskSubtitle(course: course, status: task.status),
            subtitleDot: task.courseId.map { Color.course($0) },
            action: { openTask(task) },
            meta: { RowTrailing(date: deadline.map { StudyDates.relative($0, now: now) }, isOverdue: isOverdue) }
        )
        .help(StudyDates.deadline(task.deadline))
    }

    /// Due row for the grouped 4×2 view: course on the subtitle line, submission state in `RowTrailing`.
    private func dueStateRow(_ task: StudyTask, now: Date) -> some View {
        let deadline = StudyDates.usable(task.deadline)
        let isOverdue = (deadline ?? .distantFuture) < now
        let course = model.courses.first(where: { $0.courseId == task.courseId })?.shortTitle ?? task.courseTitle
        let statusText = StudyDates.statusText(task.status)
        let statusLabel: StatusLabel? = statusText.map { text in
            StatusLabel(text, tone: text == "Done" || text == "Submitted" ? .positive : .neutral)
        }
        return ListRow(
            title: task.title,
            subtitle: course,
            subtitleDot: task.courseId.map { Color.course($0) },
            action: { openTask(task) },
            meta: {
                RowTrailing(
                    date: deadline.map { StudyDates.relative($0, now: now) },
                    status: statusLabel,
                    isOverdue: isOverdue
                )
            }
        )
        .help(StudyDates.deadline(task.deadline))
    }

    private func openTask(_ task: StudyTask) {
        if task.elementId == nil, let url = model.absoluteURL(task.url) {
            NSWorkspace.shared.open(url)
        } else {
            model.selection = .upcoming
        }
    }

    // MARK: - Exams

    @ViewBuilder
    private func examRows(size: HomeTileSize, effectiveColumns: Int) -> some View {
        let plan = model.examPlan
        let isLoading = plan.phase == .loading && plan.fileURL == nil
        let failure: String? = if case .failed(let message) = plan.phase { message } else { nil }
        if model.examPlanAddress != nil, isEditing || isLoading || failure != nil || !plan.matches.isEmpty {
            HomeSection(
                title: "Exams",
                count: size == .s1x1 ? nil : plan.matches.count,
                action: size != .s1x1 && plan.fileURL != nil ? ("Open exam plan", { model.openExamPlan() }) : nil
            ) {
                if isLoading { Spinner() }
                if let failure { ErrorLine(failure) }
                if plan.matches.isEmpty && !isLoading && failure == nil {
                    HomeEmpty("No courses matched in exam plan")
                } else if !plan.matches.isEmpty {
                    switch size {
                    case .s1x1:
                        examCompactSummary(plan.matches)
                    case .s2x1:
                        HomeList {
                            ForEach(plan.matches.prefix(3)) { match in
                                ListRow(
                                    title: match.courseTitle,
                                    subtitleDot: Color.course(match.courseId),
                                    action: { model.openExamPlan(page: match.pages.first) },
                                    meta: { RowTrailing(date: Self.pagesLabel(match.pages)) }
                                )
                            }
                        }
                    case .s2x2:
                        HomeList {
                            ForEach(plan.matches) { match in examDetailedRow(match) }
                        }
                    default:
                        if effectiveColumns >= 2 {
                            let shown = Array(plan.matches.prefix(effectiveColumns >= 3 ? 4 : 2))
                            HStack(alignment: .top, spacing: Space.s24) {
                                ForEach(shown) { match in
                                    RowButton(action: { model.openExamPlan(page: match.pages.first) }) {
                                        VStack(alignment: .leading, spacing: Space.s4) {
                                            HStack(spacing: Space.s6) {
                                                CourseDot(courseId: match.courseId)
                                                Text(match.courseTitle)
                                                    .font(Type.t13)
                                                    .foregroundStyle(Color.text)
                                                    .lineLimit(2)
                                            }
                                            Text(Self.allPagesLabel(match.pages))
                                                .font(Type.t12)
                                                .foregroundStyle(Color.textMuted)
                                                .monospacedDigit()
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, -Space.s8)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                            }
                        } else {
                            HomeList {
                                ForEach(plan.matches) { match in examDetailedRow(match) }
                            }
                        }
                    }
                }
            }
            .help(plan.fetchedAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "")
        }
    }

    private func examCompactSummary(_ matches: [ExamPlanMatch]) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            RowButton(action: { model.openExamPlan(page: matches.first?.pages.first) }) {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text("\(matches.count) \(matches.count == 1 ? "course" : "courses")")
                        .font(Type.t13)
                        .foregroundStyle(Color.text)
                        .monospacedDigit()
                        .lineLimit(1)
                    if let first = matches.first {
                        HStack(spacing: Space.s6) {
                            CourseDot(courseId: first.courseId)
                            Text(first.courseTitle)
                                .font(Type.t12)
                                .foregroundStyle(Color.textMuted)
                                .lineLimit(1)
                        }
                        Text(Self.pagesLabel(first.pages))
                            .font(Type.t12)
                            .foregroundStyle(Color.textMuted)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, -Space.s8)
        .accessibilityElement(children: .combine)
    }

    private func examDetailedRow(_ match: ExamPlanMatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
            Button { model.openExamPlan(page: match.pages.first) } label: {
                HStack(spacing: Space.s6) {
                    CourseDot(courseId: match.courseId)
                    Text(match.courseTitle)
                        .font(Type.body)
                        .foregroundStyle(Color.text)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Spacer(minLength: Space.s8)

            HStack(spacing: Space.s6) {
                ForEach(match.pages.prefix(4), id: \.self) { page in
                    Button { model.openExamPlan(page: page) } label: {
                        Text("p. \((page + 1).formatted())")
                            .font(Type.t12)
                            .foregroundStyle(Color.textMuted)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel("Open \(match.courseTitle), page \(page + 1)")
                }
                if match.pages.count > 4 {
                    Text("+\(match.pages.count - 4)")
                        .font(Type.t12)
                        .foregroundStyle(Color.textFaint)
                        .monospacedDigit()
                }
            }
        }
        .plainRow()
    }

    private static func pagesLabel(_ pages: [Int]) -> String {
        let shown = pages.map { ($0 + 1).formatted() }
        if shown.count <= 2 { return "p. \(shown.joined(separator: ", "))" }
        return "p. \(shown[0]) +\(shown.count - 1)"
    }

    private static func allPagesLabel(_ pages: [Int]) -> String {
        let shown = pages.prefix(4).map { ($0 + 1).formatted() }
        let suffix = pages.count > 4 ? " +\(pages.count - 4)" : ""
        return "p. \(shown.joined(separator: ", "))\(suffix)"
    }

    /// Unread beside read when there are both; otherwise the list split in half.
    private static func splitInbox(unread: [InboxItem], read: [InboxItem], all: [InboxItem]) -> ([InboxItem], [InboxItem]) {
        if !unread.isEmpty, !read.isEmpty { return (Array(unread.prefix(4)), Array(read.prefix(4))) }
        let shown = Array(all.prefix(8))
        let mid = (shown.count + 1) / 2
        return (Array(shown.prefix(mid)), Array(shown.dropFirst(mid)))
    }

    // MARK: Actions

    /// A class opens the plan covering its time, or the calendar when no plan does.
    private func openClass(_ event: CalendarEvent) {
        Task {
            await model.loadPlansIfNeeded(for: event)
            if let course = event.courseId, let plan = model.plan(for: event, courseId: course) {
                navigation.open(plan, courseId: course)
            } else {
                model.selection = .calendar
            }
        }
    }

    private func openCourse(_ id: Int, tab: CourseTab) {
        navigation.courseTabs[id] = tab
        model.selection = .course(id)
    }

    private func openReading(_ element: PlanPreview.Element, courseId: Int) {
        if element.isResource != false {
            Task { await model.open(element, courseId: courseId) }
        } else if let url = model.absoluteURL(element.url) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Grid Layout Engine

private struct HomePlacementKey: LayoutValueKey {
    static let defaultValue = HomeGridPlacement(
        item: HomeLayout.Item(block: .due), column: 0, row: 0, columnSpan: 1, rowSpan: 1
    )
}

/// Deterministic 2D grid layout for Home tiles. Out of edit mode rows hug their content so no
/// section carries empty dead space; in edit mode `minRowHeight` keeps grid proportions clear.
private struct HomeGridLayout: Layout {
    var columns: Int
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat
    var minRowHeight: CGFloat

    struct Cache {
        var placements: [HomeGridPlacement] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(placements: subviews.map { $0[HomePlacementKey.self] })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.placements = subviews.map { $0[HomePlacementKey.self] }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let metrics = computeMetrics(width: proposal.width ?? 800, subviews: subviews, placements: cache.placements)
        return CGSize(width: metrics.totalWidth, height: metrics.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let metrics = computeMetrics(width: bounds.width, subviews: subviews, placements: cache.placements)
        for (index, subview) in subviews.enumerated() {
            guard index < metrics.frames.count else { continue }
            let frame = metrics.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private struct Metrics {
        var totalWidth: CGFloat
        var totalHeight: CGFloat
        var frames: [CGRect]
    }

    private func computeMetrics(width: CGFloat, subviews: Subviews, placements: [HomeGridPlacement]) -> Metrics {
        let cols = max(1, columns)
        let totalWidth = max(width, 1)
        let colWidth = max((totalWidth - CGFloat(cols - 1) * columnSpacing) / CGFloat(cols), 1)
        let totalRows = placements.map { $0.row + $0.rowSpan }.max() ?? 0
        guard totalRows > 0 else {
            return Metrics(totalWidth: totalWidth, totalHeight: 0, frames: [])
        }

        var rowHeights = Array(repeating: minRowHeight, count: totalRows)
        var measuredHeights: [CGFloat] = []
        measuredHeights.reserveCapacity(subviews.count)

        for (index, subview) in subviews.enumerated() {
            let p = placements[index]
            let tileW = CGFloat(p.columnSpan) * colWidth + CGFloat(max(p.columnSpan - 1, 0)) * columnSpacing
            let h = subview.sizeThatFits(ProposedViewSize(width: tileW, height: nil)).height
            measuredHeights.append(h)
            if p.rowSpan == 1, p.row < totalRows {
                rowHeights[p.row] = max(rowHeights[p.row], h)
            }
        }

        // Expand multi-row spans evenly across their rows when content exceeds current span height.
        let multiRowIndices = placements.indices
            .filter { placements[$0].rowSpan > 1 }
            .sorted { (placements[$0].row + placements[$0].rowSpan) < (placements[$1].row + placements[$1].rowSpan) }

        for index in multiRowIndices {
            let p = placements[index]
            let endRow = min(p.row + p.rowSpan, totalRows)
            guard p.row < endRow else { continue }
            let spanCount = endRow - p.row
            let currentSpan = (p.row..<endRow).reduce(CGFloat(0)) { $0 + rowHeights[$1] }
                + CGFloat(max(spanCount - 1, 0)) * rowSpacing
            let needed = measuredHeights[index]
            if needed > currentSpan {
                let extra = (needed - currentSpan) / CGFloat(spanCount)
                for r in p.row..<endRow { rowHeights[r] += extra }
            }
        }

        // A row no tile reaches keeps its height only in edit mode, where it is somewhere to drop
        // a tile; otherwise it closes up so a gap never leaves a band of blank page.
        var isCovered = Array(repeating: false, count: totalRows)
        for p in placements {
            for r in p.row..<min(p.row + p.rowSpan, totalRows) { isCovered[r] = true }
        }
        var gaps = Array(repeating: rowSpacing, count: totalRows)
        for r in 0..<totalRows where !isCovered[r] && minRowHeight == 0 {
            rowHeights[r] = 0
            gaps[r] = 0
        }
        var rowY = Array(repeating: CGFloat(0), count: totalRows)
        for r in 1..<totalRows {
            rowY[r] = rowY[r - 1] + rowHeights[r - 1] + gaps[r - 1]
        }
        let totalHeight = rowY[totalRows - 1] + rowHeights[totalRows - 1]

        var frames: [CGRect] = []
        frames.reserveCapacity(placements.count)
        for p in placements {
            let endRow = min(p.row + p.rowSpan, totalRows)
            let spanCount = max(endRow - p.row, 1)
            let x = CGFloat(p.column) * (colWidth + columnSpacing)
            let y = p.row < totalRows ? rowY[p.row] : 0
            let w = CGFloat(p.columnSpan) * colWidth + CGFloat(max(p.columnSpan - 1, 0)) * columnSpacing
            let h = (p.row..<endRow).reduce(CGFloat(0)) { $0 + rowHeights[$1] }
                + (p.row..<(endRow - 1)).reduce(CGFloat(0)) { $0 + gaps[$1] }
            frames.append(CGRect(x: x, y: y, width: w, height: h))
        }

        return Metrics(totalWidth: totalWidth, totalHeight: totalHeight, frames: frames)
    }
}

// MARK: - Edit Mode Chrome, Resize Handle & Drag Reorder

/// Wraps one section tile. Out of edit mode it adds no border or fill; in edit mode it draws a
/// concentric tile frame with a top-leading remove control, a body that moves the tile, and a
/// curved bottom-trailing Control Center resize handle.
private struct HomeTileChrome<Content: View>: View {
    let placement: HomeGridPlacement
    let isEditing: Bool
    /// Held under the pointer; its slot shows where it will land.
    let isLifted: Bool
    let isResizing: Bool
    let gridColumns: Int
    let onRemove: () -> Void
    let onSetSize: (HomeTileSize) -> Void
    let onMoveChanged: (DragGesture.Value) -> Void
    let onResizeChanged: (DragGesture.Value) -> Void
    let onEnded: (DragGesture.Value) -> Void
    let onReset: () -> Void
    @ViewBuilder let content: () -> Content

    @GestureState private var isMoving = false

    private var item: HomeLayout.Item { placement.item }

    var body: some View {
        if isEditing {
            let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
            HomeTileFace(content: content)
                .opacity(isLifted ? 0 : 1)
                .overlay {
                    if isLifted {
                        shape.fill(isResizing ? Color.accentTint : Color.clear)
                            .overlay(shape.strokeBorder(
                                isResizing ? Color.accent : Color.borderStrong,
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                            ))
                    }
                }
                .contentShape(shape)
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named("homeGrid"))
                        .updating($isMoving) { _, state, _ in state = true }
                        .onChanged(onMoveChanged)
                        .onEnded(onEnded)
                )
                .onChange(of: isMoving) { _, moving in
                    // After `onEnded` has had its turn, so only a cancelled drag is reset.
                    if !moving { DispatchQueue.main.async { onReset() } }
                }
                // Overlaid outside the drag so removing and corner resizing never move the tile.
                .overlay(alignment: .topLeading) {
                    RemoveTileButton(title: item.block.title, action: onRemove)
                        .offset(x: -7, y: -7)
                        .opacity(isLifted ? 0 : 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    CornerResizeHandle(
                        block: item.block,
                        size: item.size,
                        gridColumns: gridColumns,
                        isResizing: isResizing,
                        onDragChanged: onResizeChanged,
                        onDragEnded: onEnded,
                        onReset: onReset,
                        onStepSize: onSetSize
                    )
                    .opacity(isLifted ? 0 : 1)
                }
        } else {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Top-leading minus badge in edit mode, drawn from design tokens without filled symbol variants.
private struct RemoveTileButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.raised)
                    .overlay(Circle().fill(isHovering ? Color.hover : Color.clear))
                    .overlay(Circle().strokeBorder(Color.borderStrong, lineWidth: 1))
                    .frame(width: 20, height: 20)
                Capsule()
                    .fill(Color.text)
                    .frame(width: 8, height: 1.5)
            }
            .frame(width: Size.controlSmall, height: Size.controlSmall)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .help("Remove \(title)")
        .accessibilityLabel("Remove \(title)")
    }
}

/// Bottom-trailing concentric curved grip modeled on iOS 18 Control Center's corner handle.
private struct CornerResizeHandle: View {
    let block: HomeBlock
    let size: HomeTileSize
    let gridColumns: Int
    let isResizing: Bool
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void
    let onReset: () -> Void
    let onStepSize: (HomeTileSize) -> Void
    @GestureState private var isDragging = false
    @State private var isHovering = false

    var body: some View {
        CornerArcShape(radius: Radius.m)
            .stroke(
                isResizing ? Color.accent : (isHovering ? Color.text : Color.textMuted),
                style: StrokeStyle(lineWidth: isResizing || isHovering ? 3 : 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .padding(Space.s6)
            .frame(width: Size.control, height: Size.control, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("homeGrid"))
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged(onDragChanged)
                    .onEnded(onDragEnded)
            )
            .onChange(of: isDragging) { _, dragging in
                if !dragging { DispatchQueue.main.async { onReset() } }
            }
            .help("Resize \(block.title)")
            .accessibilityElement()
            .accessibilityLabel("Resize \(block.title)")
            .accessibilityValue(size.accessibilityDescription)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onStepSize(block.nextSize(after: size, maxColumns: gridColumns))
                case .decrement:
                    onStepSize(block.previousSize(before: size, maxColumns: gridColumns))
                @unknown default:
                    break
                }
            }
    }
}

/// Quarter-circle arc sitting concentrically inside a bottom-trailing rounded corner.
private struct CornerArcShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height))
        let center = CGPoint(x: rect.maxX - r, y: rect.maxY - r)
        path.addArc(
            center: center,
            radius: r,
            startAngle: .degrees(8),
            endAngle: .degrees(82),
            clockwise: false
        )
        return path
    }
}

/// A tile held under the pointer, being moved or resized, and the arrangement it would land in.
private struct HomeLift: Equatable {
    enum Kind: Equatable { case move, resize }
    var kind: Kind
    var block: HomeBlock
    /// The shown tiles, each pinned to its cell, as they stood when the lift began.
    var start: [HomeLayout.Item]
    var startFrame: CGRect
    var rowTops: [Int: CGFloat]
    /// The pointer's offset from the tile's top-leading corner when it was picked up.
    var grab: CGSize
    var startLocation: CGPoint
    var pointer: CGPoint
    var translation: CGSize
    var preview: [HomeLayout.Item]
    /// Released and gliding into this frame.
    var settleFrame: CGRect?

    var isSettling: Bool { settleFrame != nil }
}

/// A tile as it looks in edit mode, in its slot or lifted under the pointer.
private struct HomeTileFace<Content: View>: View {
    var isLifted = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        content()
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, Space.s16)
            .padding(.vertical, Space.s12)
            .background(shape.fill(Color.stage))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.borderStrong, lineWidth: 1))
            .shadow(color: isLifted ? Color.shadowPopup : .clear, radius: 12, x: 0, y: 8)
    }
}

/// Control Center-style "Add section" button opening a gallery popover of hidden sections.
private struct AddSectionButton: View {
    @Binding var isPresented: Bool
    let hidden: [HomeBlock]
    let onAdd: (HomeBlock) -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: Space.s6) {
                Image(systemName: Symbol.newTab)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Add section")
                    .font(Type.t13)
                    .lineLimit(1)
            }
            .foregroundStyle(isHovering ? Color.text : Color.textMuted)
            .padding(.horizontal, Space.s12)
            .frame(height: Size.control)
            .background(ZStack { shape.fill(Color.raised); shape.fill(isHovering ? Color.hover : Color.clear) })
            .overlay(shape.strokeBorder(Color.border, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .accessibilityLabel("Add section")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Space.s2) {
                ForEach(hidden) { block in
                    RowButton(action: { onAdd(block) }) {
                        HStack(spacing: Space.s8) {
                            Image(systemName: block.symbol)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Color.textMuted)
                                .frame(width: Size.icon)
                                .accessibilityHidden(true)
                            Text(block.title)
                                .font(Type.t13)
                                .foregroundStyle(Color.text)
                                .lineLimit(1)
                            Spacer(minLength: Space.s8)
                            Image(systemName: Symbol.newTab)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(Color.textMuted)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Add \(block.title)")
                }
            }
            .environment(\.rowsCompact, true)
            .padding(Space.s8)
            .frame(width: 240)
            .background(Color.raised)
        }
    }
}

// MARK: - Supporting Types

private struct DueGroup: Identifiable {
    var id: String
    var title: String
    var tasks: [StudyTask]
    var isCritical: Bool
}

private struct LectureKey: Equatable {
    var courses: [Course]
    var plans: [[PlanPreview]]
    var minute: Date
}

private struct TodayKey: Equatable {
    var events: [CalendarEvent]
    var day: Date
}

/// An icon and text a few points apart, for meta lines.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s4) {
            configuration.icon
            configuration.title.monospacedDigit()
        }
    }
}

/// A titled group on Home: 15pt semibold heading, optional muted count, and optional trailing
/// controls, then the group's content on the same leading edge.
private struct HomeSection<Trailing: View, Content: View>: View {
    @Environment(\.homeEditing) private var isEditing
    let title: String
    var count: Int?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        count: Int? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.count = count
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                titleText
                    .lineLimit(1)
                    .offset(x: -1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(shownCount.map { "\(title), \($0)" } ?? title)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s8)
                if !isEditing {
                    trailing()
                }
            }
            .padding(.bottom, Space.s8)
            content()
        }
    }

    private var shownCount: Int? { (count ?? 0) > 0 ? count : nil }

    private var titleText: Text {
        let head = Text(title).font(Type.group).foregroundStyle(Color.text)
        guard let shownCount else { return head }
        return head + Text(" \(shownCount)").font(Type.groupCount).foregroundStyle(Color.textMuted)
    }
}

extension HomeSection where Trailing == AnyView {
    init(
        title: String,
        count: Int? = nil,
        action: (String, () -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            count: count,
            trailing: {
                action.map { AnyView(SectionLink($0.0, action: $0.1)) } ?? AnyView(EmptyView())
            },
            content: content
        )
    }
}

/// An empty or loading line, on the same left edge as the group's header.
private struct HomeEmpty: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Type.t13)
            .foregroundStyle(Color.textMuted)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Space.s6)
    }
}

/// A course's own hue as a small dot, before its name or a class named after it.
private struct CourseDot: View {
    let courseId: Int
    var isFaint = false

    var body: some View {
        Circle()
            .fill(Color.course(courseId))
            .opacity(isFaint ? 0.5 : 1)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// One of the person's links, or the edit button at the end of the strip.
private struct LinkChip: View {
    let title: String
    var symbol: String = Symbol.open
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        Button(action: action) {
            HStack(spacing: Space.s4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .regular))
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
            }
            .font(Type.t12)
            .foregroundStyle(isHovering ? Color.text : Color.textMuted)
            .padding(.horizontal, Space.s8)
            .frame(height: Size.controlSmall)
            .background(ZStack { shape.fill(Color.raised); shape.fill(isHovering ? Color.hover : Color.clear) })
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
    }
}

/// A link as an icon, its name on hover. Quiet ones have no fill, such as the edit button.
struct LinkIconButton: View {
    let symbol: String
    let label: String
    var isQuiet = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isHovering ? Color.text : Color.textMuted)
                .frame(width: Size.control, height: Size.control)
                .background(ZStack {
                    shape.fill(isQuiet ? Color.clear : Color.raised)
                    shape.fill(isHovering ? Color.hover : Color.clear)
                })
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Adds, removes and orders the person's links, and holds the exam plan's address.
struct LinksEditor: View {
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var address = ""
    @State private var examAddress = ""

    private var draft: StudyLink { StudyLink(title: title.trimmingCharacters(in: .whitespaces), address: address) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("Links")
                .font(Type.t13.weight(.semibold))
                .foregroundStyle(Color.text)
                .accessibilityAddTraits(.isHeader)
            if model.studyLinks.isEmpty {
                Text("Sites you use beside Laer, such as digital exams, mail or your student portal.")
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Space.s2) {
                ForEach(model.studyLinks) { link in
                    HStack(spacing: Space.s8) {
                        Menu {
                            ForEach(Symbol.linkChoices, id: \.self) { choice in
                                Button { setIcon(choice, for: link) } label: { Label(choice, systemImage: choice) }
                            }
                        } label: {
                            Image(systemName: link.icon)
                                .font(.system(size: 13))
                                .frame(width: Size.control, height: Size.control)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Choose an icon")
                        .accessibilityLabel("Icon for \(link.title)")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(link.title).font(Type.t13).foregroundStyle(Color.text).lineLimit(1)
                            Text(link.url?.host() ?? link.address).font(Type.t11).foregroundStyle(Color.textMuted).lineLimit(1)
                        }
                        Spacer(minLength: Space.s8)
                        IconButton("arrow.up", label: "Move \(link.title) up") { move(link, by: -1) }
                            .disabled(model.studyLinks.first == link)
                        IconButton(Symbol.close, label: "Remove \(link.title)") {
                            model.setStudyLinks(model.studyLinks.filter { $0 != link })
                        }
                    }
                }
            }
            HStack(spacing: Space.s6) {
                FieldBox(label: "Name", text: $title, onSubmit: add).frame(width: 110)
                FieldBox(label: "Address", text: $address, onSubmit: add)
                TextButton("Add", action: add).disabled(draft.title.isEmpty || draft.url == nil)
            }
            Rectangle().fill(Color.border).frame(height: 1)
            Text("Exam plan")
                .font(Type.t13.weight(.semibold))
                .foregroundStyle(Color.text)
            Text("The address of your programme's exam plan PDF. Laer saves it and finds your courses in it.")
                .font(Type.t12)
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s6) {
                FieldBox(label: "PDF address", text: $examAddress, onSubmit: saveExam)
                TextButton("Save", action: saveExam)
                    .disabled(examAddress.trimmingCharacters(in: .whitespaces) == (model.examPlanAddress ?? ""))
            }
        }
        .padding(Space.s16)
        .frame(width: 420)
        .background(Color.raised)
        .onAppear { examAddress = model.examPlanAddress ?? "" }
    }

    private func add() {
        guard !draft.title.isEmpty, draft.url != nil else { return }
        model.setStudyLinks(model.studyLinks + [draft])
        title = ""
        address = ""
    }

    private func move(_ link: StudyLink, by offset: Int) {
        var links = model.studyLinks
        guard let index = links.firstIndex(of: link), links.indices.contains(index + offset) else { return }
        links.swapAt(index, index + offset)
        model.setStudyLinks(links)
    }

    private func setIcon(_ symbol: String, for link: StudyLink) {
        model.setStudyLinks(model.studyLinks.map { $0.id == link.id ? StudyLink(id: $0.id, title: $0.title, address: $0.address, symbol: symbol) : $0 })
    }

    private func saveExam() {
        model.examPlanAddress = examAddress
    }
}

/// One lecture plan: course, when, topic, optional brief and readings to open.
private struct UpNextCard: View {
    let lecture: UpcomingLecture
    let topic: String?
    let note: LectureNote?
    var readingLimit: Int = 3
    let now: Date
    let openLecture: () -> Void
    let openReading: (PlanPreview.Element) -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        VStack(alignment: .leading, spacing: Space.s8) {
            Button(action: openLecture) {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text(lecture.plan.name ?? "Untitled plan")
                        .font(Type.t13.weight(.semibold))
                        .foregroundStyle(Color.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Space.s6) {
                        CourseDot(courseId: lecture.course.courseId)
                        Text(lecture.course.shortTitle).lineLimit(1)
                        if let topic {
                            Text("·")
                            Text(topic).lineLimit(1).layoutPriority(-1)
                        }
                        if let start = lecture.start {
                            Text("·")
                            Text(when(start))
                                .monospacedDigit()
                                .lineLimit(1)
                                .help(start.formatted(date: .complete, time: .shortened))
                        }
                    }
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { isHovering = $0 }
            if let note { BriefSummary(note: note) }
            if !lecture.readings.isEmpty, readingLimit > 0 {
                VStack(spacing: Space.s2) {
                    ForEach(lecture.readings.prefix(readingLimit)) { element in
                        LectureReadingRow(element: element, courseId: lecture.course.courseId) { openReading(element) }
                    }
                }
                .padding(.horizontal, -Space.s8)
                .undividedRows()
            }
        }
        .padding(.horizontal, Space.s8)
        .padding(.vertical, Space.s6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(shape.fill(isHovering ? Color.hover : Color.clear))
        .padding(.horizontal, -Space.s8)
    }

    private func when(_ start: Date) -> String {
        if start > now { return StudyDates.relative(start, now: now) }
        let stop = StudyDates.usable(lecture.plan.stop)
        if let stop, stop < now { return String(localized: "Ended") }
        if let stop, stop.timeIntervalSince(start) <= 24 * 3600 { return String(localized: "Now") }
        return String(localized: "This week")
    }
}

/// One line of the inbox: a message thread.
private struct InboxItem: Identifiable {
    var id: String
    var threadId: Int
    var date: Date?
    var title: String
    var place: String
    var senderName: String?
    var imageURL: String?
    var isUnread: Bool
}

/// Rows in a Home section, apart with no lines between them; hover reaches 8pt into the gutter.
private struct HomeList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, -Space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A section's link to its full screen: quiet beside the header, accent on hover, never above the content.
private struct SectionLink: View {
    private let title: String
    private let action: () -> Void
    @State private var isHovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Type.t12)
                .lineLimit(1)
                .foregroundStyle(isHovering ? Color.accent : Color.textMuted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
    }
}

extension EnvironmentValues {
    /// True while Home's sections are being arranged.
    @Entry var homeEditing = false
}
