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
    /// W3 #717: which reports "Compare Perspectives" offers, and how a passage finds its pair in each column.
    @Suite(.tags(.editorial, .integration)) struct PerspectiveReportsSuite {
        private static func article(_ key: String, publisher: String, words: Int) -> FeedArticle {
            FeedArticle(
                title: "Story \(key)", link: "https://\(key).example.com/story", guid: key, description: "",
                pubDate: Date(timeIntervalSince1970: 1_793_372_400), source: publisher,
                fullContent: Array(repeating: "word", count: words).joined(separator: " "))
        }

        @Test func offersOneReportPerPublisherRichestFirst() {
            let reports = PerspectiveReports.candidates(from: [
                Self.article("a1", publisher: "Alpha Wire", words: 80),
                Self.article("a2", publisher: "Alpha Wire", words: 300),
                Self.article("b1", publisher: "Beta Post", words: 120),
                Self.article("c1", publisher: "Gamma Daily", words: 120),
            ])
            #expect(reports.map(\.publisher) == ["Alpha Wire", "Beta Post", "Gamma Daily"])
            #expect(reports.first?.wordCount == 300, "A publisher's fullest report stands for it")
        }

        @Test func leavesOutReportsTooShortToCompare() {
            let short = PerspectiveReports.minimumWords - 1
            #expect(
                PerspectiveReports.candidates(from: [Self.article("a", publisher: "Alpha Wire", words: short)]).isEmpty)
            let withFeedSummaryOnly = FeedArticle(
                title: "Story", link: "https://s.example.com/x", guid: "s",
                description: Array(repeating: "word", count: PerspectiveReports.minimumWords).joined(separator: " "),
                pubDate: Date(), source: "Summary Wire")
            #expect(
                PerspectiveReports.candidates(from: [withFeedSummaryOnly]).count == 1, "A feed summary can stand in")
        }

        @Test func theTaskKeyChangesForAnEditThatKeepsTheLengthAndForATitleEdit() {
            func report(title: String, text: String) -> FeedArticle {
                FeedArticle(
                    title: title, link: "https://a.example.com/story", guid: "a", description: "",
                    pubDate: Date(timeIntervalSince1970: 1_793_372_400), source: "Alpha Wire", fullContent: text)
            }
            let words = Array(repeating: "word", count: 80).joined(separator: " ")
            let sameLength = "ward" + words.dropFirst(4)
            #expect(sameLength.count == words.count && sameLength != words)
            let original = PerspectiveReports.inputs(of: [report(title: "Harbour reopens", text: words)])
            #expect(original == PerspectiveReports.inputs(of: [report(title: "Harbour reopens", text: words)]))
            #expect(
                original != PerspectiveReports.inputs(of: [report(title: "Harbour reopens", text: sameLength)]),
                "The same length with other words is another text")
            #expect(
                original != PerspectiveReports.inputs(of: [report(title: "Harbour closes", text: words)]),
                "A title edit alone is read again")
        }

        @Test func theTaskKeyChangesWhenAMembersTextArrives() {
            let before = Self.article("a", publisher: "Alpha Wire", words: 10)
            let after = Self.article("a", publisher: "Alpha Wire", words: 80)
            let other = Self.article("b", publisher: "Beta Post", words: 80)
            #expect(PerspectiveReports.inputs(of: [before, other]) == PerspectiveReports.inputs(of: [before, other]))
            #expect(
                PerspectiveReports.inputs(of: [before, other]) != PerspectiveReports.inputs(of: [after, other]),
                "The same members with more text are read again")
            #expect(
                PerspectiveReports.candidates(from: [before, other]).count == 1
                    && PerspectiveReports.candidates(from: [after, other]).count == 2)
        }

        @Test func contrastCopyJudgesNeitherPublisherAndKeepsSparklesForGeneratedText() {
            let types = PerspectiveContrastType.allCases
            #expect(!types.map(\.systemIcon).contains("sparkles"))
            #expect(Set(types.map(\.systemIcon)).count == types.count, "One symbol per concept")
            let words = types.map(\.displayName).joined(separator: " ").lowercased()
            #expect(!words.contains("bias") && !words.contains("neutral") && !words.contains("unique lead"))
        }

        @Test func eachColumnFindsItsOwnPair() {
            func pair(
                _ left: Int, _ right: Int, _ similarity: Float, _ type: PerspectiveContrastType,
                side: PassageContrastPair.Side? = nil
            ) -> PassageContrastPair {
                PassageContrastPair(
                    leftPassageIndex: left, rightPassageIndex: right, leftSnippet: "l\(left)",
                    rightSnippet: "r\(right)", similarityScore: similarity, contrastType: type, uniqueSide: side)
            }
            let session = DualReaderSession(
                leftArticleId: "l", rightArticleId: "r", leftPublisherName: "Left", rightPublisherName: "Right",
                passageAlignments: [
                    pair(0, 0, 0.9, .consensus), pair(1, 0, 0.5, .divergence),
                    pair(2, 1, 0.1, .uniqueLead, side: .left),
                    pair(0, 2, 0.05, .uniqueLead, side: .right),
                ])
            #expect(session.pair(forLeft: 0)?.id == "0-0", "A right-side unique lead does not take the left passage")
            #expect(session.pair(forLeft: 2)?.contrastType == .uniqueLead)
            #expect(session.pair(forRight: 0)?.id == "0-0", "The strongest passage that chose it wins")
            #expect(
                session.pair(forRight: 1) == nil, "A passage that is only an unmatched one's closest guess has no pair")
            #expect(session.pair(forRight: 2)?.uniqueSide == .right)
            #expect(session.pair(forLeft: 9) == nil)
        }

        @Test func alignmentKeepsStableIdsAndMarksWhichReportIsAlone() async {
            let shared = "The harbour authority reopened the northern channel to ferries on Friday morning."
            let service = DualReaderAlignmentService()
            let session = await service.align(
                left: .init(
                    id: "l", title: "Channel reopens",
                    content: shared + "\n\nThe council will vote on the annual budget next week after a long debate.",
                    publisher: "Left"),
                right: .init(
                    id: "r", title: "Channel reopens",
                    content: shared
                        + "\n\nThe local football club won its cup match by three goals on Saturday afternoon.",
                    publisher: "Right"))
            #expect(session.passageAlignments.contains { $0.contrastType == .consensus })
            #expect(session.passageAlignments.map(\.id).allSatisfy { UUID(uuidString: $0) == nil }, "Ids are positions")
            for pair in session.passageAlignments {
                #expect((pair.contrastType == .uniqueLead) == (pair.uniqueSide != nil), "\(pair.id)")
            }
            let again = await service.align(
                left: .init(id: "l", title: "Channel reopens", content: shared, publisher: "Left"),
                right: .init(id: "r", title: "Channel reopens", content: shared, publisher: "Right"))
            #expect(again.passageAlignments.map(\.id) == ["0-0", "1-1"], "The same text gives the same ids")
            #expect(
                await service.boundedPassages(
                    title: "T",
                    content: (1...200).map { "Paragraph number \($0) has enough words." }.joined(separator: "\n\n")
                ).count == DualReaderAlignmentService.maximumPassages)
        }
    }
}
