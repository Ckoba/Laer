import XCTest

@MainActor
final class LaerUITests: XCTestCase {
    func testFirstRunAsksForInstitution() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-LaerUITestReset", "YES"]
        app.launch()
        XCTAssertTrue(app.textFields["Institution"].waitForExistence(timeout: 10))
    }
}
