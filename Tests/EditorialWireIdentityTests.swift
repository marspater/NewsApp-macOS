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

import Foundation
import SQLite3

/// Authored wire-identity cases, all fictional, and their effect on the momentum replay.
enum EditorialWireIdentityTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0
    static let epoch = Date(timeIntervalSince1970: 1_793_491_200)

    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value {
            failures += 1
            print("❌ WireIdentity: \(message)")
        }
    }

    /// `count` distinct words from a seed, so two seeds share no passage.
    static func prose(_ seed: String, _ count: Int = 120) -> String {
        (0..<count).map { "\(seed)\($0)" }.joined(separator: " ")
    }

    static func article(
        _ id: String, publisher: String = "Outlet", title: String? = nil, description: String = "Short blurb.",
        content: String? = nil, published: Double = 10, fetched: Double = 20, author: String? = nil
    ) -> WireIdentityArticle {
        WireIdentityArticle(
            articleID: id, publisher: publisher, title: title ?? "Distinct headline number \(id) here today",
            description: description, content: content, publishedAt: epoch.addingTimeInterval(published),
            fetchedAt: epoch.addingTimeInterval(fetched), author: author)
    }

    static func replay(_ members: [WireIdentityArticle]) throws -> MomentumSummary {
        try EditorialMomentum.replay(
            reports: EditorialWireIdentity.momentumReports(eventID: "event", members: members), eventID: "event",
            windowStart: epoch, through: epoch.addingTimeInterval(600),
            configuration: MomentumConfiguration(
                bucketSeconds: 60, shortHalfLife: 60, longHalfLife: 120, signalHalfLife: 60, volumeWindow: 180,
                minimumIndependentReports: 2, minimumOriginPublishers: 2))
    }

    static func identities(_ members: [WireIdentityArticle]) -> [String: WireIdentity] {
        Dictionary(uniqueKeysWithValues: EditorialWireIdentity.identities(event: members).map { ($0.articleID, $0) })
    }

    static func checkWireStories() throws {
        let body = prose("wire")
        let wire = [
            article("a", publisher: "First", content: "(Reuters) - " + body),
            article("b", publisher: "Second", content: body),
            article("c", publisher: "Third", content: body + " One extra closing sentence from the local desk."),
        ]
        let copies = identities(wire)
        check(
            copies.values.allSatisfy {
                $0.wireGroupID == "wire:reuters" && $0.originPublisherID == "agency:reuters" && $0.basis == .credited
            }, "one credited wire and its uncredited copies share the agency")
        let syndicated = try replay(wire)
        check(
            syndicated.rawRowsInWindow == 3 && syndicated.independentReportsInWindow == 1
                && syndicated.independentOriginsInWindow == 1 && syndicated.unknownMetadataRows == 0,
            "a wire republished by three outlets counts once")
        let rewritten = identities([
            article("a", publisher: "First", content: "PARIS (AFP) — " + prose("one")),
            article("b", publisher: "Second", content: prose("two") + " — AFP"),
        ])
        check(
            rewritten["a"]?.wireGroupID == "wire:afp" && rewritten["a"]?.wireGroupID == rewritten["b"]?.wireGroupID,
            "two differently worded credits to one agency are one group in an event")
        check(
            identities([article("a", publisher: "reuters")])["a"]?.basis == .credited,
            "an agency's own feed is credited")
        let combined = identities([
            article("a", publisher: "France 24", content: prose("one") + " (FRANCE 24 with Reuters and AFP)")
        ])["a"]
        check(
            combined?.wireGroupID == "wire:afp+reuters" && combined?.originPublisherID == nil
                && combined?.basis == .multipleCredits, "several credits leave the origin unknown")
    }

    static func checkIndependentReports() throws {
        let members = [
            article("a", publisher: "First", content: prose("one")),
            article("b", publisher: "Second", content: prose("two")),
        ]
        let independent = try replay(members)
        check(
            independent.independentReportsInWindow == 2 && independent.independentOriginsInWindow == 2,
            "two independent reports stay two")
        check(identities(members)["b"]?.originPublisherID == "publisher:second", "own report credits the publisher")
        // The band of real outlets each weaving the same agency paragraphs into their own story: pinned as independent.
        let shared = prose("shared", 70)
        let woven = identities([
            article("a", publisher: "First", content: shared + " " + prose("one", 70)),
            article("b", publisher: "Second", content: shared + " " + prose("two", 70)),
        ])
        check(woven["a"]?.wireGroupID != woven["b"]?.wireGroupID, "half-shared text stays two reports")
        let looser = EditorialWireIdentity.identities(
            event: [
                article("a", publisher: "First", content: shared + " " + prose("one", 70)),
                article("b", publisher: "Second", content: shared + " " + prose("two", 70)),
            ], textContainment: 0.4)
        check(looser[0].wireGroupID == looser[1].wireGroupID, "the containment floor is the knob for that band")
        let quote = identities([
            article("a", publisher: "First", content: prose("one") + " a spokesman told Reuters on Friday"),
            article("b", publisher: "Second", content: prose("two") + " according to Reuters on Friday"),
        ])
        check(
            quote.values.allSatisfy { $0.wireGroupID == nil && $0.basis == .agencyMention },
            "quoting an agency is neither a credit nor proof of independence")
        let caption = identities([
            article("a", content: prose("one") + " in Paris on Tuesday. — AFP " + prose("two"))
        ])["a"]
        check(caption?.basis == .agencyMention, "a mid-text photo credit is not a byline")
        let lowerCase = identities([article("a", content: prose("one") + " cupid up the map")])["a"]
        check(lowerCase?.basis == .fullText, "words containing agency letters are not mentions")
    }

    static func checkUnknowns() throws {
        let snippet = article("a", description: "A blurb too short to hold a byline.")
        check(
            identities([snippet])["a"]
                == WireIdentity(
                    articleID: "a", wireGroupID: nil, originPublisherID: nil, basis: .insufficient),
            "a feed blurb stays unknown")
        let unknown = try replay([snippet])
        check(
            unknown.unknownMetadataRows == 1 && unknown.independentReportsInWindow == 0,
            "unknown rows are counted and never credited as independent")
        check(
            identities([article("a", publisher: "  ", content: prose("one"))])["a"]?.basis == .insufficient,
            "no publisher stays unknown")
    }

    static func checkCopies() throws {
        let twins = (0..<3).map {
            article(
                "t\($0)", publisher: "Outlet \($0)", title: "Strikes kill three people in the city, medics say",
                description: "Different blurb number \($0).", published: Double(10 + $0))
        }
        let titled = identities(twins)
        check(
            titled.values.allSatisfy {
                $0.wireGroupID == "copy:t0" && $0.originPublisherID == "unattributed:t0" && $0.basis == .copies
            }, "identical headlines across outlets are one group with an unnamed origin")
        let counted = try replay(twins)
        check(
            counted.independentReportsInWindow == 1 && counted.independentOriginsInWindow == 1,
            "an uncredited copy group counts once")
        let update = identities([
            article("a", publisher: "First", title: "Strikes kill three people in the city, medics say"),
            article("b", publisher: "Second", title: "Strikes kill four people in the city, medics say"),
        ])
        check(update.values.allSatisfy { $0.wireGroupID == nil }, "one changed word in a headline is not a twin")
        let short = identities([article("a", title: "Trivia night"), article("b", title: "Trivia night")])
        check(short.values.allSatisfy { $0.basis == .insufficient }, "short headlines are not evidence")
        let quoted = "the minister told reporters this morning that the deal would hold"
        let sharedQuote = identities([
            article("a", publisher: "First", description: quoted + " in the capital"),
            article("b", publisher: "Second", description: quoted + " at a briefing"),
        ])
        check(sharedQuote.values.allSatisfy { $0.wireGroupID == nil }, "a short shared quote is not a copy")
        let revised = identities([
            article("a", publisher: "First", content: prose("one")),
            article("b", publisher: "First", content: prose("one")),
        ])
        check(
            revised["a"]?.wireGroupID == "copy:a" && revised["b"]?.originPublisherID == "publisher:first",
            "one outlet repeating its full text is its own report")
        let marked = prose("mark").replacingOccurrences(of: "mark1", with: "ma\u{2060}rk1")
        check(
            identities([
                article("a", publisher: "First", content: prose("mark")),
                article("b", publisher: "Second", content: marked),
            ])["b"]?.wireGroupID == "copy:a", "zero-width marks cannot hide a verbatim copy")
    }

    static func checkReplayFeed() throws {
        let mixed = [
            article("a", publisher: "First", content: "(Reuters) - " + prose("wire")),
            article("b", publisher: "Second", content: prose("wire")),
            article("c", publisher: "Third", content: prose("own")),
            article("d", publisher: "Fourth"),
            article("e", publisher: "Fifth", content: prose("mixed") + " (FRANCE 24 with Reuters and AFP)"),
        ]
        let forward = EditorialWireIdentity.identities(event: mixed)
        check(
            forward == EditorialWireIdentity.identities(event: mixed.reversed() + mixed),
            "order and repeats do not matter")
        let summary = try replay(mixed)
        check(
            summary.independentReportsInWindow == 2 && summary.unknownMetadataRows == 2,
            "a mixed event neither throws on origins nor loses its unknown rows")
        let late = article("a", content: prose("one"), published: 90, fetched: 30)
        let clamped = EditorialWireIdentity.momentumReports(eventID: "event", members: [late])
        check(clamped[0].publishedAt == late.fetchedAt, "publication after storage is clamped to storage")
        check(try replay([late]).independentReportsInWindow == 1, "a future stamp does not fail the event's replay")
        let undated = WireIdentityArticle(
            articleID: "u", publisher: "First", title: "Undated", description: prose("one"), content: nil,
            publishedAt: DateParser.unknownDate, fetchedAt: epoch)
        check(EditorialWireIdentity.momentumReports(eventID: "event", members: [undated]).isEmpty, "undated stays out")
        let undatedCopy = WireIdentityArticle(
            articleID: "a", publisher: "First", title: "Repeat", description: prose("one"), content: nil,
            publishedAt: DateParser.unknownDate, fetchedAt: epoch)
        let dated = article("a", content: prose("one"), published: 10, fetched: 30)
        let repeated = EditorialWireIdentity.momentumReports(
            eventID: "event", members: [undatedCopy, dated, dated])
        check(
            repeated.count == 1 && repeated[0].publishedAt == dated.publishedAt,
            "a repeated article keeps its first dated row")
        let datedAlone = EditorialWireIdentity.momentumReports(eventID: "event", members: [dated])[0]
        check(
            repeated[0].wireGroupID == datedAlone.wireGroupID && datedAlone.wireGroupID != nil
                && repeated[0].originPublisherID == datedAlone.originPublisherID,
            "a repeated article's identity comes from the same dated copy")
        check(try replay([dated, dated]).rawRowsInWindow == 1, "a repeated article counts once in the replay")
    }

    static func checkAuthorCredits() throws {
        let blurb = identities([article("a", author: "none@none.com (Reuters)")])["a"]
        check(
            blurb?.wireGroupID == "wire:reuters" && blurb?.originPublisherID == "agency:reuters"
                && blurb?.basis == .credited, "an agency in the author field credits even a feed blurb")
        let copies = identities([
            article("a", publisher: "First", title: "Strikes kill three people in the city, medics say", author: "AFP"),
            article("b", publisher: "Second", title: "Strikes kill three people in the city, medics say"),
        ])
        check(copies["b"]?.originPublisherID == "agency:afp", "an author credit reaches the article's copies")
        let two = identities([article("a", author: "Reuters and Agence France-Presse")])["a"]
        check(two?.basis == .multipleCredits && two?.originPublisherID == nil, "two agencies leave the origin unknown")
        let person = identities([article("a", author: "Jane Doe")])["a"]
        check(person?.basis == .insufficient, "a person's name says nothing about a blurb's wire")
        let mapped = identities([article("a", content: prose("one"), author: "Jane Doe")])["a"]
        check(mapped?.originPublisherID == "publisher:outlet", "a person's name changes nothing on full text")
        check(EditorialWireIdentity.bylineAgencies("Cap News Desk").isEmpty, "agency letters inside words do not count")
    }

    static func checkParsedAuthors() {
        let rss = """
            <?xml version="1.0"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:media="http://search.yahoo.com/mrss/"><channel><title>Outlet</title>
            <item><title>One</title><link>https://example.com/1</link><author>none@none.com (Reuters)</author></item>
            <item><title>Two</title><link>https://example.com/2</link><dc:creator>Jane &amp;amp; Joe</dc:creator>
            <media:credit>AFP</media:credit></item>
            <item><title>Three</title><link>https://example.com/3</link><media:credit>AFP</media:credit></item>
            <item><title>Four</title><link>https://example.com/4</link><dc:creator>   </dc:creator></item>
            <item><title>Five</title><link>https://example.com/5</link><author>\(String(repeating: "x", count: 500))</author></item>
            </channel></rss>
            """
        let items = FeedXMLParser(data: Data(rss.utf8)).parse()
        check(items.count == 5, "the authored RSS parses")
        if items.count == 5 {
            check(items[0].author == "none@none.com (Reuters)", "RSS author is kept")
            check(items[1].author == "Jane & Joe", "dc:creator is kept and decoded")
            check(items[2].author == nil, "a media credit is a photo credit, not a byline")
            check(items[3].author == nil, "a blank author is none")
            check(items[4].author?.count == 300, "a hostile author is bounded")
        }
        let atom = """
            <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Outlet</title>
            <entry><title>One</title><id>tag:one</id><link href="https://example.com/a"/>
            <author><name>Agence France-Presse</name><uri>https://example.com</uri></author>
            <author><name>Jane Doe</name></author></entry></feed>
            """
        check(
            FeedXMLParser(data: Data(atom.utf8)).parse().first?.author == "Agence France-Presse, Jane Doe",
            "Atom author names are kept, without their addresses")
        let untitled = """
            <?xml version="1.0"?><rss version="2.0"><channel><item><guid isPermaLink="false">x</guid><title>One</title>
            <author>AFP</author></item></channel></rss>
            """
        let named = FeedXMLParser(data: Data(untitled.utf8), feedURL: "https://www.example.com/rss").parse().first
        check(named?.source == "Example" && named?.author == "AFP", "naming a source afterwards keeps the author")
    }

    static func checkStoredAuthors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-author-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        func value(_ sql: String) -> String? {
            var handle: OpaquePointer?
            var statement: OpaquePointer?
            guard sqlite3_open(path, &handle) == SQLITE_OK else { return nil }
            defer { sqlite3_close(handle) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        func story(author: String?) -> FeedArticle {
            FeedArticle(
                storedID: "one", title: "Headline", link: "https://example.com/one", guid: "one", description: "Blurb",
                pubDate: epoch, source: "Outlet", author: author)
        }
        let seed = DatabaseEngine(path: path)
        try await seed.open()
        try await seed.upsertArticles([story(author: "AFP")])
        check(value("SELECT author FROM articles") == "AFP", "a parsed author is stored")
        let revisions = value("SELECT count(*) FROM publisher_content_revisions")
        try await seed.upsertArticles([story(author: nil)])
        check(value("SELECT author FROM articles") == "AFP", "a refresh with no author keeps the stored one")
        try await seed.upsertArticles([story(author: "Reuters")])
        check(value("SELECT author FROM articles") == "Reuters", "a refresh with an author updates it")
        check(
            value("SELECT count(*) FROM publisher_content_revisions") == revisions,
            "an author change is not a publisher content revision")
        let loaded = try await seed.fetchArticles()
        check(
            loaded.first?.title == "Headline" && loaded.first?.author == nil, "a loaded story does not carry the author"
        )
        let stored = value("SELECT id FROM articles") ?? ""
        try await seed.markRead(articleId: stored, isRead: true)
        try await seed.setSaved(articleId: stored, isSaved: true)
        await seed.close()

        var handle: OpaquePointer?
        check(sqlite3_open(path, &handle) == SQLITE_OK, "open the library to take it back to v32")
        check(
            sqlite3_exec(
                handle,
                "PRAGMA legacy_alter_table=ON; ALTER TABLE articles DROP COLUMN author; PRAGMA user_version=32;",
                nil, nil, nil) == SQLITE_OK, "take the library back to v32")
        sqlite3_close(handle)
        let upgraded = DatabaseEngine(path: path)
        try await upgraded.open()
        await upgraded.close()
        check(value("PRAGMA user_version") == String(DatabaseEngine.schemaVersion), "a v32 library upgrades")
        check(
            value("SELECT title FROM articles WHERE author IS NULL") == "Headline",
            "an upgraded library keeps its stories, with no author yet")
        check(
            value("SELECT is_read || is_saved FROM article_state") == "11",
            "an upgraded library keeps read and saved state")
        let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        check(copies.contains { $0.contains("-before-v32-") }, "the upgrade keeps a v32 copy to roll back to")
    }

    static func checkNamedAuthorEstimate() throws {
        for (author, expected) in [
            ("Jane Doe", true), ("none@none.com (Jane Doe)", true), ("editorial@outlet.example (Jane Doe)", true),
            ("By Jane Doe and Joe Bloggs", true), ("Jane Doe Diplomatic editor", true), ("Jane Doe in Paris", true),
            ("Émile Zola", true), ("Emiliano de Pablos", true), ("none@none.com (News Desk)", false),
            ("editorial@outlet.example", false), ("FRANCE24", false), ("FRANCE 24", false), ("Becroll", false),
            ("By Outlet Staff", false), ("Guardian staff and agencies", false), ("HQ Web Team", false),
            ("Rédaction Outlet", false), ("Outlet Reporter", false), ("Reuters", false), ("Jane Doe, Reuters", false),
        ] {
            check(
                EditorialWireIdentityEvaluation.namedPerson(author, publisher: "Outlet") == expected,
                "named author filter on \(author)")
        }
        func row(_ id: String, publisher: String, title: String? = nil, author: String?)
            -> EditorialWireIdentityEvaluation.Row
        {
            EditorialWireIdentityEvaluation.Row(
                articleID: id, eventID: "event", publisher: publisher,
                title: title ?? "Distinct headline number \(id) here today", description: "Short blurb.", content: nil,
                publishedAt: epoch.timeIntervalSince1970 + 10, fetchedAt: epoch.timeIntervalSince1970 + 20,
                canonicalURL: "https://example.com/\(id)", author: author)
        }
        let copied = "Strikes kill three people in the city, medics say"
        let rows = [
            row("a", publisher: "First", author: "Jane Doe"),
            row("b", publisher: "Second", author: "News Desk"),
            row("c", publisher: "Third", title: copied, author: "Joe Bloggs"),
            row("d", publisher: "Fourth", title: copied, author: "Ann Lee"),
            row("e", publisher: "Fifth", author: nil),
        ]
        func isNamed(_ row: EditorialWireIdentityEvaluation.Row) -> Bool {
            row.author.map { EditorialWireIdentityEvaluation.namedPerson($0, publisher: row.publisher) } ?? false
        }
        let coverage = EditorialWireIdentityEvaluation.namedCoverage(rows, isNamed: isNamed)
        check(coverage["rows_named"] as? Int == 3, "the estimate counts rows with a person's name")
        check(coverage["unknown_rows_gaining_identity"] as? Int == 1, "only an unknown named row gains identity")
        check(
            coverage["named_rows_in_copies_across_outlets"] as? Int == 2,
            "named rows in a copy group across outlets count against the assumption")
        check(
            abs((coverage["known_wire_group_share_after"] as? Double ?? 0) - 0.6) < 1e-9,
            "the estimate's share adds the gained row")
        let baseline = try EditorialWireIdentityEvaluation.replays(rows)
        let estimate = try EditorialWireIdentityEvaluation.namedEstimate(rows, since: 0, isNamed: isNamed)
        let replayed = estimate["replay"] as? [String: Any]
        check(baseline["independent_reports"] as? Int == 1, "the replay itself leaves named blurbs unknown")
        check(replayed?["independent_reports"] as? Int == 2, "the estimate's replay counts the named blurb")
        check(
            EditorialWireIdentity.identities(event: rows.map(\.article)).first?.basis == .insufficient,
            "the estimate does not change the mapping")
    }

    static func run() async {
        do {
            try checkWireStories()
            try checkIndependentReports()
            try checkUnknowns()
            try checkCopies()
            try checkReplayFeed()
            try checkAuthorCredits()
            checkParsedAuthors()
            try await checkStoredAuthors()
            try checkNamedAuthorEstimate()
            if let input = ProcessInfo.processInfo.environment["NEWS_WIRE_IDENTITY_INPUT"],
                let output = ProcessInfo.processInfo.environment["NEWS_WIRE_IDENTITY_OUTPUT"]
            {
                try await EditorialWireIdentityEvaluation.run(
                    input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output))
            }
        } catch { check(false, "Unexpected error: \(error)") }
        print("Finished \(checks) wire identity checks with \(failures) failures.")
        if failures > 0 { recordFailure("EditorialWireIdentityTests: \(failures) check failure(s)") }
    }
}
