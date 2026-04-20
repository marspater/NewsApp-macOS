import Foundation

class FeedManager: NSObject, ObservableObject, XMLParserDelegate {
    @Published var articles: [FeedArticle] = []
    
    private var currentElement = ""
    private var currentTitle = ""
    private var currentDescription = ""
    private var currentLink = ""
    private var currentPubDate = ""
    private var parsedArticles: [FeedArticle] = []
    
    // Sample feed for initialization testing
    private let feedURLs = [
        "https://techcrunch.com/feed/"
    ]
    
    private let cacheKey = "feed_articles_cache"
    
    override init() {
        super.init()
        loadCachedArticles()
    }
    
    func loadCachedArticles() {
        if let cached = CacheManager.shared.load(forKey: cacheKey, as: [FeedArticle].self) {
            self.articles = cached
        }
    }
    
    func fetchFeeds() {
        parsedArticles = []
        
        for urlString in feedURLs {
            guard let url = URL(string: urlString) else { continue }
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
            
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let data = data, error == nil else { return }
                
                let parser = XMLParser(data: data)
                parser.delegate = self
                parser.parse()
            }
            task.resume()
        }
    }
    
    func parserDidEndDocument(_ parser: XMLParser) {
        DispatchQueue.main.async {
            // Sort by newest
            self.parsedArticles.sort { $0.pubDate > $1.pubDate }
            // Deduplicate if needed and update published state
            self.articles = self.parsedArticles 
            // Save to cache layer automatically after new fetches
            CacheManager.shared.save(self.articles, forKey: self.cacheKey)
        }
    }
    
    private var currentImageUrl = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if currentElement == "item" {
            currentTitle = ""
            currentDescription = ""
            currentLink = ""
            currentPubDate = ""
            currentImageUrl = ""
        }
        
        // Extract Image from standard RSS enclosure or media:content
        if currentElement == "enclosure" || currentElement == "media:content" {
            if let type = attributeDict["type"], type.starts(with: "image"), let url = attributeDict["url"] {
                currentImageUrl = url
            } else if let url = attributeDict["url"], currentImageUrl.isEmpty {
                currentImageUrl = url
            }
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "title": currentTitle += string
        case "description": currentDescription += string
        case "link": currentLink += string
        case "pubDate": currentPubDate += string
        default: break
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            let formatter = DateFormatter()
            formatter.dateFormat = "E, d MMM yyyy HH:mm:ss Z"
            let date = formatter.date(from: currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date()
            
            // Clean HTML out of description for a nice summary
            let cleanDesc = currentDescription.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil).trimmingCharacters(in: .whitespacesAndNewlines)
            
            let article = FeedArticle(
                title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                link: currentLink.trimmingCharacters(in: .whitespacesAndNewlines),
                description: cleanDesc,
                pubDate: date,
                source: "Network",
                imageUrl: currentImageUrl.isEmpty ? nil : currentImageUrl
            )
            parsedArticles.append(article)
        }
    }
}
