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
    private let twoColumns: CGFloat = 760

    var body: some View {
        let now = Date()
        let days = weekMemo.value(for: TodayKey(events: events, day: Calendar.current.startOfDay(for: now))) {
            WeekSchedule.days(events: events, weekContaining: now, calendar: .current)
        }
        let today = days.first { Calendar.current.isDate($0.date, inSameDayAs: now) }?.blocks ?? []
        let sections = dueSections()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(now: now, today: today, sections: sections)
                    .padding(.bottom, Space.s24)
                columns(leftWidth: 300) {
                    VStack(alignment: .leading, spacing: 0) {
                        agenda(now: now, days: days, today: today)
                        due(now: now, sections: sections)
                    }
                } right: {
                    VStack(alignment: .leading, spacing: 0) {
                        upNext(now: now)
                        inbox
                    }
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(Space.s24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in width = new }
                }
            }
        }
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
            if force { await threads.refresh(using: model) } else { await threads.load(using: model) }
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
    private func columns<Left: View, Right: View>(leftWidth: CGFloat? = nil, @ViewBuilder _ left: () -> Left, @ViewBuilder right: () -> Right) -> some View {
        if width >= twoColumns {
            HStack(alignment: .top, spacing: Space.s32) {
                if let leftWidth {
                    left().frame(width: leftWidth, alignment: .topLeading)
                } else {
                    left().frame(maxWidth: .infinity, alignment: .topLeading)
                }
                right().frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                left()
                right()
            }
        }
    }

    private func header(now: Date, today: [ScheduleBlock], sections: UpcomingSections) -> some View {
        HStack(alignment: .top, spacing: Space.s16) {
            VStack(alignment: .leading, spacing: Space.s4) {
                PageHeader(title: now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                Text(summary(today: today, sections: sections))
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: Space.s8)
            linkStrip
        }
        .padding(.horizontal, Space.s8)
    }

    private func summary(today: [ScheduleBlock], sections: UpcomingSections) -> String {
        var parts: [String] = []
        parts.append(today.count == 1 ? "1 event today" : "\(today.count) events today")
        let due = sections.today.count + sections.thisWeek.count
        parts.append(due == 1 ? "1 due this week" : "\(due) due this week")
        if !sections.overdue.isEmpty { parts.append("\(sections.overdue.count) overdue") }
        return parts.joined(separator: " · ")
    }

    /// The person's own links, such as exam, mail and sign-in sites, one click from Home.
    private var linkStrip: some View {
        HStack(spacing: Space.s4) {
                ForEach(model.studyLinks) { link in
                    LinkIconButton(symbol: link.icon, label: link.title, isQuiet: true) { model.open(link) }
                }
                Group {
                    if model.studyLinks.isEmpty {
                        LinkChip(title: "Add links", symbol: Symbol.edit) { isEditingLinks = true }
                    } else {
                        LinkIconButton(symbol: Symbol.edit, label: "Edit links", isQuiet: true) { isEditingLinks = true }
                    }
                }
                .popover(isPresented: $isEditingLinks, arrowEdge: .bottom) {
                        LinksEditor().environment(model)
                    }
        }
    }

    // MARK: Sections

    /// Today as a list, as in a planner: what has ended, what is on now and how long until the rest.
    @ViewBuilder private func agenda(now: Date, days: [ScheduleDay], today: [ScheduleBlock]) -> some View {
        if ParityGate.personalCalendar {
            HomeSection(title: "Today", count: today.count, action: ("Calendar", { model.selection = .calendar })) {
                if today.isEmpty {
                    if eventsLoaded { HomeEmpty("Nothing on the calendar today") } else { Spinner() }
                }
                ForEach(today) { block in AgendaRow(block: block, now: now) { model.selection = .calendar } }
            }
            let tomorrow = days.first { Calendar.current.isDateInTomorrow($0.date) }?.blocks ?? []
            if !tomorrow.isEmpty {
                HomeSection(title: "Tomorrow") {
                    ForEach(tomorrow.prefix(4)) { block in AgendaRow(block: block, now: now) { model.selection = .calendar } }
                }
            }
        }
    }

    @ViewBuilder private func upNext(now: Date) -> some View {
        let courses = model.activeCourses
        let plans = courses.map { model.plans[$0.courseId] ?? [] }
        let lectures = lectureMemo.value(for: LectureKey(courses: courses, plans: plans, minute: currentMinute())) {
            model.upcomingLectures(limit: 4, now: now)
        }
        HomeSection(title: "Up next") {
            if let first = lectures.first {
                UpNextCard(lecture: first, note: model.lectureNote(for: first.plan, course: first.course), now: now) {
                    openCourse(first.course.courseId, tab: .plans)
                } openReading: { element in
                    openReading(element, courseId: first.course.courseId)
                }
                if lectures.count > 1 {
                    Text("Then")
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .padding(.horizontal, Space.s8)
                        .padding(.top, Space.s12)
                    ForEach(lectures.dropFirst()) { entry in
                        HomeRow(
                            leading: entry.start.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? "",
                            title: entry.plan.name ?? "Untitled plan",
                            detail: entry.course.shortTitle
                        ) { openCourse(entry.course.courseId, tab: .plans) }
                    }
                }
            } else {
                HomeEmpty(model.activeCourses.isEmpty ? "No active courses" : "No upcoming lectures")
            }
        }
    }

    /// Announcements and messages in one list, newest first, each saying where it came from.
    @ViewBuilder private var inbox: some View {
        let items = inboxItems()
        let unread = threads.records.filter(\.hasUnread).count
        HomeSection(title: "Inbox", count: unread, action: ParityGate.messages ? ("Messages", { model.selection = .messages }) : nil) {
            if items.isEmpty { HomeEmpty("No recent announcements or messages") }
            ForEach(items) { item in
                InboxRow(item: item) {
                    switch item.source {
                    case .announcement(let courseId): openCourse(courseId, tab: .updates)
                    case .message: model.selection = .messages
                    }
                }
            }
        }
    }

    private func inboxItems() -> [InboxItem] {
        let announcements = model.recentAnnouncements(limit: 8).map { entry in
            InboxItem(
                id: "update-\(entry.update.notificationId)",
                date: entry.update.published,
                title: entry.update.displayText.isEmpty ? String(localized: "Update") : entry.update.displayText,
                place: AnnouncementPlace.text(course: entry.course, update: entry.update),
                isUnread: false,
                source: .announcement(entry.course.courseId)
            )
        }
        let messages = ParityGate.messages ? threads.records.prefix(8).map { thread in
            InboxItem(
                id: "thread-\(thread.threadId)",
                date: thread.lastMessage?.created,
                title: PlainText.from(thread.lastMessage?.text ?? "").isEmpty ? (thread.name ?? "Conversation") : PlainText.from(thread.lastMessage?.text ?? ""),
                place: thread.name ?? thread.lastMessage?.createdByName ?? String(localized: "Conversation"),
                isUnread: thread.hasUnread,
                source: .message
            )
        } : []
        return Array((announcements + messages)
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(8))
    }

    private func dueSections() -> UpcomingSections {
        let activeIds = Set(model.activeCourses.map(\.courseId))
        return upcomingMemo.value(for: UpcomingKey(tasks: model.tasks, activeIds: activeIds, minute: currentMinute())) {
            UpcomingList.sections(model.tasks, activeCourseIds: activeIds, now: currentMinute(), calendar: .current)
        }
    }

    /// Tasks due in the next week, then the exams found for the person's courses, in one place.
    @ViewBuilder private func due(now: Date, sections: UpcomingSections) -> some View {
        let items = sections.overdue + sections.today + sections.thisWeek
        HomeSection(title: "Due", count: items.count, action: ("Upcoming", { model.selection = .upcoming })) {
            if items.isEmpty {
                EmptyState(state: model.tasksState, empty: "Nothing due in the next 7 days").padding(.horizontal, Space.s8).padding(.vertical, Space.s6)
            }
            ForEach(items.prefix(6)) { task in
                HomeRow(
                    leading: StudyDates.shortDeadline(task.deadline, now: now),
                    title: task.title,
                    detail: courseTitle(task.courseId) ?? task.courseTitle,
                    isWarning: (task.deadline ?? .distantFuture) < now
                ) { model.selection = .upcoming }
            }
            examRows
        }
    }

    /// The exam plan PDF from the address the person gave, with the pages naming their courses.
    @ViewBuilder private var examRows: some View {
        let plan = model.examPlan
        // The one rule on Home: where tasks end and exams begin.
        Rectangle()
            .fill(Color.border)
            .frame(height: 1)
            .padding(.horizontal, Space.s8)
            .padding(.top, Space.s12)
        HStack(alignment: .firstTextBaseline) {
            Text("Exams")
                .font(Type.t11)
                .foregroundStyle(Color.textMuted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s8)
            if plan.fileURL != nil {
                Button { model.openExamPlan() } label: {
                    Text("Exam plan").font(Type.t11).foregroundStyle(Color.textMuted)
                }
                .buttonStyle(.plain)
                .help(plan.fetchedAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "")
            }
        }
        .padding(.horizontal, Space.s8)
        .padding(.top, Space.s8)
        .padding(.bottom, Space.s2)
        Group {
            if model.examPlanAddress == nil {
                HStack(spacing: Space.s8) {
                    Text("Add your exam plan's PDF address to find your exams in it.")
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                    Spacer(minLength: Space.s8)
                    TextButton("Set up") { isEditingLinks = true }
                }
                .padding(.horizontal, Space.s8)
                .padding(.vertical, Space.s6)
            } else {
                if plan.phase == .loading, plan.fileURL == nil { Spinner() }
                if case .failed(let message) = plan.phase { ErrorLine(message).padding(.horizontal, Space.s8) }
                if plan.fileURL != nil, plan.matches.isEmpty {
                    HomeEmpty("None of your active courses appear in the exam plan")
                }
                ForEach(plan.matches) { match in
                    HomeRow(
                        leading: "p. \(match.pages.map { String($0 + 1) }.joined(separator: ", "))",
                        title: match.courseTitle,
                        detail: nil
                    ) { model.openExamPlan(page: match.pages.first) }
                }
            }
        }
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

/// A titled group on Home, with an optional link to the full screen.
private struct HomeSection<Content: View>: View {
    let title: String
    var count: Int?
    var action: (String, () -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s6) {
                Text(title)
                    .font(Type.t13.weight(.semibold))
                    .foregroundStyle(Color.text)
                    .accessibilityAddTraits(.isHeader)
                if let count, count > 0 {
                    Text(count.formatted())
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                }
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
            .padding(.bottom, Space.s6)
            content()
        }
        .padding(.bottom, Space.s32)
    }
}

/// An empty or loading line, on the same left edge as rows.
private struct HomeEmpty: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Type.t13)
            .foregroundStyle(Color.textMuted)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.s8)
            .padding(.vertical, Space.s6)
    }
}

/// Dates in a narrow column: a time today, then "Yesterday", a weekday, or day and month.
enum HomeDates {
    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct HomeRow: View {
    let leading: String
    let title: String
    let detail: String?
    var isPast = false
    var isWarning = false
    var leadingWidth: CGFloat = 72
    let action: () -> Void

    var body: some View {
        RowButton(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s12) {
                Text(leading)
                    .font(Type.t12)
                    .foregroundStyle(isWarning ? Color.danger : Color.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: leadingWidth, alignment: .leading)
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

/// A line of today's agenda: the time, what and where, and how it stands now.
private struct AgendaRow: View {
    let block: ScheduleBlock
    let now: Date
    let action: () -> Void

    private var isAllDay: Bool { block.end.timeIntervalSince(block.start) >= 23 * 3600 }
    private var hasEnded: Bool { block.end < now }
    private var isNow: Bool { !isAllDay && block.start <= now && now < block.end }

    private var status: String? {
        if isAllDay { return nil }
        if hasEnded { return String(localized: "Ended") }
        if block.start <= now { return String(localized: "Now") }
        return block.start.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    var body: some View {
        RowButton(selected: isNow, action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s12) {
                Text(isAllDay ? String(localized: "All day") : block.start.formatted(.dateTime.hour().minute()))
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .leading)
                // A rail through the day: filled for what's on now, hollow for what's next.
                Circle()
                    .strokeBorder(hasEnded ? Color.borderStrong : Color.textMuted, lineWidth: 1)
                    .background(Circle().fill(isNow ? Color.text : Color.clear))
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(block.event.title ?? "Untitled event")
                        .font(Type.t13)
                        .foregroundStyle(hasEnded ? Color.textMuted : Color.text)
                        .lineLimit(1)
                    let detail = [block.event.displayLocation, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !detail.isEmpty {
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

/// The next lecture, large: course, when, the plan, its brief and its readings to open.
private struct UpNextCard: View {
    let lecture: UpcomingLecture
    let note: LectureNote?
    let now: Date
    let openLecture: () -> Void
    let openReading: (PlanPreview.Element) -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
        VStack(alignment: .leading, spacing: Space.s8) {
            Button(action: openLecture) {
                VStack(alignment: .leading, spacing: Space.s4) {
                    HStack(spacing: Space.s6) {
                        Image(systemName: Symbol.course)
                            .font(.system(size: 12, weight: .regular))
                            .accessibilityHidden(true)
                        Text(lecture.course.shortTitle).lineLimit(1)
                        if let start = lecture.start {
                            Text("·")
                            Text(start > now
                                 ? start.formatted(.relative(presentation: .named))
                                 : String(localized: "Now"))
                                .monospacedDigit()
                                .help(start.formatted(date: .complete, time: .shortened))
                        }
                    }
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    Text(lecture.plan.name ?? "Untitled plan")
                        .font(Type.t18)
                        .foregroundStyle(Color.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { isHovering = $0 }
            if let note { BriefSummary(note: note) }
            if !lecture.readings.isEmpty {
                Text(lecture.readings.count == 1 ? "1 reading" : "\(lecture.readings.count) readings")
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                    .padding(.top, Space.s4)
                VStack(spacing: Space.s2) {
                    ForEach(lecture.readings) { element in
                        LectureReadingRow(element: element, courseId: lecture.course.courseId) { openReading(element) }
                    }
                }
                .padding(.horizontal, -Space.s8)
                .undividedRows()
                .environment(\.rowSurface, .raised)
            }
        }
        .padding(Space.s16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ZStack { shape.fill(Color.raised); shape.fill(isHovering ? Color.hover : Color.clear) })
    }
}

/// One line of the inbox: a course announcement or a message thread.
private struct InboxItem: Identifiable {
    enum Source { case announcement(Int), message }
    var id: String
    var date: Date?
    var title: String
    /// Where it came from, such as "Course › Week 11 · Author" or "Message · Name".
    var place: String
    var isUnread: Bool
    var source: Source

    var isMessage: Bool { if case .message = source { true } else { false } }
}

private enum AnnouncementPlace {
    /// "Course › Week 11 folder · Author".
    static func text(course: Course, update: CourseUpdate) -> String {
        var text = course.shortTitle
        if let location = update.locationTitle, !location.isEmpty, location != course.shortTitle, location != course.title {
            text += " › \(location)"
        }
        if let author = update.publishedBy?.fullName, !author.isEmpty { text += " · \(author)" }
        return text
    }
}

private struct InboxRow: View {
    let item: InboxItem
    let action: () -> Void

    var body: some View {
        RowButton(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s12) {
                Text(HomeDates.short(item.date))
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 72, alignment: .leading)
                Circle()
                    .fill(item.isUnread ? Color.text : Color.clear)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(item.title)
                        .font(Type.t13)
                        .foregroundStyle(Color.text)
                        .lineLimit(2)
                    // The icon says what kind it is, so the line only says where.
                    Label(item.place, systemImage: item.isMessage ? Symbol.comments : Symbol.update)
                        .labelStyle(CompactLabelStyle())
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .help(item.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isUnread ? "Unread" : "")
    }
}
