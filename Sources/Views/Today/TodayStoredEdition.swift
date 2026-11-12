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

import CryptoKit
import Foundation

/// The last complete Today edition as it is kept beside the library (#937): which story sits in which lane, in page
/// order, with what its card showed. No headline or text. At the next launch the page is laid out from it at once,
/// while the fresh edition is worked out behind it.
struct TodayStoredEdition: Codable, Equatable, Sendable {
    /// Raised when the stored fields or the lane rules change, so an edition of another build is not restored.
    static let formatVersion = 1
    /// An edition older than this is not restored: the 72 h window of Today's candidates.
    static let maximumAge: TimeInterval = 72 * 3600

    struct Story: Codable, Equatable, Sendable {
        var id: String
        var contentType: String?
        var isCoverageConfident: Bool
        var isDeveloping: Bool
        var originalReportCount: Int
        var publisherCount: Int
        var readingTimeMinutes: Double
        var score: Double
        /// The event's best photo, for a story whose listed reports carry none.
        var eventImage: URL?
        var differingAccount: String?
    }

    struct Lane: Codable, Equatable, Sendable {
        var lane: String
        var stories: [Story]
    }

    var version = TodayStoredEdition.formatVersion
    var builtAt: Date
    /// The reader settings the edition was assigned under (`identity(feedURLs:starredFeedURLs:interestsResetAt:)`).
    var identity: String
    var lanes: [Lane]

    /// Why a stored edition was not restored; the launch log names it.
    enum Rejection: String, Error, Equatable {
        case otherFormat, otherReader, tooOld, noLead, storiesGone
    }

    /// The subscriptions, starred feeds and interests reset an assignment depends on, as a digest: an edition
    /// assigned under other settings would show stories of feeds the reader has left, or lanes of another taste.
    static func identity(feedURLs: [String], starredFeedURLs: Set<String>, interestsResetAt: Date?) -> String {
        let parts =
            ["v\(formatVersion)"] + feedURLs.sorted() + ["starred"] + starredFeedURLs.sorted()
            + ["reset:\(interestsResetAt?.timeIntervalSince1970 ?? 0)"]
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(_ edition: TodayEdition, identity: String, builtAt: Date) {
        self.builtAt = builtAt
        self.identity = identity
        lanes = edition.lanes.map { lane in
            Lane(
                lane: lane.lane.rawValue,
                stories: lane.stories.map { story in
                    Story(
                        id: story.id, contentType: story.contentTypeLabel?.rawValue,
                        isCoverageConfident: story.isCoverageConfident, isDeveloping: story.isDeveloping,
                        originalReportCount: story.originalReportCount, publisherCount: story.publisherCount,
                        readingTimeMinutes: story.readingTimeMinutes, score: story.score,
                        eventImage: edition.metadata[story.id]?.imageURL,
                        differingAccount: edition.metadata[story.id]?.differingAccount)
                })
        }
    }

    /// The edition as the page shows it for the stories listed now, or the reason it cannot be shown.
    ///
    /// Stories that left the list leave their lanes, and listed stories the edition did not hold go to The Latest,
    /// both through `TodayEdition.make(…keeping:)`, which is what holds an edition on screen. A Lead slide whose
    /// photo is missing or failed to load leaves The Lead, as in a fresh assignment.
    func restored(
        entries: [FeedEntry], identity current: String, failedImageURLs: Set<URL> = [], now: Date = Date(),
        generation: Int = 0
    ) -> Result<TodayEdition, Rejection> {
        guard version == Self.formatVersion else { return .failure(.otherFormat) }
        guard identity == current else { return .failure(.otherReader) }
        let age = now.timeIntervalSince(builtAt)
        guard age >= -300, age <= Self.maximumAge else { return .failure(.tooOld) }

        let listed = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var details = TodayCardDetails()
        var held = TodayEdition(generation: generation)
        var storedInLanes = 0
        var listedInLanes = 0
        for stored in lanes {
            guard let lane = TodayLane(rawValue: stored.lane) else { return .failure(.otherFormat) }
            var stories: [TodayStoryAssignment] = []
            for story in stored.stories {
                if lane != .theLatest { storedInLanes += 1 }
                guard let entry = listed[story.id] else { continue }
                if lane != .theLatest { listedInLanes += 1 }
                if lane == .theLead {
                    guard let photo = entry.cardImageURL ?? story.eventImage, !failedImageURLs.contains(photo)
                    else { continue }
                }
                details.eventImages[story.id] = story.eventImage
                details.differingAccounts[story.id] = story.differingAccount
                stories.append(
                    TodayStoryAssignment(
                        id: story.id, entry: entry, lane: lane, score: story.score, confidence: 0,
                        reason: "restored", sortKey: entry.representative.orderDate,
                        contentTypeLabel: story.contentType.flatMap(TodayContentType.init(rawValue:)),
                        isCoverageConfident: story.isCoverageConfident, isDeveloping: story.isDeveloping,
                        originalReportCount: story.originalReportCount, publisherCount: story.publisherCount,
                        groupingConfidence: 0, readingTimeMinutes: story.readingTimeMinutes, interestMatch: 0,
                        novelty: 0))
            }
            if !stories.isEmpty { held.lanes.append(TodayEdition.Lane(lane: lane, stories: stories)) }
        }
        // An edition most of whose lane stories have left the list describes another page.
        guard listedInLanes * 2 >= storedInLanes else { return .failure(.storiesGone) }
        guard !held.lead.isEmpty else { return .failure(.noLead) }
        var edition = TodayEdition.make(
            entries: entries, plan: TodayEditionPlan(lanes: []), details: details, keeping: held,
            generation: generation)
        edition.isRestored = true
        return .success(edition)
    }
}

extension TodayEdition {
    /// The same stories in the same lanes and order: a fresh edition that only confirms the one on screen.
    func hasSameArrangement(as other: TodayEdition) -> Bool {
        lanes.map(\.lane) == other.lanes.map(\.lane)
            && zip(lanes, other.lanes).allSatisfy { $0.stories.map(\.id) == $1.stories.map(\.id) }
    }
}

/// What happens to the fresh edition once it is ready behind a restored one.
enum TodayRestoreOutcome: String, Equatable {
    /// The fresh edition has the same arrangement: it replaces the restored one unseen.
    case confirmed
    /// It differs and the reader has not touched the page: it takes the page.
    case swapped
    /// It differs and the page is in use, or another day's page is on its way: it waits behind the updates button.
    case held

    static func decide(sameArrangement: Bool, isTouched: Bool, awaitsNewDay: Bool) -> TodayRestoreOutcome {
        if sameArrangement { return .confirmed }
        return isTouched || awaitsNewDay ? .held : .swapped
    }
}
