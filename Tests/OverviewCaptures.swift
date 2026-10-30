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
/// gray. Run with `NEWS_NATIVE_HARNESS=Tests/OverviewCaptures.swift script/native_performance_baseline.sh DIR`.
@main
struct OverviewCaptures {
    static func main() async {
        let output = URL(
            fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let failures = await MainActor.run { capture(into: output) }
        print(failures == 0 ? "✅ Overview captures written to \(output.path)" : "❌ \(failures) captures failed")
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
