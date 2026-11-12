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
import SQLite3

/// Timeline audit for #1241 (`--timeline-audit COPY.sqlite3 OUTPUT_DIR`), on a copy of a real library with grouping
/// as stored. Three arms per multi-publisher event in the window, all composed from the same selected passages:
/// `main` (the stated-date builder when it has items, else the removed extractor), `branch` (the current composer)
/// and `diagnostic` (the builder fed every passage sentence; never shipped). Writes one JSON line per event with a
/// timeline in any arm, and Briefing threads built with the real `merged` over `storyEventIDs`, on stored rows and
/// on regenerated rows. Output holds measures, date texts, kinds, reason codes and event-id prefixes only, never a
/// publisher sentence. `NEWS_TIMELINE_AUDIT_NOW` pins the clock (epoch seconds), `NEWS_TIMELINE_AUDIT_HOURS` the
/// window (default 336).
enum TimelineAudit {
    private struct Row: Encodable {
        let date: String
        let kind: String
    }

    private struct EventLine: Encodable {
        let event: String
        let stored: Bool
        let storedVersion: Int?
        let mainSource: String
        let main: [Row]
        let branch: [Row]
        let diagnostic: [Row]
        /// One reason per main row that the branch does not show.
        let dropped: [String]
        /// Main rows whose extractor date has a year below 100 (a yearless date parsed with the day as the year).
        let mainYearMisparse: Int
    }

    private struct ThreadLine: Encodable {
        let story: String
        let arm: String
        let rows: [String]
        let day: Int?
        let beforeFirstReport: Int
        let monthPrecision: Int
        let misparsedYear: Int
    }

    private struct Thread {
        struct Row {
            let text: String
            let date: Date
        }
        let rows: [Row]
        let day: Int?
    }

    private typealias Stored = [String: (version: Int, items: [OverviewTimelineItem])]

    static func run(path: String, output: String) async throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(
                domain: "TimelineAudit", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The copy and the output belong under /private/tmp"])
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        let now =
            environment["NEWS_TIMELINE_AUDIT_NOW"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            ?? Date()
        let hours = environment["NEWS_TIMELINE_AUDIT_HOURS"].flatMap(Double.init) ?? 336
        let raw = try rawStoredTimelines(path: url.path)

        let db = DatabaseEngine(path: url.path)
        try await db.open()
        let active = try await db.fetchArticles(
            limit: nil, options: ArticleFetchOptions(publicationWindow: now.addingTimeInterval(-hours * 3600)...now))
        let events = try await db.eventFeedSummaries(forArticles: active.map(\.id)).filter { $0.sources.count > 1 }

        var counts: [String: Int] = [:]
        var lines: [String] = []
        var threadLines: [String] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var composedMain: [String: [OverviewTimelineItem]] = [:]
        var composedBranch: [String: [OverviewTimelineItem]] = [:]
        var firstReport: [String: Date] = [:]

        func compose(_ eventID: String, version: Int) async throws {
            guard composedBranch[eventID] == nil else { return }
            composedBranch[eventID] = []
            let members = try await db.fetchArticles(limit: nil, options: ArticleFetchOptions(eventID: eventID))
            guard let first = members.first else { return }
            firstReport[eventID] = members.map(\.pubDate).filter { $0 != DateParser.unknownDate }.min()
            let passages = OverviewPassageSelector().selectPassages(from: members, budget: OverviewTokenBudget())
                .passages
            let facts = PassageFactExtractor.deterministicExtract(passages: passages)
            let branch = OverviewComposer.composeOverview(
                eventID: eventID, eventTitle: first.title, verifiedFacts: facts, passages: passages, articles: members,
                membershipVersion: version
            ).timeline
            let (main, source) = mainTimeline(facts: facts, passages: passages, articles: members)
            composedBranch[eventID] = branch
            composedMain[eventID] = main
            let diagnostic = OverviewTimelineBuilder.build(
                facts: passageSentenceFacts(passages), passages: passages, articles: members
            ).items
            guard !main.isEmpty || !branch.isEmpty || !diagnostic.isEmpty else { return }

            let branchSummaries = Set(branch.map { normalized($0.summary) })
            let dropped = main.filter { !branchSummaries.contains(normalized($0.summary)) }.map {
                reason(for: $0, source: source, facts: facts, passages: passages, articles: members, branch: branch)
            }
            for code in dropped { counts["dropped_\(code)", default: 0] += 1 }
            counts["events_main_\(source)", default: 0] += 1
            if !main.isEmpty { counts["events_with_timeline_main", default: 0] += 1 }
            if !branch.isEmpty { counts["events_with_timeline_branch", default: 0] += 1 }
            if !diagnostic.isEmpty { counts["events_with_timeline_diagnostic", default: 0] += 1 }
            if !main.isEmpty && branch.isEmpty { counts["timelines_lost", default: 0] += 1 }
            if main.isEmpty && !branch.isEmpty { counts["timelines_gained", default: 0] += 1 }
            if branch.isEmpty && !diagnostic.isEmpty { counts["timelines_diagnostic_only", default: 0] += 1 }
            counts["rows_main", default: 0] += main.count
            counts["rows_branch", default: 0] += branch.count
            counts["rows_diagnostic", default: 0] += diagnostic.count
            let line = EventLine(
                event: String(eventID.prefix(8)), stored: raw[eventID] != nil, storedVersion: raw[eventID]?.version,
                mainSource: source, main: main.map { Row(date: $0.dateText, kind: "main") },
                branch: branch.map { Row(date: $0.dateText, kind: $0.dateKind.rawValue) },
                diagnostic: diagnostic.map { Row(date: $0.dateText, kind: $0.dateKind.rawValue) }, dropped: dropped,
                mainYearMisparse: main.filter { isMisparsed($0.eventDate) }.count)
            lines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
        }

        var storiesSeen = Set<String>()
        for event in events {
            counts["events", default: 0] += 1
            try await compose(event.eventID, version: event.membershipVersion)
            let story = (try? await db.storyEventIDs(event.eventID)) ?? [event.eventID]
            guard let storyKey = story.first, storiesSeen.insert(storyKey).inserted else { continue }
            counts["stories", default: 0] += 1
            for eventID in story where eventID != event.eventID {
                try await compose(eventID, version: 1)
            }
            // A stated date is a day, so a row counts as before the first report only on an earlier day (UTC).
            let first = story.compactMap { firstReport[$0] }.min().map {
                OverviewTimelineItem.legacyCalendar.startOfDay(for: $0)
            }

            // Stored rows as they are: main read the raw stored dates; the branch decodes them with its decoder.
            var storedBranch: [(eventID: String, items: [OverviewTimelineItem])] = []
            for eventID in story {
                if let overview = try? await db.fetchEventOverview(eventID: eventID) {
                    storedBranch.append((eventID: eventID, items: overview.timeline))
                }
            }
            let regenerated = story.map { (eventID: $0, items: composedBranch[$0] ?? []) }
            let arms: [(String, Thread?)] = [
                ("stored_main", mainThread(story.flatMap { raw[$0]?.items ?? [] }, now: now)),
                ("stored_branch", branchThread(BriefingTimelineData.merged(storedBranch, now: now), now: now)),
                ("regenerated_main", mainThread(story.flatMap { composedMain[$0] ?? [] }, now: now)),
                ("regenerated_branch", branchThread(BriefingTimelineData.merged(regenerated, now: now), now: now)),
            ]
            var visible = Set<String>()
            for (arm, thread) in arms {
                guard let thread else { continue }
                visible.insert(arm)
                counts["threads_\(arm)", default: 0] += 1
                counts["thread_rows_\(arm)", default: 0] += thread.rows.count
                let before = first.map { start in thread.rows.filter { $0.date < start }.count } ?? 0
                let month = thread.rows.filter { isMonthPrecision($0.text) }.count
                let misparsed = thread.rows.filter { isMisparsed($0.date) }.count
                counts["thread_rows_before_first_report_\(arm)", default: 0] += before
                counts["thread_rows_month_precision_\(arm)", default: 0] += month
                counts["thread_rows_misparsed_year_\(arm)", default: 0] += misparsed
                let line = ThreadLine(
                    story: String(storyKey.prefix(8)), arm: arm, rows: thread.rows.map(\.text), day: thread.day,
                    beforeFirstReport: before, monthPrecision: month, misparsedYear: misparsed)
                threadLines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
            }
            for stage in ["stored", "regenerated"] {
                let old = visible.contains("\(stage)_main")
                let new = visible.contains("\(stage)_branch")
                let key = old && new ? "shared" : old ? "main_only" : new ? "branch_only" : nil
                if let key { counts["threads_\(stage)_\(key)", default: 0] += 1 }
            }
        }

        // The edition as the app selects it at the clock: unread stories of the last 24 hours, the Briefing
        // priorities and reading interests from the library, grouped into event cards. The reader's mute rules live in
        // the app's preferences, not the library, so none are applied here.
        let candidates = try await db.fetchArticles(
            isRead: false, limit: FiniteBriefing.candidateLimit,
            options: ArticleFetchOptions(publicationWindow: now.addingTimeInterval(-FiniteBriefing.duration)...now))
        let edition = FiniteBriefing(
            candidates: candidates, readIDs: [], now: now,
            priorities: try await db.briefingPriorities(articleIDs: candidates.map(\.id)),
            interests: try await db.briefingInterests(now: now, resetAt: nil))
        let entries = EventFeedGrouping.entries(
            for: edition.articles, events: try await db.eventFeedSummaries(forArticles: edition.articles.map(\.id)),
            mode: .events)
        counts["edition_entries"] = entries.count
        var editionThreads: [String: [(Int, String, Thread)]] = [:]
        for (index, entry) in entries.enumerated() {
            let overview: EventOverviewDocument?
            var story: [String] = []
            switch entry {
            case .event(let summary, _, _):
                overview = try? await db.fetchEventOverview(eventID: summary.eventID)
                story = (try? await db.storyEventIDs(summary.eventID)) ?? [summary.eventID]
                if !story.contains(summary.eventID) { story.insert(summary.eventID, at: 0) }
            case .article(let article):
                overview = try? await db.fetchEventOverview(forArticleID: article.id)
                story = overview.map { [$0.eventID] } ?? []
            }
            if overview != nil { counts["edition_entries_with_stored_overview", default: 0] += 1 }
            for eventID in story { try await compose(eventID, version: 1) }
            var stored: [(eventID: String, items: [OverviewTimelineItem])] = []
            for eventID in story {
                if let document = try? await db.fetchEventOverview(eventID: eventID) {
                    stored.append((eventID: eventID, items: document.timeline))
                }
            }
            let regenerated = story.map { (eventID: $0, items: composedBranch[$0] ?? []) }
            // The app's own thread for the branch arms, so "day N" follows its precision rule.
            func appThread(_ timelines: [(eventID: String, items: [OverviewTimelineItem])]) -> Thread? {
                let merged = BriefingTimelineData.merged(timelines, now: now)
                return BriefingTimelineData.thread(entry: entry, timeline: merged, now: now).map {
                    Thread(rows: $0.items.map { Thread.Row(text: $0.dayText, date: $0.date) }, day: $0.day)
                }
            }
            // Stored arms skip an entry without a stored overview, as BriefingOverviews.load does.
            let arms: [(String, Thread?)] = [
                ("stored_main", overview == nil ? nil : mainThread(story.flatMap { raw[$0]?.items ?? [] }, now: now)),
                ("stored_branch", overview == nil ? nil : appThread(stored)),
                ("regenerated_main", mainThread(story.flatMap { composedMain[$0] ?? [] }, now: now)),
                ("regenerated_branch", appThread(regenerated)),
            ]
            for (arm, thread) in arms {
                guard let thread else { continue }
                editionThreads[arm, default: []].append(
                    (index, String(story.first?.prefix(8) ?? entry.id.prefix(8)), thread))
            }
        }
        for arm in ["stored_main", "stored_branch", "regenerated_main", "regenerated_branch"] {
            // BriefingTimelineData.load orders threads by publisher count, then edition order; the card shows the first.
            let threads = (editionThreads[arm] ?? []).sorted {
                entries[$0.0].publisherCount != entries[$1.0].publisherCount
                    ? entries[$0.0].publisherCount > entries[$1.0].publisherCount : $0.0 < $1.0
            }
            counts["edition_threads_\(arm)"] = threads.count
            if let (_, story, thread) = threads.first {
                let line = ThreadLine(
                    story: story, arm: "edition_visible_\(arm)", rows: thread.rows.map(\.text), day: thread.day,
                    beforeFirstReport: 0, monthPrecision: thread.rows.filter { isMonthPrecision($0.text) }.count,
                    misparsedYear: thread.rows.filter { isMisparsed($0.date) }.count)
                threadLines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
            }
            for (_, story, thread) in threads.dropFirst() {
                let line = ThreadLine(
                    story: story, arm: "edition_hidden_\(arm)", rows: thread.rows.map(\.text), day: thread.day,
                    beforeFirstReport: 0, monthPrecision: 0,
                    misparsedYear: thread.rows.filter { isMisparsed($0.date) }.count)
                threadLines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
            }
        }

        var summary = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        summary.insert("now=\(Int(now.timeIntervalSince1970)) hours=\(Int(hours)) stored_overviews=\(raw.count)", at: 0)
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("timeline-events.jsonl"), atomically: true, encoding: .utf8)
        try threadLines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("briefing-threads.jsonl"), atomically: true, encoding: .utf8)
        try summary.joined(separator: "\n").write(
            to: directory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        print("TIMELINE_AUDIT\n" + summary.joined(separator: "\n"))
    }

    // MARK: - Arms

    /// `main`: the stated-date builder (its items carried no dates there), else the removed extractor.
    private static func mainTimeline(
        facts: [PassageAnchoredFact], passages: [EvidencePassage], articles: [FeedArticle]
    ) -> ([OverviewTimelineItem], String) {
        let stated = facts.filter { OverviewTimelineBuilder.singleStatedDate(in: $0.quote) != nil }
        let builder = OverviewTimelineBuilder.build(facts: stated, passages: passages, articles: articles).items.map {
            OverviewTimelineItem(id: $0.id, dateText: $0.dateText, summary: $0.summary, isFuturePlan: $0.isFuturePlan)
        }
        if !builder.isEmpty { return (builder, "builder") }
        var citations: [String: OverviewCitation] = [:]
        for passage in passages {
            citations["cite_\(passage.id)"] = OverviewCitation(
                id: "cite_\(passage.id)", articleID: passage.articleID, passageID: passage.id,
                passageFingerprint: passage.fingerprint, quote: String(passage.text.prefix(200)))
        }
        let extractor = TimelineAuditLegacyExtractor.extractTimeline(
            passages: passages, articles: articles, existingCitations: citations)
        return (extractor, extractor.isEmpty ? "none" : "extractor")
    }

    /// The diagnostic arm's input: every passage sentence the removed extractor read, as a fact.
    private static func passageSentenceFacts(_ passages: [EvidencePassage]) -> [PassageAnchoredFact] {
        passages.flatMap { passage in
            extractorSentences(passage.text).enumerated().map {
                PassageAnchoredFact(
                    id: "diag-\(passage.id)-\($0.offset)", statement: $0.element, passageID: passage.id,
                    quote: $0.element, articleID: passage.articleID)
            }
        }
    }

    private static func extractorSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count >= 20 { sentences.append(sentence) }
            return true
        }
        return sentences
    }

    // MARK: - Reasons

    private static let englishMonth =
        "January|February|March|April|May|June|July|August|September|October|November|December"
        + "|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec"
    private static let datePattern =
        #"(?:\b\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:M)\b|\b(?:M)\.?\s+\d{1,2}\b|\b(?:M)\s+(?:19|20)\d{2}\b|\b(?:19|20)\d{2}-\d{2}-\d{2}\b)"#
        .replacingOccurrences(of: "M", with: englishMonth)

    /// Why a main row is not among the branch rows, checked in the order a sentence meets the rules.
    private static func reason(
        for item: OverviewTimelineItem, source: String, facts: [PassageAnchoredFact], passages: [EvidencePassage],
        articles: [FeedArticle], branch: [OverviewTimelineItem]
    ) -> String {
        if item.dateText.caseInsensitiveCompare("Scheduled") == .orderedSame { return "placeholder" }
        let sentence = item.summary
        let quotes = facts.map(\.quote)
        if source == "extractor", !quotes.contains(sentence) {
            let overlaps = quotes.contains { $0.contains(sentence) || sentence.contains($0) }
            if overlaps { return "segmentation" }
            guard let passage = passages.first(where: { $0.text.contains(sentence) }) else {
                return "passageNotSelected"
            }
            let candidate = RawFactCandidate(statement: sentence, passageID: passage.id, quote: sentence)
            let accepted = PassageFactValidator.validateCandidates([candidate], against: passages).acceptedFacts
            return accepted.isEmpty ? "factRejected" : "segmentation"
        }
        let articleID = facts.first { $0.quote == sentence }?.articleID
        if let article = articles.first(where: { $0.id == articleID }), article.pubDate == DateParser.unknownDate {
            return "unknownPublicationDate"
        }
        let stated = OverviewTimelineBuilder.singleStatedDate(in: sentence)
        let anchor = OverviewTimelineBuilder.anchor(in: sentence, publishedAt: Date())
        if stated == nil && anchor == nil {
            let range = NSRange(sentence.startIndex..., in: sentence)
            let sensitive =
                (try? NSRegularExpression(pattern: datePattern))?.numberOfMatches(in: sentence, range: range) ?? 0
            let insensitive =
                (try? NSRegularExpression(pattern: datePattern, options: [.caseInsensitive]))?
                .numberOfMatches(in: sentence, range: range) ?? 0
            if sensitive >= 2 { return "severalDates" }
            if sensitive == 0, insensitive > 0 { return "letterCase" }
            let anchors = OverviewTimelineItem.anchorExpressions.reduce(0) {
                $0 + $1.numberOfMatches(in: sentence, range: range)
            }
            return anchors >= 2 ? "severalAnchors" : "noDate"
        }
        if branch.isEmpty { return "fewerThanTwoDistinctDates" }
        if branch.count >= OverviewTimelineBuilder.maximumItems { return "truncationAt8" }
        return "reprintMerged"
    }

    // MARK: - Briefing

    /// Briefing on `main`: past, non-plan items dated by `eventDate ?? publicationDate`, first of each summary.
    private static func mainThread(_ items: [OverviewTimelineItem], now: Date) -> Thread? {
        var seen = Set<String>()
        let rows = items.compactMap { item -> Thread.Row? in
            guard !item.isFuturePlan, let date = item.eventDate ?? item.publicationDate, date <= now,
                seen.insert(item.summary).inserted
            else { return nil }
            return Thread.Row(text: item.dateText, date: date)
        }
        return thread(rows, now: now)
    }

    private static func branchThread(_ merged: [OverviewTimelineItem], now: Date) -> Thread? {
        guard let items = BriefingTimelineData.items(merged, now: now) else { return nil }
        return thread(items.map { Thread.Row(text: $0.dayText, date: $0.date) }, now: now)
    }

    private static func thread(_ rows: [Thread.Row], now: Date) -> Thread? {
        let latest = Array(rows.sorted { $0.date < $1.date }.suffix(5))
        guard latest.count >= 2, let first = latest.first else { return nil }
        let calendar = Calendar.current
        let day = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: first.date), to: calendar.startOfDay(for: now)
        ).day
        return Thread(rows: latest, day: day.map { max(0, $0) })
    }

    // MARK: - Stored rows

    /// The stored timelines with their raw dates, read without the branch's decoder.
    private static func rawStoredTimelines(path: String) throws -> Stored {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "TimelineAudit", code: 2)
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let query = "SELECT event_id, analysis_version, facts_json FROM event_overviews"
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "TimelineAudit", code: 3)
        }
        defer { sqlite3_finalize(statement) }
        var result: Stored = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let json = sqlite3_column_text(statement, 2) else {
                continue
            }
            let object = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any]
            let timeline = (object?["evidenceSections"] as? [String: Any])?["timeline"] as? [[String: Any]] ?? []
            let items = timeline.map { row in
                OverviewTimelineItem(
                    id: row["id"] as? String ?? "", dateText: row["dateText"] as? String ?? "",
                    summary: row["summary"] as? String ?? "", isFuturePlan: row["isFuturePlan"] as? Bool ?? false,
                    eventDate: (row["eventDate"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)),
                    publicationDate: (row["publicationDate"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
                )
            }
            result[String(cString: id)] = (Int(sqlite3_column_int(statement, 1)), items)
        }
        return result
    }

    // MARK: - Helpers

    private static func isMisparsed(_ date: Date?) -> Bool {
        date.map { OverviewTimelineItem.legacyCalendar.component(.year, from: $0) < 100 } ?? false
    }

    private static func isMonthPrecision(_ text: String) -> Bool {
        text.range(of: #"^\p{L}+\.?\s+\d{4}$"#, options: .regularExpression) != nil
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
