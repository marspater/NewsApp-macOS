import Foundation
import SwiftSoup
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
    /// The publisher shows subscribers only a barrier; the feed teaser is all the reader can show.
    case subscriberOnly

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

    public var document: ReaderDocument? {
        if case .success(_, _, let doc) = self { return doc }
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
        case .subscriberOnly:
            return "The publisher requires a subscription"
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
            // Alpine.js panels stay hidden until page scripts run, and the reader never runs them (Ars Technica's
            // text-size menu).
            || attributes["x-cloak"] != nil
    }

    /// Recursively collects visible text from this node and its children. `lineBreak` marks `<br>` and the boundary
    /// before a nested paragraph, division or list item.
    func combinedText(lineBreak: String = "\n") -> String {
        guard !isReaderExcluded else { return "" }
        if tag == "br" { return lineBreak }
        if tag == "noscript" { return "" }
        var result = text
        for child in children {
            let childText = child.combinedText(lineBreak: lineBreak)
            if !childText.isEmpty {
                if ["p", "div", "li"].contains(child.tag), !result.isEmpty {
                    result += lineBreak
                } else if !result.isEmpty,
                    let lastChar = result.last, !lastChar.isWhitespace && !lastChar.isPunctuation,
                    let firstChar = childText.first, !firstChar.isWhitespace && !firstChar.isPunctuation,
                    ["span", "a", "b", "strong", "em", "i"].contains(child.tag)
                        && !["span", "a", "b", "strong", "em", "i"].contains(tag)
                {
                    result += " "
                }
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
        if ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li"].contains(tag),
            ArticleContentRedactor.isBoilerplateLine(text.isEmpty ? children.map { $0.combinedText() }.joined() : text)
        {
            return true
        }
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
        func matches(_ pattern: NSRegularExpression) -> Bool {
            identifiers.contains { pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
        if matches(Self.auxiliaryPattern) { return true }
        // A metering wrapper that still holds the story's paragraphs is the body the page served (Variety's
        // pmc-paywall); one holding only a subscription prompt is furniture.
        return matches(Self.paywallPattern)
            && findNodes(tag: "p").filter { $0.combinedText().count >= 80 }.count < 2
    }

    private static let paywallPattern =
        (try? NSRegularExpression(pattern: #"(?i)(?:^|[^a-z0-9])paywall(?:$|[^a-z0-9])"#)) ?? NSRegularExpression()

    // Token boundaries keep editorial "commentary" distinct from comment widgets.
    private static let auxiliaryPattern =
        (try? NSRegularExpression(
            pattern:
                #"(?i)(?:^|[^a-z0-9])(?:comments?|comment-thread|disqus|also-read|read-more|most-?viewed|most-?popular|onward|onwards|submeta|subscription|related(?:-content|-stories|-articles)?|links-block|newsletter|byline|timestamp-block|recommendations?|social-share|share-tools|promo|advertisement|outbrain|taboola|eventpromo|promolist|topiclist|uploaderembed)(?:$|[^a-z0-9])"#
        )) ?? NSRegularExpression()

    func readingBlocks(allowDivFallback: Bool = true) -> [DOMElementNode] {
        guard !isReaderExcluded else { return [] }
        if tag == "noscript" { return children.flatMap { $0.readingBlocks(allowDivFallback: false) } }
        if tag == "figure" || tag == "img" || tag == "picture" || tag == "hr" { return [self] }
        // An article header holds the title and byline; only its standfirst is story text.
        if tag == "header" && !HTMLDOMBuilder.isEditorial(attributes) {
            func editorial(_ node: DOMElementNode) -> [DOMElementNode] {
                HTMLDOMBuilder.isEditorial(node.attributes)
                    ? node.readingBlocks(allowDivFallback: false) : node.children.flatMap(editorial)
            }
            return children.flatMap(editorial)
        }
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
                return DOMElementNode(
                    tag: child.tag, attributes: attributes, children: child.children, text: child.text
                )
                .readingBlocks()
            }
        }
        // A nested list follows its parent item as items one level deeper instead of running into its text.
        if tag == "li", children.contains(where: { ["ul", "ol"].contains($0.tag) }) {
            let isList = { (node: DOMElementNode) in ["ul", "ol"].contains(node.tag) }
            let own = DOMElementNode(
                tag: tag, attributes: attributes, children: children.filter { !isList($0) }, text: text)
            let nested = children.filter(isList).flatMap { $0.readingBlocks(allowDivFallback: false) }.map { item in
                var attributes = item.attributes
                attributes["reader-level"] = String((Int(attributes["reader-level"] ?? "") ?? 0) + 1)
                return DOMElementNode(tag: item.tag, attributes: attributes, children: item.children, text: item.text)
            }
            return [own] + nested
        }
        if tag == "table", tableRows() != nil { return [self] }
        if ["p", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "aside"].contains(tag) { return [self] }
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
            } else if !child.isReaderExcluded && child.tag != "header" {
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

    /// Marks a publisher line break in block text and runs until whitespace is collapsed (`readerWhitespace`), so
    /// source-formatting newlines stay spaces.
    static let lineBreak = "\u{2028}"

    func inlineContent(
        strong: Bool = false, emphasis: Bool = false, code: Bool = false, link: String? = nil,
        baselineShift: Int? = nil
    ) -> [ReaderInlineRun] {
        guard !isReaderExcluded else { return [] }
        if tag == "br" { return [ReaderInlineRun(text: Self.lineBreak)] }
        let strong = strong || ["strong", "b"].contains(tag)
        let emphasis = emphasis || ["em", "i"].contains(tag)
        let code = code || tag == "code"
        let link = tag == "a" ? attributes["href"] : link
        let shifts = ["sup": 1, "sub": -1]
        let shift = shifts[tag] ?? baselineShift
        var runs =
            text.isEmpty
            ? []
            : [
                ReaderInlineRun(
                    text: text, strong: strong, emphasis: emphasis, code: code, link: link, baselineShift: shift)
            ]
        for child in children {
            let childRuns = child.inlineContent(
                strong: strong, emphasis: emphasis, code: code, link: link, baselineShift: shift)
            if ["p", "div", "li"].contains(child.tag), !runs.isEmpty, !childRuns.isEmpty {
                runs.append(ReaderInlineRun(text: Self.lineBreak))
            }
            if let lastRun = runs.last, let lastChar = lastRun.text.last,
                !lastChar.isWhitespace && !lastChar.isPunctuation,
                let firstRun = childRuns.first, let firstChar = firstRun.text.first,
                !firstChar.isWhitespace && !firstChar.isPunctuation,
                ["span", "a", "b", "strong", "em", "i"].contains(child.tag)
                    && !["span", "a", "b", "strong", "em", "i"].contains(tag)
            {
                runs.append(ReaderInlineRun(text: " "))
            }
            runs += childRuns
        }
        return runs
    }

    var readerBlock: ReaderBlock? {
        guard !isReaderExcluded else { return nil }
        if tag == "hr" { return ReaderBlock(kind: .divider, text: "") }
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
                imageCredit: credit.flatMap {
                    $0.isEmpty
                        || caption.contains(
                            $0.replacingOccurrences(of: "[ \t\r\n]+", with: " ", options: .regularExpression))
                        ? nil : $0
                },
                imageWidth: (image.attributes["width"] ?? findNodes(tag: "img").first?.attributes["width"]).flatMap(
                    Int.init),
                imageHeight: (image.attributes["height"] ?? findNodes(tag: "img").first?.attributes["height"]).flatMap(
                    Int.init))
        }
        if tag == "table", let rows = tableRows() {
            guard computeLinkDensity() < 0.8 else { return nil }
            // ponytail: wide or long tables become a notice; no scrolling grid beyond 8 × 40 cells.
            guard rows.count <= 40, rows.map(\.count).max() ?? 0 <= 8 else {
                return ReaderBlock(kind: .embed, text: "Table")
            }
            return ReaderBlock(
                kind: .table, text: rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"),
                ordinal: findNodes(tag: "tr").first?.children.contains { $0.tag == "th" } == true ? 1 : nil)
        }
        if tag == "blockquote", let embed = socialEmbed() { return embed }
        let plain = Self.readerWhitespace(combinedText(lineBreak: Self.lineBreak))
        // Checks read the text as one line, as they did before line breaks were kept.
        let flat = plain.replacingOccurrences(of: "\n", with: " ")
        guard !plain.isEmpty, !ArticleContentRedactor.isBoilerplateLine(flat) else { return nil }
        // A metadata strip item holding only a <time> (BBC's "· 20 October 2026, 14:13 BST") is not story text.
        let timestamps = findNodes(tag: "time").map { $0.combinedText() }
        if !timestamps.isEmpty {
            var residue = flat
            for stamp in timestamps {
                residue = residue.replacingOccurrences(
                    of: stamp.trimmingCharacters(in: .whitespacesAndNewlines), with: "")
            }
            let words = residue.lowercased().split { !$0.isLetter && !$0.isNumber }
            if words.allSatisfy({ ["published", "updated", "last", "on", "at"].contains($0) }) { return nil }
        }
        // A plain "(Updated: 21 October 2026)" line under the headline (CNA) is metadata, not story text.
        if flat.range(
            of: #"^(?=.*\d)(?:\((?:last )?updated:?\s[^()]{4,40}\)|(?:last )?updated:\s[^()]{4,40})$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        {
            return nil
        }
        let kind: ReaderBlock.Kind
        switch tag {
        case "h2": kind = .heading
        case "h3", "h4", "h5", "h6": kind = .subheading
        case "li": kind = .listItem
        case "aside": kind = HTMLDOMBuilder.editorialKind(attributes) ?? .quote
        case "blockquote": kind = HTMLDOMBuilder.editorialKind(attributes) == .pullQuote ? .pullQuote : .quote
        case "pre": kind = .code
        default: kind = .paragraph
        }
        // Standalone linked teasers are navigation, while inline citations remain part of prose.
        guard computeLinkDensity() < 0.8 else { return nil }
        // Short publisher paragraphs stay when they are sentences ("He was 34."); labels and button text do not.
        guard kind != .paragraph || plain.count >= 25 || (tag == "p" && Self.isShortSentence(flat)) else {
            return nil
        }
        return ReaderBlock(
            kind: kind, text: kind == .code ? combinedText().trimmingCharacters(in: .whitespacesAndNewlines) : plain,
            ordinal: attributes["reader-ordinal"].flatMap(Int.init), inlineRuns: kind == .code ? nil : inlineContent(),
            level: attributes["reader-level"].flatMap(Int.init))
    }

    /// Collapses whitespace as the reader shows it: a run holding a publisher line break becomes one newline, any
    /// other run one space; the ends are trimmed.
    static func readerWhitespace(_ text: String) -> String {
        var result = ""
        var pending: Character?
        for character in text {
            if character.isWhitespace {
                if character == "\u{2028}" || pending == nil { pending = character == "\u{2028}" ? "\n" : " " }
            } else {
                if let gap = pending, !result.isEmpty { result.append(gap) }
                pending = nil
                result.append(character)
            }
        }
        return result
    }

    static func isShortSentence(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, let first = text.first,
            first.isUppercase || first.isNumber || "\"“‘'".contains(first),
            let last = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"”’')")).last
        else { return false }
        return ".!?…".contains(last)
    }

    /// Cell text by row for a data table: at least two rows and two columns of short, plain cells. Layout tables
    /// (cells holding paragraphs, figures or long prose) return nil and are read as ordinary content.
    func tableRows() -> [[String]]? {
        guard tag == "table", findNodes(tag: "table").count == 1 else { return nil }
        var rows = [[String]]()
        for row in findNodes(tag: "tr") {
            let cells = row.children.filter { ["td", "th"].contains($0.tag) }
            guard
                !cells.contains(where: { cell in
                    ["p", "div", "figure", "img", "ul", "ol"].contains { !cell.findNodes(tag: $0).isEmpty }
                })
            else { return nil }
            let texts = cells.map {
                Self.readerWhitespace($0.combinedText()).replacingOccurrences(of: "\n", with: " ")
            }
            guard texts.allSatisfy({ $0.count <= 200 }) else { return nil }
            if texts.contains(where: { !$0.isEmpty }) { rows.append(texts) }
        }
        guard rows.count >= 2, rows.map(\.count).max() ?? 0 >= 2 else { return nil }
        return rows
    }

    /// A social post embedded as a blockquote (X, Instagram, TikTok, Bluesky, Threads) is a placeholder for the
    /// publisher's page, not a quote the publisher wrote.
    func socialEmbed() -> ReaderBlock? {
        let classes = className
        guard
            ["twitter-tweet", "instagram-media", "tiktok-embed", "bluesky-embed", "text-post-media"].contains(where: {
                classes.contains($0)
            })
        else { return nil }
        let link = findNodes(tag: "a").compactMap { $0.attributes["href"] }.last {
            ContentExtractionPipeline.readerImageURL($0, baseURL: nil) != nil
        }
        let host = link.flatMap { URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") }
        return ReaderBlock(kind: .embed, text: host ?? "Social post", imageURL: link)
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
    private static let attrRegex =
        (try? NSRegularExpression(
            pattern: #"([a-zA-Z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        )) ?? NSRegularExpression()
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    fileprivate static let ignoredTags: Set<String> = [
        "script", "style", "iframe", "svg", "nav", "footer",
        "header", "form", "aside", "dialog", "button", "select", "textarea",
    ]

    /// Pull quotes and standfirsts that publishers wrap in otherwise ignored `<aside>` and `<header>` elements.
    static let editorialPattern =
        (try? NSRegularExpression(
            pattern:
                #"(?i)pull-?quote|standfirst|(?:^|[-_ ])dek(?:$|[-_ ])|subtitle|sub-?headline|article-summary|intro-text"#
        )) ?? NSRegularExpression()

    /// The reader kind an editorial element's class names: a pull quote, or a standfirst (standfirst, dek, subtitle,
    /// sub-headline, summary or intro text).
    static func editorialKind(_ attributes: [String: String]) -> ReaderBlock.Kind? {
        guard isEditorial(attributes) else { return nil }
        let identifier = "\(attributes["class"] ?? "") \(attributes["id"] ?? "")"
        return identifier.range(of: #"(?i)pull-?quote"#, options: .regularExpression) != nil ? .pullQuote : .standfirst
    }

    static func isEditorial(_ attributes: [String: String]) -> Bool {
        let identifier = "\(attributes["class"] ?? "") \(attributes["id"] ?? "")"
        return editorialPattern.firstMatch(in: identifier, range: NSRange(identifier.startIndex..., in: identifier))
            != nil
    }

    /// Whether a tag and everything inside it is skipped. Editorial asides and headers are kept, as is an article's
    /// own header, from which only standfirst-like children are read.
    static func isIgnored(tag: String, attributes: [String: String], insideArticle: Bool = false) -> Bool {
        guard ignoredTags.contains(tag) else { return false }
        if tag == "header" && insideArticle { return false }
        guard tag == "aside" || tag == "header" else { return true }
        return !isEditorial(attributes)
    }

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
                    handleOpeningTag(scanner: scanner, stack: &stack)
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

    private static func handleOpeningTag(scanner: Scanner, stack: inout [DOMElementBuilder]) {
        // Opening or self-closing tag
        guard let tagContent = scanner.scanUpToString(">") else { return }
        _ = scanner.scanString(">")
        let parsed = parseTagContent(tagContent)
        let tagName = parsed.tag.lowercased()

        if isIgnored(
            tag: tagName, attributes: parsed.attributes, insideArticle: stack.contains { $0.tag == "article" })
        {
            if !parsed.isSelfClosing {
                skipIgnoredSubtree(scanner: scanner, tagName: tagName)
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

    private static func skipIgnoredSubtree(scanner: Scanner, tagName: String) {
        if tagName == "script" || tagName == "style" {
            skipRawText(scanner: scanner, tagName: tagName)
            return
        }
        var depth = 1
        while !scanner.isAtEnd && depth > 0 {
            _ = scanner.scanUpToString("<")
            if scanner.scanString("</") != nil {
                if let closeName = scanner.scanUpToString(">"),
                    closeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == tagName
                {
                    depth -= 1
                    _ = scanner.scanString(">")
                }
            } else if scanner.scanString("<") != nil {
                if let openName = scanner.scanUpToString(">") {
                    let openTag =
                        openName.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased()
                        ?? ""
                    if openTag == tagName
                        && !openName.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
                    {
                        depth += 1
                    }
                    _ = scanner.scanString(">")
                }
            } else {
                _ = scanner.scanCharacter()
            }
        }
    }

    /// Script and style are raw text: they end at the first closing tag, and markup inside them (such as
    /// `document.write('<script …>')`) never opens a nested element.
    private static func skipRawText(scanner: Scanner, tagName: String) {
        while !scanner.isAtEnd {
            _ = scanner.scanUpToString("</")
            guard scanner.scanString("</") != nil else { return }
            let start = scanner.currentIndex
            if let name = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: "> \t\r\n/")),
                name.lowercased() == tagName
            {
                _ = scanner.scanUpToString(">")
                _ = scanner.scanString(">")
                return
            }
            if scanner.currentIndex == start { _ = scanner.scanCharacter() }
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
            if attrString.range(of: "(?:^|\\s)x-cloak(?:\\s|=|$)", options: .regularExpression) != nil {
                attributes["x-cloak"] = ""
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

            if response.statusCode == 401 || response.statusCode == 402 { return (.subscriberOnly, nil) }
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
        let links = ((try? SwiftSoup.parse(html).select("head link[rel][href]").array()) ?? []).filter {
            ((try? $0.attr("rel")) ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).contains("canonical")
        }
        // ponytail: one same-origin canonical probe on demand; no canonical chains.
        if links.count == 1, let href = try? links.first?.attr("href"), href.utf8.count <= 8192,
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
        guard !Task.isCancelled else { return .contentParsingFailed(reason: "Extraction cancelled") }
        guard html.utf8.count <= SecureHTTPClient.defaultArticleLimit else {
            return .contentParsingFailed(reason: "Article exceeds extraction limit")
        }
        let soup = try? SwiftSoup.parse(html)
        // Structured data and barrier markers are read before scripts and furniture are removed.
        let structured = soup.map { Self.structuredArticle(in: $0) } ?? StructuredArticle()
        let hasBarrier =
            structured.isAccessibleForFree == false
            || ((try? soup?.select(Self.barrierSelector).isEmpty()) == false)
        let discoveredLeadImage = leadImage ?? soup.flatMap { leadImages(in: $0).first }
        if let soup {
            _ = try? soup.select(
                "script, style, noscript, iframe, svg, canvas, form, button, input, select, textarea, dialog, template, "
                    + "[role=navigation], [role=complementary], [role=banner], [role=search], [aria-hidden=true], "
                    + ".visually-hidden, .sr-only, "
                    + "[data-component=byline-block], [data-component=tag-list], [data-component=links-block], [data-component=topic-list], "
                    + ".video-player-error, .media-player__error, .share-tools, .social-share, .newsletter-signup, .advertisement, .ad-slot"
            ).remove()
        }
        let effectiveImage = Self.readerImageURL(discoveredLeadImage, baseURL: baseUrl)

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

        // Explicit publisher bodies beat page-wide scoring: recommendation furniture must not enlarge the story.
        if let soup,
            let explicit = try? soup.select(
                "[itemprop~=articleBody], [data-component=text-block], .article__body, .article-body, .article-body-commercial-selector, .wysiwyg, .story-body, .rich-text, .caas-body, .articlebodycontent, .entry-content, .body-description"
            ).array()
        {
            // ponytail: a fixed share of the scored body; an explicit class on a small sponsor box (BleepingComputer's
            // .article-body) must not replace the story. Tune with the catalog reader-access run if it misfires.
            let scoredLength = Self.proseLength(candidateParagraphs)
            for element in explicit.prefix(8) {
                if let blocks = repairedReadingBlocks(in: soup, containers: [element]),
                    Self.proseLength(blocks) * 5 >= scoredLength * 2
                {
                    candidateParagraphs = leadIn(before: blocks, of: element, in: soup) + blocks
                    break
                }
            }
        }
        let prose = candidateParagraphs.filter { [.paragraph, .quote, .listItem].contains($0.kind) }.map(\.text)
        if prose.count < 2 || ContentQualityValidator.validate(paragraphs: prose) != .valid,
            let soup, let fallback = repairedReadingBlocks(in: soup), !Task.isCancelled
        {
            let repairedProse = fallback.filter { [.paragraph, .quote, .listItem].contains($0.kind) }.map(\.text)
            if ContentQualityValidator.validate(paragraphs: repairedProse) == .valid,
                prose.count < repairedProse.count || ContentQualityValidator.validate(paragraphs: prose) != .valid
            {
                candidateParagraphs = fallback
            }
        }

        // A thin or failed DOM body falls back to the publisher's own schema.org articleBody.
        let domProse = candidateParagraphs.filter { [.paragraph, .quote, .listItem].contains($0.kind) }.map(\.text)
        if ContentQualityValidator.validate(paragraphs: domProse) != .valid || domProse.joined().count < 600,
            let body = structured.articleBody
        {
            let blocks = Self.paragraphs(fromPlainText: body).map { ReaderBlock(kind: .paragraph, text: $0) }
            if ContentQualityValidator.validate(paragraphs: blocks.map(\.text)) == .valid,
                blocks.map(\.text).joined().count > domProse.joined().count
            {
                candidateParagraphs = blocks
            }
        }

        if candidateParagraphs.contains(where: {
            $0.text.localizedCaseInsensitiveContains("Subscribe to unlock this article")
        }) {
            return .subscriberOnly
        }

        // Keep media in publisher order, without allowing images to qualify an empty article.
        candidateParagraphs = candidateParagraphs.map { block in
            var block = block
            if let runs = block.inlineRuns {
                // The same collapse as `DOMElementNode.readerWhitespace`, across runs: a gap goes before the next word,
                // in the run that holds it.
                var normalized = [ReaderInlineRun]()
                var pending: Character?
                var started = false
                for var run in runs {
                    var text = ""
                    for character in run.text {
                        if character.isWhitespace {
                            if character == "\u{2028}" || pending == nil {
                                pending = character == "\u{2028}" ? "\n" : " "
                            }
                        } else {
                            if let gap = pending, started { text.append(gap) }
                            pending = nil
                            started = true
                            text.append(character)
                        }
                    }
                    run.text = text
                    run.link = Self.readerImageURL(run.link, baseURL: baseUrl)
                    if !text.isEmpty { normalized.append(run) }
                }
                // Only trailing space: the last run's leading space separates it from the run before.
                while let last = normalized.last, last.text.last?.isWhitespace == true {
                    normalized[normalized.count - 1].text.removeLast()
                    if normalized[normalized.count - 1].text.isEmpty { normalized.removeLast() }
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
        let bodyLength = candidateParagraphs.filter(isText).map(\.text.count).reduce(0, +)
        if hasBarrier && (validation != .valid || (structured.isAccessibleForFree == false && bodyLength < 600)) {
            return .subscriberOnly
        }
        candidateParagraphs = Self.tidiedDividers(candidateParagraphs).flatMap(Self.splitLongParagraph)
        switch validation {
        case .valid:
            let joined = candidateParagraphs.filter { ![.figure, .divider].contains($0.kind) }.map(\.text)
                .joined(separator: "\n\n")
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
                func dimension(_ property: String) -> Int? {
                    guard let soup,
                        let value = try? soup.select("meta[property=\"\(property)\"]").first()?.attr("content")
                    else { return nil }
                    return Int(value)
                }
                images.append(
                    ReaderImageCandidate(
                        url: effectiveImage, origin: .openGraph,
                        width: dimension("og:image:width"), height: dimension("og:image:height")))
            }
            let title = dom.findNodes(tag: "title").map { $0.combinedText() }.joined()
            let lead = ReaderImageCandidate.select(from: images, title: title)?.url
            let isComplete = candidateParagraphs.filter { $0.kind == .paragraph }.count >= 3 && joined.count >= 600
            return .success(
                content: joined, imageUrl: lead,
                document: ReaderDocument(
                    version: ReaderDocument.currentVersion,
                    blocks: candidateParagraphs,
                    images: images,
                    leadImageURL: lead,
                    isComplete: isComplete))
        case .rejected(let reason):
            return .qualityValidationFailed(reason: reason)
        }
    }

    /// Lead media and a standfirst the article shows just before its explicit body (the Guardian's media and standfirst
    /// sit beside the body, not inside it). At most four blocks are considered; only figures and one paragraph from a
    /// standfirst-marked element are kept, so headlines, bylines and player notes stay out.
    private func leadIn(before body: [ReaderBlock], of element: SwiftSoup.Element, in document: SwiftSoup.Document)
        -> [ReaderBlock]
    {
        guard let first = body.first(where: { $0.kind != .figure })?.text,
            let article = element.parents().array().first(where: { $0.tagName() == "article" }),
            let blocks = repairedReadingBlocks(in: document, containers: [article]),
            let start = blocks.firstIndex(where: { $0.text == first })
        else { return [] }
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "[ \t\r\n]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let standfirsts = Set(
            ((try? article.getAllElements().array()) ?? []).filter { candidate in
                (try? candidate.attr("data-gu-name")) == "standfirst"
                    || HTMLDOMBuilder.isEditorial([
                        "class": (try? candidate.className()) ?? "", "id": candidate.id(),
                    ])
            }.compactMap { try? normalized($0.text()) })
        let bodyImages = Set(body.compactMap(\.imageURL))
        let bodyTexts = Set(body.map(\.text))
        var keptStandfirst = false
        return blocks[..<start].suffix(4).filter { block in
            if block.kind == .figure {
                return block.imageURL.map { !bodyImages.contains($0) } ?? false
            }
            guard block.kind == .paragraph, !keptStandfirst, !bodyTexts.contains(block.text),
                standfirsts.contains(normalized(block.text))
            else { return false }
            keptStandfirst = true
            return true
        }
    }

    private static func proseLength(_ blocks: [ReaderBlock]) -> Int {
        blocks.filter { [.paragraph, .quote, .listItem].contains($0.kind) }.map(\.text.count).reduce(0, +)
    }

    struct StructuredArticle {
        var articleBody: String?
        var isAccessibleForFree: Bool?
    }

    /// Elements publishers use for subscription barriers (FT's barrier grid, Piano, generic paywall wrappers).
    private static let barrierSelector =
        "[class*=paywall], [id*=paywall], [class*=barrier], [id*=barrier], [data-component*=barrier], "
        + "[class*=subscribe-wall], [class*=subscription-wall], [class*=regwall], [id*=regwall], .tp-modal"

    /// The longest schema.org articleBody and any isAccessibleForFree=false flag in the page's JSON-LD, then in
    /// Next.js hydration state (`__NEXT_DATA__`), where the body may be HTML.
    static func structuredArticle(in document: SwiftSoup.Document) -> StructuredArticle {
        var scan = StructuredScan()
        for script in ((try? document.select("script[type=application/ld+json]").array()) ?? []).prefix(16) {
            let data = Data(script.data().utf8)
            guard data.count <= 1024 * 1024, let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            scan.visitLinkedData(json, depth: 0)
        }
        // A missing or teaser-length JSON-LD body still looks in hydration state; the longer body wins.
        if (scan.result.articleBody?.count ?? 0) < 600, let next = try? document.select("script#__NEXT_DATA__").first()
        {
            let data = Data(next.data().utf8)
            if data.count <= 4 * 1024 * 1024, let json = try? JSONSerialization.jsonObject(with: data) {
                scan.visitHydration(json, depth: 0)
            }
        }
        return scan.result
    }

    /// A bounded walk over decoded JSON that keeps the longest article body it meets.
    private struct StructuredScan {
        var result = StructuredArticle()
        var budget = 20_000

        mutating func consider(_ body: String) {
            guard body.count > (result.articleBody?.count ?? 0), body.utf8.count <= 512 * 1024 else { return }
            result.articleBody = body
        }

        /// schema.org JSON-LD: articleBody, the isAccessibleForFree flag and the containers that nest articles.
        mutating func visitLinkedData(_ value: Any, depth: Int) {
            budget -= 1
            guard depth < 8, budget > 0 else { return }
            if let array = value as? [Any] {
                for item in array.prefix(64) { visitLinkedData(item, depth: depth + 1) }
                return
            }
            guard let object = value as? [String: Any] else { return }
            if let body = object["articleBody"] as? String { consider(body) }
            let free = object["isAccessibleForFree"]
            if (free as? Bool) == false || (free as? String)?.lowercased() == "false" {
                result.isAccessibleForFree = false
            }
            for key in ["@graph", "hasPart", "mainEntity", "mainEntityOfPage"] {
                if let nested = object[key] { visitLinkedData(nested, depth: depth + 1) }
            }
        }

        /// Hydration state has no schema: every key is searched for a prose-length body.
        /// ponytail: key-name heuristic for hydration state; add per-publisher paths if this misses.
        mutating func visitHydration(_ value: Any, depth: Int) {
            budget -= 1
            guard depth < 14, budget > 0 else { return }
            if let array = value as? [Any] {
                for item in array.prefix(64) { visitHydration(item, depth: depth + 1) }
                return
            }
            guard let object = value as? [String: Any] else { return }
            for key in ["articleBody", "body", "bodyHtml", "content", "contentHtml"] {
                if let body = object[key] as? String, body.count >= 600, body.contains(". ") { consider(body) }
            }
            for nested in object.values.prefix(256) { visitHydration(nested, depth: depth + 1) }
        }
    }

    /// Paragraphs from plain text: publisher line breaks when present, otherwise groups of sentences.
    static func paragraphs(fromPlainText text: String) -> [String] {
        if text.range(of: "<p[ >]", options: [.regularExpression, .caseInsensitive]) != nil {
            return ContentExtractionPipeline.shared.extractParagraphs(from: text)
        }
        let decoded = ContentExtractionPipeline.shared.decodeHTMLEntities(text)
        let lines = decoded.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 25 }
        if lines.count >= 2 { return lines }
        let single = decoded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return splitLongParagraph(ReaderBlock(kind: .paragraph, text: single)).map(\.text)
    }

    /// Section dividers only between content: never first, last or repeated.
    static func tidiedDividers(_ blocks: [ReaderBlock]) -> [ReaderBlock] {
        var result = [ReaderBlock]()
        for block in blocks {
            if block.kind == .divider && (result.isEmpty || result.last?.kind == .divider) { continue }
            result.append(block)
        }
        if result.last?.kind == .divider { result.removeLast() }
        return result
    }

    /// Splits a wall-of-text paragraph (over 650 characters, four or more sentences) at sentence boundaries into
    /// paragraphs of roughly 300 or more characters. Inline formatting is split with the text; if the runs no longer
    /// match the words they are dropped and the plain text is kept.
    static func splitLongParagraph(_ block: ReaderBlock) -> [ReaderBlock] {
        let text = block.text
        guard block.kind == .paragraph, text.count > 650 else { return [block] }
        let cuts = sentenceCuts(in: text)
        guard !cuts.isEmpty else { return [block] }
        let bounds = [0] + cuts + [text.count]
        return zip(bounds, bounds.dropFirst()).map { lower, upper in
            let range = text.index(text.startIndex, offsetBy: lower)..<text.index(text.startIndex, offsetBy: upper)
            let piece = String(text[range]).trimmingCharacters(in: .whitespaces)
            let runs = block.inlineRuns.map { slice($0, from: lower, to: upper) }
            return ReaderBlock(
                kind: .paragraph, text: piece, ordinal: block.ordinal,
                inlineRuns: runs?.map(\.text).joined() == piece ? runs : nil)
        }
    }

    /// Character offsets where a wall of text splits: after sentences, once a piece holds 300 characters and two
    /// sentences, never leaving a tail under 120 characters. Empty with fewer than four sentences.
    private static func sentenceCuts(in text: String) -> [Int] {
        var ends = [Int]()
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) {
            _, _, enclosing, _ in
            ends.append(text.distance(from: text.startIndex, to: enclosing.upperBound))
        }
        guard ends.count >= 4 else { return [] }
        var cuts = [Int]()
        var start = 0
        var sentences = 0
        for end in ends.dropLast() {
            sentences += 1
            if end - start >= 300 && sentences >= 2 && text.count - end >= 120 {
                cuts.append(end)
                start = end
                sentences = 0
            }
        }
        return cuts
    }

    /// The inline runs covering characters `lower..<upper`, with the piece's outer whitespace removed.
    private static func slice(_ runs: [ReaderInlineRun], from lower: Int, to upper: Int) -> [ReaderInlineRun] {
        var offset = 0
        var sliced = [ReaderInlineRun]()
        for run in runs {
            let runEnd = offset + run.text.count
            let from = max(lower, offset)
            let to = min(upper, runEnd)
            if from < to {
                var part = run
                let start = run.text.index(run.text.startIndex, offsetBy: from - offset)
                let end = run.text.index(run.text.startIndex, offsetBy: to - offset)
                part.text = String(run.text[start..<end])
                sliced.append(part)
            }
            offset = runEnd
        }
        if !sliced.isEmpty { sliced[0].text = String(sliced[0].text.drop(while: \.isWhitespace)) }
        sliced.removeAll { $0.text.isEmpty }
        while let last = sliced.last, last.text.last?.isWhitespace == true {
            sliced[sliced.count - 1].text.removeLast()
            if sliced[sliced.count - 1].text.isEmpty { sliced.removeLast() }
        }
        return sliced
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

    private func repairedReadingBlocks(in document: SwiftSoup.Document, containers explicit: [SwiftSoup.Element]? = nil)
        -> [ReaderBlock]?
    {
        var count = 0
        func attributes(_ element: SwiftSoup.Element) -> [String: String] {
            Dictionary(
                (element.getAttributes()?.asList() ?? []).map { ($0.getKey(), $0.getValue()) },
                uniquingKeysWith: { first, _ in first })
        }
        func excluded(_ element: SwiftSoup.Element) -> Bool {
            HTMLDOMBuilder.isIgnored(tag: element.tagName(), attributes: attributes(element))
                || element.tagName() == "template"
                || DOMElementNode(tag: element.tagName(), attributes: attributes(element)).isReaderExcluded
        }
        func convert(_ node: SwiftSoup.Node, depth: Int, insideArticle: Bool) -> DOMElementNode? {
            guard !Task.isCancelled, depth < 128, count < 50_000 else { return nil }
            count += 1
            if let text = node as? SwiftSoup.TextNode {
                return DOMElementNode(tag: "#text", text: text.getWholeText())
            }
            // An article's own header stays, as in the DOM builder: its standfirst is story text.
            guard let element = node as? SwiftSoup.Element,
                !HTMLDOMBuilder.isIgnored(
                    tag: element.tagName(), attributes: attributes(element), insideArticle: insideArticle),
                element.tagName() != "template"
            else { return nil }
            let inArticle = insideArticle || element.tagName() == "article"
            // Exclusion reads the element's text, so it is judged with its children: an empty paragraph shell would
            // look like boilerplate and drop every paragraph of the body.
            let converted = DOMElementNode(
                tag: element.tagName(), attributes: attributes(element),
                children: element.getChildNodes().compactMap {
                    convert($0, depth: depth + 1, insideArticle: inArticle)
                })
            return converted.isReaderExcluded ? nil : converted
        }
        // ponytail: bounded repair of explicit article containers; no second readability scoring engine.
        let containers = explicit ?? ((try? document.select("[itemprop~=articleBody], article, main").array()) ?? [])
        for element in containers.prefix(32) {
            guard !element.parents().array().contains(where: excluded) else { continue }
            let insideArticle = element.parents().array().contains { $0.tagName() == "article" }
            guard let node = convert(element, depth: 0, insideArticle: insideArticle), !node.isReaderExcluded
            else { continue }
            let blocks = node.readingBlocks().compactMap(\.readerBlock)
            let prose = blocks.filter { [.paragraph, .quote, .listItem].contains($0.kind) }.map(\.text)
            if ContentQualityValidator.validate(paragraphs: prose) == .valid { return blocks }
        }
        return nil
    }

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
        for term in positiveMatches where identifier.contains(term) {
            score += 45.0
        }

        // Heavy Negative Penalties for Widgets, Comments & Navigation
        let negativeMatches = [
            "comment", "share", "social", "related", "sidebar", "ad-",
            "advertisement", "newsletter", "promo", "cookie", "banner",
            "footer", "nav", "menu", "trending", "more-stories", "recommend",
        ]
        for term in negativeMatches where identifier.contains(term) {
            score -= 160.0
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

    func extractLeadImage(from html: String) -> String? {
        extractLeadImages(from: html).first
    }

    /// Declared article media only; Organization and WebSite images are usually logos.
    func extractLeadImages(from html: String) -> [String] {
        guard !Task.isCancelled, html.utf8.count <= SecureHTTPClient.defaultArticleLimit,
            let document = try? SwiftSoup.parse(html)
        else { return [] }
        return leadImages(in: document)
    }

    private func leadImages(in document: SwiftSoup.Document) -> [String] {
        var images: [String] = []
        let metadata = (try? document.select("meta[property], meta[name]").array()) ?? []
        for key in ["og:image", "twitter:image"] {
            for element in metadata.filter({
                ((try? $0.attr(key == "og:image" ? "property" : "name")) ?? "").lowercased() == key
            }).prefix(20) {
                let candidate = ((try? element.attr("content")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        let scripts = ((try? document.select("script[type]").array()) ?? []).filter {
            ((try? $0.attr("type")) ?? "").lowercased().split(separator: ";").first?.trimmingCharacters(
                in: .whitespaces) == "application/ld+json"
        }
        for script in scripts.prefix(20) {
            guard !Task.isCancelled,
                let json = try? JSONSerialization.jsonObject(with: Data(script.data().utf8))
            else { continue }
            images += articleImages(json)
        }
        return images
    }

    // MARK: - HTML Entity Decoding

    private static let decEntityRegex = (try? NSRegularExpression(pattern: "&#([0-9]{2,7});")) ?? NSRegularExpression()
    private static let hexEntityRegex =
        (try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]{2,6});")) ?? NSRegularExpression()

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
