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

    /// A profile with no history.
    static let empty = TodayUserProfile(
        categoryWeights: [:],
        entityWeights: [:],
        keywordWeights: [:],
        publisherWeights: [:],
        topQuartilePublishers: [],
        interactionCount: 0
    )

    /// Creates a profile; nil `topQuartilePublishers` and `interactionCount` are derived from the weights.
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

    /// Whether there is enough history to personalize: three interactions, or entity weight of 2 or keyword weight of
    /// 3.
    var hasHistory: Bool {
        interactionCount >= 3
            || entityWeights.values.reduce(0, +) >= 2.0
            || keywordWeights.values.reduce(0, +) >= 3.0
    }

    /// The key of ``publisherWeights`` for a stored story: the catalog's publisher for its link, else its source.
    static func publisherKey(source: String?, link: String?) -> String {
        EventFeedSummary.displaySource(FeedCatalog.publisher(forLink: link ?? "") ?? source ?? "").lowercased()
    }

    /// Publisher affinity on a `0.0...1.0` scale relative to the reader's highest-engaged publisher.
    func publisherAffinity(for publisher: String) -> Double {
        let key = EventFeedSummary.displaySource(publisher).lowercased()
        guard let weight = publisherWeights[key], weight > 0 else { return 0.0 }
        let maxWeight = max(1.0, publisherWeights.values.max() ?? 1.0)
        return min(1.0, weight / maxWeight)
    }

    /// Whether the publisher is among `topQuartilePublishers`.
    func isTopQuartilePublisher(_ publisher: String) -> Bool {
        let key = EventFeedSummary.displaySource(publisher).lowercased()
        return topQuartilePublishers.contains(key)
    }

    /// The top quarter, at least one, of publishers with a weight of 2 or more, heaviest first and ties by name.
    static func computeTopQuartilePublishers(from weights: [String: Double]) -> Set<String> {
        let engaged = weights.filter { $0.value >= 2.0 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        guard !engaged.isEmpty else { return [] }
        let topCount = max(1, Int(ceil(Double(engaged.count) * 0.25)))
        return Set(engaged.prefix(topCount).map(\.key))
    }

    /// The affinity publishers of the rule evaluated on 12 November 2026 (#934): the top quartile of engaged
    /// publishers (weight >= 2, as above) by engagement per story published, then without those the reader read or
    /// saved fewer than `floor` stories of. `windowWeights` is the engagement with stories published in the profile
    /// window, so a read of an older story cannot lift a publisher that published nothing in it.
    static func perStoryAffinityPublishers(
        weights: [String: Double], windowWeights: [String: Double], storiesRead: [String: Int],
        published: [String: Int], floor: Int
    ) -> Set<String> {
        func rate(_ key: String) -> Double {
            windowWeights[key, default: 0] / Double(max(1, published[key, default: 0]))
        }
        let engaged = weights.filter { $0.value >= 2.0 }.keys.sorted {
            rate($0) == rate($1) ? $0 < $1 : rate($0) > rate($1)
        }
        guard !engaged.isEmpty else { return [] }
        let topCount = max(1, Int(ceil(Double(engaged.count) * 0.25)))
        return Set(engaged.prefix(topCount).filter { storiesRead[$0, default: 0] >= floor })
    }
}

/// Optional stored evidence preloaded for one story entry (#934).
/// When absent, ``TodayEditionAssigner`` derives conservative signals directly from `FeedEntry`.
struct TodayStorySignals: Equatable, Sendable {
    /// Original reports in the story's event; nil derives the count from the entry.
    var originalReportCount: Int?
    /// Stored full texts of the event's members, read for reading time and content type.
    var memberFullTexts: [String] = []
    /// Entity slugs of the story; empty derives them from the representative when the profile has entity weights.
    var entityIDs: Set<String> = []
    /// Additional feed URLs of the story's reports, for the starred-feed check.
    var feedURLs: Set<String> = []
    /// Whether the story's overview has an Industry Impact section, which raises the editorial score of a story that
    /// is not major.
    var hasSectorImpact: Bool = false
    /// Confidence that the event's reports belong together; nil derives it from the event summary.
    var groupingConfidence: Double?
    /// Replaces the NaturalLanguage importance score.
    var nlImportanceOverride: Double?
    /// Replaces the assessed Briefing importance.
    var resolvedImportanceOverride: StoryImportance?
}

/// Context passed into one deterministic Today lane-assignment pass.
struct TodayAssignmentContext: Equatable, Sendable {
    /// The time the edition is assembled for.
    var now: Date
    /// Selected subscription feed URLs (normalized via `AppSettings.feedKey` when present).
    /// When non-nil, only entries with at least one visible article matching a subscribed feed enter Today.
    var subscribedFeedURLs: Set<String>?
    /// Feeds the reader starred; their stories qualify for Your Beat.
    var starredFeedURLs: Set<String>
    /// The reader's interest and publisher profile.
    var profile: TodayUserProfile
    /// Preloaded signals by story entry id.
    var signalsByEntryID: [String: TodayStorySignals]
    /// The lane thresholds.
    var thresholds: TodayEditionThresholds
    /// Stories with no photo to show: none in any report of the event, or one that failed to load. The Lead is a
    /// photo slide, so they are not candidates for it (Mars, 11 November 2026); every other lane takes them.
    var imagelessEntryIDs: Set<String> = []

    /// Creates a context; `imagelessEntryIDs` starts empty.
    init(
        now: Date = Date(),
        subscribedFeedURLs: Set<String>? = nil,
        starredFeedURLs: Set<String> = [],
        profile: TodayUserProfile = .empty,
        signalsByEntryID: [String: TodayStorySignals] = [:],
        thresholds: TodayEditionThresholds = .standard
    ) {
        self.now = now
        self.subscribedFeedURLs = subscribedFeedURLs
        self.starredFeedURLs = starredFeedURLs
        self.profile = profile
        self.signalsByEntryID = signalsByEntryID
        self.thresholds = thresholds
    }
}
