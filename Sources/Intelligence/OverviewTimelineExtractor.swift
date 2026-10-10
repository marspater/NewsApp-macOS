import Foundation
import NaturalLanguage

/// Result of deterministically validating an overview timeline item against evidence passages and rules.
struct OverviewTimelineValidationResult: Sendable, Equatable {
    let isValid: Bool
    let rejectionReason: String?

    init(isValid: Bool, rejectionReason: String? = nil) {
        self.isValid = isValid
        self.rejectionReason = rejectionReason
    }
}

/// Enforces the four core rules of timeline items:
/// 1. Event date kept separate from publication date.
/// 2. An unknown date stays unknown (never defaulted to publication date).
/// 3. Future plans are labeled as plans.
/// 4. Every item has a verified source citation.
struct OverviewTimelineValidator: Sendable {

    /// Known future plan and intent indicators.
    private static let futurePlanKeywords: [String] = [
        "plans to", "planned to", "planning to", "scheduled to", "scheduled for",
        "will launch", "will begin", "will open", "aims to", "aiming to",
        "expected in", "expected to", "proposed", "target date", "slated to",
        "set to begin", "projected to"
    ]

    /// Validates a single timeline item against available overview citations and source articles.
    static func validateItem(
        _ item: OverviewTimelineItem,
        against citations: [String: OverviewCitation]
    ) -> OverviewTimelineValidationResult {
        // Rule 4: Every item must have a source citation
        guard !item.citationIDs.isEmpty else {
            return OverviewTimelineValidationResult(isValid: false, rejectionReason: "Timeline item has no source citation")
        }

        for citID in item.citationIDs {
            guard let citation = citations[citID] else {
                return OverviewTimelineValidationResult(
                    isValid: false,
                    rejectionReason: "Citation ID '\(citID)' not found in overview citations"
                )
            }
            guard !citation.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return OverviewTimelineValidationResult(
                    isValid: false,
                    rejectionReason: "Citation '\(citID)' has empty quote"
                )
            }
        }

        let summaryLower = item.summary.lowercased()
        let dateTextLower = item.dateText.lowercased()

        // Rule 3: Future plans must be labeled as plans
        let hasPlanKeywords = futurePlanKeywords.contains(where: {
            summaryLower.contains($0) || dateTextLower.contains($0)
        })

        var isChronologicallyFuture = false
        if let eventDate = item.eventDate, let pubDate = item.publicationDate {
            // Event date is more than 24 hours after publication date
            if eventDate.timeIntervalSince(pubDate) > 86400 {
                isChronologicallyFuture = true
            }
        }

        if (hasPlanKeywords || isChronologicallyFuture) && !item.isFuturePlan {
            return OverviewTimelineValidationResult(
                isValid: false,
                rejectionReason: "Item describes a future plan or target date but is not labeled as a plan"
            )
        }

        // Rule 1 & 2: Event date separate from publication date, unknown stays unknown
        // If the date text indicates unknown date, eventDate must be nil
        if (dateTextLower.contains("unknown") || dateTextLower.contains("unspecified")) && item.eventDate != nil {
            return OverviewTimelineValidationResult(
                isValid: false,
                rejectionReason: "Unknown event date must remain nil, never assigned a synthesized timestamp"
            )
        }

        return OverviewTimelineValidationResult(isValid: true)
    }

    /// Evaluates if text describes a scheduled future plan or target.
    static func isPlanDescribed(in text: String) -> Bool {
        let lower = text.lowercased()
        return futurePlanKeywords.contains(where: { lower.contains($0) })
    }
}

/// Extracts structured, evidence-backed timeline items from event passages and articles.
struct OverviewTimelineExtractor: Sendable {

    /// Extracts timeline items from evidence passages, linking citations to source articles.
    ///
    /// - Parameters:
    ///   - passages: Selected evidence passages for the event.
    ///   - articles: Member articles forming the event cluster.
    ///   - existingCitations: Citations already established for the overview.
    /// - Returns: Validated chronological timeline items, or empty array if insufficient data exists.
    static func extractTimeline(
        passages: [EvidencePassage],
        articles: [FeedArticle],
        existingCitations: [String: OverviewCitation]
    ) -> [OverviewTimelineItem] {
        let articlesByID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })
        var candidates: [OverviewTimelineItem] = []

        // Reverse-index passages to citation IDs
        var passageToCitationID: [String: String] = [:]
        for (citID, citation) in existingCitations {
            passageToCitationID[citation.passageID] = citID
        }

        for passage in passages {
            guard let citID = passageToCitationID[passage.id] else {
                continue
            }
            let article = articlesByID[passage.articleID]
            let pubDate = article?.pubDate

            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = passage.text
            let range = passage.text.startIndex..<passage.text.endIndex

            tokenizer.enumerateTokens(in: range) { sentenceRange, _ in
                let sentence = String(passage.text[sentenceRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard sentence.count >= 20 else { return true }

                if let item = parseTimelineItem(
                    sentence: sentence,
                    passageID: passage.id,
                    citationID: citID,
                    publicationDate: pubDate
                ) {
                    candidates.append(item)
                }
                return true
            }
        }

        // Validate candidates
        var validItems: [OverviewTimelineItem] = []
        var seenSummaries = Set<String>()

        for item in candidates {
            let validation = OverviewTimelineValidator.validateItem(item, against: existingCitations)
            guard validation.isValid else { continue }

            // Deduplicate near-identical summaries
            let key = item.summary.prefix(40).lowercased()
            guard !seenSummaries.contains(key) else { continue }
            seenSummaries.insert(key)

            validItems.append(item)
        }

        // Rule of Absent Sections: If fewer than 2 valid items exist, leave section absent
        guard validItems.count >= 2 else {
            return []
        }

        // Sort: Past items chronologically, future plans at the end
        return validItems.sorted { first, second in
            if first.isFuturePlan != second.isFuturePlan {
                // Non-plans (past/occurred) come before future plans
                return !first.isFuturePlan && second.isFuturePlan
            }
            if let d1 = first.eventDate, let d2 = second.eventDate {
                return d1 < d2
            }
            if first.eventDate != nil && second.eventDate == nil {
                return true
            }
            if first.eventDate == nil && second.eventDate != nil {
                return false
            }
            return first.dateText < second.dateText
        }
    }

    /// Parses a single candidate timeline item from an evidence sentence.
    private static func parseTimelineItem(
        sentence: String,
        passageID: String,
        citationID: String,
        publicationDate: Date?
    ) -> OverviewTimelineItem? {
        let isPlan = OverviewTimelineValidator.isPlanDescribed(in: sentence)
        let extractedDate = extractTemporalAnchor(from: sentence)

        // Rule 2: An unknown date stays unknown
        // Only emit if there is an explicit temporal anchor OR it is a marked future plan
        guard let anchor = extractedDate ?? (isPlan ? extractPlanQuarterOrYear(from: sentence) : nil) else {
            return nil
        }

        var eventDate: Date? = nil
        var isFuture = isPlan

        if let parsedDate = parseDateString(anchor) {
            eventDate = parsedDate
            if let pub = publicationDate, parsedDate.timeIntervalSince(pub) > 86400 {
                isFuture = true
            }
        }

        let itemID = "tl_\(passageID)_\(abs(sentence.hashValue % 10000))"
        return OverviewTimelineItem(
            id: itemID,
            dateText: anchor,
            summary: sentence,
            citationIDs: [citationID],
            isFuturePlan: isFuture,
            eventDate: eventDate,
            publicationDate: publicationDate
        )
    }

    /// Extracts an explicit temporal expression from text (e.g. "15 October 2026", "06:14 UTC", "October 2026").
    private static func extractTemporalAnchor(from text: String) -> String? {
        // Pattern 1: Day Month Year (e.g., "15 October 2026" or "15 Oct 2026")
        if let match = text.range(of: #"\b\d{1,2}\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4}\b"#, options: [.regularExpression, .caseInsensitive]) {
            return String(text[match])
        }

        // Pattern 2: Month Day, Year (e.g., "October 15, 2026")
        if let match = text.range(of: #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:,\s*\d{4})?\b"#, options: [.regularExpression, .caseInsensitive]) {
            return String(text[match])
        }

        // Pattern 3: Explicit time of day with timezone (e.g., "06:14 UTC", "14:30 GMT")
        if let match = text.range(of: #"\b\d{1,2}:\d{2}\s*(?:UTC|GMT|EST|PST|EDT|PDT)\b"#, options: [.regularExpression, .caseInsensitive]) {
            return String(text[match])
        }

        // Pattern 4: Relative time anchor (e.g. "Yesterday morning", "Earlier today")
        if let match = text.range(of: #"\b(?:earlier today|yesterday morning|yesterday evening|last night|earlier this week)\b"#, options: [.regularExpression, .caseInsensitive]) {
            return String(text[match]).capitalized
        }

        return nil
    }

    /// Extracts plan schedule markers like "second quarter", "Q2 2027", "2027".
    private static func extractPlanQuarterOrYear(from text: String) -> String? {
        if let match = text.range(of: #"\bQ[1-4]\s+\d{4}\b"#, options: [.regularExpression, .caseInsensitive]) {
            return String(text[match])
        }
        if let match = text.range(of: #"\b(?:first|second|third|fourth)\s+quarter(?:\s+of\s+\d{4})?\b"#, options: [.regularExpression, .caseInsensitive]) {
            return String(text[match]).capitalized
        }
        if let match = text.range(of: #"\b(?:in\s+)?202[7-9]\b"#, options: [.regularExpression, .caseInsensitive]) {
            return String(text[match])
        }
        return "Scheduled"
    }

    /// Parses ISO or standard human date formats into a Date.
    private static func parseDateString(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let formats = [
            "d MMMM yyyy",
            "MMMM d, yyyy",
            "yyyy-MM-dd",
            "d MMM yyyy",
            "MMMM yyyy"
        ]

        for fmt in formats {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}
