import Foundation

/// Advanced HTML extraction pipeline performing character encoding normalization,
/// full HTML entity unescaping, link-density filtering, DOM container scoring,
/// and lead image extraction.
final class ContentExtractionPipeline: Sendable {
    static let shared = ContentExtractionPipeline()

    init() {}

    /// Downloads and extracts the core readability text and lead imagery for a story URL.
    func extractArticle(from link: String, allowHTTP: Bool = false) async -> (content: String?, imageUrl: String?) {
        guard let url = URL(string: link) else { return (nil, nil) }

        do {
            let (data, response) = try await SecureHTTPClient.shared.fetchArticleHTML(from: url, allowHTTP: allowHTTP)
            let html = decodeHTML(data: data, response: response)
            guard !html.isEmpty else { return (nil, nil) }

            // 1. Extract lead imagery
            let leadImage = extractLeadImage(from: html)

            // 2. Remove non-content tags & scripts
            let sanitizedHTML = stripNonContentTags(from: html)

            // 3. Extract best candidate container based on readability scoring
            let candidateHTML = extractBestContentContainer(from: sanitizedHTML) ?? sanitizedHTML

            // 4. Convert candidate HTML to text paragraphs
            let rawText = htmlToPlainText(candidateHTML)

            // 5. Prose validation & boilerplate stripping via ArticleIntelligence
            let cleanedText = ArticleIntelligence.shared.cleanContent(rawText)

            // Minimum length check (must be substantive prose)
            if cleanedText.count >= 200 {
                return (cleanedText, leadImage)
            } else {
                return (nil, leadImage)
            }
        } catch {
            return (nil, nil)
        }
    }

    // MARK: - 1. Character Encoding Normalization

    func decodeHTML(data: Data, response: HTTPURLResponse? = nil) -> String {
        // Try Content-Type header charset first
        if let contentType = response?.value(forHTTPHeaderField: "Content-Type") {
            if let charset = extractCharset(from: contentType) {
                if let decoded = decode(data: data, charset: charset) {
                    return decoded
                }
            }
        }

        // Try sniffing <meta charset="..."> or <meta http-equiv="Content-Type" ...>
        if let asciiPrefix = String(data: data.prefix(2048), encoding: .ascii) {
            if let charset = extractCharsetFromMeta(asciiPrefix) {
                if let decoded = decode(data: data, charset: charset) {
                    return decoded
                }
            }
        }

        // Standard fallbacks
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        if let win1252 = String(data: data, encoding: .windowsCP1252) {
            return win1252
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func extractCharset(from header: String) -> String? {
        let pattern = "charset=[\"']?([a-zA-Z0-9_-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        return String(header[range]).lowercased()
    }

    private func extractCharsetFromMeta(_ htmlSnippet: String) -> String? {
        let patterns = [
            "<meta[^>]+charset=[\"']?([a-zA-Z0-9_-]+)",
            "<meta[^>]+content=[\"'][^\"']*charset=([a-zA-Z0-9_-]+)"
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
               let match = regex.firstMatch(in: htmlSnippet, range: NSRange(htmlSnippet.startIndex..., in: htmlSnippet)),
               let range = Range(match.range(at: 1), in: htmlSnippet) {
                return String(htmlSnippet[range]).lowercased()
            }
        }
        return nil
    }

    private func decode(data: Data, charset: String) -> String? {
        switch charset {
        case "utf-8", "utf8":
            return String(data: data, encoding: .utf8)
        case "iso-8859-1", "latin1":
            return String(data: data, encoding: .isoLatin1)
        case "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252)
        case "utf-16", "utf16":
            return String(data: data, encoding: .utf16)
        default:
            return nil
        }
    }

    // MARK: - 2. Lead Image Extraction

    func extractLeadImage(from html: String) -> String? {
        let ogPatterns = [
            "<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:image[\"']",
            "<meta[^>]+name=[\"']twitter:image[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']twitter:image[\"']"
        ]
        for pattern in ogPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let candidate = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.hasPrefix("http") {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - 3. HTML Sanitization & Tag Stripping

    private struct RegexCache {
        static let removableTags: [NSRegularExpression] = {
            let tags = [
                "script", "style", "nav", "footer", "header", "aside", "form",
                "noscript", "iframe", "svg", "figcaption", "button", "select", "dialog"
            ]
            return tags.compactMap { tag in
                let pattern = "<\(tag)[\\s>].*?</\(tag)>"
                return try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
            }
        }()

        static let commentRegex: NSRegularExpression? = {
            try? NSRegularExpression(pattern: "<!--.*?-->", options: .dotMatchesLineSeparators)
        }()

        static let junkRegex: NSRegularExpression? = {
            let junkPattern = "<(?:div|section|aside)[^>]*(?:class|id)=[\"'][^\"']*(?:share|social|related|sidebar|widget|ad-|advertisement|comment|newsletter|promo|cookie|banner|consent)[^\"']*[\"'][^>]*>.*?</(?:div|section|aside)>"
            return try? NSRegularExpression(pattern: junkPattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        }()
    }

    private func stripNonContentTags(from html: String) -> String {
        var result = html

        // Remove script, style, nav, footer, header, form, etc.
        for regex in RegexCache.removableTags {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Remove HTML comments
        if let commentRegex = RegexCache.commentRegex {
            result = commentRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Strip non-content widget blocks by class/id
        if let junkRegex = RegexCache.junkRegex {
            result = junkRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        return result
    }

    // MARK: - 4. DOM Container Scoring & Link Density

    private func extractBestContentContainer(from html: String) -> String? {
        // Priority 1: <article> tag with good text length
        if let article = extractFirstTag(from: html, tag: "article") {
            if article.count > 500 && computeLinkDensity(article) < 0.4 {
                return article
            }
        }

        // Priority 2: Semantic class containers
        let contentPatterns = [
            "entry-content", "post-content", "article-body", "article__body",
            "story-body", "story-body__inner", "caas-body", "article-text",
            "story-content", "post-body", "content-body", "article__content",
            "field-body", "c-entry-content", "article-content", "main-content"
        ]

        for className in contentPatterns {
            let pattern = "<(?:div|section|main|article)[^>]*class=\"[^\"]*\\b\(className)\\b[^\"]*\"[^>]*>(.*)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let candidate = String(html[range])
                if candidate.count > 500 && computeLinkDensity(candidate) < 0.45 {
                    return candidate
                }
            }
        }

        return nil
    }

    private func extractFirstTag(from html: String, tag: String) -> String? {
        guard let openPattern = try? NSRegularExpression(pattern: "<\(tag)[\\s>]", options: .caseInsensitive),
              let openMatch = openPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let openRange = Range(openMatch.range, in: html) else { return nil }

        let startIdx = openRange.lowerBound
        let afterOpen = html[startIdx...]
        let closeTag = "</\(tag)>"
        guard let closeRange = afterOpen.range(of: closeTag, options: .caseInsensitive) else { return nil }

        return String(html[startIdx..<closeRange.upperBound])
    }

    /// Computes link density: ratio of text inside <a> tags versus total text.
    func computeLinkDensity(_ htmlSnippet: String) -> Double {
        let plainTotal = htmlToPlainText(htmlSnippet)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard plainTotal.count > 0 else { return 0.0 }

        var linkTextLength = 0
        let aPattern = "<a[^>]*>(.*?)</a>"
        if let regex = try? NSRegularExpression(pattern: aPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let matches = regex.matches(in: htmlSnippet, range: NSRange(htmlSnippet.startIndex..., in: htmlSnippet))
            for match in matches {
                if let r = Range(match.range(at: 1), in: htmlSnippet) {
                    let linkContent = htmlToPlainText(String(htmlSnippet[r]))
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    linkTextLength += linkContent.count
                }
            }
        }

        return min(1.0, Double(linkTextLength) / Double(plainTotal.count))
    }

    // MARK: - 5. HTML to Plain Text & Entity Unescaping

    func htmlToPlainText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</h[1-6]>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        return decodeHTMLEntities(text)
    }

    /// Comprehensive HTML entity decoder supporting standard named entities,
    /// decimal numeric entities (&#1234;), and hex entities (&#x1F600;).
    func decodeHTMLEntities(_ text: String) -> String {
        var result = text

        // 1. Common named entities
        let namedEntities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…",
            "&ldquo;": "\u{201C}",
            "&rdquo;": "\u{201D}",
            "&lsquo;": "\u{2018}",
            "&rsquo;": "\u{2019}",
            "&copy;": "©",
            "&reg;": "®",
            "&trade;": "™",
            "&bull;": "•",
            "&middot;": "·",
            "&euro;": "€",
            "&pound;": "£",
            "&yen;": "¥",
            "&cent;": "¢",
            "&#8211;": "–",
            "&#8212;": "—",
            "&#8216;": "\u{2018}",
            "&#8217;": "\u{2019}",
            "&#8220;": "\u{201C}",
            "&#8221;": "\u{201D}",
            "&#8230;": "…"
        ]

        for (entity, char) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: char)
        }

        // 2. Numeric decimal entities (&#[0-9]+;)
        if let decRegex = try? NSRegularExpression(pattern: "&#([0-9]{2,7});") {
            let matches = decRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: result),
                   let numRange = Range(match.range(at: 1), in: result),
                   let code = UInt32(result[numRange]),
                   let scalar = UnicodeScalar(code) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }

        // 3. Hexadecimal numeric entities (&#x[0-9a-fA-F]+;)
        if let hexRegex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]{2,6});") {
            let matches = hexRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: result),
                   let numRange = Range(match.range(at: 1), in: result),
                   let code = UInt32(result[numRange], radix: 16),
                   let scalar = UnicodeScalar(code) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }

        return result
    }
}
