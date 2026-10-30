import Foundation
import NaturalLanguage

/// Extracts structured, evidence-backed Industry Impact entries strictly from verified passages (Epic T, #670).
/// Enforces:
/// 1. Stated practical implications on named industries (costs, prices, supply, demand, regulation, jobs, operations).
/// 2. Industry names come from one fixed, documented list (`StandardIndustry`).
/// 3. Every implication sentence is passage-grounded and passes `OverviewClaimVerifier`.
/// 4. No speculative forecasts or investment advice.
/// 5. No repetition of introduction or highlight sentences.
/// 6. Omitted when no implication meets the rule (no empty state or placeholder).
struct OverviewIndustryImpactExtractor: Sendable {

    /// Standard documented industries (12 fixed industries).
    enum StandardIndustry: String, CaseIterable, Codable, Sendable {
        case energy = "Energy"
        case financialServices = "Financial Services"
        case healthcare = "Healthcare"
        case technology = "Technology"
        case transportation = "Transportation"
        case agriculture = "Agriculture"
        case manufacturing = "Manufacturing"
        case retailAndEcommerce = "Retail & E-commerce"
        case mediaAndEntertainment = "Media & Entertainment"
        case telecommunications = "Telecommunications"
        case realEstate = "Real Estate"
        case defenseAndAerospace = "Defense & Aerospace"

        var cues: [String] {
            switch self {
            case .energy:
                return [
                    "energy", "utilities", "oil", "natural gas", "gas prices", "gas supplies", "petroleum", "refinery",
                    "refineries", "crude", "drilling",
                    "pipeline", "pipelines", "power grid", "electricity", "renewable energy", "solar", "wind farm",
                    "wind farms", "nuclear power", "utility company", "utility companies",
                ]
            case .financialServices:
                return [
                    "banking", "bank", "banks", "lender", "lenders", "financial services", "credit markets",
                    "consumer credit", "mortgage",
                    "mortgages",
                    "wall street", "investment bank", "investment banks", "hedge fund", "hedge funds", "fintech",
                    "liquidity",
                    "capital requirements", "interest rate margin",
                ]
            case .healthcare:
                return [
                    "healthcare", "pharmaceutical", "pharmaceuticals", "pharma", "drugmaker", "drugmakers",
                    "drug prices", "drug supplies", "drug shortages", "medical device", "medical devices", "biotech",
                    "hospital", "hospitals",
                    "clinical",
                    "fda approval", "prescription drug", "prescription drugs", "vaccine", "vaccines",
                ]
            case .technology:
                return [
                    "technology", "tech sector", "semiconductor", "semiconductors", "chipmaker", "chipmakers",
                    "chip", "chips", "hardware", "software", "cloud computing", "cloud provider", "cloud providers",
                    "data centers", "data center", "artificial intelligence", "cybersecurity",
                ]
            case .transportation:
                return [
                    "transportation", "airline", "airlines", "aircraft", "aviation", "flight", "flights", "airport",
                    "airports", "air carrier", "air carriers", "automaker", "automakers", "carmaker", "carmakers",
                    "auto industry", "automotive", "vehicle sales", "vehicle production", "electric vehicles",
                    "shipping", "freight",
                    "railroad", "railroads", "railway", "railways", "public transit",
                ]
            case .agriculture:
                return [
                    "agriculture", "agricultural", "farmer", "farmers", "farming", "crop", "crops", "grain", "wheat",
                    "corn", "soybean", "livestock", "cattle", "beef", "poultry", "fertilizer", "food production",
                    "harvest",
                ]
            case .manufacturing:
                return [
                    "manufacturing", "manufacturer", "manufacturers", "factory", "factories", "industrial", "steel",
                    "aluminum", "heavy industry", "machinery", "chemical plant", "chemical plants", "chemical makers",
                    "foundry", "smelter",
                    "production line", "raw materials",
                ]
            case .retailAndEcommerce:
                return [
                    "retail", "retailer", "retailers", "supermarket", "supermarkets", "e-commerce", "department stores",
                    "apparel", "consumer goods", "grocery", "merchandise", "shopping malls", "foot traffic",
                    "store closures",
                    "store sales",
                ]
            case .mediaAndEntertainment:
                return [
                    "streaming", "broadcaster", "broadcasters", "television", "media industry", "cable provider",
                    "cable providers", "film", "movie", "studios", "hollywood", "box office", "entertainment",
                    "music industry", "gaming", "video games",
                ]
            case .telecommunications:
                return [
                    "telecom", "telecoms", "telecommunications", "wireless", "broadband", "mobile network",
                    "mobile networks", "cellular", "5g", "spectrum",
                ]
            case .realEstate:
                return [
                    "real estate", "construction", "commercial property", "homebuilders", "housing market",
                    "developers", "residential property", "office space", "mortgage rates", "contractors",
                    "building materials",
                ]
            case .defenseAndAerospace:
                return [
                    "defense", "aerospace", "defense contractor", "defense contractors", "military spending",
                    "weapons maker", "weapons makers", "missile maker", "missile makers", "fighter jet", "fighter jets",
                    "defense budget",
                    "lockheed", "raytheon", "northrop", "general dynamics", "boeing defense", "pentagon contract",
                    "airbus defense",
                ]
            }
        }
    }

    /// Practical business and operational implication keywords.
    private static let implicationCues: [String] = [
        // Costs & Prices
        "cost", "costs", "price", "prices", "pricing", "tariff", "tariffs", "fee", "fees", "margin", "margins",
        "expenses",
        // Supply
        "supply", "supplies", "shortage", "shortages", "inventory", "backlog", "logistics", "shipment", "shipments",
        "delivery", "deliveries", "supply chain", "bottleneck", "bottlenecks",
        // Demand
        "demand", "orders", "booking", "bookings", "cancellation", "cancellations", "slump",
        // Regulation
        "regulation", "regulations", "regulator", "regulators", "antitrust", "sanctions", "compliance",
        "trade restriction", "trade restrictions", "subsidy", "subsidies", "mandate",
        // Jobs. Single words such as "strike", "workers" or "union" also describe conflict and protest news,
        // so only unambiguous labor phrases count.
        "jobs", "layoff", "layoffs", "laid off", "job cut", "job cuts", "hiring", "labor strike", "labour strike",
        "walkout", "walkouts", "wages",
        // Operations. "operation", "flight", "plant" and "facility" alone are too ambiguous for the same reason.
        "production", "production halt", "production halts", "flight cancellations", "halt", "halts", "halted",
        "cancel", "cancels", "cancelled", "canceling", "plant closure", "plant closures", "shutdown", "shutdowns",
        "outage", "outages", "disruption", "disruptions", "grounded",
    ]

    /// Legal orders do not establish customer demand or a practical industry implication.
    private static let legalOrderCues: [String] = [
        "court order", "court orders", "restraining order", "restraining orders", "executive order", "executive orders",
    ]

    private static let multiWordRegexes: [String: NSRegularExpression] = {
        var dict: [String: NSRegularExpression] = [:]
        var allCues: [String] = implicationCues + legalOrderCues
        for industry in StandardIndustry.allCases {
            allCues.append(contentsOf: industry.cues)
        }
        for cue in allCues where cue.contains(" ") || cue.contains("-") {
            if dict[cue] == nil,
                let regex = try? NSRegularExpression(
                    pattern: "\\b\(NSRegularExpression.escapedPattern(for: cue))\\b",
                    options: [.caseInsensitive]
                )
            {
                dict[cue] = regex
            }
        }
        return dict
    }()

    struct ExtractedIndustryImpact: Sendable {
        let items: [OverviewIndustryImpact]
        let citations: [OverviewCitation]

        init(items: [OverviewIndustryImpact] = [], citations: [OverviewCitation] = []) {
            self.items = items
            self.citations = citations
        }
    }

    private struct CandidateMatch {
        let impact: OverviewIndustryImpact
        let citation: OverviewCitation
        let industry: StandardIndustry
    }

    private struct PassageContext {
        let passage: EvidencePassage
        let article: FeedArticle
        let sourceMeta: OverviewSourceMetadata
    }

    private struct ExtractionState {
        var results: [OverviewIndustryImpact] = []
        var citations: [OverviewCitation] = []
        var coveredIndustries = Set<StandardIndustry>()
    }

    /// Normalizes excluded sentences for exact matching and returns their nonempty alphanumeric word sets.
    private static func buildExclusions(
        from excludeSentences: Set<String>
    ) -> (strings: Set<String>, wordsList: [Set<String>]) {
        let excludeStrings = Set(
            excludeSentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let excludeWordsList = excludeStrings.compactMap { ex -> Set<String>? in
            let w = wordsSet(from: ex)
            return w.isEmpty ? nil : w
        }
        return (excludeStrings, excludeWordsList)
    }

    /// Indexes citations by passage ID, keeping the first encountered citation when a passage has several.
    private static func buildPassageCitationMap(
        from existingCitations: [String: OverviewCitation]
    ) -> [String: OverviewCitation] {
        var passageToCitation: [String: OverviewCitation] = [:]
        for citation in existingCitations.values where passageToCitation[citation.passageID] == nil {
            passageToCitation[citation.passageID] = citation
        }
        return passageToCitation
    }

    /// Returns a verified implication and its new sentence citation for an uncovered industry, or nil.
    /// `resultIndex` supplies the identifiers for the proposed item and citation.
    private static func evaluateCandidateSentence(
        _ sentence: String,
        context: PassageContext,
        coveredIndustries: Set<StandardIndustry>,
        resultIndex: Int
    ) -> CandidateMatch? {
        let lower = sentence.lowercased()
        let words = wordsSet(from: lower)
        guard let industry = identifyIndustry(for: lower, words: words),
            !coveredIndustries.contains(industry)
        else {
            return nil
        }

        let sentenceCitationID = "impact_cite_\(context.passage.id)_\(resultIndex)"
        let sentenceCitation = OverviewCitation(
            id: sentenceCitationID,
            articleID: context.passage.articleID,
            passageID: context.passage.id,
            passageFingerprint: context.passage.fingerprint,
            quote: sentence,
            source: context.sourceMeta
        )

        let candidateImpact = OverviewIndustryImpact(
            id: "impact_\(industry.rawValue.lowercased().filter(\.isLetter))_\(resultIndex)",
            industry: industry.rawValue,
            implication: sentence,
            citationIDs: [sentenceCitationID]
        )

        guard
            validateIndustryImpact(
                candidateImpact,
                citation: sentenceCitation,
                passage: context.passage,
                article: context.article
            )
        else {
            return nil
        }

        return CandidateMatch(impact: candidateImpact, citation: sentenceCitation, industry: industry)
    }

    /// Uses existing passage citation metadata when present, otherwise the matching article metadata.
    /// `citations` is keyed by passage ID.
    private static func sourceMetadata(
        for passage: EvidencePassage,
        article: FeedArticle,
        citations: [String: OverviewCitation]
    ) -> OverviewSourceMetadata {
        citations[passage.id]?.source
            ?? OverviewSourceMetadata(
                title: article.title,
                name: article.source,
                url: article.link,
                publishedAt: article.pubDate
            )
    }

    /// Appends eligible, verified sentences and their citations to `state`, stopping at four total items
    /// and keeping at most one item per industry across all processed passages.
    private static func processPassageSentences(
        context: PassageContext,
        exclusions: (strings: Set<String>, wordsList: [Set<String>]),
        state: inout ExtractionState
    ) {
        let sentences = extractCandidateSentences(from: context.passage.text)
        for sentence in sentences where state.results.count < 4 {
            guard
                isEligibleSentence(
                    sentence,
                    article: context.article,
                    excludeStrings: exclusions.strings,
                    excludeWordsList: exclusions.wordsList
                )
            else { continue }

            if let match = evaluateCandidateSentence(
                sentence,
                context: context,
                coveredIndustries: state.coveredIndustries,
                resultIndex: state.results.count + 1
            ) {
                state.results.append(match.impact)
                state.citations.append(match.citation)
                state.coveredIndustries.insert(match.industry)
            }
        }
    }

    /// Returns at most four verified implications, one per industry, in passage and sentence order,
    /// together with newly created sentence citations. Passages without a matching article are skipped;
    /// sentences must contain 8–60 whitespace-separated words and pass the eligibility and claim checks.
    ///
    /// - Parameters:
    ///   - passages: Evidence to search for stated implications.
    ///   - articles: Source articles; the first article wins when IDs repeat.
    ///   - existingCitations: Citations keyed by citation ID, used for source metadata when available.
    ///   - excludeSentences: Text to omit, including normalized exact matches and alphanumeric word-set
    ///     overlap (intersection over union) of at least 0.6.
    /// - Returns: Empty item and citation arrays when no candidate qualifies.
    static func extractIndustryImpact(
        passages: [EvidencePassage],
        articles: [FeedArticle],
        existingCitations: [String: OverviewCitation],
        excludeSentences: Set<String> = []
    ) -> ExtractedIndustryImpact {
        var state = ExtractionState()
        let articlesByID = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let exclusions = buildExclusions(from: excludeSentences)
        let passageToCitation = buildPassageCitationMap(from: existingCitations)

        for passage in passages where state.results.count < 4 {
            guard let article = articlesByID[passage.articleID] else { continue }
            let sourceMeta = sourceMetadata(for: passage, article: article, citations: passageToCitation)
            let context = PassageContext(passage: passage, article: article, sourceMeta: sourceMeta)
            processPassageSentences(context: context, exclusions: exclusions, state: &state)
        }

        return ExtractedIndustryImpact(items: state.results, citations: state.citations)
    }

    /// Returns trimmed sentences with 8–60 whitespace-separated words, inclusive, in source order.
    private static func extractCandidateSentences(from text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            let words = sentence.split(whereSeparator: \.isWhitespace)
            if words.count >= 8 && words.count <= 60 {
                sentences.append(sentence)
            }
        }
        return sentences
    }

    /// Splits on non-alphanumeric characters, discarding empty tokens and preserving case.
    private static func wordsSet(from text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// Matches a cue either via precompiled regex (for multi-word or hyphenated cues) or as a distinct word in the word set.
    private static func matchesCue(_ cue: String, in text: String, words: Set<String>) -> Bool {
        if let regex = multiWordRegexes[cue] {
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        } else {
            return words.contains(cue.lowercased())
        }
    }

    /// Checks business implication cues in lowercased text and its word set. Legal-order phrases are removed first,
    /// so "court orders" is not read as demand, while another cue in the same sentence ("halted production") counts.
    private static func hasImplication(text: String, words: Set<String>) -> Bool {
        guard legalOrderCues.contains(where: { matchesCue($0, in: text, words: words) }) else {
            return implicationCues.contains { matchesCue($0, in: text, words: words) }
        }
        var remaining = text
        for cue in legalOrderCues {
            if let regex = multiWordRegexes[cue] {
                remaining = regex.stringByReplacingMatches(
                    in: remaining, range: NSRange(remaining.startIndex..., in: remaining), withTemplate: " ")
            }
        }
        let remainingWords = wordsSet(from: remaining)
        return implicationCues.contains { matchesCue($0, in: remaining, words: remainingWords) }
    }

    /// Reports whether the article title or sentence contains one of the sports exclusion cues.
    private static func isSportsContent(article: FeedArticle, sentence: String) -> Bool {
        let text = "\(article.title) \(sentence)".lowercased()
        let words = wordsSet(from: text)
        let singleWordSports: Set<String> = [
            "championship", "tournament", "stadium", "fifa", "uefa", "nfl", "nba", "mlb", "nhl",
            "striker", "goalkeeper", "quarterback", "touchdown", "halftime", "playoff", "playoffs",
            "fixture", "fixtures", "ballpark", "innings", "athletic", "athletics", "matchday",
        ]
        if !words.isDisjoint(with: singleWordSports) {
            return true
        }
        let phrases = [
            "premier league", "world cup", "champions league", "super bowl", "penalty shootout", "final match",
        ]
        return phrases.contains(where: { text.contains($0) })
    }

    /// Requires an implication cue and rejects excluded text or text flagged as sports, a forecast,
    /// or investment advice.
    /// Exclusions use normalized strings and word sets; word-set overlap of at least 0.6 is a duplicate.
    private static func isEligibleSentence(
        _ sentence: String,
        article: FeedArticle,
        excludeStrings: Set<String>,
        excludeWordsList: [Set<String>]
    ) -> Bool {
        if isSportsContent(article: article, sentence: sentence) {
            return false
        }

        // Must not be a forecast or investment advice
        if OverviewThematicAngleValidator.isForecast(sentence)
            || OverviewThematicAngleValidator.isInvestmentAdvice(sentence)
        {
            return false
        }

        let lower = sentence.lowercased()
        if excludeStrings.contains(lower) {
            return false
        }

        let words = wordsSet(from: lower)
        guard hasImplication(text: lower, words: words) else { return false }
        guard !words.isEmpty else { return false }

        for excludedWords in excludeWordsList {
            let union = words.union(excludedWords).count
            if union > 0 {
                let overlap = Double(words.intersection(excludedWords).count) / Double(union)
                if overlap >= 0.6 {
                    return false
                }
            }
        }

        return true
    }

    /// Returns the first industry in taxonomy order whose cue matches the lowercased text and word set.
    private static func identifyIndustry(for text: String, words: Set<String>) -> StandardIndustry? {
        for industry in StandardIndustry.allCases {
            for cue in industry.cues where matchesCue(cue, in: text, words: words) {
                return industry
            }
        }
        return nil
    }

    /// Checks a nonblank implication with an exact standard industry name against every listed citation.
    /// Returns false for missing citations or passages, or any failed claim check. Missing articles use
    /// citation metadata as a fallback; duplicate passage and article IDs use the first entry.
    static func validateIndustryImpact(
        _ impact: OverviewIndustryImpact,
        against citations: [String: OverviewCitation],
        passages: [EvidencePassage],
        articles: [FeedArticle]
    ) -> Bool {
        guard !impact.citationIDs.isEmpty else { return false }
        guard !impact.implication.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard StandardIndustry.allCases.contains(where: { $0.rawValue == impact.industry }) else { return false }

        let passagesByID = Dictionary(passages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let articlesByID = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for citID in impact.citationIDs {
            guard let citation = citations[citID] else { return false }
            guard let passage = passagesByID[citation.passageID] else { return false }
            let article =
                articlesByID[citation.articleID]
                ?? FeedArticle(
                    storedID: citation.articleID, title: citation.sourceTitle ?? "Article",
                    link: citation.sourceURL ?? "", guid: citation.articleID, description: "",
                    pubDate: citation.publishedAt ?? Date(), source: citation.sourceName ?? "Source"
                )
            if !validateIndustryImpact(impact, citation: citation, passage: passage, article: article) {
                return false
            }
        }
        return true
    }

    /// Returns whether the implication passes the overview claim verifier for this citation and passage.
    private static func validateIndustryImpact(
        _ impact: OverviewIndustryImpact,
        citation: OverviewCitation,
        passage: EvidencePassage,
        article: FeedArticle
    ) -> Bool {
        let fact = OverviewFact(id: impact.id, text: impact.implication, citationIDs: [citation.id])
        let checkDoc = EventOverviewDocument(
            eventID: "impact_check",
            version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "check_hash"),
            content: OverviewContent(
                title: "Impact Check",
                summary: "",
                facts: [fact],
                citations: [citation]
            ),
            provenance: OverviewProvenance(memberArticleIDs: [article.id])
        )
        let report = OverviewClaimVerifier.verifyOverview(checkDoc, passages: [passage], articles: [article])
        return report.isFullyVerified
    }
}
