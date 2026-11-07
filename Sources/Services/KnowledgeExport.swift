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
import NewsCore

struct KnowledgeExportQuote: Sendable {
    let text: String
    let publisher: String
    let url: String
}

struct KnowledgeExportDocument: Sendable {
    let id: String
    let title: String
    let publisher: String
    let url: String
    let published: Date?
    let body: String
    let tags: [String]
    let quotes: [KnowledgeExportQuote]
    let notes: [UserNote]
}

/// Explicit local exports; publisher text and private annotations remain separate and attributed.
enum KnowledgeExport {
    static func quote(_ citation: OverviewCitation, sourceArticle: FeedArticle?) -> KnowledgeExportQuote {
        KnowledgeExportQuote(
            text: citation.quote, publisher: citation.sourceName ?? sourceArticle?.source ?? "Unknown publisher",
            url: citation.sourceURL ?? sourceArticle?.link ?? "")
    }

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
            if !document.notes.isEmpty { lines += ["### My highlights and notes", ""] }
            for note in document.notes {
                lines += note.selectedText.components(separatedBy: .newlines).map { "> " + escapeMarkdown($0) }
                lines += ["", escapeMarkdown(note.noteBody), ""]
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

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
