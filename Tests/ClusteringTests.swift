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

/// The Clustering suites of the regression runner; `ClusteringTests.run()` is this atom's entry point.
enum ClusteringTests {
    static func run() async throws { try await NewsTests.runClusteringTests() }
}

extension NewsTests {
    static func runClusteringTests() async throws {
        let fixtureRoot = defaultFixtureRoot
        let tests: [(name: String, run: () async throws -> Void)] = [
            ("testEventDataModel", { try await testEventDataModel(fixtureRoot: fixtureRoot) }),
            ("testEventCandidateGeneration", { try await testEventCandidateGeneration(fixtureRoot: fixtureRoot) }),
            ("testRelatedStoryEvents", { try await testRelatedStoryEvents(fixtureRoot: fixtureRoot) }),
            ("testEventMatcherRules", { try await testEventMatcherRules() }),
            ("testActClassTable", { testActClassTable() }),
            ("testStoryCountryPlaceVeto", { testStoryCountryPlaceVeto() }),
            ("testEventClustering", { try await testEventClustering(fixtureRoot: fixtureRoot) }),
            ("testArticleSignalsRoundTrip", { try await testArticleSignalsRoundTrip() }),
            ("testPairAssessmentsRecorded", { try await testPairAssessmentsRecorded() }),
            ("testReaderVerdictsExportAndGate", { try await testReaderVerdictsExportAndGate() }),
            ("testStoryLayer", { try await testStoryLayer() }),
            ("testStoryPassOrderIndependent", { try await testStoryPassOrderIndependent() }),
            ("testEventInclusions", { try await testEventInclusions() }),
            ("testPairModelGreyZone", { try await testPairModelGreyZone() }),
            ("testEventEmbeddingIntegration", { try await testEventEmbeddingIntegration() }),
            (
                "testEventFragmentMergingAndJudge",
                { try await testEventFragmentMergingAndJudge(fixtureRoot: fixtureRoot) }
            ),
            ("testStoryVisibility", { try await testStoryVisibility(fixtureRoot: fixtureRoot) }),
            ("testOrphanStateGuards", { try await testOrphanStateGuards() }),
            ("testEventReadingState", { try await testEventReadingState(fixtureRoot: fixtureRoot) }),
            ("testEventFeedSummaryUnit", { testEventFeedSummaryUnit() }),
            ("testEventFeedGroupingAndStability", { await testEventFeedGroupingAndStability() }),
            ("testEventFeedGroupingOptimization", { testEventFeedGroupingOptimization() }),
            ("testRefreshClustersEvents", { try await testRefreshClustersEvents(fixtureRoot: fixtureRoot) }),
            ("testStoryCheckForUpdates", { try await testStoryCheckForUpdates(fixtureRoot: fixtureRoot) }),
            ("testEventCorpusHarness", { try await testEventCorpusHarness(fixtureRoot: fixtureRoot) }),
            ("testMatcherRegressionCorpus", { try await testMatcherRegressionCorpus() }),
            ("testStoryRegressionCorpus", { try await testStoryRegressionCorpus() }),
            ("testPairCalibration", { try await testPairCalibration() }),
            ("testCapturedFingerprintReview", { try testCapturedFingerprintReview() }),
        ]
        try await runSuite(tests)
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
            assertEqual(sqlite3_open(file, &connection), SQLITE_OK, "Inspect event fixture")
            defer { sqlite3_close(connection) }
            assertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK, "Prepare event inspection")
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
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open v11 event fixture")
        assertEqual(
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
            assertTrue(false, "Cancelled event migration must throw")
        } catch is CancellationError {}
        assertEqual(
            value(cancelledPath, "PRAGMA user_version;"), "11", "Cancelled event migration keeps the old version")
        assertEqual(
            value(cancelledPath, "SELECT count(*) FROM sqlite_master WHERE name IN ('events','event_members');"), "0",
            "Cancelled event migration rolls back its tables")

        let db = DatabaseEngine(path: copy)
        try await db.open()
        assertEqual(
            value(copy, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Copied v11 library upgrades to the current schema")
        assertEqual(value(path, "PRAGMA user_version;"), "11", "Original v11 fixture stays untouched")
        assertEqual(try await db.fetchArticles(limit: nil).count, 5, "Event migration keeps every article")
        assertTrue(try await db.isRead(articleId: "event-a"), "Event migration keeps read state")
        assertTrue(try await db.isSaved(articleId: "event-b"), "Event migration keeps saved state")
        assertEqual(
            value(
                copy,
                "SELECT group_concat(name) FROM (SELECT name FROM pragma_table_info('event_members') ORDER BY name);"),
            "article_id,event_id,joined_version", "Membership stores article references, not source text")
        assertEqual(
            value(
                copy,
                "SELECT count(*) FROM pragma_table_info('events') WHERE name IN ('title','description','content');"),
            "0", "Events do not copy source text")

        let first = try await db.createEvent(memberArticleIDs: ["event-a", "event-b", "event-c", "event-a"])
        assertEqual(first.membershipVersion, 1, "A new event starts at membership version 1")
        assertEqual(first.memberArticleIDs, ["event-a", "event-b", "event-c"], "Repeated articles join once")
        let grown = try await db.addArticles(["event-d"], toEvent: first.id)
        assertEqual(grown.id, first.id, "Adding members keeps the event ID")
        assertEqual(grown.membershipVersion, 2, "Adding a member bumps the membership version")
        assertEqual(
            value(copy, "SELECT joined_version FROM event_members WHERE article_id='event-d';"), "2",
            "Members record the version they joined")
        assertEqual(
            try await db.addArticles(["event-d"], toEvent: first.id).membershipVersion, 2,
            "Re-adding a member does not bump the version")

        let second = try await db.createEvent(memberArticleIDs: ["event-c"])
        assertEqual(
            try await db.fetchEvent(id: first.id)?.membershipVersion, 3,
            "Losing a member to another event bumps the version")
        assertEqual(try await db.eventID(forArticle: "event-c"), second.id, "An article belongs to one event at a time")

        let merged = try await db.mergeEvents(second.id, into: first.id)
        assertEqual(merged.id, first.id, "The survivor keeps its ID")
        assertEqual(merged.membershipVersion, 4, "A merge that moves members bumps the survivor's version")
        assertEqual(merged.memberArticleIDs, ["event-a", "event-b", "event-c", "event-d"], "A merge unions members")
        assertEqual(try await db.resolvedEventID(second.id), first.id, "The absorbed ID forwards to the survivor")
        assertEqual(try await db.fetchEvent(id: second.id)?.id, first.id, "Links to the absorbed ID open the survivor")
        assertEqual(
            try await db.mergeEvents(first.id, into: second.id).membershipVersion, 4,
            "Merging an event into its own forward is a no-op")

        let split = try await db.splitEvent(second.id, movingArticles: ["event-c", "event-d"])
        assertTrue(split.id != first.id && split.id != second.id, "A split gets a new stable ID")
        assertEqual(split.membershipVersion, 1, "A split starts its own version history")
        assertEqual(split.memberArticleIDs, ["event-c", "event-d"], "A split takes only the moved members")
        let remaining = try await db.fetchEvent(id: first.id)
        assertEqual(remaining?.memberArticleIDs, ["event-a", "event-b"], "The original keeps the remaining members")
        assertEqual(remaining?.membershipVersion, 5, "A split bumps the original's version")
        assertEqual(try await db.resolvedEventID(second.id), first.id, "Old forwards still resolve after a split")
        do {
            _ = try await db.splitEvent(first.id, movingArticles: ["event-a", "event-b"])
            assertTrue(false, "Moving every member is not a split")
        } catch {}
        do {
            _ = try await db.splitEvent(first.id, movingArticles: ["event-c"])
            assertTrue(false, "A split moves only current members")
        } catch {}
        do {
            _ = try await db.createEvent(memberArticleIDs: ["missing-article"])
            assertTrue(false, "Unknown articles cannot join an event")
        } catch {}
        assertEqual(
            try await db.fetchEvent(id: first.id)?.membershipVersion, 5, "Rejected changes leave the version untouched")

        assertTrue(try await db.isRead(articleId: "event-a"), "Merges and splits keep read state")
        assertTrue(try await db.isSaved(articleId: "event-b"), "Merges and splits keep saved state")
        assertEqual(
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
        assertEqual(
            try await db.pruneOldArticles(keepReadDays: 30), 3, "Retention removes old read, unsaved, uncited members")
        assertEqual(
            try await db.fetchEvent(id: first.id)?.memberArticleIDs, ["event-b"], "Saved members survive retention")
        assertTrue(try await db.fetchEvent(id: split.id) == nil, "Events emptied by retention are dropped")
        assertEqual(
            try await db.fetchEvent(id: cited.id)?.memberArticleIDs, ["event-e"],
            "Cited evidence stays reachable through its event")
        try await db.removeArticles(["event-e"], fromEvent: cited.id)
        try await db.removeArticles(["event-b"], fromEvent: first.id)
        assertEqual(try await db.pruneOldArticles(keepReadDays: 30), 0, "Saved and cited articles are never pruned")
        assertTrue(try await db.fetchEvent(id: cited.id) != nil, "An event with a stored overview keeps its ID")
        assertTrue(try await db.resolvedEventID(first.id) == nil, "An empty event is dropped by retention")
        assertTrue(try await db.resolvedEventID(second.id) == nil, "Its forwards are dropped with it")
        assertTrue(try await db.isSaved(articleId: "event-b"), "Dropping an event keeps the saved article")
        assertEqual(value(copy, "PRAGMA quick_check;"), "ok", "Event library passes quick_check")
        assertTrue(value(copy, "PRAGMA foreign_key_check;") == nil, "Event membership has no dangling references")
        await db.close()
    }

    static func testEventCandidateGeneration(fixtureRoot: URL) async throws {
        print("  - Testing bounded event candidates by time window, language, terms and active events...")
        let key = EventMatchKey(
            title: "Earthquake strikes Lviv region overnight",
            description: "A strong earthquake struck the Lviv region overnight, officials said.")
        assertTrue(key.terms.count <= EventMatchKey.maximumTerms, "Match keys are bounded")
        assertTrue(key.terms.contains { $0.lowercased() == "earthquake" }, "Distinctive title words become terms")
        assertEqual(key.terms.filter { $0.lowercased() == "lviv" }.count, 1, "Names and title words are deduplicated")
        assertFalse(key.terms.contains("the"), "Short words are not terms")
        let crowded = EventMatchKey(
            title: "Earthquake strikes Lviv region overnight",
            description:
                "Officials in Kyiv, Warsaw, Berlin, Paris, Rome, Madrid, Vienna, Prague and Lisbon sent condolences.")
        assertTrue(
            crowded.terms.contains { $0.lowercased() == "earthquake" }
                && crowded.terms.count <= EventMatchKey.maximumTerms,
            "Headline words keep their place in the query when the lead names many places")
        let hostile = EventMatchKey(title: "Ceasefire\" OR content:* NEAR(talks) {source} collapse", description: "")
        assertTrue(hostile.ftsQuery?.contains("\"\"") == false, "Quotes in publisher text cannot break out of a phrase")
        assertTrue(
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
        assertEqual(EventMatchKey.language(of: english), "en", "Language regression includes confident English")
        assertEqual(EventMatchKey.language(of: german), "de", "Language regression includes confident German")
        assertEqual(EventMatchKey.language(of: ""), nil, "Empty text has no detected language")
        for text in languageTexts {
            assertEqual(
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
        assertTrue(ids.contains("recent"), "Matching articles inside the window are candidates")
        assertFalse(ids.contains("target"), "An article is never its own candidate")
        assertFalse(ids.contains("old"), "Articles outside the time window are not candidates")
        assertFalse(ids.contains("unrelated"), "Articles without shared terms are not candidates")
        assertFalse(ids.contains("german"), "Articles in another detected language are not compared")
        assertFalse(ids.contains("closed"), "Members of events past their active lifetime are not candidates")
        assertEqual(
            candidates.first { $0.articleID == "active" }?.eventID, active.id, "Candidates carry their active event")
        assertEqual(candidates.first { $0.articleID == "recent" }?.eventID, nil, "Unclustered candidates have no event")

        // One language per row within a pass (#572): the first reading stands, and stored signals come before the recognizer.
        var pass: [String: EventCandidateLanguage] = [:]
        let first = try await EventCandidateFinder.candidates(for: target, in: db, now: now, languages: &pass)
        assertEqual(first, candidates, "The pass's language map changes no candidate")
        assertEqual(pass["german"]?.language, "de", "The pass keeps a row's recognized language")
        let germanText = EventCandidateFinder.languageText(title: "Erdbeben erschüttert Lviv", description: german)
        pass["german"] = EventCandidateLanguage(textHash: germanText.hashValue, language: "en")
        let reread = try await EventCandidateFinder.candidates(for: target, in: db, now: now, languages: &pass)
        assertTrue(reread.contains { $0.articleID == "german" }, "A row is not recognized again in one pass")
        pass["german"] = EventCandidateLanguage(textHash: "an earlier edit of the row".hashValue, language: "en")
        let edited = try await EventCandidateFinder.candidates(for: target, in: db, now: now, languages: &pass)
        assertFalse(edited.contains { $0.articleID == "german" }, "A row edited since it was read is read again")
        assertEqual(pass["german"]?.language, "de", "The new text replaces the old reading")
        var signals = EventFeatures(title: "Erdbeben erschüttert Lviv", description: german, date: now)
        signals.language = "en"
        try await db.upsertArticleFeatures(
            ["german": signals], version: EventFeatures.storageVersion - 1, at: now)
        var stale: [String: EventCandidateLanguage] = [:]
        let staleRead = try await EventCandidateFinder.candidates(for: target, in: db, now: now, languages: &stale)
        assertFalse(staleRead.contains { $0.articleID == "german" }, "Signals of an older version are not read")
        try await db.upsertArticleFeatures(["german": signals], version: EventFeatures.storageVersion, at: now)
        var fresh: [String: EventCandidateLanguage] = [:]
        let storedRead = try await EventCandidateFinder.candidates(for: target, in: db, now: now, languages: &fresh)
        assertTrue(storedRead.contains { $0.articleID == "german" }, "A row's stored language comes first")
        try await db.eventRows("DELETE FROM article_features;")

        try await db.upsertArticles(
            (0..<30).map { article("bulk-\($0)", "Lviv earthquake update \($0)", english, hoursAgo: 1) })
        var narrow = EventCandidatePolicy.standard
        narrow.limit = 5
        assertEqual(
            try await EventCandidateFinder.candidates(for: target, in: db, policy: narrow, now: now).count, 5,
            "Candidate count is capped")
        narrow.limit = 0
        assertTrue(
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
        assertTrue(EventStoryRelation.supports(earlier, later), "Distinct acts may be related without matching")
        assertFalse(EventStoryRelation.supports(later, earlier), "Earlier links cannot point forward")
        var organization = later
        organization.people = []
        organization.organizations = earlier.people
        assertFalse(
            EventStoryRelation.supports(earlier, organization), "Person-to-organization name collisions never link")
        var earlierOrganization = earlier
        earlierOrganization.people = []
        earlierOrganization.organizations = organization.organizations
        assertFalse(
            EventStoryRelation.supports(earlierOrganization, later), "Organization-to-person name collisions never link"
        )
        assertTrue(
            EventStoryRelation.supports(earlierOrganization, organization), "Shared typed organizations can link")
        let unrelatedCommon: Set<String> = ["someone else", "another agency"]
        assertTrue(
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
            assertFalse(
                EventStoryRelation.supports(first, other), "Weak or conflicting \(field) evidence rejects a link")
            assertFalse(
                EventStoryRelation.supports(first, other, commonActors: unrelatedCommon),
                "The common-actor set never relaxes the \(field) rule")
        }
        var country = later
        country.places = ["@US"]
        assertTrue(EventStoryRelation.supports(earlier, country), "A shared country counts as a shared place")
        assertFalse(
            EventStoryRelation.supports(earlier, later, commonActors: earlier.people.union(earlier.organizations)),
            "An actor common across the week's events does not tie two events together")
        var boundary = earlier
        boundary.date = now.addingTimeInterval(-EventStoryRelation.window)
        assertTrue(EventStoryRelation.supports(boundary, later), "The seven-day boundary is inclusive")
        boundary.date = boundary.date.addingTimeInterval(-1)
        assertFalse(EventStoryRelation.supports(boundary, later), "Older pairs are excluded")
        assertFalse(
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
        assertEqual(links.map(\.eventID), [previous.id], "Only directly supported, wholly earlier events link")
        assertFalse(links.map(\.eventID).contains(half.id), "Support from half the members is not enough")
        assertEqual(links.first?.articleID, "earlier", "Navigation carries a stored member ID")
        func row(_ id: String, hours: Double, event: String) -> EventMatchRow {
            let story = article(id, hours: hours)
            return EventMatchRow(
                id: id, title: story.title, description: story.description, source: "Publisher",
                date: story.pubDate, eventID: event)
        }
        let ranked = try EventStoryRelation.links(
            target: [row("t", hours: 0, event: "target")],
            candidates: (1...4).map { ("event-\($0)", [row("c\($0)", hours: -Double($0), event: "event-\($0)")]) })
        assertEqual(
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
        assertTrue(halfSupported.isEmpty, "Two-thirds member support still applies with a common-actor set")
        let cancelledLookup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EventStoryRelation.find(eventID: current.id, in: db)
        }
        do {
            _ = try await cancelledLookup.value
            assertTrue(false, "A cancelled lookup must not return links")
        } catch is CancellationError {}
        assertEqual(
            try await db.commonStoryTerms(["volodymyr zelenskyy"], before: now.addingTimeInterval(3600), share: 0.05),
            [], "A name in only a few events is never common, however small the library")
        assertEqual(
            try await db.commonStoryTerms(
                ["volodymyr zelenskyy", "absent name"], before: now.addingTimeInterval(3600), share: 0.05,
                minimumEvents: 1), ["volodymyr zelenskyy"], "A name across most of the week's events is common")
        assertEqual(try await db.fetchEvent(id: current.id), current, "Lookup does not change the target event")
        assertEqual(try await db.fetchEvent(id: previous.id), previous, "Lookup does not change earlier membership")
        assertTrue(try await db.isRead(articleId: "earlier"), "Lookup preserves read state")
        assertTrue(try await db.isSaved(articleId: "current"), "Lookup preserves saved state")
        assertTrue(
            try await EventStoryRelation.find(eventID: "missing", in: db).isEmpty, "Deleted events have no links")
        try await db.upsertArticles([article("forward", hours: 0)], now: now)
        let forward = try await db.createEvent(memberArticleIDs: ["forward"], at: now)
        _ = try await db.mergeEvents(forward.id, into: current.id, at: now)
        assertEqual(
            try await EventStoryRelation.find(eventID: forward.id, in: db), links,
            "Merge forwards resolve to live events")
        var extraIDs: [String] = []
        for i in 0..<5 {
            let id = "extra-\(i)"
            try await db.upsertArticles([article(id, hours: -0.5)], now: now)
            extraIDs.append(try await db.createEvent(memberArticleIDs: [id], at: now).id)
        }
        let capped = try await EventStoryRelation.find(eventID: current.id, in: db)
        assertEqual(
            capped.map(\.eventID), Array(extraIDs.sorted().prefix(3)), "Newest links are capped with stable ID ties")
        assertEqual(
            try await EventStoryRelation.find(eventID: current.id, in: db), capped,
            "Unchanged input gives stable link ordering")
        let undated = FeedArticle(
            storedID: "undated", title: articles[0].title, link: articles[0].link + "/undated", guid: "undated",
            description: articles[0].description, pubDate: DateParser.unknownDate, source: "Other publisher")
        try await db.upsertArticles([undated], now: now)
        _ = try await db.addArticles(["undated"], toEvent: current.id, at: now)
        assertTrue(
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
            assertTrue(false, "Cancelled relation work must stop")
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
        try await measureLiveRelations(path: run.appendingPathComponent("library.sqlite3").path, output: output)
        let rows =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: output).appendingPathComponent("relations-private.json")))
            as? [[String: String]] ?? []
        assertEqual(
            rows.filter { $0["kind"] == "link" }.map { $0["earlierEvent"] }, [linkedEvent.id],
            "The harness records the proposed link")
        assertEqual(
            rows.filter { $0["kind"] == "control" }.map { $0["earlierEvent"] }, [nearEvent.id],
            "A rejected earlier event sharing an actor is the control")
        assertTrue(rows.allSatisfy { $0["later"]?.isEmpty == false }, "Pairs carry reviewable text")
        let misses =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: output).appendingPathComponent("near-misses-private.json")))
            as? [[String: String]] ?? []
        // One candidate can miss several targets at different stages, so compare the stages each one reached.
        let missStages = Dictionary(misses.map { ($0["earlierEvent"] ?? "", Set([$0["kind"] ?? ""])) }) { $0.union($1) }
        assertTrue(
            missStages[olderEvent.id]?.contains("olderThanWindow") == true,
            "Coverage that began too early is a window stage")
        assertTrue(
            missStages[continuingEvent.id]?.contains("continuesAfterStart") == true,
            "Coverage past the target's start is a window stage")
        assertTrue(missStages[nearEvent.id] != nil, "Rejected in-window candidates join the recall sample")
        assertTrue(missStages[linkedEvent.id] == nil, "Linked candidates are not near misses")
        assertTrue(
            Dictionary(grouping: misses, by: { $0["kind"] ?? "" }).values.allSatisfy { $0.count <= 25 },
            "The recall sample keeps at most 25 candidates per stage")
        do {
            try await measureLiveRelations(path: run.appendingPathComponent("library.sqlite3").path, output: output)
            assertTrue(false, "A second run must not replace the first run's pairs")
        } catch {}
        do {
            try await measureLiveRelations(path: NSHomeDirectory() + "/library.sqlite3", output: output)
            assertTrue(false, "Only temporary copies are measured")
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
        assertTrue(pair.isMatch, "Shared names and places, shared action terms and close times match")
        assertEqual(pair.conflict, nil, "A matching pair has no contradicting facts")
        assertEqual(EventMatcher.assess(quakeLater, quake), pair, "Matching is symmetric")

        let wordingOnly = features([], ["earthquake", "magnitude", "damage", "building", "eastern"], hours: 1)
        assertFalse(
            EventMatcher.assess(quake, wordingOnly).isMatch,
            "Similar wording without a shared name or place is not enough")

        let thirdQuarter = features(["apple"], ["revenue", "record", "iphone", "sale"], periods: ["q3"])
        let fourthQuarter = features(["apple"], ["revenue", "record", "iphone", "sale"], hours: 1, periods: ["q4"])
        assertEqual(
            EventMatcher.assess(thirdQuarter, fourthQuarter).conflict, .period,
            "Quarterly reports of one company are different events")
        assertFalse(EventMatcher.assess(thirdQuarter, fourthQuarter).isMatch, "A period conflict never matches")

        // Two acts by the same actors on the same day are two events (#522); a consequence report follows its incident.
        var vote = features(["novak"], ["vote", "oust", "parliament", "minister"], places: ["ljubljana"])
        vote.actClass = .vote
        var protest = features(["novak"], ["protest", "oust", "parliament", "vote"], hours: 4, places: ["ljubljana"])
        protest.actClass = .protest
        assertEqual(EventMatcher.assess(vote, protest).conflict, .differentAct, "A vote and its protest differ")
        assertEqual(
            EventMatcher.assess(protest, vote).conflict, .differentAct, "The act conflict is symmetric")
        var unknownAct = protest
        unknownAct.actClass = .unknown
        assertEqual(EventMatcher.assess(vote, unknownAct).conflict, nil, "An unclassified headline never vetoes")
        var casualtyReport = protest
        casualtyReport.actClass = .casualties
        var resignation = vote
        resignation.actClass = .personnel
        assertEqual(
            EventMatcher.assess(resignation, casualtyReport).conflict, .differentAct,
            "A toll is no consequence of a resignation")
        assertEqual(
            EventMatcher.assess(vote, casualtyReport).conflict, nil,
            "Vote headlines use casualty words politically (\"survives no-confidence motion\"), so no veto")
        var protestElsewhere = features(
            ["novak"], ["protest", "oust", "parliament", "vote"], hours: 4, places: ["maribor"])
        protestElsewhere.actClass = .protest
        assertEqual(
            EventMatcher.assess(vote, protestElsewhere).conflict, .places,
            "Other contradictions come first: a related act is only one where nothing else conflicts")
        var shooting = vote
        shooting.actClass = .attack
        assertEqual(
            EventMatcher.assess(shooting, casualtyReport).conflict, nil, "A toll report follows the attack it counts")

        let mondayStrike = features(
            ["syniehubov"], ["drone", "strike", "apartment", "kill"], places: ["kharkiv"], weekdays: ["monday"])
        let tuesdayStrike = features(
            ["syniehubov"], ["drone", "strike", "apartment", "kill"], hours: 10, places: ["kharkiv"],
            weekdays: ["tuesday"])
        assertEqual(
            EventMatcher.assess(mondayStrike, tuesdayStrike).conflict, .weekday,
            "Strikes on different days in one region are different events")
        let threeKilled = features(["syniehubov"], ["drone", "strike", "kill"], places: ["kharkiv"], numbers: ["3"])
        let twelveHurt = features(
            ["syniehubov"], ["drone", "strike", "kill"], hours: 1, places: ["kharkiv"], numbers: ["12"])
        assertEqual(
            EventMatcher.assess(threeKilled, twelveHurt).conflict, .titleNumbers,
            "Different headline figures are kept apart")
        let odesa = features(["navy"], ["storm", "flood", "coast"], places: ["odesa"])
        let gdansk = features(["navy"], ["storm", "flood", "coast"], hours: 1, places: ["gdansk"])
        assertEqual(
            EventMatcher.assess(odesa, gdansk).conflict, .places,
            "The same kind of event in different places is not one event")
        let german = features(["afad"], quake.keywords, places: ["malatya"], language: "de")
        assertEqual(EventMatcher.assess(quake, german).conflict, .language, "Languages are not compared directly")
        let late = features(["afad"], quake.keywords, hours: 40, places: ["malatya"])
        assertEqual(EventMatcher.assess(quake, late).conflict, .timeGap, "Reports far apart in time never match")

        // #688: explicit days are calendar tokens, not figures; one publisher's series name is no evidence.
        let dated = EventFeatures(
            title: "Dockworkers to strike on October 21st, union says", description: "", date: now)
        assertEqual(dated.calendarDays, ["10-21"], "An ordinal date is a calendar day")
        assertTrue(dated.titleNumbers.isEmpty, "A date's day is not a headline figure")
        assertEqual(
            EventFeatures(title: "Port faces 21 October walkout", description: "", date: now).calendarDays, ["10-21"],
            "A day-first date reads the same")
        var dayOne = quake
        dayOne.calendarDays = ["10-21"]
        var dayTwo = quakeLater
        dayTwo.calendarDays = ["10-22"]
        assertEqual(EventMatcher.assess(dayOne, dayTwo).conflict, .calendarDay, "Different explicit days differ")
        let lead = "Catch up with the most important stories from around Europe this October 21st, 2026 - business."
        let morning = EventFeatures(
            title: "Latest news bulletin | October 21st, 2026 – Morning", description: lead, date: now)
        let evening = EventFeatures(
            title: "Latest news bulletin | October 21st, 2026 – Evening", description: lead,
            date: now.addingTimeInterval(10 * 3600))
        assertEqual(morning.series, "latest news bulletin", "The text before the separator names the series")
        assertEqual(morning.editions, ["morning"], "The edition slot is read from the headline")
        assertEqual(
            EventMatcher.assess(morning, evening, samePublisher: true).conflict, .edition,
            "Two editions of one publisher's series are two items")
        assertTrue(
            EventMatcher.assess(morning, evening).conflict != .edition, "Editions conflict only inside one series")
        var seriesFirst = quake
        seriesFirst.series = "afad daily"
        seriesFirst.seriesTerms = ["afad", "malatya"]
        var seriesSecond = quakeLater
        seriesSecond.series = "afad daily"
        assertTrue(EventMatcher.assess(seriesFirst, seriesSecond).isMatch, "Two publishers' shared names count")
        assertFalse(
            EventMatcher.assess(seriesFirst, seriesSecond, samePublisher: true).isMatch,
            "Inside one publisher's series its name is no shared evidence")
        // #741: storm names, and Title Case verbs that are not names.
        assertEqual(
            EventFeatures.stormNames(in: "Storm Darragh leaves 2,000 homes without power"), ["darragh"],
            "A named storm is read from the headline")
        assertEqual(
            EventFeatures.stormNames(in: "Storm Ellen Leaves Thousands Without Power"), ["ellen"],
            "A storm name in a Title Case headline is read too")
        assertEqual(
            EventFeatures.stormNames(in: "Storm Éowyn brings record winds to Ireland"), ["eowyn"],
            "An accented storm name is read and folded")
        assertTrue(
            EventFeatures.stormNames(in: "Storm Ciarán nears the coast")
                != EventFeatures.stormNames(in: "Storm Éowyn nears the coast"),
            "Two accented storms differ")
        assertTrue(
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
        assertEqual(
            EventMatcher.assess(kyivFire, kramatorskFire).conflict, .headlinePlaces,
            "Fires in Kyiv and in Kramatorsk are two events though each description names the other city")
        let ceutaA = EventFeatures(
            title: "Moroccan police intercept migrant swimming back towards Ceuta",
            description: "Spain has deported migrants from Ceuta this week.", date: now)
        let ceutaB = EventFeatures(
            title: "Spain deports migrants from Ceuta in move criticised by rights group",
            description: "Moroccan police intercepted a migrant swimming back.", date: now.addingTimeInterval(3600))
        assertTrue(
            EventMatcher.assess(ceutaA, ceutaB).conflict != .headlinePlaces,
            "Headlines that share a place (Ceuta) are not split by their countries")
        let dieselA = EventFeatures(
            title: "Trump administration may let more Russian diesel onto market", description: "", date: now)
        let dieselB = EventFeatures(
            title: "Trump-Putin diesel deal has not lowered US fuel prices", description: "",
            date: now.addingTimeInterval(3600))
        assertTrue(
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
        assertEqual(
            EventMatcher.assess(roundUpOne, roundUpTwo, samePublisher: true).conflict, .calendarDay,
            "Dateless round-ups of one series on different days are two items")
        roundUpOne.editions = ["evening"]
        roundUpTwo.editions = ["evening"]
        assertTrue(
            EventMatcher.assess(roundUpOne, roundUpTwo, samePublisher: true).conflict != .calendarDay,
            "Items with an edition word are left to the edition check")

        let followUpTerms: Set<String> = ["earthquake", "damage", "rescue", "tent", "camp", "aid", "shelter", "winter"]
        assertTrue(
            EventMatcher.assess(quake, features(["afad"], followUpTerms, hours: 2, places: ["malatya"])).isMatch,
            "Moderate overlap matches when reports are close in time")
        assertFalse(
            EventMatcher.assess(quake, features(["afad"], followUpTerms, hours: 20, places: ["malatya"])).isMatch,
            "Reports half a day apart need stronger agreement on what happened")

        // Both models are English-only (#553): a pair in another language is decided by the rules alone.
        let frenchStrike = features(["macron"], ["greve", "reforme"], language: "fr")
        let frenchStrikeLater = features(["macron"], ["greve", "retraite"], hours: 1, language: "fr")
        let frenchPair = EventMatcher.assess(frenchStrike, frenchStrikeLater, embeddingSimilarity: 0.95)
        assertTrue(frenchPair.isBorderline && !frenchPair.isMatch, "A French pair the rules leave open stays open")
        assertTrue(frenchPair.embeddingCosine == nil, "The embedding is not read for a French pair")
        assertFalse(frenchPair.neuralEligible, "A French pair is not eligible for the neural paths")
        assertFalse(EventMatcher.needsPairModel(frenchPair), "The pair model is never asked about a French pair")
        let englishStrike = features(["macron"], ["greve", "reforme"], language: "en")
        let englishStrikeLater = features(["macron"], ["greve", "retraite"], hours: 1, language: "en")
        let englishPair = EventMatcher.assess(englishStrike, englishStrikeLater, embeddingSimilarity: 0.95)
        assertTrue(englishPair.isMatch, "The same signals in English are rescued by the embedding")
        assertTrue(
            EventMatcher.needsPairModel(EventMatcher.assess(englishStrike, englishStrikeLater)),
            "Without an embedding the English pair goes to the pair model")
        assertTrue(
            EventMatcher.assess(englishStrike, features(["macron"], ["greve", "retraite"], hours: 1, language: nil))
                .neuralEligible,
            "An unrecognized language is treated like English")
        // Headline names as anchors (matcher v12, #580).
        let openAI = EventFeatures(
            title: "OpenAI says its AI agents disabled their own safety monitors",
            description: "The company said several agents switched off their monitors during a test.", date: now)
        assertTrue(
            openAI.names.contains("openai"), "A brand written with an inner capital is a name at a sentence start")
        let pope = EventFeatures(
            title: "Pope does not need further treatment after lung cancer surgery",
            description: "Doctors treating the Pope said no further treatment was needed.", date: now)
        assertTrue(
            pope.people.contains("pope") || pope.names.contains("pope"),
            "A sentence-initial word the text capitalizes mid-sentence is a name")
        let popeLeo = EventFeatures(
            title: "Pope Leo needs no further treatment after cancer surgery, doctors say", description: "", date: now)
        assertTrue(popeLeo.people.contains("pope"), "\"Pope Leo\" and \"the Pope\" share one anchor")
        let ios = EventFeatures(
            title: "iOS 27.2 introduces design changes for these Apple apps",
            description: "With the update, Apple is changing the design of several apps.", date: now)
        assertTrue(ios.names.contains("ios"), "A product written with an inner capital is a name")
        assertTrue(ios.organizations.contains("ios 27.2"), "A product and its version are one anchor")
        let titleCase = EventFeatures(
            title: "Airbnb Hosts Are Furious They Can No Longer Make Guests Do Their Chores",
            description: "Airbnb has banned hosts from asking guests to do chores like laundry and dishes.", date: now)
        assertTrue(
            titleCase.names.contains("airbnb") || titleCase.organizations.contains("airbnb"),
            "A Title Case headline keeps the names the lead corroborates")
        assertFalse(titleCase.names.contains("furious"), "… and no other capitalized word")
        let plainStart = EventFeatures(
            title: "Thousands march in Paris against pension reform",
            description: "Thousands marched in Paris on Saturday.", date: now)
        assertFalse(plainStart.names.contains("thousands"), "An ordinary sentence-initial word is still no name")

        // The pair model's input prefix (#626): the gap and the publishers in plain words, "unknown" when absent.
        assertEqual(
            EventMatcher.pairModelInput("Headline\nLead", gap: 14.4 * 3600, samePublisher: true),
            "gap 14 hours; same publisher. Headline\nLead", "Gap and one publisher")
        assertEqual(
            EventMatcher.pairModelInput("H", gap: 1.6 * 3600, samePublisher: false),
            "gap 2 hours; different publishers. H", "Rounded gap and two publishers")
        assertEqual(
            EventMatcher.pairModelInput("H", gap: nil, samePublisher: nil), "gap unknown; publishers unknown. H",
            "Public pretraining rows without dates or publishers")

        // Admission and rescue knobs measured in #582, all off in the standard policy.
        var sweep = EventMatchPolicy.standard
        let storm = features(
            ["austen", "storm austen"], ["wind", "power", "cut"], places: [EventPlaces.canonical("UK")])
        let stormLater = features(
            ["austen", "storm austen"], ["wind", "batter", "rain"], hours: 2, places: [EventPlaces.canonical("UK")])
        assertFalse(
            EventMatcher.assess(storm, stormLater, embeddingSimilarity: 0.66).isMatch,
            "Two shared names and a cosine under 0.70 are no match by default")
        sweep.twoAnchorRescueThreshold = 0.65
        assertTrue(
            EventMatcher.assess(storm, stormLater, policy: sweep, embeddingSimilarity: 0.66).isMatch,
            "The two-anchor rescue links them when switched on")
        let bare = features([], ["central", "bank", "rate", "hold"])
        let bareLater = features([], ["central", "bank", "rate", "unchanged"], hours: 1)
        assertFalse(
            EventMatcher.needsPairModel(EventMatcher.assess(bare, bareLater, embeddingSimilarity: 0.9)),
            "Without any shared anchor the pair model is not asked by default")
        sweep = EventMatchPolicy.standard
        sweep.anchorlessModelCosine = 0.85
        assertTrue(
            EventMatcher.needsPairModel(EventMatcher.assess(bare, bareLater, policy: sweep, embeddingSimilarity: 0.9)),
            "An anchorless pair at a high cosine goes to the model when switched on")
        sweep = EventMatchPolicy.standard
        sweep.compatibleRequiresMatch = true
        let open = EventMatcher.assess(englishStrike, englishStrikeLater)
        assertTrue(open.isCompatible && !open.isMatch, "A borderline pair with a shared name is compatible by default")
        assertFalse(
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
                assertTrue(false, "The pair model is never called for French reports")
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
        assertTrue(
            EventMatcher.assess(a, b).isMatch && EventMatcher.assess(b, c).isMatch, "Chain fixture: neighbours match")
        assertTrue(EventMatcher.eventScore(for: c, members: [b]) != nil, "C fits an event holding only B")
        assertTrue(
            EventMatcher.eventScore(for: c, members: [a, b]) == nil, "Whole-event compatibility stops the chain A≈B≈C")
        assertTrue(
            EventMatcher.eventScore(for: quakeLater, members: [quake], excluded: true) == nil,
            "A local exclusion always wins")
        var capped = EventMatchPolicy.standard
        capped.maximumEventSize = 1
        assertTrue(
            EventMatcher.eventScore(for: quakeLater, members: [quake], policy: capped) == nil,
            "Events stop growing at their size bound")

        let extracted = EventFeatures(
            title: "Apple reports record third-quarter revenue in 2026",
            description:
                "<p>Apple said on Thursday that revenue in its fiscal Q3 rose, officials in Cupertino said.</p>",
            date: now)
        assertTrue(extracted.periods.contains("q3"), "Quarter phrases and Q3 tokens become periods")
        assertTrue(extracted.weekdays.contains("thursday"), "Weekdays are explicit when-signals")
        assertTrue(extracted.years.contains("2026"), "Years are explicit when-signals")
        assertTrue(extracted.titleNumbers.isEmpty, "Years are not headline figures")
        assertFalse(
            extracted.keywords.contains("say") || extracted.keywords.contains("said"),
            "Reporting verbs are not evidence")
        assertFalse(extracted.keywords.contains { $0.contains("<") || $0 == "p" }, "Markup is not evidence")
        assertTrue(
            extracted.anchors.contains("cupertino"), "Mid-sentence names are anchors even when the tagger misses them")
        let toll = EventFeatures(title: "Drone strike kills three in Kharkiv", description: "", date: now)
        assertEqual(toll.tollNumbers, ["3"], "Spelled casualty figures are tolls")
        assertTrue(toll.titleNumbers.isEmpty, "Casualty tolls are not distinguishing headline figures")
        assertTrue(toll.anchors.contains("kharkiv"), "Places in a headline are anchors")
        let magnitude = EventFeatures(title: "Magnitude 6 earthquake hits Malatya", description: "", date: now)
        assertEqual(magnitude.titleNumbers, ["6"], "Other headline figures still tell incidents apart")

        // Updated tolls of one attack match; the same toll wording elsewhere does not erase a place conflict.
        let twelve = EventFeatures(
            title: "Russian attack on Ukraine’s Kramatorsk kills at least 12 people",
            description: "A missile strike hit buses in the eastern city of Kramatorsk in Donetsk region.", date: now)
        let thirty = EventFeatures(
            title: "Russian attack on bus kills at least 30 people near Ukraine frontline",
            description: "The strike on Kramatorsk buses in Donetsk region killed civilians.",
            date: now.addingTimeInterval(2 * 3600))
        assertEqual(twelve.tollNumbers, ["12"], "Digits before a casualty word are a toll")
        assertEqual(thirty.tollNumbers, ["30"], "Digits after 'kills at least' are a toll")
        assertTrue(
            EventMatcher.assess(twelve, thirty).conflict != .titleNumbers, "Rising tolls of one attack do not conflict")

        // Places: aliases and nationality adjectives resolve to one country; city against country is not a conflict.
        assertEqual(
            EventPlaces.canonical("U.S."), EventPlaces.canonical("American"), "U.S. and American are one country")
        assertEqual(EventPlaces.canonical("Spanish"), EventPlaces.canonical("Spain"), "Spanish means Spain")
        assertEqual(EventPlaces.canonical("Madrid"), "madrid", "Cities stay names")
        let spain = features(
            ["abascal"], ["eviction", "pensioner", "housing", "protest"], places: [EventPlaces.canonical("Spain")])
        let madrid = features(
            ["abascal"], ["eviction", "pensioner", "housing", "protest"], hours: 1, places: ["madrid"])
        assertTrue(
            EventMatcher.assess(spain, madrid).isMatch, "A city and its story's country are not contradicting places")
        let ukraine = features(["kramatorsk"], ["strike", "bus", "kill"], places: [EventPlaces.canonical("Ukraine")])
        let syria = features(
            ["kramatorsk"], ["strike", "drone", "market"], hours: 1, places: [EventPlaces.canonical("Syria")])
        assertEqual(EventMatcher.assess(ukraine, syria).conflict, .places, "Different countries conflict")
        let syriaSameWords = features(
            ["kramatorsk"], ["strike", "bus", "kill"], hours: 1, places: [EventPlaces.canonical("Syria")])
        assertEqual(
            EventMatcher.assess(ukraine, syriaSameWords).conflict, .places,
            "Strong wording cannot soften a country conflict")
        assertFalse(EventMatcher.assess(ukraine, syriaSameWords).isMatch, "A country conflict never matches")
        assertTrue(
            EventMatcher.assess(odesa, gdansk).conflict != nil,
            "Conflicting places remain a veto with one shared name")
        // Three shared specific names outweigh one mistyped place (#580): a match report and its live blog share the
        // teams and players while the tagger reads a player's name as a place.
        let matchReport = features(
            ["real madrid", "rb leipzig", "mbappe"], ["score", "win", "thrash"], places: ["leipzig"])
        let liveBlog = features(
            ["real madrid", "rb leipzig", "mbappe"], ["live", "score", "win"], hours: 1, places: ["bellingham"])
        assertEqual(
            EventMatcher.assess(matchReport, liveBlog).conflict, nil,
            "A place conflict needs fewer than three shared specific names")
        let canadian = EventFeatures(
            title: "Canadian writer Anne Carson wins 2026 Nobel Prize in Literature", description: "", date: now)
        assertTrue(
            canadian.countries.contains(EventPlaces.canonical("Canada")),
            "An untyped nationality adjective is a country")

        // A compatible majority cannot override hard contradictions.
        let d = features(
            ["afad"], ["earthquake", "magnitude", "damage", "building", "aid"], hours: 1, places: ["malatya"])
        assertTrue(
            EventMatcher.eventScore(for: c, members: [a, b, d]) == nil,
            "A weekday conflict vetoes admission even with two of three compatible members")
        assertTrue(
            EventMatcher.eventScore(for: c, members: [a, b]) == nil, "Both members of a two-member event must agree")
        var weak = pair
        weak.isCompatible = false
        weak.isMatch = false
        weak.score = 0.5
        assertTrue(
            EventMatcher.eventScore(pairs: [pair, pair, weak]) != nil,
            "A noncontradictory weak minority remains allowed")
        var generic = weak
        generic.sharedSpecificAnchors = 0
        assertTrue(
            EventMatcher.eventScore(pairs: [pair, pair, generic]) == nil,
            "Two-thirds compatibility cannot override missing specific evidence on a cross-pair")
        var undated = quake
        undated.date = DateParser.unknownDate
        assertEqual(
            EventMatcher.assess(undated, quakeLater).conflict, .unknownDate, "Unknown publication times cannot match")
        for conflict in [EventConflict.language, .timeGap, .period, .year, .weekday, .excluded] {
            var hard = pair
            hard.conflict = conflict
            hard.isMatch = false
            hard.isCompatible = false
            assertTrue(
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
        assertTrue(
            EventMatcher.eventScore(pairs: [pair, pair, diverging]) == nil, "One semantic veto blocks by default")
        assertTrue(
            EventMatcher.eventScore(pairs: [pair, pair, diverging], policy: vetoMinimum) != nil,
            "One semantic veto is outvoted when two are required")
        assertTrue(
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
        assertTrue(
            EventMatcher.eventScore(pairs: [editionMatch, editionItem, editionItem]) == nil,
            "An edition's other items veto by default")
        assertTrue(
            EventMatcher.eventScore(pairs: [editionMatch, editionItem, editionItem], policy: editionPolicy) != nil,
            "An edition joins through its matched pair")
        assertTrue(
            EventMatcher.eventScore(pairs: [editionItem, editionItem], policy: editionPolicy) == nil,
            "An edition without a matched pair stays out")
        var editionMember = diverging
        editionMember.memberIsEdition = true
        assertTrue(
            EventMatcher.eventScore(pairs: [pair, editionMember]) == nil, "An edition member vetoes by default")
        assertTrue(
            EventMatcher.eventScore(pairs: [pair, editionMember], policy: editionPolicy) != nil,
            "An edition member does not count against a report")
        assertTrue(
            EventMatcher.eventScore(pairs: [editionMember], policy: editionPolicy) == nil,
            "A member that is only an edition still has to match")
        var matchedEdition = pair
        matchedEdition.memberIsEdition = true
        assertTrue(
            EventMatcher.eventScore(pairs: [matchedEdition, diverging], policy: editionPolicy) == nil,
            "A match with the edition alone carries no report into its host")
        assertFalse(
            EventMatcher.forced(editionMember, policy: editionPolicy).memberIsEdition,
            "A reader's inclusion with an edition keeps counting")
        var placed = diverging
        placed.conflict = .places
        assertTrue(
            EventMatcher.eventScore(pairs: [pair, pair, pair, diverging, placed], policy: vetoMinimum) == nil,
            "Two vetoes of either outvotable kind block under the minimum")
        assertTrue(
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
        assertEqual(EventMatcher.assess(kyivBlaze, lyonBlaze).conflict, .places, "Disjoint countries are a places veto")
        let maskedPlaces = EventMatcher.assess(kyivBlaze, lyonBlaze, policy: vetoMinimum)
        assertTrue(
            maskedPlaces.conflict == .places && maskedPlaces.masksAbsoluteConflict,
            "Under the veto threshold the conflict stays places, so story links keep the veto, and is marked absolute")
        assertTrue(
            EventMatcher.conflictsBlock([pair, pair, pair, maskedPlaces], policy: vetoMinimum),
            "A places veto with a headline conflict behind it is not outvoted")
        assertTrue(
            !EventMatcher.conflictsBlock(
                [pair, EventMatcher.forced(maskedPlaces, policy: vetoMinimum)], policy: vetoMinimum),
            "A reader's Same Event verdict clears the absolute mask too, so revalidation keeps the pair")
        var weekday = diverging
        weekday.conflict = .weekday
        assertTrue(
            EventMatcher.eventScore(pairs: [pair, pair, weekday], policy: vetoMinimum) == nil,
            "Other conflicts stay absolute under the veto threshold")

        // Borderline floor (#737, evaluation): a compatible borderline pair the pair model scores low needs three names.
        var borderline = pair
        borderline.isMatch = false
        borderline.sharedSpecificAnchors = 1
        var floor = EventMatchPolicy.standard
        floor.borderlineFloor = 0.5
        let defaultFloor = EventMatcher.applyingBorderlineFloor(borderline, probability: 0.3)
        assertTrue(
            defaultFloor.isCompatible && EventMatcher.eventScore(pairs: [pair, defaultFloor]) != nil,
            "A low-scored borderline pair is compatible by default")
        let floored = EventMatcher.applyingBorderlineFloor(borderline, probability: 0.3, policy: floor)
        assertTrue(
            EventMatcher.eventScore(pairs: [pair, floored], policy: floor) == nil,
            "Below the floor with one shared name it no longer carries the join")
        var named = borderline
        named.sharedSpecificAnchors = 3
        assertTrue(
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
        assertFalse(
            EventMatcher.assess(pontoonFollowUp, bridgeStrike).isMatch
                || EventMatcher.assess(pontoonFollowUp, bridgeStrike).isCompatible,
            "A follow-up plan whose primary headline clause shares only a city with a prior strike must not merge into the strike"
        )
        assertTrue(
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
        assertTrue(
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
        assertTrue(
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
        assertTrue(
            EventMatcher.assess(g7First, g7Second).isMatch,
            "Alphanumeric group names like G7 act as specific anchors rather than headline figures")

        let demonymReport = EventFeatures(
            title: "Americans and Iranians meet in UAE for talks",
            description: "Palestinians and Saudis also watched the diplomatic session closely.",
            date: now)
        assertTrue(
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
        assertTrue(
            !figureFirst.titleNumbers.intersection(figureSecond.titleNumbers).isEmpty
                && EventMatcher.assess(figureFirst, figureSecond).sharedAnchors >= 1,
            "Shared headline figures are retained on both reports to corroborate lexical evidence")

        let leadingClause = EventFeatures(
            title: "Hours after winning architectural award, developer launches new housing project",
            description: "The developer unveiled plans for the residential tower.",
            date: now)
        assertTrue(
            leadingClause.primaryTitleTerms.contains("developer")
                && !leadingClause.primaryTitleTerms.contains("architectural"),
            "Leading temporal background clause is excluded from primaryTitleTerms")
        let wakeClause = EventFeatures(
            title: "Regulators tighten ferry inspections in the wake of harbor collision",
            description: "Maritime officials ordered new safety checks across the fleet.",
            date: now)
        assertTrue(
            wakeClause.primaryTitleTerms.contains("ferry")
                && !wakeClause.primaryTitleTerms.contains("collision"),
            "Trailing 'in the wake of' background clause is excluded from primaryTitleTerms")

        // Supported leading connector forms and punctuation delimiters:
        let followingLeading = EventFeatures(
            title: "Following summit, President announces ceasefire accord",
            description: "The leaders signed the diplomatic agreement.", date: now)
        assertTrue(
            !followingLeading.primaryTitleTerms.isEmpty
                && !followingLeading.primaryTitleTerms.contains("summit"),
            "Leading 'Following <clause>,' isolates primary clause terms")

        let daysAfterLeading = EventFeatures(
            title: "Days after volcano eruption, flights resume across archipelago",
            description: "Airlines restored service as ash clouds cleared.", date: now)
        assertTrue(
            daysAfterLeading.primaryTitleTerms.contains("resume")
                && !daysAfterLeading.primaryTitleTerms.contains("volcano"),
            "Leading 'Days after <clause>,' isolates primary clause terms")

        let colonLeading = EventFeatures(
            title: "Shortly after verdict: protesters gather outside courthouse",
            description: "Crowds assembled following the judge's ruling.", date: now)
        assertTrue(
            !colonLeading.primaryTitleTerms.isEmpty
                && !colonLeading.primaryTitleTerms.contains("verdict"),
            "Leading connector with colon delimiter isolates primary clause")

        // Hardening (#502–#504): shared matching text, consequence-only primary clauses, person tokens.
        let plainText = EventFeatures.matchingText(
            title: "A <b>bold</b>\nheadline", description: "<p>Lead &amp; more</p><img src=\"x\">")
        assertTrue(
            !plainText.contains("<") && plainText.contains("Lead & more") && plainText.hasPrefix("A ")
                && plainText.filter(\.isNewline).count == 1,
            "Matching text strips markup and entities and keeps one headline line")
        let tollAfter = EventFeatures(
            title: "Three dead after gunman opens fire at Westfield mall in Sydney",
            description:
                "Police said a gunman shot shoppers at the Westfield Bondi Junction mall in Sydney on Saturday before an officer shot him dead.",
            date: now)
        assertTrue(
            tollAfter.primaryTitleTerms.isEmpty,
            "A primary clause that only counts the dead names no act of its own")
        let namedGunman = EventFeatures(
            title: "Sydney mall shooting: police name Westfield gunman",
            description:
                "New South Wales police identified the gunman who shot shoppers at Westfield Bondi Junction in Sydney before an officer shot him.",
            date: now.addingTimeInterval(2 * 3600))
        assertTrue(
            EventMatcher.assess(tollAfter, namedGunman).isMatch,
            "A toll-after headline matches the report that leads with the shooting itself")
        assertFalse(
            EventMatcher.assess(pontoonFollowUp, bridgeStrike).isCompatible,
            "A primary clause that names an act keeps the background-clause guard")
        let jordan = EventFeatures(
            title: "Michael Jordan returns to Chicago for championship ceremony",
            description: "The former Chicago Bulls star Michael Jordan attended the ceremony at the United Center.",
            date: now)
        assertFalse(jordan.countries.contains("@JO"), "A word of a typed person name is never a country")

        let emDashLeading = EventFeatures(
            title: "Soon after power outage — subway lines reopen across city",
            description: "Transit authorities restored train operations.", date: now)
        assertTrue(
            !emDashLeading.primaryTitleTerms.isEmpty
                && !emDashLeading.primaryTitleTerms.contains("outage"),
            "Leading connector with em-dash delimiter isolates primary clause")

        let enDashLeading = EventFeatures(
            title: "Just after rocket launch – satellites achieve orbit successfully",
            description: "Space agency confirmed payload separation.", date: now)
        assertTrue(
            !enDashLeading.primaryTitleTerms.isEmpty
                && !enDashLeading.primaryTitleTerms.contains("launch"),
            "Leading connector with en-dash delimiter isolates primary clause")

        // Supported trailing connector forms:
        let followingTrailing = EventFeatures(
            title: "Port workers end strike following mediation agreement",
            description: "Labor union reached deal with terminal operators.", date: now)
        assertTrue(
            followingTrailing.primaryTitleTerms.contains("strike")
                && !followingTrailing.primaryTitleTerms.contains("mediation"),
            "Trailing 'following' background clause is excluded from primaryTitleTerms")

        let shortlyAfterTrailing = EventFeatures(
            title: "Bridge reopens shortly after inspection check",
            description: "Engineers cleared the crossing for vehicle traffic.", date: now)
        assertTrue(
            !shortlyAfterTrailing.primaryTitleTerms.isEmpty
                && !shortlyAfterTrailing.primaryTitleTerms.contains("inspection"),
            "Trailing 'shortly after' background clause is excluded from primaryTitleTerms")

        let afterTrailing = EventFeatures(
            title: "Factory restarts operations after gas leak contained",
            description: "Safety inspectors allowed workers to return to the facility.", date: now)
        assertTrue(
            !afterTrailing.primaryTitleTerms.isEmpty
                && !afterTrailing.primaryTitleTerms.contains("contained"),
            "Trailing 'after' background clause is excluded from primaryTitleTerms")

        // Unicode and edge-case robustness:
        let unicodeAccented = EventFeatures(
            title: "Café chain expands across Madrid — hours after regional approval",
            description: "The coffee retailer opened five new storefronts in the capital.", date: now)
        assertTrue(
            !unicodeAccented.primaryTitleTerms.isEmpty
                && !unicodeAccented.primaryTitleTerms.contains("approval"),
            "Accented characters and em-dashes maintain safe Unicode range alignment")

        let unicodeEmoji = EventFeatures(
            title: "🚨 Hospitals prepare emergency wards following toxic chemical spill",
            description: "Medical teams mobilized across the province.", date: now)
        assertTrue(
            !unicodeEmoji.primaryTitleTerms.isEmpty
                && !unicodeEmoji.primaryTitleTerms.contains("spill"),
            "Surrogate pair emojis do not panic string indexing in background clause extraction")

        let plainHeadline = EventFeatures(
            title: "Telecom provider rolls out fiber network in suburban districts",
            description: "Broadband speeds doubled for residential subscribers.", date: now)
        assertTrue(
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
        assertEqual(report.merged, 1, "Fragments of one story merge without a judge when member pairs decide")
        assertEqual(
            try await db.eventID(forArticle: "m1"), try await db.eventID(forArticle: "m4"),
            "The merged event holds both fragments")
        assertEqual(try await EventClusterer.run(in: db, now: now).merged, 0, "A merged story is not merged again")
        await db.close()

        let forming = DatabaseEngine(path: ":memory:")
        try await forming.open()
        try await forming.upsertArticles(Array(quake.prefix(3)))
        _ = try await EventClusterer.run(in: forming, now: now)
        let seedID = try await forming.eventID(forArticle: "m1")
        assertTrue(seedID != nil, "Three independently worded reports still form an event")
        assertEqual(try await forming.eventID(forArticle: "m2"), seedID, "Second publisher joins")
        assertEqual(try await forming.eventID(forArticle: "m3"), seedID, "Third publisher joins")
        await forming.close()

        let vetoed = try await library()
        let vetoReport = try await EventClusterer.run(in: vetoed, now: now, limit: 0)
        assertEqual(vetoReport.merged, 1, "Supported fragments merge deterministically")
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
        assertTrue(
            terms(groups[0][0]).intersection(terms(groups[2][0])).count < 2,
            "The third fragment requires terms introduced by the second")
        var chainPolicy = EventMatchPolicy.standard
        chainPolicy.minimumSharedTerms = 2
        chainPolicy.matchScore = 0.35
        chainPolicy.compatibilityScore = 0
        chainPolicy.compatibleShare = 0
        let chainReport = try await EventClusterer.run(in: chain, matchPolicy: chainPolicy, now: now, limit: 0)
        assertEqual(chainReport.merged, 1, "New vocabulary cannot bridge a cross-pair without shared specific evidence")
        await chain.close()

        // A local exclusion between fragments always wins.
        let excluded = try await library()
        if let event = try await excluded.eventID(forArticle: "m3") {
            _ = try await excluded.addArticles(["m1"], toEvent: event, at: now)
            try await excluded.separateArticle("m1", fromEvent: event, at: now)
        }
        _ = try await excluded.addArticles(["m1"], toEvent: try await excluded.eventID(forArticle: "m2") ?? "", at: now)
        let exclusions = try await excluded.eventExclusions(for: quake.map(\.id) + (0..<450).map { "a-missing-\($0)" })
        assertEqual(exclusions["m1"], Set(["m3", "m4"]), "Bulk exclusions span SQLite parameter batches")
        assertEqual(exclusions["m3"], Set(["m1"]), "Bulk exclusions work from either endpoint")
        assertEqual(exclusions["m4"], Set(["m1"]), "Repeated rows across batches do not duplicate exclusions")
        assertEqual(exclusions.count, 3, "Unknown and unexcluded members create no exclusion entries")
        assertTrue(try await excluded.eventExclusions(for: []).isEmpty, "An empty member set needs no exclusion query")
        assertEqual(
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
        assertTrue(
            try await hard.eventID(forArticle: "h1") == nil, "Reports of strikes in different countries stay apart")
        assertEqual(hardReport.created, 0, "No event forms across a country conflict")
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

        assertEqual(try await listed(), Set(all.map(\.id)), "Importance never hides a publication")
        assertEqual(try await db.waitingStoryCount(), 0, "No story waits for model approval")
        assertEqual(
            try await db.fetchArticles(limit: nil).count, all.count,
            "Lists that do not hide waiting stories list everything")
        try await db.recordImportance("pair-2", .notable, at: now)
        assertTrue(
            try await listed().isSuperset(of: ["pair-1", "pair-2"]), "One important report shows its whole event")
        let reviewed = Set(
            try await db.ratedImportanceRows(level: .minor, activeSince: now.addingTimeInterval(-72 * 3600)).map(\.id))
        assertEqual(
            reviewed, ["minor", "saved", "read", "pair-1", "wide-1", "wide-2", "wide-3", "wide-4"],
            "The #309 review lists every minor-rated story in the window")
        assertEqual(
            reviewed.subtracting(try await db.notificationStoryIDs(Array(reviewed))), [],
            "Minor ratings do not remove notification eligibility")
        assertTrue(
            try await db.ratedImportanceRows(level: .minor, activeSince: now).isEmpty,
            "Stories before the window are not reviewed")

        assertEqual(
            try await db.expireWaitingStories(now: now.addingTimeInterval(3600)), 0, "Nothing expires within a day")
        assertEqual(
            try await db.expireWaitingStories(now: now.addingTimeInterval(25 * 3600)), 0,
            "Importance never expires an unread story")
        assertEqual(try await listed(), Set(all.map(\.id)), "All publications remain after 24 hours")
        assertTrue(try await db.isSaved(articleId: "saved"), "Saved state remains")
        assertTrue(try await db.isRead(articleId: "read"), "Read history remains")
        let priorities = try await db.briefingPriorities(articleIDs: all.map(\.id))
        assertEqual(priorities["wide-1"]?.sourceCount, 4, "Coverage counts publishers across event members")
        assertEqual(priorities["pair-1"]?.importance, .notable, "An event uses its highest stored rating")
        assertEqual(priorities["unrated"]?.importance, nil, "Unrated metadata stays neutral")
        assertEqual(priorities["minor"]?.sourceCount, 1, "A singleton has one publisher")
        await db.close()

        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("news-expiry-\(UUID())")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        let legacyPath = legacyDirectory.appendingPathComponent("library.sqlite3").path
        let legacy = DatabaseEngine(path: legacyPath)
        try await legacy.open()
        var legacyHandle: OpaquePointer?
        assertEqual(sqlite3_open(legacyPath, &legacyHandle), SQLITE_OK, "Open old expiry fixture")
        assertEqual(
            sqlite3_exec(
                legacyHandle, "INSERT INTO expired_stories(key, expired_at) VALUES('legacy', 1);", nil, nil, nil),
            SQLITE_OK, "Preserve an old importance-expiry tombstone")
        sqlite3_close(legacyHandle)
        assertEqual(
            try await legacy.upsertArticles([story("legacy", "One")]), ["legacy"],
            "Old tombstones do not suppress feeds")
        assertEqual(try await legacy.fetchArticles(limit: nil).count, 1, "The returning publisher story is readable")
        await legacy.close()

        // Panel retention remains intact; importance no longer deletes any publisher's stories.
        let panel = DatabaseEngine(path: ":memory:")
        try await panel.open()
        let panelFeed = TensionMethodology.v1.panel[0].url
        try await panel.upsertArticles([story("panel-minor", "Panel")], feedUrl: panelFeed)
        try await panel.upsertArticles([story("other-minor", "Other")], feedUrl: "https://example.com/other.xml")
        for id in ["panel-minor", "other-minor"] { try await panel.recordImportance(id, .minor, at: now) }
        assertEqual(
            try await panel.expireWaitingStories(now: now.addingTimeInterval(25 * 3600), keepingFeedURLs: [panelFeed]),
            0,
            "Neither panel nor ordinary minor stories expire")
        let panelDay = DateInterval(start: now.addingTimeInterval(-12 * 3600), duration: 24 * 3600)
        assertEqual(
            try await panel.tensionCorpus(day: panelDay, feedURLs: [panelFeed]).map(\.article.id), ["panel-minor"],
            "The waiting panel story still counts in its tension day")
        assertEqual(
            try await panel.fetchArticles(limit: nil, options: ArticleFetchOptions(hidingWaitingStories: true)).count,
            2,
            "Panel and ordinary stories remain visible")
        let collectionOff = try await StoryCurator.run(
            in: panel, now: now.addingTimeInterval(26 * 3600))
        assertEqual(
            collectionOff.expired, 0, "Image/audit curation never expires a story, regardless of collection")
        await panel.close()

        // Audit ratings (the opt-in live curation measurement) never hide a story.
        let curated = DatabaseEngine(path: ":memory:")
        try await curated.open()
        try await curated.upsertArticles([story("c1", "One"), story("c2", "Two"), story("c3", "Three")])
        assertEqual(
            try await curated.fetchArticles(limit: nil, options: ArticleFetchOptions(hidingWaitingStories: true)).count,
            3, "Unrated stories show")
        try await curated.recordImportance("c1", .major, at: now)
        for id in ["c2", "c3"] { try await curated.recordImportance(id, .minor, at: now) }
        assertEqual(
            Set(
                try await curated.fetchArticles(limit: nil, options: ArticleFetchOptions(hidingWaitingStories: true))
                    .map(\.id)), ["c1", "c2", "c3"],
            "Explicit audit ratings cannot hide stories")
        assertEqual(
            try await curated.notificationStoryIDs(["c1", "c2", "c3", "missing"]), ["c1", "c2", "c3"],
            "All existing stories remain eligible; missing stories do not notify")
        let changed = FeedArticle(
            storedID: "c2", title: "Updated national emergency", link: story("c2", "Two").link,
            guid: "c2", description: "A significant update", pubDate: now, source: "Two")
        try await curated.upsertArticles([changed])
        assertFalse(
            try await curated.recordImportance(
                "c2", .minor, expectedTitle: "Story c2", expectedDescription: "Summary."),
            "A rating begun before a publisher edit cannot hide the updated story")
        assertTrue(
            try await curated.notificationStoryIDs(["c2"]).contains("c2"), "The changed, now unrated headline shows")
        await curated.close()

        let suite = testDefaultsSuite("test.importance-notifications")
        let defaults = UserDefaults(suiteName: suite)!
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
        assertEqual(notified, reports.map(\.title), "Refresh never filters eligible stories by model importance")
        await eventually("Image lookups follow clustering") { await pages.arrivals > 0 }
        await pages.open()
        await refresh.value
        manager.stopBackgroundWork()
        await store.database.close()
        assertEqual(OnDeviceImportanceJudge.level("Major."), .major, "MAJOR is major")
        assertEqual(OnDeviceImportanceJudge.level("notable"), .notable, "NOTABLE is notable")
        assertTrue(OnDeviceImportanceJudge.level("It depends") == nil, "Anything else is no rating")
        // #309: Mars's rulings on the three borderline single-source stories.
        let instructions = OnDeviceImportanceJudge.prompt(
            EventJudgeReport(id: "r", title: "Flour price rises", summary: ""))
        for rule in [
            "programme cuts at a broadcaster, is MINOR", "trespass arrests are MINOR",
            "terrorism charges or a real security breach are NOTABLE",
            "Nationwide price changes of staple goods are NOTABLE",
        ] {
            assertTrue(instructions.contains(rule), "Rating instructions keep the borderline rule: \(rule)")
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
        assertEqual(try await db.pruneOldArticles(keepReadDays: 30), 1, "Old read stories are pruned; saved ones stay")
        assertTrue(try await db.isSaved(articleId: saved.id), "Pruning keeps saved stories")
        await db.close()

        var handle: OpaquePointer?
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open the orphan fixture")
        defer { sqlite3_close(handle) }
        func count(_ sql: String) -> Int32 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
        }
        assertEqual(
            count("SELECT count(*) FROM pragma_foreign_key_check;"), 0, "No state row outlives or precedes its article")
        assertEqual(
            count("SELECT count(*) FROM article_state WHERE article_id = 'test_non_existent';"), 0,
            "Writes for a missing article store nothing")
        assertEqual(
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
            assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open cluster fixture")
            assertEqual(
                sqlite3_create_function_v2(
                    handle, "news_publisher_input", 3, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, publisherInputFunction,
                    nil, nil, nil), SQLITE_OK, "Register publisher hashing on the isolated cluster writer")
            assertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Edit cluster fixture")
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
        assertEqual(report.processed, 9, "A pass handles every recent unmatched article exactly once")
        guard let quakeEvent = try await db.eventID(forArticle: "quake-1") else {
            return assertTrue(false, "Reports of one earthquake form an event")
        }
        let secondJoined = try await together("quake-1", "quake-2")
        let thirdJoined = try await together("quake-1", "quake-3")
        assertTrue(secondJoined && thirdJoined, "All reports of the earthquake join one event")
        assertTrue(report.changedEvents.contains(quakeEvent), "The pass reports the events it changed")
        assertFalse(
            try await together("strike-monday", "strike-tuesday"), "Different strikes in one region stay separate")
        assertFalse(
            try await together("apple-q3", "apple-q4"), "Different quarterly reports of one company stay separate")
        assertFalse(try await together("live-1", "live-2"), "Identical generic headlines are not one event")
        assertTrue(
            try await db.eventID(forArticle: "old") == nil, "Articles outside the active lifetime are never matched")
        assertEqual(try await EventClusterer.run(in: db, now: now).processed, 0, "A second pass recomputes nothing")

        // A changed member is matched again and leaves an event it no longer fits.
        let version = try await db.fetchEvent(id: quakeEvent)?.membershipVersion ?? 0
        execute(
            "UPDATE articles SET title='Central bank holds interest rates', description='The central bank left its benchmark rate unchanged.' WHERE id='quake-3';"
        )
        let changed = try await EventClusterer.run(in: db, now: now)
        assertEqual(changed.processed, 1, "Only the changed article is matched again")
        assertEqual(changed.detached, 1, "A member that no longer fits leaves its event")
        assertTrue(try await db.eventID(forArticle: "quake-3") == nil, "The changed article is no longer a member")
        assertEqual(
            try await db.fetchEvent(id: quakeEvent)?.membershipVersion, version + 1, "Leaving bumps the version once")

        // A new report joins the active event it fits as a whole.
        try await db.upsertArticles([
            article(
                "quake-4", "Malatya earthquake: magnitude 7 quake damages buildings in eastern Turkey",
                "Rescuers searched damaged buildings in Malatya in eastern Turkey after the magnitude 7 earthquake on Monday, the disaster agency AFAD said.",
                hoursAgo: 1, source: "Gazette Four")
        ])
        let grown = try await EventClusterer.run(in: db, now: now)
        assertEqual(grown.joined, 1, "A new report joins the event")
        assertTrue(try await together("quake-1", "quake-4"), "The new report shares the event ID")

        // "These are different events" is a local exclusion that survives refreshes and re-clustering.
        try await db.setSaved(articleId: "quake-2", isSaved: true)
        let separated = try await db.separateArticle("quake-2", fromEvent: quakeEvent)
        assertFalse(separated.memberArticleIDs.contains("quake-2"), "Separation removes the article from the event")
        assertEqual(
            try await db.eventExclusions(of: "quake-2"), Set(separated.memberArticleIDs),
            "The article is excluded from every remaining member")
        do {
            _ = try await db.separateArticle("quake-2", fromEvent: quakeEvent)
            assertTrue(false, "Only members can be separated")
        } catch {}
        assertEqual(
            try await EventClusterer.run(in: db, now: now).processed, 1, "Only the separated article is matched again")
        assertFalse(try await together("quake-2", "quake-1"), "A separated article never rejoins its excluded partners")
        try await db.upsertArticles([
            EventControlSet.articles(now: now, root: fixtureRoot).first { $0.article.id == "quake-2" }!.article
        ])
        _ = try await EventClusterer.run(in: db, now: now)
        assertFalse(try await together("quake-2", "quake-1"), "Exclusions survive a refresh of the article")
        execute("DELETE FROM event_members; DELETE FROM events; DELETE FROM event_match_state;")
        _ = try await EventClusterer.run(in: db, now: now)
        let rejoinedFirst = try await together("quake-2", "quake-1")
        let rejoinedNew = try await together("quake-2", "quake-4")
        assertFalse(rejoinedFirst || rejoinedNew, "Exclusions survive a complete re-clustering")
        assertTrue(
            try await together("quake-1", "quake-4"), "Re-clustering rebuilds the event without the excluded article")
        assertTrue(try await db.isSaved(articleId: "quake-2"), "Saving stays with the article through regrouping")

        // Passes are bounded and cancellable; unfinished work stays pending.
        try await db.upsertArticles(
            (0..<5).map {
                article(
                    "bulk-\($0)", "Unrelated bulletin \($0)", "Standalone notice \($0).", hoursAgo: 1,
                    source: "Bulletin")
            })
        assertEqual(try await EventClusterer.run(in: db, now: now, limit: 2).processed, 2, "A pass stops at its bound")
        let cancelled = Task { () async throws -> EventClusteringReport in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EventClusterer.run(in: db, now: now)
        }
        do {
            _ = try await cancelled.value
            assertTrue(false, "A cancelled pass throws")
        } catch is CancellationError {}
        assertEqual(
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
        assertEqual(bounded.created, 1, "The seed forms an event with its later partner")
        assertEqual(bounded.processed, 2, "An out-of-batch partner cannot overspend the article budget")
        assertEqual(
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
            return assertTrue(false, "Seed an event matched by an older matcher")
        }
        let seededVersion = try await db.fetchEvent(id: upgradeEvent)?.membershipVersion
        try await db.setSaved(articleId: "upgrade-3", isSaved: true)
        try await db.markRead(articleId: "upgrade-1", isRead: true)
        let upgradePending = try await db.pendingEventMatchRows(
            activeSince: now.addingTimeInterval(-72 * 3600),
            matcherVersion: EventMatcher.version, limit: 10)
        assertEqual(
            upgradePending.map(\.id), ["upgrade-3", "upgrade-2", "upgrade-1"],
            "An older matcher version leaves members pending, newest first (#541)")
        assertTrue(
            upgradePending.allSatisfy(\.previouslyMatched),
            "Members pending only for the matcher version are reported as matched before")
        func upgradeFeatures(_ row: EventMatchRow) -> EventFeatures {
            EventFeatures(title: row.title, description: row.description, date: row.date)
        }
        assertTrue(
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
        assertTrue(try await db.recordEventOverview(oldOverview), "Store an overview of the old membership")
        execute(
            "CREATE TRIGGER fail_upgrade BEFORE UPDATE OF event_id ON event_members WHEN old.article_id='upgrade-3' BEGIN SELECT RAISE(ABORT, 'test upgrade rollback'); END;"
        )
        do {
            _ = try await EventClusterer.run(in: db, now: now)
            assertTrue(false, "A failed partition must propagate")
        } catch {
            assertTrue(
                error.localizedDescription.contains("test upgrade rollback"), "The intended membership write failed")
        }
        assertEqual(
            try await db.fetchEvent(id: upgradeEvent)?.memberArticleIDs.sorted(),
            ["upgrade-1", "upgrade-2", "upgrade-3"], "Failed partition rolls back all memberships")
        assertEqual(
            try await db.fetchEventOverview(eventID: upgradeEvent)?.id, oldOverview.id,
            "Rollback retains the old overview")
        assertEqual(
            try await db.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-72 * 3600),
                matcherVersion: EventMatcher.version, limit: 10
            ).count, 3, "Rollback leaves upgrade work pending")
        execute("DROP TRIGGER fail_upgrade;")
        let upgraded = try await EventClusterer.run(in: db, now: now)
        assertEqual(
            try await db.fetchEventOverview(eventID: upgradeEvent), nil,
            "A committed split invalidates the old overview")
        assertEqual(upgraded.processed, 3, "A matcher version bump matches the members again")
        assertEqual(upgraded.detached, 1, "A known-invalid legacy member moves to its own event")
        assertEqual(
            try await db.fetchEvent(id: upgradeEvent)?.memberArticleIDs.sorted(),
            ["upgrade-1", "upgrade-2"], "The earliest compatible subgroup retains the original ID")
        assertEqual(
            try await db.fetchEvent(id: upgradeEvent)?.membershipVersion, (seededVersion ?? 0) + 1,
            "Splitting bumps the original membership version")
        assertTrue(try await db.isSaved(articleId: "upgrade-3"), "A split preserves saving")
        assertTrue(try await db.isRead(articleId: "upgrade-1"), "A split preserves read history")
        assertEqual(try await EventClusterer.run(in: db, now: now).processed, 0, "The completed upgrade is idempotent")
        assertTrue(
            try await db.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-72 * 3600),
                matcherVersion: EventMatcher.version, limit: 1
            ).isEmpty, "Kept members are processed under the current matcher")
        execute(
            "UPDATE articles SET title='Central bank holds interest rates', description='The central bank left its benchmark rate unchanged.' WHERE id='upgrade-1';"
        )
        let edited = try await EventClusterer.run(in: db, now: now)
        assertEqual(edited.processed, 1, "Only the edited member is matched again")
        assertEqual(edited.detached, 1, "An edited member is checked against its event again")
        assertEqual(
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
        assertEqual(
            try await EventClusterer.run(in: db, now: now, limit: 1).processed, 0,
            "An event partition waits rather than exceeding the remaining article budget")
        assertEqual(
            try await EventClusterer.run(in: db, now: now).detached, 1,
            "An active legacy event is upgraded even when all publication dates are old")
        assertEqual(
            try await db.fetchEvent(id: activeOld.id)?.memberArticleIDs, ["active-old-1"],
            "Oldest active member keeps the original ID")
        let archive = try await db.createEvent(
            memberArticleIDs: oldMembers.map(\.id), at: now.addingTimeInterval(-100 * 3600))
        try await db.markEventMatchProcessed(oldMembers.map(\.id), matcherVersion: EventMatcher.version - 1, at: now)
        _ = try await EventClusterer.run(in: db, now: now)
        assertEqual(try await db.fetchEvent(id: archive.id), archive, "Inactive archived groups remain intact")

        let unknown = oldMembers.enumerated().map { index, item in
            FeedArticle(
                storedID: "unknown-\(index)", title: oldMembers[0].title,
                link: fixtureRoot.appendingPathComponent("unknown/\(index)").absoluteString, guid: nil,
                description: oldMembers[0].description, pubDate: DateParser.unknownDate, source: item.source)
        }
        try await db.upsertArticles(unknown)
        assertTrue(
            try await db.eventMatchRows(articleIDs: unknown.map(\.id)).allSatisfy { $0.date == DateParser.unknownDate },
            "Matching retains unknown publication dates rather than substituting ingestion time")
        assertEqual(try await EventClusterer.run(in: db, now: now).created, 0, "Undated reports stay separate")

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
        assertTrue(try await db.recordEventOverview(v5Overview), "Store an overview for the v5 event")
        try await db.setSaved(articleId: "v5-strike-2", isSaved: true)
        try await db.markRead(articleId: "v5-strike-1", isRead: true)

        let v5Run = try await EventClusterer.run(in: db, now: now)
        assertEqual(v5Run.processed, 2, "Active v5 event members are processed under v6")
        assertEqual(v5Run.detached, 1, "Disjoint primary-clause member is detached from the v5 event")
        assertEqual(
            try await db.fetchEvent(id: v5Event.id)?.memberArticleIDs, ["v5-strike-1"],
            "Primary strike story retains the original event ID")
        let movedEventID = try await db.eventID(forArticle: "v5-strike-2")
        assertTrue(movedEventID != nil && movedEventID != v5Event.id, "Moved member has a separate event")
        if let movedEventID {
            assertEqual(
                try await db.fetchEvent(id: movedEventID)?.memberArticleIDs, ["v5-strike-2"],
                "New event contains exactly the moved member")
        }
        assertEqual(
            try await db.fetchEvent(id: v5Event.id)?.membershipVersion, v5Event.membershipVersion + 1,
            "The original event version advances after moving a member")
        assertTrue(try await db.isSaved(articleId: "v5-strike-2"), "v6 preserves saving on the moved member")
        assertTrue(try await db.isRead(articleId: "v5-strike-1"), "v6 preserves read state on the kept member")
        assertEqual(
            try await db.fetchEventOverview(eventID: v5Event.id), nil,
            "Re-partitioning active event invalidates the obsolete overview")
        assertTrue(
            try await db.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-72 * 3600),
                matcherVersion: EventMatcher.version, limit: 1
            ).isEmpty, "All upgraded members are marked with current matcher version")
        await db.close()
        var handle: OpaquePointer?
        var statement: OpaquePointer?
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Inspect cluster library")
        assertEqual(
            sqlite3_prepare_v2(handle, "PRAGMA foreign_key_check;", -1, &statement, nil), SQLITE_OK,
            "Check cluster references")
        assertTrue(sqlite3_step(statement) == SQLITE_DONE, "Clustering leaves no dangling references")
        sqlite3_finalize(statement)
        sqlite3_close(handle)
    }

    static func testEventReadingState(fixtureRoot: URL) async throws {
        print(
            "  - Testing event seen versions, substantive updates, independence from article state and the v14 migration..."
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-event-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite3").path
        let now = Date()
        func article(_ id: String, _ title: String, source: String, hoursAgo: Double) -> FeedArticle {
            FeedArticle(
                storedID: id, title: title, link: fixtureRoot.appendingPathComponent("state/\(id)").absoluteString,
                guid: id, description: "Report \(id)", pubDate: now.addingTimeInterval(-hoursAgo * 3600), source: source
            )
        }
        let db = DatabaseEngine(path: path)
        try await db.open()
        try await db.upsertArticles([
            article("first", "Ferry sinks off Crete", source: "Wire One", hoursAgo: 5),
            article("second", "Ferry sinking near Crete: passengers rescued", source: "Daily Two", hoursAgo: 4),
            article("reprint", "Ferry sinks off Crete", source: "Herald Three", hoursAgo: 3),
            article("update", "Crete ferry: captain detained after sinking", source: "Wire One", hoursAgo: 1),
            article("merged", "Crete ferry owner faces inquiry", source: "Gazette Four", hoursAgo: 0.5),
        ])
        let event = try await db.createEvent(memberArticleIDs: ["first", "second"], at: now)
        func summary() async throws -> EventFeedSummary? {
            try await db.eventFeedSummaries(forArticles: ["first"]).first
        }
        let genericFeeds = [
            "https://www.euronews.com/2026/10/11/test-report", "https://www.france24.com/en/test-report",
        ]
        let genericStories = genericFeeds.enumerated().map { index, link in
            FeedArticle(
                storedID: "generic-\(index)", title: "Shared report \(index)", link: link,
                guid: "generic-\(index)", description: "Coverage", pubDate: now, source: "News")
        }
        try await db.upsertArticles(genericStories)
        _ = try await db.createEvent(memberArticleIDs: genericStories.map(\.id), at: now)
        let canonical = try await db.eventFeedSummaries(forArticles: genericStories.map(\.id)).first
        assertEqual(
            Set(canonical?.sources ?? []), Set(["Euronews", "France 24"]),
            "Generic feed names resolve to distinct catalog publishers")
        assertEqual(canonical?.coverageText, "2 stories · 2 publishers", "Coverage always exposes both counts")
        assertEqual(try await summary()?.seenVersion, nil, "An event starts unseen")
        assertFalse(try await summary()?.hasSubstantiveUpdate ?? true, "An unseen event is new, not updated")
        assertEqual(
            try await summary()?.members.map(\.articleID), ["second", "first"], "Members are listed newest first")
        assertEqual(try await db.markEventSeen(event.id), 1, "Opening records the current version")
        assertFalse(try await db.isRead(articleId: "first"), "Seeing an event marks no article read")
        try await db.addArticles(["reprint"], toEvent: event.id)
        assertFalse(
            try await summary()?.hasSubstantiveUpdate ?? true, "A reprint of a known headline is not new reporting")
        assertEqual(
            try await summary()?.coverageText, "3 stories · 3 publishers", "Coverage counts distinct publishers")
        try await db.addArticles(["update"], toEvent: event.id)
        assertEqual(try await db.markEventSeen(event.id, version: 2), 2, "Reading overview version 2 records version 2")
        assertTrue(
            try await summary()?.hasSubstantiveUpdate ?? false, "Version 2 does not cover reporting that joined later")
        try await db.markRead(articleId: "update", isRead: true)
        assertFalse(try await summary()?.hasSubstantiveUpdate ?? true, "Reading the new article settles the update")
        assertEqual(try await db.eventSeenVersion(event.id), 2, "Article state does not change event state")
        assertEqual(try await db.markEventSeen(event.id), 3, "Opening again records the latest version")
        assertEqual(try await db.markEventSeen(event.id, version: 1), 3, "Seen versions never go back")
        let other = try await db.createEvent(memberArticleIDs: ["merged"], at: now)
        try await db.mergeEvents(other.id, into: event.id)
        assertTrue(
            try await summary()?.hasSubstantiveUpdate ?? false, "Reporting merged in later is an update of the event")
        assertEqual(try await db.markEventSeen(other.id), 4, "The absorbed ID records state on the survivor")
        try await db.setSaved(articleId: "second", isSaved: true)
        assertEqual(
            try await summary()?.members.first { $0.articleID == "second" }?.isSaved, true,
            "Members carry their own saved state")
        await db.close()

        // v13 → v14 on a copy: cancellation rolls back; the upgrade keeps events.
        var handle: OpaquePointer?
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open v14 fixture")
        assertEqual(
            sqlite3_exec(
                handle,
                "DROP TRIGGER trg_articles_event_rematch; DROP TABLE event_state; DROP TABLE event_exclusions; DROP TABLE event_match_state; PRAGMA user_version = 13;",
                nil, nil, nil), SQLITE_OK, "Reconstruct a v13 library")
        sqlite3_close(handle)
        let copy = directory.appendingPathComponent("copy.sqlite3").path
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        func value(_ file: String, _ sql: String) -> String? {
            var connection: OpaquePointer?
            var statement: OpaquePointer?
            assertEqual(sqlite3_open(file, &connection), SQLITE_OK, "Inspect v14 fixture")
            defer { sqlite3_close(connection) }
            assertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK, "Prepare v14 inspection")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        let cancelledDB = DatabaseEngine(path: copy)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cancelledDB.open()
        }
        do {
            try await cancelled.value
            assertTrue(false, "Cancelled v14 migration must throw")
        } catch is CancellationError {}
        assertEqual(value(copy, "PRAGMA user_version;"), "13", "Cancelled v14 migration keeps version 13")
        assertEqual(
            value(
                copy,
                "SELECT count(*) FROM sqlite_master WHERE name IN ('event_match_state','event_exclusions','event_state');"
            ), "0", "Cancelled v14 migration rolls back its tables")
        let migrated = DatabaseEngine(path: copy)
        try await migrated.open()
        assertEqual(
            value(copy, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Copied v13 library upgrades to the current schema")
        assertEqual(value(path, "PRAGMA user_version;"), "13", "Original v13 fixture stays untouched")
        assertEqual(
            try await migrated.fetchEvent(id: event.id)?.memberArticleIDs.count, 5, "Migration keeps events and members"
        )
        assertTrue(try await migrated.isSaved(articleId: "second"), "Migration keeps saved state")
        assertEqual(
            value(
                copy,
                "SELECT count(*) FROM pragma_table_info('event_exclusions') WHERE name IN ('title','description','content');"
            ), "0", "Exclusions store no source text")
        assertEqual(value(copy, "PRAGMA quick_check;"), "ok", "Migrated library passes quick_check")
        await migrated.close()
    }

    static func testEventFeedSummaryUnit() {
        print("  - Testing EventFeedSummary extraction, display source, title key, dates, and update detection...")
        assertEqual(EventFeedSummary.displaySource(""), "", "Empty display source remains empty")
        assertEqual(
            EventFeedSummary.displaySource("   BBC News   \n   Section  "), "BBC News",
            "Trims whitespace and extracts first line")
        assertEqual(EventFeedSummary.displaySource("TechCrunch"), "TechCrunch", "Single line display source trimmed")

        assertEqual(EventFeedSummary.titleKey(""), "", "Empty titleKey is empty")
        assertEqual(
            EventFeedSummary.titleKey("Hello, World! 123..."), "hello world 123",
            "Strips punctuation/symbols and converts to lowercase")
        assertEqual(
            EventFeedSummary.titleKey("   Breaking:   News-Flash!  "), "breaking news flash",
            "Handles spaces and special characters")

        let now = Date()
        let member1 = EventFeedMember(
            articleID: "a1", source: "  Wire One \n Secondary ", title: "First Story", date: now, joinedVersion: 1,
            isRead: false, isSaved: false)
        let member2 = EventFeedMember(
            articleID: "a2", source: "WIRE ONE", title: "Second Story", date: now.addingTimeInterval(100),
            joinedVersion: 1, isRead: false, isSaved: false)
        let member3 = EventFeedMember(
            articleID: "a3", source: "Daily Two", title: "Third Story", date: now.addingTimeInterval(-100),
            joinedVersion: 2, isRead: false, isSaved: false)

        let summary1 = EventFeedSummary(eventID: "e1", membershipVersion: 1, seenVersion: nil, members: [member1])
        assertFalse(summary1.isConfirmed, "Single member event is not confirmed")
        assertEqual(summary1.sources, ["Wire One"], "Sources extracts formatted displaySource")

        let summaryMulti = EventFeedSummary(
            eventID: "e2", membershipVersion: 2, seenVersion: nil, members: [member1, member2, member3])
        assertTrue(summaryMulti.isConfirmed, "Multiple member event is confirmed")
        assertEqual(
            summaryMulti.sources, ["Wire One", "Daily Two"], "Deduplicates sources case-insensitively in order")

        assertEqual(
            EventFeedSummary(eventID: "e0", membershipVersion: 1, seenVersion: nil, members: []).latestDate, nil,
            "Empty members has nil latestDate")
        assertEqual(summaryMulti.latestDate, now.addingTimeInterval(100), "latestDate picks maximum date among members")

        assertEqual(
            EventFeedSummary(eventID: "e0", membershipVersion: 1, seenVersion: nil, members: []).coverageText,
            "0 stories · 0 publishers", "Empty members coverageText fallback")
        assertEqual(summary1.coverageText, "1 story · 1 publisher", "Single article from single source formatting")
        let summarySameSource = EventFeedSummary(
            eventID: "e3", membershipVersion: 1, seenVersion: nil, members: [member1, member2])
        assertEqual(
            summarySameSource.coverageText, "2 stories · 1 publisher",
            "Multiple articles from single source formatting")
        assertEqual(summaryMulti.coverageText, "3 stories · 2 publishers", "Multiple sources coverageText formatting")

        assertFalse(summaryMulti.hasSubstantiveUpdate, "Nil seenVersion returns false")

        let summarySeenCurrent = EventFeedSummary(
            eventID: "e4", membershipVersion: 2, seenVersion: 2, members: [member1, member2, member3])
        assertFalse(summarySeenCurrent.hasSubstantiveUpdate, "seenVersion equal to membershipVersion returns false")

        let member3Read = EventFeedMember(
            articleID: "a3", source: "Daily Two", title: "Third Story", date: now, joinedVersion: 2, isRead: true,
            isSaved: false)
        let summaryReadUpdate = EventFeedSummary(
            eventID: "e5", membershipVersion: 2, seenVersion: 1, members: [member1, member2, member3Read])
        assertFalse(summaryReadUpdate.hasSubstantiveUpdate, "Read new member does not trigger substantive update")

        let member3Reprint = EventFeedMember(
            articleID: "a3", source: "Daily Two", title: "First Story!", date: now, joinedVersion: 2, isRead: false,
            isSaved: false)
        let summaryReprint = EventFeedSummary(
            eventID: "e6", membershipVersion: 2, seenVersion: 1, members: [member1, member2, member3Reprint])
        assertFalse(
            summaryReprint.hasSubstantiveUpdate, "Unread new member repeating known title (reprint) returns false")

        let summarySubstantive = EventFeedSummary(
            eventID: "e7", membershipVersion: 2, seenVersion: 1, members: [member1, member2, member3])
        assertTrue(summarySubstantive.hasSubstantiveUpdate, "Unread new member with novel headline returns true")
    }

    static func testEventFeedGroupingAndStability() async {
        print("  - Testing event cards, publication mode, source filters and the stable feed buffer...")
        let now = Date()
        func article(_ id: String, source: String, minutesAgo: Double, title: String? = nil) -> FeedArticle {
            FeedArticle(
                storedID: id, title: title ?? "Story \(id)", link: "https://example.com/\(id)", guid: id,
                description: "", pubDate: now.addingTimeInterval(-minutesAgo * 60), source: source)
        }
        func member(_ article: FeedArticle, joined: Int = 1) -> EventFeedMember {
            EventFeedMember(
                articleID: article.id, source: article.source, title: article.title, date: article.pubDate,
                joinedVersion: joined, isRead: false, isSaved: false)
        }
        let a = article("a", source: "Wire One", minutesAgo: 1)
        let b = article("b", source: "Daily Two", minutesAgo: 2)
        let c = article("c", source: "Daily Two\nSection", minutesAgo: 3)
        let d = article("d", source: "Solo", minutesAgo: 4)
        let event = EventFeedSummary(
            eventID: "e1", membershipVersion: 1, seenVersion: nil, members: [member(a), member(c)])
        let single = EventFeedSummary(eventID: "e2", membershipVersion: 2, seenVersion: nil, members: [member(d)])
        let grouped = EventFeedGrouping.entries(for: [a, b, c, d], events: [event, single], mode: .events)
        assertEqual(grouped.map(\.id), ["a", "b", "d"], "A confirmed event is one card at its first listed member")
        if case .event(let summary, let representative, let visible) = grouped[0] {
            assertEqual(summary.eventID, "e1", "The card carries its event")
            assertEqual(representative.id, "a", "The first listed member represents the event")
            assertEqual(visible.map(\.id), ["a", "c"], "Every listed member stays available inside the event")
        } else {
            assertTrue(false, "The first entry is an event card")
        }
        assertEqual(
            EventFeedGrouping.entries(for: [a, b, c, d], events: [event, single], mode: .publications).map(\.id),
            ["a", "b", "c", "d"], "Publication mode lists every article")
        assertEqual(
            EventFeedGrouping.entries(for: [c, b], events: [event], mode: .events).first?.representative.id, "c",
            "A source filter keeps that source's own article on the card")
        assertEqual(
            EventFeedGrouping.entries(for: [a, a, b], events: [], mode: .events).map(\.id), ["a", "b"],
            "No article is listed twice")
        assertEqual(event.sources, ["Wire One", "Daily Two"], "Sources are distinct display names")
        assertEqual(single.coverageText, "1 story · 1 publisher", "Single-publisher coverage names the publisher")

        var buffer = FeedUpdateBuffer()
        assertEqual(
            FeedUpdateBuffer.debouncesReload(isPaging: false, isNewQuery: true, hasStories: false), false,
            "A section's first page is shown without the reload debounce")
        assertEqual(
            FeedUpdateBuffer.debouncesReload(isPaging: false, isNewQuery: false, hasStories: false), false,
            "An empty list fills at once at startup")
        assertEqual(
            FeedUpdateBuffer.debouncesReload(isPaging: false, isNewQuery: false, hasStories: true), true,
            "Revision bursts over a shown list are debounced")
        assertEqual(
            buffer.receive(FeedSnapshot(articles: [a, b]), holding: true, mode: .events), .replaced,
            "The first page always shows")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 7))!
        func dated(_ id: String, _ date: Date) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Story \(id)", link: "https://news.example/\(id)", guid: id, description: "",
                pubDate: date, source: "Wire One")
        }
        var cached = FeedUpdateBuffer()
        cached.replace(with: FeedSnapshot(articles: [dated("y", morning.addingTimeInterval(-10 * 3600))]))
        assertTrue(
            cached.showsOnlyEarlierDays(now: morning, calendar: calendar),
            "A list of only yesterday's stories is not today's reading")
        cached.replace(with: FeedSnapshot(articles: [dated("t", morning.addingTimeInterval(-3600))]))
        assertFalse(
            cached.showsOnlyEarlierDays(now: morning, calendar: calendar), "A story from today keeps the list held")
        assertFalse(
            FeedUpdateBuffer().showsOnlyEarlierDays(now: morning, calendar: calendar), "An empty list is not stale")
        let fresh = article("n", source: "Wire One", minutesAgo: 0)
        assertEqual(
            buffer.receive(FeedSnapshot(articles: [fresh, a, b]), holding: true, mode: .events), .waiting,
            "New stories wait while the list is read")
        assertEqual(buffer.displayed.articles.map(\.id), ["a", "b"], "Cards do not move under the reader")
        assertEqual(buffer.newEntryCount(.events), 1, "The indicator counts new cards")
        buffer.applyPending()
        assertEqual(buffer.displayed.articles.map(\.id), ["n", "a", "b"], "Applying shows the update")
        assertTrue(buffer.pending == nil, "Nothing waits after applying")
        let renamed = article("b", source: "Daily Two", minutesAgo: 2, title: "Story b, updated")
        assertEqual(
            buffer.receive(FeedSnapshot(articles: [fresh, renamed]), holding: true, mode: .events), .waiting,
            "Removals wait while the list is read")
        assertEqual(
            buffer.displayed.articles.map(\.id), ["n", "a", "b"],
            "A card read away in Unread stays until the reader updates")
        assertEqual(buffer.displayed.articles[2].title, "Story b, updated", "Listed content refreshes in place")
        assertEqual(buffer.newEntryCount(.events), 0, "An update without new cards is not counted as new")
        assertEqual(
            buffer.receive(FeedSnapshot(articles: [fresh, renamed]), holding: false, mode: .events), .replaced,
            "Updates apply when nobody is reading")

        buffer.replace(with: FeedSnapshot(articles: [a, b, c]))
        assertEqual(
            buffer.receive(FeedSnapshot(articles: [a, b, c], events: [event]), holding: true, mode: .events), .waiting,
            "Regrouping waits while the list is read")
        assertEqual(
            buffer.displayed.entries(.events).map(\.id), ["a", "b", "c"], "Grouping does not change under the reader")
        buffer.applyPending()
        let seen = EventFeedSummary(
            eventID: "e1", membershipVersion: 1, seenVersion: 1, members: [member(a), member(c)])
        assertEqual(
            buffer.receive(FeedSnapshot(articles: [a, b, c], events: [seen]), holding: true, mode: .events),
            .refreshedInPlace, "Event state that moves nothing applies at once")
        assertEqual(buffer.displayed.events.first?.seenVersion, 1, "The card shows the new event state")
        buffer.append([d], events: [seen, single])
        assertEqual(buffer.displayed.articles.map(\.id), ["a", "b", "c", "d"], "Further pages append in order")
        assertEqual(
            buffer.receive(
                FeedSnapshot(articles: [a, b], events: [seen]), holding: true, mode: .events, hasMore: true),
            .refreshedInPlace, "A same-order first page keeps further pages")
        assertEqual(buffer.displayed.articles.count, 4, "Loaded pages stay")
    }

    static func testEventFeedGroupingOptimization() {
        print("  - Testing FeedEntry array allocation avoidance logic for ID derivation...")
        let now = Date()
        func article(_ id: String, source: String, minutesAgo: Double, title: String? = nil) -> FeedArticle {
            FeedArticle(
                storedID: id, title: title ?? "Story \(id)", link: "https://example.com/\(id)", guid: id,
                description: "", pubDate: now.addingTimeInterval(-minutesAgo * 60), source: source)
        }
        func member(_ article: FeedArticle, joined: Int = 1) -> EventFeedMember {
            EventFeedMember(
                articleID: article.id, source: article.source, title: article.title, date: article.pubDate,
                joinedVersion: joined, isRead: false, isSaved: false)
        }

        let a = article("a", source: "Wire One", minutesAgo: 30)
        let b = article("b", source: "Daily Two", minutesAgo: 45)
        let c = article("c", source: "Solo", minutesAgo: 60)
        let d = article("d", source: "Another", minutesAgo: 70)
        let e = article("e", source: "Extra", minutesAgo: 80)

        // Confirmed event (2 members: a, b)
        let eventAB = EventFeedSummary(
            eventID: "e1", membershipVersion: 1, seenVersion: nil, members: [member(a), member(b)])
        // Unconfirmed event (1 member: e)
        let eventUnconfirmed = EventFeedSummary(
            eventID: "e2", membershipVersion: 1, seenVersion: nil, members: [member(e)])

        let articlesWithDupes = [a, a, b, c, c, d, e]
        let events = [eventAB, eventUnconfirmed]

        // 1. Verify entryIDs matches entries().map(\.id) in event mode with dupes and grouped members
        assertEqual(
            EventFeedGrouping.entryIDs(for: articlesWithDupes, events: events, mode: .events),
            EventFeedGrouping.entries(for: articlesWithDupes, events: events, mode: .events).map(\.id),
            "Optimized entryIDs matches entries().map(\\.id) for events"
        )

        // 2. Verify entryIDs matches entries().map(\.id) in non-event mode (publications)
        assertEqual(
            EventFeedGrouping.entryIDs(for: articlesWithDupes, events: events, mode: .publications),
            EventFeedGrouping.entries(for: articlesWithDupes, events: events, mode: .publications).map(\.id),
            "Optimized entryIDs matches entries().map(\\.id) for publications"
        )

        // 3. Reordered articles
        let articlesReordered = [d, c, b, a]
        assertEqual(
            EventFeedGrouping.entryIDs(for: articlesReordered, events: events, mode: .events),
            EventFeedGrouping.entries(for: articlesReordered, events: events, mode: .events).map(\.id),
            "Optimized entryIDs matches for reordered articles"
        )

        // 4. Newly grouped articles
        let eventCD = EventFeedSummary(
            eventID: "e3", membershipVersion: 1, seenVersion: nil, members: [member(c), member(d)])
        assertEqual(
            EventFeedGrouping.entryIDs(for: [a, b, c, d], events: [eventAB, eventCD], mode: .events),
            EventFeedGrouping.entries(for: [a, b, c, d], events: [eventAB, eventCD], mode: .events).map(\.id),
            "Optimized entryIDs matches for newly grouped articles"
        )

        // 5. Scaling and allocation behavior: 200, 1000, and 10000 items
        for count in [200, 1000, 10000] {
            var syntheticArticles: [FeedArticle] = []
            syntheticArticles.reserveCapacity(count)
            var syntheticMembers: [EventFeedMember] = []
            syntheticMembers.reserveCapacity(count / 2)

            for i in 0..<count {
                let id = "art_\(count)_\(i)"
                let art = article(id, source: "Source_\(i % 5)", minutesAgo: Double(i))
                syntheticArticles.append(art)
                if i % 2 == 0 {
                    syntheticMembers.append(member(art))
                }
            }

            let syntheticEvent = EventFeedSummary(
                eventID: "syn_event_\(count)",
                membershipVersion: 1,
                seenVersion: nil,
                members: syntheticMembers
            )

            assertEqual(
                EventFeedGrouping.entryIDs(for: syntheticArticles, events: [syntheticEvent], mode: .events),
                EventFeedGrouping.entries(for: syntheticArticles, events: [syntheticEvent], mode: .events).map(\.id),
                "Scaled entryIDs matches entries for \(count) items (.events mode)"
            )
            assertEqual(
                EventFeedGrouping.entryIDs(for: syntheticArticles, events: [syntheticEvent], mode: .publications),
                EventFeedGrouping.entries(for: syntheticArticles, events: [syntheticEvent], mode: .publications).map(
                    \.id),
                "Scaled entryIDs matches entries for \(count) items (.publications mode)"
            )
        }
    }

    @MainActor
    static func testRefreshClustersEvents(fixtureRoot: URL) async throws {
        print("  - Testing clustering after refresh, off the main actor and outside the refresh path...")
        let suite = testDefaultsSuite("test.refresh-events")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let feeds = ["https://8.8.8.8/one.xml", "https://8.8.4.4/two.xml"]
        settings.feedURLs = feeds
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let control = EventControlSet.articles(now: Date(), root: fixtureRoot).filter {
            $0.article.id.hasPrefix("quake")
        }.map(\.article)
        let batches = Dictionary(
            uniqueKeysWithValues: zip(feeds, [Array(control.prefix(2)), Array(control.dropFirst(2))]))
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, batches[$0], nil, nil) } },
            notifyBatch: { _, _ in })
        let revision = store.eventRevision
        await manager.fetchFeedsAsync()
        await manager.waitForEventClustering()
        let ids = manager.articles.map(\.id)
        assertEqual(ids.count, 3, "The refresh publishes every report")
        var events = Set<String?>()
        for id in ids { events.insert(try await db.eventID(forArticle: id)) }
        assertEqual(events.count, 1, "Reports collected by one refresh are grouped afterwards")
        assertTrue(events.first! != nil, "The grouped reports share an event")
        assertTrue(store.eventRevision != revision, "The feed is told to regroup")
        await manager.fetchFeedsAsync()
        await manager.waitForEventClustering()
        assertEqual(try await EventClusterer.run(in: db).processed, 0, "Refreshes leave nothing unmatched")
        manager.stopBackgroundWork()
    }

    /// #992: Check for Updates refreshes, waits for clustering and says whether reports joined the open story.
    @MainActor
    static func testStoryCheckForUpdates(fixtureRoot: URL) async throws {
        print("  - Testing Check for Updates on a story's overview: one report joins, then none (#992)...")
        final class Batches: @unchecked Sendable {
            private let lock = NSLock()
            private var results: [String: ([FeedArticle]?, FeedError?)] = [:]
            func set(_ url: String, _ articles: [FeedArticle]?, _ error: FeedError? = nil) {
                lock.lock()
                results[url] = (articles, error)
                lock.unlock()
            }
            func batch(_ urls: [String]) -> [FeedFetchResult] {
                lock.lock()
                defer { lock.unlock() }
                return urls.map { ($0, results[$0]?.0 ?? [], results[$0]?.1, nil) }
            }
        }
        let suite = testDefaultsSuite("test.story-check-for-updates")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let feeds = ["https://8.8.8.8/one.xml", "https://8.8.4.4/two.xml"]
        settings.feedURLs = feeds
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let control = EventControlSet.articles(now: Date(), root: fixtureRoot).filter {
            $0.article.id.hasPrefix("quake")
        }.map(\.article)
        assertEqual(control.count, 3, "The quake controls are three reports of one event")
        let batches = Batches()
        batches.set(feeds[0], Array(control.prefix(2)))
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in batches.batch(urls) }, notifyBatch: { _, _ in },
            dependencies: FeedManager.Dependencies(imageFinder: .unavailable, allowsBackgroundWork: { true }))
        defer { manager.stopBackgroundWork() }
        await manager.fetchFeedsAsync()
        await manager.waitForEventClustering()
        let open = control[0].id

        batches.set(feeds[1], Array(control.dropFirst(2)))
        let joined = await manager.checkForUpdates(storyOf: open)
        assertEqual(joined, .checked(newReports: 1, failedFeeds: 0, deferredMatching: false), "One report joins")
        assertEqual(joined.statusText, "1 new report joined this story", "The status line counts the new report")

        let unchanged = await manager.checkForUpdates(storyOf: open)
        assertEqual(unchanged.statusText, "No new reports from your sources", "A refresh that adds none says so")

        batches.set(feeds[1], nil, .httpStatus(503))
        let partial = await manager.checkForUpdates(storyOf: open)
        assertEqual(
            partial.statusText, "No new reports from your sources · 1 feed could not be checked",
            "A feed that failed is named, never hidden")
        assertEqual(
            FeedManager.StoryUpdateResult.checked(newReports: 0, failedFeeds: 0, deferredMatching: true).statusText,
            "No new reports yet. Some story matching waits while the Mac saves energy or cools down",
            "Deferred matching claims nothing and names no single cause")
        assertEqual(
            FeedManager.StoryUpdateResult.checked(newReports: 3, failedFeeds: 2, deferredMatching: true).statusText,
            "3 new reports joined this story · 2 feeds could not be checked", "Counts are plural")
        assertEqual(
            FeedManager.StoryUpdateResult.refused("The library is read-only.").statusText,
            "Refresh is off. The library is read-only.", "A refused refresh says why")
    }

    /// #737: the country signal does not join two reports that name different places below country level; a shared
    /// place word, or a side naming none, leaves the signal to its other rules. On by default, off only to measure.
    static func testStoryCountryPlaceVeto() {
        print("  - Testing the country signal's sub-national place veto (#737)...")
        func features(
            _ places: Set<String>, series: String? = nil, seriesTerms: Set<String> = [],
            seriesOnlyPlaces: Set<String> = []
        ) -> EventFeatures {
            var value = EventFeatures(language: "en", date: Date(timeIntervalSince1970: 1_790_000_000))
            value.places = places
            value.series = series
            value.seriesTerms = seriesTerms
            value.seriesOnlyPlaces = seriesOnlyPlaces
            return value
        }
        let lucknow = features(["@IN", "uttar pradesh", "lucknow"])
        let bengaluru = features(["@IN", "karnataka", "bengaluru"])
        let pradesh = features(["@IN", "pradesh"])
        let countryOnly = features(["@IN"])
        assertTrue(
            EventMatcher.namesDifferentLocalPlaces(lucknow, bengaluru), "Two states of one country are two stories")
        assertFalse(
            EventMatcher.namesDifferentLocalPlaces(lucknow, pradesh), "A shared place word keeps the signal")
        assertFalse(
            EventMatcher.namesDifferentLocalPlaces(lucknow, countryOnly),
            "A report naming only the country is not vetoed")
        assertFalse(
            EventMatcher.namesDifferentLocalPlaces(countryOnly, countryOnly), "Country-only reports are not vetoed")
        let seriesA = features(
            ["@IN", "lucknow", "delhi"], series: "Delhi Dispatch", seriesTerms: ["delhi", "dispatch"],
            seriesOnlyPlaces: ["delhi"])
        let seriesB = features(
            ["@IN", "bengaluru", "delhi"], series: "Delhi Dispatch", seriesTerms: ["delhi", "dispatch"],
            seriesOnlyPlaces: ["delhi"])
        let template = EventFeatures.sharedSeriesTerms(seriesA, seriesB, samePublisher: true) ?? []
        assertTrue(
            EventMatcher.namesDifferentLocalPlaces(
                seriesA.without(template).keepingStoryPlaces(of: seriesA),
                seriesB.without(template).keepingStoryPlaces(of: seriesB)),
            "Shared series terms are stripped so disjoint story places still veto")
        let seriesDelhi = features(
            ["@IN", "delhi"], series: "Delhi Dispatch", seriesTerms: ["delhi", "dispatch"],
            seriesOnlyPlaces: [])
        assertTrue(
            EventMatcher.namesDifferentLocalPlaces(
                seriesDelhi.without(template).keepingStoryPlaces(of: seriesDelhi),
                seriesB.without(template).keepingStoryPlaces(of: seriesB)),
            "A story naming the series place outside the prefix keeps it so disjoint places still veto")
        let extractedDelhi = EventFeatures(
            title: "Delhi: Severe air pollution returns to Delhi",
            description: "Air quality index crossed dangerous levels.",
            date: Date(timeIntervalSince1970: 1_790_000_000))
        assertEqual(
            extractedDelhi.seriesOnlyPlaces, [],
            "A place named in the series prefix and in the headline is not a series-only place")
        let extractedLucknow = EventFeatures(
            title: "Delhi: Voter turnout in Lucknow",
            description: "Polling opened early on Monday morning.",
            date: Date(timeIntervalSince1970: 1_790_000_000))
        assertTrue(
            extractedLucknow.seriesOnlyPlaces.contains("delhi"),
            "A place named only in the series prefix is recorded as a series-only place")
        assertTrue(EventMatchPolicy.standard.storyCountryPlaceVeto, "The veto is on whenever the signal is")
        assertTrue(EventMatchPolicy.standard.storyCountryKeywords == nil, "The country signal itself stays off")
    }

    /// The act class reads the headline's primary clause (#522): one cue → that act, two acts → unknown, a
    /// consequence only when no act is named. Phrases cover "steps down", "opens fire", "strikes down".
    static func testActClassTable() {
        print("  - Testing act classes of headlines (#522)...")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func act(_ title: String) -> ActClass {
            EventFeatures(title: title, description: "", date: date).actClass
        }
        assertEqual(act("Parliament votes to oust Prime Minister Novak in Ljubljana"), .vote, "A vote")
        assertEqual(act("Thousands protest in Ljubljana after parliament ousts Novak"), .protest, "The protest after")
        assertEqual(act("Commissioner steps down over failed Alabama execution"), .personnel, "Steps down, over …")
        assertEqual(act("Alabama corrections commissioner resigns after botched execution"), .personnel, "Resigns")
        assertEqual(act("Inmate survives botched execution in Alabama"), .casualties, "Survives: a consequence")
        assertEqual(act("Alabama inmate in critical condition after failed execution"), .casualties, "Critical cond.")
        assertEqual(act("Three dead after gunman opens fire at Westfield mall in Sydney"), .casualties, "Toll first")
        assertEqual(act("Sydney mall shooting: police name Westfield gunman"), .attack, "The shooting itself")
        assertEqual(act("Witnesses describe panic as gunman opened fire"), .attack, "Opened fire")
        assertEqual(act("Supreme Court strikes down state social media age law"), .ruling, "Strikes down")
        assertEqual(act("Supreme Court rules Texas age-verification law unconstitutional"), .ruling, "Unconstitut.")
        assertEqual(act("Iraq and Turkey sign oil pipeline supply agreement in Ankara"), .agreement, "An agreement")
        assertEqual(act("Drone attack sets fire to Kirkuk oil field a day after pipeline deal"), .attack, "Act first")
        assertEqual(act("Magnitude 6.1 earthquake strikes Malatya in eastern Turkey"), .disaster, "Strike is no cue")
        assertEqual(act("Rescuers search rubble after Malatya earthquake kills four"), .rescue, "Rescue after it")
        assertEqual(act("Trump says Fed chair should resign at Ohio rally"), .unknown, "Two acts named: unknown")
        assertEqual(act("Siemens to cut 5,000 jobs in energy division"), .unknown, "No cue: unknown")
        assertEqual(act("Hungarian novelist wins 2026 Nobel Prize in Literature"), .unknown, "No cue: unknown")
        assertEqual(act("Zelensky attacks Trump over peace plan"), .unknown, "A verbal attack is no attack")
        assertEqual(act("Israeli troops storm hospital in Gaza City"), .unknown, "Storm is no cue")
        assertEqual(act("Supreme Court dismisses former prime minister's appeal"), .unknown, "Dismiss is no cue")
        assertEqual(act("United States quits Paris climate accord"), .unknown, "Quit is no cue")
        assertEqual(act("Bayrou survives no-confidence motion"), .casualties, "Survives reads as a consequence …")
        assertFalse(ActClass.casualties.conflicts(with: .vote), "… which never vetoes a vote")
        assertFalse(ActClass.ruling.conflicts(with: .casualties), "… or a ruling (\"law survives challenge\")")
        assertTrue(ActClass.vote.conflicts(with: .protest), "Two acts conflict")
        assertFalse(ActClass.vote.conflicts(with: .unknown), "Unknown never conflicts")
        assertFalse(ActClass.disaster.conflicts(with: .rescue), "A rescue follows a disaster")
        assertFalse(ActClass.attack.conflicts(with: .crash), "A deliberate crash is an attack")
        assertFalse(ActClass.crash.conflicts(with: .attack), "… in either order")
        assertFalse(ActClass.casualties.conflicts(with: .rescue), "Two consequence reports agree")
        assertTrue(ActClass.casualties.conflicts(with: .personnel), "A resignation leaves no casualties")
        assertTrue(ActClass.personnel.conflicts(with: .casualties), "… in either order")
    }

    /// Stored matcher signals (#522): version-gated, JSON round trip, dropped with the embedding and pair decisions
    /// when the title changes, gone with the article, cleared with AI analysis while pair decisions stay.
    static func testArticleSignalsRoundTrip() async throws {
        print("  - Testing stored article signals and pair decisions (#522)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func story(_ id: Int, _ title: String) -> FeedArticle {
            FeedArticle(
                title: title, link: "https://signals.invalid/\(id)", guid: "signals-\(id)", description: "",
                pubDate: date, source: "Publisher")
        }
        let first = story(1, "Parliament votes to oust Prime Minister Novak in Ljubljana")
        let second = story(2, "Thousands protest in Ljubljana after parliament ousts Novak")
        try await db.upsertArticles([first, second])
        let ids = [try await db.resolvedArticleID(for: first), try await db.resolvedArticleID(for: second)]
        let features = [
            ids[0]: EventFeatures(title: first.title, description: "", date: date),
            ids[1]: EventFeatures(title: second.title, description: "", date: date),
        ]
        try await db.upsertArticleFeatures(features, version: EventFeatures.storageVersion)
        let fetched = try await db.fetchArticleFeatures(articleIDs: ids, version: EventFeatures.storageVersion)
        assertEqual(fetched, features, "Signals round-trip through JSON unchanged")
        assertEqual(
            try await db.fetchArticleFeatures(articleIDs: ids, version: EventFeatures.storageVersion + 1).count, 0,
            "Another storage version reads nothing")
        try await db.upsertArticleEmbeddings([ids[0]: Array(repeating: 0.05, count: 384)], modelVersion: 1)
        let pair = DatabaseEngine.PairDecision(
            articleID: ids[0], otherArticleID: ids[1], decision: "related-act", reason: "differentAct", score: 0.4)
        try await db.upsertPairDecisions([pair], matcherVersion: EventMatcher.version)
        func count(_ table: String) async throws -> String? {
            try await db.eventRows("SELECT count(*) FROM \(table);").first?[0]
        }
        assertEqual(try await count("pair_assessments"), "1", "The decision is stored once per pair")
        let reversed = DatabaseEngine.PairDecision(
            articleID: ids[1], otherArticleID: ids[0], decision: "match", reason: "match", score: 1)
        try await db.upsertPairDecisions([reversed], matcherVersion: EventMatcher.version)
        assertEqual(try await count("pair_assessments"), "1", "A pair given high ID first is not stored twice")

        // A changed title drops the signals, the embedding and the pair decisions with the match state.
        try await db.upsertArticles([story(1, "Parliament in Ljubljana ousts Prime Minister Novak in late-night vote")])
        assertEqual(
            try await db.fetchArticleFeatures(articleIDs: ids, version: EventFeatures.storageVersion).count, 1,
            "The retitled story's signals are dropped; the other's stay")
        assertEqual(
            try await db.fetchArticleEmbeddings(articleIDs: ids, modelVersion: 1).count, 0, "Its embedding too")
        assertEqual(try await count("pair_assessments"), "0", "And its pair decisions")
        // A pass that read the old headline stores nothing computed from it once a refresh has replaced it.
        try await db.storeClusteringPass(
            DatabaseEngine.ClusteringPassWrites(
                features: features, embeddings: [ids[0]: Array(repeating: 0.05, count: 384)], decisions: [pair],
                readTexts: [ids[0]: first.title + "\n", ids[1]: second.title + "\n"]))
        assertEqual(
            try await db.fetchArticleFeatures(articleIDs: ids, version: EventFeatures.storageVersion).keys.sorted(),
            [ids[1]], "Only the unchanged story's signals are stored")
        assertEqual(
            try await db.fetchArticleEmbeddings(articleIDs: ids, modelVersion: SentenceEmbedder.modelVersion).count, 0,
            "No vector of the old headline")
        assertEqual(try await count("pair_assessments"), "0", "No decision about it either")
        try await db.upsertPairDecisions([pair], matcherVersion: EventMatcher.version)
        try await db.storeClusteringPass(
            DatabaseEngine.ClusteringPassWrites(cleared: [(pair.articleID, pair.otherArticleID)]))
        assertEqual(try await count("pair_assessments"), "0", "A pair that no longer qualifies loses its row")

        try await db.upsertArticleFeatures(features, version: EventFeatures.storageVersion)
        try await db.upsertPairDecisions([pair], matcherVersion: EventMatcher.version)
        try await db.clearArticleEnrichment()
        assertEqual(try await count("article_features"), "0", "Clearing AI analysis clears stored signals")
        assertEqual(try await count("pair_assessments"), "1", "Pair decisions carry no text and stay")
        try await db.eventRows("DELETE FROM articles WHERE id = ?;", [.text(ids[1])])
        assertEqual(try await count("pair_assessments"), "0", "A deleted story takes its pair decisions along")
        await db.close()
    }

    /// The clusterer keeps a vote and the protest after it apart as two events and records the pair as a related act,
    /// which the earlier event's overview can list (#522).
    static func testPairAssessmentsRecorded() async throws {
        print("  - Testing related-act decisions recorded by the clusterer (#522)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func story(_ id: Int, _ title: String, hours: Double) -> FeedArticle {
            FeedArticle(
                title: title, link: "https://acts.invalid/\(id)", guid: "acts-\(id)", description: "",
                pubDate: start.addingTimeInterval(hours * 3600), source: "Publisher \(id)")
        }
        let stories = [
            story(1, "Parliament votes to oust Prime Minister Novak in Ljubljana", hours: 0),
            story(2, "Parliament in Ljubljana votes to oust Prime Minister Novak", hours: 1),
            story(3, "Thousands protest in Ljubljana after parliament votes to oust Novak", hours: 5),
            story(4, "Thousands protest in Ljubljana streets after parliament votes to oust Novak", hours: 6),
        ]
        try await db.upsertArticles(stories)
        let report = try await EventClusterer.run(in: db, now: start.addingTimeInterval(7 * 3600))
        assertEqual(report.created, 2, "The vote and the protest form two events")
        var events: [String: String] = [:]
        for article in stories {
            let id = try await db.resolvedArticleID(for: article)
            events[article.guid ?? ""] = try await db.eventID(forArticle: id)
        }
        assertTrue(events["acts-1"] != nil && events["acts-1"] == events["acts-2"], "Both vote reports share an event")
        assertTrue(events["acts-3"] != nil && events["acts-3"] == events["acts-4"], "Both protest reports share one")
        assertTrue(events["acts-1"] != events["acts-3"], "The vote and the protest are different events")
        let relatedRows = try await db.eventRows(
            "SELECT count(*) FROM pair_assessments WHERE decision = 'related-act';")
        let related = relatedRows.first?[0]
        assertTrue((related.flatMap(Int.init) ?? 0) >= 1, "A vote/protest pair is recorded as a related act")
        let matchRows = try await db.eventRows("SELECT count(*) FROM pair_assessments WHERE decision = 'match';")
        let matches = matchRows.first?[0]
        assertTrue((matches.flatMap(Int.init) ?? 0) >= 2, "The matching pairs inside each event are recorded")
        if let protestEvent = events["acts-3"], let voteEvent = events["acts-1"] {
            let links = try await db.relatedActEvents(eventID: protestEvent)
            assertEqual(links.map(\.eventID), [voteEvent], "The protest's overview can list the vote as a related act")
            assertEqual(links.first?.title, stories[0].title, "… by its earliest report")
        }
        var resolved: [String] = []
        for article in stories { resolved.append(try await db.resolvedArticleID(for: article)) }
        assertEqual(
            try await db.fetchArticleFeatures(articleIDs: resolved, version: EventFeatures.storageVersion).count, 4,
            "The pass stored every story's signals")

        // Every decision carries what it rested on (#551), and a vetoed pair with shared evidence is kept.
        let featureRows = try await db.eventRows(
            "SELECT decision, features FROM pair_assessments WHERE features IS NOT NULL;")
        assertTrue(featureRows.count >= 3, "Match and related-act rows store their features")
        let decoded = featureRows.compactMap { row in
            row[1].flatMap { try? JSONDecoder().decode(EventPairFeatures.self, from: Data($0.utf8)) }
        }
        assertEqual(decoded.count, featureRows.count, "The features JSON decodes for every row")
        assertTrue(
            decoded.contains { $0.conflict == EventConflict.differentAct.rawValue && $0.sharedSpecific >= 1 },
            "A related act records its conflict and shared evidence")
        let vetoedDB = DatabaseEngine(path: ":memory:")
        try await vetoedDB.open()
        try await vetoedDB.upsertArticles([
            story(5, "Drone strike hits market in Kharkiv, Ukraine", hours: 0),
            story(6, "Drone strike hits market in Idlib, Syria", hours: 1),
        ])
        _ = try await EventClusterer.run(in: vetoedDB, now: start.addingTimeInterval(2 * 3600))
        let vetoedRows = try await vetoedDB.eventRows(
            "SELECT reason, features FROM pair_assessments WHERE decision = 'vetoed';")
        assertEqual(vetoedRows.count, 1, "A vetoed pair that shares words is recorded once")
        assertEqual(vetoedRows.first?[0], EventConflict.places.rawValue, "… with its conflict as the reason")
        assertTrue(
            vetoedRows.first?[1].flatMap({ try? JSONDecoder().decode(EventPairFeatures.self, from: Data($0.utf8)) })?
                .sharedKeywords ?? 0 >= 2, "… and the shared evidence that made it worth reviewing")
        await vetoedDB.close()

        // The review export writes one row per stored pair with both headlines and the corrections (#551).
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("library.sqlite3").path
        try await db.eventRows("VACUUM INTO ?;", [.text(copy)])
        await db.close()
        let stored = try await { () async throws -> Int in
            let count = DatabaseEngine(path: copy)
            try await count.open()
            let rows = try await count.eventRows("SELECT count(*) FROM pair_assessments;")
            await count.close()
            return rows.first?[0].flatMap(Int.init) ?? -1
        }()
        let exported = try await exportPairReview(snapshot: copy, outputDirectory: directory.path)
        assertEqual(exported, stored, "The export has one row per stored pair")
        let csv = try String(contentsOf: directory.appendingPathComponent("pairs-review.csv"), encoding: .utf8)
        let lines = csv.split(separator: "\n")
        assertEqual(lines.count, exported + 1, "A header and one line per pair")
        assertTrue(lines.first?.hasPrefix("article_id,other_article_id,decision") == true, "Columns are named")
        assertTrue(
            lines.dropFirst().contains { $0.contains("Parliament votes to oust Prime Minister Novak in Ljubljana") },
            "Rows carry the headlines")
        var refused = false
        do {
            _ = try await exportPairReview(
                snapshot: "/Users/x/Library/Containers/app/news.sqlite3", outputDirectory: directory.path)
        } catch {
            refused = true
        }
        assertTrue(refused, "The live library is refused")
        let container = directory.appendingPathComponent("Library/Containers/app")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let live = container.appendingPathComponent("news.sqlite3")
        try Data().write(to: live)
        let link = directory.appendingPathComponent("link.sqlite3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: live)
        assertTrue(StoryCorpus.isLiveLibrary(link.path), "A symlink to the live library is the live library")
        assertTrue(!StoryCorpus.isLiveLibrary(directory.appendingPathComponent("copy.sqlite3").path), "A copy is not")
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linked = directory.appendingPathComponent("Library/Containers/linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        assertTrue(
            StoryCorpus.isLiveLibrary(linked.appendingPathComponent("news.sqlite3").path),
            "A container path that links elsewhere is still the live library")
        var linkRefused = false
        do {
            _ = try await exportPairReview(snapshot: link.path, outputDirectory: directory.path)
        } catch StoryCorpus.Failure.invalid(let message) {
            linkRefused = message.contains("never the live file")
        }
        assertTrue(linkRefused, "The export refuses a symlink to the live library")
    }

    /// Reader verdicts (#552): "Same Event" and "Not the Same Event" pairs leave the library as weight-5 training rows
    /// ahead of the mined ones, and the holdout harness fails when a re-clustering violates one.
    static func testReaderVerdictsExportAndGate() async throws {
        print("  - Testing reader verdicts as training rows and as the gate (#552)...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let db = DatabaseEngine(path: path)
        try await db.open()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func story(_ id: Int, _ title: String, hours: Double) -> FeedArticle {
            FeedArticle(
                title: title, link: "https://verdict.invalid/\(id)", guid: "verdict-\(id)",
                description: "A report on the Ljubljana parliament and its prime minister.",
                pubDate: start.addingTimeInterval(hours * 3600), source: "Publisher \(id)")
        }
        let stories = [
            story(1, "Parliament votes to oust Prime Minister Novak in Ljubljana", hours: 0),
            story(2, "Parliament in Ljubljana votes to oust Prime Minister Novak", hours: 1),
            story(3, "Thousands protest in Ljubljana after parliament votes to oust Novak", hours: 5),
        ]
        try await db.upsertArticles(stories)
        let now = start.addingTimeInterval(7 * 3600)
        _ = try await EventClusterer.run(in: db, now: now)
        var ids: [String] = []
        for article in stories { ids.append(try await db.resolvedArticleID(for: article)) }
        guard let vote = try await db.eventID(forArticle: ids[0]), vote == (try await db.eventID(forArticle: ids[1]))
        else {
            assertTrue(false, "The two vote reports form an event")
            return
        }
        // "Not the Same Event" between the two vote reports, "Same Event" between a vote report and the protest.
        try await db.separateArticle(ids[1], fromEvent: vote)
        if let protest = try await db.eventID(forArticle: ids[2]) {
            try await db.includeEvent(protest, inEvent: vote)
        } else {
            let pair = ids[0] < ids[2] ? (ids[0], ids[2]) : (ids[2], ids[0])
            try await db.eventRows(
                "INSERT INTO event_inclusions(article_id, other_article_id, created_at) VALUES (?, ?, ?);",
                [.text(pair.0), .text(pair.1), .real(now.timeIntervalSince1970)])
        }
        // The protest report joins the vote's story alone (#581), so the separation also excludes it: count the pairs.
        let verdicts =
            try await db.eventRows(
                "SELECT (SELECT count(*) FROM event_exclusions) + (SELECT count(*) FROM event_inclusions);"
            ).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
        assertTrue(verdicts >= 2, "Both corrections are recorded")
        let protestVerdicts =
            try await db.eventRows(
                """
                SELECT (SELECT count(*) FROM event_exclusions WHERE ? IN (article_id, other_article_id))
                    + (SELECT count(*) FROM event_inclusions WHERE ? IN (article_id, other_article_id));
                """, [.text(ids[2]), .text(ids[2])]
            ).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
        await db.close()
        let corpus = directory.appendingPathComponent("corpus.json")
        try Data(#"{"articles":[{"title":"Unrelated corpus item","published":"2010-01-01T00:00:00Z"}]}"#.utf8)
            .write(to: corpus)
        try await exportTrainingPairs(
            snapshots: path, output: directory.path, corpusPath: corpus.path, verdictsOnly: true)
        let csv = try String(contentsOf: directory.appendingPathComponent("verdicts.csv"), encoding: .utf8)
        // Texts carry newlines, so the rows are checked by their markers rather than split by line.
        assertTrue(
            csv.hasPrefix("label,group,text_a,text_b,pieces_a,pieces_b,weight,marginal\n"),
            "The export has weight and marginal columns (#627)")
        assertEqual(csv.components(separatedBy: ",\"v:").count - 1, verdicts, "One row per verdict")
        assertEqual(csv.components(separatedBy: ",5,").count - 1, verdicts, "Verdict rows weigh five")
        assertTrue(
            csv.contains("\n0,\"v:") && csv.contains("\n2,\"v:") && csv.contains(",5,01"),
            "An exclusion is not one occurrence (0, marginal 01), an inclusion is same (2)")
        // A library-holdout article (#579) never leaves as a training row, verdicts included.
        let otherPath = directory.appendingPathComponent("other.sqlite3").path
        let otherDB = DatabaseEngine(path: otherPath)
        try await otherDB.open()
        let other = story(4, "Astronomers discover a distant galaxy", hours: 2)
        try await otherDB.upsertArticles([other])
        let otherID = try await otherDB.resolvedArticleID(for: other)
        await otherDB.close()
        let heldOut = directory.appendingPathComponent("holdout-protest.json")
        try JSONSerialization.data(withJSONObject: [["a": ids[2], "b": otherID, "label": "different"]])
            .write(to: heldOut)
        let held = directory.appendingPathComponent("held")
        try FileManager.default.createDirectory(
            at: held, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try await exportTrainingPairs(
                snapshots: path, output: held.path, corpusPath: corpus.path, holdoutPath: heldOut.path,
                verdictsOnly: true)
            assertTrue(false, "An unresolved holdout ID must fail the export")
        } catch StoryCorpus.Failure.invalid(let message) {
            assertTrue(message.contains("do not resolve 1 library holdout IDs"), "Missing holdout IDs are reported")
        }
        assertFalse(
            FileManager.default.fileExists(atPath: held.appendingPathComponent("verdicts.csv").path),
            "An incomplete holdout title set never writes training rows")
        try await exportTrainingPairs(
            snapshots: path + ":" + otherPath, output: held.path, corpusPath: corpus.path, holdoutPath: heldOut.path,
            verdictsOnly: true)
        let heldCSV = try String(contentsOf: held.appendingPathComponent("verdicts.csv"), encoding: .utf8)
        assertEqual(
            heldCSV.components(separatedBy: ",\"v:").count - 1, verdicts - protestVerdicts,
            "The holdout article's verdicts are left out")
        // The gate: re-clustering the copy without corrections re-merges the excluded vote pair, so the harness fails.
        let holdout = directory.appendingPathComponent("holdout.json")
        try Data("[]".utf8).write(to: holdout)
        var failure = ""
        do {
            try await evaluateLibraryHoldout(snapshot: path, holdout: holdout.path)
        } catch {
            failure = "\(error)"
        }
        assertTrue(
            failure.contains("reader verdicts violated"), "A violated verdict fails the library holdout run: \(failure)"
        )
    }

    /// #791: with a reader's exclusion between two events that each agree with a third, which pair forms a story must
    /// not depend on dictionary or input order: every insertion order and every run of the pass gives the same stories.
    static func testStoryPassOrderIndependent() async throws {
        print("  - Testing the story pass is independent of iteration and input order (#791)...")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func story(_ id: Int, _ title: String, hours: Double) -> FeedArticle {
            FeedArticle(
                title: title, link: "https://order.invalid/\(id)", guid: "order-\(id)", description: "",
                pubDate: start.addingTimeInterval(hours * 3600), source: "Publisher \(id)")
        }
        let stories = [
            story(1, "Parliament votes to oust Prime Minister Novak in Ljubljana", hours: 0),
            story(2, "Parliament in Ljubljana votes to oust Prime Minister Novak", hours: 1),
            story(3, "Novak's party appoints interim leader in Ljubljana after parliament ousts him", hours: 3),
            story(4, "Novak's party names interim leader in Ljubljana after parliament ousts him", hours: 3.5),
            story(5, "Thousands protest in Ljubljana after parliament votes to oust Novak", hours: 5),
            story(6, "Thousands protest in Ljubljana streets after parliament votes to oust Novak", hours: 6),
        ]
        let now = start.addingTimeInterval(7 * 3600)
        var generator = SystemRandomNumberGenerator()
        var groupings = Set<[[Int]]>()
        for _ in 0..<8 {
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            try await db.upsertArticles(stories.shuffled(using: &generator))
            _ = try await EventClusterer.run(in: db, now: now)
            var ids: [String] = []
            for article in stories { ids.append(try await db.resolvedArticleID(for: article)) }
            // The reader excluded an appointment report against a protest report.
            let (low, high) = ids[2] < ids[4] ? (ids[2], ids[4]) : (ids[4], ids[2])
            try await db.eventRows(
                "INSERT INTO event_exclusions(article_id, other_article_id, created_at) VALUES (?, ?, ?);",
                [.text(low), .text(high), .real(now.addingTimeInterval(100).timeIntervalSince1970)])
            _ = try await EventClusterer.run(in: db, now: now.addingTimeInterval(120))
            var storyOf: [String] = []
            for id in ids {
                if let event = try await db.eventID(forArticle: id) {
                    storyOf.append(try await db.storyID(forEvent: event) ?? event)
                } else {
                    storyOf.append(id)
                }
            }
            let groups = Dictionary(grouping: storyOf.indices, by: { storyOf[$0] }).values.map { $0.sorted() }
            groupings.insert(groups.sorted { $0.first ?? 0 < $1.first ?? 0 })
            await db.close()
        }
        assertEqual(groupings.count, 1, "Every input order gives the same stories: \(groupings)")
        assertEqual(
            groupings.first, [[0, 1, 2, 3], [4, 5]],
            "The vote joins the appointment, whose first report came first; the excluded protest stays apart")
    }

    /// The story layer (#581): two events of one story (a vote and the protest after it) become one card, versions and
    /// seen state add up across the story, "Not the Same Event" through the story works on the article's own event,
    /// and an exclusion across the two events keeps them apart.
    static func testStoryLayer() async throws {
        print("  - Testing the story layer: one card per story across related acts (#581)...")
        var components = EventClusterer.StoryComponents()
        components.join("a", "b")
        components.join("c", "d")
        assertEqual(Set(components.component(of: "b")), ["a", "b"], "A component holds every event joined with it")
        assertEqual(components.component(of: "z"), ["z"], "An event in no component is its own")
        components.join("b", "c")
        assertEqual(Set(components.component(of: "a")), ["a", "b", "c", "d"], "Joins are transitive")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func story(_ id: Int, _ title: String, hours: Double) -> FeedArticle {
            FeedArticle(
                title: title, link: "https://story.invalid/\(id)", guid: "story-\(id)", description: "",
                pubDate: start.addingTimeInterval(hours * 3600), source: "Publisher \(id)")
        }
        let stories = [
            story(1, "Parliament votes to oust Prime Minister Novak in Ljubljana", hours: 0),
            story(2, "Parliament in Ljubljana votes to oust Prime Minister Novak", hours: 1),
            story(3, "Thousands protest in Ljubljana after parliament votes to oust Novak", hours: 5),
            story(4, "Thousands protest in Ljubljana streets after parliament votes to oust Novak", hours: 6),
        ]
        try await db.upsertArticles(stories)
        let now = start.addingTimeInterval(7 * 3600)
        let report = try await EventClusterer.run(in: db, now: now)
        var ids: [String] = []
        for article in stories { ids.append(try await db.resolvedArticleID(for: article)) }
        guard let vote = try await db.eventID(forArticle: ids[0]),
            let protest = try await db.eventID(forArticle: ids[2]),
            vote != protest
        else {
            assertTrue(false, "The vote and the protest are two events")
            return
        }
        let storyID = try await db.storyID(forEvent: vote)
        assertEqual(storyID, try await db.storyID(forEvent: protest), "Two acts of one story share a story")
        assertEqual(storyID, vote, "The story is named by its earliest event")
        assertTrue(
            report.changedEvents.contains(vote) && report.changedEvents.contains(protest), "Story changes are reported")
        assertEqual(try await db.storyEventIDs(storyID ?? "").sorted(), [vote, protest].sorted(), "Both events belong")
        assertEqual(try await db.storyEventIDs(protest).sorted(), [vote, protest].sorted(), "… from either event")
        assertEqual(
            try await db.storyIDs(forEvents: [vote, protest]), [protest: vote],
            "Notifications map a later event to its story; the story's own event is absent (#740)")
        var summaries = try await db.eventFeedSummaries(forArticles: [ids[0]])
        assertEqual(summaries.count, 1, "One card for the story")
        assertEqual(summaries.first?.eventID, protest, "The card opens the story's newest event")
        assertEqual(
            try await db.relatedActEvents(eventID: protest, limit: .max).map(\.eventID), [vote],
            "The newest event's overview reaches the story's earlier event")
        // "Earlier in This Story" (#671): the story's own earlier events come first and are never capped away by other
        // links; other links fill up to the cap.
        let store = await ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        assertEqual(
            try await store.relatedStoryEvents(eventID: protest).map(\.eventID), [vote],
            "The overview lists the story's earlier event")
        func link(_ id: String) -> RelatedStoryEvent {
            RelatedStoryEvent(eventID: id, articleID: "a-\(id)", title: id, firstPublishedAt: now)
        }
        assertEqual(
            ArticleStore.earlierLinks(
                story: ["s1", "s2"].map { link($0) }, others: ["l1", "l2", "l3", "s1", "l4"].map { link($0) }
            ).map(\.eventID), ["s1", "s2", "l1", "l2", "l3"],
            "Every story event first, then at most three other links, no duplicates")
        assertEqual(summaries.first?.members.count, 4, "All four reports are on the card")
        assertEqual(summaries.first?.membershipVersion, 2, "The story version is the sum of its events' versions")
        assertEqual(summaries.first?.seenVersion, nil, "Never opened")
        assertEqual(try await db.markEventSeen(protest), 2, "Seeing the story through its open event marks every event")
        summaries = try await db.eventFeedSummaries(forArticles: [ids[0]])
        assertEqual(summaries.first?.seenVersion, 2, "Seen versions add up")
        assertFalse(summaries.first?.hasSubstantiveUpdate ?? true, "Nothing new since the reader looked")
        try await db.upsertArticles([
            story(5, "Thousands protest in central Ljubljana after parliament votes to oust Novak", hours: 6.5)
        ])
        _ = try await EventClusterer.run(in: db, now: now.addingTimeInterval(60))
        summaries = try await db.eventFeedSummaries(forArticles: [ids[0]])
        assertEqual(summaries.first?.members.count, 5, "The late protest report joins the story")
        assertTrue(summaries.first?.hasSubstantiveUpdate ?? false, "A report that joined after the look is an update")
        // "Not the Same Event" through the story: the protest report leaves its own event, not the lead's.
        let separated = try await db.separateArticle(ids[2], fromEvent: storyID ?? "")
        assertEqual(separated.id, protest, "The article leaves the event that held it")
        assertEqual(try await db.eventID(forArticle: ids[2]), nil, "It is in no event afterwards")
        let exclusions = try await db.eventExclusions(of: ids[2])
        assertTrue(
            exclusions.isSuperset(of: [ids[0], ids[1], ids[3]]), "It is excluded from every member of the story")
        // An exclusion across the two events keeps them apart as stories.
        let apart = DatabaseEngine(path: ":memory:")
        try await apart.open()
        try await apart.upsertArticles(stories)
        _ = try await EventClusterer.run(in: apart, now: now)
        var apartIDs: [String] = []
        for article in stories { apartIDs.append(try await apart.resolvedArticleID(for: article)) }
        guard let voteApart = try await apart.eventID(forArticle: apartIDs[0]),
            let protestApart = try await apart.eventID(forArticle: apartIDs[2])
        else {
            assertTrue(false, "The vote and the protest are two events in the exclusion fixture")
            await apart.close()
            await db.close()
            return
        }
        assertEqual(
            try await apart.storyID(forEvent: voteApart), try await apart.storyID(forEvent: protestApart),
            "Linked before the exclusion")
        // The expanded story card reads every event of the story, not only the lead's reports.
        var storyReports = 0
        if let lead = try await apart.storyID(forEvent: voteApart) {
            for id in try await apart.storyEventIDs(lead) {
                storyReports += try await apart.fetchArticles(limit: nil, options: ArticleFetchOptions(eventID: id))
                    .count
            }
        }
        assertEqual(
            try await apart.fetchArticles(
                limit: nil, options: ArticleFetchOptions(eventID: voteApart, wholeStory: true)
            ).count, storyReports,
            "A story's reports are its events' reports")
        assertTrue(
            try await apart.fetchArticles(limit: nil, options: ArticleFetchOptions(eventID: voteApart)).count
                < storyReports,
            "One event of the story holds fewer reports than the story")
        // A low-energy pass can finish every report while leaving only the story work pending.
        let lastStoryPass = await apart.lastStoryPass
        try await apart.upsertArticles([story(9, "Astronomers discover a distant galaxy", hours: 6)])
        let withoutEnergy = try await EventClusterer.run(
            in: apart, now: now.addingTimeInterval(30), allowsEnergy: false)
        assertEqual(withoutEnergy.processed, 1, "Low energy finishes the unrelated report")
        assertEqual(withoutEnergy.deferred, 0, "No report is deferred in the story-only retry fixture")
        assertTrue(await apart.storyPassPending, "Skipped story work remains pending")
        let idleWithoutEnergy = try await EventClusterer.run(
            in: apart, now: now.addingTimeInterval(40), allowsEnergy: false)
        assertEqual(idleWithoutEnergy.processed, 0, "The next pass has no reports to process")
        assertEqual(await apart.lastStoryPass, lastStoryPass, "Low energy leaves the last completed story pass intact")
        let resumedAt = now.addingTimeInterval(60)
        let resumed = try await EventClusterer.run(in: apart, now: resumedAt, allowsEnergy: true)
        assertEqual(resumed.processed, 0, "Story work resumes with no pending reports")
        assertEqual(await apart.lastStoryPass, resumedAt, "The pending story pass completes when energy returns")
        assertFalse(await apart.storyPassPending, "Completed story work clears the pending marker")
        _ = try await EventClusterer.run(in: apart, now: now.addingTimeInterval(90), allowsEnergy: true)
        assertEqual(await apart.lastStoryPass, resumedAt, "An unchanged library does not repeat completed story work")
        // A reader's exclusion between one vote report and one protest report, both staying in their events. It is
        // recorded after the last completed story pass, as a verdict in the app is, so the next pass re-checks stories.
        let (low, high) = apartIDs[0] < apartIDs[2] ? (apartIDs[0], apartIDs[2]) : (apartIDs[2], apartIDs[0])
        try await apart.eventRows(
            "INSERT INTO event_exclusions(article_id, other_article_id, created_at) VALUES (?, ?, ?);",
            [.text(low), .text(high), .real(now.addingTimeInterval(100).timeIntervalSince1970)])
        _ = try await EventClusterer.run(in: apart, now: now.addingTimeInterval(120))
        assertTrue(
            try await apart.storyID(forEvent: voteApart) != (try await apart.storyID(forEvent: protestApart)),
            "An exclusion across the events vetoes the story link")
        // A story id naming an event that pruning removed is cleared with it.
        try await apart.eventRows("UPDATE events SET story_id = 'pruned-lead' WHERE id = ?;", [.text(protestApart)])
        try await apart.pruneEmptyEvents()
        assertEqual(
            try await apart.eventRows("SELECT story_id FROM events WHERE id = ?;", [.text(protestApart)]).first?[0],
            nil, "A dangling story id is cleared when its lead event is gone")
        await apart.close()
        assertTrue(
            EventClusterer.headline("Elon Musk’s dangerous grip on outer space", names: "musk"),
            "A name in a headline is found across case and possessives")
        assertTrue(EventClusterer.headline("iOS 27.2: Three new features", names: "ios 27.2"), "Multi-word names match")
        assertFalse(EventClusterer.headline("Muskrat numbers rise", names: "musk"), "Only whole words match")
        // A report alone that agrees with the story joins its card as a one-member event; it never names the story,
        // never merges into an event, and a reader's exclusion against the story's reports takes it out again.
        let attach = DatabaseEngine(path: ":memory:")
        try await attach.open()
        let appointment = story(
            6, "Novak's party appoints interim leader in Ljubljana after parliament ousts him", hours: 3)
        try await attach.upsertArticles(stories + [appointment])
        _ = try await EventClusterer.run(in: attach, now: now)
        _ = try await EventClusterer.run(in: attach, now: now.addingTimeInterval(60))
        let appointmentID = try await attach.resolvedArticleID(for: appointment)
        var attachIDs: [String] = []
        for article in stories { attachIDs.append(try await attach.resolvedArticleID(for: article)) }
        if let single = try await attach.eventID(forArticle: appointmentID),
            let voteEvent = try await attach.eventID(forArticle: attachIDs[0])
        {
            assertEqual(
                try await attach.eventMatchMembers(eventID: single)?.members.count, 1,
                "The attached report stays an event of its own")
            let lead = try await attach.storyID(forEvent: voteEvent)
            assertEqual(try await attach.storyID(forEvent: single), lead, "The report alone joins the story")
            assertTrue(lead != single, "A report alone never names the story")
            assertEqual(
                try await attach.eventFeedSummaries(forArticles: [attachIDs[0]]).first?.members.count, 5,
                "The story card shows the attached report")
            for other in attachIDs {
                let (low, high) = appointmentID < other ? (appointmentID, other) : (other, appointmentID)
                try await attach.eventRows(
                    "INSERT INTO event_exclusions(article_id, other_article_id, created_at) VALUES (?, ?, ?);",
                    [.text(low), .text(high), .real(now.timeIntervalSince1970)])
            }
            _ = try await EventClusterer.run(in: attach, now: now.addingTimeInterval(120))
            assertEqual(
                try await attach.storyID(forEvent: single), single, "An exclusion against the story takes it out")
        } else {
            assertTrue(false, "The appointment is attached to the vote's story as an event of its own")
        }
        await attach.close()
        // When there are no active multi-report events, the story pass skips story linking (#893).
        let singleDb = DatabaseEngine(path: ":memory:")
        try await singleDb.open()
        let loneStories = (0..<10).map { index in
            FeedArticle(
                title: "Lone report \(index) on distinct topic",
                link: "https://story.invalid/lone-\(index)",
                guid: "lone-\(index)", description: "Unclustered article",
                pubDate: now.addingTimeInterval(Double(index) * 60),
                source: "Publisher \(index)")
        }
        try await singleDb.upsertArticles(loneStories)
        let loneReport = try await EventClusterer.run(in: singleDb, now: now.addingTimeInterval(180))
        assertEqual(loneReport.changedEvents.count, 0, "No stories changed when no multi-report events exist (#893)")

        // When multi-report events exist alongside unclustered stories, candidate pruning only processes relevant stories (#893).
        let eventStories = [
            FeedArticle(
                title: "SpaceX Falcon rocket launches from Cape Canaveral",
                link: "https://story.invalid/spacex-1",
                guid: "spacex-1", description: "SpaceX orbital spaceflight from Cape Canaveral",
                pubDate: now.addingTimeInterval(0),
                source: "Publisher 1"),
            FeedArticle(
                title: "Falcon rocket launches from Cape Canaveral in SpaceX mission",
                link: "https://story.invalid/spacex-2",
                guid: "spacex-2", description: "SpaceX orbital spaceflight from Cape Canaveral",
                pubDate: now.addingTimeInterval(60),
                source: "Publisher 2"),
        ]
        try await singleDb.upsertArticles(eventStories)
        _ = try await EventClusterer.run(in: singleDb, now: now.addingTimeInterval(240))
        let eventArtID = try await singleDb.resolvedArticleID(for: eventStories[0])
        let createdEventID = try await singleDb.eventID(forArticle: eventArtID)
        assertTrue(createdEventID != nil, "SpaceX stories form an active multi-report event")
        // Canonical country features like @US match candidate reports mentioning demonyms or full country names
        let countryFeature = EventFeatures(
            title: "American diplomat arrives for summit", description: "Diplomatic mission", date: now)
        assertTrue(countryFeature.countries.contains("@US"), "American resolves to canonical @US country feature")
        assertFalse(
            countryFeature.countries.isDisjoint(with: ["@US"]), "Canonical @US intersects active @US country set")

        // Candidate prefilter retains reports whose specificAnchors overlap allAnchorTerms (#893, review fix).
        let boosterStory = FeedArticle(
            title: "Touchdown confirmed",
            link: "https://story.invalid/booster-1",
            guid: "booster-1", description: "First stage recovered safely.",
            pubDate: now.addingTimeInterval(300),
            source: "Publisher 3")
        try await singleDb.upsertArticles([boosterStory])
        let boosterID = try await singleDb.resolvedArticleID(for: boosterStory)
        var boosterFeatures = EventFeatures(
            title: boosterStory.title, description: boosterStory.description,
            date: boosterStory.pubDate)
        boosterFeatures.organizations.insert(EventFeatures.normalized("SpaceX"))
        boosterFeatures.keywords.insert("rocket")
        try await singleDb.upsertArticleFeatures([boosterID: boosterFeatures], version: EventFeatures.storageVersion)
        var prefilterPolicy = EventMatchPolicy.standard
        prefilterPolicy.storyModelThreshold = 0.8
        prefilterPolicy.semanticVetoThreshold = 0.0
        _ = try await EventClusterer.run(
            in: singleDb, matchPolicy: prefilterPolicy, now: now.addingTimeInterval(360), allowsEnergy: true,
            scoring: EventClusterScoring(storyProbabilities: { @Sendable _, _ in (0.6, 0.35) }))
        if let boosterEvent = try await singleDb.eventID(forArticle: boosterID),
            let targetEvent = createdEventID
        {
            let lead = try await singleDb.storyID(forEvent: targetEvent)
            assertEqual(
                try await singleDb.storyID(forEvent: boosterEvent), lead,
                "Candidate prefilter retains reports whose specificAnchors overlap allAnchorTerms")
        } else {
            assertTrue(false, "Booster story should have an event and attach to the SpaceX story")
        }
        await singleDb.close()
        await db.close()
    }

    /// The pair model (#525) is asked only about borderline pairs. A confident answer joins two reports that share no
    /// specific name or place; a lower one, or no model, leaves the matcher's decision as it was.
    static func testPairModelGreyZone() async throws {
        print("  - Testing the pair model in the grey zone (#525)...")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func story(_ id: Int, _ title: String, hours: Double) -> FeedArticle {
            FeedArticle(
                title: title, link: "https://grey.invalid/\(id)", guid: "grey-\(id)", description: "",
                pubDate: start.addingTimeInterval(hours * 3600), source: "Publisher \(id)")
        }
        let stories = [
            story(1, "Floods kill dozens across Pakistan after monsoon rains", hours: 0),
            story(2, "Pakistan flood death toll climbs as monsoon rains continue", hours: 3),
            story(3, "Parliament votes to oust Prime Minister Novak in Ljubljana", hours: 1),
            story(4, "Thousands protest in Ljubljana after parliament votes to oust Novak", hours: 2),
        ]
        actor Calls {
            var pairs: [String] = []
            func add(_ a: String, _ b: String) { pairs.append(a + " | " + b) }
        }
        func clustered(_ answer: Double?, prefix: Bool = false) async throws -> (events: [String?], calls: [String]) {
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            try await db.upsertArticles(stories)
            let calls = Calls()
            var policy = EventMatchPolicy.standard
            policy.pairModelPrefix = prefix
            _ = try await EventClusterer.run(
                in: db, matchPolicy: policy, now: start.addingTimeInterval(4 * 3600),
                scoring: EventClusterScoring(pairProbability: { a, b in
                    await calls.add(a, b)
                    return answer
                }))
            var events: [String?] = []
            for article in stories {
                events.append(try await db.eventID(forArticle: try await db.resolvedArticleID(for: article)))
            }
            await db.close()
            return (events, await calls.pairs)
        }
        let confident = try await clustered(0.99)
        assertTrue(
            confident.events[0] != nil && confident.events[0] == confident.events[1],
            "A confident pair model joins two flood reports that share only the country")
        assertFalse(confident.calls.isEmpty, "The borderline flood pair is sent to the pair model")
        assertFalse(
            confident.calls.contains { $0.contains("oust Prime Minister Novak") && $0.contains("Thousands protest") },
            "A pair with a hard conflict (two different acts) is never sent to the model")
        assertTrue(
            confident.calls.allSatisfy { !$0.hasPrefix("gap ") },
            "With the prefix off (the default) the model reads the plain texts")
        let prefixed = try await clustered(0.99, prefix: true)
        assertTrue(
            prefixed.calls.allSatisfy { $0.hasPrefix("gap ") && $0.contains(" | gap ") },
            "With the prefix on (#626) both inputs carry the gap and publisher words")
        let unsure = try await clustered(EventMatchPolicy.standard.pairModelThreshold - 0.01)
        assertEqual(unsure.events[0], nil, "Below the threshold the flood reports stay apart")
        let unavailable = try await clustered(nil)
        assertEqual(unavailable.events[0], nil, "Without the model the matcher decides as before")

        // Under the energy rule (#534) neither model runs; the pair waits for a pass with energy.
        let lowPower = DatabaseEngine(path: ":memory:")
        try await lowPower.open()
        try await lowPower.upsertArticles(stories)
        let rulesOnly = try await EventClusterer.run(
            in: lowPower, now: start.addingTimeInterval(4 * 3600), allowsEnergy: false,
            scoring: EventClusterScoring(pairProbability: { _, _ in
                assertTrue(false, "The pair model is not asked without energy")
                return 0.99
            }))
        var ids: [String] = []
        for article in stories { ids.append(try await lowPower.resolvedArticleID(for: article)) }
        assertEqual(try await lowPower.eventID(forArticle: ids[0]), nil, "The rules alone leave the flood pair apart")
        assertTrue(
            try await lowPower.fetchArticleEmbeddings(articleIDs: ids, modelVersion: SentenceEmbedder.modelVersion)
                .isEmpty, "No embedding is computed without energy")
        assertEqual(rulesOnly.deferred, 2, "Both flood reports wait for a pass with energy")
        let againWithoutEnergy = try await EventClusterer.run(
            in: lowPower, now: start.addingTimeInterval(5 * 3600), allowsEnergy: false,
            scoring: EventClusterScoring(pairProbability: { _, _ in
                assertTrue(false, "Deferred rows are not read again without energy")
                return 0.99
            }))
        assertEqual(againWithoutEnergy.processed, 0, "Deferred rows wait for energy instead of being re-read")
        let withEnergy = try await EventClusterer.run(
            in: lowPower, now: start.addingTimeInterval(6 * 3600), allowsEnergy: true,
            scoring: EventClusterScoring(pairProbability: { _, _ in 0.99 }))
        assertTrue(withEnergy.processed >= 2, "A pass with energy reads the deferred rows again")
        let joinedFlood = try await lowPower.eventID(forArticle: ids[0])
        let joinedFloodPartner = try await lowPower.eventID(forArticle: ids[1])
        assertTrue(
            joinedFlood != nil && joinedFlood == joinedFloodPartner, "The pair model then joins the flood reports")
        await lowPower.close()
    }

    /// "Same Event" (#524): the reader's inclusion merges two events, survives a pass that re-matches a member the
    /// rules would split off, and the newer of an inclusion and a separation of one pair wins.
    static func testEventInclusions() async throws {
        print("  - Testing Same Event inclusions (#524)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func story(_ id: Int, _ title: String, hours: Double) -> FeedArticle {
            FeedArticle(
                title: title, link: "https://same.invalid/\(id)", guid: "same-\(id)", description: "",
                pubDate: start.addingTimeInterval(hours * 3600), source: "Publisher \(id)")
        }
        let stories = [
            story(1, "Parliament votes to oust Prime Minister Novak in Ljubljana", hours: 0),
            story(2, "Parliament in Ljubljana votes to oust Prime Minister Novak", hours: 1),
            story(3, "Thousands protest in Ljubljana after parliament votes to oust Novak", hours: 5),
            story(4, "Thousands protest in Ljubljana streets after parliament votes to oust Novak", hours: 6),
        ]
        try await db.upsertArticles(stories)
        let now = start.addingTimeInterval(7 * 3600)
        _ = try await EventClusterer.run(in: db, now: now)
        var ids: [String] = []
        for article in stories { ids.append(try await db.resolvedArticleID(for: article)) }
        func event(_ index: Int) async throws -> String? { try await db.eventID(forArticle: ids[index]) }
        guard let vote = try await event(0), let protest = try await event(2), vote != protest else {
            assertTrue(false, "The rules keep the vote and the protest apart")
            return
        }
        try await db.includeEvent(vote, inEvent: protest)
        // The combination is the reader's change: it is already seen, without a second call to race a clustering pass.
        var card = try await db.eventFeedSummaries(forArticles: [ids[0]]).first
        assertEqual(card?.seenVersion, card?.membershipVersion, "Same Event records the combined version as seen")
        assertFalse(card?.hasSubstantiveUpdate ?? true, "The combination itself is not an update")
        assertEqual(try await event(0), protest, "Same Event moves the related event's reports into this one")
        assertEqual(try await db.resolvedEventID(vote), protest, "The absorbed event forwards to the survivor")
        assertEqual(
            try await db.eventInclusions(for: [ids[0]])[ids[0]], Set([ids[2], ids[3]]),
            "Every pair across the two events is recorded")

        // A retitled vote report is matched again; the rules alone would split it off, the inclusion keeps it.
        let retitled = story(1, "Parliament votes to oust Prime Minister Novak in Ljubljana late at night", hours: 0)
        try await db.upsertArticles([retitled])
        _ = try await EventClusterer.run(in: db, now: now.addingTimeInterval(60))
        assertEqual(try await event(0), protest, "The included report stays after the next pass")
        // A new report of either side still joins: it matches the vote reports, which are one event with the protest.
        let later = story(5, "Parliament in Ljubljana votes to oust Novak as prime minister", hours: 2)
        try await db.upsertArticles([later])
        ids.append(try await db.resolvedArticleID(for: later))
        _ = try await EventClusterer.run(in: db, now: now.addingTimeInterval(90))
        assertEqual(try await event(4), protest, "A later vote report joins the combined event")
        card = try await db.eventFeedSummaries(forArticles: [ids[0]]).first
        assertTrue(card?.hasSubstantiveUpdate ?? false, "A report that joined after Same Event still shows Updated")

        // Separating it later wins over the inclusion, and including it again wins over the separation.
        try await db.separateArticle(ids[0], fromEvent: protest)
        assertEqual(try await db.eventInclusions(for: [ids[0]])[ids[0]] ?? [], [], "Separation drops its inclusions")
        assertEqual(
            try await db.eventExclusions(of: ids[0]), Set([ids[2], ids[3]]),
            "… and excludes only the side it was combined with, not the other vote reports")
        _ = try await EventClusterer.run(in: db, now: now.addingTimeInterval(120))
        assertTrue(try await event(0) != protest, "A separated report never rejoins the event by itself")
        let alone = try await db.createEvent(memberArticleIDs: [ids[0]])
        try await db.includeEvent(alone.id, inEvent: protest)
        assertEqual(
            try await db.eventExclusions(of: ids[0]).intersection([ids[2], ids[3]]), [],
            "Including it again drops the exclusions")
        assertEqual(try await event(0), protest, "… and the report is back in the event")
        await db.close()
    }

    /// Bounded calibration (#629): dormant below 50 verdicts, never more than ±0.05 off the cutoff, gone when the stored
    /// pair signals are cleared, and a clean synthetic verdict replay.
    static func testPairCalibration() async throws {
        print("  - Testing the bounded pair-model calibration from reader verdicts (#629)...")
        let base = EventMatchPolicy.standard.pairModelThreshold
        assertTrue(PairCalibration.fit(syntheticVerdicts(49)) == nil, "Dormant below 50 verdicts")
        let oneAnswer = syntheticVerdicts(80).map { PairCalibration.Row(features: $0.features, same: true) }
        assertTrue(PairCalibration.fit(oneAnswer) == nil, "Verdicts with one answer fit nothing")
        guard let calibration = PairCalibration.fit(syntheticVerdicts(120)) else {
            return assertTrue(false, "120 verdicts with both answers fit a calibration")
        }
        for features in [[0.0, 0, 0, 0, 0], [1.0, 1, 1, 1, 1], [0.9, 0.7, 0.4, 0, 1], [0.9, 0.7, 0.4, 1, 1]] {
            let cutoff = calibration.cutoff(base, features)
            assertTrue(abs(cutoff - base) <= PairCalibration.maximumShift + 1e-12, "The cutoff moves at most ±0.05")
        }
        let near = PairCalibration.features(pairModel: 0.9, cosine: 0.7, sharedSpecific: 2, gapHours: 2, sameAct: true)
        let far = PairCalibration.features(pairModel: 0.9, cosine: 0.7, sharedSpecific: 2, gapHours: 48, sameAct: true)
        assertTrue(calibration.cutoff(base, near) < calibration.cutoff(base, far), "It learns what the verdicts say")
        let replay = verdictReplay(syntheticVerdicts(120))
        assertTrue(replay.fitted && replay.calibrated >= replay.bare, "The synthetic verdict replay is clean")

        // Verdicts reach the fit through the stored signals of their pair decisions; without them it is dormant again.
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let reports = (0..<4).map { index in
            FeedArticle(
                storedID: "verdict-\(index)", title: "Report \(index)", link: "https://verdict.invalid/\(index)",
                guid: "verdict-\(index)", description: "", pubDate: start.addingTimeInterval(Double(index) * 3600),
                source: "Publisher \(index)")
        }
        try await db.upsertArticles(reports)
        var ids: [String] = []
        for report in reports { ids.append(try await db.resolvedArticleID(for: report)) }
        func decision(_ a: String, _ b: String) -> DatabaseEngine.PairDecision {
            let (low, high) = a < b ? (a, b) : (b, a)
            return DatabaseEngine.PairDecision(
                articleID: low, otherArticleID: high, decision: "borderline", reason: "borderline", score: 0.6,
                features: #"{"cosine":0.7,"entity":0.5,"pairModel":0.88,"sharedAnchors":2,"sharedKeywords":2,"#
                    + #""sharedSpecific":2,"what":0.3}"#)
        }
        try await db.upsertPairDecisions(
            [decision(ids[0], ids[1]), decision(ids[2], ids[3])], matcherVersion: EventMatcher.version)
        for (table, a, b) in [("event_inclusions", ids[0], ids[1]), ("event_exclusions", ids[2], ids[3])] {
            let (low, high) = a < b ? (a, b) : (b, a)
            try await db.eventRows(
                "INSERT INTO \(table)(article_id, other_article_id, created_at) VALUES (?, ?, ?);",
                [.text(low), .text(high), .real(start.timeIntervalSince1970)])
        }
        let rows = try await db.calibrationRows()
        assertEqual(rows.map(\.same).sorted { !$0 && $1 }, [false, true], "One row per verdict with a stored signal")
        assertEqual(rows.first?.features.count, 5, "Five features per verdict")
        assertEqual(try await db.calibrationRows(limit: 1).count, 1, "The limit bounds the rows read")
        try await db.clearArticleEnrichment()
        let cleared = try await db.calibrationRows()
        assertEqual(cleared.count, 0, "Clear AI Analysis empties the calibration's input")
        assertTrue(PairCalibration.fit(cleared) == nil, "… so the calibration is dormant again")
        assertEqual(
            try await db.eventRows("SELECT count(*) FROM pair_assessments;").first?.first ?? nil, "2",
            "The pair decisions themselves remain")
        await db.close()
    }

    /// Authored story regressions (#581): the known story failures as synthetic families, asserted exactly at both levels,
    /// which reports share an event and which share a story card. A pair in `knownGaps` is asserted the other way round
    /// from its label, so a fix that closes a gap fails here until the gap is taken off the list.
    static func testStoryRegressionCorpus() async throws {
        print("  - Testing the authored story regressions: events and story cards (#581)...")
        struct Fixture: Decodable {
            struct Item: Decodable {
                let id: String, title: String, description: String?, source: String, published: Date
                let event: String?, story: String?
            }
            struct Gaps: Decodable { let events: [[String]], stories: [[String]] }
            let articles: [Item]
            let knownGaps: Gaps
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/story-corpus/story-regressions-v1.json")))
        let items = fixture.articles.sorted { ($0.published, $0.id) < ($1.published, $1.id) }
        let memberships = try await StoryCorpus.memberships(
            articles: items.map {
                FeedArticle(
                    storedID: $0.id, title: $0.title, link: "https://story-regressions.invalid/\($0.id)", guid: $0.id,
                    description: $0.description ?? "", pubDate: $0.published, source: $0.source)
            })
        func key(_ a: String, _ b: String) -> String { a < b ? a + "+" + b : b + "+" + a }
        let eventGaps = Set(fixture.knownGaps.events.map { key($0[0], $0[1]) })
        let storyGaps = Set(fixture.knownGaps.stories.map { key($0[0], $0[1]) })
        // NEWS_ENERGY=0 (#534): the rules-only replay holds every match for a pass with energy, so only links are checked.
        let rulesOnly = ProcessInfo.processInfo.environment["NEWS_ENERGY"] == "0"
        var failures: [String] = []
        var linked = (events: 0, stories: 0)
        for i in items.indices {
            for j in items.indices where j > i {
                let (a, b) = (items[i], items[j])
                let pair = key(a.id, b.id)
                let event = a.event != nil && a.event == b.event
                let story = (a.story ?? a.event).map { $0 == (b.story ?? b.event) } ?? false
                let predictedEvent = memberships[a.id]?.event == memberships[b.id]?.event
                let predictedStory = memberships[a.id]?.story == memberships[b.id]?.story
                if predictedEvent { linked.events += 1 }
                if predictedStory { linked.stories += 1 }
                if predictedEvent != (event != eventGaps.contains(pair)), predictedEvent || !rulesOnly {
                    failures.append("event \(pair) \(predictedEvent ? "linked" : "apart")")
                }
                if predictedStory != (story != storyGaps.contains(pair)), predictedStory || !rulesOnly {
                    failures.append("story \(pair) \(predictedStory ? "linked" : "apart")")
                }
            }
        }
        print(
            "    story regressions v\(EventMatcher.version): \(linked.events) event pairs, \(linked.stories) story pairs;"
                + " known gaps \(eventGaps.count) event, \(storyGaps.count) story")
        print("    unexpected: \(failures.isEmpty ? "none" : failures.joined(separator: ", "))")
        assertTrue(failures.isEmpty, "Authored story regressions changed (\(failures.count) pairs)")
    }

    static func testMatcherRegressionCorpus() async throws {
        print("  - Testing the authored matcher regression corpus (#506)...")
        struct Fixture: Decodable {
            struct Item: Decodable {
                let id: String, title: String, description: String?, source: String, published: Date, event: String?
            }
            struct Expected: Decodable { let minimumTruePositives: Int, maximumFalsePositives: Int }
            let articles: [Item]
            let expected: Expected
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/story-corpus/matcher-regressions-v1.json")))
        let items = fixture.articles.sorted { ($0.published, $0.id) < ($1.published, $1.id) }
        let articles = items.map {
            FeedArticle(
                storedID: $0.id, title: $0.title, link: "https://matcher-regressions.invalid/\($0.id)", guid: $0.id,
                description: $0.description ?? "", pubDate: $0.published, source: $0.source)
        }
        // NEWS_ENERGY=0 replays Low Power Mode (#534): a fresh replay has no stored vectors, so every rule match waits for
        // a pass with energy and the true-positive floor cannot hold; the false-pair ceiling still applies.
        let rulesOnly = ProcessInfo.processInfo.environment["NEWS_ENERGY"] == "0"
        var deferred = 0
        // Event labels only: a story-level link between two events of one story would read as a false pair, so this
        // corpus is scored by event; the story regressions and the library holdout's story level measure stories.
        let memberships = try await StoryCorpus.eventMemberships(articles: articles) { deferred += $0.deferred }
        var metrics = EventCorpusMetrics()
        var falsePairs: [String] = []
        var missedPairs: [String] = []
        for i in items.indices {
            for j in items.indices where j > i {
                let predicted =
                    memberships[items[i].id] != nil && memberships[items[i].id] == memberships[items[j].id]
                let gold = items[i].event != nil && items[i].event == items[j].event
                guard predicted || gold else { continue }
                metrics.add(predicted: predicted, gold: gold)
                if predicted && !gold { falsePairs.append("\(items[i].id)+\(items[j].id)") }
                if gold && !predicted { missedPairs.append("\(items[i].id)+\(items[j].id)") }
            }
        }
        print("    matcher regressions v\(EventMatcher.version): \(metrics.line)")
        print("    false pairs: \(falsePairs.isEmpty ? "none" : falsePairs.joined(separator: ", "))")
        print("    missed pairs: \(missedPairs.isEmpty ? "none" : missedPairs.joined(separator: ", "))")
        if rulesOnly {
            print("    rules only (NEWS_ENERGY=0): \(deferred) rows deferred to a pass with energy; no floor")
        }
        assertTrue(
            (rulesOnly && deferred > 0) || metrics.truePositives >= fixture.expected.minimumTruePositives,
            "Authored corpus true positives fell below the recorded floor (\(metrics.truePositives))")
        assertTrue(
            metrics.falsePositives <= fixture.expected.maximumFalsePositives,
            "Authored corpus false pairs exceeded the recorded ceiling (\(metrics.falsePositives))")
    }

    static func testEventCorpusHarness(fixtureRoot: URL) async throws {
        // A pinned holdout window includes both boundaries and excludes later snapshot reports.
        let windowDB = DatabaseEngine(path: ":memory:")
        try await windowDB.open()
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        // Typed offsets (3 days + 1 s and 3 days before the clock, the clock, 1 s after): the literal arithmetic inside
        // the closure took the CI compiler past its type-check limit.
        let windowOffsets: [TimeInterval] = [-259_201, -259_200, 0, 1]
        let windowArticles: [FeedArticle] = windowOffsets.enumerated().map { index, offset in
            FeedArticle(
                storedID: "window-\(index)", title: "Window report \(index)", link: "https://window.invalid/\(index)",
                guid: "window-\(index)", description: "", pubDate: pinned.addingTimeInterval(offset), source: "Corpus")
        }
        try await windowDB.upsertArticles(windowArticles)
        let window = try await recentLibraryRows(windowDB, now: pinned)
        assertEqual(window.newest, pinned, "The pinned clock is independent of the snapshot's newest report")
        assertEqual(window.rows.map(\.id), ["window-1", "window-2"], "Recent totals use the closed pinned window")
        await windowDB.close()
        // One refresh-sized batch must not bypass production's article budget in the evaluator.
        let batchDate = Date(timeIntervalSince1970: 1_700_000_000)
        let oversized = (0..<2_001).map { index in
            FeedArticle(
                storedID: "budget-\(index)", title: "", link: "https://corpus.invalid/budget-\(index)",
                guid: "budget-\(index)", description: "", pubDate: batchDate, source: "Corpus")
        }
        var processed: [Int] = []
        let boundedMemberships = try await StoryCorpus.eventMemberships(articles: oversized) {
            processed.append($0.processed)
        }
        assertEqual(processed, [2_000], "Corpus replay uses the production per-pass article limit")
        assertEqual(boundedMemberships.count, 2_001, "Budget-deferred articles remain observable as singletons")
        print("  - Testing the labeled event corpus harness on the synthetic control set...")
        assertTrue(EventCorpusMetrics().precision == nil, "No predicted positives cannot establish precision")
        assertTrue(EventCorpusMetrics().recall == nil, "No labeled positives cannot establish recall")
        // The 9 October judge-off replay: 21 TP, 1 FP, 17 FN (#307).
        let replay = EventCorpusMetrics(truePositives: 21, falsePositives: 1, falseNegatives: 17).line
        assertTrue(
            replay.contains("precision 0.955 [95% 0.782–0.992]"), "Precision carries its Wilson 95% interval: \(replay)"
        )
        assertTrue(
            replay.contains("recall 0.553 [95% 0.397–0.699]"), "Recall carries its Wilson 95% interval: \(replay)")
        assertEqual(
            EventCorpusMetrics().line, "precision n/a (TP 0, FP 0), recall n/a (FN 0)",
            "Undefined metrics carry no interval")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let formatter = ISO8601DateFormatter()
        let items = EventControlSet.articles(now: Date(), root: fixtureRoot).map { item -> [String: String] in
            var entry = [
                "id": item.article.id, "title": item.article.title, "description": item.article.description,
                "source": item.article.source, "published": formatter.string(from: item.article.pubDate),
                "split": "holdout",
            ]
            entry["event"] = item.event
            return entry
        }
        let file = directory.appendingPathComponent("corpus.json")
        try JSONSerialization.data(withJSONObject: ["articles": items]).write(to: file)
        let sealed = try await evaluateEventCorpus(path: file.path)
        assertTrue(sealed["holdout"] == nil, "Default corpus evaluation leaves holdout sealed")
        let metrics = try await evaluateEventCorpus(path: file.path, selectedSplit: "holdout")
        guard let holdout = metrics["holdout"] else { return assertTrue(false, "The holdout split is evaluated") }
        assertEqual(holdout.falsePositives, 0, "The synthetic control set has no false merges")
        assertTrue(holdout.truePositives >= 3, "The synthetic earthquake reports are linked")

        // Real corpus URLs must exercise identity resolution, including updated titles at one URL.
        let identityItems: [[String: String]] = [
            [
                "id": "url-original", "title": "Council authorises bridge reconstruction", "source": "Corpus",
                "url": "https://corpus.example/document", "published": formatter.string(from: Date()),
                "event": "document", "split": "tune",
            ],
            [
                "id": "url-variant", "title": "Revised transportation memorandum", "source": "Corpus",
                "url": "https://corpus.example/document?utm_source=variant",
                "published": formatter.string(from: Date()),
                "event": "document", "split": "tune",
            ],
        ]
        let identityFile = directory.appendingPathComponent("identity.json")
        try JSONSerialization.data(withJSONObject: ["articles": identityItems]).write(to: identityFile)
        let identityMetrics = try await evaluateEventCorpus(path: identityFile.path)
        assertEqual(
            identityMetrics["tune"]?.truePositives, 1, "Observed URLs resolve copies even when their titles differ")
        assertEqual(
            identityMetrics["tune"]?.falsePositives, 0, "URL replay preserves document identity without false merges")

        let spanish = [
            "id": "spanish",
            "title": "Las autoridades municipales aprueban la construcción de una nueva biblioteca pública",
            "source": "Corpus", "published": formatter.string(from: Date()), "split": "tune",
        ]
        try JSONSerialization.data(withJSONObject: ["articles": identityItems + [spanish]]).write(to: identityFile)
        let english = try await evaluateEventCorpus(
            path: identityFile.path, language: "en", outputDirectory: directory.path)
        assertEqual(english["tune"]?.truePositives, 1, "English replay preserves observed document identity")
        let output = directory.appendingPathComponent("event-replay-tune.json")
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String: Any]
        assertEqual(
            (receipt["memberships"] as? [String: String])?.count, 2, "Other languages never enter the English replay")
        assertTrue(
            (receipt["passes"] as? [[String: Int]])?.isEmpty == false,
            "Saved predictions include clustering pass counts")
        do {
            _ = try await evaluateEventCorpus(path: identityFile.path, language: "en", outputDirectory: directory.path)
            assertTrue(false, "A replay must not overwrite its previous evidence")
        } catch {
            // Existing evidence is rejected before scoring.
        }

        print("  - Testing the native embedding comparison (#127)...")
        let now = Date()
        let controls = EventControlSet.articles(now: now, root: fixtureRoot)
        let memberships = try await StoryCorpus.eventMemberships(articles: controls.map(\.article))
        var comparisonItems = controls.map {
            EventEmbeddingComparison.Item(
                title: $0.article.title, description: $0.article.description, date: $0.article.pubDate,
                event: $0.event, membership: memberships[$0.article.id])
        }
        // The same earthquake in French, and an English copy dated six days earlier.
        comparisonItems.append(
            .init(
                title: "Un séisme de magnitude 7 frappe l'est de la Turquie près de Malatya",
                description:
                    "Un puissant séisme de magnitude 7 a frappé lundi l'est de la Turquie près de la ville de Malatya, endommageant des bâtiments, selon l'agence turque de gestion des catastrophes.",
                date: now.addingTimeInterval(-5 * 3600), event: "quake", membership: nil))
        comparisonItems.append(
            .init(
                title: controls[0].article.title, description: controls[0].article.description,
                date: now.addingTimeInterval(-6 * 86400), event: "quake", membership: nil))

        let unsupported = EventEmbeddingComparison(items: comparisonItems, thresholds: [2], model: { _ in nil })
        assertEqual(unsupported.notCompared["cross-language"], 4, "Vectors from different languages are never compared")
        assertEqual(
            unsupported.notCompared["outside time window"], 3, "Pairs the matcher cannot link in time are not compared")
        assertEqual(
            unsupported.notCompared["no sentence embedding"], 3, "A language without a sentence embedding abstains")
        assertTrue(unsupported.scores.isEmpty, "Nothing is scored without vectors")
        assertTrue(
            unsupported.languages.values.allSatisfy { $0.dimension == nil }, "Missing models are reported per language")
        assertEqual(EventEmbeddingComparison.cosineDistance([1, 0], [0, 0]), 2, "A zero vector is never close")
        assertTrue(
            abs(EventEmbeddingComparison.cosineDistance([1, 2], [2, 4])) < 1e-12, "Parallel vectors have no distance")

        let support = Set(FeedCatalog.feeds.map(\.language)).sorted().map { code in
            "\(code) "
                + (NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: code)).map { "\($0.dimension)" } ?? "none")
        }
        print("    Sentence embeddings for catalog languages on this system: \(support.joined(separator: ", "))")
        let native = EventEmbeddingComparison(items: comparisonItems, thresholds: [0.5, 2])
        guard native.languages["en"]?.dimension != nil, let all = native.scores["all"] else {
            return print("    No English sentence embedding on this system; native scoring not exercised")
        }
        assertEqual(native.notCompared["cross-language"], 4, "Cross-language pairs stay out with native models")
        assertEqual(all.deterministic.truePositives, 3, "Deterministic links are scored on the same pairs")
        assertEqual(all.deterministic.falsePositives, 0, "The control set has no deterministic false merges")
        for row in all.rows {
            assertTrue(
                row.veto.truePositives <= all.deterministic.truePositives
                    && row.veto.falsePositives <= all.deterministic.falsePositives,
                "A veto only removes deterministic links")
            assertTrue(row.rescue.truePositives >= all.deterministic.truePositives, "A rescue only adds links")
        }
        assertEqual(all.rows.last?.embedding.falseNegatives, 0, "The widest cutoff links every comparable labeled pair")
    }

    static func testCapturedFingerprintReview() throws {
        print("  - Testing the private captured-feed fingerprint review (#102)...")
        let request = StoryCorpus.PageRequest(id: "doc-0001", url: "https://example.com/article")
        assertTrue(StoryCorpus.validPageRequests([request]), "A bounded uniquely identified page is accepted")
        assertFalse(StoryCorpus.validPageRequests([]), "An empty evidence request is rejected")
        assertFalse(
            StoryCorpus.validPageRequests([request, request]), "Repeated IDs cannot overwrite publisher evidence")
        assertFalse(
            StoryCorpus.validPageRequests([.init(id: "../outside", url: request.url)]),
            "Evidence IDs cannot escape the private directory")
        assertFalse(
            StoryCorpus.validPageRequests((0...500).map { .init(id: "doc-\($0)", url: request.url) }),
            "Evidence collection stays bounded")
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("news-capture-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        defer { try? fileManager.removeItem(at: directory) }

        func rejects(_ path: String) -> Bool { (try? StoryCorpus.privateDirectory(path)) == nil }
        assertTrue(rejects("relative/captures"), "Relative capture directories are rejected")
        assertTrue(
            rejects(directory.appendingPathComponent("missing").path), "A missing directory is not created implicitly")
        assertTrue(rejects(fileManager.currentDirectoryPath), "Publisher text never lands in the checkout")
        let shared = directory.appendingPathComponent("shared")
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
        assertTrue(rejects(shared.path), "A directory other users can read is rejected")
        assertFalse(rejects(directory.path), "A private directory is accepted")

        let hosts = (0..<64).map { "publisher\($0).example" }
        guard let tuningHost = hosts.first(where: { StoryCorpus.captureSplit(host: $0) == "tuning" }),
            let holdoutHost = hosts.first(where: { StoryCorpus.captureSplit(host: $0) == "holdout" })
        else {
            return assertTrue(false, "Both splits are reachable")
        }
        let body = (1...60).map { "Captured report sentence \($0) adds one verifiable detail." }.joined(separator: " ")
        func item(
            _ host: String, _ path: String, guid: String, text: String? = nil,
            published: Double? = 1_800_000_000, language: String = "en"
        ) -> StoryCorpus.CapturedItem {
            StoryCorpus.CapturedItem(
                feed: "https://\(host)/feed.xml", language: language, source: "Publisher",
                link: "https://\(host)/\(path)",
                guid: guid, title: "Council approves budget", description: "Short teaser.",
                content: text ?? body, published: published)
        }
        let original = item(tuningHost, "news/budget", guid: "1")
        let amp = item(tuningHost, "amp/news/budget", guid: "2")
        let tracked = item(tuningHost, "news/budget?utm_source=rss", guid: "3")
        let edited = item(tuningHost, "news/budget", guid: "4", text: body + " A correction was appended.")
        let other = item(
            tuningHost, "news/other", guid: "5", text: body.replacingOccurrences(of: "verifiable", with: "separate"))
        let short = item(tuningHost, "news/short", guid: "6", text: "Too short to fingerprint.")
        let undated = item(tuningHost, "news/undated", guid: "7", published: nil)
        let holdoutPair = [item(holdoutHost, "story", guid: "h1"), item(holdoutHost, "story?output=amp", guid: "h2")]

        let parsed = original.article
        let roundTrip = StoryCorpus.CapturedItem(feed: original.feed, language: "en", article: parsed)
        assertEqual(roundTrip, original, "A parsed article is captured unchanged")
        assertEqual(
            ArticleIdentity.publisherTextFingerprints(roundTrip.article),
            ArticleIdentity.publisherTextFingerprints(parsed),
            "Captured items reproduce the production fingerprint")
        assertTrue(
            StoryCorpus.CapturedItem(feed: "f", language: "en", article: undated.article).published == nil,
            "Unknown dates stay unknown")

        let first = try StoryCorpus.writeCapture(
            StoryCorpus.Capture(
                version: 1, capturedAt: 1_800_000_100,
                items: [
                    original, amp, tracked, edited, other, short,
                    item(tuningHost, "parked", guid: "parked", language: "de"),
                    item(holdoutHost, "parked", guid: "parked", language: "de"),
                ] + holdoutPair), in: directory)
        let permissions = try fileManager.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
        assertEqual(permissions?.intValue, 0o600, "Captured publisher text is readable only by its owner")
        assertTrue(
            (try? StoryCorpus.writeCapture(
                StoryCorpus.Capture(version: 1, capturedAt: 1_800_000_100, items: []), in: directory)) == nil,
            "An existing capture is never overwritten")
        try StoryCorpus.writeCapture(
            StoryCorpus.Capture(version: 1, capturedAt: 1_800_000_200, items: [original, undated]), in: directory)

        var review = try StoryCorpus.reviewCaptures(directory: directory.path, holdout: false)
        assertEqual(review.captureFiles, 2, "Every capture file is read")
        assertEqual(
            review.observations, 7,
            "Repeated observations count once, parked languages are excluded and holdout hosts stay sealed")
        assertEqual(review.eligible, 5, "Short and undated items are not fingerprinted")
        assertEqual(review.eligibleDocuments, 3, "Copies at one canonical URL count as one eligible document")
        assertEqual(review.eligibleByLanguage["de"], nil, "Parked captures cannot inflate the release denominator")
        assertEqual(review.sameURLShared, 1, "A stripped tracking parameter is the same URL")
        assertEqual(review.sameURLDisjoint, 2, "An edited body at the same URL no longer shares a fingerprint")
        assertEqual(review.total.candidates, 1, "One different-URL pair shares a fingerprint")
        assertEqual(review.total.unlabeled, 1, "Unreviewed candidates abstain")
        assertTrue(review.total.precision == nil && !review.gatePassed, "No adjudication, no precision")
        let sheet = try Data(contentsOf: directory.appendingPathComponent("review-tuning.json"))
        let key = StoryCorpus.capturePairKey(original.article.normalizedLink, amp.article.normalizedLink)
        assertTrue(String(decoding: sheet, as: UTF8.self).contains(key), "The review sheet lists the candidate pair")
        assertFalse(
            String(decoding: sheet, as: UTF8.self).contains("Captured report sentence"),
            "The review sheet carries no body text")
        assertFalse(
            fileManager.fileExists(atPath: directory.appendingPathComponent("review-holdout.json").path),
            "The holdout stays sealed")

        let readiness = try StoryCorpus.reviewCaptures(directory: directory.path, holdout: true, readinessOnly: true)
        assertEqual(readiness.eligibleDocuments, 2, "Readiness counts distinct eligible holdout documents")
        assertEqual(readiness.report["scoringPerformed"] as? Bool, false, "Readiness never scores")
        assertTrue(
            readiness.report["differentURLCandidates"] == nil && readiness.report["falseMergeUpperBound95"] == nil,
            "Readiness exposes no pair outcomes or observed error bound")
        assertFalse(readiness.gatePassed, "Sample counts alone cannot pass acceptance")
        assertFalse(
            fileManager.fileExists(atPath: directory.appendingPathComponent("review-holdout.json").path),
            "Readiness leaves the holdout sealed")

        let holdoutKey = StoryCorpus.capturePairKey(
            holdoutPair[0].article.normalizedLink, holdoutPair[1].article.normalizedLink)
        let labelsFile = directory.appendingPathComponent("labels.json")
        try JSONSerialization.data(withJSONObject: [key: "same_document", holdoutKey: "same_document"]).write(
            to: labelsFile)
        review = try StoryCorpus.reviewCaptures(directory: directory.path, holdout: false)
        assertEqual(
            [review.total.sameDocument, review.total.different, review.total.unlabeled], [1, 0, 0],
            "Labels are applied to their split")
        assertEqual(review.byLanguage["en"]?.precision, 1, "Precision is reported per language")
        assertEqual(review.bySource["Publisher"]?.candidates, 1, "Candidates are reported per source")
        assertFalse(review.gatePassed, "Tuning never passes the release gate")
        review = try StoryCorpus.reviewCaptures(directory: directory.path, holdout: true)
        assertEqual(
            [review.observations, review.total.candidates, review.total.sameDocument], [2, 1, 1],
            "The holdout is scored when unsealed")
        assertFalse(review.gatePassed, "Two eligible documents are too little support for the gate")
        try JSONSerialization.data(withJSONObject: [key: "maybe"]).write(to: labelsFile, options: .atomic)
        assertEqual(
            try StoryCorpus.reviewCaptures(directory: directory.path, holdout: true, readinessOnly: true)
                .eligibleDocuments,
            2, "Readiness does not read adjudication labels")
        assertTrue(
            (try? StoryCorpus.reviewCaptures(directory: directory.path, holdout: false)) == nil,
            "Unknown labels are rejected")

        func metrics(_ same: Int, _ different: Int, unlabeled: Int = 0) -> StoryCorpus.CaptureMetrics {
            StoryCorpus.CaptureMetrics(
                candidates: same + different + unlabeled, sameDocument: same, different: different)
        }
        func passes(_ metrics: StoryCorpus.CaptureMetrics, documents: Int = 1_000, split: String = "holdout") -> Bool {
            StoryCorpus.captureGatePassed(split: split, metrics: metrics, eligibleDocuments: documents)
        }
        assertTrue(passes(metrics(99, 1)), "99% over 100 adjudicated candidates passes")
        assertFalse(passes(metrics(98, 2)), "Two errors in 100 fail")
        assertTrue(
            passes(metrics(0, 0), documents: 381), "Without matches, 381 eligible documents bound false merges at 1%")
        assertFalse(passes(metrics(0, 0), documents: 380), "Fewer eligible documents cannot bound false merges at 1%")
        assertFalse(passes(metrics(5, 1), documents: 381), "One false merge needs more eligible support")
        assertFalse(passes(metrics(150, 0, unlabeled: 1)), "Unreviewed candidates block the gate")
        assertFalse(passes(metrics(200, 0), split: "tuning"), "Tuning never passes the gate")
        assertTrue(
            abs((metrics(100, 0).precisionLowerBound ?? 0) - 0.963) < 0.001,
            "The Wilson bound reports sampling uncertainty")
    }

}
