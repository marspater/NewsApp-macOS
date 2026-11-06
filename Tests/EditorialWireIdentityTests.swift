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
        content: String? = nil, published: Double = 10, fetched: Double = 20
    ) -> WireIdentityArticle {
        WireIdentityArticle(
            articleID: id, publisher: publisher, title: title ?? "Distinct headline number \(id) here today",
            description: description, content: content, publishedAt: epoch.addingTimeInterval(published),
            fetchedAt: epoch.addingTimeInterval(fetched))
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
        check(try replay([dated, dated]).rawRowsInWindow == 1, "a repeated article counts once in the replay")
    }

    static func run() async {
        do {
            try checkWireStories()
            try checkIndependentReports()
            try checkUnknowns()
            try checkCopies()
            try checkReplayFeed()
            if let input = ProcessInfo.processInfo.environment["NEWS_WIRE_IDENTITY_INPUT"],
                let output = ProcessInfo.processInfo.environment["NEWS_WIRE_IDENTITY_OUTPUT"]
            {
                try EditorialWireIdentityEvaluation.run(
                    input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output))
            }
        } catch { check(false, "Unexpected error: \(error)") }
        print("Finished \(checks) wire identity checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
