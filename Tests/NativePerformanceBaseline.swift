import AppKit
import SwiftUI
import Darwin
import Vision

/// A separate entry point: renders the production MainView with isolated, offline dependencies.
@main
struct NativePerformanceBaseline {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(1) }
        let app = NSApplication.shared
        let delegate = BaselineDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class BaselineDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await measure()
                NSApplication.shared.terminate(nil)
            } catch {
                fputs("Native baseline failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func measure() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("news-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "test.native.performance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        settings.feedURLs = ["https://baseline.example/feed"]
        let database = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
        let store = ArticleStore(database: database)
        await store.initialize()
        guard store.isReady else { throw Failure.storage }
        let now = Date()
        let articles = (0..<10_000).map { index in
            FeedArticle(title: index == 0 ? "Native baseline story Alpha" : "Native baseline story \(index)", link: "https://baseline.example/story/\(index)",
                        guid: "native-\(index)", description: "Controlled offline article for native rendering.",
                        pubDate: now.addingTimeInterval(-Double(index)), source: "Publisher \(index % 20)")
        }
        try await database.upsertArticles(articles)
        // A steady-state library: archived rows were matched by an earlier refresh.
        try await database.markEventMatchProcessed(articles.map(\.id), matcherVersion: EventMatcher.version, at: now)
        guard await store.refreshState() else { throw Failure.storage }
        let incoming = [FeedArticle(title: "Native refreshed story", link: "https://baseline.example/new",
                                   guid: "native-new", description: "A new article collected by the mocked feed.",
                                   pubDate: now.addingTimeInterval(1), source: "Publisher 0")]
        let manager = FeedManager(settings: settings, store: store, schedulesRefresh: false,
                                  fetchBatch: { urls, _ in urls.map { ($0, incoming, nil, nil) } })
        // Finish the initial catch-up before window timing; refresh still uses real collection/signposts.
        await manager.waitForEventClustering()
        let container = AppContainer(appSettings: settings, articleStore: store, feedManager: manager,
                                     themeManager: ThemeManager())
        defer { manager.stopBackgroundWork() }
        var samples: [Double] = []
        let firstTitle = articles.first!.title
        for index in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            let root = MainView()
                .environmentObject(container)
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(manager)
                .environmentObject(container.themeManager)
                .environmentObject(container.readManager)
                .environmentObject(container.savedStories)
                .defaultAppStorage(defaults)
            let view = NSHostingView(rootView: root)
            let current = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            current.isReleasedWhenClosed = false
            current.title = "News — isolated performance baseline"
            current.contentView = view
            window = current
            current.center()
            current.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            while true {
                try await Task.sleep(for: .milliseconds(10))
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure.render }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let capturedAt = ProcessInfo.processInfo.systemUptime
                guard let image = bitmap.cgImage else { throw Failure.render }
                // Verify actual pixels. Internal SwiftUI AX children omit lazily rendered cards.
                let found = try await Task.detached {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .fast
                    request.usesLanguageCorrection = false
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    return request.results?.contains { $0.topCandidates(1).first?.string == firstTitle } == true
                }.value
                if found {
                    samples.append((capturedAt - start) * 1000)
                    if index == 0 {
                        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.render }
                        try png.write(to: output.appendingPathComponent("first-card.png"))
                    }
                    break
                }
                guard capturedAt - start < 15 else { throw Failure.cardTimeout }
            }
            current.close()
            window = nil
        }
        let refreshStart = ProcessInfo.processInfo.systemUptime
        await manager.fetchFeedsAsync()
        let refreshMilliseconds = (ProcessInfo.processInfo.systemUptime - refreshStart) * 1000
        var expected = incoming[0]
        expected.identityFeedURL = settings.feedURLs[0]
        guard manager.articles.first?.id == expected.id, !manager.isAnyFeedLoading,
              try await database.counts().total == 10_001 else { throw Failure.storage }
        await manager.waitForEventClustering()
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure.memory }
        let report: [String: Any] = [
            "library_rows": 10_000, "final_library_rows": 10_001, "publishers": 20,
            "window_width": 1100, "window_height": 800, "snapshot_rows": 500,
            "window_to_first_card_bitmap_ms": samples, "refresh_one_mocked_feed_ms": refreshMilliseconds,
            "peak_process_rss_bytes": usage.ru_maxrss, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "scope": "Seeded native MainView, text-only synthetic articles, offline. Time to first sampled bitmap containing the title; includes prior failed capture/OCR polls but excludes successful OCR. Memory includes setup, SwiftUI and Vision. Not cold app launch, live network, or model timing."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-baseline.json"))
        await database.close()
    }

    private enum Failure: Error { case storage, cardTimeout, render, memory }
}
