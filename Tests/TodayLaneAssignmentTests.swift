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
            ("testInMotionUpdateWindowKeepsUnderwayApart", { testTodayInMotionUpdateWindow() }),
            ("testInMotionWithoutRisingNeverFillsWithRepetition", { testTodayInMotionWithoutRising() }),
            ("testYourBeatAffinityAsBoosterOnly", { testTodayYourBeatAffinityBooster() }),
            ("testDeepReadAssignedBeforeYourBeatAndLabelContract", { testTodayDeepReadOrderAndLabelContract() }),
            ("testDeepReadOverflowKeepsDepthAndSummaryPhraseAlone", { testTodayDeepReadOverflowKeepsDepth() }),
            ("testYourBeatFinerProfileAndOverflowCascade", { testTodayYourBeatProfileAndOverflowCascade() }),
            ("testOutsideYourUsualAndNewLibraryEmptyHistory", { testTodayOutsideYourUsualAndNewLibrary() }),
            ("testConditionalUnderflowHidesLaneAndCascades", { testTodayUnderflowHidesAndCascades() }),
            ("testSubscriptionPoolAndZeroDuplicatesAndLatestSafetyNet", { testTodaySubscriptionPoolAndSafetyNet() }),
            ("testCoverageGateAndDevelopingPill", { testTodayCoverageGateAndDevelopingPill() }),
            ("testCardMetadataHasRealSourcesOrIsHidden", { testTodayCardMetadata() }),
            ("testCardMetadataIsBuiltWithTheLayout", { await testTodayCardDetailsOffMainActor() }),
            ("testFocusMovesWithinAndBetweenLanes", { testTodayFocusMap() }),
            ("testFocusIsRestoredWhenTheEditionChanges", { testTodayFocusRestore() }),
            ("testEditionKeepsLanesUntilAnUpdateIsApplied", { testTodayEditionPinsLanes() }),
            ("testHeldEditionKeepsTagsEntriesAndNewEditionSortsLatest", { testTodayHeldEditionDetails() }),
            ("testStoredEditionRestoresValidatesAndFallsBack", { try await testTodayStoredEdition() }),
            ("testConcurrentEvaluationMatchesSerial", { testTodayConcurrentEvaluationMatchesSerial() }),
            ("testLeadNeedsAPhotoAndLeftFeedsLeaveToday", { testTodayLeadPhotoAndLeftFeeds() }),
            ("testNotificationThresholdsRemainIndependent", { testTodayNotificationThresholdsIndependent() }),
            ("testDeterminismAndDatabaseLoaderIntegration", { try await testTodayDeterminismAndDatabaseLoader() }),
            ("testLoaderGroupingConfidenceCoversStory", { try await testTodayLoaderGroupingConfidenceCoversStory() }),
            ("testLoaderSectorImpactNeedsStoredSection", { try await testTodayLoaderSectorImpactNeedsStoredSection() }),
            ("testFullEditionIsDeterministicPerLaneWithOneLanePerStory", { testTodayFullEditionContract() }),
            ("testOutputHoldsNoTopicLaneAndNoBriefingAnalysis", { testTodayOutputHasNoTopicLaneOrAnalysis() }),
            ("testNotifyingStoryNeedNotLeadToday", { testTodayNotifyingStoryNeedNotLead() }),
            ("testYourBeatPerStoryAffinityIsOffByDefault", { try await testTodayYourBeatPerStoryAffinity() }),
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

    /// An event of two or more reports, newest first, each `hoursAgo` before the reference clock.
    private static func inMotionEvent(
        _ id: String, reports: [(hoursAgo: Double, title: String)]
    ) -> FeedEntry {
        makeEventEntry(
            eventID: "im-\(id)",
            members: reports.enumerated().map { index, report in
                (
                    "\(id)-\(index)", "Outlet \(id) \(index)", report.title, "Report.",
                    referenceNow.addingTimeInterval(-report.hoursAgo * 3600), "https://\(id)\(index).example/rss"
                )
            })
    }

    private static let inquiryHeadline = "Regulators open preliminary inquiry into proposed rail merger"
    private static let rulingHeadline = "Court blocks merger and orders divestiture of regional assets"

    /// The evaluation variant of #934: "is the story underway" stays at 24 h whatever the update window is.
    static func testTodayInMotionUpdateWindow() {
        func summary(_ entry: FeedEntry) -> EventFeedSummary {
            guard case .event(let summary, _, _) = entry else { fatalError("An event entry") }
            return summary
        }
        func variant(_ entry: FeedEntry, updateHours: Double) -> Bool {
            TodayEditionAssigner.hasSubstantiveInMotionUpdate(
                summary(entry), now: referenceNow, underway: 24 * 3600, updateWindow: updateHours * 3600)
        }
        func shipped(_ entry: FeedEntry, windowHours: Double = 24) -> Bool {
            TodayEditionAssigner.hasSubstantiveInMotionUpdate(
                summary(entry), now: referenceNow, window: windowHours * 3600)
        }

        // An initial report 30 hours ago with an update 2 hours ago.
        let freshUpdate = inMotionEvent("fresh", reports: [(2, rulingHeadline), (30, inquiryHeadline)])
        assertTrue(shipped(freshUpdate), "The shipped rule takes an update 2 h old on a story 30 h old")
        assertTrue(variant(freshUpdate, updateHours: 24), "So does the 24 h update window")
        assertTrue(variant(freshUpdate, updateHours: 36), "So does the 36 h update window")
        assertFalse(
            shipped(freshUpdate, windowHours: 36),
            "Moving the shipped cutoff to 36 h also moves the earlier reports inside it: the story reads as new")

        // An older story whose latest meaningful update is 25 to 36 hours old.
        for updateAge in [25.0, 30.0, 36.0] {
            let olderUpdate = inMotionEvent("older", reports: [(updateAge, rulingHeadline), (60, inquiryHeadline)])
            assertFalse(shipped(olderUpdate), "The shipped rule has no report inside 24 h (update \(updateAge) h old)")
            assertFalse(variant(olderUpdate, updateHours: 24), "Nor has the 24 h update window (\(updateAge) h)")
            assertTrue(variant(olderUpdate, updateHours: 36), "The 36 h update window takes it (\(updateAge) h)")
        }
        let staleUpdate = inMotionEvent("stale", reports: [(37, rulingHeadline), (60, inquiryHeadline)])
        assertFalse(variant(staleUpdate, updateHours: 36), "An update 37 h old is outside the 36 h window")

        // A story whose reports all fall in the last 24 hours is new, not ongoing, whatever the update window.
        let newStory = inMotionEvent("new", reports: [(2, rulingHeadline), (20, inquiryHeadline)])
        assertFalse(shipped(newStory), "The shipped rule calls a story inside 24 h new")
        assertFalse(variant(newStory, updateHours: 24), "The 24 h update window calls a story inside 24 h new")
        assertFalse(variant(newStory, updateHours: 36), "The 36 h update window calls a story inside 24 h new")

        // The update is compared against the reports that came before it. A first report has none; a report that
        // repeats an earlier one is no update, also when that earlier report is itself inside the window.
        let firstReportOnly = inMotionEvent("first", reports: [(30, inquiryHeadline), (30, rulingHeadline)])
        assertFalse(variant(firstReportOnly, updateHours: 36), "Reports of the same moment are not each other's past")
        let repeated = inMotionEvent(
            "repeat",
            reports: [
                (30, "Annual budget bill debated by Parliament on Tuesday"),
                (60, "Parliament debates annual budget bill on Monday"),
            ])
        assertFalse(variant(repeated, updateHours: 36), "A paraphrase 30 h old is repetition in the 36 h window")
        let repeatedInsideWindow = inMotionEvent(
            "echo",
            reports: [
                (2, "Court blocks the merger and orders divestiture of regional assets"),
                (30, rulingHeadline),
                (60, inquiryHeadline),
            ])
        assertFalse(
            variant(repeatedInsideWindow, updateHours: 24),
            "The 2 h report repeats the 30 h one, and the 30 h update is outside the 24 h window")
        assertTrue(
            variant(repeatedInsideWindow, updateHours: 36),
            "The 30 h report is the update of the 60 h story in the 36 h window")
    }

    /// Without the rising requirement steady and fading stories enter In Motion; the headline test still decides,
    /// so a lane short of its minimum stays hidden.
    static func testTodayInMotionWithoutRising() {
        let lead = inMotionEvent(
            "lead",
            reports: [
                (0.5, "National emergency declared after severe coastal storms kill dozens"),
                (0.6, "Evacuations ordered across three provinces after deadly storms"),
            ])
        // Fading: one report 6 to 12 hours ago and none since. Steady: nothing in the last 12 hours.
        let fading = (1...2).map {
            inMotionEvent("fading\($0)", reports: [(8, rulingHeadline), (30, inquiryHeadline)])
        }
        let steady = inMotionEvent("steady", reports: [(14, rulingHeadline), (30, inquiryHeadline)])
        let olderUpdate = inMotionEvent("older", reports: [(30, rulingHeadline), (60, inquiryHeadline)])
        let newStory = inMotionEvent("new", reports: [(8, rulingHeadline), (20, inquiryHeadline)])
        let repetition = inMotionEvent(
            "repeat",
            reports: [
                (8, "Annual budget bill debated by Parliament on Tuesday"),
                (30, "Parliament debates annual budget bill on Monday"),
            ])
        let entries = [lead] + fading + [steady, olderUpdate, newStory, repetition]

        func inMotion(_ entries: [FeedEntry], _ change: (inout TodayEditionThresholds) -> Void) -> Set<String> {
            var thresholds = TodayEditionThresholds.standard
            change(&thresholds)
            var signals = Dictionary(
                uniqueKeysWithValues: entries.map {
                    ($0.id, TodayStorySignals(nlImportanceOverride: 0.30, resolvedImportanceOverride: .minor))
                })
            signals["lead-0"] = TodayStorySignals(nlImportanceOverride: 0.95, resolvedImportanceOverride: .major)
            let plan = TodayEditionAssigner.assign(
                entries: entries,
                context: TodayAssignmentContext(now: referenceNow, signalsByEntryID: signals, thresholds: thresholds))
            assertEqual(plan.allAssignments.count, entries.count, "Every story keeps one lane")
            return Set(plan.entries(for: .inMotion).map(\.id))
        }

        assertEqual(inMotion(entries) { _ in }, [], "The shipped rule needs rising momentum")
        assertEqual(
            inMotion(entries) { $0.inMotionUpdateWindowSeconds = 24 * 3600 }, [],
            "The update window alone keeps the rising requirement")
        assertEqual(
            inMotion(entries) {
                $0.inMotionUpdateWindowSeconds = 24 * 3600
                $0.inMotionRequiresRisingMomentum = false
            },
            ["fading1-0", "fading2-0", "steady-0"],
            "Steady and fading updates enter; the new story, the repetition and the 30 h update stay out")
        assertEqual(
            inMotion(entries) {
                $0.inMotionUpdateWindowSeconds = 36 * 3600
                $0.inMotionRequiresRisingMomentum = false
            },
            ["fading1-0", "fading2-0", "steady-0", "older-0"],
            "The 36 h window adds the update 30 h old, and nothing that is new or repeated")
        assertEqual(
            inMotion([lead, fading[0], steady, newStory, repetition]) {
                $0.inMotionUpdateWindowSeconds = 36 * 3600
                $0.inMotionRequiresRisingMomentum = false
            }, [],
            "Two real updates are under the minimum of three: repetition never fills the lane")
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

    /// The evaluation option of #934: publisher affinity qualifies only together with an interest match above a
    /// lower bar, while a starred feed and a strong interest match still qualify alone.
    static func testTodayYourBeatAffinityBooster() {
        let profile = TodayUserProfile(
            entityWeights: ["organization:cern": 12.0],
            keywordWeights: ["fusion": 10.0],
            publisherWeights: ["favorite": 12.0, "occasional": 2.0, "rare": 2.0, "other": 2.0],
            interactionCount: 25
        )
        func story(
            _ id: String, _ title: String, source: String, feedURL: String = "https://plain.example/rss",
            entities: [EntityResult]? = nil
        ) -> FeedEntry {
            .article(
                makeArticle(
                    id: id, title: title, source: source, feedURL: feedURL, category: nil,
                    pubDate: referenceNow.addingTimeInterval(-600), entities: entities))
        }
        let lead = story("lead", "Crisis emergency talks begin", source: "Wire Desk")
        let affinityOnly = (1...3).map {
            story("affinity-\($0)", "Harbor authority reviews ferry timetable \($0)", source: "Favorite")
        }
        let affinityAndSomeInterest = story(
            "boosted", "Fusion startup secures funding for reactor prototype", source: "Favorite")
        let strongInterest = (1...2).map {
            story(
                "interest-\($0)", "Collider team publishes beam results \($0)", source: "Rare",
                entities: [EntityResult(name: "CERN", type: .organization)])
        }
        let starred = story(
            "starred", "Council approves cycling budget", source: "Other", feedURL: "https://starred.example/rss")
        let entries = [lead] + affinityOnly + [affinityAndSomeInterest] + strongInterest + [starred]

        func yourBeat(affinityInterestMinimum: Double) -> [TodayStoryAssignment] {
            var thresholds = TodayEditionThresholds.standard
            thresholds.yourBeatAffinityInterestMinimum = affinityInterestMinimum
            var signals = Dictionary(
                uniqueKeysWithValues: entries.map {
                    ($0.id, TodayStorySignals(nlImportanceOverride: 0.30, resolvedImportanceOverride: .minor))
                })
            signals["lead"] = TodayStorySignals(nlImportanceOverride: 0.90, resolvedImportanceOverride: .major)
            return TodayEditionAssigner.assign(
                entries: entries,
                context: TodayAssignmentContext(
                    now: referenceNow, starredFeedURLs: ["https://starred.example/rss"], profile: profile,
                    signalsByEntryID: signals, thresholds: thresholds)
            ).entries(for: .yourBeat)
        }

        let shipped = yourBeat(affinityInterestMinimum: TodayEditionThresholds.standard.yourBeatAffinityInterestMinimum)
        assertEqual(
            Set(shipped.map(\.id)),
            ["affinity-1", "affinity-2", "affinity-3", "boosted", "interest-1", "interest-2", "starred"],
            "The shipped rule lets top-quartile affinity qualify a story on its own")
        let boostedMatch = shipped.first { $0.id == "boosted" }?.interestMatch ?? 0
        assertTrue(
            boostedMatch >= 0.30 && boostedMatch < 0.50,
            "The boosted story's interest match (\(boostedMatch)) is under the bar that qualifies alone")

        let booster = yourBeat(affinityInterestMinimum: 0.30)
        assertEqual(
            Set(booster.map(\.id)), ["boosted", "interest-1", "interest-2", "starred"],
            "As a booster, affinity needs an interest match of 0.30; stars and strong interest qualify alone")
        assertEqual(
            booster.first { $0.id == "boosted" }?.reason, "your_beat_publisher_affinity",
            "The boosted story still enters through its publisher")
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
    /// #1174: a card's metadata is worked out while the edition is laid out, in a detached task as
    /// `ArticleStore.todayEdition` does, so a card body only reads it: the reading time counted from stored text is
    /// there before any card is drawn.
    static func testTodayCardDetailsOffMainActor() async {
        let story = makeArticle(
            id: "off-main", title: "Ministers agree a plan", pubDate: referenceNow.addingTimeInterval(-600),
            fullContent: Array(repeating: "word", count: 1200).joined(separator: " "))
        let entries: [FeedEntry] = [.article(story)]
        let plan = TodayEditionAssigner.assign(entries: entries, context: TodayAssignmentContext(now: referenceNow))
        let edition = await Task.detached { TodayEdition.make(entries: entries, plan: plan) }.value
        assertEqual(edition.metadata["off-main"]?.readingMinutes, 6, "Reading time is counted with the layout")
    }

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
        assertEqual(
            map.move(.down, from: "m2", memory: [:], visible: [.theDeepRead: "d3"]), "d3",
            "A lane without a remembered card gives focus to the card at its leading edge")
        assertEqual(
            map.move(.down, from: "m2", memory: [.theDeepRead: "d2"], visible: [.theDeepRead: "d3"]), "d2",
            "A remembered card comes before the leading one")
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
            shape(held), ["The Lead: a", "In Motion: b,d", "The Latest: e,f,g,stray"],
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

    /// #937: the last complete edition is laid out again at launch for the stories still listed, and anything that
    /// makes it another page falls back to the fresh path.
    static func testTodayStoredEdition() async throws {
        func entries(_ ids: [String]) -> [FeedEntry] {
            ids.map { .article(makeArticle(id: $0, title: $0, pubDate: referenceNow)) }
        }
        func story(_ id: String, _ lane: TodayLane) -> TodayStoryAssignment {
            TodayStoryAssignment.unplaced(.article(makeArticle(id: id, title: id, pubDate: referenceNow))).placed(
                in: lane, contentType: lane == .theDeepRead ? .explainer : nil)
        }
        func shape(_ edition: TodayEdition?) -> [String] {
            (edition?.lanes ?? []).map { "\($0.lane.rawValue): \($0.stories.map(\.id).joined(separator: ","))" }
        }
        let plan = TodayEditionPlan(
            lanes: [
                TodayLaneResult(
                    lane: .theLead, qualifies: true, entries: [story("a", .theLead), story("b", .theLead)]),
                TodayLaneResult(lane: .theDeepRead, qualifies: true, entries: [story("c", .theDeepRead)]),
                TodayLaneResult(lane: .yourBeat, qualifies: true, entries: [story("d", .yourBeat)]),
                TodayLaneResult(lane: .theLatest, qualifies: true, entries: [story("e", .theLatest)]),
            ])
        let photo = URL(string: "https://images.example/a.jpg")!
        var details = TodayCardDetails()
        details.eventImages = ["a": photo, "b": URL(string: "https://images.example/b.jpg")!]
        let fresh = TodayEdition.make(entries: entries(["a", "b", "c", "d", "e"]), plan: plan, details: details)
        let identity = TodayStoredEdition.identity(
            feedURLs: ["https://b.example/rss", "https://a.example/rss"], starredFeedURLs: [], interestsResetAt: nil)
        assertEqual(
            identity,
            TodayStoredEdition.identity(
                feedURLs: ["https://a.example/rss", "https://b.example/rss"], starredFeedURLs: [],
                interestsResetAt: nil), "The same subscriptions in another order are the same reader")
        let stored = try JSONDecoder().decode(
            TodayStoredEdition.self,
            from: JSONEncoder().encode(TodayStoredEdition(fresh, identity: identity, builtAt: referenceNow)))
        func restore(
            _ ids: [String], identity current: String? = nil, failed: Set<URL> = [], after seconds: TimeInterval = 60,
            from edition: TodayStoredEdition? = nil
        ) -> Result<TodayEdition, TodayStoredEdition.Rejection> {
            (edition ?? stored).restored(
                entries: entries(ids), identity: current ?? identity, failedImageURLs: failed,
                now: referenceNow.addingTimeInterval(seconds))
        }

        let same = try restore(["a", "b", "c", "d", "e"]).get()
        assertEqual(shape(same), shape(fresh), "The stored edition comes back with every story in its lane and order")
        assertTrue(same.isRestored && !same.isAssigned, "A restored edition is marked, and is not one to store again")
        assertTrue(same.hasSameArrangement(as: fresh), "A fresh edition of the same arrangement confirms it")
        assertEqual(same.metadata["a"]?.imageURL, photo, "A Lead slide keeps the event photo its card showed")
        assertEqual(same.metadata["c"]?.contentType, "Explainer", "A Deep Read card keeps its tag")

        let changed = try restore(["a", "b", "d", "e", "new"]).get()
        assertEqual(
            shape(changed), ["The Lead: a,b", "Your Beat: d", "The Latest: e,new"],
            "A story that left the list leaves its lane, and a story the edition never held joins The Latest")
        assertFalse(changed.hasSameArrangement(as: fresh), "Another arrangement is not a confirmation")

        var leftDetails = details
        leftDetails.unsubscribedIDs = ["gone"]
        let withLeft = TodayStoredEdition(
            TodayEdition.make(entries: entries(["a", "b", "c", "d", "e", "gone"]), plan: plan, details: leftDetails),
            identity: identity, builtAt: referenceNow)
        assertEqual(
            shape(try restore(["a", "b", "c", "d", "e", "gone"], from: withLeft).get()), shape(fresh),
            "A story of a feed the reader has left stays out of a restored edition, also out of The Latest")

        let onePhoto = try restore(["a", "b", "c", "d", "e"], failed: [photo]).get()
        assertEqual(onePhoto.lead.map(\.id), ["b"], "A slide whose photo failed to load leaves The Lead")
        assertTrue(onePhoto.latest.map(\.id).contains("a"), "It stays on the page, in The Latest")

        func rejection(_ result: Result<TodayEdition, TodayStoredEdition.Rejection>) -> String? {
            if case .failure(let reason) = result { return reason.rawValue }
            return nil
        }
        assertEqual(
            rejection(restore(["a", "b", "c", "d", "e"], identity: "other")), "otherReader",
            "Other subscriptions, stars or interests: the edition is not this reader's")
        assertEqual(
            rejection(restore(["a", "b", "c", "d", "e"], after: TodayStoredEdition.maximumAge + 1)), "tooOld",
            "An edition older than Today's window is not shown")
        var otherFormat = stored
        otherFormat.version += 1
        assertEqual(
            rejection(restore(["a", "b", "c", "d", "e"], from: otherFormat)), "otherFormat",
            "An edition another build wrote is not shown")
        assertEqual(
            rejection(restore(["d", "e", "x", "y"])), "storiesGone",
            "An edition most of whose lane stories left the list describes another page")
        assertEqual(
            rejection(restore(["a", "b", "c", "d", "e"], failed: Set(details.eventImages.values))), "noLead",
            "With no slide left, the fresh path lays the page out")

        assertEqual(
            TodayRestoreOutcome.decide(sameArrangement: true, isTouched: true, awaitsNewDay: true), .confirmed,
            "The same arrangement replaces the restored edition unseen")
        assertEqual(
            TodayRestoreOutcome.decide(sameArrangement: false, isTouched: false, awaitsNewDay: false), .swapped,
            "Another arrangement takes an untouched page")
        assertEqual(
            TodayRestoreOutcome.decide(sameArrangement: false, isTouched: true, awaitsNewDay: false), .held,
            "A page in use keeps its cards; the fresh edition waits behind the updates button")
        assertEqual(
            TodayRestoreOutcome.decide(sameArrangement: false, isTouched: false, awaitsNewDay: true), .held,
            "No swap while another day's page is on its way")

        // The held path (#937): the reader touched the restored page before the fresh edition was ready.
        let restoredPage = try restore(["a", "b", "c", "d", "e"]).get()
        let freshPlan = TodayEditionPlan(
            lanes: [
                TodayLaneResult(lane: .theLead, qualifies: true, entries: [story("e", .theLead)]),
                TodayLaneResult(
                    lane: .theLatest, qualifies: true,
                    entries: ["a", "b", "c", "d"].map { story($0, .theLatest) }),
            ])
        let freshBehind = TodayEdition.make(entries: entries(["a", "b", "c", "d", "e"]), plan: freshPlan)
        assertFalse(
            TodayEdition.keepsLanes(of: restoredPage, isHolding: true, generation: 0),
            "A restored edition is never kept: the fresh one behind it is laid out from the assignment")
        assertEqual(
            TodayRestoreOutcome.decide(
                sameArrangement: freshBehind.hasSameArrangement(as: restoredPage), isTouched: true,
                awaitsNewDay: false), .held, "A touched page holds its restored cards")
        let heldPage = restoredPage.heldBehindUpdates(for: entries(["a", "b", "c", "d", "e"]), fresh: freshBehind)
        assertTrue(!heldPage.isRestored && shape(heldPage) == shape(restoredPage), "The cards stay as they were")
        assertEqual(heldPage.metadata["a"]?.imageURL, photo, "A held Lead slide keeps the photo it showed")
        var leftFeed = freshBehind
        leftFeed.excludedIDs = ["d"]
        assertEqual(
            shape(restoredPage.heldBehindUpdates(for: entries(["a", "b", "c", "d", "e", "page2"]), fresh: leftFeed)),
            ["The Lead: a,b", "The Deep Read: c", "The Latest: e,page2"],
            "Held, a story of a feed left since leaves Today and a further page joins The Latest")
        let page2Photo = URL(string: "https://images.example/page2.jpg")!
        var page2Details = TodayCardDetails()
        page2Details.eventImages = ["page2": page2Photo]
        let freshWithPage2 = TodayEdition.make(
            entries: entries(["a", "b", "c", "d", "e", "page2"]), plan: freshPlan, details: page2Details)
        assertEqual(
            restoredPage.heldBehindUpdates(for: entries(["a", "b", "c", "d", "e", "page2"]), fresh: freshWithPage2)
                .metadata["page2"]?.imageURL, page2Photo,
            "A story the list gained takes its event photo from the fresh edition")
        assertEqual(
            TodayRestoreOutcome.decide(sameArrangement: false, isTouched: false, awaitsNewDay: true, isApplied: true),
            .swapped, "The new day's page, which only replaces an untouched list, takes the page")
        assertEqual(
            TodayRestoreOutcome.decide(sameArrangement: false, isTouched: true, awaitsNewDay: false, isApplied: true),
            .swapped, "An update the reader applied over the restored edition takes the page, touched or not")
        assertEqual(
            TodayRestoreOutcome.decide(sameArrangement: true, isTouched: false, awaitsNewDay: false, isApplied: true),
            .swapped, "Applied, the fresh edition keeps its new generation instead of confirming the old one")
        assertTrue(
            TodayEdition.keepsLanes(of: heldPage, isHolding: true, generation: 0),
            "Later store revisions keep the held cards in their lanes")
        let afterRevision = TodayEdition.make(
            entries: entries(["a", "b", "c", "d", "e", "late"]), plan: freshPlan, keeping: heldPage)
        assertEqual(
            shape(afterRevision), ["The Lead: a,b", "Your Beat: d", "The Deep Read: c", "The Latest: e,late"],
            "Until Show Updates nothing moves; a story the list gained joins The Latest")
        assertFalse(
            TodayEdition.keepsLanes(of: heldPage, isHolding: true, generation: 1),
            "Show Updates starts a new generation, so the page is laid out afresh")
        assertTrue(
            TodayEdition.make(entries: entries(["a", "b", "c", "d", "e"]), plan: freshPlan, generation: 1)
                .hasSameArrangement(as: freshBehind), "Show Updates shows the fresh edition")
        assertFalse(
            TodayEdition.keepsLanes(of: heldPage, isHolding: false, generation: 0),
            "A refresh the reader asked for lays the page out afresh too")
        assertFalse(TodayEdition.keepsLanes(of: nil, isHolding: true, generation: 0), "A first edition has none")

        // The side file: nothing stored reads as nothing, a stored edition comes back, nil removes it.
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        assertTrue(await db.storedTodayEdition() == nil, "A library without a stored edition takes the fresh path")
        let data = try JSONEncoder().encode(stored)
        try await db.storeTodayEdition(data)
        assertEqual(await db.storedTodayEdition(), data, "The stored edition is read back")
        try await db.storeTodayEdition(nil)
        assertTrue(await db.storedTodayEdition() == nil, "Removing it leaves none")
        let generation = await db.analysisGeneration
        try await db.storeTodayEdition(data)
        try await db.clearArticleEnrichment()
        try await db.storeTodayEdition(data, expectedGeneration: generation)
        assertTrue(
            await db.storedTodayEdition() == nil, "An edition read before Clear Analysis is not stored after it")
        assertTrue(
            await db.storedTodayEdition() == nil, "Clear Analysis removes the stored edition and its differing accounts"
        )
        await db.close()
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

    /// #937: spreading the stories over the cores keeps their order and every value of the serial evaluation.
    static func testTodayConcurrentEvaluationMatchesSerial() {
        let titles = ["Senate passes budget", "Storm closes harbor", "Chip maker reports record sales"]
        let entries: [FeedEntry] = (0..<40).map { index in
            .article(
                makeArticle(
                    id: "c\(index)", title: "\(titles[index % 3]) number \(index)", pubDate: referenceNow))
        }
        let context = TodayAssignmentContext(now: referenceNow)
        // Every field of the evaluation, not a chosen few: a value that concurrency changed would show.
        func summary(_ stories: [TodayEditionAssigner.EvaluatedStory]) -> [String] {
            stories.map { String(describing: $0) }
        }
        let serial = entries.map { TodayEditionAssigner.evaluateStory($0, context: context) }
        let concurrent = TodayEditionAssigner.evaluateStories(entries, context: context)
        assertEqual(
            summary(concurrent), summary(serial), "Concurrent evaluation keeps the serial order and values")
    }

    /// Live feedback of 11 November 2026: a story with no photo takes no slide while another story has one; a story
    /// whose feeds the reader has all left is out of Today, and one whose feed is unknown stays; The Latest is
    /// newest first by the date its cards show.
    static func testTodayLeadPhotoAndLeftFeeds() {
        func event(_ id: String, minutesAgo: Double) -> FeedEntry {
            let date = referenceNow.addingTimeInterval(-minutesAgo * 60)
            return makeEventEntry(
                eventID: "ev-\(id)",
                members: [
                    ("\(id)1", "Outlet 1", "Bridge \(id) collapses in storm", "Detail", date, "https://o1.example/rss"),
                    ("\(id)2", "Outlet 2", "Teams reach bridge \(id)", "Detail", date, "https://o2.example/rss"),
                    (
                        "\(id)3", "Outlet 3", "Traffic diverted at bridge \(id)", "Detail", date,
                        "https://o3.example/rss"
                    ),
                ])
        }
        let entries = [event("a", minutesAgo: 30), event("b", minutesAgo: 40)]
        var context = TodayAssignmentContext(now: referenceNow)
        let open = TodayEditionAssigner.assign(entries: entries, context: context)
        guard let top = open.entries(for: .theLead).first?.id else {
            assertTrue(false, "The Lead has a first slide")
            return
        }
        context.imagelessEntryIDs = [top]
        let pictured = TodayEditionAssigner.assign(entries: entries, context: context)
        assertFalse(pictured.entries(for: .theLead).contains { $0.id == top }, "A story with no photo takes no slide")
        assertTrue(pictured.allAssignments.contains { $0.id == top }, "It is still in the edition, in another lane")
        assertEqual(pictured.entries(for: .theLead).count, 1, "The pictured story leads")
        context.imagelessEntryIDs = Set(entries.map(\.id))
        assertEqual(
            TodayEditionAssigner.assign(entries: entries, context: context).entries(for: .theLead).first?.id, top,
            "With no photo anywhere, the top story still leads")

        // Subscriptions: a story of a feed the reader left, one of a kept feed and one whose feed is not known.
        let left = makeArticle(
            id: "left", title: "From a feed the reader left", feedURL: "https://left.example/rss",
            pubDate: referenceNow.addingTimeInterval(-600))
        let kept = makeArticle(
            id: "kept", title: "From a kept feed", feedURL: "https://kept.example/rss",
            pubDate: referenceNow.addingTimeInterval(-1200))
        var unknown = makeArticle(
            id: "unknown", title: "Feed not known", pubDate: referenceNow.addingTimeInterval(-300))
        unknown.identityFeedURL = nil
        let listed: [FeedEntry] = [.article(unknown), .article(left), .article(kept)]
        let subscribed = TodayAssignmentContext(now: referenceNow, subscribedFeedURLs: ["https://kept.example/rss"])
        let gone = TodayEditionAssigner.unsubscribedEntryIDs(listed, context: subscribed)
        assertEqual(gone, ["left"], "Only a story whose known feeds are all unsubscribed leaves Today")
        let edition = TodayEdition.make(
            entries: listed, plan: TodayEditionAssigner.assign(entries: listed, context: subscribed),
            details: TodayCardDetails(unsubscribedIDs: gone))
        assertEqual(
            edition.lanes.flatMap { $0.stories.map(\.id) }.sorted(), ["kept", "unknown"],
            "The left feed's story is not shown; the story with no known feed is kept")
        let held = TodayEdition.make(
            entries: listed, plan: TodayEditionPlan(lanes: []),
            details: TodayCardDetails(unsubscribedIDs: ["kept"]), keeping: edition)
        assertFalse(held.storyIDs.contains("kept"), "Unsubscribing removes the story from a held edition at once")

        // The Latest follows the date on its cards, newest first, whatever order the stories arrive in.
        let ordered = TodayEdition.make(
            entries: [.article(kept), .article(unknown), .article(left)], plan: TodayEditionPlan(lanes: []))
        assertEqual(ordered.latest.map(\.id), ["unknown", "left", "kept"], "The Latest is newest first")
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
        let wholeHistory = try await db.todayUserProfile(now: now, interactionLimit: 1)
        let noHistory = try await db.todayUserProfile(now: now, interactionLimit: 0)
        assertEqual(wholeHistory, ctx1.profile, "A limit at or above the reader's history changes nothing")
        assertFalse(noHistory.hasHistory, "A history cut to nothing is the profile of a new reader")
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

    // MARK: - #934 acceptance: the whole edition

    /// A page that fills every lane: one Lead story, three In Motion events, three long reads, three stories on the
    /// reader's subject, three outside it and two that clear no bar.
    private static func fullEdition() -> (entries: [FeedEntry], context: TodayAssignmentContext) {
        var entries: [FeedEntry] = [
            .article(makeArticle(id: "lead", title: "Crisis emergency talks begin", pubDate: referenceNow))
        ]
        var signals: [String: TodayStorySignals] = [
            "lead": TodayStorySignals(nlImportanceOverride: 0.90, resolvedImportanceOverride: .major)
        ]
        for index in 1...3 {
            entries.append(
                inMotionEvent("m\(index)", reports: [(0.25, rulingHeadline), (30, inquiryHeadline)]))
            signals["m\(index)-0"] = TodayStorySignals(nlImportanceOverride: 0.30, resolvedImportanceOverride: .minor)
            entries.append(
                .article(
                    makeArticle(
                        id: "deep-\(index)", title: "Investigation: harbor dredging contract number \(index)",
                        source: "Harbor Review \(index)", category: "Local",
                        pubDate: referenceNow.addingTimeInterval(-Double(1000 + index)))))
            signals["deep-\(index)"] = TodayStorySignals(
                nlImportanceOverride: 0.25, resolvedImportanceOverride: .minor)
            entries.append(
                .article(
                    makeArticle(
                        id: "beat-\(index)", title: "CERN fusion experiment milestone \(index)",
                        description: "Research team reports fusion containment gain.",
                        source: "Science Daily \(index)", category: "Science",
                        pubDate: referenceNow.addingTimeInterval(-Double(2000 + index)),
                        entities: [EntityResult(name: "CERN", type: .organization)])))
            signals["beat-\(index)"] = TodayStorySignals(
                nlImportanceOverride: 0.25, resolvedImportanceOverride: .minor)
            entries.append(
                .article(
                    makeArticle(
                        id: "out-\(index)", title: "Central bank governor testifies on inflation framework \(index)",
                        description: "Detailed macroeconomic briefing with named institutions.",
                        source: "Finance Press \(index)", category: "Business",
                        pubDate: referenceNow.addingTimeInterval(-Double(3000 + index)))))
            signals["out-\(index)"] = TodayStorySignals(
                originalReportCount: 2, nlImportanceOverride: 0.65, resolvedImportanceOverride: .notable)
        }
        for index in 1...2 {
            entries.append(
                .article(
                    makeArticle(
                        id: "rest-\(index)", title: "Brief notice", description: "", source: "Misc",
                        category: "Lifestyle", pubDate: referenceNow.addingTimeInterval(-Double(4000 + index)))))
            signals["rest-\(index)"] = TodayStorySignals(
                nlImportanceOverride: 0.15, resolvedImportanceOverride: .minor)
        }
        let profile = TodayUserProfile(
            entityWeights: ["organization:cern": 12.0], keywordWeights: ["fusion": 10.0], interactionCount: 25)
        return (entries, TodayAssignmentContext(now: referenceNow, profile: profile, signalsByEntryID: signals))
    }

    /// #934 acceptance, in one edition with all six lanes filled: the same inputs give the same plan in every
    /// lane, in whatever order the stories arrive; each story is in exactly one lane and no event twice; every
    /// story is placed, and the ones no lane takes are in The Latest; each entry carries the output contract.
    static func testTodayFullEditionContract() {
        let (entries, context) = fullEdition()
        let plan = TodayEditionAssigner.assign(entries: entries, context: context)

        for lane in TodayLane.assignmentOrder {
            assertTrue(plan.result(for: lane)?.qualifies == true, "\(lane.rawValue) shows in the full edition")
            let again = TodayEditionAssigner.assign(entries: entries, context: context)
            assertEqual(
                again.entries(for: lane), plan.entries(for: lane), "\(lane.rawValue) repeats for the same inputs")
            let reversed = TodayEditionAssigner.assign(entries: entries.reversed(), context: context)
            assertEqual(
                reversed.entries(for: lane).map(\.id), plan.entries(for: lane).map(\.id),
                "\(lane.rawValue) does not depend on the order the stories arrive in")
        }

        // One story, one lane; story entries only, so no event twice.
        let placed = plan.allAssignments
        assertEqual(placed.count, Set(placed.map(\.id)).count, "No story is in two lanes")
        let events = placed.compactMap { item -> String? in
            if case .event(let summary, _, _) = item.entry { return summary.eventID }
            return nil
        }
        assertEqual(events.count, Set(events).count, "No event is in two lanes")
        for lane in TodayLane.assignmentOrder {
            assertTrue(
                plan.entries(for: lane).allSatisfy { $0.lane == lane }, "\(lane.rawValue) entries name their lane")
        }

        // The Latest is the safety net: every story is placed, and what no lane took is there.
        assertEqual(Set(placed.map(\.id)), Set(entries.map(\.id)), "Every story of the pool is placed")
        assertEqual(
            Set(plan.entries(for: .theLatest).map(\.id)), ["rest-1", "rest-2"],
            "Stories that clear no bar are in The Latest")
        assertTrue(
            plan.entries(for: .theLatest).allSatisfy { $0.reason == "the_latest_safety_net" },
            "The Latest gives the safety net as its reason")

        // Output contract: lane, score, confidence, reason, sortKey.
        for item in placed {
            assertTrue((0.0...1.0).contains(item.score), "\(item.id): score is on the 0–1 scale")
            assertTrue((0.0...1.0).contains(item.confidence), "\(item.id): confidence is on the 0–1 scale")
            assertFalse(item.reason.isEmpty, "\(item.id): a reason is given")
            assertTrue(
                item.reason.allSatisfy { $0 == "_" || $0.isNumber || ($0.isLetter && $0.isLowercase) },
                "\(item.id): the reason is a code, not reader copy")
            assertEqual(item.sortKey, item.entry.representative.orderDate, "\(item.id): sortKey is the story's date")
        }
        for lane in TodayLane.assignmentOrder where lane != .theLead {
            let keys = plan.entries(for: lane).map(\.sortKey)
            assertEqual(keys, keys.sorted(by: >), "\(lane.rawValue) is newest first")
        }
        assertEqual(plan.entries(for: .theLead).first?.reason, "lead_top_story", "The Lead follows rank")
    }

    /// #934 acceptance: the output has the six fixed lanes and no topic lane, and an entry carries the contract's
    /// fields and no Briefing analysis (assessment, gauge, strategic impact, weak signal).
    static func testTodayOutputHasNoTopicLaneOrAnalysis() {
        assertEqual(
            TodayLane.allCases.map(\.rawValue),
            ["The Lead", "In Motion", "The Deep Read", "Your Beat", "Outside Your Usual", "The Latest"],
            "Today has the six lanes of the spec and no other")
        let sections = Set(NewsCategory.allCases.map { $0.rawValue.lowercased() })
        assertTrue(
            TodayLane.allCases.allSatisfy { !sections.contains($0.rawValue.lowercased()) }, "No lane is a section")

        let (entries, context) = fullEdition()
        let plan = TodayEditionAssigner.assign(entries: entries, context: context)
        assertEqual(plan.lanes.map(\.lane), TodayLane.assignmentOrder, "A plan holds exactly the six lanes")
        guard let item = plan.allAssignments.first else { return assertTrue(false, "The full edition places stories") }
        let fields = Mirror(reflecting: item).children.compactMap(\.label)
        assertEqual(
            fields,
            [
                "id", "entry", "lane", "score", "confidence", "reason", "sortKey", "contentTypeLabel",
                "isCoverageConfident", "isDeveloping", "originalReportCount", "publisherCount", "groupingConfidence",
                "readingTimeMinutes", "interestMatch", "novelty",
            ],
            "An entry carries the output contract, card flags and evaluation numbers: a new field is a decision")
        let analysis = ["assessment", "gauge", "impact", "signal", "sitrep", "tension", "summary", "overview"]
        assertTrue(
            fields.allSatisfy { field in !analysis.contains { field.lowercased().contains($0) } },
            "No entry field carries Briefing analysis")
        assertTrue(
            Mirror(reflecting: plan).children.compactMap(\.label) == ["lanes"],
            "A plan carries its lanes and nothing else")
    }

    /// #934 acceptance, the reverse of `testTodayNotificationThresholdsIndependent`: a story that passes the
    /// notification bar does not lead Today on that account. Wire copy gives it four publishers and one original
    /// report; Today's bar for a one-report slide is its own score.
    static func testTodayNotifyingStoryNeedNotLead() {
        let title = "Breaking: ferry service suspended"
        assertTrue(
            NotificationService.isPriority(
                title: title, score: NotificationService.priorityScore,
                publishers: NotificationService.priorityPublishers),
            "The story passes the notification bar")
        let wire = makeEventEntry(
            eventID: "ev-wire",
            members: (1...4).map {
                (
                    "w\($0)", "Wire Client \($0)", title, "Agency copy.",
                    referenceNow.addingTimeInterval(-Double($0 * 60)), "https://w\($0).example/rss"
                )
            })
        let top = FeedEntry.article(
            makeArticle(id: "top", title: "Crisis emergency talks begin", pubDate: referenceNow))
        let plan = TodayEditionAssigner.assign(
            entries: [top, wire],
            context: TodayAssignmentContext(
                now: referenceNow,
                signalsByEntryID: [
                    "top": TodayStorySignals(nlImportanceOverride: 0.90, resolvedImportanceOverride: .major),
                    "w1": TodayStorySignals(
                        originalReportCount: 1, nlImportanceOverride: 0.40, resolvedImportanceOverride: .minor),
                ]))
        assertEqual(plan.entries(for: .theLead).map(\.id), ["top"], "The notifying wire story takes no slide")
        assertTrue(plan.entries(for: .theLatest).contains { $0.id == "w1" }, "It is still on the page")
        let today = TodayEditionThresholds.standard
        assertTrue(
            Mirror(reflecting: today).children.compactMap(\.label).allSatisfy {
                !$0.lowercased().contains("notif") && !$0.lowercased().contains("priority")
                    && !$0.lowercased().contains("breaking")
            }, "Today's thresholds hold no notification threshold")
    }

    /// The default-off option of #934 (12 November 2026): affinity per story published with a floor of read or
    /// saved stories. Off, the profile and the plan are the shipped ones; on, a publisher read often but
    /// publishing much gives way to one read at a higher rate, and a publisher under the floor is no affinity
    /// publisher at all.
    static func testTodayYourBeatPerStoryAffinity() async throws {
        assertTrue(TodayEditionThresholds.standard.yourBeatAffinityPerStoryFloor == nil, "The option ships off")
        // Four engaged publishers, so the quartile is one. "busy" has the most reads; "quiet" the highest rate.
        let weights = ["busy": 8.0, "quiet": 6.0, "small": 2.0, "other": 2.0]
        let window = weights
        let read = ["busy": 8, "quiet": 6, "small": 2, "other": 2]
        let published = ["busy": 400, "quiet": 20, "small": 2, "other": 50]
        assertEqual(TodayUserProfile.computeTopQuartilePublishers(from: weights), ["busy"], "Shipped: most engagement")
        assertEqual(
            TodayUserProfile.perStoryAffinityPublishers(
                weights: weights, windowWeights: window, storiesRead: read, published: published, floor: 5),
            [], "The highest rate belongs to a publisher under the floor: no affinity publisher")
        assertEqual(
            TodayUserProfile.perStoryAffinityPublishers(
                weights: weights, windowWeights: window, storiesRead: read,
                published: published.merging(["small": 40]) { $1 }, floor: 5),
            ["quiet"], "Per story published, the quieter publisher is the affinity publisher")
        assertEqual(
            TodayUserProfile.perStoryAffinityPublishers(
                weights: [:], windowWeights: [:], storiesRead: [:], published: published, floor: 5),
            [], "No history, no affinity publisher")

        // Through the loader: "Busy Wire" is read six times of 30 stories, "Quiet Review" five times of six.
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        defer { Task { await db.close() } }
        let now = Date()
        let feed = "https://global.example/rss"
        var stories: [FeedArticle] = []
        for index in 0..<30 {
            stories.append(
                makeArticle(
                    id: "busy-\(index)", title: "Harbor ledger entry \(index)", source: "Busy Wire", feedURL: feed,
                    pubDate: now.addingTimeInterval(-Double(3600 + index * 60))))
        }
        for index in 0..<6 {
            stories.append(
                makeArticle(
                    id: "quiet-\(index)", title: "Orchard almanac note \(index)", source: "Quiet Review",
                    feedURL: feed, pubDate: now.addingTimeInterval(-Double(7200 + index * 60))))
        }
        try await db.upsertArticles(stories)
        for id in (0..<6).map({ "busy-\($0)" }) + (0..<5).map({ "quiet-\($0)" }) {
            try await db.markRead(articleId: id, isRead: true)
        }
        let shipped = try await db.todayUserProfile(now: now)
        let option = try await db.todayUserProfile(now: now, affinityStoryFloor: 5)
        let highFloor = try await db.todayUserProfile(now: now, affinityStoryFloor: 6)
        assertEqual(shipped.topQuartilePublishers, ["busy wire"], "Shipped rule: the publisher read most")
        assertEqual(option.topQuartilePublishers, ["quiet review"], "Option: the publisher read at the higher rate")
        assertEqual(highFloor.topQuartilePublishers, [], "A floor above its read stories switches affinity off")
        var same = option
        same.topQuartilePublishers = shipped.topQuartilePublishers
        assertEqual(same, shipped, "The option changes the affinity publishers and nothing else in the profile")

        let entries = stories.map(FeedEntry.article)
        let standard = try await db.loadTodayAssignmentContext(entries: entries, now: now, subscribedFeedURLs: [feed])
        let explicit = try await db.loadTodayAssignmentContext(
            entries: entries, now: now, subscribedFeedURLs: [feed], thresholds: .standard)
        assertEqual(standard, explicit, "Without the option the loaded context is the shipped one")
        assertEqual(standard.profile, shipped, "The shipped context holds the shipped profile")
        var thresholds = TodayEditionThresholds.standard
        thresholds.yourBeatAffinityPerStoryFloor = 5
        let optional = try await db.loadTodayAssignmentContext(
            entries: entries, now: now, subscribedFeedURLs: [feed], thresholds: thresholds)
        func affinityStories(_ context: TodayAssignmentContext) -> Set<String> {
            Set(
                TodayEditionAssigner.evaluateStories(entries, context: context)
                    .filter(\.isTopQuartilePublisher).map { String($0.id.prefix(while: { $0 != "-" })) })
        }
        assertEqual(affinityStories(standard), ["busy"], "Shipped: the busy publisher's stories carry affinity")
        assertEqual(affinityStories(optional), ["quiet"], "Option on: the quiet publisher's stories carry it")
    }
}
