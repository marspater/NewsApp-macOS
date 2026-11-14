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

import AppKit
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
            // An hour older, so this story is never the Today lead whose full-size image the launch waits for.
            .replacingOccurrences(
                of: "{{EARLIER_PUBDATE}}", with: formatter.string(from: Date(timeIntervalSinceNow: -3600)))
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
        // #1328 diagnostic: pass NEWS_DIAG_* (set as TEST_RUNNER_NEWS_DIAG_*) through to the app.
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("NEWS_DIAG_") {
            app.launchEnvironment[key] = value
        }
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
        Self.story(headline, in: app)
    }

    static func story(_ headline: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", headline)).firstMatch
    }

    func openHeadline(_ headline: String = headline) {
        let card = searchHeadline(headline)
        // #1328 diagnostic: the screen and window the reader opens in.
        print("DIAG1328 screen=\(NSScreen.main?.frame ?? .zero) visible=\(NSScreen.main?.visibleFrame ?? .zero) "
            + "window=\(app.windows.firstMatch.frame) env=\(ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("NEWS_DIAG_") })")
        card.click()
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
        // The image decoded: its loading placeholder is gone, so the walk covers the loaded state.
        let loading = app.descendants(matching: .any)["Loading story image"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, "The lead image did not finish loading")
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
    /// The native sheet toolbar adds height beyond the view's content bounds; check the actual Done button (#1265).
    func test09SettingsSheetsKeepDoneInsideWindow() {
        openSettings()
        let settings = settingsWindow
        settings.toolbars.buttons["Subscriptions"].click()

        for (openerTitle, sheetTitle) in [
            ("Publisher Health…", "Publisher Health"),
            ("Browse Catalog…", "Feed Catalog"),
        ] {
            let opener = settings.buttons[openerTitle]
            XCTAssertTrue(opener.waitForExistence(timeout: 10), "Missing \(sheetTitle) opener")
            opener.click()

            let sheet = settings.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "\(sheetTitle) did not open")
            let done = sheet.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 10), "\(sheetTitle) Done is missing")
            // A sheet taller than the pane grows the Settings window while it slides in, so the frames are read
            // once the window has settled around it; a sheet that really overflows still fails below.
            let settled = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in settings.frame.contains(done.frame) }, object: nil)
            _ = XCTWaiter.wait(for: [settled], timeout: 5)
            XCTAssertTrue(
                settings.frame.contains(done.frame),
                "\(sheetTitle) Done extends outside Settings: settings \(settings.frame), done \(done.frame)")
            XCTAssertTrue(done.isHittable, "\(sheetTitle) Done cannot be clicked")
            done.click()

            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: sheet)
            XCTAssertEqual(
                XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, "\(sheetTitle) did not dismiss")
        }
    }

    /// #1306, against the app's own binary: a story is saved and the app is quit at once with ⌘Q, the path through
    /// `applicationShouldTerminate`. The next launch still lists it under Saved Stories, so the save reached the
    /// library before the process ended.
    func test10SaveSurvivesAnImmediateQuit() throws {
        let headline = "Regional Orchestra Announces Free Summer Concert Series"
        openHeadline(headline)
        let save = app.buttons["Save Story"]
        XCTAssertTrue(save.exists, "The story is already saved; this run's library is not fresh for it")
        save.click()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "The app did not quit")

        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "The main window did not appear")
        sidebarRow("Saved Stories").click()
        XCTAssertTrue(story(headline).waitForExistence(timeout: 20), "The save made just before quitting was lost")
    }

    /// #715, the keyboard pass of the Publisher Health sheet: the table lists the subscribed feed, a row can be
    /// selected, Escape closes the sheet and so does Return, the Done button's default action.
    func test11PublisherHealthSheetByKeyboard() {
        openSettings()
        let settings = settingsWindow
        settings.toolbars.buttons["Subscriptions"].click()
        let opener = settings.buttons["Publisher Health…"]
        XCTAssertTrue(opener.waitForExistence(timeout: 10), "Missing Publisher Health opener")
        let sheet = settings.sheets.firstMatch
        let dismissed = NSPredicate(format: "exists == false")

        opener.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Publisher Health did not open")
        let row = sheet.outlines.firstMatch.outlineRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The table lists no feed")
        sheet.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dismissed, object: sheet)], timeout: 5),
            .completed, "Escape did not close Publisher Health")

        opener.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Publisher Health did not reopen")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The table lists no feed after reopening")
        // On the CI runner XCTest found the row's centre outside the sheet's visible area, scrolled sideways and still
        // refused the row as not hittable. Click near its leading edge, where a reader would.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        XCTAssertTrue(row.isSelected, "A click did not select the feed's row")
        sheet.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dismissed, object: sheet)], timeout: 5),
            .completed, "Return did not close Publisher Health")
    }

}
