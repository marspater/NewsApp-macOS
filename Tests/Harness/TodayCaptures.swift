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

/// Captures of the Today edition (epic Z, #932) without a window or Screen Recording, in light, dark and both with
/// Increase Contrast. Run with `NEWS_NATIVE_HARNESS=Tests/Harness/TodayCaptures.swift
/// script/native_performance_baseline.sh DIR`. The stories are fictional and the photos are drawn here, so nothing
/// reads a library or the network.
@main
struct TodayCaptures {
    static func main() async {
        let output = URL(
            fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let failures = await MainActor.run { captureCards(into: output) + capturePage(into: output) }
        print(failures == 0 ? "✅ Captures written to \(output.path)" : "❌ \(failures) captures failed")
        exit(failures == 0 ? 0 : 1)
    }

    static let now = Date()

    /// A story with a drawn photo in the card image cache, or none when `photo` is nil.
    @MainActor
    static func story(
        _ id: String, _ publisher: String, _ title: String, hoursAgo: Double = 2, photo: Int? = nil,
        dek: String = "Officials said the decision follows weeks of talks, and more detail is expected on Friday."
    ) -> FeedArticle {
        let image = photo.map { _ in "https://example.com/today/\(id).jpg" }
        if let image, let url = URL(string: image), let photo {
            DecodedImageCache.cardImages.setObject(syntheticPhoto(seed: photo), forKey: url as NSURL)
            DecodedImageCache.images.setObject(syntheticPhoto(seed: photo), forKey: url as NSURL)
        }
        return FeedArticle(
            storedID: id, title: title, link: "https://example.com/today/\(id)", guid: id, description: dek,
            pubDate: now.addingTimeInterval(-hoursAgo * 3600), source: publisher, imageUrl: image)
    }

    // MARK: - Card variants (#938)

    /// Every variant with its metadata, the same variants with none (each field hidden), a read card and a card
    /// with keyboard focus.
    @MainActor
    static func captureCards(into output: URL) -> Int {
        let readManager = ReadManager()
        let savedStories = SavedStoriesManager()
        let suite = testDefaultsSuite("today-captures")
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)

        let developing = story(
            "developing", "Reuters", "Grid operators extend emergency reserves as the cold front moves east",
            hoursAgo: 0.3, photo: 1)
        let standard = story(
            "standard", "The Verge", "Open-source browser engine reaches its first stable release", photo: 2)
        let feature = story(
            "feature", "The Atlantic", "Inside how a river town rebuilt its flood defences, one street at a time",
            hoursAgo: 9, photo: 3)
        let coverage = story(
            "coverage", "BBC News", "Typhoon closes ports across the northern Philippines", hoursAgo: 4, photo: 4)
        let bare = story("bare", "DW", "Ministers meet in Brussels over Baltic airspace incursions", hoursAgo: 5)
        let read = story("read", "Nature", "Astronomers map the largest known structure in the early universe")
        readManager.readArticles.insert(read.id)
        let compact = [
            story("compact-a", "Al Jazeera", "Aid convoys reach El Fasher after weeks of delays", photo: 5),
            story(
                "compact-b", "Bloomberg",
                "Oil prices slip as shipping routes reopen in the Red Sea and insurers cut war-risk premiums for "
                    + "tankers", hoursAgo: 3, photo: 6),
            story("compact-c", "STAT", "Regulators approve a once-yearly injection", hoursAgo: 6),
        ]

        func card(
            _ article: FeedArticle, _ variant: StoryCardVariant, _ metadata: StoryCardMetadata = StoryCardMetadata(),
            focused: Bool = false
        ) -> some View {
            ArticleCardView(
                article: article, isSelected: focused, variant: variant, metadata: metadata, action: {},
                footer: EmptyView()
            )
            .frame(width: variant.laneWidth)
        }

        let sheet = VStack(alignment: .leading, spacing: AppSpacing.lg) {
            HStack(alignment: .top, spacing: AppLayout.cardGap) {
                card(
                    developing, .developing,
                    StoryCardMetadata(
                        updatedAt: now.addingTimeInterval(-14 * 60), publisherCount: 7, newReportCount: 3,
                        reportDays: 4))
                card(standard, .standard)
                card(
                    coverage, .coverage,
                    StoryCardMetadata(
                        publisherCount: 9, originalReports: 4, publishers: ["BBC News", "Reuters", "Rappler", "DW"],
                        differingAccount: "Rappler reports 40,000 moved; officials say 31,000."))
            }
            HStack(alignment: .top, spacing: AppLayout.cardGap) {
                card(feature, .feature, StoryCardMetadata(contentType: "Investigation", readingMinutes: 14))
                card(bare, .feature)
            }
            HStack(alignment: .top, spacing: AppLayout.cardGap) {
                card(bare, .developing)
                card(read, .standard)
                card(standard, .coverage, focused: true)
            }
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: AppLayout.gridColumnMinimum, maximum: AppLayout.gridColumnMaximum),
                        spacing: AppLayout.cardGap, alignment: .top)
                ], spacing: AppLayout.cardGap
            ) {
                ForEach(compact) { card($0, .compact) }
            }
        }
        .padding(AppLayout.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environmentObject(readManager).environmentObject(savedStories).environmentObject(settings)

        var failures = 0
        for (name, dark, contrast) in appearances {
            failures += render(
                sheet, name: "today-cards-\(name)", size: NSSize(width: 1080, height: 1500), dark: dark,
                contrast: contrast, into: output)
        }
        return failures
    }

    // MARK: - The page (#935, #936)

    /// One placed story, with the evidence its card shows.
    @MainActor
    static func placed(
        _ lane: TodayLane, _ article: FeedArticle, publishers: [String] = [], original: Int = 1, days: Int = 1,
        developing: Bool = false, type: TodayContentType? = nil, minutes: Double = 0, coverage: Bool = false
    ) -> TodayStoryAssignment {
        let entry: FeedEntry
        if publishers.count > 1 {
            let members = publishers.enumerated().map { index, publisher in
                EventFeedMember(
                    articleID: index == 0 ? article.id : "\(article.id)-\(index)", source: publisher,
                    title: article.title,
                    date: article.pubDate.addingTimeInterval(-Double(index % max(1, days)) * 86_400),
                    joinedVersion: index + 1, isRead: false, isSaved: false)
            }
            entry = .event(
                EventFeedSummary(
                    eventID: "event-\(article.id)", membershipVersion: members.count,
                    seenVersion: max(1, members.count - 2), members: members),
                representative: article, visibleMembers: [article])
        } else {
            entry = .article(article)
        }
        return TodayStoryAssignment(
            id: article.id, entry: entry, lane: lane, score: 0.8, confidence: 0.8, reason: "capture",
            sortKey: article.pubDate, contentTypeLabel: type, isCoverageConfident: coverage, isDeveloping: developing,
            originalReportCount: original, publisherCount: max(1, publishers.count), groupingConfidence: 0.9,
            readingTimeMinutes: minutes, interestMatch: 0, novelty: 0)
    }

    /// A full library's edition: five slides, every conditional lane and nine stories in The Latest.
    @MainActor
    static func fullEdition() -> TodayEdition {
        let wires = ["BBC News", "Reuters", "AP News", "Al Jazeera", "DW", "France 24"]
        var seed = 10
        func next(_ id: String, _ publisher: String, _ title: String, hours: Double, photo: Bool = true) -> FeedArticle
        {
            seed += 1
            return story(id, publisher, title, hoursAgo: hours, photo: photo ? seed : nil)
        }
        let lead = [
            placed(
                .theLead,
                next(
                    "lead-1", "BBC News", "Grid operators agree on a cross-border reserve after a week of talks",
                    hours: 2),
                publishers: wires, original: 4, developing: true, minutes: 4),
            placed(
                .theLead, next("lead-2", "Reuters", "Typhoon closes ports across the northern Philippines", hours: 3),
                publishers: Array(wires.prefix(4)), original: 3),
            placed(
                .theLead, next("lead-3", "Financial Times", "Central banks hold rates as inflation cools", hours: 4),
                publishers: Array(wires.prefix(3)), original: 2),
        ]
        let motion = [
            ("motion-1", "Al Jazeera", "Ceasefire monitors report a quieter night along the line", 7, 4),
            ("motion-2", "AP News", "Rescue teams reach the last cut-off villages after the floods", 5, 3),
            ("motion-3", "The Guardian", "Court sets a date for the appeal in the data-transfer case", 3, 1),
            ("motion-4", "Deutsche Welle", "Coalition talks resume after a weekend pause", 4, 5),
        ].map { id, publisher, title, count, days in
            placed(
                .inMotion, next(id, publisher, title, hours: 0.4),
                publishers: [publisher] + wires.prefix(count - 1), original: 2, days: days)
        }
        let beat = [
            placed(
                .yourBeat,
                next(
                    "beat-1", "Ars Technica", "Chip makers settle on a shared memory standard for on-device models",
                    hours: 1),
                publishers: ["Ars Technica", "The Verge", "Wired", "Reuters", "Bloomberg"], original: 3, coverage: true),
            placed(
                .yourBeat,
                next(
                    "beat-2", "The Verge", "A quieter keyboard and a brighter screen: the laptop refresh in detail",
                    hours: 1)),
            placed(
                .yourBeat,
                next(
                    "beat-3", "Nature", "Ocean sensors record the warmest October on record in the North Atlantic",
                    hours: 3)),
            placed(
                .yourBeat,
                next(
                    "beat-4", "NPR", "Cities test free transit on weekends to bring back downtown shoppers", hours: 5,
                    photo: false)),
        ]
        let deep = [
            placed(
                .theDeepRead,
                next(
                    "deep-1", "ProPublica", "Inside the contracts that kept a failing water utility afloat", hours: 20),
                type: .investigation, minutes: 18),
            placed(
                .theDeepRead,
                next("deep-2", "Vox", "Why electricity prices rise even when gas gets cheaper", hours: 22),
                type: .explainer, minutes: 11),
            placed(
                .theDeepRead, next("deep-3", "The Conversation", "The case for slower trains", hours: 40),
                type: .opinion, minutes: 9),
        ]
        let outside = [
            placed(
                .outsideYourUsual,
                next("out-1", "CBC", "A northern town's library becomes the busiest room in the region", hours: 4)),
            placed(
                .outsideYourUsual,
                next("out-2", "France 24", "Marseille's fishing fleet turns to a cooperative model", hours: 6)),
            placed(
                .outsideYourUsual,
                next("out-3", "Politico Europe", "The small print in the farm subsidy deal", hours: 7)),
        ]
        let latestTitles = [
            ("BBC News", "Central bank holds rates and signals a cut in spring"),
            ("The Guardian", "Theatre reopens after a four-year restoration"),
            ("AP News", "Ferry service resumes after the strike"),
            ("Deutsche Welle", "Berlin approves a new cycling budget"),
            ("NPR", "Schools trial a four-day week in two districts"),
            ("Al Jazeera", "Talks on fishing quotas enter a second day"),
            ("The Verge", "A new standard for USB power labels"),
            ("Ars Technica", "Browser vendors agree on a date to drop an old cipher"),
            ("France 24", "Lyon's festival of lights announces its programme"),
        ]
        let latest = latestTitles.enumerated().map { index, item in
            placed(
                .theLatest, next("latest-\(index)", item.0, item.1, hours: 0.5 + Double(index) / 2, photo: index != 7))
        }
        let all = lead + motion + beat + deep + outside + latest
        let plan = TodayEditionPlan(
            lanes: [
                TodayLaneResult(lane: .theLead, qualifies: true, entries: lead),
                TodayLaneResult(lane: .inMotion, qualifies: true, entries: motion),
                TodayLaneResult(lane: .theDeepRead, qualifies: true, entries: deep),
                TodayLaneResult(lane: .yourBeat, qualifies: true, entries: beat),
                TodayLaneResult(lane: .outsideYourUsual, qualifies: true, entries: outside),
                TodayLaneResult(lane: .theLatest, qualifies: true, entries: latest),
            ])
        return TodayEdition.make(
            entries: all.map(\.entry), plan: plan,
            details: TodayCardDetails(differingAccounts: [
                "beat-1": "The Verge: the standard is voluntary. Ars Technica: the consortium can enforce it."
            ]))
    }

    /// The page at the detail width of a 1,440 pt window and of the 900 pt minimum window, full and partly filled
    /// (The Lead and The Latest only), with a masthead stand-in in the list's tokens above it.
    /// The capture must be taller than the page: a shorter one centres it and cuts the masthead and the last row.
    @MainActor
    static func capturePage(into output: URL) -> Int {
        let readManager = ReadManager()
        let savedStories = SavedStoriesManager()
        let suite = testDefaultsSuite("today-page-captures")
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        let full = fullEdition()
        readManager.readArticles.formUnion(["motion-1", "deep-3", "latest-4"])
        var partly = TodayEdition()
        partly.lanes = full.lanes.filter { !$0.lane.isConditional }.map {
            TodayEdition.Lane(lane: $0.lane, stories: Array($0.stories.prefix($0.lane == .theLead ? 1 : 5)))
        }
        partly.metadata = full.metadata

        func page(_ edition: TodayEdition, size: CGSize) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text("Today").font(AppTypography.masthead).foregroundStyle(AppColor.primaryText)
                    Text("128 stories · 41 events · updated 09:42")
                        .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                }
                .padding(.horizontal, AppLayout.pageInset)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppLayout.cardGap)
                TodayEditionView(
                    edition: edition, readIDs: readManager.readArticles,
                    columnSize: CGSize(width: size.width, height: size.width > 1000 ? 848 : 548),
                    isMotionPaused: true, actions: TodayEditionActions(open: { _ in }))
                Spacer(minLength: 0)
            }
            .environmentObject(readManager).environmentObject(savedStories).environmentObject(settings)
        }

        var failures = 0
        for (window, width) in [(1440, 1211), (900, 660)] {
            for (name, dark, contrast) in appearances where contrast == .standard || window == 1440 {
                failures += render(
                    page(full, size: CGSize(width: width, height: 2700)), name: "today-\(window)pt-\(name)",
                    size: NSSize(width: CGFloat(width), height: width > 1000 ? 2800 : 3100), dark: dark,
                    contrast: contrast, into: output)
            }
        }
        failures += render(
            page(partly, size: CGSize(width: 1211, height: 1100)), name: "today-1440pt-partly-light",
            size: NSSize(width: 1211, height: 1100), dark: false, contrast: .standard, into: output)
        return failures
    }

    static let appearances: [(String, Bool, ColorSchemeContrast)] = [
        ("light", false, .standard), ("dark", true, .standard), ("light-ic", false, .increased),
        ("dark-ic", true, .increased),
    ]

    // MARK: - Rendering

    /// Renders `view` offscreen on the window background at `size`, trimmed below its content, as `name.png`;
    /// returns 1 on failure.
    @MainActor
    static func render<V: View>(
        _ view: V, name: String, size: NSSize, dark: Bool, contrast: ColorSchemeContrast, into output: URL
    ) -> Int {
        let host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).background(AppColor.background)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.overrideContrast, contrast).environment(\.overrideReduceMotion, true))
        let increased = contrast == .increased
        let appearanceName: NSAppearance.Name =
            dark
            ? (increased ? .accessibilityHighContrastDarkAqua : .darkAqua)
            : (increased ? .accessibilityHighContrastAqua : .aqua)
        let appearance = NSAppearance(named: appearanceName) ?? NSAppearance.currentDrawing()
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        var rendered: NSBitmapImageRep?
        // Rows measure their tallest card through state, which needs a turn of the run loop to settle.
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        appearance.performAsCurrentDrawingAppearance {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            rendered = bitmap
        }
        guard let bitmap = rendered, let png = bitmap.representation(using: .png, properties: [:]) else {
            print("  blank: \(name)")
            return 1
        }
        do {
            try png.write(to: output.appendingPathComponent("\(name).png"))
            return 0
        } catch {
            print("  write failed: \(name): \(error.localizedDescription)")
            return 1
        }
    }

    /// A 1600 × 900 stand-in photograph: a sky-to-ground gradient with a few shapes, different per seed.
    static func syntheticPhoto(seed: Int) -> CGImage {
        let width = 1600
        let height = 900
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hue = CGFloat(seed) * 0.17
        let colors = [
            NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 0.85, alpha: 1).cgColor,
            NSColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.35, alpha: 1)
                .cgColor,
        ]
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
        context.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor)
        for shape in 0..<6 {
            let x = CGFloat((seed * 211 + shape * 263) % width)
            let size = CGFloat(120 + (seed * 37 + shape * 53) % 220)
            context.fillEllipse(in: CGRect(x: x, y: CGFloat(200 + shape * 60), width: size, height: size))
        }
        return context.makeImage()!
    }
}
