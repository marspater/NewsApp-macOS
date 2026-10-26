import Foundation

/// Pure, testable parser for NewsApp custom URL schemes (`feed:` and `news:`).
public struct NewsURLParser: Sendable {
    public enum Destination: Equatable, Sendable {
        case addFeed(url: URL)
        case story(id: String)
    }

    /// Parses an incoming URL into a navigation destination or feed subscription request.
    /// - Parameters:
    ///   - url: The incoming URL.
    ///   - allowInsecureHTTP: When `false`, plaintext `http://` feeds are automatically upgraded to `https://`.
    /// - Returns: A `Destination` if the URL is valid and recognized, or `nil` if malformed or unsupported.
    public static func parse(url: URL, allowInsecureHTTP: Bool) -> Destination? {
        guard let scheme = url.scheme?.lowercased() else { return nil }

        switch scheme {
        case "feed":
            return parseFeedURL(url, allowInsecureHTTP: allowInsecureHTTP)
        case "news":
            return parseNewsURL(url)
        default:
            return nil
        }
    }

    /// Convenience overload accepting a raw URL string.
    public static func parse(urlString: String, allowInsecureHTTP: Bool) -> Destination? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return parse(url: url, allowInsecureHTTP: allowInsecureHTTP)
    }

    // MARK: - Private Helpers

    private static func parseFeedURL(_ url: URL, allowInsecureHTTP: Bool) -> Destination? {
        let urlString = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard urlString.lowercased().hasPrefix("feed:") else { return nil }

        var rest = String(urlString.dropFirst(5))
        if rest.hasPrefix("//") {
            rest = String(rest.dropFirst(2))
        }

        let cleaned = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // Must not be empty or solely slashes
        if cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            return nil
        }

        let lower = cleaned.lowercased()
        let targetURLString: String

        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            targetURLString = cleaned
        } else {
            // Reject explicitly disallowed schemes like javascript:, file:, data:, ftp://
            if lower.contains("://") { return nil }
            if let colonIdx = lower.firstIndex(of: ":") {
                let before = lower[..<colonIdx]
                let after = lower[lower.index(after: colonIdx)...]
                if !before.contains("/") {
                    let portPart = after.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
                    if portPart.isEmpty || !portPart.allSatisfy({ $0.isNumber }) {
                        return nil
                    }
                }
            }
            targetURLString = "https://" + cleaned
        }

        guard
            let normalized = AppSettings.normalizeFeedURL(targetURLString, allowInsecureHTTP: allowInsecureHTTP),
            let targetURL = URL(string: normalized),
            let targetScheme = targetURL.scheme?.lowercased(),
            targetScheme == "https" || (allowInsecureHTTP && targetScheme == "http"),
            let targetHost = targetURL.host, !targetHost.isEmpty
        else {
            return nil
        }

        return .addFeed(url: targetURL)
    }

    private static func parseNewsURL(_ url: URL) -> Destination? {
        let storyID: String
        if let host = url.host?.lowercased(), !host.isEmpty {
            guard host == "story" else { return nil }
            storyID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            let comps = url.pathComponents.filter { $0 != "/" }
            guard comps.first?.lowercased() == "story", comps.count >= 2 else { return nil }
            storyID = comps.dropFirst().joined(separator: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        guard !storyID.isEmpty else { return nil }
        let decodedID = storyID.removingPercentEncoding ?? storyID
        guard !decodedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .story(id: decodedID)
    }
}
