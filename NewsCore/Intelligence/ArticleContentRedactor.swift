// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import NaturalLanguage

// MARK: - Article Content Redactor & Formatter

public enum ArticleContentRedactor {
    private static let boilerplatePatterns: [String] = [
        // Fused sentence ending, e.g. 'last year.Read full article' or 'last year. Read full article Comments'
        "(?i)(\\.|!|\\?)\\s*(?:read full article|read more|continue reading|view comments|leave a comment|full story)\\b.*$",
        // Trailing standalone boilerplate
        "(?i)[\\s\\.]*\\b(?:read full article|read more|continue reading|view comments|leave a comment|full story)\\b[\\s\\.]*$",
        // Syndication notices at end of line
        "(?i)the post .* appeared first on .*\\.?$",
    ]

    private static let boilerplateLineExact: Set<String> = [
        "most viewed", "explore more on these topics",
        "comments", "comment", "read full article", "read more", "continue reading",
        "view comments", "leave a comment", "share this article", "share this post",
        "related articles", "related topics", "more on this story", "source", "read original", "full article",
        "full story", "keywords for this article", "keywords for this story", "keywords",
        "tags for this article", "tags for this story", "email story", "join our whatsapp channel",
    ]

    private static let compiledBoilerplateRegexes: [(regex: NSRegularExpression, template: String)] = {
        boilerplatePatterns.compactMap { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
                return nil
            }
            return (regex, pattern.contains("(\\.|!|\\?)") ? "$1" : "")
        }
    }()

    /// Cleans boilerplate phrases, syndication notes, and trailing artifacts from text.
    public static func cleanText(_ rawText: String) -> String {
        var text = rawText

        for compiled in compiledBoilerplateRegexes {
            let range = NSRange(text.startIndex..., in: text)
            text = compiled.regex.stringByReplacingMatches(
                in: text, options: [], range: range, withTemplate: compiled.template)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Redacts boilerplate and intelligently splits article content into readable editorial paragraphs.
    public static func redactAndSplit(_ rawText: String) -> [String] {
        let normalized =
            rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let rawParagraphs: [String]
        if normalized.contains("\n\n") {
            rawParagraphs = normalized.components(separatedBy: "\n\n")
        } else if normalized.contains("\n") {
            rawParagraphs = normalized.components(separatedBy: "\n")
        } else {
            rawParagraphs = [normalized]
        }

        var result = [String]()
        for para in rawParagraphs {
            let cleaned = cleanText(para)
            guard !cleaned.isEmpty else { continue }
            if isBoilerplateLine(cleaned) { continue }

            // If a single paragraph is too monolithic (> 450 characters and 3+ sentences), split it
            if cleaned.count > 450 {
                let subParagraphs = splitLongParagraph(cleaned)
                for sub in subParagraphs {
                    let subCleaned = cleanText(sub)
                    if !subCleaned.isEmpty && !isBoilerplateLine(subCleaned) {
                        result.append(subCleaned)
                    }
                }
            } else {
                result.append(cleaned)
            }
        }

        while let last = result.last, isBoilerplateLine(last) {
            result.removeLast()
        }

        return result
    }

    /// Checks if a string is solely a boilerplate phrase or syndication footer.
    public static func isBoilerplateLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!-–—()[]{}•*#0123456789/ "))
        let lower = stripped.lowercased()

        if rawNewsletterCTA(trimmed) { return true }
        if boilerplateLineExact.contains(lower) {
            return true
        }
        if (lower.hasPrefix("comment") || lower.hasSuffix("comments")) && lower.count < 25 {
            return true
        }
        let rawLower = trimmed.lowercased()
        if rawLower.hasPrefix("the post ") && rawLower.contains(" appeared first on ") {
            return true
        }
        if rawLower.hasPrefix("photo by ") || rawLower.hasPrefix("image credit:") || rawLower.hasPrefix("photo credit:")
        {
            return true
        }
        // Video errors and playback placeholders (BBC News, Al Jazeera, France 24)
        if rawLower.contains("to play this video you need to enable javascript")
            || rawLower.contains("to view this video please enable javascript")
            || rawLower.contains("this video can not be played")
            || rawLower.contains("this video cannot be played")
            || (rawLower.hasPrefix("video duration") && rawLower.count < 80)
            || (rawLower.hasPrefix("watch:") && rawLower.count < 60)
        {
            return true
        }
        // Follow prompts for a personalised feed (The Verge).
        if rawLower.contains("personalized homepage feed") || rawLower.contains("personalised homepage feed")
            || (rawLower.hasPrefix("follow topics") && rawLower.count < 80)
            || (rawLower.hasPrefix("follow ") && rawLower.contains("email updates"))
            || (rawLower.hasPrefix("posts from this") && rawLower.contains("homepage feed"))
        {
            return true
        }
        // Google Preferred Source prompts (CNA, DW, Google News CTAs)
        if rawLower.contains("preferred source on google")
            || rawLower.contains("trusted source to help google")
            || rawLower.contains("follow us on google news")
        {
            return true
        }
        // Editorial standards, corrections, credits footers (CBC, DW, The Hindu)
        if rawLower.hasPrefix("cbc's journalistic standards")
            || rawLower.hasPrefix("corrections and clarifications")
            || (rawLower.hasPrefix("edited by:") && rawLower.count < 100)
            || (rawLower.hasPrefix("published - ") && rawLower.count < 100)
            || (rawLower.hasPrefix("by ") && rawLower.count < 100
                && (rawLower.contains("correspondent") || rawLower.contains("reporter")
                    || rawLower.contains("editor")))
        {
            return true
        }
        // Consent and player notices that stand in for embedded video (France 24).
        if rawLower.hasPrefix("to display this content from") && rawLower.contains("you must enable")
            || rawLower.hasPrefix("one of your browser extensions seems to be blocking")
        {
            return true
        }
        // Tag and keyword strips (e.g. France 24 footer "Keywords for this article" or "Topics:ReformGiorgia MeloniItaly").
        if rawLower.count < 200,
            ["topics:", "tags:", "related topics:", "keywords:", "keywords for this", "tags for this"].contains(
                where: rawLower.hasPrefix)
        {
            return true
        }
        // Missing, expired or unavailable placeholder notices (e.g. France 24 "The content you requested does not exist or is not available anymore.").
        if rawLower.contains("content you requested does not exist")
            || rawLower.contains("is not available anymore")
            || (rawLower.contains("content is no longer available") && rawLower.count < 150)
            || (rawLower.contains("no longer available") && rawLower.count < 100)
        {
            return true
        }
        return false
    }

    private static func rawNewsletterCTA(_ text: String) -> Bool {
        text.range(of: "(?i)^(?:sign up|subscribe) (?:for|to) (?:our|the) .*newsletter\\b", options: .regularExpression)
            != nil
    }

    /// Splits a large unsegmented paragraph at sentence boundaries into balanced readable paragraphs.
    private static func splitLongParagraph(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences = [String]()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }

        guard sentences.count > 2 else { return [text] }

        var paragraphs = [String]()
        var currentPara = ""
        for sentence in sentences {
            if !currentPara.isEmpty && (currentPara.count + sentence.count > 320) {
                paragraphs.append(currentPara)
                currentPara = sentence
            } else {
                if currentPara.isEmpty {
                    currentPara = sentence
                } else {
                    currentPara += " " + sentence
                }
            }
        }
        if !currentPara.isEmpty {
            paragraphs.append(currentPara)
        }
        return paragraphs.isEmpty ? [text] : paragraphs
    }
}
