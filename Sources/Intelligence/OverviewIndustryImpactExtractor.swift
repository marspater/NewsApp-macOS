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
                    "energy", "utilities", "oil", "gas", "petroleum", "refinery", "refineries", "crude", "drilling",
                    "pipeline", "power grid", "electricity", "renewable energy", "solar", "wind farm", "nuclear power",
                    "utility company",
                ]
            case .financialServices:
                return [
                    "banking", "banks", "lender", "lenders", "financial services", "credit", "mortgage", "mortgages",
                    "wall street", "investment bank", "hedge fund", "fintech", "liquidity", "capital requirements",
                    "interest rate margin",
                ]
            case .healthcare:
                return [
                    "healthcare", "pharmaceutical", "pharmaceuticals", "pharma", "drugmaker", "drugmakers",
                    "medical device", "medical devices", "biotech", "hospital", "hospitals", "clinical",
                    "fda approval", "prescription drug", "vaccine", "vaccines",
                ]
            case .technology:
                return [
                    "technology", "tech sector", "semiconductor", "semiconductors", "chipmaker", "chipmakers",
                    "chips", "hardware", "software", "cloud computing", "cloud provider", "data centers",
                    "artificial intelligence", "cybersecurity",
                ]
            case .transportation:
                return [
                    "transportation", "airline", "airlines", "aircraft", "aviation", "flight", "flights", "airport",
                    "airports", "carrier", "carriers", "automaker", "automakers", "carmaker", "carmakers",
                    "auto industry", "automotive", "vehicles", "electric vehicles", "shipping", "freight", "railroad",
                    "railways", "transit",
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
                    "aluminum", "heavy industry", "machinery", "chemicals", "foundry", "smelter", "production line",
                    "raw materials",
                ]
            case .retailAndEcommerce:
                return [
                    "retail", "retailers", "supermarket", "supermarkets", "e-commerce", "department stores",
                    "apparel", "consumer goods", "grocery", "merchandise", "shopping malls", "foot traffic", "stores",
                ]
            case .mediaAndEntertainment:
                return [
                    "streaming", "broadcaster", "broadcasters", "television", "media industry", "cable provider",
                    "film", "movie", "studios", "hollywood", "box office", "entertainment", "music industry", "gaming",
                    "video games",
                ]
            case .telecommunications:
                return [
                    "telecom", "telecommunications", "wireless", "broadband", "mobile network", "cellular", "5g",
                    "spectrum",
                ]
            case .realEstate:
                return [
                    "real estate", "construction", "commercial property", "homebuilders", "housing market",
                    "developers", "residential property", "office space", "mortgage rates", "contractors",
                    "building materials",
                ]
            case .defenseAndAerospace:
                return [
                    "defense", "aerospace", "defense contractor", "military spending", "weapons", "missiles",
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
        "demand", "order", "orders", "booking", "bookings", "cancellation", "cancellations", "slump",
        // Regulation
        "regulation", "regulations", "regulator", "regulators", "antitrust", "sanctions", "compliance",
        "trade restriction", "trade restrictions", "subsidy", "subsidies", "mandate",
        // Jobs
        "job", "jobs", "layoff", "layoffs", "laid off", "job cut", "job cuts", "hiring", "strike", "strikes",
        "walkout", "walkouts", "labor", "workers", "union", "wages",
        // Operations
        "operation", "operations", "production", "flight", "flights", "halt", "halts", "halted", "cancel",
        "cancels", "cancelled", "canceling", "plant", "plants", "facility", "facilities", "shutdown", "shutdowns",
        "outage", "outages", "disruption", "disruptions", "grounded",
    ]

    struct ExtractedIndustryImpact: Sendable {
        let items: [OverviewIndustryImpact]
        let citations: [OverviewCitation]

        init(items: [OverviewIndustryImpact] = [], citations: [OverviewCitation] = []) {
            self.items = items
            self.citations = citations
        }
    }

    /// Extracts structured Industry Impact entries from evidence passages.
    static func extractIndustryImpact(
        passages: [EvidencePassage],
        articles: [FeedArticle],
        existingCitations: [String: OverviewCitation],
        excludeSentences: Set<String> = []
    ) -> ExtractedIndustryImpact {
        var results: [OverviewIndustryImpact] = []
        var impactCitations: [OverviewCitation] = []
        var coveredIndustries = Set<StandardIndustry>()
        let articlesByID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })

        // Build mapping from passage ID to citation
        var passageToCitation: [String: OverviewCitation] = [:]
        for citation in existingCitations.values {
            if passageToCitation[citation.passageID] == nil {
                passageToCitation[citation.passageID] = citation
            }
        }

        for passage in passages {
            guard let citation = passageToCitation[passage.id],
                let article = articlesByID[passage.articleID]
            else { continue }

            let sentences = extractCandidateSentences(from: passage.text)
            for sentence in sentences {
                guard isEligibleSentence(sentence, excludeSentences: excludeSentences) else { continue }
                guard let industry = identifyIndustry(for: sentence) else { continue }
                guard !coveredIndustries.contains(industry) else { continue }

                // Build a dedicated citation for this exact sentence to satisfy verbatim quote grounding
                let sentenceCitationID = "impact_cite_\(passage.id)_\(results.count + 1)"
                let sentenceCitation = OverviewCitation(
                    id: sentenceCitationID,
                    articleID: passage.articleID,
                    passageID: passage.id,
                    passageFingerprint: passage.fingerprint,
                    quote: sentence,
                    source: citation.source
                )

                let candidateImpact = OverviewIndustryImpact(
                    id: "impact_\(industry.rawValue.lowercased().filter(\.isLetter))_\(results.count + 1)",
                    industry: industry.rawValue,
                    implication: sentence,
                    citationIDs: [sentenceCitationID]
                )

                if validateIndustryImpact(
                    candidateImpact,
                    citation: sentenceCitation,
                    passage: passage,
                    article: article
                ) {
                    results.append(candidateImpact)
                    impactCitations.append(sentenceCitation)
                    coveredIndustries.insert(industry)
                    if results.count >= 4 { break }
                }
            }
            if results.count >= 4 { break }
        }

        return ExtractedIndustryImpact(items: results, citations: impactCitations)
    }

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

    private static func isEligibleSentence(_ sentence: String, excludeSentences: Set<String>) -> Bool {
        // Must not be a forecast or investment advice
        if OverviewThematicAngleValidator.isForecast(sentence)
            || OverviewThematicAngleValidator.isInvestmentAdvice(sentence)
        {
            return false
        }

        // Must match at least one practical implication cue
        let lower = sentence.lowercased()
        let hasImplication = implicationCues.contains { cue in
            lower.contains(cue)
        }
        guard hasImplication else { return false }

        // Must not overlap with introduction or highlight sentences
        let sentenceWords = Set(TensionEventClassifier.words(sentence))
        guard !sentenceWords.isEmpty else { return false }

        for excluded in excludeSentences {
            let excludedWords = Set(TensionEventClassifier.words(excluded))
            let union = sentenceWords.union(excludedWords).count
            if union > 0 {
                let overlap = Double(sentenceWords.intersection(excludedWords).count) / Double(union)
                if overlap >= 0.6 {
                    return false
                }
            }
        }

        return true
    }

    private static func identifyIndustry(for sentence: String) -> StandardIndustry? {
        let lower = sentence.lowercased()
        for industry in StandardIndustry.allCases {
            for cue in industry.cues {
                if lower.contains(cue) {
                    return industry
                }
            }
        }
        return nil
    }

    /// Verifies that an industry impact implication is valid and grounded in its cited passage.
    static func validateIndustryImpact(
        _ impact: OverviewIndustryImpact,
        against citations: [String: OverviewCitation],
        passages: [EvidencePassage],
        articles: [FeedArticle]
    ) -> Bool {
        guard !impact.citationIDs.isEmpty else { return false }
        guard !impact.implication.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard StandardIndustry.allCases.contains(where: { $0.rawValue == impact.industry }) else { return false }

        let passagesByID = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0) })
        let articlesByID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })

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
