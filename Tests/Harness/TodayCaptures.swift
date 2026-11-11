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
        let failures = await MainActor.run { captureCards(into: output) }
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
