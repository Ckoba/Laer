import AppKit
import Foundation
import LaerCore
import os
import SwiftUI
import Testing
@testable import Laer

@Suite(.serialized)
@MainActor
struct AppModelSpecTests {
    private func withTestModel(signedOut: Bool = false, transport: (any ReadTransport)? = nil, _ body: (AppModel) async throws -> Void) async throws {
        let model = await AppModel.forTesting(signedOut: signedOut, transport: transport)
        do {
            try await body(model)
        } catch {
            await model.cleanupForTesting()
            throw error
        }
        await model.cleanupForTesting()
    }

    @Test func signOutDiscardsOAuthExchangeThatFinishesAfterwards() async throws {
        try await withTestModel { model in
            let delayed = SuspendedOperation()
            var saveCount = 0
            let exchange = Task {
                await model.finishOAuthForTesting { code, verifier in
                    #expect(code == "fixture")
                    #expect(verifier.count == 43)
                    await delayed.pause()
                    return Self.tokens
                } save: { _ in
                    saveCount += 1
                    return true
                }
            }
            await delayed.waitUntilStarted()
            await model.signOut()
            delayed.resume()
            await exchange.value

            #expect(saveCount == 0)
            #expect(model.authState == .signingIn)
            #expect(model.snapshots == nil)
            #expect(await model.avatarAuthorization(for: FixtureTransport.site.baseURL) == nil)
        }
    }

    @Test func signOutInvalidatesOAuthRenewalBeforeItCanPersist() async throws {
        try await withTestModel { model in
            await model.waitForSearchReadyForTesting()
            let delayed = SuspendedOperation()
            let saves = OSAllocatedUnfairLock(initialState: 0)
            let recovery = SessionRecovery(refresh: {
                await delayed.pause()
                return Self.tokens
            }, persist: { _ in
                saves.withLock { $0 += 1 }
            })
            model.useOAuthForTesting(Self.tokens, recovery: recovery)
            let renewal = Task {
                try await model.fetch(key: "renewal-test") { try await $0.person() }
            }
            await delayed.waitUntilStarted()
            await model.signOut()
            delayed.resume()

            await #expect(throws: RefreshError.staleGeneration) { try await renewal.value }
            #expect(saves.withLock { $0 } == 0)
            #expect(model.authState == .signingIn)
            #expect(await model.avatarAuthorization(for: FixtureTransport.site.baseURL) == nil)
        }
    }

    @Test func verifiedStartupIdentityInvalidatesReadsBeforeSwitchingStores() async throws {
        try await withTestModel { model in
            await model.waitForSearchReadyForTesting()
            let oldStore = try #require(model.snapshots)
            let delayed = SuspendedOperation()
            let oldRead = Task {
                try await model.fetch(key: "identity-test") { _ in
                    await delayed.pause()
                    return 1
                }
            }
            await delayed.waitUntilStarted()
            await model.installVerifiedIdentityForTesting(Person(personId: 2002))
            await #expect(throws: RefreshError.staleGeneration) { try await oldRead.value }
            delayed.resume()

            #expect(model.snapshots !== oldStore)
            #expect(model.authState == .ready(Person(personId: 2002)))
            #expect(model.courses.isEmpty)
            #expect(try await model.fetch(key: "identity-test") { _ in 2 } == 2)
        }
    }

    @Test(arguments: [true, false])
    func partialOrFailedPageZeroPreservesCompleteOfflineSnapshots(partial: Bool) async throws {
        let degrade = OSAllocatedUnfairLock(initialState: false)
        let transport = SpecTransport { request in
            guard degrade.withLock({ $0 }) else { return nil }
            let invalidPage = #"{"EntityArray":[],"Total":1,"CurrentPageIndex":1,"PageSize":100}"#
            let json: String
            switch request.routeTemplate {
            case "courses/v4", "tasks/v1", "course/{id}/plans/all/v1":
                json = invalidPage
            case "courses/{id}/resources/v1":
                json = #"{"Resources":\#(invalidPage)}"#
            default: return nil
            }
            return SpecTransport.json(json, status: partial ? 200 : 403)
        }
        try await withTestModel(transport: transport) { model in
            await model.waitForSearchReadyForTesting()
            let store = try #require(model.snapshots)
            let folder = AppModel.folderKey(courseId: 11, folderId: nil)
            let courses = try #require(await store.load(Course.self, collection: "courses"))
            let tasks = try #require(await store.load(StudyTask.self, collection: "tasks"))
            let client = ItslearningClient(transport: FixtureTransport())
            let plans = try await client.plans(courseId: 11).items
            let resources = try await client.rootResources(courseId: 11).items
            try await store.save(plans, collection: "plans-11", coverage: .complete, checkpoint: nil, at: .distantPast)
            try await store.save(resources, collection: folder, coverage: .complete, checkpoint: nil, at: .distantPast)

            degrade.withLock { $0 = true }
            await model.refreshCourses()
            await model.refreshTasks()
            await model.loadPlans(courseId: 11)
            await model.loadFolder(courseId: 11, folderId: nil)

            #expect(model.courses == courses.records)
            #expect(model.tasks == tasks.records)
            #expect(model.plans[11] == plans)
            #expect(model.resources[folder] == resources)
            #expect(!model.coursesState.isIncomplete)
            #expect(!model.tasksState.isIncomplete)
            #expect(model.plansState[11]?.isIncomplete == false)
            #expect(model.resourcesState[folder]?.isIncomplete == false)
            #expect(await store.load(Course.self, collection: "courses")?.lastSuccess == courses.lastSuccess)
            #expect(await store.load(StudyTask.self, collection: "tasks")?.lastSuccess == tasks.lastSuccess)
            #expect(await store.load(PlanPreview.self, collection: "plans-11")?.lastSuccess == .distantPast)
            #expect(await store.load(Resource.self, collection: folder)?.lastSuccess == .distantPast)
        }
    }

    @Test func websiteFallbackClearsStaleBearer() async throws {
        try await withTestModel { model in
            let origin = FixtureTransport.site.baseURL
            model.useOAuthForTesting(Self.tokens)
            #expect(await model.avatarAuthorization(for: origin) != nil)
            model.beginWebsiteSignIn()
            #expect(model.usesWebsiteSignIn)
            #expect(!model.hasBearerForTesting())
            #expect(model.authState == .signingIn)
            // End the attempt before it can open the embedded site.
            await model.signOut()
            #expect(await model.avatarAuthorization(for: origin) == nil)
        }
    }

    @Test func unverifiedWebsiteAccountsUseUniqueEphemeralStores() async throws {
        try await withTestModel { model in
            let shared = SnapshotStore(rootDirectory: model.localDataRoot, accountKey: "1-0")
            try await shared.save([StoredId(99)], collection: "starred", coverage: .complete, checkpoint: nil, at: Date())
            let unverified = Person(personId: 0)
            await model.installWebsiteIdentityForTesting(unverified)
            let first = model.examPlanRoot
            let firstStore = try #require(model.snapshots)
            await model.waitForSearchReadyForTesting()
            #expect(first.lastPathComponent.hasPrefix("LaerEphemeral-"))
            #expect(model.starredIds.isEmpty)
            #expect(model.searchIndex != nil)
            #expect(model.briefs.store != nil)
            #expect(FileManager.default.fileExists(atPath: first.path))

            await model.signOut()
            #expect(!FileManager.default.fileExists(atPath: first.path))
            await model.installWebsiteIdentityForTesting(unverified)
            #expect(model.examPlanRoot != first)
            #expect(model.snapshots !== firstStore)
            #expect(await shared.load(StoredId.self, collection: "starred")?.records.map(\.value) == [99])
        }
    }

    @Test func destructiveSignOutWipesAllOfflineData() async throws {
        try await withTestModel { model in
            await model.waitForSearchReadyForTesting()
            let store = try #require(model.snapshots)
            let downloads = try #require(model.downloads)
            let briefs = try #require(model.briefs.store)
            let index = try await store.searchDatabase()
            await model.loadFolder(courseId: 11, folderId: nil)
            let syllabus = try #require(model.resources[AppModel.folderKey(courseId: 11, folderId: nil)]?.first { $0.elementId == 702 })
            await model.download(syllabus)
            let file = try #require(await model.savedFileURL(for: syllabus))
            try await briefs.save(GeneratedBrief(planId: 601, courseId: 11, lectureTitle: nil, sourceKey: "example",
                                                  readingTitles: [], language: nil, generatedAt: Date(),
                                                  summary: "Example brief", keyQuestions: [], concepts: []))
            let examPlan = model.examPlanRoot.appending(path: "ExamPlan.pdf")
            try Data("%PDF-fixture".utf8).write(to: examPlan)
            let other = SnapshotStore(rootDirectory: model.localDataRoot, accountKey: "1-2002")
            try await other.save([StoredId(1)], collection: "starred", coverage: .complete, checkpoint: nil, at: Date())

            await model.signOut(removeLocalData: true)

            #expect(model.authState == .signingIn)
            #expect(model.signInStatus == nil)
            #expect(model.searchIndex == nil)
            #expect(await store.load(Course.self, collection: "courses") == nil)
            #expect(await other.load(StoredId.self, collection: "starred") == nil)
            #expect(await downloads.allAssets().isEmpty)
            #expect(await briefs.all().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: model.localDataRoot.appending(path: "Accounts").path))
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!FileManager.default.fileExists(atPath: examPlan.path))
            await #expect(throws: SearchDatabaseError.self) { try await index.count() }
            await #expect(throws: SearchDatabaseError.self) { try await store.searchDatabase() }
            await #expect(throws: CancellationError.self) {
                try await store.save([StoredId(1)], collection: "starred", coverage: .complete, checkpoint: nil, at: Date())
            }
        }
    }

    @Test func conversationLoaderUsesCursorToReachPastFirstTenThreads() async throws {
        let transport = SpecTransport { request in
            guard request.routeTemplate == "instantmessages/messagethreads/v4" else { return nil }
            let cursor = request.query.first(where: { $0.name == "fromSortIndex" })?.value
            let range: ClosedRange<Int>
            switch cursor {
            case nil: range = 1...10
            case "90": range = 10...16
            default: return SpecTransport.json("{}", status: 403)
            }
            let items = range.map {
                #"{"InstantMessageThreadId":\#($0),"SortIndex":\#(100 - $0)}"#
            }.joined(separator: ",")
            return SpecTransport.json(#"{"Threads":{"EntityArray":[\#(items)]},"HasMore":\#(cursor == nil)}"#)
        }
        try await withTestModel(transport: transport) { model in
            let loader = ConversationLoader()
            await loader.load(using: model)
            #expect(loader.records.map(\.threadId) == Array(1...10))
            #expect(loader.cursor == 90)
            await loader.loadMore(using: model)
            #expect(loader.records.map(\.threadId) == Array(1...16))
            #expect(loader.cursor == nil)
            #expect(loader.pageError == nil)
            let snapshot = await model.snapshots?.load(MessageThread.self, collection: "message-conversations")
            #expect(snapshot?.records.count == 16)
        }
    }

    @Test func calendarDistinguishesACompleteEmptyWeekFromAReadFailure() async throws {
        let fails = OSAllocatedUnfairLock(initialState: false)
        let transport = SpecTransport { request in
            guard request.routeTemplate == "calendar/events/v1" else { return nil }
            return SpecTransport.json(FixtureTransport.page("", count: 0), status: fails.withLock({ $0 }) ? 403 : 200)
        }
        try await withTestModel(transport: transport) { model in
            let date = Date()
            guard case .loaded(let events, let complete) = await model.loadWeekEvents(weekContaining: date) else {
                Issue.record("Expected a successful empty week")
                return
            }
            #expect(events.isEmpty && complete)
            fails.withLock { $0 = true }
            guard case .failed(let message) = await model.loadWeekEvents(weekContaining: date) else {
                Issue.record("Expected a failed refresh")
                return
            }
            #expect(!message.isEmpty)
            #expect(await model.cachedWeekEvents(weekContaining: date)?.coverage == .complete)
        }
    }

    @Test func prefetchedFilesAreEvictedAndExplicitlyOpenedFilesAreKept() async throws {
        try await withTestModel { model in
            await model.waitForSearchReadyForTesting()
            await model.loadFolder(courseId: 11, folderId: nil)
            await model.loadFolder(courseId: 11, folderId: 701)
            let store = try #require(model.downloads)
            let syllabus = try #require(model.resources[AppModel.folderKey(courseId: 11, folderId: nil)]?.first { $0.elementId == 702 })
            let notes = try #require(model.resources[AppModel.folderKey(courseId: 11, folderId: 701)]?.first { $0.elementId == 704 })
            await model.download(syllabus, isAutoPrefetched: true)
            await model.download(notes, isAutoPrefetched: true)
            #expect(model.savedAssets[syllabus.id]?.isAutoPrefetched == true)
            #expect(model.savedAssets[notes.id]?.isAutoPrefetched == true)
            await model.open(syllabus)
            let keptFile = try #require(model.viewerItem?.fileURL)
            await model.enforcePrefetchQuota(store: store, maxBytes: 0)
            #expect(model.savedAssets[syllabus.id]?.isAutoPrefetched == false)
            #expect(model.savedAssets[notes.id] == nil)
            #expect(await store.asset(for: notes.id) == nil)
            #expect(FileManager.default.fileExists(atPath: keptFile.path))
        }
    }

    private nonisolated static let tokens = OAuthTokens(
        accessToken: "example-access", refreshToken: "example-refresh", expiresAt: .distantPast
    )

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

    @Test func sweepTemporarySessionFoldersRemovesOrphanedEphemeralAndOfficeDirectories() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "LaerSweepTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ephemeral = dir.appending(path: "LaerEphemeral-123")
        let office = dir.appending(path: "LaerOffice-456")
        let unrelated = dir.appending(path: "KeepMe")
        try FileManager.default.createDirectory(at: ephemeral, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: office, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        #expect(AppModel.sweepTemporarySessionFolders(in: dir))
        #expect(!FileManager.default.fileExists(atPath: ephemeral.path))
        #expect(!FileManager.default.fileExists(atPath: office.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func optionalFeaturesDefaultOffAndPersistOnboardingChoice() async throws {
        let defaults = UserDefaults.standard
        let priorFetch = defaults.object(forKey: AppModel.fetchesAheadKey)
        let priorAsked = defaults.object(forKey: AppModel.optionalFeaturesAskedKey)
        defaults.removeObject(forKey: AppModel.fetchesAheadKey)
        defaults.removeObject(forKey: AppModel.optionalFeaturesAskedKey)
        defer {
            if let priorFetch { defaults.set(priorFetch, forKey: AppModel.fetchesAheadKey) }
            else { defaults.removeObject(forKey: AppModel.fetchesAheadKey) }
            if let priorAsked { defaults.set(priorAsked, forKey: AppModel.optionalFeaturesAskedKey) }
            else { defaults.removeObject(forKey: AppModel.optionalFeaturesAskedKey) }
        }

        try await withTestModel { model in
            #expect(!model.fetchesAhead)
            #expect(!model.hasSeenOptionalFeaturesPrompt)
            await model.dismissOptionalFeaturesPrompt(fetchAhead: true, lectureBriefs: false)
            #expect(model.hasSeenOptionalFeaturesPrompt)
            #expect(model.fetchesAhead)
            await model.dismissOptionalFeaturesPrompt(fetchAhead: false, lectureBriefs: false)
            #expect(!model.fetchesAhead)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LAER_CAPTURE_README_SHOTS"] != nil))
    func captureReadmeShowcaseScreenshots() async throws {
        let outURL = FileManager.default.temporaryDirectory.appending(path: "laer-readme-shots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        let priorShowcase = defaults.object(forKey: "LaerFixtureShowcase")
        defaults.set(true, forKey: "LaerFixtureShowcase")
        defer {
            if let priorShowcase { defaults.set(priorShowcase, forKey: "LaerFixtureShowcase") }
            else { defaults.removeObject(forKey: "LaerFixtureShowcase") }
        }

        try await withTestModel { model in
            await model.waitForSearchReadyForTesting()
            let updater = Updater()
            for (appearanceName, fileName) in [(NSAppearance.Name.aqua, "screenshot-light.png"), (.darkAqua, "screenshot-dark.png")] {
                let appearance = NSAppearance(named: appearanceName)
                NSApp.appearance = appearance
                let size = NSSize(width: 1200, height: 780)
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.appearance = appearance
                let hosting = NSHostingView(
                    rootView: RootView()
                        .environment(model)
                        .environment(updater)
                        .environment(\.colorScheme, appearanceName == .darkAqua ? .dark : .light)
                        .frame(width: size.width, height: size.height)
                )
                hosting.appearance = appearance
                window.contentView = hosting
                window.layoutIfNeeded()
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(900))
                hosting.layoutSubtreeIfNeeded()

                let targetView = window.contentView?.superview ?? hosting
                guard let rep = targetView.bitmapImageRepForCachingDisplay(in: targetView.bounds) else {
                    Issue.record("Could not create bitmap rep for \(fileName)")
                    continue
                }
                targetView.cacheDisplay(in: targetView.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    Issue.record("Could not encode PNG for \(fileName)")
                    continue
                }
                try png.write(to: outURL.appending(path: fileName))
                window.close()
            }
            NSApp.appearance = nil
        }
    }
}


private struct SpecTransport: ReadTransport {
    let override: @Sendable (ReadRequest) -> ReadResponse?

    func send(_ request: ReadRequest) async throws -> ReadResponse {
        if let response = override(request) { return response }
        return try await FixtureTransport().send(request)
    }

    static func json(_ body: String, status: Int = 200) -> ReadResponse {
        ReadResponse(status: status, contentType: "application/json", finalURL: FixtureTransport.site.baseURL, body: Data(body.utf8))
    }
}

private struct SuspendedOperation: Sendable {
    private let started = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    func pause() async {
        started.continuation.yield()
        started.continuation.finish()
        for await _ in released.stream { break }
    }

    func waitUntilStarted() async {
        for await _ in started.stream { break }
    }

    func resume() {
        released.continuation.yield()
        released.continuation.finish()
    }
}
