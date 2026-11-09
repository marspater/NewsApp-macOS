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

/// One publisher's account of an event, as the dual reader reads it (W3 #717).
struct PerspectiveReport: Identifiable, Hashable, Sendable {
    /// The article's id.
    let id: String
    let publisher: String
    let title: String
    let text: String
    let wordCount: Int
}

enum PerspectiveReports {
    /// Fewer words than this compare headlines, not reporting.
    static let minimumWords = 60

    /// One report per publisher, the one with the most text, richest first, so the first two are the fullest accounts.
    /// A publisher counts once however many reports it has, and a report too short to compare is left out; an event
    /// with fewer than two such publishers has nothing to compare and shows no "Compare Perspectives" action.
    static func candidates(from articles: [FeedArticle]) -> [PerspectiveReport] {
        var richest: [String: PerspectiveReport] = [:]
        for article in articles {
            let text = [article.fullContent, article.description].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            let words = text.split(whereSeparator: \.isWhitespace).count
            guard words >= minimumWords else { continue }
            let report = PerspectiveReport(
                id: article.id, publisher: article.publisherName, title: article.title, text: text, wordCount: words)
            if let kept = richest[report.publisher], kept.wordCount >= words { continue }
            richest[report.publisher] = report
        }
        return richest.values.sorted { ($0.wordCount, $1.publisher) > ($1.wordCount, $0.publisher) }
    }
}
