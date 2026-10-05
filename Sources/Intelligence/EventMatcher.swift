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
    var titleNumbers: Set<String> = []
    var periods: Set<String> = []
    var years: Set<String> = []
    var weekdays: Set<String> = []

    var anchors: Set<String> { people.union(organizations).union(places).union(names) }
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

        let lexicon = language.flatMap { EventLexicon.byLanguage[$0] }
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
            case .placeName: places.insert(name)
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
        if let lexicon { periods.formUnion(lexicon.quarters(in: text)) }

        let titleWords = title.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 3 }
        let titleCase = !titleWords.isEmpty
            && Double(titleWords.filter { $0.first?.isUppercase == true }.count) / Double(titleWords.count) > 0.6
        let usesCapitalization = !(language.map(Self.capitalizedNounLanguages.contains) ?? false)

        let wordOptions: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        var lemmas: [String.Index: String] = [:]
        var sawWordClass = false
        var plainTerms = Set<String>()
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
            if let day = Self.weekdayNames.contains(word) ? word : lexicon?.weekdays[word] {
                weekdays.insert(day)
                return true
            }
            if inTitle, let number = Self.numberWords[word] {
                titleNumbers.insert(number)
                return true
            }
            guard word.count >= 3, word.contains(where: \.isLetter), !Self.stopwords.contains(word),
                  !Self.monthNames.contains(word), !Self.numberWords.keys.contains(word),
                  !(lexicon?.isBoilerplate(word) ?? false) else { return true }

            // A capitalized word inside a sentence is most likely a name the tagger did not type.
            if usesCapitalization, token.first?.isUppercase == true, !(inTitle && titleCase),
               !Self.startsSentence(range.lowerBound, in: text) {
                if !nameTokens.contains(word) { names.insert(word) }
                return true
            }
            guard !nameTokens.contains(word) else { return true }
            if let tag, tag != .otherWord {
                sawWordClass = true
                guard [.noun, .verb, .adjective].contains(tag) else { return true }
                let keyword = lemmas[range.lowerBound].flatMap { $0.isEmpty ? nil : $0 } ?? word
                if keyword.count >= 3, !Self.stopwords.contains(keyword), !(lexicon?.isBoilerplate(keyword) ?? false) {
                    keywords.insert(keyword)
                }
            } else if word.count >= 4 {
                if tag == nil { keywords.insert(word) } else { plainTerms.insert(word) }
            }
            return true
        }
        // Without a word-class model the tagger calls every word `otherWord`. Plain words then stand in
        // for action terms, but only where the boilerplate is listed; a name opening a sentence counts once.
        if !sawWordClass, lexicon?.allowsPlainTerms == true { keywords.formUnion(plainTerms.subtracting(names)) }

        self.init(language: language, people: people, organizations: organizations, places: places, names: names,
                  keywords: keywords, date: date, titleNumbers: titleNumbers, periods: periods, years: years, weekdays: weekdays)
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
    /// Every member of an event must reach this against a newcomer.
    var compatibilityScore = 0.35
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
    /// Bump when matching changes; recent articles are then matched again.
    static let version = 1

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
        func disjoint(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool { !lhs.isEmpty && !rhs.isEmpty && lhs.isDisjoint(with: rhs) }
        if let left = a.language, let right = b.language, left != right { conflict = .language }
        else if gap > policy.maximumTimeGap { conflict = .timeGap }
        else if disjoint(a.periods, b.periods) { conflict = .period }
        else if disjoint(a.years, b.years) { conflict = .year }
        else if disjoint(a.weekdays, b.weekdays) { conflict = .weekday }
        // Headline figures (a toll, a magnitude, a count) differ between separate incidents. Updated
        // tolls of one incident are missed as a result; that is the conservative trade.
        else if disjoint(a.titleNumbers, b.titleNumbers) { conflict = .titleNumbers }
        else if disjoint(a.places, b.places) { conflict = .places }

        let isMatch = conflict == nil
            && sharedAnchors >= 1 && sharedKeywords >= 2
            && sharedAnchors + sharedKeywords >= policy.minimumSharedTerms
            && what >= policy.minimumWhat && score >= policy.matchScore
            && (gap <= policy.strictTimeGap || (what >= policy.strictWhat && sharedKeywords >= 3))
        let isCompatible = conflict == nil
            && (sharedAnchors >= 1 || sharedKeywords >= 2) && score >= policy.compatibilityScore
        return EventPairAssessment(conflict: conflict, score: score, what: what, entity: entity,
                                   sharedAnchors: sharedAnchors, sharedKeywords: sharedKeywords,
                                   isMatch: isMatch, isCompatible: isCompatible)
    }

    /// Whole-event check: the newcomer must strongly match at least one member and be compatible
    /// with every member, so a chain A≈B≈C cannot pull unrelated A and C together. Returns the mean
    /// score when the newcomer may join, nil otherwise.
    static func eventScore(
        for article: EventFeatures, members: [EventFeatures], excluded: Bool = false,
        policy: EventMatchPolicy = .standard
    ) -> Double? {
        guard !excluded, !members.isEmpty, members.count < policy.maximumEventSize else { return nil }
        var total = 0.0
        var matched = false
        for member in members {
            let pair = assess(article, member, policy: policy)
            guard pair.isCompatible else { return nil }
            matched = matched || pair.isMatch
            total += pair.score
        }
        let mean = total / Double(members.count)
        return matched && mean >= policy.eventScore ? mean : nil
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

/// Boilerplate, dates and financial quarters for catalog languages other than English, so plain terms
/// carry what happened rather than who said it, and weekdays and quarters still rule pairs out.
struct EventLexicon: Sendable {
    let stopwords: Set<String>
    let months: Set<String>
    /// Inflected weekday forms mapped to the English name, so the weekday conflict compares days.
    let weekdays: [String: String]
    private let quarterStems: [String: String]
    private let quarterPattern: NSRegularExpression

    /// Plain terms without a boilerplate list would make reporting verbs and titles look like evidence.
    var allowsPlainTerms: Bool { !stopwords.isEmpty }

    init(stopwords: [String] = [], months: [String], weekdays: [String: [String]], quarters: [String: [String]],
         quarterWords: [String]) {
        self.stopwords = Set(stopwords.map(EventFeatures.normalized))
        self.months = Set(months.map(EventFeatures.normalized))
        var days: [String: String] = [:]
        for (day, forms) in weekdays {
            for form in forms { for variant in [form, form.replacingOccurrences(of: "'", with: "’")] { days[EventFeatures.normalized(variant)] = day } }
        }
        self.weekdays = days
        var stems: [String: String] = [:]
        for (quarter, list) in quarters { for stem in list { stems[stem.lowercased()] = quarter } }
        quarterStems = stems
        let ordinals = stems.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let nouns = quarterWords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // An ordinal word, an upper-case Roman numeral (Latin or Cyrillic І) or a digit, then the quarter noun.
        quarterPattern = try! NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])(?:("# + ordinals + #")\p{L}*|(IV|III|II|I|ІV|ІІІ|ІІ|І)|([1-4])(?:-\p{L}+)?)[\s-]+(?:"#
                + nouns + #")"#, options: [.caseInsensitive])
    }

    func isBoilerplate(_ word: String) -> Bool { stopwords.contains(word) || months.contains(word) }

    func quarters(in text: String) -> Set<String> {
        var found = Set<String>()
        for match in quarterPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text), let quarter = quarterStems[text[range].lowercased()] {
                found.insert(quarter)
            } else if let range = Range(match.range(at: 2), in: text), text[range] == text[range].uppercased() {
                // Case-insensitive matching would read the Italian article "i" as a numeral.
                let roman = text[range].replacingOccurrences(of: "І", with: "I")
                if let quarter = ["I": "q1", "II": "q2", "III": "q3", "IV": "q4"][roman] { found.insert(quarter) }
            } else if let range = Range(match.range(at: 3), in: text) {
                found.insert("q" + text[range])
            }
        }
        return found
    }

    static let byLanguage: [String: EventLexicon] = [
        "uk": EventLexicon(
            stopwords: words("""
                через після перед проти щодо понад серед біля поблизу навколо внаслідок згідно завдяки протягом
                впродовж межах сфері боку разом також тому коли якщо хоча адже однак проте водночас тобто навіть лише
                тільки саме дуже більше менше зокрема наприклад нібито знову вперше майже близько приблизно щонайменше
                принаймні можливо ймовірно офіційно тимчасово одразу який якого якої якому якій яким якими яких якою
                його вона вони своє свої свою свого своєї своїх їхні їхній цього цієї цьому того такий така таке такі
                таких такого всіх всього всій усіх інші інших іншого новий нова нове нові нових нового бути буде
                будуть було була були може можуть можна мають мали треба потрібно немає стане стало хоче хочуть планує
                планують вдалося стався сталася сталося відбувся відбулася відбулося відбудеться зазнав зазнала
                зазнали провів провела провели провести заявив заявила заявили заявило заявляє заява заяви заяву
                сказав сказала сказали каже кажуть повідомив повідомила повідомили повідомило повідомляє
                повідомляється повідомлення розповів розповіла розповіли зазначив зазначила зазначили зазначається
                наголосив наголосила наголосили додав додала додали пояснив пояснила пояснили підкреслив уточнили
                оголосив оголосила оголосили написав написала пише передає йдеться відповів відповіла відповідь
                відповіддю відреагував відреагувала відреагували підтвердив підтвердила підтвердили вважає словами
                даними джерела джерел інформацією посиланням відомо президент президента президенту президентом
                президентка прем'єр прем'єра прем'єрка віце міністр міністра міністром міністри міністрів міністерка
                голова голови головою глава глави очільник очільника очільниця керівник керівника речник речника
                речниця мера мером губернатор губернатора канцлер канцлера канцлером канцлерка посол посла послом
                депутат депутата депутати депутатів нардеп нардепи генерал генерала командувач командувача заступник
                заступника заступниця секретар секретаря спікер спікера лідер лідера представник представника
                представники представників посадовці посадовців чиновники влада влади владі пана пані король короля
                папа директор директора люди людей людина людини новини новина новин відео фото онлайн наживо
                трансляція оновлено оновлення деталі подробиці читайте дивіться терміново головне сьогодні вчора учора
                завтра ранку вранці зранку вечора ввечері увечері вночі уночі ночі день днів днями тиждень тижня тижні
                тижнів місяць місяця місяці місяців року році роки років годину години годин доба добу доби часу
                вихідні вихідних минулого минулої минулий наступного наступної наступний поточного нещодавно
                напередодні наприкінці початку останні останніх наразі зараз нині тепер досі поки раніше згодом
                незабаром один одна одного одному одній двох двоє троє трьох кілька кількох декілька десятки десятків
                сотні тисяча тисячі тисяч мільйон мільйона мільйонів мільярд мільярда мільярдів млрд відсотків
                відсотка більшість разів рази область області району районі районах районів місто міста місті села
                селі вулиці столиці столицю країни країні країн
                """),
            months: words("""
                січень січня січні січнем січню лютий лютого лютому лютим березень березня березні березнем березню
                квітень квітня квітні квітнем квітню травень травня травні травнем травню червень червня червні
                червнем червню липень липня липні липнем липню серпень серпня серпні серпнем серпню вересень вересня
                вересні вереснем вересню жовтень жовтня жовтні жовтнем жовтню листопад листопада листопаді листопадом
                листопаду грудень грудня грудні груднем грудню
                """),
            weekdays: [
                "monday": ["понеділок", "понеділка", "понеділку", "понеділком"],
                "tuesday": ["вівторок", "вівторка", "вівторку", "вівторком"],
                "wednesday": ["середа", "середу", "середи", "середі", "середою"],
                "thursday": ["четвер", "четверга", "четвергу", "четвергом"],
                "friday": ["п'ятниця", "п'ятницю", "п'ятниці", "п'ятницею"],
                "saturday": ["субота", "суботу", "суботи", "суботі", "суботою"],
                "sunday": ["неділя", "неділю", "неділі", "неділею"]
            ],
            quarters: ["q1": ["перш"], "q2": ["друг"], "q3": ["треті", "треть", "третя", "третю"], "q4": ["четверт"]],
            quarterWords: ["квартал"]),
        "pl": EventLexicon(
            stopwords: words("""
                przez przed podczas według wobec wśród około ponad między przeciwko dzięki mimo zamiast poza obok
                wewnątrz wraz przy jako związku sprawie temat ciągu trakcie dotyczy zdaniem oraz albo lecz jednak
                ponieważ więc czyli żeby jeśli kiedy gdzie dlaczego dlatego natomiast także również który która które
                którego której których którzy tego temu tych taki takie jakie czego jego niego niej nich sobie siebie
                swoje swojej swojego swoich wszystko wszyscy wszystkie wszystkich każdy inne innych samej cały cała
                całe kolejny kolejne kolejnych różne jest będzie będą była było byli były został została zostało
                zostali zostały zostanie może mogą można musi trzeba powinien chce chcą mają miał miała jeszcze nadal
                wciąż teraz obecnie właśnie bardzo nawet tylko znów ponownie wkrótce niedawno ostatnio ostatnich
                ostatnie wcześniej później następnie potem wtedy prawie niemal zbyt więcej mniej jeden jedna jednego
                jednym dwie dwóch trzy trzech cztery pięć kilka kilku kilkanaście kilkadziesiąt wiele wielu większość
                większości tysiące tysięcy milion miliona milionów miliard miliardy miliardów procent proc mówi mówią
                powiedział powiedziała stwierdził stwierdziła oświadczył oświadczyła ogłosił ogłosiła zapowiedział
                zapowiedziała zapowiada poinformował poinformowała poinformowali informuje przekazał przekazała dodał
                dodała dodaje zaznaczył zaznaczyła podkreślił podkreśliła podkreśla wyjaśnił wyjaśnia tłumaczy
                zauważył ocenił ocenia uważa twierdzi przekonuje pisze napisał podaje podał wskazuje zapewnia przyznał
                przyznaje przypomina opowiada prezydent prezydenta prezydentem premier premiera premierem minister
                ministra ministrem ministerstwo ministerstwa wiceminister wicepremier szef szefa szefowa rzecznik
                rzecznika rzeczniczka burmistrz wojewoda marszałek marszałka poseł posła posłanka posłowie senator
                ambasador generał gubernator kanclerz król króla królowa papież papieża prezes prezesa dyrektor
                przewodniczący sekretarz pani pana profesor prof władze władz ludzie ludzi osoby osób wiadomości
                informacje informacji wideo nagranie zdjęcia foto relacja żywo aktualizacja czytaj zobacz pilne
                najnowsze najważniejsze szczegóły transmisja transmisję zapraszamy zaprasza dzisiaj dziś wczoraj jutro
                rano wieczorem nocy dzień dnia dniu dniach doby tydzień tygodnia tygodniu tygodni miesiąc miesiąca
                miesiącu miesięcy roku lata latach godzina godziny godzin godz czas czasie chwili weekend
                """),
            months: words("""
                styczeń stycznia styczniu styczniem luty lutego lutym marzec marca marcu marcem kwiecień kwietnia
                kwietniu kwietniem maj maja maju majem czerwiec czerwca czerwcu czerwcem lipiec lipca lipcu lipcem
                sierpień sierpnia sierpniu sierpniem wrzesień września wrześniu wrześniem październik października
                październiku październikiem listopad listopada listopadzie listopadem grudzień grudnia grudniu
                grudniem
                """),
            weekdays: [
                "monday": ["poniedziałek", "poniedziałku", "poniedziałkiem"],
                "tuesday": ["wtorek", "wtorku", "wtorkiem"],
                "wednesday": ["środa", "środę", "środy", "środzie", "środą"],
                "thursday": ["czwartek", "czwartku", "czwartkiem"],
                "friday": ["piątek", "piątku", "piątkiem"],
                "saturday": ["sobota", "sobotę", "soboty", "sobocie", "sobotą"],
                "sunday": ["niedziela", "niedzielę", "niedzieli", "niedzielą"]
            ],
            quarters: ["q1": ["pierwsz"], "q2": ["drugi"], "q3": ["trzeci"], "q4": ["czwart"]],
            quarterWords: ["kwartał", "kwartal"]),
        "fr": EventLexicon(
            stopwords: words("""
                dans avec pour sans sous vers chez entre contre depuis pendant avant après selon lors auprès près face
                travers jusqu'à jusqu'au mais donc comme quand lorsque ainsi alors afin parce dont pourquoi comment
                laquelle elle elles nous vous leur leurs celui celle ceux cela cette tout tous toute toutes chaque
                autre autres même certains certaines plusieurs quelques quelle c'est d'un d'une qu'il qu'ils qu'elle
                n'est s'est s'agit d'être d'avoir d'autres d'après être avoir sont était sera serait soit avait aurait
                ayant peut pourra pourrait doit devrait faut fait faire veut vont voir aussi déjà encore toujours
                maintenant très plus moins bien également notamment désormais puis environ deux trois milliers million
                millions milliard milliards déclaré déclaration affirmé annoncé estimé assuré expliqué précisé ajouté
                souligné indiqué rapporté confirmé évoqué président présidente ministre ministres premier première
                maire chef porte parole gouverneur chancelier député députée députés sénateur ambassadeur général
                secrétaire directeur dirigeant dirigeants responsable responsables officiel officiels autorités
                adjoint vice patron monsieur madame pape personne personnes gens actualité info infos informations
                direct vidéo vidéos photo photos lire suite détails dernier dernière nouveau nouvelle nouvelles
                prochain aujourd'hui hier demain matin soir nuit jour jours journée semaine semaines mois année années
                l'année heure heures temps fois moment récemment actuellement week weekend début raison côté nombre
                """),
            months: words("""
                janvier février mars avril d'avril mai juin juillet août d'août septembre octobre d'octobre novembre
                décembre
                """),
            weekdays: [
                "monday": ["lundi", "lundis"],
                "tuesday": ["mardi", "mardis"],
                "wednesday": ["mercredi", "mercredis"],
                "thursday": ["jeudi", "jeudis"],
                "friday": ["vendredi", "vendredis"],
                "saturday": ["samedi", "samedis"],
                "sunday": ["dimanche", "dimanches"]
            ],
            quarters: ["q1": ["premi", "1er", "1re"], "q2": ["deuxième", "second", "2e"], "q3": ["troisième", "3e"], "q4": ["quatrième", "4e"]],
            quarterWords: ["trimestre"]),
        "it": EventLexicon(
            stopwords: words("""
                della delle dello degli dalla dalle dallo dagli alla alle allo agli nella nelle nello negli sulla
                sulle sullo sugli dopo prima verso contro oltre senza fuori presso durante mentre tramite secondo
                circa entro fino insieme nonostante rispetto anche ancora pure oppure quindi dunque però perché poiché
                infatti inoltre invece tuttavia comunque allora quando quanto come dove così cosa sempre forse subito
                ormai intanto quasi almeno appena solo proprio molto poco tanto ecco finora questo questa questi
                queste quello quella quelli quelle tutto tutta tutti tutte altro altra altri altre molti molte alcuni
                alcune ogni loro stesso stessa qualche quale quali sono stato stata stati state essere sarà saranno
                sarebbe siano fosse erano aver avere hanno abbiamo aveva avrebbe avuto possono potrebbe potrebbero
                potrà deve devono dovrebbe dovrà vuole viene vengono fatto fare fanno farà faranno dice dicono detto
                dire dichiara dichiarato dichiarazione dichiarazioni annuncia annunciato afferma spiega spiegato
                aggiunge aggiunto sottolinea sottolineato riferisce riferito riportato conferma confermato precisa
                racconta ribadisce ribadito scrive parla ricorda ricordato stando fonti fonte comunicato nota
                presidente presidenti premier primo ministro ministra ministri ministero sindaco sindaca governatore
                cancelliere capo vice vicepremier vicepresidente portavoce deputato deputata deputati senatore
                parlamentare parlamentari ambasciatore generale comandante segretario leader assessore consigliere
                direttore esponente uscente papa pontefice signor signora amministratore delegato notizia notizie news
                video foto immagini diretta live aggiornamento aggiornamenti ultim'ora ultime ultimi ultimo ultima
                breaking leggi guarda dettagli articolo intervista stampa continua oggi ieri domani stamattina stasera
                stanotte mattina pomeriggio sera serata notte giorno giorni giornata settimana settimane mese mesi
                anno anni quest'anno tempo minuti scorso scorsa scorsi prossimo prossima prossimi recentemente
                attualmente momento volta volte inizio fine metà mila mille migliaia milione milioni miliardo miliardi
                cento decine centinaia diversi diverse numerosi quattro cinque sette otto dieci persone persona gente
                parte modo perche' pero' cosi' piu' gia' sara' potra' fara' meta' puo'
                """),
            months: words("""
                gennaio febbraio marzo aprile maggio giugno luglio agosto settembre ottobre novembre dicembre
                """),
            weekdays: [
                "monday": ["lunedì", "lunedi'"],
                "tuesday": ["martedì", "martedi'"],
                "wednesday": ["mercoledì", "mercoledi'"],
                "thursday": ["giovedì", "giovedi'"],
                "friday": ["venerdì", "venerdi'"],
                "saturday": ["sabato", "sabati"],
                "sunday": ["domenica", "domeniche"]
            ],
            quarters: ["q1": ["prim"], "q2": ["second"], "q3": ["terz"], "q4": ["quart"]],
            quarterWords: ["trimestr"]),
        "nl": EventLexicon(
            stopwords: words("""
                zijn door heeft voor naar niet over worden wordt werd werden hebben hadden tegen maar zich vanwege
                weer geen daar hier waar tussen onder meer sinds eerst moet moeten moest kunnen zullen zouden willen
                wilde gaan gaat ging waren geweest omdat doordat toen terwijl zoals zonder naast vanaf rond richting
                volgens tijdens binnen deze verder zelf zelfs alleen vooral echter toch opnieuw steeds inmiddels
                daarna elkaar niemand alles alle enkele sommige andere veel weinig aantal ongeveer zo'n bijna zeker
                ruim vaak heel haar mogelijk waarschijnlijk duidelijk bekend laat liet twee drie vier vijf zeven acht
                negen tien twintig honderd honderden tientallen duizend duizenden miljoen miljoenen miljard miljarden
                procent eerste tweede derde zegt zeggen gezegd zeiden vertelt vertelde meldt melden meldde gemeld
                bericht berichten berichtte schrijft schreef verklaarde kondigt kondigde aangekondigd bevestigt
                bevestigde bevestigd benadrukte voegde weten aldus president premier minister ministers ministerie
                staatssecretaris burgemeester wethouder gouverneur kanselier koning koningin paus kamerlid ambassadeur
                generaal voorzitter leider hoofd chef topman directeur woordvoerder woordvoerster plaatsvervangende
                autoriteiten functionarissen nieuws liveblog live update video foto foto's beelden interview overzicht
                goedemorgen wekdienst persbureau omroep media bronnen correspondent laatste vandaag gisteren morgen
                vanochtend vanmorgen vanmiddag vanavond vannacht gisteravond ochtend middag avond nacht dagen week
                weken weekend maand maanden jaar jaren jarige tijd momenteel onlangs eerder later afgelopen vorige
                volgende komende mensen verschillende terug
                """),
            months: words("""
                januari februari maart april mei juni juli augustus september oktober november december
                """),
            weekdays: [
                "monday": ["maandag", "maandagen", "maandags", "maandagochtend", "maandagmorgen", "maandagmiddag", "maandagavond", "maandagnacht"],
                "tuesday": ["dinsdag", "dinsdagen", "dinsdags", "dinsdagochtend", "dinsdagmorgen", "dinsdagmiddag", "dinsdagavond", "dinsdagnacht"],
                "wednesday": ["woensdag", "woensdagen", "woensdags", "woensdagochtend", "woensdagmorgen", "woensdagmiddag", "woensdagavond", "woensdagnacht"],
                "thursday": ["donderdag", "donderdagen", "donderdags", "donderdagochtend", "donderdagmorgen", "donderdagmiddag", "donderdagavond", "donderdagnacht"],
                "friday": ["vrijdag", "vrijdagen", "vrijdags", "vrijdagochtend", "vrijdagmorgen", "vrijdagmiddag", "vrijdagavond", "vrijdagnacht"],
                "saturday": ["zaterdag", "zaterdagen", "zaterdags", "zaterdagochtend", "zaterdagmorgen", "zaterdagmiddag", "zaterdagavond", "zaterdagnacht"],
                "sunday": ["zondag", "zondagen", "zondags", "zondagochtend", "zondagmorgen", "zondagmiddag", "zondagavond", "zondagnacht"]
            ],
            quarters: ["q1": ["eerste"], "q2": ["tweede"], "q3": ["derde"], "q4": ["vierde"]],
            quarterWords: ["kwartaal", "kwartalen"]),
        "de": EventLexicon(
            months: words("""
                januar jänner februar märz april mai juni juli august september oktober november dezember
                """),
            weekdays: [
                "monday": ["montag", "montagabend", "montagmorgen", "montagnachmittag", "montagnacht", "montags"],
                "tuesday": ["dienstag", "dienstagabend", "dienstagmorgen", "dienstagnachmittag", "dienstagnacht", "dienstags"],
                "wednesday": ["mittwoch", "mittwochabend", "mittwochmorgen", "mittwochnachmittag", "mittwochnacht", "mittwochs"],
                "thursday": ["donnerstag", "donnerstagabend", "donnerstagmorgen", "donnerstagnachmittag", "donnerstagnacht", "donnerstags"],
                "friday": ["freitag", "freitagabend", "freitagmorgen", "freitagnachmittag", "freitagnacht", "freitags"],
                "saturday": ["samstag", "samstagabend", "samstagmorgen", "samstagnachmittag", "samstagnacht", "samstags", "sonnabend"],
                "sunday": ["sonntag", "sonntagabend", "sonntagmorgen", "sonntagnachmittag", "sonntagnacht", "sonntags"]
            ],
            quarters: ["q1": ["erst"], "q2": ["zweit"], "q3": ["dritt"], "q4": ["viert"]],
            quarterWords: ["quartal"]),
    ]

    private static func words(_ list: String) -> [String] { list.split(whereSeparator: \.isWhitespace).map(String.init) }
}
