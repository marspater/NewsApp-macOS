import Foundation

/// Result of deterministically validating an overview thematic angle against evidence passages and rules.
struct OverviewThematicAngleValidationResult: Sendable, Equatable {
    let isValid: Bool
    let rejectionReason: String?

    init(isValid: Bool, rejectionReason: String? = nil) {
        self.isValid = isValid
        self.rejectionReason = rejectionReason
    }
}

/// Enforces the three core rules of thematic angles:
/// 1. No forecasts (no speculative projections, price targets, or forward-looking predictions).
/// 2. No investment advice (no buy/sell ratings, portfolio recommendations, or trading advice).
/// 3. Every fact cited (every single fact and angle summary has verified citation grounding).
struct OverviewThematicAngleValidator: Sendable {

    /// Known forecast and speculative projection indicators.
    private static let forecastKeywords: [String] = [
        "forecast", "forecasts", "forecasting", "forecasted",
        "projected to", "projected revenue", "projected growth",
        "predicts", "predicting", "predicted to",
        "expected to grow", "expected to surge", "expected to rise",
        "expected to drop", "expected to fall", "expected to reach",
        "will reach", "will hit", "will surge", "will double", "will triple",
        "outlook suggests", "price target", "price targets",
        "analysts anticipate", "analysts project", "projected by 20"
    ]

    /// Known investment advice, stock ratings, and trading recommendation keywords.
    private static let investmentAdviceKeywords: [String] = [
        "buy recommendation", "sell recommendation", "hold recommendation",
        "strong buy", "strong sell", "overweight", "underweight",
        "investors should", "investors are advised", "recommend buying",
        "recommend selling", "stock pick", "stock picks", "trading advice",
        "investment advice", "portfolio allocation", "buy rating",
        "sell rating", "hold rating", "target price recommendation",
        "should buy shares", "should sell shares", "buy shares"
    ]

    /// Evaluates whether text contains speculative forecasts or forward-looking projections.
    static func isForecast(_ text: String) -> Bool {
        let lower = text.lowercased()
        for kw in forecastKeywords where lower.contains(kw) {
            return true
        }
        return false
    }

    /// Evaluates whether text contains investment advice, stock ratings, or trading directives.
    static func isInvestmentAdvice(_ text: String) -> Bool {
        let lower = text.lowercased()
        for kw in investmentAdviceKeywords where lower.contains(kw) {
            return true
        }
        return false
    }

    /// Validates a thematic angle against available citations.
    static func validateAngle(
        _ angle: OverviewThematicAngle,
        against citations: [String: OverviewCitation]
    ) -> OverviewThematicAngleValidationResult {
        // Basic non-empty checks
        guard !angle.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return OverviewThematicAngleValidationResult(isValid: false, rejectionReason: "Title is empty")
        }

        guard !angle.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return OverviewThematicAngleValidationResult(isValid: false, rejectionReason: "Summary is empty")
        }

        // Rule 1: No forecasts in summary
        if isForecast(angle.summary) {
            return OverviewThematicAngleValidationResult(
                isValid: false,
                rejectionReason: "Thematic angle summary contains forward-looking forecast or projection"
            )
        }

        // Rule 2: No investment advice in summary
        if isInvestmentAdvice(angle.summary) {
            return OverviewThematicAngleValidationResult(
                isValid: false,
                rejectionReason: "Thematic angle summary contains investment advice or stock ratings"
            )
        }

        // Rule 3: Every fact cited & validation of individual facts
        guard !angle.facts.isEmpty else {
            return OverviewThematicAngleValidationResult(
                isValid: false,
                rejectionReason: "Thematic angle has no facts"
            )
        }

        for fact in angle.facts {
            guard !fact.citationIDs.isEmpty else {
                return OverviewThematicAngleValidationResult(
                    isValid: false,
                    rejectionReason: "Thematic fact has no citation IDs"
                )
            }

            for citID in fact.citationIDs {
                guard let citation = citations[citID] else {
                    return OverviewThematicAngleValidationResult(
                        isValid: false,
                        rejectionReason: "Citation ID '\(citID)' not found in overview citations"
                    )
                }
                guard !citation.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return OverviewThematicAngleValidationResult(
                        isValid: false,
                        rejectionReason: "Citation '\(citID)' has empty quote"
                    )
                }
            }

            // Rule 1: No forecasts in individual facts
            if isForecast(fact.text) {
                return OverviewThematicAngleValidationResult(
                    isValid: false,
                    rejectionReason: "Thematic fact contains forward-looking forecast"
                )
            }

            // Rule 2: No investment advice in individual facts
            if isInvestmentAdvice(fact.text) {
                return OverviewThematicAngleValidationResult(
                    isValid: false,
                    rejectionReason: "Thematic fact contains investment advice"
                )
            }
        }

        return OverviewThematicAngleValidationResult(isValid: true)
    }
}

/// Extracts structured thematic angles (e.g. financial or quantitative figures) strictly from existing verified facts,
/// enforcing the rules of no forecasts, no investment advice, and complete citation grounding.
struct OverviewThematicAngleExtractor: Sendable {

    /// Financial and quantitative currency symbols and scale indicators.
    private static let financialMarkers: [String] = [
        "$", "€", "£", "¥", "₴", "usd", "eur", "gbp", "cad", "aud",
        "million", "billion", "trillion", "revenue", "valuation",
        "market cap", "earnings", "profit", "loss", "budget", "funding",
        "debt", "dividend", "acquisition price", "cash and equity"
    ]

    private static let quantitativeMarkers: [String] = [
        "%", "percent", "employees", "workforce", "megawatts", "gigawatts",
        "kilometers", "kilometres", "tonnes", "hectares", "acres", "passengers"
    ]

    /// Extracts a validated thematic angle from existing verified facts and source evidence.
    ///
    /// - Parameters:
    ///   - facts: Verified passage-anchored facts available for the event.
    ///   - passages: Selected evidence passages.
    ///   - existingCitations: Overview citations map.
    /// - Returns: Validated `OverviewThematicAngle`, or `nil` if insufficient thematic facts exist.
    static func extractThematicAngle(
        facts: [PassageAnchoredFact],
        passages: [EvidencePassage],
        existingCitations: [String: OverviewCitation]
    ) -> OverviewThematicAngle? {
        // Reverse-index passages to citation IDs
        var passageToCitationID: [String: String] = [:]
        for (citID, citation) in existingCitations {
            passageToCitationID[citation.passageID] = citID
        }

        var candidateFacts: [(fact: PassageAnchoredFact, citationID: String, isFinancial: Bool)] = []

        for fact in facts {
            // Rule 1 & 2: Filter out forecasts or investment advice
            if OverviewThematicAngleValidator.isForecast(fact.statement) ||
               OverviewThematicAngleValidator.isForecast(fact.quote) ||
               OverviewThematicAngleValidator.isInvestmentAdvice(fact.statement) ||
               OverviewThematicAngleValidator.isInvestmentAdvice(fact.quote) {
                continue
            }

            guard let citID = passageToCitationID[fact.passageID] else {
                continue
            }

            let lowerStatement = fact.statement.lowercased()
            let lowerQuote = fact.quote.lowercased()
            let combined = "\(lowerStatement) \(lowerQuote)"

            let hasFinancial = financialMarkers.contains(where: { combined.contains($0) })
            let hasQuantitative = quantitativeMarkers.contains(where: { combined.contains($0) })

            if hasFinancial || hasQuantitative {
                candidateFacts.append((fact: fact, citationID: citID, isFinancial: hasFinancial))
            }
        }

        // Rule of Absent Sections: If fewer than 2 thematic facts exist, leave section absent
        guard candidateFacts.count >= 2 else {
            return nil
        }

        let financialCount = candidateFacts.filter(\.isFinancial).count
        let isPrimarilyFinancial = Double(financialCount) / Double(candidateFacts.count) >= 0.5
        let title = isPrimarilyFinancial ? "Financial figures" : "Key figures & metrics"

        // Take up to 4 representative thematic facts
        let selected = candidateFacts.prefix(4)

        var angleFacts: [OverviewFact] = []
        var allCitationIDs: Set<String> = []

        for (index, item) in selected.enumerated() {
            let citID = item.citationID
            allCitationIDs.insert(citID)

            angleFacts.append(OverviewFact(
                id: "angle_fact_\(index + 1)",
                text: item.fact.statement,
                citationIDs: [citID]
            ))
        }

        // Synthesize a factual, non-speculative summary sentence from the first 2 facts
        let summaryStatements = selected.prefix(2).map(\.fact.statement)
        let summary = summaryStatements.joined(separator: " ")

        let angle = OverviewThematicAngle(
            id: "angle_thematic_\(abs(title.hashValue % 10000))",
            title: title,
            summary: summary,
            citationIDs: Array(allCitationIDs).sorted(),
            facts: angleFacts
        )

        let validation = OverviewThematicAngleValidator.validateAngle(angle, against: existingCitations)
        guard validation.isValid else {
            return nil
        }

        return angle
    }
}
