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

extension DatabaseEngine {
    /// One actor turn captures current stored text, citations and notes without fetching or changing read state.
    func knowledgeExportDocuments(articleIDs: [String], digest: Bool = false) throws -> [KnowledgeExportDocument] {
        guard articleIDs.count <= FiniteBriefing.maximumStories else { throw KnowledgeEPUB.Error.tooLarge }
        return try articleIDs.map { id in
            try Task.checkCancellation()
            guard let article = try fetchArticles(limit: 1, id: id).first else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let overview = try fetchEventOverview(forArticleID: article.id)
            let quotes = try (overview?.citations.values.sorted { $0.id < $1.id } ?? []).map { citation in
                let source = try fetchArticles(limit: 1, id: citation.articleID).first
                return KnowledgeExport.quote(citation, sourceArticle: source)
            }
            let text =
                article.readerDocument?.blocks.map(\.text).joined(separator: "\n\n")
                ?? FeedXMLParser.stripHTMLSimple(article.fullContent ?? article.description)
            let notes = try fetchNotes(for: article.id)
            let body = digest ? FeedXMLParser.stripHTMLSimple(article.description) : text
            guard body.utf8.count <= 2 * 1024 * 1024, notes.count <= 10000, quotes.count <= 1000 else {
                throw KnowledgeEPUB.Error.tooLarge
            }
            return KnowledgeExportDocument(
                id: article.id, title: article.title, publisher: article.source,
                url: article.link, published: article.pubDate == DateParser.unknownDate ? nil : article.pubDate,
                body: body, tags: article.category.map { [$0] } ?? [], quotes: quotes, notes: notes)
        }
    }
}
