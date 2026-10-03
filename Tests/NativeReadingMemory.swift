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
    /// Reader image completions by URL, as `ArticleRemoteImage` reports them.
    private var finishedImages: [String: Bool] = [:]

    func applicationDidFinishLaunching(_: Notification) {
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
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
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

        let before = footprint()
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
        // Two passes over the same stories: growth that repeats on the second pass would be a leak, not a cache.
        for pass in 0..<2 {
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
        let whileReading = footprint()
        current.close()
        window = nil
        try await Task.sleep(for: .seconds(3))
        sampler.cancel()
        let after = footprint()
        let complete = imageFailures == 0 && samples.allSatisfy { $0["document_ready"] as? Bool == true }
        let report: [String: Any] = [
            "complete": complete, "image_failures": imageFailures,
            "stories": stories.count, "feeds": feeds, "window_width": 1100, "window_height": 800,
            "footprint_before_reading_mib": mebibytes(before.current),
            "footprint_highest_sampled_mib": mebibytes(highest),
            "footprint_lifetime_peak_mib": mebibytes(max(whileReading.peak, after.peak)),
            "footprint_3s_after_close_mib": mebibytes(after.current),
            "footprint_after_each_pass_mib": afterPass,
            "per_story": samples,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "scope": "Production ArticleDetailView reading live panel stories one after another in one window, twice, with real extraction and image loading through the app's network client; isolated temporary storage and settings, AI off. Footprint includes the harness and live fetch setup. Not the shipping app delegate, the web view, or event overviews."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("reading-memory.json"))
        await database.close()
        // A run with missing documents or images is not the documented workload; keep its report but fail.
        guard complete else { throw Failure.incomplete }
    }

    private enum Failure: Error { case storage, feeds, incomplete }
}
