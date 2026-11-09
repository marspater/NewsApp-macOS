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

import CoreGraphics
import Foundation

/// Service providing on-device vector map projection, location coordinate resolution,
/// and regional hotspot aggregation without external map tile requests (#718).
public struct HotspotProjectionService: Sendable {
    public init() {}

    // MARK: - Standard Geopolitical Regions

    public static let standardRegions: [HotspotRegion] = [
        HotspotRegion(
            id: "UA",
            name: "Eastern Europe",
            centroid: GeographicCoordinate(latitude: 49.0, longitude: 31.0),
            tensionScore: 78.0,
            activeClusterCount: 12,
            articleCount: 45
        ),
        HotspotRegion(
            id: "ME",
            name: "Middle East",
            centroid: GeographicCoordinate(latitude: 29.5, longitude: 45.0),
            tensionScore: 82.0,
            activeClusterCount: 18,
            articleCount: 62
        ),
        HotspotRegion(
            id: "TW",
            name: "Taiwan Strait & East Asia",
            centroid: GeographicCoordinate(latitude: 24.0, longitude: 121.0),
            tensionScore: 68.0,
            activeClusterCount: 8,
            articleCount: 30
        ),
        HotspotRegion(
            id: "EU",
            name: "Western Europe",
            centroid: GeographicCoordinate(latitude: 48.0, longitude: 10.0),
            tensionScore: 32.0,
            activeClusterCount: 14,
            articleCount: 50
        ),
        HotspotRegion(
            id: "US",
            name: "North America",
            centroid: GeographicCoordinate(latitude: 38.0, longitude: -97.0),
            tensionScore: 28.0,
            activeClusterCount: 22,
            articleCount: 85
        ),
        HotspotRegion(
            id: "CN",
            name: "South China Sea",
            centroid: GeographicCoordinate(latitude: 16.0, longitude: 114.0),
            tensionScore: 64.0,
            activeClusterCount: 7,
            articleCount: 24
        ),
        HotspotRegion(
            id: "IN",
            name: "South Asia",
            centroid: GeographicCoordinate(latitude: 21.0, longitude: 78.0),
            tensionScore: 42.0,
            activeClusterCount: 6,
            articleCount: 20
        ),
        HotspotRegion(
            id: "KR",
            name: "Korean Peninsula",
            centroid: GeographicCoordinate(latitude: 38.0, longitude: 127.5),
            tensionScore: 58.0,
            activeClusterCount: 4,
            articleCount: 16
        ),
    ]

    // MARK: - Coordinate Projection

    /// Projects a geographic latitude/longitude coordinate to a 2D canvas point using Equirectangular projection.
    public func projectEquirectangular(
        coordinate: GeographicCoordinate,
        canvasSize: CGSize
    ) -> CGPoint {
        // Clamped latitude [-90, 90], longitude [-180, 180]
        let lat = max(-90.0, min(90.0, coordinate.latitude))
        let lon = max(-180.0, min(180.0, coordinate.longitude))

        let xNormalized = (lon + 180.0) / 360.0
        let yNormalized = (90.0 - lat) / 180.0

        return CGPoint(
            x: CGFloat(xNormalized) * canvasSize.width,
            y: CGFloat(yNormalized) * canvasSize.height
        )
    }

    /// Projects a geographic coordinate using bounded Mercator projection.
    public func projectMercator(
        coordinate: GeographicCoordinate,
        canvasSize: CGSize
    ) -> CGPoint {
        // Mercator cannot project poles; clamp latitude to [-85, 85]
        let lat = max(-85.0, min(85.0, coordinate.latitude))
        let lon = max(-180.0, min(180.0, coordinate.longitude))

        let xNormalized = (lon + 180.0) / 360.0
        let radLat = lat * .pi / 180.0
        let mercatorN = log(tan(.pi / 4.0 + radLat / 2.0))
        let yNormalized = (1.0 - (mercatorN / .pi)) / 2.0

        let clampedY = max(0.0, min(1.0, yNormalized))

        return CGPoint(
            x: CGFloat(xNormalized) * canvasSize.width,
            y: CGFloat(clampedY) * canvasSize.height
        )
    }

    // MARK: - Location Coordinate Resolution

    private static let locationCentroids: [String: GeographicCoordinate] = [
        // Eastern Europe
        "ukraine": GeographicCoordinate(latitude: 49.0, longitude: 31.0),
        "kyiv": GeographicCoordinate(latitude: 50.45, longitude: 30.52),
        "crimea": GeographicCoordinate(latitude: 45.3, longitude: 34.4),
        "donetsk": GeographicCoordinate(latitude: 48.0, longitude: 37.8),
        "kharkiv": GeographicCoordinate(latitude: 49.99, longitude: 36.23),
        "poland": GeographicCoordinate(latitude: 52.0, longitude: 19.0),
        "warsaw": GeographicCoordinate(latitude: 52.23, longitude: 21.01),

        // Middle East & Levant
        "israel": GeographicCoordinate(latitude: 31.5, longitude: 34.8),
        "gaza": GeographicCoordinate(latitude: 31.5, longitude: 34.45),
        "jerusalem": GeographicCoordinate(latitude: 31.77, longitude: 35.21),
        "tel aviv": GeographicCoordinate(latitude: 32.08, longitude: 34.78),
        "lebanon": GeographicCoordinate(latitude: 33.85, longitude: 35.86),
        "beirut": GeographicCoordinate(latitude: 33.89, longitude: 35.50),
        "iran": GeographicCoordinate(latitude: 32.42, longitude: 53.68),
        "tehran": GeographicCoordinate(latitude: 35.68, longitude: 51.38),
        "saudi arabia": GeographicCoordinate(latitude: 23.88, longitude: 45.07),
        "yemen": GeographicCoordinate(latitude: 15.55, longitude: 48.51),
        "red sea": GeographicCoordinate(latitude: 20.0, longitude: 38.5),

        // East Asia
        "taiwan": GeographicCoordinate(latitude: 23.69, longitude: 120.96),
        "taipei": GeographicCoordinate(latitude: 25.03, longitude: 121.56),
        "taiwan strait": GeographicCoordinate(latitude: 24.0, longitude: 119.5),
        "china": GeographicCoordinate(latitude: 35.86, longitude: 104.19),
        "beijing": GeographicCoordinate(latitude: 39.90, longitude: 116.40),
        "south china sea": GeographicCoordinate(latitude: 16.0, longitude: 114.0),
        "korea": GeographicCoordinate(latitude: 38.0, longitude: 127.5),
        "seoul": GeographicCoordinate(latitude: 37.56, longitude: 126.97),
        "tokyo": GeographicCoordinate(latitude: 35.68, longitude: 139.69),
        "japan": GeographicCoordinate(latitude: 36.20, longitude: 138.25),

        // Western Europe & Americas
        "united states": GeographicCoordinate(latitude: 37.09, longitude: -95.71),
        "washington": GeographicCoordinate(latitude: 38.90, longitude: -77.03),
        "new york": GeographicCoordinate(latitude: 40.71, longitude: -74.00),
        "united kingdom": GeographicCoordinate(latitude: 55.37, longitude: -3.43),
        "london": GeographicCoordinate(latitude: 51.50, longitude: -0.12),
        "france": GeographicCoordinate(latitude: 46.22, longitude: 2.21),
        "paris": GeographicCoordinate(latitude: 48.85, longitude: 2.35),
        "germany": GeographicCoordinate(latitude: 51.16, longitude: 10.45),
        "berlin": GeographicCoordinate(latitude: 52.52, longitude: 13.40),
        "geneva": GeographicCoordinate(latitude: 46.20, longitude: 6.14),
        "switzerland": GeographicCoordinate(latitude: 46.81, longitude: 8.22),
        "india": GeographicCoordinate(latitude: 20.59, longitude: 78.96),
        "new delhi": GeographicCoordinate(latitude: 28.61, longitude: 77.20),
    ]

    /// Resolves canonical location name to known geographic coordinates.
    public func resolveCoordinate(for locationName: String) -> GeographicCoordinate? {
        let separators = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        let words = locationName.lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return nil }

        // Longest n-gram first at each start position, in input order.
        for start in words.indices {
            for end in stride(from: words.count, to: start, by: -1) {
                let candidate = words[start..<end].joined(separator: " ")
                if let hit = Self.locationCentroids[candidate] {
                    return hit
                }
            }
        }

        return nil
    }

    /// Finds the closest matching standard region for a given coordinate within maxDegrees.
    public func closestRegion(
        for coordinate: GeographicCoordinate,
        maxDegrees: Double = 25.0
    ) -> HotspotRegion? {
        var closest: HotspotRegion?
        var minDistance: Double = maxDegrees * maxDegrees

        for region in Self.standardRegions {
            let dLat = region.centroid.latitude - coordinate.latitude
            var dLon = abs(region.centroid.longitude - coordinate.longitude)
            if dLon > 180.0 { dLon = 360.0 - dLon }
            let distance = dLat * dLat + dLon * dLon
            if distance <= minDistance {
                minDistance = distance
                closest = region
            }
        }

        return closest
    }
}
