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
    /// An overview's timeline rows and the citations they refer to; both empty when no timeline qualifies.
    struct Timeline: Sendable, Equatable {
        var items: [OverviewTimelineItem] = []
        var citations: [OverviewCitation] = []
    }

    /// A calendar date exactly as precise as the source states it.
    struct StatedDate: Hashable, Sendable {
        /// The year; nil when the source states none.
        let year: Int?
        /// The month, 1 to 12.
        let month: Int
        /// The day of the month; nil for a month-and-year date.
        let day: Int?
    }

    /// A range or list of dates the source states in one coordinated phrase (#1249): one row and one span, however
    /// many dates it holds.
    struct StatedSpan: Hashable, Sendable {
        /// In the order the source gives them; a range holds its start and its end.
        let dates: [StatedDate]
        /// True for a range ("from 19 to 28 November"), false for a list ("on 3 and 5 November").
        let isRange: Bool
    }

    /// A single stated date or a stated range or list.
    enum StatedExpression: Hashable, Sendable {
        case date(StatedDate)
        case span(StatedSpan)
    }

    /// A stated expression and where it was found in a sentence.
    struct StatedExpressionMatch: Hashable, Sendable {
        let expression: StatedExpression
        /// The matched characters: the date itself, or a combined phrase from its first date to its last.
        let range: NSRange
        /// True when several date atoms combined into one range or list.
        let isCombined: Bool
    }

    /// A single dated sentence is not a timeline.
    static let minimumDistinctDates = 2
    /// The most rows a timeline shows.
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

    /// Builds the timeline from the facts' source sentences: one row per sentence that states one date, span or anchor,
    /// corroborated rows first, at most `maximumItems`, shown in time order.
    ///
    /// Returns an empty timeline unless at least `minimumDistinctDates` rows have distinct, non-overlapping dates.
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
        func span(_ entry: Entry) -> DateInterval? {
            let unit: Calendar.Component = entry.precision == 0 ? .month : .day
            guard let start = calendar.dateInterval(of: unit, for: entry.resolved),
                let end = calendar.dateInterval(of: unit, for: entry.end ?? entry.resolved)
            else { return nil }
            return DateInterval(start: start.start, end: end.end)
        }
        func establishesTimeline(_ selection: [Entry]) -> Bool {
            let distinct = Set(
                selection.filter { $0.end == nil }.map {
                    $0.kind == .anchor
                        ? "anchor|\($0.dateText.lowercased())"
                        : "\($0.resolved.timeIntervalSince1970)|\($0.precision)"
                })
            return distinct.count >= minimumDistinctDates
                || selection.contains { first in
                    first.end != nil
                        && selection.contains { other in
                            guard let a = span(first), let b = span(other) else { return false }
                            return a.end <= b.start || b.end <= a.start
                        }
                }
        }

        guard establishesTimeline(entries) else {
            return Timeline()
        }

        // Prefer corroborated items, then the order the facts arrived in; show them in time order.
        let prioritized = entries.sorted { ($0.facts.count, -$0.order) > ($1.facts.count, -$1.order) }
        var selected = Array(prioritized.prefix(maximumItems))
        if !establishesTimeline(selected) {
            // Two rows always suffice to establish a timeline, and more rows never undo it. So keep the best-ranked
            // such pair and fill the other places by rank: one swap is not enough when both rows of the pair rank
            // below the first eight (#1249).
            var pair: (Int, Int)?
            search: for first in prioritized.indices {
                for second in prioritized.indices.dropFirst(first + 1)
                where establishesTimeline([prioritized[first], prioritized[second]]) {
                    pair = (first, second)
                    break search
                }
            }
            guard let pair else { return Timeline() }
            let rest = prioritized.indices.filter { $0 != pair.0 && $0 != pair.1 }.prefix(maximumItems - 2)
            selected = ([pair.0, pair.1] + rest).map { prioritized[$0] }
        }
        let kept = selected.sorted {
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
            let precision: OverviewTimelineItem.DatePrecision?
            if entry.kind != .stated {
                precision = nil
            } else if entry.end != nil {
                precision = .range
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
        /// The anchor exactly as the source words it.
        let text: String
        /// The provisional placement used for ordering only.
        let resolved: Date
        /// True when the source states the anchor as a plan still ahead when reported.
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

    /// The one explicit date a sentence states; nil when it states none, several, a range or a list, or an
    /// impossible one.
    static func singleStatedDate(in sentence: String) -> StatedDate? {
        if case .date(let date)? = statedExpression(in: sentence) { return date }
        return nil
    }

    private static let dayNumber = #"\d{1,2}(?:st|nd|rd|th|er)?(?!\d)"#
    private static let rangeJoin = #"(?:\s*[–—-]\s*|\s+(?:to|through|until)\s+)"#
    private static let dayListJoin = #"(?:,\s+|,?\s+and\s+)"#
    private static let dayFirstMonth = alternation(englishMonths.merging(dayFirstMonths) { english, _ in english }.keys)
    private static let englishMonth = alternation(englishMonths.keys)

    /// Shared-month ranges and lists are matched before single dates, which can otherwise take only one day.
    private static let sharedMonthPatterns: [(regex: NSRegularExpression, monthFirst: Bool)] = {
        let year = #"(?<year>(?:19|20)\d{2})(?!\d)"#
        func days(_ day: String) -> String {
            #"(?<days>\#(day)\#(rangeJoin)\#(day)|\#(day)(?:\#(dayListJoin)\#(day))+)"#
        }
        let dayFirst = days(#"\#(dayNumber)\.?"#)
        let monthFirst = days(dayNumber)
        let sources: [(String, Bool)] = [
            (
                #"(?<![\d.,])\#(dayFirst)\s+(?:of\s+)?(?<month>\#(dayFirstMonth))(?!\p{L})\.?(?:,?\s+\#(year))?"#,
                false
            ),
            (
                #"(?<!\p{L})(?<month>\#(englishMonth))(?!\p{L})\.?\s+\#(monthFirst)(?:,?\s+\#(year))?"#,
                true
            ),
        ]
        var compiled: [(regex: NSRegularExpression, monthFirst: Bool)] = []
        for (pattern, monthFirst) in sources {
            if let regex = try? NSRegularExpression(pattern: pattern) { compiled.append((regex, monthFirst)) }
        }
        return compiled
    }()

    private static let rangeBetweenDates =
        #"^(?:[–—-]|to|through|until|and\s+(?:runs?|running|continues?|extends?|lasts?)\s+(?:through|until|to))$"#
    private static let listBetweenDates = #"^(?:,|and|,\s*and)$"#

    /// What a sentence states as dates: one date, one range or list in a single coordinated phrase, or nil when it
    /// states none, several unrelated dates (separate clauses, a range or list plus another date), a reversed
    /// range, an expression whose parts cannot share a precision or year, or an impossible date.
    static func statedExpression(in sentence: String) -> StatedExpression? {
        statedExpressionMatch(in: sentence)?.expression
    }

    /// The parsed `StatedExpression` together with its matched character range in `sentence`.
    static func statedExpressionMatch(in sentence: String) -> StatedExpressionMatch? {
        let range = NSRange(sentence.startIndex..., in: sentence)
        guard let atoms = dateAtoms(in: sentence, range: range), let first = atoms.first, let last = atoms.last,
            !hasBareMonthEndpoint(before: first.range, after: last.range, in: sentence)
        else { return nil }
        if atoms.count == 1 {
            let expression = first.span.map(StatedExpression.span) ?? first.date.map(StatedExpression.date)
            return expression.map { StatedExpressionMatch(expression: $0, range: first.range, isCombined: false) }
        }
        guard let expression = combined(atoms, in: sentence) else { return nil }
        if case .date = expression {
            return StatedExpressionMatch(expression: expression, range: first.range, isCombined: false)
        }
        return StatedExpressionMatch(
            expression: expression, range: NSUnionRange(first.range, last.range), isCombined: true)
    }

    /// A bare month beside a parsed date cannot supply the precision or year needed for a range.
    private static func hasBareMonthEndpoint(before first: NSRange, after last: NSRange, in sentence: String) -> Bool {
        guard let first = Range(first, in: sentence), let lastRange = Range(last, in: sentence) else { return false }
        let before = sentence[..<first.lowerBound]
        let after = sentence[lastRange.upperBound...]
        let month = #"(?<!\p{L})(?:\#(englishMonth))(?!\p{L})\.?"#
        let between = #"\bbetween\s+"#
        let and = #"\s+and\s+"#
        if before.range(of: #"(?:\#(month)\#(rangeJoin)|\#(between)\#(month)\#(and))$"#, options: .regularExpression)
            != nil
        {
            return true
        }
        let join =
            before.range(of: #"\#(between)$"#, options: .regularExpression) == nil
            ? rangeJoin : #"(?:\#(rangeJoin)|\#(and))"#
        return after.range(of: #"^\#(join)\#(month)"#, options: .regularExpression) != nil
    }

    /// One date, or one shared-month range or list ("19–28 November"), found in a sentence.
    private struct DateAtom {
        let range: NSRange
        let date: StatedDate?
        let span: StatedSpan?
    }

    private enum SharedMonthMatch {
        case span(StatedSpan)
        case skip
        case invalid
    }

    /// Every date and shared-month span of a sentence in reading order; nil when one of them is impossible or
    /// reversed, which rejects the whole sentence.
    private static func dateAtoms(in sentence: String, range: NSRange) -> [DateAtom]? {
        var atoms: [DateAtom] = []
        func isTaken(_ candidate: NSRange) -> Bool {
            atoms.contains { NSIntersectionRange($0.range, candidate).length > 0 }
        }
        for (regex, monthFirst) in sharedMonthPatterns {
            for match in regex.matches(in: sentence, range: range) where !isTaken(match.range) {
                switch sharedMonthSpan(match, monthFirst: monthFirst, in: sentence) {
                case .span(let span): atoms.append(DateAtom(range: match.range, date: nil, span: span))
                case .skip: continue
                case .invalid: return nil
                }
            }
        }
        for regex in patterns {
            for match in regex.matches(in: sentence, range: range) where !isTaken(match.range) {
                guard let date = statedDate(from: match, in: sentence) else { return nil }
                atoms.append(DateAtom(range: match.range, date: date, span: nil))
            }
        }
        return atoms.sorted { $0.range.location < $1.range.location }
    }

    /// Distinguish a shared month from a full date on each side and reject mixed ranges and lists.
    private static func sharedMonthSpan(_ match: NSTextCheckingResult, monthFirst: Bool, in sentence: String)
        -> SharedMonthMatch
    {
        func group(_ name: String) -> String? {
            Range(match.range(withName: name), in: sentence).map { String(sentence[$0]) }
        }
        guard let monthText = group("month"), let month = englishMonths[monthText] ?? dayFirstMonths[monthText],
            let text = group("days"), let found = Range(match.range, in: sentence)
        else { return .invalid }
        let prefix = sentence[..<found.lowerBound]
        let suffix = sentence[found.upperBound...]
        let year = group("year").flatMap(Int.init)

        // In "November 29 to 3 December" neither month is shared. Let the full-date matcher read both.
        if monthFirst, year == nil,
            suffix.range(of: #"^\s+(?:of\s+)?(?:\#(dayFirstMonth))(?!\p{L})"#, options: .regularExpression) != nil
        {
            return .skip
        }
        if !monthFirst,
            prefix.range(of: #"(?<!\p{L})(?:\#(englishMonth))\.?\s+$"#, options: .regularExpression) != nil
        {
            return .skip
        }

        let hasRangeJoin = text.range(of: rangeJoin, options: .regularExpression) != nil
        let isRange = hasRangeJoin || precededByBetween(match.range, in: sentence)
        if prefix.range(
            of: #"(?<![\d.,])\#(dayNumber)\.?(?:\#(rangeJoin)|\#(dayListJoin))$"#, options: .regularExpression
        ) != nil {
            return .invalid
        }
        let endsPhrase = suffix.range(of: #"^\s*(?:[.!?;)]|$)"#, options: .regularExpression) != nil
        // "November 3 and 5 people" counts people; "November 19 and 21 at the courthouse" lists two days.
        // ponytail: a short list of words that cannot follow a count; any other word keeps the single-date reading.
        let continuesAfterList =
            suffix.range(
                of: #"^,?\s+(?:at|in|on|for|by|with|before|after|when|while|as|and|but|to|from)\b"#,
                options: .regularExpression) != nil
        if monthFirst, year == nil, !isRange, !endsPhrase, !continuesAfterList { return .skip }
        if suffix.range(
            // A further day, or a further range of days ("April 9 to 11 and 16 to 18"), shares the month too.
            of: #"^(?:\#(rangeJoin)|\#(dayListJoin))\#(dayNumber)(?:\#(rangeJoin)\#(dayNumber))?(?=\s*(?:[,;.!?)]|$))"#,
            options: .regularExpression
        ) != nil {
            return .invalid
        }
        let days = text.split { !$0.isNumber }.compactMap { Int($0) }
        var dates: [StatedDate] = []
        for date in days.map({ StatedDate(year: year, month: month, day: $0) }) {
            guard isPossible(date) else { return .invalid }
            if !dates.contains(date) { dates.append(date) }
        }
        guard dates.count >= 2, !isRange || (dates.count == 2 && days[0] < days[1]) else { return .invalid }
        return .span(StatedSpan(dates: dates, isRange: isRange))
    }

    private static func precededByBetween(_ range: NSRange, in sentence: String) -> Bool {
        guard let found = Range(range, in: sentence) else { return false }
        return sentence[..<found.lowerBound].trimmingCharacters(in: .whitespaces).lowercased().hasSuffix("between")
    }

    /// Several full dates of one sentence as one range or list, when only range or list words join them; nil for a
    /// range or list plus another date, unrelated dates, mixed precision, or a list whose dates differ in stating a
    /// year.
    private static func combined(_ atoms: [DateAtom], in sentence: String) -> StatedExpression? {
        let dates = atoms.compactMap(\.date)
        guard dates.count == atoms.count, let first = atoms.first else { return nil }
        if Set(dates).count == 1 { return .date(dates[0]) }
        guard Set(dates.map { $0.day == nil }).count == 1 else { return nil }
        let joins = zip(atoms, atoms.dropFirst()).compactMap { pair -> String? in
            let gap = NSRange(
                location: NSMaxRange(pair.0.range), length: pair.1.range.location - NSMaxRange(pair.0.range))
            return Range(gap, in: sentence).map { sentence[$0].trimmingCharacters(in: .whitespaces) }
        }
        func all(_ pattern: String) -> Bool {
            joins.allSatisfy { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        let between = precededByBetween(first.range, in: sentence)
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
            // The first date's year places every date that states none, so a list never splits across years.
            guard let first = span.dates.first, let anchor = resolve(first, publishedAt: publishedAt) else {
                return nil
            }
            let year = calendar.component(.year, from: anchor)
            let placed = span.dates.compactMap { date in place(date, year: date.year ?? year).map { (date, $0) } }
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

    /// The date formatted for `locale` at the precision the source states, never adding a missing day or year.
    static func dateText(_ date: StatedDate, locale: Locale) -> String {
        let template: String
        switch (date.day != nil, date.year != nil) {
        case (true, true): template = "dMMMy"
        case (true, false): template = "dMMM"
        case (false, false): template = "MMM"
        default: template = "MMMy"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = gregorian(locale)
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
                // Days that share their month and year say them once.
                // The month and year sit where the locale puts them in a single date: "Nov 3 and 5" or "3 and 5 Nov".
                let days = list.string(from: span.dates.compactMap { $0.day.map(String.init) }) ?? ""
                let month = dateText(StatedDate(year: nil, month: first.month, day: nil), locale: locale)
                let monthFirst = dateText(StatedDate(year: nil, month: first.month, day: first.day), locale: locale)
                    .hasPrefix(month)
                let year = first.year.map { monthFirst ? ", \($0)" : " \($0)" } ?? ""
                return (monthFirst ? "\(month) \(days)" : "\(days) \(month)") + year
            }
            return list.string(from: span.dates.map { dateText($0, locale: locale) }) ?? ""
        }
        let (start, end) = (span.dates[0], span.dates[1])
        let wraps = wrapsYear(start, end)
        // The interval formatter otherwise moves a year stated only at the start to the end.
        if (start.year != nil && end.year == nil) || (wraps && start.year == nil) {
            return "\(dateText(start, locale: locale)) – \(dateText(end, locale: locale))"
        }
        let startYear = start.year ?? end.year ?? 2000
        let endYear = end.year ?? start.year ?? (wraps ? startYear + 1 : startYear)
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = gregorian(locale)
        formatter.dateTemplate = (start.day == nil ? "MMM" : "dMMM") + (start.year == nil && end.year == nil ? "" : "y")
        guard
            let from = calendar.date(from: DateComponents(year: startYear, month: start.month, day: start.day ?? 1)),
            let to = calendar.date(from: DateComponents(year: endYear, month: end.month, day: end.day ?? 1))
        else { return "" }
        return formatter.string(from: from, to: to)
    }

    /// The reader's locale with the Gregorian calendar the builder works in. A locale that names another calendar
    /// (ISO 8601 puts the year first) is honoured by the date formatter and ignored by the interval formatter, which
    /// swapped day, month and year between the rows of one timeline.
    private static func gregorian(_ locale: Locale) -> Locale {
        var components = Locale.Components(locale: locale)
        components.calendar = .gregorian
        return Locale(components: components)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .split(separator: " ").map { String($0) }.joined(separator: " ")
    }
}
