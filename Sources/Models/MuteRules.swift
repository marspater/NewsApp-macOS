import Foundation

/// The reader's own muting: publisher hostnames and topic words, kept apart. Nothing is muted by default and no preset
/// lists are imported. Matching is deterministic and literal, never a classification: a source rule covers an article
/// whose document URL is on that host or one of its subdomains; a topic rule covers an article whose headline or feed
/// summary contains the topic's words as whole words, in order and ignoring case. Lists apply the rules in SQLite before
/// pagination and say how many stories they hide; Saved Stories and History list everything.
struct MuteRules: Equatable, Hashable, Sendable {
    /// Rules kept per kind; muting is a short personal list, and every listed story is checked against all of them.
    static let limit = 200
    static let topicLength = 80

    /// Normalized publisher hostnames, such as `example.com`.
    private(set) var sources: [String] = []
    /// Topics as the reader typed them, with whitespace collapsed.
    private(set) var topics: [String] = []

    init(sources: [String] = [], topics: [String] = []) {
        for source in sources { addSource(source) }
        for topic in topics { addTopic(topic) }
    }

    var isEmpty: Bool { sources.isEmpty && topics.isEmpty }

    // MARK: - Editing

    /// Adds a publisher host from a hostname or URL. Returns the stored host, or nil if it is invalid, already muted or
    /// over the limit.
    @discardableResult
    mutating func addSource(_ raw: String) -> String? {
        guard sources.count < Self.limit, let host = Self.host(raw), !sources.contains(host) else { return nil }
        sources.append(host)
        return host
    }

    /// Adds a topic word or phrase. Returns the stored topic, or nil if it has no words, is too long, is already muted
    /// (in any letter case) or is over the limit.
    @discardableResult
    mutating func addTopic(_ raw: String) -> String? {
        let topic = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let phrase = Self.phrase(topic)
        guard topics.count < Self.limit, !phrase.isEmpty, topic.count <= Self.topicLength,
              !topics.contains(where: { Self.phrase($0) == phrase }) else { return nil }
        topics.append(topic)
        return topic
    }

    mutating func removeSource(_ host: String) {
        sources.removeAll { $0 == host }
    }

    mutating func removeTopic(_ topic: String) {
        topics.removeAll { $0 == topic }
    }

    // MARK: - Matching

    func mutes(_ article: FeedArticle) -> Bool {
        mutesSource(link: article.link) || mutesTopic(title: article.title, description: article.description)
    }

    func mutesSource(link: String) -> Bool {
        Self.sourceList(sourceParameter, mutes: link)
    }

    func mutesTopic(title: String, description: String) -> Bool {
        Self.topicList(topicParameter, mutes: title + "\n" + description)
    }

    /// The muted hosts covering the host of `link`.
    func matchedSources(link: String) -> [String] {
        guard let host = Self.linkHost(link) else { return [] }
        return sources.filter { Self.covers(rule: $0, host: host) }
    }

    /// The muted topics found as whole words in a headline or summary.
    func matchedTopics(title: String, description: String) -> [String] {
        let text = Self.paddedPhrase(title + "\n" + description)
        return topics.filter { text.contains(Self.paddedPhrase($0)) }
    }

    /// Hosts, one per line, as bound to `news_muted_source` in SQLite.
    var sourceParameter: String { sources.joined(separator: "\n") }
    /// Normalized topic phrases, one per line, as bound to `news_muted_topic` in SQLite.
    var topicParameter: String { topics.map(Self.phrase).joined(separator: "\n") }

    /// Whether a host list (one per line) covers the host of `link`.
    static func sourceList(_ list: String, mutes link: String) -> Bool {
        guard !list.isEmpty, let host = linkHost(link) else { return false }
        return list.split(separator: "\n").contains { covers(rule: String($0), host: host) }
    }

    /// Whether `text` contains any normalized phrase of the list (one per line) as whole words.
    static func topicList(_ list: String, mutes text: String) -> Bool {
        guard !list.isEmpty else { return false }
        let padded = paddedPhrase(text)
        return list.split(separator: "\n").contains { padded.contains(" " + String($0) + " ") }
    }

    /// The same host or one of its subdomains: `example.com` covers `news.example.com`, not `badexample.com`.
    static func covers(rule: String, host: String) -> Bool {
        host == rule || host.hasSuffix("." + rule)
    }

    // MARK: - Normalization

    /// Words compared by topic rules: letters and digits, lowercased. Everything else separates words, so "art" matches
    /// "Art's" and "art-house" but not "artist", and "covid-19" matches "COVID 19". Diacritics are significant.
    static func words(_ text: String) -> [Substring] {
        let lowered = text.lowercased()
        return lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    static func phrase(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    /// A phrase between single spaces, so containment of padded phrases is whole-word containment.
    static func paddedPhrase(_ text: String) -> String {
        " " + phrase(text) + " "
    }

    /// A muting host from a hostname or URL the reader typed: lowercased, without scheme, port, path or a leading `www.`.
    static func host(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let host = linkHost(candidate), host.contains("."), !host.hasPrefix("."), !host.hasPrefix("-"),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) else { return nil }
        return host
    }

    /// The publisher host of an article's document URL, lowercased and without a leading `www.` or trailing dot.
    static func linkHost(_ link: String) -> String? {
        guard var host = URLComponents(string: link)?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
}

/// Stories each rule covers in the stored library, for the muting settings.
struct MuteRuleCounts: Equatable, Sendable {
    var sources: [String: Int] = [:]
    var topics: [String: Int] = [:]
}
