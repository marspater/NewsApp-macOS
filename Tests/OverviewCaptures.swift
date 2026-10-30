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
/// gray. Run with `NEWS_NATIVE_HARNESS=Tests/OverviewCaptures.swift script/native_performance_baseline.sh DIR`;
/// `NEWS_CAPTURE_SET=tension` renders the World Tension sheet, sidebar foot and Briefing strip instead (#781), and
/// `NEWS_CAPTURE_SET=briefing` the Briefing situation board (#780).
@main
struct OverviewCaptures {
    static func main() async {
        let output = URL(
            fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let set = ProcessInfo.processInfo.environment["NEWS_CAPTURE_SET"]
        let failures = await MainActor.run {
            switch set {
            case "tension": return captureTension(into: output)
            case "briefing": return captureBriefing(into: output)
            default: return capture(into: output)
            }
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

    /// Renders `view` offscreen on the window background at `size` and writes `name.png`, with `trim` cut below the
    /// content; returns 1 on failure.
    @MainActor
    static func render<V: View>(
        _ view: V, name: String, size: NSSize, dark: Bool, trim: Bool = false, into output: URL
    ) -> Int {
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
        guard let full = rendered, let rendered = trim ? trimmed(full) : full, distinctColors(rendered) > 1 else {
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

// MARK: - Briefing situation board (#780)

extension OverviewCaptures {
    /// The board at the detail width of a 1,600 pt window and of the 900 pt minimum window, light and dark, with a
    /// masthead stand-in in the list's tokens above it (the list draws the real one, and the toolbar is not offscreen).
    /// Images are drawn here and put in the decoded-image cache, so nothing is fetched.
    @MainActor
    static func captureBriefing(into output: URL) -> Int {
        let (entries, facts, images, readIDs) = briefingFixture()
        let (now, history) = tensionFixture()
        let tension = WorldTensionModel(
            state: WorldTensionState(history: WorldTensionSmoothing.displayed(history), loadedAt: now))
        let briefing = FiniteBriefing(
            startedAt: now.addingTimeInterval(-8 * 3600), articles: entries.map(\.representative))
        let readManager = ReadManager()
        let savedStories = SavedStoriesManager()
        let suite = testDefaultsSuite("briefing-captures")
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        var failures = 0
        // 1,600 pt and 900 pt windows less the sidebar's ideal and minimum widths.
        for (window, width) in [(1600, 1360), (900, 680)] {
            for dark in [false, true] {
                let board = VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text("Briefing").font(AppTypography.masthead).foregroundStyle(AppColor.primaryText)
                        Text("Friday, October 30 briefing · Selected by coverage and your interests")
                            .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppLayout.pageInset)
                    .padding(.top, AppSpacing.md)
                    .padding(.bottom, AppLayout.cardGap)
                    BriefingView(
                        entries: entries, briefing: briefing,
                        details: BriefingStoryDetails(facts: facts, images: images), readIDs: readIDs,
                        savedIDs: [entries[3].id], focusedID: nil, nextEdition: now.addingTimeInterval(16 * 3600),
                        actions: BriefingActions(
                            onOpenArticle: { _ in }, onOpenEvent: { _ in }, onStartNewBriefing: {}, onBackToToday: {}))
                    Spacer(minLength: 0)
                }
                .environmentObject(readManager).environmentObject(savedStories).environmentObject(settings)
                .environment(tension)
                failures += render(
                    board, name: "briefing-\(window)pt-\(dark ? "dark" : "light")",
                    size: NSSize(width: width, height: 2600), dark: dark, trim: true, into: output)
            }
        }
        return failures
    }

    /// Ten stories of a morning edition: five events with several publishers and five single reports, across World,
    /// Business, Technology, Science and Health, with stored highlights for six, three of them read.
    @MainActor
    static func briefingFixture() -> ([FeedEntry], [String: BriefingCitedFact], [String: URL], Set<String>) {
        let now = Date(timeIntervalSince1970: 1_793_372_400)
        let stories: [(String, String, String, Int, String)] = [
            (
                "World", "Reuters", "Ceasefire talks resume in Cairo as aid convoys reach northern Gaza", 14,
                "Mediators said both delegations had agreed to a third round of talks on Sunday."
            ),
            (
                "Business", "Financial Times", "Central banks hold rates as inflation cools across Europe", 9,
                "The European Central Bank kept its deposit rate at 2 percent for a fourth meeting."
            ),
            (
                "World", "BBC News", "Typhoon closes ports across the northern Philippines", 7,
                "More than 40,000 people were moved to evacuation centres before landfall."
            ),
            ("Technology", "The Verge", "Chipmakers report record demand for data-centre processors", 6, ""),
            (
                "Science", "Nature", "Astronomers map the largest known structure in the early universe", 5,
                "The filament spans more than a billion light years, the team reported."
            ),
            ("World", "Al Jazeera", "Sudan aid convoys reach El Fasher after weeks of delays", 1, ""),
            (
                "Health", "STAT", "Regulators approve a once-yearly injection for HIV prevention", 1,
                "The agency approved the injection for adults and adolescents weighing at least 35 kilograms."
            ),
            ("Business", "Bloomberg", "Oil prices slip as shipping routes reopen in the Red Sea", 1, ""),
            ("Technology", "Ars Technica", "Open-source browser engine reaches its first stable release", 1, ""),
            ("World", "DW", "NATO ministers meet in Brussels over Baltic airspace incursions", 1, ""),
        ]
        var entries: [FeedEntry] = []
        var facts: [String: BriefingCitedFact] = [:]
        var images: [String: URL] = [:]
        for (index, story) in stories.enumerated() {
            let (category, publisher, title, publishers, fact) = story
            let id = "briefing-\(index)"
            let image = "https://example.com/briefing/\(index).jpg"
            let article = FeedArticle(
                storedID: id, title: title, link: "https://example.com/briefing/\(index)", guid: id,
                description: "\(title). Reporting continues as more details emerge from officials and witnesses.",
                pubDate: now.addingTimeInterval(-Double(index + 2) * 3600), source: publisher, imageUrl: image,
                category: category)
            if publishers > 1 {
                let members = (0..<publishers).map { member in
                    EventFeedMember(
                        articleID: member == 0 ? id : "\(id)-\(member)",
                        source: member == 0 ? publisher : "Outlet \(member)",
                        title: title, date: article.pubDate, joinedVersion: 1, isRead: false, isSaved: false)
                }
                entries.append(
                    .event(
                        EventFeedSummary(
                            eventID: "event-\(index)", membershipVersion: 1, seenVersion: nil, members: members),
                        representative: article, visibleMembers: [article]))
            } else {
                entries.append(.article(article))
            }
            if !fact.isEmpty { facts[id] = BriefingCitedFact(text: fact, isCited: true, citationPublisher: publisher) }
            if let url = URL(string: image), index < 5 {
                images[id] = url
                DecodedImageCache.images.setObject(syntheticPhoto(seed: index), forKey: url as NSURL)
            }
        }
        return (entries, facts, images, ["briefing-2", "briefing-6", "briefing-8"])
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
