import Foundation
import os

/// Constructed only after protected fetching and document-equivalence checks.
struct DocumentIdentityEvidence: Equatable, Sendable {
    let requestedURL: String
    let urls: [String]

    fileprivate init(requestedURL: String, urls: [String]) {
        self.requestedURL = requestedURL
        self.urls = urls
    }
}

// MARK: - Extraction Outcome & Diagnostics

public enum ExtractionOutcome: Equatable, Sendable {
    case success(content: String, imageUrl: String?, document: ReaderDocument? = nil)
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
        if case .success(let c, _, _) = self { return c }
        return nil
    }

    public var imageUrl: String? {
        if case .success(_, let img, _) = self { return img }
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
        // Mostly repeated text is a syndication loop; a few repeats are page furniture the pipeline removes.
        if paragraphs.count >= 3 && duplicates * 2 >= paragraphs.count {
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
    private let isNavigationCard: Bool

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
        // Classify once: immutable DOM nodes are revisited while scoring ancestor containers.
        let cardTokens = (attributes["class"] ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }
        )
        if self.tag != "a" && (cardTokens.contains("card") || cardTokens.contains("teaser")) {
            let links = children.flatMap { $0.findNodes(tag: "a") }
            let destinations = Set(links.compactMap { $0.attributes["href"] })
            let visibleText = (text + children.map { $0.combinedText() }.joined()).filter { !$0.isWhitespace }.count
            let linkedText = links.reduce(0) { $0 + $1.combinedText().filter { !$0.isWhitespace }.count }
            isNavigationCard = destinations.count >= 2 && linkedText * 2 > visibleText
        } else {
            isNavigationCard = false
        }
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

    private var isHidden: Bool {
        attributes["style"]?.range(
            of: #"(?:display\s*:\s*none|visibility\s*:\s*hidden)"#, options: [.regularExpression, .caseInsensitive])
            != nil || attributes["hidden"] != nil || attributes["aria-hidden"]?.lowercased() == "true"
            || className.split(whereSeparator: { $0.isWhitespace }).contains("visually-hidden")
    }

    /// Recursively collects visible text from this node and its children.
    func combinedText() -> String {
        guard !isReaderExcluded else { return "" }
        if tag == "br" { return "\n" }
        if tag == "noscript" { return "" }
        var result = text
        for child in children {
            let childText = child.combinedText()
            if !childText.isEmpty {
                if ["p", "div", "li"].contains(child.tag), !result.isEmpty { result += "\n" }
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

    var isReaderExcluded: Bool {
        if isHidden || isNavigationCard { return true }
        // BBC renders this listening CTA as ordinary prose; require its exact media links.
        if tag == "p" {
            let links = findNodes(tag: "a").compactMap { $0.attributes["href"] }
            let prose = (text + children.map { $0.combinedText() }.joined()).trimmingCharacters(
                in: .whitespacesAndNewlines)
            if prose.hasPrefix("Listen to Newsbeat"),
                links.contains("/sounds/play/live:bbc_radio_one"),
                links.contains("/programmes/b006wkry/episodes/player")
            {
                return true
            }
            // Newsletter signup prose (BBC, #330): it links to a newsletter page and asks the reader to sign up.
            if links.contains(where: { URL(string: $0)?.path.hasPrefix("/newsletters/") == true }),
                prose.range(of: "sign up", options: .caseInsensitive) != nil,
                prose.range(of: "newsletter", options: .caseInsensitive) != nil
            {
                return true
            }
        }
        // Promotional newsletter banners are images whose alt text describes the promotion; editorial figures stay.
        if ["figure", "picture", "img"].contains(tag),
            findNodes(tag: "img").contains(where: {
                $0.attributes["alt"]?.range(
                    of: #"(?i)\bbanner promoting\b[^.]*\bnewsletter\b"#, options: .regularExpression) != nil
            })
        {
            return true
        }
        let identifiers = [
            className, idValue, dataComponent, attributes["data-testid"] ?? "", attributes["data-block"] ?? "",
            attributes["role"] ?? "",
        ]
        return identifiers.contains {
            Self.auxiliaryPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
    }

    // Token boundaries keep editorial "commentary" distinct from comment widgets.
    private static let auxiliaryPattern = try! NSRegularExpression(
        pattern:
            #"(?i)(?:^|[^a-z0-9])(?:comments?|comment-thread|disqus|related(?:-content|-stories|-articles)?|links-block|newsletter|byline|timestamp-block|recommendations?|social-share|share-tools|promo|advertisement|outbrain|taboola|eventpromo|promolist|topiclist|uploaderembed)(?:$|[^a-z0-9])"#
    )

    func readingBlocks(allowDivFallback: Bool = true) -> [DOMElementNode] {
        guard !isReaderExcluded else { return [] }
        if tag == "noscript" { return children.flatMap { $0.readingBlocks(allowDivFallback: false) } }
        if tag == "figure" || tag == "img" || tag == "picture" { return [self] }
        if ["div", "p"].contains(tag), children.contains(where: { $0.tag == "br" }) {
            var groups = [[DOMElementNode]]([[]])
            for child in children {
                if child.tag == "br" { groups.append([]) } else { groups[groups.count - 1].append(child) }
            }
            let paragraphs = groups.filter { !$0.isEmpty }.map { DOMElementNode(tag: "p", children: $0) }
            if paragraphs.count > 1, paragraphs.allSatisfy({ $0.combinedText().count >= 25 }) { return paragraphs }
        }
        if tag == "figcaption" { return [] }
        if tag == "ol" {
            var ordinal = Int(attributes["start"] ?? "") ?? 1
            return children.flatMap { child -> [DOMElementNode] in
                guard child.tag == "li", !child.isReaderExcluded else { return child.readingBlocks() }
                ordinal = Int(child.attributes["value"] ?? "") ?? ordinal
                var attributes = child.attributes
                attributes["reader-ordinal"] = String(ordinal)
                if ordinal < Int.max { ordinal += 1 }
                return [
                    DOMElementNode(tag: child.tag, attributes: attributes, children: child.children, text: child.text)
                ]
            }
        }
        if ["p", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre"].contains(tag) { return [self] }
        var blocks = [DOMElementNode]()
        var inline = [DOMElementNode]()
        func flushInline() {
            let paragraph = DOMElementNode(tag: "p", children: inline)
            if paragraph.combinedText().trimmingCharacters(in: .whitespacesAndNewlines).count >= 25 {
                blocks.append(paragraph)
            }
            inline.removeAll()
        }
        for child in children {
            let nested = child.readingBlocks(allowDivFallback: false)
            if !nested.isEmpty {
                flushInline()
                blocks += nested
            } else if child.tag == "br" {
                flushInline()
            } else if !child.isReaderExcluded {
                inline.append(child)
            }
        }
        flushInline()
        if blocks.contains(where: { $0.tag != "figure" }) || !allowDivFallback { return blocks }
        let divs = children.flatMap { $0.readingBlocks() }
        if !divs.isEmpty { return divs }
        if ["div", "article", "main", "section"].contains(tag),
            combinedText().trimmingCharacters(in: .whitespacesAndNewlines).count >= 25
        {
            return [self]
        }
        return []
    }

    func inlineContent(strong: Bool = false, emphasis: Bool = false, code: Bool = false, link: String? = nil)
        -> [ReaderInlineRun]
    {
        guard !isReaderExcluded else { return [] }
        let strong = strong || ["strong", "b"].contains(tag)
        let emphasis = emphasis || ["em", "i"].contains(tag)
        let code = code || tag == "code"
        let link = tag == "a" ? attributes["href"] : link
        var runs =
            text.isEmpty
            ? [] : [ReaderInlineRun(text: text, strong: strong, emphasis: emphasis, code: code, link: link)]
        for child in children {
            if ["p", "div", "li"].contains(child.tag), !runs.isEmpty { runs.append(ReaderInlineRun(text: " ")) }
            runs += child.inlineContent(strong: strong, emphasis: emphasis, code: code, link: link)
        }
        return runs
    }

    var readerBlock: ReaderBlock? {
        guard !isReaderExcluded else { return nil }
        if ["figure", "img", "picture"].contains(tag) {
            guard let image = visibleReaderImage(),
                let source = image.readerImageSource,
                image.attributes["alt"]?.range(of: #"\blogo\b"#, options: [.regularExpression, .caseInsensitive]) == nil
            else { return nil }
            // Responsive layouts (The Guardian) repeat one figcaption per breakpoint; each distinct caption appears once.
            var seenCaptions = Set<String>()
            let caption = findNodes(tag: "figcaption").map { node in
                node.children.filter { !$0.className.contains("credit") && !$0.className.contains("attribution") }.map {
                    $0.combinedText()
                }.joined()
                    .replacingOccurrences(of: "[ \t\r\n]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty && seenCaptions.insert($0).inserted }.joined(separator: " ")
            let credit =
                (image.attributes["data-credit"] ?? attributes["data-credit"]
                ?? findNodes(tag: "figcaption").flatMap { $0.children }.first(where: {
                    $0.className.contains("credit") || $0.className.contains("attribution")
                })?.combinedText())?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReaderBlock(
                kind: .figure, text: String(caption.prefix(2000)), imageURL: source,
                imageAlt: (image.attributes["alt"] ?? findNodes(tag: "img").first?.attributes["alt"]).map {
                    String($0.prefix(500))
                },
                // A credit already printed inside the caption is not repeated below it.
                imageCredit: credit.flatMap { $0.isEmpty || caption.contains($0) ? nil : $0 },
                imageWidth: (image.attributes["width"] ?? findNodes(tag: "img").first?.attributes["width"]).flatMap(
                    Int.init),
                imageHeight: (image.attributes["height"] ?? findNodes(tag: "img").first?.attributes["height"]).flatMap(
                    Int.init))
        }
        let plain = combinedText().replacingOccurrences(of: "[ \t\r\n]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty, !ArticleContentRedactor.isBoilerplateLine(plain) else { return nil }
        let kind: ReaderBlock.Kind
        switch tag {
        case "h2": kind = .heading
        case "h3", "h4", "h5", "h6": kind = .subheading
        case "li": kind = .listItem
        case "blockquote": kind = .quote
        case "pre": kind = .code
        default: kind = .paragraph
        }
        // Standalone linked teasers are navigation, while inline citations remain part of prose.
        guard computeLinkDensity() < 0.8 else { return nil }
        guard kind != .paragraph || plain.count >= 25 else { return nil }
        return ReaderBlock(
            kind: kind, text: kind == .code ? combinedText().trimmingCharacters(in: .whitespacesAndNewlines) : plain,
            ordinal: attributes["reader-ordinal"].flatMap(Int.init), inlineRuns: kind == .code ? nil : inlineContent())
    }

    var readerImageSource: String? {
        // ponytail: bounded responsive candidates for a 1200 px reader; no media-query engine.
        for key in ["data-srcset", "srcset"] {
            let candidates = (attributes[key] ?? "").split(separator: ",").prefix(32).compactMap {
                item -> (String, Double)? in
                let parts = item.split(whereSeparator: { $0.isWhitespace })
                guard let url = parts.first else { return nil }
                let descriptor = parts.count > 1 ? String(parts[1]) : "1x"
                guard let size = Double(descriptor.dropLast()), size > 0, size.isFinite,
                    descriptor.hasSuffix("w") || descriptor.hasSuffix("x")
                else { return nil }
                return (String(url), descriptor.hasSuffix("x") ? size * 600 : size)
            }.sorted { $0.1 < $1.1 }
            if let chosen = candidates.first(where: { $0.1 >= 1200 }) ?? candidates.last { return chosen.0 }
        }
        for key in ["data-src", "data-original", "data-lazy-src", "src"] {
            if let url = attributes[key], !url.isEmpty, !url.hasPrefix("data:") { return url }
        }
        return nil
    }

    private func visibleReaderImage() -> DOMElementNode? {
        guard !isReaderExcluded else { return nil }
        if tag == "img" || tag == "source" {
            for dimension in ["width", "height"] {
                if let value = attributes[dimension].flatMap(Int.init), value < 80 { return nil }
            }
            return readerImageSource == nil ? nil : self
        }
        for child in children {
            if let image = child.visibleReaderImage() { return image }
        }
        return nil
    }

    /// Computes link density: ratio of text inside <a> tags versus total combined text.
    func computeLinkDensity() -> Double {
        let allText = combinedText().filter { !$0.isWhitespace }
        guard !allText.isEmpty else { return 0.0 }

        let aNodes = findNodes(tag: "a")
        var linkTextCount = 0
        for a in aNodes {
            linkTextCount += a.combinedText().filter { !$0.isWhitespace }.count
        }

        return min(1.0, Double(linkTextCount) / Double(allText.count))
    }

    /// Share of text in links outside cited prose: navigation and teaser cards, not inline citations.
    /// A prose-length paragraph, list item or quotation whose links are citations: under 80% of its text, and no single
    /// link covering half of it, as a teaser card's headline would.
    var isCitedProse: Bool {
        guard ["p", "li", "blockquote"].contains(tag) else { return false }
        let text = combinedText()
        guard text.count >= 120 else { return false }
        let total = text.filter { !$0.isWhitespace }.count
        let links = findNodes(tag: "a").map { $0.combinedText().filter { !$0.isWhitespace }.count }
        return links.reduce(0, +) * 5 < total * 4 && (links.max() ?? 0) * 2 < total
    }

    func navigationLinkDensity() -> Double {
        let allText = combinedText().filter { !$0.isWhitespace }.count
        guard allText > 0 else { return 0.0 }
        func navigationLinkText(_ node: DOMElementNode) -> Int {
            if node.isCitedProse { return 0 }
            if node.tag == "a" { return node.combinedText().filter { !$0.isWhitespace }.count }
            // An excluded widget between prose sections is inside the article, not evidence of a page wrapper.
            // Keep counting excluded menus at the edges: those still distinguish wrappers from their article body.
            guard node.children.count >= 3,
                node.children.dropFirst().dropLast().contains(where: { $0.isReaderExcluded })
            else {
                return node.children.reduce(0) { $0 + navigationLinkText($1) }
            }
            let proseIndices = node.children.indices.filter { index in
                let child = node.children[index]
                return !child.isReaderExcluded && child.readingBlocks().contains(where: { $0.isCitedProse })
            }
            return node.children.enumerated().reduce(0) { total, entry in
                let (index, child) = entry
                if child.isReaderExcluded, let first = proseIndices.first, let last = proseIndices.last,
                    first < index && index < last
                {
                    return total
                }
                return total + navigationLinkText(child)
            }
        }
        return min(1.0, Double(navigationLinkText(self)) / Double(allText))
    }
}

// MARK: - HTML DOM Tree Builder

enum HTMLDOMBuilder {
    private static let attrRegex = try! NSRegularExpression(
        pattern: #"([a-zA-Z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    private static let ignoredTags: Set<String> = [
        "script", "style", "iframe", "svg", "nav", "footer",
        "header", "form", "aside", "dialog", "time", "button",
    ]

    private static let commentRegex = try? NSRegularExpression(
        pattern: "<!--.*?-->", options: .dotMatchesLineSeparators)

    /// Parses clean HTML into a DOM tree while filtering non-content containers.
    static func parse(html: String) -> DOMElementNode {
        var cleanHTML = html
        // Remove HTML comments
        if let commentRegex = Self.commentRegex {
            cleanHTML = commentRegex.stringByReplacingMatches(
                in: cleanHTML, range: NSRange(cleanHTML.startIndex..., in: cleanHTML), withTemplate: "")
        }

        let root = DOMElementNode(tag: "root")
        var stack: [DOMElementBuilder] = [DOMElementBuilder(tag: "root")]

        let scanner = Scanner(string: cleanHTML)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            if scanner.scanString("<") != nil {
                if scanner.scanString("/") != nil {
                    handleClosingTag(scanner: scanner, stack: &stack)
                } else if scanner.scanString("!") != nil {
                    // DOCTYPE or comment; skip to >
                    _ = scanner.scanUpToString(">")
                    _ = scanner.scanString(">")
                } else {
                    handleOpeningTag(scanner: scanner, html: cleanHTML, stack: &stack)
                }
            } else {
                handleTextNode(scanner: scanner, stack: &stack)
            }
        }

        while stack.count > 1 {
            let popped = stack.removeLast()
            let node = popped.build()
            stack.last?.children.append(node)
        }

        return stack.first?.build() ?? root
    }

    private static func handleClosingTag(scanner: Scanner, stack: inout [DOMElementBuilder]) {
        // Closing tag: </tag>
        guard let closeTag = scanner.scanUpToString(">") else { return }
        _ = scanner.scanString(">")
        let tagClean = closeTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Match nearest open tag of this name.
        if stack.count > 1, let idx = stack.lastIndex(where: { $0.tag == tagClean }) {
            while stack.count > idx {
                let popped = stack.removeLast()
                let node = popped.build()
                if !stack.isEmpty {
                    stack.last?.children.append(node)
                }
            }
        }
    }

    private static func handleOpeningTag(scanner: Scanner, html: String, stack: inout [DOMElementBuilder]) {
        // Opening or self-closing tag
        guard let tagContent = scanner.scanUpToString(">") else { return }
        _ = scanner.scanString(">")
        let parsed = parseTagContent(tagContent)
        let tagName = parsed.tag.lowercased()

        if ignoredTags.contains(tagName) {
            // Skip content until closing tag
            if let closing = html.range(
                of: "</\(tagName)\\s*>", options: [.regularExpression, .caseInsensitive],
                range: scanner.currentIndex..<html.endIndex
            ) {
                scanner.currentIndex = closing.upperBound
            }
            return
        }

        // HTML permits omitted paragraph end tags.
        if tagName == "p", let index = stack.lastIndex(where: { $0.tag == "p" }) {
            while stack.count > index {
                let node = stack.removeLast().build()
                stack.last?.children.append(node)
            }
        }
        // Bound recursion for hostile or malformed publisher HTML.
        guard stack.count < 128 else { return }
        let isSelfClosing = parsed.isSelfClosing || voidTags.contains(tagName)
        let elementBuilder = DOMElementBuilder(
            tag: tagName, attributes: parsed.attributes, isSelfClosing: isSelfClosing)

        if isSelfClosing {
            let node = elementBuilder.build()
            stack.last?.children.append(node)
        } else {
            stack.append(elementBuilder)
        }
    }

    private static func handleTextNode(scanner: Scanner, stack: inout [DOMElementBuilder]) {
        // Text node
        guard let textContent = scanner.scanUpToString("<") else { return }
        let decoded = ContentExtractionPipeline.shared.decodeHTMLEntities(textContent)
        stack.last?.children.append(DOMElementNode(tag: "#text", text: decoded))
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

        let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        let tag = parts.first.map(String.init) ?? "div"
        var attributes = [String: String]()

        if parts.count > 1 {
            let attrString = String(parts[1])
            if attrString.range(of: "(?:^|\\s)hidden(?:\\s|=|$)", options: [.regularExpression, .caseInsensitive])
                != nil
            {
                attributes["hidden"] = ""
            }
            let matches = Self.attrRegex.matches(
                in: attrString, range: NSRange(attrString.startIndex..., in: attrString))
            for match in matches {
                if let keyRange = Range(match.range(at: 1), in: attrString),
                    let valRange = (2...4).compactMap({ Range(match.range(at: $0), in: attrString) }).first
                {
                    let key = String(attrString[keyRange]).lowercased()
                    let val = ContentExtractionPipeline.shared.decodeHTMLEntities(String(attrString[valRange]))
                    attributes[key] = val
                }
            }
        }

        return ParsedTag(tag: tag, attributes: attributes, isSelfClosing: isSelfClosing)
    }

    private class DOMElementBuilder {
        let tag: String
        var attributes: [String: String]
        var children: [DOMElementNode] = []
        let isSelfClosing: Bool

        init(tag: String, attributes: [String: String] = [:], isSelfClosing: Bool = false) {
            self.tag = tag
            self.attributes = attributes
            self.isSelfClosing = isSelfClosing
        }

        func build() -> DOMElementNode {
            return DOMElementNode(
                tag: tag,
                attributes: attributes,
                children: children,
                text: tag == "br" || tag == "hr" ? "\n" : "",
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

    private let client: SecureHTTPClient

    init(client: SecureHTTPClient = .shared) { self.client = client }

    private static func articleURL(from link: String, allowHTTP: Bool) -> URL? {
        guard let url = URL(string: link) else { return nil }
        // Upgrade old feed links before the protected client validates their destination.
        guard !allowHTTP, url.scheme?.lowercased() == "http",
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    /// Detailed extraction entry point returning structured outcome for diagnostics.
    func extractArticleDetailed(from link: String, allowHTTP: Bool = false) async -> ExtractionOutcome {
        await extractArticleWithIdentity(from: link, allowHTTP: allowHTTP).outcome
    }

    func extractArticleWithIdentity(from link: String, allowHTTP: Bool = false) async
        -> (outcome: ExtractionOutcome, evidence: DocumentIdentityEvidence?)
    {
        guard let url = Self.articleURL(from: link, allowHTTP: allowHTTP) else {
            logger.error("[Extraction] Malformed article URL")
            return (.contentParsingFailed(reason: "Malformed URL: \(link)"), nil)
        }

        let host = url.host ?? "unknown"

        do {
            let (data, response) = try await client.fetchArticleHTML(from: url, allowHTTP: allowHTTP)

            if response.statusCode >= 400 {
                logger.warning("[Extraction] Host: \(host, privacy: .public) | HTTP Error: \(response.statusCode)")
                return (.httpError(status: response.statusCode), nil)
            }

            let html = decodeHTML(data: data, response: response)
            guard !html.isEmpty else {
                logger.warning("[Extraction] Host: \(host, privacy: .public) | Empty response body")
                return (.emptyContent, nil)
            }

            let leadImage = extractLeadImage(from: html)
            let finalURL = response.url ?? url
            if url.scheme?.lowercased() == "https", finalURL.scheme?.lowercased() == "http" {
                throw FeedError.insecureScheme("http")
            }
            try await client.validateDestination(finalURL, allowHTTP: allowHTTP)
            let outcome = extractFromHTML(html, baseUrl: finalURL.absoluteString, leadImage: leadImage)

            switch outcome {
            case .success(let content, _, _):
                logger.info(
                    "[Extraction] Host: \(host, privacy: .public) | Success: \(content.count) characters extracted")
            case .qualityValidationFailed(let reason):
                logger.notice(
                    "[Extraction] Host: \(host, privacy: .public) | Quality rejected: \(reason, privacy: .public)")
            case .contentParsingFailed(let reason):
                logger.notice(
                    "[Extraction] Host: \(host, privacy: .public) | Parse failure: \(reason, privacy: .public)")
            default:
                break
            }

            let evidence = try await identityEvidence(
                requestedURL: url, finalURL: finalURL,
                html: html, outcome: outcome, allowHTTP: allowHTTP)
            return (outcome, evidence)
        } catch let error as FeedError {
            switch error {
            case .httpStatus(let status):
                return (.httpError(status: status), nil)
            case .blockedHost(let h, let reason):
                logger.warning("[Extraction] Host \(h, privacy: .public) blocked: \(reason, privacy: .public)")
                return (.securityBlocked(reason: "Blocked host: \(reason)"), nil)
            case .insecureScheme(let s):
                logger.warning("[Extraction] Insecure scheme rejected: \(s, privacy: .public)")
                return (.securityBlocked(reason: "Insecure scheme: \(s)"), nil)
            case .blockedPort(let p):
                return (.securityBlocked(reason: "Blocked port: \(p)"), nil)
            case .responseTooLarge(let bytes, let maxAllowed):
                logger.warning("[Extraction] Response exceeded limit: \(bytes) > \(maxAllowed)")
                return (.networkError(reason: "Response too large (\(bytes) bytes)"), nil)
            default:
                logger.warning(
                    "[Extraction] Feed error for \(host, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return (.networkError(reason: error.localizedDescription), nil)
            }
        } catch {
            logger.error(
                "[Extraction] Network failure for \(host, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return (.networkError(reason: error.localizedDescription), nil)
        }
    }

    private func identityEvidence(
        requestedURL: URL, finalURL: URL, html: String,
        outcome: ExtractionOutcome, allowHTTP: Bool
    ) async throws -> DocumentIdentityEvidence? {
        guard let content = outcome.content, Self.documentURL(finalURL) else { return nil }
        var urls = [finalURL.absoluteString]
        let dom = HTMLDOMBuilder.parse(html: html)
        let title = Self.normalizedEvidenceText(dom.findNodes(tag: "title").map { $0.combinedText() }.joined())
        let links = dom.findNodes(tag: "head")
            .flatMap { $0.findNodes(tag: "link") }
            .filter {
                ($0.attributes["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).contains(
                    "canonical")
            }
        // ponytail: one same-origin canonical probe on demand; no canonical chains.
        if links.count == 1, let href = links.first?.attributes["href"], href.utf8.count <= 8192,
            let candidate = URL(string: href, relativeTo: finalURL)?.absoluteURL,
            Self.documentURL(candidate), Self.sameOrigin(candidate, finalURL),
            ArticleIdentity.canonicalizeURL(candidate.absoluteString)
                != ArticleIdentity.canonicalizeURL(finalURL.absoluteString),
            !title.isEmpty, content.count >= 400, content.utf8.count <= 262_144
        {
            do {
                let (data, response) = try await client.fetchArticleHTML(from: candidate, allowHTTP: allowHTTP)
                if let resolved = response.url, Self.documentURL(resolved), Self.sameOrigin(resolved, finalURL) {
                    try await client.validateDestination(resolved, allowHTTP: allowHTTP)
                    let candidateHTML = decodeHTML(data: data, response: response)
                    let otherTitle = Self.normalizedEvidenceText(
                        HTMLDOMBuilder.parse(html: candidateHTML)
                            .findNodes(tag: "title").map { $0.combinedText() }.joined())
                    if title == otherTitle,
                        let other = extractFromHTML(candidateHTML, baseUrl: resolved.absoluteString).content,
                        other.utf8.count <= 262_144,
                        Self.normalizedEvidenceText(other) == Self.normalizedEvidenceText(content)
                    {
                        urls.append(candidate.absoluteString)
                        urls.append(resolved.absoluteString)
                    }
                }
            } catch {
                // Failed optional canonical verification does not discard readable content.
                // Cancellation still prevents returning or storing identity evidence below.
            }
        }
        try Task.checkCancellation()
        guard !urls.isEmpty else { return nil }
        return DocumentIdentityEvidence(
            requestedURL: ArticleIdentity.canonicalizeURL(requestedURL.absoluteString),
            urls: Array(Set(urls.map { ArticleIdentity.canonicalizeURL($0) })).sorted())
    }

    private static func normalizedEvidenceText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func documentURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.host?.isEmpty == false, components.user == nil, components.password == nil
        else { return false }
        return !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            || !(components.query ?? "").isEmpty
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? (lhs.scheme == "https" ? 443 : 80)) == (rhs.port ?? (rhs.scheme == "https" ? 443 : 80))
    }

    /// Legacy backward-compatible facade returning (content, imageUrl).
    func extractArticle(from link: String, allowHTTP: Bool = false) async -> (content: String?, imageUrl: String?) {
        let outcome = await extractArticleDetailed(from: link, allowHTTP: allowHTTP)
        switch outcome {
        case .success(let content, let image, _):
            return (content, image)
        default:
            return (nil, nil)
        }
    }

    /// Core DOM-aware extraction engine that processes HTML into structured article prose.
    func extractFromHTML(_ html: String, baseUrl: String? = nil, leadImage: String? = nil) -> ExtractionOutcome {
        let effectiveImage = Self.readerImageURL(leadImage ?? extractLeadImage(from: html), baseURL: baseUrl)

        // 1. Build DOM Tree
        let dom = HTMLDOMBuilder.parse(html: html)

        // 2. Score candidate containers
        let scoredParagraphs = scoreAndExtractBestParagraphs(from: dom)

        // 3. Fallback to document-level paragraphs if top container yielded insufficient prose
        var candidateParagraphs = scoredParagraphs
        if candidateParagraphs.filter({ $0.kind != .figure }).count < 2 {
            let docParas = extractDocumentParagraphs(from: dom)
            if docParas.filter({ $0.kind != .figure }).count > candidateParagraphs.filter({ $0.kind != .figure }).count
            {
                candidateParagraphs = docParas
            }
        }

        // Keep media in publisher order, without allowing images to qualify an empty article.
        candidateParagraphs = candidateParagraphs.map { block in
            var block = block
            if let runs = block.inlineRuns {
                var normalized = [ReaderInlineRun]()
                var precedingWhitespace = true
                for var run in runs {
                    var text = ""
                    for character in run.text {
                        if character.isWhitespace {
                            if !precedingWhitespace {
                                text += " "
                                precedingWhitespace = true
                            }
                        } else {
                            text.append(character)
                            precedingWhitespace = false
                        }
                    }
                    run.text = text
                    run.link = Self.readerImageURL(run.link, baseURL: baseUrl)
                    if !text.isEmpty { normalized.append(run) }
                }
                if !normalized.isEmpty {
                    normalized[normalized.count - 1].text = normalized.last!.text.trimmingCharacters(in: .whitespaces)
                }
                // Invalid/legacy structure falls back to plain text, never changes its words.
                block.inlineRuns = normalized.map(\.text).joined() == block.text ? normalized : nil
            }
            return block
        }
        var seenImages = Set<String>()
        candidateParagraphs = candidateParagraphs.compactMap { block in
            guard block.kind == .figure else { return block }
            guard seenImages.count < 8,
                let url = Self.readerImageURL(block.imageURL, baseURL: baseUrl),
                ReaderImageCandidate.usable(url: url, width: block.imageWidth, height: block.imageHeight),
                seenImages.insert(url).inserted
            else { return nil }
            var resolved = block
            resolved.imageURL = url
            return resolved
        }

        // 4. Validate Content Quality
        let isText: (ReaderBlock) -> Bool = { $0.kind == .paragraph || $0.kind == .quote || $0.kind == .listItem }
        let key: (ReaderBlock) -> String = { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let isProse: (ReaderBlock) -> Bool = { block in
            block.text.count >= 120
                || block.text.trimmingCharacters(in: CharacterSet(charactersIn: " )]}\"'’”»›"))
                    .last.map { ".!?…".contains($0) } == true
        }
        // Repeated labels (headlines, related links, buttons, bylines, video placeholders) are page furniture: every copy
        // goes before validation, so the repetition check only judges prose.
        let counts = Dictionary(candidateParagraphs.filter(isText).map { (key($0), 1) }, uniquingKeysWith: +)
        candidateParagraphs.removeAll { isText($0) && counts[key($0), default: 0] > 1 && !isProse($0) }
        var validation = ContentQualityValidator.validate(paragraphs: candidateParagraphs.filter(isText).map(\.text))
        if validation == .valid {
            // Repeated prose that is not a loop, such as a sentence that is also a pull quote, keeps its first occurrence.
            var kept = Set<String>()
            candidateParagraphs.removeAll {
                isText($0) && counts[key($0), default: 0] > 1 && !kept.insert(key($0)).inserted
            }
            validation = ContentQualityValidator.validate(paragraphs: candidateParagraphs.filter(isText).map(\.text))
        }
        switch validation {
        case .valid:
            let joined = candidateParagraphs.filter { $0.kind != .figure }.map(\.text).joined(separator: "\n\n")
            var images = candidateParagraphs.filter { $0.kind == .figure }.compactMap {
                block -> ReaderImageCandidate? in
                guard let url = block.imageURL else { return nil }
                return ReaderImageCandidate(
                    url: url, origin: .body, width: block.imageWidth, height: block.imageHeight, caption: block.text,
                    credit: block.imageCredit, alt: block.imageAlt)
            }
            if let effectiveImage, ReaderImageCandidate.usable(url: effectiveImage),
                !images.contains(where: { $0.url == effectiveImage })
            {
                let metadata = dom.findNodes(tag: "head").flatMap { $0.findNodes(tag: "meta") }
                func dimension(_ property: String) -> Int? {
                    metadata.first { $0.attributes["property"]?.lowercased() == property }?.attributes["content"]
                        .flatMap(Int.init)
                }
                images.append(
                    ReaderImageCandidate(
                        url: effectiveImage, origin: .openGraph,
                        width: dimension("og:image:width"), height: dimension("og:image:height")))
            }
            let title = dom.findNodes(tag: "title").map { $0.combinedText() }.joined()
            let lead = ReaderImageCandidate.select(from: images, title: title)?.url
            return .success(
                content: joined, imageUrl: lead,
                document: ReaderDocument(blocks: candidateParagraphs, images: images, leadImageURL: lead))
        case .rejected(let reason):
            return .qualityValidationFailed(reason: reason)
        }
    }

    /// Structural URL validation only; actual loads still pass through SecureHTTPClient.
    static func readerImageURL(_ raw: String?, baseURL: String?) -> String? {
        guard let raw, raw.utf8.count <= 8192,
            let url = URL(
                string: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                relativeTo: baseURL.flatMap(URL.init(string:)))?.absoluteURL,
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.isEmpty == false, url.user == nil, url.password == nil
        else { return nil }
        return url.absoluteString
    }

    // MARK: - Container Scoring Engine

    private func scoreAndExtractBestParagraphs(from root: DOMElementNode) -> [ReaderBlock] {
        var candidateContainers = [DOMElementNode]()
        collectCandidateContainers(from: root, into: &candidateContainers)

        var bestScore: Double = -1000.0
        var bestParagraphs: [ReaderBlock] = []

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
        guard !node.isReaderExcluded else { return }
        let tag = node.tag
        if tag == "article" || tag == "main" || tag == "section" || tag == "div" {
            results.append(node)
        }
        for child in node.children {
            collectCandidateContainers(from: child, into: &results)
        }
    }

    private func scoreContainer(_ container: DOMElementNode) -> (Double, [ReaderBlock]) {
        let substantiveParagraphs = container.readingBlocks().compactMap(\.readerBlock)

        guard !substantiveParagraphs.isEmpty else {
            return (-1000.0, [])
        }

        var score: Double = 0.0

        // Paragraph count & text length contribution
        let textBlocks = substantiveParagraphs.filter { $0.kind != .figure }
        score += Double(textBlocks.count) * 30.0
        let totalChars = textBlocks.reduce(0) { $0 + $1.text.count }
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
            "text-block",
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
            "footer", "nav", "menu", "trending", "more-stories", "recommend",
        ]
        for term in negativeMatches {
            if identifier.contains(term) {
                score -= 160.0
            }
        }

        // Link Density Penalty
        // Only navigation links count: cited prose keeps the container that holds every section, while a page wrapper
        // cannot outscore the article on its teasers.
        let navigation = container.navigationLinkDensity()
        if navigation > 0.35 {
            score -= 300.0
        } else if navigation > 0.20 {
            score -= 100.0
        }
        if score > 0 { score *= (1 - navigation) * (1 - navigation) }

        return (score, substantiveParagraphs)
    }

    private func extractDocumentParagraphs(from root: DOMElementNode) -> [ReaderBlock] {
        root.readingBlocks().compactMap(\.readerBlock)
    }

    /// Legacy helper returning semantic paragraphs from HTML string.
    func extractParagraphs(from html: String) -> [String] {
        let dom = HTMLDOMBuilder.parse(html: html)
        let scored = scoreAndExtractBestParagraphs(from: dom)
        if scored.count >= 2 {
            return scored.filter { $0.kind != .figure }.map(\.text)
        }
        return extractDocumentParagraphs(from: dom).filter { $0.kind != .figure }.map(\.text)
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
        if let contentType = response?.value(forHTTPHeaderField: "Content-Type"),
            let charset = extractCharset(from: contentType),
            let decoded = decode(data: data, charset: charset)
        {
            return decoded
        }

        if let asciiPrefix = String(data: data.prefix(2048), encoding: .isoLatin1),
            let charset = extractCharsetFromMeta(asciiPrefix),
            let decoded = decode(data: data, charset: charset)
        {
            return decoded
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

    private static let headerCharsetRegex = try? NSRegularExpression(
        pattern: "charset=[\"']?([a-zA-Z0-9_-]+)", options: .caseInsensitive)

    private func extractCharset(from header: String) -> String? {
        guard let regex = Self.headerCharsetRegex,
            let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
            let range = Range(match.range(at: 1), in: header)
        else { return nil }
        return String(header[range]).lowercased()
    }

    private static let metaCharsetRegexes = [
        "<meta[^>]+charset=[\"']?([a-zA-Z0-9_-]+)",
        "<meta[^>]+content=[\"'][^\"']*charset=([a-zA-Z0-9_-]+)",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    private func extractCharsetFromMeta(_ htmlSnippet: String) -> String? {
        for regex in Self.metaCharsetRegexes {
            if let match = regex.firstMatch(
                in: htmlSnippet, range: NSRange(htmlSnippet.startIndex..., in: htmlSnippet)),
                let range = Range(match.range(at: 1), in: htmlSnippet)
            {
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

    private static let ogImageRegexes: [NSRegularExpression] = [
        "<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)[\"']",
        "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:image[\"']",
        "<meta[^>]+name=[\"']twitter:image[\"'][^>]+content=[\"']([^\"']+)[\"']",
        "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']twitter:image[\"']",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    func extractLeadImage(from html: String) -> String? {
        extractLeadImages(from: html).first
    }

    private static let schemaImageRegex = try? NSRegularExpression(
        pattern: #"<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// Declared article media only; Organization and WebSite images are usually logos.
    func extractLeadImages(from html: String) -> [String] {
        var images: [String] = []
        for regex in Self.ogImageRegexes {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(20) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let candidate = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { images.append(candidate) }
            }
        }
        func imageURLs(_ value: Any, depth: Int = 0) -> [String] {
            guard depth < 16 else { return [] }
            if let url = value as? String { return [url] }
            if let object = value as? [String: Any] {
                return [object["url"], object["contentUrl"]].compactMap { $0 as? String }
            }
            if let array = value as? [Any] { return array.prefix(20).flatMap { imageURLs($0, depth: depth + 1) } }
            return []
        }
        func articleImages(_ value: Any, depth: Int = 0) -> [String] {
            guard depth < 16 else { return [] }
            if let array = value as? [Any] { return array.prefix(50).flatMap { articleImages($0, depth: depth + 1) } }
            guard let object = value as? [String: Any] else { return [] }
            let types = (object["@type"] as? [String]) ?? [object["@type"] as? String ?? ""]
            if types.contains(where: {
                ["Article", "NewsArticle", "ReportageNewsArticle", "AnalysisNewsArticle"].contains($0)
            }) {
                return object["image"].map { imageURLs($0) } ?? []
            }
            return object["@graph"].map { articleImages($0, depth: depth + 1) } ?? []
        }
        for match in Self.schemaImageRegex?.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(20)
            ?? []
        {
            guard let range = Range(match.range(at: 1), in: html),
                let json = try? JSONSerialization.jsonObject(with: Data(html[range].utf8))
            else { continue }
            images += articleImages(json)
        }
        return images
    }

    // MARK: - HTML Entity Decoding

    private static let decEntityRegex = try! NSRegularExpression(pattern: "&#([0-9]{2,7});")
    private static let hexEntityRegex = try! NSRegularExpression(pattern: "&#x([0-9a-fA-F]{2,6});")

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
            "&#8230;": "…",
        ]

        for (entity, char) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: char)
        }

        let decMatches = Self.decEntityRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in decMatches.reversed() {
            if let fullRange = Range(match.range, in: result),
                let numRange = Range(match.range(at: 1), in: result),
                let code = UInt32(result[numRange]),
                let scalar = UnicodeScalar(code)
            {
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        let hexMatches = Self.hexEntityRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in hexMatches.reversed() {
            if let fullRange = Range(match.range, in: result),
                let numRange = Range(match.range(at: 1), in: result),
                let code = UInt32(result[numRange], radix: 16),
                let scalar = UnicodeScalar(code)
            {
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        return result
    }
}
