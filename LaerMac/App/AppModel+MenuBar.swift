import AppKit
import Foundation
import LaerCore

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
            await self.prefetchReadings(self.upcomingLectures())
            self.readingPrefetch = nil
        }
    }

    /// Saves files for the given lectures one at a time, skipping saved ones and ones that failed before.
    private func prefetchReadings(_ lectures: [UpcomingLecture]) async {
        for lecture in lectures {
            for element in lecture.readings.prefix(8) where element.isResource != false {
                let resource = Resource(planElement: element, courseId: lecture.course.courseId)
                guard savedAssets[resource.id] == nil, downloadStates[resource.id] == nil,
                      FileAcquirer.canAttempt(resource) else { continue }
                await download(resource)
            }
            // Readings saved earlier get a brief too; ones saved just now are already queued.
            scheduleBrief(for: lecture.plan, courseId: lecture.course.courseId)
        }
    }

    /// Opens a reading from the menu bar the way a click in the course does: the course on its
    /// Plans tab and the file in the right panel. Website-only items open in the browser.
    func openFromMenuBar(_ element: PlanPreview.Element, in lecture: UpcomingLecture) {
        let courseId = lecture.course.courseId
        selection = .course(courseId)
        plansTabRequest = courseId
        guard element.isFolder != true, element.isResource != false else {
            if let url = absoluteURL(element.url) { NSWorkspace.shared.open(url) }
            return
        }
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
