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
import SQLite3

/// Shadow evaluation runner (`--today-shadow COPY.sqlite3 OUTPUT_DIR`) for Z2 (`#934`).
/// Runs on a temporary copy of a real library, writes aggregate metrics to `shadow-report.json`, and
/// keeps any headline/title spot-check sheets strictly in private temporary files outside the repository.
/// `NEWS_TODAY_NOW` pins the clock (epoch seconds), `NEWS_TODAY_WINDOW_HOURS` the candidate window,
/// `NEWS_TODAY_LABELS` names the private label file and `NEWS_TODAY_FEEDS` the snapshot's subscription list.
enum TodayShadowEvaluation {
    /// Z5 (#937): what the Today page costs to lay out. The list shows 200 stories a page, so the newest 200 of the
    /// window are loaded and assigned three times and the medians printed, with no story text.
    static func timeFirstPage(
        of articles: [FeedArticle], summaries: [EventFeedSummary], database: DatabaseEngine, now: Date,
        feeds: Set<String>
    ) async throws {
        let page = Array(articles.sorted { $0.orderDate > $1.orderDate }.prefix(200))
        let entries = EventFeedGrouping.entries(for: page, events: summaries, mode: .events)
        var loader: [Double] = []
        var assign: [Double] = []
        var combined: [Double] = []
        for _ in 0..<3 {
            let loadStart = CFAbsoluteTimeGetCurrent()
            let context = try await database.loadTodayAssignmentContext(
                entries: entries, now: now, subscribedFeedURLs: feeds)
            loader.append((CFAbsoluteTimeGetCurrent() - loadStart) * 1000)
            let assignStart = CFAbsoluteTimeGetCurrent()
            _ = TodayEditionAssigner.assign(entries: entries, context: context)
            let end = CFAbsoluteTimeGetCurrent()
            assign.append((end - assignStart) * 1000)
            combined.append((end - loadStart) * 1000)
        }
        print(
            String(
                format:
                    "TODAY_PAGE_TIMING stories=%d entries=%d loaderMedianMs=%.1f assignMedianMs=%.1f combinedMedianMs=%.1f",
                page.count, entries.count, loader.sorted()[1], assign.sorted()[1], combined.sorted()[1]))
    }

    struct StoryLabels: Decodable {
        var stories: [String: StoryLabel]?
        var events: [String: String]?  // "initial_report", "new_information", "repetition"
    }

    struct StoryLabel: Decodable {
        var leadImportant: Bool?
        var expectedLane: String?
    }

    struct ShadowReport: Encodable {
        let nowTimestamp: Double
        let candidateWindowHours: Double
        /// `NEWS_TODAY_FEEDS` when the run was given the subscription list, else `feeds-table`.
        let subscriptionSource: String
        let subscribedFeedCount: Int
        let loaderDurationMs: Double
        let assignDurationMs: Double
        let candidatesTotal: Int
        let candidates24h: Int
        let latestCompleteness: Double
        let duplicateRate: Double
        let yourBeatPerDay24h: Int
        let yourBeatRawQualifying24h: Int
        let laneCounts: [String: Int]
        let laneRawQualifyingCounts: [String: Int]
        let laneShares: [String: Double]
        let laneQualifies: [String: Bool]
        let leadUniquePublishers: Int
        let leadMaxShareByOnePublisher: Double
        let conditionalUniquePublishers: Int
        let conditionalSimpsonDiversity: Double
        let deepReadQualifyingLengthCount: Int
        let deepReadQualifyingClassificationCount: Int
        let deepReadBreakdown: [String: Int]
        let deepReadMissingFullContentCount: Int
        let deepReadStoredFullContentCount: Int
        let deepReadStoredLongShown: Int
        let deepReadStoredLongDropped: Int
        let deepReadSummaryOnlyExcluded: Int
        let coverageMultiPublisherEvents: Int
        let coveragePassingGate: Int
        let threeRankingComparison: ThreeRankingReport
        let labelledEvaluation: LabelledEvaluationReport?
    }

    struct ThreeRankingReport: Encodable {
        let sampleSize: Int
        let publisherCountTop5IDs: [String]
        let briefingSignalsTop5IDs: [String]
        let z2CombinedTop5IDs: [String]
        let publisherCountTop5MeanOriginals: Double
        let briefingSignalsTop5MeanOriginals: Double
        let z2CombinedTop5MeanOriginals: Double
        let publisherCountTop5WireOnlyCount: Int
        let briefingSignalsTop5WireOnlyCount: Int
        let z2CombinedTop5WireOnlyCount: Int
        let rankOverlapPublisherVsZ2Top5: Int
        let rankOverlapBriefingVsZ2Top5: Int
    }

    struct LabelledEvaluationReport: Encodable {
        let labelledStoriesCount: Int
        let leadPrecisionAt5PublisherCount: Double?
        let leadPrecisionAt5BriefingSignals: Double?
        let leadPrecisionAt5Z2Combined: Double?
        let lanePurityOverall: Double?
        let lanePurityByLane: [String: Double]
        let inMotionReviewedCount: Int
        let inMotionTruePositivesNewInfo: Int
        let inMotionFalsePositivesInitial: Int
        let inMotionFalsePositivesRepetition: Int
        let inMotionFalseNegativesNewInfo: Int
    }

    struct PrivateStoryRow: Encodable {
        let id: String
        let title: String
        let description: String
        let publisher: String
        let lane: String
        let score: Double
        let confidence: Double
        let reason: String
        let publisherCount: Int
        let originalReportCount: Int
        let groupingConfidence: Double
        let readingTimeMinutes: Double
        let hasFullContent: Bool
        let contentTypeLabel: String?
        let interestMatch: Double
        let novelty: Double
        let isCoverageConfident: Bool
        let isDeveloping: Bool
        let rankingPublisherCountPosition: Int
        let rankingBriefingPosition: Int
        let rankingZ2Position: Int
    }

    struct PrivateInMotionRow: Encodable {
        let eventID: String
        let representativeID: String
        let title: String
        let publisherCount: Int
        let originalReportCount: Int
        let knownBefore24hCount: Int
        let inside24hCount: Int
        let knownBeforeTitles: [String]
        let insideTitles: [String]
        let momentum: String
        let clockHeadlineNovel: Bool
        let inMotionPlaced: Bool
    }

    static func run(path: String, output: String) async throws {
        let sourceURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let outURL = URL(fileURLWithPath: output).resolvingSymlinksInPath()
        guard sourceURL.path.hasPrefix("/private/tmp/") || sourceURL.path.hasPrefix("/tmp/"),
            outURL.path.hasPrefix("/private/tmp/") || outURL.path.hasPrefix("/tmp/"),
            !sourceURL.path.contains("/Library/Containers/")
        else {
            throw NSError(
                domain: "TodayShadowEvaluation", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Use a copied library and output directory under /private/tmp"
                ]
            )
        }

        // The sheets hold titles and profile-derived scores: the output directory is the user's alone, created
        // 0700 when absent and checked before the run, and each file is written 0600.
        try FileManager.default.createDirectory(
            at: outURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let outputDirectory = try StoryCorpus.privateDirectory(outURL.path)

        // Snapshot to a scratch database so migrations (e.g. from older v27/v29 snapshots) never alter source.
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("today-shadow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratchDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let scratchDB = scratchDir.appendingPathComponent("library.sqlite3")
        try snapshot(of: sourceURL, to: scratchDB)

        let db = DatabaseEngine(path: scratchDB.path)
        try await db.open()
        let currentVersion = try await db.schemaUserVersion()
        if currentVersion < DatabaseEngine.schemaVersion {
            let coordinator = MigrationCoordinator(database: db)
            _ = try await coordinator.migrateIfNeeded()
        }

        // Clock: NEWS_TODAY_NOW or the latest visible article order date in the snapshot.
        let env = ProcessInfo.processInfo.environment
        let allArticles = try await db.fetchArticles(
            limit: nil, options: ArticleFetchOptions(hidingWaitingStories: false))
        let latestDate = allArticles.map(\.orderDate).filter { $0 != DateParser.unknownDate }.max() ?? Date()
        let now = env["NEWS_TODAY_NOW"].flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) } ?? latestDate

        let windowHours = env["NEWS_TODAY_WINDOW_HOURS"].flatMap(Double.init) ?? 72.0
        let windowStart = now.addingTimeInterval(-windowHours * 3600)
        let windowArticles = allArticles.filter {
            $0.orderDate >= windowStart && $0.orderDate <= now.addingTimeInterval(300)
        }
        let summaries = try await db.eventFeedSummaries(forArticles: windowArticles.map(\.id))
        let entries = EventFeedGrouping.entries(for: windowArticles, events: summaries, mode: .events)

        let subscriptions = try await subscribedFeeds(env, database: db)
        let loaderStart = CFAbsoluteTimeGetCurrent()
        let context = try await db.loadTodayAssignmentContext(
            entries: entries, now: now, subscribedFeedURLs: subscriptions.urls)
        let loaderDurationMs = (CFAbsoluteTimeGetCurrent() - loaderStart) * 1000.0

        let assignStart = CFAbsoluteTimeGetCurrent()
        let plan = TodayEditionAssigner.assign(entries: entries, context: context)
        let assignDurationMs = (CFAbsoluteTimeGetCurrent() - assignStart) * 1000.0
        try await timeFirstPage(
            of: windowArticles, summaries: summaries, database: db, now: now, feeds: subscriptions.urls)
        let summaryByEventID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.eventID, $0) })

        let rawQualifyingCounts = computeRawQualifyingCounts(entries: entries, context: context)

        // Verify Latest completeness & 0% duplicate rate across lanes.
        let eligibleBySub = entries.filter { entry in
            guard let subscribed = context.subscribedFeedURLs else { return true }
            let keys = Set(subscribed.map(AppSettings.feedKey))
            let urls = Set(entry.visibleArticles.compactMap(\.identityFeedURL))
                .union(context.signalsByEntryID[entry.id]?.feedURLs ?? [])
            return urls.contains { subscribed.contains($0) || keys.contains(AppSettings.feedKey($0)) }
        }
        let eligibleIDs = Set(eligibleBySub.map(\.id))
        let assignedList = plan.allAssignments
        let assignedIDs = Set(assignedList.map(\.id))
        let completeness =
            eligibleIDs.isEmpty ? 1.0 : Double(assignedIDs.intersection(eligibleIDs).count) / Double(eligibleIDs.count)
        let duplicateCount = assignedList.count - assignedIDs.count
        let duplicateRate = assignedList.isEmpty ? 0.0 : Double(duplicateCount) / Double(assignedList.count)

        // Your Beat daily count (last 24 h).
        let cutoff24h = now.addingTimeInterval(-24 * 3600)
        let entries24h = entries.filter { $0.representative.orderDate >= cutoff24h }
        let context24h = try await db.loadTodayAssignmentContext(
            entries: entries24h, now: now, subscribedFeedURLs: subscriptions.urls)
        let plan24h = TodayEditionAssigner.assign(entries: entries24h, context: context24h)
        let yourBeat24h = plan24h.entries(for: .yourBeat).count
        let yourBeatRaw24h =
            computeRawQualifyingCounts(entries: entries24h, context: context24h)[TodayLane.yourBeat.rawValue] ?? 0

        // Lane distribution.
        var laneCounts: [String: Int] = [:]
        var laneShares: [String: Double] = [:]
        var laneQualifies: [String: Bool] = [:]
        let totalAssigned = max(1, assignedList.count)
        for result in plan.lanes {
            laneCounts[result.lane.rawValue] = result.entries.count
            laneShares[result.lane.rawValue] = Double(result.entries.count) / Double(totalAssigned)
            laneQualifies[result.lane.rawValue] = result.qualifies
        }

        // Publisher diversity.
        let leadEntries = plan.entries(for: .theLead)
        let leadPubs = leadEntries.map { $0.entry.representative.publisherName }
        let leadPubFreq = Dictionary(leadPubs.map { ($0, 1) }, uniquingKeysWith: +)
        let leadUniquePubs = leadPubFreq.count
        let leadMaxShare = leadEntries.isEmpty ? 0.0 : Double(leadPubFreq.values.max() ?? 0) / Double(leadEntries.count)

        let conditionalEntries = [TodayLane.inMotion, .theDeepRead, .yourBeat, .outsideYourUsual]
            .flatMap { plan.entries(for: $0) }
        let condPubs = conditionalEntries.map { $0.entry.representative.publisherName }
        let condFreq = Dictionary(condPubs.map { ($0, 1) }, uniquingKeysWith: +)
        let condTotal = max(1, conditionalEntries.count)
        let condSimpson =
            conditionalEntries.isEmpty
            ? 0.0
            : 1.0 - condFreq.values.reduce(0.0) { $0 + pow(Double($1) / Double(condTotal), 2.0) }

        // Deep Read breakdown & unfetched-body measurement across candidate pool.
        let deepReadEntries = plan.entries(for: .theDeepRead)
        var deepByType: [String: Int] = [:]
        var deepLengthOnly = 0
        var deepClassified = 0
        for item in deepReadEntries {
            if let label = item.contentTypeLabel {
                deepClassified += 1
                deepByType[label.rawValue, default: 0] += 1
            } else {
                deepLengthOnly += 1
            }
        }
        let storedFullCount = assignedList.filter { item in
            let storedLen = item.entry.visibleArticles.contains { ($0.fullContent?.isEmpty == false) }
            return storedLen
                || (context.signalsByEntryID[item.id]?.memberFullTexts.contains { $0.count > 1200 } == true)
        }.count
        let missingFullCount = max(0, assignedList.count - storedFullCount)
        // #1194: stored long reads the lane shows, and those its cap drops to a later lane.
        let minimumMinutes = context.thresholds.deepReadMinimumMinutes
        let storedLongShown = deepReadEntries.filter { $0.readingTimeMinutes >= minimumMinutes }.count
        let storedLongDropped = assignedList.filter {
            $0.readingTimeMinutes >= minimumMinutes && ![.theLead, .inMotion, .theDeepRead].contains($0.lane)
        }.count
        // Short stories that only their feed summary would have classified.
        let summaryOnlyExcluded = assignedList.filter { item in
            let rep = item.entry.representative
            let minimum = context.thresholds.deepReadClassificationMinimumConfidence
            let withSummary = TodayEditionAssigner.classifyContentType(
                title: rep.title, description: rep.description, category: rep.category, link: rep.link)
            let used = TodayEditionAssigner.deepReadContentType(
                of: rep, readingTimeMinutes: item.readingTimeMinutes, thresholds: context.thresholds)
            return (withSummary?.confidence ?? 0) >= minimum && (used?.confidence ?? 0) < minimum
        }.count

        // Coverage card gate breakdown.
        let multiPubEvents = assignedList.filter { $0.publisherCount >= 3 }
        let passingCoverage = multiPubEvents.filter(\.isCoverageConfident)

        // Three-ranking comparison on top 100-200 most recent stories (ordered by recency first, capped at 200).
        let comparisonPool = Array(
            assignedList.sorted {
                $0.entry.representative.orderDate == $1.entry.representative.orderDate
                    ? $0.id < $1.id
                    : $0.entry.representative.orderDate > $1.entry.representative.orderDate
            }.prefix(200)
        )
        let comparisonRawEntries = comparisonPool.map(\.entry)

        let briefingRanking = await BriefingRanking.load(entries: comparisonRawEntries, database: db)
        let byPublisherCount = comparisonPool.sorted {
            if $0.publisherCount != $1.publisherCount { return $0.publisherCount > $1.publisherCount }
            return $0.sortKey > $1.sortKey
        }
        let briefingOrderIDs = briefingRanking.order(comparisonRawEntries).map(\.id)
        let assignmentByID = Dictionary(uniqueKeysWithValues: comparisonPool.map { ($0.id, $0) })
        let byBriefingSignals = briefingOrderIDs.compactMap { assignmentByID[$0] }
        let byZ2Combined = comparisonPool.sorted { a, b in
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            if a.originalReportCount != b.originalReportCount { return a.originalReportCount > b.originalReportCount }
            return a.sortKey > b.sortKey
        }

        func top5Metrics(_ ranked: [TodayStoryAssignment]) -> (ids: [String], meanOriginals: Double, wireOnly: Int) {
            let top5 = Array(ranked.prefix(5))
            let ids = top5.map(\.id)
            let meanOrig =
                top5.isEmpty ? 0.0 : Double(top5.reduce(0) { $0 + $1.originalReportCount }) / Double(top5.count)
            let wireOnly = top5.filter { $0.publisherCount >= 2 && $0.originalReportCount <= 1 }.count
            return (ids, meanOrig, wireOnly)
        }
        let mPub = top5Metrics(byPublisherCount)
        let mBriefing = top5Metrics(byBriefingSignals)
        let mZ2 = top5Metrics(byZ2Combined)

        let threeComparison = ThreeRankingReport(
            sampleSize: comparisonPool.count,
            publisherCountTop5IDs: mPub.ids,
            briefingSignalsTop5IDs: mBriefing.ids,
            z2CombinedTop5IDs: mZ2.ids,
            publisherCountTop5MeanOriginals: mPub.meanOriginals,
            briefingSignalsTop5MeanOriginals: mBriefing.meanOriginals,
            z2CombinedTop5MeanOriginals: mZ2.meanOriginals,
            publisherCountTop5WireOnlyCount: mPub.wireOnly,
            briefingSignalsTop5WireOnlyCount: mBriefing.wireOnly,
            z2CombinedTop5WireOnlyCount: mZ2.wireOnly,
            rankOverlapPublisherVsZ2Top5: Set(mPub.ids).intersection(Set(mZ2.ids)).count,
            rankOverlapBriefingVsZ2Top5: Set(mBriefing.ids).intersection(Set(mZ2.ids)).count
        )

        // Optional labelled evaluation if NEWS_TODAY_LABELS is provided.
        var labelledReport: LabelledEvaluationReport?
        if let labelsPath = env["NEWS_TODAY_LABELS"], FileManager.default.fileExists(atPath: labelsPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: labelsPath))
            let labels = try JSONDecoder().decode(StoryLabels.self, from: data)
            labelledReport = evaluateLabels(
                labels: labels,
                byPub: byPublisherCount,
                byBriefing: byBriefingSignals,
                byZ2: byZ2Combined,
                plan: plan,
                summariesByEventID: summaryByEventID,
                now: now
            )
        }

        let report = ShadowReport(
            nowTimestamp: now.timeIntervalSince1970,
            candidateWindowHours: windowHours,
            subscriptionSource: subscriptions.source,
            subscribedFeedCount: subscriptions.urls.count,
            loaderDurationMs: loaderDurationMs,
            assignDurationMs: assignDurationMs,
            candidatesTotal: eligibleBySub.count,
            candidates24h: entries24h.count,
            latestCompleteness: completeness,
            duplicateRate: duplicateRate,
            yourBeatPerDay24h: yourBeat24h,
            yourBeatRawQualifying24h: yourBeatRaw24h,
            laneCounts: laneCounts,
            laneRawQualifyingCounts: rawQualifyingCounts,
            laneShares: laneShares,
            laneQualifies: laneQualifies,
            leadUniquePublishers: leadUniquePubs,
            leadMaxShareByOnePublisher: leadMaxShare,
            conditionalUniquePublishers: condFreq.count,
            conditionalSimpsonDiversity: condSimpson,
            deepReadQualifyingLengthCount: deepLengthOnly,
            deepReadQualifyingClassificationCount: deepClassified,
            deepReadBreakdown: deepByType,
            deepReadMissingFullContentCount: missingFullCount,
            deepReadStoredFullContentCount: storedFullCount,
            deepReadStoredLongShown: storedLongShown,
            deepReadStoredLongDropped: storedLongDropped,
            deepReadSummaryOnlyExcluded: summaryOnlyExcluded,
            coverageMultiPublisherEvents: multiPubEvents.count,
            coveragePassingGate: passingCoverage.count,
            threeRankingComparison: threeComparison,
            labelledEvaluation: labelledReport
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Write aggregate-only report.
        try StoryCorpus.writePrivate(
            try encoder.encode(report), to: outputDirectory.appendingPathComponent("shadow-report.json"),
            replacing: true)

        // Write private spot-check sheets strictly in the /private/tmp output directory.
        let posPub = Dictionary(
            uniqueKeysWithValues: byPublisherCount.enumerated().map { ($0.element.id, $0.offset + 1) })
        let posBrief = Dictionary(
            uniqueKeysWithValues: byBriefingSignals.enumerated().map { ($0.element.id, $0.offset + 1) })
        let posZ2 = Dictionary(uniqueKeysWithValues: byZ2Combined.enumerated().map { ($0.element.id, $0.offset + 1) })

        let privateCandidates = comparisonPool.map { item -> PrivateStoryRow in
            let rep = item.entry.representative
            let hasBody = item.entry.visibleArticles.contains { ($0.fullContent?.isEmpty == false) }
            return PrivateStoryRow(
                id: item.id,
                title: rep.title,
                description: String(rep.description.prefix(240)),
                publisher: rep.publisherName,
                lane: item.lane.rawValue,
                score: item.score,
                confidence: item.confidence,
                reason: item.reason,
                publisherCount: item.publisherCount,
                originalReportCount: item.originalReportCount,
                groupingConfidence: item.groupingConfidence,
                readingTimeMinutes: item.readingTimeMinutes,
                hasFullContent: hasBody,
                contentTypeLabel: item.contentTypeLabel?.rawValue,
                interestMatch: item.interestMatch,
                novelty: item.novelty,
                isCoverageConfident: item.isCoverageConfident,
                isDeveloping: item.isDeveloping,
                rankingPublisherCountPosition: posPub[item.id] ?? 0,
                rankingBriefingPosition: posBrief[item.id] ?? 0,
                rankingZ2Position: posZ2[item.id] ?? 0
            )
        }
        try StoryCorpus.writePrivate(
            try encoder.encode(privateCandidates),
            to: outputDirectory.appendingPathComponent("shadow-candidates-private.json"), replacing: true)

        // Collect 30-50 confirmed events for In Motion evaluation (rising or split across 24h boundary first).
        let inMotionAssignedIDs = Set(plan.entries(for: .inMotion).map(\.id))
        let eventItems = assignedList.compactMap { item -> PrivateInMotionRow? in
            guard case .event(let summary, let rep, _) = item.entry else { return nil }
            let cutoff24 = now.addingTimeInterval(-24 * 3600)
            let before = summary.members.filter { $0.date < cutoff24 }
            let inside = summary.members.filter { $0.date >= cutoff24 && $0.date <= now.addingTimeInterval(300) }
            let mom = BriefingPriorityData.momentum(dates: summary.members.map(\.date), now: now)
            let clockNovel = TodayEditionAssigner.hasSubstantiveInMotionUpdate(summary, now: now)
            return PrivateInMotionRow(
                eventID: summary.eventID,
                representativeID: rep.id,
                title: rep.title,
                publisherCount: item.publisherCount,
                originalReportCount: item.originalReportCount,
                knownBefore24hCount: before.count,
                inside24hCount: inside.count,
                knownBeforeTitles: Array(Set(before.map(\.title))).sorted(),
                insideTitles: Array(Set(inside.map(\.title))).sorted(),
                momentum: mom == .rising ? "rising" : (mom == .fading ? "fading" : "steady"),
                clockHeadlineNovel: clockNovel,
                inMotionPlaced: inMotionAssignedIDs.contains(item.id)
            )
        }
        .sorted { a, b in
            let aBoundary = (a.knownBefore24hCount > 0 && a.inside24hCount > 0) ? 1 : 0
            let bBoundary = (b.knownBefore24hCount > 0 && b.inside24hCount > 0) ? 1 : 0
            if aBoundary != bBoundary { return aBoundary > bBoundary }
            return a.publisherCount > b.publisherCount
        }
        try StoryCorpus.writePrivate(
            try encoder.encode(Array(eventItems.prefix(50))),
            to: outputDirectory.appendingPathComponent("in-motion-candidates-private.json"), replacing: true)

        print("TODAY_SHADOW_REPORT \(String(decoding: try encoder.encode(report), as: UTF8.self))")
        await db.close()
    }

    /// A consistent snapshot of the copied library, its `-wal` included, taken through a read-only connection as
    /// `measureLiveOverviews` takes its own, so the copy is never written.
    private static func snapshot(of source: URL, to destination: URL) throws {
        // Apple's sqlite3 cannot open a WAL-mode file read-only once its `-wal` and `-shm` are gone, as after a
        // plain copy of the main file. With no `-wal` and no `-journal` beside it the file is complete on its
        // own, so it is read as immutable.
        let hasJournal = ["-wal", "-journal"].contains { FileManager.default.fileExists(atPath: source.path + $0) }
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [
            source.absoluteString + (hasJournal ? "?mode=ro" : "?immutable=1"),
            "VACUUM INTO '\(destination.path.replacingOccurrences(of: "'", with: "''"))';",
        ]
        let errors = Pipe()
        sqlite.standardError = errors
        try sqlite.run()
        sqlite.waitUntilExit()
        guard sqlite.terminationStatus == 0, FileManager.default.fileExists(atPath: destination.path) else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "TodayShadowEvaluation", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not snapshot the library copy: \(message)"])
        }
    }

    /// The snapshot's subscriptions. A library holds no subscription list (it lives in the app's settings), so
    /// `NEWS_TODAY_FEEDS` names a file with one feed URL per line; an empty file is an empty list and admits no
    /// story. Without it the run falls back to every feed the library has fetched, which still counts the
    /// stories of a feed removed since.
    private static func subscribedFeeds(
        _ environment: [String: String], database: DatabaseEngine
    ) async throws -> (urls: Set<String>, source: String) {
        guard let path = environment["NEWS_TODAY_FEEDS"] else {
            let fetched = try await database.fetchedFeedURLs()
            print("TODAY_SHADOW_NOTE NEWS_TODAY_FEEDS is not set: the \(fetched.count) fetched feeds stand in for it")
            return (fetched, "feeds-table")
        }
        let listed = try String(contentsOfFile: path, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (Set(listed), "NEWS_TODAY_FEEDS")
    }

    private static func computeRawQualifyingCounts(
        entries: [FeedEntry],
        context: TodayAssignmentContext
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        // Check each story independently via 1-item/solo checks or checking each conditional lane without caps.
        let plan = TodayEditionAssigner.assign(entries: entries, context: context)
        let deepReadQualCount = plan.allAssignments.filter { item in
            let byType =
                TodayEditionAssigner.deepReadContentType(
                    of: item.entry.representative,
                    readingTimeMinutes: item.readingTimeMinutes,
                    thresholds: context.thresholds
                ).map { $0.confidence >= context.thresholds.deepReadClassificationMinimumConfidence } ?? false
            return item.readingTimeMinutes >= context.thresholds.deepReadMinimumMinutes || byType
        }.count
        let yourBeatQualCount = plan.allAssignments.filter { item in
            let isStarred =
                item.reason == "your_beat_starred"
                || Set(item.entry.visibleArticles.compactMap(\.identityFeedURL))
                    .union(context.signalsByEntryID[item.id]?.feedURLs ?? [])
                    .contains { raw in
                        let key = AppSettings.feedKey(raw)
                        return context.starredFeedURLs.contains(raw)
                            || context.starredFeedURLs.contains(where: { AppSettings.feedKey($0) == key })
                    }
            let isTopQuartile = context.profile.isTopQuartilePublisher(item.entry.representative.publisherName)
            return item.interestMatch >= context.thresholds.yourBeatInterestMatchMinimum || isStarred || isTopQuartile
        }.count
        let inMotionQualCount = plan.allAssignments.filter { item in
            guard case .event(let summary, _, _) = item.entry else { return false }
            let mom = BriefingPriorityData.momentum(dates: summary.members.map(\.date), now: context.now)
            return mom == .rising
                && TodayEditionAssigner.hasSubstantiveInMotionUpdate(
                    summary, now: context.now, window: context.thresholds.inMotionWindowSeconds)
        }.count
        let outsideQualCount = plan.allAssignments.filter { item in
            context.profile.hasHistory
                && item.novelty >= context.thresholds.outsideNoveltyMinimum
                && item.score >= context.thresholds.outsideScoreMinimum
        }.count
        counts[TodayLane.inMotion.rawValue] = inMotionQualCount
        counts[TodayLane.theDeepRead.rawValue] = deepReadQualCount
        counts[TodayLane.yourBeat.rawValue] = yourBeatQualCount
        counts[TodayLane.outsideYourUsual.rawValue] = outsideQualCount
        return counts
    }

    private static func evaluateLabels(
        labels: StoryLabels,
        byPub: [TodayStoryAssignment],
        byBriefing: [TodayStoryAssignment],
        byZ2: [TodayStoryAssignment],
        plan: TodayEditionPlan,
        summariesByEventID: [String: EventFeedSummary],
        now: Date
    ) -> LabelledEvaluationReport {
        let storyLabels = labels.stories ?? [:]
        func precisionAt5(_ ranked: [TodayStoryAssignment]) -> Double? {
            let labelledTop = ranked.prefix(5).compactMap { storyLabels[$0.id]?.leadImportant }
            guard !labelledTop.isEmpty else { return nil }
            let hits = labelledTop.filter { $0 }.count
            return Double(hits) / Double(labelledTop.count)
        }

        var purityHits = 0
        var purityTotal = 0
        var perLaneHits: [String: Int] = [:]
        var perLaneTotal: [String: Int] = [:]
        for item in plan.allAssignments {
            if let expected = storyLabels[item.id]?.expectedLane {
                purityTotal += 1
                perLaneTotal[item.lane.rawValue, default: 0] += 1
                if expected == item.lane.rawValue {
                    purityHits += 1
                    perLaneHits[item.lane.rawValue, default: 0] += 1
                }
            }
        }
        var lanePurityMap: [String: Double] = [:]
        for (lane, total) in perLaneTotal {
            lanePurityMap[lane] = Double(perLaneHits[lane, default: 0]) / Double(max(1, total))
        }

        let eventLabels = labels.events ?? [:]
        var tpNew = 0
        var fpInitial = 0
        var fpRep = 0
        var fnNew = 0
        for (eventID, label) in eventLabels {
            guard let summary = summariesByEventID[eventID] else { continue }
            let predicted =
                TodayEditionAssigner.hasSubstantiveInMotionUpdate(summary, now: now)
                && BriefingPriorityData.momentum(dates: summary.members.map(\.date), now: now) == .rising
            switch label {
            case "new_information":
                if predicted { tpNew += 1 } else { fnNew += 1 }
            case "initial_report":
                if predicted { fpInitial += 1 }
            case "repetition":
                if predicted { fpRep += 1 }
            default:
                break
            }
        }

        return LabelledEvaluationReport(
            labelledStoriesCount: storyLabels.count,
            leadPrecisionAt5PublisherCount: precisionAt5(byPub),
            leadPrecisionAt5BriefingSignals: precisionAt5(byBriefing),
            leadPrecisionAt5Z2Combined: precisionAt5(byZ2),
            lanePurityOverall: purityTotal > 0 ? Double(purityHits) / Double(purityTotal) : nil,
            lanePurityByLane: lanePurityMap,
            inMotionReviewedCount: eventLabels.count,
            inMotionTruePositivesNewInfo: tpNew,
            inMotionFalsePositivesInitial: fpInitial,
            inMotionFalsePositivesRepetition: fpRep,
            inMotionFalseNegativesNewInfo: fnNew
        )
    }
}

extension DatabaseEngine {
    fileprivate func schemaUserVersion() throws -> Int {
        let rows = try eventRows("PRAGMA user_version;")
        return rows.first?.first.flatMap { $0 }.flatMap(Int.init) ?? 0
    }

    /// Every feed the library has fetched: fetch state, not the subscription list, since a removed feed keeps
    /// its row.
    fileprivate func fetchedFeedURLs() throws -> Set<String> {
        Set(try eventRows("SELECT url FROM feeds;").compactMap { $0[0] }.filter { !$0.isEmpty })
    }
}
