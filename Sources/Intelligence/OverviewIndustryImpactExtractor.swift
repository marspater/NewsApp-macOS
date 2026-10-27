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
                    "pipeline", "pipelines", "power grid", "electricity", "renewable energy", "solar", "wind farm",
                    "wind farms", "nuclear power", "utility company", "utility companies",
                ]
            case .financialServices:
                return [
                    "banking", "bank", "banks", "lender", "lenders", "financial services", "credit", "mortgage",
                    "mortgages",
                    "wall street", "investment bank", "investment banks", "hedge fund", "hedge funds", "fintech",
                    "liquidity",
                    "capital requirements", "interest rate margin",
                ]
            case .healthcare:
                return [
                    "healthcare", "pharmaceutical", "pharmaceuticals", "pharma", "drugmaker", "drugmakers",
                    "drug", "drugs", "medical device", "medical devices", "biotech", "hospital", "hospitals",
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
                    "airports", "carrier", "carriers", "automaker", "automakers", "carmaker", "carmakers",
                    "auto industry", "automotive", "vehicle", "vehicles", "electric vehicles", "shipping", "freight",
                    "railroad", "railroads", "railway", "railways", "transit",
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
                    "aluminum", "heavy industry", "machinery", "chemical", "chemicals", "foundry", "smelter",
                    "production line", "raw materials",
                ]
            case .retailAndEcommerce:
                return [
                    "retail", "retailer", "retailers", "supermarket", "supermarkets", "e-commerce", "department stores",
                    "apparel", "consumer goods", "grocery", "merchandise", "shopping malls", "foot traffic", "store",
                    "stores",
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
                    "weapon", "weapons", "missile", "missiles", "fighter jet", "fighter jets", "defense budget",
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
                guard isEligibleSentence(sentence, article: article, excludeSentences: excludeSentences) else {
                    continue
                }
                let lower = sentence.lowercased()
                let words = wordsSet(from: lower)
                guard let industry = identifyIndustry(for: lower, words: words) else { continue }
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

    private static func wordsSet(from text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// Matches a cue either as a distinct word in the word set (single-word cue) or as a bounded phrase.
    private static func matchesCue(_ cue: String, in text: String, words: Set<String>) -> Bool {
        if cue.contains(" ") {
            guard
                let regex = try? NSRegularExpression(
                    pattern: "\\b\(NSRegularExpression.escapedPattern(for: cue))\\b",
                    options: [.caseInsensitive]
                )
            else {
                return false
            }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        } else {
            return words.contains(cue.lowercased())
        }
    }

    private static func hasImplication(text: String, words: Set<String>) -> Bool {
        for cue in implicationCues {
            if cue == "order" {
                if words.contains("order") {
                    let cleaned =
                        text
                        .replacingOccurrences(of: "in order to", with: " ")
                        .replacingOccurrences(of: "in order that", with: " ")
                        .replacingOccurrences(of: "in order for", with: " ")
                    let cleanedWords = wordsSet(from: cleaned)
                    if cleanedWords.contains("order") {
                        return true
                    }
                }
            } else if matchesCue(cue, in: text, words: words) {
                return true
            }
        }
        return false
    }

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
        for phrase in phrases {
            if text.contains(phrase) {
                return true
            }
        }
        return false
    }

    private static func isEligibleSentence(
        _ sentence: String,
        article: FeedArticle,
        excludeSentences: Set<String>
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
        let words = wordsSet(from: lower)
        guard hasImplication(text: lower, words: words) else { return false }

        guard !words.isEmpty else { return false }

        for excluded in excludeSentences {
            let excludedWords = wordsSet(from: excluded.lowercased())
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

    private static func identifyIndustry(for text: String, words: Set<String>) -> StandardIndustry? {
        for industry in StandardIndustry.allCases {
            for cue in industry.cues {
                if matchesCue(cue, in: text, words: words) {
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
