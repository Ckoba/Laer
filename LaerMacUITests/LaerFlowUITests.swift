import XCTest

/// End-to-end flows on synthetic fixture data, launched with `-LaerFixtureMode YES`.
@MainActor
final class LaerFlowUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-LaerUITestReset", "YES", "-LaerFixtureMode", "YES",
            // Launch-time values, so the person's own sidebar and page settings never reach the tests.
            "-showsSidebar", "YES", "-viewerPagesLocked", "NO"] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            // Only static text is compared by value: other elements can hold non-strings, which throws inside the query.
            .matching(NSPredicate(
                format: "label CONTAINS %@ OR title CONTAINS %@ OR (elementType == %d AND value CONTAINS %@)",
                text, text, XCUIElement.ElementType.staticText.rawValue, text
            ))
            .firstMatch
    }

    /// An element whose label holds every fragment, for rows SwiftUI combines into one label.
    private func element(_ app: XCUIApplication, labelContainsAll fragments: [String]) -> XCUIElement {
        let predicates = fragments.map { NSPredicate(format: "label CONTAINS %@", $0) }
        return app.descendants(matching: .any)
            .matching(NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
            .firstMatch
    }

    /// Sidebar rows and section tabs by identifier, so a menu item or a row elsewhere never matches.
    private func sidebar(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let row = app.descendants(matching: .any)["sidebar.\(name)"].firstMatch
        if row.waitForExistence(timeout: 5) { return row }
        // Courses that are not active are in the rail's archive list; open it the way a person would.
        let archive = rail(app, "archive")
        if archive.waitForExistence(timeout: 5) { archive.click() }
        return app.descendants(matching: .any)["archive.\(name)"].firstMatch
    }

    /// Rail icons: search, home, upcoming, calendar, messages.
    private func rail(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["rail.\(name)"].firstMatch
    }

    private func openUpdates(_ app: XCUIApplication) {
        open(tab(app, "Updates"), "The Updates tab")
    }

    private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)["tab.\(title)"].firstMatch
    }

    private func open(_ target: XCUIElement, _ what: String) {
        XCTAssertTrue(target.waitForExistence(timeout: 15), "\(what) did not appear")
        target.click()
    }

    private func openCourseOne(_ app: XCUIApplication) {
        open(sidebar(app, "course.11"), "Course one in the sidebar")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    func testLaunchShowsCourses() {
        let app = launch()
        XCTAssertTrue(sidebar(app, "course.12").waitForExistence(timeout: 15), "The active course did not show")
        XCTAssertTrue(rail(app, "home").exists)
        XCTAssertTrue(element(app, containing: "Today").waitForExistence(timeout: 10), "Home did not show")
        XCTAssertTrue(sidebar(app, "course.11").waitForExistence(timeout: 5), "The archive list did not open")
    }

    func testOpenCourseShowsUpdatesAndMaterials() {
        let app = launch()
        openCourseOne(app)
        XCTAssertTrue(tab(app, "Plans").waitForExistence(timeout: 10))
        XCTAssertTrue(tab(app, "Plans").isSelected, "Plans is not the default tab")
        openUpdates(app)
        XCTAssertTrue(element(app, containing: "Exam moved to").waitForExistence(timeout: 10), "The course's updates did not show")

        open(tab(app, "Materials"), "The Materials tab")
        XCTAssertTrue(element(app, containing: "Syllabus.pdf").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, containing: "Course page").exists)
    }

    func testEmptyCourseSaysSo() {
        let app = launch()
        open(sidebar(app, "course.13"), "Empty course in the sidebar")
        openUpdates(app)
        XCTAssertTrue(element(app, containing: "No recent updates").waitForExistence(timeout: 10))
    }

    func testRefreshKeepsContent() {
        let app = launch()
        openCourseOne(app)
        openUpdates(app)
        XCTAssertTrue(element(app, containing: "Exam moved to").waitForExistence(timeout: 10))
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element(app, containing: "Exam moved to").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, containing: "The refresh failed").exists)
    }

    func testOpenSavedMaterial() {
        let app = launch()
        openCourseOne(app)
        open(tab(app, "Materials"), "The Materials tab")
        let row = element(app, containing: "Syllabus.pdf")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(element(app, labelContainsAll: ["Syllabus.pdf", "Saved"]).waitForExistence(timeout: 15), "The material was not marked saved")
        // The file opens in the right panel, in this window. The window's own close button is left out.
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close' AND identifier != '_XCUI:CloseWindow'")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The saved file did not open in the right panel")
        XCTAssertTrue(close.isHittable, "The right panel's close button is outside the window")
        close.click()
        XCTAssertTrue(waitUntil(timeout: 5) { !close.exists }, "Close did not close the right panel")
        row.click()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "A saved file did not open again")
    }

    func testPlanFileOpensInPanel() {
        let app = launch()
        openCourseOne(app)
        XCTAssertTrue(tab(app, "Plans").waitForExistence(timeout: 10))
        open(element(app, containing: "Show previous lectures"), "The previous lectures group")
        open(element(app, labelContainsAll: ["Week one", "2 files"]), "The past plan")
        open(element(app, containing: "Syllabus.pdf"), "The plan's file")
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close' AND identifier != '_XCUI:CloseWindow'")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15), "The plan's file did not open in the right panel")
        XCTAssertTrue(close.isHittable, "The right panel's close button is outside the window")
    }

    func testPageStripOpensOnHoverAndCloses() {
        let app = launch()
        openCourseOne(app)
        XCTAssertTrue(tab(app, "Plans").waitForExistence(timeout: 10))
        open(element(app, containing: "Show previous lectures"), "The previous lectures group")
        open(element(app, labelContainsAll: ["Week one", "2 files"]), "The past plan")
        open(element(app, containing: "Syllabus.pdf"), "The plan's file")
        let window = app.windows.firstMatch
        XCTAssertTrue(element(app, containing: "Page 1 of 3").waitForExistence(timeout: 15), "The page ticks did not appear")
        let strip = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: window.frame.width - 19, dy: 0))
        strip.hover()
        let pages = element(app, containing: "3 pages")
        XCTAssertTrue(pages.waitForExistence(timeout: 3), "Hovering the ticks did not open the pages")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).hover()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pages)
        wait(for: [closed], timeout: 3)
    }

    func testDoubleClickOnTopBarZooms() {
        let app = launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let before = window.frame
        let bar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 20))
        bar.doubleClick()
        let changed = expectation(for: NSPredicate { _, _ in window.frame != before }, evaluatedWith: window)
        wait(for: [changed], timeout: 4)
        bar.doubleClick()
    }

    func testRecoverFromSignedOut() {
        let app = launch(["-LaerFixtureSignedOut", "YES"])
        let signIn = app.buttons["Sign in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15), "No sign-in prompt for a signed-out session")
        XCTAssertFalse(element(app, containing: "Course one").exists, "Nothing was cached, so no course should show")
        signIn.click()
        XCTAssertTrue(sidebar(app, "course.12").waitForExistence(timeout: 15), "Courses did not load after signing in")
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["Sign in"].exists }, "The sign-in prompt stayed after recovery")
    }

    func testMessagesShowThread() {
        let app = launch()
        open(rail(app, "messages"), "Messages in the rail")
        open(element(app, containing: "Group work"), "The fixture thread")
        XCTAssertTrue(element(app, containing: "Here is the outline.").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, containing: "outline.pdf").exists, "The attachment did not show")
    }

    func testReplySendsOnceAndClears() {
        let app = launch()
        open(rail(app, "messages"), "Messages in the rail")
        open(element(app, containing: "Group work"), "The fixture thread")
        let reply = app.textFields["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.click()
        reply.typeText("Sent from Laer")
        app.buttons["Send"].click()
        XCTAssertTrue(element(app, containing: "Sent from Laer").waitForExistence(timeout: 10), "The thread did not show the sent message")
        XCTAssertTrue(waitUntil(timeout: 5) { (reply.value as? String ?? "").isEmpty }, "The reply field did not clear")
        XCTAssertFalse(element(app, containing: "didn't go through").exists)
    }

    func testDeleteAsksInPlace() {
        let app = launch()
        open(rail(app, "messages"), "Messages in the rail")
        open(element(app, containing: "Group work"), "The fixture thread")
        let message = element(app, containing: "Here is the outline.")
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        // The first message is the oldest, "Here is the outline."
        open(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Message actions'")).firstMatch, "The message actions menu")
        let delete = app.menuItems["Delete…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        XCTAssertTrue(element(app, containing: "Delete this message for everyone").waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertTrue(waitUntil(timeout: 3) { !self.element(app, containing: "Delete this message for everyone").exists })
        XCTAssertTrue(message.exists, "Cancel must not delete")
    }

    func testCoursePageRendersNatively() {
        let app = launch()
        openCourseOne(app)
        open(tab(app, "Materials"), "The Materials tab")
        open(element(app, containing: "Course page"), "The course page material")
        XCTAssertTrue(element(app, containing: "Bring the reader").waitForExistence(timeout: 10))
        XCTAssertEqual(app.webViews.count, 0, "Page content must not render in a web view")
    }

    func testMakeActiveAndRemove() {
        let app = launch()
        // The archive icon exists only while some courses are active.
        let activeLabel = rail(app, "archive")
        XCTAssertTrue(activeLabel.waitForExistence(timeout: 15), "The fixture's active course did not show")
        let row = sidebar(app, "course.12")
        row.rightClick()
        let remove = app.menuItems["Remove from active"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        // With nothing active, every course shows as one list.
        XCTAssertTrue(waitUntil(timeout: 10) { !activeLabel.exists }, "Removing did not move the course back")
        let moved = sidebar(app, "course.12")
        XCTAssertTrue(moved.waitForExistence(timeout: 5))
        moved.rightClick()
        XCTAssertTrue(app.menuItems["Make active"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testChevronShowsCourseSections() {
        let app = launch()
        // The chevron shows on hover, as for a person pointing at the course.
        let course = sidebar(app, "course.12")
        XCTAssertTrue(course.waitForExistence(timeout: 15))
        course.hover()
        open(app.descendants(matching: .any)["sidebar.expand.12"].firstMatch, "The course chevron")
        open(sidebar(app, "course.12.Materials"), "The Materials row under the course")
        XCTAssertTrue(tab(app, "Materials").waitForExistence(timeout: 10))
        XCTAssertTrue(tab(app, "Materials").isSelected, "The Materials row did not open that tab")
    }

    func testParticipantsIsNotOffered() {
        let app = launch()
        open(sidebar(app, "course.12"), "The active course")
        XCTAssertTrue(tab(app, "Plans").waitForExistence(timeout: 10))
        XCTAssertFalse(tab(app, "Participants").exists, "Participants should not be in navigation")
    }

    func testPaletteFindsCourse() {
        let app = launch()
        XCTAssertTrue(sidebar(app, "course.12").waitForExistence(timeout: 15))
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["Search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘K did not open the palette")
        field.typeText("Course two")
        XCTAssertTrue(element(app, labelContainsAll: ["Course two"]).waitForExistence(timeout: 10))
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 3) { !app.textFields["Search"].exists }, "Esc did not close the palette")
    }

    func testWeekCalendarMovesByWeek() {
        let app = launch()
        open(rail(app, "calendar"), "Calendar in the rail")
        let next = app.buttons["Next week"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let thisWeek = app.buttons["This week"]
        XCTAssertFalse(thisWeek.isEnabled, "This week should be disabled on the current week")
        next.click()
        XCTAssertTrue(waitUntil(timeout: 3) { thisWeek.isEnabled }, "Next week did not move the grid")
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testNewConversation() {
        let app = launch()
        open(rail(app, "messages"), "Messages in the rail")
        open(app.buttons["New message"], "The new message button")
        let to = app.textFields["To"]
        XCTAssertTrue(to.waitForExistence(timeout: 5))
        to.click()
        to.typeText("Rob")
        open(element(app, containing: "Robin Example"), "The recipient search result")
        XCTAssertFalse(app.buttons["Course one"].exists, "Only people should be offered")
        let body = app.textFields["Message"]
        body.click()
        body.typeText("Hello from Laer")
        app.buttons["Send"].click()
        XCTAssertTrue(element(app, containing: "Hello from Laer").waitForExistence(timeout: 10), "The new conversation did not open")
    }

    func testOlderMessagesLoadOnRequest() {
        let app = launch()
        open(rail(app, "messages"), "Messages in the rail")
        open(element(app, containing: "Group work"), "The fixture thread")
        XCTAssertFalse(element(app, containing: "Earlier message").exists)
        open(app.buttons["Show older"], "The show older button")
        XCTAssertTrue(element(app, containing: "Earlier message").waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["Show older"].exists }, "Show older stayed after the last page")
    }

    func testSubmitAssignment() {
        let app = launch()
        open(rail(app, "upcoming"), "Upcoming in the rail")
        // The task belongs to a course that is not active.
        open(app.buttons["All courses"], "The all courses filter")
        open(element(app, containing: "Essay draft"), "The assignment task")
        XCTAssertTrue(element(app, containing: "words.").waitForExistence(timeout: 10), "The assignment description did not show")
        let answer = app.textFields["Answer text"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.click()
        answer.typeText("My answer")
        XCTAssertTrue(element(app, containing: "Submits your text").waitForExistence(timeout: 5), "Submit did not say what it sends")
        app.buttons["Submit"].click()
        XCTAssertTrue(element(app, containing: "Submitted").waitForExistence(timeout: 10))
    }

    func testNonAssignmentTaskDoesNotOpen() {
        let app = launch()
        open(rail(app, "upcoming"), "Upcoming in the rail")
        open(element(app, containing: "Show no deadline"), "The no deadline group")
        let quiz = element(app, containing: "Reading quiz")
        XCTAssertTrue(quiz.waitForExistence(timeout: 15))
        quiz.click()
        XCTAssertFalse(app.textFields["Answer text"].waitForExistence(timeout: 3))
    }
}
