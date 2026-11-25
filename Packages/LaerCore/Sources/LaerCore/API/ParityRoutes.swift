import Foundation

/// Read-only parity routes.
extension ItslearningClient {
    /// The signed-in person's calendar from `from` onward, optionally through `toDate`.
    public func calendarEvents(from: Date, toDate: Date? = nil) async throws -> PagedResult<CalendarEvent> {
        func fetch(_ index: Int) async throws -> Page<CalendarEvent> {
            try await get(ReadRequest(
                path: "/restapi/personal/calendar/events/v1",
                query: [URLQueryItem(name: "fromDate", value: Self.queryDate(from))] + pageQuery(index: index, size: Self.maxPageSize),
                routeTemplate: "calendar/events/v1"
            ))
        }
        guard let toDate else { return try await collect(fetch: fetch) }

        var items: [CalendarEvent] = []
        var received = 0
        var lastSeenStart: Date?
        var isMonotonic = true
        for index in 0..<Self.pageLimit {
            try Task.checkCancellation()
            let page = try await fetch(index)
            if let reportedIndex = page.pageIndex, reportedIndex != index { break }
            received += page.items.count
            for event in page.items {
                if let start = event.fromDate {
                    if let previous = lastSeenStart, start < previous { isMonotonic = false }
                    lastSeenStart = start
                }
                if (event.fromDate ?? .distantFuture) <= toDate {
                    items.append(event)
                }
            }
            // Stop early only when returned events stay in start-date order past `toDate`.
            if isMonotonic, let lastStart = page.items.last(where: { $0.fromDate != nil })?.fromDate, lastStart > toDate {
                return PagedResult(items: items, isComplete: true)
            }
            if let total = page.total {
                if received >= total { return PagedResult(items: items, isComplete: true) }
                if page.items.isEmpty { break }
            } else if page.items.count < (page.pageSize ?? Self.maxPageSize) {
                return PagedResult(items: items, isComplete: true)
            }
        }
        return PagedResult(items: items, isComplete: false)
    }

    public func courseCalendarEvents(courseId: Int, from: Date, to: Date) async throws -> PagedResult<CalendarEvent> {
        try await collect { index in
            try await get(ReadRequest(
                path: "/restapi/personal/courses/\(courseId)/calendarevents/v1",
                query: pageQuery(index: index, size: Self.maxPageSize) + [
                    URLQueryItem(name: "fromDate", value: Self.queryDate(from)),
                    URLQueryItem(name: "toDate", value: Self.queryDate(to)),
                ],
                routeTemplate: "courses/{id}/calendarevents/v1"
            )) as Page<CalendarEvent>
        }
    }

    /// A page element and its content blocks.
    public func page(elementId: Int) async throws -> PageContent {
        try await get(ReadRequest(path: "/restapi/personal/pages/\(elementId)/v1", routeTemplate: "pages/{id}/v1"))
    }

    public func assignment(elementId: Int) async throws -> Assignment {
        try await get(ReadRequest(path: "/restapi/personal/assignments/\(elementId)/v1", routeTemplate: "assignments/{id}/v1"))
    }

    public func assignmentAnswer(elementId: Int, personId: Int) async throws -> AssignmentAnswer {
        try await get(ReadRequest(
            path: "/restapi/personal/assignments/\(elementId)/answers/persons/\(personId)/v1",
            routeTemplate: "assignments/{id}/answers/persons/{id}/v1"
        ))
    }

    public func topics(courseId: Int) async throws -> PagedResult<Topic> {
        try await allPages(path: "/restapi/personal/courses/\(courseId)/topics/v1", routeTemplate: "courses/{id}/topics/v1")
    }

    /// Version 3 pages with `paging.PageIndex` and `paging.PageSize`.
    public func participants(courseId: Int) async throws -> PagedResult<Participant> {
        try await collect { index in
            try await get(ReadRequest(
                path: "/restapi/personal/courses/\(courseId)/participants/v3",
                query: [
                    URLQueryItem(name: "paging.PageIndex", value: String(index)),
                    URLQueryItem(name: "paging.PageSize", value: String(Self.maxPageSize)),
                ],
                routeTemplate: "courses/{id}/participants/v3"
            )) as Page<Participant>
        }
    }

    /// One page of message threads, newest first. Each thread embeds recent messages, so keep pages small.
    /// Pass the last thread's sort index to continue.
    public func messageThreads(before sortIndex: Int64? = nil, pageSize: Int = 10) async throws -> ThreadList {
        var query = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let sortIndex { query.append(URLQueryItem(name: "fromSortIndex", value: String(sortIndex))) }
        return try await get(ReadRequest(
            path: "/restapi/personal/instantmessages/messagethreads/v4",
            query: query,
            routeTemplate: "instantmessages/messagethreads/v4"
        ))
    }

    /// Messages in a thread with IDs below `before`, newest first.
    public func messages(threadId: Int, before messageId: Int64? = nil, pageSize: Int = 50) async throws -> MessageList {
        var query = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let messageId { query.append(URLQueryItem(name: "fromId", value: String(messageId))) }
        return try await get(ReadRequest(
            path: "/restapi/personal/instantmessages/messagethreads/\(threadId)/messages/v3",
            query: query,
            routeTemplate: "instantmessages/messagethreads/{id}/messages/v3"
        ))
    }

    /// Starred course cards. The site caps nothing here, but pages are read to the end.
    public func starredCourses() async throws -> PagedResult<CourseCard> {
        try await allPages(path: "/restapi/personal/courses/cards/starred/v1", routeTemplate: "courses/cards/starred/v1")
    }

    /// People and groups matching `text`. The site returns at most 100, so search as the user types.
    public func searchRecipients(_ text: String) async throws -> [Recipient] {
        try await get(ReadRequest(
            path: "/restapi/personal/instantmessages/recipients/search/v1",
            query: [URLQueryItem(name: "searchText", value: text)],
            routeTemplate: "instantmessages/recipients/search/v1"
        ))
    }

    public func unreadThreadCount() async throws -> Int {
        try await get(ReadRequest(
            path: "/restapi/personal/instantmessages/messagethreads/unread/count/v1",
            routeTemplate: "instantmessages/messagethreads/unread/count/v1"
        ))
    }

    /// The newest notifications. The feed is a recent window, not a full history.
    public func notifications(pageSize: Int = 50) async throws -> [ParityNotification] {
        let page: Page<ParityNotification> = try await get(ReadRequest(
            path: "/restapi/personal/notifications/v2",
            query: pageQuery(index: 0, size: pageSize),
            routeTemplate: "notifications/v2"
        ))
        return page.items
    }

    public func unreadNotificationCount() async throws -> Int {
        try await get(ReadRequest(path: "/restapi/personal/notifications/unread/count/v1", routeTemplate: "notifications/unread/count/v1"))
    }

    public func bulletins(courseId: Int) async throws -> PagedResult<Bulletin> {
        try await allPages(path: "/restapi/personal/courses/\(courseId)/bulletins/v1", routeTemplate: "courses/{id}/bulletins/v1")
    }

    public func bulletinElements(bulletinId: Int) async throws -> PagedResult<BulletinElement> {
        try await allPages(
            path: "/restapi/personal/courses/bulletins/\(bulletinId)/elements/v1",
            routeTemplate: "courses/bulletins/{id}/elements/v1"
        )
    }

    public func bulletinComments(bulletinId: Int) async throws -> PagedResult<BulletinComment> {
        try await allPages(path: "/restapi/personal/lightbulletins/\(bulletinId)/comments/v1", routeTemplate: "lightbulletins/{id}/comments/v1")
    }

    public func assessmentRecord(courseId: Int, termId: Int? = nil) async throws -> AssessmentRecord {
        try await get(ReadRequest(
            path: "/restapi/personal/course/\(courseId)/assessmentrecord/assessmentrecordelements/v1",
            query: termId.map { [URLQueryItem(name: "termId", value: String($0))] } ?? [],
            routeTemplate: "course/{id}/assessmentrecord/assessmentrecordelements/v1"
        ))
    }

    /// Gradebook results. For a student the listing is expected to hold only their own row.
    public func personAssessments(courseId: Int) async throws -> PagedResult<PersonAssessments> {
        try await collect { index in
            try await get(ReadRequest(
                path: "/restapi/personal/course/\(courseId)/assessmentrecord/assessmentrecordpersonitems/v1",
                query: [
                    URLQueryItem(name: "paging.PageIndex", value: String(index)),
                    URLQueryItem(name: "paging.PageSize", value: String(Self.maxPageSize)),
                ],
                routeTemplate: "course/{id}/assessmentrecord/assessmentrecordpersonitems/v1"
            )) as Page<PersonAssessments>
        }
    }

    /// Dates in queries are UTC instants with a time part, as the help pages ask.
    static func queryDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
    }
}

/// File routes that answer with a redirect to the bytes. These are paths for the file acquirer;
/// the client never follows them, because the answer is not JSON.
public enum ParityFilePaths {
    public static func assignmentFile(elementId: Int, fileId: Int) -> String {
        "/restapi/personal/assignments/\(elementId)/files/\(fileId)/v1"
    }

    public static func pageFile(elementId: Int, blockId: Int, fileId: Int) -> String {
        "/restapi/personal/pages/\(elementId)/contentblocks/\(blockId)/files/\(fileId)/v1"
    }
}
