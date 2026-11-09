// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import XCTest

/// Smoke flows against the Debug app (#1070). Every launch uses one library per test run (`NEWS_LIBRARY_NAME`) in the
/// development container and answers every subscription with `Tests/Fixtures/ui-smoke/feed.xml`, so no flow reaches
/// the network, the release app's container or the normal development library. Run in CI only.
///
/// XCTest runs a class's tests in name order; the numbers keep the flows in the order the plan lists them.
final class NewsSmokeUITests: XCTestCase {
    static let headline = "Harbor Council Approves Lighthouse Restoration Plan"

    /// One library per test run, shared by every launch of the run; a new run starts on an empty one.
    static let libraryName: String = {
        let env = ProcessInfo.processInfo.environment
        let run =
            env["GITHUB_RUN_ID"] ?? env["CIRCLE_WORKFLOW_ID"] ?? env["CM_BUILD_ID"]
            ?? String(Int(Date().timeIntervalSince1970))
        return "uitest-\(run.filter { $0.isLetter || $0.isNumber || $0 == "-" })"
    }()

    static func fixtureFeed() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ui-smoke/feed.xml")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "{{PUBDATE}}", with: formatter.string(from: Date()))
    }

    /// The Debug app built beside the test runner (`NewsUITests-Runner.app`).
    static let newsAppURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("News.app")

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Launched by URL: TEST_TARGET_NAME = News resolved to the package's `News` executable, not News.app.
        app = XCUIApplication(url: Self.newsAppURL)
        app.launchEnvironment["NEWS_LIBRARY_NAME"] = Self.libraryName
        app.launchEnvironment["NEWS_FIXTURE_FEED"] = try Self.fixtureFeed()
        // Argument-domain defaults: they win over the development container's stored settings without changing them.
        // One subscription, so the fixture is stored whatever the container's own subscriptions are.
        app.launchArguments += [
            "-first_launch_completed", "YES", "-notifications_enabled", "NO",
            "-saved_feed_urls", "(\"https://example.com/ui-smoke/feed.xml\")",
        ]
        app.launch()

        // The app under test must be the development build, never the release app (`com.marspater.news`).
        let info = Bundle(url: Self.newsAppURL)
        XCTAssertEqual(info?.bundleIdentifier, "com.marspater.news.dev")

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "The main window did not appear")
        try assertLibraryApplied()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// The Storage pane names the open library file; it must be this run's library, not `news.sqlite3`.
    func assertLibraryApplied() throws {
        openSettings()
        let settings = settingsWindow
        settings.toolbars.buttons["Storage"].click()
        let library = settings.staticTexts.containing(
            NSPredicate(format: "value CONTAINS %@", "\(Self.libraryName).sqlite3")
        ).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10), "The run's library \(Self.libraryName) was not applied")
        settings.typeKey("w", modifierFlags: .command)
    }

    /// SwiftUI names its Settings window with this identifier.
    var settingsWindow: XCUIElement { app.windows["com_apple_SwiftUI_Settings_window"] }

    func openSettings() {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(
            settingsWindow.toolbars.buttons["General"].waitForExistence(timeout: 10),
            "Settings did not open")
    }

    /// Searches the archive for the fixture headline and returns its first result.
    func searchHeadline(_ headline: String = headline) -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "No search field in the toolbar")
        // The toolbar field rests collapsed; ⌘F expands and focuses it, after which typing goes to the app.
        app.typeKey("f", modifierFlags: .command)
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed, "The search field did not take focus")
        app.typeText(headline + "\n")
        let result = story(headline)
        XCTAssertTrue(result.waitForExistence(timeout: 60), "The fixture headline was not found")
        return result
    }

    /// A story card: one button whose label starts with the headline, followed by source, date and state.
    func story(_ headline: String = headline) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", headline)).firstMatch
    }

    func openHeadline(_ headline: String = headline) {
        searchHeadline(headline).click()
        XCTAssertTrue(
            app.buttons["Save Story"].waitForExistence(timeout: 20)
                || app.buttons["Remove from Saved Stories"].exists,
            "The story did not open in the reader")
    }

    func sidebarRow(_ title: String) -> XCUIElement {
        app.outlines.firstMatch.staticTexts[title].firstMatch
    }

    func test01LaunchShowsMainWindow() {
        XCTAssertTrue(sidebarRow("Today").waitForExistence(timeout: 10))
    }

    func test02SwitchNavigationSections() {
        for title in ["Saved Stories", "Today"] {
            let row = sidebarRow(title)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "No sidebar row \(title)")
            row.click()
        }
    }

    func test03SearchFixtureHeadline() {
        _ = searchHeadline()
    }

    func test04OpenArticle() {
        openHeadline()
    }

    func test05SaveStoryAppearsUnderSaved() {
        openHeadline()
        let save = app.buttons["Save Story"]
        if save.exists { save.click() }
        XCTAssertTrue(app.buttons["Remove from Saved Stories"].waitForExistence(timeout: 10), "The story was not saved")
        // The search stays: Saved Stories then lists the saved stories that match it.
        sidebarRow("Saved Stories").click()
        XCTAssertTrue(story().waitForExistence(timeout: 10), "Not under Saved")
    }

    func test06OpenAndCloseSettings() {
        openSettings()
        settingsWindow.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(settingsWindow.waitForExistence(timeout: 2), "Settings did not close")
        XCTAssertTrue(sidebarRow("Today").waitForExistence(timeout: 10), "The main window did not return")
    }

    /// Reads every element's label, which makes the app resolve each accessibility label as VoiceOver would. A label
    /// set on an AppKit-backed view (spinner, selectable text) once looped until the app crashed (#466); the app
    /// dying here fails the test.
    func walkAccessibilityTree() -> [String] {
        let labels = app.windows.firstMatch.descendants(matching: .any).allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(app.state, .runningForeground, "The app stopped while its accessibility tree was read")
        return labels
    }

    /// A story whose lead image loaded and has a credit (fixture `media:credit`).
    func test07AccessibilityTreeWithImageCredit() {
        openHeadline("Coastal Survey Maps Tidal Flats From The Air")
        XCTAssertTrue(
            app.descendants(matching: .any)["Image credit: Fixture Photo Desk"].waitForExistence(timeout: 20),
            "The credit line did not appear")
        XCTAssertTrue(walkAccessibilityTree().contains("Image credit: Fixture Photo Desk"))
    }

    /// A story whose lead image never finishes loading (fixture URL containing `stall`).
    func test08AccessibilityTreeWithImageStillLoading() {
        openHeadline("Ferry Timetable Change Waits On Slow Harbour Photo")
        XCTAssertTrue(
            app.descendants(matching: .any)["Loading story image"].waitForExistence(timeout: 20),
            "The loading placeholder did not appear")
        XCTAssertTrue(walkAccessibilityTree().contains("Loading story image"))
    }
}
