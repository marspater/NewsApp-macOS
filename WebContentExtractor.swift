import Foundation

/// Extracts full article text and lead imagery from remote web pages using
/// bounded streaming downloads via SecureHTTPClient and readability heuristics.
final class WebContentExtractor: Sendable {

    static func fetchFullContentAndImage(for link: String, allowHTTP: Bool = false) async -> (String?, String?) {
        guard let url = URL(string: link) else { return (nil, nil) }

        do {
            let (data, _) = try await SecureHTTPClient.shared.fetchArticleHTML(from: url, allowHTTP: allowHTTP)
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return (nil, nil)
            }

            // Extract og:image
            var extractedImageUrl: String? = nil
            let ogPatterns = [
                "<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)[\"']",
                "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:image[\"']",
                "<meta[^>]+name=[\"']twitter:image[\"'][^>]+content=[\"']([^\"']+)[\"']"
            ]
            for pattern in ogPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let range = Range(match.range(at: 1), in: html) {
                    let candidate = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.hasPrefix("http") {
                        extractedImageUrl = candidate
                        break
                    }
                }
            }

            // Remove scripts, styles, navs, footers, etc.
            let cleanedHTML = removeBoilerplateBlocks(from: html)

            // Extract main content container
            let candidateHTML = extractArticleContainer(from: cleanedHTML) ?? cleanedHTML

            // Convert to plain text
            let rawText = stripHTMLRegex(candidateHTML)

            // NLP-based content cleanup
            let result = AIManager.shared.cleanExtractedContent(rawText)

            if result.count > 200 {
                return (result, extractedImageUrl)
            }
            return (nil, extractedImageUrl)
        } catch {
            return (nil, nil)
        }
    }

    // MARK: - HTML Processing Helpers

    private static func removeBoilerplateBlocks(from html: String) -> String {
        var result = html
        for tag in ["script", "style", "nav", "footer", "aside", "header", "form", "noscript", "iframe", "svg", "figcaption"] {
            let pattern = "<\(tag)[\\s>].*?</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }
        if let commentRegex = try? NSRegularExpression(pattern: "<!--.*?-->", options: .dotMatchesLineSeparators) {
            result = commentRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        let junkClassPattern = "<div[^>]*class=\"[^\"]*(?:share|social|related|sidebar|widget|ad-|comment|newsletter|promo|footer|nav)[^\"]*\"[^>]*>.*?</div>"
        if let junkRegex = try? NSRegularExpression(pattern: junkClassPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            result = junkRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    private static func extractArticleContainer(from html: String) -> String? {
        if let articleContent = extractFirstTag(from: html, tag: "article") {
            if articleContent.count > 500 { return articleContent }
        }

        let contentPatterns = [
            "entry-content", "post-content", "article-body", "article__body",
            "story-body", "story-body__inner", "caas-body", "article-text",
            "story-content", "post-body", "content-body", "article__content",
            "field-body", "c-entry-content", "article-content",
            "content", "rich-text", "post_content", "main-content", "article",
            "post-entry", "entry", "story", "page-content"
        ]

        for className in contentPatterns {
            let pattern = "<(?:div|section|main|article)[^>]*class=\"[^\"]*\\b\(className)\\b[^\"]*\"[^>]*>(.*)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let content = String(html[range])
                if content.count > 500 { return content }
            }
        }
        return nil
    }

    private static func extractFirstTag(from html: String, tag: String) -> String? {
        guard let openPattern = try? NSRegularExpression(pattern: "<\(tag)[\\s>]", options: .caseInsensitive),
              let openMatch = openPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let openRange = Range(openMatch.range, in: html) else { return nil }

        let startIdx = openRange.lowerBound
        let afterOpen = html[startIdx...]
        let closeTag = "</\(tag)>"
        guard let closeRange = afterOpen.range(of: closeTag, options: .caseInsensitive) else { return nil }

        return String(html[startIdx..<closeRange.upperBound])
    }

    private static func stripHTMLRegex(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</h[1-6]>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode HTML entities
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&#8217;", with: "\u{2019}")
        result = result.replacingOccurrences(of: "&#8220;", with: "\u{201C}")
        result = result.replacingOccurrences(of: "&#8221;", with: "\u{201D}")
        result = result.replacingOccurrences(of: "&#8212;", with: "—")
        result = result.replacingOccurrences(of: "&#8211;", with: "–")

        return result
    }
}
