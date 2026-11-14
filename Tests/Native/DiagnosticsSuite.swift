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

import AppIntents
import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import NaturalLanguage
import Network
import PDFKit
import SQLite3
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Native port of the `DiagnosticsTests` atom (#1070): the same fourteen tests, in the runner's order, with each
/// `assertEqual`/`assertTrue` turned into the matching `expect` helper of NativeExpectations.swift and the defaults
/// force unwrap into `#require`, so a failure is recorded and later tests still run. The seeded library comes from
/// `NewsTests.diagnosticsLibrary()`, which the bundle compiles. The runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.diagnostics, .integration)) struct DiagnosticsSuite {
        @Test func signpostHelperExecution() async { await Self.testSignpostHelperExecution() }
        @Test @MainActor func diagnosticsExport() async throws { try await Self.testDiagnosticsExport() }
        @Test @MainActor func logWindowModel() async { await Self.testLogWindowModel() }
        @Test func diagnosticsLibrary() async throws { try await Self.testDiagnosticsLibrary() }
        @Test func diagnosticsFeeds() async { await Self.testDiagnosticsFeeds() }
        @Test func diagnosticsClustering() async throws { try await Self.testDiagnosticsClustering() }
        @Test func diagnosticsIntelligence() async throws { try await Self.testDiagnosticsIntelligence() }
        @Test func diagnosticsNotifications() async throws { try await Self.testDiagnosticsNotifications() }
        @Test func diagnosticsImages() async throws { try await Self.testDiagnosticsImages() }
        @Test func diagnosticsNetwork() async { await Self.testDiagnosticsNetwork() }
        @Test func diagnosticsProcess() async { await Self.testDiagnosticsProcess() }
        @Test func diagnosticsLogFiles() async { await Self.testDiagnosticsLogFiles() }
        @Test func diagnosticsSpotlightAndCaches() async { await Self.testDiagnosticsSpotlightAndCaches() }
        @Test func diagnosticsSections() async throws { try await Self.testDiagnosticsSections() }
    }
}

extension NativeSuites.DiagnosticsSuite {
    static func testSignpostHelperExecution() async {
        print("  - Testing OSSignposter Measure Execution & Error Propagation (Sync & Async)...")

        // 1. Synchronous helper executes work and returns result
        let result = NewsSignposts.measure(
            signposter: NewsSignposts.database, name: "TestMeasure", metadata: "test=true"
        ) {
            return 42
        }
        expectEqual(result, 42, "measure should return work value")

        // 2. Synchronous helper propagates thrown errors
        struct TestError: Error, Equatable {}
        var caughtError = false
        do {
            try NewsSignposts.measure(signposter: NewsSignposts.feeds, name: "TestError") {
                throw TestError()
            }
        } catch is TestError {
            caughtError = true
        } catch {
            expectTrue(false, "measure must preserve the original error type")
        }
        expectTrue(caughtError, "measure should propagate thrown error")

        // 3. Asynchronous helper executes async work and returns result
        let asyncResult = try? await NewsSignposts.measure(
            signposter: NewsSignposts.database, name: "TestAsyncMeasure", metadata: "async=true"
        ) {
            try await Task.sleep(nanoseconds: 1_000_000)
            return 84
        }
        expectEqual(asyncResult, 84, "async measure should return async work value")

        // 4. Asynchronous helper propagates thrown errors
        var caughtAsyncError = false
        do {
            try await NewsSignposts.measure(signposter: NewsSignposts.feeds, name: "TestAsyncError") {
                try await Task.sleep(nanoseconds: 1_000_000)
                throw TestError()
            }
        } catch is TestError {
            caughtAsyncError = true
        } catch {
            expectTrue(false, "async measure must preserve the original error type")
        }
        expectTrue(caughtAsyncError, "async measure should propagate thrown error")
    }

    @MainActor
    static func testDiagnosticsExport() async throws {
        print("  - Testing the diagnostics export and its redaction (#564)...")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let title = "Minister resigns over leaked budget memo"
        let log = [
            DiagnosticsExport.LogLine(
                date: now, category: "Feeds", level: "Error",
                message: "Fetch failed for https://reader:pw@news.example.com/world/2026/leaked-memo?id=7 after 3 tries"
            ),
            DiagnosticsExport.LogLine(
                date: now, category: "Database", level: "Notice",
                message: "Integrity check at /Users/mars/Library/Containers/com.marspater.news/Data/news.sqlite: ok"),
            DiagnosticsExport.LogLine(
                date: now, category: "Feeds", level: "Info", message: "Stored \(title) from feed:https://x.example/a"),
        ]
        let suite = testDefaultsSuite("diagnostics-export")
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        let failing = FeedHealth(FeedFetchState(failures: 2), now: now)
        let summary = DiagnosticsExport.summary(
            settings: settings, feedHealth: ["https://feeds.example.org/private/world.xml": failing], schema: 26,
            now: now)
        let files = DiagnosticsExport.files(summary: summary, log: log, titles: [title, "Short"])
        let text = files.values.joined()
        for hidden in ["/world/", "leaked-memo", "id=7", "reader:pw", "/private/world.xml", "/Users/mars", title] {
            expectTrue(!text.contains(hidden), "The export leaves out \(hidden)")
        }
        let tricky = DiagnosticsExport.redact(
            "a https://news.example.com/private'token b https://reader@mail@news.example.com:8443/p c", titles: [])
        expectEqual(tricky, "a news.example.com b news.example.com c", "Quotes and repeated @ never keep URL text")
        let logText = files["log.txt"] ?? ""
        expectTrue(logText.contains("Fetch failed for news.example.com after 3 tries"), "URLs keep their host")
        expectTrue(logText.contains("at ~/Library/Containers/com.marspater.news/Data/news.sqlite"), "Home becomes ~")
        expectTrue(logText.contains("Stored <story> from feed:x.example"), "Story titles are replaced")
        expectTrue(logText.hasPrefix("2026-09-21T14:13:20Z Error Feeds: "), "Lines carry date, level and category")
        let summaryText = files["summary.txt"] ?? ""
        expectTrue(summaryText.contains("Library schema version: 26"), "The summary names the schema version")
        expectTrue(summaryText.contains("Feeds: 2, starred: 0"), "The summary counts subscriptions")
        expectTrue(
            summaryText.contains("feeds.example.org: Not responding (2 failed attempts)"), "Feed health by host")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("News Diagnostics.zip")
        try DiagnosticsExport.archive(files, to: zip)
        try DiagnosticsExport.archive(files, to: zip)  // An existing file is replaced.
        expectTrue(try Data(contentsOf: zip).starts(with: [0x50, 0x4B, 0x03, 0x04]), "The export is a zip archive")
        let listing = Process()
        let output = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z1", zip.path]
        listing.standardOutput = output
        try listing.run()
        listing.waitUntilExit()
        let names = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        expectTrue(
            names.contains("News Diagnostics/summary.txt") && names.contains("News Diagnostics/log.txt"),
            "The zip holds the summary and the log: \(names)")

        // This process's own entries are readable from the unified log, as the app's are; private values stay redacted.
        let marker = "diagnostics-check-\(UUID().uuidString)"
        let secret = "https://feeds.example/private?token=\(UUID().uuidString)"
        NewsSignposts.launchLog.notice("\(marker, privacy: .public) \(secret)")
        // The unified log may store the entry a moment later; poll briefly instead of reading once.
        let deadline = ContinuousClock.now + .seconds(5)
        var found = false
        while !found && ContinuousClock.now < deadline {
            let own = try DiagnosticsExport.currentLaunchLog()
            found = own.contains { $0.message == "\(marker) <private>" && $0.category == "Launch" }
            if !found { try await Task.sleep(for: .milliseconds(100)) }
        }
        expectTrue(found, "The export reads this launch's log")
    }

    @MainActor
    static func testLogWindowModel() async {
        print("  - Testing the development Log window's filters and gate (#1005)...")
        expectTrue(LogWindowModel.isAvailable(bundleIdentifier: "com.marspater.news.dev"), "make run shows the Log")
        expectTrue(!LogWindowModel.isAvailable(bundleIdentifier: "com.marspater.news"), "A release build has no Log")
        expectTrue(!LogWindowModel.isAvailable(bundleIdentifier: nil), "No bundle id, no Log")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func line(_ offset: TimeInterval, _ category: String, _ level: String, _ message: String)
            -> DiagnosticsExport.LogLine
        {
            DiagnosticsExport.LogLine(
                date: start.addingTimeInterval(offset), category: category, level: level, message: message)
        }
        let model = LogWindowModel()
        model.follows = false
        model.clear()
        expectTrue(model.follows, "Clear follows new lines again: an empty view has nothing to scroll back from")
        model.append([
            line(0, "Feeds", "Info", "Fetched 12 items"), line(1, "Database", "Error", "Integrity check failed"),
            line(2, "Feeds", "Error", "Fetch failed for news.example.com"),
        ])
        // A reread from the last line's time returns it again; only newer lines are added.
        model.append([
            line(2, "Feeds", "Error", "Fetch failed for news.example.com"), line(3, "Launch", "Notice", "Ready"),
        ])
        expectEqual(model.entries.count, 4, "Rereads add only newer lines")
        expectEqual(model.visible.map(\.line.message).last, "Ready", "Newest last")
        expectEqual(model.categories, ["Database", "Feeds", "Launch"], "Categories come from the entries")
        model.level = "Error"
        expectEqual(model.visible.count, 2, "Level filter")
        model.category = "Feeds"
        expectEqual(model.visible.map(\.line.message), ["Fetch failed for news.example.com"], "Level and category")
        model.level = nil
        model.search = "FETCHED"
        expectEqual(model.visible.map(\.line.message), ["Fetched 12 items"], "Search ignores case")
        model.category = nil
        model.search = "database"
        expectEqual(model.visible.count, 1, "Search matches the category too")
        expectTrue(model.visibleText.hasSuffix("Error Database: Integrity check failed"), "Copy holds visible lines")
        model.search = ""
        model.clear()
        expectTrue(model.visible.isEmpty, "Clear hides what was shown")
        model.append([line(1, "Feeds", "Info", "Old"), line(4, "Feeds", "Info", "After clear")])
        expectEqual(model.visible.map(\.line.message), ["After clear"], "Lines shown before Clear stay hidden")
    }

    static func testDiagnosticsLibrary() async throws {
        print("  - Testing the diagnostics library writer (#1006)...")
        let text = try await DiagnosticsExport.library(try await NewsTests.diagnosticsLibrary())
        expectTrue(
            text.contains("Schema version: \(DatabaseEngine.schemaVersion)"), "Library names its schema: \(text)")
        expectTrue(text.contains("Integrity check: ok"), "Library runs the integrity check")
        expectTrue(text.contains("\narticles: 2\n"), "Library counts rows per table")
        expectTrue(text.contains("Oldest story: 2026-09-21T14:13:20Z"), "Library names the oldest story's date")
        expectTrue(!text.contains("Minister"), "Library carries no story text")
    }

    static func testDiagnosticsFeeds() async {
        print("  - Testing the diagnostics feeds writer (#1006)...")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let url = "https://feeds.example.org/private/world.xml?token=1"
        var state = FeedFetchState(failures: 2)
        state.validators = FeedValidators(etag: "\"abc\"", lastModified: nil)
        state.retryAt = now.addingTimeInterval(600)
        state.itemCount = 12
        state.fullTextItems = 3
        let text = DiagnosticsExport.feeds(
            feedURLs: [url, "https://other.example/rss"], states: [url: state],
            statuses: [url: DiagnosticsExport.failureKind(.httpStatus(503))], now: now)
        expectTrue(
            text.contains("1. feeds.example.org: status httpStatus 503, last fetch never, failures 2"),
            "Feeds list status and failures by host: \(text)")
        expectTrue(text.contains("validators ETag, items 12, full text 3 of 12"), "Feeds list validators and items")
        expectTrue(text.contains("2. other.example: status idle"), "Every subscription is listed")
        expectTrue(!text.contains("/private/") && !text.contains("token"), "Feeds keep only the host")
        expectTrue(
            DiagnosticsExport.feeds(feedURLs: [url], states: nil, statuses: [:], now: now)
                .contains("1. feeds.example.org: status idle, fetch state unreadable"),
            "An unreadable library is named, not reported as empty states")
        expectEqual(
            DiagnosticsExport.failureKind(.network("https://x.example/a failed")), "network",
            "A failure kind carries no payload")
    }

    static func testDiagnosticsClustering() async throws {
        print("  - Testing the diagnostics clustering writer (#1006)...")
        var stages = EventClusteringStages(total: 2, pairModelCalls: 3)
        stages.add(EventClusteringStages(total: 1, candidateSearch: 0.5, pairModelCalls: 4))
        expectEqual(stages.total, 3, "A run's stage seconds add up over its passes (#691)")
        expectEqual(stages.candidateSearch, 0.5, "Candidate search adds up over passes")
        expectEqual(stages.pairModelCalls, 7, "Pair-model calls add up over passes")
        var report = EventClusteringReport()
        report.processed = 4
        report.deferred = 1
        let pass = FeedManager.ClusteringPass(
            report: report, seconds: 0.25, finishedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let text = try await DiagnosticsExport.clustering(
            try await NewsTests.diagnosticsLibrary(), lastPass: pass, embedderAvailable: true, pairModelAvailable: false
        )
        expectTrue(text.contains("Matcher version: \(EventMatcher.version)"), "Clustering names the matcher: \(text)")
        expectTrue(text.contains("older matcher): 1"), "Clustering counts stories pending a match")
        expectTrue(text.contains("version \(SentenceEmbedder.modelVersion), available"), "Embedder state")
        expectTrue(
            text.contains("Pair model: matcher version \(EventMatcher.version), unavailable"), "Pair model state")
        expectTrue(text.contains("0.25 s, processed 4") && text.contains("deferred 1"), "The last pass and deferrals")
    }

    static func testDiagnosticsIntelligence() async throws {
        print("  - Testing the diagnostics intelligence writer (#1006)...")
        let overviews = OverviewGenerationCoordinator.Counts(
            inFlight: 1, extractions: 2, failedExtractions: 3, cached: 4)
        let text = try await DiagnosticsExport.intelligence(
            try await NewsTests.diagnosticsLibrary(), foundationModels: "available",
            queue: ["queued": 5, "running": 1],
            overviews: overviews)
        expectTrue(text.contains("Foundation Models: available"), "Intelligence names model availability: \(text)")
        expectTrue(text.contains("Enrichment queue: queued 5, running 1"), "The queue by state")
        expectTrue(
            text.contains(#/Enrichment rows: 2, enriched \d+, with a summary \d+/#), "Stored enrichment counts: \(text)"
        )
        expectTrue(
            text.contains("in flight: 1, page fetches running 2, failed this launch 3, held in memory 4"),
            "Overview work in flight")
        let counts = await EnrichmentQueue().stateCounts()
        expectTrue(counts.isEmpty, "A new queue holds nothing")
    }

    static func testDiagnosticsNotifications() async throws {
        print("  - Testing the diagnostics notifications writer (#1006)...")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let database = try await NewsTests.diagnosticsLibrary()
        let clock = now.timeIntervalSince1970
        try await database.eventRows(
            "INSERT INTO notification_deliveries(lane, grouped, feed_url, story_count, delivered_at) VALUES (0, 0, NULL, 1, ?), (2, 1, NULL, 3, ?), (0, 0, NULL, 1, ?);",
            [.real(clock - 60), .real(clock - 120), .real(clock - 2 * 86400)])
        let log = [
            DiagnosticsExport.LogLine(
                date: now, category: "StoryBanner", level: "Notice", message: "posted <private> route=appBanner"),
            DiagnosticsExport.LogLine(
                date: now, category: "StoryBanner", level: "Notice",
                message: "posted <private> route=notificationCenter"),
            DiagnosticsExport.LogLine(
                date: now, category: "NotificationService", level: "Error",
                message: "Failed to schedule full notification '<private>': domain=UNErrorDomain code=1 Not allowed"),
        ]
        let text = try await DiagnosticsExport.notifications(
            database, settings: ["Authorization: authorized"], log: log, now: now)
        expectTrue(text.contains("Authorization: authorized"), "Notifications list the settings: \(text)")
        expectTrue(text.contains("normal: 1, 1") && text.contains("priority, grouped: 1, 3"), "The last 24 h by lane")
        expectTrue(
            text.contains("appBanner: 1") && text.contains("notificationCenter: 1")
                && text.contains("refused UNErrorDomain 1: 1"), "Routes and refusals")
    }

    static func testDiagnosticsImages() async throws {
        print("  - Testing the diagnostics images writer (#1006)...")
        let now = Date()
        let database = try await NewsTests.diagnosticsLibrary()
        let ids = try await database.eventRows("SELECT id FROM articles ORDER BY id;").compactMap { $0[0] }
        try await database.recordStoryImage(ids[0], imageURL: "https://img.example/a.jpg", at: now)
        try await database.recordStoryImage(ids[1], imageURL: nil, at: now)
        var lookup = StoryCurator.Report()
        lookup.imagesFound = 1
        lookup.imagesChecked = 2
        let text = try await DiagnosticsExport.images(database, lastLookup: lookup, now: now)
        expectTrue(
            text.contains("Lookup rows: 2, with an image 1, refused or without one 1, checked in the last 24 hours 2"),
            "Images count the lookup table: \(text)")
        expectTrue(text.contains("found 1, checked 2 of a budget of \(StoryCurator.imageBudget)"), "The last pass")
        expectTrue(
            text.contains("full size at most \(DecodedImageCache.fullCountLimit) images")
                && text.contains("card size at most \(DecodedImageCache.cardCountLimit) images"),
            "The decoded caches' limits")
    }

    static func testDiagnosticsNetwork() async {
        print("  - Testing the diagnostics network writer (#1006)...")
        let log = [
            DiagnosticsExport.LogLine(
                date: Date(), category: "NetworkBoundaryProxy", level: "Error",
                message: "Upstream connect to port 443 refused: posix ECONNREFUSED"),
            DiagnosticsExport.LogLine(
                date: Date(), category: "NetworkBoundaryProxy", level: "Error",
                message: "Upstream connect to port 443 refused: posix ECONNREFUSED"),
        ]
        let text = DiagnosticsExport.network(
            gatewayPort: 50_123, resolverCancellations: 2,
            feedStatuses: ["https://a.example/rss": "timeout", "https://b.example/rss": "timeout", "c": "idle"],
            proxy: DiagnosticsExport.proxyLines(["HTTPSEnable": 1, "__SCOPED__": ["utun3": [:], "en0": [:]]]), log: log)
        expectTrue(text.contains("listening on 127.0.0.1:50123"), "Network names the gateway: \(text)")
        expectTrue(text.contains("cancelled before they answered 2"), "Resolver cancellations")
        expectTrue(text.contains("timeout: 2"), "Feed failures by kind")
        expectTrue(text.contains("refused posix ECONNREFUSED: 2"), "Upstream outcomes from the log")
        expectTrue(text.contains("HTTPS proxy: on") && text.contains("VPN interfaces: utun3"), "Proxy and VPN state")
        expectTrue(!text.contains("en0"), "Only tunnel interfaces are listed")
    }

    static func testDiagnosticsProcess() async {
        print("  - Testing the diagnostics process writer (#1006)...")
        let snapshot = DiagnosticsExport.processSnapshot(
            displayScale: 2, reduceMotion: true, increaseContrast: false, voiceOver: false)
        expectTrue(snapshot.footprintBytes ?? 0 > 0, "The process reads its memory footprint")
        expectTrue(snapshot.launchedAt != nil, "The process reads its start time")
        let text = DiagnosticsExport.process(snapshot, now: Date())
        expectTrue(text.contains("Display scale: 2.0"), "Process names the display scale: \(text)")
        expectTrue(text.contains("Reduce Motion: on, Increase Contrast: off, VoiceOver: off"), "Accessibility")
        expectTrue(text.contains("Thermal state: ") && text.contains("Locale: "), "Energy and locale")
    }

    static func testDiagnosticsLogFiles() async {
        print("  - Testing the diagnostics log files (#1006)...")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let log = [
            DiagnosticsExport.LogLine(date: now, category: "Feeds", level: "Info", message: "one"),
            DiagnosticsExport.LogLine(date: now, category: "Database", level: "Error", message: "two"),
            DiagnosticsExport.LogLine(date: now, category: "Feeds", level: "Info", message: "three"),
        ]
        let files = DiagnosticsExport.logFiles(log)
        expectEqual(files.keys.sorted(), ["log-Database.txt", "log-Feeds.txt", "log.txt"], "One file per category")
        expectEqual(files["log-Feeds.txt"]?.components(separatedBy: "\n").count, 3, "A category file holds its lines")
        expectEqual(files["log.txt"]?.components(separatedBy: "\n").count, 4, "The combined file holds every line")
    }

    static func testDiagnosticsSpotlightAndCaches() async {
        print("  - Testing the diagnostics Spotlight and caches writer (#1006)...")
        var app = DiagnosticsExport.AppSnapshot()
        app.savedStories = 3
        app.spotlightAvailable = true
        app.urlCache = (memory: 1024, disk: 2048, memoryCapacity: 4096, diskCapacity: 8192)
        let log = [
            DiagnosticsExport.LogLine(
                date: Date(timeIntervalSince1970: 1_790_000_000), category: "CacheManager", level: "Info",
                message: "Cleared HTTP network cache.")
        ]
        let text = DiagnosticsExport.spotlightAndCaches(app, log: log)
        expectTrue(text.contains("indexing available, saved stories to index 3"), "Spotlight state: \(text)")
        expectTrue(text.contains("URL cache: memory 1 KB of 4 KB"), "URL cache use")
        expectTrue(text.contains("2026-09-21T14:13:20Z Cleared HTTP network cache."), "Clear commands run")
    }

    static func testDiagnosticsSections() async throws {
        print("  - Testing the diagnostics archive's file list (#1006)...")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let sections = await DiagnosticsExport.sectionFiles(
            try await NewsTests.diagnosticsLibrary(), app: DiagnosticsExport.AppSnapshot(), log: [], now: now)
        let files = DiagnosticsExport.files(summary: "News diagnostics\n", sections: sections, log: [], titles: [])
        let summary = files["summary.txt"] ?? ""
        for name in files.keys {
            expectTrue(summary.contains("\n\(name)\n") || summary.hasSuffix("\n\(name)\n"), "summary.txt lists \(name)")
        }
        for name in [
            "library.txt", "feeds.txt", "clustering.txt", "intelligence.txt", "notifications.txt", "images.txt",
            "network.txt", "gateway-timing.txt", "process.txt", "spotlight-and-caches.txt", "log.txt",
        ] {
            expectTrue(files[name] != nil, "The archive holds \(name)")
        }
    }
}
