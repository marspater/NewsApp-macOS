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
import SwiftUI
import UniformTypeIdentifiers

/// Focused commands compare their captured context, not new closure instances on every reader render.
struct KnowledgeExportActions: Equatable {
    struct Context: Equatable {
        let articleIDs: [String]
        let title: String
        let storeID: ObjectIdentifier
        let digest: Bool
    }
    let markdown: () -> Void
    let epub: () -> Void
    let notes: () -> Void
    var context: Context? = nil

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.context == rhs.context }
}
private struct KnowledgeExportActionsKey: FocusedValueKey { typealias Value = KnowledgeExportActions }
extension FocusedValues {
    var knowledgeExport: KnowledgeExportActions? {
        get { self[KnowledgeExportActionsKey.self] }
        set { self[KnowledgeExportActionsKey.self] = newValue }
    }
}

struct KnowledgeExportMenu: View {
    let actions: KnowledgeExportActions
    var body: some View {
        Menu {
            Button("Export as Markdown…", action: actions.markdown)
            Button("Compile to EPUB…", action: actions.epub)
            Button("Add to Apple Notes…", action: actions.notes)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up.on.square")
        }
        .help("Export stored text, cited passages and your private notes")
    }
}

enum KnowledgeExportFormat: Sendable { case markdown, epub, notes }

private actor KnowledgeExportEncoder {
    static let shared = KnowledgeExportEncoder()
    func write(_ payload: Data, to destination: URL) throws {
        try Task.checkCancellation()
        try payload.write(to: destination, options: .atomic)
    }

    func encode(_ documents: [KnowledgeExportDocument], title: String, format: KnowledgeExportFormat) throws -> Data {
        try Task.checkCancellation()
        // The EPUB writer validates aggregate input size before rendering any format.
        try KnowledgeEPUB.validate(documents: documents, title: title)
        return format == .epub
            ? try KnowledgeEPUB.make(documents: documents, title: title)
            : KnowledgeExport.markdown(documents, title: title)
    }
}

/// Owns one explicit, bounded export operation. Replacing it cancels presentation of the older result.
@MainActor enum KnowledgeExportUI {
    private static var task: Task<Void, Never>?
    static func actions(articles: [FeedArticle], title: String, store: ArticleStore, digest: Bool = false)
        -> KnowledgeExportActions
    {
        KnowledgeExportActions(
            markdown: { start(articles: articles, title: title, store: store, digest: digest, format: .markdown) },
            epub: { start(articles: articles, title: title, store: store, digest: digest, format: .epub) },
            notes: { start(articles: articles, title: title, store: store, digest: digest, format: .notes) },
            context: .init(
                articleIDs: articles.map(\.id), title: title, storeID: ObjectIdentifier(store), digest: digest))
    }

    private static func start(
        articles: [FeedArticle], title: String, store: ArticleStore, digest: Bool, format: KnowledgeExportFormat
    ) {
        task?.cancel()
        task = Task { @MainActor in
            do {
                let documents = try await store.database.knowledgeExportDocuments(
                    articleIDs: articles.map(\.id), digest: digest)
                let payload = try await KnowledgeExportEncoder.shared.encode(documents, title: title, format: format)
                try Task.checkCancellation()
                if format == .notes {
                    try shareToNotes(documents, title: title)
                    return
                }
                let panel = NSSavePanel()
                let ext = format == .epub ? "epub" : "md"
                panel.title = digest ? "Export Briefing Digest" : "Export Story"
                panel.prompt = "Export"
                panel.message = "Includes stored publisher text and your private highlights and notes."
                panel.nameFieldStringValue = "News Export." + ext
                panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try Task.checkCancellation()
                try await KnowledgeExportEncoder.shared.write(payload, to: destination)
            } catch is CancellationError {
                // A newer explicit export replaced this one.
            } catch { NSAlert(error: error).runModal() }
        }
    }

    static func richText(_ documents: [KnowledgeExportDocument], title: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title + "\n", attributes: [.font: NSFont.preferredFont(forTextStyle: .headline)])
        for document in documents {
            result.append(
                NSAttributedString(
                    string: "\n" + document.title + "\n",
                    attributes: [.font: NSFont.preferredFont(forTextStyle: .headline)]))
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let url = WebLink.url(document.url) { attributes[.link] = url }
            result.append(
                NSAttributedString(string: document.publisher + " — " + document.url + "\n", attributes: attributes))
            result.append(NSAttributedString(string: document.body + "\n"))
            for quote in document.quotes {
                var attribution: [NSAttributedString.Key: Any] = [:]
                if let url = WebLink.url(quote.url) { attribution[.link] = url }
                result.append(NSAttributedString(string: "\n“" + quote.text + "”\n"))
                result.append(
                    NSAttributedString(string: quote.publisher + " — " + quote.url + "\n", attributes: attribution))
            }
            if !document.notes.isEmpty {
                let sortedNotes = document.notes.sortedInReadingOrder()
                result.append(NSAttributedString(string: "\nMy highlights and notes\n"))
                if sortedNotes.count > 1 {
                    result.append(
                        NSAttributedString(string: "Story passages in reading order (\(sortedNotes.count)):\n"))
                }
                for (i, note) in sortedNotes.enumerated() {
                    let prefix = sortedNotes.count > 1 ? "\nPassage \(i + 1):\n" : ""
                    let body = note.noteBody.isEmpty ? "" : note.noteBody + "\n"
                    result.append(NSAttributedString(string: "\(prefix)“\(note.selectedText)”\n\(body)"))
                }
            }
        }
        return result
    }

    static func shareToNotes(_ documents: [KnowledgeExportDocument], title: String) throws {
        let service = NSSharingService(named: NSSharingService.Name("com.apple.Notes.SharingExtension"))
        let items: [Any] = [richText(documents, title: title)]
        guard let service, service.canPerform(withItems: items) else { throw CocoaError(.featureUnsupported) }
        service.perform(withItems: items)
    }
}
