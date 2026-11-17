import LaerCore
import SwiftUI

/// Events grouped by day, in the user's calendar and time zone.
struct EventList: View {
    let events: [CalendarEvent]
    let state: CollectionState
    var showsLocation = true

    var body: some View {
        FreshnessLine(state: state)
        if events.isEmpty {
            EmptyState(state: state, empty: "No events in this period")
        }
        ForEach(days, id: \.day) { group in
            Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(Type.t12)
                .foregroundStyle(Color.textMuted)
                .padding(.top, Space.s16)
                .accessibilityAddTraits(.isHeader)
            ForEach(group.events) { event in
                EventRow(event: event, showsLocation: showsLocation)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s12) {
            Text(timeText)
                .font(Type.t12)
                .foregroundStyle(Color.textMuted)
                .monospacedDigit()
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(event.title ?? "Untitled event")
                    .font(Type.t13)
                    .foregroundStyle(Color.text)
                    .lineLimit(2)
                if showsLocation, let location = event.displayLocation, !location.isEmpty {
                    Text(location)
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
                if let text = event.eventDescription, !text.isEmpty {
                    Text(PlainText.from(text))
                        .font(Type.t12)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .plainRow()
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        guard let start = event.fromDate else { return "" }
        guard let end = event.toDate, end > start else {
            return start.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDate(start, inSameDayAs: end),
           Calendar.current.dateComponents([.hour, .minute], from: start, to: end).hour ?? 0 >= 23 {
            return "All day"
        }
        return (start..<end).formatted(.interval.hour().minute())
    }
}

enum CalendarWindow {
    /// How far ahead the calendar screens read.
    static let length: TimeInterval = 90 * 24 * 3600
}

/// A course's events for the coming weeks.
struct CourseCalendarView: View {
    @Environment(AppModel.self) private var model
    @State private var loader: CollectionLoader<CalendarEvent>

    init(course: Course) {
        let courseId = course.courseId
        _loader = State(initialValue: CollectionLoader(key: "course-calendar-\(courseId)", coverage: .recentWindow) { client in
            let start = Calendar.current.startOfDay(for: Date())
            return try await client.courseCalendarEvents(courseId: courseId, from: start, to: start.addingTimeInterval(CalendarWindow.length))
        })
    }

    var body: some View {
        PageScroll(spacing: 0, lazy: true) {
            EventList(events: loader.records, state: loader.state, showsLocation: false)
        }
        .dividedRows()
        .task { await loader.load(using: model) }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await loader.refresh(using: model) })
    }
}

/// The signed-in person's calendar as a week grid, one block per event.
struct PersonalCalendarView: View {
    @Environment(AppModel.self) private var model
    @State private var weekStart = Self.defaultWeek()
    @State private var weekMemo = Memo<WeekKey, [ScheduleDay]>()
    @State private var events: [CalendarEvent] = []
    @State private var loadedWeek: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: weekTitle) {
                HStack(spacing: Space.s4) {
                    if loadedWeek != weekStart { Spinner() }
                    IconButton(Symbol.back, label: "Previous week") { shift(-1) }
                    TextButton("This week") { weekStart = Self.defaultWeek() }
                        .disabled(weekStart == Self.defaultWeek())
                    IconButton(Symbol.disclosure, label: "Next week") { shift(1) }
                }
            }
            .padding(.horizontal, Space.s24)
            .padding(.vertical, Space.s16)
            WeekGrid(allDays: weekMemo.value(for: WeekKey(events: events, weekStart: weekStart)) {
                WeekSchedule.days(events: events, weekContaining: weekStart, calendar: .current)
            })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Calendar")
        .task(id: weekStart) { await load() }
        .focusedSceneValue(\.refreshCurrent, RefreshAction { await load() })
    }

    private func load() async {
        let week = weekStart
        // Saved events show first, with no spinner; the network answer replaces them.
        if loadedWeek != week {
            let cached = await model.cachedEvents(weekContaining: week)
            guard week == weekStart else { return }
            if !cached.isEmpty {
                events = cached
                loadedWeek = week
            }
        }
        let found = await model.events(weekContaining: week)
        guard week == weekStart else { return }
        events = found
        loadedWeek = week
    }

    private func shift(_ weeks: Int) {
        weekStart = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: weekStart) ?? weekStart
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

    private var weekTitle: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return (weekStart..<end).formatted(.interval.day().month(.abbreviated).year())
    }
}

private struct WeekKey: Equatable {
    var events: [CalendarEvent]
    var weekStart: Date
}

/// Seven columns of hours with events placed by time. All-day events sit in a strip above.
private struct WeekGrid: View {
    let allDays: [ScheduleDay]
    private let minHourHeight: CGFloat = 36
    private let gutter: CGFloat = 50
    /// Narrower than this and a block's words break mid-word; the grid scrolls sideways instead.
    private let minColumn: CGFloat = 76
    /// Room for the weekday header and the top hour label.
    private let chromeHeight: CGFloat = 60

    /// Weekend days appear only when something is on, so the working week gets the width.
    private var days: [ScheduleDay] {
        let calendar = Calendar.current
        return allDays.filter { !calendar.isDateInWeekend($0.date) || !$0.blocks.isEmpty }
    }

    private var hours: ClosedRange<Int> {
        let calendar = Calendar.current
        let timed = days.flatMap(\.blocks).filter { !isAllDay($0) }
        let first = timed.map { calendar.component(.hour, from: $0.start) }.min() ?? 8
        let last = timed.map { block -> Int in
            let hour = calendar.component(.hour, from: block.end)
            return calendar.component(.minute, from: block.end) > 0 ? hour + 1 : hour
        }.max() ?? 17
        return min(first, 8)...max(min(last, 24), 17)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, gutter + minColumn * CGFloat(max(days.count, 1)))
            // A normal day fits the window without scrolling.
            let hourHeight = max(minHourHeight, (proxy.size.height - chromeHeight) / CGFloat(max(hours.count - 1, 1)))
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    header
                    if days.contains(where: { $0.blocks.contains(where: isAllDay) }) { allDayStrip }
                    Rectangle().fill(Color.border).frame(height: 1)
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            hourLabels(hourHeight: hourHeight)
                            ForEach(days) { day in
                                DayColumn(day: day, hours: hours, hourHeight: hourHeight, isAllDay: isAllDay)
                                    .overlay(alignment: .leading) { Rectangle().fill(Color.border).frame(width: 1) }
                            }
                        }
                        .padding(.top, Space.s8)
                        .padding(.bottom, Space.s8)
                    }
                }
                .frame(width: width, height: proxy.size.height)
            }
            .scrollDisabled(width <= proxy.size.width)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days) { day in
                let isToday = Calendar.current.isDateInToday(day.date)
                VStack(spacing: Space.s2) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                    Text(day.date.formatted(.dateTime.day()))
                        .font(isToday ? Type.t15 : Type.t13)
                        .foregroundStyle(Color.text)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, Space.s6)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private var allDayStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("All day")
                .font(Type.t11)
                .foregroundStyle(Color.textMuted)
                .padding(.leading, Space.s6)
                .frame(width: gutter, alignment: .leading)
            ForEach(days) { day in
                VStack(spacing: Space.s2) {
                    ForEach(day.blocks.filter(isAllDay)) { block in
                        EventBlock(block: block, compact: true)
                            .frame(height: Size.controlSmall - Space.s2)
                    }
                }
                .padding(.horizontal, Space.s2)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.bottom, Space.s4)
    }

    private func hourLabels(hourHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(hours.dropLast()), id: \.self) { hour in
                Text(Self.hourText(hour))
                    .font(Type.t11)
                    .foregroundStyle(Color.textMuted)
                    .monospacedDigit()
                    .padding(.leading, Space.s6)
                    .frame(width: gutter, height: hourHeight, alignment: .topLeading)
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
                ForEach(Array(hours.dropLast()), id: \.self) { _ in
                    Rectangle().fill(Color.border).frame(height: 1)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: height)
            if Calendar.current.isDateInToday(day.date) {
                Color.accentTint.opacity(0.4).frame(height: height)
            }
            GeometryReader { proxy in
                ForEach(timed) { block in
                    let lane = lanes[block.id] ?? (0, 1)
                    // Overlapping events cascade: each later one sits a step right and on top, so
                    // every block keeps most of the column and its words stay whole.
                    let step = min(Self.cascadeStep, proxy.size.width / CGFloat(lane.count + 1))
                    let inset = CGFloat(lane.index) * step
                    EventBlock(block: block, compact: false)
                        .frame(width: max(proxy.size.width - inset - Space.s4, 8), height: max(offset(block.end) - offset(block.start) - 2, 18), alignment: .topLeading)
                        .offset(x: inset + Space.s2, y: offset(block.start) + 1)
                }
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
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

    private var detail: String? {
        guard courseName != nil, let title, title != courseName else { return nil }
        return title
    }
    @State private var isShowingDetails = false
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
        Button { isShowingDetails = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(heading)
                    .font(Type.t11.weight(.semibold))
                    .foregroundStyle(Color.text)
                    .lineLimit(compact ? 1 : 2)
                if !compact {
                    Text(block.start.formatted(date: .omitted, time: .shortened))
                        .font(Type.t11)
                        .foregroundStyle(Color.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(Type.t11)
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Opaque, with an edge in the column's colour, so a block on top of another reads as its own.
            .background(shape.fill(Color.accentTint))
            .background(shape.fill(Color.stage))
            .overlay(shape.strokeBorder(Color.stage, lineWidth: 1))
            .background(shape.fill(isHovering ? Color.hover : Color.clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .clipped()
        .help([courseName, block.event.title].compactMap { $0 }.joined(separator: "\n"))
        .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
            EventDetails(event: block.event)
        }
        .accessibilityLabel([heading, detail, block.start.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct EventDetails: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            Text(event.title ?? "Untitled event")
                .font(Type.t13.weight(.semibold))
                .foregroundStyle(Color.text)
                .fixedSize(horizontal: false, vertical: true)
            if let start = event.fromDate {
                let end = max(event.toDate ?? start, start)
                Text((start..<end).formatted(.interval.weekday().day().month().hour().minute()))
                    .font(Type.t12)
                    .foregroundStyle(Color.textMuted)
            }
            if let location = event.displayLocation, !location.isEmpty {
                Text(location).font(Type.t12).foregroundStyle(Color.textMuted)
            }
            if let text = event.eventDescription, !text.isEmpty {
                Text(PlainText.from(text))
                    .font(Type.t12)
                    .foregroundStyle(Color.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let course = event.courseId {
                TextButton("Open course") { model.selection = .course(course) }
            }
        }
        .padding(Space.s12)
        .frame(width: 280, alignment: .leading)
    }
}
