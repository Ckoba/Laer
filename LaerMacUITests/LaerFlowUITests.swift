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
            // Only text is compared by value: other elements can hold non-strings, which throws inside the query.
            // Course text bodies are read-only text views.
            .matching(NSPredicate(
                format: "label CONTAINS %@ OR title CONTAINS %@ OR ((elementType == %d OR elementType == %d) AND value CONTAINS %@)",
                text, text, XCUIElement.ElementType.staticText.rawValue, XCUIElement.ElementType.textView.rawValue, text
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
        XCTAssertTrue(element(app, containing: "Schedule").waitForExistence(timeout: 10), "Home did not show")
        XCTAssertTrue(sidebar(app, "course.11").waitForExistence(timeout: 5), "The archive list did not open")
    }

    func testOpenCourseShowsUpdatesAndMaterials() {
        let app = launch()
        openCourseOne(app)
        XCTAssertTrue(tab(app, "Plans").waitForExistence(timeout: 10))
        XCTAssertTrue(tab(app, "Plans").isSelected, "Plans is not the default tab")
        openUpdates(app)
        XCTAssertTrue(element(app, containing: "Exam moved to").waitForExistence(timeout: 10), "The course's updates did not show")

        open(tab(app, "Files"), "The Files tab")
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
        open(tab(app, "Files"), "The Files tab")
        let row = element(app, containing: "Syllabus.pdf")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(element(app, labelContainsAll: ["Syllabus.pdf", "Downloaded"]).waitForExistence(timeout: 15), "The material was not marked downloaded")
        // The file opens in the right panel, in this window. The window's own close button is left out.
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close file' AND identifier != '_XCUI:CloseWindow'")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The saved file did not open in the right panel")
        XCTAssertTrue(close.isHittable, "The right panel's close button is outside the window")

        let handle = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Resize file panel'")).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "The reader's resize divider did not appear")
        let window = app.windows.firstMatch
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)))
        let toggle = app.buttons["viewer.toggleFull"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 5) { toggle.label == "Restore split view" }, "Dragging left did not expand the reader")
        toggle.click()
        XCTAssertTrue(waitUntil(timeout: 5) { self.tab(app, "Files").isHittable }, "Restoring split view did not reveal the course")

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
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close file' AND identifier != '_XCUI:CloseWindow'")).firstMatch
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

    func testMessagesSayWhoSentEach() {
        let app = launch()
        open(rail(app, "messages"), "Messages in the rail")
        open(element(app, containing: "Lab report"), "The two-sided fixture thread")
        XCTAssertTrue(element(app, labelContainsAll: ["You", "Sure, on it now."]).waitForExistence(timeout: 10),
                      "A sent message did not say it was the signed-in person's")
        XCTAssertTrue(element(app, labelContainsAll: ["Kim Example", "Two things left:"]).exists,
                      "A received message did not name its sender")
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
        // The actions toolbar shows when the pointer is over the message, as for a person using it.
        message.hover()
        // A SwiftUI menu button exposes its name as the title and keeps its symbol's description ("More") as the label.
        let actions = app.descendants(matching: .any)
            .matching(NSPredicate(format: "title == 'Message actions' OR label == 'Message actions'")).firstMatch
        open(actions, "The message actions menu")
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
        open(tab(app, "Files"), "The Files tab")
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
        open(sidebar(app, "course.12.Files"), "The Files row under the course")
        XCTAssertTrue(tab(app, "Files").waitForExistence(timeout: 10))
        XCTAssertTrue(tab(app, "Files").isSelected, "The Files row did not open that tab")
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

    func testPaletteOpensTheIndexedPlan() {
        let app = launch()
        openCourseOne(app)
        open(element(app, containing: "Show previous lectures"), "The indexed plan has loaded")
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["Search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("introduction and reading")
        let result = app.descendants(matching: .any)["search.result.plan-11-601"].firstMatch
        open(result, "A plan found by its description")
        XCTAssertTrue(app.descendants(matching: .any)["search.plan.601"].firstMatch.waitForExistence(timeout: 10), "Search did not open plan 601")
        XCTAssertTrue(app.descendants(matching: .any)["plan.resource.702"].firstMatch.waitForExistence(timeout: 10),
                      "The exact plan should show its materials")
    }

    func testOnlineResultsAppendWithoutReplacingTheSelectedLocalHit() {
        let app = launch(["-LaerSearchOnline", "YES"])
        openCourseOne(app)
        open(tab(app, "Files"), "The local course materials")
        XCTAssertTrue(element(app, containing: "Syllabus.pdf").waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["Search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Syllabus")
        let local = app.descendants(matching: .any).matching(identifier: "search.result.material-11-learningtoolelement-702")
        let online = app.descendants(matching: .any)["search.result.material-11-learningtoolelement-799"].firstMatch
        XCTAssertTrue(local.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(online.waitForExistence(timeout: 10))
        XCTAssertEqual(local.count, 1, "The online match for a local file is joined by stable ID")
        keepScreenshot(app, name: "Local and online search results")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Close Syllabus.pdf"].firstMatch.waitForExistence(timeout: 10))
    }

    func testPaletteOpensThePageFoundInsideASavedPDF() {
        let app = launch(["-viewerPagesLocked", "NO"])
        openCourseOne(app)
        open(tab(app, "Files"), "The Files tab")
        open(element(app, containing: "Syllabus.pdf"), "The PDF to save")
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close file' AND identifier != '_XCUI:CloseWindow'")).firstMatch
        open(close, "The open PDF")
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["Search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("silted up")
        let result = app.descendants(matching: .any)["search.result.document-LearningToolElement-702-1"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        keepScreenshot(app, name: "PDF text search")
        open(result, "Text from page two of the saved PDF")
        let page = element(app, containing: "Page 2 of 3")
        let indicator = app.staticTexts["viewer.pdf.page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15), "The PDF reader indicator: \(indicator.debugDescription)")
        keepScreenshot(app, name: "PDF page opened from search")
        // Back reopens the palette with the same query and results; Forward returns to the page.
        open(app.buttons["topbar.back"].firstMatch, "Back in the top bar")
        XCTAssertEqual(app.textFields["Search"].firstMatch.value as? String, "silted up")
        XCTAssertTrue(result.exists)
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(page.waitForExistence(timeout: 15), "Forward did not return to page two")
        XCTAssertFalse(app.textFields["Search"].firstMatch.exists)
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPaletteFindsOCRTextAndOpensTheScannedPage() {
        let app = launch(["-LaerSearchOCR", "YES", "-LaerFixtureScannedPDF", "YES", "-viewerPagesLocked", "NO"])
        openCourseOne(app)
        open(tab(app, "Files"), "The Files tab")
        open(element(app, containing: "Syllabus.pdf"), "The scanned PDF to save")
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close file' AND identifier != '_XCUI:CloseWindow'")).firstMatch
        open(close, "The open PDF")
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["Search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("field observations")
        let result = app.descendants(matching: .any)["search.result.document-LearningToolElement-702-1"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "Vision text from the image-only page did not become searchable")
        XCTAssertTrue(element(app, containing: "OCR · may contain errors").exists, "OCR results should be marked")
        keepScreenshot(app, name: "OCR match for an image-only PDF page")
        open(result, "Text recognized on page two")
        XCTAssertTrue(element(app, containing: "Page 2 of 3").waitForExistence(timeout: 15))
    }

    func testWeekCalendarMovesByWeek() throws {
        let app = launch()
        open(rail(app, "calendar"), "Calendar in the rail")
        let next = app.buttons["Next week"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Today"].waitForExistence(timeout: 5), "Today should sit between the week arrows")
        let prefix = "calendar.day."
        let days = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        XCTAssertTrue(days.firstMatch.waitForExistence(timeout: 5))
        let epoch = try XCTUnwrap(TimeInterval(days.firstMatch.identifier.dropFirst(prefix.count)))
        let initialDay = Date(timeIntervalSince1970: epoch)
        let advancedDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: initialDay))
        let advancedID = prefix + String(Int(advancedDay.timeIntervalSince1970))
        next.click()
        XCTAssertTrue(days[advancedID].waitForExistence(timeout: 5), "Next week did not advance seven days")
        app.buttons["Today"].click()
        XCTAssertTrue(days[prefix + String(Int(epoch))].waitForExistence(timeout: 5), "Today did not return to the original week")
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
        open(app.buttons["Older messages"], "The older messages button")
        XCTAssertTrue(element(app, containing: "Earlier message").waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["Older messages"].exists }, "Older messages stayed after the last page")
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
        XCTAssertTrue(element(app, containing: "No deadline").waitForExistence(timeout: 15), "The no deadline section did not appear")
        let quiz = element(app, containing: "Reading quiz")
        XCTAssertTrue(quiz.waitForExistence(timeout: 15))
        quiz.click()
        XCTAssertFalse(app.textFields["Answer text"].waitForExistence(timeout: 3))
    }
}
