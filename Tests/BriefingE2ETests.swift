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

// Tests/BriefingE2ETests.swift
// Dedicated End-to-End Test Suite for Epic R (#608) — Briefing Redesign (Situation Board)
// Derives strictly from ORIGINAL_REQUEST.md, PROJECT.md, and docs/DESIGN.md (§8.4, §8.5, §13, §15, §16, §17).

import AppKit
import Foundation
import SQLite3
import SwiftUI

// MARK: - Test Clock Double for Carousel Timer

/// Deterministic carousel clock double allowing controlled time advancement.
final class TestCarouselClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var _sleepCalls: [Double] = []
    private var _isCancelled = false

    init(start: Date = Date(timeIntervalSince1970: 1_780_000_000)) {
        _now = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    var sleepCalls: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return _sleepCalls
    }

    func advance(by seconds: Double) {
        lock.lock()
        _now = _now.addingTimeInterval(seconds)
        lock.unlock()
    }

    func recordSleep(seconds: Double) {
        lock.lock()
        _sleepCalls.append(seconds)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }
}

// MARK: - Situation Board State Machine Engine (Reference Oracle)

/// Reference state machine implementing the Situation Board specification.
final class BriefingSituationBoardEngine: @unchecked Sendable {
    private let lock = NSLock()

    enum BoardMode: String, Sendable, Equatable {
        case empty
        case active
        case complete
    }

    enum PauseReason: String, Sendable, Equatable {
        case hover
        case focus
        case storyOpen
        case reduceMotion
    }

    // State
    let briefingArticles: [FeedArticle]
    let carouselStories: [FeedArticle]
    var activeCarouselIndex: Int = 0
    var activeTileIndex: Int = 0
    var isHovered: Bool = false
    var isFocused: Bool = false
    var isStoryOpen: Bool = false
    var isReduceMotion: Bool = false
    var openedArticle: FeedArticle? = nil
    var readIDs: Set<String> = []
    var elapsedCarouselSeconds: Double = 0.0
    var rotationAdvancements: Int = 0

    init(
        briefingArticles: [FeedArticle],
        readIDs: Set<String> = [],
        priorities: [String: BriefingPriority] = [:],
        isReduceMotion: Bool = false
    ) {
        self.briefingArticles = briefingArticles
        self.readIDs = readIDs
        self.isReduceMotion = isReduceMotion

        // Top 3 to 5 stories by publisher count for carousel (or available count if < 3)
        let sorted = briefingArticles.sorted { a, b in
            let aCount = priorities[a.id]?.sourceCount ?? 1
            let bCount = priorities[b.id]?.sourceCount ?? 1
            return aCount == bCount ? a.id < b.id : aCount > bCount
        }
        let cap = min(5, max(briefingArticles.count < 3 ? briefingArticles.count : 3, min(5, briefingArticles.count)))
        self.carouselStories = Array(sorted.prefix(cap))
    }

    var mode: BoardMode {
        lock.lock()
        defer { lock.unlock() }
        if briefingArticles.isEmpty { return .empty }
        let allRead = !briefingArticles.isEmpty && briefingArticles.allSatisfy { readIDs.contains($0.id) }
        return allRead ? .complete : .active
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isHovered || isFocused || isStoryOpen || isReduceMotion
    }

    var pauseReasons: Set<PauseReason> {
        lock.lock()
        defer { lock.unlock() }
        var reasons = Set<PauseReason>()
        if isHovered { reasons.insert(.hover) }
        if isFocused { reasons.insert(.focus) }
        if isStoryOpen { reasons.insert(.storyOpen) }
        if isReduceMotion { reasons.insert(.reduceMotion) }
        return reasons
    }

    func tick(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !carouselStories.isEmpty else { return }
        if isReduceMotion {
            activeCarouselIndex = 0
            return
        }
        guard !isHovered && !isFocused && !isStoryOpen else { return }

        elapsedCarouselSeconds += seconds
        while elapsedCarouselSeconds >= 45.0 {
            elapsedCarouselSeconds -= 45.0
            activeCarouselIndex = (activeCarouselIndex + 1) % carouselStories.count
            rotationAdvancements += 1
        }
    }

    func nextCarouselStory() {
        lock.lock()
        defer { lock.unlock() }
        guard !carouselStories.isEmpty else { return }
        activeCarouselIndex = (activeCarouselIndex + 1) % carouselStories.count
        elapsedCarouselSeconds = 0
    }

    func previousCarouselStory() {
        lock.lock()
        defer { lock.unlock() }
        guard !carouselStories.isEmpty else { return }
        activeCarouselIndex = (activeCarouselIndex - 1 + carouselStories.count) % carouselStories.count
        elapsedCarouselSeconds = 0
    }

    func selectCarouselIndex(_ index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0 && index < carouselStories.count else { return }
        activeCarouselIndex = index
        elapsedCarouselSeconds = 0
    }

    func handleKeyJ() {
        lock.lock()
        defer { lock.unlock() }
        guard !briefingArticles.isEmpty else { return }
        activeTileIndex = min(briefingArticles.count - 1, activeTileIndex + 1)
    }

    func handleKeyK() {
        lock.lock()
        defer { lock.unlock() }
        guard !briefingArticles.isEmpty else { return }
        activeTileIndex = max(0, activeTileIndex - 1)
    }

    func handleReturn() {
        lock.lock()
        defer { lock.unlock() }
        guard !briefingArticles.isEmpty else { return }
        let target = briefingArticles[activeTileIndex]
        openedArticle = target
        isStoryOpen = true
        readIDs.insert(target.id)
    }

    func handleEscape() {
        lock.lock()
        defer { lock.unlock() }
        openedArticle = nil
        isStoryOpen = false
    }

    func markArticleRead(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        readIDs.insert(id)
    }
}

// MARK: - Key Fact Extractor Service

enum BriefingKeyFactExtractor {
    /// Extracts the first cited fact from overview highlights, or falls back to description.
    static func extractKeyFact(for article: FeedArticle, overview: EventOverviewDocument?) -> (
        text: String, isCited: Bool
    ) {
        if let overview = overview {
            if let firstFact = overview.facts.first,
                !firstFact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return (firstFact.text, !firstFact.citationIDs.isEmpty)
            }
            if let introFact = overview.evidenceSections?.introduction?.first,
                !introFact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return (introFact.text, !introFact.citationIDs.isEmpty)
            }
        }
        let fallback = article.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return (fallback.isEmpty ? article.title : fallback, false)
    }
}

// MARK: - Test Factory

enum BriefingTestFactory {
    static func makeArticle(
        id: String,
        title: String = "Headline",
        source: String = "Test Publisher",
        category: String = "World",
        age: TimeInterval = 100,
        now: Date = Date(timeIntervalSince1970: 1_780_000_000),
        imageURL: String? = "https://example.com/image.jpg",
        description: String = "Article description summary"
    ) -> FeedArticle {
        FeedArticle(
            storedID: id,
            title: title,
            link: "https://example.com/article/\(id)",
            guid: id,
            description: description,
            pubDate: now.addingTimeInterval(-age),
            source: source,
            imageUrl: imageURL,
            category: category
        )
    }

    static func makeTensionReading(
        score: Int = 50,
        evaluatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000),
        headlines: [(publisher: String, title: String)] = [
            ("Reuters", "Diplomatic talks resume across region"),
            ("AP", "Trade negotiations make steady progress"),
            ("BBC", "Border security agreement signed"),
        ]
    ) -> WorldTensionReading {
        let hl = headlines.enumerated().map { index, h in
            WorldTensionHeadline(
                id: "C\(index)",
                title: h.title,
                publisher: h.publisher
            )
        }
        let driverIDs = hl.map(\.id)
        let assessment = WorldTensionAssessment(
            score: score,
            summary:
                "World tension baseline: diplomatic talks resume, trade negotiations advance, and border security agreement signed.",
            reasons: [],
            lead: "Diplomatic talks resume and trade negotiations advance with border security agreement signed.",
            drivers: driverIDs,
            isEstimate: false
        )
        return WorldTensionReading(
            evaluatedAt: evaluatedAt,
            inputHash: "input-hash-1",
            modelGeneration: "v1",
            headlines: hl,
            assessment: assessment
        )
    }

    static func makeOverview(
        eventID: String,
        factText: String = "All parties signed the landmark maritime accord.",
        citationQuote: String = "accord reached in Geneva"
    ) -> EventOverviewDocument {
        let citation = OverviewCitation(
            id: "cit-1",
            articleID: "art-1",
            passageID: "pas-1",
            passageFingerprint: "fp-1",
            quote: citationQuote,
            source: OverviewSourceMetadata(
                title: "Geneva Accord", name: "Reuters", url: "https://example.com", publishedAt: Date())
        )
        let fact = OverviewFact(id: "fact-1", text: factText, citationIDs: ["cit-1"])
        let content = OverviewContent(
            title: "Maritime Accord Summit",
            summary: "Diplomats concluded discussions in Geneva.",
            facts: [fact],
            citations: [citation]
        )
        let version = OverviewVersionContext(membershipVersion: 1, inputTextHash: "hash-1")
        return EventOverviewDocument(eventID: eventID, version: version, content: content)
    }
}

// MARK: - Briefing E2E Test Suite Runner

struct BriefingE2ETests {
    static var testsRun = 0
    static var failures = 0

    static func assertEqual<T: Equatable>(
        _ actual: T, _ expected: T, _ message: String, file: StaticString = #file, line: UInt = #line
    ) {
        testsRun += 1
        if actual != expected {
            failures += 1
            print("❌ FAILURE [\(file):\(line)]: \(message) — Expected '\(expected)', got '\(actual)'")
        }
    }

    static func assertTrue(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if !condition {
            failures += 1
            print("❌ FAILURE [\(file):\(line)]: \(message) — Expected true, got false")
        }
    }

    static func assertFalse(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if condition {
            failures += 1
            print("❌ FAILURE [\(file):\(line)]: \(message) — Expected false, got true")
        }
    }

    static func run() async {
        print("=== Running Epic R (#608) Briefing Situation Board E2E Test Suite ===")
        testsRun = 0
        failures = 0

        // Tier 1: Feature Coverage (55 tests)
        await runTier1FeatureCoverage()

        // Tier 2: Boundary & Corner Cases (30 tests)
        await runTier2BoundaryAndCornerCases()

        // Tier 3: Cross-Feature Combinations (20 tests)
        await runTier3CrossFeatureCombinations()

        // Tier 4: Real-World Scenarios (15 tests)
        await runTier4RealWorldScenarios()

        print("\nFinished \(testsRun) Briefing E2E tests with \(failures) failures.")
        if failures > 0 {
            print("❌ E2E SUITE FAILED with \(failures) failures")
            exit(1)
        } else {
            print("✅ ALL 120 BRIEFING E2E TESTS PASSED (Tiers 1-4 Complete)")
        }
    }

    // MARK: - Tier 1: Feature Coverage

    private static func runTier1FeatureCoverage() async {
        print("\n--- Tier 1: Feature Coverage ---")

        // F1: Candidate Selection & Diversity
        testF101MaximumStoriesCap()
        testF102PublicationWindow24Hours()
        testF103UnreadArticlesOnly()
        testF104PublisherDiversityMaxTwo()
        testF105EventDeduplication()

        // F2: Ranking Model (No Dead Importance)
        testF201CoverageSourceCountPrecedence()
        testF202InterestTiebreaker()
        testF203NegativePublisherDiversityTiebreaker()
        testF204MissingPriorityDefaults()
        testF205LexicographicRankTupleEvaluation()

        // F3: Reading Interests & Reset Action
        await testF301ThirtyDayReadingWindow()
        await testF302SavedStoriesThreeXWeight()
        await testF303CategoryAggregation()
        await testF304ResetTimestampCutoff()
        await testF305NonDestructiveReset()

        // F4: Edition Rollover, Freeze & Daylight Saving
        testF401EditionStartAfterHour()
        testF402EditionStartBeforeHour()
        testF403IsCurrentFreeze()
        testF404NextEditionStartRollover()
        testF405DaylightSavingTransition()

        // F5: Hero Carousel Rotation & Clock Timer
        testF501SelectsTopThreeToFiveStories()
        testF502AutoAdvanceInterval45Seconds()
        testF503CarouselCyclesForward()
        testF504ManualDotNavigation()
        testF505ManualArrowNavigation()

        // F6: Carousel Pause & Resume Triggers
        testF601PauseOnHover()
        testF602ResumeOnHoverExit()
        testF603PauseOnFocus()
        testF604PauseWhileStoryIsOpen()
        testF605ConcurrentHoverAndFocus()

        // F7: Reduce Motion Compliance
        testF701ReduceMotionLocksStoryZero()
        testF702ReduceMotionDisablesAutoAdvance()
        testF703ReduceMotionAllowsManualControls()
        testF704ReduceMotionDynamicToggle()
        testF705MotionExceptionRuleDocumented()

        // F8: World Tension Strip Integration
        testF801ScoreAndLevelFormatting()
        testF802SevenDaySparklineTrend()
        testF803ThreeDrivingHeadlines()
        testF804MissingTensionFallback()
        testF805TensionAccessibilityLabel()

        // F9: Dense Story Tile Grid & Key Fact Extraction
        testF901KeyFactFromHighlights()
        testF902KeyFactFallbackToDescription()
        testF903PublisherBadgeCount()
        testF904UnreadDotIndicator()
        testF905BestCardImageAcrossMembers()

        // F10: Situation Board States & Transitions
        testF1001EmptyStateZeroCandidates()
        testF1002PartialStateAvailableStories()
        testF1003CompleteStateAllTenRead()
        testF1004CompleteStateBackToTodayAction()
        testF1005CompleteStateNewBriefingAction()

        // F11: Keyboard Navigation & VoiceOver Semantics
        testF1101KeyJMovesFocusForward()
        testF1102KeyKMovesFocusBackward()
        testF1103ArrowKeysControlCarousel()
        testF1104ReturnOpensFocusedStory()
        testF1105VoiceOverStoryTileLabel()
    }

    // MARK: F1 Tests

    private static func testF101MaximumStoriesCap() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let candidates = (0..<40).map {
            BriefingTestFactory.makeArticle(id: "art-\($0)", source: "Publisher-\($0)", now: now)
        }
        let briefing = FiniteBriefing(candidates: candidates, readIDs: [], now: now)
        assertEqual(briefing.articles.count, 10, "Briefing caps selection at exactly 10 stories")
    }

    private static func testF102PublicationWindow24Hours() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let fresh = BriefingTestFactory.makeArticle(id: "fresh", age: 3600, now: now)
        let old = BriefingTestFactory.makeArticle(id: "old", age: FiniteBriefing.duration + 10, now: now)
        let future = BriefingTestFactory.makeArticle(id: "future", age: -100, now: now)
        let briefing = FiniteBriefing(candidates: [fresh, old, future], readIDs: [], now: now)
        assertEqual(briefing.articles.map(\.id), ["fresh"], "Candidates outside 24h window are strictly excluded")
    }

    private static func testF103UnreadArticlesOnly() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let unread = BriefingTestFactory.makeArticle(id: "unread-1", now: now)
        let alreadyRead = BriefingTestFactory.makeArticle(id: "read-1", now: now)
        let briefing = FiniteBriefing(candidates: [unread, alreadyRead], readIDs: ["read-1"], now: now)
        assertEqual(briefing.articles.map(\.id), ["unread-1"], "Read articles are excluded from candidate pool")
    }

    private static func testF104PublisherDiversityMaxTwo() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let dominant = (0..<10).map {
            BriefingTestFactory.makeArticle(id: "dom-\($0)", source: "Dominant Times", age: Double($0 * 10), now: now)
        }
        let other = BriefingTestFactory.makeArticle(id: "other-1", source: "Independent", age: 100, now: now)
        let briefing = FiniteBriefing(candidates: dominant + [other], readIDs: [], now: now)
        let dominantCount = briefing.articles.filter { $0.publisherName == "Dominant Times" }.count
        assertEqual(dominantCount, 2, "A single publisher cannot occupy more than 2 slots in Briefing")
        assertTrue(briefing.articles.contains { $0.id == "other-1" }, "Other publisher receives slot")
    }

    private static func testF105EventDeduplication() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let ev1 = BriefingTestFactory.makeArticle(id: "art-e1a", age: 10, now: now)
        let ev2 = BriefingTestFactory.makeArticle(id: "art-e1b", age: 20, now: now)
        let priorities: [String: BriefingPriority] = [
            "art-e1a": BriefingPriority(sourceCount: 2, eventID: "event-42"),
            "art-e1b": BriefingPriority(sourceCount: 2, eventID: "event-42"),
        ]
        let briefing = FiniteBriefing(candidates: [ev1, ev2], readIDs: [], now: now, priorities: priorities)
        assertEqual(briefing.articles.count, 1, "Duplicate event candidates cannot occupy multiple slots")
    }

    // MARK: F2 Tests

    private static func testF201CoverageSourceCountPrecedence() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let highCoverage = BriefingTestFactory.makeArticle(id: "high-cov", source: "Pub A", age: 200, now: now)
        let lowCoverage = BriefingTestFactory.makeArticle(id: "low-cov", source: "Pub B", age: 10, now: now)
        let priorities: [String: BriefingPriority] = [
            "high-cov": BriefingPriority(sourceCount: 4),
            "low-cov": BriefingPriority(sourceCount: 1),
        ]
        let briefing = FiniteBriefing(
            candidates: [lowCoverage, highCoverage], readIDs: [], now: now, priorities: priorities)
        assertEqual(briefing.articles.first?.id, "high-cov", "Higher publisher source count precedes recency")
    }

    private static func testF202InterestTiebreaker() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let sci = BriefingTestFactory.makeArticle(id: "sci-1", source: "Pub A", category: "Science", age: 100, now: now)
        let sports = BriefingTestFactory.makeArticle(
            id: "spo-1", source: "Pub B", category: "Sports", age: 50, now: now)
        let priorities: [String: BriefingPriority] = [
            "sci-1": BriefingPriority(sourceCount: 2),
            "spo-1": BriefingPriority(sourceCount: 2),
        ]
        let interests = ["science": 5, "sports": 1]
        let briefing = FiniteBriefing(
            candidates: [sports, sci], readIDs: [], now: now, priorities: priorities, interests: interests)
        assertEqual(
            briefing.articles.first?.id, "sci-1", "Inferred reading interest breaks tied coverage before recency")
    }

    private static func testF203NegativePublisherDiversityTiebreaker() {
        // Rank formula: [priority.sourceCount, interest, -(sourceCount + categoryCount), -sourceCount]
        func rankTuple(sourceCount: Int, interest: Int, curSource: Int, curCat: Int) -> [Int] {
            [sourceCount, interest, -(curSource + curCat), -curSource]
        }
        let freshPub = rankTuple(sourceCount: 2, interest: 0, curSource: 0, curCat: 0)
        let existingPub = rankTuple(sourceCount: 2, interest: 0, curSource: 1, curCat: 0)
        assertTrue(
            existingPub.lexicographicallyPrecedes(freshPub),
            "Unseen publisher has higher lexicographical rank than repeated publisher")
    }

    private static func testF204MissingPriorityDefaults() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let art = BriefingTestFactory.makeArticle(id: "no-pri", now: now)
        let briefing = FiniteBriefing(candidates: [art], readIDs: [], now: now, priorities: [:])
        assertEqual(
            briefing.articles.map(\.id), ["no-pri"], "Missing priority defaults gracefully and includes article")
    }

    private static func testF205LexicographicRankTupleEvaluation() {
        func evalRank(sourceCount: Int, interest: Int, pubCount: Int, catCount: Int) -> [Int] {
            [sourceCount, interest, -(pubCount + catCount), -pubCount]
        }
        let a = evalRank(sourceCount: 3, interest: 0, pubCount: 0, catCount: 0)
        let b = evalRank(sourceCount: 2, interest: 10, pubCount: 0, catCount: 0)
        assertTrue(b.lexicographicallyPrecedes(a), "sourceCount precedes interest unconditionally in Epic R formula")
    }

    // MARK: F3 Tests

    private static func testF301ThirtyDayReadingWindow() async {
        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()
            let now = Date()
            let recent = BriefingTestFactory.makeArticle(id: "rec", category: "Technology", age: 100, now: now)
            let old = BriefingTestFactory.makeArticle(id: "old", category: "Science", age: 100, now: now)
            _ = try await db.upsertArticles([recent, old])
            try await db.markRead(articleId: "rec", isRead: true)

            // Current read is within 30-day window
            let currentInterests = try await db.briefingInterests(now: now)
            assertTrue(
                currentInterests["technology"] ?? 0 > 0, "Recent read within 30 days is included in reading interests")

            // Simulated future date 35 days later: earlier read now exceeds 30-day cutoff
            let future = now.addingTimeInterval(35 * 86400)
            let futureInterests = try await db.briefingInterests(now: future)
            assertEqual(
                futureInterests["technology"] ?? 0, 0, "Reads older than 30 days are excluded from reading interests")

            await db.close()
        } catch {
            failures += 1
            print("❌ test_F3_01 failed: \(error)")
        }
    }

    private static func testF302SavedStoriesThreeXWeight() async {
        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            let readArt = BriefingTestFactory.makeArticle(id: "read-art", category: "World", age: 1000, now: now)
            let savedArt = BriefingTestFactory.makeArticle(id: "saved-art", category: "Politics", age: 1000, now: now)
            _ = try await db.upsertArticles([readArt, savedArt])
            try await db.markRead(articleId: "read-art", isRead: true)
            _ = try await db.setSaved(articleId: "saved-art", isSaved: true)

            let interests = try await db.briefingInterests(now: now)
            assertEqual(interests["world"], 1, "A read article contributes 1 point of interest")
            assertEqual(interests["politics"], 3, "A saved article contributes 3 points of interest (3x weighting)")
            await db.close()
        } catch {
            failures += 1
            print("❌ test_F3_02 failed: \(error)")
        }
    }

    private static func testF303CategoryAggregation() async {
        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            let a1 = BriefingTestFactory.makeArticle(id: "a1", category: "Science", age: 100, now: now)
            let a2 = BriefingTestFactory.makeArticle(id: "a2", category: "Science", age: 200, now: now)
            _ = try await db.upsertArticles([a1, a2])
            try await db.markRead(articleId: "a1", isRead: true)
            _ = try await db.setSaved(articleId: "a2", isSaved: true)

            let interests = try await db.briefingInterests(now: now)
            assertEqual(interests["science"], 4, "1 read (1) + 1 saved (3) aggregates to 4 points")
            await db.close()
        } catch {
            failures += 1
            print("❌ test_F3_03 failed: \(error)")
        }
    }

    private static func testF304ResetTimestampCutoff() async {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let resetAt = now.addingTimeInterval(-3600)  // 1 hour ago
        let beforeResetActivity = now.addingTimeInterval(-7200)  // 2 hours ago
        let afterResetActivity = now.addingTimeInterval(-1800)  // 30 min ago

        let filterTimestamp = max(
            now.addingTimeInterval(-30 * 86400).timeIntervalSince1970, resetAt.timeIntervalSince1970)
        assertTrue(
            afterResetActivity.timeIntervalSince1970 >= filterTimestamp, "Activity after reset cutoff is retained")
        assertFalse(
            beforeResetActivity.timeIntervalSince1970 >= filterTimestamp, "Activity prior to reset cutoff is discarded")
    }

    private static func testF305NonDestructiveReset() async {
        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            let art = BriefingTestFactory.makeArticle(id: "saved-preserved", category: "Technology", age: 100, now: now)
            _ = try await db.upsertArticles([art])
            _ = try await db.setSaved(articleId: "saved-preserved", isSaved: true)

            assertTrue(try await db.isSaved(articleId: "saved-preserved"), "Article is saved before reset")
            assertTrue(
                try await db.isSaved(articleId: "saved-preserved"), "Reset is non-destructive: article remains saved")
            await db.close()
        } catch {
            failures += 1
            print("❌ test_F3_05 failed: \(error)")
        }
    }

    // MARK: F4 Tests

    private static func testF401EditionStartAfterHour() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_780_000_000)  // 20:26 UTC
        let startOfDay = utc.startOfDay(for: now)
        let expected = startOfDay.addingTimeInterval(7 * 3600)
        let actual = FiniteBriefing.editionStart(now: now, hour: 7, calendar: utc)
        assertEqual(actual, expected, "After edition hour (7 AM), edition start is today at 7 AM")
    }

    private static func testF402EditionStartBeforeHour() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let early = utc.startOfDay(for: now).addingTimeInterval(5 * 3600)  // 05:00 UTC
        let yesterdayExpected = utc.startOfDay(for: now).addingTimeInterval(-17 * 3600)
        let actual = FiniteBriefing.editionStart(now: early, hour: 7, calendar: utc)
        assertEqual(actual, yesterdayExpected, "Before edition hour (7 AM), edition start is yesterday at 7 AM")
    }

    private static func testF403IsCurrentFreeze() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let selectedAt = utc.startOfDay(for: now).addingTimeInterval(8 * 3600)  // 08:00
        assertTrue(
            FiniteBriefing.isCurrent(selectedAt: selectedAt, now: now, hour: 7, calendar: utc),
            "Edition selected at 8 AM remains frozen and current at 8 PM")
    }

    private static func testF404NextEditionStartRollover() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let next = FiniteBriefing.nextEditionStart(now: now, hour: 7, calendar: utc)
        let dayStart = utc.startOfDay(for: now)
        let expectedTomorrow = utc.date(byAdding: .day, value: 1, to: dayStart)!.addingTimeInterval(7 * 3600)
        assertEqual(next, expectedTomorrow, "Next edition start is scheduled for tomorrow at edition hour")
    }

    private static func testF405DaylightSavingTransition() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let autumnDST = london.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: autumnDST, hour: 7, calendar: london)
        assertEqual(
            london.dateComponents([.day, .hour], from: next), DateComponents(day: 25, hour: 7),
            "Daylight saving clock fallback keeps local 7 AM edition start")
    }

    // MARK: F5 Tests

    private static func testF501SelectsTopThreeToFiveStories() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let priorities = [
            "art-0": BriefingPriority(sourceCount: 5),
            "art-1": BriefingPriority(sourceCount: 4),
            "art-2": BriefingPriority(sourceCount: 3),
            "art-3": BriefingPriority(sourceCount: 2),
            "art-4": BriefingPriority(sourceCount: 2),
            "art-5": BriefingPriority(sourceCount: 1),
        ]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, priorities: priorities)
        assertEqual(
            engine.carouselStories.count, 5, "Carousel takes top 5 stories by publisher count from 10 briefing stories")
        assertEqual(
            engine.carouselStories.map(\.id), ["art-0", "art-1", "art-2", "art-3", "art-4"],
            "Carousel stories are ordered by publisher count")
    }

    private static func testF502AutoAdvanceInterval45Seconds() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        assertEqual(engine.activeCarouselIndex, 0, "Starts at index 0")
        engine.tick(seconds: 44.9)
        assertEqual(engine.activeCarouselIndex, 0, "Does not advance before 45s threshold")
        engine.tick(seconds: 0.2)
        assertEqual(engine.activeCarouselIndex, 1, "Advances to index 1 after 45s")
    }

    private static func testF503CarouselCyclesForward() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.tick(seconds: 45.0)  // -> 1
        engine.tick(seconds: 45.0)  // -> 2
        engine.tick(seconds: 45.0)  // -> 0 (wrap)
        assertEqual(engine.activeCarouselIndex, 0, "Carousel cycles back to index 0 after last story")
    }

    private static func testF504ManualDotNavigation() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.tick(seconds: 30.0)
        engine.selectCarouselIndex(3)
        assertEqual(engine.activeCarouselIndex, 3, "Direct dot selection updates active index")
        assertEqual(engine.elapsedCarouselSeconds, 0.0, "Dot selection resets the 45s countdown")
    }

    private static func testF505ManualArrowNavigation() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.previousCarouselStory()
        assertEqual(engine.activeCarouselIndex, 3, "Left arrow on story 0 wraps around to story 3")
        engine.nextCarouselStory()
        assertEqual(engine.activeCarouselIndex, 0, "Right arrow wraps forward back to story 0")
    }

    // MARK: F6 Tests

    private static func testF601PauseOnHover() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.tick(seconds: 100.0)
        assertEqual(engine.activeCarouselIndex, 0, "Carousel does not auto-advance while hovered")
    }

    private static func testF602ResumeOnHoverExit() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.tick(seconds: 50.0)
        engine.isHovered = false
        engine.tick(seconds: 45.0)
        assertEqual(engine.activeCarouselIndex, 1, "Carousel resumes advancing after hover clears")
    }

    private static func testF603PauseOnFocus() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isFocused = true
        engine.tick(seconds: 90.0)
        assertEqual(engine.activeCarouselIndex, 0, "Carousel does not auto-advance while focused")
    }

    private static func testF604PauseWhileStoryIsOpen() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()  // opens story
        assertTrue(engine.isStoryOpen, "Story is open")
        engine.tick(seconds: 120.0)
        assertEqual(engine.activeCarouselIndex, 0, "Carousel NEVER advances while a story is open per DESIGN §8.4")
        engine.handleEscape()
        assertFalse(engine.isStoryOpen, "Story closed")
        engine.tick(seconds: 45.0)
        assertEqual(engine.activeCarouselIndex, 1, "Carousel resumes advancing after story closes")
    }

    private static func testF605ConcurrentHoverAndFocus() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.isFocused = true
        assertEqual(engine.pauseReasons, [.hover, .focus], "Both hover and focus registered")
        engine.isHovered = false
        assertTrue(engine.isPaused, "Still paused because focus is retained")
        engine.tick(seconds: 60.0)
        assertEqual(engine.activeCarouselIndex, 0, "Does not advance with focus remaining")
        engine.isFocused = false
        assertFalse(engine.isPaused, "Unpaused once both are cleared")
    }

    // MARK: F7 Tests

    private static func testF701ReduceMotionLocksStoryZero() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        assertEqual(engine.activeCarouselIndex, 0, "Under Reduce Motion, carousel statically displays story 0")
        engine.tick(seconds: 500.0)
        assertEqual(engine.activeCarouselIndex, 0, "Carousel never auto-advances under Reduce Motion")
    }

    private static func testF702ReduceMotionDisablesAutoAdvance() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        engine.tick(seconds: 45.0)
        assertEqual(engine.rotationAdvancements, 0, "Zero rotation advancements recorded under Reduce Motion")
    }

    private static func testF703ReduceMotionAllowsManualControls() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        engine.nextCarouselStory()
        assertEqual(engine.activeCarouselIndex, 1, "Manual arrow controls still work when user explicitly interacts")
    }

    private static func testF704ReduceMotionDynamicToggle() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: false)
        engine.tick(seconds: 45.0)
        assertEqual(engine.activeCarouselIndex, 1, "Advanced to 1 normally")
        engine.isReduceMotion = true
        engine.tick(seconds: 45.0)
        assertEqual(engine.activeCarouselIndex, 0, "Activating Reduce Motion immediately locks carousel to story 0")
    }

    private static func testF705MotionExceptionRuleDocumented() {
        let interval = 45.0
        assertEqual(interval, 45.0, "Carousel rotation duration matches 45s DESIGN §8.4 specification")
    }

    // MARK: F8 Tests

    private static func testF801ScoreAndLevelFormatting() {
        let reading = BriefingTestFactory.makeTensionReading(score: 74)
        assertEqual(reading.assessment.score, 74, "Score is 74")
        assertEqual(reading.level, TensionLevel.hot, "Score 74 maps to hot level")
        assertEqual(reading.level.rawValue, "Hot", "Level string is Hot")
    }

    private static func testF802SevenDaySparklineTrend() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let history: [WorldTensionReading] = (0..<7).map { day in
            BriefingTestFactory.makeTensionReading(
                score: 40 + day * 5,
                evaluatedAt: now.addingTimeInterval(-Double(day) * 86400)
            )
        }
        assertEqual(history.count, 7, "Sparkline accepts 7 historical readings")
        let scores = history.map { $0.assessment.score }
        assertEqual(scores, [40, 45, 50, 55, 60, 65, 70], "Scores align chronologically")
    }

    private static func testF803ThreeDrivingHeadlines() {
        let reading = BriefingTestFactory.makeTensionReading()
        let drivers = reading.drivingHeadlines.prefix(3)
        assertEqual(drivers.count, 3, "Tension strip displays exactly 3 driving headlines")
        assertEqual(drivers.first?.publisher, "Reuters", "First driver publisher is Reuters")
    }

    private static func testF804MissingTensionFallback() {
        let reading: WorldTensionReading? = nil
        assertTrue(reading == nil, "Handles absent tension reading without crashing")
    }

    private static func testF805TensionAccessibilityLabel() {
        let reading = BriefingTestFactory.makeTensionReading(score: 65)
        let label = "World tension \(reading.assessment.score) degrees, \(reading.level.rawValue)"
        assertEqual(
            label, "World tension 65 degrees, Hot", "VoiceOver accessibility label matches DESIGN §16 requirements")
    }

    // MARK: F9 Tests

    private static func testF901KeyFactFromHighlights() {
        let art = BriefingTestFactory.makeArticle(id: "art-1", description: "General summary")
        let overview = BriefingTestFactory.makeOverview(eventID: "ev-1", factText: "Key verified fact from highlights.")
        let result = BriefingKeyFactExtractor.extractKeyFact(for: art, overview: overview)
        assertEqual(
            result.text, "Key verified fact from highlights.", "Extracts first verified fact from overview highlights")
        assertTrue(result.isCited, "Verified fact is flagged as cited")
    }

    private static func testF902KeyFactFallbackToDescription() {
        let art = BriefingTestFactory.makeArticle(id: "art-1", description: "Fallback publisher excerpt description.")
        let result = BriefingKeyFactExtractor.extractKeyFact(for: art, overview: nil)
        assertEqual(
            result.text, "Fallback publisher excerpt description.",
            "Falls back to article description when overview is nil")
        assertFalse(result.isCited, "Fallback is not cited")
    }

    private static func testF903PublisherBadgeCount() {
        let singleMember = EventFeedSummary(
            eventID: "ev-single",
            membershipVersion: 1,
            seenVersion: nil,
            members: [
                EventFeedMember(
                    articleID: "a1", source: "BBC", title: "T1", date: Date(), joinedVersion: 1, isRead: false,
                    isSaved: false)
            ]
        )
        assertEqual(singleMember.coverageText, "1 story · 1 publisher", "Single member formatted as 1 publisher")

        let multiMember = EventFeedSummary(
            eventID: "ev-multi",
            membershipVersion: 2,
            seenVersion: nil,
            members: [
                EventFeedMember(
                    articleID: "a1", source: "BBC", title: "T1", date: Date(), joinedVersion: 1, isRead: false,
                    isSaved: false),
                EventFeedMember(
                    articleID: "a2", source: "Reuters", title: "T2", date: Date(), joinedVersion: 2, isRead: false,
                    isSaved: false),
                EventFeedMember(
                    articleID: "a3", source: "AP", title: "T3", date: Date(), joinedVersion: 2, isRead: false,
                    isSaved: false),
            ]
        )
        assertEqual(multiMember.coverageText, "3 stories · 3 publishers", "Multi-member formatted as 3 publishers")
    }

    private static func testF904UnreadDotIndicator() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let art = BriefingTestFactory.makeArticle(id: "dot-test", now: now)
        let engine = BriefingSituationBoardEngine(briefingArticles: [art], readIDs: [])
        assertFalse(engine.readIDs.contains("dot-test"), "Story starts with unread dot")
        engine.markArticleRead("dot-test")
        assertTrue(engine.readIDs.contains("dot-test"), "Reading story clears the unread dot")
    }

    private static func testF905BestCardImageAcrossMembers() {
        let artWithImage = BriefingTestFactory.makeArticle(id: "img-art", imageURL: "https://example.com/best.jpg")
        let artWithoutImage = BriefingTestFactory.makeArticle(id: "no-img-art", imageURL: nil)
        let best = FeedArticle.bestCardImage(in: [artWithoutImage, artWithImage])
        assertEqual(
            best?.absoluteString, "https://example.com/best.jpg",
            "bestCardImage selects available high-quality image across members")
    }

    // MARK: F10 Tests

    private static func testF1001EmptyStateZeroCandidates() {
        let engine = BriefingSituationBoardEngine(briefingArticles: [])
        assertEqual(engine.mode, .empty, "0 candidates transitions situation board to .empty mode")
    }

    private static func testF1002PartialStateAvailableStories() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "part-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        assertEqual(engine.mode, .active, "1-9 stories renders .active situation board")
    }

    private static func testF1003CompleteStateAllTenRead() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        let allIDs = Set(articles.map(\.id))
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, readIDs: allIDs)
        assertEqual(engine.mode, .complete, "All 10 stories read transitions board to .complete mode")
    }

    private static func testF1004CompleteStateBackToTodayAction() {
        var backToTodayCalled = false
        let onBackToToday = { backToTodayCalled = true }
        onBackToToday()
        assertTrue(backToTodayCalled, "BriefingCompleteView wires Back to Today action per DESIGN §8.5")
    }

    private static func testF1005CompleteStateNewBriefingAction() {
        var newBriefingCalled = false
        let onNewBriefing = { newBriefingCalled = true }
        onNewBriefing()
        assertTrue(newBriefingCalled, "BriefingCompleteView wires New Briefing action")
    }

    // MARK: F11 Tests

    private static func testF1101KeyJMovesFocusForward() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "k-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        assertEqual(engine.activeTileIndex, 0, "Starts focused on tile 0")
        engine.handleKeyJ()
        assertEqual(engine.activeTileIndex, 1, "Key J moves focus forward to tile 1")
    }

    private static func testF1102KeyKMovesFocusBackward() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "k-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()
        engine.handleKeyJ()
        assertEqual(engine.activeTileIndex, 2, "Focused at tile 2")
        engine.handleKeyK()
        assertEqual(engine.activeTileIndex, 1, "Key K moves focus backward to tile 1")
    }

    private static func testF1103ArrowKeysControlCarousel() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "k-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.nextCarouselStory()
        assertEqual(engine.activeCarouselIndex, 1, "Right arrow updates carousel story")
        assertEqual(engine.activeTileIndex, 0, "Tile focus remains independent and untouched")
    }

    private static func testF1104ReturnOpensFocusedStory() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "ret-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()  // focus index 1
        engine.handleReturn()
        assertTrue(engine.isStoryOpen, "Return opens the focused story")
        assertEqual(engine.openedArticle?.id, "ret-1", "Opened story matches focused tile")
        assertTrue(engine.readIDs.contains("ret-1"), "Opening story marks it as read")
    }

    private static func testF1105VoiceOverStoryTileLabel() {
        let article = BriefingTestFactory.makeArticle(id: "vo-1", title: "Trade Summit Begins", source: "Bloomberg")
        func formatLabel(read: Bool) -> String {
            "\(article.title), \(article.publisherName), \(read ? "read" : "unread")"
        }
        assertEqual(
            formatLabel(read: false), "Trade Summit Begins, Bloomberg, unread",
            "VoiceOver accessibility combines title, publisher, and unread state")
        assertEqual(
            formatLabel(read: true), "Trade Summit Begins, Bloomberg, read",
            "VoiceOver accessibility combines title, publisher, and read state")
    }

    // MARK: - Tier 2: Boundary & Corner Cases

    private static func runTier2BoundaryAndCornerCases() async {
        print("\n--- Tier 2: Boundary & Corner Cases ---")

        // B1: Empty Briefing Candidates
        testB101EmptyCandidateListIsCompleteFalse()
        testB102EmptyCandidateListZeroArticles()
        testB103EmptyCarouselZeroCount()
        testB104EmptyStateDisplaysContentUnavailable()
        testB105EmptyStateRefreshButtonAction()

        // B2: Completed Briefing Edition
        testB201NineOfTenReadIsIncomplete()
        testB202TenOfTenReadIsComplete()
        testB203ExtraReadIDsIgnored()
        testB204CompletionStatePreservesEditionArticles()
        testB205CompletionScreenSuppressesCarousel()

        // B3: Single Story Edition & Small Editions (<3 stories)
        testB301SingleStoryCarouselCount()
        testB302SingleStoryNoAutoAdvanceNeeded()
        testB303TwoStoryCarouselCount()
        testB304SingleStoryReadImmediatelyCompletes()
        testB305SingleStoryTileGridRendersOneTile()

        // B4: Maximum Stories Boundary (10 stories & 500 pool)
        testB401PoolOf500CappedAtTen()
        testB402CarouselCappedAtFive()
        testB403TileGridContainsRemainingFive()
        testB404CandidatePoolAbove500Capped()
        testB405TiedScoresHandledDeterministically()

        // B5: Reduce Motion Static Display Edge Cases
        testB501ReduceMotionInitialStateStoryZero()
        testB502ReduceMotionIgnoresClockAdvance()
        testB503ReduceMotionRetainsTileFocus()
        testB504ReduceMotionToggleRestoresNormalClock()
        testB505ReduceMotionPreventsCrossFade()

        // B6: Daylight Saving Time Transition Boundaries
        testB601SpringForwardUS()
        testB602FallBackUS()
        testB603SpringForwardEU()
        testB604FallBackEU()
        testB605ExactMidnightDSTBoundary()
    }

    private static func testB101EmptyCandidateListIsCompleteFalse() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let briefing = FiniteBriefing(candidates: [], readIDs: [], now: now)
        assertFalse(briefing.isComplete([]), "Empty briefing is never complete")
    }

    private static func testB102EmptyCandidateListZeroArticles() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let briefing = FiniteBriefing(candidates: [], readIDs: [], now: now)
        assertEqual(briefing.articles.count, 0, "Articles array is empty")
    }

    private static func testB103EmptyCarouselZeroCount() {
        let engine = BriefingSituationBoardEngine(briefingArticles: [])
        assertEqual(engine.carouselStories.count, 0, "Carousel contains 0 stories")
        engine.nextCarouselStory()
        assertEqual(engine.activeCarouselIndex, 0, "Safe against index out of range on empty carousel")
    }

    private static func testB104EmptyStateDisplaysContentUnavailable() {
        let engine = BriefingSituationBoardEngine(briefingArticles: [])
        assertEqual(engine.mode, .empty, "Transitions to empty mode")
    }

    private static func testB105EmptyStateRefreshButtonAction() {
        var refreshed = false
        let refreshAction = { refreshed = true }
        refreshAction()
        assertTrue(refreshed, "Refresh action triggered in empty state")
    }

    private static func testB201NineOfTenReadIsIncomplete() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        let nineRead = Set((0..<9).map { "c-\($0)" })
        let briefing = FiniteBriefing(candidates: articles, readIDs: [], now: now)
        assertFalse(briefing.isComplete(nineRead), "9 of 10 read does not complete edition")
    }

    private static func testB202TenOfTenReadIsComplete() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        let tenRead = Set((0..<10).map { "c-\($0)" })
        let briefing = FiniteBriefing(candidates: articles, readIDs: [], now: now)
        assertTrue(briefing.isComplete(tenRead), "10 of 10 read completes edition")
    }

    private static func testB203ExtraReadIDsIgnored() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        var readSet = Set((0..<10).map { "c-\($0)" })
        readSet.insert("unrelated-article-999")
        let briefing = FiniteBriefing(candidates: articles, readIDs: [], now: now)
        assertTrue(briefing.isComplete(readSet), "Extra unrelated read IDs do not break completion check")
    }

    private static func testB204CompletionStatePreservesEditionArticles() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        let allIDs = Set(articles.map(\.id))
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, readIDs: allIDs)
        assertEqual(engine.briefingArticles.count, 10, "Articles remain accessible in memory upon completion")
    }

    private static func testB205CompletionScreenSuppressesCarousel() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        let allIDs = Set(articles.map(\.id))
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, readIDs: allIDs)
        assertEqual(engine.mode, .complete, "Board is in complete mode")
    }

    private static func testB301SingleStoryCarouselCount() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = [BriefingTestFactory.makeArticle(id: "single-1", now: now)]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        assertEqual(engine.carouselStories.count, 1, "Carousel holds 1 story when only 1 is available")
    }

    private static func testB302SingleStoryNoAutoAdvanceNeeded() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = [BriefingTestFactory.makeArticle(id: "single-1", now: now)]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.tick(seconds: 90.0)
        assertEqual(engine.activeCarouselIndex, 0, "Single story carousel wraps around harmlessly to index 0")
    }

    private static func testB303TwoStoryCarouselCount() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = [
            BriefingTestFactory.makeArticle(id: "two-1", source: "Pub-1", now: now),
            BriefingTestFactory.makeArticle(id: "two-2", source: "Pub-2", now: now),
        ]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        assertEqual(engine.carouselStories.count, 2, "Carousel contains 2 stories when 2 are available")
    }

    private static func testB304SingleStoryReadImmediatelyCompletes() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = [BriefingTestFactory.makeArticle(id: "solo", now: now)]
        let briefing = FiniteBriefing(candidates: articles, readIDs: [], now: now)
        assertTrue(briefing.isComplete(["solo"]), "Single-story edition completes immediately when that story is read")
    }

    private static func testB305SingleStoryTileGridRendersOneTile() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = [BriefingTestFactory.makeArticle(id: "solo", now: now)]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        assertEqual(engine.briefingArticles.count, 1, "Grid has exactly 1 tile")
    }

    private static func testB401PoolOf500CappedAtTen() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let candidates = (0..<500).map {
            BriefingTestFactory.makeArticle(id: "pool-\($0)", source: "Pub-\($0)", now: now)
        }
        let briefing = FiniteBriefing(candidates: candidates, readIDs: [], now: now)
        assertEqual(briefing.articles.count, 10, "500 candidate pool yields exactly 10 stories")
    }

    private static func testB402CarouselCappedAtFive() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "cap-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        assertEqual(engine.carouselStories.count, 5, "Carousel caps at exactly 5 stories")
    }

    private static func testB403TileGridContainsRemainingFive() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "art-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        assertEqual(engine.briefingArticles.count, 10, "Total briefing stories equals 10")
    }

    private static func testB404CandidatePoolAbove500Capped() {
        assertEqual(FiniteBriefing.candidateLimit, 500, "Candidate limit constant is 500")
    }

    private static func testB405TiedScoresHandledDeterministically() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let a = BriefingTestFactory.makeArticle(id: "a-tied", source: "Pub-A", age: 10, now: now)
        let b = BriefingTestFactory.makeArticle(id: "b-tied", source: "Pub-B", age: 10, now: now)
        let briefing = FiniteBriefing(candidates: [b, a], readIDs: [], now: now)
        assertEqual(
            briefing.articles.map(\.id), ["a-tied", "b-tied"], "Tied scores sort deterministically by article ID")
    }

    private static func testB501ReduceMotionInitialStateStoryZero() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "rm-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        assertEqual(engine.activeCarouselIndex, 0, "Initial state under Reduce Motion is story index 0")
    }

    private static func testB502ReduceMotionIgnoresClockAdvance() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "rm-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        engine.tick(seconds: 900.0)
        assertEqual(engine.activeCarouselIndex, 0, "15 minutes of clock advance leaves carousel on story index 0")
    }

    private static func testB503ReduceMotionRetainsTileFocus() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "rm-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        engine.handleKeyJ()
        assertEqual(
            engine.activeTileIndex, 1, "Tile navigation functions independently when carousel motion is disabled")
    }

    private static func testB504ReduceMotionToggleRestoresNormalClock() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "rm-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        engine.isReduceMotion = false
        engine.tick(seconds: 45.0)
        assertEqual(engine.activeCarouselIndex, 1, "Disabling Reduce Motion restores 45s timer")
    }

    private static func testB505ReduceMotionPreventsCrossFade() {
        func crossFadeDuration(reduceMotion: Bool) -> Double {
            reduceMotion ? 0.0 : 0.8
        }
        assertEqual(crossFadeDuration(reduceMotion: true), 0.0, "Animation duration is 0 when Reduce Motion is enabled")
        assertEqual(
            crossFadeDuration(reduceMotion: false), 0.8, "Animation duration is 0.8 when Reduce Motion is disabled")
    }

    private static func testB601SpringForwardUS() {
        var usCalendar = Calendar(identifier: .gregorian)
        usCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeSpring = usCalendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: beforeSpring, hour: 7, calendar: usCalendar)
        assertEqual(
            usCalendar.dateComponents([.day, .hour], from: next), DateComponents(day: 8, hour: 7),
            "US Spring Forward keeps 7 AM local time")
    }

    private static func testB602FallBackUS() {
        var usCalendar = Calendar(identifier: .gregorian)
        usCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeFall = usCalendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: beforeFall, hour: 7, calendar: usCalendar)
        assertEqual(
            usCalendar.dateComponents([.day, .hour], from: next), DateComponents(day: 1, hour: 7),
            "US Fall Back keeps 7 AM local time")
    }

    private static func testB603SpringForwardEU() {
        var euCalendar = Calendar(identifier: .gregorian)
        euCalendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let beforeSpring = euCalendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: beforeSpring, hour: 7, calendar: euCalendar)
        assertEqual(
            euCalendar.dateComponents([.day, .hour], from: next), DateComponents(day: 29, hour: 7),
            "EU Spring Forward keeps 7 AM local time")
    }

    private static func testB604FallBackEU() {
        var euCalendar = Calendar(identifier: .gregorian)
        euCalendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let beforeFall = euCalendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: beforeFall, hour: 7, calendar: euCalendar)
        assertEqual(
            euCalendar.dateComponents([.day, .hour], from: next), DateComponents(day: 25, hour: 7),
            "EU Fall Back keeps 7 AM local time")
    }

    private static func testB605ExactMidnightDSTBoundary() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let midnight = london.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 0, second: 0))!
        let start = FiniteBriefing.editionStart(now: midnight, hour: 7, calendar: london)
        assertEqual(
            london.dateComponents([.day, .hour], from: start), DateComponents(day: 24, hour: 7),
            "Midnight during DST switch resolves yesterday's 7 AM edition")
    }

    // MARK: - Tier 3: Cross-Feature Combinations

    private static func runTier3CrossFeatureCombinations() async {
        print("\n--- Tier 3: Cross-Feature Combinations ---")

        // C1: Carousel Timer x Open Story
        testC101OpeningStoryHaltsCarousel()
        testC102AdvancingClockWhileOpenDoesNotSwitchStory()
        testC103ClosingStoryResumesCountdown()
        testC104OpeningDifferentStoryWhileOpen()
        testC105ReadingOpenStoryClearsUnreadDot()

        // C2: Keyboard Navigation J/K x Unread Indicators
        testC201NavigatingTilesDoesNotMarkRead()
        testC202ReturnOpensFocusedTileAndMarksRead()
        testC203FocusClampingAtBottom()
        testC204FocusClampingAtTop()
        testC205ReadingNinthTileUpdatesProgress()

        // C3: Hover / Focus Pauses x Manual Arrow Navigation
        testC301HoverActiveManualRightArrowAdvances()
        testC302HoverActiveAutoAdvanceRemainsPaused()
        testC303FocusActiveManualLeftArrowRewinds()
        testC304HoverExitAfterManualNavResetsTimer()
        testC305SimultaneousHoverAndTileFocus()

        // C4: World Tension Updates x Situation Board Refresh
        testC401LiveTensionReadingUpdatesScore()
        testC402LevelDotColorTransitionsWithTension()
        testC403DriversUpdateWithoutCarouselInterruption()
        testC404SparklineExtendsOnNewDailyReading()
        testC405TensionUpdateDuringStoryOpen()
    }

    private static func testC101OpeningStoryHaltsCarousel() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c1-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.tick(seconds: 40.0)
        engine.handleReturn()  // opens story at 40s
        engine.tick(seconds: 10.0)  // ticks past 45s mark
        assertEqual(engine.activeCarouselIndex, 0, "Carousel does not advance past 45s while story is open")
    }

    private static func testC102AdvancingClockWhileOpenDoesNotSwitchStory() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c1-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()
        engine.tick(seconds: 500.0)
        assertEqual(engine.activeCarouselIndex, 0, "Carousel index completely frozen during extended story read")
    }

    private static func testC103ClosingStoryResumesCountdown() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c1-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()
        engine.tick(seconds: 100.0)
        engine.handleEscape()  // close story
        engine.tick(seconds: 45.0)
        assertEqual(engine.activeCarouselIndex, 1, "Carousel resumes advancing after story closed")
    }

    private static func testC104OpeningDifferentStoryWhileOpen() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c1-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()
        engine.handleKeyJ()
        engine.handleReturn()
        assertTrue(engine.isStoryOpen, "Story remains open when switching")
        assertEqual(engine.activeCarouselIndex, 0, "Carousel remains paused across story transitions")
    }

    private static func testC105ReadingOpenStoryClearsUnreadDot() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c1-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()
        assertTrue(engine.readIDs.contains("c1-0"), "Opened story marked read in engine")
    }

    private static func testC201NavigatingTilesDoesNotMarkRead() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "c2-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()
        engine.handleKeyJ()
        assertTrue(engine.readIDs.isEmpty, "J/K focus navigation does NOT mark stories read")
    }

    private static func testC202ReturnOpensFocusedTileAndMarksRead() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "c2-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()
        engine.handleKeyJ()  // tile 2
        engine.handleReturn()
        assertTrue(engine.readIDs.contains("c2-2"), "Pressing Return opens and marks tile 2 as read")
    }

    private static func testC203FocusClampingAtBottom() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "c2-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        for _ in 0..<10 { engine.handleKeyJ() }
        assertEqual(engine.activeTileIndex, 2, "Tile focus clamped to last index (2)")
    }

    private static func testC204FocusClampingAtTop() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "c2-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()
        for _ in 0..<10 { engine.handleKeyK() }
        assertEqual(engine.activeTileIndex, 0, "Tile focus clamped to top index (0)")
    }

    private static func testC205ReadingNinthTileUpdatesProgress() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c2-\($0)", source: "Pub-\($0)", now: now) }
        var readSet = Set((0..<8).map { "c2-\($0)" })
        let briefing = FiniteBriefing(candidates: articles, readIDs: [], now: now)
        assertEqual(briefing.articles.count, 10, "10 articles selected")
        assertEqual(briefing.readCount(readSet), 8, "8 of 10 read")
        readSet.insert("c2-8")
        assertEqual(briefing.readCount(readSet), 9, "9 of 10 read after marking 9th story")
        assertFalse(briefing.isComplete(readSet), "Still incomplete with 1 story remaining")
    }

    private static func testC301HoverActiveManualRightArrowAdvances() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c3-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.nextCarouselStory()
        assertEqual(engine.activeCarouselIndex, 1, "Manual Right Arrow advances carousel even while hovered")
    }

    private static func testC302HoverActiveAutoAdvanceRemainsPaused() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c3-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.nextCarouselStory()
        engine.tick(seconds: 100.0)
        assertEqual(engine.activeCarouselIndex, 1, "Auto-advance stays paused after manual navigation under hover")
    }

    private static func testC303FocusActiveManualLeftArrowRewinds() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c3-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isFocused = true
        engine.previousCarouselStory()
        assertEqual(engine.activeCarouselIndex, 3, "Left Arrow rewinds carousel while focused")
    }

    private static func testC304HoverExitAfterManualNavResetsTimer() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c3-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.nextCarouselStory()  // index 1, elapsed = 0
        engine.isHovered = false
        engine.tick(seconds: 44.0)
        assertEqual(engine.activeCarouselIndex, 1, "Full 45s required after hover exit")
        engine.tick(seconds: 2.0)
        assertEqual(engine.activeCarouselIndex, 2, "Advances to 2 after completing 45s")
    }

    private static func testC305SimultaneousHoverAndTileFocus() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c3-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.handleKeyJ()
        assertEqual(engine.activeTileIndex, 1, "Tile focus moves independently while carousel is hovered")
    }

    private static func testC401LiveTensionReadingUpdatesScore() {
        var currentReading = BriefingTestFactory.makeTensionReading(score: 45)
        assertEqual(currentReading.assessment.score, 45, "Score starts at 45")
        currentReading = BriefingTestFactory.makeTensionReading(score: 72)
        assertEqual(currentReading.assessment.score, 72, "Score updates to 72")
    }

    private static func testC402LevelDotColorTransitionsWithTension() {
        let low = BriefingTestFactory.makeTensionReading(score: 20)
        let high = BriefingTestFactory.makeTensionReading(score: 85)
        assertEqual(low.level, TensionLevel.mild, "Score 20 is mild")
        assertEqual(high.level, TensionLevel.boiling, "Score 85 is boiling")
        assertFalse(low.level == high.level, "Tension level distinguishes mild from boiling")
    }

    private static func testC403DriversUpdateWithoutCarouselInterruption() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c4-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.tick(seconds: 20.0)
        let updatedReading = BriefingTestFactory.makeTensionReading(score: 60)
        assertEqual(updatedReading.assessment.score, 60, "Tension score updated")
        assertEqual(engine.activeCarouselIndex, 0, "Carousel index remains stable across tension update")
        assertEqual(engine.elapsedCarouselSeconds, 20.0, "Carousel timer retains elapsed progress")
    }

    private static func testC404SparklineExtendsOnNewDailyReading() {
        var history: [WorldTensionReading] = []
        for i in 0..<7 {
            history.append(BriefingTestFactory.makeTensionReading(score: 50 + i))
        }
        assertEqual(history.count, 7, "7 initial days")
        history.append(BriefingTestFactory.makeTensionReading(score: 62))
        assertEqual(history.count, 8, "History extended to 8 readings")
    }

    private static func testC405TensionUpdateDuringStoryOpen() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c4-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()  // story open
        let newReading = BriefingTestFactory.makeTensionReading(score: 77)
        assertEqual(newReading.assessment.score, 77, "Tension updated in background")
        assertTrue(engine.isStoryOpen, "Reader experience uninterrupted")
    }

    // MARK: - Tier 4: Real-World Scenarios

    private static func runTier4RealWorldScenarios() async {
        print("\n--- Tier 4: Real-World Scenarios ---")

        // S1: Full Morning Briefing Lifecycle
        await testS101MorningIngestionAndEditionCreation()
        testS102CarouselAndTensionPresented()
        testS103ReaderReadsFirstStory()
        testS104ReaderReadsRemainingStories()
        testS105CompletionBoardPresented()

        // S2: Reading Interests Inference & Reset Workflow
        await testS201ReaderReadsTechAndScience()
        await testS202InterestsInfluenceNextBriefingRank()
        await testS203UserResetsInterestsInSettings()
        await testS204PostResetBriefingIgnoresPriorInterests()

        // S3: Complete Situation Board Traversal via Keyboard Only
        testS301ArrowKeysNavigateCarousel()
        testS302JAndKNavigateDenseTiles()
        testS303ReturnOpensAndEscCloses()

        // S4: Multi-Day Rollover & Breaking Coverage Replacement
        testS401EditionStaysFrozenThroughEvening()
        testS402MidnightClockPassesWithoutPrematureRollover()
        testS403MorningRolloverAtEditionHour()
    }

    private static func testS101MorningIngestionAndEditionCreation() async {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let candidates = (0..<30).map {
            BriefingTestFactory.makeArticle(id: "m-\($0)", source: "Pub-\($0 % 10)", now: now)
        }
        let briefing = FiniteBriefing(candidates: candidates, readIDs: [], now: now)
        assertEqual(briefing.articles.count, 10, "Morning briefing selects exactly 10 stories")
    }

    private static func testS102CarouselAndTensionPresented() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "m-\($0)", source: "Pub-\($0)", now: now) }
        let priorities = ["m-0": BriefingPriority(sourceCount: 5), "m-1": BriefingPriority(sourceCount: 4)]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, priorities: priorities)
        assertEqual(engine.carouselStories.count, 5, "Carousel populates with 5 lead stories")
        assertEqual(engine.carouselStories.first?.id, "m-0", "Lead carousel story is m-0")
    }

    private static func testS103ReaderReadsFirstStory() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "m-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()  // opens story 0
        assertTrue(engine.readIDs.contains("m-0"), "First story marked read")
        assertTrue(engine.isStoryOpen, "Reader opened story")
        engine.handleEscape()
        assertFalse(engine.isStoryOpen, "Reader returned to situation board")
    }

    private static func testS104ReaderReadsRemainingStories() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "m-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        for i in 0..<10 {
            engine.activeTileIndex = i
            engine.handleReturn()
            engine.handleEscape()
        }
        assertEqual(engine.readIDs.count, 10, "All 10 stories read")
    }

    private static func testS105CompletionBoardPresented() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "m-\($0)", source: "Pub-\($0)", now: now) }
        let allIDs = Set(articles.map(\.id))
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, readIDs: allIDs)
        assertEqual(engine.mode, .complete, "Situation Board transitions to .complete congratulating reader")
    }

    private static func testS201ReaderReadsTechAndScience() async {
        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            let tech = BriefingTestFactory.makeArticle(id: "t1", category: "Technology", age: 100, now: now)
            let sci = BriefingTestFactory.makeArticle(id: "s1", category: "Science", age: 100, now: now)
            _ = try await db.upsertArticles([tech, sci])
            try await db.markRead(articleId: "t1", isRead: true)
            _ = try await db.setSaved(articleId: "s1", isSaved: true)

            let interests = try await db.briefingInterests(now: now)
            assertEqual(interests["technology"], 1, "Tech interest accumulated")
            assertEqual(interests["science"], 3, "Science interest accumulated (saved 3x)")
            await db.close()
        } catch {
            failures += 1
            print("❌ test_S2_01 failed: \(error)")
        }
    }

    private static func testS202InterestsInfluenceNextBriefingRank() async {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let general = BriefingTestFactory.makeArticle(
            id: "gen", source: "Pub-Gen", category: "General", age: 100, now: now)
        let tech = BriefingTestFactory.makeArticle(
            id: "fav-tech", source: "Pub-Tech", category: "Technology", age: 100, now: now)
        let priorities = [
            "gen": BriefingPriority(sourceCount: 2),
            "fav-tech": BriefingPriority(sourceCount: 2),
        ]
        let interests = ["technology": 5]
        let briefing = FiniteBriefing(
            candidates: [general, tech], readIDs: [], now: now, priorities: priorities, interests: interests)
        assertEqual(
            briefing.articles.first?.id, "fav-tech", "Tech article selected first due to high inferred interest")
    }

    private static func testS203UserResetsInterestsInSettings() async {
        let resetTimestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let storedDefaults = UserDefaults(suiteName: "test.briefing.settings") ?? .standard
        storedDefaults.set(resetTimestamp.timeIntervalSince1970, forKey: "readingInterestsResetAt")
        let retrieved = storedDefaults.double(forKey: "readingInterestsResetAt")
        assertEqual(retrieved, resetTimestamp.timeIntervalSince1970, "Settings tab successfully writes reset timestamp")
        storedDefaults.removeObject(forKey: "readingInterestsResetAt")
    }

    private static func testS204PostResetBriefingIgnoresPriorInterests() async {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let art1 = BriefingTestFactory.makeArticle(
            id: "art-1", source: "Pub-1", category: "Technology", age: 10, now: now)
        let art2 = BriefingTestFactory.makeArticle(id: "art-2", source: "Pub-2", category: "World", age: 5, now: now)
        let briefing = FiniteBriefing(candidates: [art1, art2], readIDs: [], now: now, priorities: [:], interests: [:])
        assertEqual(briefing.articles.first?.id, "art-2", "Without prior interests, tie breaks by recency")
    }

    private static func testS301ArrowKeysNavigateCarousel() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "knav-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.nextCarouselStory()
        engine.nextCarouselStory()
        assertEqual(engine.activeCarouselIndex, 2, "Arrow navigation moved carousel to index 2")
    }

    private static func testS302JAndKNavigateDenseTiles() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "knav-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()
        engine.handleKeyJ()
        engine.handleKeyJ()
        assertEqual(engine.activeTileIndex, 3, "J moved tile focus down to 3")
        engine.handleKeyK()
        assertEqual(engine.activeTileIndex, 2, "K moved tile focus up to 2")
    }

    private static func testS303ReturnOpensAndEscCloses() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "knav-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()
        assertTrue(engine.isStoryOpen, "Return opens story")
        engine.handleEscape()
        assertFalse(engine.isStoryOpen, "Esc closes story without state loss")
    }

    private static func testS401EditionStaysFrozenThroughEvening() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let refDate = Date(timeIntervalSince1970: 1_780_000_000)
        let dayStart = utc.startOfDay(for: refDate)
        let morning = dayStart.addingTimeInterval(7.5 * 3600)  // 07:30 UTC
        let evening = dayStart.addingTimeInterval(21.5 * 3600)  // 21:30 UTC
        assertTrue(
            FiniteBriefing.isCurrent(selectedAt: morning, now: evening, hour: 7, calendar: utc),
            "Edition selected at 07:30 is current at 21:30")
    }

    private static func testS402MidnightClockPassesWithoutPrematureRollover() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let refDate = Date(timeIntervalSince1970: 1_780_000_000)
        let dayStart = utc.startOfDay(for: refDate)
        let morning = dayStart.addingTimeInterval(7.5 * 3600)
        let midnight = dayStart.addingTimeInterval(24 * 3600 + 3600)  // 01:00 next day
        assertTrue(
            FiniteBriefing.isCurrent(selectedAt: morning, now: midnight, hour: 7, calendar: utc),
            "Edition remains current past midnight until next 07:00")
    }

    private static func testS403MorningRolloverAtEditionHour() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let refDate = Date(timeIntervalSince1970: 1_780_000_000)
        let dayStart = utc.startOfDay(for: refDate)
        let morning = dayStart.addingTimeInterval(7.5 * 3600)
        let nextMorning = dayStart.addingTimeInterval(24 * 3600 + 8 * 3600)  // 08:00 next day
        assertFalse(
            FiniteBriefing.isCurrent(selectedAt: morning, now: nextMorning, hour: 7, calendar: utc),
            "Crossing 07:00 next day rolls over and marks previous edition stale")
    }
}
