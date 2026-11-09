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

public struct EntityRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: String  // canonical slug: e.g. "person:satya-nadella"
    public let canonicalName: String
    public let entityType: EntityType
    public let mentionCount: Int
    public let firstSeen: Date
    public let lastSeen: Date

    public init(
        id: String,
        canonicalName: String,
        entityType: EntityType,
        mentionCount: Int,
        firstSeen: Date,
        lastSeen: Date
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.entityType = entityType
        self.mentionCount = mentionCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public struct EntityMention: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let entityId: String
    public let articleId: String
    public let publisherId: String
    public let publishedAt: Date
    public let passageOffset: Int?
    public let confidence: Float

    public init(
        id: String = UUID().uuidString,
        entityId: String,
        articleId: String,
        publisherId: String,
        publishedAt: Date,
        passageOffset: Int? = nil,
        confidence: Float
    ) {
        self.id = id
        self.entityId = entityId
        self.articleId = articleId
        self.publisherId = publisherId
        self.publishedAt = publishedAt
        self.passageOffset = passageOffset
        self.confidence = confidence
    }
}

public struct EntityCoOccurrence: Hashable, Codable, Sendable {
    public let sourceEntityId: String
    public let targetEntityId: String
    public let targetCanonicalName: String
    public let targetEntityType: EntityType
    public let coOccurrenceCount: Int

    public init(
        sourceEntityId: String = "",
        targetEntityId: String,
        targetCanonicalName: String,
        targetEntityType: EntityType,
        coOccurrenceCount: Int
    ) {
        self.sourceEntityId = sourceEntityId
        self.targetEntityId = targetEntityId
        self.targetCanonicalName = targetCanonicalName
        self.targetEntityType = targetEntityType
        self.coOccurrenceCount = coOccurrenceCount
    }
}

public struct EntityPublisherDistribution: Hashable, Codable, Sendable {
    public let publisherId: String
    public let publisherName: String
    public let mentionCount: Int
    public let share: Double  // 0.0 ... 1.0

    public init(
        publisherId: String,
        publisherName: String,
        mentionCount: Int,
        share: Double
    ) {
        self.publisherId = publisherId
        self.publisherName = publisherName
        self.mentionCount = mentionCount
        self.share = share
    }
}

public struct EntityCoverageTimeseriesBucket: Hashable, Codable, Sendable {
    public let dateBucket: String  // "YYYY-MM-DD"
    public let mentionCount: Int

    public init(
        dateBucket: String,
        mentionCount: Int
    ) {
        self.dateBucket = dateBucket
        self.mentionCount = mentionCount
    }
}

public struct EntityDossier: Identifiable, Hashable, Codable, Sendable {
    public var id: String { entity.id }
    public let entity: EntityRecord
    public let coverage30Days: [EntityCoverageTimeseriesBucket]
    public let coOccurringEntities: [EntityCoOccurrence]
    public let publisherBreakdown: [EntityPublisherDistribution]
    public let recentArticleIds: [String]

    public init(
        entity: EntityRecord,
        coverage30Days: [EntityCoverageTimeseriesBucket],
        coOccurringEntities: [EntityCoOccurrence],
        publisherBreakdown: [EntityPublisherDistribution],
        recentArticleIds: [String]
    ) {
        self.entity = entity
        self.coverage30Days = coverage30Days
        self.coOccurringEntities = coOccurringEntities
        self.publisherBreakdown = publisherBreakdown
        self.recentArticleIds = recentArticleIds
    }
}
