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
        createdAt: Date = Date(),
        matchAllKeywords: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.categories = categories
        self.includeKeywords = includeKeywords
        self.excludeKeywords = excludeKeywords
        self.publishers = publishers
        self.createdAt = createdAt
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

    // MARK: - Parameterized SQL Translation

    /// Translates compound rules into 100% parameterised SQL query filter conditions.
    /// Never interpolates user text directly into the SQL query string.
    public func sqlCondition() -> (sql: String, parameters: [String]) {
        var clauses: [String] = []
        var parameters: [String] = []

        let cleanCategories =
            categories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanCategories.isEmpty {
            let catClauses = cleanCategories.map { _ in "coalesce(ae.category, a.category) LIKE ?" }
            clauses.append("(" + catClauses.joined(separator: " OR ") + ")")
            parameters.append(contentsOf: cleanCategories.map { "%\($0)%" })
        }

        let cleanPublishers =
            publishers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanPublishers.isEmpty {
            let pubClauses = cleanPublishers.map { _ in "(a.source LIKE ? OR a.canonical_url LIKE ?)" }
            clauses.append("(" + pubClauses.joined(separator: " OR ") + ")")
            for pub in cleanPublishers {
                parameters.append("%\(pub)%")
                parameters.append("%\(pub)%")
            }
        }

        let cleanIncludes =
            includeKeywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanIncludes.isEmpty {
            if matchAllKeywords {
                for kw in cleanIncludes {
                    clauses.append("(a.title LIKE ? OR coalesce(a.description, '') LIKE ?)")
                    parameters.append("%\(kw)%")
                    parameters.append("%\(kw)%")
                }
            } else {
                let incClauses = cleanIncludes.map { _ in "(a.title LIKE ? OR coalesce(a.description, '') LIKE ?)" }
                clauses.append("(" + incClauses.joined(separator: " OR ") + ")")
                for kw in cleanIncludes {
                    parameters.append("%\(kw)%")
                    parameters.append("%\(kw)%")
                }
            }
        }

        let cleanExcludes =
            excludeKeywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanExcludes.isEmpty {
            for kw in cleanExcludes {
                clauses.append("NOT (a.title LIKE ? OR coalesce(a.description, '') LIKE ?)")
                parameters.append("%\(kw)%")
                parameters.append("%\(kw)%")
            }
        }

        guard !clauses.isEmpty else { return ("", []) }
        return (" AND " + clauses.joined(separator: " AND "), parameters)
    }

    // MARK: - In-Memory Article Matching

    /// Pure in-memory rule evaluation matching FeedArticle instances against compound topic rules.
    func matches(article: FeedArticle) -> Bool {
        let cleanCategories =
            categories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanCategories.isEmpty {
            let cat = article.category?.lowercased() ?? ""
            let matchesCat = cleanCategories.contains { cat.contains($0.lowercased()) }
            if !matchesCat { return false }
        }

        let cleanPublishers =
            publishers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanPublishers.isEmpty {
            let source = article.source.lowercased()
            let pubName = article.publisherName.lowercased()
            let link = article.link.lowercased()
            let matchesPub = cleanPublishers.contains {
                let p = $0.lowercased()
                return source.contains(p) || pubName.contains(p) || link.contains(p)
            }
            if !matchesPub { return false }
        }

        let text = "\(article.title) \(article.description)".lowercased()

        let cleanIncludes =
            includeKeywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanIncludes.isEmpty {
            if matchAllKeywords {
                for kw in cleanIncludes {
                    if !text.contains(kw.lowercased()) { return false }
                }
            } else {
                let matchesInc = cleanIncludes.contains { text.contains($0.lowercased()) }
                if !matchesInc { return false }
            }
        }

        let cleanExcludes =
            excludeKeywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanExcludes.isEmpty {
            for kw in cleanExcludes {
                if text.contains(kw.lowercased()) { return false }
            }
        }

        return true
    }
}
