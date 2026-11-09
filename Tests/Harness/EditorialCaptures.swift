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

/// Captures of Epic W's editorial views (#716, #717, #718) without a window or Screen Recording: the entity dossier, the
/// dual reader side by side and stacked, and the World Tension hotspot map are rendered offscreen in light, dark and
/// Increase Contrast. Run with `NEWS_NATIVE_HARNESS=Tests/Harness/EditorialCaptures.swift
/// script/native_performance_baseline.sh DIR`. The fixtures are fictional; nothing reads a library or a model.
@main
struct EditorialCaptures {
    static func main() async {
        let output = URL(
            fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let failures = await MainActor.run { capture(into: output) }
        print(failures == 0 ? "✅ Captures written to \(output.path)" : "❌ \(failures) captures failed")
        exit(failures == 0 ? 0 : 1)
    }

    private static let now = Date(timeIntervalSince1970: 1_793_372_400)

    private static var dossier: EntityDossier {
        let entity = EntityRecord(
            id: "organization:harbour-authority", canonicalName: "Harbour Authority", entityType: .organization,
            storyCount: 21, firstSeen: now.addingTimeInterval(-26 * 86_400), lastSeen: now, centrality: 0.004)
        let related = EntityRecord(
            id: "place:northern-channel", canonicalName: "Northern Channel", entityType: .place, storyCount: 9,
            firstSeen: now.addingTimeInterval(-20 * 86_400), lastSeen: now, centrality: 0.002)
        let counts = [0, 0, 1, 0, 0, 2, 1, 0, 0, 0, 1, 0, 3, 1, 0, 0, 2, 0, 1, 0, 0, 4, 2, 1, 0, 1, 3, 2, 1, 2]
        return EntityDossier(
            entity: entity,
            coverage: counts.enumerated().map {
                EntityCoverageDay(
                    day: DatabaseEngine.windowStart(now: now).addingTimeInterval(Double($0.offset) * 86_400),
                    storyCount: $0.element)
            },
            publishers: [
                EntityPublisherShare(publisher: "Reuters", storyCount: 9, share: 0.43),
                EntityPublisherShare(publisher: "Associated Press", storyCount: 7, share: 0.33),
                EntityPublisherShare(publisher: "Metro Desk", storyCount: 5, share: 0.24),
            ],
            recentStories: [
                EntityStoryReference(
                    id: "a", title: "Harbour authority reopens the northern channel after storm damage",
                    publisher: "Reuters", date: now.addingTimeInterval(-3_600)),
                EntityStoryReference(
                    id: "b", title: "Ferries resume a reduced timetable while divers inspect the breakwater",
                    publisher: "Metro Desk", date: now.addingTimeInterval(-90_000)),
            ],
            related: [RelatedEntity(entity: related, sharedStories: 8, score: 0.3)])
    }

    private static let left = [
        "Harbour authority reopens the northern channel after storm damage",
        "Ferries resume a reduced timetable while divers inspect the breakwater.",
        "The authority said the channel will stay closed to freight until Friday.",
        "Residents on the quay were told to expect noise from repair crews overnight.",
    ]
    private static let right = [
        "Northern channel reopens to ferries after storm repairs",
        "A reduced ferry timetable starts today as divers check the breakwater for cracks.",
        "A port spokesperson blamed the delay on a late delivery of replacement bollards.",
    ]

    private static var session: DualReaderSession {
        func pair(
            _ l: Int, _ r: Int, _ similarity: Float, _ type: PerspectiveContrastType,
            side: PassageContrastPair.Side? = nil
        )
            -> PassageContrastPair
        {
            PassageContrastPair(
                id: "\(l)-\(r)", leftPassageIndex: l, rightPassageIndex: r, leftSnippet: left[l],
                rightSnippet: right[r],
                similarityScore: similarity, contrastType: type, uniqueSide: side)
        }
        return DualReaderSession(
            leftArticleId: "l", rightArticleId: "r", leftPublisherName: "Reuters", rightPublisherName: "Metro Desk",
            passageAlignments: [
                pair(0, 0, 0.86, .consensus), pair(1, 1, 0.83, .consensus), pair(2, 2, 0.6, .divergence),
                pair(3, 2, 0.2, .uniqueLead, side: .left),
            ])
    }

    private static var hotspots: (regions: [HotspotRegion], pins: [HotspotClusterPin]) {
        let service = HotspotProjectionService()
        func pin(_ name: String, _ tension: Double, _ stories: Int) -> HotspotClusterPin? {
            guard let place = service.resolveLocation(for: name) else { return nil }
            return HotspotClusterPin(
                id: place.name, title: place.name.capitalized, coordinate: place.coordinate, tensionScore: tension,
                topPublisherIds: [], storyCount: stories, isApproximate: service.isApproximate(place.name))
        }
        let pins = [
            pin("Kyiv", 82, 6), pin("Gaza", 74, 5), pin("Sudan", 55, 3), pin("Taipei", 38, 2), pin("Red Sea", 31, 2),
        ].compactMap { $0 }
        let regions = [("UA", 82.0), ("ME", 74.0), ("TW", 38.0)].compactMap { id, tension in
            HotspotProjectionService.regionAnchors.first { $0.id == id }.map {
                HotspotRegion(
                    id: $0.id, name: $0.name, centroid: $0.centroid, tensionScore: tension, activeClusterCount: 1,
                    articleCount: 3)
            }
        }
        return (regions, pins)
    }

    @MainActor
    private static func capture(into output: URL) -> Int {
        let map = hotspots
        let subjects: [(name: String, size: CGSize, view: AnyView)] = [
            (
                "dossier", CGSize(width: AppLayout.entityDossierWidth, height: AppLayout.entityDossierMaxHeight),
                AnyView(EntityDossierView(dossier: dossier, canGoBack: true))
            ),
            (
                "dual-reader-wide",
                CGSize(width: AppLayout.dualReaderSheetWidth, height: AppLayout.dualReaderSheetHeight),
                AnyView(DualReaderView(session: session, leftPassages: left, rightPassages: right))
            ),
            (
                "dual-reader-stacked",
                CGSize(width: AppLayout.dualReaderSheetMinimumWidth, height: AppLayout.dualReaderSheetHeight),
                AnyView(DualReaderView(session: session, leftPassages: left, rightPassages: right))
            ),
            (
                "hotspot-map",
                CGSize(
                    width: AppLayout.tensionSheetWidth - 2 * AppLayout.pageInset, height: AppLayout.hotspotMapHeight),
                AnyView(GlobalHotspotMapView(regions: map.regions, clusterPins: map.pins))
            ),
        ]
        let variants:
            [(name: String, appearance: NSAppearance.Name, scheme: ColorScheme, contrast: ColorSchemeContrast)] = [
                ("light", .aqua, .light, .standard), ("dark", .darkAqua, .dark, .standard),
                ("light-ic", .accessibilityHighContrastAqua, .light, .increased),
                ("dark-ic", .accessibilityHighContrastDarkAqua, .dark, .increased),
            ]
        var failures = 0
        for subject in subjects {
            for variant in variants {
                let appearance = NSAppearance(named: variant.appearance) ?? NSAppearance.currentDrawing()
                let hosting = NSHostingView(
                    rootView: subject.view
                        .frame(width: subject.size.width, height: subject.size.height)
                        .background(AppColor.background)
                        .environment(\.colorScheme, variant.scheme)
                        .environment(\.overrideContrast, variant.contrast)
                        .environment(\.overrideReduceMotion, true))
                hosting.appearance = appearance
                hosting.frame = NSRect(origin: .zero, size: subject.size)
                // The popover and the charts draw only inside a window; this one is never ordered on screen.
                let window = NSWindow(
                    contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = hosting
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                var rendered: NSBitmapImageRep?
                appearance.performAsCurrentDrawingAppearance {
                    hosting.layoutSubtreeIfNeeded()
                    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    rendered = bitmap
                }
                window.contentView = nil
                let name = "\(subject.name)-\(variant.name)"
                guard let bitmap = rendered, distinctColors(bitmap) > 8 else {
                    print("  blank: \(name)")
                    failures += 1
                    continue
                }
                do {
                    try write(bitmap, to: output.appendingPathComponent("\(name).png"))
                } catch {
                    print("  write failed: \(name): \(error.localizedDescription)")
                    failures += 1
                }
            }
        }
        return failures
    }

    private static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 24) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 24) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(
                    UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8
                        | UInt32(color.blueComponent * 255))
            }
        }
        return seen.count
    }

    private static func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try png.write(to: url)
    }
}
