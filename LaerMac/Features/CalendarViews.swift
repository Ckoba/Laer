import LaerCore
import SwiftUI

/// Events grouped by day, in the user's calendar and time zone.
struct EventList: View {
    let events: [CalendarEvent]
    let state: CollectionState
    var showsLocation = true
    /// Inside a course: an event named after the course says nothing new, so its location leads.
    var courseNames: [String] = []
    /// What clicking an event does, or nil when it opens nothing.
    var action: (CalendarEvent) -> (() -> Void)? = { _ in nil }

    var body: some View {
        FreshnessLine(state: state)
        if events.isEmpty {
            EmptyState(state: state, empty: "No events in this period")
        }
        ForEach(days, id: \.day) { group in
            SectionHeader(title: group.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                // The header's own 20 pt leads the first group; later groups get 24.
                .padding(.top, group.day == days.first?.day ? 0 : Space.s4)
            // Row text starts on the day heading's edge; the rows reach 8pt into the gutter.
            ForEach(group.events) { event in
                EventRow(event: event, showsLocation: showsLocation, courseNames: courseNames, action: action(event))
                    .environment(\.rowDividerHidden, event.id == group.events.last?.id)
                    .padding(.horizontal, -Space.s8)
            }
        }
    }

    private var days: [(day: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        let dated = events.filter { $0.fromDate != nil }
        let grouped = Dictionary(grouping: dated) { calendar.startOfDay(for: $0.fromDate!) }
        return grouped.keys.sorted().map { day in
            (day, grouped[day]!.sorted { ($0.fromDate ?? .distantPast) < ($1.fromDate ?? .distantPast) })
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    let showsLocation: Bool
    var courseNames: [String] = []
    var action: (() -> Void)?

    /// The event's own title, or, when that only repeats the course, its location or "Class".
    private var title: String {
        let own = event.title ?? ""
        let repeatsCourse = courseNames.contains { own.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard !courseNames.isEmpty, own.isEmpty || repeatsCourse else {
            return own.isEmpty ? String(localized: "Untitled event") : own
        }
        if let location = event.displayLocation, !location.isEmpty { return location }
        return String(localized: "Class")
    }

    /// The location as a second line, unless it is already the title.
    private var locationLine: String? {
        guard let location = event.displayLocation, !location.isEmpty, location != title else { return nil }
        return showsLocation || !courseNames.isEmpty ? location : nil
    }

    var body: some View {
        if let action {
            RowButton(action: action) { content }
                .accessibilityElement(children: .combine)
        } else {
            content
                .plainRow()
                .accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s12) {
            // As wide as the widest range in this locale, so 12-hour times stay on one line
            // and every title starts at the same edge.
            ZStack(alignment: .leading) {
                Text(Self.widestRange).hidden()
                Text(timeText)
            }
            .font(Type.t12)
            .foregroundStyle(Color.textMuted)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(title)
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(2)
                if let location = locationLine {
                    Text(location)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
                if let text = event.eventDescription, !text.isEmpty {
                    Text(RichTextCache.preview(text))
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private static let widestRange: String = {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(22 * 3600 + 45 * 60)
        return StudyDates.timeRange(start, start.addingTimeInterval(3600))
    }()

    private var timeText: String {
        guard let start = event.fromDate else { return "" }
        guard let end = event.toDate, end > start else {
            return StudyDates.time(start)
        }
        if Calendar.current.isDate(start, inSameDayAs: end),
           Calendar.current.dateComponents([.hour, .minute], from: start, to: end).hour ?? 0 >= 23 {
            return "All day"
        }
        return StudyDates.timeRange(start, end)
    }
}

enum CalendarWindow {
    /// How far ahead the calendar screens read.
    static let length: TimeInterval = 90 * 24 * 3600
}

/// A course's events for the coming weeks.
struct CourseCalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    private let courseId: Int
    @State private var loader: CollectionLoader<CalendarEvent>
    private let courseNames: [String]

    init(course: Course) {
        let courseId = course.courseId
        self.courseId = courseId
        courseNames = [course.shortTitle, course.displayTitle, course.title].compactMap { $0 }
        _loader = State(initialValue: CollectionLoader(key: "course-calendar-\(courseId)", coverage: .recentWindow) { client in
            let start = Calendar.current.startOfDay(for: Date())
            return try await client.courseCalendarEvents(courseId: courseId, from: start, to: start.addingTimeInterval(CalendarWindow.length))
        })
    }

    var body: some View {
        PageScroll(spacing: 0, lazy: true) {
            EventList(events: loader.records, state: loader.state, showsLocation: false, courseNames: courseNames) { event in
                guard let plan = model.plan(for: event, courseId: courseId) else { return nil }
                return { navigation.open(plan, courseId: courseId) }
            }
        }
        .dividedRows()
        .task {
            async let events: Void = loader.load(using: model)
            async let plans: Void = model.loadPlans(courseId: courseId)
            _ = await (events, plans)
        }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await loader.refresh(using: model) })
    }
}

/// The signed-in person's calendar as a week grid, one block per event.
struct PersonalCalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @State private var weekStart = Self.defaultWeek()
    @State private var weekMemo = Memo<WeekKey, [ScheduleDay]>()
    @State private var events: [CalendarEvent] = []
    @State private var loadedWeek: Date?
    @State private var loadedSession: CollectionSession?
    @State private var activeRequest: UUID?
    @State private var failure: (request: WeekRequest, message: String)?
    @State private var isIncomplete = false

    private struct WeekRequest: Equatable {
        var week: Date
        var session: CollectionSession
    }

    private var request: WeekRequest {
        WeekRequest(week: weekStart, session: CollectionSession(model))
    }

    private var isShowingWeek: Bool { loadedWeek == weekStart && loadedSession == request.session }
    private var visibleEvents: [CalendarEvent] { isShowingWeek ? events : [] }
    @State private var mode: CalendarMode = .week
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: weekTitle) {
                HStack(spacing: Space.s8) {
                    if activeRequest != nil, !isShowingWeek { Spinner() }
                    SectionTabs(
                        selection: $mode,
                        items: CalendarMode.allCases.map { ($0, $0.label) },
                        identifier: { "calendar.mode.\($0.rawValue)" }
                    )
                    CalendarNavigation(
                        isWeek: mode == .week,
                        previous: { shift(-1) }, today: { goToToday() }, next: { shift(1) }
                    )
                }
            }
            .padding(.leading, Space.page)
            .padding(.trailing, Space.page)
            .padding(.top, Space.page)
            if let failure, failure.request == request {
                HStack(spacing: Space.s8) {
                    ErrorLine(failure.message)
                    TextButton("Retry") { Task { await load() } }
                        .disabled(activeRequest != nil)
                }
                .padding(.horizontal, Space.page)
            } else if isShowingWeek, isIncomplete {
                Text("Partial week")
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                    .padding(.horizontal, Space.page)
            }
            if case .event(let id) = navigation.searchTarget?.destination, let hit = navigation.searchTarget {
                PageScroll {
                    Button("Show calendar", systemImage: Symbol.back) { navigation.searchTarget = nil }
                    if let event = visibleEvents.first(where: { $0.eventId == id }) {
                        EventRow(event: event, showsLocation: true)
                            .padding(.horizontal, -Space.s8)
                    } else {
                        Text(hit.title).font(Type.t13)
                        if let date = hit.date { Text(date, style: .date) }
                        if let detail = hit.detail { Text(detail) }
                        Text(activeRequest == nil || isShowingWeek ? "Showing indexed details" : "Loading event…")
                            .font(Type.t11)
                            .foregroundStyle(Color.textMuted)
                    }
                }
            } else {
                WeekGrid(allDays: visibleDays, showsHeader: mode == .week)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Calendar")
        .onChange(of: mode) { _, mode in
            if mode == .day { weekStart = Self.start(of: selectedDay) }
        }
        .task(id: request) { await load() }
        .task(id: navigation.searchTarget?.id) {
            guard navigation.searchTarget?.kind == .event, let date = navigation.searchTarget?.date else { return }
            selectedDay = Calendar.current.startOfDay(for: date)
            weekStart = Self.start(of: date)
        }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await load() })
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        let target = request
        let id = UUID()
        activeRequest = id
        if loadedSession != target.session {
            loadedSession = target.session
            loadedWeek = nil
            events = []
        }
        failure = nil
        defer { if activeRequest == id { activeRequest = nil } }

        func isCurrent() -> Bool { !Task.isCancelled && activeRequest == id && target == request }

        if !isShowingWeek, let cached = await model.cachedWeekEvents(weekContaining: target.week) {
            guard isCurrent() else { return }
            events = cached.records
            loadedWeek = target.week
            isIncomplete = cached.coverage == .incomplete
        }
        guard isCurrent() else { return }
        let result = await model.loadWeekEvents(weekContaining: target.week)
        guard isCurrent() else { return }
        switch result {
        case .loaded(let items, let complete):
            events = items
            loadedWeek = target.week
            isIncomplete = !complete
        case .failed(let message):
            failure = (target, message)
        case .cancelled:
            break
        }
    }

    private func shift(_ steps: Int) {
        let calendar = Calendar.current
        if mode == .day {
            selectedDay = calendar.date(byAdding: .day, value: steps, to: selectedDay) ?? selectedDay
            let week = Self.start(of: selectedDay)
            if week != weekStart { weekStart = week }
        } else {
            weekStart = calendar.date(byAdding: .weekOfYear, value: steps, to: weekStart) ?? weekStart
            selectedDay = weekStart
        }
    }

    private func goToToday() {
        selectedDay = Calendar.current.startOfDay(for: Date())
        weekStart = mode == .day ? Self.start(of: selectedDay) : Self.defaultWeek(now: selectedDay)
    }

    private static func start(of date: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// The current week, or the coming one when only weekend days are left in it.
    static func defaultWeek(now: Date = Date(), calendar: Calendar = .current) -> Date {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return now }
        var day = calendar.startOfDay(for: now)
        while day < week.end {
            if !calendar.isDateInWeekend(day) { return week.start }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? week.end
        }
        return week.end
    }

    private var weekDays: [ScheduleDay] {
        weekMemo.value(for: WeekKey(events: visibleEvents, weekStart: weekStart)) {
            WeekSchedule.days(events: visibleEvents, weekContaining: weekStart, calendar: Calendar.current)
        }
    }

    /// Weekend days appear only when something is on, so the working week gets the width.
    private var visibleDays: [ScheduleDay] {
        let calendar = Calendar.current
        let all = weekDays
        if mode == .day {
            let one = all.filter { calendar.isDate($0.date, inSameDayAs: selectedDay) }
            return one.isEmpty ? Array(all.prefix(1)) : one
        }
        return all.filter { !calendar.isDateInWeekend($0.date) || !$0.blocks.isEmpty }
    }

    /// The range of the visible columns, so the header always matches the grid.
    private var weekTitle: String {
        let days = visibleDays
        let start = days.first?.date ?? weekStart
        let end = days.last?.date ?? (Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart)
        if mode == .day { return start.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
        let calendar = Calendar.current
        if end <= start || calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return start.formatted(.dateTime.month(.wide).year())
        }
        return (start..<end).formatted(.interval.month(.abbreviated).year())
    }
}

private enum CalendarMode: String, CaseIterable, Identifiable {
    case day, week
    var id: String { rawValue }
    var label: String { self == .day ? "Day" : "Week" }
}

/// Previous, Today and Next as plain buttons with no track, so they don't read as a second segmented control.
private struct CalendarNavigation: View {
    let isWeek: Bool
    let previous: () -> Void
    let today: () -> Void
    let next: () -> Void
    @State private var isHoveringToday = false

    var body: some View {
        HStack(spacing: 0) {
            IconButton(Symbol.back, label: isWeek ? "Previous week" : "Previous day", action: previous)
            // Always enabled so it reads as a button; on this week it simply stays put.
            Button(action: today) {
                Text("Today")
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(1)
                    .padding(.horizontal, Space.s8)
                    .frame(height: Size.controlSmall)
                    .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(isHoveringToday ? Color.hover : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(FocusRingButtonStyle())
            .focusEffectDisabled()
            .onHover { isHoveringToday = $0 }
            .help("Go to today")
            IconButton(Symbol.disclosure, label: isWeek ? "Next week" : "Next day", action: next)
        }
        .fixedSize()
    }
}

private struct WeekKey: Equatable {
    var events: [CalendarEvent]
    var weekStart: Date
}

/// Seven columns of hours with events placed by time. All-day events sit in a strip above.
private struct WeekGrid: View {
    let allDays: [ScheduleDay]
    /// The day names row; the single-day view leaves it out, since the page title says the day.
    var showsHeader = true
    /// Hour rows are sized so the week's events fill the view, within these bounds; the full day scrolls.
    private let hourHeightRange: ClosedRange<CGFloat> = 40...56
    private var headerHeight: CGFloat { showsHeader ? 32 : 0 }
    private let gutter: CGFloat = 50
    /// No room after the last column: rules and hairlines end at its closing border.
    private let edge: CGFloat = 0
    /// Narrower than this and a block's words break mid-word; the grid scrolls sideways instead.
    private let minColumn: CGFloat = 64

    /// The visible days, already filtered by the caller to match the header.
    private var days: [ScheduleDay] { allDays }

    private let hours: ClosedRange<Int> = 0...24

    private func minutes(_ date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    private var timedBlocks: [ScheduleBlock] { days.flatMap(\.blocks).filter { !isAllDay($0) } }

    /// Minutes after midnight, 15 before the first timed event of the week, or 7:30 when nothing is on.
    private var scrollMinutes: Int {
        let early = 7 * 60 + 30
        guard let first = timedBlocks.map({ minutes($0.start) }).min() else { return early }
        return max(first - 15, 0)
    }

    /// Hours the view should show: first event's lead-in to 30 minutes after the last, at least 8.
    private var visibleHours: Double {
        let blocks = timedBlocks
        guard !blocks.isEmpty else { return 8 }
        // An event that runs past midnight counts to the day's end.
        let last = blocks.map { Calendar.current.isDate($0.end, inSameDayAs: $0.start) ? minutes($0.end) : 24 * 60 }.max() ?? 0
        return max(Double(last + 30 - scrollMinutes) / 60, 8)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, gutter + edge + minColumn * CGFloat(max(days.count, 1)))
            let strip = allDayLayout(width: width)
            // The view's height less the header and all-day lane, shared by `visibleHours` hours.
            let viewport = proxy.size.height - headerHeight - strip.height - Space.s4 - (strip.spans.isEmpty ? 2 : 3)
            let hourHeight = min(max((viewport / CGFloat(visibleHours)).rounded(.down), hourHeightRange.lowerBound), hourHeightRange.upperBound)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    rule
                    if showsHeader {
                        header
                        rule
                    }
                    if !strip.spans.isEmpty {
                        allDayStrip(strip)
                        rule
                    }
                    ScrollViewReader { reader in
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 0) {
                                hourLabels(hourHeight: hourHeight)
                                ForEach(days) { day in
                                    DayColumn(day: day, hours: hours, hourHeight: hourHeight, isAllDay: isAllDay)
                                }
                                Color.clear.frame(width: edge, height: 1)
                            }
                            .background(alignment: .top) {
                                // An invisible marker at the start minute, so the view opens just before the first event.
                                VStack(spacing: 0) {
                                    Color.clear.frame(width: 1, height: CGFloat(scrollMinutes) / 60 * hourHeight)
                                    Color.clear.frame(width: 1, height: 1).id("grid.start")
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        // Margins, not padding, so scrolling still leaves the labels whole.
                        .contentMargins(.top, Space.s4, for: .scrollContent)
                        .contentMargins(.bottom, Space.s32, for: .scrollContent)
                        .onAppear { reader.scrollTo("grid.start", anchor: .top) }
                        .onChange(of: scrollMinutes) { _, _ in reader.scrollTo("grid.start", anchor: .top) }
                        .onChange(of: hourHeight) { _, _ in reader.scrollTo("grid.start", anchor: .top) }
                    }
                }
                // Behind the header, the all-day lane and the hours alike, so the day lines and
                // today's tint run the columns' full height.
                .background(alignment: .top) { columnBackdrop.padding(.top, 1) }
                .frame(width: width, height: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    /// One line at each day's leading edge and a closing one after the last; today's column is tinted.
    private var columnBackdrop: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            ForEach(days) { day in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Calendar.current.isDateInToday(day.date) ? Color.accent.opacity(0.05) : Color.clear)
                    Rectangle().fill(Color.border).frame(width: 1)
                }
                .overlay(alignment: .trailing) {
                    if day.id == days.last?.id { Rectangle().fill(Color.border).frame(width: 1) }
                }
                .frame(maxWidth: .infinity)
            }
            Color.clear.frame(width: edge)
        }
        .accessibilityHidden(true)
    }

    /// A hairline across the whole grid, gutter included.
    private var rule: some View {
        Rectangle().fill(Color.border).frame(height: 1).accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days) { day in
                let isToday = Calendar.current.isDateInToday(day.date)
                HStack(spacing: Space.s4) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                    Text(day.date.formatted(.dateTime.day()))
                        .font(isToday ? Type.t13.weight(.semibold) : Type.t13)
                        .foregroundStyle(isToday ? Color.onAccent : Color.text)
                        .monospacedDigit()
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Circle().fill(isToday ? Color.accentFill : Color.clear))
                }
                .padding(.leading, days.count == 1 ? Space.s8 : 0)
                .frame(maxWidth: .infinity, minHeight: headerHeight, alignment: days.count == 1 ? .leading : .center)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("calendar.day.\(Int(day.date.timeIntervalSince1970))")
            }
            Color.clear.frame(width: edge, height: 1)
        }
    }

    /// One chip per all-day event, spanning every visible day it covers; rows keep overlapping chips apart.
    private struct AllDaySpan: Identifiable {
        var block: ScheduleBlock
        var first: Int
        var last: Int
        var row = 0
        var id: String { "\(block.event.eventId)-\(first)" }
    }

    private var allDaySpans: [AllDaySpan] {
        var spans: [AllDaySpan] = []
        for (index, day) in days.enumerated() {
            for block in day.blocks.filter(isAllDay) {
                if let k = spans.firstIndex(where: { $0.block.event.eventId == block.event.eventId && $0.last == index - 1 }) {
                    spans[k].last = index
                } else {
                    spans.append(AllDaySpan(block: block, first: index, last: index))
                }
            }
        }
        var rowEnds: [Int] = []
        for k in spans.indices {
            let row = rowEnds.firstIndex { $0 < spans[k].first } ?? rowEnds.count
            if row == rowEnds.count { rowEnds.append(spans[k].last) } else { rowEnds[row] = spans[k].last }
            spans[k].row = row
        }
        return spans
    }

    private struct AllDayLayout {
        var spans: [AllDaySpan]
        var rows: Int
        var rowHeight: CGFloat
        /// The lane's height, with its bottom gap; zero when no all-day event is on.
        var height: CGFloat { spans.isEmpty ? 0 : CGFloat(rows) * rowHeight + Space.s2 }
    }

    private func allDayLayout(width: CGFloat) -> AllDayLayout {
        let spans = allDaySpans
        let rows = (spans.map(\.row).max() ?? 0) + 1
        let column = max(width - gutter - edge, 1) / CGFloat(max(days.count, 1))
        // 30pt rows; 40pt when some title is too long for one line of its chip.
        let wraps = spans.contains { span in
            let chars = (span.block.event.title ?? "").count
            return CGFloat(chars) * 6.5 > column * CGFloat(span.last - span.first + 1) - 16
        }
        return AllDayLayout(spans: spans, rows: rows, rowHeight: wraps ? 40 : 30)
    }

    private func allDayStrip(_ layout: AllDayLayout) -> some View {
        let rowHeight = layout.rowHeight
        let laneHeight = CGFloat(layout.rows) * rowHeight
        return HStack(alignment: .top, spacing: 0) {
            Text("All day")
                .font(Type.t11)
                .foregroundStyle(Color.textMuted)
                .lineLimit(1)
                .padding(.trailing, Space.s6)
                .frame(width: gutter, height: laneHeight, alignment: .trailing)
            // Measured, so chips match the day columns below exactly.
            GeometryReader { grid in
                let col = grid.size.width / CGFloat(max(days.count, 1))
                ForEach(layout.spans) { span in
                    let count = CGFloat(span.last - span.first + 1)
                    EventBlock(block: span.block, compact: true)
                        .frame(width: max(col * count - Space.s8, 8), height: rowHeight - Space.s4)
                        .offset(x: col * CGFloat(span.first) + Space.s4, y: CGFloat(span.row) * rowHeight + Space.s2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: laneHeight)
            Color.clear.frame(width: edge, height: 1)
        }
        .padding(.bottom, Space.s2)
    }

    private func hourLabels(hourHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(hours.dropLast()), id: \.self) { hour in
                Text(Self.hourText(hour))
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                    .padding(.trailing, Space.s6)
                    .frame(width: gutter, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -6)
            }
        }
        .frame(width: gutter)
        .accessibilityHidden(true)
    }

    private static func hourText(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    private func isAllDay(_ block: ScheduleBlock) -> Bool {
        block.end.timeIntervalSince(block.start) >= 23 * 3600
    }
}

private struct DayColumn: View {
    let day: ScheduleDay
    let hours: ClosedRange<Int>
    let hourHeight: CGFloat
    let isAllDay: (ScheduleBlock) -> Bool

    var body: some View {
        let timed = day.blocks.filter { !isAllDay($0) }
        let lanes = Self.lanes(timed)
        let height = CGFloat(hours.count - 1) * hourHeight
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(hours.dropLast()), id: \.self) { hour in
                    // The divider under the header already draws the top edge.
                    Rectangle().fill(hour == hours.lowerBound ? Color.clear : Color.border).frame(height: 1)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: height)
            if Calendar.current.isDateInToday(day.date) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.accent).frame(height: 1.5)
                        Circle().fill(Color.accent).frame(width: 7, height: 7).offset(x: -3)
                    }
                    .offset(y: offset(context.date) - 3.5)
                    .opacity(isVisible(context.date) ? 1 : 0)
                }
                .frame(height: height, alignment: .top)
                .allowsHitTesting(false)
                .zIndex(1)
            }
            GeometryReader { proxy in
                ForEach(timed) { block in
                    let lane = lanes[block.id] ?? (0, 1)
                    // Overlapping events cascade: each later one sits a step right and on top, so
                    // every block keeps most of the column and its words stay whole.
                    let step = min(Self.cascadeStep, (proxy.size.width - Space.s8) / CGFloat(lane.count + 1))
                    let inset = CGFloat(lane.index) * step
                    let blockHeight = max(offset(block.end) - offset(block.start) - 2, 18)
                    EventBlock(block: block, compact: false, height: blockHeight)
                        .frame(width: max(proxy.size.width - inset - Space.s8, 8), height: blockHeight, alignment: .topLeading)
                        .offset(x: inset + Space.s4, y: offset(block.start) + 1)
                }
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
    }

    private func isVisible(_ date: Date) -> Bool {
        let y = offset(date)
        return y >= 0 && y <= CGFloat(hours.count - 1) * hourHeight
    }

    private func offset(_ date: Date) -> CGFloat {
        let calendar = Calendar.current
        let minutes = date.timeIntervalSince(calendar.startOfDay(for: day.date)) / 60
        return CGFloat(minutes / 60 - Double(hours.lowerBound)) * hourHeight
    }

    static let cascadeStep: CGFloat = 18

    /// Lanes for overlapping events.
    private static func lanes(_ blocks: [ScheduleBlock]) -> [String: (index: Int, count: Int)] {
        var result: [String: (Int, Int)] = [:]
        var cluster: [(ScheduleBlock, Int)] = []
        var laneEnds: [Date] = []
        var clusterEnd = Date.distantPast
        func flush() {
            for (block, lane) in cluster { result[block.id] = (lane, laneEnds.count) }
            cluster = []
            laneEnds = []
        }
        for block in blocks.sorted(by: { $0.start < $1.start }) {
            if block.start >= clusterEnd { flush() }
            let lane = laneEnds.firstIndex { $0 <= block.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(block.end) } else { laneEnds[lane] = block.end }
            cluster.append((block, lane))
            clusterEnd = max(clusterEnd, block.end)
        }
        flush()
        return result
    }
}

private struct EventBlock: View {
    @Environment(AppModel.self) private var model
    let block: ScheduleBlock
    let compact: Bool
    var height: CGFloat = 0

    /// The course's short name leads; the event's own title follows when it says something else.
    private var courseName: String? {
        if let id = block.event.courseId, let course = model.courses.first(where: { $0.courseId == id }) {
            return course.shortTitle
        }
        return block.event.displayLocation.map(Course.shortName).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var title: String? {
        block.event.title.map(Course.shortName).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var heading: String { courseName ?? title ?? "Untitled event" }

    /// The course's hue, or nil for events with no course.
    private var tint: Color? { courseId.map(Color.course) }

    /// The event's course id, or that of the course its title or room names.
    private var courseId: Int? {
        if let id = block.event.courseId { return id }
        let names = [block.event.title, block.event.displayLocation].compactMap { $0 }.map(Course.shortName)
        return model.courses.first { names.contains($0.shortTitle) }?.courseId
    }

    private var detail: String? {
        guard courseName != nil, let title, title != courseName else { return nil }
        return title
    }
    @Environment(\.colorScheme) private var scheme
    @State private var isShowingDetails = false
    @State private var isHovering = false

    /// The course colour, darkened in light mode so its words keep contrast on the pale fill.
    private var titleStyle: Color {
        guard let tint else { return Color.text }
        return tint
    }

    /// "8.00–9.30 AM", then the room when the event has one.
    private var timeLine: String {
        var text = block.end > block.start
            ? StudyDates.timeRange(block.start, block.end)
            : StudyDates.time(block.start)
        if let room = block.event.displayLocation, !room.isEmpty, Course.shortName(room) != courseName {
            text += " · " + room
        }
        return text
    }

    private var titleDarken: Double { scheme == .light && tint != nil ? -0.25 : 0 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
        // Past events fade their colour only, so their words keep full contrast.
        let fade = block.end < Date() ? 0.65 : 1
        Button { isShowingDetails = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(heading)
                    .font(Type.t12.weight(.semibold))
                    .foregroundStyle(titleStyle)
                    .brightness(titleDarken)
                    .lineLimit(compact || height >= 52 ? 2 : 1)
                    .truncationMode(.tail)
                if !compact {
                    Text(timeLine)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                    if let detail, height >= 76 {
                        Text(detail)
                            .font(Type.t11)
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.leading, Space.s4 + (tint == nil ? 0 : Self.barInset + 3))
            .padding(.trailing, Space.s4)
            .padding(.vertical, Space.s2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A thin bar inside the block, as in Calendar, rather than an edge that bends round the corner.
            .background(alignment: .leading) {
                if let tint {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tint.opacity(fade))
                        .frame(width: 3)
                        .padding(.vertical, Self.barInset)
                        .padding(.leading, Self.barInset)
                }
            }
            // Opaque, with an edge in the column's colour, so a block on top of another reads as its own.
            .background(shape.fill(tint.map { $0.opacity((scheme == .light ? 0.16 : 0.22) * fade) } ?? Color.accentTint.opacity(fade)))
            .background(shape.fill(isHovering ? Color.hover : Color.clear))
            .background(shape.fill(Color.stage))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.stage, lineWidth: 1))
            .overlay { if isShowingDetails { shape.strokeBorder(tint ?? Color.accent, lineWidth: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(FocusRingButtonStyle(cornerRadius: Radius.s))
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .clipped()
        .help([courseName, block.event.title].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "\n"))
        .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
            EventDetails(event: block.event)
        }
        .accessibilityLabel([heading, detail, block.start.formatted(.dateTime.weekday(.wide).day().month()),
                             block.end > block.start ? StudyDates.timeRange(block.start, block.end) : StudyDates.time(block.start)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows details")
    }

    /// Space between the bar and the block's edges.
    private static let barInset: CGFloat = 2
}

private struct EventDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    let event: CalendarEvent

    /// "Tuesday 18 November, 8:00–9:30 AM", with both days when the event spans two.
    private static func when(_ start: Date, _ end: Date) -> String {
        let day = Date.FormatStyle.dateTime.weekday().day().month()
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(start.formatted(day)), \(StudyDates.timeRange(start, end))"
        }
        return "\(start.formatted(day)), \(StudyDates.time(start)) – \(end.formatted(day)), \(StudyDates.time(end))"
    }

    /// True when the course line would only repeat the title or room.
    private func repeats(_ course: Course) -> Bool {
        let known = [course.title, course.shortTitle, course.displayTitle].map { $0.lowercased() }
        return [event.title, event.displayLocation].compactMap { $0?.lowercased() }.contains { known.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            Text(event.title ?? "Untitled event")
                .font(Type.t13.weight(.semibold))
                .foregroundStyle(Color.text)
                .fixedSize(horizontal: false, vertical: true)
            if let start = event.fromDate {
                let end = max(event.toDate ?? start, start)
                Text(Self.when(start, end))
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
            }
            if let location = event.displayLocation, !location.isEmpty {
                Text(location).font(Type.t12).foregroundStyle(Color.textMuted)
            }
            if let id = event.courseId, let course = model.courses.first(where: { $0.courseId == id }),
               !repeats(course) {
                Text(course.title).font(Type.t12).foregroundStyle(Color.textMuted)
            }
            if let text = event.eventDescription, !text.isEmpty {
                RichTextView(html: text)
            }
            if let course = event.courseId {
                // The lesson's own plan when one covers this time, otherwise the course.
                if let plan = model.plan(for: event, courseId: course) {
                    TextButton("Open plan") { navigation.open(plan, courseId: course) }
                } else {
                    TextButton("Open course") { model.selection = .course(course) }
                }
            }
        }
        .padding(Space.s12)
        .frame(width: 280, alignment: .leading)
        .task(id: event.id) { await model.loadPlansIfNeeded(for: event) }
    }
}
