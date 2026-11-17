import Foundation
import LaerCore

/// One stored group of search records. Groups refresh independently.
private struct SearchGroup: Codable, Sendable {
    var group: String
    var hits: [SearchHit]
}

extension AppModel {
    /// Starred courses are the active ones. With none starred, every course counts as active.
    var activeCourses: [Course] {
        guard !starredIds.isEmpty else { return courses }
        return courses.filter { starredIds.contains($0.courseId) }
    }

    var archivedCourses: [Course] {
        guard !starredIds.isEmpty else { return [] }
        return courses.filter { !starredIds.contains($0.courseId) }
    }

    func refreshStarred() async {
        do {
            let result = try await fetch(key: "starred") { try await $0.starredCourses() }
            let ids = result.items.filter { $0.isFavourite != false }.map(\.courseId)
            starredIds = Set(ids)
            try? await snapshots?.save(ids.map(StoredId.init), collection: "starred", coverage: .complete, checkpoint: nil, at: Date())
        } catch {
            // The saved list stays. Courses still show, grouped as they were.
        }
    }

    func toggleActive(_ course: Course) async {
        let id = course.courseId
        do {
            try await write { try await $0.toggleFavorite(courseId: id) }
            if starredIds.contains(id) { starredIds.remove(id) } else { starredIds.insert(id) }
            await refreshStarred()
        } catch {
            sessionNoticeIfNeeded(error)
        }
    }

    /// Loads what a course opens to, so switching between active courses is instant.
    func prefetchActiveCourses() async {
        for course in activeCourses {
            let id = course.courseId
            async let plans: Void = loadPlans(courseId: id)
            async let folder: Void = loadFolder(courseId: id, folderId: nil)
            _ = await (plans, folder)
        }
    }

    // MARK: - Viewer

    /// Shows a file at once, in a tab that fills in when the bytes arrive.
    func open(_ resource: Resource) async {
        if let url = await savedFileURL(for: resource) {
            viewerItem = ViewerItem(id: resource.id, title: resource.title, fileURL: url)
            noteRecent(resource)
            Perf.mark("saved file shown")
            return
        }
        if FileAcquirer.canAttempt(resource) {
            viewerItem = ViewerItem(id: resource.id, title: resource.title, fileURL: nil)
        }
        await download(resource)
        if let url = await savedFileURL(for: resource) {
            viewerItem = ViewerItem(id: resource.id, title: resource.title, fileURL: url)
            noteRecent(resource)
        } else if let tab = viewerTabs.first(where: { $0.id == resource.id && $0.fileURL == nil }) {
            // Not a file after all. The caller decides what to show instead.
            closeTab(tab)
        }
    }

    /// Saved events for a week, for showing before the refresh returns.
    func cachedEvents(weekContaining date: Date) async -> [CalendarEvent] {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return await snapshots?.load(CalendarEvent.self, collection: "events-\(Int(week.start.timeIntervalSince1970))")?.records ?? []
    }

    func open(_ element: PlanPreview.Element, courseId: Int?) async {
        await open(Resource(planElement: element, courseId: courseId))
    }

    func open(_ hit: SearchHit) {
        switch hit.kind {
        case .material:
            if let resource = hit.resource, !resource.isFolder {
                Task { await open(resource) }
            } else if let course = hit.courseId {
                selection = .course(course)
            }
        case .course, .plan:
            if let course = hit.courseId { selection = .course(course) }
        case .task:
            selection = .upcoming
        case .message:
            selection = .messages
        case .event:
            selection = .calendar
        }
    }

    // MARK: - Calendar

    /// A week's events. Shows the saved copy when the service can't be reached.
    func events(weekContaining date: Date) async -> [CalendarEvent] {
        let calendar = Calendar.current
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        let key = "events-\(Int(week.start.timeIntervalSince1970))"
        do {
            let start = week.start
            let result = try await fetch(key: key) { try await $0.calendarEvents(from: start) }
            let items = result.items.filter { ($0.fromDate ?? .distantFuture) < week.end }
            try? await snapshots?.save(items, collection: key, coverage: .complete, checkpoint: nil, at: Date())
            return items
        } catch {
            sessionNoticeIfNeeded(error)
            return await snapshots?.load(CalendarEvent.self, collection: key)?.records ?? []
        }
    }

    // MARK: - Search

    func search(_ text: String, scope: SearchScope, kinds: Set<SearchKind>, fileExtension: String?) async -> [SearchHit] {
        let index = searchIndex
        let active = Set(activeCourses.map(\.courseId))
        return await Task.detached(priority: .userInitiated) {
            index.search(text, scope: scope, activeCourseIds: active, kinds: kinds, fileExtension: fileExtension)
        }.value
    }

    func loadSearchIndex() async {
        guard let snapshot = await snapshots?.load(SearchGroup.self, collection: "search-index") else { return }
        let groups = snapshot.records
        searchIndex = await Task.detached(priority: .utility) {
            SearchIndex(records: Dictionary(groups.map { ($0.group, $0.hits) }) { first, _ in first })
        }.value
        searchIndexedAt = snapshot.lastSuccess
    }

    /// Rebuilds in the background, active courses first. A failed part keeps its earlier records.
    func refreshSearchIndexIfStale() async {
        guard !isIndexing else { return }
        if let last = searchIndexedAt, Date().timeIntervalSince(last) < 6 * 60 * 60 { return }
        isIndexing = true
        defer { isIndexing = false }

        replaceSearchGroup("courses", courses.map {
            SearchHit(id: "course-\($0.courseId)", kind: .course, title: $0.shortTitle, detail: $0.title, courseId: $0.courseId, url: $0.url)
        })
        replaceSearchGroup("tasks", tasks.map {
            SearchHit(id: "task-\($0.taskId)", kind: .task, title: $0.title, detail: $0.courseTitle, courseId: $0.courseId, date: $0.deadline, url: $0.url)
        })

        guard let client = indexingClient() else { return }
        for course in activeCourses + archivedCourses {
            let deep = activeCourses.contains(course)
            let hits = await Self.indexCourse(course, client: client, deep: deep)
            if let hits { replaceSearchGroup("course-\(course.courseId)", hits) }
        }
        if let threads = try? await client.messageThreads(pageSize: 30) {
            replaceSearchGroup("messages", threads.threads.map { thread in
                SearchHit(
                    id: "thread-\(thread.threadId)", kind: .message,
                    title: thread.name ?? thread.lastMessage?.createdByName ?? "Conversation",
                    detail: PlainText.from(thread.lastMessage?.text ?? ""), date: thread.lastMessage?.created
                )
            })
        }
        let horizon = Calendar.current.date(byAdding: .month, value: -2, to: Date()) ?? Date()
        if let events = try? await client.calendarEvents(from: horizon) {
            replaceSearchGroup("events", events.items.map {
                SearchHit(id: "event-\($0.eventId)", kind: .event, title: $0.title ?? "Event", detail: $0.displayLocation, courseId: $0.courseId, date: $0.fromDate)
            })
        }
        let now = Date()
        searchIndexedAt = now
        let groups = searchIndex.records.map { SearchGroup(group: $0.key, hits: $0.value) }
        try? await snapshots?.save(groups, collection: "search-index", coverage: .complete, checkpoint: nil, at: now)
    }

    private func replaceSearchGroup(_ group: String, _ hits: [SearchHit]) {
        searchIndex.replace(group: group, with: hits)
    }

    /// Plans, their elements and folder contents. Active courses walk their folders, others stay shallow.
    private nonisolated static func indexCourse(_ course: Course, client: ItslearningClient, deep: Bool) async -> [SearchHit]? {
        var hits: [SearchHit] = []
        var succeeded = false
        if let plans = try? await client.plans(courseId: course.courseId) {
            succeeded = true
            for plan in plans.items {
                hits.append(SearchHit(
                    id: "plan-\(plan.planId)", kind: .plan, title: plan.name ?? "Plan",
                    detail: course.shortTitle, courseId: course.courseId, date: plan.start, url: plan.url
                ))
                for element in plan.elements ?? [] where element.isFolder != true {
                    let resource = Resource(planElement: element, courseId: course.courseId)
                    hits.append(SearchHit(
                        id: resource.id, kind: .material, title: element.title ?? "Material",
                        detail: "\(course.shortTitle), \(plan.name ?? "Plan")", courseId: course.courseId,
                        resource: resource, url: element.url
                    ))
                }
            }
        }
        var queue: [(id: Int?, path: String)] = [(nil, course.shortTitle)]
        var budget = deep ? 60 : 1
        while let folder = queue.popLast(), budget > 0 {
            budget -= 1
            let listing: PagedResult<Resource>?
            if let id = folder.id {
                listing = try? await client.folderResources(courseId: course.courseId, folderId: id)
            } else {
                listing = try? await client.rootResources(courseId: course.courseId)
            }
            guard let listing else { continue }
            succeeded = true
            for resource in listing.items {
                hits.append(SearchHit(
                    id: resource.id, kind: .material, title: resource.title, detail: folder.path,
                    courseId: course.courseId, resource: resource, url: resource.url ?? resource.contentUrl
                ))
                if resource.isFolder { queue.append((resource.elementId, "\(folder.path) / \(resource.title)")) }
            }
        }
        guard succeeded else { return nil }
        // A file listed in both a plan and a folder appears once, with its plan as context.
        var seen = Set<String>()
        return hits.filter { hit in
            let key = hit.kind == .material ? "\(hit.courseId ?? 0)-\(hit.title.lowercased())" : hit.id
            return seen.insert(key).inserted
        }
    }

    private func sessionNoticeIfNeeded(_ error: Error) {
        if case APIError.signedOut = error { _ = message(for: error) }
    }
}

/// A plain ID in a snapshot.
struct StoredId: Codable, Sendable {
    var value: Int
    init(_ value: Int) { self.value = value }
}
