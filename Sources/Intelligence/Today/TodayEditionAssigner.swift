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
import NaturalLanguage

/// The six fixed lanes of the Today edition (Epic Z, #932, #934).
///
/// Assignment order assigns ``theDeepRead`` before ``yourBeat`` so a narrow format lane is not starved
/// by reading interests; ``displayOrder`` keeps ``yourBeat`` above ``theDeepRead`` on the page
/// (see `docs/plans/2026-11-09-today-edition-spec.md` §2, §4.1).
enum TodayLane: String, CaseIterable, Sendable, Hashable {
    case theLead = "The Lead"
    case inMotion = "In Motion"
    case theDeepRead = "The Deep Read"
    case yourBeat = "Your Beat"
    case outsideYourUsual = "Outside Your Usual"
    case theLatest = "The Latest"

    /// Sequential evaluation order: one story enters the first lane whose bar it clears.
    static let assignmentOrder: [TodayLane] = [
        .theLead,
        .inMotion,
        .theDeepRead,
        .yourBeat,
        .outsideYourUsual,
        .theLatest,
    ]

    /// Visual presentation order on the Today page (`docs/design/today.md`).
    static let displayOrder: [TodayLane] = [
        .theLead,
        .inMotion,
        .yourBeat,
        .theDeepRead,
        .outsideYourUsual,
        .theLatest,
    ]

    /// Sentence-case one-line description shown under the lane title.
    var subtitle: String {
        switch self {
        case .theLead: return "Today's most important stories from your publishers."
        case .inMotion: return "Ongoing stories with new reporting."
        case .theDeepRead: return "Long reads: investigations, explainers and opinion."
        case .yourBeat: return "Stories close to what you read, save and follow."
        case .outsideYourUsual: return "Stories from your publishers beyond your usual reading."
        case .theLatest: return "Everything else from your publishers, newest first."
        }
    }

    var isConditional: Bool {
        self != .theLead && self != .theLatest
    }

    var minimumCount: Int {
        switch self {
        case .theLead: return 1
        case .inMotion, .theDeepRead, .yourBeat, .outsideYourUsual: return 3
        case .theLatest: return 0
        }
    }

    var cap: Int? {
        switch self {
        case .theLead: return 5
        case .inMotion: return 12
        case .theDeepRead: return 8
        case .yourBeat: return 12
        case .outsideYourUsual: return 6
        case .theLatest: return nil
        }
    }
}

/// Content-type label shown on Feature cards in The Deep Read when classified on device (Z7 #1174).
/// Never emitted from word count / reading time alone.
enum TodayContentType: String, CaseIterable, Sendable, Hashable {
    case investigation = "Investigation"
    case explainer = "Explainer"
    case opinion = "Opinion"
}

/// Thresholds and calibration weights for Z2 Today lane assignment (`#934`).
/// Initial starting values follow `docs/plans/2026-11-09-today-edition-spec.md` §2.2; final values
/// are verified by the Z2 shadow evaluation. Editorial thresholds remain separate from notification thresholds.
struct TodayEditionThresholds: Equatable, Sendable {
    var leadMultiReportScoreMinimum = 0.60
    var leadSingleReportScoreMinimum = 0.75
    var leadMinimumConfidence = 0.50

    var inMotionWindowSeconds: TimeInterval = 24 * 3600
    var inMotionMinimumConfidence = 0.70

    var deepReadMinimumMinutes = 8.0
    var deepReadWordsPerMinute = 200.0
    var deepReadClassificationMinimumConfidence = 0.70
    var deepReadMinimumConfidence = 0.60

    var yourBeatInterestMatchMinimum = 0.50
    var yourBeatMinimumConfidence = 0.60

    var outsideNoveltyMinimum = 0.60
    var outsideScoreMinimum = 0.35
    var outsideMinimumConfidence = 0.60

    var coverageMinimumPublishers = 3
    var coverageMinimumOriginalReports = 2
    var coverageMinimumGroupingConfidence = 0.70

    var developingWindowSeconds: TimeInterval = 3600

    static let `default` = TodayEditionThresholds()
}

/// 30-day finer reading-interest and publisher-affinity profile built from local read (`+1`) and saved (`+3`) history.
///
/// Coarse 12-category weights (`briefingInterests`) are capped below `yourBeatInterestMatchMinimum` so a reader's
/// top category alone never floods `Your Beat` and starves `Outside Your Usual` (spec §4.1).
struct TodayUserProfile: Equatable, Sendable {
    /// Lowercased `NewsCategory` raw value -> bounded weight (read +1, saved +3 over 30 days).
    var categoryWeights: [String: Double]
    /// Entity slug (e.g. `person:jane-doe`, `organization:central-bank`) -> accumulated 30-day weight.
    var entityWeights: [String: Double]
    /// Substantive title/section keyword token -> accumulated 30-day weight.
    var keywordWeights: [String: Double]
    /// Canonical publisher (lowercased displaySource) -> accumulated 30-day weight.
    var publisherWeights: [String: Double]
    /// Canonical publishers in the top quartile of 30-day engagement (minimum weight >= 2).
    var topQuartilePublishers: Set<String>
    /// Total weighted reading/saving interactions recorded in the profile window.
    var interactionCount: Int

    static let empty = TodayUserProfile(
        categoryWeights: [:],
        entityWeights: [:],
        keywordWeights: [:],
        publisherWeights: [:],
        topQuartilePublishers: [],
        interactionCount: 0
    )

    init(
        categoryWeights: [String: Double] = [:],
        entityWeights: [String: Double] = [:],
        keywordWeights: [String: Double] = [:],
        publisherWeights: [String: Double] = [:],
        topQuartilePublishers: Set<String>? = nil,
        interactionCount: Int? = nil
    ) {
        self.categoryWeights = categoryWeights
        self.entityWeights = entityWeights
        self.keywordWeights = keywordWeights
        self.publisherWeights = publisherWeights
        self.topQuartilePublishers =
            topQuartilePublishers ?? Self.computeTopQuartilePublishers(from: publisherWeights)
        self.interactionCount =
            interactionCount
            ?? Int(
                max(
                    publisherWeights.values.reduce(0, +),
                    categoryWeights.values.reduce(0, +)
                ).rounded()
            )
    }

    var hasHistory: Bool {
        interactionCount >= 3
            || entityWeights.values.reduce(0, +) >= 2.0
            || keywordWeights.values.reduce(0, +) >= 3.0
    }

    /// Publisher affinity on a `0.0...1.0` scale relative to the reader's highest-engaged publisher.
    func publisherAffinity(for publisher: String) -> Double {
        let key = EventFeedSummary.displaySource(publisher).lowercased()
        guard let weight = publisherWeights[key], weight > 0 else { return 0.0 }
        let maxWeight = max(1.0, publisherWeights.values.max() ?? 1.0)
        return min(1.0, weight / maxWeight)
    }

    func isTopQuartilePublisher(_ publisher: String) -> Bool {
        let key = EventFeedSummary.displaySource(publisher).lowercased()
        return topQuartilePublishers.contains(key)
    }

    static func computeTopQuartilePublishers(from weights: [String: Double]) -> Set<String> {
        let engaged = weights.filter { $0.value >= 2.0 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        guard !engaged.isEmpty else { return [] }
        let topCount = max(1, Int(ceil(Double(engaged.count) * 0.25)))
        return Set(engaged.prefix(topCount).map(\.key))
    }
}

/// Optional stored evidence preloaded for one story entry (#934).
/// When absent, ``TodayEditionAssigner`` derives conservative signals directly from `FeedEntry`.
struct TodayStorySignals: Equatable, Sendable {
    var originalReportCount: Int?
    var memberFullTexts: [String] = []
    var entityIDs: Set<String> = []
    var feedURLs: Set<String> = []
    var hasSectorImpact: Bool = false
    var groupingConfidence: Double?
    var nlImportanceOverride: Double?
    var resolvedImportanceOverride: StoryImportance?
}

/// Context passed into one deterministic Today lane-assignment pass.
struct TodayAssignmentContext: Equatable, Sendable {
    var now: Date
    /// Selected subscription feed URLs (normalized via `AppSettings.feedKey` when present).
    /// When non-nil, only entries with at least one visible article matching a subscribed feed enter Today.
    var subscribedFeedURLs: Set<String>?
    var starredFeedURLs: Set<String>
    var profile: TodayUserProfile
    var signalsByEntryID: [String: TodayStorySignals]
    var thresholds: TodayEditionThresholds

    init(
        now: Date = Date(),
        subscribedFeedURLs: Set<String>? = nil,
        starredFeedURLs: Set<String> = [],
        profile: TodayUserProfile = .empty,
        signalsByEntryID: [String: TodayStorySignals] = [:],
        thresholds: TodayEditionThresholds = .default
    ) {
        self.now = now
        self.subscribedFeedURLs = subscribedFeedURLs
        self.starredFeedURLs = starredFeedURLs
        self.profile = profile
        self.signalsByEntryID = signalsByEntryID
        self.thresholds = thresholds
    }
}

/// Output contract per story entry placed in a Today lane (`#934`).
struct TodayStoryAssignment: Identifiable, Equatable, Sendable {
    let id: String
    let entry: FeedEntry
    let lane: TodayLane
    /// Editorial relevance score (`0.0...1.0`), calibrated separately from notification thresholds.
    let score: Double
    /// Confidence in this lane placement (`0.0...1.0`).
    let confidence: Double
    /// Structured reason code for evaluation and tests; never shown as reader copy.
    let reason: String
    /// Order key within chronological lanes (newest report date); Lead slides stay rank-ordered.
    let sortKey: Date
    /// Classified content-type label (`Investigation`, `Explainer`, `Opinion`) for Z7 (`#1174`),
    /// populated only when the classifier reaches `>= 0.70`, never from word count alone.
    let contentTypeLabel: TodayContentType?
    /// True when the Coverage card variant gate holds (`>= 3` publishers, `>= 2` original reports,
    /// and grouping confidence `>= threshold`).
    let isCoverageConfident: Bool
    /// True when the story qualifies for the Developing pill (Briefing definition: confirmed event
    /// with a report in the last hour).
    let isDeveloping: Bool

    // Evaluation & diagnostic scalars (no private text).
    let originalReportCount: Int
    let publisherCount: Int
    let groupingConfidence: Double
    let readingTimeMinutes: Double
    let interestMatch: Double
    let novelty: Double
}

/// One lane's assignment outcome, carrying both whether the lane qualifies for display and its entries.
struct TodayLaneResult: Identifiable, Equatable, Sendable {
    var id: TodayLane { lane }
    let lane: TodayLane
    let qualifies: Bool
    let entries: [TodayStoryAssignment]
}

/// Complete deterministic result of one Today edition assignment pass.
struct TodayEditionPlan: Equatable, Sendable {
    let lanes: [TodayLaneResult]

    /// Lanes in page display order (`Your Beat` shown above `The Deep Read`).
    var displayLanes: [TodayLaneResult] {
        let byLane = Dictionary(uniqueKeysWithValues: lanes.map { ($0.lane, $0) })
        return TodayLane.displayOrder.compactMap { byLane[$0] }
    }

    func result(for lane: TodayLane) -> TodayLaneResult? {
        lanes.first { $0.lane == lane }
    }

    func entries(for lane: TodayLane) -> [TodayStoryAssignment] {
        result(for: lane)?.entries ?? []
    }

    var allAssignments: [TodayStoryAssignment] {
        lanes.flatMap(\.entries)
    }
}

/// Pure, deterministic Today edition importance scoring and 6-lane assignment module (Z2, #934).
///
/// Decision on stored `StoryImportance` (`story_importance` SQLite table, #934):
/// Today computes a continuous `0.0...1.0` editorial score from stored signals (original report count,
/// `BriefingPriorityData.assessImportance` severity/coverage/momentum, and `NotificationService.computeImportance`)
/// without writing or reading stored `story_importance` rows. Stored `StoryImportance` remains retired from
/// any app write path and untouched for Briefing / legacy `--curation-live` compatibility.
enum TodayEditionAssigner {

    private struct EvaluatedStory {
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

    /// Assigns each story entry (from the `#581` story layer) to at most one lane in spec §2 assignment order.
    static func assign(
        entries: [FeedEntry],
        context: TodayAssignmentContext = TodayAssignmentContext()
    ) -> TodayEditionPlan {
        // Deduplicate story entries by story identity so an event never enters twice.
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

        guard !eligible.isEmpty else {
            return TodayEditionPlan(
                lanes: TodayLane.assignmentOrder.map {
                    TodayLaneResult(lane: $0, qualifies: $0 == .theLatest, entries: [])
                }
            )
        }

        let evaluated = eligible.map { evaluateStory($0, context: context) }
        let thresholds = context.thresholds

        // 1. The Lead (1–5 slides, rank-ordered).
        // Tie-break puts original report count before publisher affinity so affinity never lifts a 1-report
        // story ahead of a multi-report one (spec §2.2, Mars 9 Nov 2026).
        let leadOrdered = evaluated.sorted { a, b in
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            if a.originalReportCount != b.originalReportCount { return a.originalReportCount > b.originalReportCount }
            if abs(a.publisherAffinity - b.publisherAffinity) > 1e-9 {
                return a.publisherAffinity > b.publisherAffinity
            }
            if a.orderDate != b.orderDate { return a.orderDate > b.orderDate }
            return a.id < b.id
        }

        var leadWinners: [(story: EvaluatedStory, confidence: Double, reason: String)] = []
        var pool: [EvaluatedStory] = []
        if let first = leadOrdered.first {
            leadWinners.append((first, max(0.50, leadConfidence(first)), "lead_top_story"))
            for story in leadOrdered.dropFirst() {
                let conf = leadConfidence(story)
                let qualifiesScore =
                    (story.originalReportCount >= 2 && story.score >= thresholds.leadMultiReportScoreMinimum)
                    || (story.originalReportCount == 1 && story.score >= thresholds.leadSingleReportScoreMinimum)
                if leadWinners.count < (TodayLane.theLead.cap ?? 5),
                    qualifiesScore,
                    conf >= thresholds.leadMinimumConfidence
                {
                    let reason =
                        story.originalReportCount >= 2 ? "lead_multi_report" : "lead_high_score_single_report"
                    leadWinners.append((story, conf, reason))
                } else {
                    pool.append(story)
                }
            }
        }

        // 2. In Motion (min 3, cap 12, chronological newest first)
        let inMotionResult = placeConditionalLane(
            lane: .inMotion,
            candidates: pool,
            evaluate: { story in
                let conf = inMotionConfidence(story)
                guard story.hasInMotionUpdate, story.momentum == .rising,
                    conf >= thresholds.inMotionMinimumConfidence
                else { return nil }
                return (conf, "in_motion_substantive_24h_update")
            }
        )
        pool = inMotionResult.remaining

        // 3. The Deep Read (min 3, cap 8, chronological newest first; assigned BEFORE Your Beat per spec §4.1)
        let deepReadResult = placeConditionalLane(
            lane: .theDeepRead,
            candidates: pool,
            evaluate: { story in
                let byLength = story.readingTimeMinutes >= thresholds.deepReadMinimumMinutes
                let byType =
                    (story.contentType?.confidence ?? 0.0) >= thresholds.deepReadClassificationMinimumConfidence
                let conf = deepReadConfidence(story)
                guard byLength || byType, conf >= thresholds.deepReadMinimumConfidence else { return nil }
                let reason = byType ? "deep_read_content_type" : "deep_read_length"
                return (conf, reason)
            }
        )
        pool = deepReadResult.remaining

        // 4. Your Beat (min 3, cap 12, chronological newest first)
        let yourBeatResult = placeConditionalLane(
            lane: .yourBeat,
            candidates: pool,
            evaluate: { story in
                let byInterest = story.interestMatch >= thresholds.yourBeatInterestMatchMinimum
                let byStar = story.isStarredFeed
                let byAffinity = story.isTopQuartilePublisher
                let conf = yourBeatConfidence(story)
                guard byInterest || byStar || byAffinity, conf >= thresholds.yourBeatMinimumConfidence else {
                    return nil
                }
                let reason =
                    byStar ? "your_beat_starred" : (byInterest ? "your_beat_interest" : "your_beat_publisher_affinity")
                return (conf, reason)
            }
        )
        pool = yourBeatResult.remaining

        // 5. Outside Your Usual (min 3, cap 6, chronological newest first)
        let outsideResult = placeConditionalLane(
            lane: .outsideYourUsual,
            candidates: pool,
            evaluate: { story in
                guard context.profile.hasHistory else { return nil }
                let conf = outsideConfidence(story)
                guard story.novelty >= thresholds.outsideNoveltyMinimum,
                    story.score >= thresholds.outsideScoreMinimum,
                    conf >= thresholds.outsideMinimumConfidence
                else { return nil }
                return (conf, "outside_profile_distance")
            }
        )
        pool = outsideResult.remaining

        // 6. The Latest (always shown, chronological newest first; safety net)
        let latestOrdered = pool.sorted {
            $0.orderDate == $1.orderDate ? $0.id < $1.id : $0.orderDate > $1.orderDate
        }

        let leadAssignments = leadWinners.map { item in
            makeAssignment(
                item.story, lane: .theLead, confidence: item.confidence, reason: item.reason, includeContentLabel: false
            )
        }
        let latestAssignments = latestOrdered.map { story in
            makeAssignment(
                story, lane: .theLatest, confidence: 1.0, reason: "the_latest_safety_net", includeContentLabel: false)
        }

        let laneResults: [TodayLaneResult] = [
            TodayLaneResult(lane: .theLead, qualifies: !leadAssignments.isEmpty, entries: leadAssignments),
            TodayLaneResult(
                lane: .inMotion, qualifies: !inMotionResult.placed.isEmpty, entries: inMotionResult.placed),
            TodayLaneResult(
                lane: .theDeepRead, qualifies: !deepReadResult.placed.isEmpty, entries: deepReadResult.placed),
            TodayLaneResult(
                lane: .yourBeat, qualifies: !yourBeatResult.placed.isEmpty, entries: yourBeatResult.placed),
            TodayLaneResult(
                lane: .outsideYourUsual, qualifies: !outsideResult.placed.isEmpty, entries: outsideResult.placed),
            TodayLaneResult(lane: .theLatest, qualifies: true, entries: latestAssignments),
        ]
        return TodayEditionPlan(lanes: laneResults)
    }

    // MARK: - Conditional lane placement

    private static func placeConditionalLane(
        lane: TodayLane,
        candidates: [EvaluatedStory],
        evaluate: (EvaluatedStory) -> (confidence: Double, reason: String)?
    ) -> (placed: [TodayStoryAssignment], remaining: [EvaluatedStory]) {
        var matching: [(story: EvaluatedStory, confidence: Double, reason: String)] = []
        var nonMatching: [EvaluatedStory] = []

        for story in candidates {
            if let decision = evaluate(story) {
                matching.append((story, decision.confidence, decision.reason))
            } else {
                nonMatching.append(story)
            }
        }

        // Below minimum count -> lane stays hidden and every survivor cascades onward unchanged.
        guard matching.count >= lane.minimumCount else {
            return ([], candidates)
        }

        let cap = lane.cap ?? matching.count
        // Spec §2.2: overflow keeps highest score, breaking ties by newest report then story id.
        let ranked = matching.sorted { a, b in
            if abs(a.story.score - b.story.score) > 1e-9 { return a.story.score > b.story.score }
            if a.story.orderDate != b.story.orderDate { return a.story.orderDate > b.story.orderDate }
            return a.story.id < b.story.id
        }

        let kept = ranked.prefix(cap)
        let overflow = ranked.dropFirst(cap).map(\.story)

        // Chronological order within every conditional lane (Rule 1).
        let chronological = kept.sorted {
            $0.story.orderDate == $1.story.orderDate
                ? $0.story.id < $1.story.id : $0.story.orderDate > $1.story.orderDate
        }

        let placed = chronological.map { item in
            makeAssignment(
                item.story,
                lane: lane,
                confidence: item.confidence,
                reason: item.reason,
                includeContentLabel: lane == .theDeepRead
            )
        }

        return (placed, nonMatching + overflow)
    }

    private static func makeAssignment(
        _ story: EvaluatedStory,
        lane: TodayLane,
        confidence: Double,
        reason: String,
        includeContentLabel: Bool
    ) -> TodayStoryAssignment {
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
            confidence: min(1.0, max(0.0, confidence)),
            reason: reason,
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

    // MARK: - Story Evaluation

    private static func evaluateStory(
        _ entry: FeedEntry,
        context: TodayAssignmentContext
    ) -> EvaluatedStory {
        let rep = entry.representative
        let signals = context.signalsByEntryID[entry.id]
        let thresholds = context.thresholds

        let memberTexts: [(publisher: String, text: String)]
        let eventSummary: EventFeedSummary?
        switch entry {
        case .event(let summary, _, let visible):
            eventSummary = summary
            if let preloaded = signals?.memberFullTexts, !preloaded.isEmpty {
                // When preloaded full reports exist, combine publisher with stored member text.
                let fallbackReports = visible.map { ($0.publisherName, BriefingPriorityData.reportText($0)) }
                let bySource = preloaded.enumerated().map { index, text -> (String, String) in
                    let pub = index < summary.members.count ? summary.members[index].source : rep.publisherName
                    return (pub, text)
                }
                memberTexts = bySource.count >= fallbackReports.count ? bySource : fallbackReports
            } else if !visible.isEmpty {
                memberTexts = visible.map { ($0.publisherName, BriefingPriorityData.reportText($0)) }
            } else {
                memberTexts = summary.members.map { ($0.source, $0.title) }
            }
        case .article(let article):
            eventSummary = nil
            memberTexts = [(article.publisherName, BriefingPriorityData.reportText(article))]
        }

        let computedOriginal = max(1, BriefingPriorityData.originalReports(memberTexts))
        let originalCount = max(1, signals?.originalReportCount ?? computedOriginal)
        let publisherCount = max(1, eventSummary?.sources.count ?? 1)

        // Developing pill matches Briefing definition (`BriefingView.isDeveloping`).
        let isDeveloping: Bool
        if let summary = eventSummary, summary.isConfirmed, let latest = summary.latestDate {
            let age = context.now.timeIntervalSince(latest)
            isDeveloping = age <= thresholds.developingWindowSeconds && age >= -300
        } else {
            isDeveloping = false
        }

        // Momentum and 24-hour In Motion substantive update.
        let momentum: BriefingPriorityData.Momentum
        let hasInMotionUpdate: Bool
        if let summary = eventSummary {
            momentum = BriefingPriorityData.momentum(dates: summary.members.map(\.date), now: context.now)
            hasInMotionUpdate = hasSubstantiveInMotionUpdate(
                summary, now: context.now, window: thresholds.inMotionWindowSeconds)
        } else {
            momentum = .steady
            hasInMotionUpdate = false
        }

        // Grouping confidence for Coverage card gate.
        let groupingConfidence: Double
        if let preloaded = signals?.groupingConfidence {
            groupingConfidence = preloaded
        } else if let summary = eventSummary, summary.isConfirmed {
            groupingConfidence = fallbackGroupingConfidence(for: summary)
        } else {
            groupingConfidence = 0.0
        }
        let isCoverageConfident =
            publisherCount >= thresholds.coverageMinimumPublishers
            && originalCount >= thresholds.coverageMinimumOriginalReports
            && groupingConfidence >= thresholds.coverageMinimumGroupingConfidence

        // Stored reading time: counted from stored text only (zero network fetches).
        let readingTimeMinutes = storedReadingTimeMinutes(
            for: entry,
            preloadedTexts: signals?.memberFullTexts ?? [],
            wordsPerMinute: thresholds.deepReadWordsPerMinute
        )

        // On-device content-type classification from headline, summary and feed/URL cues.
        let contentType = classifyContentType(
            title: rep.title,
            description: rep.description,
            category: rep.category,
            link: rep.link
        )

        // Briefing importance level (severity, coverage, sector impact, momentum/developing).
        let assessed =
            signals?.resolvedImportanceOverride
            ?? BriefingPriorityData.assessImportance(
                stored: nil,
                publisherCount: publisherCount,
                originalCount: originalCount,
                representative: rep,
                overview: nil,
                momentum: momentum,
                isDeveloping: isDeveloping
            )
        let hasSectorImpact = signals?.hasSectorImpact ?? false

        // NaturalLanguage importance score (notification threshold stays independent).
        let nlImportance =
            signals?.nlImportanceOverride
            ?? NotificationService.shared.computeImportance(title: rep.title, description: rep.description)

        var rawScore = computeEditorialScore(
            originalCount: originalCount,
            assessedImportance: assessed,
            hasSectorImpact: hasSectorImpact,
            momentum: momentum,
            isDeveloping: isDeveloping,
            nlImportance: nlImportance
        )
        if Self.isPromotionalDeal(title: rep.title) {
            rawScore = min(rawScore, 0.25)
        }
        let editorialScore = rawScore

        // Personalization: publisher affinity (tie-breaker in Lead, full weight in Your Beat), stars, fine interests.
        let affinity = context.profile.publisherAffinity(for: rep.publisherName)
        let isTopQuartile = context.profile.isTopQuartilePublisher(rep.publisherName)
        let entryFeedURLs =
            Set(entry.visibleArticles.compactMap(\.identityFeedURL))
            .union(signals?.feedURLs ?? [])
        let isStarred = entryFeedURLs.contains { raw in
            let key = AppSettings.feedKey(raw)
            return context.starredFeedURLs.contains(raw)
                || context.starredFeedURLs.contains(where: { AppSettings.feedKey($0) == key })
        }

        let preloadedEntities = signals?.entityIDs
        let storyEntities: Set<String>
        if let preloadedEntities, !preloadedEntities.isEmpty {
            storyEntities = preloadedEntities
        } else if !context.profile.entityWeights.isEmpty {
            storyEntities = extractFallbackEntities(from: rep)
        } else {
            storyEntities = []
        }
        let (interestMatch, novelty) = evaluateInterestProfile(
            article: rep,
            storyEntities: storyEntities,
            profile: context.profile
        )

        return EvaluatedStory(
            entry: entry,
            score: editorialScore,
            originalReportCount: originalCount,
            publisherCount: publisherCount,
            publisherAffinity: affinity,
            isTopQuartilePublisher: isTopQuartile,
            isStarredFeed: isStarred,
            isDeveloping: isDeveloping,
            groupingConfidence: groupingConfidence,
            isCoverageConfident: isCoverageConfident,
            readingTimeMinutes: readingTimeMinutes,
            contentType: contentType,
            interestMatch: interestMatch,
            novelty: novelty,
            hasInMotionUpdate: hasInMotionUpdate,
            momentum: momentum
        )
    }

    // MARK: - Editorial Score (`0.0...1.0`)

    /// Computes editorial relevance on a `0.0...1.0` scale without publisher affinity (affinity is a Lead
    /// tie-breaker only) and without reading any stored notification threshold.
    static func computeEditorialScore(
        originalCount: Int,
        assessedImportance: StoryImportance,
        hasSectorImpact: Bool,
        momentum: BriefingPriorityData.Momentum,
        isDeveloping: Bool,
        nlImportance: Double
    ) -> Double {
        // 1. Original reporting breadth (saturates smoothly by ~5 independent originals; wire copies count once).
        let breadth = min(1.0, log2(Double(max(1, originalCount))) / log2(6.0)) * 0.42

        // 2. Severity / Briefing impact rating (+ sector impact if overview exists).
        let importanceComponent: Double
        switch assessedImportance {
        case .major: importanceComponent = 0.28
        case .notable: importanceComponent = 0.16
        case .minor: importanceComponent = 0.04
        }
        let sectorBoost = (hasSectorImpact && assessedImportance != .major) ? 0.05 : 0.0

        // 3. NaturalLanguage semantic salience.
        let nlComponent = min(1.0, max(0.0, nlImportance)) * 0.20

        // 4. Active momentum / developing cadence.
        let momentumComponent: Double
        if momentum == .rising && isDeveloping {
            momentumComponent = 0.10
        } else if momentum == .rising || isDeveloping {
            momentumComponent = 0.07
        } else if momentum == .steady {
            momentumComponent = 0.02
        } else {
            momentumComponent = 0.0
        }

        return min(1.0, max(0.0, breadth + importanceComponent + sectorBoost + nlComponent + momentumComponent))
    }

    // MARK: - In Motion (24 h Clock & Material Change)

    /// Clock-based `hasSubstantiveUpdate` without unread/seen state (spec §2.2):
    /// Requires both reports older than 24 h ("known headlines") and at least one report within the last 24 h
    /// carrying material new reporting rather than repeating or paraphrasing a known headline.
    static func hasSubstantiveInMotionUpdate(
        _ summary: EventFeedSummary,
        now: Date,
        window: TimeInterval = 24 * 3600
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        let upperBound = now.addingTimeInterval(300)
        let knownMembers = summary.members.filter { $0.date < cutoff }
        let recentMembers = summary.members.filter { $0.date >= cutoff && $0.date <= upperBound }

        // Spec §2.2: An event whose reports all fall inside the 24 h is new, not updated.
        guard !knownMembers.isEmpty, !recentMembers.isEmpty else { return false }

        let knownTitles = knownMembers.map(\.title)
        let knownKeys = Set(knownTitles.map(EventFeedSummary.titleKey))
        let knownLemmaSets = knownTitles.map(headlineComparisonLemmas)

        return recentMembers.contains { candidate in
            let key = EventFeedSummary.titleKey(candidate.title)
            guard !key.isEmpty, !knownKeys.contains(key) else { return false }
            return isMaterialHeadlineChange(candidate: candidate.title, againstKnownTokenSets: knownLemmaSets)
        }
    }

    /// Distinguishes genuine new reporting / numbers / developments from same-story headline rewordings.
    static func isMaterialHeadlineChange(
        candidate: String,
        againstKnownTokenSets knownTokenSets: [Set<String>]
    ) -> Bool {
        let tokens = headlineComparisonLemmas(candidate)
        guard !tokens.isEmpty else { return false }
        for knownTokens in knownTokenSets where !knownTokens.isEmpty {
            let intersection = tokens.intersection(knownTokens).count
            let dice = (2.0 * Double(intersection)) / Double(tokens.count + knownTokens.count)
            let novelTokens = tokens.subtracting(knownTokens)
            let novelShare = Double(novelTokens.count) / Double(tokens.count)
            // High lemma Dice overlap (>= 0.60) or repeating core headline with <= 1 minor filler token is repetition.
            if dice >= 0.60 || (intersection >= 3 && novelTokens.count <= 1 && novelShare < 0.35) {
                return false
            }
        }
        return true
    }

    /// Lemmatized substantive headline tokens with weekday/temporal filler removed for material-change detection.
    static func headlineComparisonLemmas(_ text: String) -> Set<String> {
        let temporalFiller: Set<String> = [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "today", "yesterday", "tonight", "morning", "evening", "afternoon",
        ]
        let baseTokens = substantiveHeadlineTokens(text).subtracting(temporalFiller)
        guard !baseTokens.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var lemmas = Set<String>()
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let raw = (tag?.rawValue ?? String(text[range]))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if raw.count >= 3, !temporalFiller.contains(raw) {
                let surface = String(text[range])
                    .folding(
                        options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                if baseTokens.contains(surface) || baseTokens.contains(raw) {
                    lemmas.insert(raw)
                }
            }
            return true
        }
        return lemmas.isEmpty ? baseTokens : lemmas
    }

    // MARK: - The Deep Read (Stored Reading Time + Content-Type Classification)

    static func storedReadingTimeMinutes(
        for entry: FeedEntry,
        preloadedTexts: [String] = [],
        wordsPerMinute: Double = 200.0
    ) -> Double {
        let candidates =
            entry.visibleArticles.flatMap { article -> [String] in
                var texts: [String] = []
                if let doc = article.readerDocument {
                    texts.append(doc.blocks.map(\.text).joined(separator: " "))
                }
                if let body = article.fullContent, !body.isEmpty {
                    texts.append(body)
                }
                if !article.description.isEmpty {
                    texts.append(article.description)
                }
                return texts
            } + preloadedTexts

        let maxWords = candidates.map { $0.split { $0.isWhitespace || $0.isNewline }.count }.max() ?? 0
        guard wordsPerMinute > 0 else { return 0 }
        return Double(maxWords) / wordsPerMinute
    }

    /// Deterministic on-device content-type classifier over headline, feed summary, section/category and URL path.
    static func classifyContentType(
        title: String,
        description: String,
        category: String?,
        link: String = ""
    ) -> (type: TodayContentType, confidence: Double)? {
        let paddedTitle = MuteRules.paddedPhrase(title)
        let paddedSummary = MuteRules.paddedPhrase(description)
        let combined = "\(paddedTitle) \(paddedSummary)"
        let rawLower = "\(title) \(description) \(category ?? "") \(link)".lowercased()

        // Explicit URL/category or investigative-journalism markers carry highest confidence;
        // bare news briefs reporting "police launch investigation" stay news, not The Deep Read.
        let investigationExact: [String] = [
            "special report", "deep dive", "exclusive investigation", "an investigation by",
            "months long investigation", "documents reveal", "inside how",
        ]
        if rawLower.contains("/investigation") || rawLower.contains("/special-report")
            || title.lowercased().hasPrefix("investigation:")
            || investigationExact.contains(where: { combined.contains(MuteRules.paddedPhrase($0)) })
        {
            return (.investigation, 0.85)
        }

        let explainerExact: [String] = [
            "explainer", "explained", "how it works", "why it matters", "what to know",
            "what you need to know", "everything you need to know", "guide to", "q&a",
        ]
        if rawLower.contains("/explainer")
            || explainerExact.contains(where: { combined.contains(MuteRules.paddedPhrase($0)) })
            || title.lowercased().hasPrefix("explainer:")
            || title.lowercased().hasPrefix("how ") && title.contains("?")
        {
            return (.explainer, 0.80)
        }

        let opinionExact: [String] = [
            "opinion", "editorial", "commentary", "op ed", "columnist", "my view",
            "letters to the editor", "perspective", "viewpoint", "analysis and opinion",
        ]
        if rawLower.contains("/opinion") || rawLower.contains("/editorial") || rawLower.contains("/commentisfree")
            || (category?.lowercased().contains("opinion") == true)
            || opinionExact.contains(where: {
                paddedTitle.contains(MuteRules.paddedPhrase($0))
                    || MuteRules.paddedPhrase(category ?? "").contains(MuteRules.paddedPhrase($0))
            })
        {
            return (.opinion, 0.85)
        }
        if opinionExact.contains(where: { paddedSummary.contains(MuteRules.paddedPhrase($0)) }) {
            return (.opinion, 0.72)
        }

        return nil
    }

    // MARK: - Your Beat & Outside Your Usual (Finer Profile)

    /// Scores `interestMatch` (`0.0...1.0`) and `novelty` (`0.0...1.0`) against the 30-day finer profile.
    static func evaluateInterestProfile(
        article: FeedArticle,
        storyEntities: Set<String>,
        profile: TodayUserProfile
    ) -> (match: Double, novelty: Double) {
        guard profile.hasHistory else {
            return (0.0, 0.0)
        }

        // 1. Named entity match (`entity_mentions` / extracted named entities): strong fine signal.
        let maxEntityWeight = max(1.0, profile.entityWeights.values.max() ?? 1.0)
        let matchedEntityWeight = storyEntities.reduce(0.0) { total, id in
            total + (profile.entityWeights[id] ?? 0.0)
        }
        let entitySignal: Double
        if !storyEntities.isEmpty && !profile.entityWeights.isEmpty {
            entitySignal = min(1.0, matchedEntityWeight / max(2.0, maxEntityWeight * 1.15))
        } else {
            entitySignal = 0.0
        }

        // 2. Specific headline/section keyword match normalized by candidate length so single common
        // words cannot flood Your Beat across an entire library.
        let tokens = substantiveHeadlineTokens(article.title + " " + (article.category ?? ""))
        let maxKeywordWeight = max(1.0, profile.keywordWeights.values.max() ?? 1.0)
        let matchedKeywordWeight = tokens.reduce(0.0) { total, token in
            total + (profile.keywordWeights[token] ?? 0.0)
        }
        let denominator = max(3.0, Double(tokens.count)) * maxKeywordWeight * 0.30
        let keywordSignal =
            (!tokens.isEmpty && !profile.keywordWeights.isEmpty)
            ? min(1.0, matchedKeywordWeight / max(2.0, denominator))
            : 0.0

        // 3. Coarse 12-category share: strictly bounded (<= 0.18) so coarse category alone cannot clear 0.50.
        let totalCategoryWeight = max(1.0, profile.categoryWeights.values.reduce(0.0, +))
        let categorySignal: Double
        if let category = article.category.flatMap(NewsCategory.match(from:))?.rawValue.lowercased(),
            let catWeight = profile.categoryWeights[category],
            catWeight > 0
        {
            categorySignal = min(0.18, (catWeight / totalCategoryWeight) * 0.45)
        } else {
            categorySignal = 0.0
        }

        // Combined fine match (`0.0...1.0`)
        let rawFine = max(entitySignal, keywordSignal) * 0.75 + min(entitySignal, keywordSignal) * 0.15 + categorySignal
        let match = min(1.0, max(0.0, rawFine))
        let novelty = min(1.0, max(0.0, 1.0 - match))
        return (match, novelty)
    }

    // MARK: - Helper Signals

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

    static func isPromotionalDeal(title: String) -> Bool {
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("deals:") || lower.hasPrefix("deal:") { return true }
        let padded = MuteRules.paddedPhrase(lower)
        let promoCues = ["black friday", "cyber monday", "doorbusters", "amazon prime day", "best deals on"]
        return promoCues.contains { padded.contains(MuteRules.paddedPhrase($0)) }
    }

    private static func fallbackGroupingConfidence(for summary: EventFeedSummary) -> Double {
        let titles = summary.members.map(\.title)
        guard titles.count >= 2 else { return 0.0 }
        let tokenSets = titles.map(substantiveHeadlineTokens)
        var pairs = 0
        var totalSim = 0.0
        for i in tokenSets.indices {
            for j in tokenSets.indices where j > i {
                let a = tokenSets[i]
                let b = tokenSets[j]
                let union = a.union(b).count
                guard union > 0 else { continue }
                let jaccard = Double(a.intersection(b).count) / Double(union)
                totalSim += jaccard
                pairs += 1
            }
        }
        guard pairs > 0 else { return 0.0 }
        // Scale cohesive headline overlap into the 0.55–0.95 grouping range when pair_assessments isn't loaded.
        let meanJaccard = totalSim / Double(pairs)
        return min(0.95, 0.50 + meanJaccard * 1.25)
    }

    static func substantiveHeadlineTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "and", "for", "that", "with", "from", "this", "are", "was", "were",
            "will", "have", "has", "had", "not", "but", "what", "when", "where", "who",
            "why", "how", "about", "after", "before", "over", "into", "onto", "than",
            "more", "most", "new", "says", "said", "amid", "near", "under", "between",
            "could", "would", "should", "may", "might", "can", "his", "her", "their",
            "our", "its", "all", "one", "two", "first", "last", "year", "years", "day",
            "days", "week", "news", "report", "reports", "update", "updates", "live",
        ]
        return Set(
            MuteRules.foldedWords(text)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }

    static func extractFallbackEntities(from article: FeedArticle) -> Set<String> {
        if let stored = article.entities, !stored.isEmpty {
            return Set(stored.map { EntityGraph.slug(name: $0.name, type: $0.type) })
        }
        let text = "\(article.title). \(article.description)"
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var slugs = Set<String>()
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard let tag else { return true }
            let entityType: EntityType
            switch tag {
            case .personalName: entityType = .person
            case .organizationName: entityType = .organization
            case .placeName: entityType = .place
            default: return true
            }
            let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count >= 2 {
                slugs.insert(EntityGraph.slug(name: name, type: entityType))
            }
            return slugs.count < 16
        }
        return slugs
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
