import Foundation

// News tension (experiment, #99). The normative text is docs/methodology/tension-index-v1.md; change it and this file
// together and bump `TensionMethodology.version`. Nothing here produces a score: weights and smoothing come from
// calibration on a historical sample (#158), and the view (#159) is separate. The rest of the app does not depend on it.

// MARK: - Methodology

/// World regions of panel publishers. A region without a panel member is a stated gap of that methodology version.
enum TensionMacroRegion: String, CaseIterable, Codable, Sendable {
    case europe, northAmerica, latinAmerica, middleEastNorthAfrica, subSaharanAfrica, southAsia, eastSoutheastAsia, oceania
}

/// A fixed panel feed, recorded as the catalog verified it. A changed catalog entry is a methodology change.
struct TensionPanelMember: Equatable, Sendable {
    let catalogID: String
    let url: String
    let region: TensionMacroRegion
}

/// Which panel feeds delivered dated items on an observation day.
struct TensionCoverage: Equatable, Sendable {
    enum Status: String, Sendable {
        /// No panel feed delivered an item that day: a gap, never zero.
        case noData
        /// Too few panel feeds or regions reported for a comparable day.
        case insufficient
        case sufficient
    }

    let reporting: [TensionPanelMember]
    let regions: Set<TensionMacroRegion>
    let status: Status
}

/// The indicator describes what a fixed panel of international news feeds reported about unique events. It is not a
/// measure of danger, risk or the state of the world.
struct TensionMethodology: Equatable, Sendable {
    let version: Int
    /// Language of the panel and of the classification cues.
    let language: String
    let panel: [TensionPanelMember]
    /// A day is assessed only when more than half of the panel feeds, from more than half of the panel's regions,
    /// delivered dated items published that day.
    let minimumReportingFeeds: Int
    let minimumReportingRegions: Int
    /// Late feed items and event clustering can still change a day until this long after it ends.
    let provisionalPeriod: TimeInterval

    static let disclaimer = "News tension describes what a fixed panel of international news feeds reported, not how dangerous the world is. It depends on which outlets are in the panel, what they chose to cover and the language they publish in."

    static let v1 = TensionMethodology(
        version: 1,
        language: "en",
        panel: [
            TensionPanelMember(catalogID: "bbc-world", url: "https://feeds.bbci.co.uk/news/world/rss.xml", region: .europe),
            TensionPanelMember(catalogID: "guardian-world", url: "https://www.theguardian.com/world/rss", region: .europe),
            TensionPanelMember(catalogID: "dw-english", url: "https://rss.dw.com/xml/rss-en-top", region: .europe),
            TensionPanelMember(catalogID: "france-24", url: "https://www.france24.com/en/rss", region: .europe),
            TensionPanelMember(catalogID: "euronews", url: "https://www.euronews.com/rss?level=theme&name=news", region: .europe),
            TensionPanelMember(catalogID: "cbc-world", url: "https://www.cbc.ca/webfeed/rss/rss-world", region: .northAmerica),
            TensionPanelMember(catalogID: "al-jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml", region: .middleEastNorthAfrica),
            TensionPanelMember(catalogID: "arab-news", url: "https://www.arabnews.com/rss.xml", region: .middleEastNorthAfrica),
            TensionPanelMember(catalogID: "the-hindu", url: "https://www.thehindu.com/news/international/feeder/default.rss", region: .southAsia),
            TensionPanelMember(catalogID: "dawn", url: "https://www.dawn.com/feeds/home", region: .southAsia),
            TensionPanelMember(catalogID: "cna", url: "https://www.channelnewsasia.com/rssfeeds/8395884", region: .eastSoutheastAsia),
            TensionPanelMember(catalogID: "africanews", url: "https://www.africanews.com/feed/rss", region: .subSaharanAfrica)
        ],
        minimumReportingFeeds: 7,
        minimumReportingRegions: 4,
        provisionalPeriod: 24 * 60 * 60
    )

    var panelRegions: Set<TensionMacroRegion> { Set(panel.map(\.region)) }

    func member(feedURL: String) -> TensionPanelMember? {
        panel.first { $0.url == feedURL }
    }

    /// Observation days are UTC calendar days, so a day means the same span for every reader.
    static func day(containing date: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 24 * 60 * 60)
    }

    func isProvisional(_ day: DateInterval, now: Date) -> Bool {
        now < day.end.addingTimeInterval(provisionalPeriod)
    }

    func coverage(reportingFeedURLs: Set<String>) -> TensionCoverage {
        let reporting = panel.filter { reportingFeedURLs.contains($0.url) }
        let regions = Set(reporting.map(\.region))
        let status: TensionCoverage.Status
        if reporting.isEmpty {
            status = .noData
        } else if reporting.count >= minimumReportingFeeds && regions.count >= minimumReportingRegions {
            status = .sufficient
        } else {
            status = .insufficient
        }
        return TensionCoverage(reporting: reporting, regions: regions, status: status)
    }
}

// MARK: - Classification

/// Kinds of event the indicator counts. Declaration order breaks ties between equally supported types; it is not a
/// weighting.
enum TensionEventType: String, CaseIterable, Codable, Sendable {
    case armedConflict, terrorism, civilUnrest, coercion, disaster, healthEmergency, cyberAttack
}

/// Order of magnitude of the largest figure a fact reports.
enum TensionMagnitude: Int, CaseIterable, Comparable, Codable, Sendable {
    case notReported, units, tens, hundreds, thousands

    init(count: Int) {
        switch count {
        case ..<1: self = .notReported
        case 1..<10: self = .units
        case 10..<100: self = .tens
        case 100..<1000: self = .hundreds
        default: self = .thousands
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Escalation as the day's facts report it explicitly; nothing is inferred from changing figures.
enum TensionEscalation: String, Codable, Sendable {
    case noSignal, escalating, deescalating, mixed
}

/// One unique event's classification, with the facts behind each finding so explanations can cite them.
struct TensionEventClassification: Equatable, Sendable {
    let methodologyVersion: Int
    /// Nil when no fact carries a cue of any counted type.
    let type: TensionEventType?
    let typeEvidence: [String]
    let deaths: TensionMagnitude
    let affected: TensionMagnitude
    let magnitudeEvidence: [String]
    let escalation: TensionEscalation
    let escalationEvidence: [String]
    let factCount: Int
}

/// Deterministic classification from passage-anchored facts. Only each fact's verbatim publisher quote is read, never a
/// model's restatement, a headline or a generated overview. Cues are English words and phrases matched as whole words;
/// a cue right after a negation ("no", "denied", "rejected"…) does not count.
enum TensionEventClassifier {
    static let typeCues: [TensionEventType: [String]] = [
        .armedConflict: [
            "airstrike", "airstrikes", "air strike", "air strikes", "missile strike", "missile strikes", "drone strike",
            "drone strikes", "drone attack", "drone attacks", "shelling", "shelled", "artillery", "bombardment",
            "offensive", "invasion", "invaded", "troops", "front line", "frontline", "fighting", "military operation",
            "ceasefire", "cease fire", "insurgents"
        ],
        .terrorism: [
            "terrorist", "terrorists", "terrorism", "terror attack", "suicide bomber", "suicide bombing", "car bomb",
            "gunman", "gunmen", "mass shooting", "hostage", "hostages", "kidnapped", "abducted", "explosive device"
        ],
        .civilUnrest: [
            "protest", "protests", "protesters", "protestors", "demonstrators", "riot", "riots", "rioting", "unrest",
            "curfew", "tear gas", "crackdown", "coup", "uprising", "martial law"
        ],
        .coercion: [
            "sanctions", "embargo", "blockade", "ultimatum", "mobilization", "mobilisation", "military drills",
            "nuclear test", "missile test", "ballistic missile", "expelled diplomats", "troop buildup"
        ],
        .disaster: [
            "earthquake", "tsunami", "hurricane", "typhoon", "cyclone", "flood", "floods", "flooding", "wildfire",
            "wildfires", "landslide", "eruption", "drought", "heatwave", "heat wave", "famine", "derailment"
        ],
        .healthEmergency: [
            "outbreak", "epidemic", "pandemic", "cholera", "ebola", "mpox", "public health emergency"
        ],
        .cyberAttack: [
            "cyberattack", "cyberattacks", "cyber attack", "cyber attacks", "ransomware", "data breach", "ddos"
        ]
    ]

    static let escalatingCues = [
        "escalate", "escalated", "escalates", "escalating", "escalation", "intensified", "intensifies", "intensifying",
        "stepped up", "new offensive", "launched an offensive", "renewed fighting", "renewed attacks", "declared war",
        "retaliated", "retaliatory", "mobilized", "mobilised", "deployed additional", "state of emergency"
    ]

    static let deescalatingCues = [
        "ceasefire", "cease fire", "truce", "armistice", "peace talks", "peace deal", "peace agreement", "de escalation",
        "de escalate", "deescalation", "withdrew", "withdrawal", "pulled back", "prisoner exchange", "prisoner swap",
        "released hostages", "hostages were released", "lifted the curfew", "lifted sanctions", "resumed talks"
    ]

    /// Words up to three places before a cue that cancel it.
    static let negations: Set<String> = ["no", "not", "never", "without", "rejected", "rejects", "refused", "refuses", "denied", "denies", "ruled"]
    /// Words up to three places after a de-escalation cue that cancel it ("ceasefire collapsed").
    static let reversals: Set<String> = ["collapsed", "collapses", "failed", "fails", "broke", "violated", "ended", "stalled", "faltered"]

    static func classify(_ facts: [PassageAnchoredFact], methodology: TensionMethodology = .v1) -> TensionEventClassification {
        var support: [TensionEventType: [String]] = [:]
        var deaths = 0, affected = 0
        var magnitudeEvidence: [String] = [], escalating: [String] = [], deescalating: [String] = []
        for fact in facts {
            let words = Self.words(fact.quote)
            for kind in TensionEventType.allCases where containsCue(words, typeCues[kind] ?? []) {
                support[kind, default: []].append(fact.id)
            }
            let figures = TensionFigures(fact.quote)
            if figures.deaths > 0 || figures.affected > 0 { magnitudeEvidence.append(fact.id) }
            deaths = max(deaths, figures.deaths)
            affected = max(affected, figures.affected)
            if containsCue(words, escalatingCues) { escalating.append(fact.id) }
            if containsCue(words, deescalatingCues, reversible: true) { deescalating.append(fact.id) }
        }
        var type: TensionEventType?
        for candidate in TensionEventType.allCases where (support[candidate]?.count ?? 0) > (type.flatMap { support[$0]?.count } ?? 0) {
            type = candidate
        }
        let escalation: TensionEscalation
        switch (escalating.isEmpty, deescalating.isEmpty) {
        case (true, true): escalation = .noSignal
        case (false, true): escalation = .escalating
        case (true, false): escalation = .deescalating
        case (false, false): escalation = .mixed
        }
        return TensionEventClassification(
            methodologyVersion: methodology.version,
            type: type,
            typeEvidence: type.flatMap { support[$0] } ?? [],
            deaths: TensionMagnitude(count: deaths),
            affected: TensionMagnitude(count: affected),
            magnitudeEvidence: magnitudeEvidence,
            escalation: escalation,
            escalationEvidence: escalating + deescalating.filter { !escalating.contains($0) },
            factCount: facts.count
        )
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Whether any cue occurs as whole words without a negation before it (or, for reversible cues, a reversal after).
    static func containsCue(_ words: [String], _ cues: [String], reversible: Bool = false) -> Bool {
        for cue in cues.map(Self.words) where !cue.isEmpty && cue.count <= words.count {
            for start in 0...(words.count - cue.count) where Array(words[start..<(start + cue.count)]) == cue {
                let end = start + cue.count
                if words[max(0, start - 3)..<start].contains(where: { negations.contains($0) }) { continue }
                if reversible && words[end..<min(words.count, end + 3)].contains(where: { reversals.contains($0) }) { continue }
                return true
            }
        }
        return false
    }
}

/// The largest death and harm figures a quote reports, read from explicit numbers ("12 people were killed", "killing
/// at least 30", "the death toll rose to 1,200") and quantity words ("hundreds displaced"). Four-digit numbers from
/// 1900 to 2099 written without separators are read as years and skipped.
struct TensionFigures: Equatable, Sendable {
    private(set) var deaths = 0
    private(set) var affected = 0

    private static let deathWords: Set<String> = ["killed", "dead", "died", "deaths", "fatalities", "killing", "kills"]
    private static let number = #"(?<n>\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)(?:\s+(?<m>thousand|million))?"#
    private static let auxiliary = #"(?:(?:were|was|have|has|had|are|is|been|being|now|reportedly)\s+){0,3}"#
    private static let harm = #"(?<h>killed|dead|died|deaths|fatalities|injured|wounded|hurt|displaced|evacuated|missing|hospitali[sz]ed|homeless)"#
    private static let person = #"(?:people|persons|civilians|soldiers|troops|children|residents|others|migrants|workers|passengers|fighters|militants|police|officers|protesters|demonstrators|villagers|patients|refugees|students|journalists|members|adults|women|men)"#
    private static let qualifier = #"(?:(?:at least|more than|over|about|around|nearly|almost|some|up to)\s+)?"#
    // Groups: n (number), m (thousand/million), h (harm word), q (quantity word). The toll pattern (3) has no h and
    // the quantity pattern (4) has only q and h.
    private static let patterns: [NSRegularExpression] = [
        #"\b\#(number)\s+(?:(?:more|other)\s+)?(?:[a-z]+\s+)?\#(person)\s+\#(auxiliary)\#(harm)\b"#,
        #"\b\#(number)\s+\#(auxiliary)\#(harm)\b"#,
        #"\b(?<h>killing|killed|kills|injuring|injured|wounding|wounded|displacing|displaced)\s+\#(qualifier)\#(number)\b"#,
        #"\b(?:death toll|toll)\b[^.;]{0,40}?\b(?:to|at|of|reached|hit|passed|surpassed|exceeded)\s+\#(qualifier)\#(number)\b"#,
        #"\b(?<q>dozens|scores|hundreds|thousands|millions)\s+(?:of\s+)?(?:[a-z]+\s+){0,2}?\#(auxiliary)\#(harm)\b"#
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let quantities = ["dozens": 24, "scores": 40, "hundreds": 200, "thousands": 2_000, "millions": 2_000_000]

    init(_ quote: String) {
        let text = quote.lowercased()
        let range = NSRange(text.startIndex..., in: text)
        for (index, pattern) in Self.patterns.enumerated() {
            for match in pattern.matches(in: text, range: range) {
                func group(_ name: String) -> String? {
                    Range(match.range(withName: name), in: text).map { String(text[$0]) }
                }
                let count = index == 4 ? group("q").flatMap { Self.quantities[$0] } : group("n").flatMap { Self.figure($0, multiplier: group("m")) }
                guard let count else { continue }
                // The toll pattern has no harm word; a toll counts deaths.
                if index == 3 || group("h").map({ Self.deathWords.contains($0) }) == true {
                    deaths = max(deaths, count)
                } else {
                    affected = max(affected, count)
                }
            }
        }
    }

    private static func figure(_ digits: String, multiplier: String?) -> Int? {
        if multiplier == nil, !digits.contains(","), !digits.contains("."), let year = Int(digits), (1900...2099).contains(year) {
            return nil
        }
        guard let value = Double(digits.replacingOccurrences(of: ",", with: "")) else { return nil }
        let scaled = value * (multiplier == "million" ? 1_000_000 : multiplier == "thousand" ? 1_000 : 1)
        guard scaled.isFinite, scaled >= 1, scaled < 1e12 else { return nil }
        return Int(scaled)
    }
}

// MARK: - Daily assessment

/// A panel article as stored: the feed that delivered it and its event, if clustering grouped it.
struct TensionCorpusRow: Sendable {
    let article: FeedArticle
    let feedURL: String
    let eventID: String?
}

/// One unique event on one observation day: its panel articles from that day and their classification.
struct TensionEventDay: Equatable, Sendable {
    /// The event ID, or the article ID of a story clustering did not group.
    let key: String
    let articleIDs: [String]
    let reporting: [TensionPanelMember]
    let classification: TensionEventClassification
}

struct TensionDayAssessment: Equatable, Sendable {
    let methodologyVersion: Int
    let day: DateInterval
    let coverage: TensionCoverage
    let isProvisional: Bool
    /// Unique events with panel coverage that day, in key order. Empty unless coverage is sufficient.
    let events: [TensionEventDay]
}

enum TensionDayAssessor {
    /// Classifies a day's unique events from the stored panel corpus. Articles outside the day or the panel are
    /// ignored, each event counts once however many outlets reported it, and no score is computed.
    static func assess(day: DateInterval, rows: [TensionCorpusRow], now: Date, methodology: TensionMethodology = .v1) -> TensionDayAssessment {
        let rows = rows.filter { methodology.member(feedURL: $0.feedURL) != nil && $0.article.pubDate >= day.start && $0.article.pubDate < day.end }
        let coverage = methodology.coverage(reportingFeedURLs: Set(rows.map(\.feedURL)))
        var events: [TensionEventDay] = []
        if coverage.status == .sufficient {
            let selector = OverviewPassageSelector()
            let groups = Dictionary(grouping: rows) { $0.eventID ?? $0.article.id }
            for key in groups.keys.sorted() {
                let members = groups[key] ?? []
                var articles: [FeedArticle] = []
                for row in members where !articles.contains(where: { $0.id == row.article.id }) { articles.append(row.article) }
                articles.sort { $0.id < $1.id }
                let passages = articles.flatMap { selector.extractRankedPassages(from: $0) }
                let facts = PassageFactExtractor.deterministicExtract(passages: passages)
                let reporting = methodology.panel.filter { member in members.contains { $0.feedURL == member.url } }
                events.append(TensionEventDay(key: key, articleIDs: articles.map(\.id), reporting: reporting,
                                              classification: TensionEventClassifier.classify(facts, methodology: methodology)))
            }
        }
        return TensionDayAssessment(methodologyVersion: methodology.version, day: day, coverage: coverage,
                                    isProvisional: methodology.isProvisional(day, now: now), events: events)
    }
}

// MARK: - Calibration and Scoring (#158)

/// Calibrated weights and parameters derived from the historical sample corpus (Issue #158).
struct TensionWeights: Equatable, Codable, Sendable {
    let typeWeights: [TensionEventType: Double]
    let deathMultipliers: [TensionMagnitude: Double]
    let affectedMultipliers: [TensionMagnitude: Double]
    let escalationMultipliers: [TensionEscalation: Double]
    let breadthMultipliers: [Int: Double]
    let scaleFactor: Double
    let smoothingAlpha: Double

    init(
        typeWeights: [TensionEventType: Double],
        deathMultipliers: [TensionMagnitude: Double],
        affectedMultipliers: [TensionMagnitude: Double],
        escalationMultipliers: [TensionEscalation: Double],
        breadthMultipliers: [Int: Double],
        scaleFactor: Double,
        smoothingAlpha: Double
    ) {
        self.typeWeights = typeWeights
        self.deathMultipliers = deathMultipliers
        self.affectedMultipliers = affectedMultipliers
        self.escalationMultipliers = escalationMultipliers
        self.breadthMultipliers = breadthMultipliers
        self.scaleFactor = scaleFactor
        self.smoothingAlpha = smoothingAlpha
    }

    static let calibratedV1 = TensionWeights(
        typeWeights: [
            .armedConflict: 10.0,
            .terrorism: 8.0,
            .disaster: 6.0,
            .civilUnrest: 4.0,
            .coercion: 4.0,
            .healthEmergency: 4.0,
            .cyberAttack: 3.0
        ],
        deathMultipliers: [
            .notReported: 1.0,
            .units: 1.2,
            .tens: 1.5,
            .hundreds: 2.0,
            .thousands: 2.5
        ],
        affectedMultipliers: [
            .notReported: 1.0,
            .units: 1.1,
            .tens: 1.25,
            .hundreds: 1.5,
            .thousands: 2.0
        ],
        escalationMultipliers: [
            .noSignal: 1.0,
            .escalating: 1.3,
            .deescalating: 0.7,
            .mixed: 1.0
        ],
        breadthMultipliers: [
            1: 0.85,
            2: 1.0,
            3: 1.15,
            4: 1.30
        ],
        scaleFactor: 25.0,
        smoothingAlpha: 0.25
    )

    func magnitudeMultiplier(deaths: TensionMagnitude, affected: TensionMagnitude) -> Double {
        let dMult = deathMultipliers[deaths] ?? 1.0
        let aMult = affectedMultipliers[affected] ?? 1.0
        return max(dMult, aMult)
    }

    func breadthMultiplier(regionCount: Int) -> Double {
        if regionCount <= 1 { return breadthMultipliers[1] ?? 0.85 }
        if regionCount == 2 { return breadthMultipliers[2] ?? 1.0 }
        if regionCount == 3 { return breadthMultipliers[3] ?? 1.15 }
        return breadthMultipliers[4] ?? 1.30
    }

    /// Continuous monotonic scaling: maps raw event score sums into a 0...100 index.
    func scaleRawScore(_ raw: Double) -> Double {
        guard raw > 0 else { return 0.0 }
        let scaled = 100.0 * (1.0 - exp(-raw / scaleFactor))
        return min(100.0, max(0.0, scaled))
    }
}

/// Scoring breakdown for a single unique event on an observation day.
struct TensionEventScore: Equatable, Sendable {
    let key: String
    let rawScore: Double
    let typeWeight: Double
    let magnitudeMultiplier: Double
    let escalationMultiplier: Double
    let breadthMultiplier: Double

    init(
        key: String,
        rawScore: Double,
        typeWeight: Double,
        magnitudeMultiplier: Double,
        escalationMultiplier: Double,
        breadthMultiplier: Double
    ) {
        self.key = key
        self.rawScore = rawScore
        self.typeWeight = typeWeight
        self.magnitudeMultiplier = magnitudeMultiplier
        self.escalationMultiplier = escalationMultiplier
        self.breadthMultiplier = breadthMultiplier
    }
}

/// Scored evaluation of an observation day with raw, calibrated, and smoothed indices.
struct TensionDayScore: Equatable, Sendable {
    let day: DateInterval
    let coverageStatus: TensionCoverage.Status
    /// Nil when coverage is insufficient or noData: gaps are never zero.
    let rawDailyScore: Double?
    /// Continuous index in [0, 100], or nil when coverage is insufficient.
    let calibratedIndex: Double?
    /// Trailing 7-day EMA smoothing, or nil when coverage is insufficient.
    let smoothedIndex: Double?
    let eventScores: [TensionEventScore]
    let isProvisional: Bool

    init(
        day: DateInterval,
        coverageStatus: TensionCoverage.Status,
        rawDailyScore: Double?,
        calibratedIndex: Double?,
        smoothedIndex: Double?,
        eventScores: [TensionEventScore],
        isProvisional: Bool
    ) {
        self.day = day
        self.coverageStatus = coverageStatus
        self.rawDailyScore = rawDailyScore
        self.calibratedIndex = calibratedIndex
        self.smoothedIndex = smoothedIndex
        self.eventScores = eventScores
        self.isProvisional = isProvisional
    }
}

enum TensionCalibrator {
    static func scoreEvent(_ event: TensionEventDay, weights: TensionWeights = .calibratedV1) -> TensionEventScore {
        guard let type = event.classification.type else {
            return TensionEventScore(
                key: event.key,
                rawScore: 0.0,
                typeWeight: 0.0,
                magnitudeMultiplier: 1.0,
                escalationMultiplier: 1.0,
                breadthMultiplier: 1.0
            )
        }
        let tWeight = weights.typeWeights[type] ?? 0.0
        let mMult = weights.magnitudeMultiplier(deaths: event.classification.deaths, affected: event.classification.affected)
        let eMult = weights.escalationMultipliers[event.classification.escalation] ?? 1.0
        let regions = Set(event.reporting.map(\.region))
        let bMult = weights.breadthMultiplier(regionCount: regions.count)
        let raw = tWeight * mMult * eMult * bMult
        return TensionEventScore(
            key: event.key,
            rawScore: raw,
            typeWeight: tWeight,
            magnitudeMultiplier: mMult,
            escalationMultiplier: eMult,
            breadthMultiplier: bMult
        )
    }

    static func scoreDay(
        assessment: TensionDayAssessment,
        previousSmoothedIndex: Double? = nil,
        weights: TensionWeights = .calibratedV1
    ) -> TensionDayScore {
        guard assessment.coverage.status == .sufficient else {
            return TensionDayScore(
                day: assessment.day,
                coverageStatus: assessment.coverage.status,
                rawDailyScore: nil,
                calibratedIndex: nil,
                smoothedIndex: nil,
                eventScores: [],
                isProvisional: assessment.isProvisional
            )
        }

        let eventScores = assessment.events.map { scoreEvent($0, weights: weights) }
        let rawDaily = eventScores.reduce(0.0) { $0 + $1.rawScore }
        let calibrated = weights.scaleRawScore(rawDaily)

        let smoothed: Double
        if let prev = previousSmoothedIndex {
            smoothed = weights.smoothingAlpha * calibrated + (1.0 - weights.smoothingAlpha) * prev
        } else {
            smoothed = calibrated
        }

        return TensionDayScore(
            day: assessment.day,
            coverageStatus: assessment.coverage.status,
            rawDailyScore: rawDaily,
            calibratedIndex: calibrated,
            smoothedIndex: smoothed,
            eventScores: eventScores,
            isProvisional: assessment.isProvisional
        )
    }

    static func scoreSeries(
        assessments: [TensionDayAssessment],
        weights: TensionWeights = .calibratedV1
    ) -> [TensionDayScore] {
        var results: [TensionDayScore] = []
        var lastSmoothed: Double? = nil
        let sorted = assessments.sorted { $0.day.start < $1.day.start }
        for assessment in sorted {
            let dayScore = scoreDay(assessment: assessment, previousSmoothedIndex: lastSmoothed, weights: weights)
            if let s = dayScore.smoothedIndex {
                lastSmoothed = s
            }
            results.append(dayScore)
        }
        return results
    }
}

