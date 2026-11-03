// Copyright 2026 NewsApp Contributors
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

/// A user-defined virtual section ("Smart Binder") evaluated dynamically via SQLite queries.
/// Compound rules specify categories, include keywords, exclude keywords, and publishers without
/// duplicating rows or persisting story membership in the database.
public struct SmartBinder: Identifiable, Codable, Sendable, Hashable, Equatable {
    public var id: UUID
    public var name: String
    public var icon: String
    public var categories: [String]
    public var includeKeywords: [String]
    public var excludeKeywords: [String]
    public var publishers: [String]
    public var createdAt: Date
    public var matchAllKeywords: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "folder",
        categories: [String] = [],
        includeKeywords: [String] = [],
        excludeKeywords: [String] = [],
        publishers: [String] = [],
        matchAllKeywords: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.categories = categories
        self.includeKeywords = includeKeywords
        self.excludeKeywords = excludeKeywords
        self.publishers = publishers
        self.createdAt = Date()
        self.matchAllKeywords = matchAllKeywords
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, categories, includeKeywords, excludeKeywords, publishers, createdAt, matchAllKeywords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "folder"
        self.categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        self.includeKeywords = try container.decodeIfPresent([String].self, forKey: .includeKeywords) ?? []
        self.excludeKeywords = try container.decodeIfPresent([String].self, forKey: .excludeKeywords) ?? []
        self.publishers = try container.decodeIfPresent([String].self, forKey: .publishers) ?? []
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.matchAllKeywords = try container.decodeIfPresent(Bool.self, forKey: .matchAllKeywords) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(categories, forKey: .categories)
        try container.encode(includeKeywords, forKey: .includeKeywords)
        try container.encode(excludeKeywords, forKey: .excludeKeywords)
        try container.encode(publishers, forKey: .publishers)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(matchAllKeywords, forKey: .matchAllKeywords)
    }

    // MARK: - Sidebar Identifiers

    public var sidebarTag: String {
        "binder:\(id.uuidString)"
    }

    public static func isBinderTag(_ tag: String) -> Bool {
        tag.hasPrefix("binder:")
    }

    public static func binderID(fromTag tag: String) -> UUID? {
        guard tag.hasPrefix("binder:") else { return nil }
        return UUID(uuidString: String(tag.dropFirst(7)))
    }

    /// Escapes SQL LIKE special wildcard characters (`%`, `_`, `\`) using `\` as the escape character.
    public static func escapeLikeWildcards(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Parameterized SQL Translation

    private static func cleanTerms(_ terms: [String]) -> [String] {
        terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func categoryCondition() -> (clause: String?, parameters: [String]) {
        let clean = Self.cleanTerms(categories)
        guard !clean.isEmpty else { return (nil, []) }
        var clauses: [String] = []
        var parameters: [String] = []
        for cat in clean {
            if cat == "U.S. Politics" {
                clauses.append(
                    "news_section(a.title, coalesce(a.description, ''), coalesce(ae.category, a.category), ?) = 1")
                parameters.append(cat)
            } else {
                clauses.append("coalesce(ae.category, a.category) LIKE ? ESCAPE '\\'")
                parameters.append("%\(Self.escapeLikeWildcards(cat))%")
            }
        }
        return ("(" + clauses.joined(separator: " OR ") + ")", parameters)
    }

    private func publisherCondition() -> (clause: String?, parameters: [String]) {
        let clean = Self.cleanTerms(publishers)
        guard !clean.isEmpty else { return (nil, []) }
        let clauses = clean.map { _ in "(a.source LIKE ? ESCAPE '\\' OR a.canonical_url LIKE ? ESCAPE '\\')" }
        var parameters: [String] = []
        for pub in clean {
            let escaped = Self.escapeLikeWildcards(pub)
            parameters.append("%\(escaped)%")
            parameters.append("%\(escaped)%")
        }
        return ("(" + clauses.joined(separator: " OR ") + ")", parameters)
    }

    private func includeKeywordsCondition() -> (clauses: [String], parameters: [String]) {
        let clean = Self.cleanTerms(includeKeywords)
        guard !clean.isEmpty else { return ([], []) }
        var clauses: [String] = []
        var parameters: [String] = []
        if matchAllKeywords {
            for kw in clean {
                clauses.append("(a.title LIKE ? ESCAPE '\\' OR coalesce(a.description, '') LIKE ? ESCAPE '\\')")
                let escaped = Self.escapeLikeWildcards(kw)
                parameters.append("%\(escaped)%")
                parameters.append("%\(escaped)%")
            }
        } else {
            let incClauses = clean.map { _ in
                "(a.title LIKE ? ESCAPE '\\' OR coalesce(a.description, '') LIKE ? ESCAPE '\\')"
            }
            clauses.append("(" + incClauses.joined(separator: " OR ") + ")")
            for kw in clean {
                let escaped = Self.escapeLikeWildcards(kw)
                parameters.append("%\(escaped)%")
                parameters.append("%\(escaped)%")
            }
        }
        return (clauses, parameters)
    }

    private func excludeKeywordsCondition() -> (clauses: [String], parameters: [String]) {
        let clean = Self.cleanTerms(excludeKeywords)
        guard !clean.isEmpty else { return ([], []) }
        var clauses: [String] = []
        var parameters: [String] = []
        for kw in clean {
            clauses.append("NOT (a.title LIKE ? ESCAPE '\\' OR coalesce(a.description, '') LIKE ? ESCAPE '\\')")
            let escaped = Self.escapeLikeWildcards(kw)
            parameters.append("%\(escaped)%")
            parameters.append("%\(escaped)%")
        }
        return (clauses, parameters)
    }

    /// Translates compound rules into 100% parameterised SQL query filter conditions.
    /// Never interpolates user text directly into the SQL query string.
    public func sqlCondition() -> (sql: String, parameters: [String]) {
        var clauses: [String] = []
        var parameters: [String] = []

        let (catClause, catParams) = categoryCondition()
        if let catClause {
            clauses.append(catClause)
            parameters.append(contentsOf: catParams)
        }

        let (pubClause, pubParams) = publisherCondition()
        if let pubClause {
            clauses.append(pubClause)
            parameters.append(contentsOf: pubParams)
        }

        let (incClauses, incParams) = includeKeywordsCondition()
        clauses.append(contentsOf: incClauses)
        parameters.append(contentsOf: incParams)

        let (excClauses, excParams) = excludeKeywordsCondition()
        clauses.append(contentsOf: excClauses)
        parameters.append(contentsOf: excParams)

        guard !clauses.isEmpty else { return ("", []) }
        return (" AND " + clauses.joined(separator: " AND "), parameters)
    }

    // MARK: - In-Memory Article Matching

    private func matchesCategories(article: FeedArticle) -> Bool {
        let clean = Self.cleanTerms(categories)
        guard !clean.isEmpty else { return true }
        let cat = article.category?.lowercased() ?? ""
        return clean.contains { category in
            if category == "U.S. Politics" {
                return ArticleSection.matches(
                    category,
                    title: article.title,
                    description: article.description,
                    category: article.category
                )
            }
            return cat.contains(category.lowercased())
        }
    }

    private func matchesPublishers(article: FeedArticle) -> Bool {
        let clean = Self.cleanTerms(publishers)
        guard !clean.isEmpty else { return true }
        let source = article.source.lowercased()
        let pubName = article.publisherName.lowercased()
        let link = article.link.lowercased()
        return clean.contains {
            let p = $0.lowercased()
            return source.contains(p) || pubName.contains(p) || link.contains(p)
        }
    }

    private func matchesKeywords(in text: String) -> Bool {
        let cleanIncludes = Self.cleanTerms(includeKeywords)
        if !cleanIncludes.isEmpty {
            if matchAllKeywords {
                if !cleanIncludes.allSatisfy({ text.contains($0.lowercased()) }) { return false }
            } else {
                if !cleanIncludes.contains(where: { text.contains($0.lowercased()) }) { return false }
            }
        }

        let cleanExcludes = Self.cleanTerms(excludeKeywords)
        if !cleanExcludes.isEmpty {
            if cleanExcludes.contains(where: { text.contains($0.lowercased()) }) { return false }
        }

        return true
    }

    /// Pure in-memory rule evaluation matching FeedArticle instances against compound topic rules.
    func matches(article: FeedArticle) -> Bool {
        guard matchesCategories(article: article),
            matchesPublishers(article: article)
        else { return false }
        let text = "\(article.title) \(article.description)".lowercased()
        return matchesKeywords(in: text)
    }
}
