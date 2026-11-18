import AppKit
import LaerCore
import SwiftUI

/// Everything at a glance in two columns that each read as one list: time on the left (today's
/// agenda, then what's due including exams), content on the right (the next lecture and its
/// readings, then announcements and messages together). The person's links sit by the date.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var events: [CalendarEvent] = []
    @State private var eventsLoaded = false
    @State private var upcomingMemo = Memo<UpcomingKey, UpcomingSections>()
    @State private var lectureMemo = Memo<LectureKey, [UpcomingLecture]>()
    @State private var weekMemo = Memo<TodayKey, [ScheduleDay]>()
    @State private var width: CGFloat = 0
    @State private var isEditingLinks = false
    @State private var threads = CollectionLoader<MessageThread>(key: "message-threads", coverage: .recentWindow) { client in
        let list = try await client.messageThreads()
        return PagedResult(items: list.threads, isComplete: true)
    }

    /// Below this the two columns stack.
    private let twoColumns: CGFloat = 820
    /// The share of the two columns' width the left one (Due, Schedule) gets, so a due title and
    /// its status stay on one line.
    private let leftShare: CGFloat = 0.58

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
                nextStrip(now: now, classes: classes, sections: sections, messages: messages)
                    .padding(.top, Space.s12)
                columns {
                    VStack(alignment: .leading, spacing: 0) {
                        due(now: now, sections: sections)
                        courseNews
                        schedule(now: now, classes: classes)
                        examRows
                    }
                } right: {
                    VStack(alignment: .leading, spacing: 0) {
                        upNext(now: now)
                        inbox(messages)
                    }
                }
            }
            .frame(maxWidth: Size.contentMax, alignment: .leading)
            .padding(Size.contentInset)
            // Room under the last section, so its header is not cut at the window's edge.
            .padding(.bottom, Space.s32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The scroll view is held to the pane. A scroll view left to itself grows to its content's
        // minimum width, and two columns need more than a narrow pane has.
        .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // The pane's width, measured outside the scroll view so wide content cannot make the pane
        // look wide and keep itself in two columns.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color.stage)
        .undividedRows()
        .navigationTitle("Home")
        .task { await load() }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await load(force: true) })
    }

    private func load(force: Bool = false) async {
        // Saved events show at once; the network answer replaces them when it comes.
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

    // MARK: Layout

    @ViewBuilder
    private func columns<Left: View, Right: View>(@ViewBuilder _ left: () -> Left, @ViewBuilder right: () -> Right) -> some View {
        if width >= twoColumns {
            let gutter = Space.s32
            let usable = min(width - 2 * Size.contentInset, Size.contentMax) - gutter
            HStack(alignment: .top, spacing: gutter) {
                left().frame(width: (usable * leftShare).rounded(), alignment: .topLeading)
                right().frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                left()
                right()
            }
        }
    }

    private func header(now: Date) -> some View {
        // The links sit on the title's baseline at the content's trailing edge. The counts live in
        // the summary card below, not in a second line here.
        PageHeader(title: now.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
            linkStrip
        }
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
                    // Looks like `WebsiteLink`, since every entry leaves Laer for a website: the
                    // arrow-out icon and the words in the secondary colour, not the system's
                    // accent-coloured menu title.
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
                // The borderless menu adds ~4pt of system padding; end on the column edge like other header links.
                .padding(.trailing, -4)
                .help("Your school's links")
                .accessibilityLabel("School links")
            }
        }
        .popover(isPresented: $isEditingLinks, arrowEdge: .bottom) {
            LinksEditor().environment(model)
        }
    }

    // MARK: Sections

    private var unreadCount: Int {
        guard ParityGate.messages else { return 0 }
        return model.unreadThreadCount ?? threads.records.filter(\.hasUnread).count
    }

    /// Classes still to come this week, soonest first. All-day entries are not classes.
    private func upcomingClasses(now: Date, days: [ScheduleDay]) -> [ScheduleBlock] {
        days.flatMap(\.blocks)
            .filter { $0.end.timeIntervalSince($0.start) < 23 * 3600 && $0.end > now }
            .sorted { $0.start < $1.start }
    }

    private func course(of block: ScheduleBlock) -> Course? {
        block.event.courseId.flatMap { id in model.courses.first { $0.courseId == id } }
    }

    /// The day and time of a class: "Tomorrow 8:00 AM", or "Now" while it is on.
    private func classWhen(_ block: ScheduleBlock, now: Date) -> String {
        block.start <= now ? String(localized: "Now") : StudyDates.relative(block.start, now: now)
    }

    /// The things to look at first, one fact and one time per row: what is overdue, the next
    /// class, the next deadline that is not overdue, and unread messages. A line with nothing to
    /// say is left out. Overdue work has its own row, so "Next due" never carries its count.
    @ViewBuilder private func nextStrip(
        now: Date, classes: [ScheduleBlock], sections: UpcomingSections, messages: [InboxItem]
    ) -> some View {
        let next = ParityGate.personalCalendar ? classes.first : nil
        let overdue = sections.overdue
        let deadline = (sections.today + sections.thisWeek).first
        let unread = unreadCount
        if next != nil || deadline != nil || !overdue.isEmpty || unread > 0 {
            VStack(alignment: .leading, spacing: 0) {
                if !overdue.isEmpty {
                    NextLine(label: "Overdue", detail: nil, action: { model.selection = .upcoming }) {
                        Text(overdue.count == 1 ? String(localized: "1 assignment") : String(localized: "\(overdue.count) assignments"))
                            .foregroundStyle(Color.danger)
                            .lineLimit(1)
                    }
                }
                if let next {
                    let place = course(of: next)
                    NextLine(label: "Next class", detail: classWhen(next, now: now), action: { model.selection = .calendar }) {
                        HStack(spacing: Space.s6) {
                            if let id = next.event.courseId { CourseDot(courseId: id) }
                            Text(place?.shortTitle ?? next.event.title ?? String(localized: "Untitled event"))
                                .foregroundStyle(Color.text)
                                .lineLimit(1)
                        }
                    }
                }
                if let deadline {
                    let due = StudyDates.usable(deadline.deadline)
                    NextLine(
                        label: "Next due",
                        detail: due.map { StudyDates.relative($0, now: now) },
                        action: { model.selection = .upcoming }
                    ) {
                        Text(deadline.title).foregroundStyle(Color.text).lineLimit(1)
                    }
                }
                if unread > 0 {
                    let sender = messages.first { $0.isUnread }?.place
                    NextLine(label: "Messages", detail: sender, action: { model.selection = .messages }) {
                        Text(String(localized: "\(unread) unread")).foregroundStyle(Color.text).lineLimit(1)
                    }
                }
            }
            // A hairline under each row; the last one is masked off.
            .mask(Rectangle().padding(.bottom, 1))
            .padding(.vertical, Space.s4)
            .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Color.raised))
            .environment(\.rowSurface, Color.raised)
            .environment(\.rowsCompact, true)
            // Like a list group, the card reaches 8pt into the gutter: its text sits on the page's
            // edge and its chevrons on the same trailing x as every row below.
            .padding(.horizontal, -Space.s8)
        }
    }

    /// The next three classes today and tomorrow, one line each.
    @ViewBuilder private func schedule(now: Date, classes: [ScheduleBlock]) -> some View {
        if ParityGate.personalCalendar {
            let calendar = Calendar.current
            let coming = classes
                .filter { calendar.isDateInToday($0.start) || calendar.isDateInTomorrow($0.start) }
                .prefix(3)
            let times = coming.map { classWhen($0, now: now) }
            HomeSection(title: "Schedule", action: ("Open calendar", { model.selection = .calendar })) {
                if coming.isEmpty {
                    if eventsLoaded { HomeEmpty("No more classes today or tomorrow") } else { Spinner() }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(coming) { block in
                        let place = course(of: block)
                        RowButton(action: { model.selection = .calendar }) {
                            HStack(spacing: Space.s6) {
                                // The time, then the course with its dot: no separator before a dot.
                                // The time column is as wide as the widest time, so every course
                                // starts on one x whatever its hour reads.
                                timeColumn(classWhen(block, now: now), among: times)
                                    .padding(.trailing, Space.s2)
                                if let id = block.event.courseId { CourseDot(courseId: id) }
                                Text(place?.shortTitle ?? block.event.title ?? String(localized: "Untitled event"))
                                    .foregroundStyle(Color.text)
                                Spacer(minLength: 0)
                            }
                            .font(Type.t13)
                            .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .environment(\.rowsCompact, true)
                .padding(.horizontal, -Space.s8)
            }
        }
    }

    /// A time that takes the width of the widest of `times`: the others sit unseen behind it, so
    /// each row's column is the same width and what follows it lines up.
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

    /// The soonest lecture large, then other plans of this week, then plans of later weeks under
    /// "Later plans" with their week's range. A plan whose week contains today is never "Later".
    @ViewBuilder private func upNext(now: Date) -> some View {
        let courses = model.activeCourses
        let plans = courses.map { model.plans[$0.courseId] ?? [] }
        let lectures = lectureMemo.value(for: LectureKey(courses: courses, plans: plans, minute: currentMinute())) {
            model.upcomingLectures(limit: 24, now: now)
        }
        let weekEnd = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.end ?? now
        let rest = Array(lectures.dropFirst())
        let thisWeek = Array(rest.filter { ($0.start ?? .distantFuture) < weekEnd }.prefix(2))
        let later = Array(rest.filter { ($0.start ?? .distantFuture) >= weekEnd }.prefix(3))
        HomeSection(title: "Next plan") {
            if let first = lectures.first {
                UpNextCard(
                    lecture: first,
                    topic: PlanTopics.displayName(of: first.plan, topics: model.topics[first.course.courseId] ?? []),
                    note: model.lectureNote(for: first.plan, course: first.course),
                    now: now
                ) {
                    openCourse(first.course.courseId, tab: .plans)
                } openReading: { element in
                    openReading(element, courseId: first.course.courseId)
                }
                if !thisWeek.isEmpty {
                    ListGroup {
                        ForEach(thisWeek) { entry in lectureRow(entry, label: String(localized: "This week")) }
                    }
                }
                if !later.isEmpty {
                    SectionHeader(title: "Later plans")
                    ListGroup {
                        ForEach(later) { entry in lectureRow(entry, label: weekLabel(entry)) }
                    }
                }
            } else {
                HomeEmpty(model.activeCourses.isEmpty ? "No active courses" : "No upcoming lectures")
            }
        }
    }

    private func lectureRow(_ entry: UpcomingLecture, label: String?) -> some View {
        ListRow(
            title: entry.plan.name ?? "Untitled plan",
            subtitle: entry.course.shortTitle,
            subtitleDot: Color.course(entry.course.courseId),
            action: { openCourse(entry.course.courseId, tab: .plans) },
            meta: { RowTrailing(date: label, chevron: true) }
        )
    }

    /// The plan's week as a range such as "22-28 Nov".
    private func weekLabel(_ entry: UpcomingLecture) -> String? {
        guard let start = entry.start else { return nil }
        let stop = StudyDates.usable(entry.plan.stop) ?? start
        return StudyDates.weekRange(start, max(stop, start))
    }

    /// Recent messages, newest first. Course announcements have their own section.
    private func inbox(_ items: [InboxItem]) -> some View {
        HomeSection(title: "Messages", action: ParityGate.messages ? ("Open Messages", { model.selection = .messages }) : nil) {
            if items.isEmpty { HomeEmpty("No recent messages") }
            ListGroup {
                ForEach(items.prefix(2)) { item in
                    ListRow(
                        title: item.title,
                        emphasised: item.isUnread,
                        subtitle: item.place,
                        action: { model.selection = .messages },
                        leadingWidth: 28,
                        leading: {
                            // The sender's picture; an unread message adds the accent dot at its corner.
                            Avatar(name: item.senderName, imageURL: item.imageURL, size: 28)
                                .overlay(alignment: .topTrailing) {
                                    if item.isUnread {
                                        Circle()
                                            .fill(Color.accent)
                                            .frame(width: 8, height: 8)
                                            .overlay(Circle().strokeBorder(Color.stage, lineWidth: 1.5))
                                            .offset(x: 2, y: -2)
                                    }
                                }
                        },
                        meta: { RowTrailing(date: item.date.map { StudyDates.relative($0) }, chevron: true) }
                    )
                    .accessibilityValue(item.isUnread ? "Unread" : "")
                }
            }
        }
    }

    /// The latest course updates across active courses, each opening its course's Updates tab.
    @ViewBuilder private var courseNews: some View {
        let items = model.recentAnnouncements(limit: 3)
        if !items.isEmpty {
            HomeSection(title: "New in your courses") {
                ListGroup {
                    ForEach(items, id: \.update.notificationId) { entry in
                        ListRow(
                            title: entry.update.displayText.isEmpty ? String(localized: "Update") : entry.update.displayText,
                            subtitle: entry.course.shortTitle,
                            subtitleDot: Color.course(entry.course.courseId),
                            action: { openCourse(entry.course.courseId, tab: .updates) },
                            leadingWidth: 28,
                            leading: {
                                Avatar(name: entry.update.publishedBy?.fullName, imageURL: entry.update.publishedBy?.imageURLString, size: 28)
                            },
                            meta: { RowTrailing(date: entry.update.published.map { StudyDates.relative($0) }, chevron: true) }
                        )
                    }
                }
            }
        }
    }

    private func inboxItems() -> [InboxItem] {
        guard ParityGate.messages else { return [] }
        return threads.records.prefix(8).map { thread in
            let preview = PlainText.from(thread.lastMessage?.text ?? "")
            return InboxItem(
                id: "thread-\(thread.threadId)",
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

    private func dueSections() -> UpcomingSections {
        let activeIds = Set(model.activeCourses.map(\.courseId))
        return upcomingMemo.value(for: UpcomingKey(tasks: model.tasks, activeIds: activeIds, minute: currentMinute())) {
            UpcomingList.sections(model.tasks, activeCourseIds: activeIds, now: currentMinute(), calendar: .current)
        }
    }

    /// Overdue tasks first, then those due in the next week. The count is the whole list; the
    /// header's link opens all of them.
    @ViewBuilder private func due(now: Date, sections: UpcomingSections) -> some View {
        let items = Self.dueItems(sections)
        let shown = 5
        HomeSection(title: "Due", count: items.count, action: ("All assignments", { model.selection = .upcoming })) {
            if items.isEmpty {
                EmptyState(state: model.tasksState, empty: "Nothing due in the next 7 days").padding(.vertical, Space.s6)
            }
            ListGroup {
                ForEach(items.prefix(shown)) { task in dueRow(task, now: now) }
            }
        }
    }

    /// One line of trailing text, the same on Assignments: the red "Overdue" capsule when the
    /// deadline has passed, then the submission state ("In progress") in a quieter neutral
    /// capsule, then the date. The two are independent, so a row can carry both.
    private func dueRow(_ task: StudyTask, now: Date) -> some View {
        let deadline = StudyDates.usable(task.deadline)
        let isOverdue = (deadline ?? .distantFuture) < now
        let state = StudyDates.statusText(task.status)
        let course = model.courses.first(where: { $0.courseId == task.courseId })?.shortTitle ?? task.courseTitle
        return ListRow(
            title: task.title,
            subtitle: course,
            subtitleDot: task.courseId.map { Color.course($0) },
            action: { openTask(task) },
            meta: {
                HStack(spacing: Space.s8) {
                    if isOverdue { StatusCapsule("Overdue", tone: .critical) }
                    if let state { StatusCapsule(state, tone: .neutral) }
                    RowTrailing(date: deadline.map { StudyDates.relative($0, now: now) }, chevron: true)
                }
            }
        )
        .help(StudyDates.deadline(task.deadline))
    }

    /// Tasks with an element open in Assignments; others go to their page on the website.
    private func openTask(_ task: StudyTask) {
        if task.elementId == nil, let url = model.absoluteURL(task.url) {
            NSWorkspace.shared.open(url)
        } else {
            model.selection = .upcoming
        }
    }

    /// The exam plan PDF from the address the person gave, with the pages naming their courses.
    /// A small section that closes the left column. It is left out while there is nothing to say:
    /// no address (the links editor holds it), or no active course in the plan.
    @ViewBuilder private var examRows: some View {
        let plan = model.examPlan
        let isLoading = plan.phase == .loading && plan.fileURL == nil
        let failure: String? = if case .failed(let message) = plan.phase { message } else { nil }
        if model.examPlanAddress != nil, isLoading || failure != nil || !plan.matches.isEmpty {
            HomeSection(
                title: "Exams",
                action: plan.fileURL != nil ? ("Open exam plan", { model.openExamPlan() }) : nil
            ) {
                if isLoading { Spinner() }
                if let failure { ErrorLine(failure) }
                ListGroup {
                    ForEach(plan.matches) { match in
                        ListRow(
                            title: match.courseTitle,
                            action: { model.openExamPlan(page: match.pages.first) },
                            meta: { RowTrailing(date: Self.pagesLabel(match.pages), chevron: true) }
                        )
                    }
                }
            }
            .help(plan.fetchedAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "")
        }
    }

    /// Exam pages in the column: "p. 3", "p. 3, 7", or "p. 3 +2" when there are more.
    private static func pagesLabel(_ pages: [Int]) -> String {
        let shown = pages.map { ($0 + 1).formatted() }
        if shown.count <= 2 { return "p. \(shown.joined(separator: ", "))" }
        return "p. \(shown[0]) +\(shown.count - 1)"
    }

    // MARK: Actions

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

/// A titled group on Home: the page's `SectionHeader` (title, the count, and the one link to the
/// full screen in its trailing slot), then the group's content on the same left edge.
private struct HomeSection<Content: View>: View {
    let title: String
    /// How many rows the section lists in all.
    var count: Int?
    /// The link's own words, such as "Open calendar", and what it does.
    var action: (String, () -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, count: (count ?? 0) > 0 ? count : nil) {
                if let action { InlineLink(action.0, action: action.1) }
            }
            content()
        }
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

/// One line of the "Next" strip: its label, what it is, and one time at the trailing edge, then a
/// chevron placed like every other row's.
private struct NextLine<Main: View>: View {
    let label: LocalizedStringKey
    var detail: String?
    let action: () -> Void
    @ViewBuilder var main: () -> Main

    var body: some View {
        RowButton(action: action) {
            HStack(spacing: Space.s8) {
                Text(label)
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .frame(width: 76, alignment: .leading)
                main()
                    .layoutPriority(1)
                Spacer(minLength: Space.s8)
                // A sender or title can be long, so it shortens here instead of widening the row
                // past the pane the way a fixed-size trailing date would.
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 220, alignment: .trailing)
                        .layoutPriority(2)
                }
                RowTrailing(date: nil, chevron: true)
            }
            .font(Type.t13)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.border).frame(height: 1).padding(.horizontal, Space.s8)
        }
        .accessibilityElement(children: .combine)
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

/// The next lecture, large: course, when, the plan, its brief and its readings to open.
private struct UpNextCard: View {
    let lecture: UpcomingLecture
    /// The plan's itslearning topic, when it has one: the card's secondary line.
    let topic: String?
    let note: LectureNote?
    let now: Date
    let openLecture: () -> Void
    let openReading: (PlanPreview.Element) -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        VStack(alignment: .leading, spacing: Space.s8) {
            Button(action: openLecture) {
                VStack(alignment: .leading, spacing: Space.s4) {
                    HStack(spacing: Space.s6) {
                        CourseDot(courseId: lecture.course.courseId)
                        Text(lecture.course.shortTitle).lineLimit(1)
                        if let start = lecture.start {
                            Text("·")
                            Text(when(start))
                                .monospacedDigit()
                                .help(start.formatted(date: .complete, time: .shortened))
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
                    if let topic {
                        Text(topic)
                            .font(Type.t12)
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { isHovering = $0 }
            if let note { BriefSummary(note: note) }
            if !lecture.readings.isEmpty {
                Text("Prepare for class")
                    .font(Type.section)
                    .foregroundStyle(Color.textMuted)
                    .padding(.top, Space.s4)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: Space.s2) {
                    ForEach(lecture.readings.prefix(3)) { element in
                        LectureReadingRow(element: element, courseId: lecture.course.courseId) { openReading(element) }
                    }
                }
                .padding(.horizontal, -Space.s8)
                .undividedRows()
            }
        }
        // No card fill: the lecture sits on the page, its text on the section header's edge, so
        // it does not out-rank what is due. Hovering the title washes the block.
        .padding(.horizontal, Space.s8)
        .padding(.vertical, Space.s6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(shape.fill(isHovering ? Color.hover : Color.clear))
        // The wash reaches 8pt into the gutter, like a row's, so the text sits on the header's edge.
        .padding(.horizontal, -Space.s8)
    }

    /// A plan already under way: "Now" only for one that lasts a day or less, so a week's plan
    /// does not say "Now" while the timetable says its class has ended.
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
    var date: Date?
    var title: String
    /// Who it is with, such as the conversation's name.
    var place: String
    /// The last message's sender, and their picture, for the row's avatar.
    var senderName: String?
    var imageURL: String?
    var isUnread: Bool
}
