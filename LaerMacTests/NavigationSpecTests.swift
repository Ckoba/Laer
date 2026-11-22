import Foundation
import LaerCore
import Testing
@testable import Laer

@Suite(.serialized)
@MainActor
struct NavigationSpecTests {
    private func withTestNavigation(_ body: (AppModel, Navigation) async throws -> Void) async throws {
        let model = await AppModel.forTesting()
        let navigation = Navigation()
        navigation.start(model)
        do {
            try await body(model, navigation)
        } catch {
            await model.cleanupForTesting()
            throw error
        }
        await model.cleanupForTesting()
    }

    @Test func historyRecordsMovesAndRestoresSearchPaletteState() async throws {
        try await withTestNavigation { model, navigation in
            #expect(!navigation.canGoBack && !navigation.canGoForward)

            model.selection = .course(11)
            navigation.record()
            #expect(navigation.canGoBack)

            let hit = SearchHit(
                id: "plan-11-601", kind: .plan, title: "Week one",
                courseId: 11, destination: .plan(courseId: 11, planId: 601)
            )
            let returnState = SearchReturnState(
                text: "silted up",
                scope: .everywhere,
                kind: nil,
                fileType: nil,
                selectedID: hit.id,
                visibleCount: 20,
                localHits: [hit],
                onlineHits: [],
                onlineSummary: nil,
                expandedDocuments: []
            )
            navigation.arrive(at: hit, from: returnState) {
                model.selection = .course(11)
                navigation.courseTabs[11] = .plans
            }
            #expect(navigation.searchTarget?.id == hit.id)

            navigation.goBack()
            #expect(navigation.isPaletteOpen)
            #expect(navigation.paletteRestore?.text == "silted up")
            #expect(navigation.paletteRestore?.localHits.map(\.id) == [hit.id])
            #expect(navigation.canGoForward)

            navigation.goForward()
            #expect(!navigation.isPaletteOpen)
            #expect(navigation.searchTarget?.id == hit.id)
        }
    }

    @Test func unsentDraftBlocksHistoryMoveUntilConfirmed() async throws {
        try await withTestNavigation { model, navigation in
            model.selection = .messages
            navigation.record()
            navigation.hasDraft = true

            navigation.goBack()
            #expect(navigation.pendingMove == .back)
            #expect(model.selection == .messages)

            navigation.move(.back, confirmed: true)
            #expect(navigation.pendingMove == nil)
            #expect(model.selection == .home)
        }
    }

    @Test func bellOpensCourseUpdatesAndPlanInTheWindow() async throws {
        try await withTestNavigation { model, navigation in
            let items = try await ItslearningClient(transport: FixtureTransport()).notifications()
            let courseUpdate = try #require(items.first)
            let plan = try #require(items.last)

            #expect(navigation.openNotification(courseUpdate) == nil)
            #expect(model.selection == .course(11))
            #expect(navigation.tab(for: 11) == .updates)
            navigation.record()

            #expect(navigation.openNotification(plan) == nil)
            #expect(navigation.tab(for: 11) == .plans)
            #expect(navigation.searchTarget?.destination == .plan(courseId: 11, planId: 601))
            navigation.record()

            navigation.goBack()
            #expect(navigation.tab(for: 11) == .updates)
            navigation.goBack()
            #expect(model.selection == .home)
            navigation.goForward()
            navigation.goForward()
            #expect(navigation.searchTarget?.destination == .plan(courseId: 11, planId: 601))
        }
    }

    @Test func nativeLinksOpenTheSpecificAssignmentAndFolder() async throws {
        try await withTestNavigation { model, navigation in
            let assignment = try #require(model.absoluteURL("/main.aspx?CourseID=11&ElementID=70&ElementType=131072"))
            #expect(navigation.openSiteLink(assignment))
            #expect(model.selection == .upcoming)
            #expect(navigation.openTask?.taskId == 801)

            let folder = try #require(model.absoluteURL("/Resources?FolderID=701"))
            #expect(navigation.openSiteLink(folder, courseId: 11))
            #expect(model.selection == .course(11))
            #expect(navigation.tab(for: 11) == .materials)
            #expect(navigation.folder(for: 11).path.map(\.elementId) == [701])
        }
    }

    @Test func unsupportedBellLinksStillFallBackToTheirWebsite() async throws {
        try await withTestNavigation { model, navigation in
            let item = try JSONDecoder().decode(ParityNotification.self, from: Data(#"""
                {"NotificationId": 9, "Url": "https://example.org/main.aspx?CourseId=11",
                 "ContentUrl":"/main.aspx?CourseId=11&ElementID=70&ElementType=1"}
                """#.utf8))
            #expect(navigation.openNotification(item) == URL(string: "https://example.org/main.aspx?CourseId=11"))
            #expect(model.selection == .home)
        }
    }
}
