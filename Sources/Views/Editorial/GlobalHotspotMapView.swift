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

import SwiftUI

/// The offline map of the places a World Tension reading's headlines name (W4 #718): regions glow with the cue index
/// of their headlines, places are pins that grow with their coverage and tension, and choosing either narrows the
/// sheet's headline table to it. Nothing is fetched: the coastlines are bundled. A pin marks the center of a named
/// place and never where anything happened, so a country or a sea draws as a dashed circle and says so.
struct GlobalHotspotMapView: View {
    let regions: [HotspotRegion]
    let clusterPins: [HotspotClusterPin]
    var onSelectRegion: (HotspotRegion?) -> Void = { _ in
        // The map filters nothing by itself; the sheet passes the handler that narrows its headline table.
    }
    var onSelectPin: (HotspotClusterPin?) -> Void = { _ in
        // The map filters nothing by itself; the sheet passes the handler that narrows its headline table.
    }

    @State private var selectedRegionId: String?
    @State private var selectedPinId: String?
    @Environment(\.effectiveContrast) private var contrast
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appearsActive) private var appearsActive

    /// The pulse stops under Reduce Motion, in an inactive window and while the app is in the background, as the
    /// flame in the sheet header does.
    private var pulses: Bool { !reduceMotion && scenePhase == .active && appearsActive }

    /// Where a pin's pulse is in its cycle, 0 ..< 1.
    static func pulsePhase(at time: TimeInterval) -> Double {
        let phase = (time / AppMotion.pulsePeriod).truncatingRemainder(dividingBy: 1.0)
        return phase < 0 ? phase + 1.0 : phase
    }

    /// A pin grows with its coverage (up to ten stories) and its tension, and an area draws larger.
    static func pinSize(for pin: HotspotClusterPin) -> CGFloat {
        let coverage = min(Double(pin.storyCount), 10.0) / 10.0
        let tension = min(max(pin.tensionScore, 0.0), 100.0) / 100.0
        let size = AppLayout.hotspotPinMinimumSize + AppLayout.hotspotPinGrowth * CGFloat(coverage + tension)
        return pin.isApproximate ? size * AppLayout.hotspotApproximateScale : size
    }

    var body: some View {
        VStack(spacing: 0) {
            legend
            Divider()
            ZStack(alignment: .bottom) {
                GeometryReader { geometry in
                    let viewport = HotspotViewport.fitting(
                        regions.map(\.centroid) + clusterPins.map(\.coordinate),
                        aspect: geometry.size.width / max(geometry.size.height, 1))
                    ZStack {
                        coastlines(in: viewport)
                        ForEach(regions) { regionMarker($0, viewport: viewport, in: geometry.size) }
                        ForEach(clusterPins) { pinMarker($0, viewport: viewport, in: geometry.size) }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if let summary = selection { detailBar(summary) }
            }
        }
        .background(AppColor.mapWater)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map of the places the current headlines name")
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            ReaderTagLayout(spacing: AppSpacing.sm) {
                ForEach(HotspotTensionLevel.allCases, id: \.self) { level in
                    HStack(spacing: AppSpacing.xxs) {
                        Circle().fill(AppColor.hotspot(level))
                            .frame(width: AppLayout.tensionDotSize, height: AppLayout.tensionDotSize)
                            .accessibilityHidden(true)
                        Text(Self.legendText(level))
                    }
                }
                HStack(spacing: AppSpacing.xxs) {
                    Image(systemName: "circle.dashed").accessibilityHidden(true)
                    Text("Country or sea: its center, not a location")
                }
            }
            .font(AppTypography.caption)
            .foregroundStyle(AppColor.secondaryText)
            if selectedRegionId != nil || selectedPinId != nil {
                Button("Reset Filter") {
                    selectedRegionId = nil
                    selectedPinId = nil
                    onSelectRegion(nil)
                    onSelectPin(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColor.surface)
    }

    static func legendText(_ level: HotspotTensionLevel) -> String {
        switch level {
        case .elevated: return "\(level.displayName) (below 35)"
        case .significant: return "\(level.displayName) (35–69)"
        case .critical: return "\(level.displayName) (70–100)"
        }
    }

    // MARK: - Coastlines

    private func coastlines(in viewport: HotspotViewport) -> some View {
        Canvas { context, size in
            // The equator and the prime meridian, where the viewport holds them.
            var graticule = Path()
            let equator = viewport.project(GeographicCoordinate(latitude: 0, longitude: 0), in: size)
            if (0...size.height).contains(equator.y) {
                graticule.move(to: CGPoint(x: 0, y: equator.y))
                graticule.addLine(to: CGPoint(x: size.width, y: equator.y))
            }
            if (0...size.width).contains(equator.x) {
                graticule.move(to: CGPoint(x: equator.x, y: 0))
                graticule.addLine(to: CGPoint(x: equator.x, y: size.height))
            }
            context.stroke(graticule, with: .color(AppColor.mapGraticule), lineWidth: AppLayout.hairline)
            for coastline in Self.landmasses {
                context.fill(Self.path(of: coastline, in: viewport, size: size), with: .color(AppColor.mapLand))
            }
            for water in Self.inlandWaters {
                context.fill(Self.path(of: water, in: viewport, size: size), with: .color(AppColor.mapWater))
            }
        }
        .accessibilityHidden(true)
    }

    private static func path(of ring: [(lat: Double, lon: Double)], in viewport: HotspotViewport, size: CGSize) -> Path
    {
        var path = Path()
        for (index, point) in ring.enumerated() {
            let projected = viewport.project(GeographicCoordinate(latitude: point.lat, longitude: point.lon), in: size)
            if index == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
        }
        path.closeSubpath()
        return path
    }

    /// Inland seas and the Gulf, painted over the land so they read as water at the zoom the map fits to.
    private static let inlandWaters: [[(lat: Double, lon: Double)]] = [
        // Black Sea
        [
            (41.2, 29.1), (43.2, 28.0), (44.2, 28.7), (45.2, 29.7), (46.6, 31.0), (46.0, 33.5), (44.4, 33.6),
            (45.0, 36.5), (44.6, 37.8), (43.6, 39.8), (41.65, 41.65), (41.0, 39.5), (41.3, 36.3), (42.0, 35.2),
            (41.9, 32.5),
        ],
        // Caspian Sea
        [
            (47.0, 49.5), (45.5, 53.0), (42.0, 52.8), (40.0, 53.0), (37.0, 54.0), (37.0, 50.0), (39.0, 49.0),
            (41.5, 50.2), (43.0, 47.5), (45.5, 47.0),
        ],
        // Persian Gulf
        [(30.0, 48.5), (29.5, 50.5), (27.0, 52.0), (26.0, 56.0), (24.0, 54.0), (25.0, 51.5), (28.0, 49.5)],
    ]

    /// Simplified coastlines as (latitude, longitude) rings, projected with the same equirectangular projection as the
    /// markers so that glows and pins sit on the landmass they name.
    private static let landmasses: [[(lat: Double, lon: Double)]] = [
        // North America
        [
            (66, -168), (71, -156), (70, -128), (68, -96), (60, -94), (58, -78), (62, -70), (52, -56), (47, -53),
            (44, -66), (40, -74), (35, -76), (30, -81), (25, -80), (25, -97), (19, -96), (21, -87), (16, -88),
            (10, -84), (8, -78), (8, -81), (15, -93), (20, -105), (23, -110), (32, -117), (40, -124), (48, -124),
            (55, -130), (60, -145), (57, -158), (64, -166),
        ],
        // South America
        [
            (12, -72), (10, -62), (5, -52), (0, -50), (-7, -35), (-13, -38), (-23, -42), (-35, -57), (-41, -62),
            (-52, -68), (-55, -68), (-50, -75), (-40, -73), (-30, -71), (-18, -70), (-5, -81), (1, -80), (8, -77),
        ],
        // Eurasia
        [
            (71, 28), (70, 60), (73, 80), (76, 105), (73, 130), (70, 160), (66, 180), (60, 163), (52, 156), (51, 141),
            (43, 132), (39, 128), (35, 129), (39, 121), (37, 122), (31, 122), (22, 114), (21, 108), (10, 107), (9, 105),
            (13, 100), (8, 100), (2, 104), (16, 94), (22, 91), (16, 82), (8, 77), (21, 72), (25, 66), (25, 57),
            (22, 60), (12, 45), (15, 42), (28, 34), (31, 34), (36, 36), (37, 27), (40, 26), (38, 22), (40, 18),
            (45, 13), (44, 8), (43, 3), (37, -1), (36, -6), (37, -9), (43, -9), (48, -5), (51, 2), (54, 8), (57, 10),
            (55, 13), (59, 18), (65, 22), (63, 10), (70, 23),
        ],
        // Africa
        [
            (37, 10), (37, -2), (35, -6), (28, -13), (21, -17), (15, -17), (5, -8), (5, 8), (4, 10), (-5, 12),
            (-12, 14), (-22, 14), (-34, 18), (-34, 26), (-27, 33), (-16, 40), (-5, 40), (5, 48), (12, 51), (11, 43),
            (18, 39), (28, 33), (31, 32),
        ],
        // Great Britain and Ireland
        [(58, -5), (57, -2), (53, 0), (51, 1), (50, -5), (53, -4), (55, -6)],
        // Japan
        [(45, 142), (41, 142), (35, 140), (34, 135), (31, 131), (34, 130), (37, 137), (40, 140)],
        // Australia
        [
            (-11, 131), (-12, 142), (-19, 147), (-28, 153), (-38, 150), (-38, 141), (-35, 135), (-32, 127), (-34, 115),
            (-22, 114), (-15, 124),
        ],
    ]

    // MARK: - Markers

    private func selectRegion(_ region: HotspotRegion) {
        selectedRegionId = region.id
        selectedPinId = nil
        onSelectRegion(region)
    }

    private func selectPin(_ pin: HotspotClusterPin) {
        selectedPinId = pin.id
        selectedRegionId = nil
        onSelectPin(pin)
    }

    /// The cue index beside a marker, so a band never rests on color alone; the band also shows in the outline.
    private func scoreTag(_ score: Double, color: Color) -> some View {
        Text("\(Int(score))")
            .font(AppTypography.eyebrow)
            .foregroundStyle(AppColor.primaryText)
            .monospacedDigit()
            .padding(.horizontal, AppSpacing.xxs)
            .padding(.vertical, AppSpacing.textStack)
            .background(AppColor.background, in: Capsule())
            .overlay {
                Capsule().stroke(
                    color,
                    lineWidth: contrast == .increased ? AppLayout.hotspotTagStrokeStrong : AppLayout.hotspotTagStroke)
            }
    }

    /// A region is a button, so it takes keyboard focus and VoiceOver activation as well as a click. Its ring grows with
    /// its tension, so the level shows by size as well as by color, and the number stays for the places inside it.
    private func regionMarker(_ region: HotspotRegion, viewport: HotspotViewport, in size: CGSize) -> some View {
        let isSelected = selectedRegionId == region.id
        let color = AppColor.hotspot(region.tensionLevel)
        let glow = isSelected ? AppLayout.hotspotGlowSelectedSize : AppLayout.hotspotGlowSize
        let ring =
            AppLayout.hotspotRingSize + AppLayout.hotspotRingGrowth
            * CGFloat(min(max(region.tensionScore, 0), 100) / 100)
            + (isSelected ? AppLayout.hotspotPinSelectedGrowth : 0)
        return Button {
            selectRegion(region)
        } label: {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [AppColor.hotspotGlow(color, selected: isSelected, contrast: contrast), .clear],
                            center: .center, startRadius: ring / 8, endRadius: glow / 2)
                    )
                    .frame(width: glow, height: glow)
                Circle()
                    .stroke(
                        AppColor.hotspotRing(color, selected: isSelected, contrast: contrast),
                        lineWidth: isSelected ? AppLayout.hotspotTagStrokeStrong : AppLayout.hotspotTagStroke
                    )
                    .frame(width: ring, height: ring)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .position(viewport.project(region.centroid, in: size))
        .accessibilityLabel(
            "\(region.name), \(region.tensionLevel.displayName), headline cue index \(Int(region.tensionScore)) of 100, \(region.articleCount) current headlines contributing to the cue index"
        )
        .accessibilityHint("Shows only the headlines about this region")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// An expanding ring behind a pin, sized from the pin; invisible and still when the pulse is off.
    private func pulseRing(color: Color, diameter: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: AppMotion.pulseFrameInterval, paused: !pulses)) { timeline in
            let phase = pulses ? Self.pulsePhase(at: timeline.date.timeIntervalSinceReferenceDate) : 0
            Circle()
                .stroke(
                    pulses ? AppColor.hotspotPulse(color, phase: phase) : .clear,
                    lineWidth: AppLayout.hotspotPulseStroke
                )
                .frame(width: diameter, height: diameter)
                .scaleEffect(1 + phase)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func pinMarker(_ pin: HotspotClusterPin, viewport: HotspotViewport, in size: CGSize) -> some View {
        let isSelected = selectedPinId == pin.id
        let color = AppColor.hotspot(pin.tensionLevel)
        let diameter = Self.pinSize(for: pin)
        return Button {
            selectPin(pin)
        } label: {
            VStack(spacing: AppSpacing.textStack) {
                Image(systemName: pin.isApproximate ? "circle.dashed" : "mappin.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: diameter + (isSelected ? AppLayout.hotspotPinSelectedGrowth : 0))
                    .foregroundStyle(color)
                    .background { pulseRing(color: color, diameter: diameter) }
                scoreTag(pin.tensionScore, color: color)
            }
        }
        .buttonStyle(.plain)
        .position(viewport.project(pin.coordinate, in: size))
        .accessibilityLabel(
            "\(pin.title)\(pin.isApproximate ? ", country or sea" : ""), headline cue index \(Int(pin.tensionScore)) of 100, \(pin.storyCount) current headlines contributing to the cue index"
        )
        .accessibilityHint("Shows only the headlines about this place")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Selection

    private struct Selection {
        let title: String
        let subtitle: String
        let note: String?
        let tension: Double
    }

    private var selection: Selection? {
        if let id = selectedPinId, let pin = clusterPins.first(where: { $0.id == id }) {
            return Selection(
                title: pin.title, subtitle: "\(pin.storyCount) current headlines contributing to the cue index",
                note: pin.isApproximate
                    ? "The marker shows the center of the area, not where anything happened." : nil,
                tension: pin.tensionScore)
        }
        if let id = selectedRegionId, let region = regions.first(where: { $0.id == id }) {
            return Selection(
                title: region.name,
                subtitle:
                    "\(region.activeClusterCount) mapped places · \(region.articleCount) current headlines contributing to the cue index",
                note: nil,
                tension: region.tensionScore)
        }
        return nil
    }

    private func detailBar(_ selection: Selection) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
                VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                    Text(selection.title).font(AppTypography.headline)
                    Text(selection.subtitle).font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                    if let note = selection.note {
                        Text(note).font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                    }
                }
                Spacer(minLength: AppSpacing.md)
                Text("Headline cue index \(Int(selection.tension))/100")
                    .font(AppTypography.label)
                    .foregroundStyle(AppColor.primaryText)
                    .monospacedDigit()
            }
            .padding(AppSpacing.sm)
        }
        .background(AppColor.surface)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
    #Preview("Hotspot map", traits: .modifier(PreviewEnvironment())) {
        GlobalHotspotMapView(regions: PreviewFixtures.hotspotRegions, clusterPins: PreviewFixtures.hotspotPins)
            .frame(width: AppLayout.tensionSheetWidth - 2 * AppLayout.pageInset, height: AppLayout.hotspotMapHeight)
            .padding(AppLayout.pageInset)
    }

    #Preview("Hotspot map accessibility", traits: .modifier(PreviewEnvironment())) {
        GlobalHotspotMapView(regions: PreviewFixtures.hotspotRegions, clusterPins: PreviewFixtures.hotspotPins)
            .frame(width: AppLayout.tensionSheetWidth - 2 * AppLayout.pageInset, height: AppLayout.hotspotMapHeight)
            .padding(AppLayout.pageInset)
            .previewAccessibility()
    }
#endif
