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

import AppIntents
import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import NaturalLanguage
import Network
import PDFKit
import SQLite3
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Native port of the `KnowledgeExportTests` atom (#1070): its one test, the Markdown, rich text and database export
/// check, with each `check` turned into `expectTrue` of NativeExpectations.swift (the runner log is invisible to Swift
/// Testing), so a failure is recorded and later checks still run. The `NEWS_KNOWLEDGE_OUTPUT` branch, which writes the
/// exports to a folder for a manual look and asserts nothing, stays as in the runner; the test plans do not set it. The
/// atom's closing summary is not a test and stays in the runner. The runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.knowledgeExport, .integration)) struct KnowledgeExportSuite {
        @Test @MainActor func knowledgeExport() async { await Self.testKnowledgeExport() }
    }
}

extension NativeSuites.KnowledgeExportSuite {
    @MainActor static func testKnowledgeExport() async {
        do {
            let commandOwner = NSObject()
            let context = KnowledgeExportActions.Context(
                articleIDs: ["one"], title: "Story", storeID: ObjectIdentifier(commandOwner), digest: false)
            let firstActions = KnowledgeExportActions(markdown: {}, epub: {}, notes: {}, context: context)
            let newClosures = KnowledgeExportActions(
                markdown: { print("unused") }, epub: {}, notes: {}, context: context)
            expectTrue(
                firstActions == newClosures,
                "fresh closures for unchanged focused commands do not invalidate the window")
            let nextStory = KnowledgeExportActions(
                markdown: {}, epub: {}, notes: {},
                context: .init(
                    articleIDs: ["two"], title: "Story", storeID: ObjectIdentifier(commandOwner), digest: false))
            expectTrue(firstActions != nextStory, "new selection replaces captured export commands")
            let text = "Title: \"quoted\"\n---\n<script> & café 🐈\u{2028}end"
            let scalar = KnowledgeExport.yamlString(text)
            expectTrue(
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
            expectTrue(
                unattributed.publisher == "Independent source" && unattributed.url.isEmpty,
                "missing citation URL never links to unrelated representative")
            let markdown = KnowledgeExport.markdown([document], title: "Reading")
            let output = String(decoding: markdown, as: UTF8.self)
            expectTrue(
                output.hasPrefix("---\ntitle: ") && output.components(separatedBy: "\n---\n").count == 2,
                "one frontmatter boundary; untrusted title cannot inject YAML")
            expectTrue(
                output.contains("My highlights and notes") && output.contains("Quoted publisher words"),
                "notes and highlights")
            expectTrue(
                !output.contains("Story passages in reading order"), "single note has no extraneous group header")
            let note2 = UserNote(
                articleID: "id", paragraphIndex: 1, charStart: 0, selectedText: "Second quote", prefix: "",
                suffix: "", noteBody: "Second private note")
            let multiDoc = KnowledgeExportDocument(
                id: "id", title: text, publisher: "Original [publisher]", url: "https://example.com/story",
                published: Date(timeIntervalSince1970: 0), body: "Body", tags: [], quotes: [], notes: [note2, note])
            let multiOutput = String(decoding: KnowledgeExport.markdown([multiDoc], title: "Reading"), as: UTF8.self)
            expectTrue(
                multiOutput.contains("Story passages in reading order (2)"), "multiple notes group header in export")
            expectTrue(
                multiOutput.contains("Passage 1") && multiOutput.contains("Passage 2"),
                "passages numbered in reading order")
            let passage1Start = multiOutput.range(of: "Passage 1")?.upperBound ?? multiOutput.startIndex
            let noteIdx = multiOutput.range(of: "Quoted publisher words", range: passage1Start..<multiOutput.endIndex)?
                .lowerBound
            let note2Idx = multiOutput.range(of: "Second quote", range: passage1Start..<multiOutput.endIndex)?
                .lowerBound
            expectTrue(noteIdx != nil && note2Idx != nil && noteIdx! < note2Idx!, "notes exported in reading order")
            expectTrue(
                output.contains("Cited qualified words") && output.contains("example.org/report"),
                "independent source citation")
            let body = output.components(separatedBy: "\n---\n").last ?? ""
            expectTrue(body.contains("\\<script\\>") && body.contains("\\<img"), "publisher and note HTML is escaped")
            let rich = KnowledgeExportUI.richText([document], title: "Reading")
            expectTrue(
                rich.string.contains(note.noteBody) && rich.string.contains("Second publisher"),
                "rich text retains private note and attribution")
            let rtf = try rich.data(
                from: NSRange(location: 0, length: rich.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let decoded = try NSAttributedString(
                data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            expectTrue(decoded.string == rich.string, "native rich text round trip")
            let digest = String(
                decoding: KnowledgeExport.markdown([document, document], title: "Briefing · 2026-11-06"), as: UTF8.self)
            expectTrue(
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
            expectTrue(
                documents.count == 1 && documents[0].notes == [storedNote] && documents[0].published == nil,
                "database snapshot preserves notes and unknown dates")
            expectTrue(documents[0].body == "Full cached text", "cached full text, not feed excerpt")
            let digestDocuments = try await db.knowledgeExportDocuments(articleIDs: [article.id], digest: true)
            expectTrue(digestDocuments[0].body == "Feed excerpt", "digest uses compact cached excerpt")
            do {
                _ = try await db.knowledgeExportDocuments(articleIDs: ["missing"])
                expectTrue(false, "missing story must fail, never silently omit")
            } catch {
                expectTrue(
                    error.localizedDescription == KnowledgeEPUB.Error.storyMissing.errorDescription,
                    "missing story rejected with a readable message")
            }
            expectTrue(
                KnowledgeEPUB.Error.tooLarge.localizedDescription.hasPrefix("This export is too large"),
                "size limit explains itself")
            var mediaOnly = FeedArticle(
                title: "Media only", link: "https://example.com/media-only", guid: "media-only",
                description: "<p>Media description</p>",
                pubDate: Date(timeIntervalSince1970: 1000), source: "Publisher")
            mediaOnly.readerDocument = ReaderDocument(blocks: [ReaderBlock(kind: .embed, text: "Social post")])
            var mixed = FeedArticle(
                title: "Mixed", link: "https://example.com/mixed", guid: "mixed", description: "Mixed description",
                pubDate: Date(timeIntervalSince1970: 1000), source: "Publisher")
            mixed.readerDocument = ReaderDocument(blocks: [
                ReaderBlock(kind: .paragraph, text: "Story text"), ReaderBlock(kind: .embed, text: "example.com"),
                ReaderBlock(kind: .figure, text: "A caption"), ReaderBlock(kind: .divider, text: ""),
                ReaderBlock(kind: .table, text: "a\tb"),
            ])
            try await db.upsertArticles([mediaOnly, mixed])
            let blockDocuments = try await db.knowledgeExportDocuments(articleIDs: [mediaOnly.id, mixed.id])
            expectTrue(
                blockDocuments[0].body == "Media description", "media-only document falls back to the description")
            expectTrue(
                blockDocuments[1].body == "Story text\n\nA caption\n\na\tb",
                "embed notices leave the export; captions and tables stay")
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
        } catch { expectTrue(false, "Unexpected error: \(error)") }
    }
}
