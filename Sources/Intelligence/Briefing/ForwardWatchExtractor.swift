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

// Angelia · Athena (editorial selection) owns this file. Register: docs/ANGELIA.md.

import Foundation

/// One forward-looking line a publisher stated, in the publisher's words. The app schedules nothing.
struct ForwardWatchItem: Equatable, Hashable, Sendable {
    enum Kind: Int, Sendable, Comparable {
        case scheduled, expected, conditional

        var title: String {
            switch self {
            case .scheduled: return "Scheduled"
            case .expected: return "Expected"
            case .conditional: return "Conditional"
            }
        }

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let kind: Kind
    /// The cited sentence, trimmed.
    let text: String
    /// The date exactly as written in `text`; nil when the sentence states none. Never inferred.
    let dateText: String?
    let publisher: String?
    let citationID: String?
}

/// Scheduled, expected and conditional items stated in cited passages, in the publisher's words (#851). Sentence
/// segmentation, regex anchors and keyword lists, no model.
enum ForwardWatchExtractor {
    static let maximumItems = 6

    /// Reads cited passages. Publication resolves partial dates; `now` determines whether the date has passed.
    /// `publishedAt` also stands in for a citation without its own publication date.
    static func extract(
        facts: [OverviewFact], citations: [String: OverviewCitation], publishedAt: Date, now: Date? = nil
    )
        -> [ForwardWatchItem]
    {
        var items: [ForwardWatchItem] = []
        var seen = Set<String>()
        for fact in facts {
            for citationID in fact.citationIDs {
                guard let citation = citations[citationID] else { continue }
                let quote = citation.quote
                for range in PassageFactExtractor.segmentedSentences(in: quote) {
                    let sentence = quote[range].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard sentence.count >= 20,
                        let (kind, dateText) = classify(
                            sentence, publishedAt: citation.publishedAt ?? publishedAt,
                            now: now ?? citation.publishedAt ?? publishedAt)
                    else { continue }
                    // One item per sentence and publisher, so the module can count every publisher that stated it.
                    guard seen.insert(key(sentence) + "\u{0}" + (citation.sourceName ?? "")).inserted else { continue }
                    items.append(
                        ForwardWatchItem(
                            kind: kind, text: sentence, dateText: dateText, publisher: citation.sourceName,
                            citationID: citationID))
                }
            }
        }
        // The cap counts distinct sentences; further publishers of a kept sentence stay in.
        var kept = Set<String>()
        return sorted(items).filter { item in
            let sentence = key(item.text)
            if kept.contains(sentence) { return true }
            guard kept.count < maximumItems else { return false }
            kept.insert(sentence)
            return true
        }
    }

    /// Dedupe key: the whole sentence, whitespace collapsed and case folded, so identical wire copy merges but two
    /// claims that only share an opening stay apart.
    static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Scheduled first, then expected, then conditional; stable within a kind.
    static func sorted(_ items: [ForwardWatchItem]) -> [ForwardWatchItem] {
        items.enumerated().sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }.map(\.element)
    }

    /// The sentence's kind and its verbatim date text, or nil when it states nothing ahead.
    static func classify(_ sentence: String, publishedAt: Date, now: Date? = nil) -> (ForwardWatchItem.Kind, String?)? {
        let lower = sentence.lowercased()
        if matches(lower, Pattern.reportedPast) || matches(lower, Pattern.counterfactual) { return nil }
        let schedule = scheduleDate(in: sentence, publishedAt: publishedAt, now: now ?? publishedAt)
        guard !schedule.expired else { return nil }
        let date = schedule.text
        if isConditional(lower) { return (.conditional, date ?? firstMatch(sentence, Pattern.vagueTime)) }
        if let date, matches(lower, Pattern.scheduling) { return (.scheduled, date) }
        if matches(lower, Pattern.expectation) || firstMatch(sentence, Pattern.vagueTime) != nil {
            return (.expected, firstMatch(sentence, Pattern.vagueTime) ?? date)
        }
        return nil
    }

    private static func isConditional(_ lower: String) -> Bool {
        guard !matches(lower, Pattern.notConditional) else { return false }
        let condition =
            matches(lower, Pattern.ifClause) || lower.contains("in the event of")
            || matches(lower, Pattern.shouldThen)
        return condition && matches(lower, Pattern.consequence)
    }

    /// A day, date, or date range, exactly as written. Calendar dates resolve against publication and must not have
    /// ended by the edition date; a weekday or "next week" needs a future marker so "met on Tuesday" never counts.
    private static func scheduleDate(in sentence: String, publishedAt: Date, now: Date) -> (
        text: String?, expired: Bool
    ) {
        if let match = OverviewTimelineBuilder.statedExpressionMatch(in: sentence) {
            let today = Calendar.utc.startOfDay(for: now)
            switch match.expression {
            case .date(let stated):
                guard let resolved = OverviewTimelineBuilder.resolve(stated, publishedAt: publishedAt) else {
                    return (nil, false)
                }
                guard let end = Calendar.utc.dateInterval(of: stated.day == nil ? .month : .day, for: resolved)?.end
                else { return (nil, false) }
                guard end > today else { return (nil, true) }
                return (
                    firstMatch(sentence, Pattern.calendarDate)
                        ?? verbatimDateText(in: sentence, matchRange: match.range, isRange: false, isCombined: false),
                    false
                )
            case .span(let span):
                // A month-only end runs to the end of that month, not to its first day.
                guard let placed = OverviewTimelineBuilder.placedDates(of: span, publishedAt: publishedAt),
                    let latest = placed.max(by: { $0.at < $1.at }),
                    let end = Calendar.utc.dateInterval(of: latest.date.day == nil ? .month : .day, for: latest.at)?.end
                else { return (nil, false) }
                guard end > today else { return (nil, true) }
                return (
                    verbatimDateText(
                        in: sentence, matchRange: match.range, isRange: span.isRange, isCombined: match.isCombined),
                    false
                )
            }
        }
        guard matches(sentence.lowercased(), Pattern.futureMarker) else { return (nil, false) }
        return (firstMatch(sentence, Pattern.relativeDay), false)
    }

    /// Slices the verbatim date expression from `sentence`, keeping the leading preposition (`from`/`between` for a
    /// range, or `on`/`in` for a single phrase) when present.
    private static func verbatimDateText(
        in sentence: String, matchRange: NSRange, isRange: Bool, isCombined: Bool
    ) -> String? {
        guard let range = Range(matchRange, in: sentence) else { return nil }
        var end = range.upperBound
        while end > range.lowerBound, sentence[sentence.index(before: end)] == "." {
            end = sentence.index(before: end)
        }
        guard end > range.lowerBound else { return nil }
        let prefix = sentence[..<range.lowerBound]
        if isRange,
            let lead = prefix.range(of: #"\b(?:from|between)\s+$"#, options: [.regularExpression, .caseInsensitive])
        {
            return String(sentence[lead.lowerBound..<end])
        }
        if !isCombined, let lead = prefix.range(of: #"\b(?:on|in)\s+$"#, options: .regularExpression) {
            return String(sentence[lead.lowerBound..<end])
        }
        return String(sentence[range.lowerBound..<end])
    }

    private static func matches(_ text: String, _ regex: NSRegularExpression) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func firstMatch(_ text: String, _ regex: NSRegularExpression) -> String? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            .flatMap { Range($0.range, in: text) }
            .map { String(text[$0]) }
    }

    private enum Pattern {
        static func make(_ pattern: String, caseless: Bool = true) -> NSRegularExpression {
            // The patterns are literals; a typo is a programming error caught by the evaluation test.
            guard let regex = try? NSRegularExpression(pattern: pattern, options: caseless ? [.caseInsensitive] : [])
            else { preconditionFailure("Forward watch pattern does not compile: \(pattern)") }
            return regex
        }

        static let months =
            "January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec"
        static let weekdays = "Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday"

        /// Matched case-sensitively so "may" as a verb is never a month.
        static let calendarDate = make(
            #"(?:(?:on|in)\s+)?(?:(?:19|20)\d{2}-\d{2}-\d{2}|\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:\#(months))\b(?:,?\s+(?:19|20)\d{2})?|(?:\#(months))\.?\s+\d{1,2}(?:st|nd|rd|th)?\b(?:,?\s+(?:19|20)\d{2})?|(?:\#(months))\s+(?:19|20)\d{2}\b)"#,
            caseless: false)
        static let relativeDay = make(
            #"\b(?:next\s+(?:week|month)|(?:next\s+|this\s+)?(?:\#(weekdays)))\b"#, caseless: false)
        static let vagueTime = make(
            #"\b(?:later\s+this\s+(?:week|month|year)|in\s+the\s+coming\s+(?:days|weeks|months)|within\s+(?:days|weeks)|by\s+the\s+end\s+of\s+(?:the|this)\s+(?:week|month|year))\b"#
        )

        static let futureMarker = make(
            #"\b(?:will|is\s+due|are\s+due|is\s+scheduled|are\s+scheduled|scheduled\s+for|set\s+to|is\s+to|are\s+to|to\s+be\s+held|upcoming|expires|takes?\s+effect)\b"#
        )
        static let scheduling = make(
            #"\b(?:scheduled|will\s+meet|is\s+due|are\s+due|vote|votes|session|hearing|summit|talks|deadline|expires|set\s+to|to\s+be\s+held|meeting|takes?\s+effect|ruling|election|sentencing)\b"#
        )
        static let expectation = make(
            #"\b(?:is|are)\s+expected\s+to\b|\bplans?\s+to\b|\bintends?\s+to\b|\bwill\s+(?:review|decide|announce|consider|publish|release|resume|present|unveil)\b|\b(?:is|are)\s+set\s+to\b"#
        )

        static let ifClause = make(#"\b(?:if|unless)\s"#)
        static let shouldThen = make(#"\bshould\b.+\bthen\b"#)
        static let consequence = make(#"\b(?:will|would|could|may|might|threatens?\s+to|warned)\b"#)
        static let notConditional = make(#"\b(?:asked|wondered|unclear|whether)\s+if\b|\beven\s+if\b"#)
        static let counterfactual = make(#"\bwould\s+have\b|\bhad\s+(?:known|been)\b"#)
        /// Sentences that report what already happened ("was held", "met on").
        static let reportedPast = make(
            #"\b(?:was|were)\s+(?:held|signed|completed)\b|\b(?:met|voted|ended|expired)\s+(?:on|last)\b|\blast\s+(?:week|month|year)\b"#
        )
    }
}

extension Calendar {
    fileprivate static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }()
}
