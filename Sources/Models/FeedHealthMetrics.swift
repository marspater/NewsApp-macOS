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
    var attempts = 0
    var successes = 0
    /// Seconds spent on successful requests; attempts, successes and this total are halved together as they age.
    var latencyTotal: TimeInterval = 0
    /// Stories published inside `FeedHealthMetrics.frequencyWindow`, and the oldest of them.
    var recentItems = 0
    var oldestRecentItem: Date?
    var fullReader = 0
    var teaser = 0
    var subscriberOnly = 0
    var blocked = 0
}

/// Per-feed plumbing numbers for the Publisher Health inspector (#715). Like `FeedHealth`, these describe how a feed
/// behaves technically and never rate its accuracy or trustworthiness. Pure, so the arithmetic needs no database.
struct FeedHealthMetrics: Equatable, Sendable {
    enum ExtractionClass: Equatable, Sendable { case unknown, fullReader, teaser, paywall, blocked }

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

    init(_ observed: FeedHealthObservations, now: Date) {
        successRate = observed.attempts > 0 ? Double(observed.successes) / Double(observed.attempts) : nil
        averageLatency = observed.successes > 0 ? observed.latencyTotal / Double(observed.successes) : nil
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
