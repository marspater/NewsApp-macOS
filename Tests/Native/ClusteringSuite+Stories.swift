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

extension NativeSuites.ClusteringSuite {
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
        expectEqual(
            Set(canonical?.sources ?? []), Set(["Euronews", "France 24"]),
            "Generic feed names resolve to distinct catalog publishers")
        expectEqual(canonical?.coverageText, "2 stories · 2 publishers", "Coverage always exposes both counts")
        expectEqual(try await summary()?.seenVersion, nil, "An event starts unseen")
        expectFalse(try await summary()?.hasSubstantiveUpdate ?? true, "An unseen event is new, not updated")
        expectEqual(
            try await summary()?.members.map(\.articleID), ["second", "first"], "Members are listed newest first")
        expectEqual(try await db.markEventSeen(event.id), 1, "Opening records the current version")
        expectFalse(try await db.isRead(articleId: "first"), "Seeing an event marks no article read")
        try await db.addArticles(["reprint"], toEvent: event.id)
        expectFalse(
            try await summary()?.hasSubstantiveUpdate ?? true, "A reprint of a known headline is not new reporting")
        expectEqual(
            try await summary()?.coverageText, "3 stories · 3 publishers", "Coverage counts distinct publishers")
        try await db.addArticles(["update"], toEvent: event.id)
        expectEqual(try await db.markEventSeen(event.id, version: 2), 2, "Reading overview version 2 records version 2")
        expectTrue(
            try await summary()?.hasSubstantiveUpdate ?? false, "Version 2 does not cover reporting that joined later")
        try await db.markRead(articleId: "update", isRead: true)
        expectFalse(try await summary()?.hasSubstantiveUpdate ?? true, "Reading the new article settles the update")
        expectEqual(try await db.eventSeenVersion(event.id), 2, "Article state does not change event state")
        expectEqual(try await db.markEventSeen(event.id), 3, "Opening again records the latest version")
        expectEqual(try await db.markEventSeen(event.id, version: 1), 3, "Seen versions never go back")
        let other = try await db.createEvent(memberArticleIDs: ["merged"], at: now)
        try await db.mergeEvents(other.id, into: event.id)
        expectTrue(
            try await summary()?.hasSubstantiveUpdate ?? false, "Reporting merged in later is an update of the event")
        expectEqual(try await db.markEventSeen(other.id), 4, "The absorbed ID records state on the survivor")
        try await db.setSaved(articleId: "second", isSaved: true)
        expectEqual(
            try await summary()?.members.first { $0.articleID == "second" }?.isSaved, true,
            "Members carry their own saved state")
        await db.close()

        // v13 → v14 on a copy: cancellation rolls back; the upgrade keeps events.
        var handle: OpaquePointer?
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open v14 fixture")
        expectEqual(
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
            expectEqual(sqlite3_open(file, &connection), SQLITE_OK, "Inspect v14 fixture")
            defer { sqlite3_close(connection) }
            expectEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK, "Prepare v14 inspection")
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
            expectTrue(false, "Cancelled v14 migration must throw")
        } catch is CancellationError {}
        expectEqual(value(copy, "PRAGMA user_version;"), "13", "Cancelled v14 migration keeps version 13")
        expectEqual(
            value(
                copy,
                "SELECT count(*) FROM sqlite_master WHERE name IN ('event_match_state','event_exclusions','event_state');"
            ), "0", "Cancelled v14 migration rolls back its tables")
        let migrated = DatabaseEngine(path: copy)
        try await migrated.open()
        expectEqual(
            value(copy, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Copied v13 library upgrades to the current schema")
        expectEqual(value(path, "PRAGMA user_version;"), "13", "Original v13 fixture stays untouched")
        expectEqual(
            try await migrated.fetchEvent(id: event.id)?.memberArticleIDs.count, 5, "Migration keeps events and members"
        )
        expectTrue(try await migrated.isSaved(articleId: "second"), "Migration keeps saved state")
        expectEqual(
            value(
                copy,
                "SELECT count(*) FROM pragma_table_info('event_exclusions') WHERE name IN ('title','description','content');"
            ), "0", "Exclusions store no source text")
        expectEqual(value(copy, "PRAGMA quick_check;"), "ok", "Migrated library passes quick_check")
        await migrated.close()
    }

    static func testEventFeedSummaryUnit() {
        print("  - Testing EventFeedSummary extraction, display source, title key, dates, and update detection...")
        expectEqual(EventFeedSummary.displaySource(""), "", "Empty display source remains empty")
        expectEqual(
            EventFeedSummary.displaySource("   BBC News   \n   Section  "), "BBC News",
            "Trims whitespace and extracts first line")
        expectEqual(EventFeedSummary.displaySource("TechCrunch"), "TechCrunch", "Single line display source trimmed")

        expectEqual(EventFeedSummary.titleKey(""), "", "Empty titleKey is empty")
        expectEqual(
            EventFeedSummary.titleKey("Hello, World! 123..."), "hello world 123",
            "Strips punctuation/symbols and converts to lowercase")
        expectEqual(
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
        expectFalse(summary1.isConfirmed, "Single member event is not confirmed")
        expectEqual(summary1.sources, ["Wire One"], "Sources extracts formatted displaySource")

        let summaryMulti = EventFeedSummary(
            eventID: "e2", membershipVersion: 2, seenVersion: nil, members: [member1, member2, member3])
        expectTrue(summaryMulti.isConfirmed, "Multiple member event is confirmed")
        expectEqual(
            summaryMulti.sources, ["Wire One", "Daily Two"], "Deduplicates sources case-insensitively in order")

        expectEqual(
            EventFeedSummary(eventID: "e0", membershipVersion: 1, seenVersion: nil, members: []).latestDate, nil,
            "Empty members has nil latestDate")
        expectEqual(summaryMulti.latestDate, now.addingTimeInterval(100), "latestDate picks maximum date among members")

        expectEqual(
            EventFeedSummary(eventID: "e0", membershipVersion: 1, seenVersion: nil, members: []).coverageText,
            "0 stories · 0 publishers", "Empty members coverageText fallback")
        expectEqual(summary1.coverageText, "1 story · 1 publisher", "Single article from single source formatting")
        let summarySameSource = EventFeedSummary(
            eventID: "e3", membershipVersion: 1, seenVersion: nil, members: [member1, member2])
        expectEqual(
            summarySameSource.coverageText, "2 stories · 1 publisher",
            "Multiple articles from single source formatting")
        expectEqual(summaryMulti.coverageText, "3 stories · 2 publishers", "Multiple sources coverageText formatting")

        expectFalse(summaryMulti.hasSubstantiveUpdate, "Nil seenVersion returns false")

        let summarySeenCurrent = EventFeedSummary(
            eventID: "e4", membershipVersion: 2, seenVersion: 2, members: [member1, member2, member3])
        expectFalse(summarySeenCurrent.hasSubstantiveUpdate, "seenVersion equal to membershipVersion returns false")

        let member3Read = EventFeedMember(
            articleID: "a3", source: "Daily Two", title: "Third Story", date: now, joinedVersion: 2, isRead: true,
            isSaved: false)
        let summaryReadUpdate = EventFeedSummary(
            eventID: "e5", membershipVersion: 2, seenVersion: 1, members: [member1, member2, member3Read])
        expectFalse(summaryReadUpdate.hasSubstantiveUpdate, "Read new member does not trigger substantive update")

        let member3Reprint = EventFeedMember(
            articleID: "a3", source: "Daily Two", title: "First Story!", date: now, joinedVersion: 2, isRead: false,
            isSaved: false)
        let summaryReprint = EventFeedSummary(
            eventID: "e6", membershipVersion: 2, seenVersion: 1, members: [member1, member2, member3Reprint])
        expectFalse(
            summaryReprint.hasSubstantiveUpdate, "Unread new member repeating known title (reprint) returns false")

        let summarySubstantive = EventFeedSummary(
            eventID: "e7", membershipVersion: 2, seenVersion: 1, members: [member1, member2, member3])
        expectTrue(summarySubstantive.hasSubstantiveUpdate, "Unread new member with novel headline returns true")
    }

    static func testEventFeedGroupingAndStability() async throws {
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
        expectEqual(grouped.map(\.id), ["a", "b", "d"], "A confirmed event is one card at its first listed member")
        if case .event(let summary, let representative, let visible) = grouped[0] {
            expectEqual(summary.eventID, "e1", "The card carries its event")
            expectEqual(representative.id, "a", "The first listed member represents the event")
            expectEqual(visible.map(\.id), ["a", "c"], "Every listed member stays available inside the event")
        } else {
            expectTrue(false, "The first entry is an event card")
        }
        expectEqual(
            EventFeedGrouping.entries(for: [a, b, c, d], events: [event, single], mode: .publications).map(\.id),
            ["a", "b", "c", "d"], "Publication mode lists every article")
        expectEqual(
            EventFeedGrouping.entries(for: [c, b], events: [event], mode: .events).first?.representative.id, "c",
            "A source filter keeps that source's own article on the card")
        expectEqual(
            EventFeedGrouping.entries(for: [a, a, b], events: [], mode: .events).map(\.id), ["a", "b"],
            "No article is listed twice")
        expectEqual(event.sources, ["Wire One", "Daily Two"], "Sources are distinct display names")
        expectEqual(single.coverageText, "1 story · 1 publisher", "Single-publisher coverage names the publisher")

        var buffer = FeedUpdateBuffer()
        expectEqual(
            FeedUpdateBuffer.debouncesReload(isPaging: false, isNewQuery: true, hasStories: false), false,
            "A section's first page is shown without the reload debounce")
        expectEqual(
            FeedUpdateBuffer.debouncesReload(isPaging: false, isNewQuery: false, hasStories: false), false,
            "An empty list fills at once at startup")
        expectEqual(
            FeedUpdateBuffer.debouncesReload(isPaging: false, isNewQuery: false, hasStories: true), true,
            "Revision bursts over a shown list are debounced")
        expectEqual(
            buffer.receive(FeedSnapshot(articles: [a, b]), holding: true, mode: .events), .replaced,
            "The first page always shows")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 7)))
        func dated(_ id: String, _ date: Date) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Story \(id)", link: "https://news.example/\(id)", guid: id, description: "",
                pubDate: date, source: "Wire One")
        }
        var cached = FeedUpdateBuffer()
        cached.replace(with: FeedSnapshot(articles: [dated("y", morning.addingTimeInterval(-10 * 3600))]))
        expectTrue(
            cached.showsOnlyEarlierDays(now: morning, calendar: calendar),
            "A list of only yesterday's stories is not today's reading")
        cached.replace(with: FeedSnapshot(articles: [dated("t", morning.addingTimeInterval(-3600))]))
        expectFalse(
            cached.showsOnlyEarlierDays(now: morning, calendar: calendar), "A story from today keeps the list held")
        expectFalse(
            FeedUpdateBuffer().showsOnlyEarlierDays(now: morning, calendar: calendar), "An empty list is not stale")
        // The new day's page waits for its grouping, then takes an untouched page (#937).
        var handoff = FeedUpdateBuffer.NewDayHandoff()
        expectEqual(
            handoff.holds(showsOnlyEarlierDays: false, isGrouping: true, isTouched: false), nil,
            "A list with today's stories follows the ordinary rule")
        var nextMorning = FeedUpdateBuffer()
        let yesterday = dated("y", morning.addingTimeInterval(-10 * 3600))
        nextMorning.replace(with: FeedSnapshot(articles: [yesterday]))
        let ungrouped = FeedSnapshot(articles: [dated("t1", morning), dated("t2", morning), yesterday])
        handoff.noteRefreshedPage(showsOnlyEarlierDays: true, isGrouping: true)
        let whileGrouping = handoff.holds(showsOnlyEarlierDays: true, isGrouping: true, isTouched: false)
        expectEqual(whileGrouping, true, "Ungrouped stories of the new day do not take the page")
        expectEqual(
            nextMorning.receive(ungrouped, holding: whileGrouping ?? false, mode: .events), .waiting,
            "The earlier edition stays while the new stories are grouped")
        expectEqual(nextMorning.displayed.articles.map(\.id), ["y"], "Nothing ungrouped is shown")
        expectEqual(
            handoff.holds(showsOnlyEarlierDays: false, isGrouping: true, isTouched: false), true,
            "A story updated today in place does not end the wait")
        expectEqual(
            handoff.holds(showsOnlyEarlierDays: false, isGrouping: false, isTouched: true), true,
            "A page the reader scrolled or focused keeps its stories; the new ones wait behind the button")
        // A page read while the grouping ran and received after it ended is still one report a story: the reload
        // that the grouping's end starts reads the grouped page (#937).
        var raced = FeedUpdateBuffer.NewDayHandoff()
        raced.noteRefreshedPage(showsOnlyEarlierDays: true, isGrouping: false, wasGroupingAtFetch: true)
        let readMidGrouping = raced.holds(
            showsOnlyEarlierDays: true, isGrouping: false, wasGroupingAtFetch: true, isTouched: false)
        expectEqual(readMidGrouping, true, "A page read mid-grouping does not take the page once grouping ends")
        var racedMorning = FeedUpdateBuffer()
        racedMorning.replace(with: FeedSnapshot(articles: [yesterday]))
        expectEqual(
            racedMorning.receive(ungrouped, holding: readMidGrouping ?? false, mode: .events), .waiting,
            "The earlier edition stays for the grouped page")
        expectEqual(
            raced.holds(showsOnlyEarlierDays: true, isGrouping: false, isTouched: false), false,
            "The page read after the grouping takes an untouched page")
        // A launch page of stories the grouping has not processed (a refresh cut short by quitting) gives way to the
        // grouped page like an earlier day's page: once, while untouched; a touched page holds as before (#937).
        expectTrue(
            FeedUpdateBuffer.NewDayHandoff.isMostlyUngrouped(unprocessed: 638, of: 649),
            "A page of a refresh cut short waits for its grouping")
        expectFalse(
            FeedUpdateBuffer.NewDayHandoff.isMostlyUngrouped(unprocessed: 3, of: 200),
            "A few leftovers do not make an ordinary launch page give way to a refresh")
        expectFalse(FeedUpdateBuffer.NewDayHandoff.isMostlyUngrouped(unprocessed: 0, of: 0), "An empty page does not")
        var launchPage = FeedUpdateBuffer.NewDayHandoff()
        expectEqual(
            launchPage.holds(showsOnlyEarlierDays: false, isGrouping: false, isTouched: false), nil,
            "A grouped page of today's stories follows the ordinary rule")
        launchPage.notePageAwaitsGrouping()
        expectEqual(
            launchPage.holds(showsOnlyEarlierDays: false, isGrouping: true, isTouched: false), true,
            "While the grouping runs the ungrouped page stays")
        expectEqual(
            launchPage.holds(showsOnlyEarlierDays: false, isGrouping: false, isTouched: true), true,
            "A page the reader scrolled or focused keeps its cards; the grouped page waits behind Show Updates")
        let launchGrouped = launchPage.holds(showsOnlyEarlierDays: false, isGrouping: false, isTouched: false)
        expectEqual(launchGrouped, false, "Once grouped, the grouped page takes an untouched page")
        var launchList = FeedUpdateBuffer()
        let single1 = dated("s1", morning)
        let single2 = dated("s2", morning)
        launchList.replace(with: FeedSnapshot(articles: [single1, single2]))
        let groupedLaunch = FeedSnapshot(
            articles: [single1, single2],
            events: [
                EventFeedSummary(
                    eventID: "e-launch", membershipVersion: 2, seenVersion: nil,
                    members: [
                        EventFeedMember(
                            articleID: "s1", source: "One", title: "s1", date: morning, joinedVersion: 1, isRead: false,
                            isSaved: false),
                        EventFeedMember(
                            articleID: "s2", source: "Two", title: "s2", date: morning, joinedVersion: 2, isRead: false,
                            isSaved: false),
                    ])
            ])
        expectEqual(
            launchList.receive(groupedLaunch, holding: launchGrouped ?? true, mode: .events), .replaced,
            "The grouped page replaces the ungrouped one")
        launchPage.reset()
        expectEqual(
            launchPage.holds(showsOnlyEarlierDays: false, isGrouping: false, isTouched: false), nil,
            "After the replacement the ordinary rule holds new stories again")
        let afterGrouping = handoff.holds(showsOnlyEarlierDays: false, isGrouping: false, isTouched: false)
        expectEqual(afterGrouping, false, "Once grouped, the new day takes an untouched page")
        expectEqual(
            nextMorning.receive(ungrouped, holding: afterGrouping ?? true, mode: .events), .replaced,
            "The grouped page replaces the earlier edition")
        handoff.reset()
        expectEqual(
            handoff.holds(showsOnlyEarlierDays: false, isGrouping: true, isTouched: false), nil,
            "A replaced list starts over")
        let fresh = article("n", source: "Wire One", minutesAgo: 0)
        expectEqual(
            buffer.receive(FeedSnapshot(articles: [fresh, a, b]), holding: true, mode: .events), .waiting,
            "New stories wait while the list is read")
        expectEqual(buffer.displayed.articles.map(\.id), ["a", "b"], "Cards do not move under the reader")
        expectEqual(buffer.newEntryCount(.events), 1, "The indicator counts new cards")
        buffer.applyPending()
        expectEqual(buffer.displayed.articles.map(\.id), ["n", "a", "b"], "Applying shows the update")
        expectTrue(buffer.pending == nil, "Nothing waits after applying")
        let renamed = article("b", source: "Daily Two", minutesAgo: 2, title: "Story b, updated")
        expectEqual(
            buffer.receive(FeedSnapshot(articles: [fresh, renamed]), holding: true, mode: .events), .waiting,
            "Removals wait while the list is read")
        expectEqual(
            buffer.displayed.articles.map(\.id), ["n", "a", "b"],
            "A card read away in Unread stays until the reader updates")
        expectEqual(buffer.displayed.articles[2].title, "Story b, updated", "Listed content refreshes in place")
        expectEqual(buffer.newEntryCount(.events), 0, "An update without new cards is not counted as new")
        expectEqual(
            buffer.receive(FeedSnapshot(articles: [fresh, renamed]), holding: false, mode: .events), .replaced,
            "Updates apply when nobody is reading")

        buffer.replace(with: FeedSnapshot(articles: [a, b, c]))
        expectEqual(
            buffer.receive(FeedSnapshot(articles: [a, b, c], events: [event]), holding: true, mode: .events), .waiting,
            "Regrouping waits while the list is read")
        expectEqual(
            buffer.displayed.entries(.events).map(\.id), ["a", "b", "c"], "Grouping does not change under the reader")
        buffer.applyPending()
        let seen = EventFeedSummary(
            eventID: "e1", membershipVersion: 1, seenVersion: 1, members: [member(a), member(c)])
        expectEqual(
            buffer.receive(FeedSnapshot(articles: [a, b, c], events: [seen]), holding: true, mode: .events),
            .refreshedInPlace, "Event state that moves nothing applies at once")
        expectEqual(buffer.displayed.events.first?.seenVersion, 1, "The card shows the new event state")
        buffer.append([d], events: [seen, single])
        expectEqual(buffer.displayed.articles.map(\.id), ["a", "b", "c", "d"], "Further pages append in order")
        expectEqual(
            buffer.receive(
                FeedSnapshot(articles: [a, b], events: [seen]), holding: true, mode: .events, hasMore: true),
            .refreshedInPlace, "A same-order first page keeps further pages")
        expectEqual(buffer.displayed.articles.count, 4, "Loaded pages stay")
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
        expectEqual(
            EventFeedGrouping.entryIDs(for: articlesWithDupes, events: events, mode: .events),
            EventFeedGrouping.entries(for: articlesWithDupes, events: events, mode: .events).map(\.id),
            "Optimized entryIDs matches entries().map(\\.id) for events"
        )

        // 2. Verify entryIDs matches entries().map(\.id) in non-event mode (publications)
        expectEqual(
            EventFeedGrouping.entryIDs(for: articlesWithDupes, events: events, mode: .publications),
            EventFeedGrouping.entries(for: articlesWithDupes, events: events, mode: .publications).map(\.id),
            "Optimized entryIDs matches entries().map(\\.id) for publications"
        )

        // 3. Reordered articles
        let articlesReordered = [d, c, b, a]
        expectEqual(
            EventFeedGrouping.entryIDs(for: articlesReordered, events: events, mode: .events),
            EventFeedGrouping.entries(for: articlesReordered, events: events, mode: .events).map(\.id),
            "Optimized entryIDs matches for reordered articles"
        )

        // 4. Newly grouped articles
        let eventCD = EventFeedSummary(
            eventID: "e3", membershipVersion: 1, seenVersion: nil, members: [member(c), member(d)])
        expectEqual(
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

            expectEqual(
                EventFeedGrouping.entryIDs(for: syntheticArticles, events: [syntheticEvent], mode: .events),
                EventFeedGrouping.entries(for: syntheticArticles, events: [syntheticEvent], mode: .events).map(\.id),
                "Scaled entryIDs matches entries for \(count) items (.events mode)"
            )
            expectEqual(
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
        let defaults = try #require(UserDefaults(suiteName: suite))
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
        expectEqual(ids.count, 3, "The refresh publishes every report")
        var events = Set<String?>()
        for id in ids { events.insert(try await db.eventID(forArticle: id)) }
        expectEqual(events.count, 1, "Reports collected by one refresh are grouped afterwards")
        expectTrue(try #require(events.first) != nil, "The grouped reports share an event")
        expectTrue(store.eventRevision != revision, "The feed is told to regroup")
        await manager.fetchFeedsAsync()
        await manager.waitForEventClustering()
        expectEqual(try await EventClusterer.run(in: db).processed, 0, "Refreshes leave nothing unmatched")
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
        let defaults = try #require(UserDefaults(suiteName: suite))
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
        expectEqual(control.count, 3, "The quake controls are three reports of one event")
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
        expectEqual(joined, .checked(newReports: 1, failedFeeds: 0, deferredMatching: false), "One report joins")
        expectEqual(joined.statusText, "1 new report joined this story", "The status line counts the new report")

        let unchanged = await manager.checkForUpdates(storyOf: open)
        expectEqual(unchanged.statusText, "No new reports from your sources", "A refresh that adds none says so")

        batches.set(feeds[1], nil, .httpStatus(503))
        let partial = await manager.checkForUpdates(storyOf: open)
        expectEqual(
            partial.statusText, "No new reports from your sources · 1 feed could not be checked",
            "A feed that failed is named, never hidden")
        expectEqual(
            FeedManager.StoryUpdateResult.checked(newReports: 0, failedFeeds: 0, deferredMatching: true).statusText,
            "No new reports yet. Some story matching waits while the Mac saves energy or cools down",
            "Deferred matching claims nothing and names no single cause")
        expectEqual(
            FeedManager.StoryUpdateResult.checked(newReports: 3, failedFeeds: 2, deferredMatching: true).statusText,
            "3 new reports joined this story · 2 feeds could not be checked", "Counts are plural")
        expectEqual(
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
        expectTrue(
            EventMatcher.namesDifferentLocalPlaces(lucknow, bengaluru), "Two states of one country are two stories")
        expectFalse(
            EventMatcher.namesDifferentLocalPlaces(lucknow, pradesh), "A shared place word keeps the signal")
        expectFalse(
            EventMatcher.namesDifferentLocalPlaces(lucknow, countryOnly),
            "A report naming only the country is not vetoed")
        expectFalse(
            EventMatcher.namesDifferentLocalPlaces(countryOnly, countryOnly), "Country-only reports are not vetoed")
        let seriesA = features(
            ["@IN", "lucknow", "delhi"], series: "Delhi Dispatch", seriesTerms: ["delhi", "dispatch"],
            seriesOnlyPlaces: ["delhi"])
        let seriesB = features(
            ["@IN", "bengaluru", "delhi"], series: "Delhi Dispatch", seriesTerms: ["delhi", "dispatch"],
            seriesOnlyPlaces: ["delhi"])
        let template = EventFeatures.sharedSeriesTerms(seriesA, seriesB, samePublisher: true) ?? []
        expectTrue(
            EventMatcher.namesDifferentLocalPlaces(
                seriesA.without(template).keepingStoryPlaces(of: seriesA),
                seriesB.without(template).keepingStoryPlaces(of: seriesB)),
            "Shared series terms are stripped so disjoint story places still veto")
        let seriesDelhi = features(
            ["@IN", "delhi"], series: "Delhi Dispatch", seriesTerms: ["delhi", "dispatch"],
            seriesOnlyPlaces: [])
        expectTrue(
            EventMatcher.namesDifferentLocalPlaces(
                seriesDelhi.without(template).keepingStoryPlaces(of: seriesDelhi),
                seriesB.without(template).keepingStoryPlaces(of: seriesB)),
            "A story naming the series place outside the prefix keeps it so disjoint places still veto")
        let extractedDelhi = EventFeatures(
            title: "Delhi: Severe air pollution returns to Delhi",
            description: "Air quality index crossed dangerous levels.",
            date: Date(timeIntervalSince1970: 1_790_000_000))
        expectEqual(
            extractedDelhi.seriesOnlyPlaces, [],
            "A place named in the series prefix and in the headline is not a series-only place")
        let extractedLucknow = EventFeatures(
            title: "Delhi: Voter turnout in Lucknow",
            description: "Polling opened early on Monday morning.",
            date: Date(timeIntervalSince1970: 1_790_000_000))
        expectTrue(
            extractedLucknow.seriesOnlyPlaces.contains("delhi"),
            "A place named only in the series prefix is recorded as a series-only place")
        expectTrue(EventMatchPolicy.standard.storyCountryPlaceVeto, "The veto is on whenever the signal is")
        expectTrue(EventMatchPolicy.standard.storyCountryKeywords == nil, "The country signal itself stays off")
    }

    /// The act class reads the headline's primary clause (#522): one cue → that act, two acts → unknown, a
    /// consequence only when no act is named. Phrases cover "steps down", "opens fire", "strikes down".
    static func testActClassTable() {
        print("  - Testing act classes of headlines (#522)...")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func act(_ title: String) -> ActClass {
            EventFeatures(title: title, description: "", date: date).actClass
        }
        expectEqual(act("Parliament votes to oust Prime Minister Novak in Ljubljana"), .vote, "A vote")
        expectEqual(act("Thousands protest in Ljubljana after parliament ousts Novak"), .protest, "The protest after")
        expectEqual(act("Commissioner steps down over failed Alabama execution"), .personnel, "Steps down, over …")
        expectEqual(act("Alabama corrections commissioner resigns after botched execution"), .personnel, "Resigns")
        expectEqual(act("Inmate survives botched execution in Alabama"), .casualties, "Survives: a consequence")
        expectEqual(act("Alabama inmate in critical condition after failed execution"), .casualties, "Critical cond.")
        expectEqual(act("Three dead after gunman opens fire at Westfield mall in Sydney"), .casualties, "Toll first")
        expectEqual(act("Sydney mall shooting: police name Westfield gunman"), .attack, "The shooting itself")
        expectEqual(act("Witnesses describe panic as gunman opened fire"), .attack, "Opened fire")
        expectEqual(act("Supreme Court strikes down state social media age law"), .ruling, "Strikes down")
        expectEqual(act("Supreme Court rules Texas age-verification law unconstitutional"), .ruling, "Unconstitut.")
        expectEqual(act("Iraq and Turkey sign oil pipeline supply agreement in Ankara"), .agreement, "An agreement")
        expectEqual(act("Drone attack sets fire to Kirkuk oil field a day after pipeline deal"), .attack, "Act first")
        expectEqual(act("Magnitude 6.1 earthquake strikes Malatya in eastern Turkey"), .disaster, "Strike is no cue")
        expectEqual(act("Rescuers search rubble after Malatya earthquake kills four"), .rescue, "Rescue after it")
        expectEqual(act("Trump says Fed chair should resign at Ohio rally"), .unknown, "Two acts named: unknown")
        expectEqual(act("Siemens to cut 5,000 jobs in energy division"), .unknown, "No cue: unknown")
        expectEqual(act("Hungarian novelist wins 2026 Nobel Prize in Literature"), .unknown, "No cue: unknown")
        expectEqual(act("Zelensky attacks Trump over peace plan"), .unknown, "A verbal attack is no attack")
        expectEqual(act("Israeli troops storm hospital in Gaza City"), .unknown, "Storm is no cue")
        expectEqual(act("Supreme Court dismisses former prime minister's appeal"), .unknown, "Dismiss is no cue")
        expectEqual(act("United States quits Paris climate accord"), .unknown, "Quit is no cue")
        expectEqual(act("Bayrou survives no-confidence motion"), .casualties, "Survives reads as a consequence …")
        expectFalse(ActClass.casualties.conflicts(with: .vote), "… which never vetoes a vote")
        expectFalse(ActClass.ruling.conflicts(with: .casualties), "… or a ruling (\"law survives challenge\")")
        expectTrue(ActClass.vote.conflicts(with: .protest), "Two acts conflict")
        expectFalse(ActClass.vote.conflicts(with: .unknown), "Unknown never conflicts")
        expectFalse(ActClass.disaster.conflicts(with: .rescue), "A rescue follows a disaster")
        expectFalse(ActClass.attack.conflicts(with: .crash), "A deliberate crash is an attack")
        expectFalse(ActClass.crash.conflicts(with: .attack), "… in either order")
        expectFalse(ActClass.casualties.conflicts(with: .rescue), "Two consequence reports agree")
        expectTrue(ActClass.casualties.conflicts(with: .personnel), "A resignation leaves no casualties")
        expectTrue(ActClass.personnel.conflicts(with: .casualties), "… in either order")
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
        expectEqual(fetched, features, "Signals round-trip through JSON unchanged")
        expectEqual(
            try await db.fetchArticleFeatures(articleIDs: ids, version: EventFeatures.storageVersion + 1).count, 0,
            "Another storage version reads nothing")
        try await db.upsertArticleEmbeddings([ids[0]: Array(repeating: 0.05, count: 384)], modelVersion: 1)
        let pair = DatabaseEngine.PairDecision(
            articleID: ids[0], otherArticleID: ids[1], decision: "related-act", reason: "differentAct", score: 0.4)
        try await db.upsertPairDecisions([pair], matcherVersion: EventMatcher.version)
        func count(_ table: String) async throws -> String? {
            try await db.eventRows("SELECT count(*) FROM \(table);").first?[0]
        }
        expectEqual(try await count("pair_assessments"), "1", "The decision is stored once per pair")
        let reversed = DatabaseEngine.PairDecision(
            articleID: ids[1], otherArticleID: ids[0], decision: "match", reason: "match", score: 1)
        try await db.upsertPairDecisions([reversed], matcherVersion: EventMatcher.version)
        expectEqual(try await count("pair_assessments"), "1", "A pair given high ID first is not stored twice")

        // A changed title drops the signals, the embedding and the pair decisions with the match state.
        try await db.upsertArticles([story(1, "Parliament in Ljubljana ousts Prime Minister Novak in late-night vote")])
        expectEqual(
            try await db.fetchArticleFeatures(articleIDs: ids, version: EventFeatures.storageVersion).count, 1,
            "The retitled story's signals are dropped; the other's stay")
        expectEqual(
            try await db.fetchArticleEmbeddings(articleIDs: ids, modelVersion: 1).count, 0, "Its embedding too")
        expectEqual(try await count("pair_assessments"), "0", "And its pair decisions")
        // A pass that read the old headline stores nothing computed from it once a refresh has replaced it.
        try await db.storeClusteringPass(
            DatabaseEngine.ClusteringPassWrites(
                features: features, embeddings: [ids[0]: Array(repeating: 0.05, count: 384)], decisions: [pair],
                readTexts: [ids[0]: first.title + "\n", ids[1]: second.title + "\n"]))
        expectEqual(
            try await db.fetchArticleFeatures(articleIDs: ids, version: EventFeatures.storageVersion).keys.sorted(),
            [ids[1]], "Only the unchanged story's signals are stored")
        expectEqual(
            try await db.fetchArticleEmbeddings(articleIDs: ids, modelVersion: SentenceEmbedder.modelVersion).count, 0,
            "No vector of the old headline")
        expectEqual(try await count("pair_assessments"), "0", "No decision about it either")
        try await db.upsertPairDecisions([pair], matcherVersion: EventMatcher.version)
        try await db.storeClusteringPass(
            DatabaseEngine.ClusteringPassWrites(cleared: [(pair.articleID, pair.otherArticleID)]))
        expectEqual(try await count("pair_assessments"), "0", "A pair that no longer qualifies loses its row")

        try await db.upsertArticleFeatures(features, version: EventFeatures.storageVersion)
        try await db.upsertPairDecisions([pair], matcherVersion: EventMatcher.version)
        try await db.clearArticleEnrichment()
        expectEqual(try await count("article_features"), "0", "Clearing AI analysis clears stored signals")
        expectEqual(try await count("pair_assessments"), "1", "Pair decisions carry no text and stay")
        try await db.eventRows("DELETE FROM articles WHERE id = ?;", [.text(ids[1])])
        expectEqual(try await count("pair_assessments"), "0", "A deleted story takes its pair decisions along")
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
        expectEqual(report.created, 2, "The vote and the protest form two events")
        var events: [String: String] = [:]
        for article in stories {
            let id = try await db.resolvedArticleID(for: article)
            events[article.guid ?? ""] = try await db.eventID(forArticle: id)
        }
        expectTrue(events["acts-1"] != nil && events["acts-1"] == events["acts-2"], "Both vote reports share an event")
        expectTrue(events["acts-3"] != nil && events["acts-3"] == events["acts-4"], "Both protest reports share one")
        expectTrue(events["acts-1"] != events["acts-3"], "The vote and the protest are different events")
        let relatedRows = try await db.eventRows(
            "SELECT count(*) FROM pair_assessments WHERE decision = 'related-act';")
        let related = relatedRows.first?[0]
        expectTrue((related.flatMap(Int.init) ?? 0) >= 1, "A vote/protest pair is recorded as a related act")
        let matchRows = try await db.eventRows("SELECT count(*) FROM pair_assessments WHERE decision = 'match';")
        let matches = matchRows.first?[0]
        expectTrue((matches.flatMap(Int.init) ?? 0) >= 2, "The matching pairs inside each event are recorded")
        if let protestEvent = events["acts-3"], let voteEvent = events["acts-1"] {
            let links = try await db.relatedActEvents(eventID: protestEvent)
            expectEqual(links.map(\.eventID), [voteEvent], "The protest's overview can list the vote as a related act")
            expectEqual(links.first?.title, stories[0].title, "… by its earliest report")
        }
        var resolved: [String] = []
        for article in stories { resolved.append(try await db.resolvedArticleID(for: article)) }
        expectEqual(
            try await db.fetchArticleFeatures(articleIDs: resolved, version: EventFeatures.storageVersion).count, 4,
            "The pass stored every story's signals")

        // Every decision carries what it rested on (#551), and a vetoed pair with shared evidence is kept.
        let featureRows = try await db.eventRows(
            "SELECT decision, features FROM pair_assessments WHERE features IS NOT NULL;")
        expectTrue(featureRows.count >= 3, "Match and related-act rows store their features")
        let decoded = featureRows.compactMap { row in
            row[1].flatMap { try? JSONDecoder().decode(EventPairFeatures.self, from: Data($0.utf8)) }
        }
        expectEqual(decoded.count, featureRows.count, "The features JSON decodes for every row")
        expectTrue(
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
        expectEqual(vetoedRows.count, 1, "A vetoed pair that shares words is recorded once")
        expectEqual(vetoedRows.first?[0], EventConflict.places.rawValue, "… with its conflict as the reason")
        expectTrue(
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
        let exported = try await NewsTests.exportPairReview(snapshot: copy, outputDirectory: directory.path)
        expectEqual(exported, stored, "The export has one row per stored pair")
        let csv = try String(contentsOf: directory.appendingPathComponent("pairs-review.csv"), encoding: .utf8)
        let lines = csv.split(separator: "\n")
        expectEqual(lines.count, exported + 1, "A header and one line per pair")
        expectTrue(lines.first?.hasPrefix("article_id,other_article_id,decision") == true, "Columns are named")
        expectTrue(
            lines.dropFirst().contains { $0.contains("Parliament votes to oust Prime Minister Novak in Ljubljana") },
            "Rows carry the headlines")
        var refused = false
        do {
            _ = try await NewsTests.exportPairReview(
                snapshot: "/Users/x/Library/Containers/app/news.sqlite3", outputDirectory: directory.path)
        } catch {
            refused = true
        }
        expectTrue(refused, "The live library is refused")
        let container = directory.appendingPathComponent("Library/Containers/app")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let live = container.appendingPathComponent("news.sqlite3")
        try Data().write(to: live)
        let link = directory.appendingPathComponent("link.sqlite3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: live)
        expectTrue(StoryCorpus.isLiveLibrary(link.path), "A symlink to the live library is the live library")
        expectTrue(!StoryCorpus.isLiveLibrary(directory.appendingPathComponent("copy.sqlite3").path), "A copy is not")
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linked = directory.appendingPathComponent("Library/Containers/linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        expectTrue(
            StoryCorpus.isLiveLibrary(linked.appendingPathComponent("news.sqlite3").path),
            "A container path that links elsewhere is still the live library")
        var linkRefused = false
        do {
            _ = try await NewsTests.exportPairReview(snapshot: link.path, outputDirectory: directory.path)
        } catch StoryCorpus.Failure.invalid(let message) {
            linkRefused = message.contains("never the live file")
        }
        expectTrue(linkRefused, "The export refuses a symlink to the live library")
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
            expectTrue(false, "The two vote reports form an event")
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
        expectTrue(verdicts >= 2, "Both corrections are recorded")
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
        try await NewsTests.exportTrainingPairs(
            snapshots: path, output: directory.path, corpusPath: corpus.path, verdictsOnly: true)
        let csv = try String(contentsOf: directory.appendingPathComponent("verdicts.csv"), encoding: .utf8)
        // Texts carry newlines, so the rows are checked by their markers rather than split by line.
        expectTrue(
            csv.hasPrefix("label,group,text_a,text_b,pieces_a,pieces_b,weight,marginal\n"),
            "The export has weight and marginal columns (#627)")
        expectEqual(csv.components(separatedBy: ",\"v:").count - 1, verdicts, "One row per verdict")
        expectEqual(csv.components(separatedBy: ",5,").count - 1, verdicts, "Verdict rows weigh five")
        expectTrue(
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
            try await NewsTests.exportTrainingPairs(
                snapshots: path, output: held.path, corpusPath: corpus.path, holdoutPath: heldOut.path,
                verdictsOnly: true)
            expectTrue(false, "An unresolved holdout ID must fail the export")
        } catch StoryCorpus.Failure.invalid(let message) {
            expectTrue(message.contains("do not resolve 1 library holdout IDs"), "Missing holdout IDs are reported")
        }
        expectFalse(
            FileManager.default.fileExists(atPath: held.appendingPathComponent("verdicts.csv").path),
            "An incomplete holdout title set never writes training rows")
        try await NewsTests.exportTrainingPairs(
            snapshots: path + ":" + otherPath, output: held.path, corpusPath: corpus.path, holdoutPath: heldOut.path,
            verdictsOnly: true)
        let heldCSV = try String(contentsOf: held.appendingPathComponent("verdicts.csv"), encoding: .utf8)
        expectEqual(
            heldCSV.components(separatedBy: ",\"v:").count - 1, verdicts - protestVerdicts,
            "The holdout article's verdicts are left out")
        // The gate: re-clustering the copy without corrections re-merges the excluded vote pair, so the harness fails.
        let holdout = directory.appendingPathComponent("holdout.json")
        try Data("[]".utf8).write(to: holdout)
        var failure = ""
        do {
            try await NewsTests.evaluateLibraryHoldout(snapshot: path, holdout: holdout.path)
        } catch {
            failure = "\(error)"
        }
        expectTrue(
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
        expectEqual(groupings.count, 1, "Every input order gives the same stories: \(groupings)")
        expectEqual(
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
        expectEqual(Set(components.component(of: "b")), ["a", "b"], "A component holds every event joined with it")
        expectEqual(components.component(of: "z"), ["z"], "An event in no component is its own")
        components.join("b", "c")
        expectEqual(Set(components.component(of: "a")), ["a", "b", "c", "d"], "Joins are transitive")
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
            expectTrue(false, "The vote and the protest are two events")
            return
        }
        let storyID = try await db.storyID(forEvent: vote)
        expectEqual(storyID, try await db.storyID(forEvent: protest), "Two acts of one story share a story")
        expectEqual(storyID, vote, "The story is named by its earliest event")
        expectTrue(
            report.changedEvents.contains(vote) && report.changedEvents.contains(protest), "Story changes are reported")
        expectEqual(try await db.storyEventIDs(storyID ?? "").sorted(), [vote, protest].sorted(), "Both events belong")
        expectEqual(try await db.storyEventIDs(protest).sorted(), [vote, protest].sorted(), "… from either event")
        expectEqual(
            try await db.storyIDs(forEvents: [vote, protest]), [protest: vote],
            "Notifications map a later event to its story; the story's own event is absent (#740)")
        var summaries = try await db.eventFeedSummaries(forArticles: [ids[0]])
        expectEqual(summaries.count, 1, "One card for the story")
        expectEqual(summaries.first?.eventID, protest, "The card opens the story's newest event")
        expectEqual(
            try await db.relatedActEvents(eventID: protest, limit: .max).map(\.eventID), [vote],
            "The newest event's overview reaches the story's earlier event")
        // "Earlier in This Story" (#671): the story's own earlier events come first and are never capped away by other
        // links; other links fill up to the cap.
        let store = await ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        expectEqual(
            try await store.relatedStoryEvents(eventID: protest).map(\.eventID), [vote],
            "The overview lists the story's earlier event")
        func link(_ id: String) -> RelatedStoryEvent {
            RelatedStoryEvent(eventID: id, articleID: "a-\(id)", title: id, firstPublishedAt: now)
        }
        expectEqual(
            ArticleStore.earlierLinks(
                story: ["s1", "s2"].map { link($0) }, others: ["l1", "l2", "l3", "s1", "l4"].map { link($0) }
            ).map(\.eventID), ["s1", "s2", "l1", "l2", "l3"],
            "Every story event first, then at most three other links, no duplicates")
        expectEqual(summaries.first?.members.count, 4, "All four reports are on the card")
        expectEqual(summaries.first?.membershipVersion, 2, "The story version is the sum of its events' versions")
        expectEqual(summaries.first?.seenVersion, nil, "Never opened")
        expectEqual(try await db.markEventSeen(protest), 2, "Seeing the story through its open event marks every event")
        summaries = try await db.eventFeedSummaries(forArticles: [ids[0]])
        expectEqual(summaries.first?.seenVersion, 2, "Seen versions add up")
        expectFalse(summaries.first?.hasSubstantiveUpdate ?? true, "Nothing new since the reader looked")
        try await db.upsertArticles([
            story(5, "Thousands protest in central Ljubljana after parliament votes to oust Novak", hours: 6.5)
        ])
        _ = try await EventClusterer.run(in: db, now: now.addingTimeInterval(60))
        summaries = try await db.eventFeedSummaries(forArticles: [ids[0]])
        expectEqual(summaries.first?.members.count, 5, "The late protest report joins the story")
        expectTrue(summaries.first?.hasSubstantiveUpdate ?? false, "A report that joined after the look is an update")
        // "Not the Same Event" through the story: the protest report leaves its own event, not the lead's.
        let separated = try await db.separateArticle(ids[2], fromEvent: storyID ?? "")
        expectEqual(separated.id, protest, "The article leaves the event that held it")
        expectEqual(try await db.eventID(forArticle: ids[2]), nil, "It is in no event afterwards")
        let exclusions = try await db.eventExclusions(of: ids[2])
        expectTrue(
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
            expectTrue(false, "The vote and the protest are two events in the exclusion fixture")
            await apart.close()
            await db.close()
            return
        }
        expectEqual(
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
        expectEqual(
            try await apart.fetchArticles(
                limit: nil, options: ArticleFetchOptions(eventID: voteApart, wholeStory: true)
            ).count, storyReports,
            "A story's reports are its events' reports")
        expectTrue(
            try await apart.fetchArticles(limit: nil, options: ArticleFetchOptions(eventID: voteApart)).count
                < storyReports,
            "One event of the story holds fewer reports than the story")
        // A low-energy pass can finish every report while leaving only the story work pending.
        let lastStoryPass = await apart.lastStoryPass
        try await apart.upsertArticles([story(9, "Astronomers discover a distant galaxy", hours: 6)])
        let withoutEnergy = try await EventClusterer.run(
            in: apart, now: now.addingTimeInterval(30), allowsEnergy: false)
        expectEqual(withoutEnergy.processed, 1, "Low energy finishes the unrelated report")
        expectEqual(withoutEnergy.deferred, 0, "No report is deferred in the story-only retry fixture")
        expectTrue(await apart.storyPassPending, "Skipped story work remains pending")
        let idleWithoutEnergy = try await EventClusterer.run(
            in: apart, now: now.addingTimeInterval(40), allowsEnergy: false)
        expectEqual(idleWithoutEnergy.processed, 0, "The next pass has no reports to process")
        expectEqual(await apart.lastStoryPass, lastStoryPass, "Low energy leaves the last completed story pass intact")
        let resumedAt = now.addingTimeInterval(60)
        let resumed = try await EventClusterer.run(in: apart, now: resumedAt, allowsEnergy: true)
        expectEqual(resumed.processed, 0, "Story work resumes with no pending reports")
        expectEqual(await apart.lastStoryPass, resumedAt, "The pending story pass completes when energy returns")
        expectFalse(await apart.storyPassPending, "Completed story work clears the pending marker")
        _ = try await EventClusterer.run(in: apart, now: now.addingTimeInterval(90), allowsEnergy: true)
        expectEqual(await apart.lastStoryPass, resumedAt, "An unchanged library does not repeat completed story work")
        // A reader's exclusion between one vote report and one protest report, both staying in their events. It is
        // recorded after the last completed story pass, as a verdict in the app is, so the next pass re-checks stories.
        let (low, high) = apartIDs[0] < apartIDs[2] ? (apartIDs[0], apartIDs[2]) : (apartIDs[2], apartIDs[0])
        try await apart.eventRows(
            "INSERT INTO event_exclusions(article_id, other_article_id, created_at) VALUES (?, ?, ?);",
            [.text(low), .text(high), .real(now.addingTimeInterval(100).timeIntervalSince1970)])
        _ = try await EventClusterer.run(in: apart, now: now.addingTimeInterval(120))
        expectTrue(
            try await apart.storyID(forEvent: voteApart) != (try await apart.storyID(forEvent: protestApart)),
            "An exclusion across the events vetoes the story link")
        // A story id naming an event that pruning removed is cleared with it.
        try await apart.eventRows("UPDATE events SET story_id = 'pruned-lead' WHERE id = ?;", [.text(protestApart)])
        try await apart.pruneEmptyEvents()
        expectEqual(
            try await apart.eventRows("SELECT story_id FROM events WHERE id = ?;", [.text(protestApart)]).first?[0],
            nil, "A dangling story id is cleared when its lead event is gone")
        await apart.close()
        expectTrue(
            EventClusterer.headline("Elon Musk’s dangerous grip on outer space", names: "musk"),
            "A name in a headline is found across case and possessives")
        expectTrue(EventClusterer.headline("iOS 27.2: Three new features", names: "ios 27.2"), "Multi-word names match")
        expectFalse(EventClusterer.headline("Muskrat numbers rise", names: "musk"), "Only whole words match")
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
            expectEqual(
                try await attach.eventMatchMembers(eventID: single)?.members.count, 1,
                "The attached report stays an event of its own")
            let lead = try await attach.storyID(forEvent: voteEvent)
            expectEqual(try await attach.storyID(forEvent: single), lead, "The report alone joins the story")
            expectTrue(lead != single, "A report alone never names the story")
            expectEqual(
                try await attach.eventFeedSummaries(forArticles: [attachIDs[0]]).first?.members.count, 5,
                "The story card shows the attached report")
            for other in attachIDs {
                let (low, high) = appointmentID < other ? (appointmentID, other) : (other, appointmentID)
                try await attach.eventRows(
                    "INSERT INTO event_exclusions(article_id, other_article_id, created_at) VALUES (?, ?, ?);",
                    [.text(low), .text(high), .real(now.timeIntervalSince1970)])
            }
            _ = try await EventClusterer.run(in: attach, now: now.addingTimeInterval(120))
            expectEqual(
                try await attach.storyID(forEvent: single), single, "An exclusion against the story takes it out")
        } else {
            expectTrue(false, "The appointment is attached to the vote's story as an event of its own")
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
        expectEqual(loneReport.changedEvents.count, 0, "No stories changed when no multi-report events exist (#893)")

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
        expectTrue(createdEventID != nil, "SpaceX stories form an active multi-report event")
        // Canonical country features like @US match candidate reports mentioning demonyms or full country names
        let countryFeature = EventFeatures(
            title: "American diplomat arrives for summit", description: "Diplomatic mission", date: now)
        expectTrue(countryFeature.countries.contains("@US"), "American resolves to canonical @US country feature")
        expectFalse(
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
            expectEqual(
                try await singleDb.storyID(forEvent: boosterEvent), lead,
                "Candidate prefilter retains reports whose specificAnchors overlap allAnchorTerms")
        } else {
            expectTrue(false, "Booster story should have an event and attach to the SpaceX story")
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
        expectTrue(
            confident.events[0] != nil && confident.events[0] == confident.events[1],
            "A confident pair model joins two flood reports that share only the country")
        expectFalse(confident.calls.isEmpty, "The borderline flood pair is sent to the pair model")
        expectFalse(
            confident.calls.contains { $0.contains("oust Prime Minister Novak") && $0.contains("Thousands protest") },
            "A pair with a hard conflict (two different acts) is never sent to the model")
        expectTrue(
            confident.calls.allSatisfy { !$0.hasPrefix("gap ") },
            "With the prefix off (the default) the model reads the plain texts")
        let prefixed = try await clustered(0.99, prefix: true)
        expectTrue(
            prefixed.calls.allSatisfy { $0.hasPrefix("gap ") && $0.contains(" | gap ") },
            "With the prefix on (#626) both inputs carry the gap and publisher words")
        let unsure = try await clustered(EventMatchPolicy.standard.pairModelThreshold - 0.01)
        expectEqual(unsure.events[0], nil, "Below the threshold the flood reports stay apart")
        let unavailable = try await clustered(nil)
        expectEqual(unavailable.events[0], nil, "Without the model the matcher decides as before")

        // Under the energy rule (#534) neither model runs; the pair waits for a pass with energy.
        let lowPower = DatabaseEngine(path: ":memory:")
        try await lowPower.open()
        try await lowPower.upsertArticles(stories)
        let rulesOnly = try await EventClusterer.run(
            in: lowPower, now: start.addingTimeInterval(4 * 3600), allowsEnergy: false,
            scoring: EventClusterScoring(pairProbability: { _, _ in
                expectTrue(false, "The pair model is not asked without energy")
                return 0.99
            }))
        var ids: [String] = []
        for article in stories { ids.append(try await lowPower.resolvedArticleID(for: article)) }
        expectEqual(try await lowPower.eventID(forArticle: ids[0]), nil, "The rules alone leave the flood pair apart")
        expectTrue(
            try await lowPower.fetchArticleEmbeddings(articleIDs: ids, modelVersion: SentenceEmbedder.modelVersion)
                .isEmpty, "No embedding is computed without energy")
        expectEqual(rulesOnly.deferred, 2, "Both flood reports wait for a pass with energy")
        let againWithoutEnergy = try await EventClusterer.run(
            in: lowPower, now: start.addingTimeInterval(5 * 3600), allowsEnergy: false,
            scoring: EventClusterScoring(pairProbability: { _, _ in
                expectTrue(false, "Deferred rows are not read again without energy")
                return 0.99
            }))
        expectEqual(againWithoutEnergy.processed, 0, "Deferred rows wait for energy instead of being re-read")
        let withEnergy = try await EventClusterer.run(
            in: lowPower, now: start.addingTimeInterval(6 * 3600), allowsEnergy: true,
            scoring: EventClusterScoring(pairProbability: { _, _ in 0.99 }))
        expectTrue(withEnergy.processed >= 2, "A pass with energy reads the deferred rows again")
        let joinedFlood = try await lowPower.eventID(forArticle: ids[0])
        let joinedFloodPartner = try await lowPower.eventID(forArticle: ids[1])
        expectTrue(
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
            expectTrue(false, "The rules keep the vote and the protest apart")
            return
        }
        try await db.includeEvent(vote, inEvent: protest)
        // The combination is the reader's change: it is already seen, without a second call to race a clustering pass.
        var card = try await db.eventFeedSummaries(forArticles: [ids[0]]).first
        expectEqual(card?.seenVersion, card?.membershipVersion, "Same Event records the combined version as seen")
        expectFalse(card?.hasSubstantiveUpdate ?? true, "The combination itself is not an update")
        expectEqual(try await event(0), protest, "Same Event moves the related event's reports into this one")
        expectEqual(try await db.resolvedEventID(vote), protest, "The absorbed event forwards to the survivor")
        expectEqual(
            try await db.eventInclusions(for: [ids[0]])[ids[0]], Set([ids[2], ids[3]]),
            "Every pair across the two events is recorded")

        // A retitled vote report is matched again; the rules alone would split it off, the inclusion keeps it.
        let retitled = story(1, "Parliament votes to oust Prime Minister Novak in Ljubljana late at night", hours: 0)
        try await db.upsertArticles([retitled])
        _ = try await EventClusterer.run(in: db, now: now.addingTimeInterval(60))
        expectEqual(try await event(0), protest, "The included report stays after the next pass")
        // A new report of either side still joins: it matches the vote reports, which are one event with the protest.
        let later = story(5, "Parliament in Ljubljana votes to oust Novak as prime minister", hours: 2)
        try await db.upsertArticles([later])
        ids.append(try await db.resolvedArticleID(for: later))
        _ = try await EventClusterer.run(in: db, now: now.addingTimeInterval(90))
        expectEqual(try await event(4), protest, "A later vote report joins the combined event")
        card = try await db.eventFeedSummaries(forArticles: [ids[0]]).first
        expectTrue(card?.hasSubstantiveUpdate ?? false, "A report that joined after Same Event still shows Updated")

        // Separating it later wins over the inclusion, and including it again wins over the separation.
        try await db.separateArticle(ids[0], fromEvent: protest)
        expectEqual(try await db.eventInclusions(for: [ids[0]])[ids[0]] ?? [], [], "Separation drops its inclusions")
        expectEqual(
            try await db.eventExclusions(of: ids[0]), Set([ids[2], ids[3]]),
            "… and excludes only the side it was combined with, not the other vote reports")
        _ = try await EventClusterer.run(in: db, now: now.addingTimeInterval(120))
        expectTrue(try await event(0) != protest, "A separated report never rejoins the event by itself")
        let alone = try await db.createEvent(memberArticleIDs: [ids[0]])
        try await db.includeEvent(alone.id, inEvent: protest)
        expectEqual(
            try await db.eventExclusions(of: ids[0]).intersection([ids[2], ids[3]]), [],
            "Including it again drops the exclusions")
        expectEqual(try await event(0), protest, "… and the report is back in the event")
        await db.close()
    }

    /// Bounded calibration (#629): dormant below 50 verdicts, never more than ±0.05 off the cutoff, gone when the stored
    /// pair signals are cleared, and a clean synthetic verdict replay.
    static func testPairCalibration() async throws {
        print("  - Testing the bounded pair-model calibration from reader verdicts (#629)...")
        let base = EventMatchPolicy.standard.pairModelThreshold
        expectTrue(PairCalibration.fit(NewsTests.syntheticVerdicts(49)) == nil, "Dormant below 50 verdicts")
        let oneAnswer = NewsTests.syntheticVerdicts(80).map { PairCalibration.Row(features: $0.features, same: true) }
        expectTrue(PairCalibration.fit(oneAnswer) == nil, "Verdicts with one answer fit nothing")
        guard let calibration = PairCalibration.fit(NewsTests.syntheticVerdicts(120)) else {
            return expectTrue(false, "120 verdicts with both answers fit a calibration")
        }
        for features in [[0.0, 0, 0, 0, 0], [1.0, 1, 1, 1, 1], [0.9, 0.7, 0.4, 0, 1], [0.9, 0.7, 0.4, 1, 1]] {
            let cutoff = calibration.cutoff(base, features)
            expectTrue(abs(cutoff - base) <= PairCalibration.maximumShift + 1e-12, "The cutoff moves at most ±0.05")
        }
        let near = PairCalibration.features(pairModel: 0.9, cosine: 0.7, sharedSpecific: 2, gapHours: 2, sameAct: true)
        let far = PairCalibration.features(pairModel: 0.9, cosine: 0.7, sharedSpecific: 2, gapHours: 48, sameAct: true)
        expectTrue(calibration.cutoff(base, near) < calibration.cutoff(base, far), "It learns what the verdicts say")
        let replay = NewsTests.verdictReplay(NewsTests.syntheticVerdicts(120))
        expectTrue(replay.fitted && replay.calibrated >= replay.bare, "The synthetic verdict replay is clean")

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
        expectEqual(rows.map(\.same).sorted { !$0 && $1 }, [false, true], "One row per verdict with a stored signal")
        expectEqual(rows.first?.features.count, 5, "Five features per verdict")
        expectEqual(try await db.calibrationRows(limit: 1).count, 1, "The limit bounds the rows read")
        try await db.clearArticleEnrichment()
        let cleared = try await db.calibrationRows()
        expectEqual(cleared.count, 0, "Clear AI Analysis empties the calibration's input")
        expectTrue(PairCalibration.fit(cleared) == nil, "… so the calibration is dormant again")
        expectEqual(
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
            from: Data(
                contentsOf: nativeRepositoryRoot.appendingPathComponent(
                    "Tests/Fixtures/story-corpus/story-regressions-v1.json")))
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
        expectTrue(failures.isEmpty, "Authored story regressions changed (\(failures.count) pairs)")
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
            from: Data(
                contentsOf: nativeRepositoryRoot.appendingPathComponent(
                    "Tests/Fixtures/story-corpus/matcher-regressions-v1.json")))
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
        var metrics = NewsTests.EventCorpusMetrics()
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
        expectTrue(
            (rulesOnly && deferred > 0) || metrics.truePositives >= fixture.expected.minimumTruePositives,
            "Authored corpus true positives fell below the recorded floor (\(metrics.truePositives))")
        expectTrue(
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
        let window = try await NewsTests.recentLibraryRows(windowDB, now: pinned)
        expectEqual(window.newest, pinned, "The pinned clock is independent of the snapshot's newest report")
        expectEqual(window.rows.map(\.id), ["window-1", "window-2"], "Recent totals use the closed pinned window")
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
        expectEqual(processed, [2_000], "Corpus replay uses the production per-pass article limit")
        expectEqual(boundedMemberships.count, 2_001, "Budget-deferred articles remain observable as singletons")
        print("  - Testing the labeled event corpus harness on the synthetic control set...")
        expectTrue(NewsTests.EventCorpusMetrics().precision == nil, "No predicted positives cannot establish precision")
        expectTrue(NewsTests.EventCorpusMetrics().recall == nil, "No labeled positives cannot establish recall")
        // The 9 October judge-off replay: 21 TP, 1 FP, 17 FN (#307).
        let replay = NewsTests.EventCorpusMetrics(truePositives: 21, falsePositives: 1, falseNegatives: 17).line
        expectTrue(
            replay.contains("precision 0.955 [95% 0.782–0.992]"), "Precision carries its Wilson 95% interval: \(replay)"
        )
        expectTrue(
            replay.contains("recall 0.553 [95% 0.397–0.699]"), "Recall carries its Wilson 95% interval: \(replay)")
        expectEqual(
            NewsTests.EventCorpusMetrics().line, "precision n/a (TP 0, FP 0), recall n/a (FN 0)",
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
        let sealed = try await NewsTests.evaluateEventCorpus(path: file.path)
        expectTrue(sealed["holdout"] == nil, "Default corpus evaluation leaves holdout sealed")
        let metrics = try await NewsTests.evaluateEventCorpus(path: file.path, selectedSplit: "holdout")
        guard let holdout = metrics["holdout"] else { return expectTrue(false, "The holdout split is evaluated") }
        expectEqual(holdout.falsePositives, 0, "The synthetic control set has no false merges")
        expectTrue(holdout.truePositives >= 3, "The synthetic earthquake reports are linked")

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
        let identityMetrics = try await NewsTests.evaluateEventCorpus(path: identityFile.path)
        expectEqual(
            identityMetrics["tune"]?.truePositives, 1, "Observed URLs resolve copies even when their titles differ")
        expectEqual(
            identityMetrics["tune"]?.falsePositives, 0, "URL replay preserves document identity without false merges")

        let spanish = [
            "id": "spanish",
            "title": "Las autoridades municipales aprueban la construcción de una nueva biblioteca pública",
            "source": "Corpus", "published": formatter.string(from: Date()), "split": "tune",
        ]
        try JSONSerialization.data(withJSONObject: ["articles": identityItems + [spanish]]).write(to: identityFile)
        let english = try await NewsTests.evaluateEventCorpus(
            path: identityFile.path, language: "en", outputDirectory: directory.path)
        expectEqual(english["tune"]?.truePositives, 1, "English replay preserves observed document identity")
        let output = directory.appendingPathComponent("event-replay-tune.json")
        let receipt = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        expectEqual(
            (receipt["memberships"] as? [String: String])?.count, 2, "Other languages never enter the English replay")
        expectTrue(
            (receipt["passes"] as? [[String: Int]])?.isEmpty == false,
            "Saved predictions include clustering pass counts")
        do {
            _ = try await NewsTests.evaluateEventCorpus(
                path: identityFile.path, language: "en", outputDirectory: directory.path)
            expectTrue(false, "A replay must not overwrite its previous evidence")
        } catch {
            // Existing evidence is rejected before scoring.
        }

        print("  - Testing the native embedding comparison (#127)...")
        let now = Date()
        let controls = EventControlSet.articles(now: now, root: fixtureRoot)
        let memberships = try await StoryCorpus.eventMemberships(articles: controls.map(\.article))
        var comparisonItems = controls.map {
            NewsTests.EventEmbeddingComparison.Item(
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

        let unsupported = NewsTests.EventEmbeddingComparison(
            items: comparisonItems, thresholds: [2], model: { _ in nil })
        expectEqual(unsupported.notCompared["cross-language"], 4, "Vectors from different languages are never compared")
        expectEqual(
            unsupported.notCompared["outside time window"], 3, "Pairs the matcher cannot link in time are not compared")
        expectEqual(
            unsupported.notCompared["no sentence embedding"], 3, "A language without a sentence embedding abstains")
        expectTrue(unsupported.scores.isEmpty, "Nothing is scored without vectors")
        expectTrue(
            unsupported.languages.values.allSatisfy { $0.dimension == nil }, "Missing models are reported per language")
        expectEqual(
            NewsTests.EventEmbeddingComparison.cosineDistance([1, 0], [0, 0]), 2, "A zero vector is never close")
        expectTrue(
            abs(NewsTests.EventEmbeddingComparison.cosineDistance([1, 2], [2, 4])) < 1e-12,
            "Parallel vectors have no distance")

        let support = Set(FeedCatalog.feeds.map(\.language)).sorted().map { code in
            "\(code) "
                + (NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: code)).map { "\($0.dimension)" } ?? "none")
        }
        print("    Sentence embeddings for catalog languages on this system: \(support.joined(separator: ", "))")
        let native = NewsTests.EventEmbeddingComparison(items: comparisonItems, thresholds: [0.5, 2])
        guard native.languages["en"]?.dimension != nil, let all = native.scores["all"] else {
            return print("    No English sentence embedding on this system; native scoring not exercised")
        }
        expectEqual(native.notCompared["cross-language"], 4, "Cross-language pairs stay out with native models")
        expectEqual(all.deterministic.truePositives, 3, "Deterministic links are scored on the same pairs")
        expectEqual(all.deterministic.falsePositives, 0, "The control set has no deterministic false merges")
        for row in all.rows {
            expectTrue(
                row.veto.truePositives <= all.deterministic.truePositives
                    && row.veto.falsePositives <= all.deterministic.falsePositives,
                "A veto only removes deterministic links")
            expectTrue(row.rescue.truePositives >= all.deterministic.truePositives, "A rescue only adds links")
        }
        expectEqual(all.rows.last?.embedding.falseNegatives, 0, "The widest cutoff links every comparable labeled pair")
    }

    static func testCapturedFingerprintReview() throws {
        print("  - Testing the private captured-feed fingerprint review (#102)...")
        let request = StoryCorpus.PageRequest(id: "doc-0001", url: "https://example.com/article")
        expectTrue(StoryCorpus.validPageRequests([request]), "A bounded uniquely identified page is accepted")
        expectFalse(StoryCorpus.validPageRequests([]), "An empty evidence request is rejected")
        expectFalse(
            StoryCorpus.validPageRequests([request, request]), "Repeated IDs cannot overwrite publisher evidence")
        expectFalse(
            StoryCorpus.validPageRequests([.init(id: "../outside", url: request.url)]),
            "Evidence IDs cannot escape the private directory")
        expectFalse(
            StoryCorpus.validPageRequests((0...500).map { .init(id: "doc-\($0)", url: request.url) }),
            "Evidence collection stays bounded")
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("news-capture-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        defer { try? fileManager.removeItem(at: directory) }

        func rejects(_ path: String) -> Bool { (try? StoryCorpus.privateDirectory(path)) == nil }
        expectTrue(rejects("relative/captures"), "Relative capture directories are rejected")
        expectTrue(
            rejects(directory.appendingPathComponent("missing").path), "A missing directory is not created implicitly")
        expectTrue(rejects(fileManager.currentDirectoryPath), "Publisher text never lands in the checkout")
        let shared = directory.appendingPathComponent("shared")
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
        expectTrue(rejects(shared.path), "A directory other users can read is rejected")
        expectFalse(rejects(directory.path), "A private directory is accepted")

        let hosts = (0..<64).map { "publisher\($0).example" }
        guard let tuningHost = hosts.first(where: { StoryCorpus.captureSplit(host: $0) == "tuning" }),
            let holdoutHost = hosts.first(where: { StoryCorpus.captureSplit(host: $0) == "holdout" })
        else {
            return expectTrue(false, "Both splits are reachable")
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
        expectEqual(roundTrip, original, "A parsed article is captured unchanged")
        expectEqual(
            ArticleIdentity.publisherTextFingerprints(roundTrip.article),
            ArticleIdentity.publisherTextFingerprints(parsed),
            "Captured items reproduce the production fingerprint")
        expectTrue(
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
        expectEqual(permissions?.intValue, 0o600, "Captured publisher text is readable only by its owner")
        expectTrue(
            (try? StoryCorpus.writeCapture(
                StoryCorpus.Capture(version: 1, capturedAt: 1_800_000_100, items: []), in: directory)) == nil,
            "An existing capture is never overwritten")
        try StoryCorpus.writeCapture(
            StoryCorpus.Capture(version: 1, capturedAt: 1_800_000_200, items: [original, undated]), in: directory)

        var review = try StoryCorpus.reviewCaptures(directory: directory.path, holdout: false)
        expectEqual(review.captureFiles, 2, "Every capture file is read")
        expectEqual(
            review.observations, 7,
            "Repeated observations count once, parked languages are excluded and holdout hosts stay sealed")
        expectEqual(review.eligible, 5, "Short and undated items are not fingerprinted")
        expectEqual(review.eligibleDocuments, 3, "Copies at one canonical URL count as one eligible document")
        expectEqual(review.eligibleByLanguage["de"], nil, "Parked captures cannot inflate the release denominator")
        expectEqual(review.sameURLShared, 1, "A stripped tracking parameter is the same URL")
        expectEqual(review.sameURLDisjoint, 2, "An edited body at the same URL no longer shares a fingerprint")
        expectEqual(review.total.candidates, 1, "One different-URL pair shares a fingerprint")
        expectEqual(review.total.unlabeled, 1, "Unreviewed candidates abstain")
        expectTrue(review.total.precision == nil && !review.gatePassed, "No adjudication, no precision")
        let sheet = try Data(contentsOf: directory.appendingPathComponent("review-tuning.json"))
        let key = StoryCorpus.capturePairKey(original.article.normalizedLink, amp.article.normalizedLink)
        expectTrue(String(decoding: sheet, as: UTF8.self).contains(key), "The review sheet lists the candidate pair")
        expectFalse(
            String(decoding: sheet, as: UTF8.self).contains("Captured report sentence"),
            "The review sheet carries no body text")
        expectFalse(
            fileManager.fileExists(atPath: directory.appendingPathComponent("review-holdout.json").path),
            "The holdout stays sealed")

        let readiness = try StoryCorpus.reviewCaptures(directory: directory.path, holdout: true, readinessOnly: true)
        expectEqual(readiness.eligibleDocuments, 2, "Readiness counts distinct eligible holdout documents")
        expectEqual(readiness.report["scoringPerformed"] as? Bool, false, "Readiness never scores")
        expectTrue(
            readiness.report["differentURLCandidates"] == nil && readiness.report["falseMergeUpperBound95"] == nil,
            "Readiness exposes no pair outcomes or observed error bound")
        expectFalse(readiness.gatePassed, "Sample counts alone cannot pass acceptance")
        expectFalse(
            fileManager.fileExists(atPath: directory.appendingPathComponent("review-holdout.json").path),
            "Readiness leaves the holdout sealed")

        let holdoutKey = StoryCorpus.capturePairKey(
            holdoutPair[0].article.normalizedLink, holdoutPair[1].article.normalizedLink)
        let labelsFile = directory.appendingPathComponent("labels.json")
        try JSONSerialization.data(withJSONObject: [key: "same_document", holdoutKey: "same_document"]).write(
            to: labelsFile)
        review = try StoryCorpus.reviewCaptures(directory: directory.path, holdout: false)
        expectEqual(
            [review.total.sameDocument, review.total.different, review.total.unlabeled], [1, 0, 0],
            "Labels are applied to their split")
        expectEqual(review.byLanguage["en"]?.precision, 1, "Precision is reported per language")
        expectEqual(review.bySource["Publisher"]?.candidates, 1, "Candidates are reported per source")
        expectFalse(review.gatePassed, "Tuning never passes the release gate")
        review = try StoryCorpus.reviewCaptures(directory: directory.path, holdout: true)
        expectEqual(
            [review.observations, review.total.candidates, review.total.sameDocument], [2, 1, 1],
            "The holdout is scored when unsealed")
        expectFalse(review.gatePassed, "Two eligible documents are too little support for the gate")
        try JSONSerialization.data(withJSONObject: [key: "maybe"]).write(to: labelsFile, options: .atomic)
        expectEqual(
            try StoryCorpus.reviewCaptures(directory: directory.path, holdout: true, readinessOnly: true)
                .eligibleDocuments,
            2, "Readiness does not read adjudication labels")
        expectTrue(
            (try? StoryCorpus.reviewCaptures(directory: directory.path, holdout: false)) == nil,
            "Unknown labels are rejected")

        func metrics(_ same: Int, _ different: Int, unlabeled: Int = 0) -> StoryCorpus.CaptureMetrics {
            StoryCorpus.CaptureMetrics(
                candidates: same + different + unlabeled, sameDocument: same, different: different)
        }
        func passes(_ metrics: StoryCorpus.CaptureMetrics, documents: Int = 1_000, split: String = "holdout") -> Bool {
            StoryCorpus.captureGatePassed(split: split, metrics: metrics, eligibleDocuments: documents)
        }
        expectTrue(passes(metrics(99, 1)), "99% over 100 adjudicated candidates passes")
        expectFalse(passes(metrics(98, 2)), "Two errors in 100 fail")
        expectTrue(
            passes(metrics(0, 0), documents: 381), "Without matches, 381 eligible documents bound false merges at 1%")
        expectFalse(passes(metrics(0, 0), documents: 380), "Fewer eligible documents cannot bound false merges at 1%")
        expectFalse(passes(metrics(5, 1), documents: 381), "One false merge needs more eligible support")
        expectFalse(passes(metrics(150, 0, unlabeled: 1)), "Unreviewed candidates block the gate")
        expectFalse(passes(metrics(200, 0), split: "tuning"), "Tuning never passes the gate")
        expectTrue(
            abs((metrics(100, 0).precisionLowerBound ?? 0) - 0.963) < 0.001,
            "The Wilson bound reports sampling uncertainty")
    }
}
