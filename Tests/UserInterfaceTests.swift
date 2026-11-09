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

/// The UserInterface suites of the regression runner; `UserInterfaceTests.run()` is this atom's entry point.
enum UserInterfaceTests {
    static func run() async throws { try await NewsTests.runUserInterfaceTests() }
}

extension NewsTests {
    static func runUserInterfaceTests() async throws {
        let fixtureRoot = defaultFixtureRoot
        let tests: [(name: String, run: () async throws -> Void)] = [
            ("testUserMuting", { try await testUserMuting() }),
            ("testSmartBinders", { try await testSmartBinders() }),
            ("testNavigationCommands", { await testNavigationCommands() }),
            ("testStoryExport", { try await testStoryExport() }),
            ("testStoryImages", { try await testStoryImages(fixtureRoot: fixtureRoot) }),
            ("testFiniteBriefing", { try await testFiniteBriefing() }),
            ("testDockBadgeCount", { testDockBadgeCount() }),
            ("testSidebarUnreadBadgeCopy", { testSidebarUnreadBadgeCopy() }),
            ("testThemeBindingWritesOnlyChanges", { await testThemeBindingWritesOnlyChanges() }),
            ("testBriefingBoardLayout", { testBriefingBoardLayout() }),
            ("testDesignSystemAndArticleFilter", { await testDesignSystemAndArticleFilter() }),
            ("testNewsURLParserAndSchemeRouting", { await testNewsURLParserAndSchemeRouting() }),
            ("testAppIntentsExecutionAndValidation", { await testAppIntentsExecutionAndValidation() }),
            ("testAppShortcutsProviderDeclarations", { await testAppShortcutsProviderDeclarations() }),
            ("testSpotlightSavedStoriesIndexing", { try await testSpotlightSavedStoriesIndexing() }),
            ("testMenuBarExtraSettingsAndUnreadCount", { await testMenuBarExtraSettingsAndUnreadCount() }),
            ("testOnboardingAndPermissionTiming", { await testOnboardingAndPermissionTiming() }),
            ("testStoryBannerRoute", { try await testStoryBannerRoute() }),
            ("testFeedArticleWrapContextNavigation", { await testFeedArticleWrapContextNavigation() }),
            ("testCardImagePrefetchFirstPaint", { await testCardImagePrefetchFirstPaint() }),
            ("testStoryQuickLookPreview", { await testStoryQuickLookPreview() }),
        ]
        try await runSuite(tests)
    }

    static func testSidebarUnreadBadgeCopy() {
        print("  - Testing the sidebar Unread badge copy...")
        assertEqual(AppSettings.unreadBadgeCopy(0), nil, "Nothing unread shows no badge")
        assertEqual(AppSettings.unreadBadgeCopy(7), "7", "A small count shows as it is")
        assertEqual(AppSettings.unreadBadgeCopy(99), "99", "The cap itself shows")
        assertEqual(AppSettings.unreadBadgeCopy(100), "99+", "A backlog past the cap reads 99+")
        assertEqual(AppSettings.unreadBadgeCopy(1013), "99+", "However large it is")
    }

    @MainActor
    static func testThemeBindingWritesOnlyChanges() async {
        print("  - Testing that the theme bindings publish only a change...")
        let suite = testDefaultsSuite("test.theme-binding")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let theme = ThemeManager(defaults: defaults)
        var publishes = 0
        let observation = theme.objectWillChange.sink { publishes += 1 }
        defer { observation.cancel() }
        let appearance = theme.binding(\.appearance)
        appearance.wrappedValue = .system
        assertEqual(publishes, 0, "Restating the current appearance publishes nothing")
        appearance.wrappedValue = .dark
        assertEqual(theme.appearance, .dark, "A new appearance is written")
        assertTrue(publishes > 0, "A new appearance publishes")
        publishes = 0
        theme.binding(\.autoHideRead).wrappedValue = false
        assertEqual(publishes, 0, "Restating Auto-Hide Read publishes nothing")
        theme.binding(\.autoHideRead).wrappedValue = true
        assertTrue(theme.autoHideRead, "A new Auto-Hide Read is written")
    }

    @MainActor
    static func testUserMuting() async throws {
        print("  - Testing user-controlled source and topic muting...")
        assertEqual(
            MuteRules.words("Art's covid-19 Zürich").map(String.init), ["art", "s", "covid", "19", "zürich"],
            "Topic words keep diacritics and split on everything but letters and digits")
        assertEqual(
            MuteRules.foldedWords("Art's covid-19 Zürich ZURICH"), ["art", "s", "covid", "19", "zurich", "zurich"],
            "Folded words drop case and diacritics for text-to-text matching")
        var rules = MuteRules()
        assertEqual(
            rules.addSource("https://www.Example.com/world?id=1"), "example.com", "A URL mutes its publisher host")
        assertEqual(rules.addSource("EXAMPLE.com"), nil, "A host is muted once")
        assertEqual(MuteRules.host("not a host"), nil, "Text with spaces is not a host")
        assertEqual(MuteRules.host("localhost"), nil, "A muted host needs a domain")
        assertEqual(MuteRules.host("news..example.com"), nil, "Empty host labels are rejected")
        assertTrue(rules.mutesSource(link: "https://news.example.com/a"), "A host covers its subdomains")
        assertFalse(
            rules.mutesSource(link: "https://badexample.com/a"), "A host does not cover another name ending in it")
        assertFalse(
            rules.mutesSource(link: "https://example.com.attacker.net/a"),
            "A host does not cover a name that only contains it")
        assertFalse(rules.mutesSource(link: ""), "A story without a document URL is never source-muted")
        assertFalse(rules.mutesTopic(title: "Example.com launches", description: ""), "Source rules never match words")

        assertEqual(
            rules.addTopic("  Climate   change "), "Climate change",
            "Topics keep the reader's words with whitespace collapsed")
        assertEqual(rules.addTopic("CLIMATE CHANGE"), nil, "A topic is muted once in any letter case")
        assertEqual(rules.addTopic("?!"), nil, "A topic needs a word")
        assertEqual(
            rules.addTopic(String(repeating: "a", count: MuteRules.topicLength + 1)), nil,
            "Overlong topics are rejected")
        for topic in ["art", "Війна", "covid-19", "cafe"] {
            assertEqual(rules.addTopic(topic), topic, "Topic \(topic) is added")
        }
        func mutesTopic(_ title: String, _ description: String = "") -> Bool {
            rules.mutesTopic(title: title, description: description)
        }
        assertTrue(mutesTopic("Modern art fair opens"), "A topic matches a whole word in the headline")
        assertTrue(
            mutesTopic("Gallery news", "The Art's new home"), "Topics match in the feed summary and before apostrophes")
        assertFalse(mutesTopic("Artist wins prize"), "A topic never matches inside a longer word")
        assertTrue(mutesTopic("Climate-change protests grow"), "Phrases match across punctuation")
        assertFalse(mutesTopic("Climate policy change"), "Phrase words must be adjacent and in order")
        assertTrue(mutesTopic("ВІЙНА триває"), "Matching ignores letter case beyond ASCII")
        assertFalse(mutesTopic("Війни не буде"), "Other word forms are other words")
        assertTrue(mutesTopic("COVID 19 cases fall"), "A hyphenated topic matches the same words")
        assertFalse(mutesTopic("Best café in town"), "Diacritics are significant")
        assertFalse(rules.mutesSource(link: "https://art.org/climate-change"), "Topic rules never match links")
        assertEqual(
            rules.matchedTopics(title: "Art and climate change", description: ""), ["Climate change", "art"],
            "Each covering topic is reported")
        assertEqual(MuteRules(sources: rules.sources, topics: rules.topics), rules, "Stored rules restore unchanged")

        // A topic set mutes its fixed phrases with one switch (#590); whole words keep "Dubai" and "aid" visible.
        let aiSet = MuteTopicSet.artificialIntelligence.id
        var sets = MuteRules()
        assertTrue(sets.addTopicSet(aiSet), "A known topic set switches on")
        assertFalse(sets.addTopicSet(aiSet), "A topic set switches on once")
        assertFalse(sets.addTopicSet("unknown-set"), "Unknown sets are ignored")
        assertFalse(sets.isEmpty, "A switched-on set is a muting rule")
        assertTrue(
            sets.mutesTopic(title: "OpenAI says its agents disabled their own safety monitors", description: ""),
            "A set phrase matches as a whole word in the headline")
        assertTrue(sets.mutesTopic(title: "Firms rush to adopt A.I. tools", description: ""), "A.I. matches")
        assertFalse(sets.mutesTopic(title: "Dubai aid flight lands in Gaza", description: ""), "Dubai and aid stay")
        assertFalse(sets.mutesTopic(title: "Claudette reopens", description: "Said the mayor"), "Longer words stay")
        assertEqual(sets.matchedTopicSets(title: "AI startup raises funds", description: ""), [aiSet], "Sets report")
        assertEqual(MuteRules(topicSets: sets.topicSets), sets, "Stored sets restore unchanged")
        sets.removeTopicSet(aiSet)
        assertTrue(sets.isEmpty, "Switching a set off removes every phrase")

        // SQLite applies muting before LIMIT and reports what it hid.
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        func story(_ index: Int, _ link: String, _ title: String, _ description: String = "") -> FeedArticle {
            FeedArticle(
                title: title, link: link, guid: "mute-\(index)", description: description,
                pubDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 60), source: "Publisher")
        }
        let stories = [
            story(0, "https://www.example.com/0", "Example lead"),
            story(1, "https://news.example.com/1", "Example subdomain"),
            story(2, "https://other.org/2", "Climate change summit"),
            story(3, "https://other.org/3", "Budget passes", "Markets react"),
            story(4, "https://other.org/4", "Artist profile", "A gallery opening"),
            story(5, "https://other.org/5", "Election results", "Art market shrugs"),
            story(6, "https://other.org/6", "Weather"),
        ]
        try await db.upsertArticles(stories)
        let muting = MuteRules(sources: ["example.com"], topics: ["Climate change", "art"])
        let firstPage = try await db.fetchArticles(limit: 1, muting: muting)
        assertEqual(
            firstPage.map(\.id), [stories[3].id],
            "The first page is filled from unmuted stories, not trimmed after LIMIT")
        let remainder = try await db.fetchArticles(limit: nil, after: ArticleQueryCursor(firstPage[0]), muting: muting)
        assertEqual(
            (firstPage + remainder).map(\.id), [stories[3].id, stories[4].id, stories[6].id],
            "Cursor pages continue over unmuted stories only")
        assertEqual(
            try await db.mutedArticleCount(muting: muting), 4,
            "The list counts every muted story, beyond the first page")
        assertEqual(try await db.fetchArticles(limit: nil).count, stories.count, "Nothing is hidden without rules")
        assertEqual(try await db.mutedArticleCount(muting: MuteRules()), 0, "No rules hide no stories")
        try await db.markRead(articleId: stories[0].id, isRead: true)
        assertEqual(
            try await db.mutedArticleCount(isRead: false, muting: muting), 3, "Hidden counts use the list's own filters"
        )
        try await db.setSaved(articleId: stories[2].id, isSaved: true)
        assertEqual(
            try await db.fetchArticles(isSaved: true).map(\.id), [stories[2].id],
            "Saved Stories, queried without rules, keep muted stories")
        assertTrue(try await db.searchArticles(query: "example", muting: muting).isEmpty, "Search applies muting")
        assertEqual(
            try await db.searchArticles(query: "example").count, 2, "Search without rules finds the muted stories")
        assertEqual(
            try await db.mutedArticleCount(search: "example", muting: muting), 2,
            "Search reports how many stories muting hid")
        let ruleCounts = try await db.mutedRuleCounts(muting)
        assertEqual(ruleCounts.sources, ["example.com": 2], "Settings count the stories each source rule covers")
        assertEqual(
            ruleCounts.topics, ["Climate change": 1, "art": 1], "Settings count the stories each topic rule covers")
        try await db.upsertArticles([
            story(7, "https://other.org/7", "OpenAI agents disabled monitors"),
            story(8, "https://other.org/8", "Dubai aid flight lands", "AIDS research funded"),
        ])
        let aiMuting = MuteRules(topicSets: [aiSet])
        assertEqual(
            try await db.mutedArticleCount(muting: aiMuting), 1, "SQLite hides a set's stories by whole words only")
        assertEqual(
            try await db.fetchArticles(limit: nil, muting: aiMuting).count, stories.count + 1,
            "The SQLite and Swift paths agree on what a set hides")
        assertEqual(try await db.mutedRuleCounts(aiMuting).topicSets, [aiSet: 1], "Settings count a set's stories")

        // The masthead counts the whole list, not its loaded page (#782): an event counts once it groups a listed
        // story, and its read or muted reports still count toward its size, as on its card.
        _ = try await db.applyEventMatch(
            stories[3].id, .create(with: [stories[6].id]), matcherVersion: EventMatcher.version)
        _ = try await db.applyEventMatch(
            stories[4].id, .create(with: [stories[0].id]), matcherVersion: EventMatcher.version)
        let totals = try await db.listTotals(section: "Today", isRead: false, muting: muting)
        assertEqual(totals.stories, 5, "Totals count unread, unmuted stories across every page")
        assertEqual(totals.events, 2, "Totals count the events grouping listed stories")
        let whole = try await db.fetchArticles(section: "Today", isRead: false, limit: nil, muting: muting)
        let grouped = EventFeedGrouping.entries(
            for: whole, events: try await db.eventFeedSummaries(forArticles: whole.map(\.id)), mode: .events)
        assertEqual(
            grouped.filter { if case .event = $0 { return true } else { return false } }.count, totals.events,
            "Totals group events exactly as the list does")
        assertEqual(whole.count, totals.stories, "Totals match the list's stories")
        assertEqual(
            try await db.listTotals(search: "example").stories, 2, "Search totals use the search's own filters")
        await db.close()

        // Rules persist with the reader's settings; Unmute All clears them.
        let suite = testDefaultsSuite("test.muting")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        assertTrue(settings.muteRules.isEmpty, "Nothing is muted by default")
        assertEqual(
            settings.muteSource("https://www.example.com/a"), "example.com", "Settings mute a host from a story link")
        assertEqual(settings.muteSource("example.com"), nil, "A muted host is not added twice")
        assertEqual(settings.muteTopic("Election"), "Election", "Settings mute a topic")
        assertEqual(AppSettings(defaults: defaults).muteRules, settings.muteRules, "Muting persists across launches")
        settings.unmuteTopic("Election")
        assertEqual(AppSettings(defaults: defaults).muteRules.topics, [], "Unmuting a topic is stored")
        settings.setTopicSet(aiSet, muted: true)
        assertEqual(AppSettings(defaults: defaults).muteRules.topicSets, [aiSet], "A switched-on set is stored")
        settings.setTopicSet(aiSet, muted: false)
        assertEqual(AppSettings(defaults: defaults).muteRules.topicSets, [], "Switching a set off is stored")
        settings.setTopicSet(aiSet, muted: true)
        settings.clearMuting()
        assertTrue(AppSettings(defaults: defaults).muteRules.isEmpty, "Unmute All clears the stored rules")

        // Muted stories never notify.
        settings.feedURLs = ["https://other.org/feed.xml"]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        settings.muteSource("example.com")
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        var notified: [String] = []
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [stories[0], stories[3]], nil, nil) } },
            notifyBatch: { articles, _ in notified.append(contentsOf: articles.map(\.title)) })
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        assertEqual(notified, [stories[3].title], "Only unmuted new stories notify")
        assertEqual(manager.articles.count, 2, "Muted stories are still stored")
        manager.stopBackgroundWork()
    }

    static func testSmartBinders() async throws {
        print("  - Testing Dynamic Smart Binders (Compound Topic Rules #709)...")

        // 1. Pure rule-to-SQL translation with 100% parameterised queries (no string concatenation of user input)
        let complexBinder = SmartBinder(
            name: "Apple Silicon Watch",
            icon: "cpu",
            categories: ["Tech", "Business"],
            includeKeywords: ["apple", "silicon"],
            excludeKeywords: ["rumor", "leak"],
            publishers: ["Ars Technica", "The Verge"],
            matchAllKeywords: false
        )
        let (sql, params) = complexBinder.sqlCondition()

        // 100% Parameterized verification: SQL string must contain '?' and never raw user text
        for forbidden in ["apple", "silicon", "rumor", "leak", "Ars Technica", "The Verge", "Tech", "Business"] {
            assertFalse(
                sql.lowercased().contains(forbidden.lowercased()),
                "SQL must not concatenate user text '\(forbidden)'; found in: \(sql)"
            )
        }
        assertTrue(sql.contains("coalesce(ae.category, a.category) LIKE ?"), "Categories use parameterised LIKE")
        assertTrue(sql.contains("a.source LIKE ?"), "Publishers use parameterised LIKE")
        assertTrue(
            sql.contains("a.title LIKE ? ESCAPE '\\' OR coalesce(a.description, '') LIKE ? ESCAPE '\\'"),
            "Keywords use parameterised LIKE with ESCAPE")
        assertTrue(
            sql.contains("NOT (a.title LIKE ? ESCAPE '\\' OR coalesce(a.description, '') LIKE ? ESCAPE '\\')"),
            "Exclude keywords use parameterised NOT with ESCAPE")

        // Parameters match the expected formatted wildcards
        assertTrue(params.contains("%Tech%"), "Params contain category wildcard")
        assertTrue(params.contains("%Business%"), "Params contain category wildcard")
        assertTrue(params.contains("%apple%"), "Params contain include keyword wildcard")
        assertTrue(params.contains("%silicon%"), "Params contain include keyword wildcard")
        assertTrue(params.contains("%rumor%"), "Params contain exclude keyword wildcard")
        assertTrue(params.contains("%leak%"), "Params contain exclude keyword wildcard")

        // SQL Injection Attempt
        let maliciousBinder = SmartBinder(
            name: "Injection Test",
            includeKeywords: ["' OR '1'='1'; DROP TABLE articles; --"],
            excludeKeywords: ["'; DELETE FROM article_state; --"]
        )
        let (maliciousSQL, maliciousParams) = maliciousBinder.sqlCondition()
        assertFalse(maliciousSQL.contains("DROP TABLE"), "Malicious input must never be interpolated into SQL")
        assertFalse(maliciousSQL.contains("DELETE FROM"), "Malicious input must never be interpolated into SQL")
        assertTrue(
            maliciousParams.contains("%' OR '1'='1'; DROP TABLE articles; --%"), "Literal string passed as parameter")

        // Wildcard escaping: % and _ should be escaped with \ to prevent accidental wildcard expansion
        let wildcardBinder = SmartBinder(
            name: "Wildcard Test",
            includeKeywords: ["100% genuine", "foo_bar"]
        )
        let (wcSQL, wcParams) = wildcardBinder.sqlCondition()
        assertTrue(wcSQL.contains("ESCAPE '\\'"), "SQL LIKE clauses contain ESCAPE clause")
        assertTrue(wcParams.contains("%100\\% genuine%"), "Wildcard % is escaped in parameter")
        assertTrue(wcParams.contains("%foo\\_bar%"), "Wildcard _ is escaped in parameter")

        // 2. Compound include/exclude rules (in-memory matching)
        let artMatching = FeedArticle(
            title: "Apple introduces M4 Max Silicon",
            link: "https://arstechnica.com/apple-m4",
            guid: "sb-1",
            description: "New chip delivers record performance across all tasks",
            pubDate: Date(),
            source: "Ars Technica",
            category: "Tech"
        )
        let artExcluded = FeedArticle(
            title: "Apple announces M4 chip amid new leak",
            link: "https://arstechnica.com/apple-leak",
            guid: "sb-2",
            description: "New rumor claims supply issues in Taiwan",
            pubDate: Date(),
            source: "Ars Technica",
            category: "Tech"
        )
        let artWrongPublisher = FeedArticle(
            title: "Apple Silicon review",
            link: "https://wsj.com/apple-silicon",
            guid: "sb-3",
            description: "A fast Mac processor tested",
            pubDate: Date(),
            source: "Wall Street Journal",
            category: "Tech"
        )
        let artWrongCategory = FeedArticle(
            title: "Apple Silicon in restaurants",
            link: "https://arstechnica.com/apple-cooking",
            guid: "sb-4",
            description: "Kitchen management systems powered by silicon",
            pubDate: Date(),
            source: "Ars Technica",
            category: "Food"
        )

        assertTrue(complexBinder.matches(article: artMatching), "Article matching all compound rules must pass")
        assertFalse(
            complexBinder.matches(article: artExcluded),
            "Article matching include but containing exclude keyword must fail")
        assertFalse(complexBinder.matches(article: artWrongPublisher), "Article with non-matching publisher must fail")
        assertFalse(complexBinder.matches(article: artWrongCategory), "Article with non-matching category must fail")

        // Match all keywords mode
        let allKeywordsBinder = SmartBinder(
            name: "Strict Apple Silicon",
            includeKeywords: ["apple", "silicon"],
            matchAllKeywords: true
        )
        let artOnlyApple = FeedArticle(
            title: "Apple releases quarterly earnings report",
            link: "https://example.com/apple-earnings",
            guid: "sb-5",
            description: "Services revenue hit record high",
            pubDate: Date(),
            source: "Example",
            category: "Business"
        )
        assertTrue(
            allKeywordsBinder.matches(article: artMatching),
            "Article with both keywords matches under matchAllKeywords=true")
        assertFalse(
            allKeywordsBinder.matches(article: artOnlyApple),
            "Article with only one keyword fails under matchAllKeywords=true")

        // 3. Database query and Mute Rules honoured in Smart Binders
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()

        let dbStories = [
            FeedArticle(
                title: "Apple M4 Silicon review",
                link: "https://arstechnica.com/apple-m4-review",
                guid: "db-1",
                description: "Deep dive into performance",
                pubDate: Date(timeIntervalSince1970: 1_700_000_100),
                source: "Ars Technica",
                category: "Tech"
            ),
            FeedArticle(
                title: "Apple chip supply chain rumor",
                link: "https://arstechnica.com/apple-supply-rumor",
                guid: "db-2",
                description: "Unconfirmed reports from suppliers",
                pubDate: Date(timeIntervalSince1970: 1_700_000_090),
                source: "Ars Technica",
                category: "Tech"
            ),
            FeedArticle(
                title: "Apple Silicon developer tooling",
                link: "https://theverge.com/apple-tooling",
                guid: "db-3",
                description: "Xcode optimizations for M4",
                pubDate: Date(timeIntervalSince1970: 1_700_000_080),
                source: "The Verge",
                category: "Tech"
            ),
            FeedArticle(
                title: "Global monetary policy update",
                link: "https://bbc.com/economy",
                guid: "db-4",
                description: "Interest rate discussion",
                pubDate: Date(timeIntervalSince1970: 1_700_000_070),
                source: "BBC",
                category: "Business"
            ),
        ]
        try await db.upsertArticles(dbStories)

        let testBinder = SmartBinder(
            name: "Apple Silicon",
            categories: ["Tech"],
            includeKeywords: ["apple"],
            excludeKeywords: ["rumor"]
        )

        // Query without muting: db-1 and db-3 match, db-2 is excluded by rumor, db-4 is not Tech/no Apple
        let binderArticles = try await db.fetchArticles(smartBinder: testBinder)
        assertEqual(binderArticles.map(\.id), ["db-1", "db-3"], "Smart binder query returns matching articles")
        let binderTotals = try await db.listTotals(smartBinder: testBinder)
        assertEqual(binderTotals.stories, 2, "List totals reflects binder matching count")

        // SQL and in-memory matching must agree when every keyword is required.
        let strictBinder = SmartBinder(
            name: "Strict", includeKeywords: ["apple", "developer"], matchAllKeywords: true)
        let strictArticles = try await db.fetchArticles(smartBinder: strictBinder)
        assertEqual(strictArticles.map(\.id), ["db-3"], "matchAllKeywords requires every keyword in SQL")
        assertTrue(strictBinder.matches(article: dbStories[2]), "In-memory matching agrees for db-3")
        assertFalse(strictBinder.matches(article: dbStories[0]), "In-memory matching agrees for db-1")

        // U.S. Politics category uses ArticleSection matching semantics in SQL and in-memory
        let polStory = FeedArticle(
            title: "White House press briefing on new legislation",
            link: "https://example.com/us-politics-1",
            guid: "pol-1",
            description: "Administration officials discussed the bill",
            pubDate: Date(timeIntervalSince1970: 1_700_000_150),
            source: "Example News",
            category: "Politics"
        )
        let nonPolStory = FeedArticle(
            title: "Global Astronomy Conference Opens in Tokyo",
            link: "https://example.com/science-1",
            guid: "sci-1",
            description: "Researchers discuss deep space telescope discoveries",
            pubDate: Date(timeIntervalSince1970: 1_700_000_140),
            source: "Example News",
            category: "Science"
        )
        try await db.upsertArticles([polStory, nonPolStory])
        let usPolBinder = SmartBinder(name: "US Pol", categories: ["U.S. Politics"])
        let usPolArticles = try await db.fetchArticles(smartBinder: usPolBinder)
        assertTrue(
            usPolArticles.contains { $0.id == "pol-1" },
            "U.S. Politics binder matches classified Politics story in SQL")
        assertFalse(
            usPolArticles.contains { $0.id == "sci-1" },
            "U.S. Politics binder excludes non-politics story in SQL")
        assertTrue(
            usPolBinder.matches(article: polStory),
            "U.S. Politics matches in-memory for classified Politics story")
        assertFalse(
            usPolBinder.matches(article: nonPolStory),
            "U.S. Politics excludes non-politics story in-memory")

        // Case-insensitivity: "u.s. politics" also uses ArticleSection matching
        let lowerUsPolBinder = SmartBinder(name: "US Pol Lower", categories: ["u.s. politics"])
        let lowerUsPolArticles = try await db.fetchArticles(smartBinder: lowerUsPolBinder)
        assertTrue(
            lowerUsPolArticles.contains { $0.id == "pol-1" },
            "Case-insensitive u.s. politics binder matches in SQL")
        assertTrue(
            lowerUsPolBinder.matches(article: polStory),
            "Case-insensitive u.s. politics binder matches in-memory")

        // Mute rules strictly honoured: mute theverge.com
        var binderMuting = MuteRules(sources: ["theverge.com"])
        let mutedArticles = try await db.fetchArticles(smartBinder: testBinder, muting: binderMuting)
        assertEqual(mutedArticles.map(\.id), ["db-1"], "Muted publisher theverge.com is excluded from smart binder")
        let mutedCount = try await db.mutedArticleCount(smartBinder: testBinder, muting: binderMuting)
        assertEqual(mutedCount, 1, "Muted count reports exactly 1 story hidden by muting")

        // Rule edits produce distinct cache entries without requiring database writes
        var editedBinder = testBinder
        editedBinder.includeKeywords = ["nonexistent"]
        let editedMutedCount = try await db.mutedArticleCount(smartBinder: editedBinder, muting: binderMuting)
        assertEqual(editedMutedCount, 0, "Edited binder rules use a distinct cache entry")

        // Mute by topic: mute "review"
        binderMuting.addTopic("review")
        let topicMutedArticles = try await db.fetchArticles(smartBinder: testBinder, muting: binderMuting)
        assertTrue(topicMutedArticles.isEmpty, "Topic muting eliminates remaining story with 'review'")
        let doubleMutedCount = try await db.mutedArticleCount(smartBinder: testBinder, muting: binderMuting)
        assertEqual(doubleMutedCount, 2, "Both stories now counted as muted under smart binder")

        // Wildcard escaping in live database queries
        let wcArticles = [
            FeedArticle(
                title: "100% Genuine Silicon",
                link: "https://example.com/genuine",
                guid: "wc-1",
                description: "Authentic hardware",
                pubDate: Date(timeIntervalSince1970: 1_700_000_200),
                source: "Example",
                category: "Tech"
            ),
            FeedArticle(
                title: "10000 Genuine Silicon",
                link: "https://example.com/not-percent",
                guid: "wc-2",
                description: "Different number",
                pubDate: Date(timeIntervalSince1970: 1_700_000_190),
                source: "Example",
                category: "Tech"
            ),
        ]
        try await db.upsertArticles(wcArticles)
        let exactPercentBinder = SmartBinder(
            name: "Percent Test",
            includeKeywords: ["100%"]
        )
        let percentMatches = try await db.fetchArticles(smartBinder: exactPercentBinder)
        assertEqual(percentMatches.map(\.id), ["wc-1"], "Escaped % matches only literal %, not arbitrary digits")

        await db.close()

        // 4. Persistence round trip and settings backup/restore
        let suite = testDefaultsSuite("test.smartbinders")
        defer { removeTestDefaults(suite) }

        try await MainActor.run {
            let testDefaults = UserDefaults(suiteName: suite)!
            let settings = AppSettings(defaults: testDefaults)
            assertEqual(settings.smartBinders.count, 0, "Initially zero smart binders")

            let persistentBinder = SmartBinder(
                id: UUID(),
                name: "Custom Defense & Tech",
                icon: "cube",
                categories: ["Tech", "World"],
                includeKeywords: ["radar", "satellite"],
                excludeKeywords: ["speculation"],
                publishers: ["Defense News"]
            )
            settings.addSmartBinder(persistentBinder)
            assertEqual(settings.smartBinders.count, 1, "Binder added to settings")
            assertEqual(
                settings.smartBinder(id: persistentBinder.id)?.name, "Custom Defense & Tech",
                "Binder lookup by ID works")
            assertEqual(
                settings.smartBinder(forTag: persistentBinder.sidebarTag)?.icon, "cube", "Binder lookup by tag works")

            // Update binder
            var modifiedBinder = persistentBinder
            modifiedBinder.name = "Aerospace & Tech"
            assertTrue(
                modifiedBinder.hashValue != persistentBinder.hashValue,
                "Modified binder produces distinct hash value for view cache invalidation")
            settings.updateSmartBinder(modifiedBinder)
            assertEqual(
                settings.smartBinder(id: persistentBinder.id)?.name, "Aerospace & Tech", "Binder update persists")

            // Backup settings
            let backupData = try AppSettings.backupSettings(from: testDefaults)

            // Clear defaults suite and verify restoration
            testDefaults.removePersistentDomain(forName: suite)
            try AppSettings.restoreSettings(backupData, to: testDefaults)

            let restoredSettings = AppSettings(defaults: testDefaults)
            assertEqual(restoredSettings.smartBinders.count, 1, "Smart binders cleanly restored from backup")
            let restoredBinder = restoredSettings.smartBinders.first
            assertEqual(restoredBinder?.id, persistentBinder.id, "Restored binder preserves ID")
            assertEqual(restoredBinder?.name, "Aerospace & Tech", "Restored binder preserves updated name")
            assertEqual(restoredBinder?.icon, "cube", "Restored binder preserves icon")
            assertEqual(restoredBinder?.categories, ["Tech", "World"], "Restored binder preserves categories")
            assertEqual(
                restoredBinder?.includeKeywords, ["radar", "satellite"], "Restored binder preserves includeKeywords")
            assertEqual(restoredBinder?.excludeKeywords, ["speculation"], "Restored binder preserves excludeKeywords")
            assertEqual(restoredBinder?.publishers, ["Defense News"], "Restored binder preserves publishers")

            // Remove binder
            restoredSettings.removeSmartBinder(persistentBinder)
            assertEqual(restoredSettings.smartBinders.count, 0, "Binder removal persists cleanly")

            // SmartBinder tags and ID extraction
            assertTrue(SmartBinder.isBinderTag(persistentBinder.sidebarTag), "isBinderTag recognizes valid tag")
            assertFalse(SmartBinder.isBinderTag("category:all"), "isBinderTag rejects other tags")
            assertEqual(
                SmartBinder.binderID(fromTag: persistentBinder.sidebarTag), persistentBinder.id,
                "binderID parses valid tag")
            assertEqual(
                SmartBinder.binderID(fromTag: "category:all"), nil, "binderID returns nil for non-binder tag")

            // SmartBinderSheet helpers and draft builder
            assertEqual(
                SmartBinderSheet.parseCommaSeparated("apple, silicon, m4"), ["apple", "silicon", "m4"],
                "Comma-separated parsing trims and filters")
            assertEqual(
                SmartBinderSheet.parseCommaSeparated("   "), [], "Blank comma-separated string yields empty list")

            let newDraft = SmartBinderSheet.Draft(
                name: "  Apple Silicon  ",
                icon: "cpu",
                categories: ["Tech", "Science"],
                includeKeywordsText: "m4, pro",
                excludeKeywordsText: "rumor",
                publishersText: "The Verge",
                matchAllKeywords: true
            )
            let createdBinder = SmartBinderSheet.buildBinder(from: newDraft)
            assertEqual(createdBinder.name, "Apple Silicon", "buildBinder trims name")
            assertEqual(createdBinder.icon, "cpu", "buildBinder sets icon")
            assertEqual(createdBinder.categories, ["Science", "Tech"], "buildBinder sorts categories")
            assertEqual(createdBinder.includeKeywords, ["m4", "pro"], "buildBinder parses includes")
            assertEqual(createdBinder.excludeKeywords, ["rumor"], "buildBinder parses excludes")
            assertEqual(createdBinder.publishers, ["The Verge"], "buildBinder parses publishers")
            assertTrue(createdBinder.matchAllKeywords, "buildBinder sets matchAllKeywords")

            let editDraft = SmartBinderSheet.Draft(
                existing: createdBinder,
                name: "Updated Silicon",
                icon: "folder",
                categories: ["Tech"],
                includeKeywordsText: "",
                excludeKeywordsText: "",
                publishersText: "",
                matchAllKeywords: false
            )
            let updatedBinder = SmartBinderSheet.buildBinder(from: editDraft)
            assertEqual(updatedBinder.id, createdBinder.id, "Updating preserves binder ID")
            assertEqual(updatedBinder.name, "Updated Silicon", "Updating sets new name")
            assertEqual(updatedBinder.icon, "folder", "Updating sets new icon")
            assertFalse(updatedBinder.matchAllKeywords, "Updating clears matchAllKeywords")

            // Exercise SmartBinderSheet view body in creation and edit modes
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }

            let sheetNew = SmartBinderSheet()
            let hostNew = NSHostingView(rootView: sheetNew.environmentObject(settings))
            window.contentView = hostNew
            // Laid out in a window that is never ordered on screen: the headless suite opens none (#991).
            hostNew.layoutSubtreeIfNeeded()
            _ = hostNew.fittingSize

            let sheetEdit = SmartBinderSheet(binder: createdBinder)
            let hostEdit = NSHostingView(rootView: sheetEdit.environmentObject(settings))
            window.contentView = hostEdit
            hostEdit.layoutSubtreeIfNeeded()
            _ = hostEdit.fittingSize
        }
    }

    static func testNavigationCommands() async {
        print("  - Testing Keyboard Navigation Offset Logic...")

        let sampleArticles = (0..<5).map { i in
            FeedArticle(
                title: "Article \(i)",
                link: "https://example.com/article-\(i)",
                guid: "guid-\(i)",
                description: "Description \(i)",
                pubDate: Date(timeIntervalSince1970: Double(1000 + i * 100)),
                source: "Source"
            )
        }

        let currentID = "guid-2"
        let currentIndex = sampleArticles.firstIndex(where: { $0.id == currentID })!
        assertEqual(currentIndex, 2, "Current index should be 2")

        let nextIndex = min(currentIndex + 1, sampleArticles.count - 1)
        assertEqual(nextIndex, 3, "Next index should be 3")
        assertEqual(sampleArticles[nextIndex].id, "guid-3", "Next article should be guid-3")

        let prevIndex = max(currentIndex - 1, 0)
        assertEqual(prevIndex, 1, "Previous index should be 1")
        assertEqual(sampleArticles[prevIndex].id, "guid-1", "Previous article should be guid-1")
    }

    static func testStoryExport() async throws {
        print("  - Testing saved-story and history export (#565)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        func noBOM(_ data: Data) -> Bool { !data.starts(with: [0xEF, 0xBB, 0xBF]) }
        for saved in [true, false] {
            let entries = try await db.exportedStories(saved: saved)
            assertTrue(entries.isEmpty, "An empty library exports an empty list")
            let json = try StoryExport.json(entries)
            assertTrue(noBOM(json), "JSON export is UTF-8 without a byte order mark")
            assertTrue((try JSONSerialization.jsonObject(with: json) as? [Any])?.isEmpty == true, "Empty JSON list")
            let markdown = String(decoding: StoryExport.markdown(entries, title: "History"), as: UTF8.self)
            assertEqual(markdown, "# History\n\n", "Empty Markdown export is the heading alone")
        }
        let cafe = FeedArticle(
            title: "Café [live] reopens", link: "https://example.com/news/cafe", guid: "cafe",
            description: "Report", pubDate: Date(timeIntervalSince1970: 1_790_000_000), source: "Example News\nWorld")
        let undated = FeedArticle(
            title: "Undated item", link: "https://example.com/news/undated", guid: "undated", description: "Report",
            pubDate: DateParser.unknownDate, source: "Example News")
        try await db.upsertArticles([cafe, undated], feedUrl: "https://example.com/feed")
        try await db.setSaved(articleId: cafe.id, isSaved: true)
        try await db.markRead(articleId: undated.id, isRead: true)
        try await db.markRead(articleId: cafe.id, isRead: true)
        // A reconciled duplicate, saved and read most recently, is never exported; exact times decide the order.
        let copy = FeedArticle(
            title: "Café [live] reopens (copy)", link: "https://example.com/news/cafe-copy", guid: "cafe-copy",
            description: "Report", pubDate: cafe.pubDate, source: "Example News")
        try await db.upsertArticles([copy], feedUrl: "https://example.com/feed")
        try await db.setSaved(articleId: copy.id, isSaved: true)
        try await db.markRead(articleId: copy.id, isRead: true)
        let stored = Dictionary(
            try await db.fetchArticles(limit: nil, includingOriginals: true).map { ($0.title, $0.id) },
            uniquingKeysWith: { first, _ in first })
        let cafeID = stored[cafe.title]!
        let undatedID = stored[undated.title]!
        let copyID = stored[copy.title]!
        try await db.executeSimple(
            """
            UPDATE article_state SET saved_at = 2000, read_at = 3000 WHERE article_id = '\(cafeID)';
            UPDATE article_state SET read_at = 3500 WHERE article_id = '\(undatedID)';
            UPDATE article_state SET saved_at = 9000, read_at = 9000 WHERE article_id = '\(copyID)';
            INSERT INTO article_reconciliations (duplicate_id, survivor_id, canonical_url, fingerprint)
                VALUES ('\(copyID)', '\(cafeID)', '\(cafe.link)', 'test');
            """)

        let saved = try await db.exportedStories(saved: true)
        assertEqual(saved.map(\.title), [cafe.title], "Only saved stories are exported as saved")
        assertEqual(saved.first?.publisher, "Example News", "The publisher is the feed's first title line")
        assertEqual(saved.first?.published, cafe.pubDate, "The publication date is exported")
        assertEqual(saved.first?.savedAt, Date(timeIntervalSince1970: 2000), "Saved export carries the exact save time")
        assertTrue(saved.first?.readAt == nil, "Saved export names no read time")
        let history = try await db.exportedStories(saved: false)
        assertEqual(history.map(\.title), [undated.title, cafe.title], "History lists every read story, newest first")
        assertEqual(
            history.map(\.readAt), [Date(timeIntervalSince1970: 3500), Date(timeIntervalSince1970: 3000)],
            "History carries the exact read times")
        assertTrue(history.allSatisfy { $0.savedAt == nil }, "History names no save time")
        assertTrue(history.contains { $0.title == undated.title && $0.published == nil }, "Unknown dates are left out")

        let json = try StoryExport.json(saved)
        assertTrue(noBOM(json), "JSON export is UTF-8 without a byte order mark")
        let object = (try JSONSerialization.jsonObject(with: json) as? [[String: Any]])?.first
        assertEqual(object?["title"] as? String, "Café [live] reopens", "Non-ASCII titles round-trip as UTF-8")
        assertEqual(object?["url"] as? String, cafe.link, "The story URL is exported unescaped")
        assertTrue(object?["savedAt"] is String && object?["readAt"] == nil, "Saved JSON names the save time only")
        assertEqual(object?["published"] as? String, "2026-09-21T14:13:20Z", "Dates are ISO 8601 in UTC")
        let markdownData = StoryExport.markdown(history, title: "History")
        assertTrue(noBOM(markdownData), "Markdown export is UTF-8 without a byte order mark")
        let markdown = String(decoding: markdownData, as: UTF8.self)
        assertTrue(markdown.hasPrefix("# History\n\n- "), "Markdown export is a heading and a list")
        let cafeLine = "- [Café \\[live\\] reopens](<https://example.com/news/cafe>) · Example News · published "
        assertTrue(markdown.contains(cafeLine), "Markdown escapes brackets in titles and links the story")
        let undatedLine = "- [Undated item](<https://example.com/news/undated>) · Example News · read "
        assertTrue(markdown.contains(undatedLine), "Undated stories list the read time only")
        let broken = StoryExportEntry(
            title: "Line one\r\nline two\rthree\nfour", publisher: "P", url: "https://example.com/x", published: nil)
        let brokenMarkdown = String(decoding: StoryExport.markdown([broken], title: "History"), as: UTF8.self)
        assertEqual(
            brokenMarkdown, "# History\n\n- [Line one line two three four](<https://example.com/x>) · P\n",
            "Line breaks in a title stay inside one list item")
    }

    static func testStoryImages(fixtureRoot: URL) async throws {
        print("  - Testing lead images found on publisher pages for stories without any...")
        let page = "https://news.example/world/story"
        assertEqual(
            StoryImageFinder.leadImage(
                in: "<head><meta property=\"og:image\" content=\"/media/lead.jpg?w=1200&amp;q=80\"></head>",
                pageURL: page),
            .found("https://news.example/media/lead.jpg?w=1200&q=80"),
            "A relative og:image resolves against the page and decodes entities")
        assertEqual(
            StoryImageFinder.leadImage(
                in: "<meta name=\"twitter:image\" content=\"https://cdn.example/a.jpg\">", pageURL: page),
            .found("https://cdn.example/a.jpg"), "twitter:image counts")
        assertEqual(
            StoryImageFinder.leadImage(
                in: "<meta property=\"og:image\" content=\"https://news.example/logo.png\">", pageURL: page),
            .none, "Logos are not lead images")
        assertEqual(
            StoryImageFinder.leadImage(in: "<p>No image</p>", pageURL: page), .none,
            "A page without a declared image has none")
        let schema =
            #"<script type="application/ld+json">{"@graph":[{"@type":"Organization","image":"/logo.png"},{"@type":"NewsArticle","image":[{"url":"/photo.jpg"}]}]}</script>"#
        assertEqual(
            StoryImageFinder.leadImage(in: schema, pageURL: page), .found("https://news.example/photo.jpg"),
            "schema.org article images are found; publisher organization logos are skipped")
        assertEqual(
            StoryImageFinder.leadImage(
                in: "<meta property='og:image' content='/logo.png'><meta name='twitter:image' content='/photo.jpg'>",
                pageURL: page),
            .found("https://news.example/photo.jpg"), "A rejected og logo does not hide a usable Twitter image")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = mockHTTPClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }
        let head = "<meta property='og:image' content='/caf\u{00e9}.jpg'>"
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=iso-8859-1", "Content-Length": "1048576"])!
            return (response, head.data(using: .isoLatin1)! + Data(repeating: 32, count: 1024 * 1024))
        }
        let (prefix, _) = try await client.fetchArticleHead(from: URL(string: "https://example.com/story")!)
        assertEqual(prefix.count, 256 * 1024, "Only a bounded page prefix is retained even for a large declared body")
        assertEqual(
            await StoryImageFinder.publisherPages(using: client).find("https://example.com/story"),
            .found("https://example.com/caf%C3%A9.jpg"),
            "The protected finder respects the publisher's declared character encoding")

        // #312: pages that declare no image. Body prose must pass reader validation, as on a real article page.
        let prose = (1...4).map {
            "Paragraph \($0) of the report describes how regional officials responded to the flooding, which closed roads and schools across the valley this week."
        }
        func articlePage(_ figures: String) -> String {
            "<html><head><title>Flooding closes roads</title></head><body><header><img src='/brand/logo.png' alt='Publisher logo'></header>"
                + "<article><p>\(prose[0])</p>\(figures)<p>\(prose[1])</p><p>\(prose[2])</p><p>\(prose[3])</p></article></body></html>"
        }
        let pages = [
            // All prose precedes the padding, so only the figure lies beyond the prefix.
            "/late": "<html><body><article>" + prose.map { "<p>\($0)</p>" }.joined() + "<div>"
                + String(repeating: " ", count: 300 * 1024)
                + "<figure><img src='/photos/late.jpg' width='1200' height='800'></figure></div></article></body></html>",
            "/early": "<html><body><article>" + prose.map { "<p>\($0)</p>" }.joined()
                + "<div><figure><img src='/photos/late.jpg' width='1200' height='800'></figure></div></article></body></html>",
            "/figure": articlePage(
                "<figure><img src='/photos/pixel.gif' width='1' height='1'></figure>"
                    + "<figure><img src='/photos/flooded-road.jpg' width='1200' height='800' alt='A flooded road'><figcaption>A flooded road near the valley</figcaption></figure>"
                    + "<figure><img src='/photos/second.jpg' width='1200' height='800'></figure>"),
            "/furniture": articlePage(
                "<figure><img src='/photos/strip.jpg' width='4000' height='200'></figure>"
                    + "<figure><img src='/promo/n.jpg' alt='A thin banner promoting the Morning Briefing newsletter'></figure>"
                    + "<figure><img src='/photos/pixel.gif' width='1' height='1'></figure>"),
        ]
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/html; charset=utf-8"])!,
                Data((pages[request.url!.path] ?? "").utf8)
            )
        }
        let pageFinder = StoryImageFinder.publisherPages(using: client)
        assertEqual(
            await pageFinder.find("https://example.com/figure"), .found("https://example.com/photos/flooded-road.jpg"),
            "Without a declaration, the first qualifying figure in the article body is the lead")
        assertEqual(
            await pageFinder.find("https://example.com/furniture"), StoryImageLookup.none,
            "Logos, newsletter banners, tracking pixels and extreme strips never stand in for a lead")
        assertEqual(
            await pageFinder.find("https://example.com/early"), .found("https://example.com/photos/late.jpg"),
            "A figure after the article prose qualifies within the prefix")
        assertEqual(
            await pageFinder.find("https://example.com/late"), StoryImageLookup.none,
            "Only figures within the bounded page prefix are considered")
        assertEqual(StoryImageFinder.pageURL(""), nil, "An empty link is never requested")
        assertEqual(StoryImageFinder.pageURL("/relative/story"), nil, "A relative link is never requested")
        assertEqual(
            StoryImageFinder.pageURL("https://example.com:22/story"), nil, "A link on a refused port is never requested"
        )
        assertEqual(
            StoryImageFinder.pageURL("http://example.com/story")?.absoluteString, "https://example.com/story",
            "An http link is requested over https")
        // #818: a refused page is answered as no image (recorded, not retried); rate limits and outages retry.
        for (status, expected) in [
            (403, StoryImageLookup.none), (404, .none), (410, .none), (429, .unreachable), (503, .unreachable),
        ] {
            MockURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
            }
            assertEqual(
                await pageFinder.find("https://example.com/refused"), expected,
                "HTTP \(status) from a publisher page maps to its lookup state")
        }
        MockURLProtocol.requestHandler = nil

        var small = FeedArticle(
            title: "Report", link: page, guid: "small", description: "", pubDate: Date(), source: "One")
        small.readerDocument = ReaderDocument(
            blocks: [],
            images: [
                ReaderImageCandidate(url: "https://news.example/small.jpg", origin: .feed, width: 300, height: 200)
            ], leadImageURL: "https://news.example/small.jpg")
        var large = small
        large.readerDocument = ReaderDocument(
            blocks: [],
            images: [
                ReaderImageCandidate(url: "https://news.example/large.jpg", origin: .body, width: 1200, height: 800)
            ], leadImageURL: "https://news.example/large.jpg")
        assertEqual(
            FeedArticle.bestCardImage(in: [small, large])?.absoluteString, "https://news.example/large.jpg",
            "Cards select the largest usable member lead")

        var captioned = FeedArticle(
            title: "Report", link: page, guid: "captioned", description: "", pubDate: Date(), source: "Two")
        captioned.readerDocument = ReaderDocument(
            blocks: [],
            images: [
                ReaderImageCandidate(
                    url: "https://news.example/wide.jpg", origin: .body, width: 1600, height: 900,
                    caption: "  Crews clear the flooded road.  ", credit: "Photo: A. Reporter")
            ], leadImageURL: "https://news.example/wide.jpg")
        assertEqual(
            FeedArticle.cardImages(in: [small, large, captioned, large]).map(\.absoluteString),
            ["https://news.example/wide.jpg", "https://news.example/large.jpg", "https://news.example/small.jpg"],
            "Event cards rank every distinct usable member lead, best first")
        assertEqual(
            OverviewComposer.leadImage(from: [small, captioned]),
            OverviewLeadImage(
                url: "https://news.example/wide.jpg", caption: "Crews clear the flooded road.",
                credit: "Photo: A. Reporter", sourceArticleID: captioned.id),
            "The overview lead is the best member image, with its publisher caption, credit and source")
        assertEqual(
            OverviewComposer.leadImage(from: [small])?.caption, nil,
            "A lead without publisher metadata carries no invented caption")
        assertEqual(
            OverviewComposer.leadImage(from: [
                FeedArticle(
                    title: "Bare", link: page, guid: "bare", description: "", pubDate: Date(), source: "Three")
            ]),
            nil, "An event without a usable image has no overview lead")

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let now = Date()
        func story(_ id: String, _ source: String, image: String? = nil) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Story \(id)",
                link: fixtureRoot.appendingPathComponent("images/\(id)").absoluteString,
                guid: id, description: "Summary.", pubDate: now.addingTimeInterval(-3600), source: source,
                imageUrl: image)
        }
        try await db.upsertArticles([
            story("plain", "One"), story("pictured", "One", image: "https://cdn.example/p.jpg"),
            story("e1", "One"), story("e2", "Two"), story("f1", "One"),
            story("f2", "Two", image: "https://cdn.example/f.jpg"),
            story("down", "Three"), story("waiting", "Three"),
        ])
        _ = try await db.createEvent(memberArticleIDs: ["e1", "e2"], at: now)
        _ = try await db.createEvent(memberArticleIDs: ["f1", "f2"], at: now)
        try await db.recordImportance("waiting", .minor, at: now)
        let rows = try await db.imagelessStoryRows(activeSince: now.addingTimeInterval(-86_400), limit: 20)
        assertEqual(
            Set(rows.map(\.id)), ["plain", "e1", "e2", "down", "waiting"],
            "Minor-rated stories retain image eligibility; pictured events need no lookup"
        )
        assertTrue(rows.first.map { ["e1", "e2"].contains($0.id) } == true, "Clustered stories come first")
        let pastRefused = try await db.imagelessStoryRows(
            activeSince: now.addingTimeInterval(-86_400), limit: 1,
            isRequestable: { !$0.hasSuffix("/e1") && !$0.hasSuffix("/e2") })
        assertTrue(
            pastRefused.count == 1 && !["e1", "e2"].contains(pastRefused[0].id),
            "Links the client would refuse do not use up the candidate limit (#818)")
        assertEqual(
            rows.first(where: { $0.id == "plain" })?.link, story("plain", "One").link,
            "A freshly ingested story has a usable URL before reader extraction")

        let finder = StoryImageFinder { link in
            if link.hasSuffix("/down") { return .unreachable }
            if link.hasSuffix("/plain") { return .none }
            if link.hasSuffix("/waiting") { return .found("https://cdn.example/waiting.jpg") }
            return .found("https://cdn.example/found.jpg")
        }
        let report = try await StoryCurator.run(in: db, imageFinder: finder, now: now)
        assertEqual(report.imagesFound, 2, "Both an event and a minor singleton receive images")
        assertEqual(
            try await db.storyImages(for: ["e1", "e2", "plain"]).count, 1,
            "Found images are stored; misses are not images")
        assertTrue(
            FeedArticle.bestCardImage(
                in: try await db.fetchArticles(limit: nil, eventID: try await db.eventID(forArticle: "e1"))) != nil,
            "Shared storage exposes fetched images to grouped cards and Briefing, without list-only decoration")
        let remaining = Set(
            try await db.imagelessStoryRows(activeSince: now.addingTimeInterval(-86_400), limit: 20).map(\.id))
        assertEqual(remaining, ["down"], "Pages without an image are not read again; unreachable pages are retried")
        assertFalse(
            try await db.recordStoryImage("down", imageURL: "https://cdn.example/found.jpg", at: now),
            "An image another story already declared is a site default")
        assertTrue(
            try await db.storyImages(for: ["e1", "e2", "down"]).isEmpty, "A site default is cleared for every story")
        assertFalse(
            try await db.recordStoryImage("plain", imageURL: "https://cdn.example/found.jpg", at: now),
            "A third story declaring a cleared site default does not keep it (#338)")
        assertTrue(
            try await db.storyImages(for: ["e1", "e2", "down", "plain"]).isEmpty,
            "Site defaults stay cleared regardless of lookup order")

        // #595: a pictured member only on a World Tension panel feed is hidden from lists, so the listed member of
        // its event is still looked up.
        let panelURL = TensionMethodology.v1.panel[8].url
        _ = try await db.upsertArticles([story("g1", "One")], feedUrl: "https://example.com/subscribed.xml")
        _ = try await db.upsertArticles([story("g2", "Panel", image: "https://cdn.example/g.jpg")], feedUrl: panelURL)
        _ = try await db.createEvent(memberArticleIDs: ["g1", "g2"], at: now)
        let unscoped = try await db.imagelessStoryRows(activeSince: now.addingTimeInterval(-86_400), limit: 20)
        assertFalse(unscoped.contains { $0.id == "g1" }, "Without collection feeds every member counts")
        await db.setCollectionOnlyFeedURLs([panelURL])
        let scoped = try await db.imagelessStoryRows(activeSince: now.addingTimeInterval(-86_400), limit: 20)
        assertTrue(scoped.contains { $0.id == "g1" }, "A hidden member's image does not skip the listed story")
        assertFalse(scoped.contains { $0.id == "g2" }, "The hidden member itself is never looked up")
        await db.close()
        try await testStoryImageIndexMigration(fixtureRoot: fixtureRoot)
        try await testMarkAllReadScope(fixtureRoot: fixtureRoot)
    }

    /// #784: Mark All as Read marks only unread stories the reading feed shows. Earlier read times stay, and
    /// analysis-only panel reports stay unread, since a read panel report would surface in History.
    static func testMarkAllReadScope(fixtureRoot: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-mark-all-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let db = DatabaseEngine(path: path)
        try await db.open()
        func report(_ id: String) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Report \(id)", link: fixtureRoot.appendingPathComponent(id).absoluteString,
                guid: id, description: "Report.", pubDate: Date(), source: "Publisher")
        }
        let panelURL = TensionMethodology.v1.panel[8].url
        try await db.upsertArticles([report("earlier"), report("unread")], feedUrl: "https://example.com/rss")
        try await db.upsertArticles([report("panel")], feedUrl: panelURL)
        await db.setCollectionOnlyFeedURLs([panelURL])
        try await db.markRead(articleId: "earlier", isRead: true)
        func readAt(_ id: String) -> Double? {
            var handle: OpaquePointer?
            var statement: OpaquePointer?
            defer {
                sqlite3_finalize(statement)
                sqlite3_close(handle)
            }
            guard sqlite3_open(path, &handle) == SQLITE_OK,
                sqlite3_prepare_v2(
                    handle, "SELECT read_at FROM article_state WHERE article_id = ? AND is_read = 1", -1,
                    &statement, nil) == SQLITE_OK
            else { return nil }
            sqlite3_bind_text(statement, 1, id, -1, DatabaseEngine.sqliteTransient)
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_double(statement, 0) : nil
        }
        let earlier = readAt("earlier")
        try await Task.sleep(nanoseconds: 20_000_000)
        try await db.markAllRead()
        assertEqual(readAt("earlier"), earlier, "Mark All as Read keeps the time a story was first read")
        assertTrue(readAt("unread") != nil, "Mark All as Read marks unread listed stories")
        assertTrue(readAt("panel") == nil, "Analysis-only panel reports stay unread and out of History")
        try await db.markRead(articleId: "unread", isRead: false)
        try await db.markAllRead(feedUrl: panelURL)
        assertTrue(readAt("panel") == nil, "A panel feed's own Mark All as Read leaves its hidden reports alone")
        assertTrue(readAt("unread") == nil, "Another feed's Mark All as Read leaves this feed's stories unread")
        try await db.markAllRead(feedUrl: "https://example.com/rss")
        assertTrue(readAt("unread") != nil, "A feed's Mark All as Read marks its own unread stories")
        // Muted stories are not in the list, so they stay unread rather than becoming reading interests.
        try await db.upsertArticles(
            [
                FeedArticle(
                    storedID: "muted", title: "Muted report", link: "https://muted.example/story", guid: "muted",
                    description: "Report.", pubDate: Date(), source: "Muted Publisher")
            ],
            feedUrl: "https://example.com/rss")
        try await db.markRead(articleId: "unread", isRead: false)
        var muting = MuteRules()
        _ = muting.addSource("muted.example")
        try await db.markAllRead(muting: muting)
        assertTrue(readAt("muted") == nil, "Mark All as Read leaves muted stories unread")
        assertTrue(readAt("unread") != nil, "Mute rules still let unmuted stories be marked")
        await db.close()
    }

    static func testStoryImageIndexMigration(fixtureRoot: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-image-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let db = DatabaseEngine(path: path)
        try await db.open()
        let article = FeedArticle(
            storedID: "index-story", title: "Publisher report",
            link: fixtureRoot.appendingPathComponent("index-story").absoluteString,
            guid: "index-story", description: "Report.", pubDate: Date(), source: "Publisher")
        try await db.upsertArticles([article])
        try await db.markRead(articleId: article.id, isRead: true)
        try await db.setSaved(articleId: article.id, isSaved: true)
        _ = try await db.recordStoryImage(article.id, imageURL: "https://cdn.example/index.jpg")
        let neighbors = (0..<64).map { index in
            FeedArticle(
                storedID: "image-neighbor-\(index)", title: "Other report",
                link: fixtureRoot.appendingPathComponent("image-neighbor-\(index)").absoluteString,
                guid: "image-neighbor-\(index)", description: "Report.", pubDate: Date(), source: "Publisher")
        }
        try await db.upsertArticles(neighbors)
        for neighbor in neighbors {
            _ = try await db.recordStoryImage(neighbor.id, imageURL: "https://cdn.example/\(neighbor.id).jpg")
        }
        await db.close()
        var handle: OpaquePointer?
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open the isolated image migration fixture")
        defer { sqlite3_close(handle) }
        func value(_ sql: String, column: Int32 = 0) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, column) else {
                return nil
            }
            return String(cString: text)
        }
        assertEqual(
            sqlite3_exec(handle, "DROP INDEX idx_story_images_url; PRAGMA user_version = 18;", nil, nil, nil),
            SQLITE_OK,
            "Reconstruct an existing v18 image library")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await db.open()
        }
        do {
            try await cancelled.value
            assertTrue(false, "Cancelled migration must fail")
        } catch { assertTrue(error is CancellationError, "Cancelled migration preserves cancellation") }
        await db.close()
        assertEqual(value("PRAGMA user_version;"), "18", "Cancellation keeps the previous schema version")
        assertEqual(
            value("SELECT count(*) FROM sqlite_master WHERE name='idx_story_images_url';"), "0",
            "Cancellation leaves no partial index")
        try await db.open()
        assertEqual(
            value("PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Existing v18 libraries receive the image index migration")
        assertEqual(
            sqlite3_exec(handle, "ANALYZE story_images;", nil, nil, nil), SQLITE_OK,
            "Use current fixture cardinality for the query planner")
        assertTrue(
            value(
                "EXPLAIN QUERY PLAN SELECT article_id FROM story_images WHERE image_url='https://cdn.example/index.jpg' AND article_id<>'other';",
                column: 3)?.contains("idx_story_images_url") == true,
            "Duplicate-image checks use the image URL index")
        assertEqual(
            try await db.storyImages(for: [article.id])[article.id], "https://cdn.example/index.jpg",
            "Migration preserves cached images")
        assertTrue(try await db.isRead(articleId: article.id), "Migration preserves read history")
        assertTrue(try await db.isSaved(articleId: article.id), "Migration preserves saved stories")
        await db.close()
        try await db.open()
        assertEqual(
            value("SELECT count(*) FROM sqlite_master WHERE name='idx_story_images_url';"), "1",
            "Reopening preserves one index")
        assertTrue(
            value(
                "EXPLAIN QUERY PLAN SELECT a.id FROM articles a ORDER BY \(DatabaseEngine.articleDateOrder) DESC, a.id LIMIT 201;",
                column: 3)?.contains("idx_articles_order") == true,
            "List pages walk the date-order index instead of sorting every story (#778)")
        assertEqual(
            value("SELECT count(*) FROM sqlite_master WHERE name='story_image_defaults';"), "1",
            "Upgraded libraries remember site defaults")

        // #817: classifier output stays out of the publisher-hint column, and v28 clears the rows it reached.
        let hints = ["hint-classified", "hint-publisher", "hint-unclassified", "hint-unrated"].map { id in
            FeedArticle(
                storedID: id, title: "Hint report \(id)", link: fixtureRoot.appendingPathComponent(id).absoluteString,
                guid: id, description: "Report.", pubDate: Date(), source: "Publisher")
        }
        try await db.upsertArticles(hints)
        for hint in hints.prefix(2) {
            try await db.updateEnrichment(articleId: hint.id, update: .init(category: "World"))
        }
        assertEqual(
            value("SELECT category FROM articles WHERE id = 'hint-classified';"), nil,
            "A classification is stored in article_enrichment only (#817)")
        assertEqual(
            try await db.fetchArticles(limit: 1, id: "hint-classified").first?.category, "World",
            "Lists still show the classifier's category")
        await db.close()
        assertEqual(
            sqlite3_exec(
                handle,
                "UPDATE articles SET category = 'World' WHERE id = 'hint-classified'; UPDATE articles SET category = 'Sport' WHERE id = 'hint-publisher'; UPDATE articles SET category = 'World' WHERE id = 'hint-unclassified'; UPDATE articles SET category = 'Politics' WHERE id = 'hint-unrated'; PRAGMA user_version = 27;",
                nil, nil, nil), SQLITE_OK, "Reconstruct a v27 library with a classifier category in the hint column")
        try await db.open()
        assertEqual(
            value("PRAGMA user_version;"), String(DatabaseEngine.schemaVersion), "The v27 library migrates to v28")
        assertEqual(
            value("SELECT category FROM articles WHERE id = 'hint-classified';"), nil,
            "v28 clears a hint that holds the classifier's category")
        assertEqual(
            value("SELECT category FROM articles WHERE id = 'hint-publisher';"), "Sport",
            "v28 keeps a publisher category that differs from the classifier's")
        assertEqual(
            value("SELECT category FROM articles WHERE id = 'hint-unclassified';"), nil,
            "v28 clears a classifier label left in the hint after its enrichment category was cleared")
        assertEqual(
            value("SELECT category FROM articles WHERE id = 'hint-unrated';"), "Politics",
            "v28 keeps a publisher label that differs from the label the classifier gives the article")
        await db.close()
    }

    static func testDockBadgeCount() {
        print("  - Testing the Dock badge: today's unread Briefing plus notified stories (#584)...")
        // 3,502 stories, 3,454 of them unread; 10 Briefing stories, 8 unread; 2 notified stories, unread.
        let library = (0..<3_502).map { "story-\($0)" }
        let edition = Array(library[0..<10])
        let read = Set(library[3_456...]).union(edition[0..<2])
        assertEqual(library.filter { !read.contains($0) }.count, 3_454, "The seeded library has 3,454 unread stories")
        let notified: Set<String> = ["story-20", "story-21"]
        let now = Date()
        let selectedAt = FiniteBriefing.editionStart(now: now, hour: 7)
        func badge(_ read: Set<String>, notified: Set<String> = notified, selectedAt: Date = selectedAt) -> Int {
            FiniteBriefing.dockBadgeCount(
                editionIDs: edition.joined(separator: "\n"), selectedAt: selectedAt, hour: 7, notified: notified,
                read: read, now: now)
        }
        assertEqual(badge(read), 10, "8 unread Briefing stories and 2 notified ones make the badge 10, not 3,454")
        assertEqual(badge(read.union(["story-5"])), 9, "Reading a Briefing story lowers the badge at once")
        assertEqual(badge(read, notified: notified.union(["story-6"])), 10, "A notified Briefing story counts once")
        assertEqual(badge(read.union(notified)), 8, "Read notified stories no longer count")
        let yesterday = FiniteBriefing.editionStart(now: now, hour: 7).addingTimeInterval(-60)
        assertEqual(badge(read, selectedAt: yesterday), 2, "An edition from before the edition hour counts nothing")
        assertEqual(badge(Set(library)), 0, "Nothing unread hides the badge")
    }

    /// #780: the Briefing carousel takes the stories with the most publishers, edition order breaking ties, and the
    /// tiles group by topic in the order the edition reaches each one, uncategorised stories last.
    static func testBriefingBoardLayout() {
        print("  - Testing the Briefing board: hero ranking by publishers and tiles grouped by topic (#780)...")
        let now = Date(timeIntervalSince1970: 1_793_372_400)
        func story(_ id: String, _ category: String?) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Story \(id)", link: "https://example.com/\(id)", guid: id, description: "",
                pubDate: now, source: "Publisher", category: category)
        }
        func event(_ id: String, _ category: String?, publishers: Int, members: Int? = nil) -> FeedEntry {
            let article = story(id, category)
            let rows = (0..<(members ?? publishers)).map { index in
                EventFeedMember(
                    articleID: index == 0 ? id : "\(id)-\(index)", source: "Outlet \(index % publishers)",
                    title: article.title, date: now, joinedVersion: 1, isRead: false, isSaved: false)
            }
            return .event(
                EventFeedSummary(eventID: "event-\(id)", membershipVersion: 1, seenVersion: nil, members: rows),
                representative: article, visibleMembers: [article])
        }
        let entries: [FeedEntry] = [
            .article(story("a", "World")), event("b", "Business", publishers: 3),
            event("c", "International", publishers: 9),
            .article(story("d", nil)), event("e", "Technology", publishers: 3, members: 7),
            event("f", "World", publishers: 5), .article(story("g", "Science")),
        ]
        assertEqual(
            entries.map(\.publisherCount), [1, 3, 9, 1, 3, 5, 1],
            "Coverage counts distinct publishers, not reports: seven reports from three outlets are three")
        assertEqual(
            BriefingView.heroEntries(entries).map(\.id), ["c", "f", "b", "e", "a"],
            "The carousel shows five stories, most publishers first, edition order breaking ties")
        assertEqual(BriefingView.heroEntries(Array(entries.prefix(2))).count, 2, "Fewer stories show what there is")
        // Original reports first (wire copies count once), then stored importance, then publishers, then edition order.
        let wireCopies = (0..<6).map { (publisher: "Daily \($0)", text: "(AP) - Same dispatch") }
        let independent = (0..<3).map { (publisher: "Paper \($0)", text: "Own reporting \($0)") }
        assertEqual(
            BriefingPriorityData.isWireCopy(text: "Israeli-occupied town reopens", publisher: "Daily Example"), false,
            "A headline with \"occupied\" is not UPI wire copy")
        let wireSignal = BriefingRanking.signal(reports: wireCopies, importance: nil)
        assertEqual(wireSignal.originalCount, 1, "Six copies of one wire dispatch count once")
        assertEqual(
            BriefingRanking.signal(reports: independent + wireCopies, importance: .major).originalCount, 4,
            "Independent reports count each, wire copies once together")
        let ranking = BriefingRanking(signals: [
            "c": wireSignal,
            "f": BriefingRanking.signal(reports: independent, importance: nil),
            "b": BriefingRanking.signal(reports: independent, importance: .major),
            "e": BriefingRanking.signal(reports: independent, importance: .minor),
        ])
        assertEqual(
            BriefingView.heroEntries(entries, ranking: ranking).map(\.id), ["b", "e", "f", "c", "a"],
            "Nine publishers of wire copy lose to three of original reporting; importance breaks the tie, a rating beats none"
        )
        assertEqual(
            BriefingThread.ranked(entries, ranking: ranking).first?.summary.eventID, "event-b",
            "The sitrep and source footprint lead with the same story as the carousel")
        let sections = BriefingView.sections(entries)
        assertEqual(
            sections.map(\.title), ["World", "Business", "Technology", "Science", BriefingView.otherSection],
            "Sections follow the edition; a feed category maps to the app's topics and no category comes last")
        assertEqual(sections[0].entries.map(\.id), ["a", "c", "f"], "A section keeps edition order")
        assertEqual(sections.flatMap(\.entries).count, entries.count, "Every story has one tile")
    }

    static func testFiniteBriefing() async throws {
        print("  - Testing bounded, balanced and frozen briefings (#162)...")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let morning = Date(timeIntervalSince1970: 1_780_000_000)  // 2026-05-28 20:26 UTC
        let dayStart = utc.startOfDay(for: morning)
        assertEqual(
            FiniteBriefing.editionStart(now: morning, hour: 7, calendar: utc), dayStart.addingTimeInterval(7 * 3600),
            "After the edition hour, today's edition is due")
        let early = dayStart.addingTimeInterval(5 * 3600)
        assertEqual(
            FiniteBriefing.editionStart(now: early, hour: 7, calendar: utc),
            dayStart.addingTimeInterval(-17 * 3600), "Before the edition hour, yesterday's edition is still due")
        assertTrue(
            FiniteBriefing.isCurrent(
                selectedAt: dayStart.addingTimeInterval(8 * 3600), now: morning, hour: 7, calendar: utc),
            "An edition selected after today's hour stays current")
        assertFalse(
            FiniteBriefing.isCurrent(
                selectedAt: dayStart.addingTimeInterval(6 * 3600), now: morning, hour: 7, calendar: utc),
            "An edition selected before today's hour is replaced")
        assertFalse(
            FiniteBriefing.isCurrent(selectedAt: morning.addingTimeInterval(60), now: morning, hour: 7, calendar: utc),
            "An edition stamped in the future is not trusted")
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        // 24 October 2026 08:00 BST; clocks go back on the 25th, so the next 07:00 is 25 hours later.
        let beforeChange = london.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: beforeChange, hour: 7, calendar: london)
        assertEqual(
            london.dateComponents([.day, .hour], from: next), DateComponents(day: 25, hour: 7),
            "The next edition keeps its local hour across a daylight-saving change")

        let now = Date(timeIntervalSince1970: 1_790_928_000)
        func article(_ id: String, age: TimeInterval, source: String = "Dominant", category: String = "Tech")
            -> FeedArticle
        {
            FeedArticle(
                storedID: id, title: "Briefing story \(id)", link: "https://example.com/briefing/\(id)",
                guid: id, description: "Publisher report \(id)", pubDate: now.addingTimeInterval(-age),
                source: source, category: category)
        }
        var candidates = (0..<40).map { article("dominant-\($0)", age: Double($0)) }
        candidates += [
            article("world", age: 100, source: "World Desk", category: "World"),
            article("science", age: 200, source: "Science Desk", category: "Science"),
            article("read", age: 0), article("old", age: FiniteBriefing.duration + 1),
            article("future", age: -1), article("boundary", age: FiniteBriefing.duration),
        ]
        var undated = article("undated", age: 0)
        undated = FeedArticle(
            storedID: undated.id, title: undated.title, link: undated.link,
            guid: undated.guid, description: undated.description, pubDate: DateParser.unknownDate,
            source: undated.source)
        candidates.append(undated)
        let session = FiniteBriefing(candidates: candidates + [candidates[0]], readIDs: ["read"], now: now)
        assertEqual(session.articles.count, 4, "The briefing caps a dominant publisher at two stories")
        assertEqual(Set(session.articles.map(\.id)).count, 4, "Duplicate candidates cannot consume slots")
        assertEqual(
            Array(session.articles.prefix(3).map(\.id)), ["dominant-0", "world", "science"],
            "Recency ties break a source/category mix deterministically")
        assertFalse(
            session.articles.contains { ["read", "old", "future", "undated"].contains($0.id) },
            "Read, old, future and undated stories stay out")
        let frozen = session.articles
        candidates.insert(article("arriving-later", age: 0), at: 0)
        assertEqual(session.articles, frozen, "Incoming stories cannot change an existing selection")
        let allRead = Set(session.articles.map(\.id))
        assertTrue(session.isComplete(allRead), "Reading all selected stories completes the briefing")
        assertEqual(session.readCount([session.articles[0].id]), 1, "Completion follows article read state")
        assertFalse(session.isComplete([]), "An unread briefing is incomplete")
        assertFalse(
            FiniteBriefing(candidates: [], readIDs: [], now: now).isComplete([]),
            "An empty window is not a completed briefing")

        let ranked = [
            article("covered", age: 200), article("major", age: 0),
            article("stored", age: 100), article("neutral", age: 20), article("minor", age: 10),
        ]
        let priority: [String: BriefingPriority] = [
            "covered": .init(sourceCount: 3, importance: .minor),
            "major": .init(sourceCount: 1, importance: .major),
            "stored": .init(sourceCount: 2, importance: .major),
            "neutral": .init(sourceCount: 2),
            "minor": .init(sourceCount: 2, importance: .minor),
        ]
        assertEqual(
            FiniteBriefing(candidates: ranked, readIDs: [], now: now, priorities: priority).articles.map(\.id),
            ["covered", "minor"],
            "Coverage precedes recency when importance is removed; one publisher cannot occupy the briefing")

        let personalized = [
            article("general", age: 0, source: "General", category: "World"),
            article("interest", age: 20, source: "Science Desk", category: "Science"),
            article("duplicate-event", age: 10, source: "Other", category: "Science"),
        ]
        let personalizedBriefing = FiniteBriefing(
            candidates: personalized, readIDs: [], now: now,
            priorities: ["interest": .init(eventID: "one-event"), "duplicate-event": .init(eventID: "one-event")],
            interests: ["science": 3])
        assertEqual(
            personalizedBriefing.articles.first?.id, "duplicate-event",
            "Interest breaks coverage ties before recency")
        assertEqual(personalizedBriefing.articles.count, 2, "One event cannot consume two briefing slots")

        // Direct unit tests for FiniteBriefing.rank contract
        let r1 = FiniteBriefing.rank(
            priority: .init(sourceCount: 3), interest: 0, sourceCount: 0, categoryCount: 0)
        let r2 = FiniteBriefing.rank(
            priority: .init(sourceCount: 1), interest: 5, sourceCount: 0, categoryCount: 0)
        assertTrue(r2.lexicographicallyPrecedes(r1), "Source coverage precedes interest")
        let r3 = FiniteBriefing.rank(
            priority: .init(sourceCount: 2), interest: 3, sourceCount: 1, categoryCount: 1)
        assertEqual(
            r3, [2, 3, -2, -1],
            "Rank vector formula matches [sourceCount, interest, -(sources + categories), -sources]")

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        _ = try await db.upsertArticles(candidates)
        try await db.markRead(articleId: "read", isRead: true)
        let fetched = try await db.fetchArticles(
            isRead: false, limit: 500,
            publicationWindow: now.addingTimeInterval(-FiniteBriefing.duration)...now)
        let ids = Set(fetched.map(\.id))
        assertTrue(ids.contains("boundary"), "The lower time boundary is included")
        assertFalse(
            ids.contains("old") || ids.contains("future") || ids.contains("undated") || ids.contains("read"),
            "SQLite filters the exact window and read state before selection")
        assertEqual(
            try await db.fetchArticles(limit: nil).count, candidates.count, "The briefing leaves archive access intact")

        // Test non-destructive briefing interests reset
        let testNow = Date(timeIntervalSince1970: 1_700_000_000)
        let interestsDb = DatabaseEngine(path: ":memory:")
        try await interestsDb.open()
        let testArticles = [
            article("int-tech", age: 0, category: "Technology"),
            article("int-science", age: 0, category: "Science"),
            article("int-politics", age: 0, category: "Politics"),
            article("int-old", age: 0, category: "Business"),
        ]
        _ = try await interestsDb.upsertArticles(testArticles)

        let tenDaysAgo = testNow.addingTimeInterval(-10 * 86400)
        try await interestsDb.markRead(articleId: "int-tech", isRead: true)
        _ = try await interestsDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(tenDaysAgo.timeIntervalSince1970), .text("int-tech")])

        let twoDaysAgo = testNow.addingTimeInterval(-2 * 86400)
        try await interestsDb.markRead(articleId: "int-science", isRead: true)
        _ = try await interestsDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(twoDaysAgo.timeIntervalSince1970), .text("int-science")])

        let oneDayAgo = testNow.addingTimeInterval(-1 * 86400)
        try await interestsDb.setSaved(articleId: "int-politics", isSaved: true)
        _ = try await interestsDb.eventRows(
            "UPDATE article_state SET saved_at = ? WHERE article_id = ?;",
            [.real(oneDayAgo.timeIntervalSince1970), .text("int-politics")])

        let thirtyFiveDaysAgo = testNow.addingTimeInterval(-35 * 86400)
        try await interestsDb.markRead(articleId: "int-old", isRead: true)
        _ = try await interestsDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(thirtyFiveDaysAgo.timeIntervalSince1970), .text("int-old")])

        // 1. Without resetAt: respects 30-day window (excludes 35-day-old article)
        let defaultInterests = try await interestsDb.briefingInterests(now: testNow)
        assertEqual(defaultInterests["technology"], 1, "Read tech story within 30 days scores 1")
        assertEqual(defaultInterests["science"], 1, "Read science story within 30 days scores 1")
        assertEqual(defaultInterests["politics"], 3, "Saved politics story within 30 days scores 3")
        assertTrue(defaultInterests["business"] == nil, "Business story older than 30 days excluded")

        // 2. With resetAt = 5 days ago: excludes tech (10 days ago), keeps science (2 days ago) and politics (1 day ago)
        let reset5DaysAgo = testNow.addingTimeInterval(-5 * 86400)
        let resetInterests = try await interestsDb.briefingInterests(now: testNow, resetAt: reset5DaysAgo)
        assertTrue(resetInterests["technology"] == nil, "Tech story read before reset cutoff is excluded")
        assertEqual(resetInterests["science"], 1, "Science story read after reset cutoff is retained")
        assertEqual(resetInterests["politics"], 3, "Politics story saved after reset cutoff is retained")

        // 3. With resetAt = testNow: interests are completely cleared
        let clearedInterests = try await interestsDb.briefingInterests(now: testNow, resetAt: testNow)
        assertTrue(clearedInterests.isEmpty, "Resetting to now produces zero inferred interests")

        // 3b. Notification triage honors the reset like the Briefing does (#806)
        let triageUnreset = await FeedManager.triageInterests(database: interestsDb, now: testNow, resetAt: nil)
        assertFalse(triageUnreset.isEmpty, "Triage without a reset still ranks the read history")
        let triageReset = await FeedManager.triageInterests(database: interestsDb, now: testNow, resetAt: testNow)
        assertTrue(triageReset.isEmpty, "Triage after a reset has no interests from earlier history")

        // 4. Non-destructive assertion: read markers and bookmarks remain intact
        assertTrue(
            try await interestsDb.isRead(articleId: "int-tech"),
            "Read status preserved after interests reset")
        assertTrue(
            try await interestsDb.isRead(articleId: "int-science"),
            "Read status preserved after interests reset")
        assertTrue(
            try await interestsDb.isSaved(articleId: "int-politics"),
            "Saved status preserved after interests reset")

        try await testAdversarialDatabaseInterestsReset()
    }

    @MainActor
    static func testAdversarialDatabaseInterestsReset() async throws {
        print("  - Adversarial empirical challenge: briefingInterests boundary values & SQLite integrity...")
        let testNow = Date(timeIntervalSince1970: 1_750_000_000)

        func makeTestArticle(id: String, category: String, age: TimeInterval = 0) -> FeedArticle {
            FeedArticle(
                storedID: id,
                title: "Test Article \(id)",
                link: "https://example.com/test/\(id)",
                guid: id,
                description: "Description \(id)",
                pubDate: testNow.addingTimeInterval(-age),
                source: "Test Source",
                category: category
            )
        }

        // Test 1: Empty Database
        let emptyDb = DatabaseEngine(path: ":memory:")
        try await emptyDb.open()
        let empty1 = try await emptyDb.briefingInterests(now: testNow, resetAt: nil)
        assertTrue(empty1.isEmpty, "Empty database returns empty interests with nil resetAt")
        let empty2 = try await emptyDb.briefingInterests(now: testNow, resetAt: testNow)
        assertTrue(empty2.isEmpty, "Empty database returns empty interests with resetAt = now")
        let empty3 = try await emptyDb.briefingInterests(now: testNow, resetAt: testNow.addingTimeInterval(86400))
        assertTrue(empty3.isEmpty, "Empty database returns empty interests with future resetAt")
        await emptyDb.close()

        // Test 2: Cutoff Boundary Values (Future, Exactly 30 Days, 40 Days, Exactly Now)
        let boundaryDb = DatabaseEngine(path: ":memory:")
        try await boundaryDb.open()

        let artAt30d = makeTestArticle(id: "b-exact-30d", category: "Technology")
        let artOlder30d = makeTestArticle(id: "b-older-30d", category: "Technology")
        let artNewer30d = makeTestArticle(id: "b-newer-30d", category: "Technology")
        let artAt35d = makeTestArticle(id: "b-35d", category: "Business")
        let artAt45d = makeTestArticle(id: "b-45d", category: "Business")
        let artAt10d = makeTestArticle(id: "b-10d", category: "Science")
        let artAt1d = makeTestArticle(id: "b-1d", category: "World")
        let artAtNow = makeTestArticle(id: "b-now", category: "Politics")

        _ = try await boundaryDb.upsertArticles([
            artAt30d, artOlder30d, artNewer30d, artAt35d, artAt45d, artAt10d, artAt1d, artAtNow,
        ])

        let thirtyDaysSeconds = 30.0 * 86400.0
        let tExact30d = testNow.addingTimeInterval(-thirtyDaysSeconds)
        let tOlder30d = testNow.addingTimeInterval(-thirtyDaysSeconds - 2.0)
        let tNewer30d = testNow.addingTimeInterval(-thirtyDaysSeconds + 2.0)
        let t35d = testNow.addingTimeInterval(-35.0 * 86400.0)
        let t45d = testNow.addingTimeInterval(-45.0 * 86400.0)
        let t10d = testNow.addingTimeInterval(-10.0 * 86400.0)
        let t1d = testNow.addingTimeInterval(-1.0 * 86400.0)
        let tNow = testNow

        // Set read/saved timestamps in article_state
        try await boundaryDb.markRead(articleId: "b-exact-30d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(tExact30d.timeIntervalSince1970), .text("b-exact-30d")])

        try await boundaryDb.markRead(articleId: "b-older-30d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(tOlder30d.timeIntervalSince1970), .text("b-older-30d")])

        try await boundaryDb.markRead(articleId: "b-newer-30d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(tNewer30d.timeIntervalSince1970), .text("b-newer-30d")])

        try await boundaryDb.markRead(articleId: "b-35d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(t35d.timeIntervalSince1970), .text("b-35d")])

        try await boundaryDb.markRead(articleId: "b-45d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(t45d.timeIntervalSince1970), .text("b-45d")])

        try await boundaryDb.markRead(articleId: "b-10d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(t10d.timeIntervalSince1970), .text("b-10d")])

        try await boundaryDb.setSaved(articleId: "b-1d", isSaved: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET saved_at = ? WHERE article_id = ?;",
            [.real(t1d.timeIntervalSince1970), .text("b-1d")])

        try await boundaryDb.markRead(articleId: "b-now", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(tNow.timeIntervalSince1970), .text("b-now")])

        // 2a. Boundary: resetAt exactly 30 days ago (resetAt == thirtyDaysAgo)
        // Technology should include exact-30d (1 pt) + newer-30d (1 pt) = 2 pts. Older-30d is excluded.
        let interests30d = try await boundaryDb.briefingInterests(now: testNow, resetAt: tExact30d)
        assertEqual(
            interests30d["technology"], 2,
            "Exact 30-day cutoff includes interaction at exact boundary and newer, excludes older")

        // 2b. Boundary: resetAt 40 days ago (resetAt < thirtyDaysAgo)
        // Even though resetAt is 40 days ago, 30-day window max(thirtyDaysAgo, resetAt) must prevail.
        // Therefore, b-35d and b-45d (Business) must NOT appear in interests.
        let t40d = testNow.addingTimeInterval(-40.0 * 86400.0)
        let interests40d = try await boundaryDb.briefingInterests(now: testNow, resetAt: t40d)
        assertTrue(interests40d["business"] == nil, "resetAt 40 days ago cannot bypass 30-day maximum lookback")
        assertEqual(interests40d["technology"], 2, "Technology interactions within 30 days still scored")
        assertEqual(interests40d["science"], 1, "Science 10d interaction scored")
        assertEqual(interests40d["world"], 3, "World 1d saved interaction scored 3")

        // 2c. Boundary: resetAt in the future (resetAt > now)
        let tFuture = testNow.addingTimeInterval(3600)
        let interestsFuture = try await boundaryDb.briefingInterests(now: testNow, resetAt: tFuture)
        assertTrue(interestsFuture.isEmpty, "Future resetAt produces empty interests dictionary without error")

        // 2d. Boundary: resetAt == now
        // An interaction with read_at strictly before now is excluded.
        let interestsNow = try await boundaryDb.briefingInterests(now: testNow, resetAt: testNow)
        assertTrue(
            interestsNow["technology"] == nil,
            "Technology interactions prior to now excluded when resetAt == now")
        assertTrue(
            interestsNow["science"] == nil,
            "Science interactions prior to now excluded when resetAt == now")
        assertTrue(
            interestsNow["world"] == nil,
            "World interactions prior to now excluded when resetAt == now")

        // Call with resetAt strictly after the latest interaction:
        let interestsAfterAll = try await boundaryDb.briefingInterests(
            now: testNow, resetAt: testNow.addingTimeInterval(0.001))
        assertTrue(interestsAfterAll.isEmpty, "Resetting after all interactions produces completely empty interests")

        // Test 3: Exactly 200 interaction records
        let limitDb = DatabaseEngine(path: ":memory:")
        try await limitDb.open()

        var articles200: [FeedArticle] = []
        for i in 0..<100 {
            articles200.append(makeTestArticle(id: "tech-200-\(i)", category: "Technology"))
        }
        for i in 0..<100 {
            articles200.append(makeTestArticle(id: "sci-200-\(i)", category: "Science"))
        }
        _ = try await limitDb.upsertArticles(articles200)

        for i in 0..<100 {
            let artId = "tech-200-\(i)"
            try await limitDb.markRead(articleId: artId, isRead: true)
            let stamp = testNow.addingTimeInterval(-Double(i + 1) * 3600.0)
            _ = try await limitDb.eventRows(
                "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
                [.real(stamp.timeIntervalSince1970), .text(artId)])
        }
        for i in 0..<100 {
            let artId = "sci-200-\(i)"
            try await limitDb.setSaved(articleId: artId, isSaved: true)
            let stamp = testNow.addingTimeInterval(-Double(i + 1) * 3600.0)
            _ = try await limitDb.eventRows(
                "UPDATE article_state SET saved_at = ? WHERE article_id = ?;",
                [.real(stamp.timeIntervalSince1970), .text(artId)])
        }

        let interests200 = try await limitDb.briefingInterests(now: testNow)
        assertEqual(interests200["technology"], 100, "Exactly 100 read articles score 100 points")
        assertEqual(interests200["science"], 300, "Exactly 100 saved articles score 300 points")

        // Test 4: >200 records (e.g., 250 records testing recency DESC and LIMIT 200 truncation)
        // Add 50 Business articles that were read 20 days ago (older than the 200 Tech & Science articles)
        var articles50Extra: [FeedArticle] = []
        for i in 0..<50 {
            articles50Extra.append(makeTestArticle(id: "biz-extra-\(i)", category: "Business"))
        }
        _ = try await limitDb.upsertArticles(articles50Extra)
        for i in 0..<50 {
            let artId = "biz-extra-\(i)"
            try await limitDb.markRead(articleId: artId, isRead: true)
            let oldStamp = testNow.addingTimeInterval(-20.0 * 86400.0 - Double(i))
            _ = try await limitDb.eventRows(
                "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
                [.real(oldStamp.timeIntervalSince1970), .text(artId)])
        }

        // Total interactions in limitDb = 250.
        // Because briefingInterests has LIMIT 200 ORDER BY interaction DESC,
        // the 200 newest (100 Tech + 100 Science) should consume all 200 slots.
        // The 50 older Business articles must be truncated out!
        let interests250 = try await limitDb.briefingInterests(now: testNow)
        assertEqual(interests250["technology"], 100, "Top 200 keeps all recent Technology reads")
        assertEqual(interests250["science"], 300, "Top 200 keeps all recent Science saves")
        assertTrue(interests250["business"] == nil, "50 older interactions truncated by LIMIT 200 clause")

        // Test 5: 100% User Data Integrity in SQLite article_state
        struct ArticleStateRow: Equatable {
            let articleId: String
            let isRead: String
            let readAt: String
            let isSaved: String
            let savedAt: String
        }

        func queryArticleStates(engine: DatabaseEngine) async throws -> [ArticleStateRow] {
            let sql = """
                SELECT article_id, coalesce(is_read, '0'), coalesce(read_at, 'null'),
                       coalesce(is_saved, '0'), coalesce(saved_at, 'null')
                FROM article_state ORDER BY article_id;
                """
            let rows = try await engine.eventRows(sql)
            return rows.map { r in
                ArticleStateRow(
                    articleId: r[0] ?? "",
                    isRead: r[1] ?? "",
                    readAt: r[2] ?? "",
                    isSaved: r[3] ?? "",
                    savedAt: r[4] ?? ""
                )
            }
        }

        let stateSnapshotBefore = try await queryArticleStates(engine: boundaryDb)
        assertTrue(!stateSnapshotBefore.isEmpty, "article_state is populated before reset tests")

        // Call briefingInterests with many different resetAt values repeatedly
        _ = try await boundaryDb.briefingInterests(now: testNow, resetAt: testNow)
        _ = try await boundaryDb.briefingInterests(now: testNow, resetAt: tFuture)
        _ = try await boundaryDb.briefingInterests(now: testNow, resetAt: t1d)
        _ = try await boundaryDb.briefingInterests(now: testNow, resetAt: t40d)
        _ = try await boundaryDb.briefingInterests(now: testNow, resetAt: nil)

        let stateSnapshotAfter = try await queryArticleStates(engine: boundaryDb)
        assertEqual(
            stateSnapshotBefore.count, stateSnapshotAfter.count,
            "article_state row count is 100% unchanged after resetAt calls")
        assertEqual(
            stateSnapshotBefore, stateSnapshotAfter,
            "Every single field of article_state (is_read, read_at, is_saved, saved_at) is 100% bit-for-bit preserved")

        await boundaryDb.close()
        await limitDb.close()
    }

    /// Runs on the main actor: resolving an AppKit-backed Color off the main thread waits on SwiftUI's main-thread
    /// lock, which this runner's main executor never grants, so the check hung.
    @MainActor
    static func testTagTextContrast() {
        // Tinted tag text keeps 4.5:1 on its wash over the page, light and dark, with and without Increase Contrast
        // (#754). The accent path mixes from accent text, so each system accent is checked through that math.
        func srgb(_ color: Color, _ environment: EnvironmentValues, over page: Color.Resolved? = nil) -> NSColor {
            let top = color.resolve(in: environment)
            let alpha = page == nil ? 1 : top.opacity
            func channel(_ value: Float, _ under: Float?) -> CGFloat {
                CGFloat(value * alpha + (under ?? 0) * (1 - alpha))
            }
            return NSColor(
                srgbRed: channel(top.red, page?.red), green: channel(top.green, page?.green),
                blue: channel(top.blue, page?.blue), alpha: 1)
        }
        let accents: [NSColor] = [
            .systemBlue, .systemPurple, .systemPink, .systemRed, .systemOrange, .systemYellow, .systemGreen,
            .systemGray,
        ]
        for scheme in [ColorScheme.light, .dark] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                // System colors resolve differently with Increase Contrast, so each pass resolves under its own setting.
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                environment._colorSchemeContrast = contrast
                let page = AppColor.background.resolve(in: environment)
                let reference = scheme == .dark ? srgb(AppColor.background, environment) : .white
                // The accent branch mixes from accent text, whatever accent the runner has.
                assertEqual(
                    TagView.textColor(tint: AppColor.accent, contrast: contrast).resolve(in: environment),
                    TagView.textColor(tint: AppColor.accentText, contrast: contrast).resolve(in: environment),
                    "Accent tag text mixes from accent text (\(scheme), \(contrast))")
                var pairs: [(String, Color, Color)] = [
                    ("current accent", TagView.textColor(tint: AppColor.accent, contrast: contrast), AppColor.accent)
                ]
                // readableAccent reads the system colors under the current AppKit appearance, so it matches the pass.
                let appearance = NSAppearance(
                    named: scheme == .dark
                        ? (contrast == .increased ? .accessibilityHighContrastDarkAqua : .darkAqua)
                        : (contrast == .increased ? .accessibilityHighContrastAqua : .aqua))
                assertTrue(appearance != nil, "Appearance for \(scheme), \(contrast) exists")
                for accent in accents {
                    var readable = accent
                    appearance?.performAsCurrentDrawingAppearance {
                        readable = AppColor.readableAccent(accent, dark: scheme == .dark, on: reference)
                    }
                    let base = Color(nsColor: readable)
                    pairs.append(
                        ("\(accent)", TagView.textColor(tint: base, contrast: contrast), Color(nsColor: accent)))
                }
                for (name, text, tint) in pairs {
                    let wash = srgb(TagView.fill(tint: tint, contrast: contrast), environment, over: page)
                    assertTrue(
                        AppColor.contrastRatio(srgb(text, environment), wash) >= 4.5,
                        "Tag text on its \(name) wash keeps 4.5:1 (\(scheme), \(contrast))")
                }
            }
        }
    }

    static func testDesignSystemAndArticleFilter() async {
        print("  - Testing Phase 4 Design System Tokens and Article Filter Query Parser...")

        // 1. Spacing tokens
        assertEqual(AppSpacing.xxs, 4.0, "AppSpacing.xxs should be 4.0")
        assertEqual(AppSpacing.xs, 8.0, "AppSpacing.xs should be 8.0")
        assertEqual(AppSpacing.sm, 12.0, "AppSpacing.sm should be 12.0")
        assertEqual(AppSpacing.md, 16.0, "AppSpacing.md should be 16.0")
        assertEqual(AppSpacing.lg, 24.0, "AppSpacing.lg should be 24.0")

        // 2. Radius tokens
        assertEqual(AppRadius.card, 12.0, "AppRadius.card should be 12.0")
        assertEqual(AppRadius.control, 6.0, "AppRadius.control should be 6.0")
        assertEqual(AppRadius.container, 16.0, "AppRadius.container should be 16.0")

        // 3. Layout tokens
        assertEqual(AppLayout.pageInset, 24.0, "AppLayout.pageInset should be 24.0")
        assertEqual(AppLayout.sidebarInset, 12.0, "AppLayout.sidebarInset should be 12.0")
        assertEqual(AppLayout.cardGap, 16.0, "AppLayout.cardGap should be 16.0")
        assertEqual(AppLayout.readingMeasure, 720.0, "AppLayout.readingMeasure should be 720.0")
        assertEqual(AppLayout.listMaxWidth, 1000.0, "AppLayout.listMaxWidth should be 1000.0")
        assertEqual(AppLayout.gridColumnMinimum, 300.0, "AppLayout.gridColumnMinimum should be 300.0")
        assertEqual(AppLayout.gridColumnMaximum, 420.0, "AppLayout.gridColumnMaximum should be 420.0")
        assertEqual(AppSpacing.textStack, 2.0, "AppSpacing.textStack should be 2.0")
        assertEqual(AppSpacing.eyebrowGap, 6.0, "AppSpacing.eyebrowGap should be 6.0")
        assertEqual(AppTypography.eyebrowTracking, 0.5, "AppTypography.eyebrowTracking should be 0.5")

        // 4. Ghost Typography Theme tokens
        assertEqual(AppTypography.bodyLineSpacing(for: .casper), 10.0, "Casper theme line spacing should be 10")
        assertEqual(AppTypography.bodyLineSpacing(for: .edition), 8.0, "Edition theme line spacing should be 8")
        assertEqual(AppTypography.bodyLineSpacing(for: .alto), 12.0, "Alto theme line spacing should be 12")

        await testTagTextContrast()

        // 4. ArticleFilterQuery structured parsing
        let complexQuery = "source:Bloomberg category:Tech is:unread apple silicon"
        let parsed = ArticleFilterQuery.parse(complexQuery)
        assertEqual(parsed.sourceFilter, "bloomberg", "Should parse source: operator")
        assertEqual(parsed.categoryFilter, "tech", "Should parse category: operator")
        assertEqual(parsed.isReadFilter, false, "Should parse is:unread operator")
        assertEqual(parsed.terms, ["apple", "silicon"], "Should extract search terms")

        // 5. Article matching logic
        let art1 = FeedArticle(
            title: "Apple introduces M4 Max Silicon",
            link: "https://bloomberg.com/news/apple-m4",
            guid: "test-art-1",
            description: "New chip delivers record performance",
            pubDate: Date(),
            source: "Bloomberg",
            category: "Technology"
        )
        let art2 = FeedArticle(
            title: "Federal Reserve holds interest rates steady",
            link: "https://wsj.com/fed-rates",
            guid: "test-art-2",
            description: "Central bank maintains current policy stance",
            pubDate: Date(),
            source: "Wall Street Journal",
            category: "Economy"
        )

        assertTrue(parsed.matches(article: art1, isRead: false, isSaved: false), "Article 1 should match query")
        assertFalse(
            parsed.matches(article: art1, isRead: true, isSaved: false), "Article 1 should fail because it is read")
        assertFalse(
            parsed.matches(article: art2, isRead: false, isSaved: false), "Article 2 should fail source/terms match")

        // 6. Settings Pane Bounds and Section Header Tracking (#475)
        assertEqual(AppLayout.settingsPaneWidth, 720.0, "AppLayout.settingsPaneWidth should be 720.0")
        assertEqual(AppLayout.settingsPaneHeight, 560.0, "AppLayout.settingsPaneHeight should be 560.0")
        assertEqual(AppTypography.sectionHeaderTracking, 0.6, "AppTypography.sectionHeaderTracking should be 0.6")

        // 7. ArchiveSearchToken Semantic Display Names and Symbols (#475)
        let unreadToken = ArchiveSearchToken(completedExpression: "is:unread")!
        assertEqual(unreadToken.displayName, "Unread", "Unread token has display name Unread")
        assertEqual(unreadToken.systemImage, "circle.circle", "Unread token uses circle.circle")

        let readToken = ArchiveSearchToken(completedExpression: "is:read")!
        assertEqual(readToken.displayName, "Read", "Read token has display name Read")
        assertEqual(readToken.systemImage, "checkmark.circle", "Read token uses checkmark.circle")

        let savedToken = ArchiveSearchToken(completedExpression: "is:saved")!
        assertEqual(savedToken.displayName, "Saved", "Saved token has display name Saved")
        assertEqual(savedToken.systemImage, "bookmark", "Saved token uses bookmark")

        let sourceToken = ArchiveSearchToken(completedExpression: "source:reuters")!
        assertEqual(sourceToken.displayName, "Source: reuters", "Source token has formatted display name")
        assertEqual(sourceToken.systemImage, "newspaper", "Source token uses newspaper")

        let categoryToken = ArchiveSearchToken(completedExpression: "category:science")!
        assertEqual(categoryToken.displayName, "Category: science", "Category token has formatted display name")
        assertEqual(categoryToken.systemImage, "tag", "Category token uses tag")

        let fallbackToken = ArchiveSearchToken(expression: "custom:term")
        assertEqual(fallbackToken.displayName, "custom:term", "Fallback token keeps raw expression")
        assertEqual(fallbackToken.systemImage, "magnifyingglass", "Fallback token uses magnifyingglass")

        // 8. ArticleSearchState tag search transformations and navigation breadcrumbs (#930)
        // Category token generation and sanitization
        assertEqual(
            ArticleSearchState.sanitizeCategory("Science"),
            "science",
            "Category sanitization lowercases and trims"
        )
        assertEqual(
            ArticleSearchState.sanitizeCategory("category:Science"),
            "science",
            "Category sanitization strips existing category: prefix"
        )
        assertEqual(
            ArticleSearchState.sanitizeCategory("  World  News  "),
            "world-news",
            "Multi-word category converts whitespace runs to hyphens"
        )
        assertEqual(
            ArticleSearchState.sanitizeCategory("Économie & Finance"),
            "économie-&-finance",
            "Category sanitization preserves diacritics"
        )
        assertEqual(
            ArticleSearchState.categoryToken(for: "Science").expression,
            "category:science",
            "Category token produces category: prefix"
        )
        assertEqual(
            ArticleSearchState.categoryToken(for: "Technology").displayName,
            "Category: technology",
            "Category token has human-readable display name"
        )
        assertEqual(
            ArticleSearchState.categoryToken(for: "Science").systemImage,
            "tag",
            "Category token uses tag SF Symbol"
        )

        // Entity phrase query generation and sanitization
        assertEqual(
            ArticleSearchState.sanitizeEntityName("Cold Fusion"),
            "Cold Fusion",
            "Entity sanitization preserves title casing"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("\"Cold Fusion\""),
            "Cold Fusion",
            "Entity sanitization strips existing surrounding quotes"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("“Cold Fusion”"),
            "Cold Fusion",
            "Entity sanitization strips curly quotes"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("«Cold Fusion»"),
            "Cold Fusion",
            "Entity sanitization strips guillemets"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("Beyoncé"),
            "Beyoncé",
            "Entity sanitization preserves diacritics"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("Apple Inc."),
            "Apple Inc.",
            "Entity sanitization preserves punctuation"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("Dwight \"The Rock\" Johnson"),
            "Dwight 'The Rock' Johnson",
            "Internal double quotes become single quotes"
        )
        assertEqual(
            ArticleSearchState.entityQuery(for: "Cold Fusion"),
            "\"Cold Fusion\"",
            "Entity query wraps name in phrase quotes"
        )
        assertEqual(
            ArticleSearchState.entityQuery(for: "\"Cold Fusion\""),
            "\"Cold Fusion\"",
            "Already quoted entity is not double-quoted"
        )
        assertEqual(
            ArticleSearchState.entityQuery(for: "   "),
            "",
            "Empty entity produces empty query"
        )

        // Combined searchQuery helper and ArticleFilterQuery compatibility
        let catQuery = ArticleSearchState.searchQuery(for: "Science", isCategory: true)
        assertEqual(catQuery.token?.expression, "category:science", "Category query sets token")
        assertEqual(catQuery.text, "", "Category query has empty text")
        assertEqual(catQuery.query, "category:science", "Combined query string matches token")
        let parsedCat = ArticleFilterQuery.parse(catQuery.query)
        assertEqual(parsedCat.categoryFilter, "science", "ArticleFilterQuery extracts category from query")

        let entQuery = ArticleSearchState.searchQuery(for: "Cold Fusion", isCategory: false)
        assertEqual(entQuery.token, nil, "Entity query has no token")
        assertEqual(entQuery.text, "\"Cold Fusion\"", "Entity query wraps phrase in quotes")
        assertEqual(entQuery.query, "\"Cold Fusion\"", "Combined entity query is quoted phrase")
        let parsedEnt = ArticleFilterQuery.parse(entQuery.query)
        assertEqual(parsedEnt.terms, ["cold fusion"], "ArticleFilterQuery retains the entity phrase")
        let mixed = ArticleFilterQuery.parse("climate \"Cold Fusion\" is:unread")
        assertEqual(mixed.terms, ["climate", "cold fusion"], "Mixed words and phrases remain distinct")
        assertEqual(mixed.isReadFilter, false, "An operator outside the phrase still applies")
        assertEqual(ArticleFilterQuery.parse("\"is:read\"").terms, ["is:read"], "A quoted operator is text")

        // State & Navigation breadcrumb round trip
        await MainActor.run {
            let testSearchState = ArticleSearchState()
            assertEqual(testSearchState.isSearching, false, "Initial search state is not searching")
            assertEqual(testSearchState.returnStory, nil, "Initial return story is nil")

            var navPath = NavigationPath()
            let wrapA = FeedArticleWrap(article: art1, contextArticles: [art1, art2])
            navPath.append(wrapA)
            assertEqual(navPath.count, 1, "Navigation path has originating story")

            // Clicking a tag opens search, empties path, saves breadcrumb
            testSearchState.openTag(tag: "Cold Fusion", isCategory: false, from: wrapA, path: &navPath)
            assertEqual(navPath.count, 0, "Navigation path is cleared to reveal search results")
            assertEqual(testSearchState.isSearching, true, "Search state is active")
            assertEqual(testSearchState.searchText, "\"Cold Fusion\"", "Search text holds quoted entity")
            assertEqual(testSearchState.searchPresented, true, "Search is marked presented")
            assertEqual(testSearchState.returnStory?.article.id, art1.id, "Return story points to originating story")
            assertTrue(testSearchState.searchHistory.contains("\"Cold Fusion\""), "Search history records query")

            // Esc or Back returns to story
            testSearchState.returnToStory(path: &navPath)
            assertEqual(navPath.count, 1, "Navigation path restores originating story")
            assertEqual(testSearchState.returnStory, nil, "Return story is cleared on return")
            assertEqual(testSearchState.searchPresented, false, "Search presentation collapses on return")
            assertEqual(testSearchState.searchText, "", "Search text is cleared on return")
            assertTrue(testSearchState.consumeReturnTextChange(""), "Return reset is ignored by the text observer")
            assertFalse(testSearchState.consumeReturnTextChange(""), "A later text edit is not ignored")
            assertTrue(
                testSearchState.searchHistory.contains("\"Cold Fusion\""),
                "Search history keeps query after return")

            // Nested search tags (Story A -> tag search 1 -> Story B -> tag search 2)
            let wrapB = FeedArticleWrap(article: art2, contextArticles: [art2])
            navPath = NavigationPath()
            navPath.append(wrapA)
            testSearchState.openTag(tag: "Science", isCategory: true, from: wrapA, path: &navPath)
            assertEqual(testSearchState.searchTokens.first?.expression, "category:science", "Category token is active")
            assertEqual(testSearchState.returnStory?.article.id, art1.id, "Return story is art1")

            // User opens Story B from search results, then clicks an entity tag
            navPath.append(wrapB)
            testSearchState.openTag(tag: "AI Silicon", isCategory: false, from: wrapB, path: &navPath)
            assertEqual(testSearchState.returnStory?.article.id, art2.id, "Top return story is art2")

            // First Back returns to Story B
            testSearchState.returnToStory(path: &navPath)
            assertEqual(navPath.count, 1, "Restored Story B")

            assertTrue(testSearchState.consumeReturnTextChange(""), "Nested return ignores its text reset")
            // A token search reset is tracked independently from text.
            testSearchState.searchTokens = [ArticleSearchState.categoryToken(for: "Science")]
            // Second Back returns to Story A
            testSearchState.returnToStory(path: &navPath)
            assertEqual(navPath.count, 2, "Restored Story A")
            assertTrue(testSearchState.consumeReturnTokensChange([]), "Return ignores the token reset")
            assertFalse(testSearchState.consumeReturnTokensChange([]), "A later token edit is not ignored")
            assertEqual(testSearchState.returnStory, nil, "Return stack is now empty")

            testSearchState.openTag(tag: "Cold Fusion", isCategory: false, from: wrapA, path: &navPath)
            testSearchState.searchTokens = [ArticleSearchState.categoryToken(for: "Science")]
            testSearchState.returnToStory(path: &navPath)
            testSearchState.cancelPendingReturnChanges()
            assertFalse(testSearchState.consumeReturnTextChange(""), "A real edit cancels text reset suppression")
            assertFalse(testSearchState.consumeReturnTokensChange([]), "A real edit cancels token reset suppression")
        }
    }

    @MainActor
    static func testNewsURLParserAndSchemeRouting() async {
        print("  - Testing NewsURLParser URL Schemes, Insecure HTTP Gating, and Deep Linking...")

        // 1. Standard feed:// scheme normalizes to https://
        let u1 = URL(string: "feed://example.com/rss.xml")!
        let d1 = NewsURLParser.parse(url: u1, allowInsecureHTTP: false)
        assertEqual(
            d1, .addFeed(url: URL(string: "https://example.com/rss.xml")!),
            "Standard feed:// normalizes to https://")

        // 2. feed:https:// scheme
        let u2 = URL(string: "feed:https://example.com/feed.atom")!
        let d2 = NewsURLParser.parse(url: u2, allowInsecureHTTP: false)
        assertEqual(
            d2, .addFeed(url: URL(string: "https://example.com/feed.atom")!),
            "feed:https:// normalizes cleanly")

        // 3. feed://https:// double-slash composite scheme
        let u3 = URL(string: "feed://https://example.com/feed.atom")!
        let d3 = NewsURLParser.parse(url: u3, allowInsecureHTTP: false)
        assertEqual(
            d3, .addFeed(url: URL(string: "https://example.com/feed.atom")!),
            "feed://https:// normalizes cleanly")

        // 4. Insecure HTTP upgrade when allowInsecureHTTP is false
        let u4 = URL(string: "feed:http://insecure.example.com/rss")!
        let d4 = NewsURLParser.parse(url: u4, allowInsecureHTTP: false)
        assertEqual(
            d4, .addFeed(url: URL(string: "https://insecure.example.com/rss")!),
            "feed:http:// upgraded to https:// when insecure HTTP disallowed")

        let u4b = URL(string: "feed://http://insecure.example.com/rss")!
        let d4b = NewsURLParser.parse(url: u4b, allowInsecureHTTP: false)
        assertEqual(
            d4b, .addFeed(url: URL(string: "https://insecure.example.com/rss")!),
            "feed://http:// upgraded to https:// when insecure HTTP disallowed")

        // 5. Insecure HTTP preserved when allowInsecureHTTP is true
        let u5 = URL(string: "feed:http://insecure.example.com/rss")!
        let d5 = NewsURLParser.parse(url: u5, allowInsecureHTTP: true)
        assertEqual(
            d5, .addFeed(url: URL(string: "http://insecure.example.com/rss")!),
            "feed:http:// preserved when insecure HTTP allowed")

        let u5b = URL(string: "feed://http://insecure.example.com/rss")!
        let d5b = NewsURLParser.parse(url: u5b, allowInsecureHTTP: true)
        assertEqual(
            d5b, .addFeed(url: URL(string: "http://insecure.example.com/rss")!),
            "feed://http:// preserved when insecure HTTP allowed")

        // 6. Slashed feeds retain meaningful trailing slash
        let u6 = URL(string: "feed://example.com/feed/")!
        let d6 = NewsURLParser.parse(url: u6, allowInsecureHTTP: false)
        assertEqual(
            d6, .addFeed(url: URL(string: "https://example.com/feed/")!),
            "Meaningful trailing slash preserved")

        // 7. Feeds with custom ports
        let u7 = URL(string: "feed://example.com:8080/feed.xml")!
        let d7 = NewsURLParser.parse(url: u7, allowInsecureHTTP: false)
        assertEqual(
            d7, .addFeed(url: URL(string: "https://example.com:8080/feed.xml")!),
            "Port 8080 preserved in normalized feed URL")

        // 8. Story deep linking: news://story/<id>
        let u8 = URL(string: "news://story/story-uuid-1234")!
        let d8 = NewsURLParser.parse(url: u8, allowInsecureHTTP: false)
        assertEqual(
            d8, .story(id: "story-uuid-1234"),
            "news://story/<id> extracts story ID")

        // 9. Story deep linking with trailing slash
        let u9 = URL(string: "news://story/story-uuid-5678/")!
        let d9 = NewsURLParser.parse(url: u9, allowInsecureHTTP: false)
        assertEqual(
            d9, .story(id: "story-uuid-5678"),
            "Trailing slash trimmed from story ID")

        // 10. Story deep linking with percent encoding
        let u10 = URL(string: "news://story/story%20id%20with%20spaces")!
        let d10 = NewsURLParser.parse(url: u10, allowInsecureHTTP: false)
        assertEqual(
            d10, .story(id: "story id with spaces"),
            "Percent-encoded story ID decoded")

        let u10b = URL(string: "news://story/https%3A%2F%2Fexample.com%2Fstory%25201%2F")!
        assertEqual(
            NewsURLParser.parse(url: u10b, allowInsecureHTTP: false),
            .story(id: "https://example.com/story%201/"),
            "Percent-encoded story ID is decoded exactly once and keeps encoded slashes")

        let u10c = URL(string: "news:story/https://example.com/story%25201")!
        assertEqual(
            NewsURLParser.parse(url: u10c, allowInsecureHTTP: false),
            .story(id: "https://example.com/story%201"),
            "Opaque news:story/ URL keeps double slashes and decodes once")

        // 11. Malformed and empty feeds safely rejected
        assertEqual(NewsURLParser.parse(urlString: "feed:", allowInsecureHTTP: false), nil, "Bare feed: rejected")
        assertEqual(NewsURLParser.parse(urlString: "feed://", allowInsecureHTTP: false), nil, "Bare feed:// rejected")
        assertEqual(NewsURLParser.parse(urlString: "feed:///", allowInsecureHTTP: false), nil, "Bare feed:/// rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "feed://   ", allowInsecureHTTP: false), nil, "Whitespace feed rejected")

        // 12. Disallowed protocols rejected
        assertEqual(
            NewsURLParser.parse(urlString: "feed:javascript:alert(1)", allowInsecureHTTP: false), nil,
            "javascript: rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "feed:file:///etc/passwd", allowInsecureHTTP: false), nil, "file: rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "feed://ftp://example.com/feed", allowInsecureHTTP: false), nil,
            "ftp: rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "feed:data:text/html,bad", allowInsecureHTTP: false), nil, "data: rejected")

        // 13. Malformed news URLs rejected
        assertEqual(
            NewsURLParser.parse(urlString: "news://story", allowInsecureHTTP: false), nil, "Missing ID rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "news://story/", allowInsecureHTTP: false), nil, "Slash with no ID rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "news://article/123", allowInsecureHTTP: false), nil,
            "Wrong host 'article' rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "news://settings/account", allowInsecureHTTP: false), nil,
            "Wrong host 'settings' rejected")

        // 14. Unrelated schemes rejected
        assertEqual(
            NewsURLParser.parse(urlString: "https://example.com/rss", allowInsecureHTTP: false), nil,
            "Direct https scheme rejected by parser")
        assertEqual(
            NewsURLParser.parse(urlString: "http://example.com/rss", allowInsecureHTTP: false), nil,
            "Direct http scheme rejected by parser")
        assertEqual(NewsURLParser.parse(urlString: "", allowInsecureHTTP: false), nil, "Empty string rejected")

        // 15. Duplicate feed prevention
        let suiteName = testDefaultsSuite("test.url.duplicate.prevention")
        let tempDefaults = UserDefaults(suiteName: suiteName)!
        defer { removeTestDefaults(suiteName) }
        let settings = AppSettings(defaults: tempDefaults)

        let addResult1 = settings.addFeed(url: "https://example.com/rss.xml")
        assertEqual(addResult1, "https://example.com/rss.xml", "First feed subscription succeeds")
        assertTrue(settings.hasFeed("https://example.com/rss.xml"), "Settings reports hasFeed as true")

        let addResult2 = settings.addFeed(url: "https://example.com/rss.xml")
        assertEqual(addResult2, nil, "Duplicate subscription attempt returns nil")

        let addResult3 = settings.addFeed(url: "https://example.com/rss.xml/")
        assertEqual(addResult3, nil, "Duplicate subscription attempt with slash variant returns nil")
    }

    @MainActor
    static func testAppIntentsExecutionAndValidation() async {
        print("  - Testing App Intents Execution, Validation, Gating and Resolution...")

        // 1. RefreshFeedsIntent: verify title, openAppWhenRun, isolated execution and dialog
        assertEqual(RefreshFeedsIntent.title, "Refresh Feeds", "RefreshFeedsIntent title is 'Refresh Feeds'")
        assertFalse(RefreshFeedsIntent.openAppWhenRun, "RefreshFeedsIntent does not open app")

        let refreshSuite = testDefaultsSuite("test.intent.refresh")
        let refreshDefaults = UserDefaults(suiteName: refreshSuite)!
        defer { removeTestDefaults(refreshSuite) }
        let refreshSettings = AppSettings(defaults: refreshDefaults)
        let refreshStore = ArticleStore(
            database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await refreshStore.initialize()
        let refreshFeedManager = FeedManager(settings: refreshSettings, store: refreshStore, schedulesRefresh: false)

        let refreshIntent = RefreshFeedsIntent(feedManager: refreshFeedManager)
        do {
            let result = try await refreshIntent.perform()
            let dialogText = extractDialogText(from: result)
            assertTrue(
                dialogText != nil && dialogText!.contains("Feeds refreshed successfully"),
                "RefreshFeedsIntent returns confirmation dialog")
        } catch {
            assertTrue(false, "RefreshFeedsIntent perform threw: \(error)")
        }

        // Test RefreshFeedsIntent via IntentDependencyResolver
        IntentDependencyResolver.feedManagerOverride = refreshFeedManager
        defer { IntentDependencyResolver.feedManagerOverride = nil }
        let defaultRefreshIntent = RefreshFeedsIntent()
        do {
            let result = try await defaultRefreshIntent.perform()
            let dialogText = extractDialogText(from: result)
            assertTrue(
                dialogText != nil && dialogText!.contains("Feeds refreshed successfully"),
                "Default RefreshFeedsIntent uses IntentDependencyResolver")
        } catch {
            assertTrue(false, "Default RefreshFeedsIntent perform threw: \(error)")
        }

        // 2. AddFeedIntent: parameters, validation, duplicate prevention, and insecure HTTP gating
        assertEqual(AddFeedIntent.title, "Add Feed", "AddFeedIntent title is 'Add Feed'")
        assertFalse(AddFeedIntent.openAppWhenRun, "AddFeedIntent does not open app")

        let addSuite = testDefaultsSuite("test.intent.addfeed")
        let addDefaults = UserDefaults(suiteName: addSuite)!
        defer { removeTestDefaults(addSuite) }
        let addSettings = AppSettings(defaults: addDefaults)
        // Adding goes through FeedManager (#798), so the feed is fetched at once; the stub records the fetch.
        let addFetches = TestRecorder()
        let addStore = ArticleStore(
            database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await addStore.initialize()
        let addManager = FeedManager(
            settings: addSettings, store: addStore, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                await addFetches.record(urls)
                return urls.map { ($0, [], nil, nil) }
            })
        defer { addManager.stopBackgroundWork() }

        // Valid feed URL with default settings (allowInsecureHTTP = false)
        let validURL = URL(string: "https://example.com/rss.xml")!
        let addIntent1 = AddFeedIntent(url: validURL, feedManager: addManager)
        do {
            let res1 = try await addIntent1.perform()
            assertEqual(res1.value, true, "AddFeedIntent with valid URL returns true")
            assertTrue(addSettings.hasFeed("https://example.com/rss.xml"), "Feed is registered in AppSettings")
            var fetched = false
            for _ in 0..<100 where !fetched {
                fetched = await addFetches.batches.contains { $0.contains("https://example.com/rss.xml") }
                if !fetched { try? await Task.sleep(for: .milliseconds(20)) }
            }
            assertTrue(fetched, "AddFeedIntent fetches the new feed at once through FeedManager")
            let dialog1 = extractDialogText(from: res1)
            assertTrue(
                dialog1 != nil && dialog1!.contains("Subscribed to feed"),
                "AddFeedIntent returns subscription dialog")
        } catch {
            assertTrue(false, "AddFeedIntent 1 threw: \(error)")
        }

        // A later subscription change cancels the run the Shortcut awaits; the action still returns only once the
        // replacement run has collected the new feed.
        let slowSuite = testDefaultsSuite("test.intent.addfeed.slow")
        let slowDefaults = UserDefaults(suiteName: slowSuite)!
        defer { removeTestDefaults(slowSuite) }
        let slowSettings = AppSettings(defaults: slowDefaults)
        let slowFetches = TestRecorder()
        let slowManager = FeedManager(
            settings: slowSettings, store: addStore, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                await slowFetches.record(urls)
                try? await Task.sleep(for: .milliseconds(250))
                return urls.map { ($0, [], nil, nil) }
            })
        defer { slowManager.stopBackgroundWork() }
        let slowAdd = Task { @MainActor in await slowManager.addFeedAndCollect(url: "https://slow.example.com/a.xml") }
        await eventually("Feed A's refresh has started") {
            await slowFetches.batches.contains { $0.contains("https://slow.example.com/a.xml") }
        }
        slowManager.addFeed(url: "https://slow.example.com/b.xml")
        _ = await slowAdd.value
        assertFalse(slowManager.isAnyFeedLoading, "Add Feed returns only after the replacement run has finished")

        // Duplicate subscription rejection
        let addIntentDup = AddFeedIntent(url: validURL, feedManager: addManager)
        do {
            let resDup = try await addIntentDup.perform()
            assertEqual(resDup.value, false, "Duplicate subscription returns false")
            let dialogDup = extractDialogText(from: resDup)
            assertTrue(
                dialogDup != nil && dialogDup!.contains("Could not subscribe"),
                "Duplicate subscription returns failure dialog")
        } catch {
            assertTrue(false, "AddFeedIntent duplicate threw: \(error)")
        }

        // Trailing slash variant is recognized as duplicate
        let slashURL = URL(string: "https://example.com/rss.xml/")!
        let addIntentSlash = AddFeedIntent(url: slashURL, feedManager: addManager)
        do {
            let resSlash = try await addIntentSlash.perform()
            assertEqual(resSlash.value, false, "Trailing slash duplicate returns false")
        } catch {
            assertTrue(false, "AddFeedIntent trailing slash threw: \(error)")
        }

        // Insecure HTTP URL upgraded when allowInsecureHTTP is false
        let httpURL = URL(string: "http://insecure-feed.org/feed.xml")!
        let addIntentHTTP = AddFeedIntent(url: httpURL, feedManager: addManager)
        do {
            let resHTTP = try await addIntentHTTP.perform()
            assertEqual(resHTTP.value, true, "HTTP feed subscription succeeds via HTTPS upgrade")
            assertTrue(addSettings.hasFeed("https://insecure-feed.org/feed.xml"), "Feed was upgraded to HTTPS")
            assertTrue(
                extractDialogText(from: resHTTP)?.contains("https://insecure-feed.org/feed.xml") == true,
                "The dialog names the upgraded address that was subscribed")
            assertFalse(addSettings.hasFeed("http://insecure-feed.org/feed.xml"), "HTTP URL was not preserved")
        } catch {
            assertTrue(false, "AddFeedIntent HTTP upgrade threw: \(error)")
        }

        // Insecure HTTP URL preserved when allowInsecureHTTP is true
        let insecureSuite = testDefaultsSuite("test.intent.insecure")
        let insecureDefaults = UserDefaults(suiteName: insecureSuite)!
        defer { removeTestDefaults(insecureSuite) }
        let insecureSettings = AppSettings(defaults: insecureDefaults)
        insecureSettings.setAllowInsecureHTTP(true)
        let insecureManager = FeedManager(
            settings: insecureSettings, store: addStore, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [], nil, nil) } })
        defer { insecureManager.stopBackgroundWork() }

        let plainHTTPURL = URL(string: "http://plain-http.org/feed.xml")!
        let addIntentPlain = AddFeedIntent(url: plainHTTPURL, feedManager: insecureManager)
        do {
            let resPlain = try await addIntentPlain.perform()
            assertEqual(resPlain.value, true, "Plain HTTP feed subscription succeeds when allowed")
            assertTrue(insecureSettings.hasFeed("http://plain-http.org/feed.xml"), "Plain HTTP URL preserved")
        } catch {
            assertTrue(false, "AddFeedIntent plain HTTP threw: \(error)")
        }

        // Invalid scheme / unparseable URL returns false
        let invalidURL = URL(string: "file:///etc/passwd")!
        let addIntentInvalid = AddFeedIntent(url: invalidURL, feedManager: addManager)
        do {
            let resInvalid = try await addIntentInvalid.perform()
            assertEqual(resInvalid.value, false, "file:// URL scheme rejected")
        } catch {
            assertTrue(false, "AddFeedIntent invalid threw: \(error)")
        }

        // AddFeedIntent via IntentDependencyResolver
        IntentDependencyResolver.feedManagerOverride = addManager
        defer { IntentDependencyResolver.feedManagerOverride = nil }
        let resolverFeedURL = URL(string: "https://resolver-test.com/feed.xml")!
        let resolverAddIntent = AddFeedIntent(url: resolverFeedURL)
        do {
            let resResolver = try await resolverAddIntent.perform()
            assertEqual(resResolver.value, true, "AddFeedIntent uses IntentDependencyResolver feedManagerOverride")
            assertTrue(addSettings.hasFeed("https://resolver-test.com/feed.xml"), "Feed registered via resolver")
        } catch {
            assertTrue(false, "AddFeedIntent resolver threw: \(error)")
        }

        // 3. OpenSectionIntent: AppSection enumeration and navigation routing
        assertEqual(OpenSectionIntent.title, "Open Section", "OpenSectionIntent title is 'Open Section'")
        assertTrue(OpenSectionIntent.openAppWhenRun, "OpenSectionIntent opens app in foreground")
        if #available(macOS 26.0, *) {
            assertEqual(OpenSectionIntent.supportedModes, .foreground, "macOS 26 opens the app for Open Section")
            for modes in [
                RefreshFeedsIntent.supportedModes, AddFeedIntent.supportedModes, MarkAllAsReadIntent.supportedModes,
                NewBriefingIntent.supportedModes,
            ] {
                assertEqual(modes, .background, "macOS 26 runs the other intents without opening the app")
            }
        }

        let sections: [AppSection] = [.today, .unread, .briefing, .savedStories]
        for section in sections {
            var routedSection: AppSection?
            let openIntent = OpenSectionIntent(section: section) { s in
                routedSection = s
            }
            do {
                _ = try await openIntent.perform()
                assertEqual(routedSection, section, "OpenSectionIntent routes to \(section.rawValue)")
            } catch {
                assertTrue(false, "OpenSectionIntent for \(section) threw: \(error)")
            }
        }

        // OpenSectionIntent via IntentDependencyResolver.sectionNavigationHandler
        var ambientRouted: AppSection?
        IntentDependencyResolver.sectionNavigationHandler = { s in
            ambientRouted = s
        }
        defer { IntentDependencyResolver.sectionNavigationHandler = nil }
        let ambientOpenIntent = OpenSectionIntent(section: .briefing)
        do {
            _ = try await ambientOpenIntent.perform()
            assertEqual(ambientRouted, .briefing, "OpenSectionIntent routes through IntentDependencyResolver")
        } catch {
            assertTrue(false, "Ambient OpenSectionIntent threw: \(error)")
        }

        // 4. MarkAllAsReadIntent: unread count clearing, idempotency, and dialog
        assertEqual(MarkAllAsReadIntent.title, "Mark All as Read", "MarkAllAsReadIntent title is 'Mark All as Read'")
        assertFalse(MarkAllAsReadIntent.openAppWhenRun, "MarkAllAsReadIntent does not open app")

        let markStore = ArticleStore(
            database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await markStore.initialize()
        let sample1 = FeedArticle(
            title: "Story 1", link: "https://example.com/1", guid: "g1", description: "D1", pubDate: Date(),
            source: "Publisher")
        let sample2 = FeedArticle(
            title: "Story 2", link: "https://example.com/2", guid: "g2", description: "D2", pubDate: Date(),
            source: "Publisher")
        await markStore.batchUpsert(articles: [sample1, sample2])
        assertEqual(markStore.unreadCount, 2, "2 unread stories before MarkAllAsReadIntent")

        let markIntent = MarkAllAsReadIntent(articleStore: markStore)
        do {
            let resMark = try await markIntent.perform()
            assertEqual(markStore.unreadCount, 0, "Unread count is 0 after MarkAllAsReadIntent")
            let dialogMark = extractDialogText(from: resMark)
            assertTrue(
                dialogMark != nil && dialogMark!.contains("All visible stories marked as read"),
                "MarkAllAsReadIntent returns confirmation dialog")
        } catch {
            assertTrue(false, "MarkAllAsReadIntent perform threw: \(error)")
        }

        // Idempotent execution when unread is already 0
        do {
            let resMark2 = try await markIntent.perform()
            assertEqual(markStore.unreadCount, 0, "Unread count remains 0 on repeat MarkAllAsReadIntent")
            let dialogMark2 = extractDialogText(from: resMark2)
            assertTrue(
                dialogMark2 != nil && dialogMark2!.contains("All visible stories marked as read"),
                "Confirmation dialog returned on idempotent run")
        } catch {
            assertTrue(false, "MarkAllAsReadIntent repeat threw: \(error)")
        }

        // MarkAllAsReadIntent via IntentDependencyResolver
        IntentDependencyResolver.articleStoreOverride = markStore
        defer { IntentDependencyResolver.articleStoreOverride = nil }
        let ambientMarkIntent = MarkAllAsReadIntent()
        do {
            let resAmbientMark = try await ambientMarkIntent.perform()
            let dialogAmbient = extractDialogText(from: resAmbientMark)
            assertTrue(
                dialogAmbient != nil && dialogAmbient!.contains("All visible stories marked as read"),
                "Ambient MarkAllAsReadIntent succeeds via resolver")
        } catch {
            assertTrue(false, "Ambient MarkAllAsReadIntent threw: \(error)")
        }

        // 5. NewBriefingIntent: edition reset and dialog
        assertEqual(NewBriefingIntent.title, "New Briefing", "NewBriefingIntent title is 'New Briefing'")
        assertFalse(NewBriefingIntent.openAppWhenRun, "NewBriefingIntent does not open app")

        var customResetTriggered = false
        let customBriefingIntent = NewBriefingIntent(resetAction: {
            customResetTriggered = true
        })
        do {
            let resBriefing = try await customBriefingIntent.perform()
            assertTrue(customResetTriggered, "NewBriefingIntent custom reset action executed")
            let dialogBriefing = extractDialogText(from: resBriefing)
            assertTrue(
                dialogBriefing != nil && dialogBriefing!.contains("New briefing generated"),
                "NewBriefingIntent dialog confirms generation")
        } catch {
            assertTrue(false, "NewBriefingIntent custom action threw: \(error)")
        }

        // Default NewBriefingIntent resets UserDefaults
        let defaultBriefingIntent = NewBriefingIntent()
        do {
            let resDefaultBriefing = try await defaultBriefingIntent.perform()
            assertTrue(
                UserDefaults.standard.double(forKey: "briefingEditionSelectedAt") > 0,
                "briefingEditionSelectedAt timestamp updated in UserDefaults")
            assertEqual(
                UserDefaults.standard.string(forKey: "briefingEditionArticleIDs"), "",
                "briefingEditionArticleIDs cleared in UserDefaults")
            let dialogDefault = extractDialogText(from: resDefaultBriefing)
            assertTrue(
                dialogDefault != nil && dialogDefault!.contains("New briefing generated"),
                "NewBriefingIntent default execution dialog")
        } catch {
            assertTrue(false, "Default NewBriefingIntent threw: \(error)")
        }
    }

    private static func shortcutMetadata(from shortcut: AppShortcut) -> (
        shortTitle: String, systemImage: String, phrases: [String]
    ) {
        let mirror = Mirror(reflecting: shortcut)
        var title = ""
        var image = ""
        var phrases: [String] = []
        for child in mirror.children {
            if child.label == "shortTitle" {
                title = String(describing: child.value)
            } else if child.label == "systemImageName" {
                if let opt = child.value as? String? {
                    image = opt ?? ""
                }
            } else if child.label == "basePhraseTemplates" {
                if let list = child.value as? [String] {
                    phrases = list
                }
            }
        }
        return (title, image, phrases)
    }

    @MainActor
    static func testAppShortcutsProviderDeclarations() async {
        print("  - Testing NewsShortcuts AppShortcutsProvider Declarations & Terminology...")

        // 1. Shortcut tile color
        assertEqual(NewsShortcuts.shortcutTileColor, .navy, "NewsShortcuts tile color is navy")

        // 2. Exactly 5 shortcuts
        let shortcuts = NewsShortcuts.appShortcuts
        assertEqual(shortcuts.count, 5, "NewsShortcuts defines exactly 5 App Shortcuts")

        // 3. Inspect each shortcut declaration
        let refreshMeta = shortcutMetadata(from: shortcuts[0])
        assertTrue(refreshMeta.shortTitle.contains("Refresh Feeds"), "Shortcut 0 shortTitle contains 'Refresh Feeds'")
        assertEqual(refreshMeta.systemImage, "arrow.clockwise", "Shortcut 0 icon is arrow.clockwise")
        assertTrue(refreshMeta.phrases.contains("Refresh ${applicationName}"), "Shortcut 0 contains refresh phrase")

        let addFeedMeta = shortcutMetadata(from: shortcuts[1])
        assertTrue(addFeedMeta.shortTitle.contains("Add Feed"), "Shortcut 1 shortTitle contains 'Add Feed'")
        assertEqual(addFeedMeta.systemImage, "plus", "Shortcut 1 icon is plus")

        let openSectionMeta = shortcutMetadata(from: shortcuts[2])
        assertTrue(openSectionMeta.shortTitle.contains("Open Section"), "Shortcut 2 shortTitle contains 'Open Section'")
        assertEqual(openSectionMeta.systemImage, "sidebar.left", "Shortcut 2 icon is sidebar.left")

        let markReadMeta = shortcutMetadata(from: shortcuts[3])
        assertTrue(
            markReadMeta.shortTitle.contains("Mark All as Read"), "Shortcut 3 shortTitle contains 'Mark All as Read'")
        assertEqual(markReadMeta.systemImage, "checkmark.circle", "Shortcut 3 icon is checkmark.circle")

        let newBriefingMeta = shortcutMetadata(from: shortcuts[4])
        assertTrue(newBriefingMeta.shortTitle.contains("New Briefing"), "Shortcut 4 shortTitle contains 'New Briefing'")
        assertEqual(newBriefingMeta.systemImage, "text.book.closed", "Shortcut 4 icon is text.book.closed")

        // 4. Terminology review: ensure strictly 'story'/'stories' and never 'article' in shortcut titles and phrases
        for (idx, shortcut) in shortcuts.enumerated() {
            let meta = shortcutMetadata(from: shortcut)
            assertFalse(
                meta.shortTitle.lowercased().contains("article"),
                "Shortcut [\(idx)] title '\(meta.shortTitle)' must not contain 'article'"
            )
            for phrase in meta.phrases {
                assertFalse(
                    phrase.lowercased().contains("article"),
                    "Shortcut [\(idx)] phrase '\(phrase)' must not contain 'article'"
                )
            }
        }
    }

    @MainActor
    static func testOnboardingAndPermissionTiming() async {
        print("  - Testing the first-launch setting and the deferred notification request (#562)...")
        // The flow walks forward and back one step at a time, from Welcome to Done.
        var walked = [OnboardingStep.welcome]
        while let next = walked.last?.next { walked.append(next) }
        assertEqual(walked, OnboardingStep.allCases, "Continue visits every step once, in order")
        assertEqual(
            walked.map(\.title),
            [
                "Welcome to News", "Choose Your Feeds", "Pick Your Sections", "On-Device Intelligence",
                "Notifications", "You're All Set",
            ], "Each step has its own screen")
        var back = [OnboardingStep.done]
        while let previous = back.last?.previous { back.append(previous) }
        assertEqual(back, walked.reversed(), "Back retraces the same steps")
        assertTrue(OnboardingStep.welcome.previous == nil, "Welcome has no Back")
        assertTrue(OnboardingStep.done.isLast && !OnboardingStep.notifications.isLast, "Only Done is last")
        assertEqual(OnboardingStep.done.continueTitle, "Start Reading", "The last step starts reading")
        assertEqual(OnboardingStep.feeds.continueTitle, "Continue", "Other steps continue")
        assertEqual(OnboardingStep.feeds.position, "Step 2 of 6", "The indicator names the step and the count")
        assertTrue(walked.allSatisfy { !$0.tip.isEmpty && $0.companions.count <= 3 }, "Every step has a tip and art")
        func suite(_ name: String, seed: [String: Any] = [:]) -> (String, UserDefaults) {
            let name = testDefaultsSuite(name)
            let defaults = UserDefaults(suiteName: name)!
            for (key, value) in seed { defaults.set(value, forKey: key) }
            return (name, defaults)
        }
        let (freshName, fresh) = suite("onboarding-fresh")
        let (feedsName, feeds) = suite(
            "onboarding-feeds", seed: [AppSettings.feedURLsKey: ["https://example.com/feed"]])
        let (modeName, mode) = suite("onboarding-mode", seed: [AppSettings.notificationModeKey: "full"])
        defer { for name in [freshName, feedsName, modeName] { removeTestDefaults(name) } }
        assertFalse(AppSettings(defaults: fresh).firstLaunchCompleted, "A fresh install shows the first-launch sheet")
        assertFalse(AppSettings(defaults: fresh).firstLaunchCompleted, "A sheet closed by quitting shows again")
        AppSettings(defaults: fresh).completeFirstLaunch()
        assertTrue(AppSettings(defaults: fresh).firstLaunchCompleted, "Completing the sheet persists")
        assertTrue(AppSettings(defaults: feeds).firstLaunchCompleted, "Existing subscriptions skip the sheet")
        assertTrue(AppSettings(defaults: mode).firstLaunchCompleted, "Settings from an earlier version skip the sheet")

        // The permission request waits for a refresh that leaves stories, the closed sheet and the setting.
        // Refreshes deliver nothing until `delivering` is incremented; then each feed brings one story.
        func manager(_ settings: AppSettings, delivering: TestCounter) async -> FeedManager {
            settings.aiEnabled = false
            let store = ArticleStore(
                database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
            await store.initialize()
            return FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, _ in
                    guard await delivering.value > 0 else { return [] }
                    return urls.map { url in
                        let story = FeedArticle(
                            title: "First story", link: "https://example.com/onboarding/story", guid: "first",
                            description: "", pubDate: Date(), source: "Publisher")
                        return (url, [story], nil, nil)
                    }
                },
                notifyBatch: { _, _ in }, imageFinder: .unavailable)
        }
        let (newName, newDefaults) = suite("onboarding-permission")
        let (offName, offDefaults) = suite("onboarding-permission-off")
        defer { for name in [newName, offName] { removeTestDefaults(name) } }
        let settings = AppSettings(defaults: newDefaults)
        let delivering = TestCounter()
        let feedManager = await manager(settings, delivering: delivering)
        var requests = 0
        var requestedMidRefresh = false
        let request = NotificationPermissionRequest(feedManager: feedManager, settings: settings) {
            requests += 1
            requestedMidRefresh = requestedMidRefresh || feedManager.isAnyFeedLoading
        }
        assertEqual(requests, 0, "Nothing is asked at launch")
        settings.completeFirstLaunch()
        await feedManager.fetchFeedsAsync()
        assertEqual(requests, 0, "A refresh that brings no stories does not ask")
        await delivering.increment()
        await feedManager.fetchFeedsAsync()
        assertTrue(!feedManager.articles.isEmpty, "The second refresh brings a story")
        assertEqual(requests, 1, "The first refresh with stories asks once")
        assertFalse(requestedMidRefresh, "After an empty refresh, the next one asks only once it has completed")
        await feedManager.fetchFeedsAsync()
        settings.setNotificationsEnabled(false)
        settings.setNotificationsEnabled(true)
        assertEqual(requests, 1, "Later refreshes and toggles in the same launch do not ask again")
        assertTrue(request.hasRequested, "The request records that it asked")
        feedManager.stopBackgroundWork()

        // Stories and a refresh first: the sheet's closing, then turning notifications on, decide.
        let quiet = AppSettings(defaults: offDefaults)
        quiet.setNotificationsEnabled(false)
        let quietDelivering = TestCounter()
        await quietDelivering.increment()
        let quietManager = await manager(quiet, delivering: quietDelivering)
        var quietRequests = 0
        let quietRequest = NotificationPermissionRequest(feedManager: quietManager, settings: quiet) {
            quietRequests += 1
        }
        await quietManager.fetchFeedsAsync()
        assertEqual(quietRequests, 0, "Nothing is asked while the first-launch sheet is open")
        quiet.completeFirstLaunch()
        assertEqual(quietRequests, 0, "With notifications off, closing the sheet does not ask")
        quiet.setNotificationsEnabled(true)
        assertEqual(quietRequests, 1, "Turning notifications on after a refresh with stories asks")
        assertTrue(quietRequest.hasRequested, "The request records that it asked")
        quietManager.stopBackgroundWork()
    }

    /// #926: macOS asks `willPresent` only while News is active, so a story posted while News is behind another app
    /// is offered to the app's banner at post time. Exactly one banner either way: drawn means not added.
    static func testStoryBannerRoute() async throws {
        print("  - Testing the story banner route: app banner behind another app, never both (#926)...")
        assertTrue(
            StoryBannerRoute.allowsAppBanner(alert: .enabled, style: .banner, previews: .always),
            "Banners with previews are the app's")
        assertTrue(
            StoryBannerRoute.allowsAppBanner(alert: .enabled, style: .banner, previews: .whenAuthenticated),
            "Previews when unlocked still allow the app banner")
        assertFalse(
            StoryBannerRoute.allowsAppBanner(alert: .enabled, style: .alert, previews: .always),
            "The Alerts style stays with the system")
        assertFalse(
            StoryBannerRoute.allowsAppBanner(alert: .enabled, style: .none, previews: .always),
            "Alert style None draws nothing from the app")
        assertFalse(
            StoryBannerRoute.allowsAppBanner(alert: .disabled, style: .banner, previews: .always),
            "Banners off draw nothing from the app")
        assertFalse(
            StoryBannerRoute.allowsAppBanner(alert: .enabled, style: .banner, previews: .never),
            "Hidden previews stay with the system, which redacts them")

        func request(story: Bool) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = "Publisher"
            content.subtitle = "Headline"
            if story { content.categoryIdentifier = NotificationActionIdentifier.category }
            return UNNotificationRequest(identifier: "news-route", content: content, trigger: nil)
        }
        final class Calls: @unchecked Sendable {
            var presented = 0
            var added = 0
            var settingsRead = 0
        }
        func route(
            story: Bool = true, active: Bool, drawn: Bool = true,
            settings: (UNNotificationSetting, UNAlertStyle, UNShowPreviewsSetting) = (.enabled, .banner, .always)
        ) async throws -> (StoryBannerRoute, Calls) {
            let calls = Calls()
            let result = try await StoryBannerRoute.deliver(
                request(story: story), active: active,
                settings: {
                    calls.settingsRead += 1
                    return settings
                },
                present: { _ in
                    calls.presented += 1
                    return drawn
                },
                add: { _ in calls.added += 1 })
            return (result, calls)
        }

        // Behind another app with a window on screen: the app draws it and nothing is added (log of 3 November).
        var (result, calls) = try await route(active: false)
        assertEqual(result, .appBanner, "Inactive story banners are drawn by the app")
        assertEqual(calls.presented, 1, "The presenter is asked once")
        assertEqual(calls.added, 0, "A drawn banner is not also added: never both banners")
        // No window on screen (hidden, in the Dock): the presenter declines and the system banner shows.
        (result, calls) = try await route(active: false, drawn: false)
        assertEqual(result, .notificationCenter, "A declined banner goes to the system")
        assertEqual(calls.added, 1, "A declined banner is added exactly once")
        // Active: the post adds it and `willPresent` draws it, as before.
        (result, calls) = try await route(active: true)
        assertEqual(result, .notificationCenter, "Active posts are added for willPresent")
        assertEqual(calls.presented + calls.settingsRead, 0, "An active post neither presents nor reads settings")
        assertEqual(calls.added, 1, "An active post is added once")
        // Grouped and summary banners always stay with the system.
        (result, calls) = try await route(story: false, active: false)
        assertEqual(result, .notificationCenter, "Grouped banners stay with the system")
        assertEqual(calls.presented, 0, "A grouped banner is never offered to the app")
        // Alerts style or hidden previews: the system draws it, the app does not.
        for settings: (UNNotificationSetting, UNAlertStyle, UNShowPreviewsSetting) in [
            (.enabled, .alert, .always), (.enabled, .banner, .never), (.disabled, .banner, .always),
        ] {
            (result, calls) = try await route(active: false, settings: settings)
            assertEqual(result, .notificationCenter, "Settings the app does not draw under go to the system")
            assertEqual(calls.presented, 0, "The presenter is not asked under those settings")
            assertEqual(calls.added, 1, "Those posts are added once")
        }
        // A refused add still throws to the caller, which logs it and does not record the banner.
        struct Refused: Error {}
        var threw = false
        do {
            _ = try await StoryBannerRoute.deliver(
                request(story: true), active: true, settings: { (.enabled, .banner, .always) },
                present: { _ in true }, add: { _ in throw Refused() })
        } catch is Refused {
            threw = true
        }
        assertTrue(threw, "A refused add surfaces as a failed post")
        // Without an app (tests, helpers) no presenter is installed, so nothing is drawn.
        assertTrue(await MainActor.run { NotificationService.presentAppBanner == nil }, "No presenter outside the app")
        // The hop to the main actor re-checks activity: a post made as News became active is added, not drawn.
        guard let banner = StoryBanner(request(story: true)) else {
            return assertTrue(false, "A story request makes a banner")
        }
        let offered = await MainActor.run {
            var received: (StoryBanner, Bool)?
            let presenter: (StoryBanner, Bool) -> Bool = { banner, sounds in
                received = (banner, sounds)
                return true
            }
            let drawn = StoryBannerRoute.offer(banner, sounds: true, active: false, presenter: presenter)
            let declined = StoryBannerRoute.offer(banner, sounds: true, active: true, presenter: presenter)
            let absent = StoryBannerRoute.offer(banner, sounds: true, active: false, presenter: nil)
            return (drawn, declined, absent, received)
        }
        assertTrue(offered.0, "Inactive: the presenter draws the copied banner")
        assertEqual(offered.3?.0, banner, "The presenter receives the banner copied out of the request")
        assertEqual(offered.3?.1, true, "The presenter is told the banner asks for a sound")
        assertFalse(offered.1, "Became active meanwhile: declined, so the add files it for willPresent")
        assertFalse(offered.2, "No presenter installed: nothing is drawn")
        // The request form copies the banner out and hops to the main actor; without a presenter it declines.
        assertFalse(await StoryBannerRoute.offer(request(story: true)), "No presenter: a story request is declined")
        assertFalse(await StoryBannerRoute.offer(request(story: false)), "A grouped request makes no banner")
    }

    static func testFeedArticleWrapContextNavigation() async {
        print("  - Testing FeedArticleWrap Context Preservation & Filtered Navigation Boundaries...")

        let artA = FeedArticle(
            title: "Article A", link: "https://example.com/a", guid: "a", description: "Desc A", pubDate: Date(),
            source: "Source 1", category: "Technology")
        let artB = FeedArticle(
            title: "Article B", link: "https://example.com/b", guid: "b", description: "Desc B", pubDate: Date(),
            source: "Source 2", category: "Science")
        let artC = FeedArticle(
            title: "Article C", link: "https://example.com/c", guid: "c", description: "Desc C", pubDate: Date(),
            source: "Source 1", category: "Technology")
        let artD = FeedArticle(
            title: "Article D", link: "https://example.com/d", guid: "d", description: "Desc D", pubDate: Date(),
            source: "Source 3", category: "Business")

        let allGlobal = [artA, artB, artC, artD]
        let techFilter = [artA, artC]

        // 1. Wrap with filtered context
        let wrap = FeedArticleWrap(article: artA, contextArticles: techFilter)
        assertEqual(wrap.article.id, artA.id, "Wrapped article ID must match artA")
        assertEqual(wrap.contextArticles.count, 2, "Filtered context must contain exactly 2 articles")
        assertEqual(
            wrap.contextArticles.map(\.id), [artA.id, artC.id], "Filtered context articles must match techFilter")

        // 2. Boundary simulation in filtered context:
        // In techFilter: artA is index 0. Has next (artC), but NO previous.
        let idxA = wrap.contextArticles.firstIndex(where: { $0.id == artA.id })
        assertEqual(idxA, 0, "artA should be at index 0 in filtered context")
        let hasPrevInFilter = idxA.map { $0 > 0 } ?? false
        let hasNextInFilter = idxA.map { $0 + 1 < wrap.contextArticles.count } ?? false
        assertFalse(hasPrevInFilter, "artA must not have previous article in filtered context")
        assertTrue(hasNextInFilter, "artA must have next article (artC) in filtered context")

        // In techFilter: Next article from artA is artC (skipping artB which is Science!)
        let nextArt = wrap.contextArticles[idxA! + 1]
        assertEqual(nextArt.id, artC.id, "Next article in tech filter must be artC, skipping artB")

        // In global context without filter: Next article from artA would have been artB
        let globalIdxA = allGlobal.firstIndex(where: { $0.id == artA.id })!
        let globalNext = allGlobal[globalIdxA + 1]
        assertEqual(globalNext.id, artB.id, "In unfiltered global context, next is artB")

        // 3. Fallback behavior when contextArticles is empty
        let wrapEmpty = FeedArticleWrap(article: artB)
        assertTrue(wrapEmpty.contextArticles.isEmpty, "Default contextArticles should be empty")

        // 4. Stable uniqueness of wrap identity
        let wrap2 = FeedArticleWrap(article: artA, contextArticles: techFilter)
        assertTrue(wrap.id != wrap2.id, "Each wrap must have a distinct UUID identity for navigation state")
    }

    /// A loader whose completions wait in a queue until the test releases them, oldest first (#591).
    @MainActor final class QueuedImageLoader {
        private struct Waiting {
            let id: UUID
            let url: URL
            let continuation: CheckedContinuation<CGImage, Error>
        }
        let honorsCancellation: Bool
        private(set) var requests: [URL] = []
        /// The pixel bound each request asked for, in request order.
        private(set) var pixelBounds: [Int] = []
        private var queue: [Waiting] = []
        private let image: CGImage = {
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .makeImage()!
        }()
        var queued: Int { queue.count }

        init(honorsCancellation: Bool = true) { self.honorsCancellation = honorsCancellation }

        var loader: @Sendable (URL, Int) async throws -> CGImage {
            { url, maxPixels in try await self.enqueue(url, maxPixels: maxPixels) }
        }

        private func enqueue(_ url: URL, maxPixels: Int) async throws -> CGImage {
            requests.append(url)
            pixelBounds.append(maxPixels)
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.append(Waiting(id: id, url: url, continuation: continuation))
                }
            } onCancel: {
                Task { @MainActor in self.cancel(id) }
            }
        }

        private func cancel(_ id: UUID) {
            guard honorsCancellation, let index = queue.firstIndex(where: { $0.id == id }) else { return }
            queue.remove(at: index).continuation.resume(throwing: CancellationError())
        }

        /// Completes the `count` oldest waiting loads.
        func release(_ count: Int) {
            let released = queue.prefix(count)
            queue.removeFirst(released.count)
            for waiting in released { waiting.continuation.resume(returning: image) }
        }

        /// Waits until the loads that released ones lead to have reached the queue: no change across ten 1 ms polls.
        func settle() async {
            var last = (-1, -1)
            var stable = 0
            while stable < 10 {
                try? await Task.sleep(for: .milliseconds(1))
                let now = (requests.count, queue.count)
                stable = now == last ? stable + 1 : 0
                last = now
            }
        }
    }

    /// #591: scrolling 200 cards shows at most 5% placeholders at first paint when prefetch decodes each card's own
    /// image ahead of it, and nothing else is fetched; a decode that finished is kept though its only waiter cancelled.
    @MainActor static func testCardImagePrefetchFirstPaint() async {
        print("  - Testing card image prefetch and placeholders at first paint...")
        DecodedImageCache.clear()
        defer {
            DecodedImageCache.cardFirstPaints = nil
            DecodedImageCache.clear()
        }

        // This loader ignores cancellation, so it finishes after the shared task was cancelled.
        let stubborn = QueuedImageLoader(honorsCancellation: false)
        let keptURL = URL(string: "https://cards.example/kept/\(UUID().uuidString).jpg")!
        let waiter = Task { @MainActor in _ = try? await DecodedImageCache.load(keptURL, using: stubborn.loader) }
        await eventually("The stubborn load is queued before its waiter cancels") { @MainActor in
            stubborn.requests.count == 1 && stubborn.queued == 1
        }
        let shared = DecodedImageCache.sharedLoad(for: keptURL)
        assertTrue(shared != nil, "The stubborn load is shared under its URL")
        waiter.cancel()
        // The last waiter's cancellation cancels the shared task on the main actor; release only after it has.
        await eventually("The shared load is cancelled while its decode is still queued") { @MainActor in
            shared?.task.isCancelled == true && stubborn.queued == 1
        }
        stubborn.release(1)
        _ = await waiter.value
        await stubborn.settle()
        assertTrue(DecodedImageCache.cached(keptURL) != nil, "A finished decode is kept after its waiter cancelled")

        // #1132: when one of multiple waiters cancels, the shared load stays in `pending` so a later waiter coalesces.
        let coalescedLoader = QueuedImageLoader()
        let coalescedURL = URL(string: "https://cards.example/coalesced/\(UUID().uuidString).jpg")!
        let waiterA = Task { @MainActor in
            _ = try? await DecodedImageCache.load(coalescedURL, using: coalescedLoader.loader)
        }
        let waiterB = Task { @MainActor in
            _ = try? await DecodedImageCache.load(coalescedURL, using: coalescedLoader.loader)
        }
        await eventually("Both initial waiters join the same in-flight load") { @MainActor in
            coalescedLoader.requests.count == 1 && DecodedImageCache.sharedLoad(for: coalescedURL)?.waiters == 2
        }
        waiterA.cancel()
        await eventually("First waiter cancellation is recorded without evicting the pending load") { @MainActor in
            DecodedImageCache.sharedLoad(for: coalescedURL)?.cancelledWaiters == 1
        }
        assertTrue(
            DecodedImageCache.sharedLoad(for: coalescedURL) != nil,
            "An in-flight load with an active waiter stays in pending after another waiter exits (#1132)")
        let waiterC = Task { @MainActor in
            _ = try? await DecodedImageCache.load(coalescedURL, using: coalescedLoader.loader)
        }
        await eventually("A third waiter joins the existing shared load instead of starting a second download") {
            @MainActor in
            DecodedImageCache.sharedLoad(for: coalescedURL)?.waiters == 3
        }
        assertEqual(
            coalescedLoader.requests.count, 1,
            "Coalesced waiter reuses the single in-flight request (#1132)")
        coalescedLoader.release(1)
        _ = await (waiterA.value, waiterB.value, waiterC.value)
        await eventually("Pending entry is cleared once the shared task finishes") { @MainActor in
            DecodedImageCache.sharedLoad(for: coalescedURL) == nil
        }

        // 200 cards: every fifth an event of three reports with an image each, every tenth without an image.
        let now = Date()
        var articles: [FeedArticle] = []
        var events: [EventFeedSummary] = []
        for index in 0..<200 {
            let members = (0..<(index % 5 == 0 ? 3 : 1)).map { member in
                FeedArticle(
                    title: "Prefetch story \(index) report \(member)",
                    link: "https://news.example/\(index)/\(member)", guid: "prefetch-\(index)-\(member)",
                    description: "Summary", pubDate: now.addingTimeInterval(-Double(index * 10 + member)),
                    source: "Publisher \(member)",
                    imageUrl: index % 10 == 9 ? nil : "https://cards.example/\(index)/\(member).jpg")
            }
            articles += members
            if members.count > 1 {
                events.append(
                    EventFeedSummary(
                        eventID: "prefetch-event-\(index)", membershipVersion: 1, seenVersion: nil,
                        members: members.map {
                            EventFeedMember(
                                articleID: $0.id, source: $0.source, title: $0.title, date: $0.pubDate,
                                joinedVersion: 1, isRead: false, isSaved: false)
                        }))
            }
        }
        let entries = FeedSnapshot(articles: articles, events: events).entries(.events)
        assertEqual(entries.count, 200, "The seeded list has 200 cards")
        let cardURLs = Set(entries.compactMap(\.cardImageURL))
        assertEqual(cardURLs.count, 180, "180 cards show an image of their own")

        // Each card appears (ArticleRemoteImage.init asks the cache), moves the prefetch window, and two queued
        // loads complete before the next card appears.
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            print("    skipped: Low Power Mode turns prefetch off")
            return
        }
        let probe = QueuedImageLoader()
        let prefetch = CardImagePrefetch()
        DecodedImageCache.cardFirstPaints = (0, 0)
        let initial = Task { @MainActor in
            await CardImagePrefetch.first(
                CardImagePrefetch.initialURLs(entries), leadAtFullSize: false, using: probe.loader)
        }
        await probe.settle()
        for (index, entry) in entries.enumerated() {
            if let url = entry.cardImageURL { _ = ArticleRemoteImage(url: url, size: .card) { _ in EmptyView() } }
            prefetch.ahead(of: index, in: entries, using: probe.loader)
            await probe.settle()
            probe.release(2)
            await probe.settle()
        }
        let counts = DecodedImageCache.cardFirstPaints ?? (0, 0)
        assertEqual(counts.placeholders + counts.images, 180, "Every card with an image is counted once")
        print("    card placeholders at first paint: \(counts.placeholders) of 180")
        assertTrue(
            Double(counts.placeholders) <= 0.05 * 180, "At most 5% of cards show a placeholder at first paint")
        let others = Set(probe.requests).subtracting(cardURLs)
        assertTrue(others.isEmpty, "Only the images cards show are fetched (\(others.count) others)")
        assertTrue(
            !probe.pixelBounds.isEmpty && probe.pixelBounds.allSatisfy { $0 == DecodedImageCache.Size.card.maxPixels },
            "Without a lead, every card prefetch decodes at card size, never at the reader's bound")
        assertEqual(stubborn.pixelBounds, [DecodedImageCache.Size.full.maxPixels], "A plain load decodes at full size")
        prefetch.reset()
        initial.cancel()
        while probe.queued > 0 {
            probe.release(probe.queued)
            await probe.settle()
        }
        _ = await initial.value
    }

    @MainActor
    static func testSpotlightSavedStoriesIndexing() async throws {
        print("  - Testing Spotlight indexing of saved stories (#559)...")
        let mockIndexer = MockSpotlightIndexer()
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: mockIndexer)
        await store.initialize()
        let savedManager = SavedStoriesManager(articleStore: store)

        let pubDate = Date(timeIntervalSince1970: 1_730_000_000)
        let article = FeedArticle(
            storedID: "spotlight-unit-1",
            title: "Breakthrough in Fusion Energy",
            link: "https://example.com/fusion-1",
            guid: "spotlight-unit-1",
            description: "Scientists achieved sustained net energy gain.",
            pubDate: pubDate,
            source: "Science Daily"
        )
        await store.batchUpsert(articles: [article], feedUrl: "https://example.com/rss")

        // 1. Saving a story indexes CSSearchableItem with title, publisher, summary, date, and news://story/<id>
        savedManager.save(article)
        await savedManager.waitForPendingChanges()

        let item = await mockIndexer.item(for: "spotlight-unit-1")
        assertTrue(item != nil, "Saving a story indexes a CSSearchableItem (#559)")
        assertEqual(
            item?.domainIdentifier, "com.marspater.news.saved-stories",
            "Spotlight item uses saved-stories domain (#559)"
        )
        assertEqual(item?.attributeSet.title, "Breakthrough in Fusion Energy", "Spotlight item preserves title")
        assertEqual(item?.attributeSet.publishers, ["Science Daily"], "Spotlight item preserves publisher")
        assertEqual(
            item?.attributeSet.contentDescription,
            "Scientists achieved sustained net energy gain.",
            "Spotlight item preserves summary"
        )
        assertEqual(item?.attributeSet.contentCreationDate, pubDate, "Spotlight item preserves publication date")
        assertEqual(
            item?.attributeSet.contentURL?.absoluteString,
            "news://story/spotlight-unit-1",
            "Spotlight item links to news://story/<id> (#559)"
        )
        let scopedID = "https://example.com/feed.xml#guid:https://example.com/story%201/"
        let scopedArticle = FeedArticle(
            storedID: scopedID, title: "Scoped", link: "https://example.com/story%201/",
            guid: "https://example.com/story%201/", description: "Summary", pubDate: pubDate, source: "Science Daily")
        let scopedURL = SystemSpotlightIndexer.makeSearchableItem(for: scopedArticle).attributeSet.contentURL
        assertEqual(
            scopedURL.flatMap { NewsURLParser.parse(url: $0, allowInsecureHTTP: false) },
            .story(id: scopedID),
            "Spotlight contentURL round-trips scoped GUIDs with percent-encoding and trailing slashes"
        )

        // 2. Clear All Caches preserves saved-story Spotlight items
        try await store.clearAllDatabaseCache()
        let preserved = await mockIndexer.contains(id: "spotlight-unit-1")
        assertTrue(preserved, "Clear All Caches preserves saved-story Spotlight items (#559)")

        // 3. Unsaving removes the CSSearchableItem
        savedManager.remove(article)
        await savedManager.waitForPendingChanges()
        let afterRemove = await mockIndexer.contains(id: "spotlight-unit-1")
        assertFalse(afterRemove, "Unsaving a story removes its CSSearchableItem (#559)")

        // 4. Library reset / removeAllSavedStories clears the Spotlight domain
        savedManager.save(article)
        await savedManager.waitForPendingChanges()
        assertTrue(await mockIndexer.contains(id: "spotlight-unit-1"), "Re-saved story is indexed again")
        savedManager.removeAll()
        await savedManager.waitForPendingChanges()
        assertEqual(await mockIndexer.getIndexedCount(), 0, "Removing all saved stories purges Spotlight domain (#559)")

        // 5. A rebuild keeps exactly the open library's saved stories, dropping a previous library's entries (#812)
        savedManager.save(article)
        await savedManager.waitForPendingChanges()
        let previous = FeedArticle(
            storedID: "spotlight-previous-library", title: "Previous library", link: "https://example.com/previous",
            guid: "spotlight-previous-library", description: "", pubDate: pubDate, source: "Old")
        await mockIndexer.indexSavedArticle(previous)
        await store.rebuildSpotlightIndex()
        assertFalse(
            await mockIndexer.contains(id: "spotlight-previous-library"),
            "Rebuild drops entries the open library does not hold (#812)")
        assertTrue(
            await mockIndexer.contains(id: "spotlight-unit-1"), "Rebuild indexes the library's saved stories (#812)")

        // 6. A generated summary never reaches the entry, so Clear AI Analysis leaves none behind (#983)
        let generated = "Model-written summary of the fusion story."
        let analysis = ArticleAnalysis(
            summary: generated, keyPoints: [], entities: [], category: "Science",
            modelIdentifier: "test", analysisVersion: 1)
        await store.saveArticleAnalysis(analysis, for: "spotlight-unit-1")
        await store.rebuildSpotlightIndex()
        let withSummary = await mockIndexer.item(for: "spotlight-unit-1")
        assertEqual(
            withSummary?.attributeSet.contentDescription, "Scientists achieved sustained net energy gain.",
            "A saved story with a generated summary is indexed with the publisher description only (#983)")
        try await store.clearAIAnalysis()
        await store.rebuildSpotlightIndex()
        let afterClear = await mockIndexer.item(for: "spotlight-unit-1")
        assertEqual(
            afterClear?.attributeSet.contentDescription, "Scientists achieved sustained net energy gain.",
            "The entry stays and holds the publisher description, not the generated summary, after a clear (#983)")
        // A story that already carries a generated summary when it is saved (no rebuild involved)
        let later = FeedArticle(
            storedID: "spotlight-unit-2", title: "Fusion Follow-up", link: "https://example.com/fusion-2",
            guid: "spotlight-unit-2", description: "Follow-up from the publisher.", pubDate: pubDate,
            source: "Science Daily")
        await store.batchUpsert(articles: [later], feedUrl: "https://example.com/rss")
        await store.saveArticleAnalysis(analysis, for: "spotlight-unit-2")
        let summarised = try await db.fetchArticles().first { $0.id == "spotlight-unit-2" }
        assertEqual(summarised?.aiSummary, generated, "The unsaved story carries its generated summary")
        savedManager.save(summarised ?? later)
        await savedManager.waitForPendingChanges()
        assertEqual(
            await mockIndexer.item(for: "spotlight-unit-2")?.attributeSet.contentDescription,
            "Follow-up from the publisher.",
            "Saving a story with a summary indexes the publisher description only (#983)")
        try await store.clearAIAnalysis()
        assertEqual(
            await mockIndexer.item(for: "spotlight-unit-2")?.attributeSet.contentDescription,
            "Follow-up from the publisher.",
            "The saved entry still holds no generated text after Clear AI Analysis (#983)")
        var enriched = article
        enriched.aiSummary = generated
        assertEqual(
            SystemSpotlightIndexer.makeSearchableItem(for: enriched).attributeSet.contentDescription,
            "Scientists achieved sustained net energy gain.",
            "An article carrying aiSummary still indexes the publisher description (#983)")
        await db.close()
    }

    @MainActor
    static func testMenuBarExtraSettingsAndUnreadCount() async {
        print("  - Testing Menu Bar Extra preference and unread count source (#561)...")
        let suite = testDefaultsSuite("test.menubar-extra")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }

        let settings = AppSettings(defaults: defaults)
        assertFalse(settings.showsMenuBarExtra, "Show in Menu Bar is off by default (#561)")

        settings.setShowsMenuBarExtra(true)
        assertTrue(settings.showsMenuBarExtra, "setShowsMenuBarExtra(true) updates published property")
        assertTrue(
            defaults.bool(forKey: AppSettings.showsMenuBarExtraKey),
            "Show in Menu Bar preference persists in UserDefaults (#561)"
        )

        let reloaded = AppSettings(defaults: defaults)
        assertTrue(reloaded.showsMenuBarExtra, "Reloaded AppSettings restores Show in Menu Bar preference")

        reloaded.setShowsMenuBarExtra(false)
        assertFalse(reloaded.showsMenuBarExtra, "setShowsMenuBarExtra(false) disables Menu Bar Extra")

        // Verify unreadCount source matches ArticleStore.unreadCount
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let readManager = ReadManager(articleStore: store)
        let a1 = FeedArticle(
            storedID: "mb-1", title: "Unread 1", link: "https://example.com/mb1",
            guid: "mb-1", description: "", pubDate: Date(), source: "Source"
        )
        let a2 = FeedArticle(
            storedID: "mb-2", title: "Unread 2", link: "https://example.com/mb2",
            guid: "mb-2", description: "", pubDate: Date(), source: "Source"
        )
        await store.batchUpsert(articles: [a1, a2], feedUrl: "https://example.com/rss")
        assertEqual(store.unreadCount, 2, "ArticleStore.unreadCount reflects 2 unread stories")
        readManager.markAsRead("mb-1")
        await readManager.waitForPendingChanges()
        assertEqual(store.unreadCount, 1, "ArticleStore.unreadCount decrements to 1 when story is marked read")
        await db.close()
    }

    // MARK: - Hybrid Search & RRF Tests (#708)

    @MainActor
    static func testStoryQuickLookPreview() async {
        print("  - Testing the Quick Look preview: local content, upright page, no remote references (#707)...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "com.marspater.news.quicklook.test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Remote links and a tracking pixel in the feed text must never reach the preview.
        let article = FeedArticle(
            storedID: "test-ql-1",
            title: "Autonomous Space Tug Successfully Completes Orbital Test",
            link: "https://publisher.example.com/stories/space-tug-2026",
            guid: "space-tug-12345",
            description:
                "<p>The orbital tug demonstrated automated rendezvous with a target satellite. <a href=\"https://tracking.adnetwork.com/click?id=99\">Read sponsor message</a></p>",
            pubDate: Date(timeIntervalSince1970: 1_770_000_000),
            source: "Aerospace Daily",
            imageUrl: "https://images.example.com/satellite.jpg",
            fullContent:
                "Full story with tracker: <img src=\"https://tracker.analytics.com/pixel.gif\" /> and more content."
        )

        let renderData = StoryQuickLookRenderer.renderData(for: article)
        assertEqual(renderData.title, article.title, "Render data captures article title")
        assertEqual(renderData.publisher, "Aerospace Daily", "Render data uses publisher name")
        assertTrue(renderData.image == nil, "An image that is not decoded yet is never fetched for the preview")
        assertFalse(renderData.excerpt.isEmpty, "Excerpt is extracted from local data")
        assertFalse(renderData.excerpt.contains("<"), "HTML is stripped from the excerpt")

        for isDark in [false, true] {
            let previewFile = tempDir.appendingPathComponent("preview-\(isDark).pdf")
            assertTrue(
                StoryQuickLookRenderer.renderPDF(data: renderData, to: previewFile, isDark: isDark),
                "renderPDF succeeds offline (dark: \(isDark))")
            let pdfData = (try? Data(contentsOf: previewFile)) ?? Data()
            let pdfString = String(bytes: pdfData, encoding: .isoLatin1) ?? ""
            for marker in ["http://", "https://", "/URI", "/Launch", "adnetwork", "tracker"] {
                assertFalse(pdfString.contains(marker), "Generated PDF contains no \(marker) (dark: \(isDark))")
            }

            // PDF space has its origin at the bottom left, so text near the top of the page has a large y.
            guard let page = PDFDocument(url: previewFile)?.page(at: 0), let text = page.string as NSString? else {
                assertTrue(false, "The preview PDF has a readable page (dark: \(isDark))")
                continue
            }
            // The page's extracted text and its annotations carry no link either.
            for marker in ["http://", "https://", "www.", "adnetwork", "tracker"] {
                assertFalse((text as String).contains(marker), "Page text contains no \(marker) (dark: \(isDark))")
            }
            assertTrue(page.annotations.isEmpty, "The preview page has no annotations or link actions")
            let height = page.bounds(for: .mediaBox).height
            let titleBounds = page.selection(for: text.range(of: "Autonomous Space Tug"))?.bounds(for: page) ?? .zero
            let footerBounds = page.selection(for: text.range(of: "Open in Reader"))?.bounds(for: page) ?? .zero
            assertTrue(titleBounds.minY > height * 0.7, "The headline sits at the top of an upright page")
            assertTrue(
                footerBounds.maxY > 0 && footerBounds.maxY < height * 0.15, "The footer sits at the bottom of the page")
        }
    }
}
