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
import Combine
import Darwin
import SwiftUI

/// What background work costs the list and the reader (#778), with no window: the production MainView is hosted
/// offscreen over a seeded temporary library (29 feeds, 609 stories in 24 hours, 60 three-report events) and updated
/// every 16 ms like a 60 Hz display, through an enrichment burst and a feed refresh with Today showing, then again with
/// a story open. It reports store and FeedManager publications, main-thread CPU time and the time to draw a scrolled
/// frame. With `NEWS_NATIVE_BODY_COUNTS=1` the script compiles a staged copy of the sources that ticks `BodyCount` in
/// each counted view body, the list's page fetch and the reader's revision query, and the report adds those counts.
/// Run with `NEWS_NATIVE_BODY_COUNTS=1 NEWS_NATIVE_HARNESS=Tests/ListInvalidationBaseline.swift
/// script/native_performance_baseline.sh DIR`; `NEWS_INVALIDATION_GRID=1` measures the grid layout instead of the list.
@MainActor
enum BodyCount {
    static var counts: [String: Int] = [:]
    static func tick(_ name: String) { counts[name, default: 0] += 1 }
}

@main
struct ListInvalidationBaseline {
    @MainActor
    static func main() async {
        let output = URL(
            fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        // MainView reaches NSApp (the Dock badge); a prohibited app has no Dock icon, menu bar or window.
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try await run(into: output)
            exit(0)
        } catch {
            fputs("List invalidation baseline failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static let feeds = (0..<29).map { "https://feed\($0).example/rss" }
    static let counted = [
        "MainView", "SidebarView", "ArticleListView", "ArticleCardView", "EventCardView", "ArticleDetailView",
        "ListFetch", "ReaderRevisionQuery",
    ]

    @MainActor
    static func run(into output: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-invalidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = testDefaultsSuite("test.native.invalidation")
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            removeTestDefaults(suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let grid = ProcessInfo.processInfo.environment["NEWS_INVALIDATION_GRID"] == "1"
        defaults.set(false, forKey: AppSettings.showsDockBadgeKey)
        defaults.set(grid, forKey: "articleGridLayout")
        let settings = AppSettings(defaults: defaults)
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        settings.feedURLs = feeds
        let database = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
        let store = ArticleStore(database: database)
        await store.initialize()
        guard store.isReady else { throw Failure.storage }

        // 21 unclassified stories per feed, interleaved in time over the last 24 hours, two of three with an image.
        let now = Date()
        for (feed, url) in feeds.enumerated() {
            let batch = (0..<21).map { story($0 * feeds.count + feed, feed: feed, now: now) }
            try await database.upsertArticles(batch, feedUrl: url)
        }
        let stored = try await database.fetchArticles(limit: nil)
        guard stored.count == 609 else { throw Failure.storage }
        for first in stride(from: 0, to: 360, by: 6) {
            let outcome = try await database.applyEventMatch(
                stored[first].id, .create(with: [stored[first + 2].id, stored[first + 4].id]),
                matcherVersion: EventMatcher.version, at: now)
            guard case .created = outcome else { throw Failure.storage }
        }
        try await database.markEventMatchProcessed(stored.map(\.id), matcherVersion: EventMatcher.version, at: now)
        // The story the reader opens has a stored publisher document, so it renders without a network request.
        let opened = stored[1]
        let paragraphs = (1...14).map {
            "Paragraph \($0) of the opened story carries enough publisher text to lay out several lines in the reading column."
        }
        try await database.updateEnrichment(
            articleId: opened.id,
            update: .init(
                content: paragraphs.joined(separator: "\n\n"),
                readerDocument: ReaderDocument(
                    blocks: paragraphs.map { ReaderBlock(kind: .paragraph, text: $0) }, isComplete: true)))
        guard await store.refreshState() else { throw Failure.storage }

        let rounds = RefreshRounds()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                let round = await rounds.next()
                return urls.enumerated().map { feed, url in
                    let fresh = (0..<2).map { item in
                        var article = story(10_000 * round + feed * 2 + item, feed: feed, now: Date())
                        article.identityFeedURL = url
                        return article
                    }
                    return (url, fresh, nil, nil)
                }
            },
            allowsBackgroundWork: { false })
        defer { manager.stopBackgroundWork() }
        let themes = ThemeManager(defaults: defaults)
        themes.autoHideRead = true
        let container = AppContainer(
            appSettings: settings, articleStore: store, feedManager: manager, themeManager: themes)
        let root = MainView()
            .environmentObject(container)
            .environmentObject(settings)
            .environmentObject(store)
            .environmentObject(manager)
            .environmentObject(themes)
            .environmentObject(container.readManager)
            .environmentObject(container.savedStories)
            .defaultAppStorage(defaults)
            .environment(\.readerImageLoader) { _ in try OfflineImage.make() }
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)

        // Launch: the list settles, then runs the launch refresh and catch-up clustering.
        try await pump(view, timeout: 30) { manager.lastRefreshCompletedAt != nil && !manager.isAnyFeedLoading }
        await manager.waitForEventClustering()
        try await pump(view, seconds: 1.5)
        let bodyCounts = ProcessInfo.processInfo.environment["NEWS_NATIVE_BODY_COUNTS"] == "1"
        if bodyCounts, let missing = counted.prefix(5).first(where: { BodyCount.counts[$0, default: 0] == 0 }) {
            throw Failure.counterMissing(missing)
        }

        let queue = EnrichmentQueue(store: store)
        let unclassified = try await database.fetchArticles(limit: nil).filter { $0.category == nil }
        guard unclassified.count >= 300 else { throw Failure.storage }
        var phases: [[String: Any]] = []
        phases.append(
            try await measure("list-enrichment-150", view: view, store: store, manager: manager) {
                try await enrich(Array(unclassified.prefix(150)), queue: queue, view: view)
            })
        phases.append(
            try await measure("list-refresh-29-feeds", view: view, store: store, manager: manager) {
                try await refresh(manager, view: view)
            })
        let scroll = try await scrollFrames(view)

        store.pendingNavigation = .init(articleID: opened.id, link: "")
        try await pump(view, timeout: 10) { store.pendingNavigation == nil }
        try await pump(view, seconds: 1.5)
        if bodyCounts, BodyCount.counts["ArticleDetailView", default: 0] == 0 {
            throw Failure.counterMissing("ArticleDetailView")
        }
        phases.append(
            try await measure("reader-enrichment-150", view: view, store: store, manager: manager) {
                try await enrich(Array(unclassified.dropFirst(150).prefix(150)), queue: queue, view: view)
            })
        phases.append(
            try await measure("reader-refresh-29-feeds", view: view, store: store, manager: manager) {
                try await refresh(manager, view: view)
            })

        let report: [String: Any] = [
            "layout": grid ? "grid" : "list", "window_points": [1100, 800], "feeds": feeds.count,
            "seeded_stories": stored.count, "seeded_events": 60, "body_counts": bodyCounts,
            "phases": phases, "scroll_frame_ms": scroll,
            "scope":
                "Offscreen NSHostingView of MainView, updated every 16 ms; counts are per phase, CPU is the main thread's user and system time over the phase including a settle after the work; scroll frames are synchronous layout and bitmap readback of the visible list, an upper bound rather than GPU frame time.",
        ]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("invalidation-\(grid ? "grid" : "list").json"))
        for phase in phases {
            print(phase.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        print("scroll_frame_ms=\(scroll)")
        await database.close()
    }

    static func story(_ n: Int, feed: Int, now: Date) -> FeedArticle {
        var article = FeedArticle(
            title: "Offline report \(n) on the measured desk of publisher \(feed)",
            link: "https://feed\(feed).example/story/\(n)", guid: "invalidation-\(n)",
            description: "Summary \(n): "
                + String(repeating: "a controlled offline sentence for card layout. ", count: 4),
            pubDate: now.addingTimeInterval(-Double(n % 10_000) * 140), source: "Publisher \(feed)")
        if n % 3 != 0 { article.imageUrl = "https://images.example/\(n).jpg" }
        return article
    }

    /// Classifies stories through the production queue and waits until no job is left running.
    @MainActor
    static func enrich(_ articles: [FeedArticle], queue: EnrichmentQueue, view: NSView) async throws {
        await queue.enqueue(articles: articles, priority: .background)
        let start = ProcessInfo.processInfo.systemUptime
        while await queue.activeJobCount() > 0 {
            try await Task.sleep(for: .milliseconds(16))
            view.layoutSubtreeIfNeeded()
            guard ProcessInfo.processInfo.systemUptime - start < 60 else { throw Failure.timeout }
        }
        try await pump(view, seconds: 1.5)
    }

    @MainActor
    static func refresh(_ manager: FeedManager, view: NSView) async throws {
        let finished = Finished()
        Task {
            await manager.fetchFeedsAsync()
            finished.value = true
        }
        try await pump(view, timeout: 60) { finished.value }
        try await pump(view, seconds: 1.5)
    }

    /// One phase: publications, counted evaluations and main-thread CPU time.
    @MainActor
    static func measure(
        _ name: String, view: NSView, store: ArticleStore, manager: FeedManager, work: () async throws -> Void
    ) async throws -> [String: Any] {
        var articles = 0
        var revisions = 0
        var storeChanges = 0
        var managerChanges = 0
        let observations = [
            store.$articles.dropFirst().sink { _ in articles += 1 },
            store.$revision.dropFirst().sink { _ in revisions += 1 },
            store.objectWillChange.sink { _ in storeChanges += 1 },
            manager.objectWillChange.sink { _ in managerChanges += 1 },
        ]
        let before = BodyCount.counts
        let cpu = mainThreadCPUMilliseconds()
        let start = ProcessInfo.processInfo.systemUptime
        try await work()
        var phase: [String: Any] = [
            "phase": name,
            "main_thread_cpu_ms": Int(mainThreadCPUMilliseconds() - cpu),
            "wall_ms": Int((ProcessInfo.processInfo.systemUptime - start) * 1000),
            "store_articles_publications": articles, "store_revision_bumps": revisions,
            "store_object_will_change": storeChanges, "feed_manager_object_will_change": managerChanges,
        ]
        for name in counted where !BodyCount.counts.isEmpty {
            phase[name] = BodyCount.counts[name, default: 0] - before[name, default: 0]
        }
        for observation in observations { observation.cancel() }
        return phase
    }

    /// Drives SwiftUI updates the way a 60 Hz display does until `done` holds.
    @MainActor
    static func pump(_ view: NSView, timeout: Double, until done: () -> Bool) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        repeat {
            try await Task.sleep(for: .milliseconds(16))
            view.layoutSubtreeIfNeeded()
        } while !done() && ProcessInfo.processInfo.systemUptime - start < timeout
        guard done() else { throw Failure.timeout }
    }

    @MainActor
    static func pump(_ view: NSView, seconds: Double) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        try await pump(view, timeout: seconds + 1) { ProcessInfo.processInfo.systemUptime >= end }
    }

    /// Twenty 120-point scroll steps of the story list, each laid out and drawn to a bitmap.
    @MainActor
    static func scrollFrames(_ view: NSView) async throws -> [String: Double] {
        var scrollViews: [NSScrollView] = []
        func walk(_ node: NSView) {
            if let scroll = node as? NSScrollView, scroll.documentView != nil { scrollViews.append(scroll) }
            node.subviews.forEach(walk)
        }
        walk(view)
        guard let scroller = scrollViews.max(by: { $0.bounds.width < $1.bounds.width }) else {
            throw Failure.scrollUnavailable
        }
        var samples: [Double] = []
        for step in 1...20 {
            let clip = scroller.contentView
            let start = ProcessInfo.processInfo.systemUptime
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 120))
            scroller.reflectScrolledClipView(clip)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure.render }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await Task.sleep(for: .milliseconds(16))
        }
        let sorted = samples.sorted()
        return [
            "median": (sorted[9] + sorted[10]) / 2, "mean": samples.reduce(0, +) / Double(samples.count),
            "max": sorted.last ?? 0,
        ]
    }

    static func mainThreadCPUMilliseconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let seconds = Double(info.user_time.seconds + info.system_time.seconds)
        let micros = Double(info.user_time.microseconds + info.system_time.microseconds)
        return seconds * 1000 + micros / 1000
    }

    enum Failure: Error {
        case storage, timeout, render, scrollUnavailable
        case counterMissing(String)
    }
}

@MainActor
private final class Finished {
    var value = false
}

private actor RefreshRounds {
    private var round = 0
    func next() -> Int {
        round += 1
        return round
    }
}

/// A plain gray card image, so cards draw an image without a network request.
private enum OfflineImage {
    static func make() throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: 600, height: 340, bitsPerComponent: 8, bytesPerRow: 2400,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw URLError(.cannotDecodeContentData) }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 340))
        guard let image = context.makeImage() else { throw URLError(.cannotDecodeContentData) }
        return image
    }
}
