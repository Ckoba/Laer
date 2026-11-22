import XCTest

/// Thin smoke checks wired strictly by stable accessibility identifiers.
/// Behavioral and state coverage lives in `LaerMacTests` and `LaerCoreTests`.
@MainActor
final class LaerSmokeUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testFirstRunAsksForInstitution() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-LaerUITestReset", "YES"]
        app.launch()
        XCTAssertTrue(app.textFields["Institution"].waitForExistence(timeout: 10))
    }

    func testCoreShellAndReaderSmoke() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-LaerUITestReset", "YES",
            "-LaerFixtureMode", "YES",
            "-viewerPagesLocked", "NO",
        ]
        app.launch()

        let nodes = app.descendants(matching: .any)

        let activeCourse = nodes["sidebar.course.12"].firstMatch
        XCTAssertTrue(activeCourse.waitForExistence(timeout: 15))

        let sidebarToggle = nodes["topbar.sidebar"].firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))
        sidebarToggle.click()
        XCTAssertTrue(nodes["rail.course.12"].firstMatch.waitForExistence(timeout: 5))
        sidebarToggle.click()
        XCTAssertTrue(activeCourse.waitForExistence(timeout: 5))

        activeCourse.click()
        XCTAssertTrue(nodes["tab.Plans"].firstMatch.waitForExistence(timeout: 10))
        nodes["tab.Updates"].firstMatch.click()
        nodes["tab.Files"].firstMatch.click()

        nodes["rail.messages"].firstMatch.click()
        nodes["rail.calendar"].firstMatch.click()
        nodes["rail.upcoming"].firstMatch.click()

        app.typeKey("k", modifierFlags: .command)
        let palette = nodes["palette"].firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(nodes["sidebar.course.12"].firstMatch.waitForExistence(timeout: 5))
    }
}
