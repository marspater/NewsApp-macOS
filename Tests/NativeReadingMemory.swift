import AppKit
import SwiftUI
import Darwin

/// A separate, opt-in entry point: reads live publisher stories in the production reader, with isolated storage and
/// settings, and records the process's physical footprint while extraction and images load.
@main
struct NativeReadingMemory {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(1) }
        let app = NSApplication.shared
        let delegate = ReadingDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {
            // Keeps the delegate alive for the whole run loop.
        }
    }
}

/// Current and lifetime-peak physical footprint, the measure Activity Monitor and jetsam use.
private func footprint() -> (current: UInt64, peak: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak))) : (0, 0)
}

private func mebibytes(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }

@MainActor
private final class ReadingDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var finishedWebLoads = 0
    private let fullApp = ProcessInfo.processInfo.environment["NEWS_READING_FULL_APP"] == "1"
    /// Reader image completions by URL, as `ArticleRemoteImage` reports them.
    private var finishedImages: [String: Bool] = [:]

    func applicationDidFinishLaunching(_: Notification) {
        if fullApp { CacheManager.shared.configureOfflineCache() }
        Task {
            do {
                try await measure()
                NSApplication.shared.terminate(nil)
            } catch {
                fputs("Reading memory measurement failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func measure() async throws {
        let output = fullApp ? FileManager.default.temporaryDirectory : URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("news-reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "test.native.reading.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        // Panel publishers that carry article images, so reading exercises image decoding as well as extraction.
        let feeds = ["bbc-world", "guardian-world", "al-jazeera", "dw-english", "cna"].compactMap { id in
            TensionMethodology.v1.panel.first { $0.catalogID == id }?.url
        }
        settings.feedURLs = feeds
        let database = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
        let store = ArticleStore(database: database)
        await store.initialize()
        guard store.isReady else { throw Failure.storage }
        // Exactly 20 distinct stories, four per feed where possible, so every run is the same workload.
        var perFeed: [[FeedArticle]] = []
        for result in await FeedFetcher().fetchAllFeeds(urls: feeds) {
            let fetched = (result.articles ?? []).map { article in
                var article = article
                article.identityFeedURL = result.urlString
                return article
            }
            _ = await store.batchUpsert(articles: fetched, feedUrl: result.urlString, validators: result.validators)
            perFeed.append(fetched)
        }
        var stories: [FeedArticle] = []
        var round = 0
        while stories.count < 20, perFeed.contains(where: { $0.count > round }) {
            for items in perFeed where items.count > round && stories.count < 20 && !stories.contains(where: { $0.id == items[round].id }) {
                stories.append(items[round])
            }
            round += 1
        }
        guard await store.refreshState(), stories.count == 20 else { throw Failure.feeds }
        let manager = FeedManager(settings: settings, store: store, schedulesRefresh: false, fetchBatch: { _, _ in [] })
        let container = AppContainer(appSettings: settings, articleStore: store, feedManager: manager,
                                     themeManager: ThemeManager())
        defer { manager.stopBackgroundWork() }
        // The manager clusters the newly stored stories on start; finish that first so only reading is measured.
        await manager.waitForEventClustering()

        let libraryRows = try await database.counts().total
        let before = footprint()
        let initialCacheUsage = URLCache.shared.currentMemoryUsage
        var webSamples: [[String: Any]] = []
        var overviewSamples: [[String: Any]] = []
        var webLoading = true
        var webError: String?
        var highest = before.current
        let sampler = Task {
            while !Task.isCancelled {
                highest = max(highest, footprint().current)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        func reader(_ article: FeedArticle) -> some View {
            // A new identity per story, as navigation creates, so each opening starts its own extraction and images.
            ArticleDetailView(article: article, allArticles: stories, path: .constant(NavigationPath()))
                .id(article.id)
                .environmentObject(container)
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(manager)
                .environmentObject(container.themeManager)
                .environmentObject(container.readManager)
                .environmentObject(container.savedStories)
                .defaultAppStorage(defaults)
        }
        let view = NSHostingView(rootView: AnyView(EmptyView()))
        let current = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        current.isReleasedWhenClosed = false
        current.title = "News — isolated reading memory"
        current.contentView = view
        window = current
        current.center()
        current.orderFront(nil)

        var samples: [[String: Any]] = []
        var imageFailures = 0
        let observer = NotificationCenter.default.addObserver(forName: .readerImageFinished, object: nil, queue: .main) { note in
            guard let url = (note.object as? URL)?.absoluteString else { return }
            let success = note.userInfo?["success"] as? Bool ?? false
            MainActor.assumeIsolated { self.finishedImages[url] = success }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var afterPass: [Double] = []
        // Repeated passes over the same stories (two by default): growth that repeats on every pass would be a leak, not
        // a cache that fills once.
        let passes = max(2, Int(ProcessInfo.processInfo.environment["NEWS_READING_PASSES"] ?? "") ?? 2)
        for pass in 0..<passes {
        for story in stories {
            finishedImages.removeAll()
            view.rootView = AnyView(reader(story))
            let start = ProcessInfo.processInfo.systemUptime
            // Ready once a publisher document is stored, from the feed or from extraction; failures time out to the fallback.
            var ready = false
            while ProcessInfo.processInfo.systemUptime - start < 15 {
                if store.articles.first(where: { $0.id == story.id })?.readerDocument?.hasPublisherText == true { ready = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            // Wait until the reader itself reports each image decoded (or failed), so a slow image is measured or
            // reported instead of being cancelled unnoticed when the next story replaces the view.
            let stored = store.articles.first { $0.id == story.id }
            let document = stored?.readerDocument
            let imageURLs = Set((document?.blocks.compactMap(\.imageURL) ?? []) + [document?.selectedImage(fallback: stored?.imageUrl) ?? (document == nil ? stored?.imageUrl : nil)].compactMap { $0 })
            let imageStart = ProcessInfo.processInfo.systemUptime
            while !imageURLs.isSubset(of: finishedImages.keys), ProcessInfo.processInfo.systemUptime - imageStart < 15 {
                try await Task.sleep(for: .milliseconds(100))
            }
            let loaded = imageURLs.filter { finishedImages[$0] == true }.count
            imageFailures += imageURLs.count - loaded
            try await Task.sleep(for: .milliseconds(500))
            samples.append(["pass": pass + 1, "source": story.source, "document_ready": ready,
                            "images": imageURLs.count, "images_loaded": loaded,
                            "blocks": document?.blocks.count ?? 0,
                            "figures": document?.blocks.filter { $0.kind == .figure }.count ?? 0,
                            "seconds": ((ProcessInfo.processInfo.systemUptime - start) * 10).rounded() / 10,
                            "footprint_mib": mebibytes(footprint().current)])
        }
            afterPass.append(mebibytes(footprint().current))
        }
        if fullApp {
            guard URLCache.shared.memoryCapacity == 64 * 1024 * 1024,
                  URLCache.shared.diskCapacity == 512 * 1024 * 1024 else { throw Failure.incomplete }
            // These are controlled timing inputs, not claims that unrelated live stories form one event.
            let coordinator = OverviewGenerationCoordinator(store: store, queue: EnrichmentQueue(store: store))
            let members = Array(store.articles.filter { $0.readerDocument?.hasPublisherText == true }.prefix(3))
            guard members.count == 3 else { throw Failure.incomplete }
            for index in 0..<10 {
                let start = ProcessInfo.processInfo.systemUptime
                guard let overview = await coordinator.requestOverview(
                    eventID: "workload-\(index)", eventTitle: members[0].title,
                    membershipVersion: 1, articles: members, priority: .visibleEvent),
                    !overview.citations.isEmpty,
                    try await store.fetchEventOverview(eventID: overview.eventID)?.id == overview.id
                else { throw Failure.incomplete }
                let generated = ProcessInfo.processInfo.systemUptime
                view.rootView = AnyView(EventOverviewReaderView(overview: overview, memberArticles: members,
                    onSelectArticle: { _ in }, onSelectCitation: { _, _ in }).id(overview.id))
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure.incomplete }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if index == 0, let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: output.appendingPathComponent("overview.png"))
                }
                overviewSamples.append(["sample": index + 1,
                    "generation_and_persistence_ms": (generated - start) * 1000,
                    "view_capture_ms": (ProcessInfo.processInfo.systemUptime - generated) * 1000,
                    "citations": overview.citations.count, "footprint_mib": mebibytes(footprint().current)])
                try await Task.sleep(for: .milliseconds(500))
            }
            let webObserver = NotificationCenter.default.addObserver(forName: Notification.Name("workloadWebFinished"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.finishedWebLoads += 1 }
            }
            defer { NotificationCenter.default.removeObserver(webObserver) }
            // Exercise the publisher pages for the same live reading selection, through the protected Web view.
            for (index, story) in stories.prefix(5).enumerated() {
                guard let url = URL(string: story.link), url.scheme == "https" else { throw Failure.incomplete }
                finishedWebLoads = 0
                webLoading = true
                webError = nil
                let start = ProcessInfo.processInfo.systemUptime
                view.rootView = AnyView(ArticleWebView(url: url,
                    isLoading: Binding(get: { webLoading }, set: { webLoading = $0 }),
                    canGoBack: .constant(false), canGoForward: .constant(false),
                    loadError: Binding(get: { webError }, set: { webError = $0 })).id(index))
                while webLoading, ProcessInfo.processInfo.systemUptime - start < 30 {
                    try await Task.sleep(for: .milliseconds(50))
                }
                let seconds = ProcessInfo.processInfo.systemUptime - start
                let loaded = !webLoading && webError == nil && finishedWebLoads > 0
                view.layoutSubtreeIfNeeded()
                webSamples.append(["sample": index + 1, "source": story.source, "loaded": loaded, "seconds": seconds,
                    "footprint_mib": mebibytes(footprint().current)])
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        let whileReading = footprint()
        if fullApp {
            view.rootView = AnyView(EmptyView())
            view.layoutSubtreeIfNeeded()
        }
        current.close()
        window = nil
        try await Task.sleep(for: .seconds(3))
        sampler.cancel()
        let after = footprint()
        let complete = imageFailures == 0 && samples.allSatisfy { $0["document_ready"] as? Bool == true }
            && (!fullApp || (webSamples.count == 5 && webSamples.allSatisfy { $0["loaded"] as? Bool == true } && overviewSamples.count == 10))
        let report: [String: Any] = [
            "complete": complete, "full_app_components": fullApp,
            "web": webSamples, "overviews": overviewSamples,
            "url_cache_memory_capacity_bytes": URLCache.shared.memoryCapacity,
            "url_cache_memory_usage_bytes": URLCache.shared.currentMemoryUsage,
            "url_cache_memory_usage_before_reading_bytes": initialCacheUsage,
            "url_cache_disk_capacity_bytes": URLCache.shared.diskCapacity, "image_failures": imageFailures,
            "stories": stories.count, "library_rows": libraryRows, "feeds": feeds, "window_width": 1100, "window_height": 800,
            "footprint_before_reading_mib": mebibytes(before.current),
            "footprint_highest_sampled_mib": mebibytes(highest),
            "footprint_lifetime_peak_mib": mebibytes(max(whileReading.peak, after.peak)),
            "footprint_3s_after_close_mib": mebibytes(after.current),
            "footprint_after_each_pass_mib": afterPass,
            "per_story": samples,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "scope": "Production ArticleDetailView reading live panel stories one after another in one window, twice, with real extraction and image loading through the app's network client; isolated temporary storage and settings, AI off. Footprint includes the harness and live fetch setup. " + (fullApp ? "Combined sandboxed bundle uses production CacheManager configuration, ten controlled deterministic overview generation/persistence/view captures and five protected public HTTPS Web view loads. Excludes notification authorization, NewsApp scenes, memory pressure and WebKit auxiliary-process footprint." : "Not the shipping app delegate, the web view, or event overviews.")
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("reading-memory.json"))
        if fullApp {
            print("WORKLOAD_REPORT=" + data.base64EncodedString())
            print("WORKLOAD_IMAGE=" + output.appendingPathComponent("overview.png").path)
        }
        await database.close()
        // A run with missing documents or images is not the documented workload; keep its report but fail.
        guard complete else { throw Failure.incomplete }
    }

    private enum Failure: Error { case storage, feeds, incomplete }
}
