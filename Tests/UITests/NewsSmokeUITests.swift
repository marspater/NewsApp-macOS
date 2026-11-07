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

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["NEWS_LIBRARY_NAME"] = Self.libraryName
        app.launchEnvironment["NEWS_FIXTURE_FEED"] = try Self.fixtureFeed()
        // Argument-domain defaults: they win over the development container's stored settings without changing them.
        app.launchArguments += ["-first_launch_completed", "YES", "-notifications_enabled", "NO"]
        app.launch()

        // The app under test must be the development build, never the release app (`com.marspater.news`).
        let info = Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("News.app"))
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
    func searchHeadline() -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "No search field in the toolbar")
        field.click()
        field.typeText("Lighthouse Restoration\n")
        let result = app.staticTexts[Self.headline].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 60), "The fixture headline was not found")
        return result
    }

    func openHeadline() {
        searchHeadline().click()
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
        XCTAssertTrue(app.staticTexts[Self.headline].firstMatch.waitForExistence(timeout: 10), "Not under Saved")
    }

    func test06OpenAndCloseSettings() {
        openSettings()
        settingsWindow.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(settingsWindow.waitForExistence(timeout: 2), "Settings did not close")
        XCTAssertTrue(sidebarRow("Today").waitForExistence(timeout: 10), "The main window did not return")
    }
}
