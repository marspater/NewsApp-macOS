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
    /// Laid out afresh from a lane assignment that succeeded: the only kind kept for the next launch.
    var isAssigned = false
    /// Laid out from the edition kept at the last launch, while the fresh one is worked out (#937).
    var isRestored = false
    /// Listed stories left out because the reader has left all their feeds (`TodayCardDetails.unsubscribedIDs`).
    var excludedIDs: Set<String> = []
    /// The library's analysis generation when the edition's details were read; a clear since then removed them.
    var analysisGeneration: Int?

    func stories(in lane: TodayLane) -> [TodayStoryAssignment] {
        lanes.first { $0.lane == lane }?.stories ?? []
    }

    var lead: [TodayStoryAssignment] { stories(in: .theLead) }
    var latest: [TodayStoryAssignment] { stories(in: .theLatest) }
    var conditionalLanes: [Lane] { lanes.filter { $0.lane.isConditional } }
    var storyIDs: Set<String> { Set(lanes.flatMap { $0.stories.map(\.id) }) }

    /// The window pool (#934) from the window's grouped stories and the listed page: an event the page lists keeps
    /// the page's entry (its id is the page's representative), the window's other stories follow in their order, and
    /// listed stories outside the window come last. Each story once.
    static func windowPool(_ window: [FeedEntry], listed: [FeedEntry]) -> [FeedEntry] {
        var listedByEvent: [String: FeedEntry] = [:]
        for entry in listed {
            if case .event(let summary, _, _) = entry { listedByEvent[summary.eventID] = entry }
        }
        let listedIDs = Set(listed.map(\.id))
        let listedReports = Set(listed.flatMap { $0.visibleArticles.map(\.id) })
        var seen = Set<String>()
        var pool: [FeedEntry] = []
        for entry in window {
            var chosen = entry
            if case .event(let summary, _, _) = entry, let page = listedByEvent[summary.eventID] {
                chosen = page
            } else if !listedIDs.contains(entry.id),
                entry.visibleArticles.contains(where: { listedReports.contains($0.id) })
            {
                // Grouped differently on the page (read before a regrouping): the page's entry stands for it.
                continue
            }
            if seen.insert(chosen.id).inserted { pool.append(chosen) }
        }
        for entry in listed where seen.insert(entry.id).inserted { pool.append(entry) }
        return pool
    }

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
            return lane.stories.prefix(count).compactMap { imageURL(of: $0) }
        }
    }

    /// The photo a story's card shows: from the reports listed on the page, else the best of its whole event.
    func imageURL(of story: TodayStoryAssignment) -> URL? {
        story.entry.cardImageURL ?? metadata[story.id]?.imageURL
    }

    /// Stories near the top of the page that have no photo yet, The Lead's lanes first: the next photo lookup
    /// starts with them.
    var imagelessShownIDs: [String] {
        lanes.flatMap { lane in
            lane.stories.prefix(lane.lane == .theLatest ? 30 : 12).filter { imageURL(of: $0) == nil }.map(\.id)
        }
    }

    // MARK: - Building

    /// Lays the listed stories out as an edition.
    ///
    /// A new edition (`previous` nil) follows the assignment `plan`. An edition that is already on screen keeps
    /// every story in its lane, because nothing moves until the reader applies an update (docs/design/today.md,
    /// "Updates"): its cards take the fresh values, a story that left the list leaves its lane, and stories the
    /// list gained (a further page) join The Latest. A listed story the plan did not place because its feed is not
    /// known also goes to The Latest, so a gap in the stored feed identity never hides a story; a story whose
    /// feeds the reader has all left (`details.unsubscribedIDs`) is not shown at all.
    ///
    /// `pool`: the stories the lanes may hold when they are wider than the listed page (the window pool, #934),
    /// listed stories included. The Latest still holds only listed stories: every listed story no lane took, once.
    /// Nil keeps the lanes to the listed page.
    static func make(
        entries: [FeedEntry], plan: TodayEditionPlan, details: TodayCardDetails = TodayCardDetails(),
        keeping previous: TodayEdition? = nil, generation: Int = 0, pool: [FeedEntry]? = nil
    ) -> TodayEdition {
        var fresh: [String: TodayStoryAssignment] = [:]
        for assignment in plan.allAssignments { fresh[assignment.id] = assignment }
        // A story of a feed the reader has left is not part of Today, wherever it was before.
        let entries = entries.filter { !details.unsubscribedIDs.contains($0.id) }
        let listed = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listedIDs = Set(listed.keys)
        // The stories a lane may hold: the listed page, or the wider pool.
        let laneable =
            pool.map { pool in
                Dictionary(
                    pool.filter { !details.unsubscribedIDs.contains($0.id) }.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                ).merging(listed) { _, listedEntry in listedEntry }
            } ?? listed
        func mayHold(_ id: String, in lane: TodayLane) -> Bool {
            lane == .theLatest ? listedIDs.contains(id) : laneable[id] != nil
        }
        var laneStories: [TodayLane: [TodayStoryAssignment]] = [:]
        var placed = Set<String>()

        let retaining = previous.map { !$0.lanes.isEmpty } ?? false
        if let previous, retaining {
            for lane in previous.lanes {
                for story in lane.stories where mayHold(story.id, in: lane.lane) {
                    // The card keeps its content-type tag too, also when the fresh plan would retag or move the story.
                    // A story the plan no longer places still shows the current entry, not the one it was built from.
                    let current = (fresh[story.id] ?? story).held(
                        in: lane.lane, contentType: story.contentTypeLabel, entry: laneable[story.id])
                    laneStories[lane.lane, default: []].append(current)
                    placed.insert(story.id)
                }
            }
        } else {
            for result in plan.displayLanes where result.qualifies || !result.lane.isConditional {
                // A lane the plan hid passed its stories on already; only shown lanes hold cards.
                // With the wider pool, The Latest stays the listed page's.
                let stories = pool == nil ? result.entries : result.entries.filter { mayHold($0.id, in: result.lane) }
                laneStories[result.lane] = stories
                placed.formUnion(stories.map(\.id))
            }
        }
        for entry in entries where !placed.contains(entry.id) {
            laneStories[.theLatest, default: []].append(
                fresh[entry.id]?.placed(in: .theLatest) ?? .unplaced(entry))
        }
        // The Latest is always newest first by the date its cards show, also with the stories the assignment left
        // out and in an edition that is being held: a held Latest is in that order already, and a further page is
        // older, so sorting moves nothing the reader was looking at.
        laneStories[.theLatest]?.sort {
            let (a, b) = ($0.entry.representative.orderDate, $1.entry.representative.orderDate)
            return a == b ? $0.id < $1.id : a > b
        }

        var edition = TodayEdition(generation: generation)
        edition.lanes = TodayLane.displayOrder.compactMap { lane in
            guard let stories = laneStories[lane], !stories.isEmpty else { return nil }
            return Lane(lane: lane, stories: stories)
        }
        edition.metadata = cardMetadata(of: edition.lanes, details: details)
        edition.excludedIDs = details.unsubscribedIDs
        return edition
    }

    /// Every card's metadata, with the lane and the event it belongs to.
    private static func cardMetadata(of lanes: [Lane], details: TodayCardDetails) -> [String: StoryCardMetadata] {
        var result: [String: StoryCardMetadata] = [:]
        for lane in lanes {
            for story in lane.stories {
                var metadata = StoryCardMetadata(story, differingAccount: details.differingAccounts[story.id])
                metadata.imageURL = details.eventImages[story.id]
                metadata.laneName = lane.lane.rawValue
                if case .event(let summary, _, _) = story.entry { metadata.eventID = summary.eventID }
                result[story.id] = metadata
            }
        }
        return result
    }
}

extension TodayStoryAssignment {
    /// The same story shown in another lane; its scores and evidence are unchanged.
    func placed(in lane: TodayLane, contentType kept: TodayContentType? = nil) -> TodayStoryAssignment {
        guard lane != self.lane else { return self }
        return held(in: lane, contentType: lane == .theDeepRead ? (contentTypeLabel ?? kept) : nil)
    }

    /// The story as an edition on screen holds it: in `lane` with the content-type tag the card already shows, also
    /// when the fresh assignment tags it differently or not at all.
    func held(in lane: TodayLane, contentType: TodayContentType?, entry current: FeedEntry? = nil)
        -> TodayStoryAssignment
    {
        TodayStoryAssignment(
            id: id, entry: current ?? entry, lane: lane, score: score, confidence: confidence, reason: reason,
            sortKey: sortKey, contentTypeLabel: lane == .theDeepRead ? contentType : nil,
            isCoverageConfident: isCoverageConfident, isDeveloping: isDeveloping,
            originalReportCount: originalReportCount, publisherCount: publisherCount,
            groupingConfidence: groupingConfidence, readingTimeMinutes: readingTimeMinutes,
            interestMatch: interestMatch, novelty: novelty)
    }

    /// A listed story the assignment did not see, shown in The Latest with no claims about it.
    static func unplaced(_ entry: FeedEntry) -> TodayStoryAssignment {
        TodayStoryAssignment(
            id: entry.id, entry: entry, lane: .theLatest, score: 0, confidence: 0, reason: "listed_unassigned",
            sortKey: entry.representative.orderDate, contentTypeLabel: nil, isCoverageConfident: false,
            isDeveloping: false, originalReportCount: 1, publisherCount: entry.publisherCount,
            groupingConfidence: 0, readingTimeMinutes: 0, interestMatch: 0, novelty: 0)
    }
}

/// What the cards of an edition show that is read from the library with it.
struct TodayCardDetails: Equatable, Sendable {
    /// One attributed differing account per Coverage card, by story id.
    var differingAccounts: [String: String] = [:]
    /// The best photo of the whole event, for stories whose listed reports carry none, by story id.
    var eventImages: [String: URL] = [:]
    /// Listed stories whose feeds the reader has all left (`TodayEditionAssigner.unsubscribedEntryIDs`).
    var unsubscribedIDs: Set<String> = []
}

/// What the lane assignment needs to know about the reader, from their settings.
struct TodayReader: Sendable {
    /// Photos that failed to load this session (`DecodedImageCache.failedURLs`).
    var failedImageURLs: Set<URL> = []
    var subscribedFeedURLs: Set<String>
    var starredFeedURLs: Set<String>
    /// Reading interests count from here when the reader reset them.
    var interestsResetAt: Date?
}

extension ArticleStore {
    /// The last complete edition laid out for the stories listed now, or why it is not shown (#937). Off the main
    /// actor; nil when nothing is stored.
    func restoredTodayEdition(
        entries: [FeedEntry], pool: [FeedEntry]? = nil, reader: TodayReader, generation: Int
    ) async -> Result<TodayEdition, TodayStoredEdition.Rejection>? {
        guard let data = await database.storedTodayEdition() else { return nil }
        let identity = TodayStoredEdition.identity(
            feedURLs: Array(reader.subscribedFeedURLs), starredFeedURLs: reader.starredFeedURLs,
            interestsResetAt: reader.interestsResetAt)
        let failed = reader.failedImageURLs
        return await Task.detached(priority: .userInitiated) {
            guard let stored = try? JSONDecoder().decode(TodayStoredEdition.self, from: data) else {
                return .failure(.otherFormat)
            }
            return stored.restored(
                entries: entries, identity: identity, failedImageURLs: failed, generation: generation, pool: pool)
        }.value
    }

    /// Keeps a complete edition for the next launch. A failure only costs that launch its head start.
    func storeTodayEdition(_ edition: TodayEdition, reader: TodayReader) async {
        let identity = TodayStoredEdition.identity(
            feedURLs: Array(reader.subscribedFeedURLs), starredFeedURLs: reader.starredFeedURLs,
            interestsResetAt: reader.interestsResetAt)
        let database = self.database
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(TodayStoredEdition(edition, identity: identity, builtAt: Date()))
            else { return }
            try? await database.storeTodayEdition(data, expectedGeneration: edition.analysisGeneration)
        }.value
    }

    /// Assigns the listed stories to lanes and reads what their cards show, off the main actor. A failed read
    /// leaves every story in The Latest rather than an empty page.
    /// `pool`: with the window pool (#934), the stories assigned to lanes, the listed ones included; the listed
    /// stories still fill The Latest. Nil assigns over the listed stories.
    func todayEdition(
        entries: [FeedEntry], pool: [FeedEntry]? = nil, reader: TodayReader, keeping previous: TodayEdition?,
        generation: Int
    ) async -> TodayEdition {
        let candidates = pool ?? entries
        let database = self.database
        let now = Date()
        // An edition laid out afresh logs how long each stage took (#937).
        var timer = previous == nil ? NewsSignposts.StageTimer("Today edition") : nil
        let analysisGeneration = await database.analysisGeneration
        do {
            var context = try await database.loadTodayAssignmentContext(
                entries: candidates, now: now, starredFeedURLs: reader.starredFeedURLs,
                subscribedFeedURLs: reader.subscribedFeedURLs, resetAt: reader.interestsResetAt)
            try Task.checkCancellation()
            timer?.lap("context", count: candidates.count)
            // A story's photo may sit on a report of its event that this page does not list.
            var details = TodayCardDetails()
            // ponytail: one read per event, for at most the 60 newest events without a listed photo, so a page of
            // them cannot hold up the edition; read them in one query if a library needs more.
            let unpictured = candidates.filter { entry in
                if case .event = entry { return entry.cardImageURL == nil }
                return false
            }
            for entry in unpictured.prefix(60) {
                try Task.checkCancellation()
                guard case .event(let summary, _, _) = entry,
                    let members = try? await storyMemberArticles(eventID: summary.eventID),
                    let image = FeedArticle.bestCardImage(in: members)
                else { continue }
                details.eventImages[entry.id] = image
            }
            timer?.lap("event_images", count: min(60, unpictured.count))
            details.unsubscribedIDs = TodayEditionAssigner.unsubscribedEntryIDs(candidates, context: context)
            context.imagelessEntryIDs = Set(
                candidates.filter { entry in
                    guard let image = entry.cardImageURL ?? details.eventImages[entry.id] else { return true }
                    return reader.failedImageURLs.contains(image)
                }.map(\.id))
            let plan = await Task.detached(priority: .userInitiated) {
                TodayEditionAssigner.assign(entries: candidates, context: context)
            }.value
            try Task.checkCancellation()
            timer?.lap("assignment", count: candidates.count { if case .event = $0 { true } else { false } })
            details.differingAccounts = (try? await database.todayDifferingAccounts(for: plan)) ?? [:]
            timer?.lap("differing_accounts", count: details.differingAccounts.count)
            // Off the main actor: the cards' reading times are counted from their stored text here.
            let edition = await Task.detached(priority: .userInitiated) { [details] in
                TodayEdition.make(
                    entries: entries, plan: plan, details: details, keeping: previous, generation: generation,
                    pool: pool)
            }.value
            timer?.lap("layout", count: edition.lead.count)
            var assigned = edition
            assigned.isAssigned = previous == nil
            assigned.analysisGeneration = analysisGeneration
            return assigned
        } catch {
            return TodayEdition.make(
                entries: entries, plan: TodayEditionPlan(lanes: []), keeping: previous, generation: generation,
                pool: pool)
        }
    }
}
