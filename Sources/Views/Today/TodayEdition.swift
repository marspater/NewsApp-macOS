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

/// What the Today page shows: the stories of each lane in page order and every card's metadata (#935, #936).
/// Built off the main actor from the listed stories; a view only reads it.
struct TodayEdition: Equatable, Sendable {
    struct Lane: Equatable, Sendable, Identifiable {
        var id: TodayLane { lane }
        let lane: TodayLane
        var stories: [TodayStoryAssignment]
    }

    /// The lanes that show, in page order: The Lead, the conditional lanes that cleared their bars, The Latest.
    var lanes: [Lane] = []
    var metadata: [String: StoryCardMetadata] = [:]
    /// The list generation this edition was built for (`ArticleListView.todayGeneration`).
    var generation = 0

    func stories(in lane: TodayLane) -> [TodayStoryAssignment] {
        lanes.first { $0.lane == lane }?.stories ?? []
    }

    var lead: [TodayStoryAssignment] { stories(in: .theLead) }
    var latest: [TodayStoryAssignment] { stories(in: .theLatest) }
    var conditionalLanes: [Lane] { lanes.filter { $0.lane.isConditional } }
    var storyIDs: Set<String> { Set(lanes.flatMap { $0.stories.map(\.id) }) }

    /// The keyboard map of the page; `latestColumns` is how many cards a row of The Latest holds.
    func focusMap(latestColumns: Int) -> TodayFocusMap {
        TodayFocusMap(
            lanes: lanes.map {
                TodayFocusMap.Lane(
                    lane: $0.lane, ids: $0.stories.map(\.id),
                    columns: $0.lane == .theLatest ? max(1, latestColumns) : 0)
            })
    }

    /// The first images the page shows, The Lead's first: the first slide, the leading cards of each lane and the
    /// first rows of The Latest.
    var initialImageURLs: [URL] {
        lanes.flatMap { lane -> [URL] in
            let count: Int
            switch lane.lane {
            case .theLead: count = 1
            case .theLatest: count = 9
            default: count = 5
            }
            return lane.stories.prefix(count).compactMap(\.entry.cardImageURL)
        }
    }

    // MARK: - Building

    /// Lays the listed stories out as an edition.
    ///
    /// A new edition (`previous` nil) follows the assignment `plan`. An edition that is already on screen keeps
    /// every story in its lane, because nothing moves until the reader applies an update (docs/design/today.md,
    /// "Updates"): its cards take the fresh values, a story that left the list leaves its lane, and stories the
    /// list gained (a further page) join The Latest. A listed story the plan did not place, such as one from a
    /// feed the reader no longer subscribes to, also goes to The Latest: Today never hides a listed story.
    static func make(
        entries: [FeedEntry], plan: TodayEditionPlan, differingAccounts: [String: String] = [:],
        keeping previous: TodayEdition? = nil, generation: Int = 0
    ) -> TodayEdition {
        var fresh: [String: TodayStoryAssignment] = [:]
        for assignment in plan.allAssignments { fresh[assignment.id] = assignment }
        let listedIDs = Set(entries.map(\.id))
        var laneStories: [TodayLane: [TodayStoryAssignment]] = [:]
        var placed = Set<String>()

        if let previous, !previous.lanes.isEmpty {
            for lane in previous.lanes {
                for story in lane.stories where listedIDs.contains(story.id) {
                    // The card keeps its content-type tag too, also when the fresh plan would move the story.
                    let current =
                        fresh[story.id]?.placed(in: lane.lane, contentType: story.contentTypeLabel) ?? story
                    laneStories[lane.lane, default: []].append(current)
                    placed.insert(story.id)
                }
            }
        } else {
            for result in plan.displayLanes where result.qualifies || !result.lane.isConditional {
                // A lane the plan hid passed its stories on already; only shown lanes hold cards.
                laneStories[result.lane] = result.entries
                placed.formUnion(result.entries.map(\.id))
            }
        }
        for entry in entries where !placed.contains(entry.id) {
            laneStories[.theLatest, default: []].append(
                fresh[entry.id]?.placed(in: .theLatest) ?? .unplaced(entry))
        }

        var edition = TodayEdition(generation: generation)
        edition.lanes = TodayLane.displayOrder.compactMap { lane in
            guard let stories = laneStories[lane], !stories.isEmpty else { return nil }
            return Lane(lane: lane, stories: stories)
        }
        for lane in edition.lanes {
            for story in lane.stories {
                var metadata = StoryCardMetadata(story, differingAccount: differingAccounts[story.id])
                metadata.laneName = lane.lane.rawValue
                edition.metadata[story.id] = metadata
            }
        }
        return edition
    }
}

extension TodayStoryAssignment {
    /// The same story shown in another lane; its scores and evidence are unchanged.
    func placed(in lane: TodayLane, contentType kept: TodayContentType? = nil) -> TodayStoryAssignment {
        guard lane != self.lane else { return self }
        return TodayStoryAssignment(
            id: id, entry: entry, lane: lane, score: score, confidence: confidence, reason: reason,
            sortKey: sortKey, contentTypeLabel: lane == .theDeepRead ? (contentTypeLabel ?? kept) : nil,
            isCoverageConfident: isCoverageConfident, isDeveloping: isDeveloping,
            originalReportCount: originalReportCount, publisherCount: publisherCount,
            groupingConfidence: groupingConfidence, readingTimeMinutes: readingTimeMinutes,
            interestMatch: interestMatch, novelty: novelty)
    }

    /// A listed story the assignment did not see, shown in The Latest with no claims about it.
    static func unplaced(_ entry: FeedEntry) -> TodayStoryAssignment {
        TodayStoryAssignment(
            id: entry.id, entry: entry, lane: .theLatest, score: 0, confidence: 0, reason: "listed_unassigned",
            sortKey: entry.representative.pubDate, contentTypeLabel: nil, isCoverageConfident: false,
            isDeveloping: false, originalReportCount: 1, publisherCount: entry.publisherCount,
            groupingConfidence: 0, readingTimeMinutes: 0, interestMatch: 0, novelty: 0)
    }
}

/// What the lane assignment needs to know about the reader, from their settings.
struct TodayReader: Sendable {
    var subscribedFeedURLs: Set<String>
    var starredFeedURLs: Set<String>
    /// Reading interests count from here when the reader reset them.
    var interestsResetAt: Date?
}

extension ArticleStore {
    /// Assigns the listed stories to lanes and reads what their cards show, off the main actor. A failed read
    /// leaves every story in The Latest rather than an empty page.
    func todayEdition(
        entries: [FeedEntry], reader: TodayReader, keeping previous: TodayEdition?, generation: Int
    ) async -> TodayEdition {
        let database = self.database
        let now = Date()
        do {
            let context = try await database.loadTodayAssignmentContext(
                entries: entries, now: now, starredFeedURLs: reader.starredFeedURLs,
                subscribedFeedURLs: reader.subscribedFeedURLs, resetAt: reader.interestsResetAt)
            try Task.checkCancellation()
            let plan = await Task.detached(priority: .userInitiated) {
                TodayEditionAssigner.assign(entries: entries, context: context)
            }.value
            try Task.checkCancellation()
            let accounts = (try? await database.todayDifferingAccounts(for: plan)) ?? [:]
            return TodayEdition.make(
                entries: entries, plan: plan, differingAccounts: accounts, keeping: previous, generation: generation)
        } catch {
            return TodayEdition.make(
                entries: entries, plan: TodayEditionPlan(lanes: []), keeping: previous, generation: generation)
        }
    }
}
