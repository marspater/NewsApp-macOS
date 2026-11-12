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
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd

#if canImport(FoundationModels)
    import FoundationModels
#endif

struct NewsTests {
    static func main() async {
        do {
            try await runTests()
        } catch {
            recordFailure("TEST FAILED with unexpected error: \(error)")
        }
    }

    static func runTests(fixtureHost: String = "example.com") async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--curation-live"), CommandLine.arguments.count > index + 2
        {
            try await measureLiveCuration(
                path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--timeline-audit"), CommandLine.arguments.count > index + 2
        {
            try await TimelineAudit.run(
                path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--overviews-live"), CommandLine.arguments.count > index + 2
        {
            try await measureLiveOverviews(
                path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--related-live"), CommandLine.arguments.count > index + 2 {
            try await measureLiveRelations(
                path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--notification-priority-live"),
            CommandLine.arguments.count > index + 2
        {
            try measureLivePriority(path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--images-live"), CommandLine.arguments.count > index + 2 {
            try await measureLiveImages(
                path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--today-shadow"), CommandLine.arguments.count > index + 2 {
            try await TodayShadowEvaluation.run(
                path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-cache-audit") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing private cache path")
            }
            try StoryCorpus.auditCache(path: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-page-texts") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing private page directory")
            }
            try StoryCorpus.pageTexts(directory: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-pages") {
            guard CommandLine.arguments.indices.contains(index + 1),
                let urls = CommandLine.arguments.firstIndex(of: "--corpus-urls"),
                CommandLine.arguments.indices.contains(urls + 1)
            else { throw StoryCorpus.Failure.invalid("Supply private directory and --corpus-urls JSON") }
            try await StoryCorpus.capturePages(
                directory: CommandLine.arguments[index + 1], requestsPath: CommandLine.arguments[urls + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-capture") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing private capture directory")
            }
            try await StoryCorpus.capture(directory: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-readiness") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing private capture directory")
            }
            let review = try StoryCorpus.reviewCaptures(
                directory: CommandLine.arguments[index + 1],
                holdout: CommandLine.arguments.contains("--corpus-holdout"), readinessOnly: true)
            let data = try JSONSerialization.data(withJSONObject: review.report, options: [.sortedKeys])
            print("CAPTURE_READINESS_REPORT " + String(decoding: data, as: UTF8.self))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-review") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing private capture directory")
            }
            let review = try StoryCorpus.reviewCaptures(
                directory: CommandLine.arguments[index + 1],
                holdout: CommandLine.arguments.contains("--corpus-holdout"))
            let data = try JSONSerialization.data(withJSONObject: review.report, options: [.sortedKeys])
            print("CAPTURE_FINGERPRINT_REPORT " + String(decoding: data, as: UTF8.self))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--seed-launch-library") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing library path")
            }
            try await seedLaunchLibrary(path: CommandLine.arguments[index + 1])
            return
        }
        if CommandLine.arguments.contains("--matcher-regressions") {
            try await testMatcherRegressionCorpus()
            try await testStoryRegressionCorpus()
            return
        }
        if CommandLine.arguments.contains("--verdict-replay") {
            // NEWS_VERDICTS: a JSON array of {"pairModel", "cosine", "sharedSpecific", "gapHours", "sameAct", "same"}
            // (#629); without it, the synthetic verdicts of the unit test.
            struct Verdict: Decodable {
                let pairModel: Double, cosine: Double?, sharedSpecific: Int, gapHours: Double, sameAct: Bool, same: Bool
            }
            var rows = syntheticVerdicts(120)
            if let path = ProcessInfo.processInfo.environment["NEWS_VERDICTS"] {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                rows = try JSONDecoder().decode([Verdict].self, from: data).map {
                    PairCalibration.Row(
                        features: PairCalibration.features(
                            pairModel: $0.pairModel, cosine: $0.cosine, sharedSpecific: $0.sharedSpecific,
                            gapHours: $0.gapHours, sameAct: $0.sameAct),
                        same: $0.same)
                }
            }
            let replay = verdictReplay(rows)
            print(
                "    verdict replay (#629): \(replay.verdicts) verdicts, \(replay.bare) decided as the reader did at the"
                    + " cutoff, \(replay.calibrated) with the calibration\(replay.fitted ? "" : " (dormant)")")
            assertTrue(
                replay.fitted, "The verdict replay needs 50 verdicts with both answers; a dormant replay proves nothing"
            )
            assertTrue(replay.calibrated >= replay.bare, "The calibration decides no fewer verdicts right")
            return
        }
        if CommandLine.arguments.contains("--embedding-vectors") {
            guard let output = ProcessInfo.processInfo.environment["NEWS_EVENT_OUTPUT"] else {
                throw StoryCorpus.Failure.invalid("--embedding-vectors needs NEWS_EVENT_OUTPUT")
            }
            try await exportEmbeddingVectors(output: output)
            return
        }
        if CommandLine.arguments.contains("--compute-plan") {
            try await reportComputePlacement()
            return
        }
        if CommandLine.arguments.contains("--fragment-merge-timing") {
            try await timeFragmentMerge()
            return
        }
        if CommandLine.arguments.contains("--review-pairs") {
            let environment = ProcessInfo.processInfo.environment
            guard let snapshot = environment["NEWS_SNAPSHOT_DB"], let output = environment["NEWS_EVENT_OUTPUT"] else {
                throw StoryCorpus.Failure.invalid("--review-pairs needs NEWS_SNAPSHOT_DB and NEWS_EVENT_OUTPUT")
            }
            if CommandLine.arguments.contains("--holdout-candidates") {
                let rows = try await exportHoldoutCandidates(snapshot: snapshot, outputDirectory: output)
                print("    exported \(rows) library holdout candidate pairs (#579)")
                return
            }
            let rows = try await exportPairReview(snapshot: snapshot, outputDirectory: output)
            print("    exported \(rows) pair decisions for review (#551)")
            return
        }
        if CommandLine.arguments.contains("--features") {
            // Local: the matcher signals of each headline (one per line, optional tab and lead) in NEWS_FEATURES_FILE.
            guard let path = ProcessInfo.processInfo.environment["NEWS_FEATURES_FILE"] else {
                throw StoryCorpus.Failure.invalid("--features needs NEWS_FEATURES_FILE")
            }
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                let value = EventFeatures(title: parts[0], description: parts.count > 1 ? parts[1] : "", date: Date())
                print(parts[0])
                print(
                    "    people \(value.people.sorted()) orgs \(value.organizations.sorted()) places \(value.places.sorted())"
                        + " names \(value.names.sorted()) numbers \(value.titleNumbers.sorted()) act \(value.actClass)")
                print("    keywords \(value.keywords.sorted())")
                print(
                    "    days \(value.calendarDays.sorted()) series \(value.series ?? "none") \(value.seriesTerms.sorted())"
                        + " editions \(value.editions.sorted())")
            }
            return
        }
        if CommandLine.arguments.contains("--duplicate-replay") {
            // Local (#583): every same-publisher, same-headline pair of the last seven days of a library copy, re-ingested
            // into a fresh store as two feed items; prints how many pairs become one story and how many stay two.
            guard let snapshotPath = ProcessInfo.processInfo.environment["NEWS_SNAPSHOT_DB"] else {
                throw StoryCorpus.Failure.invalid("--duplicate-replay needs NEWS_SNAPSHOT_DB")
            }
            // Resolved first, so a link outside the container cannot point the replay at the live library.
            let snapshot = URL(fileURLWithPath: snapshotPath).resolvingSymlinksInPath().path
            guard !StoryCorpus.isLiveLibrary(snapshot) else {
                throw StoryCorpus.Failure.invalid("Replay a copy of the library, never the live file")
            }
            let source = DatabaseEngine(path: snapshot)
            try await source.open()
            // Every article of the last seven days; the pairs are formed with the resolver's own folded key, so
            // punctuation and diacritics fold as in production and both sides of a pair lie inside the window.
            let articles = try await source.eventRows(
                """
                SELECT title, source, guid, canonical_url, published_at, id FROM articles
                WHERE published_at > (SELECT max(published_at) FROM articles) - 7 * 86400
                ORDER BY published_at, id;
                """)
            await source.close()
            var byKey: [String: [[String?]]] = [:]
            for row in articles {
                guard let title = row[0], let publisher = row[1],
                    let key = ArticleIdentity.publisherTitleKey(title: title, source: publisher)
                else { continue }
                byKey[key, default: []].append(row)
            }
            var pairs = 0
            var merged = 0
            var apart = 0
            for group in byKey.values.sorted(by: { ($0.first?[5] ?? "") < ($1.first?[5] ?? "") })
            where group.count >= 2 {
                for i in group.indices {
                    for j in group.indices where j > i {
                        let (x, y) = (group[i], group[j])
                        guard let title = x[0], let publisher = x[1], let first = x[4].flatMap(Double.init),
                            let second = y[4].flatMap(Double.init)
                        else { continue }
                        pairs += 1
                        let fresh = DatabaseEngine(path: ":memory:")
                        try await fresh.open()
                        let a = FeedArticle(
                            title: title, link: x[3] ?? "", guid: x[2], description: "",
                            pubDate: Date(timeIntervalSince1970: first), source: publisher)
                        let b = FeedArticle(
                            title: y[0] ?? title, link: y[3] ?? "", guid: y[2], description: "",
                            pubDate: Date(timeIntervalSince1970: second), source: publisher)
                        try await fresh.upsertArticles([a])
                        try await fresh.upsertArticles([b])
                        let one =
                            try await fresh.resolvedArticleID(for: a) == (try await fresh.resolvedArticleID(for: b))
                        await fresh.close()
                        if one { merged += 1 } else { apart += 1 }
                        print(
                            String(
                                format: "      %@ %.1fh %@: %@", one ? "one story " : "two stories",
                                abs(second - first) / 3600, publisher, title))
                    }
                }
            }
            print("    duplicate replay: \(pairs) same-publisher pairs, \(merged) become one story, \(apart) stay two")
            return
        }
        if CommandLine.arguments.contains("--library-holdout") {
            let environment = ProcessInfo.processInfo.environment
            guard let snapshot = environment["NEWS_SNAPSHOT_DB"], let holdout = environment["NEWS_LIBRARY_HOLDOUT"]
            else {
                throw StoryCorpus.Failure.invalid("--library-holdout needs NEWS_SNAPSHOT_DB and NEWS_LIBRARY_HOLDOUT")
            }
            try await evaluateLibraryHoldout(snapshot: snapshot, holdout: holdout)
            return
        }
        if CommandLine.arguments.contains("--pair-signals") {
            let environment = ProcessInfo.processInfo.environment
            guard let snapshot = environment["NEWS_SNAPSHOT_DB"], let pairs = environment["NEWS_LIBRARY_HOLDOUT"],
                let output = environment["NEWS_EVENT_OUTPUT"]
            else {
                throw StoryCorpus.Failure.invalid(
                    "--pair-signals needs NEWS_SNAPSHOT_DB, NEWS_LIBRARY_HOLDOUT and NEWS_EVENT_OUTPUT")
            }
            try await exportPairSignals(snapshot: snapshot, pairs: pairs, output: output)
            return
        }
        if CommandLine.arguments.contains("--model-outcome-check") {
            try await checkOnDeviceModelOutcomes()
            return
        }
        if CommandLine.arguments.contains("--active-work-cancellation") {
            try await testActiveWorkCancellation()
            return
        }
        let corpusMode =
            CommandLine.arguments.contains("--corpus-fingerprints") || CommandLine.arguments.contains("--corpus-events")
        try await StoryCorpus.run(evaluate: corpusMode)
        if corpusMode { return }
        var fixtureURL = URLComponents()
        fixtureURL.scheme = "https"
        fixtureURL.host = fixtureHost
        let fixtureRoot = fixtureURL.url!
        if CommandLine.arguments.contains("--fts-refresh-regression") {
            try await testUnchangedFTSRefresh()
            try await testFTSRowIDMigration()
            try await testDatabaseHealthAndDerivedRetention()
            try await testRealLibraryMigrationFixture()
            try await testLibraryBackupAndFutureSchemaGuard()
            try await testLibraryBackupRestore()
            try await testSQLiteFailuresAreNotEmptyResults()
            return
        }
        if CommandLine.arguments.contains("--export-pairs") {
            let environment = ProcessInfo.processInfo.environment
            guard let snapshots = environment["NEWS_SNAPSHOT_DB"], let output = environment["NEWS_EVENT_OUTPUT"],
                let corpusPath = environment["NEWS_EVENT_CORPUS"]
            else {
                throw StoryCorpus.Failure.invalid(
                    "--export-pairs needs NEWS_SNAPSHOT_DB, NEWS_EVENT_OUTPUT and NEWS_EVENT_CORPUS")
            }
            try await exportTrainingPairs(
                snapshots: snapshots, output: output, corpusPath: corpusPath,
                holdoutPath: environment["NEWS_LIBRARY_HOLDOUT"],
                verdictsOnly: CommandLine.arguments.contains("--verdicts-only"))
            return
        }
        if CommandLine.arguments.contains("--export-categories") {
            try await exportCategorySample()
            return
        }
        if CommandLine.arguments.contains("--event-corpus") {
            guard let path = ProcessInfo.processInfo.environment["NEWS_EVENT_CORPUS"] else {
                print("❌ Set NEWS_EVENT_CORPUS to a labeled event corpus JSON file")
                exit(1)
            }
            print("🏃 Evaluating event clustering on \(path)...")
            try await evaluateEventCorpus(
                path: path, selectedSplit: CommandLine.arguments.contains("--corpus-holdout") ? "holdout" : "tune",
                language: ProcessInfo.processInfo.environment["NEWS_EVENT_LANGUAGE"],
                outputDirectory: ProcessInfo.processInfo.environment["NEWS_EVENT_OUTPUT"])
            return
        }
        if CommandLine.arguments.contains("--performance-baseline") {
            try await runPerformanceBaseline()
            return
        }
        if CommandLine.arguments.contains("--search-memory") {
            try await runSearchMemory()
            return
        }
        if CommandLine.arguments.contains("--transport-cancellation") {
            try await testTransportCancellation()
            return
        }
        if CommandLine.arguments.contains("--publisher-cancellation") {
            try await testPublisherCancellation()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--debug-extract") {
            for path in CommandLine.arguments[(index + 1)...] {
                let html = ContentExtractionPipeline.shared.decodeHTML(
                    data: try Data(contentsOf: URL(fileURLWithPath: path)))
                let outcome = ContentExtractionPipeline.shared.extractFromHTML(html, baseUrl: "https://example.com/a")
                if case .success(let content, _, let doc) = outcome {
                    print(
                        "DBG", path.split(separator: "/").last!, "OK words",
                        content.split(whereSeparator: \.isWhitespace).count,
                        "complete", doc?.isComplete.map(String.init) ?? "nil")
                    // NEWS_DEBUG_BLOCKS=1 prints every block: kind, then its text or image URL.
                    if ProcessInfo.processInfo.environment["NEWS_DEBUG_BLOCKS"] != nil {
                        for block in doc?.blocks ?? [] {
                            let image = block.kind == .figure ? (block.imageURL ?? "") + " | " : ""
                            print("  [\(block.kind)] \(image)\(block.text)")
                        }
                    }
                } else {
                    print("DBG", path.split(separator: "/").last!, outcome)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--catalog-reader-access") {
            await testCatalogReaderAccess()
            return
        }
        if CommandLine.arguments.contains("--reader-live-pages") {
            await testLiveReader(pagesOnly: true)
            print("✅ Live reader pages passed")
            return
        }
        if CommandLine.arguments.contains("--story-regressions") {
            try await testReaderPhaseC(fixtureRoot: fixtureRoot)
            testReaderPassageMatcher()
            try await testReaderFigures(fixtureRoot: fixtureRoot)
            testReaderExtractionFidelity(fixtureRoot: fixtureRoot)
            try await testCanonicalArticleIngestion(fixtureRoot: fixtureRoot)
            try await testPersistentArticleAliases(fixtureRoot: fixtureRoot)
            try await testBatchStateAliasResolution()
            try await testFeedScopedGUIDs(fixtureRoot: fixtureRoot)
            try await testValidatedDocumentIdentity(fixtureRoot: fixtureRoot)
            try await testIdentityBaselineScenarios(fixtureRoot: fixtureRoot)
            try await testPublisherTextFingerprints()
            try await testOverviewDocumentModelBoundToInputsAndVersions(fixtureHost: fixtureHost)
            try await testOverviewVersionFollowsEventNotStorySum()
            try await testOverviewPassageSelectionAndTokenBudget(fixtureHost: fixtureHost)
            try await testPromptInjectionDefenses(fixtureHost: fixtureHost)
            try await testPassageAnchoredFactExtraction()
            try await testOverviewCompositionFromVerifiedFacts(fixtureHost: fixtureHost)
            try testHighlightsSkipTitleBlock()
            try testHighlightsSkipFeedBoilerplateAndHeadings(fixtureHost: fixtureHost)
            try await testCutDescriptionTails(fixtureHost: fixtureHost)
            try await testPlainTextGeneration(fixtureHost: fixtureHost)
            try await testOverviewPublisherEvidence(fixtureHost: fixtureHost)
            try await testOverviewQualityAuditAndReleaseGate(fixtureHost: fixtureHost)
            try await testOnDemandOverviewGenerationAndCaching(fixtureHost: fixtureHost)
            try await testOverviewGenerationCancellationAndSupersession(fixtureHost: fixtureHost)
            try await testDeterministicClaimVerification(fixtureHost: fixtureHost)
            testOverviewVerifierControls()
            try await testEventOverviewReaderMode(fixtureHost: fixtureHost)
            try await testOverviewResolutionWhenOpeningMemberArticle(fixtureHost: fixtureHost)
            try await testOverviewTimeline(fixtureHost: fixtureHost)
            try testOverviewTimelineDateProvenance(fixtureHost: fixtureHost)
            try testOverviewTimelineAnchors(fixtureHost: fixtureHost)
            try testOverviewTimelineRanges(fixtureHost: fixtureHost)
            try await testAttributedPerspectivesOfParticipantsAndPublishers(fixtureHost: fixtureHost)
            try await testThematicAngleFromExistingFacts(fixtureHost: fixtureHost)
            try await testCoverageSentimentEvaluation(fixtureHost: fixtureHost)
            try await testHistoricalReconciliation(fixtureRoot: fixtureRoot)
            try await testEventDataModel(fixtureRoot: fixtureRoot)
            try await testEventCandidateGeneration(fixtureRoot: fixtureRoot)
            try await testRelatedStoryEvents(fixtureRoot: fixtureRoot)
            try await testEventMatcherRules()
            testActClassTable()
            try await testEventClustering(fixtureRoot: fixtureRoot)
            try await testArticleSignalsRoundTrip()
            try await testPairAssessmentsRecorded()
            try await testReaderVerdictsExportAndGate()
            try await testStoryLayer()
            try await testStoryPassOrderIndependent()
            try await testEventInclusions()
            try await testPairModelGreyZone()
            try await testEventEmbeddingIntegration()
            try await testEventFragmentMergingAndJudge(fixtureRoot: fixtureRoot)
            try await testStoryVisibility(fixtureRoot: fixtureRoot)
            try await testStoryImages(fixtureRoot: fixtureRoot)
            try await testEventReadingState(fixtureRoot: fixtureRoot)
            testEventFeedSummaryUnit()
            await testEventFeedGroupingAndStability()
            testEventFeedGroupingOptimization()
            try await testFiniteBriefing()
            try await testPublisherContentProvenance()
            try await testRefreshClustersEvents(fixtureRoot: fixtureRoot)
            try await testStoryCheckForUpdates(fixtureRoot: fixtureRoot)
            try await testEventCorpusHarness(fixtureRoot: fixtureRoot)
            try await testMatcherRegressionCorpus()
            try await testStoryRegressionCorpus()
            try await testPairCalibration()
            try testCapturedFingerprintReview()
            try await testAuditPersistenceAndRoutingRegressions(fixtureRoot: fixtureRoot)
            try await testUndatedArticleOrdering()
            try await testFutureDatedItems()
            await testDatabaseEnginePersistence()
            await testFTS5SearchAndOperators()
            try await testUnchangedFTSRefresh()
            try await testSearchSpellingSuggestion()
            try await testRefreshStateKeepsChangesMadeWhileLoading()
            try await testCountsStayExactAcrossToggleAndBulkChanges()
            try await testUnreadCountAndSavedStateCoverTheLibrary()
            try await testFTSRowIDMigration()
            try await testDatabaseHealthAndDerivedRetention()
            try await testRealLibraryMigrationFixture()
            await testReaderParsingRegressions()
            await testStructuredReaderAndTags()
            await testReaderStoreUpdates()
            await testArticleRetentionPolicy()
            try await testGranularCacheClearingAndRetention()
            await testMultiPublisherExtractionFixtures()
            await testReaderFurnitureRemoval()
            print("✅ Story regressions passed")
            return
        }
        print("🏃 Running the StoryCorpus check...")

        if ProcessInfo.processInfo.environment["NEWS_LIVE_READER_CHECK"] == "1" {
            await testLiveReader()
        }
        if ProcessInfo.processInfo.environment["NEWS_LIVE_CATALOG_CHECK"] == "1" {
            await testLiveCatalog()
        }
        if let snapshot = ProcessInfo.processInfo.environment["NEWS_SNAPSHOT_DB"] {
            let database = DatabaseEngine(path: snapshot)
            try await database.open()
            let articles = try await database.fetchArticles(limit: 500)
            assertFalse(articles.isEmpty, "Migrated snapshot must display stored articles")
            let counts = try await database.counts()
            print("  - Migrated isolated snapshot: \(counts.total) stories, \(counts.saved) saved")
            await database.close()
        }
        print("✅ SUCCESS: All tests passed!")
    }

    /// Writes a new 10,000-story library for `script/launch_baseline.sh`: unread, recent and already clustered,
    /// so launch measures loading a steady-state archive rather than a first-run clustering backlog.
    static func seedLaunchLibrary(path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw StoryCorpus.Failure.invalid("Refusing to overwrite \(path)")
        }
        let db = DatabaseEngine(path: path)
        try await db.open()
        let now = Date()
        let prose = (1...20).map {
            "Researchers in London compared observation \($0) with the published evidence and documented the results."
        }.joined(separator: " ")
        let archive = (0..<10_000).map { index in
            FeedArticle(
                title: "Research report \(index)", link: "https://launch.invalid/article/\(index)",
                guid: "launch-\(index)",
                description: "Research evidence", pubDate: now.addingTimeInterval(-Double(index) * 15),
                source: "Publisher \(index % 20)", fullContent: prose,
                readerDocument: ReaderDocument(blocks: [ReaderBlock(kind: .paragraph, text: prose)]))
        }
        try await db.upsertArticles(archive, feedUrl: "https://launch.invalid/feed.xml")
        try await db.markEventMatchProcessed(archive.map(\.id), matcherVersion: EventMatcher.version, at: now)
        await db.close()
        print("Seeded \(archive.count) stories at \(path)")
    }

    /// Writes the sentence embedding of every authored-corpus article to `embedding-vectors.json` (#540), so a change
    /// to `SentenceEmbedder` can be compared vector by vector with the implementation before it.
    static func exportEmbeddingVectors(output: String) async throws {
        struct Item: Decodable { let id: String, title: String, description: String? }
        struct Fixture: Decodable { let articles: [Item] }
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/story-corpus/matcher-regressions-v1.json")))
        let texts = fixture.articles.map {
            EventFeatures.matchingText(title: $0.title, description: $0.description ?? "")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let vectors = await SentenceEmbedder.shared.embedBatch(texts)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        var byID: [String: [Float]] = [:]
        for (item, vector) in zip(fixture.articles, vectors) {
            guard let vector else { throw StoryCorpus.Failure.invalid("No embedding for \(item.id); nothing written") }
            byID[item.id] = vector
        }
        let file = try StoryCorpus.privateDirectory(output).appendingPathComponent("embedding-vectors.json")
        let data = try JSONSerialization.data(
            withJSONObject: byID.mapValues { $0.map(Double.init) }, options: [.sortedKeys])
        // An existing dump is the reference of a comparison, so it is never overwritten; use another directory.
        try StoryCorpus.writePrivate(data, to: file, replacing: false)
        print(
            String(
                format: "    embedded %d of %d texts in %.0f ms -> %@", byID.count, texts.count, elapsed * 1000,
                file.path))
    }

    /// Opt-in controlled service timings; not a rendered UI or network benchmark.
    @MainActor
    static func runPerformanceBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = testDefaultsSuite("test.performance")
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            removeTestDefaults(suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        settings.feedURLs = (0..<5).map { "https://baseline.example/feed-\($0)" }
        let db = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let prose = (1...20).map {
            "Researchers in London compared observation \($0) with the published evidence and documented the results."
        }.joined(separator: " ")
        // Past wall-clock dates: an upsert stores a future feed date as unknown (#981), which would empty the candidate
        // window below and leave the refreshed stories undated, behind the archive (#1043).
        let clusterNow = Date()
        func article(_ index: Int) -> FeedArticle {
            let image = "https://baseline.example/media/publisher-\(index % 20).jpg"
            let document = ReaderDocument(
                blocks: [ReaderBlock(kind: .paragraph, text: prose)],
                images: [ReaderImageCandidate(url: image, origin: .body, width: 1200, height: 800)], leadImageURL: image
            )
            return FeedArticle(
                title: "Research report \(index)", link: "https://baseline.example/article/\(index)",
                guid: "baseline-\(index)", description: "Research evidence",
                pubDate: clusterNow.addingTimeInterval(Double(index) - 10_250),
                source: "Publisher \(index % 20)", imageUrl: image, fullContent: prose, readerDocument: document)
        }
        let archive = (0..<10_000).map(article)
        try await db.upsertArticles(archive, now: clusterNow)
        // Steady-state archive, rather than a first-launch clustering backlog competing with refresh.
        try await db.markEventMatchProcessed(archive.map(\.id), matcherVersion: EventMatcher.version, at: clusterNow)
        var measurements = [String: [Double]]()
        func record(_ name: String, from start: Double) {
            measurements[name, default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        // Diagnostics reports (#1006) on the 10,000-story library: every state writer plus the log and the redaction.
        // The app snapshot and the zip that Help › Export Diagnostics adds are not part of this time.
        let exportStart = ProcessInfo.processInfo.systemUptime
        let exportLog = try DiagnosticsExport.logLines(since: .distantPast)
        let exportSections = await DiagnosticsExport.sectionFiles(
            db, app: DiagnosticsExport.AppSnapshot(feedURLs: settings.feedURLs), log: exportLog, now: clusterNow)
        let exportFiles = DiagnosticsExport.files(
            summary: "News diagnostics\n", sections: exportSections, log: exportLog, titles: archive.map(\.title))
        record("diagnosticsExport", from: exportStart)
        print(
            "Diagnostics reports (no snapshot or zip): \(exportFiles.count) files in \(measurements["diagnosticsExport"]?.last ?? 0) ms"
        )
        let coldStart = ProcessInfo.processInfo.systemUptime
        assertTrue(await store.refreshState(), "Baseline snapshot hydrates")
        record("snapshot_first_500_ms", from: coldStart)
        assertEqual(store.articles.count, 500, "Baseline keeps the real snapshot limit")
        let batches = (0..<5).map { offset in (0..<50).map { article(10_000 + offset * 50 + $0) } }
        let freshGUIDs = Set(batches.flatMap { $0.compactMap(\.guid) })
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                zip(urls, batches).map { ($0.0, $0.1, nil, nil) }
            })
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            await manager.fetchFeedsAsync()
            record("refresh_5_mocked_feeds_ms", from: start)
            assertEqual(manager.articles.count, 500, "Refresh publishes the bounded snapshot")
            assertTrue(
                freshGUIDs.isSubset(of: Set(manager.articles.compactMap(\.guid))), "Refresh publishes the new stories")
            await manager.waitForEventClustering()
        }
        assertEqual(try await db.counts().total, 10_250, "Repeated refreshes keep one row per document")
        manager.stopBackgroundWork()

        // Paired query comparison on one database/index; alternate order to avoid warm-cache bias.
        var comparisonHandle: OpaquePointer?
        assertEqual(
            sqlite3_open_v2(
                directory.appendingPathComponent("library.sqlite3").path, &comparisonHandle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK, "Open isolated candidate comparison")
        defer { sqlite3_close(comparisonHandle) }
        let probe = archive[9_800]
        let candidateQuery = "{title description} : (\"research\" OR \"report\")"
        func legacyCandidateRows() -> [[String?]] {
            let sql = """
                SELECT a.id, a.title, coalesce(a.description, ''), m.event_id
                FROM articles_fts fts JOIN articles a ON a.id = fts.article_id
                LEFT JOIN event_members m ON m.article_id = a.id
                LEFT JOIN events e ON e.id = m.event_id
                WHERE articles_fts MATCH ? AND a.id != ?
                    AND CASE WHEN a.published_at = \(DateParser.unknownDate.timeIntervalSince1970)
                        THEN a.created_at ELSE a.published_at END BETWEEN ? AND ?
                    AND NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = a.id)
                    AND (m.event_id IS NULL OR e.updated_at >= ?)
                ORDER BY fts.rank, a.id LIMIT 80;
                """
            var statement: OpaquePointer?
            assertEqual(
                sqlite3_prepare_v2(comparisonHandle, sql, -1, &statement, nil), SQLITE_OK,
                "Prepare legacy candidate comparison")
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, candidateQuery, -1, transient)
            sqlite3_bind_text(statement, 2, probe.id, -1, transient)
            sqlite3_bind_double(statement, 3, probe.pubDate.timeIntervalSince1970 - 48 * 3600)
            sqlite3_bind_double(statement, 4, probe.pubDate.timeIntervalSince1970 + 48 * 3600)
            sqlite3_bind_double(statement, 5, clusterNow.timeIntervalSince1970 - 72 * 3600)
            var rows: [[String?]] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                rows.append((0..<4).map { sqlite3_column_text(statement, Int32($0)).map { String(cString: $0) } })
                status = sqlite3_step(statement)
            }
            assertEqual(status, SQLITE_DONE, "Legacy candidate comparison completes")
            return rows
        }
        let expectedCandidates = legacyCandidateRows()
        assertEqual(expectedCandidates.count, 80, "Paired comparison returns the full candidate cap")
        func measureLegacy() {
            let start = ProcessInfo.processInfo.systemUptime
            let rows = legacyCandidateRows()
            record("event_candidate_legacy_join_ms", from: start)
            assertEqual(rows, expectedCandidates, "Legacy candidate comparison stays deterministic")
        }
        func measureMapped() async throws {
            let start = ProcessInfo.processInfo.systemUptime
            let rows = try await db.eventCandidateRows(
                matching: candidateQuery, around: probe.pubDate,
                window: 48 * 3600, activeSince: clusterNow.addingTimeInterval(-72 * 3600), excluding: probe.id,
                limit: 80)
            record("event_candidate_rowid_join_ms", from: start)
            assertEqual(
                rows.map { [$0.id, $0.title, $0.description, $0.eventID] }, expectedCandidates,
                "Durable rowid join preserves all ordered candidate fields")
        }
        for iteration in 0..<10 {
            if iteration.isMultiple(of: 2) {
                measureLegacy()
                try await measureMapped()
            } else {
                try await measureMapped()
                measureLegacy()
            }
        }
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let rows = try await db.searchArticles(query: "Research", limit: 100)
            record("fts_first_100_ms", from: start)
            assertEqual(rows.count, 100, "FTS benchmark returns expected rows")
        }

        // Hybrid search (FTS5 BM25 + embedding cosine, RRF; #708). A query every story matches, so both arms rank the
        // whole library: the worst case of the lexical arm. Synthetic unit vectors: the first 150 stories align with the
        // query (cosine 0.9), the rest do not (0.1).
        let vectorDimension = SentenceEmbedder.vectorDimension
        let halfDimension = sqrt(Double(vectorDimension / 2))
        let benchmarkQueryVector: [Float] = (0..<vectorDimension).map { $0 % 2 == 0 ? Float(1 / halfDimension) : 0 }
        func syntheticEmbeddings(_ articles: ArraySlice<FeedArticle>) -> [String: [Float]] {
            var vectors: [String: [Float]] = [:]
            vectors.reserveCapacity(articles.count)
            for (index, article) in articles.enumerated() {
                let align = index < 150 ? 0.9 : 0.1
                let even = Float(align / halfDimension)
                let odd = Float(sqrt(max(0, 1 - align * align)) / halfDimension)
                vectors[article.id] = (0..<vectorDimension).map { $0 % 2 == 0 ? even : odd }
            }
            return vectors
        }
        // #708's acceptance: a 5,000-story seeded library, every story embedded.
        let searchLibrary = DatabaseEngine(path: directory.appendingPathComponent("search-5000.sqlite3").path)
        try await searchLibrary.open()
        try await searchLibrary.upsertArticles(Array(archive.prefix(5_000)))
        try await searchLibrary.upsertArticleEmbeddings(
            syntheticEmbeddings(archive.prefix(5_000)), modelVersion: SentenceEmbedder.modelVersion)
        // The 10,000-story archive above with 5,000 of its stories embedded: the number #953 first reported.
        try await db.upsertArticleEmbeddings(
            syntheticEmbeddings(archive.prefix(5_000)), modelVersion: SentenceEmbedder.modelVersion)
        let searchRuns = [
            (searchLibrary, "hybrid_search_5000_stories_ms", 5_000),
            (db, "hybrid_search_10000_archive_ms", 10_250),
        ]
        // Alternate the order of the two libraries so neither always runs on a warmer cache.
        for iteration in 0..<10 {
            for (library, name, total) in iteration.isMultiple(of: 2) ? searchRuns : searchRuns.reversed() {
                let start = ProcessInfo.processInfo.systemUptime
                let rows = try await library.searchArticles(
                    query: "Research", limit: 100, queryEmbedding: benchmarkQueryVector)
                record(name, from: start)
                assertEqual(rows.count, 100, "Hybrid search benchmark returns a full page (\(total) matches)")
                assertTrue(rows.allSatisfy { $0.searchSnippet != nil }, "Every lexical hit of the page has a snippet")
            }
        }
        await searchLibrary.close()
        let html =
            "<article><h2>Evidence</h2><p>\(prose)</p><figure><img src='/photo.jpg' width='1200' height='800'></figure><p>\(prose)</p></article>"
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            assertTrue(
                ContentExtractionPipeline.shared.extractFromHTML(html, baseUrl: "https://baseline.example/story")
                    .isSuccess, "Benchmark extraction succeeds")
            record("html_extraction_ms", from: start)
            let analysisStart = ProcessInfo.processInfo.systemUptime
            let analysis = try await ArticleAnalyzer.shared.analyze(
                title: "Research evidence", content: prose, allowFoundationModels: false)
            record("natural_language_analysis_ms", from: analysisStart)
            assertFalse(analysis.summary.isEmpty, "Deterministic analysis returns publisher-derived text")
        }

        // Event clustering & feed grouping (#104, #153). Unchanged archives must do no matching work.
        try await db.markEventMatchProcessed(
            batches.flatMap { $0 }.map(\.id), matcherVersion: EventMatcher.version, at: clusterNow)
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let report = try await EventClusterer.run(in: db, now: clusterNow)
            record("event_clustering_unchanged_ms", from: start)
            assertEqual(report.processed, 0, "Unchanged refresh does not recompute the archive")
        }
        // Reset the same 200 rows for each dense candidate pass: equal work, not successive backlog slices.
        let denseIDs = archive.suffix(200).map(\.id)
        var processedRows: [Int] = []
        for _ in 0..<5 {
            try await db.markEventMatchProcessed(denseIDs, matcherVersion: 0, at: clusterNow)
            let start = ProcessInfo.processInfo.systemUptime
            let report = try await EventClusterer.run(in: db, now: clusterNow, limit: 200)
            record("event_clustering_dense_200_ms", from: start)
            processedRows.append(report.processed)
            assertEqual(report.processed, 200, "Each dense pass processes exactly the reset rows")
            assertTrue(
                try await db.pendingEventMatchRows(
                    activeSince: clusterNow.addingTimeInterval(-72 * 3600),
                    matcherVersion: EventMatcher.version, limit: 1
                ).isEmpty, "Dense pass drains its bounded work")
        }
        let snapshotArticles = Array(store.articles.prefix(500))
        let snapshotIDs = snapshotArticles.map(\.id)
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let summaries = try await store.eventFeedSummaries(for: snapshotIDs)
            let entries = EventFeedGrouping.entries(for: snapshotArticles, events: summaries, mode: .events)
            record("event_feed_grouping_ms", from: start)
            assertFalse(entries.isEmpty, "Grouped feed entries are not empty")
        }

        // Overview generation & cached lookup (#104, #153)
        let eventArticles = Array(archive.prefix(3))
        let queue = EnrichmentQueue(store: store)
        let coordinator = OverviewGenerationCoordinator(store: store, queue: queue)
        for i in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let doc = await coordinator.requestOverview(
                eventID: "bench-event-\(i)",
                eventTitle: "Research report on observation",
                membershipVersion: 1,
                articles: eventArticles,
                priority: .visibleEvent
            )
            record("overview_generation_ms", from: start)
            assertTrue(doc != nil, "Benchmark overview generation succeeds")
        }
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let cached = try await store.fetchEventOverview(eventID: "bench-event-0")
            record("overview_cached_ms", from: start)
            assertTrue(cached != nil, "Cached overview lookup succeeds")
        }
        for _ in 0..<10 {
            let entered = TestCounter()
            let cancelledManager = FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { _, _ in
                    await entered.increment()
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch {}
                    return []
                })
            let refresh = Task { await cancelledManager.fetchFeedsAsync() }
            while await entered.value == 0 { await Task.yield() }
            let start = ProcessInfo.processInfo.systemUptime
            cancelledManager.stopBackgroundWork()
            await refresh.value
            record("refresh_cancel_mock_wait_ms", from: start)
        }
        // Embedding throughput (#540): a fresh embedder, model load included, over 2,000 archive texts.
        if await SentenceEmbedder.shared.isAvailable {
            let texts = archive.prefix(2_000).map {
                EventFeatures.matchingText(title: $0.title, description: $0.description)
            }
            let start = ProcessInfo.processInfo.systemUptime
            let vectors = await SentenceEmbedder().embedBatch(texts)
            record("embedding_cold_2000_ms", from: start)
            guard vectors.allSatisfy({ $0 != nil }) else { fatalError("Every archive text embeds") }
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { fatalError("Cannot obtain process memory high-water mark") }
        let report: [String: Any] = [
            "library_rows": 10_250, "publishers": 20, "snapshot_rows": 500,
            "search_library_rows": 5_000, "search_library_embeddings": 5_000, "archive_embeddings": 5_000,
            "feed_count": 5, "fresh_rows_per_feed": 50, "prose_characters": prose.count, "html_characters": html.count,
            "dense_clustering_processed_rows": processedRows,
            "candidate_comparison_rows": expectedCandidates.count,
            "sqlite_version": String(cString: sqlite3_libversion()),
            "peak_process_rss_bytes": usage.ru_maxrss, "measurements_ms": measurements,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "cpu_count": ProcessInfo.processInfo.processorCount,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "optimization": "-O (test.sh performance mode)",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("PERFORMANCE_BASELINE_JSON_BEGIN")
        print(String(decoding: data, as: UTF8.self))
        print("PERFORMANCE_BASELINE_JSON_END")
        await db.close()
    }

    /// Opt-in (#708): the process footprint over repeated searches of a 5,000-story seeded library, each through the
    /// path a list's search takes (`ArticleListView.performQueryReload`): the text embedded by the on-device model,
    /// the first page, the muted count and the masthead totals, the next page, and for every tenth a spelling
    /// suggestion. Every search has new text, as typing does, so each one embeds and runs a new query vector.
    /// Footprint is sampled after each block of searches; the check passes when the last sample is within
    /// `NEWS_SEARCH_MEMORY_LIMIT_MB` (default 6) of the first one after the warm-up. Runs on 3 November 2026 showed
    /// one-time steps of up to 3.8 MiB and no trend over 1,500 searches. Over the default 500 searches, 6 MiB fails
    /// any steady growth above about 12.3 KiB a search (6 MiB / 500), far below one retained model output
    /// (128 × 384 floats, 192 KiB); smaller or intermittent growth can stay under it.
    @MainActor
    static func runSearchMemory() async throws {
        func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { fatalError("Cannot read the process footprint") }
            return info.phys_footprint
        }
        func mebibytes(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }
        guard await SentenceEmbedder.shared.isAvailable else {
            fatalError("The search memory check needs the embedder")
        }
        let environment = ProcessInfo.processInfo.environment
        let blocks = Int(environment["NEWS_SEARCH_MEMORY_BLOCKS"] ?? "") ?? 10
        // Zero blocks would compare the warm-up sample with itself and pass without a measured search.
        guard blocks >= 1 else { fatalError("NEWS_SEARCH_MEMORY_BLOCKS must be at least 1") }
        let perBlock = 50
        let limit = Double(environment["NEWS_SEARCH_MEMORY_LIMIT_MB"] ?? "") ?? 6

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-search-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
        try await db.open()
        let topics = [
            "central bank raises interest rates", "wildfire forces evacuations", "parliament passes budget",
            "storm floods coastal towns", "court rules on election appeal", "chipmaker reports record revenue",
            "vaccine trial shows results", "football club signs striker", "satellite launch succeeds",
            "strike halts rail services",
        ]
        let prose = (1...20).map {
            "Researchers in London compared observation \($0) with the published evidence and documented the results."
        }.joined(separator: " ")
        let archive = (0..<5_000).map { index in
            FeedArticle(
                title: "\(topics[index % topics.count].capitalized) in report \(index)",
                link: "https://memory.invalid/article/\(index)", guid: "memory-\(index)",
                description: "Research evidence on \(topics[(index / 10) % topics.count])",
                pubDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                source: "Publisher \(index % 20)", fullContent: prose)
        }
        try await db.upsertArticles(archive)
        let vectors = await SentenceEmbedder.shared.embedBatch(
            archive.map { EventFeatures.matchingText(title: $0.title, description: $0.description) })
        var embeddings: [String: [Float]] = [:]
        for (article, vector) in zip(archive, vectors) { embeddings[article.id] = vector }
        guard embeddings.count == archive.count else { fatalError("Every seeded story embeds") }
        try await db.upsertArticleEmbeddings(embeddings, modelVersion: SentenceEmbedder.modelVersion)
        embeddings = [:]

        let muting = MuteRules(topics: ["wildfire"])
        var searches = 0
        var listed = 0
        var durations: [Double] = []
        func search() async throws {
            // New text every time, as typing gives: a topic, a number and a word that changes the embedding.
            let words = ["latest", "update", "analysis", "reaction", "impact"]
            let text = "\(topics[searches % topics.count]) \(words[(searches / 10) % words.count]) \(searches)"
            searches += 1
            let start = ProcessInfo.processInfo.systemUptime
            let page = try await db.searchArticles(query: text, limit: 201, muting: muting)
            let vector = try await db.searchQueryVector(for: text)
            _ = try await db.mutedArticleCount(search: text, searchVector: vector, muting: muting)
            let totals = try await db.listTotals(search: text, searchVector: vector, muting: muting)
            if let last = page.last {
                _ = try await db.searchArticles(
                    query: text, limit: 201, after: ArticleQueryCursor(last), muting: muting)
            }
            if searches.isMultiple(of: 10) {
                _ = try await db.searchSuggestion(query: "wildfyre evacuashuns \(searches)", muting: muting)
            }
            durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            listed += totals.stories
        }
        for _ in 0..<perBlock { try await search() }  // Warm-up: model, SQLite page cache, spelling vocabulary.
        // Latency and listed counts cover the measured searches only, as the footprint samples do.
        durations.removeAll()
        listed = 0
        var samples = [footprint()]
        for _ in 0..<blocks {
            for _ in 0..<perBlock { try await search() }
            samples.append(footprint())
        }
        await db.close()
        // Raw bytes are compared with the limit; only the reported value is rounded.
        let rawGrowth = (Double(samples.last!) - Double(samples.first!)) / 1_048_576
        let growth = (rawGrowth * 10).rounded() / 10
        let sorted = durations.sorted()
        let report: [String: Any] = [
            "library_rows": archive.count, "embeddings": archive.count, "warm_up_searches": perBlock,
            "measured_searches": blocks * perBlock, "searches_per_sample": perBlock,
            "footprint_mb": samples.map(mebibytes), "growth_mb": growth, "limit_mb": limit,
            "search_round_ms_median": sorted[sorted.count / 2], "search_round_ms_p95": sorted[sorted.count * 95 / 100],
            "mean_listed_stories": listed / (blocks * perBlock),
            "sqlite_version": String(cString: sqlite3_libversion()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "optimization": "-O (test.sh search memory mode)",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("SEARCH_MEMORY_JSON_BEGIN")
        print(String(decoding: data, as: UTF8.self))
        print("SEARCH_MEMORY_JSON_END")
        assertTrue(listed > 0, "Searches list stories")
        assertTrue(
            rawGrowth <= limit,
            "Footprint stays within the limit over \(blocks * perBlock) searches: grew \(growth) MiB"
                + " (limit \(limit) MiB)")
    }

    static func testLiveReader(pagesOnly: Bool = false) async {
        for link in [
            "https://www.bbc.co.uk/news/articles/c6jdvmy1287yo", "https://www.bbc.co.uk/news/articles/cm750pyz5r0eo",
        ] {
            let outcome = await ContentExtractionPipeline.shared.extractArticleDetailed(from: link)
            guard case .success(let content, _, let document) = outcome else {
                assertTrue(false, "BBC reader regression must extract publisher prose")
                continue
            }
            assertTrue(document != nil, "Live publisher retains reader structure")
            print(
                "Live page: \(link), \(content.count) prose characters, \(document?.blocks.count ?? 0) blocks, \(document?.images?.count ?? 0) image candidates"
            )
            assertFalse(content.contains("Get in touch"), "BBC contact furniture excluded")
            assertFalse(content.contains("17:45 weekdays"), "BBC listening promotion excluded")
        }

        if pagesOnly { return }
        for url in [
            "https://www.theguardian.com/world/rss", "https://feeds.arstechnica.com/arstechnica/index",
            "https://www.nasa.gov/feed/",
        ] {
            let result = await FeedFetcher.shared.fetchSingleFeed(urlString: url)
            assertTrue(result.error == nil, "Live feed fetch must succeed for \(url)")
            guard let article = result.articles?.first else {
                assertTrue(false, "Live feed must contain an article")
                continue
            }
            let outcome = await ContentExtractionPipeline.shared.extractArticleDetailed(from: article.link)
            let content = article.fullContent ?? outcome.content ?? ""
            assertFalse(
                ArticleContentRedactor.redactAndSplit(content).isEmpty,
                "Live publisher article must provide readable prose for \(url)")
            print(
                "  - Live reader: \(URL(string: url)!.host!), \(result.articles!.count) items, \(content.count) body characters; extraction success: \(outcome.isSuccess)"
            )
        }
    }

    /// Fetches every catalog feed through the app's own protected networking and parsers. Needs the network.
    static func testLiveCatalog() async {
        print("  - Live catalog check: fetching \(FeedCatalog.feeds.count) feeds...")
        let results = await FeedFetcher().fetchAllFeeds(urls: FeedCatalog.feeds.map(\.url))
        var failures: [String] = []
        for feed in FeedCatalog.feeds {
            guard let result = results.first(where: { $0.urlString == feed.url }) else {
                failures.append("\(feed.id): no result")
                continue
            }
            if let error = result.error {
                failures.append("\(feed.id): \(error.localizedDescription)")
            } else if (result.articles ?? []).isEmpty {
                failures.append("\(feed.id): no articles")
            }
        }
        for failure in failures { print("    ✗ \(failure)") }
        assertTrue(
            failures.isEmpty,
            "Every catalog feed fetches and parses (\(failures.count) of \(FeedCatalog.feeds.count) failed)")
    }

    /// Opt-in, live: opens the newest stories of every catalog feed in the app's own reader extraction. Free, open
    /// feeds only: a feed whose articles refuse the reader (HTTP 403, paywall teaser) does not belong in the catalog.
    static func testCatalogReaderAccess() async {
        let only = Set(
            (ProcessInfo.processInfo.environment["NEWS_CATALOG_FEEDS"] ?? "").split(separator: ",").map(String.init))
        let sample = Int(ProcessInfo.processInfo.environment["NEWS_CATALOG_SAMPLE"] ?? "") ?? 3
        let feeds = FeedCatalog.allFeeds.filter { only.isEmpty || only.contains($0.id) }
        print("  - Catalog reader access: \(feeds.count) feeds, up to \(sample) stories each...")
        let results = await FeedFetcher().fetchAllFeeds(urls: feeds.map(\.url))
        await withTaskGroup(of: String.self) { group in
            for feed in feeds {
                let links = (results.first { $0.urlString == feed.url }?.articles ?? [])
                    .map(\.link).filter { !$0.isEmpty }.prefix(sample)
                group.addTask {
                    guard !links.isEmpty else { return "\(feed.id)\tno stories in feed" }
                    var readable = 0
                    var words: [Int] = []
                    var failures: [String] = []
                    for link in links {
                        let outcome = await ContentExtractionPipeline.shared.extractArticleWithIdentity(from: link)
                            .outcome
                        if case .success(let content, _, _) = outcome {
                            readable += 1
                            words.append(content.split(whereSeparator: \.isWhitespace).count)
                        } else {
                            failures.append("\(outcome)".prefix(60).description)
                        }
                    }
                    let median = words.sorted().dropFirst(words.count / 2).first ?? 0
                    return
                        "\(feed.id)\t\(feed.language)\treadable \(readable)/\(links.count)\tmedian words \(median)\t\(failures.joined(separator: "; "))"
                }
            }
            var lines: [String] = []
            for await line in group { lines.append(line) }
            for line in lines.sorted() { print("    \(line)") }
        }
    }

    /// Opt-in live measurement on a SQLite backup under the temporary directory, never the installed library.
    static func measureLiveCuration(path: String, output: String) async throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(
                domain: "LiveCuration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Use a library backup and output under /private/tmp"])
        }
        let db = DatabaseEngine(path: url.path)
        try await db.open()
        let clock = Date()
        let activeSince = clock.addingTimeInterval(-EventCandidatePolicy.standard.activeEventLifetime)
        let all = try await db.fetchArticles(limit: nil)
        let active = all.filter { $0.pubDate >= activeSince }
        var ratings: [[String: String]] = []
        for pass in 1...100 {
            let before = ratings.count
            let pending = try await db.pendingImportanceRows(activeSince: activeSince, limit: 60)
            if pending.isEmpty { break }
            for row in pending {
                try Task.checkCancellation()
                guard let importance = await OnDeviceImportanceJudge.shared.rate(OnDeviceImportanceJudge.report(row))
                else {
                    continue
                }
                if try await db.recordImportance(
                    row.id, importance, at: clock, expectedTitle: row.title, expectedDescription: row.description)
                {
                    ratings.append([
                        "id": row.id, "title": row.title, "summary": row.description,
                        "importance": String(describing: importance),
                    ])
                }
            }
            print("CURATION_PASS \(pass) rated=\(ratings.count)")
            fflush(stdout)
            if ratings.count == before { break }
        }
        let visible = Set(
            try await db.fetchArticles(limit: nil, options: ArticleFetchOptions(hidingWaitingStories: true)).map(\.id))
        let hiddenMajor = ratings.filter { $0["importance"] == "major" && !visible.contains($0["id"] ?? "") }.count
        assertEqual(hiddenMajor, 0, "No rated major story is hidden")
        // #309: every minor-rated story in the window, whether it waits, and one sampled re-rate that bypasses the cache.
        // The review sheet built from this file hides the waiting flag and the re-rate from the labeller.
        let minorRows = try await db.ratedImportanceRows(level: .minor, activeSince: activeSince)
        let shownMinor = try await db.notificationStoryIDs(minorRows.map(\.id))
        var review: [[String: String]] = []
        for row in minorRows {
            try Task.checkCancellation()
            let rerate = await OnDeviceImportanceJudge.modelRating(OnDeviceImportanceJudge.report(row), sampled: true)
            review.append([
                "id": row.id, "title": row.title, "summary": row.description, "source": row.source,
                "waiting": shownMinor.contains(row.id) ? "no" : "yes",
                "rerate": rerate.map { String(describing: $0) } ?? "none",
            ])
        }
        print("CURATION_REVIEW minor=\(review.count) waiting=\(review.filter { $0["waiting"] == "yes" }.count)")
        let report: [String: Int] = [
            "library": all.count, "active": active.count, "rated": ratings.count,
            "major": ratings.filter { $0["importance"] == "major" }.count,
            "notable": ratings.filter { $0["importance"] == "notable" }.count,
            "minor": ratings.filter { $0["importance"] == "minor" }.count,
            "waiting": try await db.waitingStoryCount(), "hiddenMajor": hiddenMajor,
            "unrated": try await db.pendingImportanceRows(activeSince: activeSince, limit: 10000).count,
        ]
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ratings).write(to: directory.appendingPathComponent("ratings-private.json"))
        try encoder.encode(review).write(to: directory.appendingPathComponent("minor-review-private.json"))
        try encoder.encode(report).write(to: directory.appendingPathComponent("curation.json"))
        print("CURATION_REPORT \(String(decoding: try encoder.encode(report), as: UTF8.self))")
        await db.close()
    }

    /// Opt-in protected publisher requests on an already rated, temporary library backup.
    /// How often the priority rule (#665) fires on a library backup: for each event, the first visible story, created in
    /// the last 14 days, that qualifies with the publishers its event had when that story arrived. Read-only.
    static func measureLivePriority(path: String, output: String) throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(
                domain: "LivePriority", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a temporary library backup"]
            )
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "LivePriority", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot open \(path)"])
        }
        defer { sqlite3_close(connection) }
        let now =
            ProcessInfo.processInfo.environment["NEWS_PRIORITY_NOW"].flatMap(TimeInterval.init)
            ?? Date().timeIntervalSince1970
        let query = """
            SELECT a.id, a.title, coalesce(a.description, ''), a.created_at, m.event_id,
                (SELECT count(DISTINCT b.source) FROM event_members n JOIN articles b ON b.id = n.article_id
                 WHERE n.event_id = m.event_id AND b.created_at <= a.created_at)
            FROM articles a JOIN event_members m ON m.article_id = a.id
            WHERE a.created_at >= ? AND a.created_at <= ?
                AND NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = a.id)
            ORDER BY a.created_at;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "LivePriority", code: 3, userInfo: [NSLocalizedDescriptionKey: "Query failed"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now - 14 * 86400)
        sqlite3_bind_double(statement, 2, now)
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var first: [String: (day: String, title: String, score: Double, publishers: Int)] = [:]
        var stories = 0
        var days = Set<String>()
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        while sqlite3_step(statement) == SQLITE_ROW {
            stories += 1
            let created = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            days.insert(dayFormat.string(from: created))
            let event = text(4)
            guard first[event] == nil else { continue }
            let title = text(1)
            let publishers = Int(sqlite3_column_int(statement, 5))
            let score = NotificationService.shared.computeImportance(title: title, description: text(2))
            if NotificationService.isPriority(title: title, score: score, publishers: publishers) {
                first[event] = (dayFormat.string(from: created), title, score, publishers)
            }
        }
        var lines = [
            "Priority keys (#665) over 14 days: \(first.count), from \(stories) clustered stories on \(days.count) days with ingestion"
        ]
        for day in days.sorted() {
            let keys = first.values.filter { $0.day == day }.sorted { $0.score > $1.score }
            lines.append("\(day): \(keys.count)")
            for key in keys {
                lines.append("  - \(String(format: "%.2f", key.score)), \(key.publishers) publishers: \(key.title)")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }

    static func measureLiveImages(path: String, output: String) async throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(
                domain: "LiveImages", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a temporary library backup"])
        }
        let db = DatabaseEngine(path: url.path)
        try await db.open()
        // NEWS_IMAGES_NOW (seconds since 1970) repeats an earlier measurement on the same 72-hour denominator (#312).
        let clock =
            ProcessInfo.processInfo.environment["NEWS_IMAGES_NOW"].flatMap(TimeInterval.init).map(
                Date.init(timeIntervalSince1970:)) ?? Date()
        var placeholders: [[String: String]] = []
        func coverage() async throws -> (cards: Int, pictured: Int) {
            let articles = try await db.fetchArticles(
                limit: nil,
                options: ArticleFetchOptions(
                    publicationWindow: clock.addingTimeInterval(-72 * 3600)...clock, hidingWaitingStories: true))
            let summaries = try await db.eventFeedSummaries(forArticles: articles.map(\.id))
            let entries = EventFeedGrouping.entries(for: articles, events: summaries, mode: .events)
            var pictured = 0
            placeholders = []
            let pending = Set(
                try await db.imagelessStoryRows(
                    activeSince: clock.addingTimeInterval(-EventCandidatePolicy.standard.activeEventLifetime),
                    limit: 2000
                ).map(\.id))
            for entry in entries {
                let members: [FeedArticle]
                switch entry {
                case .article(let article): members = [article]
                case .event(let summary, _, _):
                    members = try await db.fetchArticles(
                        limit: nil, options: ArticleFetchOptions(eventID: summary.eventID))
                }
                if FeedArticle.bestCardImage(in: members) != nil {
                    pictured += 1
                    continue
                }
                // Private: which cards keep the placeholder, and whether their pages were looked up.
                let looked = try await db.storyImages(for: members.map(\.id))
                for member in members {
                    let checked =
                        pending.contains(member.id)
                        ? "not looked up" : looked[member.id] == nil ? "looked up, none" : "found"
                    placeholders.append([
                        "card": members.count > 1 ? "event" : "single", "members": String(members.count),
                        "link": member.link, "lookup": checked,
                    ])
                }
            }
            return (entries.count, pictured)
        }
        let before = try await coverage()
        let placeholdersBefore = placeholders
        var checks = 0
        var found = 0
        for pass in 1...10 {
            let report = try await StoryCurator.run(
                in: db, imageFinder: .publisherPages, now: clock)
            checks += report.imagesChecked
            found += report.imagesFound
            print("IMAGE_PASS \(pass) checked=\(report.imagesChecked) found=\(report.imagesFound)")
            fflush(stdout)
            if report.imagesChecked == 0 { break }
        }
        let after = try await coverage()
        let images = try await db.storyImages(for: try await db.fetchArticles(limit: nil).map(\.id))
        var decoded = 0
        var failed = 0
        for link in Set(images.values) {
            if let url = URL(string: link), (try? await SecureHTTPClient.shared.fetchReaderImage(from: url)) != nil {
                decoded += 1
            } else {
                failed += 1
            }
        }
        let report = [
            "cardsBefore": before.cards, "picturedBefore": before.pictured,
            "cardsAfter": after.cards, "picturedAfter": after.pictured, "checks": checks, "imagesFound": found,
            "pageImagesDecoded": decoded, "pageImagesFailed": failed,
        ]
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("images.json"))
        try JSONSerialization.data(
            withJSONObject: ["before": placeholdersBefore, "after": placeholders],
            options: [.prettyPrinted, .sortedKeys]
        )
        .write(to: directory.appendingPathComponent("placeholders-private.json"))
        print("IMAGE_REPORT \(String(decoding: try encoder.encode(report), as: UTF8.self))")
        await db.close()
    }

    /// Opt-in #314 measurement on a copied library: every event's related-story links, each mixed with a hard near-miss
    /// control (an earlier candidate sharing a person, organization or place that the rule rejected), plus
    /// `near-misses-private.json`: up to 25 rejected candidates per stage for a recall read. Private text stays in the
    /// temporary audit directory; `script/evaluation/relation_review.py` builds the blind sheet and the report.
    static func measureLiveRelations(path: String, output: String) async throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(domain: "LiveRelations", code: 1)
        }
        let db = DatabaseEngine(path: url.path)
        try await db.open()
        var report: [String: Int] = ["eventsWithLinks": 0, "links": 0, "controls": 0]
        // `NEWS_RELATED_RECLUSTER=1` first runs the production clustering pass on the copy, with the clock at its last
        // refresh, so an older library gets the events the current matcher would build.
        if ProcessInfo.processInfo.environment["NEWS_RELATED_RECLUSTER"] == "1",
            let newest = try await db.fetchArticles(limit: nil).map(\.pubDate).max()
        {
            var converged = false
            for pass in 1...5 where !converged {
                let clustering = try await EventClusterer.run(in: db, now: newest.addingTimeInterval(3600))
                report["reclusterPasses"] = pass
                report["reclusterChangedEvents", default: 0] += clustering.changedEvents.count
                converged = clustering.changedEvents.isEmpty
            }
            // A pass that still changes events leaves a partial re-cluster; measuring it would mislead.
            guard converged else {
                await db.close()
                throw NSError(
                    domain: "LiveRelations", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Re-clustering still changed events after five passes"])
            }
        }
        let articles = try await db.fetchArticles(limit: nil)
        let events = try await db.eventFeedSummaries(forArticles: articles.map(\.id))
        report["events"] = events.count
        struct Pair {
            let kind: String
            let earlierID: String
            let laterID: String
            let earlier: [EventMatchRow]
            let later: [EventMatchRow]
        }
        var pairs: [Pair] = []
        // Rejected candidates by stage, so a recall sample can show which condition loses real developing stories.
        var nearMisses: [Pair] = []
        for event in events {
            let snapshot = try await db.relatedStoryEventRows(eventID: event.eventID)
            let common = try await EventStoryRelation.commonActors(of: snapshot.target, in: db)
            let links = try EventStoryRelation.links(
                target: snapshot.target, candidates: snapshot.candidates, commonActors: common)
            guard let start = snapshot.target.map(\.date).min() else { continue }
            report["linksPerEvent_\(links.count)", default: 0] += 1
            let linked = Set(links.map(\.eventID))
            if !links.isEmpty { report["eventsWithLinks", default: 0] += 1 }
            for candidate in snapshot.candidates where linked.contains(candidate.id) {
                pairs.append(
                    Pair(
                        kind: "link", earlierID: candidate.id, laterID: event.eventID, earlier: candidate.members,
                        later: snapshot.target))
            }
            let later = snapshot.target.map {
                EventFeatures(title: $0.title, description: $0.description, date: $0.date)
            }
            // Candidates the window rule skips before any pair is compared, and how many of them would link on their
            // earlier, in-window members alone.
            for candidate in snapshot.candidates where !candidate.members.isEmpty {
                let inWindow = candidate.members.filter {
                    $0.date < start && start.timeIntervalSince($0.date) <= EventStoryRelation.window
                }
                guard inWindow.count < candidate.members.count else { continue }
                let stage =
                    candidate.members.contains { $0.date >= start } ? "continuesAfterStart" : "olderThanWindow"
                report["candidateStage_\(stage)", default: 0] += 1
                nearMisses.append(
                    Pair(
                        kind: stage, earlierID: candidate.id, laterID: event.eventID, earlier: candidate.members,
                        later: snapshot.target))
                if !inWindow.isEmpty,
                    try !EventStoryRelation.links(
                        target: snapshot.target, candidates: [(candidate.id, inWindow)], commonActors: common
                    ).isEmpty
                {
                    report["windowBlocked_\(stage)_wouldLink", default: 0] += 1
                }
            }
            // Aggregate rejection stages over earlier candidates within the window: the first condition no pair meets.
            for candidate in snapshot.candidates
            where !candidate.members.isEmpty
                && candidate.members.allSatisfy({
                    $0.date < start && start.timeIntervalSince($0.date) <= EventStoryRelation.window
                })
            {
                let earlier = candidate.members.map {
                    EventFeatures(title: $0.title, description: $0.description, date: $0.date)
                }
                let pairs = earlier.flatMap { e in later.map { (e, $0) } }
                let stage =
                    if !pairs.contains(where: {
                        !$0.people.isDisjoint(with: $1.people)
                            || !$0.organizations.isDisjoint(with: $1.organizations)
                    }) {
                        earlier.allSatisfy { $0.people.isEmpty && $0.organizations.isEmpty }
                            || later.allSatisfy { $0.people.isEmpty && $0.organizations.isEmpty }
                            ? "noActorOnOneSide" : "differentActors"
                    } else if !pairs.contains(where: { !$0.places.isDisjoint(with: $1.places) }) {
                        "noSharedPlace"
                    } else if !pairs.contains(where: { EventStoryRelation.supports($0, $1, commonActors: common) }) {
                        "noPairMeetsAll"
                    } else if linked.contains(candidate.id) { "linked" } else { "belowTwoThirdsSupport" }
                report["candidateStage_\(stage)", default: 0] += 1
                if stage != "linked" {
                    nearMisses.append(
                        Pair(
                            kind: stage, earlierID: candidate.id, laterID: event.eventID, earlier: candidate.members,
                            later: snapshot.target))
                }
            }
            // The hardest rejected candidate: earlier, within the window, sharing an actor or a local place.
            let control = snapshot.candidates.first { candidate in
                !linked.contains(candidate.id) && !candidate.members.isEmpty
                    && candidate.members.allSatisfy {
                        $0.date < start && start.timeIntervalSince($0.date) <= EventStoryRelation.window
                    }
                    && candidate.members.contains { row in
                        let earlier = EventFeatures(title: row.title, description: row.description, date: row.date)
                        return later.contains {
                            !earlier.people.isDisjoint(with: $0.people)
                                || !earlier.organizations.isDisjoint(with: $0.organizations)
                                || !earlier.localPlaces.isDisjoint(with: $0.localPlaces)
                        }
                    }
            }
            if !links.isEmpty, let control {
                pairs.append(
                    Pair(
                        kind: "control", earlierID: control.id, laterID: event.eventID, earlier: control.members,
                        later: snapshot.target))
            }
        }
        report["links"] = pairs.filter { $0.kind == "link" }.count
        report["controls"] = pairs.filter { $0.kind == "control" }.count
        func describe(_ rows: [EventMatchRow]) -> (titles: String, summary: String, first: Date) {
            let titles = rows.prefix(3).map { "\($0.title) (\($0.source))" }.joined(separator: " | ")
            return (titles, String((rows.first?.description ?? "").prefix(300)), rows.map(\.date).min() ?? .distantPast)
        }
        func row(_ pair: Pair) -> (String, [String: Any]) {
            let (earlier, later) = (describe(pair.earlier), describe(pair.later))
            let hash = ArticleIdentity.sha256Hex(pair.earlierID + ">" + pair.laterID)
            return (
                hash,
                [
                    "hash": hash, "kind": pair.kind,
                    "earlierEvent": pair.earlierID, "laterEvent": pair.laterID, "earlier": earlier.titles,
                    "earlier_summary": earlier.summary, "later": later.titles, "later_summary": later.summary,
                    "gap_hours": String(format: "%.1f", later.first.timeIntervalSince(earlier.first) / 3600),
                ]
            )
        }
        // Pairs sorted by a hash, so links and controls interleave; `relation_review.py sheet` hides their kind.
        let rows = pairs.map(row).sorted { $0.0 < $1.0 }.map(\.1)
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(
            to: directory.appendingPathComponent("relations-private.json"), options: .withoutOverwriting)
        // Recall sample: up to 25 rejected candidates per stage, chosen by hash. `kind` names the rejecting stage.
        var perStage: [String: Int] = [:]
        var sample: [[String: Any]] = []
        for (_, fields) in nearMisses.map(row).sorted(by: { $0.0 < $1.0 }) {
            let stage = fields["kind"] as? String ?? ""
            guard perStage[stage, default: 0] < 25 else { continue }
            perStage[stage, default: 0] += 1
            sample.append(fields)
        }
        try JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]).write(
            to: directory.appendingPathComponent("near-misses-private.json"), options: .withoutOverwriting)
        let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RELATION_REPORT \(String(decoding: encoded, as: UTF8.self))")
        await db.close()
    }

    /// Opt-in #308/#313 measurement on a copied library: labeled controls, model overviews for covered events until
    /// `NEWS_OVERVIEWS_TARGET` drafts (default 30) are accepted, and deterministic perspective coverage for every covered
    /// event in the window. `NEWS_OVERVIEWS_EXCLUDE` names an earlier output directory whose live events are skipped for
    /// generation. Private text stays in the temporary audit directory.
    @MainActor
    static func measureLiveOverviews(path: String, output: String) async throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(domain: "LiveOverviews", code: 1)
        }
        let environment = ProcessInfo.processInfo.environment
        let target = environment["NEWS_OVERVIEWS_TARGET"].flatMap(Int.init) ?? 30
        let maxAttempts = environment["NEWS_OVERVIEWS_MAX_EVENTS"].flatMap(Int.init) ?? 120
        var excluded = Set<String>()
        if let previous = environment["NEWS_OVERVIEWS_EXCLUDE"] {
            let previousDirectory = URL(fileURLWithPath: previous)
            for file in try FileManager.default.contentsOfDirectory(atPath: previous)
            where file.hasPrefix("overview-private-live-") {
                let object =
                    try JSONSerialization.jsonObject(
                        with: Data(contentsOf: previousDirectory.appendingPathComponent(file))) as? [String: Any]
                if let id = (object?["document"] as? [String: Any])?["eventID"] as? String { excluded.insert(id) }
            }
            guard !excluded.isEmpty else { throw NSError(domain: "LiveOverviews", code: 2) }
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func runGitCommand(_ arguments: [String]) -> String? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = arguments
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return nil
            }
        }

        func fileSHA256(_ fileURL: URL) -> String? {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        // Consistent snapshot of the input library, WAL included. The input opens read-only, so the
        // snapshot never checkpoints or otherwise writes the library it reads.
        let snapshotURL = directory.appendingPathComponent("library-snapshot.sqlite3")
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            try FileManager.default.removeItem(at: snapshotURL)
        }
        let inputFiles = [url, URL(fileURLWithPath: url.path + "-wal")]
        let inputHashes = inputFiles.map(fileSHA256)
        let sqliteProc = Process()
        sqliteProc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqliteProc.arguments = [
            url.absoluteString + "?mode=ro",
            "VACUUM INTO '\(snapshotURL.path.replacingOccurrences(of: "'", with: "''"))';",
        ]
        let sqliteErrPipe = Pipe()
        sqliteProc.standardError = sqliteErrPipe
        try sqliteProc.run()
        sqliteProc.waitUntilExit()
        guard sqliteProc.terminationStatus == 0, FileManager.default.fileExists(atPath: snapshotURL.path) else {
            let errData = sqliteErrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(decoding: errData, as: UTF8.self)
            throw NSError(
                domain: "LiveOverviews", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create SQLite snapshot: \(errMsg)"])
        }
        guard inputFiles.map(fileSHA256) == inputHashes else {
            throw NSError(
                domain: "LiveOverviews", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Snapshot changed the input library"])
        }
        guard let snapshotSHA256 = fileSHA256(snapshotURL) else {
            throw NSError(
                domain: "LiveOverviews", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to compute snapshot SHA256"])
        }

        let runLibraryURL = directory.appendingPathComponent("run-library.sqlite3")
        if FileManager.default.fileExists(atPath: runLibraryURL.path) {
            try FileManager.default.removeItem(at: runLibraryURL)
        }
        try FileManager.default.copyItem(at: snapshotURL, to: runLibraryURL)

        let db = DatabaseEngine(path: runLibraryURL.path)
        try await db.open()

        let captureDate = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let captureTimeUTC = isoFormatter.string(from: captureDate)

        // NEWS_OVERVIEWS_NOW=<epoch> pins the 72 h window, so a rerun on the same copy measures the same events (#670).
        let selectionAnchor =
            environment["NEWS_OVERVIEWS_NOW"].flatMap { raw -> Date? in
                guard let seconds = TimeInterval(raw), seconds.isFinite else { return nil }
                return Date(timeIntervalSince1970: seconds)
            } ?? captureDate
        let selectionWindowStart = selectionAnchor.addingTimeInterval(-72 * 3600)
        let selectionWindowEnd = selectionAnchor
        let selectionAnchorUTC = isoFormatter.string(from: selectionAnchor)
        let selectionStartUTC = isoFormatter.string(from: selectionWindowStart)
        let selectionEndUTC = isoFormatter.string(from: selectionWindowEnd)

        let gitCommit = runGitCommand(["rev-parse", "HEAD"]) ?? "unknown"
        let gitBranch = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"]) ?? "unknown"
        let gitStatus = runGitCommand(["status", "--porcelain"]) ?? ""
        let dirtyFingerprint =
            gitStatus.isEmpty ? "clean" : "dirty (\(gitStatus.split(separator: "\n").count) uncommitted changes)"

        let preProvenance: [String: Any] = [
            "stage": "pre-generation",
            "run": environment["NEWS_OVERVIEWS_RUN_NAME"] ?? "live-overview-measurement",
            "issue": 308,
            "captureTimeUTC": captureTimeUTC,
            "gitCommit": gitCommit,
            "gitBranch": gitBranch,
            "dirtyCodeFingerprint": dirtyFingerprint,
            "selectionBoundsUTC": [
                "anchor": selectionAnchorUTC,
                "start": selectionStartUTC,
                "end": selectionEndUTC,
            ],
            "librarySnapshot": [
                "path": "library-snapshot.sqlite3",
                "sha256": snapshotSHA256,
                "sourcePath": url.path,
            ],
        ]
        let preProvenanceData = try JSONSerialization.data(
            withJSONObject: preProvenance, options: [.prettyPrinted, .sortedKeys])
        try preProvenanceData.write(to: directory.appendingPathComponent("provenance-pre-generation.json"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let active = try await db.fetchArticles(
            limit: nil,
            options: ArticleFetchOptions(
                publicationWindow: selectionWindowStart...selectionWindowEnd, hidingWaitingStories: true))
        let events = try await db.eventFeedSummaries(forArticles: active.map(\.id)).filter { $0.sources.count > 1 }
            .sorted { $0.sources.count > $1.sources.count }
        var report = [
            "liveEvents": 0, "liveGenerated": 0, "liveClaims": 0, "liveUnsupported": 0, "liveCritical": 0,
            "controls": 0, "controlsGenerated": 0, "controlClaims": 0, "controlUnsupported": 0, "controlCritical": 0,
            "target": target, "excludedEvents": excluded.count,
        ]
        var coverage: [String: Int] = ["events": 0, "twoOrMore": 0, "one": 0, "none": 0]
        let measuredModel = NewsTextModel { prompt, tokens in
            let answer = try await NewsTextModel.onDevice.respond(prompt, tokens)
            let data = try JSONSerialization.data(
                withJSONObject: ["prompt": prompt, "answer": answer], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("model-private-\(UUID().uuidString).json"))
            return answer
        }
        /// Model failures by kind; refusals surface as FoundationModels guardrail or refusal errors.
        func failureKind(_ error: Error) -> String {
            if error is NewsTextModel.TemporarilyUnavailable { return "unavailable" }
            if let urlError = error as? URLError, urlError.code == .resourceUnavailable { return "unavailable" }
            let name = String(reflecting: error).lowercased()
            if name.contains("guardrail") || name.contains("refusal") { return "refusal" }
            return name.contains("context") ? "contextWindow" : "error"
        }
        /// The first step that left an event with fewer than two perspectives.
        func perspectiveGap(shown: Int, diagnosis: OverviewPerspectivesDiagnosis) -> String? {
            guard shown < 2 else { return nil }
            if diagnosis.passages == 0 { return "noPassages" }
            if diagnosis.candidates == 0 {
                return diagnosis.passagesWithUnmatchedSpeech > 0 ? "speechNotMatched" : "noAttributedSpeech"
            }
            if diagnosis.voices == 0 { return "onlyVagueSpeakers" }
            if diagnosis.perspectives < 2 { return diagnosis.rejections.isEmpty ? "singleVoice" : "validatorRejected" }
            return "fallbackOverview"
        }
        func measure(
            id: String, title: String, passages: [EvidencePassage], articles: [FeedArticle], live: Bool,
            membership: Int = 1, sources: Int = 0, perspectives: OverviewPerspectivesDiagnosis? = nil,
            evidence: [String: Any]? = nil
        ) async throws {
            let fallback = OverviewComposer.composeOverview(
                eventID: id, eventTitle: title,
                verifiedFacts: PassageFactExtractor.deterministicExtract(passages: passages), passages: passages,
                articles: articles, membershipVersion: membership)
            let start = Date()
            var document = fallback
            var outcome: OverviewModelOutcome?
            var failure: String?
            do {
                let composed = try await OverviewComposer.composeWithModelOutcome(
                    fallback: fallback, passages: passages, articles: articles, model: measuredModel)
                document = composed.document
                outcome = composed.outcome
            } catch is CancellationError { throw CancellationError() } catch { failure = failureKind(error) }
            let duration = Date().timeIntervalSince(start)
            let audit = OverviewQualityAuditor.auditOverview(document, passages: passages, duration: duration)
            let prefix = live ? "live" : "control"
            report[live ? "liveEvents" : "controls", default: 0] += 1
            report[live ? "liveGenerated" : "controlsGenerated", default: 0] += outcome?.result == .accepted ? 1 : 0
            report[live ? "liveClaims" : "controlClaims", default: 0] += audit.totalClaims
            report[live ? "liveUnsupported" : "controlUnsupported", default: 0] += audit.unsupportedClaims
            report[live ? "liveCritical" : "controlCritical", default: 0] += audit.totalCriticalErrors
            report["\(prefix)Outcome_\(failure ?? outcome?.result.rawValue ?? "unknown")", default: 0] += 1
            var privateJSON: [String: Any] = [
                "document": try JSONSerialization.jsonObject(with: encoder.encode(document)),
                "passages": try JSONSerialization.jsonObject(with: encoder.encode(passages)),
                "audit": try JSONSerialization.jsonObject(with: encoder.encode(audit)),
                "durationSeconds": duration, "sources": sources, "failure": failure.map { $0 as Any } ?? NSNull(),
                "outcome": try outcome.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) } ?? NSNull(),
            ]
            if let perspectives {
                privateJSON["perspectives"] = try JSONSerialization.jsonObject(with: encoder.encode(perspectives))
            }
            if let evidence { privateJSON["evidence"] = evidence }
            try JSONSerialization.data(withJSONObject: privateJSON, options: [.prettyPrinted, .sortedKeys]).write(
                to: directory.appendingPathComponent(
                    "overview-private-\(prefix)-\(report[live ? "liveEvents" : "controls"]!).json"))
            if live { _ = try await db.recordEventOverview(document) }
            print(
                "OVERVIEW_AUDIT \(prefix) result=\(failure ?? outcome?.result.rawValue ?? "unknown") seconds=\(String(format: "%.1f", duration)) claims=\(audit.totalClaims) critical=\(audit.totalCriticalErrors)"
            )
            fflush(stdout)
        }
        for sample in OverviewControlSample.standardBenchmark() {
            try await measure(
                id: sample.eventID, title: sample.title, passages: sample.passages, articles: sample.articles,
                live: false)
        }
        // `NEWS_OVERVIEWS_EXTRACT=1` (#308 step 2): before each measured event, the production coordinator stores
        // publisher text for its representatives, with its deadline and fetch limit, and the run records the step.
        let fetches = EvidenceFetchTally()
        let evidenceStore = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        let evidenceCoordinator: OverviewGenerationCoordinator? =
            environment["NEWS_OVERVIEWS_EXTRACT"] == "1"
            ? OverviewGenerationCoordinator(
                store: evidenceStore,
                extractText: { link in
                    let outcome = await ContentExtractionPipeline.shared.extractArticleWithIdentity(from: link).outcome
                    await fetches.add(Task.isCancelled ? "cutAtDeadline" : outcome.kindName)
                    return outcome
                }) : nil
        // Industry Impact (#670) on every covered event: the share that shows the section, and each entry with the full
        // text of the passages it cites, for the 30-event support review. Private, like the other outputs.
        var industryEntries: [[String: Any]] = []
        for event in events {
            var members = try await db.fetchArticles(limit: nil, options: ArticleFetchOptions(eventID: event.eventID))
            guard let first = members.first else { continue }
            let measured =
                !excluded.contains(event.eventID) && report["liveGenerated", default: 0] < target
                && report["liveEvents", default: 0] < maxAttempts
            var evidence: [String: Any]?
            if measured, let evidenceCoordinator, Set(members.map { $0.source.lowercased() }).count > 1 {
                let before = await fetches.counts
                let lacking = Set(members.filter { !OverviewGenerationCoordinator.hasPublisherText($0) }.map(\.id))
                let start = Date()
                members = await evidenceCoordinator.articlesWithPublisherText(
                    members, excluding: [], store: evidenceStore)
                let after = await fetches.counts
                let outcomes = after.reduce(into: [String: Int]()) { result, entry in
                    let added = entry.value - (before[entry.key] ?? 0)
                    if added > 0 { result[entry.key] = added }
                }
                evidence = [
                    "seconds": Date().timeIntervalSince(start), "pageRequests": outcomes.values.reduce(0, +),
                    "storedTexts": members.filter {
                        lacking.contains($0.id) && OverviewGenerationCoordinator.hasPublisherText($0)
                    }.count,
                    "outcomes": outcomes,
                ]
            }
            let passages = OverviewPassageSelector().selectPassages(from: members, budget: OverviewTokenBudget())
                .passages
            // Every passage is citable, as in a synthesized overview, so the diagnosis sees what the extractor would.
            let citations = Dictionary(
                passages.map {
                    (
                        $0.id,
                        OverviewCitation(
                            id: $0.id, articleID: $0.articleID, passageID: $0.id,
                            passageFingerprint: $0.fingerprint, quote: String($0.text.prefix(200)))
                    )
                }, uniquingKeysWith: { kept, _ in kept })
            let diagnosis = OverviewPerspectivesExtractor.diagnosePerspectives(
                passages: passages, articles: members, existingCitations: citations)
            let composed = OverviewComposer.composeOverview(
                eventID: event.eventID, eventTitle: first.title,
                verifiedFacts: PassageFactExtractor.deterministicExtract(passages: passages), passages: passages,
                articles: members,
                membershipVersion: event.membershipVersion
            )
            let shown = composed.perspectives.count
            let impact = composed.evidenceSections?.industryImpact ?? []
            if !impact.isEmpty {
                coverage["industryImpactEvents", default: 0] += 1
                coverage["industryImpactEntries", default: 0] += impact.count
                let passageText = Dictionary(passages.map { ($0.id, $0.text) }, uniquingKeysWith: { kept, _ in kept })
                industryEntries.append([
                    "eventID": event.eventID, "eventTitle": first.title, "sources": event.sources.count,
                    "entries": impact.map { item in
                        [
                            "industry": item.industry, "implication": item.implication,
                            "citedPassages": item.citationIDs.compactMap { id in
                                composed.citations[id].map { passageText[$0.passageID] ?? $0.quote }
                            },
                        ] as [String: Any]
                    },
                ])
            }
            coverage["events", default: 0] += 1
            coverage[shown >= 2 ? "twoOrMore" : shown == 1 ? "one" : "none", default: 0] += 1
            if let gap = perspectiveGap(shown: shown, diagnosis: diagnosis) { coverage["gap_\(gap)", default: 0] += 1 }
            for (key, value) in [
                "passages": diagnosis.passages, "passagesWithCandidates": diagnosis.passagesWithCandidates,
                "passagesWithUnmatchedSpeech": diagnosis.passagesWithUnmatchedSpeech,
                "passagesWithTypographicQuotes": diagnosis.passagesWithTypographicQuotes,
                "candidates": diagnosis.candidates, "vagueCandidates": diagnosis.vagueCandidates,
                "voices": diagnosis.voices, "extractedPerspectives": diagnosis.perspectives,
            ] {
                coverage[key, default: 0] += value
            }
            for (rule, count) in diagnosis.rejections { coverage["rejected_\(rule)", default: 0] += count }
            guard measured else { continue }
            try await measure(
                id: event.eventID, title: first.title, passages: passages, articles: members, live: true,
                membership: event.membershipVersion, sources: event.sources.count, perspectives: diagnosis,
                evidence: evidence)
        }
        if let harsh = active.first(where: { ($0.title + $0.description).lowercased().contains("killed") }) {
            let analysis = try await ArticleAnalyzer(textModel: measuredModel).analyze(
                title: harsh.title, content: harsh.fullContent ?? harsh.description)
            report["sensitiveAnalysisUsedModel"] = analysis.modelIdentifier == "apple.foundation-model" ? 1 : 0
            try encoder.encode(analysis).write(to: directory.appendingPathComponent("analysis-private.json"))
        }
        try encoder.encode(report).write(to: directory.appendingPathComponent("overviews.json"))
        try encoder.encode(coverage).write(to: directory.appendingPathComponent("perspectives.json"))
        try JSONSerialization.data(withJSONObject: industryEntries, options: [.prettyPrinted, .sortedKeys]).write(
            to: directory.appendingPathComponent("industry-impact-private.json"), options: .withoutOverwriting)
        print("OVERVIEW_REPORT \(String(decoding: try encoder.encode(report), as: UTF8.self))")
        print("PERSPECTIVE_COVERAGE \(String(decoding: try encoder.encode(coverage), as: UTF8.self))")

        // Automatically record synchronous run receipt and provenance (#308/#313).
        var outputFiles: [String: [String: Any]] = [:]
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator.allObjects {
                guard !fileURL.hasDirectoryPath,
                    fileURL.lastPathComponent != "receipt.json",
                    fileURL.lastPathComponent != "run-library.sqlite3",
                    fileURL.lastPathComponent != "run-library.sqlite3-wal",
                    fileURL.lastPathComponent != "run-library.sqlite3-shm"
                else { continue }
                if let hash = fileSHA256(fileURL) {
                    outputFiles[fileURL.lastPathComponent] = [
                        "sha256": hash
                    ]
                }
            }
        }

        let receipt: [String: Any] = [
            "run": environment["NEWS_OVERVIEWS_RUN_NAME"] ?? "live-overview-measurement",
            "issue": 308,
            "receiptType": "live",
            "captureTimeUTC": captureTimeUTC,
            "gitCommit": gitCommit,
            "gitBranch": gitBranch,
            "dirtyCodeFingerprint": dirtyFingerprint,
            "selectionBoundsUTC": [
                "anchor": selectionAnchorUTC,
                "start": selectionStartUTC,
                "end": selectionEndUTC,
            ],
            "library": [
                "snapshotPath": "library-snapshot.sqlite3",
                "snapshotSHA256": snapshotSHA256,
                "sourcePath": url.path,
                "articleCount": active.count,
                "multiSourceActiveEvents": events.count,
            ],
            "outputs": outputFiles,
        ]

        let receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try receiptData.write(to: directory.appendingPathComponent("receipt.json"))
        print("LIVE_RUN_RECEIPT \(String(decoding: receiptData, as: UTF8.self))")
        await db.close()
    }

    /// The authored English corpus replayed through the real clusterer (#506). Regression evidence with a ratchet;
    /// the private holdout (#509) stays the acceptance measurement. Pairs are printed by fixture id only.
    /// Opt-in, live, local only (#508): the real on-device model over authored reports of violence. Prints the
    /// identifier and version the reader would store and whether a second request repeats the outcome; the
    /// `NewsTextModel` log category carries the outcome label. No publisher text, nothing stored.
    static func checkOnDeviceModelOutcomes() async throws {
        let reports: [(name: String, title: String, content: String)] = [
            (
                "benign",
                "City council approves new library branch",
                """
                The city council voted on Tuesday to fund a new library branch in the eastern district. \
                Construction is expected to start next spring and take eighteen months. \
                Councillors said the branch would include a children's reading room and a community hall. \
                The budget was approved without opposition after a short debate.
                """
            ),
            (
                "shooting",
                "Three dead after gunman opens fire at shopping mall",
                """
                A gunman shot and killed three people at a shopping mall on Saturday afternoon before a police \
                officer shot him dead, police said. Two more people were wounded and taken to hospital. \
                Witnesses described shoppers running from the food court as shots rang out. \
                Police have not named the attacker and said the motive was unknown.
                """
            ),
            (
                "war",
                "Air strike on apartment block kills at least twelve",
                """
                An overnight air strike hit a residential block in the city's northern district, killing at least \
                twelve people including four children, the regional governor said on Monday. \
                Rescue teams pulled survivors from the rubble through the morning as shelling continued nearby. \
                The military said it had struck a command post; residents said the building housed only families.
                """
            ),
        ]
        let analyzer = ArticleAnalyzer(textModel: .onDevice)
        for report in reports {
            let first = try await analyzer.analyze(title: report.title, content: report.content)
            let second = try await analyzer.analyze(title: report.title, content: report.content)
            print(
                "    \(report.name): identifier \(first.modelIdentifier) version \(first.analysisVersion), "
                    + "repeat identifier \(second.modelIdentifier) version \(second.analysisVersion), "
                    + "summary \(first.summary.count) chars")
        }
        // A prompt past the context window is the one rejection that needs no sensitive text to provoke.
        do {
            _ = try await NewsTextModel.onDevice.respond(String(repeating: "word ", count: 40_000), 32)
            print("    oversized prompt: answered")
        } catch let rejected as NewsTextModel.Rejected {
            print("    oversized prompt: rejected:\(rejected.reason.rawValue) (final)")
        } catch {
            print("    oversized prompt: \(type(of: error)) (provisional)")
        }
        print(
            "    Outcome labels: log show --predicate 'subsystem == \"com.marspater.news\" AND category == \"NewsTextModel\"' "
                + "--last 10m")
    }

    /// A verdict replay (#629): how many verdicts the pair model decides as the reader did at `base`, and with the
    /// calibration fitted on them. Clean when the calibration decides at least as many as the bare cutoff.
    static func verdictReplay(
        _ rows: [PairCalibration.Row], base: Double = EventMatchPolicy.standard.pairModelThreshold
    ) -> (verdicts: Int, bare: Int, calibrated: Int, fitted: Bool) {
        // Fitted as production fits: on at most the first 1,000 rows (verdicts.csv is written in pair-id order).
        let calibration = PairCalibration.fit(Array(rows.prefix(1_000)))
        var bare = 0
        var calibrated = 0
        for row in rows {
            if (row.features[0] >= base) == row.same { bare += 1 }
            let cutoff = calibration?.cutoff(base, row.features) ?? base
            if (row.features[0] >= cutoff) == row.same { calibrated += 1 }
        }
        return (rows.count, bare, calibrated, calibration != nil)
    }

    /// Synthetic verdicts: the pair model spread over 0.82–0.98, and the reader says "same" for reports under 24 h
    /// apart, which the bare cutoff cannot see.
    static func syntheticVerdicts(_ count: Int) -> [PairCalibration.Row] {
        (0..<count).map { index in
            let gap = Double(index * 7 % 60)
            return PairCalibration.Row(
                features: PairCalibration.features(
                    pairModel: 0.82 + 0.16 * Double(index % 17) / 16, cosine: 0.7, sharedSpecific: 2, gapHours: gap,
                    sameAct: true),
                same: gap < 24)
        }
    }

    struct EventCorpusMetrics {
        var truePositives = 0, falsePositives = 0, falseNegatives = 0, impureEvents = 0
        var precision: Double? {
            truePositives + falsePositives == 0 ? nil : Double(truePositives) / Double(truePositives + falsePositives)
        }
        var recall: Double? {
            truePositives + falseNegatives == 0 ? nil : Double(truePositives) / Double(truePositives + falseNegatives)
        }
        mutating func add(predicted: Bool, gold: Bool) {
            if predicted && gold {
                truePositives += 1
            } else if predicted {
                falsePositives += 1
            } else if gold {
                falseNegatives += 1
            }
        }
        var line: String {
            let precisionText = precision.map { String(format: "%.3f", $0) } ?? "n/a"
            let recallText = recall.map { String(format: "%.3f", $0) } ?? "n/a"
            func interval(_ successes: Int, _ trials: Int) -> String {
                StoryCorpus.wilson(successes, of: trials).map {
                    String(format: " [95%% %.3f–%.3f]", $0.lowerBound, $0.upperBound)
                } ?? ""
            }
            return
                "precision \(precisionText)\(interval(truePositives, truePositives + falsePositives)) (TP \(truePositives), FP \(falsePositives)), recall \(recallText)\(interval(truePositives, truePositives + falseNegatives)) (FN \(falseNegatives))"
        }
    }

    /// Replays a labeled corpus through the real clusterer in six-hour steps, as refreshes would, and
    /// reports pairwise precision, recall and false merges per split, language and source. Tuning
    /// must use the "tune" split only; the "holdout" split is the acceptance measurement (#102).
    /// Format: {"articles": [{"id", "title", "description", "source", "published" (ISO 8601),
    /// "event" (label, or absent for singletons), "split" ("tune" or "holdout")}]}.
    @discardableResult
    static func evaluateEventCorpus(
        path: String, selectedSplit: String = "tune", language: String? = nil,
        outputDirectory: String? = nil
    ) async throws -> [String: EventCorpusMetrics] {
        let output = try outputDirectory.map {
            try StoryCorpus.privateDirectory($0).appendingPathComponent("event-replay-\(selectedSplit).json")
        }
        if let output, FileManager.default.fileExists(atPath: output.path) {
            throw StoryCorpus.Failure.invalid("Replay evidence already exists; refusing to score again")
        }
        struct Corpus: Decodable {
            struct Item: Decodable {
                let id: String, title: String, description: String?, source: String, published: Date, event: String?,
                    split: String?
                let url: String?
            }
            let articles: [Item]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let corpus = try decoder.decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var results: [String: EventCorpusMetrics] = [:]
        for split in [selectedSplit] {
            let items = corpus.articles.filter {
                ($0.split ?? "tune") == split
                    && (language == nil
                        || EventMatchKey.language(of: $0.title + "\n" + ($0.description ?? "")) == language)
            }.sorted { ($0.published, $0.id) < ($1.published, $1.id) }
            let articles = items.map { item in
                FeedArticle(
                    storedID: item.id, title: item.title, link: item.url ?? "https://corpus.invalid/\(item.id)",
                    guid: item.id,
                    description: item.description ?? "", pubDate: item.published, source: item.source)
            }
            var passes: [[String: Int]] = []
            let memberships = try await StoryCorpus.eventMemberships(articles: articles) { report in
                passes.append([
                    "processed": report.processed, "joined": report.joined, "created": report.created,
                    "merged": report.merged, "conflicts": report.conflicts,
                    "detached": report.detached,
                ])
            }
            // Per-pair gate values for every labeled or linked pair, ids only: which gate holds a missed pair out,
            // and what a wrong pair passed. Opt-in; the aggregate lines above are the measurement.
            if ProcessInfo.processInfo.environment["NEWS_EVENT_DIAGNOSE"] == "1" {
                var featureCache: [String: EventFeatures] = [:]
                var vectorCache: [String: [Float]] = [:]
                for item in items {
                    featureCache[item.id] = EventFeatures(
                        title: item.title, description: item.description ?? "", date: item.published)
                    if let vector = await SentenceEmbedder.shared.embed(
                        EventFeatures.matchingText(title: item.title, description: item.description ?? ""))
                    {
                        vectorCache[item.id] = vector
                    }
                }
                // The replay's scorer (a candidate model or none under NEWS_PAIR_MODEL=0), else the shipped one; built once.
                let probability =
                    StoryCorpus.pairProbabilityFromEnvironment()
                    ?? { @Sendable a, b in await PairScorer.shared.probability(a, b) }
                for i in items.indices {
                    for j in items.indices where j > i {
                        let gold = items[i].event != nil && items[i].event == items[j].event
                        let linked =
                            memberships[items[i].id] != nil && memberships[items[i].id] == memberships[items[j].id]
                        guard gold || linked, let a = featureCache[items[i].id], let b = featureCache[items[j].id]
                        else { continue }
                        var similarity: Double?
                        if let va = vectorCache[items[i].id], let vb = vectorCache[items[j].id] {
                            similarity = SentenceEmbedder.cosineSimilarity(va, vb)
                        }
                        let diagnosePolicy = StoryCorpus.policyFromEnvironment()
                        var pair = EventMatcher.assess(
                            a, b, policy: diagnosePolicy, embeddingSimilarity: similarity,
                            samePublisher: !items[i].source.isEmpty && items[i].source == items[j].source)
                        // The clusterer's same-publisher gate (NEWS_SAME_PUBLISHER=1), so the printed gate is the real one.
                        if diagnosePolicy.samePublisherRequiresMatch, !pair.isMatch, !items[i].source.isEmpty,
                            items[i].source == items[j].source
                        {
                            pair.isCompatible = false
                        }
                        func input(_ index: Int) -> String {
                            let known = !items[i].source.isEmpty && !items[j].source.isEmpty
                            return EventMatcher.pairModelText(
                                title: items[index].title, description: items[index].description ?? "",
                                gap: abs(items[i].published.timeIntervalSince(items[j].published)),
                                samePublisher: known ? items[i].source == items[j].source : nil, policy: diagnosePolicy)
                        }
                        let pairModel = EventMatcher.needsPairModel(pair) ? await probability(input(i), input(j)) : nil
                        // As the clusterer does: a borderline pair the model confirms at the cutoff is a match.
                        if let pairModel, pairModel >= diagnosePolicy.pairModelThreshold {
                            pair = EventMatcher.modelConfirmed(pair, policy: diagnosePolicy)
                        }
                        pair = EventMatcher.applyingBorderlineFloor(
                            pair, probability: pairModel, policy: diagnosePolicy)
                        let nonPlaceB = b.keywords.union(b.titleNumbers).union(b.tollNumbers)
                        let nonPlaceA = a.keywords.union(a.titleNumbers).union(a.tollNumbers)
                        let primaryDisjoint =
                            (!a.primaryTitleTerms.isEmpty && a.primaryTitleTerms.isDisjoint(with: nonPlaceB))
                            || (!b.primaryTitleTerms.isEmpty && b.primaryTitleTerms.isDisjoint(with: nonPlaceA))
                        let gap = abs(items[i].published.timeIntervalSince(items[j].published)) / 3600
                        print(
                            String(
                                format: "      pair %@+%@ gold=%d linked=%d gap=%.1fh conflict=%@ primaryDisjoint=%d "
                                    + "match=%d compatible=%d borderline=%d specific=%d anchors=%d keywords=%d what=%.2f "
                                    + "score=%.2f cosine=%@ pairModel=%@",
                                items[i].id, items[j].id, gold ? 1 : 0, linked ? 1 : 0, gap,
                                pair.conflict?.rawValue ?? "-", primaryDisjoint ? 1 : 0, pair.isMatch ? 1 : 0,
                                pair.isCompatible ? 1 : 0, pair.isBorderline ? 1 : 0, pair.sharedSpecificAnchors,
                                pair.sharedAnchors, pair.sharedKeywords, pair.what, pair.score,
                                similarity.map { String(format: "%.2f", $0) } ?? "-",
                                pairModel.map { String(format: "%.3f", $0) } ?? "-"))
                    }
                }
            }
            if let output {
                let receipt: [String: Any] = [
                    "split": split, "language": language ?? "all", "matcherVersion": EventMatcher.version,
                    "memberships": memberships, "passes": passes,
                ]
                try StoryCorpus.writePrivate(
                    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), to: output,
                    replacing: false)
            }
            let predicted = items.map { memberships[$0.id] }
            let languages = items.map {
                EventMatchKey.language(of: $0.title + "\n" + ($0.description ?? "")) ?? "unknown"
            }
            var total = EventCorpusMetrics()
            var byLanguage: [String: EventCorpusMetrics] = [:]
            var bySource: [String: EventCorpusMetrics] = [:]
            for i in items.indices {
                for j in items.indices where j > i {
                    let isPredicted = predicted[i] != nil && predicted[i] == predicted[j]
                    let isGold = items[i].event != nil && items[i].event == items[j].event
                    guard isPredicted || isGold else { continue }
                    total.add(predicted: isPredicted, gold: isGold)
                    byLanguage[languages[i] == languages[j] ? languages[i] : "mixed", default: EventCorpusMetrics()]
                        .add(predicted: isPredicted, gold: isGold)
                    for source in Set([items[i].source, items[j].source]) {
                        bySource[source, default: EventCorpusMetrics()].add(predicted: isPredicted, gold: isGold)
                    }
                }
            }
            var labelsByEvent: [String: Set<String>] = [:]
            for (position, event) in predicted.enumerated() {
                guard let event else { continue }
                labelsByEvent[event, default: []].insert(items[position].event ?? "unlabeled-\(items[position].id)")
            }
            total.impureEvents = labelsByEvent.values.filter { $0.count > 1 }.count
            print(
                "    \(split): \(items.count) articles, \(total.line), \(total.falsePositives) falsely merged pairs in \(total.impureEvents) events"
            )
            for (language, metrics) in byLanguage.sorted(by: { $0.key < $1.key }) {
                print("      language \(language): \(metrics.line)")
            }
            for (source, metrics) in bySource.sorted(by: { $0.key < $1.key }) {
                print("      source \(source): \(metrics.line)")
            }
            if CommandLine.arguments.contains("--export-features") {
                let pairs = try await exportPairFeatures(
                    items: items.map {
                        PairExportItem(
                            id: $0.id, title: $0.title, description: $0.description ?? "", published: $0.published,
                            event: $0.event, source: $0.source)
                    },
                    predicted: predicted, split: split, outputDirectory: outputDirectory)
                print("    exported \(pairs) candidate pairs with features for the fit (#524)")
            }
            var thresholds = EventEmbeddingComparison.sweep
            if split == "holdout" {
                // The holdout is scored at one cutoff chosen on tune, never swept.
                thresholds =
                    ProcessInfo.processInfo.environment["NEWS_EMBEDDING_THRESHOLD"].flatMap { Double($0) }.map { [$0] }
                    ?? []
            }
            let comparisonItems = items.map {
                EventEmbeddingComparison.Item(
                    title: $0.title, description: $0.description ?? "", date: $0.published,
                    event: $0.event, membership: memberships[$0.id])
            }
            EventEmbeddingComparison(items: comparisonItems, thresholds: thresholds).report(split: split)
            results[split] = total
        }
        return results
    }

    /// Every stored pair decision of a library copy with both headlines, publishers, dates, event ids and the reader's
    /// corrections, as `pairs-review.csv` in the private directory (#551). The CSV carries headlines, so it is never
    /// written inside the checkout and never overwritten; a file inside an app container is refused.
    static func exportPairReview(snapshot: String, outputDirectory: String) async throws -> Int {
        guard !StoryCorpus.isLiveLibrary(snapshot) else {
            throw StoryCorpus.Failure.invalid("Export from a copy of the library, never the live file")
        }
        let file = try StoryCorpus.privateDirectory(outputDirectory).appendingPathComponent("pairs-review.csv")
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let db = DatabaseEngine(path: snapshot)
        try await db.open()
        let rows = try await db.eventRows(
            """
            SELECT p.article_id, p.other_article_id, p.decision, p.reason, p.score, p.matcher_version, p.assessed_at,
                coalesce(p.features, ''), a.source, a.title, a.published_at, coalesce(ma.event_id, ''),
                b.source, b.title, b.published_at, coalesce(mb.event_id, ''),
                EXISTS (SELECT 1 FROM event_inclusions i
                    WHERE i.article_id = p.article_id AND i.other_article_id = p.other_article_id),
                EXISTS (SELECT 1 FROM event_exclusions x
                    WHERE x.article_id = p.article_id AND x.other_article_id = p.other_article_id)
            FROM pair_assessments p
            JOIN articles a ON a.id = p.article_id
            JOIN articles b ON b.id = p.other_article_id
            LEFT JOIN event_members ma ON ma.article_id = a.id
            LEFT JOIN event_members mb ON mb.article_id = b.id
            ORDER BY p.decision, p.score DESC, p.article_id, p.other_article_id;
            """)
        await db.close()
        var lines = [
            "article_id,other_article_id,decision,reason,score,matcher_version,assessed_at,features,"
                + "source_a,title_a,published_a,event_a,source_b,title_b,published_b,event_b,included,excluded"
        ]
        for row in rows {
            lines.append(
                row.enumerated().map { index, value in
                    [7, 8, 9, 12, 13].contains(index) ? quoted(value ?? "") : (value ?? "")
                }.joined(separator: ","))
        }
        try StoryCorpus.writePrivate(Data(lines.joined(separator: "\n").utf8), to: file, replacing: false)
        return rows.count
    }

    /// A story of a library copy as the holdout tools read it.
    struct LibraryRow {
        let id: String, title: String, description: String, source: String, date: Date, event: String?
    }

    /// Stories in the three days ending at `now` (by default the copy's newest story), with their live event.
    static func recentLibraryRows(
        _ db: DatabaseEngine, now: Date? = nil
    ) async throws -> (rows: [LibraryRow], newest: Date) {
        let newest: TimeInterval
        if let now {
            newest = now.timeIntervalSince1970
        } else {
            newest =
                try await db.eventRows(
                    "SELECT max(published_at) FROM articles WHERE published_at < ?;",
                    [.real(Date().timeIntervalSince1970 + 86_400)]
                ).first?.first.flatMap { $0 }.flatMap(Double.init) ?? Date().timeIntervalSince1970
        }
        let rows = try await db.eventRows(
            """
            SELECT a.id, a.title, coalesce(a.description, ''), a.source, a.published_at, e.id
            FROM articles a
            LEFT JOIN event_members m ON m.article_id = a.id
            LEFT JOIN events e ON e.id = m.event_id AND e.merged_into IS NULL
            WHERE a.published_at >= ? AND a.published_at <= ? AND \(DatabaseEngine.visibleArticle)
            ORDER BY a.published_at, a.id;
            """, [.real(newest - 3 * 86_400), .real(newest)]
        ).compactMap { row -> LibraryRow? in
            guard let id = row[0], let title = row[1], let published = row[4].flatMap(Double.init) else { return nil }
            return LibraryRow(
                id: id, title: title, description: row[2] ?? "", source: row[3] ?? "",
                date: Date(timeIntervalSince1970: published), event: row[5])
        }
        return (rows, Date(timeIntervalSince1970: newest))
    }

    /// Candidate pairs for the library holdout (#579), as `holdout-candidates.csv` in the private directory: borderline
    /// decisions scored ≥ 0.6, singleton headlines sharing a specific anchor and a keyword with an event member within
    /// 36 h, and pairs of active events sharing two terms (one representative pair each). Each class is drawn in SHA-256
    /// order of the two ids, so a rerun draws the same pairs. Headlines travel with the rows; never written in the checkout.
    static func exportHoldoutCandidates(snapshot: String, outputDirectory: String) async throws -> Int {
        guard !StoryCorpus.isLiveLibrary(snapshot) else {
            throw StoryCorpus.Failure.invalid("Export from a copy of the library, never the live file")
        }
        let file = try StoryCorpus.privateDirectory(outputDirectory).appendingPathComponent("holdout-candidates.csv")
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func order(_ a: String, _ b: String) -> String {
            SHA256.hash(data: Data((a + b).utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let db = DatabaseEngine(path: snapshot)
        try await db.open()
        let (rows, _) = try await recentLibraryRows(db)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines = [
            "kind,article_id,other_article_id,evidence,source_a,title_a,published_a,source_b,title_b,published_b"
        ]
        var seen = Set<String>()
        func append(_ kind: String, _ a: LibraryRow, _ b: LibraryRow, _ evidence: String) {
            let (low, high) = a.id < b.id ? (a, b) : (b, a)
            guard seen.insert(low.id + "\n" + high.id).inserted else { return }
            lines.append(
                [
                    kind, low.id, high.id, evidence, quoted(low.source), quoted(low.title),
                    String(low.date.timeIntervalSince1970), quoted(high.source), quoted(high.title),
                    String(high.date.timeIntervalSince1970),
                ].joined(separator: ","))
        }
        // 1. Borderline decisions with a high score, the pairs the rules nearly matched.
        var borderline = try await db.eventRows(
            "SELECT article_id, other_article_id, score FROM pair_assessments WHERE decision = 'borderline' AND score >= 0.6;"
        ).compactMap { row -> (LibraryRow, LibraryRow, String)? in
            guard let a = row[0].flatMap({ byID[$0] }), let b = row[1].flatMap({ byID[$0] }) else { return nil }
            return (a, b, String(format: "borderline %.2f", Double(row[2] ?? "") ?? 0))
        }
        borderline.sort { order($0.0.id, $0.1.id) < order($1.0.id, $1.1.id) }
        for (a, b, evidence) in borderline.prefix(100) { append("borderline", a, b, evidence) }
        // 2. Singletons next to an event they share a specific anchor and a keyword with.
        let features = Dictionary(
            uniqueKeysWithValues: rows.map {
                ($0.id, EventFeatures(title: $0.title, description: $0.description, date: $0.date))
            })
        let members = rows.filter { $0.event != nil }
        var singles: [(LibraryRow, LibraryRow, String)] = []
        for single in rows where single.event == nil {
            guard let features1 = features[single.id] else { continue }
            var best: (LibraryRow, Int)?
            for member in members where abs(member.date.timeIntervalSince(single.date)) <= 36 * 3600 {
                guard let features2 = features[member.id],
                    !features1.specificAnchors.isDisjoint(with: features2.specificAnchors)
                else { continue }
                let shared = features1.keywords.intersection(features2.keywords).count
                if shared >= 1, shared > (best?.1 ?? 0) { best = (member, shared) }
            }
            if let best { singles.append((single, best.0, "singleton shares \(best.1) keywords")) }
        }
        singles.sort { order($0.0.id, $0.1.id) < order($1.0.id, $1.1.id) }
        for (a, b, evidence) in singles.prefix(60) { append("singleton", a, b, evidence) }
        // 3. Fragments: two active events sharing two terms, represented by their earliest members.
        let events = Dictionary(grouping: members) { $0.event ?? "" }
        let terms = events.mapValues { group in
            group.reduce(into: Set<String>()) { set, row in
                if let value = features[row.id] { set.formUnion(value.specificAnchors.union(value.keywords)) }
            }
        }
        var fragments: [(LibraryRow, LibraryRow, String)] = []
        let ids = events.keys.sorted()
        for (n, first) in ids.enumerated() {
            for second in ids[(n + 1)...] {
                let shared = (terms[first] ?? []).intersection(terms[second] ?? []).count
                guard shared >= 2, let a = events[first]?.min(by: { $0.date < $1.date }),
                    let b = events[second]?.min(by: { $0.date < $1.date }),
                    abs(a.date.timeIntervalSince(b.date)) <= 36 * 3600
                else { continue }
                fragments.append((a, b, "fragments share \(shared) terms"))
            }
        }
        fragments.sort { order($0.0.id, $0.1.id) < order($1.0.id, $1.1.id) }
        for (a, b, evidence) in fragments.prefix(60) { append("fragments", a, b, evidence) }
        await db.close()
        try StoryCorpus.writePrivate(Data(lines.joined(separator: "\n").utf8), to: file, replacing: false)
        return lines.count - 1
    }

    /// One clustering pass's stages (#691), in seconds; matching is what the fragment merge and story pass leave of the total.
    static func stageLine(_ stages: EventClusteringStages) -> String {
        func value(_ seconds: Double) -> String { String(format: "%.2f", seconds) }
        let matching = stages.total - stages.fragmentMerge - stages.storyPass
        return "total \(value(stages.total)) s = matching \(value(matching)) + fragment merge "
            + "\(value(stages.fragmentMerge)) + story pass \(value(stages.storyPass)); across them: features "
            + "\(value(stages.features)), embeddings \(value(stages.embeddings)) (\(stages.embeddedRows) rows), rules "
            + "\(value(stages.ruleAssessment)), pair model \(value(stages.pairModel)) (\(stages.pairModelCalls) calls), "
            + "writes \(value(stages.writes)), candidate search \(value(stages.candidateSearch)), event reads "
            + "\(value(stages.eventReads)), match commits \(value(stages.matchCommits))"
    }

    /// The admission verdict of a matched pair the clustering kept apart (#737, `NEWS_EVENT_DIAGNOSE=1`, local console
    /// only): each article's event, and whether the article would enter the other's event as that event stands now, with
    /// the rules that refuse it and the cross-pairs behind them. Assessed like the clusterer's own pass, so a verdict
    /// describes the final membership; the greedy pass may have refused against fewer members.
    static func printAdmissionVerdict(
        _ a: String, _ b: String, memberships: [String: String], in db: DatabaseEngine, policy: EventMatchPolicy,
        calibration: PairCalibration?, titles: [String: String]
    ) async throws {
        var eventMembers: [String: [EventMatchRow]] = [:]
        for id in [memberships[a], memberships[b]].compactMap({ $0 }) where eventMembers[id] == nil {
            eventMembers[id] = try await db.eventMatchMembers(eventID: id)?.members ?? []
        }
        let rows = try await db.eventMatchRows(articleIDs: [a, b])
        let everyRow = rows + eventMembers.values.flatMap { $0 }
        let ids = Array(Set(everyRow.map(\.id)))
        let stored = try await db.fetchArticleFeatures(articleIDs: ids, version: EventFeatures.storageVersion)
        let vectors = try await db.fetchArticleEmbeddings(articleIDs: ids, modelVersion: SentenceEmbedder.modelVersion)
        func features(_ row: EventMatchRow) -> EventFeatures {
            var value =
                stored[row.id] ?? EventFeatures(title: row.title, description: row.description, date: row.date)
            value.date = row.date
            return value
        }
        let probability =
            StoryCorpus.pairProbabilityFromEnvironment()
            ?? { @Sendable a, b in await PairScorer.shared.probability(a, b) }
        func assessed(_ a: EventMatchRow, _ b: EventMatchRow) async -> (pair: EventPairAssessment, model: Double?) {
            let cosine = vectors[a.id].flatMap { left in
                vectors[b.id].map { SentenceEmbedder.cosineSimilarity(left, $0) }
            }
            let samePublisher = !a.source.isEmpty && a.source == b.source
            var pair = EventMatcher.assess(
                features(a), features(b), policy: policy, embeddingSimilarity: cosine, samePublisher: samePublisher)
            var model: Double?
            if EventMatcher.needsPairModel(pair) {
                let gap: TimeInterval? = policy.pairModelPrefix ? abs(a.date.timeIntervalSince(b.date)) : nil
                let known = policy.pairModelPrefix && !a.source.isEmpty && !b.source.isEmpty
                model = await probability(
                    EventMatcher.pairModelText(
                        title: a.title, description: a.description, gap: gap,
                        samePublisher: known ? samePublisher : nil, policy: policy),
                    EventMatcher.pairModelText(
                        title: b.title, description: b.description, gap: gap,
                        samePublisher: known ? samePublisher : nil, policy: policy))
                let cutoff =
                    calibration?.cutoff(
                        policy.pairModelThreshold,
                        PairCalibration.features(
                            pairModel: model ?? 0, cosine: pair.embeddingCosine,
                            sharedSpecific: pair.sharedSpecificAnchors,
                            gapHours: abs(a.date.timeIntervalSince(b.date)) / 3600,
                            sameAct: pair.conflict != .differentAct)) ?? policy.pairModelThreshold
                if let model, model >= cutoff { pair = EventMatcher.modelConfirmed(pair, policy: policy) }
                pair = EventMatcher.applyingBorderlineFloor(pair, probability: model, policy: policy)
            }
            if policy.samePublisherRequiresMatch, !pair.isMatch, samePublisher { pair.isCompatible = false }
            if policy.editionAdmission {
                pair.rowIsEdition = EventMatcher.isNewsletterEdition(title: a.title)
                pair.memberIsEdition = EventMatcher.isNewsletterEdition(title: b.title)
            }
            return (pair, model)
        }
        for (label, id, other) in [("a", a, b), ("b", b, a)] {
            guard let row = rows.first(where: { $0.id == id }) else { continue }
            let event = memberships[id]
            let size = event.flatMap { eventMembers[$0]?.count } ?? 0
            print("        \(label) in \(event ?? "no event") (\(size) members)")
            guard let target = memberships[other], let members = eventMembers[target] else {
                print("        \(label) into the other's event: the other holds no event")
                continue
            }
            var assessments: [(member: EventMatchRow, pair: EventPairAssessment, model: Double?)] = []
            for member in members.sorted(by: { ($0.date, $0.id) < ($1.date, $1.id) }) {
                let (pair, model) = await assessed(row, member)
                assessments.append((member, pair, model))
            }
            let pairs = assessments.map(\.pair)
            let score = EventMatcher.eventScore(pairs: pairs, policy: policy)
            let failures = admissionFailures(pairs, policy: policy)
            print(
                "        \(label) into the other's event: "
                    + (score.map { "admitted, score \(String(format: "%.2f", $0))" }
                        ?? "refused: \(failures.joined(separator: "; "))"))
            // ponytail: the first twelve refusing cross-pairs; the counts above cover a larger event.
            let refusing = assessments.filter { !$0.pair.isCompatible || $0.pair.conflict != nil }
            for item in refusing.prefix(12) {
                let pair = item.pair
                print(
                    "          x \(titles[item.member.id] ?? item.member.id)\n"
                        + "            \(pair.conflict?.rawValue ?? "no conflict") match=\(pair.isMatch ? 1 : 0) "
                        + "compatible=\(pair.isCompatible ? 1 : 0) specific=\(pair.sharedSpecificAnchors) "
                        + "score=\(String(format: "%.2f", pair.score)) "
                        + "cosine=\(pair.embeddingCosine.map { String(format: "%.2f", $0) } ?? "-") "
                        + "model=\(item.model.map { String(format: "%.3f", $0) } ?? "-")")
            }
            if refusing.count > 12 { print("          … \(refusing.count - 12) more refusing cross-pairs") }
        }
    }

    /// The rules of `EventMatcher.eventScore(pairs:policy:)` a set of cross-pairs fails, in words.
    static func admissionFailures(_ allPairs: [EventPairAssessment], policy: EventMatchPolicy) -> [String] {
        var failures: [String] = []
        if allPairs.count >= policy.maximumEventSize { failures.append("event full") }
        let pairs = EventMatcher.admissionPairs(allPairs, policy: policy)
        if EventMatcher.conflictsBlock(pairs, policy: policy) {
            let conflicts = Dictionary(grouping: pairs.compactMap(\.conflict), by: \.rawValue).mapValues(\.count)
            let named = conflicts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            failures.append("veto \(pairs.filter { $0.conflict != nil }.count)/\(pairs.count) (\(named))")
        }
        let nameless = pairs.filter { $0.sharedSpecificAnchors < 1 && !$0.modelConfirmed }.count
        if nameless > 0 { failures.append("no shared name \(nameless)/\(pairs.count)") }
        if !pairs.contains(where: \.isMatch) { failures.append("no matched pair") }
        let required = Int((Double(pairs.count) * policy.compatibleShare).rounded(.up))
        let compatible = pairs.filter(\.isCompatible).count
        if compatible < required { failures.append("two-thirds \(compatible)/\(pairs.count), needs \(required)") }
        let mean = pairs.isEmpty ? 0 : pairs.map(\.score).reduce(0, +) / Double(pairs.count)
        if mean < policy.eventScore {
            failures.append("mean \(String(format: "%.2f", mean)) below \(policy.eventScore)")
        }
        return failures
    }

    /// The matcher's signals for each labelled pair of a library copy (#737): `NEWS_LIBRARY_HOLDOUT` is the pair file
    /// `--library-holdout` reads. Writes `pair-signals.csv` (ids, label and numbers, no text) to `NEWS_EVENT_OUTPUT`: the
    /// rule assessment as clustering computes it, the cosine, the time gap, and whether either report finds the other
    /// in its candidate search. Nothing is clustered and the copy's events are not read
    /// (docs/audits/2026-11-09-evidence-head.md).
    static func exportPairSignals(snapshot: String, pairs: String, output: String) async throws {
        guard !StoryCorpus.isLiveLibrary(snapshot) else {
            throw StoryCorpus.Failure.invalid("Export from a copy of the library, never the live file")
        }
        struct Pair: Decodable {
            let a: String, b: String, label: String
        }
        let labelled = try JSONDecoder().decode([Pair].self, from: Data(contentsOf: URL(fileURLWithPath: pairs)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("library.sqlite3").path
        try StoryCorpus.writableCopy(of: snapshot, to: copy)
        let db = DatabaseEngine(path: copy)
        try await db.open()
        let ids = Array(Set(labelled.flatMap { [$0.a, $0.b] }))
        let rows = Dictionary(
            try await db.eventMatchRows(articleIDs: ids).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var vectors = try await db.fetchArticleEmbeddings(articleIDs: ids, modelVersion: SentenceEmbedder.modelVersion)
        let missing = ids.compactMap { rows[$0] }.filter { vectors[$0.id] == nil }
        let computed = await SentenceEmbedder.shared.embedBatch(
            missing.map { EventFeatures.matchingText(title: $0.title, description: $0.description) })
        for (row, vector) in zip(missing, computed) { vectors[row.id] = vector }
        let policy = StoryCorpus.policyFromEnvironment()
        var features: [String: EventFeatures] = [:]
        func signals(_ row: EventMatchRow) -> EventFeatures {
            if let known = features[row.id] { return known }
            let value = EventFeatures(title: row.title, description: row.description, date: row.date)
            features[row.id] = value
            return value
        }
        func finds(_ row: EventMatchRow, _ other: EventMatchRow) async throws -> Bool {
            let probe = FeedArticle(
                storedID: row.id, title: row.title, link: "", guid: nil, description: row.description,
                pubDate: row.date, source: row.source)
            let now = max(row.date, other.date).addingTimeInterval(3600)
            return try await EventCandidateFinder.candidates(for: probe, in: db, now: now).contains {
                $0.articleID == other.id
            }
        }
        var lines = [
            "a,b,label,gap_hours,same_publisher,cosine,conflict,rule_match,borderline,compatible,shared_anchors,"
                + "shared_specific,shared_keywords,what,entity,candidate"
        ]
        for pair in labelled {
            guard let a = rows[pair.a], let b = rows[pair.b] else { continue }
            let cosine = vectors[a.id].flatMap { left in
                vectors[b.id].map { SentenceEmbedder.cosineSimilarity(left, $0) }
            }
            let samePublisher = !a.source.isEmpty && a.source == b.source
            let assessed = EventMatcher.assess(
                signals(a), signals(b), policy: policy, embeddingSimilarity: cosine, samePublisher: samePublisher)
            var candidate = try await finds(a, b)
            if !candidate { candidate = try await finds(b, a) }
            let fields: [String] = [
                "\"\(a.id)\"", "\"\(b.id)\"", pair.label,
                String(format: "%.2f", abs(a.date.timeIntervalSince(b.date)) / 3600), samePublisher ? "1" : "0",
                cosine.map { String(format: "%.4f", $0) } ?? "", assessed.conflict?.rawValue ?? "",
                assessed.isMatch ? "1" : "0", assessed.isBorderline ? "1" : "0", assessed.isCompatible ? "1" : "0",
                String(assessed.sharedAnchors), String(assessed.sharedSpecificAnchors), String(assessed.sharedKeywords),
                String(format: "%.4f", assessed.what), String(format: "%.4f", assessed.entity), candidate ? "1" : "0",
            ]
            lines.append(fields.joined(separator: ","))
        }
        await db.close()
        try StoryCorpus.writePrivate(
            Data(lines.joined(separator: "\n").utf8),
            to: try StoryCorpus.privateDirectory(output).appendingPathComponent("pair-signals.csv"), replacing: false)
        print("    pair signals: \(lines.count - 1) of \(labelled.count) pairs written")
    }

    /// The library holdout (#579): `NEWS_LIBRARY_HOLDOUT` is a JSON array of `{"a", "b", "label"}` with article ids of
    /// `NEWS_SNAPSHOT_DB` and labels `same`, `related` or `different`. A temporary copy of the library is re-clustered
    /// from scratch inside the active window (events, memberships, match state, pair decisions and corrections removed;
    /// stored signals and vectors kept), then every labelled pair is scored twice (#627): strict event (both stories in
    /// one event; `same` is a true pair, `related` or `different` a false one, `different` also counted alone) and story
    /// level (both stories' events in one `story_id`; `same` and `related` are true pairs, only `different` is a false
    /// merge). Also prints the share of recent stories shown in a multi-publisher event. The copy is deleted afterwards.
    static func evaluateLibraryHoldout(snapshot: String, holdout: String) async throws {
        guard !StoryCorpus.isLiveLibrary(snapshot) else {
            throw StoryCorpus.Failure.invalid("Evaluate on a copy of the library, never the live file")
        }
        struct Pair: Decodable {
            let a: String, b: String, label: String
        }
        let pairs = try JSONDecoder().decode([Pair].self, from: Data(contentsOf: URL(fileURLWithPath: holdout)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("library.sqlite3").path
        try StoryCorpus.writableCopy(of: snapshot, to: copy)
        let db = DatabaseEngine(path: copy)
        try await db.open()
        // The reader's verdicts (#552) are read before the corrections are cleared: the matcher alone must keep every
        // "Same Event" pair together and every "Not the Same Event" pair apart, or the change fails the gate.
        let verdicts = try await db.eventRows(
            """
            SELECT article_id, other_article_id, 1 FROM event_inclusions
            UNION ALL SELECT article_id, other_article_id, 0 FROM event_exclusions;
            """
        ).compactMap { row -> (a: String, b: String, same: Bool)? in
            guard let a = row[0], let b = row[1] else { return nil }
            return (a, b, row[2] == "1")
        }
        // The calibration the app would apply (#629) is read before the verdicts and pair decisions are cleared and
        // handed to every pass, so the holdout measures the cutoff production uses.
        let calibrationRows = try await db.calibrationRows()
        for table in [
            "event_overview_citations", "event_overviews", "event_state", "event_members", "event_match_state",
            "pair_assessments", "event_exclusions", "event_inclusions", "events",
        ] {
            try await db.eventRows("DELETE FROM \(table);")
        }
        // NEWS_HOLDOUT_COLD=1 (#691) also drops the stored signals and vectors, as a clear or a version bump of them does.
        if ProcessInfo.processInfo.environment["NEWS_HOLDOUT_COLD"] == "1" {
            for table in ["article_features", "article_embeddings"] { try await db.eventRows("DELETE FROM \(table);") }
        }
        // NEWS_HOLDOUT_NOW=<epoch> pins the clock to when the holdout was drawn, for a copy taken later (#688).
        let pinned = ProcessInfo.processInfo.environment["NEWS_HOLDOUT_NOW"].flatMap { TimeInterval($0) }
            .map { Date(timeIntervalSince1970: $0) }
        let newest = try await recentLibraryRows(db, now: pinned).newest
        let policy = StoryCorpus.policyFromEnvironment()
        let modelOff = ProcessInfo.processInfo.environment["NEWS_PAIR_MODEL"] == "0"
        let candidate = ProcessInfo.processInfo.environment["NEWS_PAIR_MODEL_PATH"]
        let started = Date()
        var passes = 0
        var total = EventClusteringReport()
        repeat {
            let report = try await EventClusterer.run(
                in: db, matchPolicy: policy, now: newest, allowsEnergy: true,
                scoring: EventClusterScoring(
                    pairProbability: StoryCorpus.pairProbabilityFromEnvironment(),
                    storyProbabilities: StoryCorpus.storyProbabilitiesFromEnvironment(),
                    calibrationRows: calibrationRows))
            passes += 1
            total.processed += report.processed
            total.joined += report.joined
            total.created += report.created
            total.merged += report.merged
            total.stages.add(report.stages)
            print("    pass \(passes): processed \(report.processed), \(stageLine(report.stages))")
            if report.processed == 0 || passes >= 20 { break }
        } while true
        let elapsed = Date().timeIntervalSince(started)
        print("    stages: \(stageLine(total.stages))")
        let memberships = try await db.eventIDs(
            forArticles: pairs.flatMap { [$0.a, $0.b] } + verdicts.flatMap { [$0.a, $0.b] })
        var verdictFailures: [String] = []
        for verdict in verdicts {
            let linked = memberships[verdict.a] != nil && memberships[verdict.a] == memberships[verdict.b]
            if linked != verdict.same {
                verdictFailures.append(
                    "\(verdict.same ? "inclusion separated" : "exclusion re-merged"): \(verdict.a) + \(verdict.b)")
            }
        }
        var storyOf: [String: String] = [:]
        for row in try await db.eventRows("SELECT id, coalesce(story_id, id) FROM events WHERE merged_into IS NULL;") {
            if let id = row[0], let story = row[1] { storyOf[id] = story }
        }
        var truePairs = 0
        var falsePairs = 0
        var missed = 0
        var keptApart = 0
        var byLabel: [String: (linked: Int, total: Int)] = [:]
        var inStory: [String: (linked: Int, total: Int)] = [:]
        // NEWS_EVENT_DIAGNOSE=1 names the misses and the wrong links with their headlines (local console only).
        let diagnose = ProcessInfo.processInfo.environment["NEWS_EVENT_DIAGNOSE"] == "1"
        var titles: [String: String] = [:]
        if diagnose {
            for row in try await db.eventRows("SELECT id, source || ': ' || title FROM articles;") {
                if let id = row[0] { titles[id] = row[1] ?? "" }
            }
        }
        for (pairNumber, pair) in pairs.enumerated() {
            let linked = memberships[pair.a] != nil && memberships[pair.a] == memberships[pair.b]
            byLabel[pair.label, default: (0, 0)].total += 1
            if linked { byLabel[pair.label, default: (0, 0)].linked += 1 }
            let story = memberships[pair.a].map { storyOf[$0] ?? $0 }
            let storyLinked = story != nil && story == memberships[pair.b].map { storyOf[$0] ?? $0 }
            inStory[pair.label, default: (0, 0)].total += 1
            if storyLinked { inStory[pair.label, default: (0, 0)].linked += 1 }
            switch (pair.label == "same", linked) {
            case (true, true): truePairs += 1
            case (true, false): missed += 1
            case (false, true): falsePairs += 1
            case (false, false): keptApart += 1
            }
            if diagnose, storyLinked, !linked, pair.label == "different" {
                print("      WRONG STORY [different] \(titles[pair.a] ?? pair.a) || \(titles[pair.b] ?? pair.b)")
            }
            if diagnose, (pair.label == "same") != linked {
                let (low, high) = pair.a < pair.b ? (pair.a, pair.b) : (pair.b, pair.a)
                let decision = try await db.eventRows(
                    "SELECT decision, reason, coalesce(features, '') FROM pair_assessments WHERE article_id = ? AND other_article_id = ?;",
                    [.text(low), .text(high)]
                ).first
                print(
                    "      \(linked ? "WRONG LINK" : "MISSED") [\(pair.label)] \(titles[pair.a] ?? pair.a) || "
                        + "\(titles[pair.b] ?? pair.b)\n        decision \(decision?[0] ?? "none") \(decision?[1] ?? "") "
                        + "\(decision?[2] ?? "")")
                if !linked, decision?[0] == "match" {
                    print("        pair \(pairNumber) a \(pair.a) b \(pair.b)")
                    try await printAdmissionVerdict(
                        pair.a, pair.b, memberships: memberships, in: db, policy: policy,
                        calibration: PairCalibration.fit(calibrationRows), titles: titles)
                }
            }
        }
        let precision = truePairs + falsePairs == 0 ? 0 : Double(truePairs) / Double(truePairs + falsePairs)
        let recall = truePairs + missed == 0 ? 0 : Double(truePairs) / Double(truePairs + missed)
        // Story-level view: recent stories shown in an event with two or more publishers, and in a story (#581).
        let recent = try await recentLibraryRows(db, now: newest).rows
        let sources = Dictionary(grouping: recent.filter { $0.event != nil }) { $0.event ?? "" }
            .mapValues { Set($0.map(\.source)).count }
        let multi = recent.filter { ($0.event.flatMap { sources[$0] } ?? 0) >= 2 }.count
        let byStory = Dictionary(grouping: recent.filter { $0.event != nil }) { storyOf[$0.event ?? ""] ?? "" }
        let storySources = byStory.mapValues { Set($0.map(\.source)).count }
        let multiStory = recent.filter { ($0.event.flatMap { storySources[storyOf[$0] ?? ""] } ?? 0) >= 2 }.count
        // Events per story over every event, not only those with reports in the audit window.
        let eventsOf = Dictionary(grouping: storyOf.keys) { storyOf[$0] ?? "" }.mapValues(\.count)
        let joinedStories = byStory.filter { (eventsOf[$0.key] ?? 0) >= 2 }
        // The feed's cards: one per story, one per report no story holds (#581).
        func card(_ row: LibraryRow) -> String { row.event.map { storyOf[$0] ?? $0 } ?? row.id }
        let cards = Set(recent.map(card)).count
        if let output = ProcessInfo.processInfo.environment["NEWS_EVENT_OUTPUT"] {
            // Every report of the clusterer's window (72 h before its clock, NEWS_HOLDOUT_NOW when set) with its card, for
            // card counts and named cases (#581).
            let windowRows = try await db.eventRows(
                """
                SELECT a.id, a.source, a.published_at, m.event_id, a.title,
                    (SELECT count(*) FROM event_members x WHERE x.event_id = m.event_id)
                FROM articles a LEFT JOIN event_members m ON m.article_id = a.id
                WHERE a.published_at >= ? AND a.published_at <= ? AND \(DatabaseEngine.visibleArticle)
                ORDER BY a.published_at, a.id;
                """, [.real(newest.timeIntervalSince1970 - 3 * 86_400), .real(newest.timeIntervalSince1970)])
            let cardLines =
                ["card,article,source,published,event,event_size,title"]
                + windowRows.map { row in
                    let card = row[3].map { storyOf[$0] ?? $0 } ?? row[0] ?? ""
                    // Every field is quoted: ids and sources are free text ("Example, Inc.").
                    func quoted(_ value: String?) -> String {
                        "\"" + (value ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    }
                    return ([card, row[0], row[1], row[2], row[3], row[5], row[4]].map(quoted)).joined(separator: ",")
                }
            try StoryCorpus.writePrivate(
                Data(cardLines.joined(separator: "\n").utf8),
                to: try StoryCorpus.privateDirectory(output).appendingPathComponent("story-cards.csv"),
                replacing: false)
            // One line per story that joins two or more events: each event's earliest headline within the window,
            // for the group review.
            // Countries named in headlines (#737): a story whose events name disjoint countries ("Jordan" beside "US")
            // is flagged cross_country for the review; so is an event whose reports do.
            func headlineCountries(_ rows: [LibraryRow]) -> Set<String> {
                rows.reduce(into: Set<String>()) {
                    $0.formUnion(EventFeatures(title: $1.title, description: "", date: $1.date).countries)
                }
            }
            func disjointCountries(_ sets: [Set<String>]) -> Bool {
                let named = sets.filter { !$0.isEmpty }
                return named.indices.contains { i in named.indices.contains { j in named[i].isDisjoint(with: named[j]) }
                }
            }
            var crossCountryStories = 0
            var lines = ["story_id,events,recent_members,cross_country,countries,recent_acts"]
            for (story, rows) in joinedStories.sorted(by: { $0.key < $1.key }) {
                let groups = Dictionary(grouping: rows) { $0.event ?? "" }.values
                let acts =
                    groups
                    .compactMap { group in
                        group.min(by: { $0.date < $1.date }).map { "\(group.count)× \($0.source): \($0.title)" }
                    }
                    .sorted()
                let countrySets = groups.map { headlineCountries($0) }
                let cross = disjointCountries(countrySets)
                if cross { crossCountryStories += 1 }
                let countries: String = countrySets.map { $0.sorted().joined(separator: " ") }.sorted()
                    .joined(separator: " | ")
                let headlines: String = acts.joined(separator: " || ").replacingOccurrences(of: "\"", with: "\"\"")
                let fields: [String] = [
                    story, String(eventsOf[story] ?? acts.count), String(rows.count), cross ? "yes" : "no",
                    "\"\(countries)\"", "\"\(headlines)\"",
                ]
                lines.append(fields.joined(separator: ","))
            }
            let crossCountryEvents = Dictionary(grouping: recent.filter { $0.event != nil }) { $0.event ?? "" }.values
                .filter { group in disjointCountries(group.map { headlineCountries([$0]) }) }
            print(
                "    cross-country (headline countries disjoint): \(crossCountryStories) of \(joinedStories.count) story groups, "
                    + "\(crossCountryEvents.count) events")
            var eventLines = ["event,reports,countries,headlines"]
            for group in crossCountryEvents {
                eventLines.append(
                    [
                        group.first?.event ?? "", String(group.count),
                        "\""
                            + group.map { headlineCountries([$0]).sorted().joined(separator: " ") }.joined(
                                separator: " | ") + "\"",
                        "\""
                            + group.map { "\($0.source): \($0.title)" }.joined(separator: " || ")
                            .replacingOccurrences(of: "\"", with: "\"\"") + "\"",
                    ].joined(separator: ","))
            }
            try StoryCorpus.writePrivate(
                Data(eventLines.joined(separator: "\n").utf8),
                to: try StoryCorpus.privateDirectory(output).appendingPathComponent("cross-country-events.csv"),
                replacing: false)
            try StoryCorpus.writePrivate(
                Data(lines.joined(separator: "\n").utf8),
                to: try StoryCorpus.privateDirectory(output).appendingPathComponent("story-groups.csv"),
                replacing: false)
        }
        await db.close()
        print(
            String(
                format:
                    "    stories: %d (%.0f%%) recent stories in a multi-publisher story; %d stories join two or more events",
                multiStory, recent.isEmpty ? 0 : 100 * Double(multiStory) / Double(recent.count), joinedStories.count))
        print("    cards: \(cards) for \(recent.count) recent stories (one per story, one per report no story holds)")
        if !verdicts.isEmpty {
            print("    verdicts (#552): \(verdicts.count) in the copy, \(verdictFailures.count) violated")
            for failure in verdictFailures { print("      \(failure)") }
        }
        print(
            String(
                format:
                    "    library holdout: %d pairs, precision %.3f (TP %d, FP %d), recall %.3f (FN %d), kept apart %d",
                pairs.count, precision, truePairs, falsePairs, recall, missed, keptApart))
        for (label, counts) in byLabel.sorted(by: { $0.key < $1.key }) {
            print("      \(label): \(counts.linked) of \(counts.total) linked")
        }
        // The dual gate (#627): strict event and story level, the counts the gate compares.
        let same = byLabel["same"] ?? (0, 0)
        let related = byLabel["related"] ?? (0, 0)
        let different = byLabel["different"] ?? (0, 0)
        let linkedPairs = same.linked + related.linked + different.linked
        print(
            String(
                format: "    strict event: %d linked = %d same, %d related, %d different; precision %.3f, "
                    + "recall %.3f (%d of %d same)",
                linkedPairs, same.linked, related.linked, different.linked,
                linkedPairs == 0 ? 0 : Double(same.linked) / Double(linkedPairs),
                same.total == 0 ? 0 : Double(same.linked) / Double(same.total), same.linked, same.total))
        let storyTrue = (inStory["same"]?.linked ?? 0) + (inStory["related"]?.linked ?? 0)
        let storyFalse = inStory["different"]?.linked ?? 0
        let storyTotal = (inStory["same"]?.total ?? 0) + (inStory["related"]?.total ?? 0)
        print(
            String(
                format: "    story level: %d in one story = %d same or related (%d same, %d related), %d different; "
                    + "precision %.3f, recall %.3f (%d of %d same or related)",
                storyTrue + storyFalse, storyTrue, inStory["same"]?.linked ?? 0, inStory["related"]?.linked ?? 0,
                storyFalse, storyTrue + storyFalse == 0 ? 0 : Double(storyTrue) / Double(storyTrue + storyFalse),
                storyTotal == 0 ? 0 : Double(storyTrue) / Double(storyTotal), storyTrue, storyTotal))
        print(
            String(
                format: "    library: %d recent stories, %d (%.0f%%) in a multi-publisher event; %d passes, "
                    + "processed %d, joined %d, created %d, merged %d, %.1f s; matcher v%d, pair cutoff %.2f%@",
                recent.count, multi, recent.isEmpty ? 0 : 100 * Double(multi) / Double(recent.count), passes,
                total.processed, total.joined, total.created, total.merged, elapsed, EventMatcher.version,
                policy.pairModelThreshold,
                modelOff ? ", pair model off" : (candidate.map { ", pair model \($0)" } ?? "")))
        guard verdictFailures.isEmpty else {
            throw StoryCorpus.Failure.invalid("\(verdictFailures.count) reader verdicts violated (#552)")
        }
    }

    /// Opt-in, local: times one fragment-merge pass (`limit: 0`) over a temporary copy of `NEWS_SNAPSHOT_DB`, with
    /// `now` at the newest event, and prints the merge count (#541, #582). The copy is deleted afterwards; a file
    /// inside an app container is refused, so the live library is never opened.
    static func timeFragmentMerge() async throws {
        guard let snapshot = ProcessInfo.processInfo.environment["NEWS_SNAPSHOT_DB"] else {
            throw StoryCorpus.Failure.invalid("--fragment-merge-timing needs NEWS_SNAPSHOT_DB")
        }
        guard !StoryCorpus.isLiveLibrary(snapshot) else {
            throw StoryCorpus.Failure.invalid("Measure on a copy of the library, never the live file")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("library.sqlite3").path
        try StoryCorpus.writableCopy(of: snapshot, to: copy)
        let db = DatabaseEngine(path: copy)
        try await db.open()
        let newest =
            try await db.eventRows("SELECT max(updated_at) FROM events WHERE merged_into IS NULL;").first?.first
            .flatMap { $0 }.flatMap(Double.init) ?? Date().timeIntervalSince1970
        let active = try await db.activeEventMembers(
            since: Date(timeIntervalSince1970: newest - EventCandidatePolicy.standard.activeEventLifetime))
        let started = Date()
        let report = try await EventClusterer.run(in: db, now: Date(timeIntervalSince1970: newest), limit: 0)
        let elapsed = Date().timeIntervalSince(started)
        await db.close()
        print(
            String(
                format: "    fragment merge: %d active events, %d members, %d merged in %.2f s",
                active.count, active.reduce(0) { $0 + $1.members.count }, report.merged, elapsed))
    }

    /// One CSV row per pair within the candidate window that shares an anchor or a keyword, or a gold event: the
    /// matcher's pair features, the act classes and the labels, for the offline fit of the decision head (#524). Pairs
    /// without a specific anchor are kept, so the fit can measure that gate. Corpus ids only; no publisher text.
    /// Requires `NEWS_EVENT_OUTPUT` and refuses to overwrite.
    struct PairExportItem {
        let id: String
        let title: String
        let description: String
        let published: Date
        let event: String?
        var source = ""
    }

    static func exportPairFeatures(
        items: [PairExportItem], predicted: [String?], split: String, outputDirectory: String?
    ) async throws -> Int {
        guard let outputDirectory else {
            throw StoryCorpus.Failure.invalid("--export-features needs NEWS_EVENT_OUTPUT")
        }
        let file = try StoryCorpus.privateDirectory(outputDirectory)
            .appendingPathComponent("pair-features-\(split).csv")
        let extracted = items.map { EventFeatures(title: $0.title, description: $0.description, date: $0.published) }
        var vectors: [[Float]?] = Array(repeating: nil, count: items.count)
        if await SentenceEmbedder.shared.isAvailable {
            vectors = await SentenceEmbedder.shared.embedBatch(
                items.map { EventFeatures.matchingText(title: $0.title, description: $0.description) })
        }
        var lines = [
            "id_a,id_b,label,predicted_same,gap_hours,what,entity,shared_anchors,shared_specific,shared_keywords,"
                + "toll_agree,number_agree,cosine,act_a,act_b,conflict,is_match,is_borderline"
        ]
        for i in items.indices {
            for j in items.indices where j > i {
                let a = extracted[i]
                let b = extracted[j]
                let gap = abs(a.date.timeIntervalSince(b.date))
                guard gap <= EventCandidatePolicy.standard.window else { continue }
                var cosine: Double? = nil
                if let left = vectors[i], let right = vectors[j] {
                    cosine = SentenceEmbedder.cosineSimilarity(left, right)
                }
                // The clusterer's publisher identity, so edition conflicts and series evidence match it (#688).
                let pair = EventMatcher.assess(
                    a, b, embeddingSimilarity: cosine,
                    samePublisher: !items[i].source.isEmpty && items[i].source == items[j].source)
                let gold = items[i].event != nil && items[i].event == items[j].event
                guard gold || pair.sharedAnchors + pair.sharedKeywords >= 1 else { continue }
                let same = predicted[i] != nil && predicted[i] == predicted[j]
                let tollAgree = !a.tollNumbers.isDisjoint(with: b.tollNumbers)
                let numberAgree = !a.titleNumbers.isDisjoint(with: b.titleNumbers)
                lines.append(
                    [
                        items[i].id, items[j].id, gold ? "1" : "0", same ? "1" : "0",
                        String(format: "%.2f", gap / 3600), String(format: "%.4f", pair.what),
                        String(format: "%.4f", pair.entity), String(pair.sharedAnchors),
                        String(pair.sharedSpecificAnchors), String(pair.sharedKeywords), tollAgree ? "1" : "0",
                        numberAgree ? "1" : "0", cosine.map { String(format: "%.4f", $0) } ?? "",
                        a.actClass.rawValue, b.actClass.rawValue, pair.conflict?.rawValue ?? "",
                        pair.isMatch ? "1" : "0", pair.isBorderline ? "1" : "0",
                    ].joined(separator: ","))
            }
        }
        try StoryCorpus.writePrivate(Data(lines.joined(separator: "\n").utf8), to: file, replacing: false)
        return lines.count - 1
    }

    /// Re-clusters a copy of a library from scratch at the current matcher, in the order the stories arrived (#627), so
    /// its events and stories (`story_id`) are the ones this build would make: events, memberships, match state and
    /// pair decisions are cleared, and a clock walks the publication dates in 6 h steps. The copy starts without
    /// articles; each step inserts the stories published by it, with their rows in every table that references them
    /// (corrections once both reports are in), and clusters at that time, so no candidate is a story from after the
    /// clock. Returns the copy, made in `directory`.
    static func reclusteredLibraryCopy(_ path: String, in directory: URL) async throws -> String {
        let copy = directory.appendingPathComponent(UUID().uuidString + ".sqlite3").path
        let source = directory.appendingPathComponent(UUID().uuidString + "-source.sqlite3").path
        try StoryCorpus.writableCopy(of: path, to: copy)
        try StoryCorpus.writableCopy(of: path, to: source)
        // The source is migrated like the copy, so both have the same columns for the row copies below.
        let migrated = DatabaseEngine(path: source)
        try await migrated.open()
        await migrated.close()
        let db = DatabaseEngine(path: copy)
        try await db.open()
        for table in [
            "event_overview_citations", "event_overviews", "event_state", "event_members", "event_match_state",
            "pair_assessments", "events",
        ] {
            try await db.eventRows("DELETE FROM \(table);")
        }
        let date = DatabaseEngine.articleDateOrder
        // Every table that references an article, with its referencing columns; FTS rows follow the articles'
        // triggers, new stories get no match state, so each step's stories are pending, and pair decisions and
        // memberships are this build's own, never the source's.
        var dependents: [(table: String, columns: [String])] = []
        for row in try await db.eventRows(
            """
            SELECT m.name, group_concat(f."from") FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) f
            WHERE m.type = 'table' AND f."table" = 'articles' GROUP BY m.name ORDER BY m.name;
            """)
        {
            guard let table = row[0], let columns = row[1],
                ![
                    "article_fts_rows", "event_match_state", "event_members", "event_overview_citations",
                    "pair_assessments",
                ].contains(table)
            else { continue }
            dependents.append((table, columns.split(separator: ",").map(String.init)))
        }
        for dependent in dependents { try await db.eventRows("DELETE FROM \(dependent.table);") }
        try await db.eventRows("DELETE FROM articles;")
        try await db.eventRows("ATTACH DATABASE ? AS src;", [.text(source)])
        let dates = try await db.eventRows("SELECT DISTINCT \(date) FROM src.articles a ORDER BY 1;")
            .compactMap { $0.first.flatMap { $0 }.flatMap(Double.init) }
        let policy = StoryCorpus.policyFromEnvironment()
        var total = EventClusteringReport()
        var steps = 0
        var previous = -Double.infinity
        var index = 0
        while index < dates.count {
            let clock = max(dates[index], previous + 6 * 3600)
            let arriving = "SELECT id FROM src.articles a WHERE \(date) > ? AND \(date) <= ?"
            try await db.eventRows(
                "INSERT INTO articles SELECT * FROM src.articles a WHERE \(date) > ? AND \(date) <= ?;",
                [.real(previous), .real(clock)])
            // A row joins once every report it names is in and one of them arrives now.
            for dependent in dependents {
                let present = dependent.columns.map { "(\($0) IS NULL OR \($0) IN (SELECT id FROM main.articles))" }
                let new = dependent.columns.map { "\($0) IN (\(arriving))" }
                try await db.eventRows(
                    "INSERT OR IGNORE INTO main.\(dependent.table) SELECT * FROM src.\(dependent.table) WHERE "
                        + present.joined(separator: " AND ") + " AND (" + new.joined(separator: " OR ") + ");",
                    Array(repeating: [DatabaseEngine.EventValue.real(previous), .real(clock)], count: new.count)
                        .flatMap { $0 })
            }
            var passes = 0
            repeat {
                let report = try await EventClusterer.run(
                    in: db, matchPolicy: policy, now: Date(timeIntervalSince1970: clock), allowsEnergy: true,
                    scoring: EventClusterScoring(
                        pairProbability: StoryCorpus.pairProbabilityFromEnvironment(),
                        storyProbabilities: StoryCorpus.storyProbabilitiesFromEnvironment()))
                total.processed += report.processed
                total.created += report.created
                total.merged += report.merged
                passes += 1
                if report.processed == 0 || passes >= 20 { break }
            } while true
            steps += 1
            previous = clock
            while index < dates.count, dates[index] <= clock { index += 1 }
        }
        let stories = try await db.eventRows(
            "SELECT count(DISTINCT coalesce(story_id, id)), count(*) FROM events WHERE merged_into IS NULL;"
        ).first
        try await db.eventRows("DETACH DATABASE src;")
        await db.close()
        try? FileManager.default.removeItem(atPath: source)
        print(
            "    re-clustered \(URL(fileURLWithPath: path).lastPathComponent) at matcher v\(EventMatcher.version): "
                + "\(steps) steps, processed \(total.processed), created \(total.created), merged \(total.merged); "
                + "\(stories?[1] ?? "0") events in \(stories?[0] ?? "0") stories")
        return copy
    }

    /// Writes a sample of stored stories for the topic-classifier audit (#546) to `NEWS_EVENT_OUTPUT/categories.csv`:
    /// id, headline, summary, publisher, the publisher's own category, the category the deterministic classifier
    /// assigns now and the one stored in the library. `NEWS_SNAPSHOT_DB` is a library copy (a file inside an app
    /// container is refused). `NEWS_CATEGORY_SAMPLE` sets the size (default 200) and `NEWS_CATEGORY_SEED` the fixed
    /// pseudo-random order, so the same sample is drawn before and after a rule change; `NEWS_CATEGORY_IDS`, a file
    /// with one story id per line, exports exactly those stories instead, whatever their age. The file carries
    /// headlines, so it goes to the private directory only and is never overwritten; labels are kept beside it, never
    /// in the repository.
    static func exportCategorySample() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let snapshot = environment["NEWS_SNAPSHOT_DB"], let output = environment["NEWS_EVENT_OUTPUT"] else {
            throw StoryCorpus.Failure.invalid("--export-categories needs NEWS_SNAPSHOT_DB and NEWS_EVENT_OUTPUT")
        }
        guard !StoryCorpus.isLiveLibrary(snapshot) else {
            throw StoryCorpus.Failure.invalid("Export from a copy of the library, never the live file")
        }
        let size = Int(environment["NEWS_CATEGORY_SAMPLE"] ?? "") ?? 200
        let seed = environment["NEWS_CATEGORY_SEED"] ?? "546"
        let wanted = try environment["NEWS_CATEGORY_IDS"].map {
            try String(contentsOfFile: $0, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        }
        let file = try StoryCorpus.privateDirectory(output).appendingPathComponent("categories.csv")
        let db = DatabaseEngine(path: snapshot)
        try await db.open()
        let rows = try await db.eventRows(
            """
            SELECT a.id, a.title, coalesce(a.description, ''), a.source, coalesce(a.category, ''), a.content,
                coalesce(e.category, '')
            FROM articles a LEFT JOIN article_enrichment e ON e.article_id = a.id
            WHERE a.published_at >= ? ORDER BY a.id;
            """,
            // A listed sample is exported whatever its age, so it can be measured again on a later day.
            [.real(wanted == nil ? Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970 : 0)])
        await db.close()
        // A fixed pseudo-random order (FNV-1a of the seed and the id), then the first `size` rows.
        func order(_ id: String) -> UInt64 {
            (seed + id).utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let selected: [[String?]]
        if let wanted {
            let byID = Dictionary(rows.compactMap { row in row[0].map { ($0, row) } }, uniquingKeysWith: { a, _ in a })
            selected = wanted.compactMap { byID[$0] }
        } else {
            selected = Array(rows.sorted { order($0[0] ?? "") < order($1[0] ?? "") }.prefix(size))
        }
        var lines = ["id,title,summary,publisher,publisher_category,assigned,stored"]
        for row in selected {
            let title = row[1] ?? ""
            let description = row[2] ?? ""
            let assigned =
                NaturalLanguageTopicClassifier.classifyContent(title: title, description: description, text: row[5])?
                .category ?? NewsCategory.world.rawValue
            lines.append(
                [row[0] ?? "", title, description, row[3] ?? "", row[4] ?? "", assigned, row[6] ?? ""].map(quoted)
                    .joined(separator: ","))
        }
        try StoryCorpus.writePrivate(Data(lines.joined(separator: "\n").utf8), to: file, replacing: false)
        print(
            "    exported \(selected.count) of \(rows.count) stories \(wanted == nil ? "from the last 14 days" : "listed") for the category audit (#546)"
        )
    }

    /// Mines labelled pairs for the pair model (#525) from copies of real libraries into `NEWS_EVENT_OUTPUT/pairs.csv`.
    /// `NEWS_SNAPSHOT_DB` lists the copies, colon-separated; a file inside an app container is refused, so the live
    /// library is never opened. Rows follow the three-way contract of `script/training/train_pair_model.py` (#627):
    /// `label` 0 different, 1 related, 2 same; `marginal` empty, or the classes whose summed probability is the target.
    /// Each copy is first re-clustered from scratch by this build (`reclusteredLibraryCopy`), so events and stories
    /// are current. Positives (2): two English reports from different publishers in one event that the current rules
    /// match directly, unless the recorded decision was the pair model's alone (#627: 21% of those were false in the #551
    /// review; a reader verdict or a reviewed label brings such a pair back). Negatives: two reports sharing a specific
    /// name or place 36 h to 7 days apart, which the matcher's window keeps apart by definition (0, marginal `01`: not
    /// one occurrence, possibly a later act of one story); never act-class negatives. Same-day negatives (0, weight 2):
    /// the same within 36 h across two events of two or more members in different stories, only with a hard conflict
    /// (place, figure, period, year, weekday) or a cosine below 0.58, so fragments of one story are not negatives.
    /// Articles of the private corpus (`NEWS_EVENT_CORPUS`, tune and holdout) are left out by URL and headline, and every
    /// article from a day around the corpus dates, so no other report of a corpus event is trained on; the articles of
    /// the library holdout (`holdoutPath`, #579) and any copy of their headlines are left out too. The CSV carries
    /// headline and lead text, so it is written only to the private directory and never overwritten.
    /// The reader's verdicts (#552) come first with weight 5: every "Same Event" pair as same (2) and every "Not the
    /// Same Event" pair as not one occurrence (0, marginal `01`), group `v:<low id>`; a mined row of the same pair is
    /// then skipped. With `verdictsOnly` only those rows are written, as `verdicts.csv`.
    static func exportTrainingPairs(
        snapshots: String, output: String, corpusPath: String, holdoutPath: String? = nil, verdictsOnly: Bool = false
    ) async throws {
        let file = try StoryCorpus.privateDirectory(output)
            .appendingPathComponent(verdictsOnly ? "verdicts.csv" : "pairs.csv")
        struct Corpus: Decodable {
            struct Item: Decodable {
                let title: String, url: String?, published: Date
            }
            let articles: [Item]
        }
        func key(_ title: String) -> String { MuteRules.foldedWords(title).joined(separator: " ") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let corpus = try decoder.decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: corpusPath)))
        let corpusTitles = Set(corpus.articles.map { key($0.title) })
        let corpusURLs = Set(corpus.articles.compactMap(\.url))
        // Other publishers' reports of the corpus events stay out too: nothing from a day around its dates is used.
        let dates = corpus.articles.map(\.published)
        let corpusWindow =
            (dates.min() ?? .distantFuture).addingTimeInterval(
                -86400)...(dates.max() ?? .distantPast)
            .addingTimeInterval(86400)
        struct HoldoutPair: Decodable {
            let a: String, b: String
        }
        let holdoutIDs = Set(
            try holdoutPath.map {
                try JSONDecoder().decode([HoldoutPair].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
            }?.flatMap { [$0.a, $0.b] } ?? [])
        struct Row {
            let id: String, title: String, description: String, source: String, date: Date, event: String?
            var text: String { EventFeatures.matchingText(title: title, description: description) }
        }
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        // The app's own word pieces travel with each text, so training sees exactly the ids the app will send.
        let tokenizer = try BertWordPieceTokenizer(vocabURL: URL(fileURLWithPath: "Sources/Resources/CoreML/vocab.txt"))
        func pieces(_ text: String) -> String { tokenizer.pieces(text).map { String($0) }.joined(separator: " ") }
        var lines = ["label,group,text_a,text_b,pieces_a,pieces_b,weight,marginal"]
        var seen = Set<String>()
        var excluded = 0
        var holdoutExcluded = 0
        var verdicts = 0
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Every copy of a holdout headline is left out, whichever snapshot holds it and under whichever id: the titles
        // are collected from all snapshots first.
        var holdoutTitles = Set<String>()
        var unresolvedHoldoutIDs = holdoutIDs
        // The live library is refused before anything reads or copies it.
        guard !snapshots.split(separator: ":").contains(where: { StoryCorpus.isLiveLibrary(String($0)) }) else {
            throw StoryCorpus.Failure.invalid("Export from a copy of the library, never the live file")
        }
        for path in snapshots.split(separator: ":").map(String.init) where !holdoutIDs.isEmpty {
            let copy = scratch.appendingPathComponent("titles-\(UUID().uuidString).sqlite3").path
            try StoryCorpus.writableCopy(of: path, to: copy)
            let db = DatabaseEngine(path: copy)
            try await db.open()
            for row in try await db.eventRows("SELECT id, title FROM articles;") {
                if let id = row[0], let title = row[1], holdoutIDs.contains(id) {
                    holdoutTitles.insert(key(title))
                    unresolvedHoldoutIDs.remove(id)
                }
            }
            await db.close()
        }
        guard unresolvedHoldoutIDs.isEmpty else {
            throw StoryCorpus.Failure.invalid(
                "Snapshots do not resolve \(unresolvedHoldoutIDs.count) library holdout IDs")
        }
        for path in snapshots.split(separator: ":").map(String.init) {
            // Mined pairs come from this build's events and stories, not the ones stored by an older matcher.
            let db = DatabaseEngine(path: verdictsOnly ? path : try await reclusteredLibraryCopy(path, in: scratch))
            try await db.open()
            var rows: [Row] = []
            let articles = try await db.eventRows(
                """
                SELECT a.id, a.title, coalesce(a.description, ''), a.source, a.published_at,
                    coalesce(a.canonical_url, ''), e.id
                FROM articles a
                LEFT JOIN event_members m ON m.article_id = a.id
                LEFT JOIN events e ON e.id = m.event_id AND e.merged_into IS NULL
                WHERE a.published_at IS NOT NULL;
                """)
            for values in articles {
                guard let id = values[0], let title = values[1], let published = values[4].flatMap({ Double($0) })
                else { continue }
                if holdoutIDs.contains(id) || holdoutTitles.contains(key(title)) {
                    holdoutExcluded += 1
                    continue
                }
                if corpusTitles.contains(key(title)) || corpusURLs.contains(values[5] ?? "")
                    || corpusWindow.contains(Date(timeIntervalSince1970: published))
                {
                    excluded += 1
                    continue
                }
                let row = Row(
                    id: id, title: title, description: values[2] ?? "", source: values[3] ?? "",
                    date: Date(timeIntervalSince1970: published), event: values[6])
                if EventMatchKey.language(of: row.title + "\n" + row.description) == "en" { rows.append(row) }
            }
            let corrections = try await db.eventRows(
                """
                SELECT article_id, other_article_id, 1 FROM event_inclusions
                UNION ALL SELECT article_id, other_article_id, 0 FROM event_exclusions ORDER BY 1, 2;
                """)
            // Pairs the pair model alone linked (#627), keyed low id first like the decisions.
            let modelOnly = Set(
                try await db.eventRows(
                    "SELECT article_id || char(10) || other_article_id FROM pair_assessments "
                        + "WHERE decision = 'match' AND reason = 'pairModel';"
                ).compactMap { $0.first ?? nil })
            // The story of each event (#581); a copy clustered before the story layer has each event as its own story.
            var storyOf: [String: String] = [:]
            let stories = "SELECT id, coalesce(story_id, id) FROM events WHERE merged_into IS NULL;"
            for row in try await db.eventRows(stories) {
                if let id = row[0], let story = row[1] { storyOf[id] = story }
            }
            await db.close()
            let features = rows.map { EventFeatures(title: $0.title, description: $0.description, date: $0.date) }
            let prefixed = StoryCorpus.policyFromEnvironment().pairModelPrefix
            func append(_ label: Int, _ group: String, _ i: Int, _ j: Int, weight: Int = 1, marginal: String = "") {
                let pairKey = [key(rows[i].title) + "|" + rows[i].source, key(rows[j].title) + "|" + rows[j].source]
                    .sorted().joined(separator: "\n")
                if weight == 5 {
                    // A verdict is one article pair: keyed by ids, so two pairs with the same headlines stay
                    // distinct; the text key is taken as well, so the mined row of that pair is skipped.
                    guard seen.insert([rows[i].id, rows[j].id].sorted().joined(separator: "\n")).inserted else {
                        return
                    }
                    seen.insert(pairKey)
                } else {
                    guard seen.insert(pairKey).inserted else { return }
                }
                // The prefix the model reads at run time (#626): the pair's gap and whether one publisher wrote both.
                func input(_ index: Int) -> String {
                    // Unknown stays unknown: an undated article or an empty publisher gives no gap or relation.
                    let dated = rows[i].date != DateParser.unknownDate && rows[j].date != DateParser.unknownDate
                    let known = !rows[i].source.isEmpty && !rows[j].source.isEmpty
                    return prefixed
                        ? EventMatcher.pairModelInput(
                            rows[index].text, gap: dated ? abs(rows[i].date.timeIntervalSince(rows[j].date)) : nil,
                            samePublisher: known ? rows[i].source == rows[j].source : nil) : rows[index].text
                }
                lines.append(
                    [
                        String(label), quoted(group), quoted(input(i)), quoted(input(j)), pieces(input(i)),
                        pieces(input(j)), String(weight), marginal,
                    ].joined(separator: ","))
            }
            let indexByID = Dictionary(rows.indices.map { (rows[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
            for correction in corrections {
                guard let low = correction[0].flatMap({ indexByID[$0] }),
                    let high = correction[1].flatMap({ indexByID[$0] })
                else { continue }
                let before = lines.count
                if correction[2] == "1" {
                    append(2, "v:" + rows[low].id, low, high, weight: 5)
                } else {
                    append(0, "v:" + rows[low].id, low, high, weight: 5, marginal: "01")
                }
                verdicts += lines.count - before
            }
            if verdictsOnly { continue }
            // Positives: events, scored with the same embedding the clusterer uses.
            let members = Dictionary(grouping: rows.indices.filter { rows[$0].event != nil }) { rows[$0].event ?? "" }
            var vectors: [Int: [Float]] = [:]
            for index in members.values.filter({ $0.count >= 2 }).flatMap({ $0 }) {
                vectors[index] = await SentenceEmbedder.shared.embed(rows[index].text)
            }
            func cosine(_ i: Int, _ j: Int) -> Double? {
                vectors[i].flatMap { a in vectors[j].map { SentenceEmbedder.cosineSimilarity(a, $0) } }
            }
            var positives = 0
            var modelOnlySkipped = 0
            for (event, indices) in members where indices.count >= 2 {
                for (n, i) in indices.enumerated() {
                    for j in indices[(n + 1)...] where rows[i].source != rows[j].source {
                        guard EventMatcher.assess(features[i], features[j], embeddingSimilarity: cosine(i, j)).isMatch
                        else { continue }
                        let (low, high) = rows[i].id < rows[j].id ? (rows[i].id, rows[j].id) : (rows[j].id, rows[i].id)
                        if modelOnly.contains(low + "\n" + high) {
                            modelOnlySkipped += 1
                            continue
                        }
                        let before = lines.count
                        append(2, "e:" + event, i, j)
                        positives += lines.count - before
                    }
                }
            }
            // Negatives: a shared specific anchor, too far apart to be one event. Very common anchors are capped.
            var byAnchor: [String: [Int]] = [:]
            for (index, value) in features.enumerated() {
                for anchor in value.specificAnchors { byAnchor[anchor, default: []].append(index) }
            }
            var candidates = Set<[Int]>()
            for indices in byAnchor.values {
                let sample =
                    indices.count > 80 ? Array(indices.sorted { rows[$0].id < rows[$1].id }.prefix(80)) : indices
                for (n, i) in sample.enumerated() {
                    // Cross-publisher only, like the positives: otherwise the publisher alone would predict the label.
                    for j in sample[(n + 1)...] where rows[i].source != rows[j].source {
                        let gap = abs(rows[i].date.timeIntervalSince(rows[j].date))
                        guard gap > 36 * 3600, gap <= 7 * 86400 else { continue }
                        if let event = rows[i].event, event == rows[j].event { continue }
                        candidates.insert(i < j ? [i, j] : [j, i])
                    }
                }
            }
            // A fixed pseudo-random order (FNV-1a of the ids), then twice as many negatives as positives.
            func order(_ pair: [Int]) -> UInt64 {
                (rows[pair[0]].id + rows[pair[1]].id).utf8.reduce(14_695_981_039_346_656_037) {
                    ($0 ^ UInt64($1)) &* 1_099_511_628_211
                }
            }
            let negatives = candidates.sorted { order($0) < order($1) }.prefix(2 * positives)
            for pair in negatives { append(0, "n:" + rows[pair[0]].id, pair[0], pair[1], marginal: "01") }
            // Same-day negatives (#625): two reports sharing a specific anchor within 36 h that sit in different
            // events of two or more members each, the same-topic-different-story case the model confuses. Fragments
            // of one story sit in such events too (#627), so only pairs in different stories with a hard conflict or a
            // cosine below 0.58 are kept. They repeat the matcher's own separations, so they weigh 2, not 5 like a
            // reviewed label, and are capped at the number of positives.
            let eventSizes = Dictionary(grouping: rows.indices.filter { rows[$0].event != nil }) {
                rows[$0].event ?? ""
            }
            .mapValues(\.count)
            let hardConflicts: Set<EventConflict> = [.places, .titleNumbers, .period, .year, .weekday, .edition]
            var sameDay = Set<[Int]>()
            for indices in byAnchor.values {
                let sample =
                    indices.count > 80 ? Array(indices.sorted { rows[$0].id < rows[$1].id }.prefix(80)) : indices
                for (n, i) in sample.enumerated() {
                    // Same-publisher pairs stay in: two items of one series in different events are the commonest
                    // false merge (#551), so they are the most useful negatives.
                    for j in sample[(n + 1)...] {
                        guard let a = rows[i].event, let b = rows[j].event, a != b, (eventSizes[a] ?? 0) >= 2,
                            (eventSizes[b] ?? 0) >= 2, rows[i].date != DateParser.unknownDate,
                            rows[j].date != DateParser.unknownDate,
                            abs(rows[i].date.timeIntervalSince(rows[j].date)) <= 36 * 3600,
                            (storyOf[a] ?? a) != (storyOf[b] ?? b)
                        else { continue }
                        // The clusterer's publisher relation, so two editions of one series meet their edition conflict.
                        let conflict = EventMatcher.assess(
                            features[i], features[j],
                            samePublisher: !rows[i].source.isEmpty && rows[i].source == rows[j].source
                        ).conflict
                        guard conflict.map(hardConflicts.contains) == true || (cosine(i, j) ?? 1) < 0.58 else {
                            continue
                        }
                        sameDay.insert(i < j ? [i, j] : [j, i])
                    }
                }
            }
            var sameDayWritten = 0
            for pair in sameDay.sorted(by: { order($0) < order($1) }) where sameDayWritten < positives {
                let before = lines.count
                append(0, "s:" + rows[pair[0]].id, pair[0], pair[1], weight: 2)
                sameDayWritten += lines.count - before
            }
            print(
                "    \(URL(fileURLWithPath: path).lastPathComponent): \(rows.count) English articles, \(positives) positives "
                    + "(\(modelOnlySkipped) pair-model-only links left out), \(negatives.count) negatives, "
                    + "\(sameDayWritten) of \(sameDay.count) clean same-day negatives (#625, #627)"
            )
        }
        try StoryCorpus.writePrivate(Data(lines.joined(separator: "\n").utf8), to: file, replacing: false)
        print(
            "    exported \(lines.count - 1) pairs for the pair model (#525), \(verdicts) of them reader verdicts (#552); "
                + "\(excluded) corpus or corpus-window articles and \(holdoutExcluded) library-holdout articles "
                + "(\(holdoutIDs.count) ids) left out"
        )
    }

    /// Native sentence embeddings against deterministic matching on the same labeled pairs (#127).
    /// Evaluation only: production matching uses no embeddings. Vectors are compared only within one
    /// language, because separate language models share no vector space, and only inside the matcher's
    /// time window, where a deterministic link is possible at all. "Veto" keeps a deterministic link
    /// only when the embeddings agree; "rescue" adds embedding links to it. Scores are pairwise and skip
    /// the whole-event check, so a rescue row overstates what clustering would accept.
    struct EventEmbeddingComparison {
        struct Item {
            let title: String, description: String, date: Date, event: String?, membership: String?
        }
        struct Row {
            let threshold: Double
            var embedding = EventCorpusMetrics(), veto = EventCorpusMetrics(), rescue = EventCorpusMetrics()
        }
        struct Scores {
            var deterministic = EventCorpusMetrics()
            var rows: [Row]
        }
        struct Support {
            var articles = 0
            /// Nil when the system has no sentence embedding for the language.
            let dimension: Int?
        }

        /// Cosine-distance cutoffs swept on the tune split.
        static let sweep = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]

        let thresholds: [Double]
        /// Detected languages; articles without a confident language are only counted.
        var languages: [String: Support] = [:]
        var undetected = 0
        /// Per language, plus "all".
        var scores: [String: Scores] = [:]
        /// Labeled or deterministically linked pairs left out of the comparison, by reason.
        var notCompared: [String: Int] = [:]

        init(
            items: [Item], thresholds: [Double], window: TimeInterval = EventMatchPolicy.standard.maximumTimeGap,
            model: (NLLanguage) -> NLEmbedding? = { NLEmbedding.sentenceEmbedding(for: $0) }
        ) {
            self.thresholds = thresholds
            var models: [String: NLEmbedding] = [:]
            var codes: [String?] = []
            var vectors: [[Double]?] = []
            for item in items {
                // As in the deterministic features: the title and the start of the plain description.
                let description = String(
                    item.description.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                        .prefix(EventFeatures.descriptionPrefix))
                let language = EventMatchKey.language(of: item.title + "\n" + item.description)
                codes.append(language)
                guard let code = language else {
                    undetected += 1
                    vectors.append(nil)
                    continue
                }
                if languages[code] == nil {
                    let embedding = model(NLLanguage(rawValue: code))
                    models[code] = embedding
                    languages[code] = Support(dimension: embedding?.dimension)
                }
                languages[code]?.articles += 1
                vectors.append(models[code]?.vector(for: item.title + "\n" + description))
            }

            let empty = Scores(rows: thresholds.map { Row(threshold: $0) })
            for i in items.indices {
                for j in items.indices where j > i {
                    let gold = items[i].event != nil && items[i].event == items[j].event
                    let linked = items[i].membership != nil && items[i].membership == items[j].membership
                    var reason: String?
                    if codes[i] == nil || codes[j] == nil {
                        reason = "unknown language"
                    } else if codes[i] != codes[j] {
                        reason = "cross-language"
                    } else if abs(items[i].date.timeIntervalSince(items[j].date)) > window {
                        reason = "outside time window"
                    } else if vectors[i] == nil || vectors[j] == nil {
                        reason = "no sentence embedding"
                    }
                    guard reason == nil, let code = codes[i], let left = vectors[i], let right = vectors[j] else {
                        if gold || linked, let reason { notCompared[reason, default: 0] += 1 }
                        continue
                    }
                    let distance = Self.cosineDistance(left, right)
                    for key in [code, "all"] {
                        var entry = scores[key] ?? empty
                        entry.deterministic.add(predicted: linked, gold: gold)
                        for index in entry.rows.indices {
                            let close = distance <= entry.rows[index].threshold
                            entry.rows[index].embedding.add(predicted: close, gold: gold)
                            entry.rows[index].veto.add(predicted: linked && close, gold: gold)
                            entry.rows[index].rescue.add(predicted: linked || close, gold: gold)
                        }
                        scores[key] = entry
                    }
                }
            }
        }

        static func cosineDistance(_ left: [Double], _ right: [Double]) -> Double {
            var dot = 0.0
            var leftNorm = 0.0
            var rightNorm = 0.0
            for (x, y) in zip(left, right) {
                dot += x * y
                leftNorm += x * x
                rightNorm += y * y
            }
            guard leftNorm > 0, rightNorm > 0 else { return 2 }
            return 1 - dot / (leftNorm * rightNorm).squareRoot()
        }

        func report(split: String) {
            let skipped = notCompared.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }.joined(
                separator: ", ")
            print(
                "    \(split) embeddings (#127): labeled or linked pairs not compared: \(skipped.isEmpty ? "none" : skipped)"
            )
            for (code, support) in languages.sorted(by: { $0.key < $1.key }) {
                let model = support.dimension.map { "\($0)-dimensional sentence embedding" } ?? "no sentence embedding"
                print("      language \(code): \(support.articles) articles, \(model)")
            }
            if undetected > 0 { print("      \(undetected) articles without a confident language") }
            let keys = ["all"] + scores.keys.filter({ $0 != "all" }).sorted()
            for key in keys {
                guard let entry = scores[key] else { continue }
                print("      \(key) deterministic: \(entry.deterministic.line)")
                for row in entry.rows {
                    let cutoff = String(format: "%.2f", row.threshold)
                    print("        distance ≤ \(cutoff) embedding: \(row.embedding.line)")
                    print("        distance ≤ \(cutoff) veto: \(row.veto.line)")
                    print("        distance ≤ \(cutoff) rescue: \(row.rescue.line)")
                }
            }
            if thresholds.isEmpty {
                print("      Set NEWS_EMBEDDING_THRESHOLD to the cutoff chosen on tune to score embeddings on \(split)")
            }
        }
    }

    /// Opt-in and live: refreshes the twelve panel feeds over the production client (real DNS, TLS and publishers),
    /// then stops refreshes at staggered offsets so shutdowns land during handshakes, transfers, parsing or ingestion.
    @MainActor
    static func testPublisherCancellation() async throws {
        let feeds = TensionMethodology.v1.panel.map(\.url)
        print("  - Live: refreshing and cancelling \(feeds.count) publisher feeds over HTTPS...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-publisher-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ label: String, cancelAfter offset: Duration?) async throws -> [String: Any] {
            let path = directory.appendingPathComponent("\(label).sqlite3").path
            let db = DatabaseEngine(path: path)
            let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
            await store.initialize()
            let suite = testDefaultsSuite("test.publisher-cancellation")
            let defaults = UserDefaults(suiteName: suite)!
            defer { removeTestDefaults(suite) }
            let settings = AppSettings(defaults: defaults)
            settings.feedURLs = feeds
            settings.aiEnabled = false
            settings.notificationsEnabled = false
            let fetcher = FeedFetcher()
            let manager = FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, allowHTTP in
                    await fetcher.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: db)
                },
                notifyBatch: { _, _ in
                    // Notifications are off and out of scope for this measurement.
                })
            let done = SocketObservation()
            let started = ContinuousClock.now
            let refresh = Task {
                await manager.fetchFeedsAsync()
                let end = ContinuousClock.now
                done.recordText("finished")
                return end
            }
            var result: [String: Any] = ["label": label]
            if let offset {
                try await Task.sleep(for: offset)
                let finishedFirst = done.count == 1
                result["finished_before_cancel"] = finishedFirst
                let cancelled = ContinuousClock.now
                manager.stopBackgroundWork()
                await eventually("Shutdown of a live refresh completes within its deadline", timeout: .seconds(2)) {
                    done.count == 1
                }
                let end = await refresh.value
                if !finishedFirst { result["stop_ms"] = milliseconds(cancelled.duration(to: end)) }
                assertFalse(manager.isAnyFeedLoading, "Shutdown clears refresh loading")
            } else {
                result["refresh_ms"] = milliseconds(started.duration(to: await refresh.value))
                manager.stopBackgroundWork()
            }
            result["articles"] = try await db.counts().total
            result["feed_states"] = try await db.feedFetchStates().count
            await db.close()
            // Validators are only ever stored with the articles they describe, so a later 304 cannot hide unsaved items.
            var handle: OpaquePointer?
            assertEqual(
                sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK, "Open the temporary library")
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            sqlite3_prepare_v2(
                handle,
                """
                SELECT COUNT(*) FROM feeds f WHERE (f.etag IS NOT NULL OR f.last_modified IS NOT NULL)
                AND NOT EXISTS (SELECT 1 FROM article_feeds af WHERE af.feed_url = f.url);
                """, -1, &statement, nil)
            assertEqual(sqlite3_step(statement), SQLITE_ROW, "Count validators without articles")
            assertEqual(sqlite3_column_int(statement, 0), 0, "\(label): no feed keeps validators without its articles")
            sqlite3_finalize(statement)
            sqlite3_prepare_v2(handle, "PRAGMA integrity_check;", -1, &statement, nil)
            assertEqual(sqlite3_step(statement), SQLITE_ROW, "Run the integrity check")
            assertEqual(
                sqlite3_column_text(statement, 0).map { String(cString: $0) }, "ok",
                "\(label): the library stays intact")
            sqlite3_finalize(statement)
            return result
        }
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        var samples: [[String: Any]] = []
        for index in 0..<2 { samples.append(try await run("full-\(index)", cancelAfter: nil)) }
        for offset in [25, 75, 150, 300, 600, 1200] {
            samples.append(try await run("cancel-\(offset)ms", cancelAfter: .milliseconds(offset)))
        }
        // Ordinary completion within the deadline is not evidence: require stops that interrupted live work.
        let full = samples.prefix(2).compactMap { $0["articles"] as? Int }.min() ?? 0
        let active = samples.filter { $0["stop_ms"] != nil }
        assertFalse(active.isEmpty, "At least one stop lands while the refresh is still running")
        assertTrue(
            active.contains { ($0["articles"] as? Int) == 0 && ($0["feed_states"] as? Int) == 0 } && full > 0,
            "A stop during the network phase stores no articles and records no feed outcome")
        for sample in active {
            assertTrue(
                (sample["stop_ms"] as? Double ?? .infinity) < 250,
                "\(sample["label"] ?? ""): the refresh stops promptly")
        }
        let report: [String: Any] = [
            "feeds": feeds.count, "samples": samples, "client": "SecureHTTPClient.shared (production proxy, live TLS)",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("PUBLISHER_CANCELLATION_REPORT " + String(decoding: data, as: UTF8.self))
    }

}
