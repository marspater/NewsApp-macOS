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

/// Dedicated interactive global hotspot map with offline vector projection (#718).
public struct GlobalHotspotMapView: View {
    public let regions: [HotspotRegion]
    public let clusterPins: [HotspotClusterPin]
    public let onSelectRegion: ((HotspotRegion?) -> Void)?
    public let onSelectPin: ((HotspotClusterPin?) -> Void)?
    /// The app's design-system colors for each tension band, and its in-app Increase Contrast setting; NewsUI cannot
    /// see either, so the host passes them in.
    public let levelColor: (HotspotTensionLevel) -> Color
    public let contrast: ColorSchemeContrast
    /// The in-app Reduce Motion setting, which the system environment cannot see; the pulse also stops in an
    /// inactive window.
    public let reduceMotion: Bool
    /// Score-tag text and fill; the host passes its design-system tokens.
    public let labelColor: Color
    public let labelBackground: Color

    @State private var selectedRegionId: String?
    @State private var selectedPinId: String?

    private let projectionService = HotspotProjectionService()

    public init(
        regions: [HotspotRegion],
        clusterPins: [HotspotClusterPin],
        levelColor: @escaping (HotspotTensionLevel) -> Color,
        contrast: ColorSchemeContrast = .standard,
        reduceMotion: Bool = false,
        labelColor: Color = .primary,
        labelBackground: Color = Color(NSColor.windowBackgroundColor),
        onSelectRegion: ((HotspotRegion?) -> Void)? = nil,
        onSelectPin: ((HotspotClusterPin?) -> Void)? = nil
    ) {
        self.regions = regions
        self.clusterPins = clusterPins
        self.levelColor = levelColor
        self.contrast = contrast
        self.reduceMotion = reduceMotion
        self.labelColor = labelColor
        self.labelBackground = labelBackground
        self.onSelectRegion = onSelectRegion
        self.onSelectPin = onSelectPin
    }

    private var isHighContrast: Bool { contrast == .increased }
    @Environment(\.controlActiveState) private var controlActiveState
    private var pulses: Bool { !reduceMotion && controlActiveState != .inactive }

    static let pulsePeriod: TimeInterval = 2.0

    /// Where a pin's pulse is in its cycle, 0 ..< 1.
    static func pulsePhase(at time: TimeInterval) -> Double {
        let phase = (time / pulsePeriod).truncatingRemainder(dividingBy: 1.0)
        return phase < 0 ? phase + 1.0 : phase
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ZStack(alignment: .bottom) {
                GeometryReader { geometry in
                    let canvasSize = geometry.size
                    ZStack {
                        // Offline Map Background & Continents
                        offlineVectorMap

                        // Hotspot Regional Tension Glows
                        ForEach(regions) { region in
                            regionGlowView(region: region, canvasSize: canvasSize)
                        }

                        // Interactive Cluster Pins
                        ForEach(clusterPins) { pin in
                            clusterPinView(pin: pin, canvasSize: canvasSize)
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                }

                // Selected Region / Pin Detail Bar
                if let selected = activeSelectionSummary {
                    selectionDetailBar(summary: selected)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(minHeight: 280)
    }

    // MARK: - Header & Legend

    private var headerBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "globe.europe.africa.fill")
                    .foregroundColor(.accentColor)
                    .font(.title3)
                Text("Global Hotspot Intelligence")
                    .font(.headline)
            }

            Spacer()

            // Tension Legend
            HStack(spacing: 12) {
                legendItem(color: levelColor(.elevated), label: "Elevated (<35)")
                legendItem(color: levelColor(.significant), label: "Significant (35-69)")
                legendItem(color: levelColor(.critical), label: "Critical (70-100)")
            }

            if selectedRegionId != nil || selectedPinId != nil {
                Button("Reset Filter") {
                    selectedRegionId = nil
                    selectedPinId = nil
                    onSelectRegion?(nil)
                    onSelectPin?(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Offline Vector Map Canvas

    private var offlineVectorMap: some View {
        Canvas { context, canvasSize in
            // Map Water Background
            let bgRect = CGRect(origin: .zero, size: canvasSize)
            context.fill(Path(bgRect), with: .color(Color(NSColor.controlBackgroundColor).opacity(0.85)))

            // Equator and Meridian Graticules
            var gridPath = Path()
            let equatorY = canvasSize.height / 2.0
            gridPath.move(to: CGPoint(x: 0, y: equatorY))
            gridPath.addLine(to: CGPoint(x: canvasSize.width, y: equatorY))

            let primeX = canvasSize.width / 2.0
            gridPath.move(to: CGPoint(x: primeX, y: 0))
            gridPath.addLine(to: CGPoint(x: primeX, y: canvasSize.height))

            context.stroke(gridPath, with: .color(Color.secondary.opacity(0.15)), lineWidth: 1)

            // Offline Simplified Continent Outlines
            let continentColor = Color(NSColor.separatorColor).opacity(0.4)
            drawLandmasses(in: &context, size: canvasSize, color: continentColor)
        }
    }

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

    private func drawLandmasses(in context: inout GraphicsContext, size: CGSize, color: Color) {
        for coastline in Self.landmasses {
            var path = Path()
            for (index, point) in coastline.enumerated() {
                let projected = projectionService.projectEquirectangular(
                    coordinate: GeographicCoordinate(latitude: point.lat, longitude: point.lon),
                    canvasSize: size)
                if index == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
            }
            path.closeSubpath()
            context.fill(path, with: .color(color))
        }
    }

    // MARK: - Hotspot Region Glows

    private func selectRegion(_ region: HotspotRegion) {
        selectedRegionId = region.id
        selectedPinId = nil
        onSelectRegion?(region)
    }

    private func selectPin(_ pin: HotspotClusterPin) {
        selectedPinId = pin.id
        selectedRegionId = nil
        onSelectPin?(pin)
    }

    /// The tension number beside a marker, so the level never rests on color alone; the band shows in its outline.
    private func scoreTag(_ score: Double, color: Color) -> some View {
        Text("\(Int(score))")
            .font(.caption2.weight(.bold))
            .foregroundStyle(labelColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(labelBackground, in: Capsule())
            .overlay(Capsule().stroke(color, lineWidth: isHighContrast ? 2 : 1))
    }

    private func regionGlowView(region: HotspotRegion, canvasSize: CGSize) -> some View {
        let pt = projectionService.projectEquirectangular(
            coordinate: region.centroid,
            canvasSize: canvasSize
        )
        let isSelected = selectedRegionId == region.id
        let color = tensionColor(for: region.tensionScore)
        let glow = isHighContrast ? 0.2 : 0.0

        // A button, so it takes keyboard focus and VoiceOver activation as well as a click.
        return Button {
            selectRegion(region)
        } label: {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color.opacity((isSelected ? 0.45 : 0.25) + glow), color.opacity(0.0)],
                            center: .center,
                            startRadius: 2,
                            endRadius: isSelected ? 45 : 30
                        )
                    )
                    .frame(width: isSelected ? 90 : 60, height: isSelected ? 90 : 60)

                Circle()
                    .stroke(
                        color.opacity(isSelected || isHighContrast ? 0.9 : 0.5),
                        lineWidth: (isSelected ? 2 : 1) + (isHighContrast ? 1 : 0)
                    )
                    .frame(width: isSelected ? 24 : 16, height: isSelected ? 24 : 16)

                scoreTag(region.tensionScore, color: color)
                    .offset(y: isSelected ? 22 : 18)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .position(pt)
        .accessibilityLabel(
            "\(region.name), \(region.tensionLevel.displayName), tension \(Int(region.tensionScore)) of 100"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Cluster Pins

    /// An expanding ring behind a pin, sized from the pin; static (invisible) with Reduce Motion or an inactive window.
    private func pulseRing(color: Color, diameter: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !pulses)) { timeline in
            let phase = pulses ? Self.pulsePhase(at: timeline.date.timeIntervalSinceReferenceDate) : 0
            Circle()
                .stroke(color.opacity(pulses ? 0.6 * (1 - phase) : 0), lineWidth: 2)
                .frame(width: diameter, height: diameter)
                .scaleEffect(1 + phase)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func clusterPinView(pin: HotspotClusterPin, canvasSize: CGSize) -> some View {
        let pt = projectionService.projectEquirectangular(
            coordinate: pin.coordinate,
            canvasSize: canvasSize
        )
        let isSelected = selectedPinId == pin.id
        let color = tensionColor(for: pin.tensionScore)

        return Button {
            selectPin(pin)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "mappin.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.pinSize(for: pin) + (isSelected ? 4 : 0))
                    .foregroundColor(color)
                    .shadow(color: color.opacity(0.6), radius: isSelected ? 4 : 2)
                    .background { pulseRing(color: color, diameter: Self.pinSize(for: pin)) }

                scoreTag(pin.tensionScore, color: color)
            }
        }
        .buttonStyle(.plain)
        .position(pt)
        .accessibilityLabel(
            "\(pin.title), tension \(Int(pin.tensionScore)) of 100, \(pin.storyCount) stories"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Selection Detail Drawer

    private struct HotspotSelectionSummary {
        let title: String
        let subtitle: String
        let tension: Double
        let count: Int
    }

    private var activeSelectionSummary: HotspotSelectionSummary? {
        if let pinId = selectedPinId, let pin = clusterPins.first(where: { $0.id == pinId }) {
            return HotspotSelectionSummary(
                title: pin.title,
                subtitle: "Active Event Cluster • \(pin.storyCount) stories",
                tension: pin.tensionScore,
                count: pin.storyCount
            )
        } else if let regionId = selectedRegionId, let region = regions.first(where: { $0.id == regionId }) {
            return HotspotSelectionSummary(
                title: region.name,
                subtitle: "\(region.activeClusterCount) active clusters • \(region.articleCount) stories",
                tension: region.tensionScore,
                count: region.articleCount
            )
        }
        return nil
    }

    private func selectionDetailBar(summary: HotspotSelectionSummary) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.headline)
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Text("Tension Index:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(Int(summary.tension))/100")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(tensionColor(for: summary.tension))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tensionColor(for: summary.tension).opacity(0.12))
            .cornerRadius(8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    /// A pin grows with its coverage (up to ten stories) and its tension, between 14 and 30 pt.
    static func pinSize(for pin: HotspotClusterPin) -> CGFloat {
        let coverage = min(Double(pin.storyCount), 10.0) / 10.0
        let tension = min(max(pin.tensionScore, 0.0), 100.0) / 100.0
        return CGFloat(14.0 + 8.0 * coverage + 8.0 * tension)
    }

    private func tensionColor(for score: Double) -> Color {
        levelColor(HotspotTensionLevel.level(for: score))
    }
}
