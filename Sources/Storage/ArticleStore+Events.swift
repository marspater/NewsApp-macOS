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
import os

extension ArticleStore {
    // MARK: - Events

    func noteEventsChanged() {
        eventRevision &+= 1
    }

    func eventFeedSummaries(for articleIDs: [String]) async throws -> [EventFeedSummary] {
        try await database.eventFeedSummaries(forArticles: articleIDs)
    }

    func eventMemberArticles(eventID: String) async throws -> [FeedArticle] {
        try await database.fetchArticles(limit: nil, eventID: eventID)
    }

    /// Every visible report of the story the event leads (#581), for the expanded story card, whose coverage counts
    /// the whole story.
    func storyMemberArticles(eventID: String) async throws -> [FeedArticle] {
        try await database.fetchArticles(limit: nil, eventID: eventID, wholeStory: true)
    }

    /// Earlier events of the same developing story, shown under "Earlier in This Story": every earlier event of the
    /// story itself (#581), then up to `EventStoryRelation.linkLimit` other links, the lexical relation's (#314) before
    /// related acts the matcher kept apart (#522).
    func relatedStoryEvents(eventID: String) async throws -> [RelatedStoryEvent] {
        let lexical = try await EventStoryRelation.find(eventID: eventID, in: database)
        let members = try await database.fetchArticles(limit: nil, eventID: eventID)
        guard let start = members.map(\.pubDate).min() else { return lexical }
        // Every related act and story event, earlier and later: the earlier-only filter comes first.
        let earlier = try await database.relatedActEvents(eventID: eventID, limit: .max)
            .filter { $0.firstPublishedAt < start }
        let story = Set(try await database.storyEventIDs(eventID))
        return Self.earlierLinks(
            story: earlier.filter { story.contains($0.eventID) },
            others: lexical + earlier.filter { !story.contains($0.eventID) })
    }

    /// The story's own events, all of them and in the given order, then other links up to the cap. Three lexical
    /// links used to fill the list before the story's own earlier events were reached (#671).
    nonisolated static func earlierLinks(
        story: [RelatedStoryEvent], others: [RelatedStoryEvent], cap: Int = EventStoryRelation.linkLimit
    ) -> [RelatedStoryEvent] {
        var seen = Set(story.map(\.eventID))
        let extra = others.filter { seen.insert($0.eventID).inserted }.prefix(cap)
        return story + extra
    }

    /// Records the event version the reader has seen. Article read and saved state stay as they are.
    func markEventSeen(_ eventID: String) async {
        do {
            let before = try await database.eventSeenVersion(eventID)
            if try await database.markEventSeen(eventID) != before { eventRevision &+= 1 }
        } catch {
            logger.error("Failed to record event reading state: \(error.localizedDescription)")
        }
    }

    /// "These are different events": a local exclusion that later refreshes and passes respect.
    @discardableResult
    func separateArticle(_ articleID: String, fromEvent eventID: String) async -> Bool {
        do {
            try await database.separateArticle(articleID, fromEvent: eventID)
            eventRevision &+= 1
            return true
        } catch {
            operationError = "This article could not be separated from the event. Please try again."
            logger.error("Failed to separate article from event: \(error.localizedDescription)")
            return false
        }
    }

    /// "Same event": the related event joins this one, and later passes keep them together (#524).
    @discardableResult
    func includeEvent(_ relatedEventID: String, inEvent eventID: String) async -> Bool {
        do {
            let combined = try await database.includeEvent(relatedEventID, inEvent: eventID)
            // The reader made this change: it is no new reporting to flag as "Updated".
            _ = try? await database.markEventSeen(combined.id)
            eventRevision &+= 1
            return true
        } catch {
            operationError = "These events could not be combined. Please try again."
            logger.error("Failed to combine events: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Event Overviews

    @discardableResult
    func recordEventOverview(
        _ document: EventOverviewDocument, expectedArticleInputs: [String: String]? = nil,
        expectedGeneration: Int? = nil
    ) async throws -> Bool {
        let stored = try await database.recordEventOverview(
            document, expectedArticleInputs: expectedArticleInputs, expectedGeneration: expectedGeneration)
        if stored { overviewRevision &+= 1 }
        return stored
    }

    func fetchEventOverview(eventID: String) async throws -> EventOverviewDocument? {
        try await database.fetchEventOverview(eventID: eventID)
    }

    func fetchEventOverview(forArticleID articleID: String) async throws -> EventOverviewDocument? {
        try await database.fetchEventOverview(forArticleID: articleID)
    }
}
