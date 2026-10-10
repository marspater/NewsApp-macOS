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
        // Compare the unmodified text baseline with the phase-six lead on the
        // same machine: NEWS_NATIVE_LEAD_STORY=1, no network or production data.
        let leadScenario = ProcessInfo.processInfo.environment["NEWS_NATIVE_LEAD_STORY"] == "1"
        let imageProbe = NativeLeadImageProbe()
        let articles = (0..<10_000).map { index -> FeedArticle in
            var story = FeedArticle(
                title: index == 0 ? "Native baseline story Alpha" : "Native baseline story \(index)",
                link: "https://baseline.example/story/\(index)",
                guid: "native-\(index)", description: "Controlled offline article for native rendering.",
                pubDate: now.addingTimeInterval(-Double(index)), source: "Publisher \(index % 20)"
            )
            if leadScenario && index == 0 { story.imageUrl = "https://images.example/native-lead.jpg" }
            return story
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
        var scrollFrameSamples: [Double] = []
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
                .environment(\.readerImageLoader) { url in try await imageProbe.load(url) }
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
            // A captured-frame sample after a bounded scroll. This is a
            // render/readback upper bound, not a GPU frame-time or FPS claim.
            guard let scroller = Self.detailScroller(in: view) else { throw Failure.scrollCaptureUnavailable }
            for step in 1...3 {
                let scrollStarted = ProcessInfo.processInfo.systemUptime
                let clip = scroller.contentView
                let maximumY = max(0, (scroller.documentView?.bounds.height ?? 0) - clip.bounds.height)
                guard maximumY > 0 else { throw Failure.scrollCaptureUnavailable }
                clip.scroll(to: NSPoint(x: 0, y: min(CGFloat(step) * 300, maximumY)))
                scroller.reflectScrolledClipView(clip)
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                guard let frame = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { throw Failure.render }
                view.cacheDisplay(in: view.bounds, to: frame)
                scrollFrameSamples.append((ProcessInfo.processInfo.systemUptime - scrollStarted) * 1000)
            }
            current.close()
            window = nil
        }
        guard scrollFrameSamples.count == 15 else { throw Failure.scrollCaptureUnavailable }
        if leadScenario {
            if #available(macOS 26.0, *) {
                guard imageProbe.requests > 0 else { throw Failure.heroNotLoaded }
            }
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
            "window_to_first_card_bitmap_ms": samples,
            "scroll_frame_capture_ms": scrollFrameSamples,
            "scroll_frame_count": scrollFrameSamples.count,
            "lead_story_scenario": leadScenario,
            "mock_lead_image_requests": imageProbe.requests,
            "refresh_one_mocked_feed_ms": refreshMilliseconds,
            "peak_process_rss_bytes": usage.ru_maxrss, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "scope": "Seeded native MainView, offline synthetic articles; optionally a mock publisher image on first Today entry. First-card samples measure time to bitmap containing the title (prior failed capture/OCR polls included, successful OCR excluded). Scroll samples measure synchronous clip move/layout/display/bitmap readback, not GPU latency or FPS. Memory includes setup, SwiftUI and Vision. Not cold launch, network or model timing."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-baseline.json"))
        await database.close()
    }

    /// SwiftUI's detail list is the widest scroll view; the sidebar is narrower.
    /// If a future SwiftUI release does not expose an NSScrollView, the
    /// benchmark fails rather than presenting an unmeasured run as a pass.
    private static func detailScroller(in root: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.documentView != nil {
                found.append(scroll)
            }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return found.filter { $0.bounds.width >= 300 }
            .max { $0.bounds.width < $1.bounds.width }
    }

    private enum Failure: Error { case storage, cardTimeout, render, memory, heroNotLoaded, scrollCaptureUnavailable }
}

/// The image variant still uses ArticleRemoteImage and the production decoded
/// cache. Only its injected loader is synthetic; it never makes a network call.
@MainActor
private final class NativeLeadImageProbe {
    private(set) var requests = 0

    func load(_ url: URL) throws -> CGImage {
        guard url.host == "images.example" else { throw URLError(.badURL) }
        requests += 1
        guard let context = CGContext(
            data: nil, width: 1200, height: 680, bitsPerComponent: 8,
            bytesPerRow: 4800, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw URLError(.cannotDecodeContentData) }
        context.setFillColor(CGColor(gray: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 680))
        guard let result = context.makeImage() else { throw URLError(.cannotDecodeContentData) }
        return result
    }
}
