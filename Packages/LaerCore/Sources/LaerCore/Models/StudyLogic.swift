import Foundation

extension Course {
    /// The course name without a trailing term or campus, such as ", spring 26. City."
    /// The full title stays available for tooltips.
    public var shortTitle: String { Self.shortName(displayTitle) }

    /// The same shortening for names that arrive as plain text, such as an event's location.
    public static func shortName(_ source: String) -> String {
        guard let range = source.range(of: #",[^,]*\d{2,4}[^,]*$"#, options: .regularExpression) else {
            return source.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = source[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? source : name
    }
}

/// A far-future placeholder year is not a real date.
func realDate(_ date: Date?) -> Date? {
    guard let date else { return nil }
    return Calendar(identifier: .gregorian).component(.year, from: date) >= 9000 ? nil : date
}

public struct PlanSections: Sendable, Equatable {
    /// The current lecture, or the next one if none is running.
    public var next: PlanPreview?
    public var upcoming: [PlanPreview]
    /// Newest first.
    public var previous: [PlanPreview]
    /// Plans without dates, such as course information, in their source order.
    public var undated: [PlanPreview]

    public init(next: PlanPreview? = nil, upcoming: [PlanPreview] = [], previous: [PlanPreview] = [], undated: [PlanPreview] = []) {
        self.next = next
        self.upcoming = upcoming
        self.previous = previous
        self.undated = undated
    }
}

public enum PlanOrder {
    public static func sections(_ plans: [PlanPreview], now: Date) -> PlanSections {
        var result = PlanSections()
        var current: [(plan: PlanPreview, start: Date)] = []
        var ended: [(plan: PlanPreview, end: Date)] = []
        for plan in plans {
            let start = realDate(plan.start)
            let stop = realDate(plan.stop)
            guard let anchor = start ?? stop else {
                result.undated.append(plan)
                continue
            }
            let end = stop ?? start ?? anchor
            if end >= now {
                current.append((plan, anchor))
            } else {
                ended.append((plan, end))
            }
        }
        let ordered = current.sorted { $0.start < $1.start }.map(\.plan)
        result.next = ordered.first
        result.upcoming = Array(ordered.dropFirst())
        result.previous = ended.sorted { $0.end > $1.end }.map(\.plan)
        return result
    }
}

public struct ScheduleBlock: Identifiable, Sendable, Hashable {
    public var event: CalendarEvent
    public var start: Date
    public var end: Date

    public var id: String { "\(event.eventId)-\(start.timeIntervalSince1970)" }
}

public struct ScheduleDay: Identifiable, Sendable, Hashable {
    public var date: Date
    public var blocks: [ScheduleBlock]

    public var id: Date { date }
}

public enum WeekSchedule {
    /// Seven days starting on the calendar's first weekday. An event crossing midnight appears on both days.
    public static func days(events: [CalendarEvent], weekContaining date: Date, calendar: Calendar) -> [ScheduleDay] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return (0..<7).compactMap { offset -> ScheduleDay? in
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: week.start),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            let blocks = events.compactMap { event -> ScheduleBlock? in
                guard let from = realDate(event.fromDate) else { return nil }
                let to = max(realDate(event.toDate) ?? from, from)
                guard from < dayEnd, to > dayStart || from >= dayStart else { return nil }
                return ScheduleBlock(event: event, start: max(from, dayStart), end: min(to, dayEnd))
            }
            return ScheduleDay(date: dayStart, blocks: blocks.sorted { ($0.start, $0.event.eventId) < ($1.start, $1.event.eventId) })
        }
    }
}

public struct UpcomingSections: Sendable, Equatable {
    public var overdue: [StudyTask] = []
    public var today: [StudyTask] = []
    public var thisWeek: [StudyTask] = []
    public var later: [StudyTask] = []
    public var noDeadline: [StudyTask] = []

    public init() {}
}

public enum UpcomingList {
    /// An empty active set means no filter, so a person with no starred courses still sees tasks.
    public static func sections(_ tasks: [StudyTask], activeCourseIds: Set<Int>, now: Date, calendar: Calendar) -> UpcomingSections {
        var result = UpcomingSections()
        // A rolling week, so something due on Monday isn't "later" when it's Saturday.
        let startOfToday = calendar.startOfDay(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 8, to: startOfToday) ?? now
        let visible = tasks.filter { task in
            guard !activeCourseIds.isEmpty, let course = task.courseId else { return true }
            return activeCourseIds.contains(course)
        }
        for task in visible {
            guard let deadline = realDate(task.deadline) else {
                result.noDeadline.append(task)
                continue
            }
            if deadline < now {
                result.overdue.append(task)
            } else if calendar.isDate(deadline, inSameDayAs: now) {
                result.today.append(task)
            } else if deadline < weekEnd {
                result.thisWeek.append(task)
            } else {
                result.later.append(task)
            }
        }
        let byDeadline: (StudyTask, StudyTask) -> Bool = { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
        result.overdue.sort { ($0.deadline ?? .distantPast) > ($1.deadline ?? .distantPast) }
        result.today.sort(by: byDeadline)
        result.thisWeek.sort(by: byDeadline)
        result.later.sort(by: byDeadline)
        result.noDeadline.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result
    }
}
