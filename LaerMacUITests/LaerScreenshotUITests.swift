import XCTest

/// Walks every screen on the stress fixtures in light and dark mode and keeps a screenshot of
/// each in the result bundle, for checking layout by eye. Asserts only that each screen opens.
@MainActor
final class LaerScreenshotUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = true
    }

    func testScreensLight() { walk(appearance: "Light") }
    func testScreensDark() { walk(appearance: "Dark") }

    private func walk(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES", "-LaerUITestReset", "YES",
            "-LaerFixtureMode", "YES", "-LaerFixtureStress", "YES", "-LaerUITestAppearance", appearance,
            "-viewerPagesLocked", "NO",
            // The window comes back at the size the last run left it, and the dark walk ends at the
            // smallest; a set size keeps each walk independent of the one before.
            "-LaerUITestWindowSize", "1180x760",
        ]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sidebar.course.14"].waitForExistence(timeout: 15), "The stress course did not show")
        settle()
        shot(app, "\(appearance) 01 Home")

        click(any["rail.upcoming"])
        click(app.buttons["All courses"])
        shot(app, "\(appearance) 02 Upcoming")

        click(any["rail.calendar"])
        shot(app, "\(appearance) 03 Calendar")

        click(any["rail.messages"])
        click(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'very long name'")).firstMatch)
        shot(app, "\(appearance) 04 Messages")

        click(any["sidebar.course.14"])
        shot(app, "\(appearance) 05 Course plans")
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -1200)
        shot(app, "\(appearance) 06 Course plans scrolled")

        click(any["tab.Updates"])
        shot(app, "\(appearance) 07 Course updates")
        click(any["tab.Files"])
        shot(app, "\(appearance) 08 Course materials")

        any["sidebar.course.14"].hover()
        click(any["sidebar.expand.14"])
        shot(app, "\(appearance) 09 Sidebar expanded")

        click(any["rail.archive"])
        shot(app, "\(appearance) 10 Archive")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["Search"].firstMatch
        if field.waitForExistence(timeout: 5) {
            field.typeText("zzzzqqq")
            settle()
            shot(app, "\(appearance) 11 Palette no results")
            field.typeKey(.escape, modifierFlags: [])
        }

        click(any["sidebar.course.11"].exists ? any["sidebar.course.11"] : any["sidebar.course.12"])
        click(any["tab.Files"])
        click(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Syllabus.pdf'")).firstMatch)
        settle(2)
        shot(app, "\(appearance) 12 File open")
        // Smallest window: drag the bottom-right corner up and left as far as it goes.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.999))
            .press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)))
        settle(1.5)
        shot(app, "\(appearance) 13 Minimum window with file")

        // Keyboard focus ring.
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        shot(app, "\(appearance) 14 Focus ring")
    }

    private func click(_ element: XCUIElement) {
        guard element.waitForExistence(timeout: 10) else {
            XCTFail("Missing: \(element)")
            return
        }
        element.click()
        settle()
    }

    private func settle(_ seconds: TimeInterval = 1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
