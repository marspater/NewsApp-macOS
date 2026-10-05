import Foundation

/// A curated starter feed. Entries are snapshots verified on `FeedCatalog.verifiedOn`, not guarantees: publishers move
/// and retire feeds, so live state comes from the feed's own health after subscribing, never from this record.
/// Subscribing is always an explicit choice; nothing here is subscribed automatically.
struct CatalogFeed: Identifiable, Equatable, Sendable {
    enum Topic: String, CaseIterable, Sendable {
        case general, politics, business, technology, science, health, culture, food, lifestyle
    }

    /// How much article text the feed itself carries when it was verified.
    enum FullText: String, Sendable {
        case full, partial, summary
    }

    /// `available`: feed and article pages were readable by an automated client. `previewOnly`: the feed works, but article
    /// pages refused or could not be verified for an automated reader, so the reader may show the feed preview instead.
    enum Availability: String, Sendable {
        case available, previewOnly
    }

    let id: String
    let title: String
    let publisher: String
    /// Already in `AppSettings.normalizeFeedURL` form, so subscribed state compares by plain equality.
    let url: String
    /// BCP 47 language code of the feed content.
    let language: String
    /// Publisher's home country (ISO 3166-1 alpha-2), or `global` for outlets without a single home country.
    let region: String
    let topic: Topic
    let set: CatalogSet
    let fullText: FullText
    let hasImages: Bool
    let availability: Availability
}

/// An opt-in group of catalog feeds.
enum CatalogSet: String, CaseIterable, Identifiable, Sendable {
    case world, politics, business, technology, scienceHealth, cultureLifestyle, ukraine, europe, regional

    var id: String { rawValue }

    /// Sets with at least one feed in a supported language; parked sets are not shown.
    static var offered: [CatalogSet] { allCases.filter { !FeedCatalog.feeds(in: $0).isEmpty } }

    var title: String {
        switch self {
        case .world: return "World news"
        case .politics: return "Politics"
        case .business: return "Business"
        case .technology: return "Technology"
        case .scienceHealth: return "Science & health"
        case .cultureLifestyle: return "Culture, food & lifestyle"
        case .ukraine: return "Ukraine"
        case .europe: return "Europe"
        case .regional: return "Asia, Middle East & Africa"
        }
    }

    var summary: String {
        switch self {
        case .world: return "International news from public broadcasters and major newsrooms, in English."
        case .politics: return "Politics and policy coverage from the US and the UK."
        case .business: return "Markets, companies and the economy."
        case .technology: return "Technology, computing and security reporting."
        case .scienceHealth: return "Science, space and health reporting."
        case .cultureLifestyle: return "Film, television, arts, food and everyday life."
        case .ukraine: return "English-language outlets covering Ukraine."
        case .europe: return "National news in German, French, Italian, Dutch and Polish."
        case .regional: return "English-language news from Asia, the Middle East and Africa."
        }
    }
}

enum FeedCatalog {
    /// Date the entries below were last fetched and checked for freshness, parseability and access.
    static let verifiedOn = "2026-10-01"

    /// Languages offered in production. Event matching does not work without a word-class model, which macOS lacks for
    /// the other catalog languages (#264), so their entries stay below but are parked until it does.
    static let supportedLanguages: Set<String> = ["en"]

    static func feeds(in set: CatalogSet) -> [CatalogFeed] {
        feeds.filter { $0.set == set }
    }

    /// The feeds the app offers.
    static let feeds = allFeeds.filter { supportedLanguages.contains($0.language) }
    /// Entries kept for later; earlier subscriptions to them end at launch (`AppSettings`).
    static let parkedFeeds = allFeeds.filter { !supportedLanguages.contains($0.language) }

    static let allFeeds: [CatalogFeed] = [
        CatalogFeed(id: "bbc-world", title: "BBC News · World", publisher: "BBC News",
                    url: "https://feeds.bbci.co.uk/news/world/rss.xml",
                    language: "en", region: "GB", topic: .general, set: .world,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "guardian-world", title: "The Guardian · World", publisher: "The Guardian",
                    url: "https://www.theguardian.com/world/rss",
                    language: "en", region: "GB", topic: .general, set: .world,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "al-jazeera", title: "Al Jazeera English", publisher: "Al Jazeera",
                    url: "https://www.aljazeera.com/xml/rss/all.xml",
                    language: "en", region: "QA", topic: .general, set: .world,
                    fullText: .summary, hasImages: false, availability: .available),
        CatalogFeed(id: "dw-english", title: "DW · Top stories", publisher: "Deutsche Welle",
                    url: "https://rss.dw.com/xml/rss-en-top",
                    language: "en", region: "DE", topic: .general, set: .world,
                    fullText: .summary, hasImages: false, availability: .available),
        CatalogFeed(id: "france-24", title: "France 24 · English", publisher: "France 24",
                    url: "https://www.france24.com/en/rss",
                    language: "en", region: "FR", topic: .general, set: .world,
                    fullText: .summary, hasImages: true, availability: .previewOnly),
        CatalogFeed(id: "cbc-world", title: "CBC News · World", publisher: "CBC News",
                    url: "https://www.cbc.ca/webfeed/rss/rss-world",
                    language: "en", region: "CA", topic: .general, set: .world,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "euronews", title: "Euronews · News", publisher: "Euronews",
                    url: "https://www.euronews.com/rss?level=theme&name=news",
                    language: "en", region: "FR", topic: .general, set: .world,
                    fullText: .summary, hasImages: false, availability: .available),
        CatalogFeed(id: "politico", title: "Politico · Politics", publisher: "Politico",
                    url: "https://rss.politico.com/politics-news.xml",
                    language: "en", region: "US", topic: .politics, set: .politics,
                    fullText: .full, hasImages: true, availability: .previewOnly),
        CatalogFeed(id: "the-hill", title: "The Hill · News", publisher: "The Hill",
                    url: "https://thehill.com/feed",
                    language: "en", region: "US", topic: .politics, set: .politics,
                    fullText: .summary, hasImages: true, availability: .previewOnly),
        CatalogFeed(id: "bbc-politics", title: "BBC News · Politics", publisher: "BBC News",
                    url: "https://feeds.bbci.co.uk/news/politics/rss.xml",
                    language: "en", region: "GB", topic: .politics, set: .politics,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "guardian-politics", title: "The Guardian · Politics", publisher: "The Guardian",
                    url: "https://www.theguardian.com/politics/rss",
                    language: "en", region: "GB", topic: .politics, set: .politics,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "bbc-business", title: "BBC News · Business", publisher: "BBC News",
                    url: "https://feeds.bbci.co.uk/news/business/rss.xml",
                    language: "en", region: "GB", topic: .business, set: .business,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "guardian-business", title: "The Guardian · Business", publisher: "The Guardian",
                    url: "https://www.theguardian.com/uk/business/rss",
                    language: "en", region: "GB", topic: .business, set: .business,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "cnbc", title: "CNBC · Top news", publisher: "CNBC",
                    url: "https://www.cnbc.com/id/100003114/device/rss/rss.html",
                    language: "en", region: "US", topic: .business, set: .business,
                    fullText: .summary, hasImages: false, availability: .available),
        CatalogFeed(id: "fast-company", title: "Fast Company · Latest", publisher: "Fast Company",
                    url: "https://www.fastcompany.com/latest/rss",
                    language: "en", region: "US", topic: .business, set: .business,
                    fullText: .full, hasImages: true, availability: .previewOnly),
        CatalogFeed(id: "ars-technica", title: "Ars Technica", publisher: "Ars Technica",
                    url: "https://feeds.arstechnica.com/arstechnica/index",
                    language: "en", region: "US", topic: .technology, set: .technology,
                    fullText: .partial, hasImages: true, availability: .available),
        CatalogFeed(id: "engadget", title: "Engadget", publisher: "Engadget",
                    url: "https://www.engadget.com/rss.xml",
                    language: "en", region: "US", topic: .technology, set: .technology,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "techcrunch", title: "TechCrunch", publisher: "TechCrunch",
                    url: "https://techcrunch.com/feed",
                    language: "en", region: "US", topic: .technology, set: .technology,
                    fullText: .summary, hasImages: false, availability: .available),
        CatalogFeed(id: "ieee-spectrum", title: "IEEE Spectrum", publisher: "IEEE Spectrum",
                    url: "https://spectrum.ieee.org/feeds/feed.rss",
                    language: "en", region: "US", topic: .technology, set: .technology,
                    fullText: .partial, hasImages: true, availability: .available),
        CatalogFeed(id: "bleepingcomputer", title: "BleepingComputer", publisher: "BleepingComputer",
                    url: "https://www.bleepingcomputer.com/feed",
                    language: "en", region: "US", topic: .technology, set: .technology,
                    fullText: .summary, hasImages: false, availability: .available),
        CatalogFeed(id: "hackaday", title: "Hackaday", publisher: "Hackaday",
                    url: "https://hackaday.com/blog/feed",
                    language: "en", region: "US", topic: .technology, set: .technology,
                    fullText: .full, hasImages: true, availability: .available),
        CatalogFeed(id: "science-news", title: "Science News", publisher: "Science News",
                    url: "https://www.sciencenews.org/feed",
                    language: "en", region: "US", topic: .science, set: .scienceHealth,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "quanta", title: "Quanta Magazine", publisher: "Quanta Magazine",
                    url: "https://www.quantamagazine.org/feed",
                    language: "en", region: "US", topic: .science, set: .scienceHealth,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "nasa", title: "NASA", publisher: "NASA",
                    url: "https://www.nasa.gov/feed",
                    language: "en", region: "US", topic: .science, set: .scienceHealth,
                    fullText: .full, hasImages: true, availability: .available),
        CatalogFeed(id: "bbc-science", title: "BBC News · Science & Environment", publisher: "BBC News",
                    url: "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml",
                    language: "en", region: "GB", topic: .science, set: .scienceHealth,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "kff-health-news", title: "KFF Health News", publisher: "KFF Health News",
                    url: "https://kffhealthnews.org/feed",
                    language: "en", region: "US", topic: .health, set: .scienceHealth,
                    fullText: .full, hasImages: true, availability: .available),
        CatalogFeed(id: "variety", title: "Variety", publisher: "Variety",
                    url: "https://variety.com/feed",
                    language: "en", region: "US", topic: .culture, set: .cultureLifestyle,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "guardian-culture", title: "The Guardian · Culture", publisher: "The Guardian",
                    url: "https://www.theguardian.com/uk/culture/rss",
                    language: "en", region: "GB", topic: .culture, set: .cultureLifestyle,
                    fullText: .partial, hasImages: true, availability: .available),
        CatalogFeed(id: "eater", title: "Eater", publisher: "Eater",
                    url: "https://www.eater.com/rss/index.xml",
                    language: "en", region: "US", topic: .food, set: .cultureLifestyle,
                    fullText: .full, hasImages: true, availability: .available),
        CatalogFeed(id: "guardian-food", title: "The Guardian · Food", publisher: "The Guardian",
                    url: "https://www.theguardian.com/food/rss",
                    language: "en", region: "GB", topic: .food, set: .cultureLifestyle,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "lifehacker", title: "Lifehacker", publisher: "Lifehacker",
                    url: "https://lifehacker.com/feed/rss",
                    language: "en", region: "US", topic: .lifestyle, set: .cultureLifestyle,
                    fullText: .full, hasImages: true, availability: .available),
        CatalogFeed(id: "ukrainska-pravda", title: "Українська правда", publisher: "Українська правда",
                    url: "https://www.pravda.com.ua/rss",
                    language: "uk", region: "UA", topic: .general, set: .ukraine,
                    fullText: .partial, hasImages: true, availability: .previewOnly),
        CatalogFeed(id: "ukrainska-pravda-en", title: "Ukrainska Pravda · English", publisher: "Ukrainska Pravda",
                    url: "https://www.pravda.com.ua/eng/rss",
                    language: "en", region: "UA", topic: .general, set: .ukraine,
                    fullText: .partial, hasImages: true, availability: .available),
        CatalogFeed(id: "ukrinform", title: "Укрінформ · Останні новини", publisher: "Укрінформ",
                    url: "https://www.ukrinform.ua/rss/block-lastnews",
                    language: "uk", region: "UA", topic: .general, set: .ukraine,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "kyiv-independent", title: "The Kyiv Independent", publisher: "The Kyiv Independent",
                    url: "https://kyivindependent.com/news-archive/rss",
                    language: "en", region: "UA", topic: .general, set: .ukraine,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "radio-svoboda", title: "Радіо Свобода", publisher: "Радіо Свобода",
                    url: "https://www.radiosvoboda.org/api/zrqiteuuir",
                    language: "uk", region: "UA", topic: .general, set: .ukraine,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "ekonomichna-pravda", title: "Економічна правда", publisher: "Економічна правда",
                    url: "https://epravda.com.ua/rss",
                    language: "uk", region: "UA", topic: .business, set: .ukraine,
                    fullText: .partial, hasImages: false, availability: .available),
        CatalogFeed(id: "tagesschau", title: "tagesschau", publisher: "ARD Tagesschau",
                    url: "https://www.tagesschau.de/index~rss2.xml",
                    language: "de", region: "DE", topic: .general, set: .europe,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "dw-deutsch", title: "DW Deutsch", publisher: "Deutsche Welle",
                    url: "https://rss.dw.com/rdf/rss-de-all",
                    language: "de", region: "DE", topic: .general, set: .europe,
                    fullText: .summary, hasImages: false, availability: .available),
        CatalogFeed(id: "ansa", title: "ANSA", publisher: "ANSA",
                    url: "https://www.ansa.it/sito/ansait_rss.xml",
                    language: "it", region: "IT", topic: .general, set: .europe,
                    fullText: .summary, hasImages: false, availability: .available),
        CatalogFeed(id: "nos", title: "NOS Nieuws", publisher: "NOS",
                    url: "https://feeds.nos.nl/nosnieuwsalgemeen",
                    language: "nl", region: "NL", topic: .general, set: .europe,
                    fullText: .full, hasImages: true, availability: .available),
        CatalogFeed(id: "onet-wiadomosci", title: "Onet · Wiadomości", publisher: "Onet",
                    url: "https://wiadomosci.onet.pl/.feed",
                    language: "pl", region: "PL", topic: .general, set: .europe,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "franceinfo", title: "franceinfo · Titres", publisher: "franceinfo",
                    url: "https://www.franceinfo.fr/titres.rss",
                    language: "fr", region: "FR", topic: .general, set: .europe,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "the-hindu", title: "The Hindu · International", publisher: "The Hindu",
                    url: "https://www.thehindu.com/news/international/feeder/default.rss",
                    language: "en", region: "IN", topic: .general, set: .regional,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "dawn", title: "Dawn", publisher: "Dawn",
                    url: "https://www.dawn.com/feeds/home",
                    language: "en", region: "PK", topic: .general, set: .regional,
                    fullText: .full, hasImages: true, availability: .previewOnly),
        CatalogFeed(id: "africanews", title: "Africanews", publisher: "Africanews",
                    url: "https://www.africanews.com/feed/rss",
                    language: "en", region: "global", topic: .general, set: .regional,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "arab-news", title: "Arab News", publisher: "Arab News",
                    url: "https://www.arabnews.com/rss.xml",
                    language: "en", region: "SA", topic: .general, set: .regional,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "times-of-india", title: "The Times of India · Top stories", publisher: "The Times of India",
                    url: "https://timesofindia.indiatimes.com/rssfeedstopstories.cms",
                    language: "en", region: "IN", topic: .general, set: .regional,
                    fullText: .summary, hasImages: true, availability: .available),
        CatalogFeed(id: "cna", title: "CNA · World and Asia", publisher: "CNA",
                    url: "https://www.channelnewsasia.com/rssfeeds/8395884",
                    language: "en", region: "SG", topic: .general, set: .regional,
                    fullText: .summary, hasImages: true, availability: .available),
    ]
}
