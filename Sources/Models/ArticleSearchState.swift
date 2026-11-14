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
import SwiftUI

/// Structured query representation produced by reader tag search transformations.
struct ReaderTagSearchQuery: Equatable, Sendable {
    /// The category chip, for a category tag; nil for an entity tag.
    let token: ArchiveSearchToken?
    /// The quoted entity phrase, for an entity tag; empty for a category tag.
    let text: String

    /// The archive query the token and text stand for.
    var query: String {
        ArchiveSearchToken.query(text: text, tokens: token.map { [$0] } ?? [])
    }

    /// Creates a query from its parts.
    init(token: ArchiveSearchToken?, text: String) {
        self.token = token
        self.text = text
    }
}

/// Observable coordinator managing archive search query text, operator tokens, presentation,
/// and breadcrumb history to return to an open story.
@MainActor
final class ArticleSearchState: ObservableObject {
    /// The free text in the search field, without its chips.
    @Published var searchText: String = ""
    /// The operator chips in the search field.
    @Published var searchTokens: [ArchiveSearchToken] = []
    /// Whether the search field is presented.
    @Published var searchPresented: Bool = false
    @Published private(set) var returnStoryStack: [FeedArticleWrap] = []
    @Published private(set) var searchHistory: [String] = []
    private var pendingReturnTextChange = false
    private var pendingReturnTokensChange = false

    /// The story the latest tag search was opened from, which Back returns to; nil when search was not opened from a
    /// story.
    var returnStory: FeedArticleWrap? {
        returnStoryStack.last
    }

    /// The full archive query: chips first, then free text.
    var archiveQuery: String {
        ArchiveSearchToken.query(text: searchText, tokens: searchTokens)
    }

    /// Whether the field holds any query.
    var isSearching: Bool {
        !archiveQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Navigation & Breadcrumb Operations

    /// Opens search pre-filled with the transformed tag query, pushing the originating article onto the return stack.
    func openTag(tag: String, isCategory: Bool, from wrap: FeedArticleWrap, path: inout NavigationPath) {
        cancelPendingReturnChanges()
        returnStoryStack.append(wrap)
        let resolved = Self.searchQuery(for: tag, isCategory: isCategory)
        if let token = resolved.token {
            searchTokens = [token]
            searchText = ""
        } else {
            searchTokens = []
            searchText = resolved.text
        }
        recordHistory(query: archiveQuery)
        searchPresented = true
        if !path.isEmpty {
            path = NavigationPath()
        }
    }

    /// Returns from search to the story that opened it, popping the top of the return stack.
    func returnToStory(path: inout NavigationPath) {
        guard let wrap = returnStoryStack.popLast() else { return }
        recordHistory(query: archiveQuery)
        searchPresented = false
        pendingReturnTextChange = !searchText.isEmpty
        pendingReturnTokensChange = !searchTokens.isEmpty
        searchText = ""
        searchTokens = []
        path.append(wrap)
    }

    /// Consume the deferred SwiftUI observations of the programmatic reset.
    func consumeReturnTextChange(_ updated: String) -> Bool {
        defer { pendingReturnTextChange = false }
        return pendingReturnTextChange && updated.isEmpty && searchText.isEmpty
    }

    /// The token counterpart of `consumeReturnTextChange(_:)`: true when this observation is the return reset itself,
    /// which the caller then ignores.
    func consumeReturnTokensChange(_ updated: [ArchiveSearchToken]) -> Bool {
        defer { pendingReturnTokensChange = false }
        return pendingReturnTokensChange && updated.isEmpty && searchTokens.isEmpty
    }

    /// User edits and other programmatic resets supersede an unobserved return reset.
    func cancelPendingReturnChanges() {
        pendingReturnTextChange = false
        pendingReturnTokensChange = false
    }

    /// Clears the return story breadcrumb stack without touching active search text.
    func clearReturnStack() {
        returnStoryStack.removeAll()
    }

    /// Clears active search parameters, search presentation, and the return stack.
    func clear() {
        cancelPendingReturnChanges()
        searchText = ""
        searchTokens = []
        searchPresented = false
        returnStoryStack.removeAll()
    }

    /// Records a search query in history, keeping the most recent unique queries.
    func recordHistory(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0 == trimmed }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > 20 {
            searchHistory.removeLast()
        }
    }

    // MARK: - Pure Query Builder Functions

    /// Sanitizes and normalizes a category string into a valid token expression value.
    ///
    /// Preserves diacritics while trimming leading/trailing whitespace, stripping redundant "category:" prefixes,
    /// and replacing internal whitespace runs with hyphens so the token remains single-word compliant.
    nonisolated static func sanitizeCategory(_ rawCategory: String) -> String {
        var text = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("category:") {
            text = String(text.dropFirst("category:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        return words.joined(separator: "-").lowercased()
    }

    /// Builds an `ArchiveSearchToken` for the given category string.
    nonisolated static func categoryToken(for rawCategory: String) -> ArchiveSearchToken {
        let sanitized = sanitizeCategory(rawCategory)
        return ArchiveSearchToken(expression: "category:\(sanitized)")
    }

    /// Sanitizes and normalizes an entity name by stripping surrounding quotes and escaping internal quotes.
    nonisolated static func sanitizeEntityName(_ rawEntity: String) -> String {
        var text = rawEntity.trimmingCharacters(in: .whitespacesAndNewlines)
        while (text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2)
            || (text.hasPrefix("“") && text.hasSuffix("”") && text.count >= 2)
            || (text.hasPrefix("«") && text.hasSuffix("»") && text.count >= 2)
        {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacingOccurrences(of: "\"", with: "'")
        text = text.replacingOccurrences(of: "“", with: "'")
        text = text.replacingOccurrences(of: "”", with: "'")
        text = text.replacingOccurrences(of: "«", with: "'")
        text = text.replacingOccurrences(of: "»", with: "'")
        return text
    }

    /// Builds a quoted search phrase query string for an entity name.
    nonisolated static func entityQuery(for rawEntity: String) -> String {
        let sanitized = sanitizeEntityName(rawEntity)
        guard !sanitized.isEmpty else { return "" }
        return "\"\(sanitized)\""
    }

    /// Turns a tag name and its category flag into a structured query representation.
    nonisolated static func searchQuery(for tag: String, isCategory: Bool) -> ReaderTagSearchQuery {
        if isCategory {
            let token = categoryToken(for: tag)
            return ReaderTagSearchQuery(token: token, text: "")
        } else {
            let entityText = entityQuery(for: tag)
            return ReaderTagSearchQuery(token: nil, text: entityText)
        }
    }
}

// MARK: - Environment Support

private struct ArticleSearchStateKey: EnvironmentKey {
    static let defaultValue: ArticleSearchState? = nil
}

extension EnvironmentValues {
    /// The window's search state; nil outside a main window.
    var articleSearchState: ArticleSearchState? {
        get { self[ArticleSearchStateKey.self] }
        set { self[ArticleSearchStateKey.self] = newValue }
    }
}
