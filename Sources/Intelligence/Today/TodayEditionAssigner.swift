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

/// Pure, deterministic Today edition importance scoring and 6-lane assignment module (Z2, #934).
///
/// Decision on stored `StoryImportance` (`story_importance` SQLite table, #934):
/// Today computes a continuous `0.0...1.0` editorial score from stored signals (original report count,
/// `BriefingPriorityData.assessImportance` severity/coverage/momentum, and `NotificationService.computeImportance`)
/// without writing or reading stored `story_importance` rows. Stored `StoryImportance` remains retired from
/// any app write path and untouched for Briefing / legacy `--curation-live` compatibility.
enum TodayEditionAssigner {

    struct EvaluatedStory {
        let entry: FeedEntry
        let score: Double
        let originalReportCount: Int
        let publisherCount: Int
        let publisherAffinity: Double
        let isTopQuartilePublisher: Bool
        let isStarredFeed: Bool
        let isDeveloping: Bool
        let groupingConfidence: Double
        let isCoverageConfident: Bool
        let readingTimeMinutes: Double
        let contentType: (type: TodayContentType, confidence: Double)?
        let interestMatch: Double
        let novelty: Double
        let hasInMotionUpdate: Bool
        let momentum: BriefingPriorityData.Momentum

        var id: String { entry.id }
        var orderDate: Date { entry.representative.orderDate }
    }

    /// A story that cleared a lane's bar, with the confidence and the reason code of that placement.
    struct LanePlacement {
        let story: EvaluatedStory
        let confidence: Double
        let reason: String
    }

    /// Assigns each story entry (from the `#581` story layer) to at most one lane in spec §2 assignment order.
    static func assign(
        entries: [FeedEntry],
        context: TodayAssignmentContext = TodayAssignmentContext()
    ) -> TodayEditionPlan {
        let eligible = eligibleEntries(entries, context: context)
        guard !eligible.isEmpty else {
            return TodayEditionPlan(
                lanes: TodayLane.assignmentOrder.map {
                    TodayLaneResult(lane: $0, qualifies: $0 == .theLatest, entries: [])
                }
            )
        }
        let thresholds = context.thresholds

        // 1. The Lead (1–5 slides, rank-ordered).
        let lead = selectLead(from: eligible.map { evaluateStory($0, context: context) }, thresholds: thresholds)
        // 2. In Motion (min 3, cap 12, chronological newest first)
        let inMotion = placeConditionalLane(lane: .inMotion, candidates: lead.pool) {
            inMotionPlacement($0, thresholds: thresholds)
        }
        // 3. The Deep Read (min 3, cap 8, chronological newest first; assigned BEFORE Your Beat per spec §4.1)
        let deepRead = placeConditionalLane(
            lane: .theDeepRead, candidates: inMotion.remaining, keeps: hasMoreDepth
        ) {
            deepReadPlacement($0, thresholds: thresholds)
        }
        // 4. Your Beat (min 3, cap 12, chronological newest first)
        let yourBeat = placeConditionalLane(lane: .yourBeat, candidates: deepRead.remaining) {
            yourBeatPlacement($0, thresholds: thresholds)
        }
        // 5. Outside Your Usual (min 3, cap 6, chronological newest first)
        let outside = placeConditionalLane(lane: .outsideYourUsual, candidates: yourBeat.remaining) {
            outsidePlacement($0, context: context)
        }
        // 6. The Latest (always shown, chronological newest first; safety net)
        let latest = outside.remaining.sorted(by: isNewer).map {
            makeAssignment(
                LanePlacement(story: $0, confidence: 1.0, reason: "the_latest_safety_net"),
                lane: .theLatest, includeContentLabel: false)
        }
        let leadEntries = lead.winners.map { makeAssignment($0, lane: .theLead, includeContentLabel: false) }

        return TodayEditionPlan(lanes: [
            TodayLaneResult(lane: .theLead, qualifies: !leadEntries.isEmpty, entries: leadEntries),
            TodayLaneResult(lane: .inMotion, qualifies: !inMotion.placed.isEmpty, entries: inMotion.placed),
            TodayLaneResult(lane: .theDeepRead, qualifies: !deepRead.placed.isEmpty, entries: deepRead.placed),
            TodayLaneResult(lane: .yourBeat, qualifies: !yourBeat.placed.isEmpty, entries: yourBeat.placed),
            TodayLaneResult(lane: .outsideYourUsual, qualifies: !outside.placed.isEmpty, entries: outside.placed),
            TodayLaneResult(lane: .theLatest, qualifies: true, entries: latest),
        ])
    }

    // MARK: - Candidate Pool

    /// Subscribed entries, deduplicated by story identity so an event never enters twice.
    private static func eligibleEntries(_ entries: [FeedEntry], context: TodayAssignmentContext) -> [FeedEntry] {
        var seenStoryKeys = Set<String>()
        var eligible: [FeedEntry] = []
        for entry in entries {
            let signals = context.signalsByEntryID[entry.id]
            if let subscribed = context.subscribedFeedURLs,
                !isSubscribed(entry, signals: signals, in: subscribed)
            {
                continue
            }
            let key: String
            switch entry {
            case .article(let article): key = "article:\(article.id)"
            case .event(let summary, _, _): key = "event:\(summary.eventID)"
            }
            guard seenStoryKeys.insert(key).inserted else { continue }
            eligible.append(entry)
        }
        return eligible
    }

    private static func isSubscribed(
        _ entry: FeedEntry,
        signals: TodayStorySignals?,
        in subscribed: Set<String>
    ) -> Bool {
        let subscribedKeys = Set(subscribed.map(AppSettings.feedKey))
        let candidateURLs =
            Set(entry.visibleArticles.compactMap(\.identityFeedURL))
            .union(signals?.feedURLs ?? [])
        return candidateURLs.contains { url in
            subscribed.contains(url) || subscribedKeys.contains(AppSettings.feedKey(url))
        }
    }

    /// Newest report first, then story id: the order inside a lane and the last tie-break of every ranking.
    private static func isNewer(_ a: EvaluatedStory, than b: EvaluatedStory) -> Bool {
        a.orderDate == b.orderDate ? a.id < b.id : a.orderDate > b.orderDate
    }

    // MARK: - The Lead

    /// The Lead's slides in rank order, and every other story as the pool the conditional lanes draw from.
    private static func selectLead(
        from evaluated: [EvaluatedStory],
        thresholds: TodayEditionThresholds
    ) -> (winners: [LanePlacement], pool: [EvaluatedStory]) {
        let ordered = evaluated.sorted(by: leadPrecedes)
        guard let first = ordered.first else { return ([], []) }
        var winners = [
            LanePlacement(story: first, confidence: max(0.50, leadConfidence(first)), reason: "lead_top_story")
        ]
        var pool: [EvaluatedStory] = []
        for story in ordered.dropFirst() {
            if winners.count < (TodayLane.theLead.cap ?? 5), let slide = leadSlide(story, thresholds: thresholds) {
                winners.append(slide)
            } else {
                pool.append(story)
            }
        }
        return (winners, pool)
    }

    /// Tie-break puts original report count before publisher affinity so affinity never lifts a 1-report
    /// story ahead of a multi-report one (spec §2.2, Mars 9 Nov 2026).
    private static func leadPrecedes(_ a: EvaluatedStory, _ b: EvaluatedStory) -> Bool {
        if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
        if a.originalReportCount != b.originalReportCount { return a.originalReportCount > b.originalReportCount }
        if abs(a.publisherAffinity - b.publisherAffinity) > 1e-9 {
            return a.publisherAffinity > b.publisherAffinity
        }
        return isNewer(a, than: b)
    }

    /// Slides 2–5: the score bar for the story's original report count, and the minimum confidence.
    private static func leadSlide(_ story: EvaluatedStory, thresholds: TodayEditionThresholds) -> LanePlacement? {
        let conf = leadConfidence(story)
        let qualifiesScore =
            (story.originalReportCount >= 2 && story.score >= thresholds.leadMultiReportScoreMinimum)
            || (story.originalReportCount == 1 && story.score >= thresholds.leadSingleReportScoreMinimum)
        guard qualifiesScore, conf >= thresholds.leadMinimumConfidence else { return nil }
        let reason = story.originalReportCount >= 2 ? "lead_multi_report" : "lead_high_score_single_report"
        return LanePlacement(story: story, confidence: conf, reason: reason)
    }

    // MARK: - Conditional lane bars

    private static func inMotionPlacement(
        _ story: EvaluatedStory,
        thresholds: TodayEditionThresholds
    ) -> LanePlacement? {
        let conf = inMotionConfidence(story)
        guard story.hasInMotionUpdate, story.momentum == .rising,
            conf >= thresholds.inMotionMinimumConfidence
        else { return nil }
        return LanePlacement(story: story, confidence: conf, reason: "in_motion_substantive_24h_update")
    }

    private static func deepReadPlacement(
        _ story: EvaluatedStory,
        thresholds: TodayEditionThresholds
    ) -> LanePlacement? {
        let byLength = story.readingTimeMinutes >= thresholds.deepReadMinimumMinutes
        let byType =
            (story.contentType?.confidence ?? 0.0) >= thresholds.deepReadClassificationMinimumConfidence
        let conf = deepReadConfidence(story)
        guard byLength || byType, conf >= thresholds.deepReadMinimumConfidence else { return nil }
        let reason = byType ? "deep_read_content_type" : "deep_read_length"
        return LanePlacement(story: story, confidence: conf, reason: reason)
    }

    private static func yourBeatPlacement(
        _ story: EvaluatedStory,
        thresholds: TodayEditionThresholds
    ) -> LanePlacement? {
        let byInterest = story.interestMatch >= thresholds.yourBeatInterestMatchMinimum
        let byStar = story.isStarredFeed
        let byAffinity = story.isTopQuartilePublisher
        let conf = yourBeatConfidence(story)
        guard byInterest || byStar || byAffinity, conf >= thresholds.yourBeatMinimumConfidence else {
            return nil
        }
        let reason =
            byStar ? "your_beat_starred" : (byInterest ? "your_beat_interest" : "your_beat_publisher_affinity")
        return LanePlacement(story: story, confidence: conf, reason: reason)
    }

    private static func outsidePlacement(_ story: EvaluatedStory, context: TodayAssignmentContext) -> LanePlacement? {
        guard context.profile.hasHistory else { return nil }
        let thresholds = context.thresholds
        let conf = outsideConfidence(story)
        guard story.novelty >= thresholds.outsideNoveltyMinimum,
            story.score >= thresholds.outsideScoreMinimum,
            conf >= thresholds.outsideMinimumConfidence
        else { return nil }
        return LanePlacement(story: story, confidence: conf, reason: "outside_profile_distance")
    }

    // MARK: - Conditional lane placement

    /// Which of two stories keeps its place when a lane is over its cap: the higher `score`, then the newest
    /// report, then the story id (spec §2.2).
    private static func hasHigherScore(_ a: EvaluatedStory, than b: EvaluatedStory) -> Bool {
        if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
        return isNewer(a, than: b)
    }

    /// The Deep Read's own rule (#1194): the longer stored text, then the surer content type, then the newest
    /// report, then the story id. The importance score follows publisher count, which is not depth.
    private static func hasMoreDepth(_ a: EvaluatedStory, than b: EvaluatedStory) -> Bool {
        if abs(a.readingTimeMinutes - b.readingTimeMinutes) > 1e-9 {
            return a.readingTimeMinutes > b.readingTimeMinutes
        }
        let typeA = a.contentType?.confidence ?? 0.0
        let typeB = b.contentType?.confidence ?? 0.0
        if abs(typeA - typeB) > 1e-9 { return typeA > typeB }
        return isNewer(a, than: b)
    }

    private static func placeConditionalLane(
        lane: TodayLane,
        candidates: [EvaluatedStory],
        keeps: (EvaluatedStory, EvaluatedStory) -> Bool = hasHigherScore,
        evaluate: (EvaluatedStory) -> LanePlacement?
    ) -> (placed: [TodayStoryAssignment], remaining: [EvaluatedStory]) {
        var matching: [LanePlacement] = []
        var nonMatching: [EvaluatedStory] = []

        for story in candidates {
            if let placement = evaluate(story) {
                matching.append(placement)
            } else {
                nonMatching.append(story)
            }
        }

        // Below minimum count -> lane stays hidden and every survivor cascades onward unchanged.
        guard matching.count >= lane.minimumCount else {
            return ([], candidates)
        }

        let cap = lane.cap ?? matching.count
        // Spec §2.2: a lane over its cap keeps the stories its rule ranks first; the rest fall through.
        let ranked = matching.sorted { keeps($0.story, $1.story) }

        let overflow = ranked.dropFirst(cap).map(\.story)

        // Chronological order within every conditional lane (Rule 1).
        let chronological = ranked.prefix(cap).sorted { isNewer($0.story, than: $1.story) }

        let placed = chronological.map {
            makeAssignment($0, lane: lane, includeContentLabel: lane == .theDeepRead)
        }

        return (placed, nonMatching + overflow)
    }

    private static func makeAssignment(
        _ placement: LanePlacement,
        lane: TodayLane,
        includeContentLabel: Bool
    ) -> TodayStoryAssignment {
        let story = placement.story
        let label: TodayContentType?
        if includeContentLabel, let ct = story.contentType, ct.confidence >= 0.70 {
            label = ct.type
        } else {
            label = nil
        }
        return TodayStoryAssignment(
            id: story.id,
            entry: story.entry,
            lane: lane,
            score: story.score,
            confidence: min(1.0, max(0.0, placement.confidence)),
            reason: placement.reason,
            sortKey: story.orderDate,
            contentTypeLabel: label,
            isCoverageConfident: story.isCoverageConfident,
            isDeveloping: story.isDeveloping,
            originalReportCount: story.originalReportCount,
            publisherCount: story.publisherCount,
            groupingConfidence: story.groupingConfidence,
            readingTimeMinutes: story.readingTimeMinutes,
            interestMatch: story.interestMatch,
            novelty: story.novelty
        )
    }

    // MARK: - Lane Confidence Functions

    private static func leadConfidence(_ story: EvaluatedStory) -> Double {
        let reportStrength = min(1.0, Double(story.originalReportCount) / 3.0)
        let scoreStrength = min(1.0, max(0.0, story.score))
        return min(1.0, 0.30 + reportStrength * 0.45 + scoreStrength * 0.25)
    }

    private static func inMotionConfidence(_ story: EvaluatedStory) -> Double {
        guard story.hasInMotionUpdate, story.momentum == .rising else { return 0.30 }
        return story.groupingConfidence >= 0.70 || story.publisherCount >= 3 ? 0.88 : 0.75
    }

    private static func deepReadConfidence(_ story: EvaluatedStory) -> Double {
        let typeConf = story.contentType?.confidence ?? 0.0
        let lengthConf: Double
        if story.readingTimeMinutes >= 12.0 {
            lengthConf = 0.88
        } else if story.readingTimeMinutes >= 8.0 {
            lengthConf = 0.75
        } else {
            lengthConf = 0.0
        }
        return max(typeConf, lengthConf)
    }

    private static func yourBeatConfidence(_ story: EvaluatedStory) -> Double {
        var conf = 0.0
        if story.isStarredFeed { conf = max(conf, 0.90) }
        if story.isTopQuartilePublisher { conf = max(conf, 0.78) }
        if story.interestMatch >= 0.50 { conf = max(conf, min(0.95, 0.55 + story.interestMatch * 0.40)) }
        return conf
    }

    private static func outsideConfidence(_ story: EvaluatedStory) -> Double {
        guard story.novelty >= 0.60, story.score >= 0.35 else { return 0.25 }
        return min(0.92, 0.45 + story.novelty * 0.30 + story.score * 0.20)
    }
}
