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

import AppKit
import Foundation

enum KnowledgeExportTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value {
            failures += 1
            print("FAIL KnowledgeExport: " + message)
        }
    }
    @MainActor static func run() async {
        do {
            let text = "Title: \"quoted\"\n---\n<script> & café 🐈\u{2028}end"
            let scalar = KnowledgeExport.yamlString(text)
            check(
                try JSONDecoder().decode(String.self, from: Data(scalar.utf8)) == text, "YAML quoted scalar round trip")
            let note = UserNote(
                articleID: "id", paragraphIndex: 0, charStart: 0, selectedText: "Quoted publisher words", prefix: "",
                suffix: "", noteBody: "Private note <script>alert(1)</script>")
            let document = KnowledgeExportDocument(
                id: "id", title: text, publisher: "Original [publisher]", url: "https://example.com/story?a=1&b=2",
                published: Date(timeIntervalSince1970: 0), body: "Cached publisher body <img src=x>",
                tags: ["science: space", "x\ny"],
                quotes: [
                    .init(
                        text: "Cited qualified words", publisher: "Second publisher", url: "https://example.org/report")
                ], notes: [note])
            let unknown = OverviewCitation(
                id: "c", articleID: "gone", passageID: "p", passageFingerprint: "f", quote: "Qualified words",
                source: OverviewSourceMetadata(name: "Independent source"))
            let unattributed = KnowledgeExport.quote(unknown, sourceArticle: nil)
            check(
                unattributed.publisher == "Independent source" && unattributed.url.isEmpty,
                "missing citation URL never links to unrelated representative")
            let markdown = KnowledgeExport.markdown([document], title: "Reading")
            let output = String(decoding: markdown, as: UTF8.self)
            check(
                output.hasPrefix("---\ntitle: ") && output.components(separatedBy: "\n---\n").count == 2,
                "one frontmatter boundary; untrusted title cannot inject YAML")
            check(
                output.contains("My highlights and notes") && output.contains("Quoted publisher words"),
                "notes and highlights")
            check(
                output.contains("Cited qualified words") && output.contains("example.org/report"),
                "independent source citation")
            let body = output.components(separatedBy: "\n---\n").last ?? ""
            check(body.contains("\\<script\\>") && body.contains("\\<img"), "publisher and note HTML is escaped")
            let rich = KnowledgeExportUI.richText([document], title: "Reading")
            check(
                rich.string.contains(note.noteBody) && rich.string.contains("Second publisher"),
                "rich text retains private note and attribution")
            let rtf = try rich.data(
                from: NSRange(location: 0, length: rich.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let decoded = try NSAttributedString(
                data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            check(decoded.string == rich.string, "native rich text round trip")
            let digest = String(
                decoding: KnowledgeExport.markdown([document, document], title: "Briefing · 2026-11-06"), as: UTF8.self)
            check(
                digest.contains("Briefing") && digest.components(separatedBy: "## Title").count == 3,
                "digest preserves selected order and stories")
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            var article = FeedArticle(
                title: "Stored story", link: "https://example.com/stored", guid: "stored", description: "Feed excerpt",
                pubDate: DateParser.unknownDate, source: "Publisher")
            article.fullContent = "<p>Full cached text</p>"
            try await db.upsertArticles([article])
            let storedNote = UserNote(
                articleID: article.id, paragraphIndex: 0, charStart: 0, selectedText: "Full cached text", prefix: "",
                suffix: "", noteBody: "My stored note", createdAt: Date(timeIntervalSince1970: 1000),
                updatedAt: Date(timeIntervalSince1970: 1000))
            try await db.saveNotes([storedNote])
            let documents = try await db.knowledgeExportDocuments(articleIDs: [article.id])
            check(
                documents.count == 1 && documents[0].notes == [storedNote] && documents[0].published == nil,
                "database snapshot preserves notes and unknown dates")
            check(documents[0].body == "Full cached text", "cached full text, not feed excerpt")
            let digestDocuments = try await db.knowledgeExportDocuments(articleIDs: [article.id], digest: true)
            check(digestDocuments[0].body == "Feed excerpt", "digest uses compact cached excerpt")
            do {
                _ = try await db.knowledgeExportDocuments(articleIDs: ["missing"])
                check(false, "missing story must fail, never silently omit")
            } catch { check(true, "missing story rejected") }
            if let directory = ProcessInfo.processInfo.environment["NEWS_KNOWLEDGE_OUTPUT"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try markdown.write(to: root.appendingPathComponent("reading.md"), options: .withoutOverwriting)
                try rtf.write(to: root.appendingPathComponent("reading.rtf"), options: .withoutOverwriting)
                try KnowledgeEPUB.make(documents: [document], title: "Reading").write(
                    to: root.appendingPathComponent("reading.epub"), options: .withoutOverwriting)
                let service = NSSharingService(named: NSSharingService.Name("com.apple.Notes.SharingExtension"))
                print("NOTES_SERVICE_AVAILABLE=\(service?.canPerform(withItems: [rich]) ?? false)")
            }
        } catch { check(false, "Unexpected error: \(error)") }
        print("Finished \(checks) knowledge export checks with \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
