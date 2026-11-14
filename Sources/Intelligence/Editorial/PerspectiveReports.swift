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

// Angelia · Clio (sourced overviews) owns this file. Register: docs/ANGELIA.md.

import Foundation

/// One publisher's account of an event, as the dual reader reads it (W3 #717).
struct PerspectiveReport: Identifiable, Hashable, Sendable {
    /// The article's id.
    let id: String
    let publisher: String
    let title: String
    /// The article's full text, or its description when no full text is stored.
    let text: String
    /// Whitespace-separated words in `text`; `PerspectiveReports.candidates(from:)` makes no report below
    /// `minimumWords`.
    let wordCount: Int
}

/// Picks the reports of an event that the dual reader can compare.
enum PerspectiveReports {
    /// Fewer words than this compare headlines, not reporting.
    static let minimumWords = 60

    private static func text(of article: FeedArticle) -> String {
        [article.fullContent, article.description].compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    /// What `candidates(from:)` reads, per article: its id and a hash of the publisher, the title and the text. A view
    /// keys its task on this, so a member whose text arrives or is edited after the overview opened, even to the same
    /// length, or whose title changes, is read again, not only when the set of members changes. The hash lives for one
    /// run of the app, which is all a task id needs.
    static func inputs(of articles: [FeedArticle]) -> [String] {
        articles.map { article in
            var hasher = Hasher()
            hasher.combine(article.publisherName)
            hasher.combine(article.title)
            hasher.combine(text(of: article))
            return "\(article.id):\(hasher.finalize())"
        }
    }

    /// One report per publisher, the one with the most text, richest first, so the first two are the fullest accounts.
    /// A publisher counts once however many reports it has, and a report too short to compare is left out; an event
    /// with fewer than two such publishers has nothing to compare and shows no "Compare Perspectives" action.
    static func candidates(from articles: [FeedArticle]) -> [PerspectiveReport] {
        var richest: [String: PerspectiveReport] = [:]
        for article in articles {
            let text = text(of: article)
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
