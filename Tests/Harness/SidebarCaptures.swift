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
import SwiftUI

/// The sidebar without a window or Screen Recording: the Unread badge past the cap, a user section and the Sections
/// header with its New Smart Binder button, in light and dark. It also measures where the badge and the button end, so
/// their alignment is a number and not an impression. Run with `NEWS_NATIVE_HARNESS=Tests/Harness/SidebarCaptures.swift
/// script/native_performance_baseline.sh DIR`. The library is in memory and the stories are fictional.
@main
struct SidebarCaptures {
    static func main() async {
        let output = URL(
            fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let context = await seed()
        let failures = await MainActor.run { capture(context, into: output) }
        print(failures == 0 ? "✅ Captures written to \(output.path)" : "❌ \(failures) captures failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// The stores the sidebar reads, over an in-memory library and a preview-only defaults domain.
    private struct Context {
        let settings: AppSettings
        let store: ArticleStore
        let feedManager: FeedManager
        let savedStories: SavedStoriesManager
        let readManager: ReadManager
        let themeManager: ThemeManager
    }

    /// Past the badge cap: 120 unread fictional stories, and one section of the reader's own.
    @MainActor
    private static func seed() async -> Context {
        let suite = "com.marspater.news.sidebar-captures"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: AppSettings.aiEnabledKey)
        let settings = AppSettings(defaults: defaults)
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.waitForStartup()
        let feedManager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { _, _ in [] },
            notifyBatch: { _, _ in
                // The harness posts no notifications.
            },
            allowsBackgroundWork: { false })
        let stories = (0..<120).map { index in
            FeedArticle(
                title: "Fictional story \(index)", link: "https://example.com/story-\(index)", guid: "story-\(index)",
                description: "", pubDate: Date(timeIntervalSince1970: 1_793_372_400 - Double(index) * 60),
                source: "Example Wire \(index % 7)")
        }
        try? await store.database.upsertArticles(stories)
        await store.refreshState()
        feedManager.addSection("Politics")
        return Context(
            settings: settings, store: store, feedManager: feedManager,
            savedStories: SavedStoriesManager(articleStore: store), readManager: ReadManager(articleStore: store),
            themeManager: ThemeManager(defaults: defaults))
    }

    @MainActor
    private static func capture(_ context: Context, into output: URL) -> Int {
        let size = CGSize(width: 240, height: 520)
        var failures = 0
        for (name, appearanceName, scheme) in [
            ("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark),
        ] {
            let appearance = NSAppearance(named: appearanceName) ?? NSAppearance.currentDrawing()
            let hosting = NSHostingView(
                rootView: SidebarView(selectedTopic: .constant("Briefing"), mastheadNotice: .constant(nil))
                    .environmentObject(context.settings).environmentObject(context.store)
                    .environmentObject(context.feedManager).environmentObject(context.savedStories)
                    .environmentObject(context.readManager).environmentObject(context.themeManager)
                    .environment(\.colorScheme, scheme)
                    .frame(width: size.width, height: size.height))
            hosting.appearance = appearance
            hosting.frame = NSRect(origin: .zero, size: size)
            // The sidebar list draws only inside a window; this one is never ordered on screen.
            let window = NSWindow(
                contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = hosting
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            var rendered: NSBitmapImageRep?
            appearance.performAsCurrentDrawingAppearance {
                hosting.layoutSubtreeIfNeeded()
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                rendered = bitmap
            }
            window.contentView = nil
            guard let bitmap = rendered else {
                print("  blank: sidebar-\(name)")
                failures += 1
                continue
            }
            do {
                try write(bitmap, to: output.appendingPathComponent("sidebar-\(name).png"))
            } catch {
                print("  write failed: sidebar-\(name): \(error.localizedDescription)")
                failures += 1
            }
            failures += report(bitmap, name: name, width: size.width)
        }
        return failures
    }

    /// The text lines of the sidebar as bands of rows that hold dark ink, each with its first and last inked column in
    /// points. The Unread row's badge and the Sections header's button are the last ink of their lines.
    private static func report(_ bitmap: NSBitmapImageRep, name: String, width: CGFloat) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / width
        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            func luminance(_ color: NSColor) -> CGFloat {
                0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
            }
            // Ink differs from the sidebar's own background by a wide margin in either appearance.
            let background = bitmap.colorAt(x: 2, y: y)?.usingColorSpace(.deviceRGB)
            return abs(luminance(color) - (background.map(luminance) ?? 0.5)) > 0.2
        }
        var bands: [(top: Int, bottom: Int, first: Int, last: Int)] = []
        var current: (top: Int, bottom: Int, first: Int, last: Int)?
        for y in 0..<bitmap.pixelsHigh {
            var first = Int.max
            var last = -1
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) where isInk(x, y) {
                first = min(first, x)
                last = max(last, x)
            }
            if last >= 0 {
                if var band = current {
                    band.bottom = y
                    band.first = min(band.first, first)
                    band.last = max(band.last, last)
                    current = band
                } else {
                    current = (y, y, first, last)
                }
            } else if let band = current {
                bands.append(band)
                current = nil
            }
        }
        if let band = current { bands.append(band) }
        for band in bands {
            print(
                String(
                    format: "  %@ y %.0f–%.0f pt  ink %.1f–%.1f pt", name, Double(band.top) / scale,
                    Double(band.bottom) / scale, Double(band.first) / scale, Double(band.last) / scale))
        }
        // The Unread row is the third line; the Sections header is the third header (their text starts at 15 pt, the
        // rows' symbols after it). The badge and the button end their lines.
        let headers = bands.filter { $0.first >= Int(14 * scale) && $0.first <= Int(16 * scale) }
        guard bands.count > 2, headers.count == 3 else {
            print("  \(name): expected the Unread row and three headers, found \(bands.count) lines")
            return 1
        }
        let badge = Double(bands[2].last) / scale
        let button = Double(headers[2].last) / scale
        print(
            String(
                format: "  %@ badge ends %.1f pt, button ends %.1f pt, off by %.1f pt", name, badge, button,
                button - badge))
        return abs(button - badge) <= 1.0 ? 0 : 1
    }

    private static func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try png.write(to: url)
    }
}
