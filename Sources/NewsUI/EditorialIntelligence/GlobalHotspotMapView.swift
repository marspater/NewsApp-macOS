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

    @State private var selectedRegionId: String?
    @State private var selectedPinId: String?
    @State private var hoverPinId: String?

    private let projectionService = HotspotProjectionService()

    public init(
        regions: [HotspotRegion],
        clusterPins: [HotspotClusterPin],
        levelColor: @escaping (HotspotTensionLevel) -> Color,
        contrast: ColorSchemeContrast = .standard,
        onSelectRegion: ((HotspotRegion?) -> Void)? = nil,
        onSelectPin: ((HotspotClusterPin?) -> Void)? = nil
    ) {
        self.regions = regions
        self.clusterPins = clusterPins
        self.levelColor = levelColor
        self.contrast = contrast
        self.onSelectRegion = onSelectRegion
        self.onSelectPin = onSelectPin
    }

    private var isHighContrast: Bool { contrast == .increased }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ZStack(alignment: .bottom) {
                GeometryReader { geometry in
                    let canvasSize = geometry.size
                    ZStack {
                        // Offline Map Background & Continents
                        offlineVectorMap(size: canvasSize)

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

    private func offlineVectorMap(size: CGSize) -> some View {
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
            drawContinentPaths(in: &context, size: canvasSize, color: continentColor)
        }
    }

    private static let continentPolygons: [[[Double]]] = [
        // North America
        [[0.12, 0.15], [0.28, 0.15], [0.32, 0.35], [0.24, 0.52], [0.18, 0.45], [0.10, 0.30]],
        // South America
        [[0.26, 0.55], [0.36, 0.58], [0.33, 0.85], [0.27, 0.88], [0.24, 0.65]],
        // Europe
        [[0.46, 0.18], [0.58, 0.18], [0.56, 0.38], [0.44, 0.38]],
        // Africa
        [[0.46, 0.42], [0.60, 0.42], [0.58, 0.78], [0.50, 0.78], [0.42, 0.52]],
        // Asia
        [[0.60, 0.15], [0.88, 0.18], [0.82, 0.55], [0.68, 0.52], [0.60, 0.35]],
        // Australia
        [[0.78, 0.68], [0.90, 0.68], [0.88, 0.85], [0.78, 0.85]],
    ]

    private func drawContinentPaths(in context: inout GraphicsContext, size: CGSize, color: Color) {
        for poly in Self.continentPolygons {
            var path = Path()
            guard let first = poly.first else { continue }
            path.move(to: projectNormalized(x: first[0], y: first[1], size: size))
            for pt in poly.dropFirst() {
                path.addLine(to: projectNormalized(x: pt[0], y: pt[1], size: size))
            }
            path.closeSubpath()
            context.fill(path, with: .color(color))
        }
    }

    private func projectNormalized(x: CGFloat, y: CGFloat, size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    // MARK: - Hotspot Region Glows

    private func regionGlowView(region: HotspotRegion, canvasSize: CGSize) -> some View {
        let pt = projectionService.projectEquirectangular(
            coordinate: region.centroid,
            canvasSize: canvasSize
        )
        let isSelected = selectedRegionId == region.id
        let color = tensionColor(for: region.tensionScore)
        let glow = isHighContrast ? 0.2 : 0.0

        return ZStack {
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
        }
        .position(pt)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(region.name), \(region.tensionLevel.displayName), tension \(Int(region.tensionScore)) of 100"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            selectedRegionId = region.id
            selectedPinId = nil
            onSelectRegion?(region)
        }
        .onTapGesture {
            selectedRegionId = region.id
            selectedPinId = nil
            onSelectRegion?(region)
        }
    }

    // MARK: - Cluster Pins

    private func clusterPinView(pin: HotspotClusterPin, canvasSize: CGSize) -> some View {
        let pt = projectionService.projectEquirectangular(
            coordinate: pin.coordinate,
            canvasSize: canvasSize
        )
        let isSelected = selectedPinId == pin.id
        let color = tensionColor(for: pin.tensionScore)

        return VStack(spacing: 2) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: Self.pinSize(for: pin) + (isSelected ? 4 : 0)))
                .foregroundColor(color)
                .shadow(color: color.opacity(0.6), radius: isSelected ? 4 : 2)

            // Primary text on the window background keeps its contrast on every band; the band shows in the outline.
            Text("\(Int(pin.tensionScore))")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color(NSColor.windowBackgroundColor), in: Capsule())
                .overlay(Capsule().stroke(color, lineWidth: isHighContrast ? 2 : 1))
        }
        .position(pt)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(pin.title), tension \(Int(pin.tensionScore)) of 100, \(pin.storyCount) stories"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            selectedPinId = pin.id
            selectedRegionId = nil
            onSelectPin?(pin)
        }
        .onTapGesture {
            selectedPinId = pin.id
            selectedRegionId = nil
            onSelectPin?(pin)
        }
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
                subtitle: "\(pin.storyCount) headlines about this place",
                tension: pin.tensionScore,
                count: pin.storyCount
            )
        } else if let regionId = selectedRegionId, let region = regions.first(where: { $0.id == regionId }) {
            return HotspotSelectionSummary(
                title: region.name,
                subtitle: "\(region.activeClusterCount) mapped places • \(region.articleCount) headlines",
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
                Text("Headline cue index:")
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
