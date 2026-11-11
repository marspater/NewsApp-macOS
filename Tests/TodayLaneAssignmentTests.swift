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

/// Unit and regression suite for Z2 Today lane assignment and importance scoring (`#934`, Epic Z `#932`).
enum TodayLaneAssignmentTests {
    static func run() async throws {
        try await NewsTests.runTodayLaneAssignmentTests()
    }
}

extension NewsTests {
    static func runTodayLaneAssignmentTests() async throws {
        let tests: [(name: String, run: () async throws -> Void)] = [
            ("testLaneOrdersAndMetadata", { testTodayLaneOrdersAndMetadata() }),
            ("testLeadFallbackAndAffinityTieBreak", { testTodayLeadFallbackAndAffinityTieBreak() }),
            ("testWireCopyDoesNotInflateOriginalReportsInLead", { testTodayWireCopyDoesNotInflateLead() }),
            ("testInMotionClockHeadlineAndMaterialChange", { testTodayInMotionClockAndMaterialChange() }),
            ("testDeepReadAssignedBeforeYourBeatAndLabelContract", { testTodayDeepReadOrderAndLabelContract() }),
            ("testDeepReadOverflowKeepsDepthAndSummaryPhraseAlone", { testTodayDeepReadOverflowKeepsDepth() }),
            ("testYourBeatFinerProfileAndOverflowCascade", { testTodayYourBeatProfileAndOverflowCascade() }),
            ("testOutsideYourUsualAndNewLibraryEmptyHistory", { testTodayOutsideYourUsualAndNewLibrary() }),
            ("testConditionalUnderflowHidesLaneAndCascades", { testTodayUnderflowHidesAndCascades() }),
            ("testSubscriptionPoolAndZeroDuplicatesAndLatestSafetyNet", { testTodaySubscriptionPoolAndSafetyNet() }),
            ("testCoverageGateAndDevelopingPill", { testTodayCoverageGateAndDevelopingPill() }),
            ("testCardMetadataHasRealSourcesOrIsHidden", { testTodayCardMetadata() }),
            ("testFocusMovesWithinAndBetweenLanes", { testTodayFocusMap() }),
            ("testFocusIsRestoredWhenTheEditionChanges", { testTodayFocusRestore() }),
            ("testEditionKeepsLanesUntilAnUpdateIsApplied", { testTodayEditionPinsLanes() }),
            ("testHeldEditionKeepsTagsEntriesAndNewEditionSortsLatest", { testTodayHeldEditionDetails() }),
            ("testNotificationThresholdsRemainIndependent", { testTodayNotificationThresholdsIndependent() }),
            ("testDeterminismAndDatabaseLoaderIntegration", { try await testTodayDeterminismAndDatabaseLoader() }),
            ("testLoaderGroupingConfidenceCoversStory", { try await testTodayLoaderGroupingConfidenceCoversStory() }),
            ("testLoaderSectorImpactNeedsStoredSection", { try await testTodayLoaderSectorImpactNeedsStoredSection() }),
        ]
        try await runSuite(tests)
    }

    private static let referenceNow = Date(timeIntervalSince1970: 1_794_310_000)

    private static func makeArticle(
        id: String,
        title: String,
        description: String = "Standard summary of the reported developments.",
        source: String = "Global Times",
        link: String? = nil,
        feedURL: String = "https://global.example/rss",
        category: String? = "World",
        pubDate: Date,
        fullContent: String? = nil,
        entities: [EntityResult]? = nil
    ) -> FeedArticle {
        var article = FeedArticle(
            storedID: id,
            title: title,
            link: link ?? "https://global.example/stories/\(id)",
            guid: id,
            description: description,
            pubDate: pubDate,
            source: source,
            fullContent: fullContent,
            category: category,
            entities: entities
        )
        article.identityFeedURL = feedURL
        return article
    }

    private static func makeEventEntry(
        eventID: String,
        members: [(id: String, source: String, title: String, description: String, date: Date, feedURL: String)],
        seenVersion: Int? = nil,
        isRead: Bool = false
    ) -> FeedEntry {
        let articles = members.map { m in
            makeArticle(
                id: m.id, title: m.title, description: m.description, source: m.source,
                feedURL: m.feedURL, pubDate: m.date)
        }
        let feedMembers = members.enumerated().map { idx, m in
            EventFeedMember(
                articleID: m.id,
                source: m.source,
                title: m.title,
                date: m.date,
                joinedVersion: idx + 1,
                isRead: isRead,
                isSaved: false
            )
        }
        let summary = EventFeedSummary(
            eventID: eventID,
            membershipVersion: max(1, feedMembers.count),
            seenVersion: seenVersion,
            members: feedMembers
        )
        return .event(summary, representative: articles[0], visibleMembers: articles)
    }

    static func testTodayLaneOrdersAndMetadata() {
        assertEqual(
            TodayLane.assignmentOrder,
            [.theLead, .inMotion, .theDeepRead, .yourBeat, .outsideYourUsual, .theLatest],
            "Assignment order places The Deep Read before Your Beat (spec §4.1)")
        assertEqual(
            TodayLane.displayOrder,
            [.theLead, .inMotion, .yourBeat, .theDeepRead, .outsideYourUsual, .theLatest],
            "Display order keeps Your Beat above The Deep Read")

        let plan = TodayEditionAssigner.assign(entries: [], context: TodayAssignmentContext(now: referenceNow))
        assertEqual(plan.displayLanes.map(\.lane), TodayLane.displayOrder, "Display lanes follow page order")
        assertTrue(plan.result(for: .theLatest)?.qualifies == true, "The Latest always qualifies")
        assertFalse(plan.result(for: .theDeepRead)?.qualifies == true, "Empty conditional lanes do not qualify")
    }

    static func testTodayLeadFallbackAndAffinityTieBreak() {
        // Low-score single-report story: Slide 1 still shows (no padding for slides 2-5).
        let singleLow = FeedEntry.article(
            makeArticle(
                id: "s-low",
                title: "Town council approves park bench repairs",
                description: "Maintenance crews will repaint benches next Tuesday.",
                source: "Local Herald",
                feedURL: "https://local.example/rss",
                pubDate: referenceNow.addingTimeInterval(-600)
            ))
        let secondLow = FeedEntry.article(
            makeArticle(
                id: "s-low-2",
                title: "Regional library extends Saturday hours",
                description: "Opening hours shift by thirty minutes.",
                source: "Local Herald",
                feedURL: "https://local.example/rss",
                pubDate: referenceNow.addingTimeInterval(-1200)
            ))
        let minimalPlan = TodayEditionAssigner.assign(
            entries: [singleLow, secondLow],
            context: TodayAssignmentContext(now: referenceNow)
        )
        assertEqual(minimalPlan.entries(for: .theLead).count, 1, "Only Slide 1 enters when second fails Lead bar")
        assertEqual(minimalPlan.entries(for: .theLead).first?.id, "s-low")
        assertEqual(minimalPlan.entries(for: .theLatest).map(\.id), ["s-low-2"])

        // Tie-break rule: publisher affinity breaks ties but NEVER lifts a 1-report story ahead of a multi-report one.
        let oneReportFavorite = FeedEntry.article(
            makeArticle(
                id: "fav-one",
                title: "Major port shutdown disrupts shipping routes",
                description: "Port authorities closed berths.",
                source: "Favorite Daily",
                feedURL: "https://fav.example/rss",
                pubDate: referenceNow.addingTimeInterval(-300)
            ))
        let twoReportOther = makeEventEntry(
            eventID: "ev-multi",
            members: [
                (
                    "m1", "Alpha News", "Major port shutdown disrupts shipping routes",
                    "Port authorities closed berths.",
                    referenceNow.addingTimeInterval(-400), "https://alpha.example/rss"
                ),
                (
                    "m2", "Beta Wire", "Ships rerouted after port shutdown", "Freight delayed across corridor.",
                    referenceNow.addingTimeInterval(-500), "https://beta.example/rss"
                ),
            ]
        )
        let profile = TodayUserProfile(publisherWeights: ["favorite daily": 20.0, "alpha news": 1.0])
        let signals: [String: TodayStorySignals] = [
            "fav-one": TodayStorySignals(
                originalReportCount: 1, nlImportanceOverride: 0.85, resolvedImportanceOverride: .major),
            "m1": TodayStorySignals(
                originalReportCount: 2, nlImportanceOverride: 0.85, resolvedImportanceOverride: .major),
        ]
        // Give equal synthetic score by setting equal nlImportanceOverride and same assessed importance, OR
        // check exact sort when multi-report score equals single-report score.
        let equalSignals: [String: TodayStorySignals] = [
            "fav-one": TodayStorySignals(
                originalReportCount: 2, nlImportanceOverride: 0.80, resolvedImportanceOverride: .major),
            "m1": TodayStorySignals(
                originalReportCount: 3, nlImportanceOverride: 0.80, resolvedImportanceOverride: .major),
        ]
        let tiedPlan = TodayEditionAssigner.assign(
            entries: [oneReportFavorite, twoReportOther],
            context: TodayAssignmentContext(
                now: referenceNow,
                profile: profile,
                signalsByEntryID: signals
            )
        )
        assertEqual(
            tiedPlan.entries(for: .theLead).first?.id, "m1",
            "Multi-report story outranks single-report favorite in The Lead even with lower publisher affinity")

        // When two multi-report stories tie in score & originals, higher affinity breaks the tie:
        let favMulti = makeEventEntry(
            eventID: "ev-fav",
            members: [
                (
                    "fm1", "Favorite Daily", "Central bank holds emergency rate session",
                    "Policy makers met overnight.",
                    referenceNow.addingTimeInterval(-200), "https://fav.example/rss"
                ),
                (
                    "fm2", "Gamma Press", "Emergency rate talks end with freeze", "Rates remain steady.",
                    referenceNow.addingTimeInterval(-300), "https://gamma.example/rss"
                ),
            ]
        )
        let otherMulti = makeEventEntry(
            eventID: "ev-other",
            members: [
                (
                    "om1", "Alpha News", "Central bank holds emergency rate session", "Policy makers met overnight.",
                    referenceNow.addingTimeInterval(-100), "https://alpha.example/rss"
                ),
                (
                    "om2", "Delta Times", "Emergency rate talks end with freeze", "Rates remain steady.",
                    referenceNow.addingTimeInterval(-200), "https://delta.example/rss"
                ),
            ]
        )
        let tieSignals: [String: TodayStorySignals] = [
            "fm1": TodayStorySignals(
                originalReportCount: 2, nlImportanceOverride: 0.80, resolvedImportanceOverride: .major),
            "om1": TodayStorySignals(
                originalReportCount: 2, nlImportanceOverride: 0.80, resolvedImportanceOverride: .major),
        ]
        let tieBreakPlan = TodayEditionAssigner.assign(
            entries: [otherMulti, favMulti],
            context: TodayAssignmentContext(now: referenceNow, profile: profile, signalsByEntryID: tieSignals)
        )
        assertEqual(
            tieBreakPlan.entries(for: .theLead).prefix(2).map(\.id), ["fm1", "om1"],
            "Affinity breaks Lead ties after score and original report count")
        _ = equalSignals
    }

    static func testTodayWireCopyDoesNotInflateLead() {
        // 4 publishers running the exact same AP wire copy == 1 original report, NOT 4!
        let wireBody = "GENEVA (AP) - Negotiators adjourned talks without announcing a formal schedule for next week."
        let wireOnlyEvent = makeEventEntry(
            eventID: "ev-wire",
            members: [
                (
                    "w1", "Daily One", "Negotiators adjourn Geneva talks", wireBody,
                    referenceNow.addingTimeInterval(-300), "https://p1.example/rss"
                ),
                (
                    "w2", "Daily Two", "Geneva talks adjourned by delegates", wireBody,
                    referenceNow.addingTimeInterval(-350), "https://p2.example/rss"
                ),
                (
                    "w3", "Daily Three", "Delegates adjourn Geneva discussions", wireBody,
                    referenceNow.addingTimeInterval(-400), "https://p3.example/rss"
                ),
                (
                    "w4", "Daily Four", "Talks in Geneva pause until next week", wireBody,
                    referenceNow.addingTimeInterval(-450), "https://p4.example/rss"
                ),
            ]
        )
        let originalTwoEvent = makeEventEntry(
            eventID: "ev-orig",
            members: [
                (
                    "o1", "Harbor Times", "Emergency quake aid reaches coastal towns after Crisis alert",
                    "Crisis response teams opened three corridors after severe damage.",
                    referenceNow.addingTimeInterval(-200), "https://harbor.example/rss"
                ),
                (
                    "o2", "Coastal Post", "Rescuers reach damaged port towns amid emergency alert",
                    "Medical teams arrived by sea following the crisis.",
                    referenceNow.addingTimeInterval(-260), "https://coastal.example/rss"
                ),
            ]
        )
        let signals: [String: TodayStorySignals] = [
            "w1": TodayStorySignals(
                memberFullTexts: [wireBody, wireBody, wireBody, wireBody],
                nlImportanceOverride: 0.55,
                resolvedImportanceOverride: .notable),
            "o1": TodayStorySignals(
                memberFullTexts: [
                    "Our reporter observed rescue convoys arriving at the port.",
                    "Correspondents spoke with local hospital directors.",
                ],
                nlImportanceOverride: 0.85,
                resolvedImportanceOverride: .major),
        ]
        let plan = TodayEditionAssigner.assign(
            entries: [wireOnlyEvent, originalTwoEvent],
            context: TodayAssignmentContext(now: referenceNow, signalsByEntryID: signals)
        )
        let leadIDs = plan.entries(for: .theLead).map(\.id)
        assertEqual(leadIDs.first, "o1", "Two original reports outrank four wire-copy reprints")
        assertFalse(leadIDs.contains("w1"), "Low-score 4-publisher wire copy does not clear Lead multi-report gate")
    }

    static func testTodayInMotionClockAndMaterialChange() {
        let oldTime = referenceNow.addingTimeInterval(-30 * 3600)  // before 24 h cutoff
        let recent1 = referenceNow.addingTimeInterval(-1800)  // inside 24 h
        let recent2 = referenceNow.addingTimeInterval(-900)  // inside 24 h

        // Qualifying events (even when seenVersion == membershipVersion and isRead == true!)
        func qualifyingInMotion(id: String, index: Int) -> FeedEntry {
            makeEventEntry(
                eventID: "im-\(id)",
                members: [
                    (
                        "\(id)-new-2", "Outlet A\(index)",
                        "Court blocks merger and orders divestiture of regional assets", "Fresh ruling.",
                        recent2, "https://a.example/rss"
                    ),
                    (
                        "\(id)-new-1", "Outlet B\(index)",
                        "Antitrust panel issues final injunction halting deal", "Panel acted today.",
                        recent1, "https://b.example/rss"
                    ),
                    (
                        "\(id)-old", "Outlet C\(index)",
                        "Regulators open preliminary inquiry into proposed rail merger", "Initial filing.",
                        oldTime, "https://c.example/rss"
                    ),
                ],
                seenVersion: 3,  // already opened in full
                isRead: true  // already read
            )
        }

        // All reports inside 24h -> NEW, not updated -> MUST NOT qualify for In Motion.
        let allInside24h = makeEventEntry(
            eventID: "im-new-only",
            members: [
                (
                    "inside-2", "Outlet X", "Subway service suspended after power failure", "Crews dispatched.",
                    recent2, "https://x.example/rss"
                ),
                (
                    "inside-1", "Outlet Y", "City deploys shuttle buses amid subway outage", "Transit update.",
                    recent1, "https://y.example/rss"
                ),
            ]
        )

        // Headline paraphrase repetition -> MUST NOT qualify for In Motion.
        let repetitionEvent = makeEventEntry(
            eventID: "im-repeat",
            members: [
                (
                    "rep-new", "Outlet P", "Parliament debates annual budget bill on Wednesday", "Same bill.",
                    recent1, "https://p.example/rss"
                ),
                (
                    "rep-old", "Outlet Q", "Annual budget bill debated by Parliament on Tuesday", "Same bill.",
                    oldTime, "https://q.example/rss"
                ),
            ]
        )

        // Force a stronger Lead story to take Slide 1 while keeping our In Motion candidates in the pool.
        let leadWinner = makeEventEntry(
            eventID: "ev-lead",
            members: [
                (
                    "lead-1", "Lead One", "National emergency declared after severe coastal storms kill dozens",
                    "Major crisis.",
                    recent1, "https://lead1.example/rss"
                ),
                (
                    "lead-2", "Lead Two", "Evacuations ordered across three provinces after deadly storms",
                    "Emergency.",
                    recent2, "https://lead2.example/rss"
                ),
                (
                    "lead-3", "Lead Three", "Aid airlift begins after coastal storm disaster", "Response.",
                    recent1.addingTimeInterval(-300), "https://lead3.example/rss"
                ),
            ]
        )

        let plan = TodayEditionAssigner.assign(
            entries: [
                leadWinner,
                qualifyingInMotion(id: "1", index: 1),
                qualifyingInMotion(id: "2", index: 2),
                qualifyingInMotion(id: "3", index: 3),
                allInside24h,
                repetitionEvent,
            ],
            context: TodayAssignmentContext(
                now: referenceNow,
                signalsByEntryID: [
                    "lead-1": TodayStorySignals(nlImportanceOverride: 0.95, resolvedImportanceOverride: .major),
                    "1-new-2": TodayStorySignals(nlImportanceOverride: 0.30, resolvedImportanceOverride: .minor),
                    "2-new-2": TodayStorySignals(nlImportanceOverride: 0.30, resolvedImportanceOverride: .minor),
                    "3-new-2": TodayStorySignals(nlImportanceOverride: 0.30, resolvedImportanceOverride: .minor),
                ]
            )
        )

        let inMotionIDs = Set(plan.entries(for: .inMotion).map(\.id))
        assertEqual(
            inMotionIDs, ["1-new-2", "2-new-2", "3-new-2"],
            "Read/seen state never removes a story from In Motion; all-inside-24h and paraphrase repetition stay out")
        assertFalse(inMotionIDs.contains("inside-2"))
        assertFalse(inMotionIDs.contains("rep-new"))
    }

    static func testTodayDeepReadOrderAndLabelContract() {
        let longBody = Array(repeating: "reporting", count: 1650).joined(separator: " ")  // >= 1,600 words (~8.25 min)
        // Stories also match the user's entity profile strongly, proving The Deep Read beats Your Beat!
        let profile = TodayUserProfile(
            entityWeights: ["organization:meridian-labs": 15.0],
            keywordWeights: ["meridian": 12.0, "semiconductor": 12.0],
            publisherWeights: ["global times": 10.0],
            interactionCount: 15
        )
        let lead = makeEventEntry(
            eventID: "lead",
            members: [
                (
                    "l1", "Alpha", "Emergency summit opens after crisis alert", "Summit crisis.", referenceNow,
                    "https://a.example/rss"
                ),
                (
                    "l2", "Beta", "Leaders meet in emergency crisis session", "Summit.", referenceNow,
                    "https://b.example/rss"
                ),
            ]
        )
        let longNoType = FeedEntry.article(
            makeArticle(
                id: "dr-len",
                title: "Meridian Labs semiconductor supply chain overview",
                description: "A long stored feature with no genre keyword.",
                pubDate: referenceNow.addingTimeInterval(-300),
                fullContent: longBody,
                entities: [EntityResult(name: "Meridian Labs", type: .organization)]
            ))
        let investigation = FeedEntry.article(
            makeArticle(
                id: "dr-inv",
                title: "Investigation: Inside Meridian Labs procurement records",
                description: "Special report on internal filings.",
                pubDate: referenceNow.addingTimeInterval(-400),
                entities: [EntityResult(name: "Meridian Labs", type: .organization)]
            ))
        let newsBriefAboutPolice = FeedEntry.article(
            makeArticle(
                id: "dr-brief",
                title: "Police launch investigation into downtown burglary",
                description: "Officers opened an inquiry yesterday.",
                pubDate: referenceNow.addingTimeInterval(-450)
            ))
        let opinion = FeedEntry.article(
            makeArticle(
                id: "dr-op",
                title: "Opinion: Why semiconductor subsidies miss the point",
                description: "Editorial commentary on industrial policy.",
                pubDate: referenceNow.addingTimeInterval(-500)
            ))

        let plan = TodayEditionAssigner.assign(
            entries: [lead, longNoType, investigation, opinion, newsBriefAboutPolice],
            context: TodayAssignmentContext(
                now: referenceNow,
                profile: profile,
                signalsByEntryID: [
                    "l1": TodayStorySignals(nlImportanceOverride: 0.95, resolvedImportanceOverride: .major),
                    "dr-len": TodayStorySignals(nlImportanceOverride: 0.25, resolvedImportanceOverride: .minor),
                    "dr-inv": TodayStorySignals(nlImportanceOverride: 0.25, resolvedImportanceOverride: .minor),
                    "dr-op": TodayStorySignals(nlImportanceOverride: 0.25, resolvedImportanceOverride: .minor),
                    "dr-brief": TodayStorySignals(nlImportanceOverride: 0.25, resolvedImportanceOverride: .minor),
                ]
            )
        )
        let deepRead = plan.entries(for: .theDeepRead)
        assertEqual(
            Set(deepRead.map(\.id)), ["dr-len", "dr-inv", "dr-op"],
            "The Deep Read is assigned before Your Beat; breaking police-investigation briefs stay out")

        let byID = Dictionary(uniqueKeysWithValues: deepRead.map { ($0.id, $0) })
        assertEqual(
            byID["dr-len"]?.contentTypeLabel, nil,
            "Content-type label MUST be nil when qualified by reading length alone")
        assertEqual(byID["dr-inv"]?.contentTypeLabel, .investigation)
        assertEqual(byID["dr-op"]?.contentTypeLabel, .opinion)
    }

    /// #1194: over its cap The Deep Read keeps the longest stored reads, not the highest importance score,
    /// and a phrase in the feed summary alone does not classify a story without a stored long text.
    static func testTodayDeepReadOverflowKeepsDepth() {
        func body(words: Int) -> String { Array(repeating: "reporting", count: words).joined(separator: " ") }
        // Eight stored long reads, 8.5 to 12 min; the longest is the oldest, so display order differs from rank.
        var entries: [FeedEntry] = []
        var signals: [String: TodayStorySignals] = [:]
        for index in 0..<8 {
            let id = "long-\(index)"
            entries.append(
                .article(
                    makeArticle(
                        id: id,
                        title: "Harbour dredging plan, part \(index)",
                        description: index == 0 ? "What to know about the dredging plan." : "A long stored feature.",
                        pubDate: referenceNow.addingTimeInterval(TimeInterval(-600 - index * 60)),
                        fullContent: body(words: 1700 + index * 100)
                    )))
            signals[id] = TodayStorySignals(nlImportanceOverride: 0.05, resolvedImportanceOverride: .minor)
        }
        // Two stories classified by their headline with no stored body: they qualify, and score higher.
        let classifiedByHeadline = [
            ("head-op", "Opinion: The port deserves better"), ("head-ex", "Explainer: How dredging works"),
        ]
        for (id, title) in classifiedByHeadline {
            entries.append(.article(makeArticle(id: id, title: title, pubDate: referenceNow.addingTimeInterval(-100))))
            signals[id] = TodayStorySignals(nlImportanceOverride: 0.45, resolvedImportanceOverride: .minor)
        }
        // A short news report whose summary alone carries an explainer phrase: not a Deep Read candidate.
        entries.append(
            .article(
                makeArticle(
                    id: "summary-only",
                    title: "Storm closes coastal roads",
                    description: "What to know about the closures.",
                    pubDate: referenceNow.addingTimeInterval(-50)
                )))
        signals["summary-only"] = TodayStorySignals(nlImportanceOverride: 0.45, resolvedImportanceOverride: .minor)

        let plan = TodayEditionAssigner.assign(
            entries: entries,
            context: TodayAssignmentContext(now: referenceNow, signalsByEntryID: signals)
        )
        let lead = Set(plan.entries(for: .theLead).map(\.id))
        let deepRead = plan.entries(for: .theDeepRead)
        let longIDs = Set((0..<8).map { "long-\($0)" }).subtracting(lead)
        let scores = Dictionary(uniqueKeysWithValues: plan.allAssignments.map { ($0.id, $0.score) })
        assertTrue(
            (scores["head-ex"] ?? 0) > (scores["long-7"] ?? 1),
            "Premise: the headline-classified stories outscore the long reads")
        assertEqual(deepRead.count, min(8, longIDs.count + 2), "The cap stays at eight")
        assertTrue(longIDs.isSubset(of: Set(deepRead.map(\.id))), "Every stored long read keeps its place")
        assertEqual(
            deepRead.map(\.id), deepRead.sorted { $0.sortKey > $1.sortKey }.map(\.id),
            "The lane still shows newest first")
        assertFalse(deepRead.contains { $0.id == "summary-only" }, "A summary phrase alone does not qualify")
        assertEqual(
            deepRead.first { $0.id == "long-0" }?.contentTypeLabel, lead.contains("long-0") ? nil : .explainer,
            "A stored long read is still classified from its summary")
        assertEqual(
            Set(plan.allAssignments.map(\.id)), Set(entries.map(\.id)),
            "Stories the cap drops stay in the edition")
    }

    static func testTodayYourBeatProfileAndOverflowCascade() {
        // Verify coarse 12-category match alone does NOT reach Your Beat >= 0.50,
        // while entity/keyword match, starred feed, or top-quartile publisher does.
        let profile = TodayUserProfile(
            categoryWeights: ["technology": 30.0],
            entityWeights: ["organization:cern": 12.0],
            keywordWeights: ["fusion": 10.0],
            publisherWeights: ["favorite": 12.0, "occasional": 2.0, "rare": 1.0, "other": 1.0],
            interactionCount: 25
        )
        let lead = FeedEntry.article(
            makeArticle(
                id: "lead-only", title: "Crisis emergency talks begin", pubDate: referenceNow))
        let coarseTechOnly = FeedEntry.article(
            makeArticle(
                id: "coarse-tech",
                title: "Laptop maker unveils lightweight charger",
                description: "New USB adapter.",
                source: "Rare Outlet",
                feedURL: "https://rare.example/rss",
                category: "Technology",
                pubDate: referenceNow.addingTimeInterval(-100)
            ))

        var beatEntries: [FeedEntry] = [lead, coarseTechOnly]
        for idx in 1...13 {
            // 13 stories qualifying for Your Beat (> cap 12): starred feed + fine entity
            beatEntries.append(
                FeedEntry.article(
                    makeArticle(
                        id: "yb-\(idx)",
                        title: "CERN fusion experiment milestone \(idx)",
                        description: "Research team reports fusion containment gain.",
                        source: "Science Daily \(idx)",
                        feedURL: idx == 1 ? "https://starred.example/rss" : "https://sci\(idx).example/rss",
                        category: "Science",
                        pubDate: referenceNow.addingTimeInterval(-Double(idx * 60)),
                        entities: [EntityResult(name: "CERN", type: .organization)]
                    ))
            )
        }

        let plan = TodayEditionAssigner.assign(
            entries: beatEntries,
            context: TodayAssignmentContext(
                now: referenceNow,
                starredFeedURLs: ["https://starred.example/rss"],
                profile: profile,
                signalsByEntryID: [
                    "lead-only": TodayStorySignals(nlImportanceOverride: 0.90, resolvedImportanceOverride: .major)
                ]
            )
        )

        let yourBeat = plan.entries(for: .yourBeat)
        assertEqual(yourBeat.count, 12, "Your Beat is capped at 12")
        assertFalse(
            yourBeat.contains { $0.id == "coarse-tech" },
            "Coarse 12-category Technology weight alone does not clear Your Beat bar")
        // Verify newest-first chronological sort inside Your Beat:
        let dates = yourBeat.map(\.sortKey)
        assertEqual(dates, dates.sorted(by: >), "Your Beat entries are ordered newest first")
        // Verify overflow (1 of the 13 yb-* items) cascaded onward to The Latest and was NOT dropped:
        let latestIDs = Set(plan.entries(for: .theLatest).map(\.id))
        let overflowCount = (1...13).filter { latestIDs.contains("yb-\($0)") }.count
        assertEqual(overflowCount, 1, "Overflow story past Your Beat cap 12 cascades to The Latest")
        assertTrue(latestIDs.contains("coarse-tech"))
    }

    static func testTodayOutsideYourUsualAndNewLibrary() {
        let lead = FeedEntry.article(
            makeArticle(id: "lead", title: "Breaking storm emergency closes port", pubDate: referenceNow))
        let candidates = (1...4).map { i in
            FeedEntry.article(
                makeArticle(
                    id: "out-\(i)",
                    title: "Central bank governor testifies on inflation framework \(i)",
                    description: "Detailed macroeconomic briefing with named institutions.",
                    source: "Finance Press \(i)",
                    category: "Business",
                    pubDate: referenceNow.addingTimeInterval(-Double(i * 100))
                ))
        }
        let lowJunk = FeedEntry.article(
            makeArticle(
                id: "junk",
                title: "Brief notice",
                description: "",
                source: "Misc",
                category: "Lifestyle",
                pubDate: referenceNow.addingTimeInterval(-600)
            ))

        // 1. Empty library history -> Outside Your Usual stays hidden (partly-filled.jpg: Lead + Latest only)
        let emptyPlan = TodayEditionAssigner.assign(
            entries: [lead] + candidates + [lowJunk],
            context: TodayAssignmentContext(now: referenceNow, profile: .empty)
        )
        assertFalse(
            emptyPlan.result(for: .outsideYourUsual)?.qualifies == true,
            "New library with no history hides Outside Your Usual")

        // 2. Populated tech history -> Business macro stories have high novelty + editorial score >= 0.35
        let techProfile = TodayUserProfile(
            categoryWeights: ["technology": 15.0],
            entityWeights: ["organization:chipmaker": 10.0],
            keywordWeights: ["silicon": 8.0],
            publisherWeights: ["tech daily": 12.0],
            interactionCount: 15
        )
        let dealsSpam = FeedEntry.article(
            makeArticle(
                id: "deals",
                title: "Deals: Early Black Friday doorbusters on AirTag and Apple Watch",
                description: "Save up to 30 percent on popular tech accessories.",
                source: "Tech Deals Blog",
                category: "Business",
                pubDate: referenceNow.addingTimeInterval(-650)
            ))
        var signals: [String: TodayStorySignals] = [
            "lead": TodayStorySignals(nlImportanceOverride: 0.90, resolvedImportanceOverride: .major),
            "junk": TodayStorySignals(nlImportanceOverride: 0.15, resolvedImportanceOverride: .minor),
        ]
        for i in 1...4 {
            signals["out-\(i)"] = TodayStorySignals(
                originalReportCount: 2, nlImportanceOverride: 0.65, resolvedImportanceOverride: .notable)
        }
        let populatedPlan = TodayEditionAssigner.assign(
            entries: [lead] + candidates + [lowJunk, dealsSpam],
            context: TodayAssignmentContext(now: referenceNow, profile: techProfile, signalsByEntryID: signals)
        )
        let outsideIDs = Set(populatedPlan.entries(for: .outsideYourUsual).map(\.id))
        assertEqual(outsideIDs, ["out-1", "out-2", "out-3", "out-4"])
        assertFalse(outsideIDs.contains("junk"), "Novelty alone without score >= 0.35 falls through to The Latest")
        assertFalse(outsideIDs.contains("deals"), "Shopping-deals promos stay out of Outside Your Usual")
        assertTrue(populatedPlan.entries(for: .theLatest).contains { $0.id == "deals" })
        assertTrue(populatedPlan.entries(for: .theLatest).contains { $0.id == "junk" })
    }

    static func testTodayUnderflowHidesAndCascades() {
        let profile = TodayUserProfile(
            entityWeights: ["organization:cern": 12.0],
            interactionCount: 10
        )
        let lead = FeedEntry.article(makeArticle(id: "l", title: "Crisis emergency", pubDate: referenceNow))
        // Only 2 Deep Read candidates (< min 3): both also qualify for Your Beat -> lane hides,
        // so both cascade down into Your Beat!
        let dr1 = FeedEntry.article(
            makeArticle(
                id: "dr1", title: "Investigation: CERN collider upgrade",
                pubDate: referenceNow.addingTimeInterval(-100),
                entities: [EntityResult(name: "CERN", type: .organization)]))
        let dr2 = FeedEntry.article(
            makeArticle(
                id: "dr2", title: "Explainer: CERN magnet design",
                pubDate: referenceNow.addingTimeInterval(-200),
                entities: [EntityResult(name: "CERN", type: .organization)]))
        let yb3 = FeedEntry.article(
            makeArticle(
                id: "yb3", title: "CERN releases quarterly budget",
                pubDate: referenceNow.addingTimeInterval(-300),
                entities: [EntityResult(name: "CERN", type: .organization)]))

        let plan = TodayEditionAssigner.assign(
            entries: [lead, dr1, dr2, yb3],
            context: TodayAssignmentContext(
                now: referenceNow,
                profile: profile,
                signalsByEntryID: [
                    "l": TodayStorySignals(nlImportanceOverride: 0.90, resolvedImportanceOverride: .major),
                    "dr1": TodayStorySignals(nlImportanceOverride: 0.25, resolvedImportanceOverride: .minor),
                    "dr2": TodayStorySignals(nlImportanceOverride: 0.25, resolvedImportanceOverride: .minor),
                    "yb3": TodayStorySignals(nlImportanceOverride: 0.25, resolvedImportanceOverride: .minor),
                ]
            )
        )
        assertFalse(plan.result(for: .theDeepRead)?.qualifies == true, "2 < 3 hides The Deep Read")
        assertEqual(
            Set(plan.entries(for: .yourBeat).map(\.id)), ["dr1", "dr2", "yb3"],
            "Hidden lane stories cascade cleanly to the next qualifying lane")
    }

    static func testTodaySubscriptionPoolAndSafetyNet() {
        let subscribedFeed = "https://sub.example/rss"
        let unsubscribedFeed = "https://other.example/rss"
        let subStory = FeedEntry.article(
            makeArticle(id: "sub-1", title: "Subscribed report", feedURL: subscribedFeed, pubDate: referenceNow))
        let unsubStory = FeedEntry.article(
            makeArticle(
                id: "unsub-1", title: "Unsubscribed panel story", feedURL: unsubscribedFeed, pubDate: referenceNow))
        let multiEvent = makeEventEntry(
            eventID: "ev-1",
            members: [
                (
                    "e1", "Sub Press", "Subscribed event headline", "Body", referenceNow.addingTimeInterval(-60),
                    subscribedFeed
                ),
                (
                    "e2", "Other Press", "Followup headline", "Body", referenceNow.addingTimeInterval(-120),
                    subscribedFeed
                ),
            ]
        )

        let plan = TodayEditionAssigner.assign(
            entries: [subStory, unsubStory, multiEvent, multiEvent],  // intentional duplicate event input
            context: TodayAssignmentContext(now: referenceNow, subscribedFeedURLs: [subscribedFeed])
        )
        let allIDs = plan.allAssignments.map(\.id)
        assertFalse(allIDs.contains("unsub-1"), "Non-subscribed feed story cannot enter Today")
        assertEqual(Set(allIDs), ["sub-1", "e1"], "Every subscribed story is placed")
        assertEqual(allIDs.count, Set(allIDs).count, "Zero duplicate stories across all lanes")
    }

    static func testTodayCoverageGateAndDevelopingPill() {
        let recentDate = referenceNow.addingTimeInterval(-1200)  // 20 min ago (Developing!)
        let confident = makeEventEntry(
            eventID: "ev-cov-pass",
            members: [
                ("c1", "Outlet 1", "Bridge collapses during storm", "Detail", recentDate, "https://o1.example/rss"),
                (
                    "c2", "Outlet 2", "Emergency teams reach collapsed bridge", "Detail", recentDate,
                    "https://o2.example/rss"
                ),
                (
                    "c3", "Outlet 3", "Traffic diverted after bridge collapse", "Detail", recentDate,
                    "https://o3.example/rss"
                ),
            ]
        )
        let weakGrouping = makeEventEntry(
            eventID: "ev-cov-weak",
            members: [
                (
                    "w1", "Outlet 1", "Story X", "Detail", referenceNow.addingTimeInterval(-7200),
                    "https://o1.example/rss"
                ),
                (
                    "w2", "Outlet 2", "Story Y", "Detail", referenceNow.addingTimeInterval(-7200),
                    "https://o2.example/rss"
                ),
                (
                    "w3", "Outlet 3", "Story Z", "Detail", referenceNow.addingTimeInterval(-7200),
                    "https://o3.example/rss"
                ),
            ]
        )
        let plan = TodayEditionAssigner.assign(
            entries: [confident, weakGrouping],
            context: TodayAssignmentContext(
                now: referenceNow,
                signalsByEntryID: [
                    "c1": TodayStorySignals(originalReportCount: 3, groupingConfidence: 0.85),
                    "w1": TodayStorySignals(originalReportCount: 2, groupingConfidence: 0.55),
                ]
            )
        )
        let byID = Dictionary(uniqueKeysWithValues: plan.allAssignments.map { ($0.id, $0) })
        assertTrue(byID["c1"]?.isCoverageConfident == true, ">= 3 pubs, >= 2 originals, >= 0.70 grouping passes gate")
        assertTrue(byID["c1"]?.isDeveloping == true, "Confirmed event updated within 1 h carries Developing flag")
        assertFalse(byID["w1"]?.isCoverageConfident == true, "Grouping confidence < 0.70 fails Coverage card gate")
        assertFalse(byID["w1"]?.isDeveloping == true, "Event older than 1 h is not Developing")
    }

    /// Z7 (#1174): every card field comes from the assignment or the event, and a field without data stays nil.
    static func testTodayCardMetadata() {
        let day = 86_400.0
        let event = makeEventEntry(
            eventID: "ev-meta",
            members: [
                (
                    "m1", "Outlet 1", "Port closes", "Detail", referenceNow.addingTimeInterval(-2 * day),
                    "https://o1.example/rss"
                ),
                (
                    "m2", "Outlet 2", "Port stays closed", "Detail", referenceNow.addingTimeInterval(-day),
                    "https://o2.example/rss"
                ),
                (
                    "m3", "Outlet 3", "Port reopens", "Detail", referenceNow.addingTimeInterval(-600),
                    "https://o3.example/rss"
                ),
            ],
            seenVersion: 1
        )
        let longRead = makeArticle(
            id: "long", title: "Inside how the port was rebuilt", pubDate: referenceNow.addingTimeInterval(-3600),
            fullContent: Array(repeating: "word", count: 2100).joined(separator: " "))
        let teaser = makeArticle(id: "teaser", title: "A short note", pubDate: referenceNow.addingTimeInterval(-3600))
        let plan = TodayEditionAssigner.assign(
            entries: [event, .article(longRead), .article(teaser)],
            context: TodayAssignmentContext(
                now: referenceNow,
                signalsByEntryID: ["m1": TodayStorySignals(originalReportCount: 2, groupingConfidence: 0.9)]))
        let byID = Dictionary(uniqueKeysWithValues: plan.allAssignments.map { ($0.id, $0) })
        guard let eventAssignment = byID["m1"], let long = byID["long"], let short = byID["teaser"] else {
            assertTrue(false, "Every entry is assigned")
            return
        }
        let utc = Calendar(identifier: .gregorian)
        let meta = StoryCardMetadata(eventAssignment, differingAccount: "A: one. B: two.", calendar: utc)
        assertEqual(meta.publisherCount, 3, "Publishers come from the event's distinct sources")
        assertEqual(meta.originalReports, 2, "Original reports come from the assignment")
        assertEqual(meta.newReportCount, 2, "Reports that joined after the seen version are new")
        assertEqual(meta.reportDays, 3, "One progress mark per report day")
        assertEqual(meta.updatedAt, referenceNow.addingTimeInterval(-600), "The pill carries the latest report's time")
        assertEqual(meta.publishers, ["Outlet 1", "Outlet 2", "Outlet 3"], "Monograms follow coverage order")
        assertEqual(meta.differingAccount, "A: one. B: two.", "The stored account is passed through")

        assertEqual(StoryCardMetadata(long).readingMinutes, 11, "2,100 stored words read in 11 minutes")
        let bare = StoryCardMetadata(short)
        assertTrue(bare.readingMinutes == nil, "A feed summary's length is not a reading time")
        assertTrue(
            bare.publisherCount == nil && bare.updatedAt == nil && bare.publishers.isEmpty, "No event, no coverage")
        assertTrue(bare.contentType == nil, "No classification, no content-type tag")

        if case .event(let summary, _, _) = event {
            assertTrue(summary.isDeveloping(now: referenceNow), "A report ten minutes ago makes the event developing")
            assertFalse(summary.isDeveloping(now: referenceNow.addingTimeInterval(7200)), "Two hours later it is not")
            assertFalse(
                summary.isDeveloping(now: referenceNow.addingTimeInterval(-4000)), "A report dated ahead does not count"
            )
        }
        let never = makeEventEntry(
            eventID: "ev-new",
            members: [
                ("n1", "Outlet 1", "A", "Detail", referenceNow, "https://o1.example/rss"),
                ("n2", "Outlet 2", "B", "Detail", referenceNow, "https://o2.example/rss"),
            ])
        if case .event(let summary, _, _) = never {
            assertTrue(summary.newReportCount == nil, "An event never opened is new, not updated")
        }

        let verge = OverviewPerspective(
            participant: "Consortium", position: "the standard is voluntary", sourcePublisher: "The Verge")
        let vergeAgain = OverviewPerspective(
            participant: "Vendors", position: "adoption will be slow.", sourcePublisher: "the verge")
        let ars = OverviewPerspective(
            participant: "Regulator", position: "the consortium can enforce it.", sourcePublisher: "Ars Technica")
        let unattributed = OverviewPerspective(participant: "Analysts", position: "it changes little")
        assertEqual(
            StoryCardMetadata.differingAccount(in: [verge, vergeAgain, unattributed, ars]),
            "The Verge: the standard is voluntary. Ars Technica: the consortium can enforce it.",
            "Two publishers' positions, each attributed, in the overview's order")
        assertTrue(
            StoryCardMetadata.differingAccount(in: [verge, vergeAgain, unattributed]) == nil,
            "One publisher's account is not a difference")
    }

    private static func focusMap(latest: [String] = ["l1", "l2", "l3", "l4", "l5"], columns: Int = 2) -> TodayFocusMap {
        TodayFocusMap(lanes: [
            .init(lane: .theLead, ids: ["a", "b", "c"]),
            .init(lane: .inMotion, ids: ["m1", "m2", "m3"]),
            .init(lane: .yourBeat, ids: []),
            .init(lane: .theDeepRead, ids: ["d1", "d2", "d3"]),
            .init(lane: .theLatest, ids: latest, columns: columns),
        ])
    }

    /// Z4 (#936): arrows inside and between lanes, J and K in reading order.
    static func testTodayFocusMap() {
        let map = focusMap()
        assertEqual(map.lanes.map(\.lane), [.theLead, .inMotion, .theDeepRead, .theLatest], "An empty lane is absent")
        assertEqual(map.move(.down, from: nil), "a", "Without focus, the first card takes it")
        assertEqual(map.move(.right, from: "c"), "a", "The Lead is a loop")
        assertEqual(map.move(.left, from: "a"), "c", "The Lead loops backwards too")
        assertEqual(map.move(.right, from: "m3"), "m3", "A row stops at its last card")
        assertEqual(map.move(.left, from: "m1"), "m1", "A row stops at its first card")
        assertEqual(map.move(.down, from: "b"), "m1", "Down from The Lead enters the first lane below")
        assertEqual(
            map.move(.down, from: "m2", memory: [.theDeepRead: "d3"]), "d3", "A lane gives focus to its remembered card"
        )
        assertEqual(
            map.move(.down, from: "m2", memory: [.theDeepRead: "gone"]), "d1",
            "A remembered card that left falls back to the first")
        assertEqual(map.move(.up, from: "a"), "a", "Nothing is above The Lead")
        assertEqual(map.move(.down, from: "d2"), "l1", "Down from the last row lane enters the grid")
        assertEqual(map.move(.right, from: "l2"), "l3", "Right in the grid wraps to the next row")
        assertEqual(map.move(.down, from: "l1"), "l3", "Down in the grid moves one row")
        assertEqual(map.move(.down, from: "l4"), "l5", "Down onto a shorter last row lands on its last card")
        assertEqual(map.move(.down, from: "l5"), "l5", "The last row is the end")
        assertEqual(map.move(.up, from: "l4"), "l2", "Up in the grid moves one row")
        assertEqual(
            map.move(.up, from: "l2", memory: [.theDeepRead: "d2"]), "d2", "Up from the first row enters the lane above"
        )
        assertEqual(map.step(1, from: "c"), "m1", "J leaves the slides for the next lane")
        assertEqual(map.step(-1, from: "l1"), "d3", "K leaves the grid for the lane above")
        assertEqual(map.step(1, from: "l5"), "l5", "J stops at the last story")
        assertEqual(map.step(1, from: nil), "a", "J without focus starts at the first story")
        assertEqual(focusMap(columns: 1).move(.down, from: "l1"), "l2", "The list layout is a grid of one column")
    }

    /// Z4 (#936): where focus lands when the reader applies an update.
    static func testTodayFocusRestore() {
        let old = focusMap()
        func restored(_ id: String, _ lanes: [TodayFocusMap.Lane]) -> String? {
            TodayFocusMap(lanes: lanes).restoredFocus(id, from: old)
        }
        let latest = TodayFocusMap.Lane(lane: .theLatest, ids: ["l1", "l2"], columns: 2)
        let lead = TodayFocusMap.Lane(lane: .theLead, ids: ["a"])
        assertEqual(
            restored("m2", [lead, .init(lane: .theDeepRead, ids: ["m2", "d1"]), latest]), "m2",
            "A card still in the edition keeps focus, also in another lane")
        assertEqual(
            restored("m2", [lead, .init(lane: .inMotion, ids: ["m1", "x", "m3"]), latest]), "x",
            "A card gone from its lane passes focus to the card at its index")
        assertEqual(
            restored("m3", [lead, .init(lane: .inMotion, ids: ["m1"]), latest]), "m1",
            "Past the end, the lane's last card takes focus")
        assertEqual(
            restored("m2", [lead, .init(lane: .theDeepRead, ids: ["d1"]), latest]), "d1",
            "A lane gone passes focus to the first card of the next lane below")
        assertEqual(
            restored("l3", [lead, .init(lane: .inMotion, ids: ["m1", "m2"])]), "m2",
            "With no lane below, the last card of the nearest lane above takes focus")
        assertTrue(restored("m1", []) == nil, "With no card left, nothing holds focus")
        assertTrue(
            TodayFocusMap(lanes: [lead]).restoredFocus(nil, from: old) == nil, "A lane appearing never takes focus")
    }

    /// Z4 (#936): nothing changes lane until the reader applies an update; Today never hides a listed story.
    static func testTodayEditionPinsLanes() {
        func story(_ id: String, _ lane: TodayLane) -> TodayStoryAssignment {
            TodayStoryAssignment.unplaced(.article(makeArticle(id: id, title: id, pubDate: referenceNow))).placed(
                in: lane)
        }
        func plan(_ lanes: [(TodayLane, [String])]) -> TodayEditionPlan {
            TodayEditionPlan(
                lanes: lanes.map { lane, ids in
                    TodayLaneResult(lane: lane, qualifies: true, entries: ids.map { story($0, lane) })
                })
        }
        func entries(_ ids: [String]) -> [FeedEntry] {
            ids.map { .article(makeArticle(id: $0, title: $0, pubDate: referenceNow)) }
        }
        func shape(_ edition: TodayEdition) -> [String] {
            edition.lanes.map { "\($0.lane.rawValue): \($0.stories.map(\.id).joined(separator: ","))" }
        }
        let first = TodayEdition.make(
            entries: entries(["a", "b", "c", "d", "e", "stray"]),
            plan: plan([(.theLead, ["a"]), (.inMotion, ["b", "c", "d"]), (.yourBeat, []), (.theLatest, ["e"])]))
        assertEqual(
            shape(first), ["The Lead: a", "In Motion: b,c,d", "The Latest: e,stray"],
            "Lanes follow the plan in page order; an empty lane is absent; a listed story the plan left out is in The Latest"
        )
        assertEqual(first.metadata["b"]?.laneName, "In Motion", "A card knows its lane for VoiceOver")

        // A later page and a refreshed plan that would move every story: the edition on screen keeps its lanes.
        let moved = plan([(.theLead, ["f"]), (.inMotion, []), (.theLatest, ["a", "b", "d", "e", "g"])])
        let held = TodayEdition.make(
            entries: entries(["a", "b", "d", "e", "stray", "f", "g"]), plan: moved, keeping: first)
        assertEqual(
            shape(held), ["The Lead: a", "In Motion: b,d", "The Latest: e,stray,f,g"],
            "Stories stay in their lanes, a story that left the list leaves its lane, new stories join The Latest")
        let tagged = TodayStoryAssignment.unplaced(.article(makeArticle(id: "t", title: "t", pubDate: referenceNow)))
        assertTrue(
            tagged.placed(in: .theDeepRead, contentType: .explainer).contentTypeLabel == .explainer
                && tagged.placed(in: .yourBeat, contentType: .explainer).contentTypeLabel == nil,
            "A story held in The Deep Read keeps its content-type tag, and no other lane shows one")
        let applied = TodayEdition.make(entries: entries(["a", "b", "d", "e", "stray", "f", "g"]), plan: moved)
        assertEqual(
            shape(applied), ["The Lead: f", "The Latest: a,b,d,e,g,stray"],
            "An applied update lays the edition out afresh")
        assertEqual(
            first.focusMap(latestColumns: 3).lanes.last?.columns, 3, "The Latest's grid columns reach the keyboard map")
    }

    /// A held edition keeps each card's tag, shows current entries, and a new edition's Latest stays newest first.
    static func testTodayHeldEditionDetails() {
        func entry(_ id: String, title: String? = nil, age: TimeInterval = 0) -> FeedEntry {
            .article(makeArticle(id: id, title: title ?? id, pubDate: referenceNow.addingTimeInterval(-age)))
        }
        func deepRead(_ entries: [FeedEntry], _ label: TodayContentType?) -> TodayEditionPlan {
            let stories = entries.map {
                TodayStoryAssignment.unplaced($0).held(in: .theDeepRead, contentType: label)
            }
            return TodayEditionPlan(lanes: [TodayLaneResult(lane: .theDeepRead, qualifies: true, entries: stories)])
        }
        let first = TodayEdition.make(entries: [entry("x")], plan: deepRead([entry("x")], .explainer))
        let retagged = TodayEdition.make(
            entries: [entry("x")], plan: deepRead([entry("x")], .opinion), keeping: first)
        assertTrue(
            retagged.stories(in: .theDeepRead).first?.contentTypeLabel == .explainer,
            "A held card keeps its tag when the fresh plan tags it differently")
        let untagged = TodayEdition.make(entries: [entry("x")], plan: deepRead([entry("x")], nil))
        let tagged = TodayEdition.make(
            entries: [entry("x")], plan: deepRead([entry("x")], .opinion), keeping: untagged)
        assertTrue(
            tagged.stories(in: .theDeepRead).first?.contentTypeLabel == nil,
            "A held card with no tag stays untagged when the fresh plan tags it")
        let renamed = TodayEdition.make(
            entries: [entry("x", title: "New title")], plan: TodayEditionPlan(lanes: []), keeping: first)
        assertEqual(
            renamed.stories(in: .theDeepRead).first?.entry.representative.title, "New title",
            "A held story the plan no longer places shows its current entry")
        let fresh = TodayEdition.make(
            entries: [entry("old", age: 3600), entry("new", age: 60)], plan: TodayEditionPlan(lanes: []))
        assertEqual(
            fresh.latest.map(\.id), ["new", "old"], "A new edition's Latest is newest first, also with unplaced stories"
        )
    }

    static func testTodayNotificationThresholdsIndependent() {
        // A story can score highly enough to be a Lead candidate without passing NotificationService.isPriority,
        // and changing NotificationService static thresholds is not referenced by TodayEditionThresholds.
        assertEqual(NotificationService.priorityPublishers, 4)
        assertEqual(NotificationService.breakingScore, 0.6)
        let twoSourceNoAlertSignal = makeEventEntry(
            eventID: "ev-no-alert",
            members: [
                (
                    "na1", "Paper One", "Central bank revises long-term inflation target", "Policy change.",
                    referenceNow, "https://p1.example/rss"
                ),
                (
                    "na2", "Paper Two", "Economists weigh revised central bank target", "Policy response.",
                    referenceNow.addingTimeInterval(-120), "https://p2.example/rss"
                ),
            ]
        )
        let plan = TodayEditionAssigner.assign(
            entries: [twoSourceNoAlertSignal],
            context: TodayAssignmentContext(now: referenceNow)
        )
        assertEqual(plan.entries(for: .theLead).map(\.id), ["na1"])
        assertFalse(
            NotificationService.isPriority(
                title: "Central bank revises long-term inflation target", score: 0.7, publishers: 2),
            "Notification priority does not trigger while story still leads Today"
        )
    }

    static func testTodayDeterminismAndDatabaseLoader() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        defer { Task { await db.close() } }

        let now = Date()
        let subURL = "https://global.example/rss"
        // A removed subscription keeps its fetch-state row and its stories; neither makes it a subscription.
        let removedURL = "https://removed.example/rss"
        for (id, url) in [("feed-1", subURL), ("feed-2", removedURL)] {
            try await db.eventRows(
                "INSERT OR IGNORE INTO feeds (id, url, created_at) VALUES (?, ?, ?);",
                [.text(id), .text(url), .real(now.timeIntervalSince1970)]
            )
        }

        let read1 = makeArticle(
            id: "hist-1", title: "CERN collider upgrade passes safety review",
            source: "Science Journal", feedURL: subURL, category: "Science",
            pubDate: now.addingTimeInterval(-86400))
        let candidate1 = makeArticle(
            id: "cand-1", title: "CERN schedules next collider beam test",
            source: "Science Journal", feedURL: subURL, category: "Science",
            pubDate: now.addingTimeInterval(-600))
        let removed1 = makeArticle(
            id: "removed-1", title: "Harbor authority reviews ferry timetable",
            source: "Removed Gazette", feedURL: removedURL, pubDate: now.addingTimeInterval(-900))
        try await db.upsertArticles([read1, candidate1, removed1])
        try await db.markRead(articleId: "hist-1", isRead: true)

        // Index entity cleanly for both stories so finer entity profile populates.
        let gen = await db.analysisGeneration
        _ = try await db.saveEntityIndex(
            [
                (
                    EntityIndexCandidate(
                        articleID: "hist-1", title: read1.title, description: read1.description, text: "",
                        publisher: read1.source, publishedAt: read1.pubDate, revision: 0),
                    [IndexedEntity(name: "CERN", type: .organization, score: 4)]
                ),
                (
                    EntityIndexCandidate(
                        articleID: "cand-1", title: candidate1.title, description: candidate1.description, text: "",
                        publisher: candidate1.source, publishedAt: candidate1.pubDate, revision: 0),
                    [IndexedEntity(name: "CERN", type: .organization, score: 4)]
                ),
            ], expectedGeneration: gen)

        let entries: [FeedEntry] = [.article(candidate1), .article(removed1)]
        let ctx1 = try await db.loadTodayAssignmentContext(entries: entries, now: now, subscribedFeedURLs: [subURL])
        let ctx2 = try await db.loadTodayAssignmentContext(entries: entries, now: now, subscribedFeedURLs: [subURL])
        let plan1 = TodayEditionAssigner.assign(entries: entries, context: ctx1)
        let plan2 = TodayEditionAssigner.assign(entries: entries, context: ctx2)
        assertEqual(plan1, plan2, "Repeated database loads and assignments are strictly deterministic")
        assertTrue(ctx1.profile.hasHistory, "Database loader builds a profile from the read story")
        assertTrue(
            (ctx1.profile.entityWeights["organization:cern"] ?? 0) > 0,
            "Database loader populates fine entity profile from stored entity_mentions")
        assertEqual(
            plan1.allAssignments.map(\.id), ["cand-1"],
            "A removed feed's story stays out of Today although the feed keeps its fetch-state row")
        let unsubscribed = try await db.loadTodayAssignmentContext(entries: entries, now: now, subscribedFeedURLs: [])
        assertTrue(
            TodayEditionAssigner.assign(entries: entries, context: unsubscribed).allAssignments.isEmpty,
            "An empty subscription list admits no story")
    }

    static func testTodayLoaderGroupingConfidenceCoversStory() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        defer { Task { await db.close() } }

        // One story of two events (`ev-a` names it) and a second story, `ev-x`.
        let now = Date()
        let stamp = now.timeIntervalSince1970
        let memberEvents = [("a1", "ev-a"), ("a2", "ev-a"), ("b1", "ev-b"), ("b2", "ev-b"), ("x1", "ev-x")]
        try await db.upsertArticles(
            memberEvents.map { makeArticle(id: $0.0, title: "Port strike report \($0.0)", pubDate: now) })
        for (event, story) in [("ev-a", "ev-a"), ("ev-b", "ev-a"), ("ev-x", "ev-x")] {
            try await db.eventRows(
                "INSERT INTO events (id, created_at, updated_at, story_id) VALUES (?, ?, ?, ?);",
                [.text(event), .real(stamp), .real(stamp), .text(story)])
        }
        for (article, event) in memberEvents {
            try await db.eventRows(
                "INSERT INTO event_members (article_id, event_id, joined_version) VALUES (?, ?, 1);",
                [.text(article), .text(event)])
        }
        let pairs: [(String, String, String, Double)] = [
            ("a1", "a2", "match", 0.9), ("b1", "b2", "match", 0.5), ("a1", "b1", "related-act", 0.7),
            ("a2", "b2", "vetoed", 0.1), ("a1", "x1", "match", 1.0),
        ]
        try await db.upsertPairDecisions(
            pairs.map {
                DatabaseEngine.PairDecision(
                    articleID: $0.0, otherArticleID: $0.1, decision: $0.2, reason: "test", score: $0.3)
            }, matcherVersion: 1)

        func entry(_ eventID: String, _ members: [String]) -> FeedEntry {
            makeEventEntry(
                eventID: eventID,
                members: members.map { ($0, "Outlet \($0)", "Port strike report \($0)", "Detail", now, "") })
        }
        let signals = try await db.todayStorySignals(
            for: [entry("ev-a", ["a1", "a2"]), entry("ev-b", ["b1", "b2"]), entry("ev-x", ["x1"])])
        // (0.9 + 0.5 + 0.7) / 3: the vetoed pair and the pair that leaves the story do not count.
        for id in ["a1", "b1"] {
            assertTrue(
                abs((signals[id]?.groupingConfidence ?? -1) - 0.7) < 1e-9,
                "Grouping confidence of \(id) is the mean of the whole story's matched pairs")
        }
        assertEqual(
            signals["x1"]?.groupingConfidence, nil, "A story without a matched pair of its own has no stored confidence"
        )
    }

    static func testTodayLoaderSectorImpactNeedsStoredSection() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        defer { Task { await db.close() } }

        // Both stored formats: a bare fact array, and the envelope an overview with evidence sections is saved in.
        let quoting = [OverviewFact(id: "f1", text: "Analysts dispute the industryImpact label.", citationIDs: [])]
        let sections: [String: OverviewEvidenceSections?] = [
            "ev-quote": nil,
            "ev-timeline": OverviewEvidenceSections(
                timeline: [OverviewTimelineItem(dateText: "Monday", summary: "Talks opened.")]),
            "ev-impact": OverviewEvidenceSections(
                industryImpact: [OverviewIndustryImpact(industry: "Energy", implication: "Costs rose.")]),
        ]
        for (eventID, evidence) in sections {
            let stored = try await db.recordEventOverview(
                EventOverviewDocument(
                    eventID: eventID,
                    version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "input"),
                    content: OverviewContent(title: "Story", summary: "", facts: quoting, evidenceSections: evidence),
                    provenance: OverviewProvenance(memberArticleIDs: [], kind: .synthesized)))
            assertTrue(stored, "The overview of \(eventID) is stored")
        }

        let now = Date()
        let signals = try await db.todayStorySignals(
            for: sections.keys.sorted().map { eventID in
                makeEventEntry(
                    eventID: eventID,
                    members: [("m-\(eventID)", "Outlet", "Tariff ruling \(eventID)", "Detail", now, "")])
            })
        assertEqual(
            signals["m-ev-quote"]?.hasSectorImpact, false, "A fact that quotes the word is not a sector impact")
        assertEqual(
            signals["m-ev-timeline"]?.hasSectorImpact, false,
            "Evidence sections without an Industry Impact item are not a sector impact")
        assertEqual(signals["m-ev-impact"]?.hasSectorImpact, true, "A stored Industry Impact item is a sector impact")
    }
}
