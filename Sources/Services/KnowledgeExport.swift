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

/// A passage an event overview cites, attributed to its publisher.
struct KnowledgeExportQuote: Sendable {
    let text: String
    let publisher: String
    /// The source link; empty when neither the citation nor its article has one.
    let url: String
}

/// One story as the exports write it: stored publisher text, cited passages and the reader's notes, kept apart.
struct KnowledgeExportDocument: Sendable {
    let id: String
    let title: String
    let publisher: String
    let url: String
    /// The publication date; nil when the feed gave none.
    let published: Date?
    /// The stored reader text, or the plain-text description in a digest export.
    let body: String
    /// The story's feed category, when it has one.
    let tags: [String]
    /// The passages the story's event overview cites.
    let quotes: [KnowledgeExportQuote]
    /// The reader's highlights and notes on the story.
    let notes: [UserNote]
}

/// Explicit local exports; publisher text and private annotations remain separate and attributed.
enum KnowledgeExport {
    /// The export form of a citation, falling back to the cited article's source and link, then to "Unknown publisher"
    /// and an empty link.
    static func quote(_ citation: OverviewCitation, sourceArticle: FeedArticle?) -> KnowledgeExportQuote {
        KnowledgeExportQuote(
            text: citation.quote, publisher: citation.sourceName ?? sourceArticle?.source ?? "Unknown publisher",
            url: citation.sourceURL ?? sourceArticle?.link ?? "")
    }

    /// A double-quoted YAML scalar: quotes and backslashes escaped, control and line-separator characters as `\uXXXX`.
    static func yamlString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
                result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// Renders the documents as UTF-8 Markdown with YAML front matter. A single document takes the front matter
    /// (source, link, tags, date) and the top heading; several share one titled file with a section each.
    static func markdown(_ documents: [KnowledgeExportDocument], title: String) -> Data {
        var lines = [
            "---", "title: " + yamlString(title), "format: news-knowledge-v1", "---", "", "# " + escapeMarkdown(title),
            "",
        ]
        for document in documents {
            if documents.count == 1 {
                lines = [
                    "---", "title: " + yamlString(document.title), "source: " + yamlString(document.publisher),
                    "url: " + yamlString(document.url),
                    "tags: [" + document.tags.map(yamlString).joined(separator: ", ") + "]",
                ]
                if let date = document.published { lines.append("published: " + yamlString(date.formatted(.iso8601))) }
                lines += ["---", "", "# " + escapeMarkdown(document.title), ""]
            } else {
                lines += ["## " + escapeMarkdown(document.title), ""]
            }
            lines += [source(document.publisher, document.url), "", escapeMarkdown(document.body), ""]
            if !document.quotes.isEmpty { lines += ["### Cited passages", ""] }
            for quote in document.quotes {
                lines += quote.text.components(separatedBy: .newlines).map { "> " + escapeMarkdown($0) }
                lines += ["", source(quote.publisher, quote.url), ""]
            }
            if !document.notes.isEmpty {
                let sortedNotes = document.notes.sortedInReadingOrder()
                lines += ["### My highlights and notes", ""]
                if sortedNotes.count > 1 {
                    lines += ["_Story passages in reading order (\(sortedNotes.count)):_", ""]
                }
                for (i, note) in sortedNotes.enumerated() {
                    if sortedNotes.count > 1 {
                        lines += ["#### Passage \(i + 1)", ""]
                    }
                    lines += note.selectedText.components(separatedBy: .newlines).map { "> " + escapeMarkdown($0) }
                    lines += ["", escapeMarkdown(note.noteBody), ""]
                }
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Backslash-escapes the Markdown punctuation in `punctuation`, so stored text cannot form emphasis, code or links; /// a line starting with a number and a period can still render as a list.
    static func escapeMarkdown(_ text: String) -> String {
        let punctuation = Set("\\`*_{}[]<>()#+!|~->")
        return text.map { punctuation.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    private static func source(_ publisher: String, _ url: String) -> String {
        guard let safe = WebLink.url(url) else { return escapeMarkdown(publisher) }
        let destination = safe.absoluteString.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(
            of: ">", with: "%3E")
        return "[" + escapeMarkdown(publisher) + "](<" + destination + ">)"
    }
}
