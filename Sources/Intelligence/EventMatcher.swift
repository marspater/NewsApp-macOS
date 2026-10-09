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
        "uk": "GB", "u.k": "GB", "britain": "GB", "great britain": "GB", "england": "GB", "scotland": "GB", "wales": "GB",
        "uae": "AE", "emirates": "AE", "korea": "KR", "south korea": "KR", "north korea": "KP", "russia": "RU",
        "czech republic": "CZ", "holland": "NL", "ivory coast": "CI", "burma": "MM", "turkey": "TR", "palestine": "PS",
        "vatican": "VA", "taiwan": "TW", "syria": "SY", "iran": "IR", "laos": "LA", "vietnam": "VN", "congo": "CD"
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
        "philippine": "PH", "vietnamese": "VN", "thai": "TH", "burmese": "MM", "cambodian": "KH"
    ]
    /// English names of every ISO country, from the system's region list.
    private static let countryNames: [String: String] = {
        let english = Locale(identifier: "en_US")
        var names: [String: String] = [:]
        for region in Locale.Region.isoRegions where region.identifier.count == 2 && region.identifier.allSatisfy(\.isLetter) {
            guard let name = english.localizedString(forRegionCode: region.identifier) else { continue }
            names[EventFeatures.normalized(name)] = region.identifier
        }
        return names
    }()

    /// `@` plus the region code for a country, its alias or demonym; any other place unchanged.
    static func canonical(_ place: String) -> String {
        let name = EventFeatures.normalized(place)
        guard let code = aliases[name] ?? demonyms[name] ?? countryNames[name] else { return name }
        return "@" + code
    }
}

extension EventFeatures {
    static let descriptionPrefix = 600

    private static let weekdayNames: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    private static let monthNames: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"
    ]
    private static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "dozen": "12", "twenty": "20", "hundred": "100"
    ]
    /// News boilerplate and honorifics: frequent across unrelated stories, so they are not evidence.
    private static let stopwords: Set<String> = [
        "say", "said", "says", "tell", "told", "report", "reported", "reports", "according", "accord", "people", "person",
        "official", "officials", "news", "year", "years", "day", "days", "time", "times", "week", "weeks", "month", "months",
        "new", "update", "updates", "updated", "live", "late", "latest", "break", "breaking", "video", "photo", "photos",
        "watch", "read", "more", "make", "take", "get", "go", "come", "show", "include", "add", "be", "have", "do",
        "will", "can", "could", "would", "should", "also", "just", "today", "yesterday", "tomorrow", "morning", "evening",
        "night", "story", "stories", "article", "briefing", "newsletter", "podcast", "opinion", "analysis", "explainer",
        "the", "and", "for", "with", "from", "that", "this", "after", "over", "into", "about", "what", "how", "why", "when",
        "mr", "mrs", "ms", "dr", "sir", "president", "prime", "minister", "chancellor", "governor", "mayor", "king",
        "queen", "pope", "ceo", "chief", "spokesperson", "spokesman", "spokeswoman", "via", "per"
    ]
    /// Languages where capitalization does not mark proper nouns.
    private static let capitalizedNounLanguages: Set<String> = ["de", "lb"]
    private static let quarterPattern = try! NSRegularExpression(
        pattern: #"\b(first|second|third|fourth|1st|2nd|3rd|4th)[\s-]+quarter\b"#, options: [.caseInsensitive])
    private static let halfPattern = try! NSRegularExpression(
        pattern: #"\b(first|second|1st|2nd)[\s-]+half\b"#, options: [.caseInsensitive])
    private static let markupPattern = try! NSRegularExpression(pattern: #"<[^>]*>"#)

    static func normalized(_ value: String) -> String {
        var text = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        for suffix in ["'s", "’s"] where text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
    }

    private static func plain(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return markupPattern.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Extracts features with on-device NaturalLanguage only. Results depend on the OS models for the
    /// language; when they are missing, the article simply has fewer signals and matches less.
    init(title rawTitle: String, description rawDescription: String, date: Date) {
        let title = Self.plain(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let description = String(Self.plain(rawDescription).prefix(Self.descriptionPrefix))
        let text = title + "\n" + description
        let language = EventMatchKey.language(of: text)
        var people = Set<String>(), organizations = Set<String>(), places = Set<String>(), names = Set<String>()
        var keywords = Set<String>(), titleNumbers = Set<String>(), periods = Set<String>()
        var years = Set<String>(), weekdays = Set<String>()
        let whole = text.startIndex..<text.endIndex
        let titleEnd = text.index(text.startIndex, offsetBy: title.count)

        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass, .lemma])
        tagger.string = text
        if let language { tagger.setLanguage(NLLanguage(rawValue: language), range: whole) }

        var nameTokens = Set<String>()
        tagger.enumerateTags(in: whole, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            guard let tag else { return true }
            let name = Self.normalized(String(text[range]))
            guard name.count >= 2, name.contains(where: \.isLetter), !Self.stopwords.contains(name) else { return true }
            switch tag {
            case .personalName:
                people.insert(name)
                // Later references often use the surname alone.
                if let surname = name.split(separator: " ").last, surname.count >= 3, String(surname) != name { people.insert(String(surname)) }
            case .placeName: places.insert(EventPlaces.canonical(name))
            case .organizationName: organizations.insert(name)
            default: return true
            }
            nameTokens.formUnion(name.split(separator: " ").map(String.init))
            return true
        }

        let lowered = text.lowercased()
        let loweredRange = NSRange(lowered.startIndex..., in: lowered)
        for match in Self.quarterPattern.matches(in: lowered, range: loweredRange) {
            guard let range = Range(match.range(at: 1), in: lowered) else { continue }
            switch lowered[range] {
            case "first", "1st": periods.insert("q1")
            case "second", "2nd": periods.insert("q2")
            case "third", "3rd": periods.insert("q3")
            default: periods.insert("q4")
            }
        }
        for match in Self.halfPattern.matches(in: lowered, range: loweredRange) {
            guard let range = Range(match.range(at: 1), in: lowered) else { continue }
            periods.insert(["first", "1st"].contains(String(lowered[range])) ? "h1" : "h2")
        }

        let titleWords = title.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 3 }
        let titleCase = !titleWords.isEmpty
            && Double(titleWords.filter { $0.first?.isUppercase == true }.count) / Double(titleWords.count) > 0.6
        let usesCapitalization = !(language.map(Self.capitalizedNounLanguages.contains) ?? false)

        let wordOptions: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        var lemmas: [String.Index: String] = [:]
        tagger.enumerateTags(in: whole, unit: .word, scheme: .lemma, options: wordOptions) { tag, range in
            if let tag { lemmas[range.lowerBound] = Self.normalized(tag.rawValue) }
            return true
        }
        tagger.enumerateTags(in: whole, unit: .word, scheme: .lexicalClass, options: wordOptions) { tag, range in
            let token = String(text[range])
            let word = Self.normalized(token)
            guard !word.isEmpty else { return true }
            let inTitle = range.lowerBound < titleEnd

            if word.count == 2, let letter = word.first, let digit = word.last,
               (letter == "q" && "1234".contains(digit)) || (letter == "h" && "12".contains(digit)) {
                periods.insert(word)
                return true
            }
            if word.contains(where: \.isNumber) {
                let digits = word.filter { $0.isNumber || $0 == "." }.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if digits.count == 4, let year = Int(digits), (1900...2100).contains(year) {
                    years.insert(digits)
                } else if inTitle, !digits.isEmpty {
                    titleNumbers.insert(digits)
                }
                return true
            }
            if Self.weekdayNames.contains(word) {
                weekdays.insert(word)
                return true
            }
            if inTitle, let number = Self.numberWords[word] {
                titleNumbers.insert(number)
                return true
            }
            guard word.count >= 3, word.contains(where: \.isLetter), !Self.stopwords.contains(word),
                  !Self.monthNames.contains(word), !Self.numberWords.keys.contains(word) else { return true }

            // A capitalized word inside a sentence is most likely a name the tagger did not type.
            if usesCapitalization, token.first?.isUppercase == true, !(inTitle && titleCase),
               !Self.startsSentence(range.lowerBound, in: text) {
                if !nameTokens.contains(word) { names.insert(word) }
                return true
            }
            guard !nameTokens.contains(word) else { return true }
            if let tag {
                guard [.noun, .verb, .adjective].contains(tag) else { return true }
                let keyword = lemmas[range.lowerBound].flatMap { $0.isEmpty ? nil : $0 } ?? word
                if keyword.count >= 3, !Self.stopwords.contains(keyword) { keywords.insert(keyword) }
            } else if word.count >= 4 {
                // No lexical model for this language: keep longer words as plain terms.
                keywords.insert(word)
            }
            return true
        }

        // Nationality adjectives the tagger leaves untyped ("Canadian writer") are places too.
        for name in names {
            let place = EventPlaces.canonical(name)
            if place.hasPrefix("@") { names.remove(name); places.insert(place) }
        }
        let tollNumbers = Self.tolls(in: title.lowercased()).intersection(titleNumbers)
        self.init(language: language, people: people, organizations: organizations, places: places, names: names,
                  keywords: keywords, date: date, titleNumbers: titleNumbers.subtracting(tollNumbers), tollNumbers: tollNumbers,
                  periods: periods, years: years, weekdays: weekdays)
    }

    private static let casualtyWords = "killed|kills?|killing|dead|deaths?|die[sd]?|dying|injured|injures?|wounded|wounds|hurt|casualties|missing|lives|victims"
    private static let tollAfterPattern = try? NSRegularExpression(
        pattern: #"\b(\d[\d,.]*|"# + numberWordPattern + #")\s+(?:[a-z-]+\s+){0,2}(?:"# + casualtyWords + #")\b"#)
    private static let tollBeforePattern = try? NSRegularExpression(
        pattern: #"\b(?:"# + casualtyWords + #"|toll\s+(?:rises|climbs|reaches)\s+to)\s+(?:at\s+least\s+|more\s+than\s+|over\s+|nearly\s+|about\s+|some\s+|up\s+to\s+)?(\d[\d,.]*|"# + numberWordPattern + #")\b"#)
    private static let numberWordPattern = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|dozen|twenty|hundred"

    /// Numbers that count casualties in a headline: "kills at least 30", "30 people killed", "toll rises to 33".
    static func tolls(in title: String) -> Set<String> {
        var result = Set<String>()
        let range = NSRange(title.startIndex..., in: title)
        for pattern in [tollAfterPattern, tollBeforePattern].compactMap({ $0 }) {
            for match in pattern.matches(in: title, range: range) {
                guard let figure = Range(match.range(at: 1), in: title).map({ String(title[$0]) }) else { continue }
                let digits = figure.filter { $0.isNumber || $0 == "." }.trimmingCharacters(in: CharacterSet(charactersIn: "."))
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
            if character.isWhitespace { continue }
            return ".!?:;\"“”'‘’«»(|—–-".contains(character)
        }
        return true
    }
}

/// Thresholds for deciding that two reports describe one event. Starting values chosen to prefer a
/// missed link over a wrong merge; they are to be tuned against the labeled corpus (#102), not
/// claimed as measured.
struct EventMatchPolicy: Sendable, Equatable {
    /// Reports further apart than this never match.
    var maximumTimeGap: TimeInterval = 36 * 3600
    /// Beyond this gap a match also needs `strictWhat` and three shared action terms.
    var strictTimeGap: TimeInterval = 12 * 3600
    var fullTimeCredit: TimeInterval = 6 * 3600
    var minimumWhat = 0.2
    var strictWhat = 0.35
    var minimumSharedTerms = 3
    var matchScore = 0.55
    /// A member counts as compatible with a newcomer at this score.
    var compatibilityScore = 0.35
    /// Share of an event's members a newcomer must be compatible with. One dissenting member of a larger event no
    /// longer keeps a matching report out; in a two-member event both must still agree.
    var compatibleShare = 2.0 / 3.0
    /// Pairs at or above this score that share a name and a word may be settled by the on-device judge.
    var borderlineScore = 0.3
    /// The newcomer's mean score across the whole event.
    var eventScore = 0.45
    /// Events at this size stop growing; a later report starts a new event instead.
    var maximumEventSize = 100

    static let standard = EventMatchPolicy()
}

/// Facts that rule a pair out regardless of how similar the rest of the text is.
enum EventConflict: String, Sendable, Equatable {
    case language, timeGap, period, year, weekday, titleNumbers, places, excluded
}

struct EventPairAssessment: Sendable, Equatable {
    var conflict: EventConflict?
    /// The conflict rests on facts that do not decide alone (different local places, different headline figures) while
    /// the reports share specific names: an on-device judge may settle it.
    var softConflict = false
    /// Open: not a match, but close enough that a judge's "same event" should make it one.
    var isBorderline = false
    /// A match on thin evidence (few shared words, or only a shared country): a judge's "different events" undoes it.
    var needsConfirmation = false
    var score: Double
    var what: Double
    var entity: Double
    var sharedAnchors: Int
    var sharedKeywords: Int
    /// Strong enough to justify a link on its own.
    var isMatch: Bool
    /// Weak enough to live in the same event as a matched newcomer.
    var isCompatible: Bool
}

enum EventMatcher {
    /// Bump when matching changes; recent articles are then matched again. Event members whose
    /// title and description are unchanged keep their events.
    static let version = 2

    /// Who, what, where and when for one pair. Headline similarity alone never passes: a match needs
    /// a shared name or place, shared action terms, closeness in time and no contradicting facts.
    static func assess(_ a: EventFeatures, _ b: EventFeatures, policy: EventMatchPolicy = .standard) -> EventPairAssessment {
        let gap = abs(a.date.timeIntervalSince(b.date))
        let sharedAnchors = a.anchors.intersection(b.anchors).count
        let sharedKeywords = a.keywords.intersection(b.keywords).count
        let what = cosine(sharedKeywords, a.keywords.count, b.keywords.count)
        let entity = overlap(sharedAnchors, a.anchors.count, b.anchors.count)
        let time = gap <= policy.fullTimeCredit ? 1
            : max(0, 1 - (gap - policy.fullTimeCredit) / max(1, policy.maximumTimeGap - policy.fullTimeCredit))
        let score = 0.4 * what + 0.4 * entity + 0.2 * time

        var conflict: EventConflict?
        var softConflict = false
        let sharedSpecific = a.specificAnchors.intersection(b.specificAnchors).count
        // Equal casualty tolls are evidence of one incident.
        let sharedEvidence = sharedKeywords + (a.tollNumbers.isDisjoint(with: b.tollNumbers) ? 0 : 1)
        func disjoint(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool { !lhs.isEmpty && !rhs.isEmpty && lhs.isDisjoint(with: rhs) }
        if let left = a.language, let right = b.language, left != right { conflict = .language }
        else if gap > policy.maximumTimeGap { conflict = .timeGap }
        else if disjoint(a.periods, b.periods) { conflict = .period }
        else if disjoint(a.years, b.years) { conflict = .year }
        else if disjoint(a.weekdays, b.weekdays) { conflict = .weekday }
        // Headline figures (a magnitude, a count) differ between separate incidents. Casualty tolls are not compared:
        // they rise as one incident is reported. With shared specific names the difference is left to the judge.
        else if disjoint(a.titleNumbers, b.titleNumbers) {
            conflict = .titleNumbers
            softConflict = sharedSpecific >= 1 && sharedKeywords >= 2
        }
        // Different countries are different events. Places below country level ("Madrid" against "Spain", one city
        // against another) only conflict when no place is shared, and a judge may settle that when names are shared.
        else if a.places.isDisjoint(with: b.places) {
            if disjoint(a.countries, b.countries) {
                // Angles of one story can name different countries; strongly shared wording leaves it to the judge.
                conflict = .places
                softConflict = sharedKeywords >= 3 && what >= policy.minimumWhat
            } else if disjoint(a.localPlaces, b.localPlaces) {
                conflict = .places
                softConflict = sharedSpecific >= 1 && sharedKeywords >= 2
            }
        }

        // A shared country alone is weak evidence: a match also needs a specific name, two shared places, or strongly
        // shared wording.
        let strongWording = sharedEvidence >= 4 && what >= policy.strictWhat
        let isMatch = conflict == nil
            && (sharedSpecific >= 1 || sharedAnchors >= 2 || (sharedAnchors >= 1 && strongWording)) && sharedEvidence >= 2
            && sharedAnchors + sharedEvidence >= policy.minimumSharedTerms
            && what >= policy.minimumWhat && score >= policy.matchScore
            && (gap <= policy.strictTimeGap || (what >= policy.strictWhat && sharedKeywords >= 3))
        let isCompatible = conflict == nil
            && (sharedAnchors >= 1 || sharedKeywords >= 2) && score >= policy.compatibilityScore
        let isBorderline = !isMatch && (conflict == nil || softConflict)
            && ((sharedAnchors >= 1 && sharedEvidence >= 1 && score >= policy.borderlineScore)
                || (sharedEvidence >= 3 && what >= policy.minimumWhat))
        let needsConfirmation = isMatch && (sharedSpecific == 0 || what < policy.strictWhat)
        return EventPairAssessment(conflict: conflict, softConflict: softConflict, isBorderline: isBorderline,
                                   needsConfirmation: needsConfirmation,
                                   score: score, what: what, entity: entity,
                                   sharedAnchors: sharedAnchors, sharedKeywords: sharedKeywords,
                                   isMatch: isMatch, isCompatible: isCompatible)
    }

    /// A pair the on-device judge called one event counts as a match.
    /// A thin match the on-device judge called separate events stays compatible but no longer links the pair.
    static func rejected(_ pair: EventPairAssessment) -> EventPairAssessment {
        var pair = pair
        pair.isMatch = false
        pair.needsConfirmation = false
        pair.isBorderline = false
        return pair
    }

    static func confirmed(_ pair: EventPairAssessment, policy: EventMatchPolicy = .standard) -> EventPairAssessment {
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

    /// Whole-event check without a judge. Returns the mean score when the newcomer may join, nil otherwise.
    static func eventScore(
        for article: EventFeatures, members: [EventFeatures], excluded: Bool = false,
        policy: EventMatchPolicy = .standard
    ) -> Double? {
        guard !excluded else { return nil }
        return eventScore(pairs: members.map { assess(article, $0, policy: policy) }, policy: policy)
    }

    /// The newcomer must strongly match one member and be compatible with at least `compatibleShare` of them (all of
    /// them in a two-member event), so a chain A≈B≈C cannot pull a contradicting C into a small event.
    static func eventScore(pairs: [EventPairAssessment], policy: EventMatchPolicy = .standard) -> Double? {
        guard !pairs.isEmpty, pairs.count < policy.maximumEventSize, pairs.contains(where: \.isMatch) else { return nil }
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
