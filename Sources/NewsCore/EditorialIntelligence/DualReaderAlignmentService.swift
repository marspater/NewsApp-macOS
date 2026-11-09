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

import Accelerate
import Foundation
import os

/// Detached actor performing on-device passage segmentation, vector embedding,
/// and perspective contrast alignment between paired articles (#717).
public actor DualReaderAlignmentService {
    public static let consensusThreshold: Float = 0.82
    public static let divergenceThreshold: Float = 0.40
    public static let vectorDimension = 384

    private let logger = Logger(subsystem: "com.marspater.news", category: "DualReaderAlignmentService")

    public init() {}

    /// Aligns passages between two articles and categorizes contrast types.
    public func align(
        leftArticleId: String,
        leftTitle: String,
        leftContent: String,
        leftPublisher: String,
        rightArticleId: String,
        rightTitle: String,
        rightContent: String,
        rightPublisher: String,
        clusterId: String = ""
    ) async -> DualReaderSession {
        let leftPassages = extractPassages(title: leftTitle, content: leftContent)
        let rightPassages = extractPassages(title: rightTitle, content: rightContent)

        guard !leftPassages.isEmpty && !rightPassages.isEmpty else {
            return DualReaderSession(
                clusterId: clusterId,
                leftArticleId: leftArticleId,
                rightArticleId: rightArticleId,
                leftPublisherName: leftPublisher,
                rightPublisherName: rightPublisher,
                passageAlignments: []
            )
        }

        // Compute vector embeddings for all passages
        let leftVectors = await embedPassages(leftPassages)
        let rightVectors = await embedPassages(rightPassages)

        var alignments: [PassageContrastPair] = []
        var matchedRightIndices = Set<Int>()

        // Find best right alignment for each left passage
        for (leftIdx, leftPassage) in leftPassages.enumerated() {
            let leftVec = leftVectors[leftIdx]
            var bestRightIdx = 0
            var bestSimilarity: Float = -1.0

            for (rightIdx, _) in rightPassages.enumerated() {
                let rightVec = rightVectors[rightIdx]
                let sim = cosineSimilarity(leftVec, rightVec)
                if sim > bestSimilarity {
                    bestSimilarity = sim
                    bestRightIdx = rightIdx
                }
            }

            matchedRightIndices.insert(bestRightIdx)
            let contrastType: PerspectiveContrastType
            if bestSimilarity >= Self.consensusThreshold {
                contrastType = .consensus
            } else if bestSimilarity >= Self.divergenceThreshold {
                contrastType = .divergence
            } else {
                contrastType = .uniqueLead
            }

            alignments.append(
                PassageContrastPair(
                    leftPassageIndex: leftIdx,
                    rightPassageIndex: bestRightIdx,
                    leftSnippet: leftPassage,
                    rightSnippet: rightPassages[bestRightIdx],
                    similarityScore: bestSimilarity,
                    contrastType: contrastType
                )
            )
        }

        // Add unique leads from right article that had no high similarity match from left
        for (rightIdx, rightPassage) in rightPassages.enumerated() where !matchedRightIndices.contains(rightIdx) {
            let rightVec = rightVectors[rightIdx]
            var maxSim: Float = -1.0
            var closestLeftIdx = 0
            for (leftIdx, _) in leftPassages.enumerated() {
                let sim = cosineSimilarity(leftVectors[leftIdx], rightVec)
                if sim > maxSim {
                    maxSim = sim
                    closestLeftIdx = leftIdx
                }
            }

            if maxSim < Self.divergenceThreshold {
                alignments.append(
                    PassageContrastPair(
                        leftPassageIndex: closestLeftIdx,
                        rightPassageIndex: rightIdx,
                        leftSnippet: leftPassages[closestLeftIdx],
                        rightSnippet: rightPassage,
                        similarityScore: maxSim,
                        contrastType: .uniqueLead
                    )
                )
            }
        }

        return DualReaderSession(
            clusterId: clusterId,
            leftArticleId: leftArticleId,
            rightArticleId: rightArticleId,
            leftPublisherName: leftPublisher,
            rightPublisherName: rightPublisher,
            passageAlignments: alignments
        )
    }

    /// Splits an article into distinct paragraphs/passages, stripping boilerplate.
    public func extractPassages(title: String, content: String) -> [String] {
        var results: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            results.append(trimmedTitle)
        }

        let rawParagraphs = content.components(separatedBy: "\n\n")
            .flatMap { $0.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 25 }

        for paragraph in rawParagraphs {
            // Filter common RSS/feed boilerplate
            if paragraph.lowercased().starts(with: "copyright")
                || paragraph.lowercased().contains("all rights reserved")
                || paragraph.lowercased().contains("subscribe to continue reading")
            {
                continue
            }
            results.append(paragraph)
        }

        return results.isEmpty ? [title] : results
    }

    private func embedPassages(_ passages: [String]) async -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(passages.count)

        for passage in passages {
            if let neuralVec = await SentenceEmbedder.shared.embed(passage) {
                vectors.append(neuralVec)
            } else {
                vectors.append(fallbackLexicalVector(for: passage))
            }
        }
        return vectors
    }

    /// On-device normalized term-frequency hashing vector when CoreML neural weights are not present.
    public func fallbackLexicalVector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0.0, count: Self.vectorDimension)
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }

        guard !words.isEmpty else {
            vector[0] = 1.0
            return vector
        }

        for word in words {
            // Hash word into bucket within vectorDimension
            var hash: UInt64 = 5381
            for byte in word.utf8 {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
            let index = Int(hash % UInt64(Self.vectorDimension))
            vector[index] += 1.0
        }

        // L2-normalize using vDSP
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(Self.vectorDimension))
        if sumSquares > 0 {
            var norm = 1.0 / sqrt(sumSquares)
            vDSP_vsmul(vector, 1, &norm, &vector, 1, vDSP_Length(Self.vectorDimension))
        } else {
            vector[0] = 1.0
        }

        return vector
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        var dot: Float = 0.0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return min(1.0, max(-1.0, dot))
    }
}
