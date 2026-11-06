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

import AppKit
import CoreSpotlight
import Foundation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Help › Export Diagnostics (#564): a zip with this launch's log for the app's subsystem (combined and per category),
/// the app, macOS and library schema versions, a settings summary, feed health and one file per subsystem's state
/// (#1006). It holds no story text: URLs keep only their host, home folders become `~`, and the titles of loaded
/// stories are replaced.
enum DiagnosticsExport {
    struct LogLine: Equatable, Sendable {
        let date: Date
        let category: String
        let level: String
        let message: String
    }

    static let window: TimeInterval = 24 * 60 * 60
    static let folderName = "News Diagnostics"

    @MainActor
    static func run(settings: AppSettings, feedManager: FeedManager, articleStore: ArticleStore) {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.prompt = "Export"
        panel.nameFieldStringValue = folderName + ".zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in
            do {
                let now = Date()
                await feedManager.reloadFeedHealth()
                let schema = try? await articleStore.database.storedSchemaVersion()
                let summary = summary(settings: settings, feedHealth: feedManager.feedHealth, schema: schema, now: now)
                let titles = (articleStore.articles + articleStore.savedArticles).map(\.title)
                let app = await snapshot(feedManager: feedManager, articleStore: articleStore)
                let database = articleStore.database
                try await Task.detached(priority: .userInitiated) {
                    var app = app
                    app.cacheFolderBytes = CacheManager.shared.calculateTotalCacheSize()
                    let log = try logLines(since: .distantPast)
                    let sections = await sectionFiles(database, app: app, log: log, now: now)
                    try archive(files(summary: summary, sections: sections, log: log, titles: titles), to: destination)
                }.value
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// The unified log of this process only: a sandboxed app cannot read earlier launches, so the export covers the
    /// current launch, and of a launch older than a day only its last 24 hours.
    static func currentLaunchLog(now: Date = Date()) throws -> [LogLine] {
        try logLines(since: now.addingTimeInterval(-window))
    }

    /// This process's entries for the app's subsystem from `start` on, as the log redacts them; the export and the
    /// development Log window (#1005) read through here.
    static func logLines(since start: Date) throws -> [LogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let subsystem = NSPredicate(format: "subsystem == %@", NewsSignposts.subsystem)
        return try store.getEntries(at: store.position(date: start), matching: subsystem).compactMap { entry in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return LogLine(
                date: log.date, category: log.category, level: name(of: log.level), message: redacted(log))
        }
    }

    /// Read in-process, the unified log returns private values in clear (feed URLs can carry tokens), so they are
    /// redacted here as the system log would: only `.public` values and unannotated numbers are kept.
    static func redacted(_ entry: OSLogEntryLog) -> String {
        entry.components.map { component in
            guard !component.placeholder.isEmpty else { return component.formatSubstring }
            let numbers: [OSLogMessageComponent.ArgumentCategory] = [.double, .int64, .uInt64]
            let number = numbers.contains(component.argumentCategory)
            let shown =
                component.placeholder.contains("public") || (number && !component.placeholder.contains("private"))
            let value = number ? component.argumentNumberValue?.stringValue : component.argumentStringValue
            return component.formatSubstring + (shown ? value ?? "" : "<private>")
        }.joined()
    }

    static let levels = ["Debug", "Info", "Notice", "Error", "Fault"]

    private static func name(of level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "Debug"
        case .info: return "Info"
        case .notice: return "Notice"
        case .error: return "Error"
        case .fault: return "Fault"
        default: return "Default"
        }
    }

    @MainActor
    static func summary(settings: AppSettings, feedHealth: [String: FeedHealth], schema: Int?, now: Date) -> String {
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let retention = settings.articleRetentionDays
        var lines = [
            "News diagnostics, \(now.formatted(.iso8601))",
            "App version: \(version) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Library schema version: \(schema.map { String($0) } ?? "unknown")",
            "Log: this whole launch; a sandboxed app cannot read earlier launches",
            "",
            "Settings",
            "Feeds: \(settings.feedURLs.count), starred: \(settings.starredFeedURLs.count)",
            "Sections: \(settings.userSections.count)",
            "Refresh interval: \(Int(settings.fetchIntervalMinutes)) minutes",
            "Keep read stories: " + (retention == 0 ? "always" : "\(retention) days"),
            "Notifications: \(onOff(settings.notificationsEnabled)), mode \(settings.notificationMode.rawValue)",
            "Dock badge: \(onOff(settings.showsDockBadge)), menu bar item: \(onOff(settings.showsMenuBarExtra))",
            "On-device intelligence: \(onOff(settings.aiEnabled))",
            "Insecure HTTP: \(onOff(settings.allowInsecureHTTP))",
            "World tension collection: \(onOff(settings.tensionCollectionOptIn))",
            "Muted publishers: \(settings.muteRules.sources.count), muted topics: \(settings.muteRules.topics.count)",
            "",
            "Feed health",
        ]
        for (url, health) in feedHealth.sorted(by: { $0.key < $1.key }) {
            lines.append("\(URL(string: url)?.host ?? "unreadable feed address"): \(health.summary(now: now))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The archive's text files, redacted; `summary.txt` ends with the list of files.
    static func files(
        summary: String, sections: [String: String] = [:], log: [LogLine], titles: [String]
    ) -> [String: String] {
        var files = sections.merging(logFiles(log)) { section, _ in section }
        let names = (Array(files.keys) + ["summary.txt"]).sorted()
        files["summary.txt"] = summary + "\nFiles\n" + names.joined(separator: "\n") + "\n"
        return files.mapValues { redact($0, titles: titles) }
    }

    /// URLs keep only their host, home folders become `~`, and listed story titles of 12 or more characters are
    /// replaced.
    static func redact(_ text: String, titles: [String]) -> String {
        // The whole non-space token goes, quotes included; the host follows the last `@` of the authority.
        var redacted = text.replacing(#/[A-Za-z][A-Za-z0-9+.\-]*://(\S*)/#) { match in
            let authority = match.output.1.prefix { !"/?#".contains($0) }
            let host = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
            return String(host.prefix { $0 != ":" && $0 != "'" && $0 != "\"" })
        }
        redacted = redacted.replacing(#/(?:/System/Volumes/Data)?/Users/[^/\s]+/#, with: "~")
        // Short titles are ordinary phrases; replacing them would blank unrelated log text.
        for title in Set(titles) where title.count >= 12 {
            redacted = redacted.replacingOccurrences(of: title, with: "<story>")
        }
        return redacted
    }

    /// Writes the files into a folder and zips it with the system archiver (`NSFileCoordinator`, `.forUploading`).
    static func archive(_ files: [String: String], to destination: URL) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let folder = root.appendingPathComponent(folderName)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        var coordinationError: NSError?
        var zipped: Result<Data, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) {
            zip in zipped = Result { try Data(contentsOf: zip) }
        }
        if let coordinationError { throw coordinationError }
        // The archive is staged beside the destination and swapped in only once complete, so a failure keeps an
        // earlier export. The sandbox can refuse that sibling file (only the chosen file is granted, as on some
        // external volumes); then the archive, already whole in memory, is written to the chosen file directly.
        let data = try zipped.get()
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staged) }
        do {
            try data.write(to: staged)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: destination)
            }
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            try data.write(to: destination)
        }
    }

    // MARK: - Subsystem state (#1006)

    /// What the export reads from the main actor and the other actors before it leaves for the background.
    struct AppSnapshot: Sendable {
        var feedURLs: [String] = []
        /// Nil when the library could not be read: the export says so instead of reporting empty states.
        var feedStates: [String: FeedFetchState]? = [:]
        /// Per feed: idle, loading or the failure kind (`failureKind`).
        var feedStatuses: [String: String] = [:]
        var lastClusteringPass: FeedManager.ClusteringPass?
        var lastImageLookup: StoryCurator.Report?
        var embedderAvailable = false
        var pairModelAvailable = false
        var foundationModels = "unknown"
        var enrichmentStates: [String: Int] = [:]
        var overviews = OverviewGenerationCoordinator.Counts()
        var notificationSettings: [String] = []
        var gatewayPort: UInt16?
        var resolverCancellations = 0
        var proxy: [String] = []
        var process = ProcessSnapshot()
        var savedStories = 0
        var spotlightAvailable = false
        var urlCache = (memory: 0, disk: 0, memoryCapacity: 0, diskCapacity: 0)
        var cacheFolderBytes: Int64 = 0
    }

    struct ProcessSnapshot: Sendable {
        var lowPowerMode = false
        var thermalState = "nominal"
        var footprintBytes: UInt64?
        var launchedAt: Date?
        var locale = ""
        var displayScale: Double?
        var reduceMotion = false
        var increaseContrast = false
        var voiceOver = false
    }

    /// One file per subsystem: counts, ids, hosts and settings only, each written from the value its owner holds. A
    /// section that cannot be read says so in its file instead of failing the export.
    static func sectionFiles(_ database: DatabaseEngine, app: AppSnapshot, log: [LogLine], now: Date) async
        -> [String: String]
    {
        func read(_ name: String, _ body: () async throws -> String) async -> String {
            do { return try await body() } catch { return "\(name): not readable (\(error.localizedDescription))\n" }
        }
        var files = [
            "feeds.txt": feeds(feedURLs: app.feedURLs, states: app.feedStates, statuses: app.feedStatuses, now: now),
            "network.txt": network(
                gatewayPort: app.gatewayPort, resolverCancellations: app.resolverCancellations,
                feedStatuses: app.feedStatuses, proxy: app.proxy, log: log),
            "process.txt": process(app.process, now: now),
            "spotlight-and-caches.txt": spotlightAndCaches(app, log: log),
        ]
        files["library.txt"] = await read("Library") { try await library(database) }
        files["clustering.txt"] = await read("Clustering") {
            try await clustering(
                database, lastPass: app.lastClusteringPass, embedderAvailable: app.embedderAvailable,
                pairModelAvailable: app.pairModelAvailable)
        }
        files["intelligence.txt"] = await read("Intelligence") {
            try await intelligence(
                database, foundationModels: app.foundationModels, queue: app.enrichmentStates, overviews: app.overviews)
        }
        files["notifications.txt"] = await read("Notifications") {
            try await notifications(database, settings: app.notificationSettings, log: log, now: now)
        }
        files["images.txt"] = await read("Images") {
            try await images(database, lastLookup: app.lastImageLookup, now: now)
        }
        return files
    }

    /// The name of a feed failure without its payload, which can carry addresses: `httpStatus 404`, `timeout`.
    static func failureKind(_ error: FeedError) -> String {
        switch error {
        case .httpStatus(let status): return "httpStatus \(status)"
        case .serverBusy(let status, _): return "serverBusy \(status)"
        default: return String(String(describing: error).prefix { $0 != "(" })
        }
    }

    /// Library: schema, files, integrity, row counts, story dates and the pre-migration copies beside it.
    static func library(_ database: DatabaseEngine, fileManager: FileManager = .default) async throws -> String {
        func value(_ sql: String) async throws -> String {
            try await scalar(database, sql) ?? "none"
        }
        var lines = [
            "Schema version: \(try await database.storedSchemaVersion()) (this build writes \(DatabaseEngine.schemaVersion))",
            "Read-only: \(await database.isReadOnly ? "yes" : "no")",
            "Health notice: \(await database.healthNotice ?? "none")",
        ]
        let path = database.dbPath
        let file = URL(fileURLWithPath: path)
        for suffix in ["", "-wal", "-shm"] {
            let size = (try? fileManager.attributesOfItem(atPath: path + suffix)[.size] as? Int) ?? nil
            lines.append("File \(file.lastPathComponent)\(suffix): \(size.map(byteText) ?? "absent")")
        }
        let integrity = try await database.eventRows("PRAGMA integrity_check(20);").compactMap { $0.first ?? nil }
        lines.append("Integrity check: \(integrity.joined(separator: "; "))")
        let oldest = try await database.eventRows("SELECT min(published_at), max(published_at) FROM articles;")
        let dates = (oldest.first ?? []).map {
            $0.flatMap(Double.init).map { Date(timeIntervalSince1970: $0).formatted(.iso8601) } ?? "none"
        }
        lines.append("Oldest story: \(dates.first ?? "none"), newest: \(dates.last ?? "none")")
        lines += ["", "Rows per table"]
        let tables = try await database.eventRows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
        for name in tables.compactMap({ $0.first ?? nil }) {
            let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\(name): \(try await value("SELECT count(*) FROM \"\(quoted)\";"))")
        }
        // `<name>-before-v<old>-<date>.sqlite3` copies the schema upgrade writes (DatabaseEngine.backupBeforeMigration).
        let folder = file.deletingLastPathComponent()
        let copies =
            ((try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.contains("-before-v") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // Only the app-written suffix is reported: the name before it is whatever the reader called the file.
        func suffix(_ copy: URL) -> String {
            "before-v" + (copy.lastPathComponent.components(separatedBy: "-before-v").last ?? "")
        }
        lines += ["", "Pre-migration copies (the migration history this library keeps): \(copies.count)"]
        for copy in copies {
            let size = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            lines.append("\(suffix(copy)): \(size.map(byteText) ?? "unknown size")")
        }
        lines.append(
            "Last backup: \(copies.last.map(suffix) ?? "none beside the library"); Back Up Library copies go where the reader saves them and are not tracked"
        )
        return lines.joined(separator: "\n") + "\n"
    }

    /// Feeds: per subscription, by host and position, what the last fetch left.
    static func feeds(
        feedURLs: [String], states: [String: FeedFetchState]?, statuses: [String: String], now: Date
    ) -> String {
        func time(_ date: Date?) -> String { date?.formatted(.iso8601) ?? "never" }
        var lines = ["Subscriptions: \(feedURLs.count)", "Response sizes are not recorded.", ""]
        for (index, url) in feedURLs.enumerated() {
            let host = URL(string: url)?.host ?? "unreadable feed address"
            guard let states else {
                lines.append("\(index + 1). \(host): status \(statuses[url] ?? "idle"), fetch state unreadable")
                continue
            }
            let state = states[url] ?? FeedFetchState()
            let validators = [
                state.validators?.etag == nil ? nil : "ETag",
                state.validators?.lastModified == nil ? nil : "Last-Modified",
            ].compactMap { $0 }
            lines.append(
                "\(index + 1). \(host): status \(statuses[url] ?? "idle"), "
                    + "last fetch \(time(state.lastFetchedAt)), failures \(state.failures), "
                    + "retry \(state.retryAt.map { $0 > now ? $0.formatted(.iso8601) : "due" } ?? "none"), "
                    + "validators \(validators.isEmpty ? "none" : validators.joined(separator: " and ")), "
                    + "items \(state.itemCount), full text \(state.fullTextItems) of \(state.itemCount), "
                    + "newest item \(time(state.latestItemAt)), "
                    + "last failure \(state.lastFailureKind?.rawValue ?? "none")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Clustering: matcher and model versions, event and story counts, the backlog and the last pass.
    static func clustering(
        _ database: DatabaseEngine, lastPass: FeedManager.ClusteringPass?, embedderAvailable: Bool,
        pairModelAvailable: Bool
    ) async throws -> String {
        func count(_ sql: String, _ values: [DatabaseEngine.EventValue] = []) async throws -> String {
            try await scalar(database, sql, values) ?? "0"
        }
        func compiled(_ name: String) -> String {
            FileManager.default.fileExists(atPath: bundledModelResource(name, "mlmodelc").path)
                ? "compiled model bundled" : "no compiled model"
        }
        var lines = [
            "Matcher version: \(EventMatcher.version)",
            "Events (live): \(try await count("SELECT count(*) FROM events WHERE merged_into IS NULL;"))",
            "Events merged into another: \(try await count("SELECT count(*) FROM events WHERE merged_into IS NOT NULL;"))",
            "Stories: \(try await count("SELECT count(DISTINCT coalesce(story_id, id)) FROM events WHERE merged_into IS NULL;"))",
            "Event members: \(try await count("SELECT count(*) FROM event_members;"))",
            "Stories pending a match (no match state or an older matcher): "
                + (try await count(
                    "SELECT count(*) FROM articles a LEFT JOIN event_match_state m ON m.article_id = a.id WHERE m.article_id IS NULL OR m.matcher_version < ?;",
                    [.integer(EventMatcher.version)])),
            "Sentence embedder: version \(SentenceEmbedder.modelVersion), \(embedderAvailable ? "available" : "unavailable"), \(compiled("minilm"))",
            "Pair model: matcher version \(EventMatcher.version), \(pairModelAvailable ? "available" : "unavailable"), \(compiled("pairscorer"))",
        ]
        if let pass = lastPass {
            let report = pass.report
            lines.append(
                "Last pass: finished \(pass.finishedAt.formatted(.iso8601)), \(String(format: "%.2f", pass.seconds)) s, "
                    + "processed \(report.processed), joined \(report.joined), created \(report.created), "
                    + "detached \(report.detached), merged \(report.merged), conflicts \(report.conflicts), "
                    + "deferred \(report.deferred), events changed \(report.changedEvents.count)")
        } else {
            lines.append("Last pass: none finished this launch")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Intelligence: model availability, the enrichment queue and stored results, and overview work in flight.
    static func intelligence(
        _ database: DatabaseEngine, foundationModels: String, queue: [String: Int],
        overviews: OverviewGenerationCoordinator.Counts
    ) async throws -> String {
        let enrichment =
            try await database.eventRows(
                "SELECT count(*), count(enriched_at), count(summary) FROM article_enrichment;"
            ).first ?? []
        let versions = try await database.eventRows(
            "SELECT coalesce(analysis_version, 0), count(*) FROM article_enrichment GROUP BY 1 ORDER BY 1;")
        let stored =
            try await scalar(database, "SELECT value FROM model_generation WHERE id = 1;")
        let lines = [
            "Foundation Models: \(foundationModels)",
            "Analysis generation: \(NewsTextModel.generation); stored for this library: \(stored ?? "none")",
            "Enrichment queue: "
                + (queue.isEmpty
                    ? "empty"
                    : queue.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")),
            "Enrichment rows: \(enrichment.first.flatMap { $0 } ?? "0"), enriched \(enrichment.dropFirst().first.flatMap { $0 } ?? "0"), with a summary \(enrichment.last.flatMap { $0 } ?? "0")",
            "Enrichment rows by analysis version: "
                + versions.map { "v\($0[0] ?? "?") \($0[1] ?? "0")" }.joined(separator: ", "),
            "Event overviews stored: \(try await scalar(database, "SELECT count(*) FROM event_overviews;") ?? "0")",
            "Overview generations in flight: \(overviews.inFlight), page fetches running \(overviews.extractions), "
                + "failed this launch \(overviews.failedExtractions), held in memory \(overviews.cached)",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Notifications: the system settings, the delivery tables of the last 24 hours and the routes this launch's log
    /// recorded (app banner, Notification Center, refusals with domain and code).
    static func notifications(
        _ database: DatabaseEngine, settings: [String], log: [LogLine], now: Date
    ) async throws -> String {
        let since = now.timeIntervalSince1970 - window
        var lines = ["Settings"] + settings + ["", "Deliveries in the last 24 hours (lane, grouped: banners, stories)"]
        let lanes = ["0": "normal", "1": "starred", "2": "priority"]
        let deliveries = try await database.eventRows(
            "SELECT lane, grouped, count(*), sum(story_count) FROM notification_deliveries WHERE delivered_at > ? GROUP BY lane, grouped ORDER BY lane, grouped;",
            [.real(since)])
        if deliveries.isEmpty { lines.append("none") }
        for row in deliveries {
            lines.append(
                "\(lanes[row[0] ?? ""] ?? "lane \(row[0] ?? "?")")\(row[1] == "1" ? ", grouped" : ""): \(row[2] ?? "0"), \(row[3] ?? "0")"
            )
        }
        lines.append(
            "Events notified in the last 24 hours: "
                + (try await scalar(
                    database,
                    "SELECT count(*) FROM event_notifications WHERE notified_at > ?;", [.real(since)]
                )
                    ?? "0"))
        lines.append(
            "Priority stories waiting: \(try await scalar(database, "SELECT count(*) FROM notification_priority_queue;") ?? "0")"
        )
        var routes: [String: Int] = [:]
        for line in log where line.category == "StoryBanner" {
            if let route = line.message.firstMatch(of: #/route=(\w+)/#)?.output.1 {
                routes[String(route), default: 0] += 1
            }
        }
        for line in log where line.category == "NotificationService" {
            if let refusal = line.message.firstMatch(of: #/domain=(\S+) code=(-?\d+)/#) {
                routes["refused \(refusal.output.1) \(refusal.output.2)", default: 0] += 1
            }
        }
        lines += ["", "Routes this launch"]
        lines += routes.isEmpty ? ["none"] : routes.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Images: the publisher-image lookup table, the last lookup pass and the decoded-image cache's limits.
    static func images(_ database: DatabaseEngine, lastLookup: StoryCurator.Report?, now: Date) async throws -> String {
        let row =
            try await database.eventRows(
                "SELECT count(*), count(image_url), count(*) - count(image_url), coalesce(sum(checked_at > ?), 0) FROM story_images;",
                [.real(now.timeIntervalSince1970 - window)]
            ).first ?? []
        let lookup = lastLookup.map {
            "found \($0.imagesFound), checked \($0.imagesChecked) of a budget of \(StoryCurator.imageBudget)"
        }
        return [
            "Lookup rows: \(cell(row, 0)), with an image \(cell(row, 1)), refused or without one \(cell(row, 2)), checked in the last 24 hours \(cell(row, 3))",
            "Last lookup pass: \(lookup ?? "none finished this launch")",
            "Decoded image caches: full size at most \(DecodedImageCache.fullCountLimit) images and \(byteText(DecodedImageCache.fullCostLimit)), card size at most \(DecodedImageCache.cardCountLimit) images and \(byteText(DecodedImageCache.cardCostLimit)); NSCache does not report what they hold",
        ].joined(separator: "\n") + "\n"
    }

    /// Network: the gateway, resolver cancellations, feed failures by kind and the gateway's upstream outcomes this
    /// launch, and the system proxy and VPN state the app can see.
    static func network(
        gatewayPort: UInt16?, resolverCancellations: Int, feedStatuses: [String: String], proxy: [String],
        log: [LogLine]
    ) -> String {
        var failures: [String: Int] = [:]
        for status in feedStatuses.values where status != "idle" && status != "loading" {
            failures[status, default: 0] += 1
        }
        var upstream: [String: Int] = [:]
        for line in log where line.category == "NetworkBoundaryProxy" {
            if let match = line.message.firstMatch(of: #/(failed|refused|is waiting): (.+)$/#) {
                upstream["\(match.output.1) \(match.output.2)", default: 0] += 1
            }
        }
        func list(_ counts: [String: Int]) -> [String] {
            counts.isEmpty ? ["none"] : counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        }
        var lines = [
            "Gateway: " + (gatewayPort.map { "listening on 127.0.0.1:\($0)" } ?? "not running"),
            "Resolver: lookups cancelled before they answered \(resolverCancellations); each lookup ends at its \(ProxyResolver.defaultDeadline.components.seconds) s deadline",
            "", "Feeds failing now, by kind",
        ]
        lines += list(failures)
        lines += ["", "Gateway upstream connects this launch, by outcome"] + list(upstream)
        lines += ["", "System proxy and VPN"] + (proxy.isEmpty ? ["none reported"] : proxy)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The system proxy flags and the scoped interfaces a VPN adds (utun, ipsec, ppp), from the proxy settings dictionary.
    static func proxyLines(_ settings: [String: Any]) -> [String] {
        var lines: [String] = []
        for (key, name) in [
            ("HTTPEnable", "HTTP proxy"), ("HTTPSEnable", "HTTPS proxy"), ("SOCKSEnable", "SOCKS proxy"),
            ("ProxyAutoConfigEnable", "Automatic proxy configuration"), ("ProxyAutoDiscoveryEnable", "Proxy discovery"),
        ] where (settings[key] as? Int) == 1 {
            lines.append("\(name): on")
        }
        let scoped = (settings["__SCOPED__"] as? [String: Any])?.keys.sorted() ?? []
        let tunnels = scoped.filter { name in ["utun", "ipsec", "ppp"].contains { name.hasPrefix($0) } }
        if !tunnels.isEmpty { lines.append("VPN interfaces: \(tunnels.joined(separator: ", "))") }
        return lines
    }

    /// Process: energy, memory, uptime, locale, display and the accessibility settings in effect.
    static func process(_ snapshot: ProcessSnapshot, now: Date) -> String {
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }
        let uptime = snapshot.launchedAt.map { "\(Int(now.timeIntervalSince($0))) s" } ?? "unknown"
        return [
            "Low Power Mode: \(onOff(snapshot.lowPowerMode))",
            "Thermal state: \(snapshot.thermalState)",
            "Memory footprint: \(snapshot.footprintBytes.map { byteText(Int($0)) } ?? "unknown")",
            "Uptime: \(uptime)",
            "Locale: \(snapshot.locale)",
            "Display scale: \(snapshot.displayScale.map { String(format: "%.1f", $0) } ?? "no display")",
            "Reduce Motion: \(onOff(snapshot.reduceMotion)), Increase Contrast: \(onOff(snapshot.increaseContrast)), VoiceOver: \(onOff(snapshot.voiceOver))",
        ].joined(separator: "\n") + "\n"
    }

    /// Reads energy, memory and locale; the display and accessibility values come from the main actor.
    static func processSnapshot(
        _ info: ProcessInfo = .processInfo, displayScale: Double?, reduceMotion: Bool, increaseContrast: Bool,
        voiceOver: Bool
    ) -> ProcessSnapshot {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let thermal: String
        switch info.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return ProcessSnapshot(
            lowPowerMode: info.isLowPowerModeEnabled, thermalState: thermal,
            footprintBytes: status == KERN_SUCCESS ? vm.phys_footprint : nil, launchedAt: NewsSignposts.processStart(),
            locale: Locale.current.identifier, displayScale: displayScale, reduceMotion: reduceMotion,
            increaseContrast: increaseContrast, voiceOver: voiceOver)
    }

    /// The whole launch's log, combined and one file per category.
    static func logFiles(_ log: [LogLine]) -> [String: String] {
        func text(_ lines: [LogLine]) -> String {
            lines.map { "\($0.date.formatted(.iso8601)) \($0.level) \($0.category): \($0.message)\n" }.joined()
        }
        var files = ["log.txt": text(log)]
        for (category, lines) in Dictionary(grouping: log, by: \.category) {
            files["log-\(category.filter { $0.isLetter || $0.isNumber })\(category.isEmpty ? "none" : "").txt"] = text(
                lines)
        }
        return files
    }

    /// Spotlight and caches: the saved stories Spotlight indexes, URL cache use and the Clear commands this launch ran.
    static func spotlightAndCaches(_ app: AppSnapshot, log: [LogLine]) -> String {
        let cache = app.urlCache
        var lines = [
            "Spotlight: indexing \(app.spotlightAvailable ? "available" : "unavailable"), saved stories to index \(app.savedStories)",
            "URL cache: memory \(byteText(cache.memory)) of \(byteText(cache.memoryCapacity)), disk \(byteText(cache.disk)) of \(byteText(cache.diskCapacity))",
            "Cache folder on disk: \(byteText(Int(app.cacheFolderBytes)))",
            "", "Clear commands this launch",
        ]
        let clears = log.filter { $0.message.hasPrefix("Cleared") }
        lines += clears.isEmpty ? ["none"] : clears.map { "\($0.date.formatted(.iso8601)) \($0.message)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The first column of the first row, nil when there is none or it is NULL.
    static func scalar(_ database: DatabaseEngine, _ sql: String, _ values: [DatabaseEngine.EventValue] = [])
        async throws
        -> String?
    {
        try await database.eventRows(sql, values).first?.first ?? nil
    }

    static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func cell(_ row: [String?], _ index: Int) -> String {
        row.indices.contains(index) ? row[index] ?? "0" : "0"
    }

    /// Reads what the main actor and the other subsystems hold, before the export leaves the main actor.
    @MainActor
    static func snapshot(feedManager: FeedManager, articleStore: ArticleStore) async -> AppSnapshot {
        var app = AppSnapshot()
        app.feedURLs = feedManager.appSettings.feedURLs
        app.feedStates = try? await articleStore.database.feedFetchStates()
        app.feedStatuses = feedManager.feedStatuses.mapValues { status in
            switch status {
            case .idle: return "idle"
            case .loading: return "loading"
            case .failed(let error): return failureKind(error)
            }
        }
        app.lastClusteringPass = feedManager.lastClusteringPass
        app.lastImageLookup = feedManager.lastImageLookup
        app.embedderAvailable = await SentenceEmbedder.shared.isAvailable
        app.pairModelAvailable = await PairScorer.shared.isAvailable
        app.foundationModels = foundationModelsAvailability()
        app.enrichmentStates = await feedManager.enrichmentQueue.stateCounts()
        app.overviews = await OverviewGenerationCoordinator.shared.counts()
        if Bundle.main.bundleIdentifier != nil {
            app.notificationSettings = notificationSettingsLines(
                await UNUserNotificationCenter.current().notificationSettings())
        }
        app.gatewayPort = await NetworkBoundaryProxy.shared.runningPort()
        app.resolverCancellations = ProxyResolver.cancellations.withLock { $0 }
        app.proxy = proxyLines((CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:])
        let workspace = NSWorkspace.shared
        app.process = processSnapshot(
            displayScale: NSScreen.main.map { Double($0.backingScaleFactor) },
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            voiceOver: workspace.isVoiceOverEnabled)
        app.savedStories = articleStore.savedArticles.count
        app.spotlightAvailable = CSSearchableIndex.isIndexingAvailable()
        let cache = URLCache.shared
        app.urlCache = (cache.currentMemoryUsage, cache.currentDiskUsage, cache.memoryCapacity, cache.diskCapacity)
        return app
    }

    static func foundationModelsAvailability() -> String {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return "available"
                case .unavailable(let reason): return "unavailable (\(reason))"
                }
            }
        #endif
        return "unavailable (needs macOS 26)"
    }

    static func notificationSettingsLines(_ settings: UNNotificationSettings) -> [String] {
        [
            "Authorization: \(name(of: settings.authorizationStatus))",
            "Alerts: \(name(of: settings.alertSetting)), style \(name(of: settings.alertStyle))",
            "Previews: \(name(of: settings.showPreviewsSetting))", "Sound: \(name(of: settings.soundSetting))",
            "Badge: \(name(of: settings.badgeSetting))",
            "Notification Center: \(name(of: settings.notificationCenterSetting))",
        ]
    }

    private static func name(of setting: UNNotificationSetting) -> String {
        switch setting {
        case .enabled: return "on"
        case .disabled: return "off"
        case .notSupported: return "not supported"
        @unknown default: return "unknown"
        }
    }

    private static func name(of status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not asked yet"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func name(of style: UNAlertStyle) -> String {
        switch style {
        case .none: return "none"
        case .banner: return "banners"
        case .alert: return "alerts"
        @unknown default: return "unknown"
        }
    }

    private static func name(of previews: UNShowPreviewsSetting) -> String {
        switch previews {
        case .always: return "always"
        case .whenAuthenticated: return "when unlocked"
        case .never: return "never"
        @unknown default: return "unknown"
        }
    }
}
