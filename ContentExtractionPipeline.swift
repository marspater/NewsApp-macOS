import Foundation
import os

// MARK: - Extraction Outcome & Diagnostics

public enum ExtractionOutcome: Equatable, Sendable {
    case success(content: String, imageUrl: String?)
    case networkError(reason: String)
    case httpError(status: Int)
    case securityBlocked(reason: String)
    case emptyContent
    case contentParsingFailed(reason: String)
    case qualityValidationFailed(reason: String)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var content: String? {
        if case .success(let c, _) = self { return c }
        return nil
    }

    public var imageUrl: String? {
        if case .success(_, let img) = self { return img }
        return nil
    }

    public var failureReason: String? {
        switch self {
        case .success:
            return nil
        case .networkError(let reason):
            return reason
        case .httpError(let status):
            return "HTTP Error \(status)"
        case .securityBlocked(let reason):
            return "Security blocked: \(reason)"
        case .emptyContent:
            return "Empty content returned by publisher"
        case .contentParsingFailed(let reason):
            return reason
        case .qualityValidationFailed(let reason):
            return reason
        }
    }
}

// MARK: - Content Quality Validator

public struct ContentQualityValidator: Sendable {
    public enum ValidationResult: Equatable {
        case valid
        case rejected(reason: String)
    }

    /// Validates candidate extracted paragraphs to ensure high editorial reading standards.
    public static func validate(paragraphs: [String]) -> ValidationResult {
        guard !paragraphs.isEmpty else {
            return .rejected(reason: "No readable paragraphs found")
        }

        let totalChars = paragraphs.reduce(0) { $0 + $1.count }
        guard totalChars >= 150 else {
            return .rejected(reason: "Content too short (\(totalChars) characters, minimum 150 required)")
        }

        if paragraphs.count < 2 && totalChars < 250 {
            return .rejected(reason: "Only 1 brief paragraph found (\(totalChars) characters)")
        }

        // 1. Boilerplate Ratio Check
        let boilerplateCount = paragraphs.filter { ArticleContentRedactor.isBoilerplateLine($0) }.count
        let boilerplateRatio = Double(boilerplateCount) / Double(paragraphs.count)
        if boilerplateRatio > 0.35 {
            return .rejected(reason: "High boilerplate ratio (\(Int(boilerplateRatio * 100))%)")
        }

        // 2. Repetition / Syndication Loop Check
        var seen = Set<String>()
        var duplicates = 0
        for p in paragraphs {
            let normalized = p.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.contains(normalized) {
                duplicates += 1
            } else {
                seen.insert(normalized)
            }
        }
        if duplicates >= 2 || (paragraphs.count >= 3 && duplicates >= paragraphs.count / 2) {
            return .rejected(reason: "Excessive repetitive text detected")
        }

        // 3. Short Snippet / Navigation Fragment Ratio Check
        let shortFragments = paragraphs.filter { $0.count < 35 }.count
        if paragraphs.count >= 4 && Double(shortFragments) / Double(paragraphs.count) > 0.6 {
            return .rejected(reason: "Excessive short snippet or navigation fragments")
        }

        return .valid
    }
}

// MARK: - Lightweight DOM Parser for HTML

final class DOMElementNode: Sendable {
    let tag: String
    let attributes: [String: String]
    let children: [DOMElementNode]
    let text: String
    let isSelfClosing: Bool

    init(
        tag: String,
        attributes: [String: String] = [:],
        children: [DOMElementNode] = [],
        text: String = "",
        isSelfClosing: Bool = false
    ) {
        self.tag = tag.lowercased()
        self.attributes = attributes
        self.children = children
        self.text = text
        self.isSelfClosing = isSelfClosing
    }

    var className: String {
        attributes["class"]?.lowercased() ?? ""
    }

    var idValue: String {
        attributes["id"]?.lowercased() ?? ""
    }

    var dataComponent: String {
        attributes["data-component"]?.lowercased() ?? ""
    }

    /// Recursively collects all text from this node and its children.
    func combinedText() -> String {
        var result = text
        for child in children {
            let childText = child.combinedText()
            if !childText.isEmpty {
                if !result.isEmpty { result += " " }
                result += childText
            }
        }
        return result
    }

    /// Recursively finds all nodes matching a given tag.
    func findNodes(tag targetTag: String) -> [DOMElementNode] {
        var results = [DOMElementNode]()
        if tag == targetTag {
            results.append(self)
        }
        for child in children {
            results.append(contentsOf: child.findNodes(tag: targetTag))
        }
        return results
    }

    /// Computes link density: ratio of text inside <a> tags versus total combined text.
    func computeLinkDensity() -> Double {
        let allText = combinedText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !allText.isEmpty else { return 0.0 }

        let aNodes = findNodes(tag: "a")
        var linkTextCount = 0
        for a in aNodes {
            linkTextCount += a.combinedText().trimmingCharacters(in: .whitespacesAndNewlines).count
        }

        return min(1.0, Double(linkTextCount) / Double(allText.count))
    }
}

// MARK: - HTML DOM Tree Builder

enum HTMLDOMBuilder {
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    private static let ignoredTags: Set<String> = [
        "script", "style", "noscript", "iframe", "svg", "nav", "footer",
        "header", "form", "aside", "dialog"
    ]

    /// Parses clean HTML into a DOM tree while filtering non-content containers.
    static func parse(html: String) -> DOMElementNode {
        var cleanHTML = html
        // Remove HTML comments
        if let commentRegex = try? NSRegularExpression(pattern: "<!--.*?-->", options: .dotMatchesLineSeparators) {
            cleanHTML = commentRegex.stringByReplacingMatches(in: cleanHTML, range: NSRange(cleanHTML.startIndex..., in: cleanHTML), withTemplate: "")
        }

        let root = DOMElementNode(tag: "root")
        var stack: [DOMElementBuilder] = [DOMElementBuilder(tag: "root")]

        let scanner = Scanner(string: cleanHTML)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            if scanner.scanString("<") != nil {
                if scanner.scanString("/") != nil {
                    // Closing tag: </tag>
                    if let closeTag = scanner.scanUpToString(">") {
                        _ = scanner.scanString(">")
                        let tagClean = closeTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if stack.count > 1 {
                            // Match nearest open tag of this name
                            if let idx = stack.lastIndex(where: { $0.tag == tagClean }) {
                                while stack.count > idx {
                                    let popped = stack.removeLast()
                                    let node = popped.build()
                                    if !stack.isEmpty {
                                        stack.last?.children.append(node)
                                    }
                                }
                            }
                        }
                    }
                } else if scanner.scanString("!") != nil {
                    // DOCTYPE or comment; skip to >
                    _ = scanner.scanUpToString(">")
                    _ = scanner.scanString(">")
                } else {
                    // Opening or self-closing tag
                    if let tagContent = scanner.scanUpToString(">") {
                        _ = scanner.scanString(">")
                        let parsed = parseTagContent(tagContent)
                        let tagName = parsed.tag.lowercased()

                        if ignoredTags.contains(tagName) {
                            // Skip content until closing tag
                            let closePattern = "</\(tagName)>"
                            _ = scanner.scanUpToString(closePattern)
                            _ = scanner.scanString(closePattern)
                            continue
                        }

                        let isSelfClosing = parsed.isSelfClosing || voidTags.contains(tagName)
                        let elementBuilder = DOMElementBuilder(tag: tagName, attributes: parsed.attributes, isSelfClosing: isSelfClosing)

                        if isSelfClosing {
                            let node = elementBuilder.build()
                            stack.last?.children.append(node)
                        } else {
                            stack.append(elementBuilder)
                        }
                    }
                }
            } else {
                // Text node
                if let textContent = scanner.scanUpToString("<") {
                    let decoded = ContentExtractionPipeline.shared.decodeHTMLEntities(textContent)
                    if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stack.last?.textPieces.append(decoded)
                    }
                }
            }
        }

        while stack.count > 1 {
            let popped = stack.removeLast()
            let node = popped.build()
            stack.last?.children.append(node)
        }

        return stack.first?.build() ?? root
    }

    private struct ParsedTag {
        let tag: String
        let attributes: [String: String]
        let isSelfClosing: Bool
    }

    private static func parseTagContent(_ content: String) -> ParsedTag {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSelfClosing = trimmed.hasSuffix("/")
        if isSelfClosing {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let tag = parts.first.map(String.init) ?? "div"
        var attributes = [String: String]()

        if parts.count > 1 {
            let attrString = String(parts[1])
            let attrPattern = "([a-zA-Z0-9_-]+)\\s*=\\s*[\"']([^\"']*)[\"']"
            if let regex = try? NSRegularExpression(pattern: attrPattern) {
                let matches = regex.matches(in: attrString, range: NSRange(attrString.startIndex..., in: attrString))
                for match in matches {
                    if let keyRange = Range(match.range(at: 1), in: attrString),
                       let valRange = Range(match.range(at: 2), in: attrString) {
                        let key = String(attrString[keyRange]).lowercased()
                        let val = String(attrString[valRange])
                        attributes[key] = val
                    }
                }
            }
        }

        return ParsedTag(tag: tag, attributes: attributes, isSelfClosing: isSelfClosing)
    }

    private class DOMElementBuilder {
        let tag: String
        var attributes: [String: String]
        var children: [DOMElementNode] = []
        var textPieces: [String] = []
        let isSelfClosing: Bool

        init(tag: String, attributes: [String: String] = [:], isSelfClosing: Bool = false) {
            self.tag = tag
            self.attributes = attributes
            self.isSelfClosing = isSelfClosing
        }

        func build() -> DOMElementNode {
            let combined = textPieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return DOMElementNode(
                tag: tag,
                attributes: attributes,
                children: children,
                text: combined,
                isSelfClosing: isSelfClosing
            )
        }
    }
}

// MARK: - Content Extraction Pipeline

/// Hardened HTML extraction pipeline performing character encoding normalization,
/// DOM-aware tree container scoring, link-density filtering, and quality validation.
final class ContentExtractionPipeline: Sendable {
    static let shared = ContentExtractionPipeline()
    private let logger = Logger(subsystem: "com.marspater.news", category: "extraction")

    init() {}

    /// Detailed extraction entry point returning structured outcome for diagnostics.
    func extractArticleDetailed(from link: String, allowHTTP: Bool = false) async -> ExtractionOutcome {
        guard let url = URL(string: link) else {
            logger.error("[Extraction] Malformed URL string: \(link, privacy: .public)")
            return .contentParsingFailed(reason: "Malformed URL: \(link)")
        }

        let host = url.host ?? "unknown"

        do {
            let (data, response) = try await SecureHTTPClient.shared.fetchArticleHTML(from: url, allowHTTP: allowHTTP)

            if response.statusCode >= 400 {
                logger.warning("[Extraction] Host: \(host, privacy: .public) | HTTP Error: \(response.statusCode)")
                return .httpError(status: response.statusCode)
            }

            let html = decodeHTML(data: data, response: response)
            guard !html.isEmpty else {
                logger.warning("[Extraction] Host: \(host, privacy: .public) | Empty response body")
                return .emptyContent
            }

            let leadImage = extractLeadImage(from: html)
            let outcome = extractFromHTML(html, baseUrl: link, leadImage: leadImage)

            switch outcome {
            case .success(let content, _):
                logger.info("[Extraction] Host: \(host, privacy: .public) | Success: \(content.count) characters extracted")
            case .qualityValidationFailed(let reason):
                logger.notice("[Extraction] Host: \(host, privacy: .public) | Quality rejected: \(reason, privacy: .public)")
            case .contentParsingFailed(let reason):
                logger.notice("[Extraction] Host: \(host, privacy: .public) | Parse failure: \(reason, privacy: .public)")
            default:
                break
            }

            return outcome
        } catch let error as FeedError {
            switch error {
            case .blockedHost(let h, let reason):
                logger.warning("[Extraction] Host \(h, privacy: .public) blocked: \(reason, privacy: .public)")
                return .securityBlocked(reason: "Blocked host: \(reason)")
            case .insecureScheme(let s):
                logger.warning("[Extraction] Insecure scheme rejected: \(s, privacy: .public)")
                return .securityBlocked(reason: "Insecure scheme: \(s)")
            case .blockedPort(let p):
                return .securityBlocked(reason: "Blocked port: \(p)")
            case .responseTooLarge(let bytes, let maxAllowed):
                logger.warning("[Extraction] Response exceeded limit: \(bytes) > \(maxAllowed)")
                return .networkError(reason: "Response too large (\(bytes) bytes)")
            default:
                logger.warning("[Extraction] Feed error for \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .networkError(reason: error.localizedDescription)
            }
        } catch {
            logger.error("[Extraction] Network failure for \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .networkError(reason: error.localizedDescription)
        }
    }

    /// Legacy backward-compatible facade returning (content, imageUrl).
    func extractArticle(from link: String, allowHTTP: Bool = false) async -> (content: String?, imageUrl: String?) {
        let outcome = await extractArticleDetailed(from: link, allowHTTP: allowHTTP)
        switch outcome {
        case .success(let content, let image):
            return (content, image)
        default:
            return (nil, nil)
        }
    }

    /// Core DOM-aware extraction engine that processes HTML into structured article prose.
    func extractFromHTML(_ html: String, baseUrl: String? = nil, leadImage: String? = nil) -> ExtractionOutcome {
        let effectiveImage = leadImage ?? extractLeadImage(from: html)

        // 1. Build DOM Tree
        let dom = HTMLDOMBuilder.parse(html: html)

        // 2. Score candidate containers
        let scoredParagraphs = scoreAndExtractBestParagraphs(from: dom)

        // 3. Fallback to document-level paragraphs if top container yielded insufficient prose
        var candidateParagraphs = scoredParagraphs
        if candidateParagraphs.count < 2 {
            let docParas = extractDocumentParagraphs(from: dom)
            if docParas.count > candidateParagraphs.count {
                candidateParagraphs = docParas
            }
        }

        // 4. Validate Content Quality
        let validation = ContentQualityValidator.validate(paragraphs: candidateParagraphs)
        switch validation {
        case .valid:
            let joined = candidateParagraphs.joined(separator: "\n\n")
            return .success(content: joined, imageUrl: effectiveImage)
        case .rejected(let reason):
            return .qualityValidationFailed(reason: reason)
        }
    }

    // MARK: - Container Scoring Engine

    private func scoreAndExtractBestParagraphs(from root: DOMElementNode) -> [String] {
        var candidateContainers = [DOMElementNode]()
        collectCandidateContainers(from: root, into: &candidateContainers)

        var bestScore: Double = -1000.0
        var bestParagraphs: [String] = []

        for container in candidateContainers {
            let (score, paragraphs) = scoreContainer(container)
            if score > bestScore {
                bestScore = score
                bestParagraphs = paragraphs
            }
        }

        if bestScore >= 40.0 && bestParagraphs.count >= 2 {
            return bestParagraphs
        }

        return bestParagraphs
    }

    private func collectCandidateContainers(from node: DOMElementNode, into results: inout [DOMElementNode]) {
        let tag = node.tag
        if tag == "article" || tag == "main" || tag == "section" || tag == "div" {
            results.append(node)
        }
        for child in node.children {
            collectCandidateContainers(from: child, into: &results)
        }
    }

    private func scoreContainer(_ container: DOMElementNode) -> (Double, [String]) {
        let pNodes = container.findNodes(tag: "p")
        var substantiveParagraphs = [String]()

        for p in pNodes {
            let plain = p.combinedText().trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.count >= 25 && !ArticleContentRedactor.isBoilerplateLine(plain) {
                substantiveParagraphs.append(plain)
            }
        }

        guard !substantiveParagraphs.isEmpty else {
            return (-1000.0, [])
        }

        var score: Double = 0.0

        // Paragraph count & text length contribution
        score += Double(substantiveParagraphs.count) * 30.0
        let totalChars = substantiveParagraphs.reduce(0) { $0 + $1.count }
        score += Double(totalChars) / 35.0

        // Tag Priority Bonus
        if container.tag == "article" {
            score += 90.0
        } else if container.tag == "main" {
            score += 50.0
        }

        // Semantic Identifiers Bonus
        let identifier = "\(container.className) \(container.idValue) \(container.dataComponent)"

        let positiveMatches = [
            "story-body", "article-body", "article__body", "entry-content",
            "post-content", "caas-body", "ssrcss", "duet-", "content-body",
            "main-content", "article-text", "article-content", "story-content",
            "text-block"
        ]
        for term in positiveMatches {
            if identifier.contains(term) {
                score += 45.0
            }
        }

        // Heavy Negative Penalties for Widgets, Comments & Navigation
        let negativeMatches = [
            "comment", "share", "social", "related", "sidebar", "ad-",
            "advertisement", "newsletter", "promo", "cookie", "banner",
            "footer", "nav", "menu", "trending", "more-stories", "recommend"
        ]
        for term in negativeMatches {
            if identifier.contains(term) {
                score -= 160.0
            }
        }

        // Link Density Penalty
        let linkDensity = container.computeLinkDensity()
        if linkDensity > 0.35 {
            score -= 300.0
        } else if linkDensity > 0.20 {
            score -= 100.0
        }

        return (score, substantiveParagraphs)
    }

    private func extractDocumentParagraphs(from root: DOMElementNode) -> [String] {
        let pNodes = root.findNodes(tag: "p")
        var substantive = [String]()
        for p in pNodes {
            let plain = p.combinedText().trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.count >= 30 && !ArticleContentRedactor.isBoilerplateLine(plain) {
                substantive.append(plain)
            }
        }
        return substantive
    }

    /// Legacy helper returning semantic paragraphs from HTML string.
    func extractParagraphs(from html: String) -> [String] {
        let dom = HTMLDOMBuilder.parse(html: html)
        let scored = scoreAndExtractBestParagraphs(from: dom)
        if scored.count >= 2 {
            return scored
        }
        return extractDocumentParagraphs(from: dom)
    }

    /// Computes link density: ratio of text inside <a> tags versus total plain text.
    func computeLinkDensity(_ htmlSnippet: String) -> Double {
        let dom = HTMLDOMBuilder.parse(html: htmlSnippet)
        return dom.computeLinkDensity()
    }

    /// Converts HTML snippet to plain text and unescapes entities.
    func htmlToPlainText(_ html: String) -> String {
        let dom = HTMLDOMBuilder.parse(html: html)
        return decodeHTMLEntities(dom.combinedText())
    }

    // MARK: - Character Encoding Normalization

    func decodeHTML(data: Data, response: HTTPURLResponse? = nil) -> String {
        if let contentType = response?.value(forHTTPHeaderField: "Content-Type") {
            if let charset = extractCharset(from: contentType) {
                if let decoded = decode(data: data, charset: charset) {
                    return decoded
                }
            }
        }

        if let asciiPrefix = String(data: data.prefix(2048), encoding: .ascii) {
            if let charset = extractCharsetFromMeta(asciiPrefix) {
                if let decoded = decode(data: data, charset: charset) {
                    return decoded
                }
            }
        }

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

    // MARK: - Lead Image Extraction

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

    // MARK: - HTML Entity Decoding

    func decodeHTMLEntities(_ text: String) -> String {
        var result = text

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
