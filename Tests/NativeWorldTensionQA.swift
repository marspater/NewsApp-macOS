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
import QuartzCore
import SwiftUI

/// Run through NEWS_NATIVE_HARNESS=Tests/NativeWorldTensionQA.swift script/native_performance_baseline.sh.
/// Uses temporary storage/defaults and synthetic headlines; never reads the installed app's library.
@main
struct NativeWorldTensionQA {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = WorldTensionQADelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class WorldTensionQADelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var intervals: [Double] = []
    private var previousTimestamp: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await run()
                NSApplication.shared.terminate(nil)
            } catch {
                fputs("World Tension QA failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        if let previousTimestamp { intervals.append((link.timestamp - previousTimestamp) * 1000) }
        previousTimestamp = link.timestamp
    }

    private func snapshot(_ view: NSView, at url: URL) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw QAError.render }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw QAError.render }
        try png.write(to: url)
    }

    private func show<V: View>(_ root: V, size: NSSize, title: String) -> NSHostingView<V> {
        let view = NSHostingView(rootView: root)
        let current = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        current.isReleasedWhenClosed = false
        current.contentView = view
        current.title = title
        current.center()
        current.makeKeyAndOrderFront(nil)
        window?.close()
        window = current
        NSApplication.shared.activate()
        return view
    }

    private func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("world-tension-qa-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = testDefaultsSuite("test.world-tension.qa")
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            removeTestDefaults(suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        settings.notificationsEnabled = false
        settings.aiEnabled = false
        settings.feedURLs = []
        let database = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
        let store = ArticleStore(database: database)
        await store.initialize()
        guard store.isReady else { throw QAError.storage }
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { _, _ in [] })
        defer { manager.stopBackgroundWork() }
        let container = AppContainer(
            appSettings: settings, articleStore: store,
            feedManager: manager, themeManager: ThemeManager())
        let settingsView = show(
            SettingsView()
                .environmentObject(settings).environmentObject(store).environmentObject(manager)
                .environmentObject(container.themeManager).environmentObject(container.readManager)
                .defaultAppStorage(defaults), size: NSSize(width: 720, height: 560),
            title: "News — isolated Settings QA")
        try await Task.sleep(for: .milliseconds(500))
        let originalFrame = window!.frame
        for pass in 0..<3 {
            for pane in SettingsPane.allCases {
                defaults.set(pane.rawValue, forKey: SettingsView.lastPaneStorageKey)
                try await Task.sleep(for: .milliseconds(150))
                settingsView.layoutSubtreeIfNeeded()
                guard window!.frame.size == originalFrame.size,
                    settingsView.frame.size == NSSize(width: 720, height: 560)
                else { throw QAError.settingsShrank }
                if pass == 0 {
                    try snapshot(settingsView, at: output.appendingPathComponent("settings-\(pane.rawValue).png"))
                }
            }
        }
        print("Settings: 27 tab changes retained 720 × 560 content bounds")
        let illustrations = HStack(spacing: AppSpacing.lg) {
            ForEach(TensionLevel.allCases, id: \.self) { level in
                VStack {
                    TensionGlyph(level: level)
                    Text(level.rawValue).font(AppTypography.callout)
                }
            }
        }.padding(AppLayout.pageInset).frame(maxWidth: .infinity, maxHeight: .infinity).background(AppColor.background)
        let states = show(
            AnyView(illustrations.environment(\.scenePhase, .active)),
            size: NSSize(width: 620, height: 180), title: "News — five World Tension states")
        states.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(300))
        try snapshot(states, at: output.appendingPathComponent("states-light.png"))
        states.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(200))
        try snapshot(states, at: output.appendingPathComponent("states-dark.png"))
        var cadence: [[String: Any]] = []
        for requested in [60, 120] {
            intervals = []
            previousTimestamp = nil
            let link = states.displayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(requested), maximum: Float(requested), preferred: Float(requested))
            link.add(to: .main, forMode: .common)
            try await Task.sleep(for: .seconds(3))
            link.invalidate()
            let sorted = intervals.filter { $0 > 0 }.sorted()
            guard !sorted.isEmpty else { throw QAError.noFrames }
            cadence.append([
                "requested_hz": requested, "screen_maximum_hz": window!.screen!.maximumFramesPerSecond,
                "samples": sorted.count, "callback_interval_p50_ms": sorted[sorted.count / 2],
                "callback_interval_p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: cadence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("display-cadence.json"))
        // Bitmap readback is an upper bound, not proof of presentation FPS.
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<30 { try snapshot(states, at: output.appendingPathComponent("frame-\(index).png")) }
        print("30 five-state bitmap captures: \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms total")
        print("Cadence: \(String(decoding: data, as: UTF8.self))")
        for (name, root) in [
            (
                "reduced-motion",
                AnyView(illustrations.environment(\.scenePhase, .active).environment(\.overrideReduceMotion, true))
            ),
            ("inactive", AnyView(illustrations.environment(\.scenePhase, .inactive))),
        ] {
            states.rootView = root
            try await Task.sleep(for: .milliseconds(300))
            let first = output.appendingPathComponent("\(name)-first.png")
            let second = output.appendingPathComponent("\(name)-second.png")
            try snapshot(states, at: first)
            try await Task.sleep(for: .milliseconds(500))
            try snapshot(states, at: second)
            guard try Data(contentsOf: first) == Data(contentsOf: second) else { throw QAError.motionDidNotPause }
        }
        print("Reduced Motion and inactive scene: identical frame captures after 500 ms")
        let now = Date()
        let titles = [
            "Peace talks resume after border ceasefire holds for a third day",
            "Regional alliance says it will avoid military escalation during talks",
            "Government withdraws proposed trade restrictions after negotiations",
            "Central bank reports stable lending and no emergency liquidity measures",
        ]
        let articles = TensionMethodology.v1.panel.enumerated().map { index, member in
            FeedArticle(
                title: titles[index % titles.count], link: "https://qa.example/world/\(index)",
                guid: "world-qa-\(index)", description: "", pubDate: now.addingTimeInterval(-3600),
                source: "Panel")
        }
        for (article, member) in zip(articles, TensionMethodology.v1.panel) {
            try await database.upsertArticles([article], feedUrl: member.url)
        }
        let modelStart = ProcessInfo.processInfo.systemUptime
        let model = NewsTextModel { prompt, tokens in
            do {
                let answer = try await NewsTextModel.onDevice.respond(prompt, tokens)
                print("Live model response: \(answer)")
                return answer
            } catch {
                print("Live model error: \(error)")
                throw error
            }
        }
        let readings = try await WorldTensionService(model: model).assess(
            database: database, now: now,
            aiEnabled: true, collectionEnabled: true)
        guard let reading = readings.last else { throw QAError.noAssessment }
        let invented = WorldTensionAssessment(
            score: 95, summary: "A nuclear attack destroyed Paris yesterday, killing 40000 people.",
            reasons: reading.assessment.reasons)
        guard !invented.isGrounded(in: reading.headlines) else { throw QAError.fabricatedClaimAccepted }
        print("Lexical grounding rejected a fabricated nuclear attack")
        try JSONEncoder().encode(reading).write(to: output.appendingPathComponent("live-model.json"))
        print(
            "Live on-device assessment: score \(reading.assessment.score), \(reading.assessment.reasons.count) supported factors, \(ProcessInfo.processInfo.systemUptime - modelStart) seconds"
        )
        settings.aiEnabled = true
        settings.tensionCollectionOptIn = true
        let sheet = show(
            TensionIndexView(history: readings).environmentObject(settings).environmentObject(store),
            size: NSSize(width: AppLayout.tensionSheetWidth, height: AppLayout.tensionSheetHeight),
            title: "News — World Tension QA")
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(sheet, at: output.appendingPathComponent("live-sheet.png"))
        if ProcessInfo.processInfo.environment["NEWS_WORLD_TENSION_INTERACTIVE"] == "1" {
            print("Interactive QA ready")
            try await Task.sleep(for: .seconds(600))
        }
        await database.close()
    }

    private enum QAError: Error {
        case render, storage, settingsShrank, noFrames, noAssessment, motionDidNotPause, fabricatedClaimAccepted
    }
}
