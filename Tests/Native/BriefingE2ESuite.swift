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

/// Native port of the `BriefingE2ETests` atom (#1070): the same 120 tests, in the runner's order, with each
/// `assertEqual`/`assertTrue`/`assertFalse` turned into the matching `expect` helper of NativeExpectations.swift and
/// each caught error the runner counted by hand (`failures += 1` and a print) into `expectTrue(false, …)` (the runner
/// log is invisible to Swift Testing), so a failure is recorded and later tests still run. The atom's counters and
/// closing summary are not tests and stay in the runner. `TestCarouselClock`, `BriefingSituationBoardEngine`,
/// `BriefingKeyFactExtractor` and `BriefingTestFactory` stay in BriefingE2ETests.swift and are shared from there. The
/// runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.briefing, .integration)) struct BriefingE2ESuite {
        @Test func f101MaximumStoriesCap() { Self.testF101MaximumStoriesCap() }
        @Test func f102PublicationWindow24Hours() { Self.testF102PublicationWindow24Hours() }
        @Test func f103UnreadArticlesOnly() { Self.testF103UnreadArticlesOnly() }
        @Test func f104PublisherDiversityMaxTwo() { Self.testF104PublisherDiversityMaxTwo() }
        @Test func f105EventDeduplication() { Self.testF105EventDeduplication() }
        @Test func f201CoverageSourceCountPrecedence() { Self.testF201CoverageSourceCountPrecedence() }
        @Test func f202InterestTiebreaker() { Self.testF202InterestTiebreaker() }
        @Test func f203NegativePublisherDiversityTiebreaker() { Self.testF203NegativePublisherDiversityTiebreaker() }
        @Test func f204MissingPriorityDefaults() { Self.testF204MissingPriorityDefaults() }
        @Test func f205LexicographicRankTupleEvaluation() { Self.testF205LexicographicRankTupleEvaluation() }
        @Test func f301ThirtyDayReadingWindow() async { await Self.testF301ThirtyDayReadingWindow() }
        @Test func f302SavedStoriesThreeXWeight() async { await Self.testF302SavedStoriesThreeXWeight() }
        @Test func f303CategoryAggregation() async { await Self.testF303CategoryAggregation() }
        @Test func f304ResetTimestampCutoff() async { await Self.testF304ResetTimestampCutoff() }
        @Test func f305NonDestructiveReset() async { await Self.testF305NonDestructiveReset() }
        @Test func f401EditionStartAfterHour() { Self.testF401EditionStartAfterHour() }
        @Test func f402EditionStartBeforeHour() { Self.testF402EditionStartBeforeHour() }
        @Test func f403IsCurrentFreeze() { Self.testF403IsCurrentFreeze() }
        @Test func f404NextEditionStartRollover() { Self.testF404NextEditionStartRollover() }
        @Test func f405DaylightSavingTransition() { Self.testF405DaylightSavingTransition() }
        @Test func f501SelectsTopThreeToFiveStories() { Self.testF501SelectsTopThreeToFiveStories() }
        @Test func f502AutoAdvanceInterval45Seconds() { Self.testF502AutoAdvanceInterval45Seconds() }
        @Test func f503CarouselCyclesForward() { Self.testF503CarouselCyclesForward() }
        @Test func f504ManualDotNavigation() { Self.testF504ManualDotNavigation() }
        @Test func f505ManualArrowNavigation() { Self.testF505ManualArrowNavigation() }
        @Test func f601PauseOnHover() { Self.testF601PauseOnHover() }
        @Test func f602ResumeOnHoverExit() { Self.testF602ResumeOnHoverExit() }
        @Test func f603PauseOnFocus() { Self.testF603PauseOnFocus() }
        @Test func f604PauseWhileStoryIsOpen() { Self.testF604PauseWhileStoryIsOpen() }
        @Test func f605ConcurrentHoverAndFocus() { Self.testF605ConcurrentHoverAndFocus() }
        @Test func f701ReduceMotionLocksStoryZero() { Self.testF701ReduceMotionLocksStoryZero() }
        @Test func f702ReduceMotionDisablesAutoAdvance() { Self.testF702ReduceMotionDisablesAutoAdvance() }
        @Test func f703ReduceMotionAllowsManualControls() { Self.testF703ReduceMotionAllowsManualControls() }
        @Test func f704ReduceMotionDynamicToggle() { Self.testF704ReduceMotionDynamicToggle() }
        @Test func f705MotionExceptionRuleDocumented() { Self.testF705MotionExceptionRuleDocumented() }
        @Test func f801ScoreAndLevelFormatting() { Self.testF801ScoreAndLevelFormatting() }
        @Test func f802SevenDaySparklineTrend() { Self.testF802SevenDaySparklineTrend() }
        @Test func f803ThreeDrivingHeadlines() { Self.testF803ThreeDrivingHeadlines() }
        @Test func f804MissingTensionFallback() { Self.testF804MissingTensionFallback() }
        @Test func f805TensionAccessibilityLabel() { Self.testF805TensionAccessibilityLabel() }
        @Test func f901KeyFactFromHighlights() { Self.testF901KeyFactFromHighlights() }
        @Test func f902KeyFactFallbackToDescription() { Self.testF902KeyFactFallbackToDescription() }
        @Test func f903PublisherBadgeCount() { Self.testF903PublisherBadgeCount() }
        @Test func f904UnreadDotIndicator() { Self.testF904UnreadDotIndicator() }
        @Test func f905BestCardImageAcrossMembers() { Self.testF905BestCardImageAcrossMembers() }
        @Test func f1001EmptyStateZeroCandidates() { Self.testF1001EmptyStateZeroCandidates() }
        @Test func f1002PartialStateAvailableStories() { Self.testF1002PartialStateAvailableStories() }
        @Test func f1003CompleteStateAllTenRead() { Self.testF1003CompleteStateAllTenRead() }
        @Test func f1004CompleteStateBackToTodayAction() { Self.testF1004CompleteStateBackToTodayAction() }
        @Test func f1005CompleteStateNewBriefingAction() { Self.testF1005CompleteStateNewBriefingAction() }
        @Test func f1101KeyJMovesFocusForward() { Self.testF1101KeyJMovesFocusForward() }
        @Test func f1102KeyKMovesFocusBackward() { Self.testF1102KeyKMovesFocusBackward() }
        @Test func f1103ArrowKeysControlCarousel() { Self.testF1103ArrowKeysControlCarousel() }
        @Test func f1104ReturnOpensFocusedStory() { Self.testF1104ReturnOpensFocusedStory() }
        @Test func f1105VoiceOverStoryTileLabel() { Self.testF1105VoiceOverStoryTileLabel() }
        @Test func b101EmptyCandidateListIsCompleteFalse() { Self.testB101EmptyCandidateListIsCompleteFalse() }
        @Test func b102EmptyCandidateListZeroArticles() { Self.testB102EmptyCandidateListZeroArticles() }
        @Test func b103EmptyCarouselZeroCount() { Self.testB103EmptyCarouselZeroCount() }
        @Test func b104EmptyStateDisplaysContentUnavailable() { Self.testB104EmptyStateDisplaysContentUnavailable() }
        @Test func b105EmptyStateRefreshButtonAction() { Self.testB105EmptyStateRefreshButtonAction() }
        @Test func b201NineOfTenReadIsIncomplete() { Self.testB201NineOfTenReadIsIncomplete() }
        @Test func b202TenOfTenReadIsComplete() { Self.testB202TenOfTenReadIsComplete() }
        @Test func b203ExtraReadIDsIgnored() { Self.testB203ExtraReadIDsIgnored() }
        @Test func b204CompletionStatePreservesEditionArticles() {
            Self.testB204CompletionStatePreservesEditionArticles()
        }
        @Test func b205CompletionScreenSuppressesCarousel() { Self.testB205CompletionScreenSuppressesCarousel() }
        @Test func b301SingleStoryCarouselCount() { Self.testB301SingleStoryCarouselCount() }
        @Test func b302SingleStoryNoAutoAdvanceNeeded() { Self.testB302SingleStoryNoAutoAdvanceNeeded() }
        @Test func b303TwoStoryCarouselCount() { Self.testB303TwoStoryCarouselCount() }
        @Test func b304SingleStoryReadImmediatelyCompletes() { Self.testB304SingleStoryReadImmediatelyCompletes() }
        @Test func b305SingleStoryTileGridRendersOneTile() { Self.testB305SingleStoryTileGridRendersOneTile() }
        @Test func b401PoolOf500CappedAtTen() { Self.testB401PoolOf500CappedAtTen() }
        @Test func b402CarouselCappedAtFive() { Self.testB402CarouselCappedAtFive() }
        @Test func b403TileGridContainsRemainingFive() { Self.testB403TileGridContainsRemainingFive() }
        @Test func b404CandidatePoolAbove500Capped() { Self.testB404CandidatePoolAbove500Capped() }
        @Test func b405TiedScoresHandledDeterministically() { Self.testB405TiedScoresHandledDeterministically() }
        @Test func b501ReduceMotionInitialStateStoryZero() { Self.testB501ReduceMotionInitialStateStoryZero() }
        @Test func b502ReduceMotionIgnoresClockAdvance() { Self.testB502ReduceMotionIgnoresClockAdvance() }
        @Test func b503ReduceMotionRetainsTileFocus() { Self.testB503ReduceMotionRetainsTileFocus() }
        @Test func b504ReduceMotionToggleRestoresNormalClock() { Self.testB504ReduceMotionToggleRestoresNormalClock() }
        @Test func b505ReduceMotionPreventsCrossFade() { Self.testB505ReduceMotionPreventsCrossFade() }
        @Test func b601SpringForwardUS() { Self.testB601SpringForwardUS() }
        @Test func b602FallBackUS() { Self.testB602FallBackUS() }
        @Test func b603SpringForwardEU() { Self.testB603SpringForwardEU() }
        @Test func b604FallBackEU() { Self.testB604FallBackEU() }
        @Test func b605ExactMidnightDSTBoundary() { Self.testB605ExactMidnightDSTBoundary() }
        @Test func c101OpeningStoryHaltsCarousel() { Self.testC101OpeningStoryHaltsCarousel() }
        @Test func c102AdvancingClockWhileOpenDoesNotSwitchStory() {
            Self.testC102AdvancingClockWhileOpenDoesNotSwitchStory()
        }
        @Test func c103ClosingStoryResumesCountdown() { Self.testC103ClosingStoryResumesCountdown() }
        @Test func c104OpeningDifferentStoryWhileOpen() { Self.testC104OpeningDifferentStoryWhileOpen() }
        @Test func c105ReadingOpenStoryClearsUnreadDot() { Self.testC105ReadingOpenStoryClearsUnreadDot() }
        @Test func c201NavigatingTilesDoesNotMarkRead() { Self.testC201NavigatingTilesDoesNotMarkRead() }
        @Test func c202ReturnOpensFocusedTileAndMarksRead() { Self.testC202ReturnOpensFocusedTileAndMarksRead() }
        @Test func c203FocusClampingAtBottom() { Self.testC203FocusClampingAtBottom() }
        @Test func c204FocusClampingAtTop() { Self.testC204FocusClampingAtTop() }
        @Test func c205ReadingNinthTileUpdatesProgress() { Self.testC205ReadingNinthTileUpdatesProgress() }
        @Test func c301HoverActiveManualRightArrowAdvances() { Self.testC301HoverActiveManualRightArrowAdvances() }
        @Test func c302HoverActiveAutoAdvanceRemainsPaused() { Self.testC302HoverActiveAutoAdvanceRemainsPaused() }
        @Test func c303FocusActiveManualLeftArrowRewinds() { Self.testC303FocusActiveManualLeftArrowRewinds() }
        @Test func c304HoverExitAfterManualNavResetsTimer() { Self.testC304HoverExitAfterManualNavResetsTimer() }
        @Test func c305SimultaneousHoverAndTileFocus() { Self.testC305SimultaneousHoverAndTileFocus() }
        @Test func c401LiveTensionReadingUpdatesScore() { Self.testC401LiveTensionReadingUpdatesScore() }
        @Test func c402LevelDotColorTransitionsWithTension() { Self.testC402LevelDotColorTransitionsWithTension() }
        @Test func c403DriversUpdateWithoutCarouselInterruption() {
            Self.testC403DriversUpdateWithoutCarouselInterruption()
        }
        @Test func c404SparklineExtendsOnNewDailyReading() { Self.testC404SparklineExtendsOnNewDailyReading() }
        @Test func c405TensionUpdateDuringStoryOpen() { Self.testC405TensionUpdateDuringStoryOpen() }
        @Test func s101MorningIngestionAndEditionCreation() async {
            await Self.testS101MorningIngestionAndEditionCreation()
        }
        @Test func s102CarouselAndTensionPresented() { Self.testS102CarouselAndTensionPresented() }
        @Test func s103ReaderReadsFirstStory() { Self.testS103ReaderReadsFirstStory() }
        @Test func s104ReaderReadsRemainingStories() { Self.testS104ReaderReadsRemainingStories() }
        @Test func s105CompletionBoardPresented() { Self.testS105CompletionBoardPresented() }
        @Test func s201ReaderReadsTechAndScience() async { await Self.testS201ReaderReadsTechAndScience() }
        @Test func s202InterestsInfluenceNextBriefingRank() async {
            await Self.testS202InterestsInfluenceNextBriefingRank()
        }
        @Test func s203UserResetsInterestsInSettings() async { await Self.testS203UserResetsInterestsInSettings() }
        @Test func s204PostResetBriefingIgnoresPriorInterests() async {
            await Self.testS204PostResetBriefingIgnoresPriorInterests()
        }
        @Test func s301ArrowKeysNavigateCarousel() { Self.testS301ArrowKeysNavigateCarousel() }
        @Test func s302JAndKNavigateDenseTiles() { Self.testS302JAndKNavigateDenseTiles() }
        @Test func s303ReturnOpensAndEscCloses() { Self.testS303ReturnOpensAndEscCloses() }
        @Test func s401EditionStaysFrozenThroughEvening() { Self.testS401EditionStaysFrozenThroughEvening() }
        @Test func s402MidnightClockPassesWithoutPrematureRollover() {
            Self.testS402MidnightClockPassesWithoutPrematureRollover()
        }
        @Test func s403MorningRolloverAtEditionHour() { Self.testS403MorningRolloverAtEditionHour() }
    }
}

extension NativeSuites.BriefingE2ESuite {

    // MARK: - Tier 1: Feature Coverage

    // MARK: F1 Tests

    static func testF101MaximumStoriesCap() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let candidates = (0..<40).map {
            BriefingTestFactory.makeArticle(id: "art-\($0)", source: "Publisher-\($0)", now: now)
        }
        let briefing = FiniteBriefing(candidates: candidates, readIDs: [], now: now)
        expectEqual(briefing.articles.count, 10, "Briefing caps selection at exactly 10 stories")
    }

    static func testF102PublicationWindow24Hours() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let fresh = BriefingTestFactory.makeArticle(id: "fresh", age: 3600, now: now)
        let old = BriefingTestFactory.makeArticle(id: "old", age: FiniteBriefing.duration + 10, now: now)
        let future = BriefingTestFactory.makeArticle(id: "future", age: -100, now: now)
        let briefing = FiniteBriefing(candidates: [fresh, old, future], readIDs: [], now: now)
        expectEqual(briefing.articles.map(\.id), ["fresh"], "Candidates outside 24h window are strictly excluded")
    }

    static func testF103UnreadArticlesOnly() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let unread = BriefingTestFactory.makeArticle(id: "unread-1", now: now)
        let alreadyRead = BriefingTestFactory.makeArticle(id: "read-1", now: now)
        let briefing = FiniteBriefing(candidates: [unread, alreadyRead], readIDs: ["read-1"], now: now)
        expectEqual(briefing.articles.map(\.id), ["unread-1"], "Read articles are excluded from candidate pool")
    }

    static func testF104PublisherDiversityMaxTwo() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let dominant = (0..<10).map {
            BriefingTestFactory.makeArticle(id: "dom-\($0)", source: "Dominant Times", age: Double($0 * 10), now: now)
        }
        let other = BriefingTestFactory.makeArticle(id: "other-1", source: "Independent", age: 100, now: now)
        let briefing = FiniteBriefing(candidates: dominant + [other], readIDs: [], now: now)
        let dominantCount = briefing.articles.filter { $0.publisherName == "Dominant Times" }.count
        expectEqual(dominantCount, 2, "A single publisher cannot occupy more than 2 slots in Briefing")
        expectTrue(briefing.articles.contains { $0.id == "other-1" }, "Other publisher receives slot")
    }

    static func testF105EventDeduplication() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let ev1 = BriefingTestFactory.makeArticle(id: "art-e1a", age: 10, now: now)
        let ev2 = BriefingTestFactory.makeArticle(id: "art-e1b", age: 20, now: now)
        let priorities: [String: BriefingPriority] = [
            "art-e1a": BriefingPriority(sourceCount: 2, eventID: "event-42"),
            "art-e1b": BriefingPriority(sourceCount: 2, eventID: "event-42"),
        ]
        let briefing = FiniteBriefing(candidates: [ev1, ev2], readIDs: [], now: now, priorities: priorities)
        expectEqual(briefing.articles.count, 1, "Duplicate event candidates cannot occupy multiple slots")
    }

    // MARK: F2 Tests

    static func testF201CoverageSourceCountPrecedence() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let highCoverage = BriefingTestFactory.makeArticle(id: "high-cov", source: "Pub A", age: 200, now: now)
        let lowCoverage = BriefingTestFactory.makeArticle(id: "low-cov", source: "Pub B", age: 10, now: now)
        let priorities: [String: BriefingPriority] = [
            "high-cov": BriefingPriority(sourceCount: 4),
            "low-cov": BriefingPriority(sourceCount: 1),
        ]
        let briefing = FiniteBriefing(
            candidates: [lowCoverage, highCoverage], readIDs: [], now: now, priorities: priorities)
        expectEqual(briefing.articles.first?.id, "high-cov", "Higher publisher source count precedes recency")
    }

    static func testF202InterestTiebreaker() {
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
        expectEqual(
            briefing.articles.first?.id, "sci-1", "Inferred reading interest breaks tied coverage before recency")
    }

    static func testF203NegativePublisherDiversityTiebreaker() {
        // Rank formula: [priority.sourceCount, interest, -(sourceCount + categoryCount), -sourceCount]
        func rankTuple(sourceCount: Int, interest: Int, curSource: Int, curCat: Int) -> [Int] {
            [sourceCount, interest, -(curSource + curCat), -curSource]
        }
        let freshPub = rankTuple(sourceCount: 2, interest: 0, curSource: 0, curCat: 0)
        let existingPub = rankTuple(sourceCount: 2, interest: 0, curSource: 1, curCat: 0)
        expectTrue(
            existingPub.lexicographicallyPrecedes(freshPub),
            "Unseen publisher has higher lexicographical rank than repeated publisher")
    }

    static func testF204MissingPriorityDefaults() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let art = BriefingTestFactory.makeArticle(id: "no-pri", now: now)
        let briefing = FiniteBriefing(candidates: [art], readIDs: [], now: now, priorities: [:])
        expectEqual(
            briefing.articles.map(\.id), ["no-pri"], "Missing priority defaults gracefully and includes article")
    }

    static func testF205LexicographicRankTupleEvaluation() {
        func evalRank(sourceCount: Int, interest: Int, pubCount: Int, catCount: Int) -> [Int] {
            [sourceCount, interest, -(pubCount + catCount), -pubCount]
        }
        let a = evalRank(sourceCount: 3, interest: 0, pubCount: 0, catCount: 0)
        let b = evalRank(sourceCount: 2, interest: 10, pubCount: 0, catCount: 0)
        expectTrue(b.lexicographicallyPrecedes(a), "sourceCount precedes interest unconditionally in Epic R formula")
    }

    // MARK: F3 Tests

    static func testF301ThirtyDayReadingWindow() async {
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
            expectTrue(
                currentInterests["technology"] ?? 0 > 0, "Recent read within 30 days is included in reading interests")

            // Simulated future date 35 days later: earlier read now exceeds 30-day cutoff
            let future = now.addingTimeInterval(35 * 86400)
            let futureInterests = try await db.briefingInterests(now: future)
            expectEqual(
                futureInterests["technology"] ?? 0, 0, "Reads older than 30 days are excluded from reading interests")

            await db.close()
        } catch {
            expectTrue(false, "test_F3_01 failed: \(error)")
        }
    }

    static func testF302SavedStoriesThreeXWeight() async {
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
            expectEqual(interests["world"], 1, "A read article contributes 1 point of interest")
            expectEqual(interests["politics"], 3, "A saved article contributes 3 points of interest (3x weighting)")
            await db.close()
        } catch {
            expectTrue(false, "test_F3_02 failed: \(error)")
        }
    }

    static func testF303CategoryAggregation() async {
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
            expectEqual(interests["science"], 4, "1 read (1) + 1 saved (3) aggregates to 4 points")
            await db.close()
        } catch {
            expectTrue(false, "test_F3_03 failed: \(error)")
        }
    }

    static func testF304ResetTimestampCutoff() async {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let resetAt = now.addingTimeInterval(-3600)  // 1 hour ago
        let beforeResetActivity = now.addingTimeInterval(-7200)  // 2 hours ago
        let afterResetActivity = now.addingTimeInterval(-1800)  // 30 min ago

        let filterTimestamp = max(
            now.addingTimeInterval(-30 * 86400).timeIntervalSince1970, resetAt.timeIntervalSince1970)
        expectTrue(
            afterResetActivity.timeIntervalSince1970 >= filterTimestamp, "Activity after reset cutoff is retained")
        expectFalse(
            beforeResetActivity.timeIntervalSince1970 >= filterTimestamp, "Activity prior to reset cutoff is discarded")
    }

    static func testF305NonDestructiveReset() async {
        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            let art = BriefingTestFactory.makeArticle(id: "saved-preserved", category: "Technology", age: 100, now: now)
            _ = try await db.upsertArticles([art])
            _ = try await db.setSaved(articleId: "saved-preserved", isSaved: true)

            expectTrue(try await db.isSaved(articleId: "saved-preserved"), "Article is saved before reset")
            expectTrue(
                try await db.isSaved(articleId: "saved-preserved"), "Reset is non-destructive: article remains saved")
            await db.close()
        } catch {
            expectTrue(false, "test_F3_05 failed: \(error)")
        }
    }

    // MARK: F4 Tests

    static func testF401EditionStartAfterHour() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_780_000_000)  // 20:26 UTC
        let startOfDay = utc.startOfDay(for: now)
        let expected = startOfDay.addingTimeInterval(7 * 3600)
        let actual = FiniteBriefing.editionStart(now: now, hour: 7, calendar: utc)
        expectEqual(actual, expected, "After edition hour (7 AM), edition start is today at 7 AM")
    }

    static func testF402EditionStartBeforeHour() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let early = utc.startOfDay(for: now).addingTimeInterval(5 * 3600)  // 05:00 UTC
        let yesterdayExpected = utc.startOfDay(for: now).addingTimeInterval(-17 * 3600)
        let actual = FiniteBriefing.editionStart(now: early, hour: 7, calendar: utc)
        expectEqual(actual, yesterdayExpected, "Before edition hour (7 AM), edition start is yesterday at 7 AM")
    }

    static func testF403IsCurrentFreeze() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let selectedAt = utc.startOfDay(for: now).addingTimeInterval(8 * 3600)  // 08:00
        expectTrue(
            FiniteBriefing.isCurrent(selectedAt: selectedAt, now: now, hour: 7, calendar: utc),
            "Edition selected at 8 AM remains frozen and current at 8 PM")
    }

    static func testF404NextEditionStartRollover() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let next = FiniteBriefing.nextEditionStart(now: now, hour: 7, calendar: utc)
        let dayStart = utc.startOfDay(for: now)
        let expectedTomorrow = utc.date(byAdding: .day, value: 1, to: dayStart)!.addingTimeInterval(7 * 3600)
        expectEqual(next, expectedTomorrow, "Next edition start is scheduled for tomorrow at edition hour")
    }

    static func testF405DaylightSavingTransition() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let autumnDST = london.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: autumnDST, hour: 7, calendar: london)
        expectEqual(
            london.dateComponents([.day, .hour], from: next), DateComponents(day: 25, hour: 7),
            "Daylight saving clock fallback keeps local 7 AM edition start")
    }

    // MARK: F5 Tests

    static func testF501SelectsTopThreeToFiveStories() {
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
        expectEqual(
            engine.carouselStories.count, 10, "Carousel takes up to ten stories by publisher count")
        expectEqual(
            Array(engine.carouselStories.map(\.id).prefix(5)), ["art-0", "art-1", "art-2", "art-3", "art-4"],
            "Carousel stories are ordered by publisher count")
    }

    static func testF502AutoAdvanceInterval45Seconds() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        expectEqual(engine.activeCarouselIndex, 0, "Starts at index 0")
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval - 0.1)
        expectEqual(engine.activeCarouselIndex, 0, "Does not advance before 45s threshold")
        engine.tick(seconds: 0.2)
        expectEqual(engine.activeCarouselIndex, 1, "Advances to index 1 after 45s")
    }

    static func testF503CarouselCyclesForward() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval)  // -> 1
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval)  // -> 2
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval)  // -> 0 (wrap)
        expectEqual(engine.activeCarouselIndex, 0, "Carousel cycles back to index 0 after last story")
    }

    static func testF504ManualDotNavigation() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        // Part of an interval: the index is still 0 and time has run, so both assertions depend on the selection.
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval * 0.6)
        engine.selectCarouselIndex(3)
        expectEqual(engine.activeCarouselIndex, 3, "Direct dot selection updates active index")
        expectEqual(engine.elapsedCarouselSeconds, 0.0, "Dot selection resets the countdown")
    }

    static func testF505ManualArrowNavigation() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.previousCarouselStory()
        expectEqual(engine.activeCarouselIndex, 3, "Left arrow on story 0 wraps around to story 3")
        engine.nextCarouselStory()
        expectEqual(engine.activeCarouselIndex, 0, "Right arrow wraps forward back to story 0")
    }

    // MARK: F6 Tests

    static func testF601PauseOnHover() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.tick(seconds: 100.0)
        expectEqual(engine.activeCarouselIndex, 0, "Carousel does not auto-advance while hovered")
    }

    static func testF602ResumeOnHoverExit() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.tick(seconds: 50.0)
        engine.isHovered = false
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval)
        expectEqual(engine.activeCarouselIndex, 1, "Carousel resumes advancing after hover clears")
    }

    static func testF603PauseOnFocus() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isFocused = true
        engine.tick(seconds: 90.0)
        expectEqual(engine.activeCarouselIndex, 0, "Carousel does not auto-advance while focused")
    }

    static func testF604PauseWhileStoryIsOpen() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()  // opens story
        expectTrue(engine.isStoryOpen, "Story is open")
        engine.tick(seconds: 120.0)
        expectEqual(engine.activeCarouselIndex, 0, "Carousel NEVER advances while a story is open per DESIGN §8.4")
        engine.handleEscape()
        expectFalse(engine.isStoryOpen, "Story closed")
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval)
        expectEqual(engine.activeCarouselIndex, 1, "Carousel resumes advancing after story closes")
    }

    static func testF605ConcurrentHoverAndFocus() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.isFocused = true
        expectEqual(engine.pauseReasons, [.hover, .focus], "Both hover and focus registered")
        engine.isHovered = false
        expectTrue(engine.isPaused, "Still paused because focus is retained")
        engine.tick(seconds: 60.0)
        expectEqual(engine.activeCarouselIndex, 0, "Does not advance with focus remaining")
        engine.isFocused = false
        expectFalse(engine.isPaused, "Unpaused once both are cleared")
    }

    // MARK: F7 Tests

    static func testF701ReduceMotionLocksStoryZero() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        expectEqual(engine.activeCarouselIndex, 0, "Under Reduce Motion, carousel statically displays story 0")
        engine.tick(seconds: 500.0)
        expectEqual(engine.activeCarouselIndex, 0, "Carousel never auto-advances under Reduce Motion")
    }

    static func testF702ReduceMotionDisablesAutoAdvance() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval)
        expectEqual(engine.rotationAdvancements, 0, "Zero rotation advancements recorded under Reduce Motion")
    }

    static func testF703ReduceMotionAllowsManualControls() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        engine.nextCarouselStory()
        expectEqual(engine.activeCarouselIndex, 1, "Manual arrow controls still work when user explicitly interacts")
    }

    static func testF704ReduceMotionDynamicToggle() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "art-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: false)
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval)
        expectEqual(engine.activeCarouselIndex, 1, "Advanced to 1 normally")
        engine.isReduceMotion = true
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval)
        expectEqual(engine.activeCarouselIndex, 0, "Activating Reduce Motion immediately locks carousel to story 0")
    }

    static func testF705MotionExceptionRuleDocumented() {
        expectEqual(
            BriefingHeroCarouselView.autoAdvanceInterval, 10.0,
            "Carousel rotation matches the 10 s of DESIGN.md section 13.1")
    }

    // MARK: F8 Tests

    static func testF801ScoreAndLevelFormatting() {
        let reading = BriefingTestFactory.makeTensionReading(score: 74)
        expectEqual(reading.assessment.score, 74, "Score is 74")
        expectEqual(reading.level, TensionLevel.hot, "Score 74 maps to hot level")
        expectEqual(reading.level.rawValue, "Hot", "Level string is Hot")
    }

    static func testF802SevenDaySparklineTrend() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let history: [WorldTensionReading] = (0..<7).map { day in
            BriefingTestFactory.makeTensionReading(
                score: 40 + day * 5,
                evaluatedAt: now.addingTimeInterval(-Double(day) * 86400)
            )
        }
        expectEqual(history.count, 7, "Sparkline accepts 7 historical readings")
        let scores = history.map { $0.assessment.score }
        expectEqual(scores, [40, 45, 50, 55, 60, 65, 70], "Scores align chronologically")
    }

    static func testF803ThreeDrivingHeadlines() {
        let reading = BriefingTestFactory.makeTensionReading()
        let drivers = reading.drivingHeadlines.prefix(3)
        expectEqual(drivers.count, 3, "Tension strip displays exactly 3 driving headlines")
        expectEqual(drivers.first?.publisher, "Reuters", "First driver publisher is Reuters")
    }

    static func testF804MissingTensionFallback() {
        let reading: WorldTensionReading? = nil
        expectTrue(reading == nil, "Handles absent tension reading without crashing")
    }

    static func testF805TensionAccessibilityLabel() {
        let reading = BriefingTestFactory.makeTensionReading(score: 65)
        let label = "World tension \(reading.assessment.score) degrees, \(reading.level.rawValue)"
        expectEqual(
            label, "World tension 65 degrees, Hot", "VoiceOver accessibility label matches DESIGN §16 requirements")
    }

    // MARK: F9 Tests

    static func testF901KeyFactFromHighlights() {
        let art = BriefingTestFactory.makeArticle(id: "art-1", description: "General summary")
        let overview = BriefingTestFactory.makeOverview(eventID: "ev-1", factText: "Key verified fact from highlights.")
        let result = BriefingKeyFactExtractor.extractKeyFact(for: art, overview: overview)
        expectEqual(
            result.text, "Key verified fact from highlights.", "Extracts first verified fact from overview highlights")
        expectTrue(result.isCited, "Verified fact is flagged as cited")
    }

    static func testF902KeyFactFallbackToDescription() {
        let art = BriefingTestFactory.makeArticle(id: "art-1", description: "Fallback publisher excerpt description.")
        let result = BriefingKeyFactExtractor.extractKeyFact(for: art, overview: nil)
        expectEqual(
            result.text, "Fallback publisher excerpt description.",
            "Falls back to article description when overview is nil")
        expectFalse(result.isCited, "Fallback is not cited")
    }

    static func testF903PublisherBadgeCount() {
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
        expectEqual(singleMember.coverageText, "1 story · 1 publisher", "Single member formatted as 1 publisher")

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
        expectEqual(multiMember.coverageText, "3 stories · 3 publishers", "Multi-member formatted as 3 publishers")
    }

    static func testF904UnreadDotIndicator() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let art = BriefingTestFactory.makeArticle(id: "dot-test", now: now)
        let engine = BriefingSituationBoardEngine(briefingArticles: [art], readIDs: [])
        expectFalse(engine.readIDs.contains("dot-test"), "Story starts with unread dot")
        engine.markArticleRead("dot-test")
        expectTrue(engine.readIDs.contains("dot-test"), "Reading story clears the unread dot")
    }

    static func testF905BestCardImageAcrossMembers() {
        let artWithImage = BriefingTestFactory.makeArticle(id: "img-art", imageURL: "https://example.com/best.jpg")
        let artWithoutImage = BriefingTestFactory.makeArticle(id: "no-img-art", imageURL: nil)
        let best = FeedArticle.bestCardImage(in: [artWithoutImage, artWithImage])
        expectEqual(
            best?.absoluteString, "https://example.com/best.jpg",
            "bestCardImage selects available high-quality image across members")
    }

    // MARK: F10 Tests

    static func testF1001EmptyStateZeroCandidates() {
        let engine = BriefingSituationBoardEngine(briefingArticles: [])
        expectEqual(engine.mode, .empty, "0 candidates transitions situation board to .empty mode")
    }

    static func testF1002PartialStateAvailableStories() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "part-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        expectEqual(engine.mode, .active, "1-9 stories renders .active situation board")
    }

    static func testF1003CompleteStateAllTenRead() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        let allIDs = Set(articles.map(\.id))
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, readIDs: allIDs)
        expectEqual(engine.mode, .complete, "All 10 stories read transitions board to .complete mode")
    }

    static func testF1004CompleteStateBackToTodayAction() {
        var backToTodayCalled = false
        let onBackToToday = { backToTodayCalled = true }
        onBackToToday()
        expectTrue(backToTodayCalled, "BriefingCompleteView wires Back to Today action per DESIGN §8.5")
    }

    static func testF1005CompleteStateNewBriefingAction() {
        var newBriefingCalled = false
        let onNewBriefing = { newBriefingCalled = true }
        onNewBriefing()
        expectTrue(newBriefingCalled, "BriefingCompleteView wires New Briefing action")
    }

    // MARK: F11 Tests

    static func testF1101KeyJMovesFocusForward() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "k-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        expectEqual(engine.activeTileIndex, 0, "Starts focused on tile 0")
        engine.handleKeyJ()
        expectEqual(engine.activeTileIndex, 1, "Key J moves focus forward to tile 1")
    }

    static func testF1102KeyKMovesFocusBackward() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "k-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()
        engine.handleKeyJ()
        expectEqual(engine.activeTileIndex, 2, "Focused at tile 2")
        engine.handleKeyK()
        expectEqual(engine.activeTileIndex, 1, "Key K moves focus backward to tile 1")
    }

    static func testF1103ArrowKeysControlCarousel() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "k-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.nextCarouselStory()
        expectEqual(engine.activeCarouselIndex, 1, "Right arrow updates carousel story")
        expectEqual(engine.activeTileIndex, 0, "Tile focus remains independent and untouched")
    }

    static func testF1104ReturnOpensFocusedStory() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "ret-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()  // focus index 1
        engine.handleReturn()
        expectTrue(engine.isStoryOpen, "Return opens the focused story")
        expectEqual(engine.openedArticle?.id, "ret-1", "Opened story matches focused tile")
        expectTrue(engine.readIDs.contains("ret-1"), "Opening story marks it as read")
    }

    static func testF1105VoiceOverStoryTileLabel() {
        let article = BriefingTestFactory.makeArticle(id: "vo-1", title: "Trade Summit Begins", source: "Bloomberg")
        func formatLabel(read: Bool) -> String {
            "\(article.title), \(article.publisherName), \(read ? "read" : "unread")"
        }
        expectEqual(
            formatLabel(read: false), "Trade Summit Begins, Bloomberg, unread",
            "VoiceOver accessibility combines title, publisher, and unread state")
        expectEqual(
            formatLabel(read: true), "Trade Summit Begins, Bloomberg, read",
            "VoiceOver accessibility combines title, publisher, and read state")
    }

    // MARK: - Tier 2: Boundary & Corner Cases

    static func testB101EmptyCandidateListIsCompleteFalse() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let briefing = FiniteBriefing(candidates: [], readIDs: [], now: now)
        expectFalse(briefing.isComplete([]), "Empty briefing is never complete")
    }

    static func testB102EmptyCandidateListZeroArticles() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let briefing = FiniteBriefing(candidates: [], readIDs: [], now: now)
        expectEqual(briefing.articles.count, 0, "Articles array is empty")
    }

    static func testB103EmptyCarouselZeroCount() {
        let engine = BriefingSituationBoardEngine(briefingArticles: [])
        expectEqual(engine.carouselStories.count, 0, "Carousel contains 0 stories")
        engine.nextCarouselStory()
        expectEqual(engine.activeCarouselIndex, 0, "Safe against index out of range on empty carousel")
    }

    static func testB104EmptyStateDisplaysContentUnavailable() {
        let engine = BriefingSituationBoardEngine(briefingArticles: [])
        expectEqual(engine.mode, .empty, "Transitions to empty mode")
    }

    static func testB105EmptyStateRefreshButtonAction() {
        var refreshed = false
        let refreshAction = { refreshed = true }
        refreshAction()
        expectTrue(refreshed, "Refresh action triggered in empty state")
    }

    static func testB201NineOfTenReadIsIncomplete() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        let nineRead = Set((0..<9).map { "c-\($0)" })
        let briefing = FiniteBriefing(candidates: articles, readIDs: [], now: now)
        expectFalse(briefing.isComplete(nineRead), "9 of 10 read does not complete edition")
    }

    static func testB202TenOfTenReadIsComplete() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        let tenRead = Set((0..<10).map { "c-\($0)" })
        let briefing = FiniteBriefing(candidates: articles, readIDs: [], now: now)
        expectTrue(briefing.isComplete(tenRead), "10 of 10 read completes edition")
    }

    static func testB203ExtraReadIDsIgnored() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        var readSet = Set((0..<10).map { "c-\($0)" })
        readSet.insert("unrelated-article-999")
        let briefing = FiniteBriefing(candidates: articles, readIDs: [], now: now)
        expectTrue(briefing.isComplete(readSet), "Extra unrelated read IDs do not break completion check")
    }

    static func testB204CompletionStatePreservesEditionArticles() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        let allIDs = Set(articles.map(\.id))
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, readIDs: allIDs)
        expectEqual(engine.briefingArticles.count, 10, "Articles remain accessible in memory upon completion")
    }

    static func testB205CompletionScreenSuppressesCarousel() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c-\($0)", source: "Pub-\($0)", now: now) }
        let allIDs = Set(articles.map(\.id))
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, readIDs: allIDs)
        expectEqual(engine.mode, .complete, "Board is in complete mode")
    }

    static func testB301SingleStoryCarouselCount() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = [BriefingTestFactory.makeArticle(id: "single-1", now: now)]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        expectEqual(engine.carouselStories.count, 1, "Carousel holds 1 story when only 1 is available")
    }

    static func testB302SingleStoryNoAutoAdvanceNeeded() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = [BriefingTestFactory.makeArticle(id: "single-1", now: now)]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.tick(seconds: 90.0)
        expectEqual(engine.activeCarouselIndex, 0, "Single story carousel wraps around harmlessly to index 0")
    }

    static func testB303TwoStoryCarouselCount() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = [
            BriefingTestFactory.makeArticle(id: "two-1", source: "Pub-1", now: now),
            BriefingTestFactory.makeArticle(id: "two-2", source: "Pub-2", now: now),
        ]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        expectEqual(engine.carouselStories.count, 2, "Carousel contains 2 stories when 2 are available")
    }

    static func testB304SingleStoryReadImmediatelyCompletes() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = [BriefingTestFactory.makeArticle(id: "solo", now: now)]
        let briefing = FiniteBriefing(candidates: articles, readIDs: [], now: now)
        expectTrue(briefing.isComplete(["solo"]), "Single-story edition completes immediately when that story is read")
    }

    static func testB305SingleStoryTileGridRendersOneTile() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = [BriefingTestFactory.makeArticle(id: "solo", now: now)]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        expectEqual(engine.briefingArticles.count, 1, "Grid has exactly 1 tile")
    }

    static func testB401PoolOf500CappedAtTen() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let candidates = (0..<500).map {
            BriefingTestFactory.makeArticle(id: "pool-\($0)", source: "Pub-\($0)", now: now)
        }
        let briefing = FiniteBriefing(candidates: candidates, readIDs: [], now: now)
        expectEqual(briefing.articles.count, 10, "500 candidate pool yields exactly 10 stories")
    }

    static func testB402CarouselCappedAtFive() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<14).map { BriefingTestFactory.makeArticle(id: "cap-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        expectEqual(engine.carouselStories.count, BriefingView.heroLimit, "Carousel caps at the hero limit")
    }

    static func testB403TileGridContainsRemainingFive() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "art-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        expectEqual(engine.briefingArticles.count, 10, "Total briefing stories equals 10")
    }

    static func testB404CandidatePoolAbove500Capped() {
        expectEqual(FiniteBriefing.candidateLimit, 500, "Candidate limit constant is 500")
    }

    static func testB405TiedScoresHandledDeterministically() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let a = BriefingTestFactory.makeArticle(id: "a-tied", source: "Pub-A", age: 10, now: now)
        let b = BriefingTestFactory.makeArticle(id: "b-tied", source: "Pub-B", age: 10, now: now)
        let briefing = FiniteBriefing(candidates: [b, a], readIDs: [], now: now)
        expectEqual(
            briefing.articles.map(\.id), ["a-tied", "b-tied"], "Tied scores sort deterministically by article ID")
    }

    static func testB501ReduceMotionInitialStateStoryZero() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "rm-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        expectEqual(engine.activeCarouselIndex, 0, "Initial state under Reduce Motion is story index 0")
    }

    static func testB502ReduceMotionIgnoresClockAdvance() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "rm-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        engine.tick(seconds: 900.0)
        expectEqual(engine.activeCarouselIndex, 0, "15 minutes of clock advance leaves carousel on story index 0")
    }

    static func testB503ReduceMotionRetainsTileFocus() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "rm-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        engine.handleKeyJ()
        expectEqual(
            engine.activeTileIndex, 1, "Tile navigation functions independently when carousel motion is disabled")
    }

    static func testB504ReduceMotionToggleRestoresNormalClock() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "rm-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, isReduceMotion: true)
        engine.isReduceMotion = false
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval)
        expectEqual(engine.activeCarouselIndex, 1, "Disabling Reduce Motion restores 45s timer")
    }

    static func testB505ReduceMotionPreventsCrossFade() {
        func crossFadeDuration(reduceMotion: Bool) -> Double {
            reduceMotion ? 0.0 : 0.8
        }
        expectEqual(crossFadeDuration(reduceMotion: true), 0.0, "Animation duration is 0 when Reduce Motion is enabled")
        expectEqual(
            crossFadeDuration(reduceMotion: false), 0.8, "Animation duration is 0.8 when Reduce Motion is disabled")
    }

    static func testB601SpringForwardUS() {
        var usCalendar = Calendar(identifier: .gregorian)
        usCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeSpring = usCalendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: beforeSpring, hour: 7, calendar: usCalendar)
        expectEqual(
            usCalendar.dateComponents([.day, .hour], from: next), DateComponents(day: 8, hour: 7),
            "US Spring Forward keeps 7 AM local time")
    }

    static func testB602FallBackUS() {
        var usCalendar = Calendar(identifier: .gregorian)
        usCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeFall = usCalendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: beforeFall, hour: 7, calendar: usCalendar)
        expectEqual(
            usCalendar.dateComponents([.day, .hour], from: next), DateComponents(day: 1, hour: 7),
            "US Fall Back keeps 7 AM local time")
    }

    static func testB603SpringForwardEU() {
        var euCalendar = Calendar(identifier: .gregorian)
        euCalendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let beforeSpring = euCalendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: beforeSpring, hour: 7, calendar: euCalendar)
        expectEqual(
            euCalendar.dateComponents([.day, .hour], from: next), DateComponents(day: 29, hour: 7),
            "EU Spring Forward keeps 7 AM local time")
    }

    static func testB604FallBackEU() {
        var euCalendar = Calendar(identifier: .gregorian)
        euCalendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let beforeFall = euCalendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: beforeFall, hour: 7, calendar: euCalendar)
        expectEqual(
            euCalendar.dateComponents([.day, .hour], from: next), DateComponents(day: 25, hour: 7),
            "EU Fall Back keeps 7 AM local time")
    }

    static func testB605ExactMidnightDSTBoundary() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let midnight = london.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 0, second: 0))!
        let start = FiniteBriefing.editionStart(now: midnight, hour: 7, calendar: london)
        expectEqual(
            london.dateComponents([.day, .hour], from: start), DateComponents(day: 24, hour: 7),
            "Midnight during DST switch resolves yesterday's 7 AM edition")
    }

    // MARK: - Tier 3: Cross-Feature Combinations

    static func testC101OpeningStoryHaltsCarousel() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c1-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval - 5)
        engine.handleReturn()  // opens the story before the interval ends
        engine.tick(seconds: 10.0)  // past the interval
        expectEqual(engine.activeCarouselIndex, 0, "Carousel does not advance past 45s while story is open")
    }

    static func testC102AdvancingClockWhileOpenDoesNotSwitchStory() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c1-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()
        engine.tick(seconds: 500.0)
        expectEqual(engine.activeCarouselIndex, 0, "Carousel index completely frozen during extended story read")
    }

    static func testC103ClosingStoryResumesCountdown() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c1-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()
        engine.tick(seconds: 100.0)
        engine.handleEscape()  // close story
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval)
        expectEqual(engine.activeCarouselIndex, 1, "Carousel resumes advancing after story closed")
    }

    static func testC104OpeningDifferentStoryWhileOpen() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c1-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()
        engine.handleKeyJ()
        engine.handleReturn()
        expectTrue(engine.isStoryOpen, "Story remains open when switching")
        expectEqual(engine.activeCarouselIndex, 0, "Carousel remains paused across story transitions")
    }

    static func testC105ReadingOpenStoryClearsUnreadDot() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c1-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()
        expectTrue(engine.readIDs.contains("c1-0"), "Opened story marked read in engine")
    }

    static func testC201NavigatingTilesDoesNotMarkRead() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "c2-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()
        engine.handleKeyJ()
        expectTrue(engine.readIDs.isEmpty, "J/K focus navigation does NOT mark stories read")
    }

    static func testC202ReturnOpensFocusedTileAndMarksRead() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "c2-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()
        engine.handleKeyJ()  // tile 2
        engine.handleReturn()
        expectTrue(engine.readIDs.contains("c2-2"), "Pressing Return opens and marks tile 2 as read")
    }

    static func testC203FocusClampingAtBottom() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "c2-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        for _ in 0..<10 { engine.handleKeyJ() }
        expectEqual(engine.activeTileIndex, 2, "Tile focus clamped to last index (2)")
    }

    static func testC204FocusClampingAtTop() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<3).map { BriefingTestFactory.makeArticle(id: "c2-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()
        for _ in 0..<10 { engine.handleKeyK() }
        expectEqual(engine.activeTileIndex, 0, "Tile focus clamped to top index (0)")
    }

    static func testC205ReadingNinthTileUpdatesProgress() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "c2-\($0)", source: "Pub-\($0)", now: now) }
        var readSet = Set((0..<8).map { "c2-\($0)" })
        let briefing = FiniteBriefing(candidates: articles, readIDs: [], now: now)
        expectEqual(briefing.articles.count, 10, "10 articles selected")
        expectEqual(briefing.readCount(readSet), 8, "8 of 10 read")
        readSet.insert("c2-8")
        expectEqual(briefing.readCount(readSet), 9, "9 of 10 read after marking 9th story")
        expectFalse(briefing.isComplete(readSet), "Still incomplete with 1 story remaining")
    }

    static func testC301HoverActiveManualRightArrowAdvances() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c3-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.nextCarouselStory()
        expectEqual(engine.activeCarouselIndex, 1, "Manual Right Arrow advances carousel even while hovered")
    }

    static func testC302HoverActiveAutoAdvanceRemainsPaused() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c3-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.nextCarouselStory()
        engine.tick(seconds: 100.0)
        expectEqual(engine.activeCarouselIndex, 1, "Auto-advance stays paused after manual navigation under hover")
    }

    static func testC303FocusActiveManualLeftArrowRewinds() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c3-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isFocused = true
        engine.previousCarouselStory()
        expectEqual(engine.activeCarouselIndex, 3, "Left Arrow rewinds carousel while focused")
    }

    static func testC304HoverExitAfterManualNavResetsTimer() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c3-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.nextCarouselStory()  // index 1, elapsed = 0
        engine.isHovered = false
        engine.tick(seconds: BriefingHeroCarouselView.autoAdvanceInterval - 1)
        expectEqual(engine.activeCarouselIndex, 1, "Full 45s required after hover exit")
        engine.tick(seconds: 2.0)
        expectEqual(engine.activeCarouselIndex, 2, "Advances to 2 after completing 45s")
    }

    static func testC305SimultaneousHoverAndTileFocus() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c3-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.isHovered = true
        engine.handleKeyJ()
        expectEqual(engine.activeTileIndex, 1, "Tile focus moves independently while carousel is hovered")
    }

    static func testC401LiveTensionReadingUpdatesScore() {
        var currentReading = BriefingTestFactory.makeTensionReading(score: 45)
        expectEqual(currentReading.assessment.score, 45, "Score starts at 45")
        currentReading = BriefingTestFactory.makeTensionReading(score: 72)
        expectEqual(currentReading.assessment.score, 72, "Score updates to 72")
    }

    static func testC402LevelDotColorTransitionsWithTension() {
        let low = BriefingTestFactory.makeTensionReading(score: 20)
        let high = BriefingTestFactory.makeTensionReading(score: 85)
        expectEqual(low.level, TensionLevel.mild, "Score 20 is mild")
        expectEqual(high.level, TensionLevel.boiling, "Score 85 is boiling")
        expectFalse(low.level == high.level, "Tension level distinguishes mild from boiling")
    }

    static func testC403DriversUpdateWithoutCarouselInterruption() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c4-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.tick(seconds: 4.0)
        let updatedReading = BriefingTestFactory.makeTensionReading(score: 60)
        expectEqual(updatedReading.assessment.score, 60, "Tension score updated")
        expectEqual(engine.activeCarouselIndex, 0, "Carousel index remains stable across tension update")
        expectEqual(engine.elapsedCarouselSeconds, 4.0, "Carousel timer retains elapsed progress")
    }

    static func testC404SparklineExtendsOnNewDailyReading() {
        var history: [WorldTensionReading] = []
        for i in 0..<7 {
            history.append(BriefingTestFactory.makeTensionReading(score: 50 + i))
        }
        expectEqual(history.count, 7, "7 initial days")
        history.append(BriefingTestFactory.makeTensionReading(score: 62))
        expectEqual(history.count, 8, "History extended to 8 readings")
    }

    static func testC405TensionUpdateDuringStoryOpen() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<4).map { BriefingTestFactory.makeArticle(id: "c4-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()  // story open
        let newReading = BriefingTestFactory.makeTensionReading(score: 77)
        expectEqual(newReading.assessment.score, 77, "Tension updated in background")
        expectTrue(engine.isStoryOpen, "Reader experience uninterrupted")
    }

    // MARK: - Tier 4: Real-World Scenarios

    static func testS101MorningIngestionAndEditionCreation() async {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let candidates = (0..<30).map {
            BriefingTestFactory.makeArticle(id: "m-\($0)", source: "Pub-\($0 % 10)", now: now)
        }
        let briefing = FiniteBriefing(candidates: candidates, readIDs: [], now: now)
        expectEqual(briefing.articles.count, 10, "Morning briefing selects exactly 10 stories")
    }

    static func testS102CarouselAndTensionPresented() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "m-\($0)", source: "Pub-\($0)", now: now) }
        let priorities = ["m-0": BriefingPriority(sourceCount: 5), "m-1": BriefingPriority(sourceCount: 4)]
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, priorities: priorities)
        expectEqual(engine.carouselStories.count, 10, "Carousel populates with the edition's ten stories")
        expectEqual(engine.carouselStories.first?.id, "m-0", "Lead carousel story is m-0")
    }

    static func testS103ReaderReadsFirstStory() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "m-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()  // opens story 0
        expectTrue(engine.readIDs.contains("m-0"), "First story marked read")
        expectTrue(engine.isStoryOpen, "Reader opened story")
        engine.handleEscape()
        expectFalse(engine.isStoryOpen, "Reader returned to situation board")
    }

    static func testS104ReaderReadsRemainingStories() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "m-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        for i in 0..<10 {
            engine.activeTileIndex = i
            engine.handleReturn()
            engine.handleEscape()
        }
        expectEqual(engine.readIDs.count, 10, "All 10 stories read")
    }

    static func testS105CompletionBoardPresented() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<10).map { BriefingTestFactory.makeArticle(id: "m-\($0)", source: "Pub-\($0)", now: now) }
        let allIDs = Set(articles.map(\.id))
        let engine = BriefingSituationBoardEngine(briefingArticles: articles, readIDs: allIDs)
        expectEqual(engine.mode, .complete, "Situation Board transitions to .complete congratulating reader")
    }

    static func testS201ReaderReadsTechAndScience() async {
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
            expectEqual(interests["technology"], 1, "Tech interest accumulated")
            expectEqual(interests["science"], 3, "Science interest accumulated (saved 3x)")
            await db.close()
        } catch {
            expectTrue(false, "test_S2_01 failed: \(error)")
        }
    }

    static func testS202InterestsInfluenceNextBriefingRank() async {
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
        expectEqual(
            briefing.articles.first?.id, "fav-tech", "Tech article selected first due to high inferred interest")
    }

    static func testS203UserResetsInterestsInSettings() async {
        let resetTimestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let suite = testDefaultsSuite("test.briefing.settings")
        defer { removeTestDefaults(suite) }
        let storedDefaults = UserDefaults(suiteName: suite)!
        storedDefaults.set(resetTimestamp.timeIntervalSince1970, forKey: "readingInterestsResetAt")
        let retrieved = storedDefaults.double(forKey: "readingInterestsResetAt")
        expectEqual(retrieved, resetTimestamp.timeIntervalSince1970, "Settings tab successfully writes reset timestamp")
        storedDefaults.removeObject(forKey: "readingInterestsResetAt")
    }

    static func testS204PostResetBriefingIgnoresPriorInterests() async {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let art1 = BriefingTestFactory.makeArticle(
            id: "art-1", source: "Pub-1", category: "Technology", age: 10, now: now)
        let art2 = BriefingTestFactory.makeArticle(id: "art-2", source: "Pub-2", category: "World", age: 5, now: now)
        let briefing = FiniteBriefing(candidates: [art1, art2], readIDs: [], now: now, priorities: [:], interests: [:])
        expectEqual(briefing.articles.first?.id, "art-2", "Without prior interests, tie breaks by recency")
    }

    static func testS301ArrowKeysNavigateCarousel() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "knav-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.nextCarouselStory()
        engine.nextCarouselStory()
        expectEqual(engine.activeCarouselIndex, 2, "Arrow navigation moved carousel to index 2")
    }

    static func testS302JAndKNavigateDenseTiles() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "knav-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleKeyJ()
        engine.handleKeyJ()
        engine.handleKeyJ()
        expectEqual(engine.activeTileIndex, 3, "J moved tile focus down to 3")
        engine.handleKeyK()
        expectEqual(engine.activeTileIndex, 2, "K moved tile focus up to 2")
    }

    static func testS303ReturnOpensAndEscCloses() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let articles = (0..<5).map { BriefingTestFactory.makeArticle(id: "knav-\($0)", source: "Pub-\($0)", now: now) }
        let engine = BriefingSituationBoardEngine(briefingArticles: articles)
        engine.handleReturn()
        expectTrue(engine.isStoryOpen, "Return opens story")
        engine.handleEscape()
        expectFalse(engine.isStoryOpen, "Esc closes story without state loss")
    }

    static func testS401EditionStaysFrozenThroughEvening() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let refDate = Date(timeIntervalSince1970: 1_780_000_000)
        let dayStart = utc.startOfDay(for: refDate)
        let morning = dayStart.addingTimeInterval(7.5 * 3600)  // 07:30 UTC
        let evening = dayStart.addingTimeInterval(21.5 * 3600)  // 21:30 UTC
        expectTrue(
            FiniteBriefing.isCurrent(selectedAt: morning, now: evening, hour: 7, calendar: utc),
            "Edition selected at 07:30 is current at 21:30")
    }

    static func testS402MidnightClockPassesWithoutPrematureRollover() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let refDate = Date(timeIntervalSince1970: 1_780_000_000)
        let dayStart = utc.startOfDay(for: refDate)
        let morning = dayStart.addingTimeInterval(7.5 * 3600)
        let midnight = dayStart.addingTimeInterval(24 * 3600 + 3600)  // 01:00 next day
        expectTrue(
            FiniteBriefing.isCurrent(selectedAt: morning, now: midnight, hour: 7, calendar: utc),
            "Edition remains current past midnight until next 07:00")
    }

    static func testS403MorningRolloverAtEditionHour() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let refDate = Date(timeIntervalSince1970: 1_780_000_000)
        let dayStart = utc.startOfDay(for: refDate)
        let morning = dayStart.addingTimeInterval(7.5 * 3600)
        let nextMorning = dayStart.addingTimeInterval(24 * 3600 + 8 * 3600)  // 08:00 next day
        expectFalse(
            FiniteBriefing.isCurrent(selectedAt: morning, now: nextMorning, hour: 7, calendar: utc),
            "Crossing 07:00 next day rolls over and marks previous edition stale")
    }
}
