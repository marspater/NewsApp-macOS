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

/// The comparisons of 11 November 2026 for Z2 (`#934`), run inside `--today-shadow` on the same copy, clock and
/// subscription list as the main report. In Motion: the shipped rule beside an update window of 24 h and 36 h, each
/// with and without rising momentum. Your Beat: the shipped publisher affinity beside narrower ones, each for the
/// whole reading history, its newest 15 and 5 stories, and none. The report holds counts only; one private sheet
/// lists the stories each In Motion variant lets through.
extension TodayShadowEvaluation {
    struct ComparisonInputs {
        let database: DatabaseEngine
        let now: Date
        let entries: [FeedEntry]
        let entries24h: [FeedEntry]
        var context: TodayAssignmentContext
        let shippedPlan: TodayEditionPlan
        let labels: StoryLabels?
        let allArticles: [FeedArticle]
    }

    struct ComparisonReport: Encodable {
        let inMotion: [InMotionVariantReport]
        let yourBeat: [YourBeatVariantReport]
        /// Days of stories the copy holds inside the 30-day profile window: the span behind "stories published".
        let publishedSpanDays: Double
    }

    struct InMotionVariantReport: Encodable {
        let name: String
        /// Nil for the shipped rule, which uses one 24 h cutoff for both questions.
        let updateWindowHours: Double?
        let requiresRising: Bool
        let clearingBar: Int
        let laneSize: Int
        let laneShows: Bool
        let laneCounts: [String: Int]
        let lanePurityOverall: Double?
        let lanePurityByLane: [String: Double]
        /// `<label>:<outcome>` over the labelled events. Outcomes: `shown`, `inTheLead`, `droppedByCap`,
        /// `laneHidden`, `notRising` (a substantive update without the momentum), `noUpdateInWindow` (the headline
        /// test found none) and `notACandidate` (outside the subscription list).
        let labelledEvents: [String: Int]
        let unlabelledShown: Int
        /// Stories clearing the bar whose newest report is older than 24 h, and those among them whose every
        /// report is 24 to 36 h old: a first day's burst of differing headlines, read as an update.
        let clearingWithNoReportInside24h: Int
        let clearingWithEveryReport24To36hOld: Int
        /// Against the shipped plan: the lanes the variant's new In Motion stories came from, and the lanes the
        /// shipped plan's In Motion stories went to.
        let enteredFrom: [String: Int]
        let leftTo: [String: Int]
    }

    struct YourBeatVariantReport: Encodable {
        let rule: String
        let history: String
        /// Read or saved stories in the profile, and publishers with a weight of 2 or more.
        let interactions: Int
        let engagedPublishers: Int
        let affinityPublishers: Int
        /// Where the affinity publishers rank by candidate stories of the last 24 h (1 is the busiest); no names.
        let affinityPublisherVolumeRanks: [Int]
        let candidates24h: Int
        let qualifying24h: Int
        let qualifying24hByReason: [String: Int]
        let qualifying24hTopPublisherShare: Double
        let qualifying24hTopThreeShare: Double
        let shown24h: Int
        let shown: Int
        let shows: Bool
        let shownTopPublisherShare: Double
        let shownTopThreeShare: Double
        /// Labelled stories the lane shows, and those among them whose label expects Your Beat.
        let shownLabelled: Int
        let shownLabelledAsExpected: Int
        let lanePurityOverall: Double?
        let outsideClearingBar: Int
        let outsideShown: Int
        let outsideShows: Bool
        /// Stories the lane shows that the shipped rule, with the whole history, does not show there.
        let shownNotInShipped: Int
        let outsideNotInShipped: Int
        let laneCounts: [String: Int]
    }

    struct PrivateInMotionVariantRow: Encodable {
        let variant: String
        let eventID: String
        let title: String
        let label: String?
        let momentum: String
        let newestReportAgeHours: Double
        let outcome: String
    }

    static func compareVariants(_ inputs: ComparisonInputs, privateOutput: URL) async throws -> ComparisonReport {
        // A story's language score is the costly part of a pass and no variant changes it, so each is computed
        // once and handed to every pass. The pools keep the language models' buffers from piling up over the
        // passes: this function's caller is one long job that never drains its own.
        var inputs = inputs
        for entry in inputs.entries {
            autoreleasepool {
                let story = entry.representative
                inputs.context.signalsByEntryID[entry.id, default: TodayStorySignals()].nlImportanceOverride =
                    NotificationService.shared.computeImportance(title: story.title, description: story.description)
            }
        }
        let inMotion = try inMotionVariants(inputs, privateOutput: privateOutput)
        let yourBeat = try await yourBeatVariants(inputs)
        return ComparisonReport(
            inMotion: inMotion, yourBeat: yourBeat.reports, publishedSpanDays: yourBeat.publishedSpanDays)
    }

    private static func laneCounts(_ plan: TodayEditionPlan) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: plan.lanes.map { ($0.lane.rawValue, $0.entries.count) })
    }

    // MARK: - In Motion

    private static func inMotionVariants(
        _ inputs: ComparisonInputs, privateOutput: URL
    ) throws -> [InMotionVariantReport] {
        let variants: [(name: String, windowHours: Double?, rising: Bool)] = [
            ("shipped", nil, true),
            ("24h-rising", 24, true),
            ("24h-any-momentum", 24, false),
            ("36h-rising", 36, true),
            ("36h-any-momentum", 36, false),
        ]
        let now = inputs.now
        let eventLabels = inputs.labels?.events ?? [:]
        let shippedLanes = Dictionary(uniqueKeysWithValues: inputs.shippedPlan.allAssignments.map { ($0.id, $0.lane) })
        let shippedShown = Set(inputs.shippedPlan.entries(for: .inMotion).map(\.id))
        var sheet: [PrivateInMotionVariantRow] = []

        let reports = variants.map { variant in
            autoreleasepool { () -> InMotionVariantReport in
                var context = inputs.context
                context.thresholds.inMotionUpdateWindowSeconds = variant.windowHours.map { $0 * 3600 }
                context.thresholds.inMotionRequiresRisingMomentum = variant.rising
                let plan = TodayEditionAssigner.assign(entries: inputs.entries, context: context)
                let lanes = Dictionary(uniqueKeysWithValues: plan.allAssignments.map { ($0.id, $0.lane) })
                let shown = Set(plan.entries(for: .inMotion).map(\.id))

                var outcomes: [String: String] = [:]
                var clearing = 0
                var noReportInside24h = 0
                var everyReport24To36hOld = 0
                var unlabelledShown = 0
                for story in evaluatedCandidates(of: plan, context: context) {
                    guard case .event(let summary, let representative, _) = story.entry else { continue }
                    let clears = TodayEditionAssigner.inMotionPlacement(story, thresholds: context.thresholds) != nil
                    let outcome: String
                    if shown.contains(story.id) {
                        outcome = "shown"
                    } else if clears {
                        outcome =
                            lanes[story.id] == .theLead ? "inTheLead" : (shown.isEmpty ? "laneHidden" : "droppedByCap")
                    } else {
                        outcome = story.hasInMotionUpdate ? "notRising" : "noUpdateInWindow"
                    }
                    outcomes[summary.eventID] = outcome
                    guard clears else { continue }

                    clearing += 1
                    let ages = summary.members.map { now.timeIntervalSince($0.date) / 3600 }
                    if ages.allSatisfy({ $0 > 24 }) {
                        noReportInside24h += 1
                        if ages.allSatisfy({ $0 <= 36 }) { everyReport24To36hOld += 1 }
                    }
                    if outcome == "shown", eventLabels[summary.eventID] == nil { unlabelledShown += 1 }
                    sheet.append(
                        PrivateInMotionVariantRow(
                            variant: variant.name, eventID: summary.eventID, title: representative.title,
                            label: eventLabels[summary.eventID],
                            momentum: story.momentum == .rising
                                ? "rising" : (story.momentum == .fading ? "fading" : "steady"),
                            newestReportAgeHours: ages.min() ?? 0, outcome: outcome))
                }
                var labelled: [String: Int] = [:]
                for (eventID, label) in eventLabels {
                    labelled["\(label):\(outcomes[eventID] ?? "notACandidate")", default: 0] += 1
                }
                let purity = lanePurity(of: plan, labels: inputs.labels?.stories ?? [:])
                return InMotionVariantReport(
                    name: variant.name,
                    updateWindowHours: variant.windowHours,
                    requiresRising: variant.rising,
                    clearingBar: clearing,
                    laneSize: shown.count,
                    laneShows: !shown.isEmpty,
                    laneCounts: laneCounts(plan),
                    lanePurityOverall: purity.overall,
                    lanePurityByLane: purity.byLane,
                    labelledEvents: labelled,
                    unlabelledShown: unlabelledShown,
                    clearingWithNoReportInside24h: noReportInside24h,
                    clearingWithEveryReport24To36hOld: everyReport24To36hOld,
                    enteredFrom: tally(shown.subtracting(shippedShown).compactMap { shippedLanes[$0]?.rawValue }),
                    leftTo: tally(shippedShown.subtracting(shown).compactMap { lanes[$0]?.rawValue })
                )
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try StoryCorpus.writePrivate(
            try encoder.encode(sheet), to: privateOutput.appendingPathComponent("in-motion-variants-private.json"),
            replacing: true)
        return reports
    }

    private static func tally(_ names: [String]) -> [String: Int] {
        Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
    }

    // MARK: - Your Beat

    private static func publisherKey(_ article: FeedArticle) -> String {
        EventFeedSummary.displaySource(article.publisherName).lowercased()
    }

    /// The shares of the busiest publisher and of the busiest three among `publishers`.
    private static func concentration(_ publishers: [String]) -> (top: Double, topThree: Double) {
        guard !publishers.isEmpty else { return (0, 0) }
        let counts = tally(publishers).values.sorted(by: >)
        let total = Double(publishers.count)
        return (Double(counts[0]) / total, Double(counts.prefix(3).reduce(0, +)) / total)
    }

    /// The top quartile of `engaged` publishers by `value`, as `TodayUserProfile` takes it from the weights.
    private static func topQuartile(_ engaged: [String: Double], by value: (String, Double) -> Double) -> Set<String> {
        guard !engaged.isEmpty else { return [] }
        let valued: [(key: String, value: Double)] = engaged.map { ($0.key, value($0.key, $0.value)) }
        let ranked = valued.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let quartile = max(1, Int(ceil(Double(ranked.count) * 0.25)))
        return Set(ranked.prefix(quartile).map { $0.key })
    }

    private static func yourBeatVariants(
        _ inputs: ComparisonInputs
    ) async throws -> (reports: [YourBeatVariantReport], publishedSpanDays: Double) {
        let now = inputs.now
        let profileStart = now.addingTimeInterval(-30 * 86400)

        // Stories each publisher published inside the profile window, by the profile's own publisher key.
        var published: [String: Int] = [:]
        var publishedIDs = Set<String>()
        var oldest = now
        for article in inputs.allArticles
        where article.orderDate >= profileStart && article.orderDate <= now.addingTimeInterval(300) {
            published[publisherKey(article), default: 0] += 1
            publishedIDs.insert(article.id)
            oldest = min(oldest, article.orderDate)
        }

        let histories: [(name: String, limit: Int)] = [
            ("whole", 200), ("newest-15", 15), ("newest-5", 5), ("none", 0),
        ]
        var reports: [YourBeatVariantReport] = []
        for history in histories {
            let profile = try await inputs.database.todayUserProfile(now: now, interactionLimit: history.limit)
            let rows = try await inputs.database.todayReadingHistoryRows(since: profileStart, limit: history.limit)
            // Stories read or saved per publisher: a count, where the profile's weight gives a saved story three.
            let storiesRead = tally(rows.map { TodayUserProfile.publisherKey(source: $0[1], link: $0[2]) })
            let engaged = profile.publisherWeights.filter { $0.value >= 2.0 }
            // The per-story numerator counts only stories of the publication window, so a read of an older story
            // cannot lift a publisher that published nothing in it.
            var windowWeights: [String: Double] = [:]
            for row in rows {
                guard let id = row[0], publishedIDs.contains(id) else { continue }
                windowWeights[TodayUserProfile.publisherKey(source: row[1], link: row[2]), default: 0] +=
                    row[5] == "1" ? 3 : 1
            }
            let shippedAffinity = profile.topQuartilePublishers
            func withMinimum(_ stories: Int) -> Set<String> {
                shippedAffinity.filter { storiesRead[$0, default: 0] >= stories }
            }
            let rules: [(name: String, affinity: Set<String>, interestMinimum: Double)] = [
                ("current", shippedAffinity, 0),
                ("booster-0.20", shippedAffinity, 0.20),
                ("booster-0.30", shippedAffinity, 0.30),
                ("booster-0.40", shippedAffinity, 0.40),
                (
                    "per-story-published",
                    topQuartile(engaged) { key, _ in
                        windowWeights[key, default: 0] / Double(max(1, published[key, default: 0]))
                    }, 0
                ),
                ("minimum-3-stories", withMinimum(3), 0),
                ("minimum-5-stories", withMinimum(5), 0),
                ("minimum-10-stories", withMinimum(10), 0),
                ("no-affinity", [], 0),
            ]
            for rule in rules {
                var context = inputs.context
                context.profile = profile
                context.profile.topQuartilePublishers = rule.affinity
                context.thresholds.yourBeatAffinityInterestMinimum = rule.interestMinimum
                reports.append(
                    autoreleasepool {
                        yourBeatReport(
                            rule: rule.name, history: history.name, interactions: rows.count,
                            engagedPublishers: engaged.count, inputs: inputs, context: context)
                    })
            }
        }
        return (reports, now.timeIntervalSince(oldest) / 86400)
    }

    private static func yourBeatReport(
        rule: String, history: String, interactions: Int, engagedPublishers: Int,
        inputs: ComparisonInputs, context: TodayAssignmentContext
    ) -> YourBeatVariantReport {
        let plan = TodayEditionAssigner.assign(entries: inputs.entries, context: context)
        let plan24h = TodayEditionAssigner.assign(entries: inputs.entries24h, context: context)
        let qualifying = evaluatedCandidates(of: plan24h, context: context).compactMap {
            TodayEditionAssigner.yourBeatPlacement($0, thresholds: context.thresholds)
        }
        let qualifyingShares = concentration(qualifying.map { publisherKey($0.story.entry.representative) })
        let shown = plan.entries(for: .yourBeat)
        let shownShares = concentration(shown.map { publisherKey($0.entry.representative) })
        let storyLabels = inputs.labels?.stories ?? [:]
        let shownExpectedLanes = shown.compactMap { storyLabels[$0.id]?.expectedLane }
        let outsideClearing = evaluatedCandidates(of: plan, context: context).filter {
            TodayEditionAssigner.outsidePlacement($0, context: context) != nil
        }.count

        let volume = tally(plan24h.allAssignments.map { publisherKey($0.entry.representative) })
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        let affinity = context.profile.topQuartilePublishers
        func notInShipped(_ lane: TodayLane) -> Int {
            Set(plan.entries(for: lane).map(\.id)).subtracting(inputs.shippedPlan.entries(for: lane).map(\.id)).count
        }
        return YourBeatVariantReport(
            rule: rule,
            history: history,
            interactions: interactions,
            engagedPublishers: engagedPublishers,
            affinityPublishers: affinity.count,
            affinityPublisherVolumeRanks: affinity.compactMap { volume.firstIndex(of: $0).map { $0 + 1 } }.sorted(),
            candidates24h: plan24h.allAssignments.count,
            qualifying24h: qualifying.count,
            qualifying24hByReason: tally(qualifying.map(\.reason)),
            qualifying24hTopPublisherShare: qualifyingShares.top,
            qualifying24hTopThreeShare: qualifyingShares.topThree,
            shown24h: plan24h.entries(for: .yourBeat).count,
            shown: shown.count,
            shows: !shown.isEmpty,
            shownTopPublisherShare: shownShares.top,
            shownTopThreeShare: shownShares.topThree,
            shownLabelled: shownExpectedLanes.count,
            shownLabelledAsExpected: shownExpectedLanes.filter { $0 == TodayLane.yourBeat.rawValue }.count,
            lanePurityOverall: lanePurity(of: plan, labels: storyLabels).overall,
            outsideClearingBar: outsideClearing,
            outsideShown: plan.entries(for: .outsideYourUsual).count,
            outsideShows: plan.result(for: .outsideYourUsual)?.qualifies == true,
            shownNotInShipped: notInShipped(.yourBeat),
            outsideNotInShipped: notInShipped(.outsideYourUsual),
            laneCounts: laneCounts(plan)
        )
    }
}
