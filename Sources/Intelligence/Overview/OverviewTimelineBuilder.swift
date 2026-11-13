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

// Angelia · Clio (sourced overviews) owns this file. Register: docs/ANGELIA.md.

import Foundation

/// Builds an event overview's timeline (#143) from verified, passage-anchored facts, without a model.
///
/// An item is a source sentence that states exactly one explicit calendar date: a day and month, with
/// or without a year, or a month and year. A sentence without one may instead state one anchor (see `Anchor`):
/// a time of day, a relative anchor such as "yesterday morning", or a quarter with its year. Weekdays ("on
/// Monday") are not resolved, so those sentences stay out. The date shown is the one the source states, at the
/// precision it states: a missing year stays missing. Publication dates are never shown as event
/// dates; they only order a date whose year is missing and tell whether an item was still a plan
/// when it was reported. An anchor item also carries its article's publication date, which the reader shows
/// as "Reported", because the anchor's wording is relative to that day. Sentences from articles without a known
/// publication date are left out.
///
/// This builder is the only source of an overview's timeline (#1241). Items carry `dateKind == .stated` and no
/// `eventDate`: a resolved date may hold a placed year, so it goes only to `orderingDateMayHoldInferredYear`, which
/// orders and filters (Briefing) and is never displayed.
enum OverviewTimelineBuilder {
    struct Timeline: Sendable, Equatable {
        var items: [OverviewTimelineItem] = []
        var citations: [OverviewCitation] = []
    }

    /// A calendar date exactly as precise as the source states it.
    struct StatedDate: Hashable, Sendable {
        let year: Int?
        let month: Int
        let day: Int?
    }

    /// A single dated sentence is not a timeline.
    static let minimumDistinctDates = 2
    static let maximumItems = 8

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }()

    /// English month names, matched case-sensitively so that "may" or "march" as words never match.
    private static let englishMonths: [String: Int] = [
        "January": 1, "Jan": 1, "February": 2, "Feb": 2, "March": 3, "Mar": 3, "April": 4, "Apr": 4, "May": 5,
        "June": 6, "Jun": 6, "July": 7, "Jul": 7, "August": 8, "Aug": 8, "September": 9, "Sept": 9, "Sep": 9,
        "October": 10, "Oct": 10, "November": 11, "Nov": 11, "December": 12, "Dec": 12,
    ]
    /// Day-first month names of the other catalog languages, in the form and case that follow a day
    /// number: German (capitalized), Dutch, French, Italian, Polish and Ukrainian (genitive in the last
    /// two). Matched case-sensitively, so "3 Mars landers" is not 3 March.
    private static let dayFirstMonths: [String: Int] = [
        "Januar": 1, "Februar": 2, "März": 3, "April": 4, "Mai": 5, "Juni": 6,
        "Juli": 7, "August": 8, "September": 9, "Oktober": 10, "November": 11, "Dezember": 12,
        "januari": 1, "februari": 2, "maart": 3, "april": 4, "mei": 5, "juni": 6,
        "juli": 7, "augustus": 8, "september": 9, "oktober": 10, "november": 11, "december": 12,
        "janvier": 1, "février": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6,
        "juillet": 7, "août": 8, "septembre": 9, "octobre": 10, "novembre": 11, "décembre": 12,
        "gennaio": 1, "febbraio": 2, "marzo": 3, "aprile": 4, "maggio": 5, "giugno": 6,
        "luglio": 7, "agosto": 8, "settembre": 9, "ottobre": 10, "dicembre": 12,
        "stycznia": 1, "lutego": 2, "marca": 3, "kwietnia": 4, "maja": 5, "czerwca": 6,
        "lipca": 7, "sierpnia": 8, "września": 9, "października": 10, "listopada": 11, "grudnia": 12,
        "січня": 1, "лютого": 2, "березня": 3, "квітня": 4, "травня": 5, "червня": 6,
        "липня": 7, "серпня": 8, "вересня": 9, "жовтня": 10, "листопада": 11, "грудня": 12,
    ]

    /// In order of precedence; a later match that overlaps an earlier one is ignored.
    private static let patterns: [NSRegularExpression] = {
        let english = Self.alternation(Self.englishMonths.keys)
        let dayFirst = Self.alternation(Self.dayFirstMonths.keys)
        let year = #"(?<year>(?:19|20)\d{2})(?!\d)"#
        let sources: [(String, NSRegularExpression.Options)] = [
            (#"(?<![\d.])(?<year>(?:19|20)\d{2})-(?<month>\d{2})-(?<day>\d{2})(?!\d)"#, []),
            (
                #"(?<![\d.,])(?<day>\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(?<month>\#(english))(?!\p{L})\.?(?:,?\s+\#(year))?"#,
                []
            ),
            (
                #"(?<!\p{L})(?<month>\#(english))(?!\p{L})\.?\s+(?<day>\d{1,2})(?:st|nd|rd|th)?(?!\d)(?:,?\s+\#(year))?"#,
                []
            ),
            (#"(?<![\d.,])(?<day>\d{1,2})(?:\.|er)?\s+(?<month>\#(dayFirst))(?!\p{L})(?:\s+\#(year))?"#, []),
            (#"(?<!\p{L})(?<month>\#(english))(?!\p{L})\.?\s+\#(year)"#, []),
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0.0, options: $0.1) }
    }()

    private static func alternation(_ names: Dictionary<String, Int>.Keys) -> String {
        names.sorted { $0.count > $1.count }.joined(separator: "|")
    }

    static func build(
        facts: [PassageAnchoredFact],
        passages: [EvidencePassage],
        articles: [FeedArticle],
        locale: Locale = .current
    ) -> Timeline {
        struct Entry {
            let dateText: String
            let kind: OverviewTimelineItem.DateKind
            let resolved: Date
            /// A month comes before the days inside it, and a day before a time on it.
            let precision: Int
            let isPlan: Bool
            /// Only for anchors, whose wording is relative to the day the article was published.
            let publishedAt: Date?
            let quote: String
            let order: Int
            var facts: [PassageAnchoredFact]
        }
        let passagesByID = Dictionary(passages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let articlesByID = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var entries: [Entry] = []
        var entryByKey: [String: Int] = [:]
        for (order, fact) in facts.enumerated() {
            // The date and the text shown both come from the verbatim quote, never from a restatement.
            guard let article = articlesByID[fact.articleID], article.pubDate != DateParser.unknownDate else {
                continue
            }
            let entry: Entry
            if let stated = singleStatedDate(in: fact.quote),
                let resolved = resolve(stated, publishedAt: article.pubDate)
            {
                entry = Entry(
                    dateText: dateText(stated, locale: locale), kind: .stated, resolved: resolved,
                    precision: stated.day == nil ? 0 : 1,
                    isPlan: isPlan(stated, resolved: resolved, publishedAt: article.pubDate), publishedAt: nil,
                    quote: fact.quote, order: order, facts: [fact])
            } else if let anchor = anchor(in: fact.quote, publishedAt: article.pubDate) {
                entry = Entry(
                    dateText: anchor.text, kind: .anchor, resolved: anchor.resolved, precision: 2,
                    isPlan: anchor.isPlan, publishedAt: article.pubDate, quote: fact.quote, order: order,
                    facts: [fact])
            } else {
                continue
            }
            // Reprints of one sentence become one item with several sources. An anchor's placement is its article's
            // publication time, so its reprints are matched by wording instead.
            let when = entry.kind == .anchor ? entry.dateText.lowercased() : "\(entry.resolved.timeIntervalSince1970)"
            let key = "\(when)|\(entry.precision)|\(normalized(fact.quote))"
            if let index = entryByKey[key] {
                entries[index].facts.append(fact)
                continue
            }
            entryByKey[key] = entries.count
            entries.append(entry)
        }
        // An anchor counts by its wording: two times ("06:14 UTC", "09:30 UTC") are two, and the same words from two
        // publications ("this morning") are one, whatever the publication times.
        func establishesTimeline(_ selection: [Entry]) -> Bool {
            Set(
                selection.map {
                    $0.kind == .anchor
                        ? "anchor|\($0.dateText.lowercased())"
                        : "\($0.resolved.timeIntervalSince1970)|\($0.precision)"
                }
            ).count >= minimumDistinctDates
        }

        guard establishesTimeline(entries) else {
            return Timeline()
        }

        // Prefer corroborated items, then the order the facts arrived in; show them in time order.
        let prioritized = entries.sorted { ($0.facts.count, -$0.order) > ($1.facts.count, -$1.order) }
        var selected = Array(prioritized.prefix(maximumItems))
        if !establishesTimeline(selected),
            let replacement = prioritized.dropFirst(maximumItems).first(where: { candidate in
                var trial = selected
                trial[trial.count - 1] = candidate
                return establishesTimeline(trial)
            })
        {
            selected[selected.count - 1] = replacement
        }
        guard establishesTimeline(selected) else {
            return Timeline()
        }
        let kept = selected.sorted { ($0.resolved, $0.precision, $0.order) < ($1.resolved, $1.precision, $1.order) }

        var timeline = Timeline()
        for (index, entry) in kept.enumerated() {
            var citationIDs: [String] = []
            var citedPassages = Set<String>()
            for fact in entry.facts {
                guard citedPassages.insert(fact.passageID).inserted else { continue }
                let citationID = "cite_tl_\(timeline.citations.count + 1)_\(fact.passageID)"
                let source = articlesByID[fact.articleID].map {
                    OverviewSourceMetadata(title: $0.title, name: $0.source, url: $0.link, publishedAt: $0.pubDate)
                }
                timeline.citations.append(
                    OverviewCitation(
                        id: citationID,
                        articleID: fact.articleID,
                        passageID: fact.passageID,
                        passageFingerprint: passagesByID[fact.passageID]?.fingerprint
                            ?? ArticleIdentity.sha256Hex(fact.quote),
                        quote: fact.quote,
                        source: source
                    ))
                citationIDs.append(citationID)
            }
            let precision: OverviewTimelineItem.DatePrecision?
            if entry.kind != .stated {
                precision = nil
            } else {
                precision = entry.precision == 0 ? .month : .day
            }
            timeline.items.append(
                OverviewTimelineItem(
                    id: "timeline_\(index + 1)",
                    dateText: entry.dateText,
                    dateKind: entry.kind,
                    datePrecision: precision,
                    summary: entry.quote,
                    citationIDs: citationIDs,
                    isFuturePlan: entry.isPlan,
                    publicationDate: entry.publishedAt,
                    orderingDateMayHoldInferredYear: entry.resolved
                ))
        }
        return timeline
    }

    /// A time reference a source states that is not a calendar date (see `OverviewTimelineItem.anchorExpressions`).
    /// Shown in the source's words. `resolved` is a provisional placement for ordering only, never the time the
    /// event happened: a time of day or relative anchor is placed at the article's publication time (a day earlier
    /// for "yesterday" and "last night"). A bare "scheduled" is no anchor.
    struct Anchor: Equatable, Sendable {
        let text: String
        let resolved: Date
        let isPlan: Bool
    }

    // ponytail: "earlier this week" is placed one day before publication; its real day is unknown, so it only
    // orders after earlier stated dates and before same-day anchors.
    private static let relativeAnchors: [(phrase: String, days: Int)] = [
        ("earlier today", 0), ("this morning", 0), ("yesterday morning", -1), ("yesterday afternoon", -1),
        ("yesterday evening", -1), ("last night", -1), ("earlier this week", -1),
    ]
    /// The former extractor's plan indicators (#143), plus "planned for" and "will resume".
    private static let planPhrases = [
        "plans to", "planned to", "planned for", "planning to", "scheduled to", "scheduled for", "will launch",
        "will begin", "will open", "will resume", "aims to", "aiming to", "expected in", "expected to", "proposed",
        "target date", "slated to", "set to begin", "projected to",
    ]

    /// The one anchor a sentence states, when it states no calendar date at all; nil otherwise. A quarter without
    /// a year and a bare later year ("in 2027") count only in a sentence that states a plan, as before #1241.
    static func anchor(in sentence: String, publishedAt: Date) -> Anchor? {
        let range = NSRange(sentence.startIndex..., in: sentence)
        guard !patterns.contains(where: { $0.firstMatch(in: sentence, range: range) != nil }) else { return nil }
        let lower = sentence.lowercased()
        let saysPlan = planPhrases.contains { lower.contains($0) }
        var matches = OverviewTimelineItem.anchorExpressions.flatMap { $0.matches(in: sentence, range: range) }
        if matches.isEmpty, saysPlan {
            matches = OverviewTimelineItem.planYearExpression.matches(in: sentence, range: range)
        }
        guard matches.count == 1, let match = matches.first, let found = Range(match.range, in: sentence) else {
            return nil
        }
        func group(_ name: String) -> String? {
            Range(match.range(withName: name), in: sentence).map { String(sentence[$0]) }
        }
        let wording = String(sentence[found])
        let text = wording.prefix(1).uppercased() + wording.dropFirst()
        let published = calendar.component(.year, from: publishedAt)
        func starting(_ year: Int, month: Int) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: 1))
        }
        if let year = group("year").flatMap({ Int($0) }) {
            guard year > published, let start = starting(year, month: 1) else { return nil }
            return Anchor(text: text, resolved: start, isPlan: true)
        }
        let quarter =
            group("q").flatMap { Int($0) }
            ?? group("ordinal").flatMap {
                ["first", "second", "third", "fourth"].firstIndex(of: $0.lowercased()).map { $0 + 1 }
            }
        if let quarter {
            if let year = (group("qyear") ?? group("oyear")).flatMap({ Int($0) }) {
                guard let start = starting(year, month: quarter * 3 - 2) else { return nil }
                return Anchor(text: text, resolved: start, isPlan: start > publishedAt)
            }
            // A quarter without a year is a plan's next such quarter; the year only orders it and is never shown.
            guard saysPlan, let thisYear = starting(published, month: quarter * 3 - 2),
                let start = thisYear > publishedAt ? thisYear : starting(published + 1, month: quarter * 3 - 2)
            else { return nil }
            return Anchor(text: text, resolved: start, isPlan: true)
        }
        let days = relativeAnchors.first { wording.lowercased() == $0.phrase }?.days ?? 0
        guard let resolved = calendar.date(byAdding: .day, value: days, to: publishedAt) else { return nil }
        return Anchor(text: text, resolved: resolved, isPlan: saysPlan)
    }

    /// The one explicit date a sentence states; nil when it states none, several, or an impossible one.
    static func singleStatedDate(in sentence: String) -> StatedDate? {
        let range = NSRange(sentence.startIndex..., in: sentence)
        var taken: [NSRange] = []
        var dates = Set<StatedDate>()
        for regex in patterns {
            for match in regex.matches(in: sentence, range: range)
            where !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                taken.append(match.range)
                guard let date = statedDate(from: match, in: sentence) else { return nil }
                dates.insert(date)
            }
        }
        return dates.count == 1 ? dates.first : nil
    }

    private static func statedDate(from match: NSTextCheckingResult, in sentence: String) -> StatedDate? {
        func group(_ name: String) -> String? {
            Range(match.range(withName: name), in: sentence).map { String(sentence[$0]) }
        }
        guard let monthText = group("month"),
            let month = englishMonths[monthText] ?? dayFirstMonths[monthText] ?? Int(monthText),
            (1...12).contains(month)
        else { return nil }
        let year = group("year").flatMap { Int($0) }
        let day = group("day").flatMap { Int($0) }
        if let day {
            // A leap year stands in for a missing year, so 29 February is possible until it is placed.
            let components = DateComponents(year: year ?? 2000, month: month, day: day)
            guard let date = calendar.date(from: components), calendar.component(.day, from: date) == day else {
                return nil
            }
        }
        return StatedDate(year: year, month: month, day: day)
    }

    /// Places a stated date in time. A missing year is taken as the one that puts the date nearest to
    /// the reporting article's publication; that only orders the item and is never displayed.
    static func resolve(_ date: StatedDate, publishedAt: Date) -> Date? {
        func place(_ year: Int) -> Date? {
            let components = DateComponents(year: year, month: date.month, day: date.day ?? 1)
            guard let placed = calendar.date(from: components),
                calendar.component(.day, from: placed) == (date.day ?? 1)
            else { return nil }
            return placed
        }
        if let year = date.year { return place(year) }
        let published = calendar.component(.year, from: publishedAt)
        return [published - 1, published, published + 1]
            .compactMap(place)
            .min { abs($0.timeIntervalSince(publishedAt)) < abs($1.timeIntervalSince(publishedAt)) }
    }

    /// A date after the day (or, for a month, after the month) the article was published had not
    /// happened yet when it was reported.
    static func isPlan(_ date: StatedDate, resolved: Date, publishedAt: Date) -> Bool {
        let unit: Calendar.Component = date.day == nil ? .month : .day
        guard let reported = calendar.dateInterval(of: unit, for: publishedAt) else { return false }
        return resolved >= reported.end
    }

    static func dateText(_ date: StatedDate, locale: Locale) -> String {
        let template: String
        switch (date.day != nil, date.year != nil) {
        case (true, true): template = "dMMMy"
        case (true, false): template = "dMMM"
        default: template = "MMMy"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        let components = DateComponents(year: date.year ?? 2000, month: date.month, day: date.day ?? 1)
        return calendar.date(from: components).map { formatter.string(from: $0) } ?? ""
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .split(separator: " ").map { String($0) }.joined(separator: " ")
    }
}
