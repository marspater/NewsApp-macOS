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
import Testing

private typealias Fixture = EditorialWireIdentityTests

/// Native port of the `EditorialWireIdentityTests` atom (#1070): its nine check functions as nine tests, in the
/// runner's order, with each local `check` turned into `expectTrue` of NativeExpectations.swift (the runner log is
/// invisible to Swift Testing), so a failure is recorded and later tests still run. The non-asserting fixtures
/// (`epoch`, `prose`, `article`, `replay`, `identities`) stay in EditorialWireIdentityTests.swift. The evaluation the
/// runner starts when `NEWS_WIRE_IDENTITY_INPUT` and `NEWS_WIRE_IDENTITY_OUTPUT` are set is a research mode
/// (`script/test_editorial_wire_identity.sh`) and is not ported. The runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.editorial, .integration)) struct EditorialWireIdentitySuite {
        @Test func wireStories() throws {
            let body = Fixture.prose("wire")
            let wire = [
                Fixture.article("a", publisher: "First", content: "(Reuters) - " + body),
                Fixture.article("b", publisher: "Second", content: body),
                Fixture.article(
                    "c", publisher: "Third", content: body + " One extra closing sentence from the local desk."),
            ]
            let copies = Fixture.identities(wire)
            expectTrue(
                copies.values.allSatisfy {
                    $0.wireGroupID == "wire:reuters" && $0.originPublisherID == "agency:reuters"
                        && $0.basis == .credited
                }, "one credited wire and its uncredited copies share the agency")
            let syndicated = try Fixture.replay(wire)
            expectTrue(
                syndicated.rawRowsInWindow == 3 && syndicated.independentReportsInWindow == 1
                    && syndicated.independentOriginsInWindow == 1 && syndicated.unknownMetadataRows == 0,
                "a wire republished by three outlets counts once")
            let rewritten = Fixture.identities([
                Fixture.article("a", publisher: "First", content: "PARIS (AFP) — " + Fixture.prose("one")),
                Fixture.article("b", publisher: "Second", content: Fixture.prose("two") + " — AFP"),
            ])
            expectTrue(
                rewritten["a"]?.wireGroupID == "wire:afp" && rewritten["a"]?.wireGroupID == rewritten["b"]?.wireGroupID,
                "two differently worded credits to one agency are one group in an event")
            expectTrue(
                Fixture.identities([Fixture.article("a", publisher: "reuters")])["a"]?.basis == .credited,
                "an agency's own feed is credited")
            let combined = Fixture.identities([
                Fixture.article(
                    "a", publisher: "France 24", content: Fixture.prose("one") + " (FRANCE 24 with Reuters and AFP)")
            ])["a"]
            expectTrue(
                combined?.wireGroupID == "wire:afp+reuters" && combined?.originPublisherID == nil
                    && combined?.basis == .multipleCredits, "several credits leave the origin unknown")
        }

        @Test func independentReports() throws {
            let members = [
                Fixture.article("a", publisher: "First", content: Fixture.prose("one")),
                Fixture.article("b", publisher: "Second", content: Fixture.prose("two")),
            ]
            let independent = try Fixture.replay(members)
            expectTrue(
                independent.independentReportsInWindow == 2 && independent.independentOriginsInWindow == 2,
                "two independent reports stay two")
            expectTrue(
                Fixture.identities(members)["b"]?.originPublisherID == "publisher:second",
                "own report credits the publisher")
            // The band of real outlets each weaving the same agency paragraphs into their own story: pinned as
            // independent.
            let shared = Fixture.prose("shared", 70)
            let woven = Fixture.identities([
                Fixture.article("a", publisher: "First", content: shared + " " + Fixture.prose("one", 70)),
                Fixture.article("b", publisher: "Second", content: shared + " " + Fixture.prose("two", 70)),
            ])
            expectTrue(woven["a"]?.wireGroupID != woven["b"]?.wireGroupID, "half-shared text stays two reports")
            let looser = EditorialWireIdentity.identities(
                event: [
                    Fixture.article("a", publisher: "First", content: shared + " " + Fixture.prose("one", 70)),
                    Fixture.article("b", publisher: "Second", content: shared + " " + Fixture.prose("two", 70)),
                ], textContainment: 0.4)
            expectTrue(
                looser[0].wireGroupID == looser[1].wireGroupID, "the containment floor is the knob for that band")
            let quote = Fixture.identities([
                Fixture.article(
                    "a", publisher: "First", content: Fixture.prose("one") + " a spokesman told Reuters on Friday"),
                Fixture.article(
                    "b", publisher: "Second", content: Fixture.prose("two") + " according to Reuters on Friday"),
            ])
            expectTrue(
                quote.values.allSatisfy { $0.wireGroupID == nil && $0.basis == .agencyMention },
                "quoting an agency is neither a credit nor proof of independence")
            let caption = Fixture.identities([
                Fixture.article(
                    "a", content: Fixture.prose("one") + " in Paris on Tuesday. — AFP " + Fixture.prose("two"))
            ])["a"]
            expectTrue(caption?.basis == .agencyMention, "a mid-text photo credit is not a byline")
            let lowerCase = Fixture.identities([
                Fixture.article("a", content: Fixture.prose("one") + " cupid up the map")
            ])[
                "a"]
            expectTrue(lowerCase?.basis == .fullText, "words containing agency letters are not mentions")
        }

        @Test func unknowns() throws {
            let snippet = Fixture.article("a", description: "A blurb too short to hold a byline.")
            expectTrue(
                Fixture.identities([snippet])["a"]
                    == WireIdentity(
                        articleID: "a", wireGroupID: nil, originPublisherID: nil, basis: .insufficient),
                "a feed blurb stays unknown")
            let unknown = try Fixture.replay([snippet])
            expectTrue(
                unknown.unknownMetadataRows == 1 && unknown.independentReportsInWindow == 0,
                "unknown rows are counted and never credited as independent")
            expectTrue(
                Fixture.identities([Fixture.article("a", publisher: "  ", content: Fixture.prose("one"))])["a"]?.basis
                    == .insufficient,
                "no publisher stays unknown")
        }

        @Test func copies() throws {
            let twins = (0..<3).map {
                Fixture.article(
                    "t\($0)", publisher: "Outlet \($0)", title: "Strikes kill three people in the city, medics say",
                    description: "Different blurb number \($0).", published: Double(10 + $0))
            }
            let titled = Fixture.identities(twins)
            expectTrue(
                titled.values.allSatisfy {
                    $0.wireGroupID == "copy:t0" && $0.originPublisherID == "unattributed:t0" && $0.basis == .copies
                }, "identical headlines across outlets are one group with an unnamed origin")
            let counted = try Fixture.replay(twins)
            expectTrue(
                counted.independentReportsInWindow == 1 && counted.independentOriginsInWindow == 1,
                "an uncredited copy group counts once")
            let update = Fixture.identities([
                Fixture.article("a", publisher: "First", title: "Strikes kill three people in the city, medics say"),
                Fixture.article("b", publisher: "Second", title: "Strikes kill four people in the city, medics say"),
            ])
            expectTrue(
                update.values.allSatisfy { $0.wireGroupID == nil }, "one changed word in a headline is not a twin")
            let short = Fixture.identities([
                Fixture.article("a", title: "Trivia night"), Fixture.article("b", title: "Trivia night"),
            ])
            expectTrue(short.values.allSatisfy { $0.basis == .insufficient }, "short headlines are not evidence")
            let quoted = "the minister told reporters this morning that the deal would hold"
            let sharedQuote = Fixture.identities([
                Fixture.article("a", publisher: "First", description: quoted + " in the capital"),
                Fixture.article("b", publisher: "Second", description: quoted + " at a briefing"),
            ])
            expectTrue(sharedQuote.values.allSatisfy { $0.wireGroupID == nil }, "a short shared quote is not a copy")
            let revised = Fixture.identities([
                Fixture.article("a", publisher: "First", content: Fixture.prose("one")),
                Fixture.article("b", publisher: "First", content: Fixture.prose("one")),
            ])
            expectTrue(
                revised["a"]?.wireGroupID == "copy:a" && revised["b"]?.originPublisherID == "publisher:first",
                "one outlet repeating its full text is its own report")
            let marked = Fixture.prose("mark").replacingOccurrences(of: "mark1", with: "ma\u{2060}rk1")
            expectTrue(
                Fixture.identities([
                    Fixture.article("a", publisher: "First", content: Fixture.prose("mark")),
                    Fixture.article("b", publisher: "Second", content: marked),
                ])["b"]?.wireGroupID == "copy:a", "zero-width marks cannot hide a verbatim copy")
        }

        @Test func replayFeed() throws {
            let mixed = [
                Fixture.article("a", publisher: "First", content: "(Reuters) - " + Fixture.prose("wire")),
                Fixture.article("b", publisher: "Second", content: Fixture.prose("wire")),
                Fixture.article("c", publisher: "Third", content: Fixture.prose("own")),
                Fixture.article("d", publisher: "Fourth"),
                Fixture.article(
                    "e", publisher: "Fifth", content: Fixture.prose("mixed") + " (FRANCE 24 with Reuters and AFP)"),
            ]
            let forward = EditorialWireIdentity.identities(event: mixed)
            expectTrue(
                forward == EditorialWireIdentity.identities(event: mixed.reversed() + mixed),
                "order and repeats do not matter")
            let summary = try Fixture.replay(mixed)
            expectTrue(
                summary.independentReportsInWindow == 2 && summary.unknownMetadataRows == 2,
                "a mixed event neither throws on origins nor loses its unknown rows")
            let late = Fixture.article("a", content: Fixture.prose("one"), published: 90, fetched: 30)
            let clamped = EditorialWireIdentity.momentumReports(eventID: "event", members: [late])
            expectTrue(clamped[0].publishedAt == late.fetchedAt, "publication after storage is clamped to storage")
            expectTrue(
                try Fixture.replay([late]).independentReportsInWindow == 1,
                "a future stamp does not fail the event's replay")
            let undated = WireIdentityArticle(
                articleID: "u", publisher: "First", title: "Undated", description: Fixture.prose("one"), content: nil,
                publishedAt: DateParser.unknownDate, fetchedAt: Fixture.epoch)
            expectTrue(
                EditorialWireIdentity.momentumReports(eventID: "event", members: [undated]).isEmpty,
                "undated stays out")
            let undatedCopy = WireIdentityArticle(
                articleID: "a", publisher: "First", title: "Repeat", description: Fixture.prose("one"), content: nil,
                publishedAt: DateParser.unknownDate, fetchedAt: Fixture.epoch)
            let dated = Fixture.article("a", content: Fixture.prose("one"), published: 10, fetched: 30)
            let repeated = EditorialWireIdentity.momentumReports(
                eventID: "event", members: [undatedCopy, dated, dated])
            expectTrue(
                repeated.count == 1 && repeated[0].publishedAt == dated.publishedAt,
                "a repeated article keeps its first dated row")
            let datedAlone = EditorialWireIdentity.momentumReports(eventID: "event", members: [dated])[0]
            expectTrue(
                repeated[0].wireGroupID == datedAlone.wireGroupID && datedAlone.wireGroupID != nil
                    && repeated[0].originPublisherID == datedAlone.originPublisherID,
                "a repeated article's identity comes from the same dated copy")
            expectTrue(
                try Fixture.replay([dated, dated]).rawRowsInWindow == 1, "a repeated article counts once in the replay")
        }

        @Test func authorCredits() throws {
            let blurb = Fixture.identities([Fixture.article("a", author: "none@none.com (Reuters)")])["a"]
            expectTrue(
                blurb?.wireGroupID == "wire:reuters" && blurb?.originPublisherID == "agency:reuters"
                    && blurb?.basis == .credited, "an agency in the author field credits even a feed blurb")
            let copies = Fixture.identities([
                Fixture.article(
                    "a", publisher: "First", title: "Strikes kill three people in the city, medics say", author: "AFP"),
                Fixture.article("b", publisher: "Second", title: "Strikes kill three people in the city, medics say"),
            ])
            expectTrue(copies["b"]?.originPublisherID == "agency:afp", "an author credit reaches the article's copies")
            let two = Fixture.identities([Fixture.article("a", author: "Reuters and Agence France-Presse")])["a"]
            expectTrue(
                two?.basis == .multipleCredits && two?.originPublisherID == nil, "two agencies leave the origin unknown"
            )
            let person = Fixture.identities([Fixture.article("a", author: "Jane Doe")])["a"]
            expectTrue(person?.basis == .insufficient, "a person's name says nothing about a blurb's wire")
            let mapped = Fixture.identities([Fixture.article("a", content: Fixture.prose("one"), author: "Jane Doe")])[
                "a"]
            expectTrue(mapped?.originPublisherID == "publisher:outlet", "a person's name changes nothing on full text")
            expectTrue(
                EditorialWireIdentity.bylineAgencies("Cap News Desk").isEmpty,
                "agency letters inside words do not count")
        }

        @Test func parsedAuthors() {
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
            expectTrue(items.count == 5, "the authored RSS parses")
            if items.count == 5 {
                expectTrue(items[0].author == "none@none.com (Reuters)", "RSS author is kept")
                expectTrue(items[1].author == "Jane & Joe", "dc:creator is kept and decoded")
                expectTrue(items[2].author == nil, "a media credit is a photo credit, not a byline")
                expectTrue(items[3].author == nil, "a blank author is none")
                expectTrue(items[4].author?.count == 300, "a hostile author is bounded")
            }
            let atom = """
                <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Outlet</title>
                <entry><title>One</title><id>tag:one</id><link href="https://example.com/a"/>
                <author><name>Agence France-Presse</name><uri>https://example.com</uri></author>
                <author><name>Jane Doe</name></author></entry></feed>
                """
            expectTrue(
                FeedXMLParser(data: Data(atom.utf8)).parse().first?.author == "Agence France-Presse, Jane Doe",
                "Atom author names are kept, without their addresses")
            let untitled = """
                <?xml version="1.0"?><rss version="2.0"><channel><item><guid isPermaLink="false">x</guid><title>One</title>
                <author>AFP</author></item></channel></rss>
                """
            let named = FeedXMLParser(data: Data(untitled.utf8), feedURL: "https://www.example.com/rss").parse().first
            expectTrue(
                named?.source == "Example" && named?.author == "AFP", "naming a source afterwards keeps the author")
        }

        @Test func storedAuthors() async throws {
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
                    storedID: "one", title: "Headline", link: "https://example.com/one", guid: "one",
                    description: "Blurb", pubDate: Fixture.epoch, source: "Outlet", author: author)
            }
            let seed = DatabaseEngine(path: path)
            try await seed.open()
            try await seed.upsertArticles([story(author: "AFP")])
            expectTrue(value("SELECT author FROM articles") == "AFP", "a parsed author is stored")
            let revisions = value("SELECT count(*) FROM publisher_content_revisions")
            try await seed.upsertArticles([story(author: nil)])
            expectTrue(value("SELECT author FROM articles") == "AFP", "a refresh with no author keeps the stored one")
            try await seed.upsertArticles([story(author: "Reuters")])
            expectTrue(value("SELECT author FROM articles") == "Reuters", "a refresh with an author updates it")
            expectTrue(
                value("SELECT count(*) FROM publisher_content_revisions") == revisions,
                "an author change is not a publisher content revision")
            let loaded = try await seed.fetchArticles()
            expectTrue(
                loaded.first?.title == "Headline" && loaded.first?.author == nil,
                "a loaded story does not carry the author")
            let stored = value("SELECT id FROM articles") ?? ""
            try await seed.markRead(articleId: stored, isRead: true)
            try await seed.setSaved(articleId: stored, isSaved: true)
            await seed.close()

            var handle: OpaquePointer?
            expectTrue(sqlite3_open(path, &handle) == SQLITE_OK, "open the library to take it back to v32")
            expectTrue(
                sqlite3_exec(
                    handle,
                    "PRAGMA legacy_alter_table=ON; ALTER TABLE articles DROP COLUMN author; PRAGMA user_version=32;",
                    nil, nil, nil) == SQLITE_OK, "take the library back to v32")
            sqlite3_close(handle)
            let upgraded = DatabaseEngine(path: path)
            try await upgraded.open()
            await upgraded.close()
            expectTrue(value("PRAGMA user_version") == String(DatabaseEngine.schemaVersion), "a v32 library upgrades")
            expectTrue(
                value("SELECT title FROM articles WHERE author IS NULL") == "Headline",
                "an upgraded library keeps its stories, with no author yet")
            expectTrue(
                value("SELECT is_read || is_saved FROM article_state") == "11",
                "an upgraded library keeps read and saved state")
            let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            expectTrue(copies.contains { $0.contains("-before-v32-") }, "the upgrade keeps a v32 copy to roll back to")
        }

        @Test func namedAuthorEstimate() throws {
            for (author, expected) in [
                ("Jane Doe", true), ("none@none.com (Jane Doe)", true), ("editorial@outlet.example (Jane Doe)", true),
                ("By Jane Doe and Joe Bloggs", true), ("Jane Doe Diplomatic editor", true), ("Jane Doe in Paris", true),
                ("Émile Zola", true), ("Emiliano de Pablos", true), ("none@none.com (News Desk)", false),
                ("editorial@outlet.example", false), ("FRANCE24", false), ("FRANCE 24", false), ("Becroll", false),
                ("By Outlet Staff", false), ("Guardian staff and agencies", false), ("HQ Web Team", false),
                ("Rédaction Outlet", false), ("Outlet Reporter", false), ("Reuters", false),
                ("Jane Doe, Reuters", false),
            ] {
                expectTrue(
                    EditorialWireIdentityEvaluation.namedPerson(author, publisher: "Outlet") == expected,
                    "named author filter on \(author)")
            }
            func row(_ id: String, publisher: String, title: String? = nil, author: String?)
                -> EditorialWireIdentityEvaluation.Row
            {
                EditorialWireIdentityEvaluation.Row(
                    articleID: id, eventID: "event", publisher: publisher,
                    title: title ?? "Distinct headline number \(id) here today", description: "Short blurb.",
                    content: nil, publishedAt: Fixture.epoch.timeIntervalSince1970 + 10,
                    fetchedAt: Fixture.epoch.timeIntervalSince1970 + 20, canonicalURL: "https://example.com/\(id)",
                    author: author)
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
            expectTrue(coverage["rows_named"] as? Int == 3, "the estimate counts rows with a person's name")
            expectTrue(
                coverage["unknown_rows_gaining_identity"] as? Int == 1, "only an unknown named row gains identity")
            expectTrue(
                coverage["named_rows_in_copies_across_outlets"] as? Int == 2,
                "named rows in a copy group across outlets count against the assumption")
            expectTrue(
                abs((coverage["known_wire_group_share_after"] as? Double ?? 0) - 0.6) < 1e-9,
                "the estimate's share adds the gained row")
            let baseline = try EditorialWireIdentityEvaluation.replays(rows)
            let estimate = try EditorialWireIdentityEvaluation.namedEstimate(rows, since: 0, isNamed: isNamed)
            let replayed = estimate["replay"] as? [String: Any]
            expectTrue(baseline["independent_reports"] as? Int == 1, "the replay itself leaves named blurbs unknown")
            expectTrue(replayed?["independent_reports"] as? Int == 2, "the estimate's replay counts the named blurb")
            expectTrue(
                EditorialWireIdentity.identities(event: rows.map(\.article)).first?.basis == .insufficient,
                "the estimate does not change the mapping")
        }
    }
}
