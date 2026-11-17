import LaerCore
import SwiftUI

/// Today and this week at a glance: today's events, tasks due, the next lecture per active
/// course and unread conversations.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var events: [CalendarEvent] = []
    @State private var eventsLoaded = false
    @State private var upcomingMemo = Memo<UpcomingKey, UpcomingSections>()
    @State private var lectureMemo = Memo<LectureKey, [LectureEntry]>()
    @State private var todayMemo = Memo<TodayKey, [ScheduleBlock]>()
    @State private var threads = CollectionLoader<MessageThread>(key: "message-threads", coverage: .recentWindow) { client in
        let list = try await client.messageThreads()
        return PagedResult(items: list.threads, isComplete: true)
    }

    var body: some View {
        let now = Date()
        PageScroll(spacing: 0) {
            PageHeader(title: now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .padding(.bottom, Space.s24)
            lectures(now: now)
            today(now: now)
            due(now: now)
            if ParityGate.messages { unread }
        }
        .dividedRows()
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
        await model.loadTasks()
        await model.loadLectureNotes(force: force)
        if ParityGate.messages {
            if force { await threads.refresh(using: model) } else { await threads.load(using: model) }
        }
        await withTaskGroup(of: Void.self) { group in
            for course in model.activeCourses.prefix(16) {
                let id = course.courseId
                group.addTask { await model.loadPlans(courseId: id) }
            }
        }
        events = await week
        eventsLoaded = true
    }

    // MARK: Sections

    @ViewBuilder private func today(now: Date) -> some View {
        if ParityGate.personalCalendar {
            let blocks = todayMemo.value(for: TodayKey(events: events, day: Calendar.current.startOfDay(for: now))) {
                WeekSchedule.days(events: events, weekContaining: now, calendar: .current)
                    .first { Calendar.current.isDate($0.date, inSameDayAs: now) }?.blocks ?? []
            }
            HomeSection(title: "Today", action: ("Calendar", { model.selection = .calendar })) {
                if blocks.isEmpty {
                    if eventsLoaded { EmptyLine("Nothing on the calendar today") } else { Spinner() }
                }
                ForEach(blocks) { block in
                    HomeRow(
                        leading: block.end.timeIntervalSince(block.start) >= 23 * 3600
                            ? "All day"
                            : (block.start..<max(block.start, block.end)).formatted(.interval.hour().minute()),
                        title: block.event.title ?? "Untitled event",
                        detail: block.event.displayLocation,
                        isPast: block.end < now
                    ) { model.selection = .calendar }
                }
            }
        }
    }

    @ViewBuilder private func due(now: Date) -> some View {
        let tasks = model.tasks
        let activeIds = Set(model.activeCourses.map(\.courseId))
        let minute = currentMinute()
        let sections = upcomingMemo.value(for: UpcomingKey(tasks: tasks, activeIds: activeIds, minute: minute)) {
            UpcomingList.sections(tasks, activeCourseIds: activeIds, now: minute, calendar: .current)
        }
        let items = sections.overdue + sections.today + sections.thisWeek
        HomeSection(title: "Next 7 days", action: ("Upcoming", { model.selection = .upcoming })) {
            if items.isEmpty {
                EmptyState(state: model.tasksState, empty: "Nothing due in the next 7 days")
            }
            ForEach(items.prefix(8)) { task in
                HomeRow(
                    leading: StudyDates.shortDeadline(task.deadline, now: now),
                    title: task.title,
                    detail: courseTitle(task.courseId) ?? task.courseTitle,
                    isWarning: (task.deadline ?? .distantFuture) < now
                ) { model.selection = .upcoming }
            }
        }
    }

    @ViewBuilder private func lectures(now: Date) -> some View {
        let courses = model.activeCourses
        let plans = courses.map { model.plans[$0.courseId] ?? [] }
        let next = lectureMemo.value(for: LectureKey(courses: courses, plans: plans, minute: currentMinute())) {
            zip(courses, plans).compactMap { course, items -> LectureEntry? in
                guard let plan = PlanOrder.sections(items, now: now).next else { return nil }
                return LectureEntry(course: course, plan: plan)
            }
            .sorted { ($0.plan.start ?? .distantFuture) < ($1.plan.start ?? .distantFuture) }
        }
        HomeSection(title: "Next lectures") {
            if next.isEmpty {
                EmptyLine(model.activeCourses.isEmpty ? "No active courses" : "No upcoming lectures")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Space.s12)], alignment: .leading, spacing: Space.s12) {
                ForEach(next, id: \.plan.planId) { entry in
                    let course = entry.course
                    LectureCard(course: course, plan: entry.plan, note: model.lectureNote(for: entry.plan, course: course)) {
                        navigation.courseTabs[course.courseId] = .plans
                        model.selection = .course(course.courseId)
                    }
                }
            }
            .padding(.top, Space.s4)
        }
    }

    @ViewBuilder private var unread: some View {
        let items = threads.records.filter(\.hasUnread)
        HomeSection(title: "Unread messages", action: ("Messages", { model.selection = .messages })) {
            if items.isEmpty {
                EmptyState(state: threads.state, empty: "No unread messages")
            }
            ForEach(items.prefix(5)) { thread in
                HomeRow(
                    leading: thread.lastMessage?.created.map { $0.formatted(.relative(presentation: .named)) } ?? "",
                    title: thread.name ?? thread.lastMessage?.createdByName ?? "Conversation",
                    detail: PlainText.from(thread.lastMessage?.text ?? "")
                ) { model.selection = .messages }
            }
        }
    }

    private func courseTitle(_ id: Int?) -> String? {
        guard let id else { return nil }
        return model.courses.first { $0.courseId == id }?.shortTitle
    }
}

private struct LectureKey: Equatable {
    var courses: [Course]
    var plans: [[PlanPreview]]
    var minute: Date
}

private struct LectureEntry {
    var course: Course
    var plan: PlanPreview
}

private struct TodayKey: Equatable {
    var events: [CalendarEvent]
    var day: Date
}

/// A next lecture as a card: the course, the plan and when, with its file count and any brief.
private struct LectureCard: View {
    let course: Course
    let plan: PlanPreview
    let note: LectureNote?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s6) {
                HStack(spacing: Space.s6) {
                    Image(systemName: Symbol.course)
                        .font(.system(size: 12, weight: .regular))
                        .accessibilityHidden(true)
                    Text(course.shortTitle).lineLimit(1)
                }
                .font(Type.t12)
                .foregroundStyle(Color.textMuted)
                Text(plan.name ?? "Untitled plan")
                    .font(Type.t15)
                    .foregroundStyle(Color.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note { BriefSummary(note: note) }
                Spacer(minLength: 0)
                HStack(spacing: Space.s12) {
                    if let start = StudyDates.usable(plan.start) {
                        Label(start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)), systemImage: Symbol.lecture)
                    }
                    if let count = plan.elements?.count, count > 0 {
                        Label(count.formatted(), systemImage: Symbol.material)
                            .accessibilityLabel(count == 1 ? "1 file" : "\(count) files")
                    }
                }
                .labelStyle(CompactLabelStyle())
                .font(Type.t11)
                .foregroundStyle(Color.textMuted)
            }
            .padding(Space.s16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(ZStack { shape.fill(Color.raised); shape.fill(isHovering ? Color.hover : Color.clear) })
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }
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

/// A titled group on Home, with an optional link to the full screen.
private struct HomeSection<Content: View>: View {
    let title: String
    var action: (String, () -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Type.t15)
                    .foregroundStyle(Color.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s8)
                if let action {
                    Button(action: action.1) {
                        Text("Show all").font(Type.t12).foregroundStyle(Color.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show all in \(action.0)")
                }
            }
            .padding(.horizontal, Space.s8)
            .padding(.bottom, Space.s4)
            content()
        }
        .padding(.bottom, Space.s32)
    }
}

private struct HomeRow: View {
    let leading: String
    let title: String
    let detail: String?
    var isPast = false
    var isWarning = false
    let action: () -> Void

    var body: some View {
        RowButton(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s12) {
                Text(leading)
                    .font(Type.t12)
                    .foregroundStyle(isWarning ? Color.danger : Color.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 148, alignment: .leading)
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(title)
                        .font(Type.t13)
                        .foregroundStyle(isPast ? Color.textMuted : Color.text)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(Type.t11)
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
