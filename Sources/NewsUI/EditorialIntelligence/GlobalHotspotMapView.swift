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

    @State private var selectedRegionId: String?
    @State private var selectedPinId: String?
    @State private var hoverPinId: String?

    private let projectionService = HotspotProjectionService()

    public init(
        regions: [HotspotRegion] = HotspotProjectionService.standardRegions,
        clusterPins: [HotspotClusterPin] = [],
        onSelectRegion: ((HotspotRegion?) -> Void)? = nil,
        onSelectPin: ((HotspotClusterPin?) -> Void)? = nil
    ) {
        self.regions = regions
        self.clusterPins = clusterPins
        self.onSelectRegion = onSelectRegion
        self.onSelectPin = onSelectPin
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
        .frame(minWidth: 700, minHeight: 450)
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
                legendItem(color: .green, label: "Elevated (<35)")
                legendItem(color: .orange, label: "Significant (35-70)")
                legendItem(color: .red, label: "Critical (>70)")
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

    private func drawContinentPaths(in context: inout GraphicsContext, size: CGSize, color: Color) {
        // Simplified polygon landmasses for 100% offline projection
        let continents: [[CGPoint]] = [
            // North America
            [
                projectNormalized(x: 0.12, y: 0.15, size: size),
                projectNormalized(x: 0.28, y: 0.15, size: size),
                projectNormalized(x: 0.32, y: 0.35, size: size),
                projectNormalized(x: 0.24, y: 0.52, size: size),
                projectNormalized(x: 0.18, y: 0.45, size: size),
                projectNormalized(x: 0.10, y: 0.30, size: size),
            ],
            // South America
            [
                projectNormalized(x: 0.26, y: 0.55, size: size),
                projectNormalized(x: 0.36, y: 0.58, size: size),
                projectNormalized(x: 0.33, y: 0.85, size: size),
                projectNormalized(x: 0.27, y: 0.88, size: size),
                projectNormalized(x: 0.24, y: 0.65, size: size),
            ],
            // Europe
            [
                projectNormalized(x: 0.46, y: 0.18, size: size),
                projectNormalized(x: 0.58, y: 0.18, size: size),
                projectNormalized(x: 0.56, y: 0.38, size: size),
                projectNormalized(x: 0.44, y: 0.38, size: size),
            ],
            // Africa
            [
                projectNormalized(x: 0.46, y: 0.42, size: size),
                projectNormalized(x: 0.60, y: 0.42, size: size),
                projectNormalized(x: 0.58, y: 0.78, size: size),
                projectNormalized(x: 0.50, y: 0.78, size: size),
                projectNormalized(x: 0.42, y: 0.52, size: size),
            ],
            // Asia
            [
                projectNormalized(x: 0.60, y: 0.15, size: size),
                projectNormalized(x: 0.88, y: 0.18, size: size),
                projectNormalized(x: 0.82, y: 0.55, size: size),
                projectNormalized(x: 0.68, y: 0.52, size: size),
                projectNormalized(x: 0.60, y: 0.35, size: size),
            ],
            // Australia
            [
                projectNormalized(x: 0.78, y: 0.68, size: size),
                projectNormalized(x: 0.90, y: 0.68, size: size),
                projectNormalized(x: 0.88, y: 0.85, size: size),
                projectNormalized(x: 0.78, y: 0.85, size: size),
            ],
        ]

        for poly in continents {
            var path = Path()
            guard let first = poly.first else { continue }
            path.move(to: first)
            for pt in poly.dropFirst() {
                path.addLine(to: pt)
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

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(isSelected ? 0.45 : 0.25), color.opacity(0.0)],
                        center: .center,
                        startRadius: 2,
                        endRadius: isSelected ? 45 : 30
                    )
                )
                .frame(width: isSelected ? 90 : 60, height: isSelected ? 90 : 60)

            Circle()
                .stroke(color.opacity(isSelected ? 0.9 : 0.5), lineWidth: isSelected ? 2 : 1)
                .frame(width: isSelected ? 24 : 16, height: isSelected ? 24 : 16)
        }
        .position(pt)
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
                .font(isSelected ? .title2 : .body)
                .foregroundColor(color)
                .shadow(color: color.opacity(0.6), radius: isSelected ? 4 : 2)

            Text("\(Int(pin.tensionScore))")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color)
                .cornerRadius(4)
        }
        .position(pt)
        .onTapGesture {
            selectedPinId = pin.id
            selectedRegionId = nil
            onSelectPin?(pin)
        }
    }

    // MARK: - Selection Detail Drawer

    private var activeSelectionSummary: (title: String, subtitle: String, tension: Double, count: Int)? {
        if let pinId = selectedPinId, let pin = clusterPins.first(where: { $0.id == pinId }) {
            return (
                title: pin.title,
                subtitle: "Active Event Cluster • \(pin.storyCount) stories",
                tension: pin.tensionScore,
                count: pin.storyCount
            )
        } else if let regionId = selectedRegionId, let region = regions.first(where: { $0.id == regionId }) {
            return (
                title: region.name,
                subtitle: "\(region.activeClusterCount) active clusters • \(region.articleCount) stories",
                tension: region.tensionScore,
                count: region.articleCount
            )
        }
        return nil
    }

    private func selectionDetailBar(summary: (title: String, subtitle: String, tension: Double, count: Int))
        -> some View
    {
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

    private func tensionColor(for score: Double) -> Color {
        if score >= 70.0 {
            return .red
        } else if score >= 35.0 {
            return .orange
        } else {
            return .green
        }
    }
}
