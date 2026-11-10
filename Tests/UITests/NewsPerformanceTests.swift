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

/// Clock, memory and CPU metrics for launch and one search on the smoke fixture (#577). Same isolation as
/// `NewsSmokeUITests`: the development build, a run library of its own and the fixture feed instead of the network.
/// Runs only when `NEWS_PERFORMANCE_TESTS=1` reaches the runner (`TEST_RUNNER_NEWS_PERFORMANCE_TESTS=1 xcodebuild …`,
/// the scheduled `profile.yml`), so the pull request UI step skips it.
final class NewsPerformanceTests: XCTestCase {
    static let libraryName = NewsSmokeUITests.libraryName.replacingOccurrences(of: "uitest-", with: "perf-")

    var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NEWS_PERFORMANCE_TESTS"] == "1",
            "Performance metrics run on the profile schedule only")
        continueAfterFailure = false
        XCTAssertEqual(Bundle(url: NewsSmokeUITests.newsAppURL)?.bundleIdentifier, "com.marspater.news.dev")
        app = XCUIApplication(url: NewsSmokeUITests.newsAppURL)
        app.launchEnvironment["NEWS_LIBRARY_NAME"] = Self.libraryName
        app.launchEnvironment["NEWS_FIXTURE_FEED"] = try NewsSmokeUITests.fixtureFeed()
        app.launchArguments += [
            "-first_launch_completed", "YES", "-notifications_enabled", "NO",
            "-saved_feed_urls", "(\"https://example.com/ui-smoke/feed.xml\")",
        ]
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric(application: app), XCTCPUMetric(application: app)] }

    var manualStop: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        return options
    }

    func testLaunchToMainWindow() {
        measure(metrics: metrics, options: manualStop) {
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "The main window did not appear")
            stopMeasuring()
            app.terminate()
        }
    }

    func testSearchFixtureHeadline() {
        app.launch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "No search field in the toolbar")
        // The fixture must be stored before timing starts: the first search waits for the refresh.
        search(field)
        clear(field)
        measure(metrics: metrics, options: manualStop) {
            search(field)
            stopMeasuring()
            clear(field)
        }
    }

    /// The fixture's other story: the unfiltered list shows it, a finished search for the headline does not.
    static let otherHeadline = "Regional Orchestra Announces Free Summer Concert Series"

    /// ⌘F expands and focuses the collapsed toolbar field, as in `NewsSmokeUITests.searchHeadline`.
    func focus(_ field: XCUIElement) {
        app.typeKey("f", modifierFlags: .command)
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed, "The search field did not take focus")
    }

    /// Done when the headline shows and the other story is gone, so an unfiltered list never ends the measurement.
    func search(_ field: XCUIElement) {
        focus(field)
        app.typeText("Lighthouse Restoration\n")
        let filtered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: story(Self.otherHeadline))
        XCTAssertEqual(XCTWaiter.wait(for: [filtered], timeout: 60), .completed, "The search did not filter the list")
        XCTAssertTrue(
            story(NewsSmokeUITests.headline).waitForExistence(timeout: 10),
            "The fixture headline was not found")
    }

    /// A story card is one button labelled headline first (#1127), so no static text equals a headline.
    func story(_ headline: String) -> XCUIElement {
        NewsSmokeUITests.story(headline, in: app)
    }

    func clear(_ field: XCUIElement) {
        focus(field)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        // An empty field may report its placeholder as value, so check only that the query is gone.
        XCTAssertFalse(((field.value as? String) ?? "").contains("Lighthouse"), "The search field did not clear")
        app.typeKey(.escape, modifierFlags: [])
        // The next measurement starts from the unfiltered list, so its end can only come from its own search.
        XCTAssertTrue(
            story(Self.otherHeadline).waitForExistence(timeout: 30),
            "The list did not return to the unfiltered fixture")
    }
}
