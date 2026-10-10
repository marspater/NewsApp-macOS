import Foundation
import CryptoKit

/// Encapsulates deterministic article identity computation, URL canonicalization,
/// and legacy ID reconciliation across syndication formats.
struct ArticleIdentity: Sendable {

    /// Normalizes and canonicalizes a URL string.
    /// - Strips whitespace and newlines.
    /// - Lowercases hostname.
    /// - Upgrades insecure http:// scheme to https://.
    /// - Strips advertising, referral, and analytics tracking parameters.
    /// - Strips trailing slash on path.
    static func canonicalizeURL(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return trimmed
        }
        
        components.host = components.host?.lowercased()
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        
        if let queryItems = components.queryItems {
            let trackingNames: Set<String> = [
                "ref", "rss_source", "feedburner", "fbclid",
                "gclid", "mc_cid", "mc_eid", "yclid", "igshid"
            ]
            let filtered = queryItems.filter { item in
                let lowerName = item.name.lowercased()
                return !lowerName.hasPrefix("utm_") && !trackingNames.contains(lowerName)
            }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        
        var path = components.path
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
            components.path = path
        }
        
        return components.url?.absoluteString ?? trimmed
    }

    /// Computes a lowercase hex SHA-256 string for the given UTF-8 text.
    static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes a fallback content fingerprint using SHA-256.
    /// Used when both GUID and canonical link are missing or generic.
    static func computeContentFingerprint(title: String, source: String, pubDate: Date) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let timestamp = Int(pubDate.timeIntervalSince1970)
        let raw = "\(normalizedTitle)|\(normalizedSource)|\(timestamp)"
        return "fp_" + String(sha256Hex(raw).prefix(16))
    }

    /// Exact publisher text is supporting evidence, never a global document key.
    static func publisherTextFingerprints(_ article: FeedArticle) -> [String] {
        guard article.pubDate != DateParser.unknownDate,
              article.pubDate.timeIntervalSince1970.isFinite,
              let url = URLComponents(string: article.normalizedLink),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              ["http", "https"].contains(url.scheme ?? ""),
              !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
                || !(url.query ?? "").isEmpty else { return [] }
        func normalized(_ text: String) -> String {
            text.precomposedStringWithCanonicalMapping
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let title = normalized(article.title)
        guard !title.isEmpty else { return [] }
        let publisher = host + (url.port.map { ":\($0)" } ?? "")
        return [("description", article.description), ("body", article.fullContent ?? "")].compactMap { kind, text in
            // ponytail: conservative exact text only; tune recall against the holdout,
            // rather than merging short teasers or truncated large documents.
            guard text.utf8.count <= 262_144 else { return nil }
            let content = normalized(text)
            guard content.count >= 400, content.split(separator: " ").count >= 40 else { return nil }
            let fields = ["publisher-text-v1", publisher, normalized(article.source), kind, title,
                          String(article.pubDate.timeIntervalSince1970), content]
            let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
            return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// GUIDs identify documents only within the configured subscription URL.
    static func scopedGUID(_ guid: String?, feedURL: String?) -> String? {
        guard let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty,
              let feedURL, !feedURL.isEmpty else { return nil }
        // AppSettings normalizes subscriptions. Keep their scheme and every query
        // parameter: document URL tracking rules must not collapse distinct feeds.
        let feed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feed.isEmpty else { return nil }
        let normalizedGUID = computeId(guid: guid, link: "")
        let digest = SHA256.hash(data: Data("\(feed.utf8.count):\(feed)\(normalizedGUID)".utf8))
        return "feed-guid:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes deterministic article identity using the three-tier resolution:
    /// 1. Stable feed GUID (if non-empty; if URL-shaped, canonicalized)
    /// 2. Canonicalized article URL
    /// 3. Fallback SHA-256 content fingerprint
    static func computeId(
        guid: String?,
        link: String,
        title: String = "",
        source: String = "",
        pubDate: Date = Date(),
        feedURL: String? = nil
    ) -> String {
        if let scoped = scopedGUID(guid, feedURL: feedURL) { return scoped }
        if let g = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
            if g.hasPrefix("http://") || g.hasPrefix("https://") {
                return canonicalizeURL(g)
            }
            return g
        }
        
        let canonical = canonicalizeURL(link)
        if !canonical.isEmpty && canonical != "https://" && canonical != "http://" {
            return canonical
        }
        
        return computeContentFingerprint(title: title, source: source, pubDate: pubDate)
    }

    /// Reconciles a legacy identifier (e.g. from UserDefaults read/saved lists)
    /// into canonical form.
    static func reconcileLegacyId(_ legacyId: String) -> String {
        let trimmed = legacyId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return canonicalizeURL(trimmed)
        }
        return trimmed
    }
}
