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

// Angelia · Athena (editorial selection) owns this file. Experimental: the Today edition has no view code yet.
// Register: docs/ANGELIA.md.

import Foundation
import NaturalLanguage

/// Text-derived signals of Z2 Today lane assignment (#934): the In Motion headline test, The Deep Read
/// evidence and the interest match of Your Beat and Outside Your Usual.
extension TodayEditionAssigner {

    // MARK: - In Motion (24 h Clock & Material Change)

    /// Clock-based `hasSubstantiveUpdate` without unread/seen state (spec §2.2):
    /// Requires both reports older than 24 h ("known headlines") and at least one report within the last 24 h
    /// carrying material new reporting rather than repeating or paraphrasing a known headline.
    static func hasSubstantiveInMotionUpdate(
        _ summary: EventFeedSummary,
        now: Date,
        window: TimeInterval = 24 * 3600
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        let upperBound = now.addingTimeInterval(300)
        let knownMembers = summary.members.filter { $0.date < cutoff }
        let recentMembers = summary.members.filter { $0.date >= cutoff && $0.date <= upperBound }

        // Spec §2.2: An event whose reports all fall inside the 24 h is new, not updated.
        guard !knownMembers.isEmpty, !recentMembers.isEmpty else { return false }

        let knownTitles = knownMembers.map(\.title)
        let knownKeys = Set(knownTitles.map(EventFeedSummary.titleKey))
        let knownLemmaSets = knownTitles.map(headlineComparisonLemmas)

        return recentMembers.contains { candidate in
            let key = EventFeedSummary.titleKey(candidate.title)
            guard !key.isEmpty, !knownKeys.contains(key) else { return false }
            return isMaterialHeadlineChange(candidate: candidate.title, againstKnownTokenSets: knownLemmaSets)
        }
    }

    /// Distinguishes genuine new reporting / numbers / developments from same-story headline rewordings.
    static func isMaterialHeadlineChange(
        candidate: String,
        againstKnownTokenSets knownTokenSets: [Set<String>]
    ) -> Bool {
        let tokens = headlineComparisonLemmas(candidate)
        guard !tokens.isEmpty else { return false }
        for knownTokens in knownTokenSets where !knownTokens.isEmpty {
            let intersection = tokens.intersection(knownTokens).count
            let dice = (2.0 * Double(intersection)) / Double(tokens.count + knownTokens.count)
            let novelTokens = tokens.subtracting(knownTokens)
            let novelShare = Double(novelTokens.count) / Double(tokens.count)
            // High lemma Dice overlap (>= 0.60) or repeating core headline with <= 1 minor filler token is repetition.
            if dice >= 0.60 || (intersection >= 3 && novelTokens.count <= 1 && novelShare < 0.35) {
                return false
            }
        }
        return true
    }

    /// Lemmatized substantive headline tokens with weekday/temporal filler removed for material-change detection.
    static func headlineComparisonLemmas(_ text: String) -> Set<String> {
        let temporalFiller: Set<String> = [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "today", "yesterday", "tonight", "morning", "evening", "afternoon",
        ]
        let baseTokens = substantiveHeadlineTokens(text).subtracting(temporalFiller)
        guard !baseTokens.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var lemmas = Set<String>()
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let raw = (tag?.rawValue ?? String(text[range]))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if raw.count >= 3, !temporalFiller.contains(raw) {
                let surface = String(text[range])
                    .folding(
                        options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                if baseTokens.contains(surface) || baseTokens.contains(raw) {
                    lemmas.insert(raw)
                }
            }
            return true
        }
        return lemmas.isEmpty ? baseTokens : lemmas
    }

    // MARK: - The Deep Read (Stored Reading Time + Content-Type Classification)

    static func storedReadingTimeMinutes(
        for entry: FeedEntry,
        preloadedTexts: [String] = [],
        wordsPerMinute: Double = 200.0
    ) -> Double {
        let candidates =
            entry.visibleArticles.flatMap { article -> [String] in
                var texts: [String] = []
                if let doc = article.readerDocument {
                    texts.append(doc.blocks.map(\.text).joined(separator: " "))
                }
                if let body = article.fullContent, !body.isEmpty {
                    texts.append(body)
                }
                if !article.description.isEmpty {
                    texts.append(article.description)
                }
                return texts
            } + preloadedTexts

        let maxWords = candidates.map { $0.split { $0.isWhitespace || $0.isNewline }.count }.max() ?? 0
        guard wordsPerMinute > 0 else { return 0 }
        return Double(maxWords) / wordsPerMinute
    }

    /// The content type The Deep Read uses. A phrase found only in the feed summary does not qualify a story
    /// whose stored text is under the length bar (#1194), so the summary is read only for a stored long read.
    /// A short stored text says nothing about the length of the publisher's page: headline, section and URL
    /// evidence still classify the story.
    static func deepReadContentType(
        of article: FeedArticle,
        readingTimeMinutes: Double,
        thresholds: TodayEditionThresholds
    ) -> (type: TodayContentType, confidence: Double)? {
        classifyContentType(
            title: article.title,
            description: readingTimeMinutes >= thresholds.deepReadMinimumMinutes ? article.description : "",
            category: article.category,
            link: article.link
        )
    }

    /// Deterministic on-device content-type classifier over headline, feed summary, section/category and URL path.
    static func classifyContentType(
        title: String,
        description: String,
        category: String?,
        link: String = ""
    ) -> (type: TodayContentType, confidence: Double)? {
        let paddedTitle = MuteRules.paddedPhrase(title)
        let paddedSummary = MuteRules.paddedPhrase(description)
        let combined = "\(paddedTitle) \(paddedSummary)"
        let rawLower = "\(title) \(description) \(category ?? "") \(link)".lowercased()

        // Explicit URL/category or investigative-journalism markers carry highest confidence;
        // bare news briefs reporting "police launch investigation" stay news, not The Deep Read.
        let investigationExact: [String] = [
            "special report", "deep dive", "exclusive investigation", "an investigation by",
            "months long investigation", "documents reveal", "inside how",
        ]
        if rawLower.contains("/investigation") || rawLower.contains("/special-report")
            || title.lowercased().hasPrefix("investigation:")
            || investigationExact.contains(where: { combined.contains(MuteRules.paddedPhrase($0)) })
        {
            return (.investigation, 0.85)
        }

        let explainerExact: [String] = [
            "explainer", "explained", "how it works", "why it matters", "what to know",
            "what you need to know", "everything you need to know", "guide to", "q&a",
        ]
        if rawLower.contains("/explainer")
            || explainerExact.contains(where: { combined.contains(MuteRules.paddedPhrase($0)) })
            || title.lowercased().hasPrefix("explainer:")
            || title.lowercased().hasPrefix("how ") && title.contains("?")
        {
            return (.explainer, 0.80)
        }

        let opinionExact: [String] = [
            "opinion", "editorial", "commentary", "op ed", "columnist", "my view",
            "letters to the editor", "perspective", "viewpoint", "analysis and opinion",
        ]
        if rawLower.contains("/opinion") || rawLower.contains("/editorial") || rawLower.contains("/commentisfree")
            || (category?.lowercased().contains("opinion") == true)
            || opinionExact.contains(where: {
                paddedTitle.contains(MuteRules.paddedPhrase($0))
                    || MuteRules.paddedPhrase(category ?? "").contains(MuteRules.paddedPhrase($0))
            })
        {
            return (.opinion, 0.85)
        }
        if opinionExact.contains(where: { paddedSummary.contains(MuteRules.paddedPhrase($0)) }) {
            return (.opinion, 0.72)
        }

        return nil
    }

    // MARK: - Your Beat & Outside Your Usual (Finer Profile)

    /// Scores `interestMatch` (`0.0...1.0`) and `novelty` (`0.0...1.0`) against the 30-day finer profile.
    static func evaluateInterestProfile(
        article: FeedArticle,
        storyEntities: Set<String>,
        profile: TodayUserProfile
    ) -> (match: Double, novelty: Double) {
        guard profile.hasHistory else {
            return (0.0, 0.0)
        }

        // 1. Named entity match (`entity_mentions` / extracted named entities): strong fine signal.
        let maxEntityWeight = max(1.0, profile.entityWeights.values.max() ?? 1.0)
        let matchedEntityWeight = storyEntities.reduce(0.0) { total, id in
            total + (profile.entityWeights[id] ?? 0.0)
        }
        let entitySignal: Double
        if !storyEntities.isEmpty && !profile.entityWeights.isEmpty {
            entitySignal = min(1.0, matchedEntityWeight / max(2.0, maxEntityWeight * 1.15))
        } else {
            entitySignal = 0.0
        }

        // 2. Specific headline/section keyword match normalized by candidate length so single common
        // words cannot flood Your Beat across an entire library.
        let tokens = substantiveHeadlineTokens(article.title + " " + (article.category ?? ""))
        let maxKeywordWeight = max(1.0, profile.keywordWeights.values.max() ?? 1.0)
        let matchedKeywordWeight = tokens.reduce(0.0) { total, token in
            total + (profile.keywordWeights[token] ?? 0.0)
        }
        let denominator = max(3.0, Double(tokens.count)) * maxKeywordWeight * 0.30
        let keywordSignal =
            (!tokens.isEmpty && !profile.keywordWeights.isEmpty)
            ? min(1.0, matchedKeywordWeight / max(2.0, denominator))
            : 0.0

        // 3. Coarse 12-category share: strictly bounded (<= 0.18) so coarse category alone cannot clear 0.50.
        let totalCategoryWeight = max(1.0, profile.categoryWeights.values.reduce(0.0, +))
        let categorySignal: Double
        if let category = article.category.flatMap(NewsCategory.match(from:))?.rawValue.lowercased(),
            let catWeight = profile.categoryWeights[category],
            catWeight > 0
        {
            categorySignal = min(0.18, (catWeight / totalCategoryWeight) * 0.45)
        } else {
            categorySignal = 0.0
        }

        // Combined fine match (`0.0...1.0`)
        let rawFine = max(entitySignal, keywordSignal) * 0.75 + min(entitySignal, keywordSignal) * 0.15 + categorySignal
        let match = min(1.0, max(0.0, rawFine))
        let novelty = min(1.0, max(0.0, 1.0 - match))
        return (match, novelty)
    }

    // MARK: - Headline Tokens

    static func substantiveHeadlineTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "and", "for", "that", "with", "from", "this", "are", "was", "were",
            "will", "have", "has", "had", "not", "but", "what", "when", "where", "who",
            "why", "how", "about", "after", "before", "over", "into", "onto", "than",
            "more", "most", "new", "says", "said", "amid", "near", "under", "between",
            "could", "would", "should", "may", "might", "can", "his", "her", "their",
            "our", "its", "all", "one", "two", "first", "last", "year", "years", "day",
            "days", "week", "news", "report", "reports", "update", "updates", "live",
        ]
        return Set(
            MuteRules.foldedWords(text)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }
}
