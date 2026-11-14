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

// Angelia · Iris (acquisition) owns this file. Experimental, no production consumer. Register: docs/ANGELIA.md.

import Foundation

/// One stored article as the identity mapping reads it. `fetchedAt` is when News first stored it.
struct WireIdentityArticle: Sendable {
    /// The stored article's id.
    let articleID: String
    /// The outlet name; empty counts as no publisher.
    let publisher: String
    let title: String
    let description: String
    /// The extracted full text, when stored.
    let content: String?
    let publishedAt: Date
    let fetchedAt: Date
    /// The feed's author field, when the article was stored with one.
    var author: String? = nil
}

/// Who an article's report comes from, or an explicit nil where the stored text cannot say.
struct WireIdentity: Sendable, Equatable {
    /// The evidence an identity rests on.
    enum Basis: String, Sendable, CaseIterable {
        /// The feed's author field or a byline-position credit names one agency, here or in a near-identical copy.
        case credited
        /// Credits name several agencies: the wire group is known, the one origin is not.
        case multipleCredits
        /// Near-identical title or text inside the event, with no credit.
        case copies
        /// Full text, no near-identical sibling, no agency named anywhere. Assumed the publisher's own report.
        case fullText
        /// Full text that names an agency outside a credit ("told AFP", a photo credit): reprint or citation is open.
        case agencyMention
        /// Too little text to compare or to read a credit in, or no publisher.
        case insufficient
    }

    let articleID: String
    /// The report the article belongs to: `wire:` plus the credited agencies, `copy:` or `report:` plus the group's
    /// lowest article id; nil when the text cannot say.
    let wireGroupID: String?
    /// Who originated the report: `agency:`, `publisher:` or `unattributed:`; nil when unknown or several agencies
    /// share credit.
    let originPublisherID: String?
    let basis: Basis
}

/// Derives the wire group and originating publisher `EditorialMomentum` needs from what the library stores, for the
/// members of one event. Experimental: nothing in the app reads it yet (#998).
///
/// Deliberately stricter than `OverviewPerspectivesExtractor.detectWireSource`: that substring match suits collapsing
/// attributed voices, but on the library nearly every agency name in text is a quotation or a photo credit.
enum EditorialWireIdentity {
    /// Agencies by stable id and the exact names a credit uses, longest first so "Associated Press" beats "AP".
    private static let agencies: [(id: String, names: [String])] = [
        ("reuters", ["Reuters"]),
        ("associated-press", ["The Associated Press", "Associated Press", "AP News", "AP"]),
        ("afp", ["Agence France-Presse", "AFP"]),
        ("bloomberg", ["Bloomberg News", "Bloomberg"]),
        ("upi", ["United Press International", "UPI"]),
        ("pr-newswire", ["PR Newswire"]),
        ("business-wire", ["Business Wire"]),
    ]
    private static let agencyByName: [String: String] = {
        var names: [String: String] = [:]
        for agency in agencies {
            for name in agency.names { names[name] = agency.id }
        }
        return names
    }()
    private static let namePattern = agencies.flatMap(\.names).sorted { $0.count > $1.count }
        .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    private static let mention = regex("\\b(\(namePattern))\\b")
    /// Byline positions only, each capturing the text that holds the agency names; matching is case-sensitive.
    private static let creditShapes: [NSRegularExpression] = [
        regex("^[^()\\n]{0,40}\\((\(namePattern))\\)\\s*[-–—:]"),  // PARIS (AFP) —
        regex("^\\s*By\\s+((?:the\\s+)?(?:\(namePattern)))\\b"),  // By Reuters
        regex("[—–-]\\s*(\(namePattern))\\.?\\s*$"),  // … — AFP
        regex("\\((\(namePattern))\\)\\.?\\s*$"),  // … (AP)
        regex("\\(([^()\\n]{0,40}\\bwith\\s[^()\\n]{1,60})\\)\\.?\\s*$"),  // (FRANCE 24 with Reuters and AFP)
        regex("(\(namePattern))\\s+contributed\\b[^\\n]{0,40}$"),  // Reuters contributed to this report.
    ]

    /// Fewer words than this and a missing credit says nothing: bylines rarely reach a feed blurb.
    private static let fullTextWords = 100
    private static let shingleWords = 8
    private static let minimumSharedShingles = 10
    /// Ceiling on the words read per article, so a hostile feed cannot make comparison expensive.
    private static let maximumWords = 2_000
    private static let titleSimilarity = 0.9
    private static let minimumTitleWords = 5

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) } catch {
            preconditionFailure("Invalid wire credit pattern: \(error)")
        }
    }

    private struct Evidence {
        let publisher: String
        let titleWords: [String]
        let shingles: Set<String>
        let credits: Set<String>
        let mentionsAgency: Bool
        let hasFullText: Bool

        init(_ article: WireIdentityArticle) {
            publisher = EditorialWireIdentity.slug(article.publisher)
            titleWords = EditorialWireIdentity.words(article.title)
            let description = EditorialWireIdentity.withoutFormatMarks(article.description)
            let content = EditorialWireIdentity.withoutFormatMarks(article.content ?? "")
            let longest = EditorialWireIdentity.words(content.count >= description.count ? content : description)
            hasFullText = longest.count >= EditorialWireIdentity.fullTextWords
            shingles = EditorialWireIdentity.shingles(longest)
            credits = EditorialWireIdentity.credits(
                publisher: article.publisher, author: article.author, description: description, content: content)
            mentionsAgency = !EditorialWireIdentity.agencyIDs(
                in: [article.title, description, content].joined(separator: "\n")
            ).isEmpty
        }
    }

    /// The agencies a feed author field names, as stable ids. The field is a byline, so any exact name there counts.
    static func bylineAgencies(_ author: String) -> Set<String> { agencyIDs(in: withoutFormatMarks(author)) }

    /// One identity per distinct article, sorted by article id; the result does not depend on input order. A group's
    /// ids derive from its lowest article id, and each group has one origin, so `EditorialMomentum` never sees
    /// conflicting origins. `textContainment` is the shared-passage share of the shorter text that makes two copies.
    /// An article repeated in `members` is read from its first dated copy, the one `momentumReports` reports.
    static func identities(event members: [WireIdentityArticle], textContainment: Double = 0.8) -> [WireIdentity] {
        var seen = Set<String>()
        let datedFirst =
            members.filter { $0.publishedAt != DateParser.unknownDate }
            + members.filter { $0.publishedAt == DateParser.unknownDate }
        let articles = datedFirst.filter { seen.insert($0.articleID).inserted }.sorted { $0.articleID < $1.articleID }
        let evidence = articles.map(Evidence.init)
        var parent = Array(articles.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        for second in articles.indices {
            for first in articles.indices.prefix(second)
            where nearIdentical(evidence[first], evidence[second], textContainment: textContainment) {
                let (a, b) = (root(first), root(second))
                parent[max(a, b)] = min(a, b)
            }
        }
        let groups = Dictionary(grouping: articles.indices, by: root)
        return articles.indices.map { index in
            let group = groups[root(index)] ?? [index]
            let found = attribution(of: group.map { evidence[$0] }, lowestID: articles[group[0]].articleID)
            return WireIdentity(
                articleID: articles[index].articleID, wireGroupID: found.wire, originPublisherID: found.origin,
                basis: found.basis)
        }
    }

    /// Replay rows for one event. An undated article has no publication time to bucket and is left out. An article
    /// stamped after News stored it (a revision date or a wrong clock) was published by the time it was stored at the
    /// latest, so its publication is clamped there rather than failing the event's replay. An article repeated in `members` keeps
    /// its first dated row.
    static func momentumReports(eventID: String, members: [WireIdentityArticle]) -> [MomentumReport] {
        let identified = Dictionary(uniqueKeysWithValues: identities(event: members).map { ($0.articleID, $0) })
        var seen = Set<String>()
        return members.compactMap { article in
            guard article.publishedAt != DateParser.unknownDate, seen.insert(article.articleID).inserted else {
                return nil
            }
            return MomentumReport(
                articleID: article.articleID, eventID: eventID, wireGroupID: identified[article.articleID]?.wireGroupID,
                localPublisherID: slug(article.publisher),
                originPublisherID: identified[article.articleID]?.originPublisherID,
                publishedAt: min(article.publishedAt, article.fetchedAt), fetchedAt: article.fetchedAt)
        }
    }

    private static func nearIdentical(_ a: Evidence, _ b: Evidence, textContainment: Double) -> Bool {
        let shared = a.shingles.intersection(b.shingles).count
        if shared >= minimumSharedShingles,
            Double(shared) / Double(min(a.shingles.count, b.shingles.count)) >= textContainment
        {
            return true
        }
        guard min(a.titleWords.count, b.titleWords.count) >= minimumTitleWords else { return false }
        let (left, right) = (Set(a.titleWords), Set(b.titleWords))
        return Double(left.intersection(right).count) / Double(left.union(right).count) >= titleSimilarity
    }

    private struct Attribution {
        var wire: String?
        var origin: String?
        var basis: WireIdentity.Basis
    }

    private static func attribution(of group: [Evidence], lowestID: String) -> Attribution {
        let credits = group.reduce(into: Set<String>()) { $0.formUnion($1.credits) }.sorted()
        if credits.count == 1 {
            return Attribution(wire: "wire:\(credits[0])", origin: "agency:\(credits[0])", basis: .credited)
        }
        if credits.count > 1 {
            return Attribution(wire: "wire:" + credits.joined(separator: "+"), origin: nil, basis: .multipleCredits)
        }
        guard group.count == 1 else {
            let outlet = Set(group.map(\.publisher))
            // Several outlets share an unnamed source: one report and one origin, which no outlet can claim. One
            // outlet repeating its own full text is that outlet's report.
            let own = outlet.count == 1 && !group[0].publisher.isEmpty && group.contains(where: \.hasFullText)
            return Attribution(
                wire: "copy:\(lowestID)", origin: own ? "publisher:\(group[0].publisher)" : "unattributed:\(lowestID)",
                basis: .copies)
        }
        let article = group[0]
        guard article.hasFullText, !article.publisher.isEmpty else {
            return Attribution(wire: nil, origin: nil, basis: .insufficient)
        }
        if article.mentionsAgency { return Attribution(wire: nil, origin: nil, basis: .agencyMention) }
        return Attribution(wire: "report:\(lowestID)", origin: "publisher:\(article.publisher)", basis: .fullText)
    }

    private static func credits(
        publisher: String, author: String?, description: String, content: String
    ) -> Set<String> {
        var found = Set<String>()
        for (name, id) in agencyByName where name.caseInsensitiveCompare(publisher) == .orderedSame { found.insert(id) }
        found.formUnion(bylineAgencies(author ?? ""))
        for text in [description, content] {
            let range = NSRange(text.startIndex..., in: text)
            for shape in creditShapes {
                guard let match = shape.firstMatch(in: text, range: range),
                    let capture = Range(match.range(at: 1), in: text)
                else { continue }
                found.formUnion(agencyIDs(in: String(text[capture])))
            }
        }
        return found
    }

    private static func agencyIDs(in text: String) -> Set<String> {
        let matches = mention.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return Set(matches.compactMap { Range($0.range(at: 1), in: text).flatMap { agencyByName[String(text[$0])] } })
    }

    /// Feeds carry zero-width marks inside words, which would hide a verbatim copy from comparison and a credit.
    private static func withoutFormatMarks(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
    }

    private static func words(_ text: String) -> [String] {
        Array(
            withoutFormatMarks(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).lazy
                .filter { !$0.isEmpty }.prefix(maximumWords))
    }

    private static func shingles(_ words: [String]) -> Set<String> {
        guard words.count >= shingleWords else { return [] }
        return Set((0...(words.count - shingleWords)).map { words[$0..<($0 + shingleWords)].joined(separator: " ") })
    }

    private static func slug(_ publisher: String) -> String { words(publisher).joined(separator: "-") }
}
