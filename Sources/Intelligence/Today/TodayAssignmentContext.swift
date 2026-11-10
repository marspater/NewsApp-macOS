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
