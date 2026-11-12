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

// Angelia · Athena (editorial selection) owns this file. Register: docs/ANGELIA.md.

import Foundation

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
    /// Evaluation option, off by default (#934, 11 November 2026). When set, In Motion asks two separate questions:
    /// is the story already underway (a report older than ``inMotionWindowSeconds``), and how recent is the new
    /// report (dated within this many seconds). A candidate report is then compared against every report dated
    /// before it, not only against those older than the window.
    var inMotionUpdateWindowSeconds: TimeInterval?
    /// Evaluation option (#934, 11 November 2026). When false, steady and fading momentum also enter In Motion;
    /// the headline test for a substantive update still applies.
    var inMotionRequiresRisingMomentum = true

    var deepReadMinimumMinutes = 8.0
    var deepReadWordsPerMinute = 200.0
    var deepReadClassificationMinimumConfidence = 0.70
    var deepReadMinimumConfidence = 0.60

    var yourBeatInterestMatchMinimum = 0.50
    var yourBeatMinimumConfidence = 0.60
    /// Evaluation option (#934, 11 November 2026). Above zero, publisher affinity is a booster: it qualifies a
    /// story for Your Beat only together with an interest match of at least this value. Starred feeds and an
    /// interest match of ``yourBeatInterestMatchMinimum`` still qualify on their own.
    var yourBeatAffinityInterestMinimum = 0.0
    /// Evaluation option, off by default (#934, 12 November 2026). When set, Your Beat's affinity publishers are
    /// the top quartile of engaged publishers by engagement per story published in the profile window, less those
    /// with fewer than this many read or saved stories (``TodayUserProfile/perStoryAffinityPublishers``). The
    /// loader counts the stories each publisher published only while this is set.
    var yourBeatAffinityPerStoryFloor: Int?

    var outsideNoveltyMinimum = 0.60
    var outsideScoreMinimum = 0.35
    var outsideMinimumConfidence = 0.60

    var coverageMinimumPublishers = 3
    var coverageMinimumOriginalReports = 2
    var coverageMinimumGroupingConfidence = 0.70

    var developingWindowSeconds: TimeInterval = 3600

    static let standard = TodayEditionThresholds()
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
