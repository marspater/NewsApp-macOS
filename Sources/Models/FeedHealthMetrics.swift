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

/// Why the reader could not take a story's text from its publisher's page (#715). Recorded per story; a later
/// complete extraction outranks it, so nothing has to clear it.
enum ReaderBarrier: String, Sendable {
    /// The publisher shows non-subscribers only a barrier.
    case subscriber
    /// A bot check or regional block answered 403; the publisher's page still opens in the Web View.
    case blocked

    /// The barrier an extraction outcome shows: subscriber-only, or a 403; nil for any other outcome.
    init?(_ outcome: ExtractionOutcome) {
        switch outcome {
        case .subscriberOnly: self = .subscriber
        case .httpError(status: 403): self = .blocked
        default: return nil
        }
    }
}

/// What the library has stored about one feed, as `DatabaseEngine.feedHealthMetrics(now:)` reads it.
struct FeedHealthObservations: Equatable, Sendable {
    /// Weighted, not whole, counts: aging halves attempts, successes and latency together, so rates and means hold.
    var attempts = 0.0
    /// Weighted successful requests.
    var successes = 0.0
    /// Seconds spent on successful requests.
    var latencyTotal: TimeInterval = 0
    /// Stories published inside `FeedHealthMetrics.frequencyWindow`, and the oldest of them.
    var recentItems = 0
    var oldestRecentItem: Date?
    /// Stories whose page gave complete text.
    var fullReader = 0
    /// Stories whose page gave only a teaser.
    var teaser = 0
    /// Stories behind a subscriber barrier.
    var subscriberOnly = 0
    /// Stories whose page answered 403.
    var blocked = 0
}

/// Per-feed plumbing numbers for the Publisher Health inspector (#715). Like `FeedHealth`, these describe how a feed
/// behaves technically and never rate its accuracy or trustworthiness. Pure, so the arithmetic needs no database.
struct FeedHealthMetrics: Equatable, Sendable {
    /// The most common reader result among the feed's opened stories; unknown below `minimumAssessedStories`.
    enum ExtractionClass: Equatable, Sendable { case unknown, fullReader, teaser, paywall, blocked }

    /// The window `itemsPerDay` counts stories over.
    static let frequencyWindow: TimeInterval = 30 * 24 * 60 * 60
    /// Fewer stories than this with a known extraction result name no class: one barrier is not a paywalled feed.
    static let minimumAssessedStories = 3

    /// Share of counted requests that succeeded, nil before the first one.
    let successRate: Double?
    /// Mean seconds per successful request, nil before the first one.
    let averageLatency: TimeInterval?
    /// Stories per day over the window, or since the oldest stored story when that is sooner; nil with no recent
    /// story. Retention deletes read stories, so this can read low.
    let itemsPerDay: Double?
    let extractionClass: ExtractionClass
    /// Stories with a known extraction result, and the share of them with complete text.
    let assessedStories: Int
    let fullReaderShare: Double?

    /// Derives the rates, means and extraction class from the stored observations.
    init(_ observed: FeedHealthObservations, now: Date) {
        successRate = observed.attempts > 0 ? observed.successes / observed.attempts : nil
        averageLatency = observed.successes > 0 ? observed.latencyTotal / observed.successes : nil
        if observed.recentItems > 0, let oldest = observed.oldestRecentItem {
            let days = max(1, now.timeIntervalSince(oldest) / (24 * 60 * 60))
            itemsPerDay = Double(observed.recentItems) / days
        } else {
            itemsPerDay = nil
        }
        let assessed = observed.fullReader + observed.teaser + observed.subscriberOnly + observed.blocked
        assessedStories = assessed
        fullReaderShare = assessed > 0 ? Double(observed.fullReader) / Double(assessed) : nil
        extractionClass = assessed < Self.minimumAssessedStories ? .unknown : Self.largestClass(observed)
    }

    /// The most common result; a tie goes to the class that says least against the feed.
    private static func largestClass(_ observed: FeedHealthObservations) -> ExtractionClass {
        let ordered: [(ExtractionClass, Int)] = [
            (.fullReader, observed.fullReader), (.teaser, observed.teaser), (.blocked, observed.blocked),
            (.paywall, observed.subscriberOnly),
        ]
        return ordered.reduce(ordered[0]) { $1.1 > $0.1 ? $1 : $0 }.0
    }
}

/// What the Publisher Health inspector suggests about a feed. These are about the feed's plumbing, never its reporting.
enum FeedHealthRecommendation: String, CaseIterable, Sendable {
    case notResponding = "Not responding"
    case inactive = "Inactive for over 30 days"
    case requiresWebView = "Requires Web View"
}

/// The table's sort. A measured value never sorts below an unavailable one, ascending or descending, so the highest
/// and lowest measured values stay at the top; text columns compare as a reader would sort names (#715).
struct PublisherHealthSort: SortComparator, Hashable, Sendable {
    /// The table column a sort uses.
    enum Column: Hashable, Sendable { case name, success, latency, frequency, extraction, recommendation }

    var column: Column
    var order: SortOrder

    /// Sorts by a column, ascending by default.
    init(_ column: Column, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    /// Compares two rows by the sort's column and order: text columns with `localizedStandardCompare`, numeric columns
    /// with unavailable values last in either direction.
    func compare(_ lhs: PublisherHealthRow, _ rhs: PublisherHealthRow) -> ComparisonResult {
        switch column {
        case .name: return text(lhs.name, rhs.name)
        case .extraction: return text(lhs.extractionText, rhs.extractionText)
        case .recommendation: return text(lhs.recommendationText, rhs.recommendationText)
        case .success: return number(lhs.successSortKey, rhs.successSortKey)
        case .latency: return number(lhs.latencySortKey, rhs.latencySortKey)
        case .frequency: return number(lhs.frequencySortKey, rhs.frequencySortKey)
        }
    }

    private func text(_ lhs: String, _ rhs: String) -> ComparisonResult {
        order == .forward ? lhs.localizedStandardCompare(rhs) : rhs.localizedStandardCompare(lhs)
    }

    private func number(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        guard let lhs else { return rhs == nil ? .orderedSame : .orderedDescending }
        guard let rhs else { return .orderedAscending }
        let (low, high) = order == .forward ? (lhs, rhs) : (rhs, lhs)
        if low < high { return .orderedAscending }
        return low > high ? .orderedDescending : .orderedSame
    }
}

/// One feed's row in the Publisher Health table: its numbers, recommendations, display text and sort keys. Pure, so
/// the wording and order need no view. Unknown values sort last in either direction.
struct PublisherHealthRow: Identifiable, Equatable, Sendable {
    /// What a cell shows for a value not measured yet.
    static let unknownText = "—"
    /// The note under the table: the feed health disclaimer and where the numbers come from.
    static let footnote =
        FeedHealth.disclaimer
        + " Request numbers build up with each refresh, and text results come from stories that have been opened."

    /// The feed's URL.
    let id: String
    let name: String
    let metrics: FeedHealthMetrics
    let recommendations: [FeedHealthRecommendation]

    /// Builds the row and its recommendations: not responding while failing, inactive while stale, and Web View when a
    /// paywall or a block is the most common result among opened stories.
    init(feedURL: String, storedPublisher: String?, metrics: FeedHealthMetrics, health: FeedHealth?) {
        id = feedURL
        name = Self.name(feedURL: feedURL, storedPublisher: storedPublisher)
        self.metrics = metrics
        var suggestions: [FeedHealthRecommendation] = []
        if case .failing = health?.availability { suggestions.append(.notResponding) }
        if health?.freshness == .stale { suggestions.append(.inactive) }
        if metrics.extractionClass == .paywall || metrics.extractionClass == .blocked {
            suggestions.append(.requiresWebView)
        }
        recommendations = suggestions
    }

    /// The catalog's title tells a publisher's feeds apart; otherwise what its stories call it, then its host.
    static func name(feedURL: String, storedPublisher: String?) -> String {
        if let title = FeedCatalog.allFeeds.first(where: { $0.url == feedURL })?.title { return title }
        if let storedPublisher, !storedPublisher.isEmpty { return storedPublisher }
        return URL(string: feedURL)?.host ?? feedURL
    }

    /// Nil is unavailable, which `PublisherHealthSort` keeps last in both directions.
    var successSortKey: Double? { metrics.successRate }
    var latencySortKey: Double? { metrics.averageLatency }
    /// Stories a day; 0 for a feed that answered but has no recent story, nil before any request.
    var frequencySortKey: Double? { metrics.itemsPerDay ?? (metrics.successRate == nil ? nil : 0) }

    /// Rounded down, so 100% means no failure.
    var successText: String {
        metrics.successRate.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? Self.unknownText
    }
    /// `successText` for VoiceOver, with "percent" spelled out.
    var successSpoken: String {
        metrics.successRate.map { "\(Int(($0 * 100).rounded(.down))) percent" } ?? Self.notMeasured
    }
    /// Mean latency to one decimal place, in seconds.
    var latencyText: String { metrics.averageLatency.map { String(format: "%.1f s", $0) } ?? Self.unknownText }
    /// `latencyText` for VoiceOver, with "seconds" spelled out.
    var latencySpoken: String {
        metrics.averageLatency.map { String(format: "%.1f seconds", $0) } ?? Self.notMeasured
    }
    /// Stories a day: whole numbers from 10 up, one decimal below, "<0.1" for fewer, "0" for a responding feed with no
    /// recent story.
    var frequencyText: String {
        guard let perDay = metrics.itemsPerDay else { return metrics.successRate == nil ? Self.unknownText : "0" }
        if perDay < 0.1 { return "<0.1" }
        return String(format: perDay >= 10 ? "%.0f" : "%.1f", perDay)
    }
    /// `frequencyText` for VoiceOver.
    var frequencySpoken: String {
        let text = frequencyText
        if text == Self.unknownText { return Self.notMeasured }
        return text == "<0.1" ? "Less than 0.1 stories a day" : "\(text) stories a day"
    }
    /// The extraction class as the table names it.
    var extractionText: String {
        switch metrics.extractionClass {
        case .unknown: return "Unknown"
        case .fullReader: return "Full reader"
        case .teaser: return "Teaser"
        case .paywall: return "Paywall"
        case .blocked: return "Blocked"
        }
    }
    /// The recommendations joined with middle dots; empty when there are none.
    var recommendationText: String { recommendations.map(\.rawValue).joined(separator: " · ") }

    private static let notMeasured = "Not measured yet"
}
