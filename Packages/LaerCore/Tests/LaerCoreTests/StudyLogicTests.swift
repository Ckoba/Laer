import Foundation
import Testing
@testable import LaerCore

private func date(_ text: String) -> Date { APIDate.parse(text)! }

private func plan(_ id: Int, start: String?, stop: String?) -> PlanPreview {
    let parts: [String] = [
        "\"id\":\(id)",
        start.map { "\"start\":\"\($0)\"" } ?? "\"start\":null",
        stop.map { "\"stop\":\"\($0)\"" } ?? "\"stop\":null",
    ]
    let json = "{\(parts.joined(separator: ","))}"
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = APIDate.decoding
    return try! decoder.decode(PlanPreview.self, from: Data(json.utf8))
}

private func task(_ id: Int, deadline: String?, course: Int? = 1) -> StudyTask {
    var parts = ["\"TaskId\":\(id)", "\"Title\":\"Task \(id)\""]
    if let deadline { parts.append("\"Deadline\":\"\(deadline)\"") }
    if let course { parts.append("\"LocationId\":\(course)") }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = APIDate.decoding
    return try! decoder.decode(StudyTask.self, from: Data("{\(parts.joined(separator: ","))}".utf8))
}

private func event(_ id: Int, from: String, to: String) -> CalendarEvent {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = APIDate.decoding
    return try! decoder.decode(CalendarEvent.self, from: Data("{\"EventId\":\(id),\"EventTitle\":\"E\",\"FromDate\":\"\(from)\",\"ToDate\":\"\(to)\"}".utf8))
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

@Suite struct ShortTitleTests {
    @Test(arguments: [
        ("Public Policy, spring 26.  City.", "Public Policy"),
        ("Survey of Students, autumn 2025", "Survey of Students"),
        ("Introduction (E24)", "Introduction (E24)"),
        ("Politics, Power and People", "Politics, Power and People"),
    ])
    func stripsOnlyTermSuffix(input: String, expected: String) {
        #expect(Course(courseId: 1, title: input).shortTitle == expected)
    }
}

@Suite struct PlanOrderTests {
    let now = date("2030-03-10T12:00:00Z")

    @Test func nextIsTheCurrentOrSoonestLecture() {
        let sections = PlanOrder.sections([
            plan(1, start: "2030-01-01T10:00:00Z", stop: "2030-01-01T12:00:00Z"),
            plan(2, start: "2030-03-17T10:00:00Z", stop: "2030-03-17T12:00:00Z"),
            plan(3, start: "2030-03-10T11:00:00Z", stop: "2030-03-10T13:00:00Z"),
            plan(4, start: "2030-02-01T10:00:00Z", stop: "2030-02-01T12:00:00Z"),
            plan(5, start: nil, stop: nil),
        ], now: now)
        #expect(sections.next?.planId == 3)
        #expect(sections.upcoming.map(\.planId) == [2])
        #expect(sections.previous.map(\.planId) == [4, 1])
        #expect(sections.undated.map(\.planId) == [5])
    }

    @Test func placeholderDatesCountAsUndated() {
        let sections = PlanOrder.sections([plan(1, start: "9999-12-31T00:00:00Z", stop: nil)], now: now)
        #expect(sections.undated.count == 1)
        #expect(sections.next == nil)
    }
}

@Suite struct WeekScheduleTests {
    @Test func placesBlocksOnTheirDaysInOrder() {
        let days = WeekSchedule.days(events: [
            event(2, from: "2030-03-12T14:00:00Z", to: "2030-03-12T16:00:00Z"),
            event(1, from: "2030-03-12T08:00:00Z", to: "2030-03-12T10:00:00Z"),
            event(3, from: "2030-03-20T08:00:00Z", to: "2030-03-20T10:00:00Z"),
        ], weekContaining: date("2030-03-13T12:00:00Z"), calendar: utc)
        #expect(days.count == 7)
        #expect(days[1].blocks.map(\.event.eventId) == [1, 2])
        #expect(days.flatMap(\.blocks).count == 2)
    }

    @Test func eventOverMidnightAppearsOnBothDays() {
        let days = WeekSchedule.days(events: [event(1, from: "2030-03-12T22:00:00Z", to: "2030-03-13T02:00:00Z")], weekContaining: date("2030-03-13T12:00:00Z"), calendar: utc)
        #expect(days[1].blocks.count == 1)
        #expect(days[2].blocks.count == 1)
    }
}

@Suite struct UpcomingListTests {
    let now = date("2030-03-12T12:00:00Z")

    @Test func groupsByDeadlineForActiveCourses() {
        let sections = UpcomingList.sections([
            task(1, deadline: "2030-03-11T12:00:00Z"),
            task(2, deadline: "2030-03-12T18:00:00Z"),
            task(3, deadline: "2030-03-15T18:00:00Z"),
            task(4, deadline: "2030-04-15T18:00:00Z"),
            task(5, deadline: nil),
            task(6, deadline: "2030-03-12T18:00:00Z", course: 2),
        ], activeCourseIds: [1], now: now, calendar: utc)
        #expect(sections.overdue.map(\.taskId) == [1])
        #expect(sections.today.map(\.taskId) == [2])
        #expect(sections.thisWeek.map(\.taskId) == [3])
        #expect(sections.later.map(\.taskId) == [4])
        #expect(sections.noDeadline.map(\.taskId) == [5])
    }

    @Test func thisWeekRollsOverTheWeekend() {
        let saturday = date("2030-03-16T12:00:00Z")
        let sections = UpcomingList.sections([task(1, deadline: "2030-03-18T18:00:00Z")], activeCourseIds: [], now: saturday, calendar: utc)
        #expect(sections.thisWeek.map(\.taskId) == [1])
    }

    @Test func noActiveCoursesMeansNoFilter() {
        let sections = UpcomingList.sections([task(1, deadline: nil, course: 9)], activeCourseIds: [], now: now, calendar: utc)
        #expect(sections.noDeadline.count == 1)
    }
}

@Suite struct SearchIndexTests {
    private func index() -> SearchIndex {
        var index = SearchIndex()
        index.replace(group: "a", with: [
            SearchHit(id: "1", kind: .material, title: "Økonomi slides.PPTX", courseId: 1),
            SearchHit(id: "2", kind: .plan, title: "Week 3 reading", detail: "macro economics", courseId: 2),
            SearchHit(id: "3", kind: .task, title: "Essay draft", courseId: 1),
        ])
        return index
    }

    @Test func matchesAcrossKindsIgnoringAccents() {
        #expect(index().search("okonomi", scope: .everywhere, activeCourseIds: []).map(\.id) == ["1"])
    }

    @Test func titleBeatsDetailAndAllWordsMustMatch() {
        #expect(index().search("reading macro", scope: .everywhere, activeCourseIds: []).map(\.id) == ["2"])
        #expect(index().search("essay missing", scope: .everywhere, activeCourseIds: []).isEmpty)
    }

    @Test func filtersByScopeKindAndFormat() {
        let index = index()
        #expect(index.search("e", scope: .course(2), activeCourseIds: []).map(\.id) == ["2"])
        #expect(index.search("e", scope: .activeCourses, activeCourseIds: [1]).allSatisfy { $0.courseId == 1 })
        #expect(index.search("", scope: .everywhere, activeCourseIds: [], fileExtension: "pptx").map(\.id) == ["1"])
        #expect(index.search("essay", scope: .everywhere, activeCourseIds: [], kinds: [.plan]).isEmpty)
    }

    @Test func replacingAGroupKeepsOthers() {
        var index = index()
        index.replace(group: "b", with: [SearchHit(id: "9", kind: .event, title: "Lecture")])
        index.replace(group: "a", with: [])
        #expect(index.count == 1)
    }

    @Test func preservesDistinctFilesWithTheSameNameAndDeduplicatesByIdentity() {
        var index = SearchIndex()
        let first = SearchHit(id: "material-17", kind: .material, title: "Notes.pdf", courseId: 1)
        let second = SearchHit(id: "material-28", kind: .material, title: "Notes.pdf", courseId: 1)
        index.replace(group: "plan", with: [first])
        index.replace(group: "folder", with: [first, second])

        let hits = index.search("notes", scope: .everywhere, activeCourseIds: [])
        #expect(hits.map(\.id) == [first.id, second.id])
    }

    @Test func exactTitleWinsAndWordsMayBeSeparatedByNewlines() {
        var index = SearchIndex()
        index.replace(group: "a", with: [
            SearchHit(id: "long", kind: .material, title: "CO2 Measurement Notes"),
            SearchHit(id: "exact", kind: .plan, title: "CO2 Measurement"),
        ])
        let hits = index.search("CO2\nmeasurement", scope: .everywhere, activeCourseIds: [])
        #expect(hits.map(\.id) == ["exact", "long"])
    }
}
