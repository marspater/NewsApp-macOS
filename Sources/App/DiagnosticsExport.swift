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
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Help › Export Diagnostics (#564): a zip with this launch's log entries for the app's subsystem (at most the last
/// 24 hours), the app, macOS and library schema versions, a settings summary and feed health. It holds no story text:
/// URLs keep only their host, home folders become `~`, and the titles of loaded stories are replaced.
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
                try await Task.detached(priority: .userInitiated) {
                    let log = try currentLaunchLog(now: now)
                    try archive(files(summary: summary, log: log, titles: titles), to: destination)
                }.value
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// The unified log of this process only: a sandboxed app cannot read earlier launches, so the export covers the
    /// current launch, and of a launch older than a day only its last 24 hours.
    static func currentLaunchLog(now: Date = Date()) throws -> [LogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let start = store.position(date: now.addingTimeInterval(-window))
        let subsystem = NSPredicate(format: "subsystem == %@", NewsSignposts.subsystem)
        return try store.getEntries(at: start, matching: subsystem).compactMap { entry in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return LogLine(
                date: log.date, category: log.category, level: name(of: log.level), message: log.composedMessage)
        }
    }

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
            "Log: this launch only, at most the last 24 hours",
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

    /// The archive's text files, redacted.
    static func files(summary: String, log: [LogLine], titles: [String]) -> [String: String] {
        let lines = log.map { "\($0.date.formatted(.iso8601)) \($0.level) \($0.category): \($0.message)\n" }
        return ["summary.txt": redact(summary, titles: titles), "log.txt": redact(lines.joined(), titles: titles)]
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
        // An atomic write replaces an earlier export only once the new archive is complete.
        try zipped.get().write(to: destination, options: .atomic)
    }
}
