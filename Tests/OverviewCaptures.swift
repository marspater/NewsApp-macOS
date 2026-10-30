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

/// Story Overview captures for Epic T (#669–#673) without a window or Screen Recording: the reader view is rendered
/// offscreen at 900 pt and 1,400 pt, text sizes 1.0 and 1.3, light, dark and Increase Contrast, each also redrawn in
/// gray. Then two rows of story grid cards (#779), collapsed and with the event card's sources shown, in light and
/// dark, with each card's height. Run with `NEWS_NATIVE_HARNESS=Tests/OverviewCaptures.swift
/// script/native_performance_baseline.sh DIR`; `NEWS_CAPTURES=overview` or `NEWS_CAPTURES=grid` runs one set, and
/// `NEWS_CAPTURE_SET=tension` renders the World Tension sheet, sidebar foot and Briefing strip instead (#781).
@main
struct OverviewCaptures {
    static func main() async {
        let output = URL(
            fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let set = ProcessInfo.processInfo.environment["NEWS_CAPTURE_SET"]
        let only = ProcessInfo.processInfo.environment["NEWS_CAPTURES"]
        var failures = 0
        if set == "tension" {
            failures = await MainActor.run { captureTension(into: output) }
        } else {
            if only != "grid" { failures = await MainActor.run { capture(into: output) } }
            if only != "overview" { failures += await GridRowCaptures.capture(into: output) }
        }
        print(failures == 0 ? "✅ Captures written to \(output.path)" : "❌ \(failures) captures failed")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    static func capture(into output: URL) -> Int {
        let (overview, members) = fixture()
        let variants:
            [(name: String, appearance: NSAppearance.Name, scheme: ColorScheme, contrast: ColorSchemeContrast)] =
                [
                    ("light", .aqua, .light, .standard), ("dark", .darkAqua, .dark, .standard),
                    ("light-ic", .accessibilityHighContrastAqua, .light, .increased),
                    ("dark-ic", .accessibilityHighContrastDarkAqua, .dark, .increased),
                ]
        var failures = 0
        for width in [900, 1400] {
            for scale in [1.0, 1.3] {
                for variant in variants {
                    let view = NSHostingView(
                        rootView: EventOverviewReaderView(
                            overview: overview, memberArticles: members, textScale: scale,
                            onSelectArticle: { _ in }, onSelectCitation: { _, _ in }
                        )
                        .environment(\.colorScheme, variant.scheme)
                        .environment(\.overrideContrast, variant.contrast)
                        .environment(\.overrideReduceMotion, true))
                    let appearance = NSAppearance(named: variant.appearance) ?? NSAppearance.currentDrawing()
                    view.appearance = appearance
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 3200)
                    // Dynamic colors (the accent, the semantic text colors) resolve against the drawing appearance,
                    // which a view outside any window does not set on its own.
                    var rendered: NSBitmapImageRep?
                    appearance.performAsCurrentDrawingAppearance {
                        view.layoutSubtreeIfNeeded()
                        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        rendered = bitmap
                    }
                    guard let full = rendered, let bitmap = trimmed(full) else {
                        failures += 1
                        continue
                    }
                    let name = "overview-\(width)pt-text\(scale == 1 ? "1.0" : "1.3")-\(variant.name)"
                    guard distinctColors(bitmap) > 8, let cgImage = bitmap.cgImage else {
                        print("  blank: \(name)")
                        failures += 1
                        continue
                    }
                    guard let gray = grayscale(cgImage) else {
                        print("  grayscale failed: \(name)")
                        failures += 1
                        continue
                    }
                    for (image, file) in [(bitmap, name), (NSBitmapImageRep(cgImage: gray), "\(name)-gray")] {
                        do {
                            try write(image, to: output.appendingPathComponent("\(file).png"))
                        } catch {
                            print("  write failed: \(file): \(error.localizedDescription)")
                            failures += 1
                        }
                    }
                }
            }
        }
        return failures
    }

    /// One overview with every Epic T section: highlights (one from an unknown publisher), a timeline with a dated, a
    /// publication-only and a planned item, two perspectives and one Industry Impact entry.
    static func fixture() -> (EventOverviewDocument, [FeedArticle]) {
        let published = Date(timeIntervalSince1970: 1_793_088_000)
        let members = [
            FeedArticle(
                storedID: "cap-1", title: "Port strike halts container shipping on the east coast",
                link: "https://example.com/cap-1", guid: "cap-1", description: "", pubDate: published,
                source: "Harbor Times"),
            FeedArticle(
                storedID: "cap-2", title: "Dockworkers walk out as contract talks collapse",
                link: "https://example.com/cap-2", guid: "cap-2", description: "", pubDate: published,
                source: "Wire Service"),
            FeedArticle(
                storedID: "cap-3", title: "Retailers warn of delays as ports close",
                link: "https://example.com/cap-3", guid: "cap-3", description: "", pubDate: published, source: ""),
        ]
        func citation(_ id: String, _ article: FeedArticle, _ quote: String) -> OverviewCitation {
            OverviewCitation(
                id: id, articleID: article.id, passageID: "p-\(id)", passageFingerprint: "fp-\(id)", quote: quote,
                source: OverviewSourceMetadata(
                    title: article.title, name: article.source.isEmpty ? nil : article.source, url: article.link,
                    publishedAt: article.pubDate))
        }
        let citations = [
            citation("c1", members[0], "Dockworkers at 14 ports walked off the job on Tuesday."),
            citation("c2", members[1], "Talks broke down after the employers rejected a wage offer."),
            citation("c3", members[2], "Retailers said holiday shipments would arrive late."),
            citation("c4", members[0], "Container lines suspended bookings for east coast ports."),
        ]
        let sections = OverviewEvidenceSections(
            timeline: [
                OverviewTimelineItem(
                    id: "t1", dateText: "Oct 1", summary: "The previous contract expired.", citationIDs: ["c2"],
                    eventDate: published.addingTimeInterval(-26 * 86_400)),
                OverviewTimelineItem(
                    id: "t2", dateText: "", summary: "Dockworkers walked off the job at 14 ports.",
                    citationIDs: ["c1"], publicationDate: published),
                OverviewTimelineItem(
                    id: "t3", dateText: "Next week", summary: "Mediated talks are scheduled to resume.",
                    citationIDs: ["c2"], isFuturePlan: true, eventDate: published.addingTimeInterval(7 * 86_400)),
            ],
            perspectives: [
                OverviewPerspective(
                    id: "v1", participant: "The dockworkers' union",
                    position: "The wage offer does not keep pace with prices.", citationIDs: ["c2"],
                    sourcePublisher: "Wire Service"),
                OverviewPerspective(
                    id: "v2", participant: "The port employers' association",
                    position: "The offer is the largest in two decades.", citationIDs: ["c1"],
                    sourcePublisher: "Harbor Times", originalWireSource: "Wire Service"),
            ],
            industryImpact: [
                OverviewIndustryImpact(
                    id: "i1", industry: "Transportation",
                    implication: "Container lines suspended bookings for east coast ports.", citationIDs: ["c4"])
            ])
        let overview = EventOverviewDocument(
            id: "captures", eventID: "evt-captures",
            version: OverviewVersionContext(
                membershipVersion: 1, inputTextHash: "captures", schemaVersion: 1,
                analysisVersion: EventOverviewDocument.currentAnalysisVersion),
            content: OverviewContent(
                title: "Port strike halts container shipping",
                summary: "Dockworkers at 14 east coast ports walked out after contract talks collapsed.",
                facts: [
                    OverviewFact(id: "f1", text: "Dockworkers at 14 ports walked off the job.", citationIDs: ["c1"]),
                    OverviewFact(id: "f2", text: "Talks broke down over wages.", citationIDs: ["c2"]),
                    OverviewFact(id: "f3", text: "Holiday shipments will arrive late.", citationIDs: ["c3"]),
                ],
                citations: citations, evidenceSections: sections),
            provenance: OverviewProvenance(memberArticleIDs: members.map(\.id), kind: .synthesized))
        return (overview, members)
    }

    static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 40) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 40) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(
                    UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8
                        | UInt32(color.blueComponent * 255))
            }
        }
        return seen.count
    }

    /// The capture without the empty space below the content (the view is laid out taller than the overview).
    static func trimmed(_ bitmap: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let image = bitmap.cgImage, let background = bitmap.colorAt(x: 1, y: bitmap.pixelsHigh - 2) else {
            return nil
        }
        var lastRow = bitmap.pixelsHigh - 1
        rows: while lastRow > 0 {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) where bitmap.colorAt(x: x, y: lastRow) != background
            {
                break rows
            }
            lastRow -= 1
        }
        let height = min(bitmap.pixelsHigh, lastRow + 60)
        guard let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: height)) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cropped)
    }

    static func grayscale(_ image: CGImage) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    static func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try png.write(to: url)
    }
}

// MARK: - World Tension (#781)

extension OverviewCaptures {
    /// The sheet, the sidebar foot and the Briefing strip in every state of the shared World Tension state, light and
    /// dark, and the sheet's 30-day trend on its own (an offscreen scroll view cannot be scrolled to it).
    @MainActor
    static func captureTension(into output: URL) -> Int {
        let (now, history) = tensionFixture()
        let shown = WorldTensionSmoothing.displayed(history)
        let earlier = Array(shown.dropLast())
        let today = TensionMethodology.day(containing: now).start
        var estimate = history
        if let last = estimate.popLast() {
            var assessment = last.assessment
            assessment.isEstimate = true
            assessment.score = 31
            estimate.append(
                WorldTensionReading(
                    evaluatedAt: last.evaluatedAt, inputHash: "fixture:estimate", modelGeneration: last.modelGeneration,
                    headlines: last.headlines, assessment: assessment))
        }
        let waiting = Array(history.last?.headlines.filter { $0.id.hasPrefix("C") }.prefix(4) ?? [])
        let states: [(name: String, state: WorldTensionState)] = [
            ("assessed", WorldTensionState(history: shown, loadedAt: now)),
            ("estimate", WorldTensionState(history: WorldTensionSmoothing.displayed(estimate), loadedAt: now)),
            (
                "stale",
                WorldTensionState(
                    history: earlier, loadedAt: now, problem: WorldTensionError.insufficientCoverage.errorDescription,
                    panelHeadlines: waiting)
            ),
            ("assessing", WorldTensionState(loadedAt: now, isLoading: true)),
            (
                "unavailable",
                WorldTensionState(
                    loadedAt: now, problem: WorldTensionError.generationFailed.errorDescription, panelHeadlines: waiting
                )
            ),
            ("ai-off", WorldTensionState(aiEnabled: false, loadedAt: now)),
        ]
        precondition(states[0].state.reading?.id == today, "The fixture's newest reading is today's")
        var failures = 0
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            for (name, state) in states {
                let model = WorldTensionModel(state: state)
                failures += render(
                    TensionIndexView().environment(model), name: "tension-sheet-\(name)-\(appearance)",
                    size: NSSize(width: AppLayout.tensionSheetWidth, height: AppLayout.tensionSheetHeight), dark: dark,
                    into: output)
                failures += render(
                    VStack(spacing: 0) {
                        Divider()
                        TensionSidebarButton(open: {})
                            .padding(.horizontal, AppLayout.sidebarInset)
                            .padding(.vertical, AppSpacing.xs)
                    }
                    .environment(model),
                    name: "tension-sidebar-\(name)-\(appearance)", size: NSSize(width: 240, height: 64), dark: dark,
                    into: output)
                guard ["assessed", "stale", "ai-off"].contains(name) else { continue }
                // 1,000 pt list measure less the page insets, and the 900 pt window's detail column less them.
                for width in [952, 632] {
                    failures += render(
                        BriefingTensionStripView().environment(model).padding(AppLayout.pageInset),
                        name: "tension-strip-\(name)-\(width + 48)pt-\(appearance)",
                        size: NSSize(width: width + 48, height: 340), dark: dark, into: output)
                }
            }
            failures += render(
                TensionTrendChart(readings: states[0].state.trend(days: 30), selection: .constant(nil))
                    .padding(AppLayout.pageInset),
                name: "tension-trend-\(appearance)", size: NSSize(width: AppLayout.tensionSheetWidth, height: 260),
                dark: dark, into: output)
        }
        return failures
    }

    /// Five weeks of daily assessments with a two-day gap and a keyword estimate, ending today (30 October 2026, 15:00
    /// UTC) with an assessment whose drivers link to their stories.
    static func tensionFixture() -> (Date, [WorldTensionReading]) {
        let now = Date(timeIntervalSince1970: 1_793_372_400)
        let today = TensionMethodology.day(containing: now).start
        let headlines = [
            ("C1", "Al Jazeera", "Israeli airstrikes hit southern Lebanon as ceasefire talks stall"),
            ("C2", "BBC News", "Russian drone strikes cut power across Kharkiv region"),
            ("C3", "DW", "NATO ministers meet in Brussels over Baltic airspace incursions"),
            ("C4", "Dawn", "Floods displace thousands in Sindh province"),
            ("C5", "CNA", "Typhoon closes ports across the northern Philippines"),
            ("C6", "Africanews", "Sudan aid convoys reach El Fasher after weeks of delays"),
            ("P1", "The Guardian", "Lebanon ceasefire talks resume in Cairo"),
            ("P2", "France 24", "Kharkiv grid repairs continue after earlier strikes"),
        ].map { id, publisher, title in
            WorldTensionHeadline(
                id: id, title: title, publisher: publisher, link: "https://example.com/tension/\(id.lowercased())")
        }
        let reasons = [
            (
                WorldTensionFactor.novelty,
                "Strikes in Lebanon resumed after the talks stalled, a change from the P coverage."
            ),
            (.worstCase, "No supplied headline describes nuclear or other weapons-of-mass-destruction risk."),
            (.reversibility, "Airstrikes and drone strikes cause loss of life that cannot be reversed."),
            (.scope, "The strikes in Lebanon and Kharkiv carry regional spillover; the floods stay local."),
        ].map { WorldTensionAssessment.Reason(factor: $0.0, explanation: $0.1) }
        let scores = [
            30, 32, 31, 35, 33, 34, 36, 38, 37, 35, 33, 34, 36, 39, 40, 38, 36, 35, 37, 39, 41, 40, 38, 36, 37, 39, 41,
            43, 42, 44, 46, 47, 48, 49, 51,
        ]
        let gap: Set<Int> = [-12, -11]
        return (
            now,
            scores.enumerated().compactMap { index, score -> WorldTensionReading? in
                let offset = index - (scores.count - 1)
                guard !gap.contains(offset) else { return nil }
                return WorldTensionReading(
                    evaluatedAt: today.addingTimeInterval(Double(offset) * 86400 + 9 * 3600),
                    inputHash: "fixture-\(offset)", modelGeneration: "fixture", headlines: headlines,
                    assessment: WorldTensionAssessment(
                        score: score,
                        summary:
                            "NATO ministers meet over Baltic airspace incursions. Floods in Sindh and a typhoon in the Philippines stay local, and aid convoys reached El Fasher.",
                        reasons: reasons,
                        lead:
                            "Israeli airstrikes in southern Lebanon and Russian drone strikes on Kharkiv lead the day.",
                        drivers: ["C1", "C2", "C3"], isEstimate: offset == -5 ? true : nil))
            }
        )
    }

    /// Renders `view` offscreen on the window background at `size` and writes `name.png`; returns 1 on failure.
    @MainActor
    static func render<V: View>(_ view: V, name: String, size: NSSize, dark: Bool, into output: URL) -> Int {
        let host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).background(AppColor.background)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.overrideContrast, .standard).environment(\.overrideReduceMotion, true))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        var rendered: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            rendered = bitmap
        }
        guard let rendered, distinctColors(rendered) > 1 else {
            print("  blank: \(name)")
            return 1
        }
        do {
            try write(rendered, to: output.appendingPathComponent("\(name).png"))
            return 0
        } catch {
            print("  write failed: \(name): \(error.localizedDescription)")
            return 1
        }
    }
}

/// Two rows of grid cards as the story list lays them out (#779): an article card, an event card of four reports and an
/// article card with an intelligence tag, then a row of three article cards. Rendered collapsed and with the event
/// card's sources shown, in light and dark; each card's height is printed and written to grid-heights.json.
@MainActor
enum GridRowCaptures {
    static func capture(into output: URL) async -> Int {
        do {
            return try await render(into: output)
        } catch {
            print("  grid captures failed: \(error)")
            return 1
        }
    }

    static func render(into output: URL) async throws -> Int {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("news-grid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = testDefaultsSuite("test.captures.grid")
        defer {
            removeTestDefaults(suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        let database = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
        let store = ArticleStore(database: database)
        await store.initialize()
        let published = Date().addingTimeInterval(-3 * 3600)
        func story(_ id: String, _ title: String, _ summary: String, _ source: String, minutes: Double) -> FeedArticle {
            FeedArticle(
                storedID: id, title: title, link: "https://\(source.lowercased().filter(\.isLetter)).example/\(id)",
                guid: id, description: summary, pubDate: published.addingTimeInterval(-minutes * 60), source: source)
        }
        let listed = [
            story("grid-a", "Council approves new bus lanes", "A short summary.", "City Desk", minutes: 0),
            story(
                "grid-e", "Port strike halts container shipping on the east coast as contract talks collapse",
                "Dockworkers at 14 ports walked off the job after employers rejected a wage offer, stopping most "
                    + "container traffic.", "Harbor Times", minutes: 5),
            story(
                "grid-c", "Researchers map a deep-sea current that carries heat from the tropics toward the poles", "",
                "Science Weekly", minutes: 10),
            story("grid-d", "Library extends weekend hours", "Branches open until eight.", "City Desk", minutes: 15),
            story(
                "grid-f", "Rail operator orders forty new trains", "Deliveries start next year.", "Transit Wire",
                minutes: 20),
            story("grid-g", "Museum reopens its east wing after repairs", "", "Arts Daily", minutes: 25),
        ]
        let coverage = [
            story("grid-e2", "Dockworkers walk out as talks fail", "", "Wire Service", minutes: 30),
            story("grid-e3", "Ports close as strike begins", "", "Morning Ledger", minutes: 35),
            story("grid-e4", "Retailers warn of delays as ports close", "", "Trade Journal", minutes: 40),
        ]
        try await database.upsertArticles(listed + coverage)
        guard
            case .created = try await database.applyEventMatch(
                "grid-e", .create(with: coverage.map(\.id)), matcherVersion: EventMatcher.version)
        else { throw CocoaError(.featureUnsupported) }
        try await database.updateEnrichment(articleId: "grid-c", update: .init(summary: "A generated summary."))
        let stored = try await database.fetchArticles(limit: nil).filter { article in
            listed.contains { $0.id == article.id }
        }
        let events = try await store.eventFeedSummaries(for: stored.map(\.id))
        let entries = EventFeedGrouping.entries(for: stored, events: events, mode: .events)
        guard entries.count == 6, case .event = entries[1] else { throw CocoaError(.featureUnsupported) }

        var failures = 0
        var report: [String: [String: Double]] = [:]
        var collapsedEventHeight: Double?
        let variants: [(name: String, appearance: NSAppearance.Name, scheme: ColorScheme)] = [
            ("light", .aqua, .light), ("dark", .darkAqua, .dark),
        ]
        for expanded in [false, true] {
            for variant in variants {
                let heights = CardHeights()
                let view = NSHostingView(
                    rootView: GridRowFixture(entries: entries, expanded: expanded, heights: heights)
                        .environmentObject(settings)
                        .environmentObject(store)
                        .environmentObject(ReadManager(articleStore: store))
                        .environmentObject(SavedStoriesManager(articleStore: store))
                        .environment(\.colorScheme, variant.scheme)
                        .environment(\.overrideReduceMotion, true))
                let appearance = NSAppearance(named: variant.appearance) ?? NSAppearance.currentDrawing()
                view.appearance = appearance
                view.frame = NSRect(x: 0, y: 0, width: 1040, height: 1200)
                // The expanded card loads its sources from the store. Wait until its height has grown past the
                // collapsed card's by more than the loading row and then held for ten updates; five seconds without
                // that is a failed capture, not a picture of the spinner.
                let event = entries[1].id
                var settled = !expanded
                var stableUpdates = 0
                var lastHeight = 0.0
                for _ in 0..<300 where !settled {
                    try await Task.sleep(for: .milliseconds(16))
                    appearance.performAsCurrentDrawingAppearance { view.layoutSubtreeIfNeeded() }
                    let height = heights.values[event] ?? 0
                    stableUpdates = height == lastHeight ? stableUpdates + 1 : 0
                    lastHeight = height
                    settled = height > (collapsedEventHeight ?? .infinity) + 100 && stableUpdates >= 10
                }
                if !expanded {
                    for _ in 0..<30 {
                        try await Task.sleep(for: .milliseconds(16))
                        appearance.performAsCurrentDrawingAppearance { view.layoutSubtreeIfNeeded() }
                    }
                    collapsedEventHeight = heights.values[event]
                }
                guard settled else {
                    print("  sources did not load: grid-row-expanded-\(variant.name)")
                    failures += 1
                    continue
                }
                var rendered: NSBitmapImageRep?
                appearance.performAsCurrentDrawingAppearance {
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    rendered = bitmap
                }
                let file = "grid-row-\(expanded ? "expanded" : "collapsed")-\(variant.name)"
                guard let full = rendered, let bitmap = OverviewCaptures.trimmed(full) else {
                    failures += 1
                    continue
                }
                do {
                    try OverviewCaptures.write(bitmap, to: output.appendingPathComponent("\(file).png"))
                } catch {
                    print("  write failed: \(file): \(error.localizedDescription)")
                    failures += 1
                }
                report[file] = heights.values
                // The bug this capture guards (#779): showing the event's sources must not change any other card.
                if expanded, let collapsed = report["grid-row-collapsed-\(variant.name)"] {
                    for entry in entries where entry.id != event && heights.values[entry.id] != collapsed[entry.id] {
                        print("  \(file): \(entry.id) changed height when the event card expanded")
                        failures += 1
                    }
                }
                print(
                    "  \(file): " + entries.map { "\($0.id)=\(Int(heights.values[$0.id] ?? 0))" }.joined(separator: " ")
                )
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("grid-heights.json"))
        await database.close()
        return failures
    }
}

@MainActor
private final class CardHeights {
    var values: [String: Double] = [:]
}

/// The story list's grid: the columns, spacing and cards of `ArticleListView.cardCollection` in grid layout.
private struct GridRowFixture: View {
    let entries: [FeedEntry]
    let expanded: Bool
    let heights: CardHeights

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: AppLayout.gridColumnMinimum, maximum: AppLayout.gridColumnMaximum),
                    spacing: AppLayout.cardGap, alignment: .top)
            ],
            spacing: AppLayout.cardGap
        ) {
            ForEach(entries) { entry in
                card(entry)
                    .onGeometryChange(for: Double.self) {
                        Double($0.size.height)
                    } action: {
                        heights.values[entry.id] = $0
                    }
            }
        }
        .padding(AppLayout.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColor.background)
    }

    @ViewBuilder
    private func card(_ entry: FeedEntry) -> some View {
        switch entry {
        case .article(let article):
            ArticleCardView(
                article: article, compact: false, reservesCoverageRow: true, action: {}, footer: EmptyView())
        case .event(let summary, let representative, let members):
            EventCardView(
                representative: representative, summary: summary, visibleMembers: members, compact: false,
                isExpanded: .constant(expanded), openRepresentative: {}, openMember: { _, _ in }, separate: { _ in },
                combine: { _ in })
        }
    }
}
