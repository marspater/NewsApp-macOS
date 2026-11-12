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
            ("testFocusMovesWithinAndBetweenLanes", { testTodayFocusMap() }),
            ("testFocusIsRestoredWhenTheEditionChanges", { testTodayFocusRestore() }),
            ("testEditionKeepsLanesUntilAnUpdateIsApplied", { testTodayEditionPinsLanes() }),
            ("testHeldEditionKeepsTagsEntriesAndNewEditionSortsLatest", { testTodayHeldEditionDetails() }),
            ("testStoredEditionRestoresValidatesAndFallsBack", { try await testTodayStoredEdition() }),
            ("testWindowPoolWidensLanesAndKeepsTheLatestListed", { try testTodayWindowPool() }),
            ("testConcurrentEvaluationMatchesSerial", { testTodayConcurrentEvaluationMatchesSerial() }),
            ("testLeadNeedsAPhotoAndLeftFeedsLeaveToday", { testTodayLeadPhotoAndLeftFeeds() }),
            ("testNotificationThresholdsRemainIndependent", { testTodayNotificationThresholdsIndependent() }),
            ("testDeterminismAndDatabaseLoaderIntegration", { try await testTodayDeterminismAndDatabaseLoader() }),
            ("testCancelledReloadLaysNoFallbackOut", { try await testTodayCancelledReload() }),
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

    /// #934, gate 6 of #932: with the window pool the lanes may hold stories beyond the listed page, The Latest holds
    /// only listed stories, and no story appears twice; without it (the default) the lanes keep to the listed page.
    static func testTodayWindowPool() throws {
        func entries(_ ids: [String]) -> [FeedEntry] {
            ids.map { .article(makeArticle(id: $0, title: $0, pubDate: referenceNow)) }
        }
        func story(_ id: String, _ lane: TodayLane) -> TodayStoryAssignment {
            TodayStoryAssignment.unplaced(.article(makeArticle(id: id, title: id, pubDate: referenceNow))).placed(
                in: lane)
        }
        func shape(_ edition: TodayEdition) -> [String] {
            edition.lanes.map { "\($0.lane.rawValue): \($0.stories.map(\.id).joined(separator: ","))" }
        }
        // The page lists p1 to p3; the window adds w1 and w2. The plan, made over the window, leads with w1, puts
        // p1 and w2 in Your Beat and leaves p2, p3 for The Latest (with w2 also there, as a window story would be).
        let listed = entries(["p1", "p2", "p3"])
        let pool = TodayEdition.windowPool(entries(["w1", "p1", "w2", "p2"]), listed: listed)
        assertEqual(
            pool.map(\.id), ["w1", "p1", "w2", "p2", "p3"], "Window order, then listed stories outside it, once")
        let regrouped = makeEventEntry(
            eventID: "ev-regrouped",
            members: [
                ("w5", "Outlet 1", "w5", "Detail", referenceNow, "https://o1.example/rss"),
                ("p3", "Outlet 2", "p3", "Detail", referenceNow, "https://o2.example/rss"),
            ])
        assertEqual(
            TodayEdition.windowPool([regrouped], listed: listed).map(\.id), ["p1", "p2", "p3"],
            "A window story holding a report the page lists under another id is left to the page's entry")
        let plan = TodayEditionPlan(lanes: [
            TodayLaneResult(lane: .theLead, qualifies: true, entries: [story("w1", .theLead)]),
            TodayLaneResult(
                lane: .yourBeat, qualifies: true, entries: [story("p1", .yourBeat), story("w2", .yourBeat)]),
            TodayLaneResult(
                lane: .theLatest, qualifies: true,
                entries: [story("p2", .theLatest), story("p3", .theLatest), story("w9", .theLatest)]),
        ])
        let wide = TodayEdition.make(entries: listed, plan: plan, pool: pool)
        assertEqual(
            shape(wide), ["The Lead: w1", "Your Beat: p1,w2", "The Latest: p2,p3"],
            "Lanes take window stories; The Latest keeps to the listed page")
        let ids = wide.lanes.flatMap { $0.stories.map(\.id) }
        assertEqual(ids.count, Set(ids).count, "No story twice")
        assertEqual(
            shape(TodayEdition.make(entries: listed, plan: plan)),
            ["The Lead: w1", "Your Beat: p1,w2", "The Latest: p2,p3,w9"],
            "Without the pool the plan is laid out as before (it is made over the listed page in the app)")

        // Held: a lane story beyond the listed page stays with the pool; without it, it leaves its lane.
        let held = TodayEdition.make(entries: listed + entries(["p4"]), plan: plan, keeping: wide, pool: pool)
        assertEqual(
            shape(held), ["The Lead: w1", "Your Beat: p1,w2", "The Latest: p2,p3,p4"],
            "Held with the pool, window stories keep their lanes and a further page joins The Latest")
        assertEqual(
            shape(TodayEdition.make(entries: listed, plan: plan, keeping: wide)),
            ["Your Beat: p1", "The Latest: p2,p3"], "Held without the pool, stories off the page leave their lanes")

        // Restored: the stored edition's lane stories are counted against the pool.
        var details = TodayCardDetails()
        details.eventImages = ["w1": URL(string: "https://images.example/w1.jpg")!]
        let identity = TodayStoredEdition.identity(feedURLs: [], starredFeedURLs: [], interestsResetAt: nil)
        let stored = TodayStoredEdition(
            TodayEdition.make(entries: listed, plan: plan, details: details, pool: pool), identity: identity,
            builtAt: referenceNow)
        let restoredWide = try stored.restored(
            entries: listed, identity: identity, now: referenceNow.addingTimeInterval(60), pool: pool
        ).get()
        assertEqual(shape(restoredWide), shape(wide), "With the pool the stored edition comes back whole")
        if case .failure(let reason) = stored.restored(
            entries: listed, identity: identity, now: referenceNow.addingTimeInterval(60))
        {
            assertEqual(reason, .storiesGone, "Without the pool most of its lane stories are off the page")
        } else {
            assertTrue(false, "Without the pool the window-wide edition is not restored")
        }
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

    /// #937: a reload cancelled by a newer revision returns an empty edition its caller discards, instead of laying a
    /// fallback edition out on the main actor; an uncancelled one lays the page out.
    @MainActor
    static func testTodayCancelledReload() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        defer { Task { await db.close() } }
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        let entries: [FeedEntry] = [.article(makeArticle(id: "c1", title: "Port reopens", pubDate: referenceNow))]
        let reader = TodayReader(subscribedFeedURLs: ["https://global.example/rss"], starredFeedURLs: [])
        let cancelled = Task { @MainActor in
            await store.todayEdition(entries: entries, reader: reader, keeping: nil, generation: 3)
        }
        cancelled.cancel()
        let discarded = await cancelled.value
        assertTrue(discarded.lanes.isEmpty && discarded.generation == 3, "A cancelled reload lays nothing out")
        let laidOut = await store.todayEdition(entries: entries, reader: reader, keeping: nil, generation: 4)
        assertEqual(laidOut.storyIDs, ["c1"], "An uncancelled reload lays the page out")

        // Stores run in order (F7): an older edition whose store is slow does not land after a newer one.
        func edition(_ id: String) -> TodayEdition {
            var made = TodayEdition.make(
                entries: [.article(makeArticle(id: id, title: id, pubDate: referenceNow))],
                plan: TodayEditionPlan(lanes: []))
            made.isAssigned = true
            return made
        }
        let slowOlder = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            await store.storeTodayEdition(edition("older"), reader: reader)
        }
        await store.storeTodayEdition(edition("newer"), reader: reader, after: slowOlder).value
        let kept = try await db.storedTodayEdition().map { try JSONDecoder().decode(TodayStoredEdition.self, from: $0) }
        assertEqual(
            kept?.lanes.flatMap { $0.stories.map(\.id) }, ["newer"], "The newer edition is the one kept")
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
}
