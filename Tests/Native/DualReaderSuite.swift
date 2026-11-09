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
import Testing

extension NativeSuites {
    @Suite(.tags(.editorial, .integration)) struct DualReaderSuite {
        @Test func passageSegmentation() async {
            let service = DualReaderAlignmentService()
            let title = "Summit Concludes in Geneva"
            let body = """
                Negotiators from all participating nations concluded bilateral talks in Geneva on Friday morning after twelve hours of discussions.

                The agreement focuses on emissions reductions, technological exchanges, and mutual safety verification standards.

                Copyright 2026 News Wire Service. All rights reserved.

                A subsequent follow-up meeting is scheduled for next November in Kyoto to formalize the enforcement framework.
                """

            let passages = await service.extractPassages(title: title, content: body)
            #expect(passages.count == 4)  // title + 3 valid paragraphs, boilerplate dropped
            #expect(passages.first == title)
            #expect(!passages.contains { $0.contains("All rights reserved") })
        }

        @Test func blankArticleYieldsNoPassagesAndEmptySession() async {
            let service = DualReaderAlignmentService()
            #expect(await service.extractPassages(title: "  ", content: "short").isEmpty)

            let blank = DualReaderAlignmentService.ArticleInput(
                id: "blank", title: " ", content: "", publisher: "Blank Wire")
            let other = DualReaderAlignmentService.ArticleInput(
                id: "other", title: " ", content: "", publisher: "Other Wire")
            let session = await service.align(left: blank, right: other)
            #expect(session.passageAlignments.isEmpty)
        }

        @Test func shortSentencesStayAndLabelsGo() async {
            let service = DualReaderAlignmentService()
            let passages = await service.extractPassages(
                title: "Resignation",
                content: "The president resigned.\n\nHe resigned.\n\n\u{201C}He resigned.\u{201D}\n\nRead more\n\nShare"
            )
            #expect(
                passages == ["Resignation", "The president resigned.", "He resigned.", "\u{201C}He resigned.\u{201D}"])
        }

        @Test func uniqueLeadHasNoCounterpart() {
            func pair(_ type: PerspectiveContrastType) -> PassageContrastPair {
                PassageContrastPair(
                    leftPassageIndex: 0, rightPassageIndex: 1, leftSnippet: "a", rightSnippet: "b",
                    similarityScore: 0.1, contrastType: type)
            }
            #expect(!pair(.uniqueLead).hasCounterpart)
            #expect(pair(.divergence).hasCounterpart && pair(.consensus).hasCounterpart)
        }

        @Test func lexicalVectorEmbedding() async {
            let service = DualReaderAlignmentService()
            let vector = await service.fallbackLexicalVector(
                for: "Renewable energy policy shift accelerates across European markets.")

            #expect(vector.count == DualReaderAlignmentService.vectorDimension)
            #expect(vector.allSatisfy { $0.isFinite })

            // Verify L2 normalization: sum of squares ≈ 1.0
            let sumSquares = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
            #expect(abs(sumSquares - 1.0) < 0.005)
        }

        @Test func passageAlignmentAndContrastClassification() async {
            let service = DualReaderAlignmentService()

            let leftText = """
                The summit concluded with unanimous agreement on emissions benchmarks across energy sectors.

                Economic analysts expressed concern over transition compliance costs for small manufacturers.
                """

            let rightText = """
                The summit concluded with unanimous agreement on emissions benchmarks across energy sectors.

                Industry lobbyists praised the new exemptions granted to regional manufacturing partners.
                """

            let session = await service.align(
                left: .init(
                    id: "left-1",
                    title: "Emissions Accord Signed",
                    content: leftText,
                    publisher: "Global News"
                ),
                right: .init(
                    id: "right-1",
                    title: "Emissions Accord Signed",
                    content: rightText,
                    publisher: "Industry Daily"
                ),
                clusterId: "cluster-77"
            )

            #expect(!session.passageAlignments.isEmpty)

            // The exact identical passage should achieve consensus
            let consensusPairs = session.passageAlignments.filter { $0.contrastType == .consensus }
            #expect(!consensusPairs.isEmpty)
            #expect(consensusPairs.first?.similarityScore ?? 0 >= DualReaderAlignmentService.consensusThreshold)

            // Metrics summary
            #expect(session.consensusScore > 0)
        }

        @Test func aSessionSaysWhenTheLexicalFallbackMadeTheVectors() async {
            func input(_ id: String) -> DualReaderAlignmentService.ArticleInput {
                .init(
                    id: id, title: "Summit Concludes in Geneva",
                    content:
                        "Negotiators from all participating nations concluded bilateral talks in Geneva on Friday morning.",
                    publisher: "Wire \(id)")
            }
            // A stand-in neural embedder: one unit vector per passage length.
            let neural: @Sendable (String) async -> [Float]? = { text in
                var vector = [Float](repeating: 0, count: DualReaderAlignmentService.vectorDimension)
                vector[text.count % DualReaderAlignmentService.vectorDimension] = 1
                return vector
            }

            let meaning = await DualReaderAlignmentService(embed: neural).align(left: input("a"), right: input("b"))
            #expect(!meaning.passageAlignments.isEmpty)
            #expect(!meaning.usesLexicalFallback, "A session the neural embedder read says nothing about words")

            let words = await DualReaderAlignmentService(embed: { _ in nil }).align(left: input("a"), right: input("b"))
            #expect(!words.passageAlignments.isEmpty)
            #expect(words.usesLexicalFallback, "Every vector is a word count, and the session says so")

            // One passage the embedder cannot read switches the whole session: one embedding space.
            let partial = await DualReaderAlignmentService(embed: { text in
                text.hasPrefix("Negotiators") ? nil : await neural(text)
            }).align(left: input("a"), right: input("b"))
            #expect(partial.usesLexicalFallback)

            #expect(DualReaderView.methodCaption(usesLexicalFallback: false) == "Compared by meaning on this Mac")
            #expect(DualReaderView.methodCaption(usesLexicalFallback: true).contains("shared words"))
            #expect(!DualReaderView.methodCaption(usesLexicalFallback: true).contains("by meaning"))
        }

        @Test func adaptiveLayoutMode() {
            #expect(DualReaderLayoutMode.mode(for: 1400) == .sideBySide)
            #expect(DualReaderLayoutMode.mode(for: 1200) == .sideBySide)
            #expect(DualReaderLayoutMode.mode(for: 1199) == .stacked)
            #expect(DualReaderLayoutMode.mode(for: 800) == .stacked)
        }
    }
}
