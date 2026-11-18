import AppKit
import Foundation
import LaerCore

private struct SearchCoverage: Codable, Sendable {
    var hasPendingWork: Bool
}

private struct FolderSearchCursor: Codable, Sendable {
    struct Folder: Codable, Sendable {
        var id: Int?
        var context: String
    }
    var pending: [Folder]
    var visited: Set<Int> = []
}

struct OnlineSearchSummary {
    var total: Int
    var searched: Int
    var incomplete: Bool
    var error: String?
}

struct SearchDocumentWork {
    var asset: LocalAsset
    var resource: Resource?
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
        let store = snapshots
        for course in activeCourses {
            guard !Task.isCancelled, store === snapshots else { return }
            let id = course.courseId
            async let plans: Void = loadPlans(courseId: id)
            async let topics: Void = loadTopics(courseId: id)
            async let folder: Void = loadFolder(courseId: id, folderId: nil)
            _ = await (plans, topics, folder)
        }
    }

    // MARK: - Viewer

    /// Shows a file at once, in a tab that fills in when the bytes arrive.
    func open(_ resource: Resource) async {
        let store = snapshots
        if let url = await savedFileURL(for: resource) {
            guard !Task.isCancelled, store === snapshots else { return }
            viewerItem = ViewerItem(id: resource.id, title: resource.title, fileURL: url)
            noteRecent(resource)
            Perf.mark("saved file shown")
            return
        }
        guard !Task.isCancelled, store === snapshots else { return }
        if FileAcquirer.canAttempt(resource) {
            viewerItem = ViewerItem(id: resource.id, title: resource.title, fileURL: nil)
        }
        await download(resource)
        guard !Task.isCancelled, store === snapshots else { return }
        if let url = await savedFileURL(for: resource) {
            guard !Task.isCancelled, store === snapshots else { return }
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
        if let document = hit.document {
            let downloads = downloads
            Task {
                guard let downloads, let asset = await downloads.asset(for: document.resourceKey),
                      asset.relativePath == document.version, downloads === self.downloads else { return }
                let url = await downloads.fileURL(for: asset)
                guard downloads === self.downloads, savedAssets[asset.id] == asset else { return }
                viewerItem = ViewerItem(id: asset.id, title: hit.title, fileURL: url, startPage: document.page,
                                        searchMatch: document.recognizedText == true ? nil : hit.matchedText)
                if let resource = hit.resource { noteRecent(resource) }
            }
            return
        }
        switch hit.kind {
        case .material:
            if let resource = hit.resource, !resource.isFolder {
                let store = snapshots
                Task {
                    if FileAcquirer.canAttempt(resource) { await open(resource) }
                    guard store === snapshots, viewerItem?.id != resource.id else { return }
                    if let url = absoluteURL(hit.url), let origin = site?.baseURL, AvatarSession.sameOrigin(url, origin) {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else if let course = hit.courseId {
                selection = .course(course)
            }
        case .course, .plan, .announcement:
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
        let store = snapshots
        let calendar = Calendar.current
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        let key = "events-\(Int(week.start.timeIntervalSince1970))"
        do {
            let start = week.start
            let result = try await fetch(key: key) { try await $0.calendarEvents(from: start) }
            let items = result.items.filter { ($0.fromDate ?? .distantFuture) < week.end }
            guard !Task.isCancelled, store === snapshots else { return [] }
            if result.isComplete { try? await store?.save(items, collection: key, coverage: .complete, checkpoint: nil, at: Date()) }
            await indexEvents(items, store: store)
            return items
        } catch {
            sessionNoticeIfNeeded(error)
            guard !Task.isCancelled, store === snapshots else { return [] }
            return await store?.load(CalendarEvent.self, collection: key)?.records ?? []
        }
    }

    // MARK: - Search
    func search(_ text: String, scope: SearchScope, kinds: Set<SearchKind>, fileExtension: String?, limit: Int = 60) async -> [SearchHit] {
        guard let index = searchIndex, let store = snapshots else { return [] }
        do {
            let matches = try await index.search(
                text, scope: scope, activeCourseIds: Set(activeCourses.map(\.courseId)),
                kinds: kinds, fileExtension: fileExtension, limit: limit
            )
            guard !Task.isCancelled, store === snapshots, index === searchIndex else { return [] }
            return matches.filter { hit in
                guard let position = hit.document else { return true }
                return savedAssets[position.resourceKey]?.relativePath == position.version
            }
        } catch is CancellationError {
            return []
        } catch {
            if store === snapshots { searchIndexFailed = true }
            return []
        }
    }

    func loadSearchIndex() async {
        guard let store = snapshots else { return }
        let coverage = await store.load(SearchCoverage.self, collection: "search-coverage")
        do {
            let index = try await store.searchDatabase()
            guard store === snapshots else { return }
            searchIndex = index
            searchIndexFailed = false
            searchIndexedAt = coverage?.records.first?.hasPendingWork == false ? coverage?.lastSuccess : nil
            searchCoverageIncomplete = coverage?.coverage != .complete
            await indexSearchGroup("courses", hits: courses.map(Self.courseSearchHit), complete: false, store: store)
            await indexSearchGroup("tasks", hits: tasks.map(Self.taskSearchHit), complete: false, store: store)
            guard store === snapshots else { return }
            for asset in savedAssets.values { queueDocumentSearch(asset, resource: nil) }
        } catch {
            if store === snapshots { searchIndexFailed = true }
        }
    }

    func rebuildSearchIndex() async {
        guard let store = snapshots, !isIndexing, !searchOCRIsClearing else { return }
        searchDocumentWorker?.cancel()
        searchOCRBatch?.cancel()
        searchDocumentWorker = nil
        searchDocumentQueue = [:]
        searchOCRBatch = nil
        searchOCRIsRunning = false
        searchIndex = nil
        searchIndexedAt = nil
        searchCoverageIncomplete = true
        do {
            try await store.removeSearchIndex(courseIds: courses.map(\.courseId))
            guard store === snapshots else { return }
            await loadSearchIndex()
            await refreshSearchIndexIfStale()
        } catch {
            if store === snapshots { searchIndexFailed = true }
        }
    }

    func changeSearchCoverage() async {
        searchIndexedAt = nil
        searchCoverageIncomplete = true
        await refreshSearchIndexIfStale()
    }

    /// Indexed snapshots remain readable while this crawl refreshes collections independently.
    func refreshSearchIndexIfStale() async {
        guard !isIndexing, let store = snapshots, searchIndex != nil, case .ready = authState else { return }
        if let last = searchIndexedAt, Date().timeIntervalSince(last) < 6 * 60 * 60 { return }
        isIndexing = true
        defer { if store === snapshots { isIndexing = false } }

        let includeArchived = UserDefaults.standard.bool(forKey: "LaerIndexArchivedCourses")
        let selected = includeArchived ? activeCourses + archivedCourses : activeCourses
        var complete = true
        for course in selected {
            guard !Task.isCancelled, store === snapshots else { return }
            if includeArchived != UserDefaults.standard.bool(forKey: "LaerIndexArchivedCourses") {
                isIndexing = false
                Task { await changeSearchCoverage() }
                return
            }
            let id = course.courseId
            do {
                let result = try await fetch(key: "plans-\(id)") { try await $0.plans(courseId: id) }
                await indexPlans(result, courseId: id, store: store)
                if result.isComplete {
                    try await store.save(result.items, collection: "plans-\(id)", coverage: .complete, checkpoint: nil, at: Date())
                } else {
                    complete = false
                }
            } catch {
                complete = false
            }
            if !(await indexFolders(in: course, store: store)) { complete = false }
            if ParityGate.bulletins {
                do {
                    let result = try await fetch(key: "bulletins-\(id)") { try await $0.bulletins(courseId: id) }
                    await indexBulletins(result.items, courseId: id, store: store)
                    if result.isComplete {
                        try await store.save(result.items, collection: "bulletins-\(id)", coverage: .recentWindow, checkpoint: nil, at: Date())
                    } else {
                        complete = false
                    }
                } catch {
                    complete = false
                }
            }
        }

        guard !Task.isCancelled, store === snapshots else { return }
        if ParityGate.messages {
            do {
                let threads = try await fetch(key: "search-recent-threads") { try await $0.messageThreads(pageSize: 30) }
                await indexThreads(threads.threads, store: store)
            } catch {
                complete = false
            }
        }
        if ParityGate.personalCalendar {
            let horizon = Calendar.current.date(byAdding: .month, value: -2, to: Date()) ?? Date()
            do {
                let events = try await fetch(key: "search-recent-events") { try await $0.calendarEvents(from: horizon) }
                await indexEvents(events.items, store: store)
                if !events.isComplete { complete = false }
            } catch {
                complete = false
            }
        }
        guard !Task.isCancelled, store === snapshots else { return }
        searchCoverageIncomplete = !complete || (!includeArchived && !archivedCourses.isEmpty)
        searchIndexedAt = complete ? Date() : nil
        try? await store.save([SearchCoverage(hasPendingWork: !complete)], collection: "search-coverage",
                              coverage: searchCoverageIncomplete ? .incomplete : .complete, checkpoint: nil, at: Date())
    }

    private func indexFolders(in course: Course, store: SnapshotStore) async -> Bool {
        let courseId = course.courseId
        let key = "search-folders-\(courseId)"
        let saved = await store.load(FolderSearchCursor.self, collection: key)
        if let saved, saved.coverage == .complete, Date().timeIntervalSince(saved.lastSuccess) < 6 * 60 * 60 { return true }
        var cursor = saved?.records.first ?? FolderSearchCursor(pending: [.init(id: nil, context: course.shortTitle)])
        for _ in 0..<24 {
            guard !Task.isCancelled, store === snapshots else { return false }
            guard !cursor.pending.isEmpty else { return true }
            let folder = cursor.pending.removeFirst()
            do {
                let result = try await fetch(key: Self.folderKey(courseId: courseId, folderId: folder.id)) { client in
                    if let id = folder.id {
                        return try await client.folderResources(courseId: courseId, folderId: id)
                    }
                    return try await client.rootResources(courseId: courseId)
                }
                guard store === snapshots else { return false }
                await indexFolder(result, courseId: courseId, folderId: folder.id, context: folder.context, store: store)
                var known = cursor.visited.union(cursor.pending.compactMap(\.id))
                if let id = folder.id { known.insert(id) }
                for child in result.items where child.isFolder && known.insert(child.elementId).inserted {
                    cursor.pending.append(.init(id: child.elementId, context: "\(folder.context) › \(child.title)"))
                }
                if result.isComplete {
                    try await store.save(result.items, collection: Self.folderKey(courseId: courseId, folderId: folder.id),
                                         coverage: .complete, checkpoint: nil, at: Date())
                    if let id = folder.id { cursor.visited.insert(id) }
                } else {
                    cursor.pending.append(folder)
                }
                try await store.save(cursor.pending.isEmpty ? [] : [cursor], collection: key,
                                     coverage: cursor.pending.isEmpty ? .complete : .incomplete, checkpoint: nil, at: Date())
                if !result.isComplete { return false }
            } catch {
                // The previous checkpoint still includes this folder. Keep its last successful hits.
                return false
            }
        }
        return cursor.pending.isEmpty
    }

    func onlineSearch(
        _ text: String, courses targets: [Course], fileExtension: String?, onResults: ([SearchHit]) -> Void
    ) async -> OnlineSearchSummary {
        let capped = targets.prefix(12)
        var summary = OnlineSearchSummary(total: targets.count, searched: 0, incomplete: capped.count < targets.count)
        guard let store = snapshots else { return summary }
        for course in capped {
            guard !Task.isCancelled, store === snapshots else { return summary }
            do {
                let id = course.courseId
                let result = try await fetch(key: "course-search-\(UUID().uuidString)") { client in
                    try await client.searchResources(courseId: id, text: String(text.prefix(512)))
                }
                guard !Task.isCancelled, store === snapshots else { return summary }
                summary.searched += 1
                if !result.isComplete { summary.incomplete = true }
                let hits = result.items.compactMap { resource -> SearchHit? in
                    guard resource.courseId == nil || resource.courseId == id else { return nil }
                    let hit = Self.materialSearchHit(resource, courseId: id, context: resource.path ?? course.shortTitle)
                    if let fileExtension, hit.fileExtension != fileExtension { return nil }
                    return hit
                }
                onResults(hits)
            } catch {
                guard !Task.isCancelled, store === snapshots else { return summary }
                summary.incomplete = true
                if summary.error == nil { summary.error = message(for: error) }
                if let api = error as? APIError, api == .forbidden || api == .notFound { continue }
                break
            }
        }
        return summary
    }

    func indexPlans(_ result: PagedResult<PlanPreview>, courseId: Int, store: SnapshotStore?) async {
        let courseName = courses.first(where: { $0.courseId == courseId })?.shortTitle
        let courseTopics = topics[courseId] ?? []
        var hits: [SearchHit] = []
        for plan in result.items {
            let title = plan.name ?? "Plan"
            let context = [courseName, PlanTopics.displayName(of: plan, topics: courseTopics)].compactMap { $0 }
            let destination = SearchDestination.plan(courseId: courseId, planId: plan.planId)
            let description = plan.planDescription.map(PlainText.from)
            hits.append(SearchHit(
                id: "plan-\(courseId)-\(plan.planId)", kind: .plan, title: title,
                detail: (context + [description].compactMap { $0 }).joined(separator: " › "),
                courseId: courseId, date: plan.start, url: plan.url, destination: destination
            ))
            for element in plan.elements ?? [] where element.isFolder != true {
                let resource = Resource(planElement: element, courseId: courseId)
                hits.append(Self.materialSearchHit(resource, courseId: courseId, context: (context + [title]).joined(separator: " › ")))
            }
        }
        await indexSearchGroup("plans-\(courseId)", hits: hits, complete: result.isComplete, store: store)
    }

    func indexFolder(_ result: PagedResult<Resource>, courseId: Int, folderId: Int?, context: String?, store: SnapshotStore?) async {
        let courseName = courses.first(where: { $0.courseId == courseId })?.shortTitle
        let hits = result.items.map { resource in
            Self.materialSearchHit(resource, courseId: courseId, context: context ?? resource.path ?? courseName)
        }
        await indexSearchGroup(Self.folderKey(courseId: courseId, folderId: folderId), hits: hits, complete: result.isComplete, store: store)
    }

    private static func materialSearchHit(_ resource: Resource, courseId: Int, context: String?) -> SearchHit {
        let target: SearchDestination? = resource.isFolder
            ? .folder(courseId: courseId, folderId: resource.elementId, title: resource.title)
            : nil
        return SearchHit(resource: resource, courseId: courseId, context: context, destination: target)
    }

    func indexThreads(_ threads: [MessageThread], store: SnapshotStore?) async {
        let hits = threads.map { thread in
            SearchHit(
                id: "thread-\(thread.threadId)", kind: .message,
                title: thread.name ?? thread.lastMessage?.createdByName ?? "Conversation",
                detail: PlainText.from(thread.lastMessage?.text ?? ""), date: thread.lastMessage?.created,
                destination: .thread(thread.threadId)
            )
        }
        await indexSearchGroup("messages", hits: hits, complete: false, store: store)
        guard let store, store === snapshots else { return }
        try? await store.save(threads, collection: "search-recent-threads", coverage: .recentWindow, checkpoint: nil, at: Date())
    }

    func indexEvents(_ events: [CalendarEvent], store: SnapshotStore?) async {
        let hits = events.map {
            SearchHit(id: "event-\($0.eventId)", kind: .event, title: $0.title ?? "Event",
                      detail: [$0.displayLocation, $0.eventDescription.map(PlainText.from)].compactMap { $0 }.joined(separator: " · "),
                      courseId: $0.courseId, date: $0.fromDate,
                      destination: .event($0.eventId))
        }
        await indexSearchGroup("events", hits: hits, complete: false, store: store)
    }

    func indexBulletins(_ bulletins: [Bulletin], courseId: Int, store: SnapshotStore?) async {
        let hits = bulletins.map { bulletin -> SearchHit in
            let text = PlainText.from(bulletin.text ?? "")
            let title = String(text.prefix(100))
            let detail = [bulletin.publishedBy?.fullName, text].compactMap { $0 }.joined(separator: " · ")
            return SearchHit(id: "announcement-\(courseId)-\(bulletin.bulletinId)", kind: .announcement,
                             title: title.isEmpty ? "Announcement" : title, detail: detail, courseId: courseId,
                             date: bulletin.published, destination: .announcement(courseId: courseId, bulletinId: bulletin.bulletinId))
        }
        await indexSearchGroup("bulletins-\(courseId)", hits: hits, complete: false, store: store)
    }

    static func courseSearchHit(_ course: Course) -> SearchHit {
        SearchHit(id: "course-\(course.courseId)", kind: .course, title: course.shortTitle,
                  detail: course.title, courseId: course.courseId, url: course.url)
    }

    static func taskSearchHit(_ task: StudyTask) -> SearchHit {
        SearchHit(id: "task-\(task.taskId)", kind: .task, title: task.title, detail: task.courseTitle,
                  courseId: task.courseId, date: task.deadline, url: task.url, destination: .task(task.taskId))
    }

    func indexSearchGroup(_ group: String, hits: [SearchHit], complete: Bool, store: SnapshotStore?) async {
        guard let store, store === snapshots, let index = searchIndex else { return }
        let known = Set(courses.map(\.courseId))
        let indexed = coursesState.lastSuccess == nil || coursesState.isIncomplete ? hits : hits.filter { hit in
            hit.courseId.map(known.contains) ?? true
        }
        do {
            try await index.update(group: group, hits: indexed, complete: complete)
            if store === snapshots, index === searchIndex { searchRevision += 1 }
        } catch is CancellationError {
            return
        } catch {
            if store === snapshots, index === searchIndex { searchIndexFailed = true }
        }
    }

    func retainSearchCourses(_ ids: Set<Int>, store: SnapshotStore?) async {
        guard let store, store === snapshots, let index = searchIndex else { return }
        do {
            try await index.retainCourses(ids)
            if store === snapshots, index === searchIndex { searchRevision += 1 }
        } catch {
            if store === snapshots, index === searchIndex { searchIndexFailed = true }
        }
    }

    static let searchOCRPreference = "LaerSearchOCR"

    private var canRunSearchOCR: Bool {
        !searchOCRIsClearing && !searchOCRPowerPaused && UserDefaults.standard.bool(forKey: Self.searchOCRPreference)
    }

    func updateSearchOCR() {
        searchOCRPowerPaused = ProcessInfo.processInfo.isLowPowerModeEnabled
        if canRunSearchOCR {
            for asset in savedAssets.values where DocumentOCR.formats.contains((asset.relativePath as NSString).pathExtension.lowercased()) {
                queueDocumentSearch(asset, resource: nil)
            }
        } else {
            searchOCRBatch?.cancel()
        }
    }

    func removeRecognizedSearchText() async {
        guard let index = searchIndex, !searchOCRIsClearing else { return }
        searchOCRIsClearing = true
        UserDefaults.standard.set(false, forKey: Self.searchOCRPreference)
        searchOCRBatch?.cancel()
        let worker = searchDocumentWorker
        worker?.cancel()
        await worker?.value
        guard index === searchIndex else { return }
        do {
            try await index.removeRecognizedText()
            if index === searchIndex { searchRevision += 1 }
        } catch {
            if index === searchIndex { searchIndexFailed = true }
        }
        guard index === searchIndex else { return }
        searchOCRIsClearing = false
        for asset in savedAssets.values { queueDocumentSearch(asset, resource: nil) }
    }

    func queueDocumentSearch(_ asset: LocalAsset, resource: Resource?) {
        let format = (asset.relativePath as NSString).pathExtension.lowercased()
        let supportsOCR = canRunSearchOCR && DocumentOCR.formats.contains(format)
        guard DocumentSearchText.formats.contains(format) || supportsOCR,
              let index = searchIndex, let downloads else { return }
        let queued = searchDocumentQueue[asset.id]
        let queuedResource = queued?.asset == asset ? queued?.resource : nil
        searchDocumentQueue[asset.id] = SearchDocumentWork(asset: asset, resource: resource ?? queuedResource)
        guard searchDocumentWorker == nil else { return }
        searchDocumentWorker = Task(priority: .utility) {
            defer {
                if index === searchIndex, downloads === self.downloads { searchDocumentWorker = nil }
            }
            while !Task.isCancelled, index === searchIndex, downloads === self.downloads,
                  let key = searchDocumentQueue.keys.first, let work = searchDocumentQueue.removeValue(forKey: key) {
                do {
                    try await indexSavedDocument(work, index: index, downloads: downloads)
                } catch is CancellationError {
                    if Task.isCancelled { break }
                } catch {
                    if index === searchIndex { searchIndexFailed = true }
                }
            }
        }
    }

    private func isCurrentSearchDocument(_ work: SearchDocumentWork, index: SearchDatabase, downloads: DownloadStore) -> Bool {
        guard !Task.isCancelled, index === searchIndex, downloads === self.downloads,
              savedAssets[work.asset.id] == work.asset else { return false }
        if let courseId = work.resource?.courseId, coursesState.lastSuccess != nil, !coursesState.isIncomplete {
            return courses.contains(where: { $0.courseId == courseId })
        }
        return true
    }

    private func indexSavedDocument(_ work: SearchDocumentWork, index: SearchDatabase, downloads: DownloadStore) async throws {
        let asset = work.asset
        let url = await downloads.fileURL(for: asset)
        guard isCurrentSearchDocument(work, index: index, downloads: downloads) else { return }
        let hasEmbeddedIndex = try await index.hasDocument(resourceKey: asset.id, version: asset.relativePath)
        if !hasEmbeddedIndex {
            let extraction = Task.detached(priority: .utility) { try DocumentSearchText.extract(from: url) }
            let result = try await withTaskCancellationHandler {
                try await extraction.value
            } onCancel: {
                extraction.cancel()
            }
            guard isCurrentSearchDocument(work, index: index, downloads: downloads) else { return }
            let pages: [DocumentSearchPage]
            if case .readable(let extracted, _) = result { pages = extracted } else { pages = [] }
            try await index.replaceDocument(asset: asset, resource: work.resource, pages: pages)
            if index === searchIndex { searchRevision += 1 }
        }
        guard DocumentOCR.formats.contains(url.pathExtension.lowercased()), canRunSearchOCR,
              let next = try await index.nextOCRPage(resourceKey: asset.id, version: asset.relativePath),
              isCurrentSearchDocument(work, index: index, downloads: downloads) else { return }
        try await indexScannedPages(work, url: url, startingAt: next, index: index, downloads: downloads)
    }

    private func indexScannedPages(
        _ work: SearchDocumentWork, url: URL, startingAt page: Int, index: SearchDatabase, downloads: DownloadStore
    ) async throws {
        guard canRunSearchOCR else { return }
        let extraction = Task.detached(priority: .utility) { try DocumentOCR.read(from: url, startPage: page) }
        searchOCRBatch = extraction
        searchOCRIsRunning = true
        defer {
            if index === searchIndex, downloads === self.downloads {
                searchOCRBatch = nil
                searchOCRIsRunning = false
            }
        }
        let batch = try await withTaskCancellationHandler {
            try await extraction.value
        } onCancel: {
            extraction.cancel()
        }
        guard canRunSearchOCR, isCurrentSearchDocument(work, index: index, downloads: downloads) else { return }
        try await index.appendOCRBatch(batch, asset: work.asset, resource: work.resource)
        guard isCurrentSearchDocument(work, index: index, downloads: downloads) else { return }
        if !batch.pages.isEmpty { searchRevision += 1 }
        if batch.nextPage != nil {
            // Yield between batches. Metadata searches and other saved documents get time on the executor.
            try await Task.sleep(for: .milliseconds(250))
            if isCurrentSearchDocument(work, index: index, downloads: downloads),
               canRunSearchOCR, searchDocumentQueue[work.asset.id] == nil {
                searchDocumentQueue[work.asset.id] = work
            }
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
