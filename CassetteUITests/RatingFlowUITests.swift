// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import XCTest

/// Drives the rating flow against a real server: log in, rate an album from its context menu,
/// then read the badge back. Credentials come from the environment so nothing is committed:
///
///     CASSETTE_URL=... CASSETTE_USER=... CASSETTE_PASSWORD=... xcodebuild test ...
final class RatingFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let url = env["CASSETTE_URL"] ?? ""
        let user = env["CASSETTE_USER"] ?? ""
        let password = env["CASSETTE_PASSWORD"] ?? ""
        try XCTSkipIf(url.isEmpty || user.isEmpty || password.isEmpty, "Server credentials not provided")

        app = XCUIApplication()
        app.launch()

        if app.buttons["Get Started"].waitForExistence(timeout: 20) {
            signIn(url: url, user: user, password: password)
        }
    }

    private func signIn(url: String, user: String, password: String) {
        app.buttons["Get Started"].tap()

        let serverField = app.textFields.firstMatch
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "server field")
        serverField.tap()
        serverField.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        serverField.typeText(url)

        let username = app.textFields["Username"]
        username.tap()
        username.typeText(user)

        let secure = app.secureTextFields["Password"]
        secure.tap()
        secure.typeText(password)

        app.buttons["Connect & Save"].tap()

        let done = app.buttons["Start Listening"]
        XCTAssertTrue(done.waitForExistence(timeout: 60), "login did not complete")
        attach(name: "01-onboarding-complete")
        done.tap()
    }

    func testRateAnAlbumFromItsContextMenu() throws {
        // The "Recently Added" card on Home is an album with the same context menu as the
        // album list, and reaching it needs no navigation.
        dismissPasswordPrompt()
        let card = try waitForAlbumCard()
        attach(name: "02-home")

        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.3)
        let rate = app.buttons["Rate Album…"]
        XCTAssertTrue(rate.waitForExistence(timeout: 10), "rate action missing from context menu")
        attach(name: "03-context-menu")
        tap(rate)

        XCTAssertTrue(app.staticTexts["Rate Album"].waitForExistence(timeout: 10), "rating sheet did not open")
        let raise = app.buttons["Raise by 0.1"]
        XCTAssertTrue(raise.waitForExistence(timeout: 5), "fine tune button missing")
        for _ in 0..<23 { tap(raise) }
        attach(name: "04-rating-sheet")

        let save = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Save '")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save button missing")
        let savedLabel = save.label
        tap(save)

        // Back on Home, the menu now shows the stored rating instead of "Rate Album…".
        let cardAgain = try waitForAlbumCard()
        attach(name: "05-after-save")
        cardAgain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.3)
        let rated = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rating: '")).firstMatch
        XCTAssertTrue(rated.waitForExistence(timeout: 10),
                      "context menu does not show the stored rating after saving \(savedLabel)")
        attach(name: "06-menu-shows-rating")
    }

    /// iOS offers to save the password after the login form; that sheet swallows the next press.
    private func dismissPasswordPrompt() {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            notNow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// The album card on Home: the first button tall enough to be artwork rather than a row.
    private func waitForAlbumCard() throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            for button in app.buttons.allElementsBoundByIndex where button.exists {
                if button.frame.height > 150 && button.frame.width > 120 { return button }
            }
            _ = app.staticTexts["Recently Added"].waitForExistence(timeout: 1)
        }
        throw XCTSkip("No album card on Home — the library has no recently added albums")
    }

    /// Taps once the element is hittable; a list still settling reports the button but refuses taps.
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        _ = waitForHittable(element)
        // Tap the middle of the frame: SwiftUI list rows here report as not hittable even while
        // they take real taps, so hit-testing would fail the run for no reason.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            _ = element.waitForExistence(timeout: 0.5)
        }
        return false
    }

    private func attach(name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
