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

/// Native port of the `ClusteringTests` atom (#1070): the same 29 tests, in the runner's order, with each
/// `assertEqual`/`assertTrue`/`assertFalse` turned into the matching `expect` helper of NativeExpectations.swift and each
/// force unwrap into `#require` (the runner log is invisible to Swift Testing), so a failure is recorded and later tests
/// still run. The tests live in this file and in ClusteringSuite+Stories.swift; `eventEmbeddingIntegration`, which the
/// atom dispatches from EventEmbeddingTests.swift, lives in ClusteringSuite+Embedding.swift. Fixture and model paths the
/// runner resolves against its working directory resolve against `nativeRepositoryRoot`; the app's
/// `bundledModelResource` and the corpus tools these tests share with the CLI modes rely on `NativeSuites` running in
/// the checkout. The runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.clustering, .integration)) struct ClusteringSuite {
        @Test @MainActor func eventDataModel() async throws {
            try await Self.testEventDataModel(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func eventCandidateGeneration() async throws {
            try await Self.testEventCandidateGeneration(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func relatedStoryEvents() async throws {
            try await Self.testRelatedStoryEvents(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func eventMatcherRules() async throws { try await Self.testEventMatcherRules() }
        @Test func actClassTable() { Self.testActClassTable() }
        @Test func storyCountryPlaceVeto() { Self.testStoryCountryPlaceVeto() }
        @Test func eventClustering() async throws {
            try await Self.testEventClustering(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func articleSignalsRoundTrip() async throws { try await Self.testArticleSignalsRoundTrip() }
        @Test func pairAssessmentsRecorded() async throws { try await Self.testPairAssessmentsRecorded() }
        @Test func readerVerdictsExportAndGate() async throws { try await Self.testReaderVerdictsExportAndGate() }
        @Test func storyLayer() async throws { try await Self.testStoryLayer() }
        @Test func storyPassOrderIndependent() async throws { try await Self.testStoryPassOrderIndependent() }
        @Test func eventInclusions() async throws { try await Self.testEventInclusions() }
        @Test func pairModelGreyZone() async throws { try await Self.testPairModelGreyZone() }
        @Test func eventEmbeddingIntegration() async throws { try await Self.testEventEmbeddingIntegration() }
        @Test func eventFragmentMergingAndJudge() async throws {
            try await Self.testEventFragmentMergingAndJudge(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test @MainActor func storyVisibility() async throws {
            try await Self.testStoryVisibility(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func orphanStateGuards() async throws { try await Self.testOrphanStateGuards() }
        @Test func eventReadingState() async throws {
            try await Self.testEventReadingState(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func eventFeedSummaryUnit() { Self.testEventFeedSummaryUnit() }
        @Test func eventFeedGroupingAndStability() async throws { try await Self.testEventFeedGroupingAndStability() }
        @Test func eventFeedGroupingOptimization() { Self.testEventFeedGroupingOptimization() }
        @Test @MainActor func refreshClustersEvents() async throws {
            try await Self.testRefreshClustersEvents(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test @MainActor func storyCheckForUpdates() async throws {
            try await Self.testStoryCheckForUpdates(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func eventCorpusHarness() async throws {
            try await Self.testEventCorpusHarness(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func matcherRegressionCorpus() async throws { try await Self.testMatcherRegressionCorpus() }
        @Test func storyRegressionCorpus() async throws { try await Self.testStoryRegressionCorpus() }
        @Test func pairCalibration() async throws { try await Self.testPairCalibration() }
        @Test func capturedFingerprintReview() throws { try Self.testCapturedFingerprintReview() }
    }
}

extension NativeSuites.ClusteringSuite {
    /// `NewsTests.eventually`, recording its timeout through Swift Testing instead of the runner's failure log.
    static func eventually(
        _ message: String, timeout: Duration = .seconds(10), isolation: isolated (any Actor)? = #isolation,
        _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            if ContinuousClock.now > deadline {
                expectTrue(false, message)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    static func testEventDataModel(fixtureRoot: URL) async throws {
        print("  - Testing event IDs, membership versions, merges, splits, retention and copied v11 migration...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("original.sqlite3").path
        let copy = directory.appendingPathComponent("copy.sqlite3").path
        let cancelledPath = directory.appendingPathComponent("cancelled.sqlite3").path
        func value(_ file: String, _ sql: String) -> String? {
            var connection: OpaquePointer?
            var statement: OpaquePointer?
            expectEqual(sqlite3_open(file, &connection), SQLITE_OK, "Inspect event fixture")
            defer { sqlite3_close(connection) }
            expectEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK, "Prepare event inspection")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        let old = Date().addingTimeInterval(-40 * 86400)
        let articles = ["a", "b", "c", "d", "e"].map { name in
            FeedArticle(
                storedID: "event-\(name)", title: "Event report \(name)",
                link: fixtureRoot.appendingPathComponent("events/\(name)").absoluteString,
                guid: "event-guid-\(name)", description: "Distinct reporting \(name)", pubDate: old,
                source: "Publisher \(name)")
        }
        let creator = DatabaseEngine(path: path)
        try await creator.open()
        try await creator.upsertArticles(articles)
        try await creator.markRead(articleId: "event-a", isRead: true)
        try await creator.markRead(articleId: "event-b", isRead: true)
        try await creator.setSaved(articleId: "event-b", isSaved: true)
        await creator.close()
        var handle: OpaquePointer?
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open v11 event fixture")
        expectEqual(
            sqlite3_exec(
                handle,
                "DROP TRIGGER trg_articles_event_rematch; DROP TABLE event_state; DROP TABLE event_exclusions; DROP TABLE event_match_state; DROP TABLE event_members; DROP TABLE events; PRAGMA user_version = 11;",
                nil, nil, nil), SQLITE_OK, "Reconstruct a v11 library")
        sqlite3_close(handle)
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        try FileManager.default.copyItem(atPath: path, toPath: cancelledPath)

        let cancelledDB = DatabaseEngine(path: cancelledPath)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cancelledDB.open()
        }
        do {
            try await cancelled.value
            expectTrue(false, "Cancelled event migration must throw")
        } catch is CancellationError {}
        expectEqual(
            value(cancelledPath, "PRAGMA user_version;"), "11", "Cancelled event migration keeps the old version")
        expectEqual(
            value(cancelledPath, "SELECT count(*) FROM sqlite_master WHERE name IN ('events','event_members');"), "0",
            "Cancelled event migration rolls back its tables")

        let db = DatabaseEngine(path: copy)
        try await db.open()
        expectEqual(
            value(copy, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Copied v11 library upgrades to the current schema")
        expectEqual(value(path, "PRAGMA user_version;"), "11", "Original v11 fixture stays untouched")
        expectEqual(try await db.fetchArticles(limit: nil).count, 5, "Event migration keeps every article")
        expectTrue(try await db.isRead(articleId: "event-a"), "Event migration keeps read state")
        expectTrue(try await db.isSaved(articleId: "event-b"), "Event migration keeps saved state")
        expectEqual(
            value(
                copy,
                "SELECT group_concat(name) FROM (SELECT name FROM pragma_table_info('event_members') ORDER BY name);"),
            "article_id,event_id,joined_version", "Membership stores article references, not source text")
        expectEqual(
            value(
                copy,
                "SELECT count(*) FROM pragma_table_info('events') WHERE name IN ('title','description','content');"),
            "0", "Events do not copy source text")

        let first = try await db.createEvent(memberArticleIDs: ["event-a", "event-b", "event-c", "event-a"])
        expectEqual(first.membershipVersion, 1, "A new event starts at membership version 1")
        expectEqual(first.memberArticleIDs, ["event-a", "event-b", "event-c"], "Repeated articles join once")
        let grown = try await db.addArticles(["event-d"], toEvent: first.id)
        expectEqual(grown.id, first.id, "Adding members keeps the event ID")
        expectEqual(grown.membershipVersion, 2, "Adding a member bumps the membership version")
        expectEqual(
            value(copy, "SELECT joined_version FROM event_members WHERE article_id='event-d';"), "2",
            "Members record the version they joined")
        expectEqual(
            try await db.addArticles(["event-d"], toEvent: first.id).membershipVersion, 2,
            "Re-adding a member does not bump the version")

        let second = try await db.createEvent(memberArticleIDs: ["event-c"])
        expectEqual(
            try await db.fetchEvent(id: first.id)?.membershipVersion, 3,
            "Losing a member to another event bumps the version")
        expectEqual(try await db.eventID(forArticle: "event-c"), second.id, "An article belongs to one event at a time")

        let merged = try await db.mergeEvents(second.id, into: first.id)
        expectEqual(merged.id, first.id, "The survivor keeps its ID")
        expectEqual(merged.membershipVersion, 4, "A merge that moves members bumps the survivor's version")
        expectEqual(merged.memberArticleIDs, ["event-a", "event-b", "event-c", "event-d"], "A merge unions members")
        expectEqual(try await db.resolvedEventID(second.id), first.id, "The absorbed ID forwards to the survivor")
        expectEqual(try await db.fetchEvent(id: second.id)?.id, first.id, "Links to the absorbed ID open the survivor")
        expectEqual(
            try await db.mergeEvents(first.id, into: second.id).membershipVersion, 4,
            "Merging an event into its own forward is a no-op")

        let split = try await db.splitEvent(second.id, movingArticles: ["event-c", "event-d"])
        expectTrue(split.id != first.id && split.id != second.id, "A split gets a new stable ID")
        expectEqual(split.membershipVersion, 1, "A split starts its own version history")
        expectEqual(split.memberArticleIDs, ["event-c", "event-d"], "A split takes only the moved members")
        let remaining = try await db.fetchEvent(id: first.id)
        expectEqual(remaining?.memberArticleIDs, ["event-a", "event-b"], "The original keeps the remaining members")
        expectEqual(remaining?.membershipVersion, 5, "A split bumps the original's version")
        expectEqual(try await db.resolvedEventID(second.id), first.id, "Old forwards still resolve after a split")
        do {
            _ = try await db.splitEvent(first.id, movingArticles: ["event-a", "event-b"])
            expectTrue(false, "Moving every member is not a split")
        } catch {}
        do {
            _ = try await db.splitEvent(first.id, movingArticles: ["event-c"])
            expectTrue(false, "A split moves only current members")
        } catch {}
        do {
            _ = try await db.createEvent(memberArticleIDs: ["missing-article"])
            expectTrue(false, "Unknown articles cannot join an event")
        } catch {}
        expectEqual(
            try await db.fetchEvent(id: first.id)?.membershipVersion, 5, "Rejected changes leave the version untouched")

        expectTrue(try await db.isRead(articleId: "event-a"), "Merges and splits keep read state")
        expectTrue(try await db.isSaved(articleId: "event-b"), "Merges and splits keep saved state")
        expectEqual(
            try await db.fetchArticles(id: "event-c").first?.id, "event-c", "Merges and splits keep article IDs")

        try await db.markRead(articleId: "event-c", isRead: true)
        try await db.markRead(articleId: "event-d", isRead: true)
        try await db.markRead(articleId: "event-e", isRead: true)
        let cited = try await db.createEvent(memberArticleIDs: ["event-e"])
        let citation = OverviewCitation(
            id: "event-citation", articleID: "event-e", passageID: "p", passageFingerprint: "f",
            quote: "Distinct reporting e")
        try await db.recordEventOverview(
            EventOverviewDocument(
                eventID: cited.id,
                version: OverviewVersionContext(membershipVersion: cited.membershipVersion, inputTextHash: "hash"),
                content: OverviewContent(title: "Event", summary: "Summary", citations: [citation])))
        expectEqual(
            try await db.pruneOldArticles(keepReadDays: 30), 3, "Retention removes old read, unsaved, uncited members")
        expectEqual(
            try await db.fetchEvent(id: first.id)?.memberArticleIDs, ["event-b"], "Saved members survive retention")
        expectTrue(try await db.fetchEvent(id: split.id) == nil, "Events emptied by retention are dropped")
        expectEqual(
            try await db.fetchEvent(id: cited.id)?.memberArticleIDs, ["event-e"],
            "Cited evidence stays reachable through its event")
        try await db.removeArticles(["event-e"], fromEvent: cited.id)
        try await db.removeArticles(["event-b"], fromEvent: first.id)
        expectEqual(try await db.pruneOldArticles(keepReadDays: 30), 0, "Saved and cited articles are never pruned")
        expectTrue(try await db.fetchEvent(id: cited.id) != nil, "An event with a stored overview keeps its ID")
        expectTrue(try await db.resolvedEventID(first.id) == nil, "An empty event is dropped by retention")
        expectTrue(try await db.resolvedEventID(second.id) == nil, "Its forwards are dropped with it")
        expectTrue(try await db.isSaved(articleId: "event-b"), "Dropping an event keeps the saved article")
        expectEqual(value(copy, "PRAGMA quick_check;"), "ok", "Event library passes quick_check")
        expectTrue(value(copy, "PRAGMA foreign_key_check;") == nil, "Event membership has no dangling references")
        await db.close()
    }

    static func testEventCandidateGeneration(fixtureRoot: URL) async throws {
        print("  - Testing bounded event candidates by time window, language, terms and active events...")
        let key = EventMatchKey(
            title: "Earthquake strikes Lviv region overnight",
            description: "A strong earthquake struck the Lviv region overnight, officials said.")
        expectTrue(key.terms.count <= EventMatchKey.maximumTerms, "Match keys are bounded")
        expectTrue(key.terms.contains { $0.lowercased() == "earthquake" }, "Distinctive title words become terms")
        expectEqual(key.terms.filter { $0.lowercased() == "lviv" }.count, 1, "Names and title words are deduplicated")
        expectFalse(key.terms.contains("the"), "Short words are not terms")
        let crowded = EventMatchKey(
            title: "Earthquake strikes Lviv region overnight",
            description:
                "Officials in Kyiv, Warsaw, Berlin, Paris, Rome, Madrid, Vienna, Prague and Lisbon sent condolences.")
        expectTrue(
            crowded.terms.contains { $0.lowercased() == "earthquake" }
                && crowded.terms.count <= EventMatchKey.maximumTerms,
            "Headline words keep their place in the query when the lead names many places")
        let hostile = EventMatchKey(title: "Ceasefire\" OR content:* NEAR(talks) {source} collapse", description: "")
        expectTrue(hostile.ftsQuery?.contains("\"\"") == false, "Quotes in publisher text cannot break out of a phrase")
        expectTrue(
            EventMatchKey(title: "A to B", description: "").ftsQuery == nil, "Articles without terms have no candidates"
        )

        let now = Date()
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        func article(_ id: String, _ title: String, _ description: String, hoursAgo: Double) -> FeedArticle {
            FeedArticle(
                storedID: id, title: title, link: fixtureRoot.appendingPathComponent("candidates/\(id)").absoluteString,
                guid: id, description: description, pubDate: now.addingTimeInterval(-hoursAgo * 3600),
                source: "Publisher \(id)")
        }
        let english = "A strong earthquake struck the Lviv region overnight, officials said on Tuesday morning."
        let german =
            "Ein starkes Erdbeben hat in der Nacht die Region Lviv erschüttert, berichten die Behörden am Dienstag."
        let recognizer = NLLanguageRecognizer()
        let languageTexts = [english, german, "", german, english, ""]
        expectEqual(EventMatchKey.language(of: english), "en", "Language regression includes confident English")
        expectEqual(EventMatchKey.language(of: german), "de", "Language regression includes confident German")
        expectEqual(EventMatchKey.language(of: ""), nil, "Empty text has no detected language")
        for text in languageTexts {
            expectEqual(
                EventMatchKey.language(of: text, using: recognizer), EventMatchKey.language(of: text),
                "Reusing the recognizer preserves independent language results, including nil")
        }
        let target = article("target", "Earthquake strikes Lviv region overnight", english, hoursAgo: 0)
        try await db.upsertArticles([
            target,
            article("recent", "Lviv earthquake damages homes", english, hoursAgo: 20),
            article("old", "Lviv earthquake damages homes", english, hoursAgo: 120),
            article(
                "unrelated", "Central bank holds interest rates", "The central bank left its benchmark rate unchanged.",
                hoursAgo: 2),
            article("german", "Erdbeben erschüttert Lviv", german, hoursAgo: 3),
            article("active", "Earthquake in Lviv: rescuers search buildings", english, hoursAgo: 5),
            article("closed", "Earthquake in Lviv: aftershocks expected", english, hoursAgo: 6),
        ])
        let active = try await db.createEvent(memberArticleIDs: ["active"], at: now)
        _ = try await db.createEvent(memberArticleIDs: ["closed"], at: now.addingTimeInterval(-96 * 3600))

        let candidates = try await EventCandidateFinder.candidates(for: target, in: db, now: now)
        let ids = Set(candidates.map(\.articleID))
        expectTrue(ids.contains("recent"), "Matching articles inside the window are candidates")
        expectFalse(ids.contains("target"), "An article is never its own candidate")
        expectFalse(ids.contains("old"), "Articles outside the time window are not candidates")
        expectFalse(ids.contains("unrelated"), "Articles without shared terms are not candidates")
        expectFalse(ids.contains("german"), "Articles in another detected language are not compared")
        expectFalse(ids.contains("closed"), "Members of events past their active lifetime are not candidates")
        expectEqual(
            candidates.first { $0.articleID == "active" }?.eventID, active.id, "Candidates carry their active event")
        expectEqual(candidates.first { $0.articleID == "recent" }?.eventID, nil, "Unclustered candidates have no event")

        // One language per row within a pass (#572): the first reading stands, and stored signals come before the recognizer.
        var pass: [String: EventCandidateLanguage] = [:]
        let first = try await EventCandidateFinder.candidates(for: target, in: db, now: now, languages: &pass)
        expectEqual(first, candidates, "The pass's language map changes no candidate")
        expectEqual(pass["german"]?.language, "de", "The pass keeps a row's recognized language")
        let germanText = EventCandidateFinder.languageText(title: "Erdbeben erschüttert Lviv", description: german)
        pass["german"] = EventCandidateLanguage(textHash: germanText.hashValue, language: "en")
        let reread = try await EventCandidateFinder.candidates(for: target, in: db, now: now, languages: &pass)
        expectTrue(reread.contains { $0.articleID == "german" }, "A row is not recognized again in one pass")
        pass["german"] = EventCandidateLanguage(textHash: "an earlier edit of the row".hashValue, language: "en")
        let edited = try await EventCandidateFinder.candidates(for: target, in: db, now: now, languages: &pass)
        expectFalse(edited.contains { $0.articleID == "german" }, "A row edited since it was read is read again")
        expectEqual(pass["german"]?.language, "de", "The new text replaces the old reading")
        var signals = EventFeatures(title: "Erdbeben erschüttert Lviv", description: german, date: now)
        signals.language = "en"
        try await db.upsertArticleFeatures(
            ["german": signals], version: EventFeatures.storageVersion - 1, at: now)
        var stale: [String: EventCandidateLanguage] = [:]
        let staleRead = try await EventCandidateFinder.candidates(for: target, in: db, now: now, languages: &stale)
        expectFalse(staleRead.contains { $0.articleID == "german" }, "Signals of an older version are not read")
        try await db.upsertArticleFeatures(["german": signals], version: EventFeatures.storageVersion, at: now)
        var fresh: [String: EventCandidateLanguage] = [:]
        let storedRead = try await EventCandidateFinder.candidates(for: target, in: db, now: now, languages: &fresh)
        expectTrue(storedRead.contains { $0.articleID == "german" }, "A row's stored language comes first")
        try await db.eventRows("DELETE FROM article_features;")

        try await db.upsertArticles(
            (0..<30).map { article("bulk-\($0)", "Lviv earthquake update \($0)", english, hoursAgo: 1) })
        var narrow = EventCandidatePolicy.standard
        narrow.limit = 5
        expectEqual(
            try await EventCandidateFinder.candidates(for: target, in: db, policy: narrow, now: now).count, 5,
            "Candidate count is capped")
        narrow.limit = 0
        expectTrue(
            try await EventCandidateFinder.candidates(for: target, in: db, policy: narrow, now: now).isEmpty,
            "A zero limit reads nothing")
        _ = try await EventCandidateFinder.candidates(
            for: article("hostile", hostile.terms.joined(separator: " "), "", hoursAgo: 0), in: db, now: now)
        await db.close()
    }

    static func testRelatedStoryEvents(fixtureRoot: URL) async throws {
        print("  - Testing read-only developing-story relations (#314)...")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let earlier = EventFeatures(
            language: "en", people: ["alex morgan"], places: ["riverside", "@US"],
            keywords: ["bridge", "river", "close"], date: now.addingTimeInterval(-3600))
        let later = EventFeatures(
            language: "en", people: ["alex morgan"], places: ["riverside", "@US"],
            keywords: ["bridge", "river", "rebuild"], date: now)
        expectTrue(EventStoryRelation.supports(earlier, later), "Distinct acts may be related without matching")
        expectFalse(EventStoryRelation.supports(later, earlier), "Earlier links cannot point forward")
        var organization = later
        organization.people = []
        organization.organizations = earlier.people
        expectFalse(
            EventStoryRelation.supports(earlier, organization), "Person-to-organization name collisions never link")
        var earlierOrganization = earlier
        earlierOrganization.people = []
        earlierOrganization.organizations = organization.organizations
        expectFalse(
            EventStoryRelation.supports(earlierOrganization, later), "Organization-to-person name collisions never link"
        )
        expectTrue(
            EventStoryRelation.supports(earlierOrganization, organization), "Shared typed organizations can link")
        let unrelatedCommon: Set<String> = ["someone else", "another agency"]
        expectTrue(
            EventStoryRelation.supports(earlier, later, commonActors: unrelatedCommon),
            "A common-actor set without the shared actor keeps a valid link")
        for field in ["actor", "place", "country", "language", "topic", "date", "period"] {
            var other = later
            switch field {
            case "actor": other.people = ["another person"]
            case "place": other.places = ["lakeside"]
            case "country": other.places = ["riverside", "@CA"]
            case "language": other.language = nil
            case "topic": other.keywords = ["football", "score"]
            case "date": other.date = DateParser.unknownDate
            default: other.periods = ["q2"]
            }
            var first = earlier
            if field == "period" { first.periods = ["q1"] }
            expectFalse(
                EventStoryRelation.supports(first, other), "Weak or conflicting \(field) evidence rejects a link")
            expectFalse(
                EventStoryRelation.supports(first, other, commonActors: unrelatedCommon),
                "The common-actor set never relaxes the \(field) rule")
        }
        var country = later
        country.places = ["@US"]
        expectTrue(EventStoryRelation.supports(earlier, country), "A shared country counts as a shared place")
        expectFalse(
            EventStoryRelation.supports(earlier, later, commonActors: earlier.people.union(earlier.organizations)),
            "An actor common across the week's events does not tie two events together")
        var boundary = earlier
        boundary.date = now.addingTimeInterval(-EventStoryRelation.window)
        expectTrue(EventStoryRelation.supports(boundary, later), "The seven-day boundary is inclusive")
        boundary.date = boundary.date.addingTimeInterval(-1)
        expectFalse(EventStoryRelation.supports(boundary, later), "Older pairs are excluded")
        expectFalse(
            EventStoryRelation.supports(boundary, later, commonActors: unrelatedCommon),
            "The common-actor set never widens the window")

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        func article(_ id: String, hours: Double, unrelated: Bool = false) -> FeedArticle {
            FeedArticle(
                storedID: id,
                title: unrelated
                    ? "Football fans celebrate a match" : "Volodymyr Zelenskyy discusses the Kherson bridge",
                link: fixtureRoot.appendingPathComponent("relations/\(id)").absoluteString,
                guid: id,
                description: unrelated
                    ? "Football fans watched the team win a league match."
                    : "Volodymyr Zelenskyy discussed the bridge across the river in Kherson, Ukraine. The bridge and river transport project will serve residents of the city.",
                pubDate: now.addingTimeInterval(hours * 3600), source: "Publisher \(id)")
        }
        let articles = [
            article("current", hours: 0), article("earlier", hours: -1),
            article("old", hours: -EventStoryRelation.window / 3600 - 1), article("future", hours: 0.2),
            article("mixed-1", hours: -2), article("mixed-2", hours: -2, unrelated: true),
            article("mixed-3", hours: -2, unrelated: true),
            article("half-1", hours: -3), article("half-2", hours: -3, unrelated: true),
        ]
        try await db.upsertArticles(articles, now: now)
        let current = try await db.createEvent(memberArticleIDs: ["current"], at: now)
        let previous = try await db.createEvent(memberArticleIDs: ["earlier"], at: now.addingTimeInterval(-10 * 86400))
        _ = try await db.createEvent(memberArticleIDs: ["old"], at: now)
        _ = try await db.createEvent(memberArticleIDs: ["future"], at: now)
        _ = try await db.createEvent(memberArticleIDs: ["mixed-1", "mixed-2", "mixed-3"], at: now)
        let half = try await db.createEvent(memberArticleIDs: ["half-1", "half-2"], at: now)
        try await db.markRead(articleId: "earlier", isRead: true)
        try await db.setSaved(articleId: "current", isSaved: true)
        let links = try await EventStoryRelation.find(eventID: current.id, in: db)
        expectEqual(links.map(\.eventID), [previous.id], "Only directly supported, wholly earlier events link")
        expectFalse(links.map(\.eventID).contains(half.id), "Support from half the members is not enough")
        expectEqual(links.first?.articleID, "earlier", "Navigation carries a stored member ID")
        func row(_ id: String, hours: Double, event: String) -> EventMatchRow {
            let story = article(id, hours: hours)
            return EventMatchRow(
                id: id, title: story.title, description: story.description, source: "Publisher",
                date: story.pubDate, eventID: event)
        }
        let ranked = try EventStoryRelation.links(
            target: [row("t", hours: 0, event: "target")],
            candidates: (1...4).map { ("event-\($0)", [row("c\($0)", hours: -Double($0), event: "event-\($0)")]) })
        expectEqual(
            ranked.map(\.eventID), ["event-1", "event-2", "event-3"],
            "At most three earlier events link, newest first")
        let halfSupported = try EventStoryRelation.links(
            target: [row("t", hours: 0, event: "target")],
            candidates: [
                (
                    "half",
                    [
                        row("h1", hours: -3, event: "half"),
                        EventMatchRow(
                            id: "h2", title: "Football fans celebrate a match",
                            description: "Football fans watched the team win a league match.", source: "Publisher",
                            date: now.addingTimeInterval(-3 * 3600), eventID: "half"),
                    ]
                )
            ], commonActors: unrelatedCommon)
        expectTrue(halfSupported.isEmpty, "Two-thirds member support still applies with a common-actor set")
        let cancelledLookup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EventStoryRelation.find(eventID: current.id, in: db)
        }
        do {
            _ = try await cancelledLookup.value
            expectTrue(false, "A cancelled lookup must not return links")
        } catch is CancellationError {}
        expectEqual(
            try await db.commonStoryTerms(["volodymyr zelenskyy"], before: now.addingTimeInterval(3600), share: 0.05),
            [], "A name in only a few events is never common, however small the library")
        expectEqual(
            try await db.commonStoryTerms(
                ["volodymyr zelenskyy", "absent name"], before: now.addingTimeInterval(3600), share: 0.05,
                minimumEvents: 1), ["volodymyr zelenskyy"], "A name across most of the week's events is common")
        expectEqual(try await db.fetchEvent(id: current.id), current, "Lookup does not change the target event")
        expectEqual(try await db.fetchEvent(id: previous.id), previous, "Lookup does not change earlier membership")
        expectTrue(try await db.isRead(articleId: "earlier"), "Lookup preserves read state")
        expectTrue(try await db.isSaved(articleId: "current"), "Lookup preserves saved state")
        expectTrue(
            try await EventStoryRelation.find(eventID: "missing", in: db).isEmpty, "Deleted events have no links")
        try await db.upsertArticles([article("forward", hours: 0)], now: now)
        let forward = try await db.createEvent(memberArticleIDs: ["forward"], at: now)
        _ = try await db.mergeEvents(forward.id, into: current.id, at: now)
        expectEqual(
            try await EventStoryRelation.find(eventID: forward.id, in: db), links,
            "Merge forwards resolve to live events")
        var extraIDs: [String] = []
        for i in 0..<5 {
            let id = "extra-\(i)"
            try await db.upsertArticles([article(id, hours: -0.5)], now: now)
            extraIDs.append(try await db.createEvent(memberArticleIDs: [id], at: now).id)
        }
        let capped = try await EventStoryRelation.find(eventID: current.id, in: db)
        expectEqual(
            capped.map(\.eventID), Array(extraIDs.sorted().prefix(3)), "Newest links are capped with stable ID ties")
        expectEqual(
            try await EventStoryRelation.find(eventID: current.id, in: db), capped,
            "Unchanged input gives stable link ordering")
        let undated = FeedArticle(
            storedID: "undated", title: articles[0].title, link: articles[0].link + "/undated", guid: "undated",
            description: articles[0].description, pubDate: DateParser.unknownDate, source: "Other publisher")
        try await db.upsertArticles([undated], now: now)
        _ = try await db.addArticles(["undated"], toEvent: current.id, at: now)
        expectTrue(
            try await EventStoryRelation.find(eventID: current.id, in: db).isEmpty,
            "Ingestion dates cannot order a story")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try EventStoryRelation.links(
                target: [
                    EventMatchRow(id: "current", title: "", description: "", source: "", date: now, eventID: "target")
                ],
                candidates: [("earlier", [])])
        }
        do {
            _ = try await cancelled.value
            expectTrue(false, "Cancelled relation work must stop")
        } catch is CancellationError {}
        await db.close()

        // The live harness writes each link with a hard near-miss control and refuses unsafe or reused outputs.
        let run = URL(fileURLWithPath: "/private/tmp/news-relation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: run) }
        let copy = DatabaseEngine(path: run.appendingPathComponent("library.sqlite3").path)
        try await copy.open()
        let near = FeedArticle(
            storedID: "near", title: "Volodymyr Zelenskyy congratulates football fans",
            link: fixtureRoot.appendingPathComponent("relations/near").absoluteString, guid: "near",
            description: "Volodymyr Zelenskyy congratulated football fans after the national team won a league match.",
            pubDate: now.addingTimeInterval(-3 * 3600), source: "Publisher near")
        let window = EventStoryRelation.window / 3600
        try await copy.upsertArticles([articles[0], articles[1], near], now: now)
        for (id, hours) in [
            ("old-in", -2), ("old-out", -window - 2), ("continuing-in", -2), ("continuing-after", 0.2),
        ] {
            try await copy.upsertArticles([article(id, hours: hours)], now: now)
        }
        _ = try await copy.createEvent(memberArticleIDs: ["current"], at: now)
        let linkedEvent = try await copy.createEvent(memberArticleIDs: ["earlier"], at: now)
        let nearEvent = try await copy.createEvent(memberArticleIDs: ["near"], at: now)
        let olderEvent = try await copy.createEvent(memberArticleIDs: ["old-in", "old-out"], at: now)
        let continuingEvent = try await copy.createEvent(
            memberArticleIDs: ["continuing-in", "continuing-after"], at: now)
        await copy.close()
        let output = run.appendingPathComponent("report").path
        try await NewsTests.measureLiveRelations(
            path: run.appendingPathComponent("library.sqlite3").path, output: output)
        let rows =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: output).appendingPathComponent("relations-private.json")))
            as? [[String: String]] ?? []
        expectEqual(
            rows.filter { $0["kind"] == "link" }.map { $0["earlierEvent"] }, [linkedEvent.id],
            "The harness records the proposed link")
        expectEqual(
            rows.filter { $0["kind"] == "control" }.map { $0["earlierEvent"] }, [nearEvent.id],
            "A rejected earlier event sharing an actor is the control")
        expectTrue(rows.allSatisfy { $0["later"]?.isEmpty == false }, "Pairs carry reviewable text")
        let misses =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: output).appendingPathComponent("near-misses-private.json")))
            as? [[String: String]] ?? []
        // One candidate can miss several targets at different stages, so compare the stages each one reached.
        let missStages = Dictionary(misses.map { ($0["earlierEvent"] ?? "", Set([$0["kind"] ?? ""])) }) { $0.union($1) }
        expectTrue(
            missStages[olderEvent.id]?.contains("olderThanWindow") == true,
            "Coverage that began too early is a window stage")
        expectTrue(
            missStages[continuingEvent.id]?.contains("continuesAfterStart") == true,
            "Coverage past the target's start is a window stage")
        expectTrue(missStages[nearEvent.id] != nil, "Rejected in-window candidates join the recall sample")
        expectTrue(missStages[linkedEvent.id] == nil, "Linked candidates are not near misses")
        expectTrue(
            Dictionary(grouping: misses, by: { $0["kind"] ?? "" }).values.allSatisfy { $0.count <= 25 },
            "The recall sample keeps at most 25 candidates per stage")
        do {
            try await NewsTests.measureLiveRelations(
                path: run.appendingPathComponent("library.sqlite3").path, output: output)
            expectTrue(false, "A second run must not replace the first run's pairs")
        } catch {}
        do {
            try await NewsTests.measureLiveRelations(path: NSHomeDirectory() + "/library.sqlite3", output: output)
            expectTrue(false, "Only temporary copies are measured")
        } catch {}
    }

    static func testEventMatcherRules() async throws {
        print(
            "  - Testing conservative event matching: who/what/where/when, conflicts and whole-event compatibility...")
        let now = Date()
        func features(
            _ anchors: Set<String>, _ keywords: Set<String>, hours: Double = 0, places: Set<String> = [],
            periods: Set<String> = [], weekdays: Set<String> = [], numbers: Set<String> = [],
            language: String? = "en"
        ) -> EventFeatures {
            EventFeatures(
                language: language, organizations: anchors, places: places, keywords: keywords,
                date: now.addingTimeInterval(hours * 3600), titleNumbers: numbers, periods: periods, weekdays: weekdays)
        }
        let quake = features(
            ["afad"], ["earthquake", "magnitude", "damage", "building", "eastern"], places: ["malatya"])
        let quakeLater = features(
            ["afad"], ["earthquake", "magnitude", "damage", "resident", "eastern"], hours: 2,
            places: ["malatya", "turkey"])
        let pair = EventMatcher.assess(quake, quakeLater)
        expectTrue(pair.isMatch, "Shared names and places, shared action terms and close times match")
        expectEqual(pair.conflict, nil, "A matching pair has no contradicting facts")
        expectEqual(EventMatcher.assess(quakeLater, quake), pair, "Matching is symmetric")

        let wordingOnly = features([], ["earthquake", "magnitude", "damage", "building", "eastern"], hours: 1)
        expectFalse(
            EventMatcher.assess(quake, wordingOnly).isMatch,
            "Similar wording without a shared name or place is not enough")

        let thirdQuarter = features(["apple"], ["revenue", "record", "iphone", "sale"], periods: ["q3"])
        let fourthQuarter = features(["apple"], ["revenue", "record", "iphone", "sale"], hours: 1, periods: ["q4"])
        expectEqual(
            EventMatcher.assess(thirdQuarter, fourthQuarter).conflict, .period,
            "Quarterly reports of one company are different events")
        expectFalse(EventMatcher.assess(thirdQuarter, fourthQuarter).isMatch, "A period conflict never matches")

        // Two acts by the same actors on the same day are two events (#522); a consequence report follows its incident.
        var vote = features(["novak"], ["vote", "oust", "parliament", "minister"], places: ["ljubljana"])
        vote.actClass = .vote
        var protest = features(["novak"], ["protest", "oust", "parliament", "vote"], hours: 4, places: ["ljubljana"])
        protest.actClass = .protest
        expectEqual(EventMatcher.assess(vote, protest).conflict, .differentAct, "A vote and its protest differ")
        expectEqual(
            EventMatcher.assess(protest, vote).conflict, .differentAct, "The act conflict is symmetric")
        var unknownAct = protest
        unknownAct.actClass = .unknown
        expectEqual(EventMatcher.assess(vote, unknownAct).conflict, nil, "An unclassified headline never vetoes")
        var casualtyReport = protest
        casualtyReport.actClass = .casualties
        var resignation = vote
        resignation.actClass = .personnel
        expectEqual(
            EventMatcher.assess(resignation, casualtyReport).conflict, .differentAct,
            "A toll is no consequence of a resignation")
        expectEqual(
            EventMatcher.assess(vote, casualtyReport).conflict, nil,
            "Vote headlines use casualty words politically (\"survives no-confidence motion\"), so no veto")
        var protestElsewhere = features(
            ["novak"], ["protest", "oust", "parliament", "vote"], hours: 4, places: ["maribor"])
        protestElsewhere.actClass = .protest
        expectEqual(
            EventMatcher.assess(vote, protestElsewhere).conflict, .places,
            "Other contradictions come first: a related act is only one where nothing else conflicts")
        var shooting = vote
        shooting.actClass = .attack
        expectEqual(
            EventMatcher.assess(shooting, casualtyReport).conflict, nil, "A toll report follows the attack it counts")

        let mondayStrike = features(
            ["syniehubov"], ["drone", "strike", "apartment", "kill"], places: ["kharkiv"], weekdays: ["monday"])
        let tuesdayStrike = features(
            ["syniehubov"], ["drone", "strike", "apartment", "kill"], hours: 10, places: ["kharkiv"],
            weekdays: ["tuesday"])
        expectEqual(
            EventMatcher.assess(mondayStrike, tuesdayStrike).conflict, .weekday,
            "Strikes on different days in one region are different events")
        let threeKilled = features(["syniehubov"], ["drone", "strike", "kill"], places: ["kharkiv"], numbers: ["3"])
        let twelveHurt = features(
            ["syniehubov"], ["drone", "strike", "kill"], hours: 1, places: ["kharkiv"], numbers: ["12"])
        expectEqual(
            EventMatcher.assess(threeKilled, twelveHurt).conflict, .titleNumbers,
            "Different headline figures are kept apart")
        let odesa = features(["navy"], ["storm", "flood", "coast"], places: ["odesa"])
        let gdansk = features(["navy"], ["storm", "flood", "coast"], hours: 1, places: ["gdansk"])
        expectEqual(
            EventMatcher.assess(odesa, gdansk).conflict, .places,
            "The same kind of event in different places is not one event")
        let german = features(["afad"], quake.keywords, places: ["malatya"], language: "de")
        expectEqual(EventMatcher.assess(quake, german).conflict, .language, "Languages are not compared directly")
        let late = features(["afad"], quake.keywords, hours: 40, places: ["malatya"])
        expectEqual(EventMatcher.assess(quake, late).conflict, .timeGap, "Reports far apart in time never match")

        // #688: explicit days are calendar tokens, not figures; one publisher's series name is no evidence.
        let dated = EventFeatures(
            title: "Dockworkers to strike on October 21st, union says", description: "", date: now)
        expectEqual(dated.calendarDays, ["10-21"], "An ordinal date is a calendar day")
        expectTrue(dated.titleNumbers.isEmpty, "A date's day is not a headline figure")
        expectEqual(
            EventFeatures(title: "Port faces 21 October walkout", description: "", date: now).calendarDays, ["10-21"],
            "A day-first date reads the same")
        var dayOne = quake
        dayOne.calendarDays = ["10-21"]
        var dayTwo = quakeLater
        dayTwo.calendarDays = ["10-22"]
        expectEqual(EventMatcher.assess(dayOne, dayTwo).conflict, .calendarDay, "Different explicit days differ")
        let lead = "Catch up with the most important stories from around Europe this October 21st, 2026 - business."
        let morning = EventFeatures(
            title: "Latest news bulletin | October 21st, 2026 – Morning", description: lead, date: now)
        let evening = EventFeatures(
            title: "Latest news bulletin | October 21st, 2026 – Evening", description: lead,
            date: now.addingTimeInterval(10 * 3600))
        expectEqual(morning.series, "latest news bulletin", "The text before the separator names the series")
        expectEqual(morning.editions, ["morning"], "The edition slot is read from the headline")
        expectEqual(
            EventMatcher.assess(morning, evening, samePublisher: true).conflict, .edition,
            "Two editions of one publisher's series are two items")
        expectTrue(
            EventMatcher.assess(morning, evening).conflict != .edition, "Editions conflict only inside one series")
        var seriesFirst = quake
        seriesFirst.series = "afad daily"
        seriesFirst.seriesTerms = ["afad", "malatya"]
        var seriesSecond = quakeLater
        seriesSecond.series = "afad daily"
        expectTrue(EventMatcher.assess(seriesFirst, seriesSecond).isMatch, "Two publishers' shared names count")
        expectFalse(
            EventMatcher.assess(seriesFirst, seriesSecond, samePublisher: true).isMatch,
            "Inside one publisher's series its name is no shared evidence")
        // #741: storm names, and Title Case verbs that are not names.
        expectEqual(
            EventFeatures.stormNames(in: "Storm Darragh leaves 2,000 homes without power"), ["darragh"],
            "A named storm is read from the headline")
        expectEqual(
            EventFeatures.stormNames(in: "Storm Ellen Leaves Thousands Without Power"), ["ellen"],
            "A storm name in a Title Case headline is read too")
        expectEqual(
            EventFeatures.stormNames(in: "Storm Éowyn brings record winds to Ireland"), ["eowyn"],
            "An accented storm name is read and folded")
        expectTrue(
            EventFeatures.stormNames(in: "Storm Ciarán nears the coast")
                != EventFeatures.stormNames(in: "Storm Éowyn nears the coast"),
            "Two accented storms differ")
        expectTrue(
            EventFeatures.stormNames(in: "Winter Storm Brings Snow to Chicago").isEmpty
                && EventFeatures.stormNames(in: "Winter Storm Dumps Snow on Chicago").isEmpty
                && EventFeatures.stormNames(in: "Storm Will Hit the Coast Tonight").isEmpty,
            "A Title Case verb after Storm is no storm name")
        // #737: different places in the headlines separate reports whose descriptions mention both places.
        let kyivFire = EventFeatures(
            title: "Ukraine: firefighters battle flames and rescue dog from Kyiv ruins",
            description: "Russian strikes hit Kyiv overnight; in Kramatorsk crews also fought fires.", date: now)
        let kramatorskFire = EventFeatures(
            title: "Russians attack firefighters while they tackle blaze in Kramatorsk",
            description: "The attack came hours after Kyiv was hit and firefighters rescued a dog.",
            date: now.addingTimeInterval(3600))
        expectEqual(
            EventMatcher.assess(kyivFire, kramatorskFire).conflict, .headlinePlaces,
            "Fires in Kyiv and in Kramatorsk are two events though each description names the other city")
        let ceutaA = EventFeatures(
            title: "Moroccan police intercept migrant swimming back towards Ceuta",
            description: "Spain has deported migrants from Ceuta this week.", date: now)
        let ceutaB = EventFeatures(
            title: "Spain deports migrants from Ceuta in move criticised by rights group",
            description: "Moroccan police intercepted a migrant swimming back.", date: now.addingTimeInterval(3600))
        expectTrue(
            EventMatcher.assess(ceutaA, ceutaB).conflict != .headlinePlaces,
            "Headlines that share a place (Ceuta) are not split by their countries")
        let dieselA = EventFeatures(
            title: "Trump administration may let more Russian diesel onto market", description: "", date: now)
        let dieselB = EventFeatures(
            title: "Trump-Putin diesel deal has not lowered US fuel prices", description: "",
            date: now.addingTimeInterval(3600))
        expectTrue(
            EventMatcher.assess(dieselA, dieselB).conflict != .headlinePlaces,
            "Headlines that share a person (Trump) are not split by their countries")
        // #739: the different-day veto covers only series items with no headline date or edition word.
        var roundUpOne = quake
        roundUpOne.series = "deals"
        roundUpOne.titleSpecificAnchors = []
        var roundUpTwo = quakeLater
        roundUpTwo.series = "deals"
        roundUpTwo.titleSpecificAnchors = []
        roundUpTwo.date = roundUpOne.date.addingTimeInterval(30 * 3600)
        expectEqual(
            EventMatcher.assess(roundUpOne, roundUpTwo, samePublisher: true).conflict, .calendarDay,
            "Dateless round-ups of one series on different days are two items")
        roundUpOne.editions = ["evening"]
        roundUpTwo.editions = ["evening"]
        expectTrue(
            EventMatcher.assess(roundUpOne, roundUpTwo, samePublisher: true).conflict != .calendarDay,
            "Items with an edition word are left to the edition check")

        let followUpTerms: Set<String> = ["earthquake", "damage", "rescue", "tent", "camp", "aid", "shelter", "winter"]
        expectTrue(
            EventMatcher.assess(quake, features(["afad"], followUpTerms, hours: 2, places: ["malatya"])).isMatch,
            "Moderate overlap matches when reports are close in time")
        expectFalse(
            EventMatcher.assess(quake, features(["afad"], followUpTerms, hours: 20, places: ["malatya"])).isMatch,
            "Reports half a day apart need stronger agreement on what happened")

        // Both models are English-only (#553): a pair in another language is decided by the rules alone.
        let frenchStrike = features(["macron"], ["greve", "reforme"], language: "fr")
        let frenchStrikeLater = features(["macron"], ["greve", "retraite"], hours: 1, language: "fr")
        let frenchPair = EventMatcher.assess(frenchStrike, frenchStrikeLater, embeddingSimilarity: 0.95)
        expectTrue(frenchPair.isBorderline && !frenchPair.isMatch, "A French pair the rules leave open stays open")
        expectTrue(frenchPair.embeddingCosine == nil, "The embedding is not read for a French pair")
        expectFalse(frenchPair.neuralEligible, "A French pair is not eligible for the neural paths")
        expectFalse(EventMatcher.needsPairModel(frenchPair), "The pair model is never asked about a French pair")
        let englishStrike = features(["macron"], ["greve", "reforme"], language: "en")
        let englishStrikeLater = features(["macron"], ["greve", "retraite"], hours: 1, language: "en")
        let englishPair = EventMatcher.assess(englishStrike, englishStrikeLater, embeddingSimilarity: 0.95)
        expectTrue(englishPair.isMatch, "The same signals in English are rescued by the embedding")
        expectTrue(
            EventMatcher.needsPairModel(EventMatcher.assess(englishStrike, englishStrikeLater)),
            "Without an embedding the English pair goes to the pair model")
        expectTrue(
            EventMatcher.assess(englishStrike, features(["macron"], ["greve", "retraite"], hours: 1, language: nil))
                .neuralEligible,
            "An unrecognized language is treated like English")
        // Headline names as anchors (matcher v12, #580).
        let openAI = EventFeatures(
            title: "OpenAI says its AI agents disabled their own safety monitors",
            description: "The company said several agents switched off their monitors during a test.", date: now)
        expectTrue(
            openAI.names.contains("openai"), "A brand written with an inner capital is a name at a sentence start")
        let pope = EventFeatures(
            title: "Pope does not need further treatment after lung cancer surgery",
            description: "Doctors treating the Pope said no further treatment was needed.", date: now)
        expectTrue(
            pope.people.contains("pope") || pope.names.contains("pope"),
            "A sentence-initial word the text capitalizes mid-sentence is a name")
        let popeLeo = EventFeatures(
            title: "Pope Leo needs no further treatment after cancer surgery, doctors say", description: "", date: now)
        expectTrue(popeLeo.people.contains("pope"), "\"Pope Leo\" and \"the Pope\" share one anchor")
        let ios = EventFeatures(
            title: "iOS 27.2 introduces design changes for these Apple apps",
            description: "With the update, Apple is changing the design of several apps.", date: now)
        expectTrue(ios.names.contains("ios"), "A product written with an inner capital is a name")
        expectTrue(ios.organizations.contains("ios 27.2"), "A product and its version are one anchor")
        let titleCase = EventFeatures(
            title: "Airbnb Hosts Are Furious They Can No Longer Make Guests Do Their Chores",
            description: "Airbnb has banned hosts from asking guests to do chores like laundry and dishes.", date: now)
        expectTrue(
            titleCase.names.contains("airbnb") || titleCase.organizations.contains("airbnb"),
            "A Title Case headline keeps the names the lead corroborates")
        expectFalse(titleCase.names.contains("furious"), "… and no other capitalized word")
        let plainStart = EventFeatures(
            title: "Thousands march in Paris against pension reform",
            description: "Thousands marched in Paris on Saturday.", date: now)
        expectFalse(plainStart.names.contains("thousands"), "An ordinary sentence-initial word is still no name")

        // The pair model's input prefix (#626): the gap and the publishers in plain words, "unknown" when absent.
        expectEqual(
            EventMatcher.pairModelInput("Headline\nLead", gap: 14.4 * 3600, samePublisher: true),
            "gap 14 hours; same publisher. Headline\nLead", "Gap and one publisher")
        expectEqual(
            EventMatcher.pairModelInput("H", gap: 1.6 * 3600, samePublisher: false),
            "gap 2 hours; different publishers. H", "Rounded gap and two publishers")
        expectEqual(
            EventMatcher.pairModelInput("H", gap: nil, samePublisher: nil), "gap unknown; publishers unknown. H",
            "Public pretraining rows without dates or publishers")

        // Admission and rescue knobs measured in #582, all off in the standard policy.
        var sweep = EventMatchPolicy.standard
        let storm = features(
            ["austen", "storm austen"], ["wind", "power", "cut"], places: [EventPlaces.canonical("UK")])
        let stormLater = features(
            ["austen", "storm austen"], ["wind", "batter", "rain"], hours: 2, places: [EventPlaces.canonical("UK")])
        expectFalse(
            EventMatcher.assess(storm, stormLater, embeddingSimilarity: 0.66).isMatch,
            "Two shared names and a cosine under 0.70 are no match by default")
        sweep.twoAnchorRescueThreshold = 0.65
        expectTrue(
            EventMatcher.assess(storm, stormLater, policy: sweep, embeddingSimilarity: 0.66).isMatch,
            "The two-anchor rescue links them when switched on")
        let bare = features([], ["central", "bank", "rate", "hold"])
        let bareLater = features([], ["central", "bank", "rate", "unchanged"], hours: 1)
        expectFalse(
            EventMatcher.needsPairModel(EventMatcher.assess(bare, bareLater, embeddingSimilarity: 0.9)),
            "Without any shared anchor the pair model is not asked by default")
        sweep = EventMatchPolicy.standard
        sweep.anchorlessModelCosine = 0.85
        expectTrue(
            EventMatcher.needsPairModel(EventMatcher.assess(bare, bareLater, policy: sweep, embeddingSimilarity: 0.9)),
            "An anchorless pair at a high cosine goes to the model when switched on")
        sweep = EventMatchPolicy.standard
        sweep.compatibleRequiresMatch = true
        let open = EventMatcher.assess(englishStrike, englishStrikeLater)
        expectTrue(open.isCompatible && !open.isMatch, "A borderline pair with a shared name is compatible by default")
        expectFalse(
            EventMatcher.assess(englishStrike, englishStrikeLater, policy: sweep).isCompatible,
            "… and not when compatibility requires a match")

        let french = DatabaseEngine(path: ":memory:")
        try await french.open()
        try await french.upsertArticles([
            FeedArticle(
                storedID: "fr1", title: "Emmanuel Macron défend la réforme des retraites devant les députés",
                link: "https://corpus.invalid/fr1", guid: "fr1",
                description:
                    "Le président Emmanuel Macron a défendu mardi sa réforme des retraites devant les députés à Paris, "
                    + "alors que les syndicats appellent à une nouvelle journée de grève dans tout le pays.",
                pubDate: now.addingTimeInterval(-7200), source: "Journal Un"),
            FeedArticle(
                storedID: "fr2", title: "Retraites : Macron maintient sa réforme malgré la grève",
                link: "https://corpus.invalid/fr2", guid: "fr2",
                description:
                    "Emmanuel Macron maintient la réforme des retraites malgré la grève des syndicats, a indiqué "
                    + "l'Élysée mardi à Paris, tandis que les députés débattent du texte.",
                pubDate: now.addingTimeInterval(-3600), source: "Gazette Deux"),
        ])
        _ = try await EventClusterer.run(
            in: french, now: now,
            scoring: EventClusterScoring(pairProbability: { _, _ in
                expectTrue(false, "The pair model is never called for French reports")
                return 1.0
            }))
        await french.close()

        // A≈B and B≈C while A contradicts C: C cannot join an event that holds A and B.
        let a = features(
            ["afad"], ["earthquake", "magnitude", "damage", "building"], places: ["malatya"], weekdays: ["monday"])
        let b = features(
            ["afad"], ["earthquake", "magnitude", "damage", "building", "aid", "rescue", "tent"], hours: 1,
            places: ["malatya"])
        let c = features(
            ["afad"], ["aid", "rescue", "tent", "donation"], hours: 2, places: ["malatya"], weekdays: ["tuesday"])
        expectTrue(
            EventMatcher.assess(a, b).isMatch && EventMatcher.assess(b, c).isMatch, "Chain fixture: neighbours match")
        expectTrue(EventMatcher.eventScore(for: c, members: [b]) != nil, "C fits an event holding only B")
        expectTrue(
            EventMatcher.eventScore(for: c, members: [a, b]) == nil, "Whole-event compatibility stops the chain A≈B≈C")
        expectTrue(
            EventMatcher.eventScore(for: quakeLater, members: [quake], excluded: true) == nil,
            "A local exclusion always wins")
        var capped = EventMatchPolicy.standard
        capped.maximumEventSize = 1
        expectTrue(
            EventMatcher.eventScore(for: quakeLater, members: [quake], policy: capped) == nil,
            "Events stop growing at their size bound")

        let extracted = EventFeatures(
            title: "Apple reports record third-quarter revenue in 2026",
            description:
                "<p>Apple said on Thursday that revenue in its fiscal Q3 rose, officials in Cupertino said.</p>",
            date: now)
        expectTrue(extracted.periods.contains("q3"), "Quarter phrases and Q3 tokens become periods")
        expectTrue(extracted.weekdays.contains("thursday"), "Weekdays are explicit when-signals")
        expectTrue(extracted.years.contains("2026"), "Years are explicit when-signals")
        expectTrue(extracted.titleNumbers.isEmpty, "Years are not headline figures")
        expectFalse(
            extracted.keywords.contains("say") || extracted.keywords.contains("said"),
            "Reporting verbs are not evidence")
        expectFalse(extracted.keywords.contains { $0.contains("<") || $0 == "p" }, "Markup is not evidence")
        expectTrue(
            extracted.anchors.contains("cupertino"), "Mid-sentence names are anchors even when the tagger misses them")
        let toll = EventFeatures(title: "Drone strike kills three in Kharkiv", description: "", date: now)
        expectEqual(toll.tollNumbers, ["3"], "Spelled casualty figures are tolls")
        expectTrue(toll.titleNumbers.isEmpty, "Casualty tolls are not distinguishing headline figures")
        expectTrue(toll.anchors.contains("kharkiv"), "Places in a headline are anchors")
        let magnitude = EventFeatures(title: "Magnitude 6 earthquake hits Malatya", description: "", date: now)
        expectEqual(magnitude.titleNumbers, ["6"], "Other headline figures still tell incidents apart")

        // Updated tolls of one attack match; the same toll wording elsewhere does not erase a place conflict.
        let twelve = EventFeatures(
            title: "Russian attack on Ukraine’s Kramatorsk kills at least 12 people",
            description: "A missile strike hit buses in the eastern city of Kramatorsk in Donetsk region.", date: now)
        let thirty = EventFeatures(
            title: "Russian attack on bus kills at least 30 people near Ukraine frontline",
            description: "The strike on Kramatorsk buses in Donetsk region killed civilians.",
            date: now.addingTimeInterval(2 * 3600))
        expectEqual(twelve.tollNumbers, ["12"], "Digits before a casualty word are a toll")
        expectEqual(thirty.tollNumbers, ["30"], "Digits after 'kills at least' are a toll")
        expectTrue(
            EventMatcher.assess(twelve, thirty).conflict != .titleNumbers, "Rising tolls of one attack do not conflict")

        // Places: aliases and nationality adjectives resolve to one country; city against country is not a conflict.
        expectEqual(
            EventPlaces.canonical("U.S."), EventPlaces.canonical("American"), "U.S. and American are one country")
        expectEqual(EventPlaces.canonical("Spanish"), EventPlaces.canonical("Spain"), "Spanish means Spain")
        expectEqual(EventPlaces.canonical("Madrid"), "madrid", "Cities stay names")
        let spain = features(
            ["abascal"], ["eviction", "pensioner", "housing", "protest"], places: [EventPlaces.canonical("Spain")])
        let madrid = features(
            ["abascal"], ["eviction", "pensioner", "housing", "protest"], hours: 1, places: ["madrid"])
        expectTrue(
            EventMatcher.assess(spain, madrid).isMatch, "A city and its story's country are not contradicting places")
        let ukraine = features(["kramatorsk"], ["strike", "bus", "kill"], places: [EventPlaces.canonical("Ukraine")])
        let syria = features(
            ["kramatorsk"], ["strike", "drone", "market"], hours: 1, places: [EventPlaces.canonical("Syria")])
        expectEqual(EventMatcher.assess(ukraine, syria).conflict, .places, "Different countries conflict")
        let syriaSameWords = features(
            ["kramatorsk"], ["strike", "bus", "kill"], hours: 1, places: [EventPlaces.canonical("Syria")])
        expectEqual(
            EventMatcher.assess(ukraine, syriaSameWords).conflict, .places,
            "Strong wording cannot soften a country conflict")
        expectFalse(EventMatcher.assess(ukraine, syriaSameWords).isMatch, "A country conflict never matches")
        expectTrue(
            EventMatcher.assess(odesa, gdansk).conflict != nil,
            "Conflicting places remain a veto with one shared name")
        // Three shared specific names outweigh one mistyped place (#580): a match report and its live blog share the
        // teams and players while the tagger reads a player's name as a place.
        let matchReport = features(
            ["real madrid", "rb leipzig", "mbappe"], ["score", "win", "thrash"], places: ["leipzig"])
        let liveBlog = features(
            ["real madrid", "rb leipzig", "mbappe"], ["live", "score", "win"], hours: 1, places: ["bellingham"])
        expectEqual(
            EventMatcher.assess(matchReport, liveBlog).conflict, nil,
            "A place conflict needs fewer than three shared specific names")
        let canadian = EventFeatures(
            title: "Canadian writer Anne Carson wins 2026 Nobel Prize in Literature", description: "", date: now)
        expectTrue(
            canadian.countries.contains(EventPlaces.canonical("Canada")),
            "An untyped nationality adjective is a country")

        // A compatible majority cannot override hard contradictions.
        let d = features(
            ["afad"], ["earthquake", "magnitude", "damage", "building", "aid"], hours: 1, places: ["malatya"])
        expectTrue(
            EventMatcher.eventScore(for: c, members: [a, b, d]) == nil,
            "A weekday conflict vetoes admission even with two of three compatible members")
        expectTrue(
            EventMatcher.eventScore(for: c, members: [a, b]) == nil, "Both members of a two-member event must agree")
        var weak = pair
        weak.isCompatible = false
        weak.isMatch = false
        weak.score = 0.5
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, pair, weak]) != nil,
            "A noncontradictory weak minority remains allowed")
        var generic = weak
        generic.sharedSpecificAnchors = 0
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, pair, generic]) == nil,
            "Two-thirds compatibility cannot override missing specific evidence on a cross-pair")
        var undated = quake
        undated.date = DateParser.unknownDate
        expectEqual(
            EventMatcher.assess(undated, quakeLater).conflict, .unknownDate, "Unknown publication times cannot match")
        for conflict in [EventConflict.language, .timeGap, .period, .year, .weekday, .excluded] {
            var hard = pair
            hard.conflict = conflict
            hard.isMatch = false
            hard.isCompatible = false
            expectTrue(
                EventMatcher.eventScore(pairs: [pair, pair, hard]) == nil,
                "A hard \(conflict) minority vetoes admission")
        }

        // Veto threshold (#737, evaluation): one semantic veto among three cross-pairs is outvoted only when switched on.
        var diverging = pair
        diverging.conflict = .semanticDivergence
        diverging.isMatch = false
        diverging.isCompatible = false
        var vetoMinimum = EventMatchPolicy.standard
        vetoMinimum.vetoMinimum = 2
        var vetoShare = EventMatchPolicy.standard
        vetoShare.vetoShare = 0.34
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, pair, diverging]) == nil, "One semantic veto blocks by default")
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, pair, diverging], policy: vetoMinimum) != nil,
            "One semantic veto is outvoted when two are required")
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, pair, diverging], policy: vetoShare) != nil,
            "One veto in three is not more than a 0.34 share")
        // Edition-aware admission (#737, evaluation): an edition enters through its matched pair, its other items raising
        // no veto, and does not count toward the two-thirds rule of other reports.
        var editionPolicy = EventMatchPolicy.standard
        editionPolicy.editionAdmission = true
        var editionMatch = pair
        editionMatch.rowIsEdition = true
        var editionItem = diverging
        editionItem.rowIsEdition = true
        expectTrue(
            EventMatcher.eventScore(pairs: [editionMatch, editionItem, editionItem]) == nil,
            "An edition's other items veto by default")
        expectTrue(
            EventMatcher.eventScore(pairs: [editionMatch, editionItem, editionItem], policy: editionPolicy) != nil,
            "An edition joins through its matched pair")
        expectTrue(
            EventMatcher.eventScore(pairs: [editionItem, editionItem], policy: editionPolicy) == nil,
            "An edition without a matched pair stays out")
        var editionMember = diverging
        editionMember.memberIsEdition = true
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, editionMember]) == nil, "An edition member vetoes by default")
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, editionMember], policy: editionPolicy) != nil,
            "An edition member does not count against a report")
        expectTrue(
            EventMatcher.eventScore(pairs: [editionMember], policy: editionPolicy) == nil,
            "A member that is only an edition still has to match")
        var matchedEdition = pair
        matchedEdition.memberIsEdition = true
        expectTrue(
            EventMatcher.eventScore(pairs: [matchedEdition, diverging], policy: editionPolicy) == nil,
            "A match with the edition alone carries no report into its host")
        expectFalse(
            EventMatcher.forced(editionMember, policy: editionPolicy).memberIsEdition,
            "A reader's inclusion with an edition keeps counting")
        var placed = diverging
        placed.conflict = .places
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, pair, pair, diverging, placed], policy: vetoMinimum) == nil,
            "Two vetoes of either outvotable kind block under the minimum")
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, pair, pair, pair, pair, diverging, placed], policy: vetoShare) != nil
                && EventMatcher.eventScore(pairs: [pair, pair, diverging, placed], policy: vetoShare) == nil,
            "The share counts both kinds against all cross-pairs")
        // A places conflict that also names different headline places stays absolute: the veto never sees it outvoted.
        // The place fields are set directly so the case does not hang on the tagger.
        var kyivBlaze = EventFeatures(
            title: "Fire destroys a warehouse", description: "Firefighters fought the blaze for six hours.", date: now)
        var lyonBlaze = EventFeatures(
            title: "Fire destroys a warehouse", description: "Firefighters fought the blaze for six hours.",
            date: now.addingTimeInterval(600))
        (kyivBlaze.places, kyivBlaze.titlePlaces) = (["@UA", "kyiv"], ["@UA", "kyiv"])
        (lyonBlaze.places, lyonBlaze.titlePlaces) = (["@FR", "lyon"], ["@FR", "lyon"])
        (kyivBlaze.titleSpecificAnchors, lyonBlaze.titleSpecificAnchors) = ([], [])
        expectEqual(EventMatcher.assess(kyivBlaze, lyonBlaze).conflict, .places, "Disjoint countries are a places veto")
        let maskedPlaces = EventMatcher.assess(kyivBlaze, lyonBlaze, policy: vetoMinimum)
        expectTrue(
            maskedPlaces.conflict == .places && maskedPlaces.masksAbsoluteConflict,
            "Under the veto threshold the conflict stays places, so story links keep the veto, and is marked absolute")
        expectTrue(
            EventMatcher.conflictsBlock([pair, pair, pair, maskedPlaces], policy: vetoMinimum),
            "A places veto with a headline conflict behind it is not outvoted")
        expectTrue(
            !EventMatcher.conflictsBlock(
                [pair, EventMatcher.forced(maskedPlaces, policy: vetoMinimum)], policy: vetoMinimum),
            "A reader's Same Event verdict clears the absolute mask too, so revalidation keeps the pair")
        var weekday = diverging
        weekday.conflict = .weekday
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, pair, weekday], policy: vetoMinimum) == nil,
            "Other conflicts stay absolute under the veto threshold")

        // Borderline floor (#737, evaluation): a compatible borderline pair the pair model scores low needs three names.
        var borderline = pair
        borderline.isMatch = false
        borderline.sharedSpecificAnchors = 1
        var floor = EventMatchPolicy.standard
        floor.borderlineFloor = 0.5
        let defaultFloor = EventMatcher.applyingBorderlineFloor(borderline, probability: 0.3)
        expectTrue(
            defaultFloor.isCompatible && EventMatcher.eventScore(pairs: [pair, defaultFloor]) != nil,
            "A low-scored borderline pair is compatible by default")
        let floored = EventMatcher.applyingBorderlineFloor(borderline, probability: 0.3, policy: floor)
        expectTrue(
            EventMatcher.eventScore(pairs: [pair, floored], policy: floor) == nil,
            "Below the floor with one shared name it no longer carries the join")
        var named = borderline
        named.sharedSpecificAnchors = 3
        expectTrue(
            EventMatcher.applyingBorderlineFloor(named, probability: 0.3, policy: floor).isCompatible
                && EventMatcher.applyingBorderlineFloor(borderline, probability: 0.6, policy: floor).isCompatible
                && EventMatcher.applyingBorderlineFloor(borderline, probability: nil, policy: floor).isCompatible,
            "Three shared names, a score at the floor or no score leave the pair compatible")

        // #307 bounded corrections: background-clause false merges, cross-tagged anchors and false place/weekday vetoes.
        let bridgeStrike = EventFeatures(
            title: "Russia hits second major bridge in Ukraine's capital Kyiv",
            description:
                "The strike on the Pivnichnyi (Northern) Bridge comes after repeat attacks on another major bridge in Ukraine's capital.",
            date: now)
        let pontoonFollowUp = EventFeatures(
            title: "Pontoon crossings coming to Kyiv following Russian strikes on key bridges, media reports",
            description:
                "A Ukrainian official said that the construction of pontoon crossings could take up to three months and would help traffic move through the capital, which remains heavily restricted after multiple bridge attacks.",
            date: now.addingTimeInterval(1800))
        let pontoonPlan = EventFeatures(
            title:
                "Kyiv is preparing pontoon crossings in case of bridge strikes and planning tunnel under Dnipro River – minister",
            description:
                "Ukraine's Recovery Minister Mykola Kalashnyk has announced plans to build reserve pontoon crossings and potentially a tunnel under the Dnipro River in Kyiv.",
            date: now.addingTimeInterval(-3600))
        expectFalse(
            EventMatcher.assess(pontoonFollowUp, bridgeStrike).isMatch
                || EventMatcher.assess(pontoonFollowUp, bridgeStrike).isCompatible,
            "A follow-up plan whose primary headline clause shares only a city with a prior strike must not merge into the strike"
        )
        expectTrue(
            EventMatcher.assess(pontoonFollowUp, pontoonPlan).isMatch,
            "Reports sharing the primary headline subject and action still match")

        let lowerBrand = EventFeatures(
            title: "‘I was fighting for my life’: Indian pilot hailed as hero recalls flydubai cockpit attack",
            description:
                "The Indian pilot who helped thwart an apparent attempt to crash a flydubai flight to Tel Aviv said his faith allowed him to open the cockpit door.",
            date: now)
        let camelBrand = EventFeatures(
            title: "'I was fighting for my life': Indian pilot hailed as hero recalls FlyDubai cockpit attack",
            description:
                "The Indian airline captain who helped thwart an apparent attempt to crash a FlyDubai flight described Friday how he fought for his life after his co-pilot stabbed him.",
            date: now.addingTimeInterval(3600))
        expectTrue(
            EventMatcher.assess(lowerBrand, camelBrand).isMatch,
            "Case differences on an untyped brand name still count as shared specific evidence")

        let fairfordPlace = EventFeatures(
            title: "UK-Iran national arrested over alleged bomb plot at RAF Fairford released on bail",
            description:
                "A sixth man who was arrested in connection with a suspected terrorist plot at RAF Fairford has been released on bail. The 25-year-old, a dual UK-Iranian national, was arrested on suspicion of preparing terrorist acts.",
            date: now)
        let fairfordOrg = EventFeatures(
            title: "Man arrested for alleged terror threat on US airbase RAF Fairford released on bail",
            description:
                "The U.K.-Iranian dual national who was arrested in connection with an alleged terror threat against a U.S.-operated military base in England was released on bail, British authorities confirmed Saturday.",
            date: now.addingTimeInterval(2 * 3600))
        expectTrue(
            EventMatcher.assess(fairfordPlace, fairfordOrg).isMatch,
            "Shared base and hyphenated dual nationality match without a tagger category-flip place conflict")

        let g7First = EventFeatures(
            title: "G7 nations agree to release 100 million barrels of oil, including diesel, boost for Trump",
            description:
                "The national average for a gallon of diesel in the U.S. was $6.37 on Friday, according to AAA.",
            date: now)
        let g7Second = EventFeatures(
            title: "G7 nations agree to release 100 million barrels of oil, including diesel, amid energy crunch",
            description:
                "The release would begin immediately and take four months, starting with a substantial diesel release.",
            date: now.addingTimeInterval(900))
        expectTrue(
            EventMatcher.assess(g7First, g7Second).isMatch,
            "Alphanumeric group names like G7 act as specific anchors rather than headline figures")

        let demonymReport = EventFeatures(
            title: "Americans and Iranians meet in UAE for talks",
            description: "Palestinians and Saudis also watched the diplomatic session closely.",
            date: now)
        expectTrue(
            demonymReport.countries.isSuperset(of: ["@US", "@IR", "@AE", "@PS", "@SA"]),
            "Plural demonyms and UAE canonicalize to country codes")

        let figureFirst = EventFeatures(
            title: "Amazon pledges 500 scholarships for engineering students",
            description: "Amazon announced the scholarship fund for university students.",
            date: now)
        let figureSecond = EventFeatures(
            title: "Amazon backs 500 student grants at universities",
            description: "The company unveiled the 500 awards for students.",
            date: now.addingTimeInterval(600))
        expectTrue(
            !figureFirst.titleNumbers.intersection(figureSecond.titleNumbers).isEmpty
                && EventMatcher.assess(figureFirst, figureSecond).sharedAnchors >= 1,
            "Shared headline figures are retained on both reports to corroborate lexical evidence")

        let leadingClause = EventFeatures(
            title: "Hours after winning architectural award, developer launches new housing project",
            description: "The developer unveiled plans for the residential tower.",
            date: now)
        expectTrue(
            leadingClause.primaryTitleTerms.contains("developer")
                && !leadingClause.primaryTitleTerms.contains("architectural"),
            "Leading temporal background clause is excluded from primaryTitleTerms")
        let wakeClause = EventFeatures(
            title: "Regulators tighten ferry inspections in the wake of harbor collision",
            description: "Maritime officials ordered new safety checks across the fleet.",
            date: now)
        expectTrue(
            wakeClause.primaryTitleTerms.contains("ferry")
                && !wakeClause.primaryTitleTerms.contains("collision"),
            "Trailing 'in the wake of' background clause is excluded from primaryTitleTerms")

        // Supported leading connector forms and punctuation delimiters:
        let followingLeading = EventFeatures(
            title: "Following summit, President announces ceasefire accord",
            description: "The leaders signed the diplomatic agreement.", date: now)
        expectTrue(
            !followingLeading.primaryTitleTerms.isEmpty
                && !followingLeading.primaryTitleTerms.contains("summit"),
            "Leading 'Following <clause>,' isolates primary clause terms")

        let daysAfterLeading = EventFeatures(
            title: "Days after volcano eruption, flights resume across archipelago",
            description: "Airlines restored service as ash clouds cleared.", date: now)
        expectTrue(
            daysAfterLeading.primaryTitleTerms.contains("resume")
                && !daysAfterLeading.primaryTitleTerms.contains("volcano"),
            "Leading 'Days after <clause>,' isolates primary clause terms")

        let colonLeading = EventFeatures(
            title: "Shortly after verdict: protesters gather outside courthouse",
            description: "Crowds assembled following the judge's ruling.", date: now)
        expectTrue(
            !colonLeading.primaryTitleTerms.isEmpty
                && !colonLeading.primaryTitleTerms.contains("verdict"),
            "Leading connector with colon delimiter isolates primary clause")

        // Hardening (#502–#504): shared matching text, consequence-only primary clauses, person tokens.
        let plainText = EventFeatures.matchingText(
            title: "A <b>bold</b>\nheadline", description: "<p>Lead &amp; more</p><img src=\"x\">")
        expectTrue(
            !plainText.contains("<") && plainText.contains("Lead & more") && plainText.hasPrefix("A ")
                && plainText.filter(\.isNewline).count == 1,
            "Matching text strips markup and entities and keeps one headline line")
        let tollAfter = EventFeatures(
            title: "Three dead after gunman opens fire at Westfield mall in Sydney",
            description:
                "Police said a gunman shot shoppers at the Westfield Bondi Junction mall in Sydney on Saturday before an officer shot him dead.",
            date: now)
        expectTrue(
            tollAfter.primaryTitleTerms.isEmpty,
            "A primary clause that only counts the dead names no act of its own")
        let namedGunman = EventFeatures(
            title: "Sydney mall shooting: police name Westfield gunman",
            description:
                "New South Wales police identified the gunman who shot shoppers at Westfield Bondi Junction in Sydney before an officer shot him.",
            date: now.addingTimeInterval(2 * 3600))
        expectTrue(
            EventMatcher.assess(tollAfter, namedGunman).isMatch,
            "A toll-after headline matches the report that leads with the shooting itself")
        expectFalse(
            EventMatcher.assess(pontoonFollowUp, bridgeStrike).isCompatible,
            "A primary clause that names an act keeps the background-clause guard")
        let jordan = EventFeatures(
            title: "Michael Jordan returns to Chicago for championship ceremony",
            description: "The former Chicago Bulls star Michael Jordan attended the ceremony at the United Center.",
            date: now)
        expectFalse(jordan.countries.contains("@JO"), "A word of a typed person name is never a country")

        let emDashLeading = EventFeatures(
            title: "Soon after power outage — subway lines reopen across city",
            description: "Transit authorities restored train operations.", date: now)
        expectTrue(
            !emDashLeading.primaryTitleTerms.isEmpty
                && !emDashLeading.primaryTitleTerms.contains("outage"),
            "Leading connector with em-dash delimiter isolates primary clause")

        let enDashLeading = EventFeatures(
            title: "Just after rocket launch – satellites achieve orbit successfully",
            description: "Space agency confirmed payload separation.", date: now)
        expectTrue(
            !enDashLeading.primaryTitleTerms.isEmpty
                && !enDashLeading.primaryTitleTerms.contains("launch"),
            "Leading connector with en-dash delimiter isolates primary clause")

        // Supported trailing connector forms:
        let followingTrailing = EventFeatures(
            title: "Port workers end strike following mediation agreement",
            description: "Labor union reached deal with terminal operators.", date: now)
        expectTrue(
            followingTrailing.primaryTitleTerms.contains("strike")
                && !followingTrailing.primaryTitleTerms.contains("mediation"),
            "Trailing 'following' background clause is excluded from primaryTitleTerms")

        let shortlyAfterTrailing = EventFeatures(
            title: "Bridge reopens shortly after inspection check",
            description: "Engineers cleared the crossing for vehicle traffic.", date: now)
        expectTrue(
            !shortlyAfterTrailing.primaryTitleTerms.isEmpty
                && !shortlyAfterTrailing.primaryTitleTerms.contains("inspection"),
            "Trailing 'shortly after' background clause is excluded from primaryTitleTerms")

        let afterTrailing = EventFeatures(
            title: "Factory restarts operations after gas leak contained",
            description: "Safety inspectors allowed workers to return to the facility.", date: now)
        expectTrue(
            !afterTrailing.primaryTitleTerms.isEmpty
                && !afterTrailing.primaryTitleTerms.contains("contained"),
            "Trailing 'after' background clause is excluded from primaryTitleTerms")

        // Unicode and edge-case robustness:
        let unicodeAccented = EventFeatures(
            title: "Café chain expands across Madrid — hours after regional approval",
            description: "The coffee retailer opened five new storefronts in the capital.", date: now)
        expectTrue(
            !unicodeAccented.primaryTitleTerms.isEmpty
                && !unicodeAccented.primaryTitleTerms.contains("approval"),
            "Accented characters and em-dashes maintain safe Unicode range alignment")

        let unicodeEmoji = EventFeatures(
            title: "🚨 Hospitals prepare emergency wards following toxic chemical spill",
            description: "Medical teams mobilized across the province.", date: now)
        expectTrue(
            !unicodeEmoji.primaryTitleTerms.isEmpty
                && !unicodeEmoji.primaryTitleTerms.contains("spill"),
            "Surrogate pair emojis do not panic string indexing in background clause extraction")

        let plainHeadline = EventFeatures(
            title: "Telecom provider rolls out fiber network in suburban districts",
            description: "Broadband speeds doubled for residential subscribers.", date: now)
        expectTrue(
            plainHeadline.primaryTitleTerms.isEmpty,
            "Headlines without background clauses leave primaryTitleTerms empty")
    }

    static func testEventFragmentMergingAndJudge(fixtureRoot: URL) async throws {
        print("  - Testing fragment merging, the judge contract and its fallback...")
        let now = Date()
        func article(_ id: String, _ title: String, _ description: String, hoursAgo: Double, source: String)
            -> FeedArticle
        {
            FeedArticle(
                storedID: id, title: title, link: fixtureRoot.appendingPathComponent("merge/\(id)").absoluteString,
                guid: id, description: description, pubDate: now.addingTimeInterval(-hoursAgo * 3600), source: source)
        }
        let quake = [
            article(
                "m1", "Magnitude 7 earthquake strikes Malatya in eastern Turkey",
                "The disaster agency AFAD said buildings collapsed in Malatya after the earthquake struck eastern Turkey.",
                hoursAgo: 3, source: "Wire One"),
            article(
                "m2", "Malatya earthquake: AFAD says buildings collapsed",
                "A magnitude 7 earthquake struck Malatya in eastern Turkey and buildings collapsed, AFAD said.",
                hoursAgo: 2.5, source: "Daily Two"),
            article(
                "m3", "Rescuers search collapsed buildings after Malatya earthquake",
                "AFAD rescuers searched collapsed buildings in Malatya after the earthquake struck eastern Turkey.",
                hoursAgo: 2, source: "Herald Three"),
            article(
                "m4", "Eastern Turkey earthquake: buildings collapse in Malatya, AFAD says",
                "Buildings collapsed in Malatya when the earthquake struck eastern Turkey, AFAD said.", hoursAgo: 1.5,
                source: "Courier Four"),
        ]
        func library() async throws -> DatabaseEngine {
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            try await db.upsertArticles(quake)
            // Two fragments of one story, as left by passes that ran before the linking reports arrived.
            _ = try await db.createEvent(memberArticleIDs: ["m1", "m2"], at: now)
            _ = try await db.createEvent(memberArticleIDs: ["m3", "m4"], at: now)
            try await db.markEventMatchProcessed(quake.map(\.id), matcherVersion: EventMatcher.version, at: now)
            return db
        }

        let db = try await library()
        let report = try await EventClusterer.run(in: db, now: now)
        expectEqual(report.merged, 1, "Fragments of one story merge without a judge when member pairs decide")
        expectEqual(
            try await db.eventID(forArticle: "m1"), try await db.eventID(forArticle: "m4"),
            "The merged event holds both fragments")
        expectEqual(try await EventClusterer.run(in: db, now: now).merged, 0, "A merged story is not merged again")
        await db.close()

        let forming = DatabaseEngine(path: ":memory:")
        try await forming.open()
        try await forming.upsertArticles(Array(quake.prefix(3)))
        _ = try await EventClusterer.run(in: forming, now: now)
        let seedID = try await forming.eventID(forArticle: "m1")
        expectTrue(seedID != nil, "Three independently worded reports still form an event")
        expectEqual(try await forming.eventID(forArticle: "m2"), seedID, "Second publisher joins")
        expectEqual(try await forming.eventID(forArticle: "m3"), seedID, "Third publisher joins")
        await forming.close()

        let vetoed = try await library()
        let vetoReport = try await EventClusterer.run(in: vetoed, now: now, limit: 0)
        expectEqual(vetoReport.merged, 1, "Supported fragments merge deterministically")
        await vetoed.close()

        // Newly merged members supply the terms needed to discover a third fragment.
        let chain = DatabaseEngine(path: ":memory:")
        try await chain.open()
        let titles = [
            "Aurora Meridian growers harvest apples",
            "Aurora Meridian growers harvest apples with Cobalt Zenith harvest robots",
            "Cobalt Zenith engineers deploy harvest robots",
        ]
        var groups: [[FeedArticle]] = []
        for (group, count) in [6, 4, 2].enumerated() {
            let members = (0..<count).map { index in
                article(
                    "chain-\(group)-\(index)", titles[group], "Scientists report that \(titles[group]).",
                    hoursAgo: 1, source: "Publisher \(group)-\(index)")
            }
            groups.append(members)
            try await chain.upsertArticles(members)
            _ = try await chain.createEvent(memberArticleIDs: members.map(\.id), at: now)
        }
        func terms(_ story: FeedArticle) -> Set<String> {
            let value = EventFeatures(title: story.title, description: story.description, date: now)
            return value.specificAnchors.union(value.keywords)
        }
        expectTrue(
            terms(groups[0][0]).intersection(terms(groups[2][0])).count < 2,
            "The third fragment requires terms introduced by the second")
        var chainPolicy = EventMatchPolicy.standard
        chainPolicy.minimumSharedTerms = 2
        chainPolicy.matchScore = 0.35
        chainPolicy.compatibilityScore = 0
        chainPolicy.compatibleShare = 0
        let chainReport = try await EventClusterer.run(in: chain, matchPolicy: chainPolicy, now: now, limit: 0)
        expectEqual(chainReport.merged, 1, "New vocabulary cannot bridge a cross-pair without shared specific evidence")
        await chain.close()

        // #1302: the bridge is the smallest fragment, so it merges after the middle one was skipped. The middle one
        // is reachable only through the bridge's terms and must still be merged in the same pass.
        let bridged = DatabaseEngine(path: ":memory:")
        try await bridged.open()
        let bridgeTitles = [
            "Growers in Meridian harvest apples",
            "Meridian orchard picking season begins",
            "Growers in Meridian harvest apples as orchard picking season begins",
        ]
        var bridgeGroups: [[FeedArticle]] = []
        for (group, count) in [6, 4, 2].enumerated() {
            let members = (0..<count).map { index in
                article(
                    "bridge-\(group)-\(index)", bridgeTitles[group], bridgeTitles[group],
                    hoursAgo: 1, source: "Publisher \(group)-\(index)")
            }
            bridgeGroups.append(members)
            try await bridged.upsertArticles(members)
            _ = try await bridged.createEvent(memberArticleIDs: members.map(\.id), at: now)
        }
        let largeAndMiddle = terms(bridgeGroups[0][0]).intersection(terms(bridgeGroups[1][0])).count
        expectTrue(largeAndMiddle < 2, "The middle fragment is skipped at first: \(largeAndMiddle) shared terms")
        expectTrue(
            terms(bridgeGroups[0][0]).union(terms(bridgeGroups[2][0])).intersection(terms(bridgeGroups[1][0])).count
                >= 2,
            "With the bridge's terms the middle fragment is reachable")
        let bridgeReport = try await EventClusterer.run(in: bridged, matchPolicy: chainPolicy, now: now, limit: 0)
        expectEqual(
            bridgeReport.merged, 2, "A fragment that becomes reachable through a later merge joins in the same pass")
        expectEqual(
            try await bridged.eventID(forArticle: "bridge-1-0"), try await bridged.eventID(forArticle: "bridge-0-0"),
            "The middle fragment ends in the survivor's event")
        await bridged.close()

        // A local exclusion between fragments always wins.
        let excluded = try await library()
        if let event = try await excluded.eventID(forArticle: "m3") {
            _ = try await excluded.addArticles(["m1"], toEvent: event, at: now)
            try await excluded.separateArticle("m1", fromEvent: event, at: now)
        }
        _ = try await excluded.addArticles(["m1"], toEvent: try await excluded.eventID(forArticle: "m2") ?? "", at: now)
        let exclusions = try await excluded.eventExclusions(for: quake.map(\.id) + (0..<450).map { "a-missing-\($0)" })
        expectEqual(exclusions["m1"], Set(["m3", "m4"]), "Bulk exclusions span SQLite parameter batches")
        expectEqual(exclusions["m3"], Set(["m1"]), "Bulk exclusions work from either endpoint")
        expectEqual(exclusions["m4"], Set(["m1"]), "Repeated rows across batches do not duplicate exclusions")
        expectEqual(exclusions.count, 3, "Unknown and unexcluded members create no exclusion entries")
        expectTrue(try await excluded.eventExclusions(for: []).isEmpty, "An empty member set needs no exclusion query")
        expectEqual(
            try await EventClusterer.run(in: excluded, now: now).merged, 0, "Excluded members keep fragments apart")
        await excluded.close()

        // A country conflict never links a pair, even one the rules otherwise leave open.
        let hard = DatabaseEngine(path: ":memory:")
        try await hard.open()
        try await hard.upsertArticles([
            article(
                "h1", "Drone strike hits market in Kharkiv, Ukraine",
                "A drone strike hit a market in Kharkiv in Ukraine.", hoursAgo: 2, source: "Wire One"),
            article(
                "h2", "Drone strike hits market in Idlib, Syria", "A drone strike hit a market in Idlib in Syria.",
                hoursAgo: 1, source: "Daily Two"),
        ])
        let hardReport = try await EventClusterer.run(in: hard, now: now)
        expectTrue(
            try await hard.eventID(forArticle: "h1") == nil, "Reports of strikes in different countries stay apart")
        expectEqual(hardReport.created, 0, "No event forms across a country conflict")
        await hard.close()
    }

    @MainActor
    static func testStoryVisibility(fixtureRoot: URL) async throws {
        print("  - Testing stored importance, visible stories, retained history and retired expiry...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let now = Date()
        func story(_ id: String, _ source: String, hoursAgo: Double = 1) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Story \(id) headline",
                link: fixtureRoot.appendingPathComponent("visibility/\(id)").absoluteString,
                guid: id, description: "Summary of \(id).", pubDate: now.addingTimeInterval(-hoursAgo * 3600),
                source: source)
        }
        let all = [
            story("minor", "One"), story("major", "One"), story("unrated", "One"), story("saved", "One"),
            story("read", "One"),
            story("pair-1", "One"), story("pair-2", "Two"),
            story("wide-1", "One"), story("wide-2", "Two"), story("wide-3", "Three"), story("wide-4", "Four"),
        ]
        try await db.upsertArticles(all)
        _ = try await db.createEvent(memberArticleIDs: ["pair-1", "pair-2"], at: now)
        _ = try await db.createEvent(memberArticleIDs: ["wide-1", "wide-2", "wide-3", "wide-4"], at: now)
        for id in ["minor", "saved", "read", "pair-1", "pair-2", "wide-1", "wide-2", "wide-3", "wide-4"] {
            try await db.recordImportance(id, .minor, at: now)
        }
        try await db.recordImportance("major", .major, at: now)
        try await db.setSaved(articleId: "saved", isSaved: true)
        try await db.markRead(articleId: "read", isRead: true)
        func listed() async throws -> Set<String> {
            Set(
                try await db.fetchArticles(limit: nil, options: ArticleFetchOptions(hidingWaitingStories: true)).map(
                    \.id))
        }

        expectEqual(try await listed(), Set(all.map(\.id)), "Importance never hides a publication")
        expectEqual(try await db.waitingStoryCount(), 0, "No story waits for model approval")
        expectEqual(
            try await db.fetchArticles(limit: nil).count, all.count,
            "Lists that do not hide waiting stories list everything")
        try await db.recordImportance("pair-2", .notable, at: now)
        expectTrue(
            try await listed().isSuperset(of: ["pair-1", "pair-2"]), "One important report shows its whole event")
        let reviewed = Set(
            try await db.ratedImportanceRows(level: .minor, activeSince: now.addingTimeInterval(-72 * 3600)).map(\.id))
        expectEqual(
            reviewed, ["minor", "saved", "read", "pair-1", "wide-1", "wide-2", "wide-3", "wide-4"],
            "The #309 review lists every minor-rated story in the window")
        expectEqual(
            reviewed.subtracting(try await db.notificationStoryIDs(Array(reviewed))), [],
            "Minor ratings do not remove notification eligibility")
        expectTrue(
            try await db.ratedImportanceRows(level: .minor, activeSince: now).isEmpty,
            "Stories before the window are not reviewed")

        expectEqual(
            try await db.expireWaitingStories(now: now.addingTimeInterval(3600)), 0, "Nothing expires within a day")
        expectEqual(
            try await db.expireWaitingStories(now: now.addingTimeInterval(25 * 3600)), 0,
            "Importance never expires an unread story")
        expectEqual(try await listed(), Set(all.map(\.id)), "All publications remain after 24 hours")
        expectTrue(try await db.isSaved(articleId: "saved"), "Saved state remains")
        expectTrue(try await db.isRead(articleId: "read"), "Read history remains")
        let priorities = try await db.briefingPriorities(articleIDs: all.map(\.id))
        expectEqual(priorities["wide-1"]?.sourceCount, 4, "Coverage counts publishers across event members")
        expectEqual(priorities["pair-1"]?.importance, .notable, "An event uses its highest stored rating")
        expectEqual(priorities["unrated"]?.importance, nil, "Unrated metadata stays neutral")
        expectEqual(priorities["minor"]?.sourceCount, 1, "A singleton has one publisher")
        await db.close()

        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("news-expiry-\(UUID())")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        let legacyPath = legacyDirectory.appendingPathComponent("library.sqlite3").path
        let legacy = DatabaseEngine(path: legacyPath)
        try await legacy.open()
        var legacyHandle: OpaquePointer?
        expectEqual(sqlite3_open(legacyPath, &legacyHandle), SQLITE_OK, "Open old expiry fixture")
        expectEqual(
            sqlite3_exec(
                legacyHandle, "INSERT INTO expired_stories(key, expired_at) VALUES('legacy', 1);", nil, nil, nil),
            SQLITE_OK, "Preserve an old importance-expiry tombstone")
        sqlite3_close(legacyHandle)
        expectEqual(
            try await legacy.upsertArticles([story("legacy", "One")]), ["legacy"],
            "Old tombstones do not suppress feeds")
        expectEqual(try await legacy.fetchArticles(limit: nil).count, 1, "The returning publisher story is readable")
        await legacy.close()

        // Panel retention remains intact; importance no longer deletes any publisher's stories.
        let panel = DatabaseEngine(path: ":memory:")
        try await panel.open()
        let panelFeed = TensionMethodology.v1.panel[0].url
        try await panel.upsertArticles([story("panel-minor", "Panel")], feedUrl: panelFeed)
        try await panel.upsertArticles([story("other-minor", "Other")], feedUrl: "https://example.com/other.xml")
        for id in ["panel-minor", "other-minor"] { try await panel.recordImportance(id, .minor, at: now) }
        expectEqual(
            try await panel.expireWaitingStories(now: now.addingTimeInterval(25 * 3600), keepingFeedURLs: [panelFeed]),
            0,
            "Neither panel nor ordinary minor stories expire")
        let panelDay = DateInterval(start: now.addingTimeInterval(-12 * 3600), duration: 24 * 3600)
        expectEqual(
            try await panel.tensionCorpus(day: panelDay, feedURLs: [panelFeed]).map(\.article.id), ["panel-minor"],
            "The waiting panel story still counts in its tension day")
        expectEqual(
            try await panel.fetchArticles(limit: nil, options: ArticleFetchOptions(hidingWaitingStories: true)).count,
            2,
            "Panel and ordinary stories remain visible")
        let collectionOff = try await StoryCurator.run(
            in: panel, now: now.addingTimeInterval(26 * 3600))
        expectEqual(
            collectionOff.expired, 0, "Image/audit curation never expires a story, regardless of collection")
        await panel.close()

        // Audit ratings (the opt-in live curation measurement) never hide a story.
        let curated = DatabaseEngine(path: ":memory:")
        try await curated.open()
        try await curated.upsertArticles([story("c1", "One"), story("c2", "Two"), story("c3", "Three")])
        expectEqual(
            try await curated.fetchArticles(limit: nil, options: ArticleFetchOptions(hidingWaitingStories: true)).count,
            3, "Unrated stories show")
        try await curated.recordImportance("c1", .major, at: now)
        for id in ["c2", "c3"] { try await curated.recordImportance(id, .minor, at: now) }
        expectEqual(
            Set(
                try await curated.fetchArticles(limit: nil, options: ArticleFetchOptions(hidingWaitingStories: true))
                    .map(\.id)), ["c1", "c2", "c3"],
            "Explicit audit ratings cannot hide stories")
        expectEqual(
            try await curated.notificationStoryIDs(["c1", "c2", "c3", "missing"]), ["c1", "c2", "c3"],
            "All existing stories remain eligible; missing stories do not notify")
        let changed = FeedArticle(
            storedID: "c2", title: "Updated national emergency", link: story("c2", "Two").link,
            guid: "c2", description: "A significant update", pubDate: now, source: "Two")
        try await curated.upsertArticles([changed])
        expectFalse(
            try await curated.recordImportance(
                "c2", .minor, expectedTitle: "Story c2", expectedDescription: "Summary."),
            "A rating begun before a publisher edit cannot hide the updated story")
        expectTrue(
            try await curated.notificationStoryIDs(["c2"]).contains("c2"), "The changed, now unrated headline shows")
        await curated.close()

        let suite = testDefaultsSuite("test.importance-notifications")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = [fixtureRoot.appendingPathComponent("feed.xml").absoluteString]
        settings.aiEnabled = true
        settings.notificationsEnabled = true
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let reports = [
            FeedArticle(
                title: "National emergency declared",
                link: fixtureRoot.appendingPathComponent("emergency").absoluteString,
                guid: "emergency", description: "A major disaster affects millions.", pubDate: now, source: "News"),
            FeedArticle(
                title: "Village football score", link: fixtureRoot.appendingPathComponent("football").absoluteString,
                guid: "football", description: "A local team wins a friendly match.", pubDate: now, source: "Sport"),
        ]
        var notified: [String] = []
        // Publisher pages that never answer must not hold notifications back.
        let pages = OpenGate()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, reports, nil, nil) } },
            notifyBatch: { articles, _ in notified += articles.map(\.title) },
            dependencies: FeedManager.Dependencies(
                imageFinder: StoryImageFinder { _ in
                    await pages.wait()
                    return .none
                }, allowsBackgroundWork: { true }))
        let refresh = Task { await manager.fetchFeedsAsync() }
        await eventually("Notifications are dispatched while image lookups wait") { notified == reports.map(\.title) }
        expectEqual(notified, reports.map(\.title), "Refresh never filters eligible stories by model importance")
        await eventually("Image lookups follow clustering") { await pages.arrivals > 0 }
        await pages.open()
        await refresh.value
        manager.stopBackgroundWork()
        await store.database.close()
        expectEqual(OnDeviceImportanceJudge.level("Major."), .major, "MAJOR is major")
        expectEqual(OnDeviceImportanceJudge.level("notable"), .notable, "NOTABLE is notable")
        expectTrue(OnDeviceImportanceJudge.level("It depends") == nil, "Anything else is no rating")
        // #309: the rulings on the three borderline single-source stories.
        let instructions = OnDeviceImportanceJudge.prompt(
            EventJudgeReport(id: "r", title: "Flour price rises", summary: ""))
        for rule in [
            "programme cuts at a broadcaster, is MINOR", "trespass arrests are MINOR",
            "terrorism charges or a real security breach are NOTABLE",
            "Nationwide price changes of staple goods are NOTABLE",
        ] {
            expectTrue(instructions.contains(rule), "Rating instructions keep the borderline rule: \(rule)")
        }
    }

    /// #331: the installed library held one `article_state` row for "test_non_existent", saved without a timestamp. No
    /// app write path can produce it; this pins that, and that the app's own deletions leave no orphan state.
    static func testOrphanStateGuards() async throws {
        print("  - Testing that state writes and pruning never leave orphan article state (#331)...")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-orphan-\(UUID().uuidString).sqlite3"
        ).path
        defer { removeTemporaryLibrary(atPath: path) }
        let db = DatabaseEngine(path: path)
        try await db.open()
        let old = Date().addingTimeInterval(-40 * 86_400)
        let read = FeedArticle(
            storedID: "read", title: "Read story", link: "https://news.example/read", guid: "read", description: "",
            pubDate: old, source: "One")
        let saved = FeedArticle(
            storedID: "saved", title: "Saved story", link: "https://news.example/saved", guid: "saved", description: "",
            pubDate: old, source: "One")
        try await db.upsertArticles([read, saved])
        try await db.markRead(articleId: read.id, isRead: true)
        try await db.setSaved(articleId: saved.id, isSaved: true)
        let missing = "test_non_existent"
        _ = try? await db.setSaved(articleId: missing, isSaved: true)
        _ = try? await db.toggleSaved(articleId: missing)
        _ = try? await db.markRead(articleId: missing, isRead: true)
        _ = try? await db.markReadBatch(articleIds: [missing], isRead: true)
        _ = try? await db.batchMarkSaved([missing])
        expectEqual(try await db.pruneOldArticles(keepReadDays: 30), 1, "Old read stories are pruned; saved ones stay")
        expectTrue(try await db.isSaved(articleId: saved.id), "Pruning keeps saved stories")
        await db.close()

        var handle: OpaquePointer?
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open the orphan fixture")
        defer { sqlite3_close(handle) }
        func count(_ sql: String) -> Int32 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
        }
        expectEqual(
            count("SELECT count(*) FROM pragma_foreign_key_check;"), 0, "No state row outlives or precedes its article")
        expectEqual(
            count("SELECT count(*) FROM article_state WHERE article_id = 'test_non_existent';"), 0,
            "Writes for a missing article store nothing")
        expectEqual(
            count("SELECT count(*) FROM article_state WHERE is_saved = 1 AND saved_at IS NULL;"), 0,
            "Saved state always carries its time")
    }

    static func testEventClustering(fixtureRoot: URL) async throws {
        print("  - Testing incremental clustering, hard negatives, changed articles, exclusions and bounded passes...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-clusters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clusters.sqlite3").path
        func execute(_ sql: String) {
            var handle: OpaquePointer?
            expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open cluster fixture")
            expectEqual(
                sqlite3_create_function_v2(
                    handle, "news_publisher_input", 3, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, publisherInputFunction,
                    nil, nil, nil), SQLITE_OK, "Register publisher hashing on the isolated cluster writer")
            expectEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Edit cluster fixture")
            sqlite3_close(handle)
        }
        let db = DatabaseEngine(path: path)
        try await db.open()
        let now = Date()
        func article(_ id: String, _ title: String, _ description: String, hoursAgo: Double, source: String)
            -> FeedArticle
        {
            FeedArticle(
                storedID: id, title: title, link: fixtureRoot.appendingPathComponent("clusters/\(id)").absoluteString,
                guid: id, description: description, pubDate: now.addingTimeInterval(-hoursAgo * 3600), source: source)
        }
        func together(_ first: String, _ second: String) async throws -> Bool {
            guard let event = try await db.eventID(forArticle: first) else { return false }
            return try await db.eventID(forArticle: second) == event
        }
        try await db.upsertArticles(
            EventControlSet.articles(now: now, root: fixtureRoot).map(\.article) + [
                article(
                    "old", "Earthquake of magnitude 7 strikes eastern Turkey near Malatya", "An archived report.",
                    hoursAgo: 200, source: "Archive")
            ])

        let report = try await EventClusterer.run(in: db, now: now)
        expectEqual(report.processed, 9, "A pass handles every recent unmatched article exactly once")
        guard let quakeEvent = try await db.eventID(forArticle: "quake-1") else {
            return expectTrue(false, "Reports of one earthquake form an event")
        }
        let secondJoined = try await together("quake-1", "quake-2")
        let thirdJoined = try await together("quake-1", "quake-3")
        expectTrue(secondJoined && thirdJoined, "All reports of the earthquake join one event")
        expectTrue(report.changedEvents.contains(quakeEvent), "The pass reports the events it changed")
        expectFalse(
            try await together("strike-monday", "strike-tuesday"), "Different strikes in one region stay separate")
        expectFalse(
            try await together("apple-q3", "apple-q4"), "Different quarterly reports of one company stay separate")
        expectFalse(try await together("live-1", "live-2"), "Identical generic headlines are not one event")
        expectTrue(
            try await db.eventID(forArticle: "old") == nil, "Articles outside the active lifetime are never matched")
        expectEqual(try await EventClusterer.run(in: db, now: now).processed, 0, "A second pass recomputes nothing")

        // A changed member is matched again and leaves an event it no longer fits.
        let version = try await db.fetchEvent(id: quakeEvent)?.membershipVersion ?? 0
        execute(
            "UPDATE articles SET title='Central bank holds interest rates', description='The central bank left its benchmark rate unchanged.' WHERE id='quake-3';"
        )
        let changed = try await EventClusterer.run(in: db, now: now)
        expectEqual(changed.processed, 1, "Only the changed article is matched again")
        expectEqual(changed.detached, 1, "A member that no longer fits leaves its event")
        expectTrue(try await db.eventID(forArticle: "quake-3") == nil, "The changed article is no longer a member")
        expectEqual(
            try await db.fetchEvent(id: quakeEvent)?.membershipVersion, version + 1, "Leaving bumps the version once")

        // A new report joins the active event it fits as a whole.
        try await db.upsertArticles([
            article(
                "quake-4", "Malatya earthquake: magnitude 7 quake damages buildings in eastern Turkey",
                "Rescuers searched damaged buildings in Malatya in eastern Turkey after the magnitude 7 earthquake on Monday, the disaster agency AFAD said.",
                hoursAgo: 1, source: "Gazette Four")
        ])
        let grown = try await EventClusterer.run(in: db, now: now)
        expectEqual(grown.joined, 1, "A new report joins the event")
        expectTrue(try await together("quake-1", "quake-4"), "The new report shares the event ID")

        // "These are different events" is a local exclusion that survives refreshes and re-clustering.
        try await db.setSaved(articleId: "quake-2", isSaved: true)
        let separated = try await db.separateArticle("quake-2", fromEvent: quakeEvent)
        expectFalse(separated.memberArticleIDs.contains("quake-2"), "Separation removes the article from the event")
        expectEqual(
            try await db.eventExclusions(of: "quake-2"), Set(separated.memberArticleIDs),
            "The article is excluded from every remaining member")
        do {
            _ = try await db.separateArticle("quake-2", fromEvent: quakeEvent)
            expectTrue(false, "Only members can be separated")
        } catch {}
        expectEqual(
            try await EventClusterer.run(in: db, now: now).processed, 1, "Only the separated article is matched again")
        expectFalse(try await together("quake-2", "quake-1"), "A separated article never rejoins its excluded partners")
        try await db.upsertArticles([
            EventControlSet.articles(now: now, root: fixtureRoot).first { $0.article.id == "quake-2" }!.article
        ])
        _ = try await EventClusterer.run(in: db, now: now)
        expectFalse(try await together("quake-2", "quake-1"), "Exclusions survive a refresh of the article")
        execute("DELETE FROM event_members; DELETE FROM events; DELETE FROM event_match_state;")
        _ = try await EventClusterer.run(in: db, now: now)
        let rejoinedFirst = try await together("quake-2", "quake-1")
        let rejoinedNew = try await together("quake-2", "quake-4")
        expectFalse(rejoinedFirst || rejoinedNew, "Exclusions survive a complete re-clustering")
        expectTrue(
            try await together("quake-1", "quake-4"), "Re-clustering rebuilds the event without the excluded article")
        expectTrue(try await db.isSaved(articleId: "quake-2"), "Saving stays with the article through regrouping")

        // Passes are bounded and cancellable; unfinished work stays pending.
        try await db.upsertArticles(
            (0..<5).map {
                article(
                    "bulk-\($0)", "Unrelated bulletin \($0)", "Standalone notice \($0).", hoursAgo: 1,
                    source: "Bulletin")
            })
        expectEqual(try await EventClusterer.run(in: db, now: now, limit: 2).processed, 2, "A pass stops at its bound")
        let cancelled = Task { () async throws -> EventClusteringReport in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EventClusterer.run(in: db, now: now)
        }
        do {
            _ = try await cancelled.value
            expectTrue(false, "A cancelled pass throws")
        } catch is CancellationError {}
        expectEqual(
            try await EventClusterer.run(in: db, now: now).processed, 3,
            "Cancelled and bounded work waits for the next pass")

        // A partner outside the fetched batch consumes the same pass budget as its seed.
        let boundedDB = DatabaseEngine(path: ":memory:")
        try await boundedDB.open()
        try await boundedDB.upsertArticles([
            article(
                "bounded-seed", "Valencia wildfire forces evacuations", "Firefighters battle wildfire in Valencia.",
                hoursAgo: 3, source: "Bound One"),
            article(
                "bounded-other", "Chip maker reports quarterly sales", "Processors drive record sales.", hoursAgo: 2,
                source: "Bound Two"),
            article(
                "bounded-partner", "Valencia wildfire forces evacuations", "Firefighters battle wildfire in Valencia.",
                hoursAgo: 1, source: "Bound Three"),
        ])
        let bounded = try await EventClusterer.run(in: boundedDB, now: now, limit: 2)
        expectEqual(bounded.created, 1, "The seed forms an event with its later partner")
        expectEqual(bounded.processed, 2, "An out-of-batch partner cannot overspend the article budget")
        expectEqual(
            try await EventClusterer.run(in: boundedDB, now: now).processed, 1,
            "The unrelated batch member stays pending")
        await boundedDB.close()

        // Active upgrades split invalid old groups once, retaining the earliest valid subgroup and user state.
        try await db.upsertArticles([
            article(
                "upgrade-1", "Wildfire forces evacuations near Valencia in eastern Spain",
                "Firefighters battled the blaze overnight.", hoursAgo: 6, source: "Upgrade One"),
            article(
                "upgrade-2", "Valencia wildfire forces thousands to evacuate in Spain",
                "Residents left their homes as the fire spread.", hoursAgo: 5, source: "Upgrade Two"),
            article(
                "upgrade-3", "Chip maker reports record third-quarter revenue",
                "Sales of data-centre processors doubled.", hoursAgo: 4, source: "Upgrade Three"),
        ])
        let seeded = try await db.applyEventMatch(
            "upgrade-1", .create(with: ["upgrade-2", "upgrade-3"]),
            matcherVersion: EventMatcher.version - 1, at: now)
        guard case .created(let upgradeEvent) = seeded else {
            return expectTrue(false, "Seed an event matched by an older matcher")
        }
        let seededVersion = try await db.fetchEvent(id: upgradeEvent)?.membershipVersion
        try await db.setSaved(articleId: "upgrade-3", isSaved: true)
        try await db.markRead(articleId: "upgrade-1", isRead: true)
        let upgradePending = try await db.pendingEventMatchRows(
            activeSince: now.addingTimeInterval(-72 * 3600),
            matcherVersion: EventMatcher.version, limit: 10)
        expectEqual(
            upgradePending.map(\.id), ["upgrade-3", "upgrade-2", "upgrade-1"],
            "An older matcher version leaves members pending, newest first (#541)")
        expectTrue(
            upgradePending.allSatisfy(\.previouslyMatched),
            "Members pending only for the matcher version are reported as matched before")
        func upgradeFeatures(_ row: EventMatchRow) -> EventFeatures {
            EventFeatures(title: row.title, description: row.description, date: row.date)
        }
        expectTrue(
            EventMatcher.eventScore(
                for: upgradeFeatures(upgradePending[0]), members: upgradePending.dropFirst().map(upgradeFeatures))
                == nil,
            "The earliest member fails the whole-event check against later members")
        let oldOverview = EventOverviewDocument(
            eventID: upgradeEvent,
            version: OverviewVersionContext(membershipVersion: seededVersion ?? 1, inputTextHash: "old-input"),
            content: OverviewContent(title: "Old overview", summary: "", facts: [], citations: []),
            provenance: OverviewProvenance(
                memberArticleIDs: ["upgrade-1", "upgrade-2", "upgrade-3"], kind: .fallbackExcerpts))
        expectTrue(try await db.recordEventOverview(oldOverview), "Store an overview of the old membership")
        execute(
            "CREATE TRIGGER fail_upgrade BEFORE UPDATE OF event_id ON event_members WHEN old.article_id='upgrade-3' BEGIN SELECT RAISE(ABORT, 'test upgrade rollback'); END;"
        )
        do {
            _ = try await EventClusterer.run(in: db, now: now)
            expectTrue(false, "A failed partition must propagate")
        } catch {
            expectTrue(
                error.localizedDescription.contains("test upgrade rollback"), "The intended membership write failed")
        }
        expectEqual(
            try await db.fetchEvent(id: upgradeEvent)?.memberArticleIDs.sorted(),
            ["upgrade-1", "upgrade-2", "upgrade-3"], "Failed partition rolls back all memberships")
        expectEqual(
            try await db.fetchEventOverview(eventID: upgradeEvent)?.id, oldOverview.id,
            "Rollback retains the old overview")
        expectEqual(
            try await db.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-72 * 3600),
                matcherVersion: EventMatcher.version, limit: 10
            ).count, 3, "Rollback leaves upgrade work pending")
        execute("DROP TRIGGER fail_upgrade;")
        let upgraded = try await EventClusterer.run(in: db, now: now)
        expectEqual(
            try await db.fetchEventOverview(eventID: upgradeEvent), nil,
            "A committed split invalidates the old overview")
        expectEqual(upgraded.processed, 3, "A matcher version bump matches the members again")
        expectEqual(upgraded.detached, 1, "A known-invalid legacy member moves to its own event")
        expectEqual(
            try await db.fetchEvent(id: upgradeEvent)?.memberArticleIDs.sorted(),
            ["upgrade-1", "upgrade-2"], "The earliest compatible subgroup retains the original ID")
        expectEqual(
            try await db.fetchEvent(id: upgradeEvent)?.membershipVersion, (seededVersion ?? 0) + 1,
            "Splitting bumps the original membership version")
        expectTrue(try await db.isSaved(articleId: "upgrade-3"), "A split preserves saving")
        expectTrue(try await db.isRead(articleId: "upgrade-1"), "A split preserves read history")
        expectEqual(try await EventClusterer.run(in: db, now: now).processed, 0, "The completed upgrade is idempotent")
        expectTrue(
            try await db.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-72 * 3600),
                matcherVersion: EventMatcher.version, limit: 1
            ).isEmpty, "Kept members are processed under the current matcher")
        execute(
            "UPDATE articles SET title='Central bank holds interest rates', description='The central bank left its benchmark rate unchanged.' WHERE id='upgrade-1';"
        )
        let edited = try await EventClusterer.run(in: db, now: now)
        expectEqual(edited.processed, 1, "Only the edited member is matched again")
        expectEqual(edited.detached, 1, "An edited member is checked against its event again")
        expectEqual(
            try await db.fetchEvent(id: upgradeEvent)?.memberArticleIDs.sorted(), ["upgrade-2"],
            "An edited member that no longer fits leaves its event")
        let oldMembers = [
            article(
                "active-old-1", "Valencia wildfire forces evacuations", "Firefighters battle wildfire in Valencia.",
                hoursAgo: 100, source: "Old One"),
            article(
                "active-old-2", "Chip maker reports quarterly sales", "Processors drive record sales.", hoursAgo: 99,
                source: "Old Two"),
        ]
        try await db.upsertArticles(oldMembers)
        let activeOld = try await db.createEvent(memberArticleIDs: oldMembers.map(\.id), at: now)
        try await db.markEventMatchProcessed(oldMembers.map(\.id), matcherVersion: EventMatcher.version - 1, at: now)
        expectEqual(
            try await EventClusterer.run(in: db, now: now, limit: 1).processed, 0,
            "An event partition waits rather than exceeding the remaining article budget")
        expectEqual(
            try await EventClusterer.run(in: db, now: now).detached, 1,
            "An active legacy event is upgraded even when all publication dates are old")
        expectEqual(
            try await db.fetchEvent(id: activeOld.id)?.memberArticleIDs, ["active-old-1"],
            "Oldest active member keeps the original ID")
        let archive = try await db.createEvent(
            memberArticleIDs: oldMembers.map(\.id), at: now.addingTimeInterval(-100 * 3600))
        try await db.markEventMatchProcessed(oldMembers.map(\.id), matcherVersion: EventMatcher.version - 1, at: now)
        _ = try await EventClusterer.run(in: db, now: now)
        expectEqual(try await db.fetchEvent(id: archive.id), archive, "Inactive archived groups remain intact")

        let unknown = oldMembers.enumerated().map { index, item in
            FeedArticle(
                storedID: "unknown-\(index)", title: oldMembers[0].title,
                link: fixtureRoot.appendingPathComponent("unknown/\(index)").absoluteString, guid: nil,
                description: oldMembers[0].description, pubDate: DateParser.unknownDate, source: item.source)
        }
        try await db.upsertArticles(unknown)
        expectTrue(
            try await db.eventMatchRows(articleIDs: unknown.map(\.id)).allSatisfy { $0.date == DateParser.unknownDate },
            "Matching retains unknown publication dates rather than substituting ingestion time")
        expectEqual(try await EventClusterer.run(in: db, now: now).created, 0, "Undated reports stay separate")

        // Active-event upgrade from v5 to v6 with primary clause isolation:
        let strikeArticles = [
            article(
                "v5-strike-1", "Dock workers launch strike across Liverpool ports",
                "Union leaders announced indefinite walkout over wages.", hoursAgo: 5, source: "Maritime Wire"),
            article(
                "v5-strike-2",
                "Cruise liners divert passengers to alternate docks hours after dock workers launch strike",
                "Travel operators adjusted ship schedules to avoid port disruptions.", hoursAgo: 4.5,
                source: "Travel News"),
        ]
        try await db.upsertArticles(strikeArticles)
        let v5Event = try await db.createEvent(memberArticleIDs: strikeArticles.map(\.id), at: now)
        try await db.markEventMatchProcessed(strikeArticles.map(\.id), matcherVersion: 5, at: now)
        let v5Overview = EventOverviewDocument(
            eventID: v5Event.id,
            version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "v5-overview"),
            content: OverviewContent(title: "Strike overview", summary: "", facts: [], citations: []),
            provenance: OverviewProvenance(
                memberArticleIDs: strikeArticles.map(\.id), kind: .fallbackExcerpts))
        expectTrue(try await db.recordEventOverview(v5Overview), "Store an overview for the v5 event")
        try await db.setSaved(articleId: "v5-strike-2", isSaved: true)
        try await db.markRead(articleId: "v5-strike-1", isRead: true)

        let v5Run = try await EventClusterer.run(in: db, now: now)
        expectEqual(v5Run.processed, 2, "Active v5 event members are processed under v6")
        expectEqual(v5Run.detached, 1, "Disjoint primary-clause member is detached from the v5 event")
        expectEqual(
            try await db.fetchEvent(id: v5Event.id)?.memberArticleIDs, ["v5-strike-1"],
            "Primary strike story retains the original event ID")
        let movedEventID = try await db.eventID(forArticle: "v5-strike-2")
        expectTrue(movedEventID != nil && movedEventID != v5Event.id, "Moved member has a separate event")
        if let movedEventID {
            expectEqual(
                try await db.fetchEvent(id: movedEventID)?.memberArticleIDs, ["v5-strike-2"],
                "New event contains exactly the moved member")
        }
        expectEqual(
            try await db.fetchEvent(id: v5Event.id)?.membershipVersion, v5Event.membershipVersion + 1,
            "The original event version advances after moving a member")
        expectTrue(try await db.isSaved(articleId: "v5-strike-2"), "v6 preserves saving on the moved member")
        expectTrue(try await db.isRead(articleId: "v5-strike-1"), "v6 preserves read state on the kept member")
        expectEqual(
            try await db.fetchEventOverview(eventID: v5Event.id), nil,
            "Re-partitioning active event invalidates the obsolete overview")
        expectTrue(
            try await db.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-72 * 3600),
                matcherVersion: EventMatcher.version, limit: 1
            ).isEmpty, "All upgraded members are marked with current matcher version")
        await db.close()
        var handle: OpaquePointer?
        var statement: OpaquePointer?
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Inspect cluster library")
        expectEqual(
            sqlite3_prepare_v2(handle, "PRAGMA foreign_key_check;", -1, &statement, nil), SQLITE_OK,
            "Check cluster references")
        expectTrue(sqlite3_step(statement) == SQLITE_DONE, "Clustering leaves no dangling references")
        sqlite3_finalize(statement)
        sqlite3_close(handle)
    }
}
