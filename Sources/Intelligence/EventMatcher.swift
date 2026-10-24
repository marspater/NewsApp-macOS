import Foundation
import NaturalLanguage

/// Deterministic who/what/where/when signals for one article, taken from its title and the start of
/// its description. Nothing here is generated or stored; it is recomputed when matching.
struct EventFeatures: Hashable, Sendable {
    /// Dominant language when the recognizer is reasonably sure; nil otherwise.
    var language: String?
    // Who
    var people: Set<String> = []
    var organizations: Set<String> = []
    // Where
    var places: Set<String> = []
    /// Capitalized words inside a sentence that the tagger did not type: usually names it missed.
    var names: Set<String> = []
    // What
    var keywords: Set<String> = []
    // When, plus explicit facts that tell two similar reports apart
    var date: Date
    /// Headline figures that tell incidents apart (a magnitude, a count of things). Casualty tolls are kept apart in
    /// `tollNumbers`: they change as reports update, so they never distinguish two reports of one incident.
    var titleNumbers: Set<String> = []
    var tollNumbers: Set<String> = []
    var periods: Set<String> = []
    var years: Set<String> = []
    var weekdays: Set<String> = []
    /// Non-place headline terms from the primary clause when the headline has a trailing/leading background clause.
    var primaryTitleTerms: Set<String> = []

    var anchors: Set<String> { people.union(organizations).union(places).union(names) }
    /// Places that name a country, canonicalized to a region code (`@US`).
    var countries: Set<String> { places.filter { $0.hasPrefix("@") } }
    /// Cities, regions and other places below country level.
    var localPlaces: Set<String> { places.filter { !$0.hasPrefix("@") } }
    /// Names that point at one occurrence: people, organizations, local places and untyped names, not countries.
    var specificAnchors: Set<String> { anchors.subtracting(countries) }
}

/// Place names compared as places. Aliases and nationality adjectives resolve to one region code, and country names
/// come from the system's region list, so "U.S.", "American" and "United States" agree and "Spanish" means Spain.
enum EventPlaces {
    private static let aliases: [String: String] = [
        "us": "US", "u.s": "US", "usa": "US", "u.s.a": "US", "america": "US", "united states of america": "US",
        "uk": "GB", "u.k": "GB", "britain": "GB", "great britain": "GB", "england": "GB", "scotland": "GB",
        "wales": "GB",
        "uae": "AE", "emirates": "AE", "korea": "KR", "south korea": "KR", "north korea": "KP", "russia": "RU",
        "czech republic": "CZ", "holland": "NL", "ivory coast": "CI", "burma": "MM", "turkey": "TR", "palestine": "PS",
        "vatican": "VA", "taiwan": "TW", "syria": "SY", "iran": "IR", "laos": "LA", "vietnam": "VN", "congo": "CD",
    ]
    private static let demonyms: [String: String] = [
        "american": "US", "british": "GB", "english": "GB", "scottish": "GB", "welsh": "GB", "canadian": "CA",
        "mexican": "MX", "brazilian": "BR", "argentine": "AR", "argentinian": "AR", "chilean": "CL", "colombian": "CO",
        "venezuelan": "VE", "cuban": "CU", "peruvian": "PE", "haitian": "HT", "french": "FR", "german": "DE",
        "italian": "IT", "spanish": "ES", "portuguese": "PT", "dutch": "NL", "belgian": "BE", "swiss": "CH",
        "austrian": "AT", "swedish": "SE", "norwegian": "NO", "danish": "DK", "finnish": "FI", "irish": "IE",
        "polish": "PL", "czech": "CZ", "slovak": "SK", "hungarian": "HU", "romanian": "RO", "bulgarian": "BG",
        "greek": "GR", "turkish": "TR", "serbian": "RS", "croatian": "HR", "russian": "RU", "ukrainian": "UA",
        "belarusian": "BY", "georgian": "GE", "armenian": "AM", "azerbaijani": "AZ", "kazakh": "KZ", "chinese": "CN",
        "japanese": "JP", "south korean": "KR", "north korean": "KP", "taiwanese": "TW", "indian": "IN",
        "pakistani": "PK", "bangladeshi": "BD", "sri lankan": "LK", "nepali": "NP", "nepalese": "NP", "afghan": "AF",
        "iranian": "IR", "iraqi": "IQ", "syrian": "SY", "lebanese": "LB", "israeli": "IL", "palestinian": "PS",
        "jordanian": "JO", "saudi": "SA", "yemeni": "YE", "emirati": "AE", "qatari": "QA", "kuwaiti": "KW",
        "omani": "OM", "bahraini": "BH", "egyptian": "EG", "libyan": "LY", "tunisian": "TN", "algerian": "DZ",
        "moroccan": "MA", "sudanese": "SD", "ethiopian": "ET", "eritrean": "ER", "somali": "SO", "kenyan": "KE",
        "ugandan": "UG", "tanzanian": "TZ", "rwandan": "RW", "congolese": "CD", "nigerian": "NG", "ghanaian": "GH",
        "senegalese": "SN", "malian": "ML", "south african": "ZA", "zimbabwean": "ZW", "zambian": "ZM",
        "australian": "AU", "indonesian": "ID", "malaysian": "MY", "singaporean": "SG", "filipino": "PH",
        "philippine": "PH", "vietnamese": "VN", "thai": "TH", "burmese": "MM", "cambodian": "KH",
    ]
    /// English names of every ISO country, from the system's region list.
    private static let countryNames: [String: String] = {
        let english = Locale(identifier: "en_US")
        var names: [String: String] = [:]
        for region in Locale.Region.isoRegions
        where region.identifier.count == 2 && region.identifier.allSatisfy(\.isLetter) {
            guard let name = english.localizedString(forRegionCode: region.identifier) else { continue }
            names[EventFeatures.normalized(name)] = region.identifier
        }
        return names
    }()

    /// `@` plus the region code for a country, its alias or demonym; any other place unchanged.
    static func canonical(_ place: String) -> String {
        let name = EventFeatures.normalized(place)
        let singularDemonym = name.hasSuffix("s") ? demonyms[String(name.dropLast())] : nil
        guard let code = aliases[name] ?? demonyms[name] ?? singularDemonym ?? countryNames[name] else { return name }
        return "@" + code
    }
}

extension EventFeatures {
    static let descriptionPrefix = 600

    private static let weekdayNames: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]
    private static let monthNames: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november",
        "december",
    ]
    private static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "dozen": "12", "twenty": "20", "hundred": "100",
    ]
    /// News boilerplate and honorifics: frequent across unrelated stories, so they are not evidence.
    private static let stopwords: Set<String> = [
        "say", "said", "says", "tell", "told", "report", "reported", "reports", "according", "accord", "people",
        "person",
        "official", "officials", "news", "year", "years", "day", "days", "time", "times", "week", "weeks", "month",
        "months",
        "new", "update", "updates", "updated", "live", "late", "latest", "break", "breaking", "video", "photo",
        "photos",
        "watch", "read", "more", "make", "take", "get", "go", "come", "show", "include", "add", "be", "have", "do",
        "will", "can", "could", "would", "should", "also", "just", "today", "yesterday", "tomorrow", "morning",
        "evening",
        "night", "story", "stories", "article", "briefing", "newsletter", "podcast", "opinion", "analysis", "explainer",
        "the", "and", "for", "with", "from", "that", "this", "after", "over", "into", "about", "what", "how", "why",
        "when",
        "mr", "mrs", "ms", "dr", "sir", "president", "prime", "minister", "chancellor", "governor", "mayor", "king",
        "queen", "pope", "ceo", "chief", "spokesperson", "spokesman", "spokeswoman", "via", "per",
    ]
    /// Languages where capitalization does not mark proper nouns.
    private static let capitalizedNounLanguages: Set<String> = ["de", "lb"]
    private static let quarterPattern =
        (try? NSRegularExpression(
            pattern: #"\b(first|second|third|fourth|1st|2nd|3rd|4th)[\s-]+quarter\b"#, options: [.caseInsensitive]))
        ?? NSRegularExpression()
    private static let halfPattern =
        (try? NSRegularExpression(pattern: #"\b(first|second|1st|2nd)[\s-]+half\b"#, options: [.caseInsensitive]))
        ?? NSRegularExpression()
    private static let markupPattern = (try? NSRegularExpression(pattern: #"<[^>]*>"#)) ?? NSRegularExpression()
    private static let leadingBackgroundPattern =
        (try? NSRegularExpression(
            pattern:
                #"^\s*(?:(?:hours|days|weeks|months|moments|shortly|soon|just)\s+)?(?:after|following)\b[^,;:—–-]*[,;:—–-]\s*(.+)$"#,
            options: [.caseInsensitive])) ?? NSRegularExpression()
    private static let trailingBackgroundPattern =
        (try? NSRegularExpression(
            pattern:
                #"\b(?:following|in\s+(?:the\s+)?wake\s+of|(?:hours|days|weeks|months|moments|shortly|soon)\s+after|after)\b"#,
            options: [.caseInsensitive])) ?? NSRegularExpression()

    static func normalized(_ value: String) -> String {
        var text = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        for suffix in ["'s", "’s"] where text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
    }

    private static func plain(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return markupPattern.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The exact text the deterministic features and the sentence embedding both read: the plain headline and the
    /// first `descriptionPrefix` plain description characters. One definition keeps the two signals aligned.
    static func matchingText(title: String, description: String) -> String {
        let headline = plain(title).trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).joined(separator: " ")
        return headline + "\n" + String(plain(description).prefix(descriptionPrefix))
    }

    private static func primaryClauseRange(in text: String, titleEnd: String.Index) -> Range<String.Index>? {
        guard text.startIndex <= titleEnd, titleEnd <= text.endIndex else { return nil }
        let nsRange = NSRange(text.startIndex..<titleEnd, in: text)
        if let leading = leadingBackgroundPattern.firstMatch(in: text, range: nsRange),
            leading.range(at: 1).location != NSNotFound,
            let clause = Range(leading.range(at: 1), in: text)
        {
            return clause
        }
        guard let trailing = trailingBackgroundPattern.firstMatch(in: text, range: nsRange),
            trailing.range.location != NSNotFound,
            let connector = Range(trailing.range, in: text)
        else { return nil }
        let prefix = text[text.startIndex..<connector.lowerBound]
        return prefix.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count >= 2
            ? text.startIndex..<connector.lowerBound : nil
    }

    private struct FeatureCollector {
        let text: String
        let whole: Range<String.Index>
        let titleEnd: String.Index
        let primaryRange: Range<String.Index>?
        let titleCase: Bool
        let usesCapitalization: Bool
        var features: EventFeatures
        var nameTokens: Set<String> = []
        /// Words of typed person names: "Jordan" in "Michael Jordan" is never the country.
        var personTokens: Set<String> = []
        var lemmas: [String.Index: String] = [:]

        mutating func collectEntities(from tagger: NLTagger) {
            tagger.enumerateTags(
                in: whole, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]
            ) { tag, range in
                guard let tag else { return true }
                let name = EventFeatures.normalized(String(text[range]))
                guard name.count >= 2, name.contains(where: \.isLetter), !EventFeatures.stopwords.contains(name) else {
                    return true
                }
                if tag == .personalName {
                    features.people.insert(name)
                    if let surname = name.split(separator: " ").last, surname.count >= 3, String(surname) != name {
                        features.people.insert(String(surname))
                    }
                    let words = name.split(separator: " ").map(String.init)
                    nameTokens.formUnion(words)
                    personTokens.formUnion(words)
                } else if tag == .placeName || tag == .organizationName {
                    let canonicalPlace = EventPlaces.canonical(name)
                    if tag == .placeName || canonicalPlace.hasPrefix("@") { features.places.insert(canonicalPlace) }
                    if tag == .organizationName { features.organizations.insert(name) }
                    if !name.contains(" ") { nameTokens.insert(name) }
                }
                return true
            }
        }

        mutating func classifyNumberToken(_ word: String, token: String, inTitle: Bool, inPrimaryClause: Bool) {
            if token.first?.isUppercase == true, word.first?.isLetter == true {
                features.organizations.insert(word)
                return
            }
            let digits = word.filter { $0.isNumber || $0 == "." }.trimmingCharacters(
                in: CharacterSet(charactersIn: "."))
            if digits.count == 4, let year = Int(digits), (1900...2100).contains(year) {
                features.years.insert(digits)
            } else if inTitle, !digits.isEmpty {
                features.titleNumbers.insert(digits)
                if inPrimaryClause { features.primaryTitleTerms.insert(digits) }
            }
        }

        mutating func classifySpecialToken(
            _ word: inout String, token: String, range: Range<String.Index>
        ) -> Bool {
            let inTitle = range.lowerBound < titleEnd
            let inPrimaryClause = primaryRange.map { $0.overlaps(range) } ?? false
            if word.contains("-") {
                for part in word.split(separator: "-").map(String.init) where part.count >= 2 {
                    let canonicalPart = EventPlaces.canonical(part)
                    if canonicalPart.hasPrefix("@") { features.places.insert(canonicalPart) }
                }
                if word == "co-pilot" { word = "copilot" }
            }
            if ["q1", "q2", "q3", "q4", "h1", "h2"].contains(word) {
                features.periods.insert(word)
                return true
            }
            if word.contains(where: \.isNumber) {
                classifyNumberToken(word, token: token, inTitle: inTitle, inPrimaryClause: inPrimaryClause)
                return true
            }
            if EventFeatures.weekdayNames.contains(word) {
                features.weekdays.insert(word)
                return true
            }
            if inTitle, let number = EventFeatures.numberWords[word] {
                features.titleNumbers.insert(number)
                if inPrimaryClause { features.primaryTitleTerms.insert(number) }
                return true
            }
            let canonicalWordPlace = EventPlaces.canonical(word)
            if canonicalWordPlace.hasPrefix("@"), token.first?.isUppercase == true, !personTokens.contains(word) {
                features.places.insert(canonicalWordPlace)
                return true
            }
            return false
        }

        mutating func classifyLexicalTerm(_ word: String, token: String, tag: NLTag?, range: Range<String.Index>) {
            guard word.count >= 3, word.contains(where: \.isLetter), !EventFeatures.stopwords.contains(word),
                !EventFeatures.monthNames.contains(word), !EventFeatures.numberWords.keys.contains(word)
            else { return }
            let inTitle = range.lowerBound < titleEnd
            let inPrimaryClause = primaryRange.map { $0.overlaps(range) } ?? false
            let startsAtSentence = EventFeatures.startsSentence(range.lowerBound, in: text)
            let isUntypedInitialName = startsAtSentence && lemmas[range.lowerBound] == nil && !word.contains("-")
            if usesCapitalization, token.first?.isUppercase == true, !(inTitle && titleCase),
                !startsAtSentence || isUntypedInitialName
            {
                if !nameTokens.contains(word) { features.names.insert(word) }
                return
            }
            guard !nameTokens.contains(word) else { return }
            if let tag {
                guard [.noun, .verb, .adjective].contains(tag) else { return }
                let keyword = lemmas[range.lowerBound].flatMap { $0.isEmpty ? nil : $0 } ?? word
                if keyword.count >= 3, !EventFeatures.stopwords.contains(keyword) {
                    features.keywords.insert(keyword)
                    if inPrimaryClause { features.primaryTitleTerms.insert(keyword) }
                }
            } else if word.count >= 4 {
                features.keywords.insert(word)
                if inPrimaryClause { features.primaryTitleTerms.insert(word) }
            }
        }

        mutating func collectLexicalFeatures(from tagger: NLTagger) {
            let wordOptions: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
            tagger.enumerateTags(in: whole, unit: .word, scheme: .lemma, options: wordOptions) { tag, range in
                if let tag { lemmas[range.lowerBound] = EventFeatures.normalized(tag.rawValue) }
                return true
            }
            tagger.enumerateTags(in: whole, unit: .word, scheme: .lexicalClass, options: wordOptions) { tag, range in
                let token = String(text[range])
                var word = EventFeatures.normalized(token)
                guard !word.isEmpty, !classifySpecialToken(&word, token: token, range: range) else { return true }
                classifyLexicalTerm(word, token: token, tag: tag, range: range)
                return true
            }
            for name in features.names {
                let place = EventPlaces.canonical(name)
                if place.hasPrefix("@") {
                    features.names.remove(name)
                    features.places.insert(place)
                }
            }
        }
    }

    private static func collectPeriods(in text: String) -> Set<String> {
        var periods = Set<String>()
        let lowered = text.lowercased()
        let loweredRange = NSRange(lowered.startIndex..., in: lowered)
        let quarterMap = ["first": "q1", "1st": "q1", "second": "q2", "2nd": "q2", "third": "q3", "3rd": "q3"]
        for match in Self.quarterPattern.matches(in: lowered, range: loweredRange) {
            guard let range = Range(match.range(at: 1), in: lowered) else { continue }
            periods.insert(quarterMap[String(lowered[range])] ?? "q4")
        }
        for match in Self.halfPattern.matches(in: lowered, range: loweredRange) {
            guard let range = Range(match.range(at: 1), in: lowered) else { continue }
            periods.insert(["first", "1st"].contains(String(lowered[range])) ? "h1" : "h2")
        }
        return periods
    }

    /// Extracts features with on-device NaturalLanguage only. Results depend on the OS models for the
    /// language; when they are missing, the article simply has fewer signals and matches less.
    init(title rawTitle: String, description rawDescription: String, date: Date) {
        let text = Self.matchingText(title: rawTitle, description: rawDescription)
        let title = String(text.prefix { !$0.isNewline })
        let language = EventMatchKey.language(of: text)
        let whole = text.startIndex..<text.endIndex
        let titleEnd = text.index(text.startIndex, offsetBy: title.count, limitedBy: text.endIndex) ?? text.endIndex
        let titleWords = title.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 3 }
        let titleCase =
            !titleWords.isEmpty
            && Double(titleWords.filter { $0.first?.isUppercase == true }.count) / Double(titleWords.count) > 0.6
        let usesCapitalization = !(language.map(Self.capitalizedNounLanguages.contains) ?? false)

        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass, .lemma])
        tagger.string = text
        if let language { tagger.setLanguage(NLLanguage(rawValue: language), range: whole) }

        var collector = FeatureCollector(
            text: text, whole: whole, titleEnd: titleEnd,
            primaryRange: Self.primaryClauseRange(in: text, titleEnd: titleEnd),
            titleCase: titleCase, usesCapitalization: usesCapitalization,
            features: EventFeatures(language: language, date: date, periods: Self.collectPeriods(in: text)))
        collector.collectEntities(from: tagger)
        collector.collectLexicalFeatures(from: tagger)

        let tollNumbers = Self.tolls(in: title.lowercased()).intersection(collector.features.titleNumbers)
        collector.features.titleNumbers.subtract(tollNumbers)
        collector.features.tollNumbers = tollNumbers
        // "Three dead after mall shooting": a primary clause that only counts consequences names no act of its own,
        // so it cannot separate the report from coverage that leads with the shooting itself.
        if collector.features.primaryTitleTerms.allSatisfy({
            Self.consequenceTerms.contains($0) || !$0.contains(where: \.isLetter)
        }) {
            collector.features.primaryTitleTerms = []
        }
        self = collector.features
    }

    /// Lemmas and words that report the outcome of an occurrence rather than an occurrence: tolls and their changes.
    private static let consequenceTerms: Set<String> = [
        "kill", "killed", "dead", "death", "deaths", "die", "died", "dying", "injure", "injured", "injury", "injuries",
        "wound", "wounded", "hurt", "casualty", "casualties", "missing", "victim", "victims", "toll", "rise", "rises",
        "climb", "climbs", "reach", "reaches", "mount", "mounts", "survivor", "survivors", "least",
    ]

    private static let casualtyWords =
        "killed|kills?|killing|dead|deaths?|die[sd]?|dying|injured|injures?|wounded|wounds|hurt|casualties|missing|lives|victims"
    private static let tollAfterPattern = try? NSRegularExpression(
        pattern: #"\b(\d[\d,.]*|"# + numberWordPattern + #")\s+(?:[a-z-]+\s+){0,2}(?:"# + casualtyWords + #")\b"#)
    private static let tollBeforePattern = try? NSRegularExpression(
        pattern: #"\b(?:"# + casualtyWords
            + #"|toll\s+(?:rises|climbs|reaches)\s+to)\s+(?:at\s+least\s+|more\s+than\s+|over\s+|nearly\s+|about\s+|some\s+|up\s+to\s+)?(\d[\d,.]*|"#
            + numberWordPattern + #")\b"#)
    private static let numberWordPattern =
        "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|dozen|twenty|hundred"

    /// Numbers that count casualties in a headline: "kills at least 30", "30 people killed", "toll rises to 33".
    static func tolls(in title: String) -> Set<String> {
        var result = Set<String>()
        let range = NSRange(title.startIndex..., in: title)
        for pattern in [tollAfterPattern, tollBeforePattern].compactMap({ $0 }) {
            for match in pattern.matches(in: title, range: range) {
                guard let figure = Range(match.range(at: 1), in: title).map({ String(title[$0]) }) else { continue }
                let digits = figure.filter { $0.isNumber || $0 == "." }.trimmingCharacters(
                    in: CharacterSet(charactersIn: "."))
                result.insert(digits.isEmpty ? (numberWords[figure] ?? figure) : digits)
            }
        }
        return result
    }

    private static func startsSentence(_ index: String.Index, in text: String) -> Bool {
        var position = index
        while position > text.startIndex {
            position = text.index(before: position)
            let character = text[position]
            if character.isNewline { return true }
            if !character.isWhitespace { return ".!?:;\"“”'‘’«»(|—–-".contains(character) }
        }
        return true
    }
}

/// Thresholds for deciding that two reports describe one event. Starting values chosen to prefer a
/// missed link over a wrong merge; they are to be tuned against the labeled corpus (#102), not
/// claimed as measured.
struct EventMatchPolicy: Sendable, Equatable {
    var maximumTimeGap: TimeInterval = 36 * 3600
    var strictTimeGap: TimeInterval = 12 * 3600
    var fullTimeCredit: TimeInterval = 6 * 3600
    var minimumWhat = 0.2
    var strictWhat = 0.35
    var minimumSharedTerms = 3
    var matchScore = 0.55
    var compatibilityScore = 0.35
    var compatibleShare = 2.0 / 3.0
    var borderlineScore = 0.3
    var eventScore = 0.45
    var maximumEventSize = 100
    /// Semantic embedding thresholds (#127, #307)
    var semanticMatchThreshold: Double = 0.82
    var semanticVetoThreshold: Double = 0.55
    var semanticFragmentThreshold: Double = 0.70
    static let standard = EventMatchPolicy()
}

/// Facts that rule a pair out regardless of how similar the rest of the text is.
enum EventConflict: String, Sendable, Equatable {
    case language, unknownDate, timeGap, period, year, weekday, titleNumbers, places, excluded, differentEvent,
        semanticDivergence
}

struct EventPairAssessment: Sendable, Equatable {
    var conflict: EventConflict?
    var softConflict = false
    var hasHardConflict: Bool { conflict != nil && !softConflict }
    var isBorderline = false
    var needsConfirmation = false
    var score: Double
    var what: Double
    var entity: Double
    var sharedAnchors: Int
    var sharedSpecificAnchors: Int
    var sharedKeywords: Int
    var isMatch: Bool
    var isCompatible: Bool
    var embeddingCosine: Double?
}

enum EventMatcher {
    /// Bump when matching changes; recent articles and active memberships are revalidated.
    /// Unchanged archived memberships remain intact.
    static let version = 8

    private static func pairConflict(
        _ a: EventFeatures, _ b: EventFeatures, gap: TimeInterval, maximumTimeGap: TimeInterval
    ) -> EventConflict? {
        func disjoint(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
            !lhs.isEmpty && !rhs.isEmpty && lhs.isDisjoint(with: rhs)
        }
        let sharesPlace =
            !a.places.isDisjoint(with: b.places)
            || !a.localPlaces.isDisjoint(with: b.specificAnchors)
            || !b.localPlaces.isDisjoint(with: a.specificAnchors)

        if a.date == DateParser.unknownDate || b.date == DateParser.unknownDate { return .unknownDate }
        if let left = a.language, let right = b.language, left != right { return .language }
        if gap > maximumTimeGap { return .timeGap }
        if disjoint(a.periods, b.periods) { return .period }
        if disjoint(a.years, b.years) { return .year }
        if disjoint(a.weekdays, b.weekdays) { return .weekday }
        if disjoint(a.titleNumbers, b.titleNumbers) { return .titleNumbers }
        if !sharesPlace && (disjoint(a.countries, b.countries) || disjoint(a.localPlaces, b.localPlaces)) {
            return .places
        }
        return nil
    }

    private static func isPrimaryDisjoint(_ a: EventFeatures, _ b: EventFeatures) -> Bool {
        let nonPlaceB = b.keywords.union(b.titleNumbers).union(b.tollNumbers)
        let nonPlaceA = a.keywords.union(a.titleNumbers).union(a.tollNumbers)
        return (!a.primaryTitleTerms.isEmpty && a.primaryTitleTerms.isDisjoint(with: nonPlaceB))
            || (!b.primaryTitleTerms.isEmpty && b.primaryTitleTerms.isDisjoint(with: nonPlaceA))
    }

    /// Who, what, where and when for one pair. Headline similarity alone never passes: a match needs
    /// a shared name or place, shared action terms, closeness in time and no contradicting facts.
    /// When available, neural sentence embeddings (#127, #307) veto semantic divergence and rescue paraphrased matches.
    static func assess(
        _ a: EventFeatures, _ b: EventFeatures, policy: EventMatchPolicy = .standard,
        embeddingSimilarity: Double? = nil
    ) -> EventPairAssessment {
        let gap = abs(a.date.timeIntervalSince(b.date))
        let crossSpecific = a.specificAnchors.intersection(b.keywords).union(b.specificAnchors.intersection(a.keywords))
        let sharedAnchors = a.anchors.intersection(b.anchors).union(crossSpecific).count
        let sharedKeywords = a.keywords.intersection(b.keywords).count
        let what = cosine(sharedKeywords, a.keywords.count, b.keywords.count)
        let entity = overlap(sharedAnchors, max(a.anchors.count, sharedAnchors), max(b.anchors.count, sharedAnchors))
        let timeSpan = max(1, policy.maximumTimeGap - policy.fullTimeCredit)
        let time = gap <= policy.fullTimeCredit ? 1.0 : max(0.0, 1.0 - (gap - policy.fullTimeCredit) / timeSpan)
        let score = 0.4 * what + 0.4 * entity + 0.2 * time

        var conflict = pairConflict(a, b, gap: gap, maximumTimeGap: policy.maximumTimeGap)
        let sharedSpecific = a.specificAnchors.intersection(b.specificAnchors).union(crossSpecific).count
        let sharedEvidence =
            sharedKeywords
            + (a.tollNumbers.isDisjoint(with: b.tollNumbers) ? 0 : 1)
            + (a.titleNumbers.isDisjoint(with: b.titleNumbers) ? 0 : 1)
        let primaryDisjoint = isPrimaryDisjoint(a, b)

        if conflict == nil, let sim = embeddingSimilarity, sim < policy.semanticVetoThreshold {
            conflict = .semanticDivergence
        }

        let ruleMatch =
            conflict == nil && !primaryDisjoint && sharedSpecific >= 1 && sharedEvidence >= 2
            && sharedAnchors + sharedEvidence >= policy.minimumSharedTerms
            && what >= policy.minimumWhat && score >= policy.matchScore
            && (gap <= policy.strictTimeGap || (what >= policy.strictWhat && sharedEvidence >= 3))

        let semanticRescue =
            conflict == nil && !primaryDisjoint && sharedSpecific >= 1
            && (embeddingSimilarity ?? 0) >= policy.semanticMatchThreshold && gap <= policy.maximumTimeGap

        let isMatch = ruleMatch || semanticRescue
        let isCompatible =
            conflict == nil && !primaryDisjoint && sharedSpecific >= 1
            && (score >= policy.compatibilityScore || (embeddingSimilarity ?? 0) >= policy.semanticFragmentThreshold)
        let isBorderline =
            !isMatch && conflict == nil && !primaryDisjoint
            && ((sharedAnchors >= 1 && sharedEvidence >= 1 && score >= policy.borderlineScore)
                || (sharedEvidence >= 3 && what >= policy.minimumWhat)
                || ((embeddingSimilarity ?? 0) >= policy.semanticFragmentThreshold && sharedSpecific >= 1))
        let needsConfirmation = isMatch && (sharedSpecific == 0 || what < policy.strictWhat)
        return EventPairAssessment(
            conflict: conflict, isBorderline: isBorderline, needsConfirmation: needsConfirmation,
            score: max(score, embeddingSimilarity ?? 0.0), what: what, entity: entity, sharedAnchors: sharedAnchors,
            sharedSpecificAnchors: sharedSpecific, sharedKeywords: sharedKeywords,
            isMatch: isMatch, isCompatible: isCompatible, embeddingCosine: embeddingSimilarity)
    }

    static func rejected(_ pair: EventPairAssessment) -> EventPairAssessment {
        var pair = pair
        pair.conflict = .differentEvent
        pair.softConflict = false
        pair.isMatch = false
        pair.isCompatible = false
        pair.needsConfirmation = false
        pair.isBorderline = false
        return pair
    }

    static func confirmed(_ pair: EventPairAssessment, policy: EventMatchPolicy = .standard) -> EventPairAssessment {
        guard pair.conflict == nil, pair.sharedSpecificAnchors >= 1 else { return pair }
        var pair = pair
        pair.conflict = nil
        pair.softConflict = false
        pair.isBorderline = false
        pair.needsConfirmation = false
        pair.isMatch = true
        pair.isCompatible = true
        pair.score = max(pair.score, policy.matchScore)
        return pair
    }

    static func eventScore(
        for article: EventFeatures, members: [EventFeatures], excluded: Bool = false,
        policy: EventMatchPolicy = .standard
    ) -> Double? {
        guard !excluded else { return nil }
        return eventScore(pairs: members.map { assess(article, $0, policy: policy) }, policy: policy)
    }

    static func eventScore(pairs: [EventPairAssessment], policy: EventMatchPolicy = .standard) -> Double? {
        guard !pairs.isEmpty, pairs.count < policy.maximumEventSize,
            pairs.allSatisfy({ $0.conflict == nil && $0.sharedSpecificAnchors >= 1 }),
            pairs.contains(where: \.isMatch)
        else { return nil }
        let required = Int((Double(pairs.count) * policy.compatibleShare).rounded(.up))
        guard pairs.filter(\.isCompatible).count >= required else { return nil }
        let mean = pairs.map(\.score).reduce(0, +) / Double(pairs.count)
        return mean >= policy.eventScore ? mean : nil
    }

    private static func cosine(_ shared: Int, _ left: Int, _ right: Int) -> Double {
        guard left > 0, right > 0 else { return 0 }
        return Double(shared) / (Double(left) * Double(right)).squareRoot()
    }

    private static func overlap(_ shared: Int, _ left: Int, _ right: Int) -> Double {
        guard left > 0, right > 0 else { return 0 }
        return Double(shared) / Double(min(left, right))
    }
}
