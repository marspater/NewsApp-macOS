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

    /// What a passage shows against the other report, in words that judge neither publisher (#717): both say it, they
    /// say it differently, or only this report says it.
    public var displayName: String {
        switch self {
        case .consensus:
            return "Both report"
        case .divergence:
            return "Reported differently"
        case .uniqueLead:
            return "Only in this report"
        }
    }

    /// `sparkles` is reserved for generated content (DESIGN.md 9, 14); a comparison by meaning is not generated text.
    public var systemIcon: String {
        switch self {
        case .consensus:
            return "equal.circle"
        case .divergence:
            return "arrow.triangle.branch"
        case .uniqueLead:
            return "doc.badge.plus"
        }
    }
}

/// Aligned pair of passages across two perspectives with contrast categorization.
public struct PassageContrastPair: Identifiable, Hashable, Codable, Sendable {
    /// The report a unique lead belongs to.
    public enum Side: String, Codable, Sendable {
        case left
        case right
    }

    /// The pair's position, the two passages it joins, and for a unique lead the side it belongs to: a left unique
    /// lead names its closest right passage only for reference, so that passage can be the right report's own unique
    /// lead, and the two pairs of one position are told apart by their side. No two pairs of a session share an id.
    public var id: String {
        "\(leftPassageIndex)-\(rightPassageIndex)" + (uniqueSide.map { "-\($0.rawValue)" } ?? "")
    }
    public let leftPassageIndex: Int
    public let rightPassageIndex: Int
    public let leftSnippet: String
    public let rightSnippet: String
    public let similarityScore: Float
    public let contrastType: PerspectiveContrastType
    /// For a unique lead, the report whose passage has no counterpart; the other index only names its closest passage.
    public let uniqueSide: Side?

    public init(
        leftPassageIndex: Int,
        rightPassageIndex: Int,
        leftSnippet: String,
        rightSnippet: String,
        similarityScore: Float,
        contrastType: PerspectiveContrastType,
        uniqueSide: Side? = nil
    ) {
        self.leftPassageIndex = leftPassageIndex
        self.rightPassageIndex = rightPassageIndex
        self.leftSnippet = leftSnippet
        self.rightSnippet = rightSnippet
        self.similarityScore = similarityScore
        self.contrastType = contrastType
        self.uniqueSide = uniqueSide
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
    /// The neural embedder was not available for at least one passage, so every vector is a hashed word count: the
    /// scores measure shared words, not meaning, and the thresholds were not set for them. Set by the alignment
    /// service, not an initializer parameter (SonarCloud S107: at most seven).
    public internal(set) var usesLexicalFallback = false

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

    /// How the left report's passage stands against the right report: the pair it opens, which is a unique lead when
    /// nothing in the other report says it.
    public func pair(forLeft index: Int) -> PassageContrastPair? {
        passageAlignments.first { $0.leftPassageIndex == index && $0.uniqueSide != .right }
    }

    /// How the right report's passage stands against the left report: the strongest left passage that chose it, else
    /// the unique lead that names it. A passage that is only some unmatched passage's closest guess has no pair.
    public func pair(forRight index: Int) -> PassageContrastPair? {
        passageAlignments.filter { $0.rightPassageIndex == index && $0.hasCounterpart }
            .max { $0.similarityScore < $1.similarityScore }
            ?? passageAlignments.first { $0.rightPassageIndex == index && $0.uniqueSide == .right }
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
