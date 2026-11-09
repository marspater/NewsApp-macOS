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

/// Categorization of perspective contrast across paired passages (#717).
public enum PerspectiveContrastType: String, Codable, Sendable, CaseIterable {
    case consensus
    case divergence
    case uniqueLead

    public var displayName: String {
        switch self {
        case .consensus:
            return "Consensus"
        case .divergence:
            return "Divergence"
        case .uniqueLead:
            return "Unique Lead"
        }
    }

    public var systemIcon: String {
        switch self {
        case .consensus:
            return "checkmark.seal.fill"
        case .divergence:
            return "arrow.triangle.swap"
        case .uniqueLead:
            return "sparkles"
        }
    }
}

/// Aligned pair of passages across two perspectives with contrast categorization.
public struct PassageContrastPair: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let leftPassageIndex: Int
    public let rightPassageIndex: Int
    public let leftSnippet: String
    public let rightSnippet: String
    public let similarityScore: Float
    public let contrastType: PerspectiveContrastType

    public init(
        id: String = UUID().uuidString,
        leftPassageIndex: Int,
        rightPassageIndex: Int,
        leftSnippet: String,
        rightSnippet: String,
        similarityScore: Float,
        contrastType: PerspectiveContrastType
    ) {
        self.id = id
        self.leftPassageIndex = leftPassageIndex
        self.rightPassageIndex = rightPassageIndex
        self.leftSnippet = leftSnippet
        self.rightSnippet = rightSnippet
        self.similarityScore = similarityScore
        self.contrastType = contrastType
    }

    /// A unique lead names the closest passage of the other article only for reference; it is not a match.
    public var hasCounterpart: Bool { contrastType != .uniqueLead }
}

/// Complete dual-reader alignment session comparing two articles in an event cluster.
public struct DualReaderSession: Identifiable, Hashable, Sendable {
    public let id: String
    public let clusterId: String
    public let leftArticleId: String
    public let rightArticleId: String
    public let leftPublisherName: String
    public let rightPublisherName: String
    public let passageAlignments: [PassageContrastPair]

    public init(
        id: String = UUID().uuidString,
        clusterId: String = "",
        leftArticleId: String,
        rightArticleId: String,
        leftPublisherName: String,
        rightPublisherName: String,
        passageAlignments: [PassageContrastPair]
    ) {
        self.id = id
        self.clusterId = clusterId
        self.leftArticleId = leftArticleId
        self.rightArticleId = rightArticleId
        self.leftPublisherName = leftPublisherName
        self.rightPublisherName = rightPublisherName
        self.passageAlignments = passageAlignments
    }

    public var consensusCount: Int {
        passageAlignments.filter { $0.contrastType == .consensus }.count
    }

    public var divergenceCount: Int {
        passageAlignments.filter { $0.contrastType == .divergence }.count
    }

    public var uniqueLeadCount: Int {
        passageAlignments.filter { $0.contrastType == .uniqueLead }.count
    }

    public var consensusScore: Double {
        guard !passageAlignments.isEmpty else { return 0.0 }
        return Double(consensusCount) / Double(passageAlignments.count)
    }

    public var divergenceScore: Double {
        guard !passageAlignments.isEmpty else { return 0.0 }
        return Double(divergenceCount) / Double(passageAlignments.count)
    }
}

/// Adaptive layout mode for dual-reader presentation based on available viewport width.
public enum DualReaderLayoutMode: String, Sendable, CaseIterable {
    case sideBySide
    case stacked

    public static let thresholdWidth: CGFloat = 1200.0

    public static func mode(for width: CGFloat) -> DualReaderLayoutMode {
        width >= thresholdWidth ? .sideBySide : .stacked
    }
}
