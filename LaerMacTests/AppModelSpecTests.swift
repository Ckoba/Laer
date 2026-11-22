import Foundation
import LaerCore
import Testing
@testable import Laer

@Suite(.serialized)
@MainActor
struct AppModelSpecTests {
    private func withTestModel(signedOut: Bool = false, _ body: (AppModel) async throws -> Void) async throws {
        let model = await AppModel.forTesting(signedOut: signedOut)
        do {
            try await body(model)
        } catch {
            await model.cleanupForTesting()
            throw error
        }
        await model.cleanupForTesting()
    }

    @Test func coursesLoadAndToggleActiveMovesBetweenActiveAndArchived() async throws {
        try await withTestModel { model in
            #expect(model.courses.map(\.courseId) == [11, 12, 13])
            #expect(model.activeCourses.map(\.courseId) == [12])
            #expect(model.archivedCourses.map(\.courseId) == [11, 13])

            let active = try #require(model.courses.first { $0.courseId == 12 })
            await model.toggleActive(active)

            #expect(model.starredIds.isEmpty)
            #expect(model.archivedCourses.isEmpty)
            #expect(model.activeCourses.map(\.courseId) == [11, 12, 13])
            #expect(FixtureWrites.shared.all.contains { $0.routeTemplate == "courses/{id}/toggleFavorite/v1" })
        }
    }

    @Test func courseContentLoadsAndEmptyCourseHasEmptyCollections() async throws {
        try await withTestModel { model in
            await model.loadUpdates(courseId: 11)
            await model.loadPlans(courseId: 11)
            await model.loadFolder(courseId: 11, folderId: nil)

            #expect(model.updates[11]?.isEmpty == false)
            #expect(model.plans[11]?.first?.planId == 601)
            let rootResources = model.resources[AppModel.folderKey(courseId: 11, folderId: nil)] ?? []
            #expect(rootResources.contains { $0.title == "Syllabus.pdf" })
            #expect(rootResources.contains { $0.title == "Course page" })

            await model.refreshUpdates(courseId: 11)
            #expect(model.updatesState[11]?.phase == .idle)
            #expect(model.updates[11]?.isEmpty == false)

            await model.loadUpdates(courseId: 13)
            await model.loadFolder(courseId: 13, folderId: nil)
            #expect(model.updates[13]?.isEmpty == true)
            #expect(model.resources[AppModel.folderKey(courseId: 13, folderId: nil)]?.isEmpty == true)
        }
    }

    @Test func signedOutSessionRecoversOnBeginSignIn() async throws {
        try await withTestModel(signedOut: true) { model in
            #expect(model.courses.isEmpty)
            #expect(model.sessionNotice != nil)

            model.beginSignIn()
            await model.refreshAll()

            #expect(model.courses.map(\.courseId) == [11, 12, 13])
        }
    }

    @Test func openingMaterialSavesOpensTabAndReusesLocalFile() async throws {
        try await withTestModel { model in
            await model.loadFolder(courseId: 11, folderId: nil)
            let rootResources = model.resources[AppModel.folderKey(courseId: 11, folderId: nil)] ?? []
            let syllabus = try #require(rootResources.first { $0.title == "Syllabus.pdf" })
            let coursePage = try #require(rootResources.first { $0.title == "Course page" })

            await model.open(syllabus)

            let savedURL = try #require(model.viewerItem?.fileURL)
            #expect(FileManager.default.fileExists(atPath: savedURL.path))
            #expect(model.savedAssets[syllabus.id] != nil)
            #expect(model.viewerTabs.contains { $0.id == syllabus.id })

            let tab = try #require(model.viewerTabs.first { $0.id == syllabus.id })
            model.closeTab(tab)
            #expect(model.viewerItem == nil)
            #expect(model.viewerTabs.isEmpty)

            await model.open(syllabus)
            #expect(model.viewerItem?.fileURL == savedURL)

            await model.open(coursePage)
            #expect(model.downloadStates[coursePage.id] == .websiteOnly)
            #expect(!model.viewerTabs.contains { $0.id == coursePage.id })
        }
    }

    @Test func messagesAndAssignmentsSupportReadsAndExplicitWrites() async throws {
        try await withTestModel { model in
            let list = try await model.fetch(key: "threads") { try await $0.messageThreads() }
            #expect(list.threads.map(\.threadId) == [300, 301, 302])

            let reply = try await model.write { writer in
                try await writer.sendMessage(text: "Sent from Laer", threadId: 300)
            }
            #expect(reply.threadId == 300)

            let created = try await model.write { writer in
                try await writer.sendMessage(text: "Hello from Laer", toPersonIds: [3])
            }
            #expect(created.threadId == 300)

            let assignment = try await model.fetch(key: "assignment-70") { try await $0.assignment(elementId: 70) }
            #expect(assignment.title == "Essay draft")

            let answerId = try await model.write { writer in
                try await writer.submitAnswer(elementId: 70, text: "<p>My answer</p>", files: [])
            }
            #expect(answerId == 900)

            await #expect(throws: APIError.self) {
                try await model.fetch(key: "assignment-999") { try await $0.assignment(elementId: 999) }
            }

            let writeRoutes = FixtureWrites.shared.all.map(\.routeTemplate)
            #expect(writeRoutes.filter { $0 == "instantmessages/v2" }.count == 2)
            #expect(writeRoutes.contains("assignments/{id}/answers/v1"))
        }
    }

    @Test func calendarEventsFilterToRequestedWeek() async throws {
        try await withTestModel { model in
            let formatter = ISO8601DateFormatter()
            let targetWeek = try #require(formatter.date(from: "2026-11-03T12:00:00Z"))
            let earlierWeek = try #require(formatter.date(from: "2026-10-20T12:00:00Z"))

            let activeEvents = await model.events(weekContaining: targetWeek)
            #expect(activeEvents.map(\.eventId) == [41])

            let emptyWeekEvents = await model.events(weekContaining: earlierWeek)
            #expect(emptyWeekEvents.isEmpty)
        }
    }

    @Test func searchIndexesCoursesPlansSavedPDFPagesAndMergesOnlineHits() async throws {
        try await withTestModel { model in
            await model.waitForSearchReadyForTesting()
            await model.loadFolder(courseId: 11, folderId: nil)
            await model.loadPlans(courseId: 11)

            let courseHits = await model.search("Course two", scope: .everywhere, kinds: Set(SearchKind.allCases), fileExtension: nil)
            #expect(courseHits.contains { $0.id == "course-12" })

            let planHits = await model.search("introduction and reading", scope: .everywhere, kinds: Set(SearchKind.allCases), fileExtension: nil)
            #expect(planHits.contains { $0.id == "plan-11-601" })

            let rootResources = model.resources[AppModel.folderKey(courseId: 11, folderId: nil)] ?? []
            let syllabus = try #require(rootResources.first { $0.title == "Syllabus.pdf" })
            await model.open(syllabus)
            await model.waitForDocumentSearchForTesting()

            let pdfHits = await model.search("silted up", scope: .everywhere, kinds: Set(SearchKind.allCases), fileExtension: nil)
            let pageHit = try #require(pdfHits.first { $0.id == "document-LearningToolElement-702-1" })
            #expect(pageHit.document?.page == 1)

            var streamedOnlineHits: [SearchHit] = []
            let summary = await model.onlineSearch("Syllabus", courses: model.courses, fileExtension: nil) { batch in
                streamedOnlineHits.append(contentsOf: batch)
            }
            #expect(summary.searched == model.courses.count)
            #expect(streamedOnlineHits.contains { $0.id == "material-11-learningtoolelement-702" })
            #expect(streamedOnlineHits.contains { $0.id == "material-11-learningtoolelement-799" })

            let localMaterialHits = await model.search("Syllabus", scope: .everywhere, kinds: [.material], fileExtension: nil)
            let merged = SearchHit.unique(localMaterialHits + streamedOnlineHits)
            #expect(merged.filter { $0.id == "material-11-learningtoolelement-702" }.count == 1)
        }
    }
}
