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

// Angelia · Athena (editorial selection) owns this file. Register: docs/ANGELIA.md.

import Foundation
import NaturalLanguage

/// Per-story evaluation of Z2 Today lane assignment (#934): coverage, editorial score and personal signals of one
/// story entry, from its stored signals or conservative fallbacks.
extension TodayEditionAssigner {

    /// What a story's reports say about its coverage; the editorial score and the lane bars read it.
    struct StoryCoverage {
        let originalCount: Int
        let publisherCount: Int
        let isDeveloping: Bool
        let momentum: BriefingPriorityData.Momentum
        let hasInMotionUpdate: Bool
    }

    /// The evidence ``computeEditorialScore(_:)`` weighs.
    struct EditorialScoreInputs {
        var originalCount: Int
        var assessedImportance: StoryImportance
        var hasSectorImpact: Bool
        var momentum: BriefingPriorityData.Momentum
        var isDeveloping: Bool
        var nlImportance: Double
    }

    // MARK: - Story Evaluation

    static func evaluateStory(_ entry: FeedEntry, context: TodayAssignmentContext) -> EvaluatedStory {
        let rep = entry.representative
        let signals = context.signalsByEntryID[entry.id]
        let thresholds = context.thresholds
        let summary = eventSummary(of: entry)
        let coverage = storyCoverage(of: entry, summary: summary, context: context)

        // Grouping confidence for Coverage card gate.
        let grouping = storyGroupingConfidence(of: summary, signals: signals)
        let isCoverageConfident =
            coverage.publisherCount >= thresholds.coverageMinimumPublishers
            && coverage.originalCount >= thresholds.coverageMinimumOriginalReports
            && grouping >= thresholds.coverageMinimumGroupingConfidence

        // Personalization: publisher affinity (tie-breaker in Lead, full weight in Your Beat), stars, fine interests.
        let profile = context.profile
        let interest = evaluateInterestProfile(
            article: rep,
            storyEntities: storyEntities(of: rep, signals: signals, profile: profile),
            profile: profile
        )

        // Stored reading time: counted from stored text only (zero network fetches).
        let readingTime = storedReadingTimeMinutes(
            for: entry,
            preloadedTexts: signals?.memberFullTexts ?? [],
            wordsPerMinute: thresholds.deepReadWordsPerMinute
        )

        return EvaluatedStory(
            entry: entry,
            score: editorialScore(of: rep, signals: signals, coverage: coverage),
            originalReportCount: coverage.originalCount,
            publisherCount: coverage.publisherCount,
            publisherAffinity: profile.publisherAffinity(for: rep.publisherName),
            isTopQuartilePublisher: profile.isTopQuartilePublisher(rep.publisherName),
            isStarredFeed: isStarredFeed(entry, signals: signals, starred: context.starredFeedURLs),
            isDeveloping: coverage.isDeveloping,
            groupingConfidence: grouping,
            isCoverageConfident: isCoverageConfident,
            readingTimeMinutes: readingTime,
            contentType: deepReadContentType(of: rep, readingTimeMinutes: readingTime, thresholds: thresholds),
            interestMatch: interest.match,
            novelty: interest.novelty,
            hasInMotionUpdate: coverage.hasInMotionUpdate,
            momentum: coverage.momentum
        )
    }

    private static func eventSummary(of entry: FeedEntry) -> EventFeedSummary? {
        if case .event(let summary, _, _) = entry { return summary }
        return nil
    }

    private static func storyCoverage(
        of entry: FeedEntry,
        summary: EventFeedSummary?,
        context: TodayAssignmentContext
    ) -> StoryCoverage {
        let signals = context.signalsByEntryID[entry.id]
        let computedOriginal = max(1, BriefingPriorityData.originalReports(memberTexts(of: entry, signals: signals)))
        return StoryCoverage(
            originalCount: max(1, signals?.originalReportCount ?? computedOriginal),
            publisherCount: max(1, summary?.sources.count ?? 1),
            isDeveloping: isDevelopingEvent(summary, context: context),
            // Momentum and 24-hour In Motion substantive update.
            momentum: summary.map { BriefingPriorityData.momentum(dates: $0.members.map(\.date), now: context.now) }
                ?? .steady,
            hasInMotionUpdate: summary.map { hasInMotionUpdate($0, context: context) } ?? false
        )
    }

    /// The shipped clock test, or the two-question variant when the evaluation option sets an update window.
    private static func hasInMotionUpdate(_ summary: EventFeedSummary, context: TodayAssignmentContext) -> Bool {
        let thresholds = context.thresholds
        guard let updateWindow = thresholds.inMotionUpdateWindowSeconds else {
            return hasSubstantiveInMotionUpdate(summary, now: context.now, window: thresholds.inMotionWindowSeconds)
        }
        return hasSubstantiveInMotionUpdate(
            summary, now: context.now, underway: thresholds.inMotionWindowSeconds, updateWindow: updateWindow)
    }

    /// Each report's publisher and text: preloaded stored text when it covers the visible members, else the
    /// visible members' own text, else the member headlines.
    private static func memberTexts(
        of entry: FeedEntry,
        signals: TodayStorySignals?
    ) -> [(publisher: String, text: String)] {
        switch entry {
        case .event(let summary, let rep, let visible):
            if let preloaded = signals?.memberFullTexts, !preloaded.isEmpty {
                // When preloaded full reports exist, combine publisher with stored member text.
                let fallbackReports = visible.map { ($0.publisherName, BriefingPriorityData.reportText($0)) }
                let bySource = preloaded.enumerated().map { index, text -> (String, String) in
                    let pub = index < summary.members.count ? summary.members[index].source : rep.publisherName
                    return (pub, text)
                }
                return bySource.count >= fallbackReports.count ? bySource : fallbackReports
            } else if !visible.isEmpty {
                return visible.map { ($0.publisherName, BriefingPriorityData.reportText($0)) }
            } else {
                return summary.members.map { ($0.source, $0.title) }
            }
        case .article(let article):
            return [(article.publisherName, BriefingPriorityData.reportText(article))]
        }
    }

    /// The Developing pill shares the Briefing's definition (`EventFeedSummary.isDeveloping`).
    private static func isDevelopingEvent(_ summary: EventFeedSummary?, context: TodayAssignmentContext) -> Bool {
        summary?.isDeveloping(now: context.now, window: context.thresholds.developingWindowSeconds) ?? false
    }

    private static func storyGroupingConfidence(
        of summary: EventFeedSummary?,
        signals: TodayStorySignals?
    ) -> Double {
        if let preloaded = signals?.groupingConfidence { return preloaded }
        if let summary, summary.isConfirmed { return fallbackGroupingConfidence(for: summary) }
        return 0.0
    }

    private static func isStarredFeed(
        _ entry: FeedEntry,
        signals: TodayStorySignals?,
        starred: Set<String>
    ) -> Bool {
        let entryFeedURLs =
            Set(entry.visibleArticles.compactMap(\.identityFeedURL))
            .union(signals?.feedURLs ?? [])
        return entryFeedURLs.contains { raw in
            let key = AppSettings.feedKey(raw)
            return starred.contains(raw) || starred.contains(where: { AppSettings.feedKey($0) == key })
        }
    }

    private static func storyEntities(
        of rep: FeedArticle,
        signals: TodayStorySignals?,
        profile: TodayUserProfile
    ) -> Set<String> {
        if let preloaded = signals?.entityIDs, !preloaded.isEmpty { return preloaded }
        if !profile.entityWeights.isEmpty { return extractFallbackEntities(from: rep) }
        return []
    }

    // MARK: - Editorial Score (`0.0...1.0`)

    private static func editorialScore(
        of rep: FeedArticle,
        signals: TodayStorySignals?,
        coverage: StoryCoverage
    ) -> Double {
        // Briefing importance level (severity, coverage, sector impact, momentum/developing).
        let assessed =
            signals?.resolvedImportanceOverride
            ?? BriefingPriorityData.assessImportance(
                stored: nil,
                publisherCount: coverage.publisherCount,
                originalCount: coverage.originalCount,
                representative: rep,
                overview: nil,
                momentum: coverage.momentum,
                isDeveloping: coverage.isDeveloping
            )
        // NaturalLanguage importance score (notification threshold stays independent).
        let nlImportance =
            signals?.nlImportanceOverride
            ?? NotificationService.shared.computeImportance(title: rep.title, description: rep.description)
        let score = computeEditorialScore(
            EditorialScoreInputs(
                originalCount: coverage.originalCount,
                assessedImportance: assessed,
                hasSectorImpact: signals?.hasSectorImpact ?? false,
                momentum: coverage.momentum,
                isDeveloping: coverage.isDeveloping,
                nlImportance: nlImportance
            )
        )
        return isPromotionalDeal(title: rep.title) ? min(score, 0.25) : score
    }

    /// Computes editorial relevance on a `0.0...1.0` scale without publisher affinity (affinity is a Lead
    /// tie-breaker only) and without reading any stored notification threshold.
    static func computeEditorialScore(_ inputs: EditorialScoreInputs) -> Double {
        // 1. Original reporting breadth (saturates smoothly by ~5 independent originals; wire copies count once).
        let breadth = min(1.0, log2(Double(max(1, inputs.originalCount))) / log2(6.0)) * 0.42

        // 2. Severity / Briefing impact rating (+ sector impact if overview exists).
        let importanceComponent: Double
        switch inputs.assessedImportance {
        case .major: importanceComponent = 0.28
        case .notable: importanceComponent = 0.16
        case .minor: importanceComponent = 0.04
        }
        let sectorBoost = (inputs.hasSectorImpact && inputs.assessedImportance != .major) ? 0.05 : 0.0

        // 3. NaturalLanguage semantic salience.
        let nlComponent = min(1.0, max(0.0, inputs.nlImportance)) * 0.20

        // 4. Active momentum / developing cadence.
        let momentumComponent: Double
        if inputs.momentum == .rising && inputs.isDeveloping {
            momentumComponent = 0.10
        } else if inputs.momentum == .rising || inputs.isDeveloping {
            momentumComponent = 0.07
        } else if inputs.momentum == .steady {
            momentumComponent = 0.02
        } else {
            momentumComponent = 0.0
        }

        return min(1.0, max(0.0, breadth + importanceComponent + sectorBoost + nlComponent + momentumComponent))
    }

    // MARK: - Helper Signals

    static func isPromotionalDeal(title: String) -> Bool {
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("deals:") || lower.hasPrefix("deal:") { return true }
        let padded = MuteRules.paddedPhrase(lower)
        let promoCues = ["black friday", "cyber monday", "doorbusters", "amazon prime day", "best deals on"]
        return promoCues.contains { padded.contains(MuteRules.paddedPhrase($0)) }
    }

    private static func fallbackGroupingConfidence(for summary: EventFeedSummary) -> Double {
        let titles = summary.members.map(\.title)
        guard titles.count >= 2 else { return 0.0 }
        let tokenSets = titles.map(substantiveHeadlineTokens)
        var pairs = 0
        var totalSim = 0.0
        for i in tokenSets.indices {
            for j in tokenSets.indices where j > i {
                let a = tokenSets[i]
                let b = tokenSets[j]
                let union = a.union(b).count
                guard union > 0 else { continue }
                let jaccard = Double(a.intersection(b).count) / Double(union)
                totalSim += jaccard
                pairs += 1
            }
        }
        guard pairs > 0 else { return 0.0 }
        // Scale cohesive headline overlap into the 0.55–0.95 grouping range when pair_assessments isn't loaded.
        let meanJaccard = totalSim / Double(pairs)
        return min(0.95, 0.50 + meanJaccard * 1.25)
    }

    static func extractFallbackEntities(from article: FeedArticle) -> Set<String> {
        if let stored = article.entities, !stored.isEmpty {
            return Set(stored.map { EntityGraph.slug(name: $0.name, type: $0.type) })
        }
        let text = "\(article.title). \(article.description)"
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var slugs = Set<String>()
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard let tag else { return true }
            let entityType: EntityType
            switch tag {
            case .personalName: entityType = .person
            case .organizationName: entityType = .organization
            case .placeName: entityType = .place
            default: return true
            }
            let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count >= 2 {
                slugs.insert(EntityGraph.slug(name: name, type: entityType))
            }
            return slugs.count < 16
        }
        return slugs
    }
}
