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

// Angelia · Eris (World Tension) owns this file. Register: docs/ANGELIA.md.

import Foundation

// News tension (experiment, #99). The normative text is docs/methodology/tension-index-v1.md; change it and this file
// together and bump `TensionMethodology.version`. Weights and smoothing come from calibration (#158); `TensionHistory`
// feeds the separate view (#159). The rest of the app does not depend on it.

// MARK: - Methodology

/// World regions of panel publishers. A region without a panel member is a stated gap of that methodology version.
enum TensionMacroRegion: String, CaseIterable, Codable, Sendable {
    case europe, northAmerica, latinAmerica, middleEastNorthAfrica, subSaharanAfrica, southAsia, eastSoutheastAsia,
        oceania
}

/// A fixed panel feed, recorded as the catalog verified it. A changed catalog entry is a methodology change.
struct TensionPanelMember: Equatable, Sendable {
    /// The feed's id in the bundled catalog.
    let catalogID: String
    /// The feed URL; stored articles are matched to the panel by it.
    let url: String
    /// The publisher's world region.
    let region: TensionMacroRegion
}

/// Which panel feeds delivered dated items on an observation day.
struct TensionCoverage: Equatable, Sendable {
    /// Whether a day can be assessed.
    enum Status: String, Sendable {
        /// No panel feed delivered an item that day: a gap, never zero.
        case noData
        /// Too few panel feeds or regions reported for a comparable day.
        case insufficient
        /// Enough panel feeds from enough regions reported for the day to be assessed.
        case sufficient
    }

    /// The panel feeds that delivered dated items that day.
    let reporting: [TensionPanelMember]
    /// The regions of those feeds.
    let regions: Set<TensionMacroRegion>
    /// Whether the day can be assessed.
    let status: Status
}

/// The indicator describes what a fixed panel of international news feeds reported about unique events. It is not a
/// measure of danger, risk or the state of the world.
struct TensionMethodology: Equatable, Sendable {
    /// The methodology version; scores of different versions are not comparable.
    let version: Int
    /// Language of the panel and of the classification cues.
    let language: String
    /// The fixed panel feeds.
    let panel: [TensionPanelMember]
    /// A day is assessed only when more than half of the panel feeds, from more than half of the panel's regions,
    /// delivered dated items published that day.
    let minimumReportingFeeds: Int
    /// See `minimumReportingFeeds`.
    let minimumReportingRegions: Int
    /// Late feed items and event clustering can still change a day until this long after it ends.
    let provisionalPeriod: TimeInterval

    /// The sentence shown with every reading: what the indicator measures and what it does not.
    static let disclaimer =
        "News tension describes what a fixed panel of international news feeds reported, not how dangerous the world is. It depends on which outlets are in the panel, what they chose to cover and the language they publish in."

    /// The first methodology: twelve English panel feeds, seven feeds from four regions for a comparable day, and a
    /// 24-hour provisional period.
    static let v1 = TensionMethodology(
        version: 1,
        language: "en",
        panel: [
            TensionPanelMember(
                catalogID: "bbc-world", url: "https://feeds.bbci.co.uk/news/world/rss.xml", region: .europe),
            TensionPanelMember(
                catalogID: "guardian-world", url: "https://www.theguardian.com/world/rss", region: .europe),
            TensionPanelMember(catalogID: "dw-english", url: "https://rss.dw.com/xml/rss-en-top", region: .europe),
            TensionPanelMember(catalogID: "france-24", url: "https://www.france24.com/en/rss", region: .europe),
            TensionPanelMember(
                catalogID: "euronews", url: "https://www.euronews.com/rss?level=theme&name=news", region: .europe),
            TensionPanelMember(
                catalogID: "cbc-world", url: "https://www.cbc.ca/webfeed/rss/rss-world", region: .northAmerica),
            TensionPanelMember(
                catalogID: "al-jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml",
                region: .middleEastNorthAfrica),
            TensionPanelMember(
                catalogID: "arab-news", url: "https://www.arabnews.com/rss.xml", region: .middleEastNorthAfrica),
            TensionPanelMember(
                catalogID: "the-hindu", url: "https://www.thehindu.com/news/international/feeder/default.rss",
                region: .southAsia),
            TensionPanelMember(catalogID: "dawn", url: "https://www.dawn.com/feeds/home", region: .southAsia),
            TensionPanelMember(
                catalogID: "cna", url: "https://www.channelnewsasia.com/rssfeeds/8395884", region: .eastSoutheastAsia),
            TensionPanelMember(
                catalogID: "africanews", url: "https://www.africanews.com/feed/rss", region: .subSaharanAfrica),
        ],
        minimumReportingFeeds: 7,
        minimumReportingRegions: 4,
        provisionalPeriod: 24 * 60 * 60
    )

    /// The regions the panel covers.
    var panelRegions: Set<TensionMacroRegion> { Set(panel.map(\.region)) }

    /// The panel member with this feed URL; nil for a feed outside the panel.
    func member(feedURL: String) -> TensionPanelMember? {
        panel.first { $0.url == feedURL }
    }

    /// Observation days are UTC calendar days, so a day means the same span for every reader.
    static func day(containing date: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 24 * 60 * 60)
    }

    /// Whether the day can still change: `now` is within `provisionalPeriod` after the day ends.
    func isProvisional(_ day: DateInterval, now: Date) -> Bool {
        now < day.end.addingTimeInterval(provisionalPeriod)
    }

    /// The day's coverage from the feeds that reported: `noData` with none, `sufficient` from `minimumReportingFeeds`
    /// feeds in `minimumReportingRegions` regions, `insufficient` otherwise.
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
    /// No figure, then 1–9, 10–99, 100–999 and 1,000 or more.
    case notReported, units, tens, hundreds, thousands

    /// The magnitude of a count; zero or less is `notReported`.
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
    /// No cue, escalation cues only, de-escalation cues only, or both.
    case noSignal, escalating, deescalating, mixed
}

/// One unique event's classification, with the facts behind each finding so explanations can cite them.
struct TensionEventClassification: Equatable, Sendable {
    /// The methodology that produced the classification.
    let methodologyVersion: Int
    /// Nil when no fact carries a cue of any counted type.
    let type: TensionEventType?
    /// Ids of the facts that carry a cue of `type`.
    let typeEvidence: [String]
    /// The magnitude of the largest death figure any fact reports.
    let deaths: TensionMagnitude
    /// The magnitude of the largest figure of people injured, displaced, evacuated or missing.
    let affected: TensionMagnitude
    /// Ids of the facts that report a death or harm figure.
    let magnitudeEvidence: [String]
    /// Escalation as the facts state it.
    let escalation: TensionEscalation
    /// Ids of the facts with an escalation or de-escalation cue, escalating ones first.
    let escalationEvidence: [String]
    /// Facts classified.
    let factCount: Int
}

/// Deterministic classification from passage-anchored facts. Only each fact's verbatim publisher quote is read, never a
/// model's restatement, a headline or a generated overview. Cues are English words and phrases matched as whole words;
/// a cue right after a negation ("no", "denied", "rejected"…) does not count.
enum TensionEventClassifier {
    /// Whole-word cues per event type; a cue right after a negation does not count.
    static let typeCues: [TensionEventType: [String]] = [
        .armedConflict: [
            "airstrike", "airstrikes", "air strike", "air strikes", "missile strike", "missile strikes", "drone strike",
            "drone strikes", "drone attack", "drone attacks", "shelling", "shelled", "artillery", "bombardment",
            "offensive", "invasion", "invaded", "troops", "front line", "frontline", "fighting", "military operation",
            "ceasefire", "cease fire", "insurgents",
        ],
        .terrorism: [
            "terrorist", "terrorists", "terrorism", "terror attack", "suicide bomber", "suicide bombing", "car bomb",
            "gunman", "gunmen", "mass shooting", "hostage", "hostages", "kidnapped", "abducted", "explosive device",
        ],
        .civilUnrest: [
            "protest", "protests", "protesters", "protestors", "demonstrators", "riot", "riots", "rioting", "unrest",
            "curfew", "tear gas", "crackdown", "coup", "uprising", "martial law",
        ],
        .coercion: [
            "sanctions", "embargo", "blockade", "ultimatum", "mobilization", "mobilisation", "military drills",
            "nuclear test", "missile test", "ballistic missile", "expelled diplomats", "troop buildup",
        ],
        .disaster: [
            "earthquake", "tsunami", "hurricane", "typhoon", "cyclone", "flood", "floods", "flooding", "wildfire",
            "wildfires", "landslide", "eruption", "drought", "heatwave", "heat wave", "famine", "derailment",
        ],
        .healthEmergency: [
            "outbreak", "epidemic", "pandemic", "cholera", "ebola", "mpox", "public health emergency",
        ],
        .cyberAttack: [
            "cyberattack", "cyberattacks", "cyber attack", "cyber attacks", "ransomware", "data breach", "ddos",
        ],
    ]

    /// Cues of explicit escalation.
    static let escalatingCues = [
        "escalate", "escalated", "escalates", "escalating", "escalation", "intensified", "intensifies", "intensifying",
        "stepped up", "new offensive", "launched an offensive", "renewed fighting", "renewed attacks", "declared war",
        "retaliated", "retaliatory", "mobilized", "mobilised", "deployed additional", "state of emergency",
    ]

    /// Cues of explicit de-escalation; a reversal right after one ("ceasefire collapsed") cancels it.
    static let deescalatingCues = [
        "ceasefire", "cease fire", "truce", "armistice", "peace talks", "peace deal", "peace agreement",
        "de escalation",
        "de escalate", "deescalation", "withdrew", "withdrawal", "pulled back", "prisoner exchange", "prisoner swap",
        "released hostages", "hostages were released", "lifted the curfew", "lifted sanctions", "resumed talks",
    ]

    /// Words up to three places before a cue that cancel it.
    static let negations: Set<String> = [
        "no", "not", "never", "without", "rejected", "rejects", "refused", "refuses", "denied", "denies", "ruled",
    ]
    /// Words up to three places after a de-escalation cue that cancel it ("ceasefire collapsed").
    static let reversals: Set<String> = [
        "collapsed", "collapses", "failed", "fails", "broke", "violated", "ended", "stalled", "faltered",
    ]

    /// Classifies one event from its facts: the type with the most supporting facts (ties go to declaration order), the
    /// largest reported figures and the escalation cues.
    static func classify(_ facts: [PassageAnchoredFact], methodology: TensionMethodology = .v1)
        -> TensionEventClassification
    {
        var support: [TensionEventType: [String]] = [:]
        var deaths = 0
        var affected = 0
        var magnitudeEvidence: [String] = []
        var escalating: [String] = []
        var deescalating: [String] = []
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
        for candidate in TensionEventType.allCases
        where (support[candidate]?.count ?? 0) > (type.flatMap { support[$0]?.count } ?? 0) {
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

    /// Ordered words; `containsCue` reads negations and reversals by position.
    static func words(_ text: String) -> [String] {
        MuteRules.words(text).map(String.init)
    }

    /// Whether any cue occurs as whole words without a negation before it (or, for reversible cues, a reversal after).
    static func containsCue(_ words: [String], _ cues: [String], reversible: Bool = false) -> Bool {
        for cue in cues.map(Self.words) where !cue.isEmpty && cue.count <= words.count {
            for start in 0...(words.count - cue.count) where Array(words[start..<(start + cue.count)]) == cue {
                let end = start + cue.count
                if words[max(0, start - 3)..<start].contains(where: { negations.contains($0) }) { continue }
                if reversible && words[end..<min(words.count, end + 3)].contains(where: { reversals.contains($0) }) {
                    continue
                }
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
    /// The largest death figure in the quote; 0 when none.
    private(set) var deaths = 0
    /// The largest figure of people injured, displaced, evacuated, missing or otherwise harmed; 0 when none.
    private(set) var affected = 0

    private static let deathWords: Set<String> = ["killed", "dead", "died", "deaths", "fatalities", "killing", "kills"]
    private static let number = #"(?<n>\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)(?:\s+(?<m>thousand|million))?"#
    private static let auxiliary = #"(?:(?:were|was|have|has|had|are|is|been|being|now|reportedly)\s+){0,3}"#
    private static let harm =
        #"(?<h>killed|dead|died|deaths|fatalities|injured|wounded|hurt|displaced|evacuated|missing|hospitali[sz]ed|homeless)"#
    private static let person =
        #"(?:people|persons|civilians|soldiers|troops|children|residents|others|migrants|workers|passengers|fighters|militants|police|officers|protesters|demonstrators|villagers|patients|refugees|students|journalists|members|adults|women|men)"#
    private static let qualifier = #"(?:(?:at least|more than|over|about|around|nearly|almost|some|up to)\s+)?"#
    // Groups: n (number), m (thousand/million), h (harm word), q (quantity word). The toll pattern (3) has no h and
    // the quantity pattern (4) has only q and h.
    private static let patterns: [NSRegularExpression] = [
        #"\b\#(number)\s+(?:(?:more|other)\s+)?(?:[a-z]+\s+)?\#(person)\s+\#(auxiliary)\#(harm)\b"#,
        #"\b\#(number)\s+\#(auxiliary)\#(harm)\b"#,
        #"\b(?<h>killing|killed|kills|injuring|injured|wounding|wounded|displacing|displaced)\s+\#(qualifier)\#(number)\b"#,
        #"\b(?:death toll|toll)\b[^.;]{0,40}?\b(?:to|at|of|reached|hit|passed|surpassed|exceeded)\s+\#(qualifier)\#(number)\b"#,
        #"\b(?<q>dozens|scores|hundreds|thousands|millions)\s+(?:of\s+)?(?:[a-z]+\s+){0,2}?\#(auxiliary)\#(harm)\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let quantities = [
        "dozens": 24, "scores": 40, "hundreds": 200, "thousands": 2_000, "millions": 2_000_000,
    ]

    /// Reads the largest figures from a quote.
    init(_ quote: String) {
        let text = quote.lowercased()
        let range = NSRange(text.startIndex..., in: text)
        for (index, pattern) in Self.patterns.enumerated() {
            for match in pattern.matches(in: text, range: range) {
                func group(_ name: String) -> String? {
                    Range(match.range(withName: name), in: text).map { String(text[$0]) }
                }
                let count =
                    index == 4
                    ? group("q").flatMap { Self.quantities[$0] }
                    : group("n").flatMap { Self.figure($0, multiplier: group("m")) }
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
        if multiplier == nil, !digits.contains(","), !digits.contains("."), let year = Int(digits),
            (1900...2099).contains(year)
        {
            return nil
        }
        guard let value = Double(digits.replacingOccurrences(of: ",", with: "")) else { return nil }
        let factor: Double =
            switch multiplier {
            case "million"?: 1_000_000
            case "thousand"?: 1_000
            default: 1
            }
        let scaled = value * factor
        guard scaled.isFinite, scaled >= 1, scaled < 1e12 else { return nil }
        return Int(scaled)
    }
}

// MARK: - Daily assessment

/// A panel article as stored: the feed that delivered it and its event, if clustering grouped it.
struct TensionCorpusRow: Sendable {
    /// The stored article.
    let article: FeedArticle
    /// The panel feed that delivered it.
    let feedURL: String
    /// Its event; nil when clustering did not group it.
    let eventID: String?
}

/// One unique event on one observation day: its panel articles from that day and their classification.
struct TensionEventDay: Equatable, Sendable {
    /// The event ID, or the article ID of a story clustering did not group.
    let key: String
    /// The event's panel articles published that day.
    let articleIDs: [String]
    /// The panel feeds that carried them.
    let reporting: [TensionPanelMember]
    /// The event's classification from those articles' facts.
    let classification: TensionEventClassification
}

/// One observation day's coverage and classified events, before scoring.
struct TensionDayAssessment: Equatable, Sendable {
    /// The methodology the day was assessed under.
    let methodologyVersion: Int
    /// The UTC calendar day.
    let day: DateInterval
    /// Which panel feeds reported that day.
    let coverage: TensionCoverage
    /// Whether late items can still change the day.
    let isProvisional: Bool
    /// Unique events with panel coverage that day, in key order. Empty unless coverage is sufficient.
    let events: [TensionEventDay]
}

/// Turns the stored panel corpus of one day into a `TensionDayAssessment`.
enum TensionDayAssessor {
    /// Classifies a day's unique events from the stored panel corpus. Articles outside the day or the panel are
    /// ignored, each event counts once however many outlets reported it, and no score is computed. With
    /// `includingHeadlines`, each article's headline is read as a fact of its own beside the passages: the keyword
    /// estimate (#544) reads it because a feed teaser often carries the cue only in its headline; the history keeps
    /// to passages as the methodology documents.
    static func assess(
        day: DateInterval, rows: [TensionCorpusRow], now: Date, methodology: TensionMethodology = .v1,
        includingHeadlines: Bool = false
    ) -> TensionDayAssessment {
        let rows = rows.filter {
            methodology.member(feedURL: $0.feedURL) != nil && $0.article.pubDate >= day.start
                && $0.article.pubDate < day.end
        }
        let coverage = methodology.coverage(reportingFeedURLs: Set(rows.map(\.feedURL)))
        var events: [TensionEventDay] = []
        if coverage.status == .sufficient {
            let selector = OverviewPassageSelector()
            let groups = Dictionary(grouping: rows) { $0.eventID ?? $0.article.id }
            for key in groups.keys.sorted() {
                let members = groups[key] ?? []
                var articles: [FeedArticle] = []
                for row in members where !articles.contains(where: { $0.id == row.article.id }) {
                    articles.append(row.article)
                }
                articles.sort { $0.id < $1.id }
                let passages = articles.flatMap { selector.extractRankedPassages(from: $0) }
                let headlines =
                    includingHeadlines
                    ? articles.map {
                        PassageAnchoredFact(
                            id: "headline:" + $0.id, statement: $0.title, passageID: "headline", quote: $0.title,
                            articleID: $0.id)
                    } : []
                let facts = headlines + PassageFactExtractor.deterministicExtract(passages: passages)
                let reporting = methodology.panel.filter { member in members.contains { $0.feedURL == member.url } }
                events.append(
                    TensionEventDay(
                        key: key, articleIDs: articles.map(\.id), reporting: reporting,
                        classification: TensionEventClassifier.classify(facts, methodology: methodology)))
            }
        }
        return TensionDayAssessment(
            methodologyVersion: methodology.version, day: day, coverage: coverage,
            isProvisional: methodology.isProvisional(day, now: now), events: events)
    }
}

// MARK: - Calibration and Scoring (#158)

/// Calibrated weights and parameters derived from the historical sample corpus (Issue #158).
struct TensionWeights: Equatable, Codable, Sendable {
    /// Base weight per event type.
    let typeWeights: [TensionEventType: Double]
    /// Multiplier per death magnitude.
    let deathMultipliers: [TensionMagnitude: Double]
    /// Multiplier per affected magnitude.
    let affectedMultipliers: [TensionMagnitude: Double]
    /// Multiplier per escalation signal.
    let escalationMultipliers: [TensionEscalation: Double]
    /// Multiplier by the number of panel regions that reported an event, 1 to 4 or more.
    let breadthMultipliers: [Int: Double]
    /// The raw score at which the index reaches about 63 of 100.
    let scaleFactor: Double
    /// The weight of the new day in the exponential smoothing of the index.
    let smoothingAlpha: Double

    /// The weights calibrated for methodology v1.
    static let calibratedV1 = TensionWeights(
        typeWeights: [
            .armedConflict: 10.0,
            .terrorism: 8.0,
            .disaster: 6.0,
            .civilUnrest: 4.0,
            .coercion: 4.0,
            .healthEmergency: 4.0,
            .cyberAttack: 3.0,
        ],
        deathMultipliers: [
            .notReported: 1.0,
            .units: 1.2,
            .tens: 1.5,
            .hundreds: 2.0,
            .thousands: 2.5,
        ],
        affectedMultipliers: [
            .notReported: 1.0,
            .units: 1.1,
            .tens: 1.25,
            .hundreds: 1.5,
            .thousands: 2.0,
        ],
        escalationMultipliers: [
            .noSignal: 1.0,
            .escalating: 1.3,
            .deescalating: 0.7,
            .mixed: 1.0,
        ],
        breadthMultipliers: [
            1: 0.85,
            2: 1.0,
            3: 1.15,
            4: 1.30,
        ],
        scaleFactor: 25.0,
        smoothingAlpha: 0.25
    )

    /// The larger of the death and affected multipliers; 1 for a magnitude without an entry.
    func magnitudeMultiplier(deaths: TensionMagnitude, affected: TensionMagnitude) -> Double {
        let dMult = deathMultipliers[deaths] ?? 1.0
        let aMult = affectedMultipliers[affected] ?? 1.0
        return max(dMult, aMult)
    }

    /// The multiplier for an event reported from this many panel regions; four or more share one value.
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
    /// The event key the score belongs to.
    let key: String
    /// Type weight times the magnitude, escalation and breadth multipliers; 0 for an event without a type.
    let rawScore: Double
    let typeWeight: Double
    let magnitudeMultiplier: Double
    let escalationMultiplier: Double
    let breadthMultiplier: Double

}

/// Scored evaluation of an observation day with raw, calibrated, and smoothed indices.
struct TensionDayScore: Equatable, Sendable {
    /// The UTC calendar day.
    let day: DateInterval
    /// The day's coverage; only a sufficient day is scored.
    let coverageStatus: TensionCoverage.Status
    /// Nil when coverage is insufficient or noData: gaps are never zero.
    let rawDailyScore: Double?
    /// Continuous index in [0, 100], or nil when coverage is insufficient.
    let calibratedIndex: Double?
    /// Trailing 7-day EMA smoothing, or nil when coverage is insufficient.
    let smoothedIndex: Double?
    /// Per-event scores; empty for an unscored day.
    let eventScores: [TensionEventScore]
    /// Whether late items can still change the day.
    let isProvisional: Bool

}

/// Scores assessed days with `TensionWeights`.
enum TensionCalibrator {
    /// The event's raw score and the factors behind it.
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
        let mMult = weights.magnitudeMultiplier(
            deaths: event.classification.deaths, affected: event.classification.affected)
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

    /// Scores a day: the sum of its event scores, scaled to 0 through 100 and smoothed with `previousSmoothedIndex`. A
    /// day without sufficient coverage gets nil scores.
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

    /// Scores the days in date order, smoothing each from the last scored day; gap days do not reset the smoothing.
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

// MARK: - History (#159)

/// One observation day as the tension view shows it: its score, coverage and the stories behind its largest
/// contributions. Gap days keep a nil index.
struct TensionHistoryDay: Sendable {
    /// The day's score.
    let score: TensionDayScore
    /// The day's coverage.
    let coverage: TensionCoverage
    /// Positive event contributions, largest first.
    let contributions: [TensionContribution]
}

/// An event's share of a day's score, with the headline of one of its panel stories and what the classifier found.
struct TensionContribution: Sendable {
    /// The event's score.
    let score: TensionEventScore
    /// The headline of one of the event's panel stories.
    let title: String
    /// What the classifier found for the event.
    var classification: TensionEventClassification?
    /// Panel feeds that reported the event that day.
    var reportingFeeds = 0
}

/// Builds the day-by-day history the tension view shows.
enum TensionHistory {
    /// Scores the most recent `days` UTC days from the stored panel corpus. The series starts at the first day any
    /// panel feed reported, so without a historical corpus it starts on the day collection began; later days without
    /// enough coverage stay in the series as gaps, never zeros.
    static func load(
        from database: DatabaseEngine, now: Date, days: Int = 30,
        methodology: TensionMethodology = .v1, weights: TensionWeights = .calibratedV1
    ) async throws -> [TensionHistoryDay] {
        let today = TensionMethodology.day(containing: now)
        var assessments: [TensionDayAssessment] = []
        var titles: [String: String] = [:]
        for offset in (0..<days).reversed() {
            try Task.checkCancellation()
            let start = today.start.addingTimeInterval(-Double(offset) * 24 * 60 * 60)
            let day = TensionMethodology.day(containing: start)
            let rows = try await database.tensionCorpus(day: day, feedURLs: methodology.panel.map(\.url))
            for row in rows { titles[row.article.id] = row.article.title }
            let assessment = TensionDayAssessor.assess(day: day, rows: rows, now: now, methodology: methodology)
            guard !assessments.isEmpty || assessment.coverage.status != .noData else { continue }
            assessments.append(assessment)
        }
        let scores = TensionCalibrator.scoreSeries(assessments: assessments, weights: weights)
        var history: [TensionHistoryDay] = []
        for (assessment, score) in zip(assessments, scores) {
            var events: [String: TensionEventDay] = [:]
            for event in assessment.events { events[event.key] = event }
            var contributions: [TensionContribution] = []
            for event in score.eventScores.sorted(by: { $0.rawScore > $1.rawScore }) where event.rawScore > 0 {
                let day = events[event.key]
                let title = (day?.articleIDs ?? []).lazy.compactMap { titles[$0] }.first ?? event.key
                contributions.append(
                    TensionContribution(
                        score: event, title: title, classification: day?.classification,
                        reportingFeeds: day?.reporting.count ?? 0))
            }
            history.append(TensionHistoryDay(score: score, coverage: assessment.coverage, contributions: contributions))
        }
        return history
    }
}

// MARK: - Presentation bands

/// Names for ranges of the 0–100 index, so a reading can say "44° Warm". Presentation only: the bands never feed
/// back into scoring, and they describe what the panel reported, not how dangerous the world is.
enum TensionLevel: String, CaseIterable, Sendable {
    case zen = "Zen"
    case mild = "Mild"
    case warm = "Warm"
    case hot = "Hot"
    case boiling = "Boiling"

    /// The band of an index: below 20 zen, below 40 mild, below 60 warm, below 80 hot, boiling from 80.
    init(index: Double) {
        switch index {
        case ..<20: self = .zen
        case ..<40: self = .mild
        case ..<60: self = .warm
        case ..<80: self = .hot
        default: self = .boiling
        }
    }

    /// The index rounded to whole degrees, as the reading shows it.
    static func degrees(_ index: Double) -> Int {
        Int(min(100, max(0, index)).rounded())
    }
}

// MARK: - Explanation (#159)

/// Everything a tension explanation may say: findings scoring already made, nothing else.
/// The displayed paragraph is assembled directly from these facts, without model-generated claims.
struct TensionBriefFacts: Hashable, Sendable {
    /// One event behind the reading, as the explanation names it.
    struct Driver: Hashable, Sendable {
        let headline: String
        let type: TensionEventType?
        let deaths: TensionMagnitude
        let affected: TensionMagnitude
        let escalation: TensionEscalation
        /// Panel feeds that reported the event.
        let reportingFeeds: Int
    }

    /// The start of the reading's UTC day.
    let day: Date
    /// The smoothed index in whole degrees.
    let degrees: Int
    /// The band of the reading.
    let level: TensionLevel
    /// Whole degrees since the previous scored day; nil when it is the first.
    let change: Int?
    /// Mean of the smoothed readings over the scored days of the history (`TensionHistory.load` covers 30 days by
    /// default); nil with fewer than three.
    let typicalDegrees: Int?
    /// Whether late items can still change the reading.
    let isProvisional: Bool
    /// Up to three events with the largest contributions.
    let drivers: [Driver]

    /// The latest reading of a history, with up to three drivers; nil when no day is scored.
    static func latest(in history: [TensionHistoryDay]) -> TensionBriefFacts? {
        let scored = history.filter { $0.score.smoothedIndex != nil }
        guard let day = scored.last, let index = day.score.smoothedIndex else { return nil }
        let degrees = TensionLevel.degrees(index)
        let previous = scored.dropLast().last?.score.smoothedIndex.map(TensionLevel.degrees)
        let readings = scored.compactMap(\.score.smoothedIndex)
        let typical = readings.count >= 3 ? TensionLevel.degrees(readings.reduce(0, +) / Double(readings.count)) : nil
        let drivers = day.contributions.prefix(3).map { contribution in
            Driver(
                headline: contribution.title, type: contribution.classification?.type,
                deaths: contribution.classification?.deaths ?? .notReported,
                affected: contribution.classification?.affected ?? .notReported,
                escalation: contribution.classification?.escalation ?? .noSignal,
                reportingFeeds: contribution.reportingFeeds)
        }
        return TensionBriefFacts(
            day: day.score.day.start, degrees: degrees, level: TensionLevel(index: index),
            change: previous.map { degrees - $0 }, typicalDegrees: typical, isProvisional: day.score.isProvisional,
            drivers: drivers)
    }

    // MARK: Plain-language parts

    /// The reading, its change from the previous day and its relation to the average, as one sentence.
    var readingSentence: String {
        var parts = ["News tension reads \(degrees)° (\(level.rawValue.lowercased()))"]
        if let change {
            parts.append(
                change == 0
                    ? "unchanged from the previous day"
                    : "\(change > 0 ? "up" : "down") \(abs(change))° from the previous day")
        }
        if let typicalDegrees {
            let gap = degrees - typicalDegrees
            parts.append(
                abs(gap) <= 3
                    ? "close to its 30-day average of \(typicalDegrees)°"
                    : "\(gap > 0 ? "above" : "below") its 30-day average of \(typicalDegrees)°")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// The event type in plain words; "a reported incident" without a type.
    static func typePhrase(_ type: TensionEventType?) -> String {
        switch type {
        case .armedConflict: return "armed conflict"
        case .terrorism: return "terrorism"
        case .civilUnrest: return "civil unrest"
        case .coercion: return "military or economic pressure"
        case .disaster: return "a disaster"
        case .healthEmergency: return "a health emergency"
        case .cyberAttack: return "a cyberattack"
        case nil: return "a reported incident"
        }
    }

    /// "dozens of deaths reported": the order of magnitude the classifier recorded, never an exact figure.
    static func magnitudePhrase(_ magnitude: TensionMagnitude, _ noun: String) -> String? {
        switch magnitude {
        case .notReported: return nil
        case .units: return "fewer than ten \(noun)"
        case .tens: return "dozens of \(noun)"
        case .hundreds: return "hundreds of \(noun)"
        case .thousands: return "thousands of \(noun)"
        }
    }

    /// The escalation signal in plain words; nil without a signal.
    static func escalationPhrase(_ escalation: TensionEscalation) -> String? {
        switch escalation {
        case .noSignal: return nil
        case .escalating: return "reports of escalation"
        case .deescalating: return "signs of de-escalation"
        case .mixed: return "mixed signs of escalation and de-escalation"
        }
    }

    /// One driver as a phrase: its type, reported harm and escalation.
    static func describe(_ driver: Driver) -> String {
        var details: [String] = []
        if let deaths = magnitudePhrase(driver.deaths, "deaths reported") { details.append(deaths) }
        if let affected = magnitudePhrase(driver.affected, "people reported hurt or displaced") {
            details.append(affected)
        }
        if let escalation = escalationPhrase(driver.escalation) { details.append(escalation) }
        let base = typePhrase(driver.type)
        return details.isEmpty ? base : "\(base) with \(details.joined(separator: " and "))"
    }

    /// The paragraph without a model: every clause comes from a scored finding.
    var deterministicParagraph: String {
        var sentences = [readingSentence]
        if let first = drivers.first {
            let feeds = first.reportingFeeds == 1 ? "1 panel feed" : "\(first.reportingFeeds) panel feeds"
            sentences.append(
                "The largest contribution is \(Self.describe(first)), covered by \(feeds): “\(first.headline)”.")
        }
        let others = drivers.dropFirst().map { "\(Self.describe($0)) (“\($0.headline)”)" }
        if !others.isEmpty {
            sentences.append("Also contributing: \(others.joined(separator: "; ")).")
        }
        if isProvisional {
            sentences.append("Today's reading is provisional and can still change.")
        }
        return sentences.joined(separator: " ")
    }
}
