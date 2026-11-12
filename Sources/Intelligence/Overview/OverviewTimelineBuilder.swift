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
/// or without a year, or a month and year. A range ("from 19 to 28 November") or a list ("on 3 and 5 November") that a
/// sentence states in one coordinated phrase is also one item, spanning its earliest to its latest date (#1249). A
/// sentence without one may instead state one anchor (see `Anchor`):
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

    /// A range or list of dates the source states in one coordinated phrase (#1249): one row and one span, however
    /// many dates it holds.
    struct StatedSpan: Hashable, Sendable {
        /// In the order the source gives them; a range holds its start and its end.
        let dates: [StatedDate]
        let isRange: Bool
    }

    enum StatedExpression: Hashable, Sendable {
        case date(StatedDate)
        case span(StatedSpan)
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
            /// The last ordering date of a range or list; nil for a single date.
            let end: Date?
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
            let expression = statedExpression(in: fact.quote)
            if case .span(let span)? = expression {
                guard let placed = placedDates(of: span, publishedAt: article.pubDate),
                    let first = placed.min(by: { $0.at < $1.at }), let last = placed.max(by: { $0.at < $1.at })
                else { continue }
                entry = Entry(
                    dateText: spanText(span, locale: locale), kind: .stated, resolved: first.at, end: last.at,
                    precision: first.date.day == nil ? 0 : 1,
                    isPlan: isPlan(first.date, resolved: first.at, publishedAt: article.pubDate), publishedAt: nil,
                    quote: fact.quote, order: order, facts: [fact])
            } else if case .date(let stated)? = expression,
                let resolved = resolve(stated, publishedAt: article.pubDate)
            {
                entry = Entry(
                    dateText: dateText(stated, locale: locale), kind: .stated, resolved: resolved, end: nil,
                    precision: stated.day == nil ? 0 : 1,
                    isPlan: isPlan(stated, resolved: resolved, publishedAt: article.pubDate), publishedAt: nil,
                    quote: fact.quote, order: order, facts: [fact])
            } else if let anchor = anchor(in: fact.quote, publishedAt: article.pubDate) {
                entry = Entry(
                    dateText: anchor.text, kind: .anchor, resolved: anchor.resolved, end: nil, precision: 2,
                    isPlan: anchor.isPlan, publishedAt: article.pubDate, quote: fact.quote, order: order,
                    facts: [fact])
            } else {
                continue
            }
            // Reprints of one sentence become one item with several sources. An anchor's placement is its article's
            // publication time, so its reprints are matched by wording instead.
            let when =
                entry.kind == .anchor
                ? entry.dateText.lowercased()
                : "\(entry.resolved.timeIntervalSince1970)-\(entry.end?.timeIntervalSince1970 ?? 0)"
            let key = "\(when)|\(entry.precision)|\(normalized(fact.quote))"
            if let index = entryByKey[key] {
                entries[index].facts.append(fact)
                continue
            }
            entryByKey[key] = entries.count
            entries.append(entry)
        }
        // An anchor counts by its wording: two times ("06:14 UTC", "09:30 UTC") are two, and the same words from two
        // publications ("this morning") are one, whatever the publication times. A range or list is one unit with a
        // span: it is distinct from another date only when the spans do not overlap, as in Briefing, so a range alone
        // or a range with a date inside it is no timeline (#1249).
        let distinct = Set(
            entries.filter { $0.end == nil }.map {
                $0.kind == .anchor
                    ? "anchor|\($0.dateText.lowercased())" : "\($0.resolved.timeIntervalSince1970)|\($0.precision)"
            })
        func span(_ entry: Entry) -> DateInterval? {
            let unit: Calendar.Component = entry.precision == 0 ? .month : .day
            guard let start = calendar.dateInterval(of: unit, for: entry.resolved),
                let end = calendar.dateInterval(of: unit, for: entry.end ?? entry.resolved)
            else { return nil }
            return DateInterval(start: start.start, end: end.end)
        }
        let establishesTimeline =
            distinct.count >= minimumDistinctDates
            || entries.contains { first in
                first.end != nil
                    && entries.contains { other in
                        guard let a = span(first), let b = span(other) else { return false }
                        return a.end <= b.start || b.end <= a.start
                    }
            }

        guard establishesTimeline
        else {
            return Timeline()
        }

        // Prefer corroborated items, then the order the facts arrived in; show them in time order.
        let kept =
            entries
            .sorted { ($0.facts.count, -$0.order) > ($1.facts.count, -$1.order) }
            .prefix(maximumItems)
            .sorted {
                ($0.resolved, $0.end == nil ? 0 : 1, $0.precision, $0.order)
                    < ($1.resolved, $1.end == nil ? 0 : 1, $1.precision, $1.order)
            }

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
            timeline.items.append(
                OverviewTimelineItem(
                    id: "timeline_\(index + 1)",
                    dateText: entry.dateText,
                    dateKind: entry.kind,
                    datePrecision: entry.kind == .stated
                        ? (entry.end != nil ? .range : entry.precision == 0 ? .month : .day) : nil,
                    summary: entry.quote,
                    citationIDs: citationIDs,
                    isFuturePlan: entry.isPlan,
                    publicationDate: entry.publishedAt,
                    orderingDateMayHoldInferredYear: entry.resolved,
                    orderingEndDateMayHoldInferredYear: entry.end
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
        let wording = group("year") ?? String(sentence[found])
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

    /// The one explicit date a sentence states; nil when it states none, several, a range or a list, or an
    /// impossible one.
    static func singleStatedDate(in sentence: String) -> StatedDate? {
        if case .date(let date)? = statedExpression(in: sentence) { return date }
        return nil
    }

    private static let dayNumber = #"\d{1,2}(?:st|nd|rd|th)?(?!\d)"#
    private static let rangeJoin = #"(?:\s*[–—-]\s*|\s+(?:to|through|until)\s+)"#

    /// A day range or list that shares its month ("19–28 November", "from 19 to 28 November", "3, 5 and 7 November",
    /// "November 19–28"). The month-first form takes "and" only after "between", where "November 3 and 5 people" is
    /// no list. Matched before the single-date patterns, which would read the last day alone.
    private static let sharedMonthPatterns: [(regex: NSRegularExpression, monthFirst: Bool)] = {
        let month = Self.alternation(Self.englishMonths.keys)
        let year = #"(?<year>(?:19|20)\d{2})(?!\d)"#
        let day = Self.dayNumber
        let sources: [(String, Bool)] = [
            (
                #"(?<![\d.,])(?<days>\#(day)\#(rangeJoin)\#(day)|\#(day)(?:,\s+\#(day))*,?\s+and\s+\#(day))\s+(?:of\s+)?(?<month>\#(month))(?!\p{L})\.?(?:,?\s+\#(year))?"#,
                false
            ),
            (
                #"(?<!\p{L})(?<month>\#(month))(?!\p{L})\.?\s+(?<days>\#(day)(?:\#(rangeJoin)|\s+and\s+)\#(day))(?:,?\s+\#(year))?"#,
                true
            ),
        ]
        return sources.compactMap { source in
            (try? NSRegularExpression(pattern: source.0)).map { ($0, source.1) }
        }
    }()

    private static let bareMonthRange: NSRegularExpression = {
        let month = Self.alternation(Self.englishMonths.keys)
        let pattern =
            #"\b(?:from|between)\s+(?:\#(month))(?!\p{L})\.?\s*(?:[–—-]|to|through|until)\s*(?:\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:\#(month))|(?:\#(month))\s+\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("The bare month range pattern is valid")
        }
        return regex
    }()

    private static let rangeBetweenDates =
        #"^(?:[–—-]|to|through|until|and\s+(?:runs?|running|continues?|extends?|lasts?)\s+(?:through|until|to))$"#
    private static let listBetweenDates = #"^(?:,|and|,\s*and)$"#

    /// What a sentence states as dates: one date, one range or list in a single coordinated phrase, or nil when it
    /// states none, several unrelated dates (separate clauses, a range or list plus another date), a reversed
    /// range, an expression whose parts cannot share a precision or year, or an impossible date.
    static func statedExpression(in sentence: String) -> StatedExpression? {
        struct Atom {
            let range: NSRange
            let date: StatedDate?
            let span: StatedSpan?
        }
        let range = NSRange(sentence.startIndex..., in: sentence)
        // "March to 5 April": a bare month and a day share no precision.
        guard bareMonthRange.firstMatch(in: sentence, range: range) == nil else { return nil }
        var atoms: [Atom] = []
        func isTaken(_ candidate: NSRange) -> Bool {
            atoms.contains { NSIntersectionRange($0.range, candidate).length > 0 }
        }
        func precededByBetween(_ range: NSRange) -> Bool {
            guard let found = Range(range, in: sentence) else { return false }
            return sentence[..<found.lowerBound].trimmingCharacters(in: .whitespaces).lowercased().hasSuffix("between")
        }
        for (regex, monthFirst) in sharedMonthPatterns {
            for match in regex.matches(in: sentence, range: range) where !isTaken(match.range) {
                func group(_ name: String) -> String? {
                    Range(match.range(withName: name), in: sentence).map { String(sentence[$0]) }
                }
                guard let monthText = group("month"), let month = englishMonths[monthText], let text = group("days")
                else { return nil }
                let isList = text.contains("and")
                let isRange = !isList || precededByBetween(match.range)
                if monthFirst, isList, !isRange { continue }
                let year = group("year").flatMap { Int($0) }
                let days = text.split { !$0.isNumber }.compactMap { Int($0) }
                var dates: [StatedDate] = []
                for day in days {
                    let date = StatedDate(year: year, month: month, day: day)
                    guard isPossible(date) else { return nil }
                    if !dates.contains(date) { dates.append(date) }
                }
                guard dates.count >= 2, !isRange || (dates.count == 2 && days[0] < days[1]) else { return nil }
                atoms.append(Atom(range: match.range, date: nil, span: StatedSpan(dates: dates, isRange: isRange)))
            }
        }
        for regex in patterns {
            for match in regex.matches(in: sentence, range: range) where !isTaken(match.range) {
                guard let date = statedDate(from: match, in: sentence) else { return nil }
                atoms.append(Atom(range: match.range, date: date, span: nil))
            }
        }
        atoms.sort { $0.range.location < $1.range.location }
        guard let first = atoms.first else { return nil }
        if atoms.count == 1 { return first.span.map { .span($0) } ?? first.date.map { .date($0) } }
        let dates = atoms.compactMap(\.date)
        // A range or list plus another date, or two unrelated dates, is no single expression.
        guard dates.count == atoms.count else { return nil }
        if Set(dates).count == 1 { return .date(dates[0]) }
        guard Set(dates.map { $0.day == nil }).count == 1 else { return nil }
        let joins = zip(atoms, atoms.dropFirst()).compactMap { pair -> String? in
            guard
                let gap = Range(
                    NSRange(
                        location: NSMaxRange(pair.0.range), length: pair.1.range.location - NSMaxRange(pair.0.range)),
                    in: sentence)
            else { return nil }
            return sentence[gap].trimmingCharacters(in: .whitespaces)
        }
        func all(_ pattern: String) -> Bool {
            joins.allSatisfy { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        let between = precededByBetween(first.range)
        if dates.count == 2, all(rangeBetweenDates) || (between && all(listBetweenDates)) {
            return .span(StatedSpan(dates: dates, isRange: true))
        }
        // A list repeats no date, and its dates either all state a year or none does.
        if all(listBetweenDates), Set(dates).count == dates.count, Set(dates.map { $0.year == nil }).count == 1 {
            return .span(StatedSpan(dates: dates, isRange: false))
        }
        return nil
    }

    private static func isPossible(_ date: StatedDate) -> Bool {
        let components = DateComponents(year: date.year ?? 2000, month: date.month, day: date.day)
        guard let day = date.day, let made = calendar.date(from: components) else { return false }
        return calendar.component(.day, from: made) == day
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

    private static func place(_ date: StatedDate, year: Int) -> Date? {
        let components = DateComponents(year: year, month: date.month, day: date.day ?? 1)
        guard let placed = calendar.date(from: components), calendar.component(.day, from: placed) == (date.day ?? 1)
        else { return nil }
        return placed
    }

    /// Places a stated date in time. A missing year is taken as the one that puts the date nearest to
    /// the reporting article's publication; that only orders the item and is never displayed.
    static func resolve(_ date: StatedDate, publishedAt: Date) -> Date? {
        if let year = date.year { return place(date, year: year) }
        let published = calendar.component(.year, from: publishedAt)
        return [published - 1, published, published + 1]
            .compactMap { place(date, year: $0) }
            .min { abs($0.timeIntervalSince(publishedAt)) < abs($1.timeIntervalSince(publishedAt)) }
    }

    /// Whether a range ends earlier in the calendar year than it starts ("28 December to 3 January").
    private static func wrapsYear(_ start: StatedDate, _ end: StatedDate) -> Bool {
        (start.month, start.day ?? 1) > (end.month, end.day ?? 1)
    }

    /// Where each date of a range or list falls in time, for ordering only. A range's end month before its start
    /// month moves into the next year; a reversed range, or one whose ends cannot share a precision, is nil.
    /// A year the source leaves out is inferred: from the range's other end, or else the one nearest publication.
    static func placedDates(of span: StatedSpan, publishedAt: Date) -> [(date: StatedDate, at: Date)]? {
        guard span.isRange else {
            let placed = span.dates.compactMap { date in resolve(date, publishedAt: publishedAt).map { (date, $0) } }
            return placed.count == span.dates.count ? placed.map { (date: $0.0, at: $0.1) } : nil
        }
        guard span.dates.count == 2 else { return nil }
        let (start, end) = (span.dates[0], span.dates[1])
        guard (start.day == nil) == (end.day == nil) else { return nil }
        let startYear: Int
        let endYear: Int
        if let known = start.year, let other = end.year {
            (startYear, endYear) = (known, other)
        } else {
            let wraps = wrapsYear(start, end)
            guard (start.month, start.day) != (end.month, end.day), !(wraps && start.month == end.month) else {
                return nil
            }
            if let known = start.year {
                (startYear, endYear) = (known, wraps ? known + 1 : known)
            } else if let known = end.year {
                (startYear, endYear) = (wraps ? known - 1 : known, known)
            } else {
                guard let nearest = resolve(start, publishedAt: publishedAt) else { return nil }
                startYear = calendar.component(.year, from: nearest)
                endYear = wraps ? startYear + 1 : startYear
            }
        }
        guard let from = place(start, year: startYear), let to = place(end, year: endYear), from < to else {
            return nil
        }
        return [(start, from), (end, to)]
    }

    /// A date after the day (or, for a month, after the month) the article was published had not
    /// happened yet when it was reported.
    static func isPlan(_ date: StatedDate, resolved: Date, publishedAt: Date) -> Bool {
        let unit: Calendar.Component = date.day == nil ? .month : .day
        guard let reported = calendar.dateInterval(of: unit, for: publishedAt) else { return false }
        return resolved >= reported.end
    }

    static func dateText(_ date: StatedDate, locale: Locale, monthOnly: Bool = false) -> String {
        let template: String
        switch (date.day != nil && !monthOnly, date.year != nil) {
        case (true, true): template = "dMMMy"
        case (true, false): template = "dMMM"
        case (false, false): template = "MMM"
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

    /// A range or list as the source states it, at the source's precision and without an invented year: a part the
    /// source writes once is written once ("19 – 28 Nov 2026", "Nov 19 – Dec 3"), a start year the source does not
    /// state is not shown ("28 Dec – 3 Jan 2027"), and a list joins its dates the way the locale lists items.
    static func spanText(_ span: StatedSpan, locale: Locale) -> String {
        guard span.isRange, span.dates.count == 2 else {
            let list = ListFormatter()
            list.locale = locale
            let first = span.dates[0]
            if first.day != nil, span.dates.allSatisfy({ $0.month == first.month && $0.year == first.year }) {
                // Days that share their month and year say them once: "3, 5 and 7 Nov".
                let days = list.string(from: span.dates.compactMap { $0.day.map(String.init) }) ?? ""
                return
                    "\(days) \(dateText(StatedDate(year: first.year, month: first.month, day: nil), locale: locale, monthOnly: true))"
            }
            return list.string(from: span.dates.map { dateText($0, locale: locale) }) ?? ""
        }
        let (start, end) = (span.dates[0], span.dates[1])
        let wraps = wrapsYear(start, end)
        if wraps, start.year == nil || end.year == nil {
            return "\(dateText(start, locale: locale)) – \(dateText(end, locale: locale))"
        }
        let startYear = start.year ?? end.year ?? 2000
        let endYear = end.year ?? start.year ?? (wraps ? startYear + 1 : startYear)
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateTemplate = (start.day == nil ? "MMM" : "dMMM") + (start.year == nil && end.year == nil ? "" : "y")
        guard
            let from = calendar.date(from: DateComponents(year: startYear, month: start.month, day: start.day ?? 1)),
            let to = calendar.date(from: DateComponents(year: endYear, month: end.month, day: end.day ?? 1))
        else { return "" }
        return formatter.string(from: from, to: to)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .split(separator: " ").map { String($0) }.joined(separator: " ")
    }
}
