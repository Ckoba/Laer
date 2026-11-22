import AppKit
import Foundation
import LaerCore

/// A menu-bar link waiting for the main window's navigation.
struct SiteLinkRequest: Equatable {
    let id = UUID()
    let url: URL
    let courseId: Int?
}

/// A coming lecture as the menu bar shows it: the course, the plan and its files.
struct UpcomingLecture: Identifiable, Equatable {
    var course: Course
    var plan: PlanPreview

    var id: Int { plan.planId }
    var start: Date? { StudyDates.usable(plan.start) ?? StudyDates.usable(plan.stop) }
    var readings: [PlanPreview.Element] { (plan.elements ?? []).filter { $0.isFolder != true } }
}

extension AppModel {
    /// The next lectures across active courses, soonest first, from what is already in memory.
    /// Nothing here waits on the network, so the menu draws complete on its first frame.
    func upcomingLectures(limit: Int = 2, now: Date = Date()) -> [UpcomingLecture] {
        var all: [UpcomingLecture] = []
        for course in activeCourses {
            let sections = PlanOrder.sections(plans[course.courseId] ?? [], now: now)
            let coming = ([sections.next].compactMap { $0 } + sections.upcoming).prefix(limit)
            all += coming.map { UpcomingLecture(course: course, plan: $0) }
        }
        return Array(all.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }.prefix(limit))
    }

    /// The plan matching a calendar event from plans already in memory, if any.
    func plan(for event: CalendarEvent, courseId: Int? = nil) -> PlanPreview? {
        guard let targetCourse = courseId ?? event.courseId, let coursePlans = plans[targetCourse] else { return nil }
        return PlanOrder.plan(for: event, in: coursePlans, courseId: targetCourse)
    }

    /// Reads the event's course plans when none are in memory, so `plan(for:)` can answer.
    func loadPlansIfNeeded(for event: CalendarEvent) async {
        guard let course = event.courseId, plans[course] == nil else { return }
        await loadPlans(courseId: course)
    }

    /// The menu opened: plans refresh if stale, and the shown readings are saved ahead so they open at once.
    func menuBarOpened() {
        guard case .ready = authState, readingPrefetch == nil else { return }
        readingPrefetch = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for course in self.activeCourses.prefix(16) {
                    let id = course.courseId
                    group.addTask { await self.loadPlans(courseId: id) }
                }
            }
            if self.fetchesAhead { await self.prefetchReadings(self.upcomingLectures()) }
            self.readingPrefetch = nil
        }
    }

    /// After a refresh, the next lessons' readings are saved and their Office files converted,
    /// so they open at once. See decision 0020.
    func saveUpcomingReadings() async {
        guard fetchesAhead, case .ready = authState, readingPrefetch == nil else { return }
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.prefetchReadings(self.upcomingLectures(limit: 6))
        }
        readingPrefetch = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if readingPrefetch == task { readingPrefetch = nil }
    }

    /// Saves files for the given lectures one at a time, skipping ones that failed before.
    /// Saved Office files are converted too, so they show as pages without waiting.
    private func prefetchReadings(_ lectures: [UpcomingLecture]) async {
        for lecture in lectures {
            for element in lecture.readings.prefix(8) where element.isResource != false {
                guard !Task.isCancelled, fetchesAhead else { return }
                let resource = Resource(planElement: element, courseId: lecture.course.courseId)
                guard FileAcquirer.canAttempt(resource) else { continue }
                if savedAssets[resource.id] == nil {
                    guard downloadStates[resource.id] == nil else { continue }
                    await download(resource)
                }
                await convertAhead(resource)
            }
            // Readings saved earlier get a brief too; ones saved just now are already queued.
            scheduleBrief(for: lecture.plan, courseId: lecture.course.courseId)
        }
    }

    private func convertAhead(_ resource: Resource) async {
        guard savedAssets[resource.id] != nil, convertedFiles[resource.id] == nil,
              !failedConversions.contains(resource.id),
              let source = await savedFileURL(for: resource),
              ViewerItem.mayNeedPDFConversion(named: source.lastPathComponent),
              OfficePDFConverter.cachedPDF(for: source, id: resource.id) == nil else { return }
        do {
            _ = try await OfficePDFConverter.convert(source, id: resource.id)
        } catch where !(error is CancellationError) && !Task.isCancelled {
            failedConversions.insert(resource.id)
        } catch {}
    }

    /// Opens a reading from the menu bar the way a click in the course does: the course on its
    /// Plans tab and the file in the right panel. Website-only items open in the browser.
    func openFromMenuBar(_ element: PlanPreview.Element, in lecture: UpcomingLecture) {
        let courseId = lecture.course.courseId
        guard element.isFolder != true, element.isResource != false else {
            if let url = absoluteURL(element.url) {
                siteLinkRequest = SiteLinkRequest(url: url, courseId: courseId)
            }
            return
        }
        selection = .course(courseId)
        plansTabRequest = courseId
        let resource = Resource(planElement: element, courseId: courseId)
        // A saved file shows in the same frame as the window, without waiting on the store.
        if let asset = savedAssets[resource.id], let url = downloads?.fileURLIfPresent(for: asset) {
            viewerItem = ViewerItem(id: resource.id, title: resource.title, fileURL: url)
            return
        }
        Task { await open(resource) }
    }

    func openLectureFromMenuBar(_ lecture: UpcomingLecture) {
        selection = .course(lecture.course.courseId)
        plansTabRequest = lecture.course.courseId
    }
}
