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
            let trackingPrefixes = [
                "utm_", "ref", "rss_source", "feedburner", "fbclid",
                "gclid", "mc_cid", "mc_eid", "yclid", "igshid"
            ]
            let filtered = queryItems.filter { item in
                let lowerName = item.name.lowercased()
                return !trackingPrefixes.contains { lowerName.hasPrefix($0) }
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

    /// Computes a fallback content fingerprint using SHA-256.
    /// Used when both GUID and canonical link are missing or generic.
    static func computeContentFingerprint(title: String, source: String, pubDate: Date) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let timestamp = Int(pubDate.timeIntervalSince1970)
        let raw = "\(normalizedTitle)|\(normalizedSource)|\(timestamp)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "fp_" + String(hex.prefix(16))
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
        pubDate: Date = Date()
    ) -> String {
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
