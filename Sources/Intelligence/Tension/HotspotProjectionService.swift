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

// Angelia · Eris (World Tension) owns this file. Register: docs/ANGELIA.md.

import CoreGraphics
import Foundation

/// Service providing on-device vector map projection, location coordinate resolution,
/// and regional hotspot aggregation without external map tile requests (#718).
public struct HotspotProjectionService: Sendable {
    public init() {}

    // MARK: - Geopolitical Region Anchors

    /// The theaters the map groups places into. They carry geography only: coverage and tension are computed from a
    /// reading's headlines (`WorldTensionReading.hotspots`), never stored here.
    public static let regionAnchors: [HotspotRegion] = [
        HotspotRegion(
            id: "UA", name: "Eastern Europe", centroid: GeographicCoordinate(latitude: 49.0, longitude: 31.0),
            tensionScore: 0, activeClusterCount: 0, articleCount: 0),
        HotspotRegion(
            id: "ME", name: "Middle East", centroid: GeographicCoordinate(latitude: 29.5, longitude: 45.0),
            tensionScore: 0, activeClusterCount: 0, articleCount: 0),
        HotspotRegion(
            id: "TW", name: "Taiwan Strait & East Asia",
            centroid: GeographicCoordinate(latitude: 24.0, longitude: 121.0),
            tensionScore: 0, activeClusterCount: 0, articleCount: 0),
        HotspotRegion(
            id: "EU", name: "Western Europe", centroid: GeographicCoordinate(latitude: 48.0, longitude: 10.0),
            tensionScore: 0, activeClusterCount: 0, articleCount: 0),
        HotspotRegion(
            id: "US", name: "North America", centroid: GeographicCoordinate(latitude: 38.0, longitude: -97.0),
            tensionScore: 0, activeClusterCount: 0, articleCount: 0),
        HotspotRegion(
            id: "CN", name: "South China Sea", centroid: GeographicCoordinate(latitude: 16.0, longitude: 114.0),
            tensionScore: 0, activeClusterCount: 0, articleCount: 0),
        HotspotRegion(
            id: "IN", name: "South Asia", centroid: GeographicCoordinate(latitude: 21.0, longitude: 78.0),
            tensionScore: 0, activeClusterCount: 0, articleCount: 0),
        HotspotRegion(
            id: "KR", name: "Korean Peninsula", centroid: GeographicCoordinate(latitude: 38.0, longitude: 127.5),
            tensionScore: 0, activeClusterCount: 0, articleCount: 0),
    ]

    // MARK: - Editorial theaters

    /// Geopolitical theater is a classification, not a nearest-point lookup. A place
    /// without a defensible theater remains a pin with no region aggregate.
    private static let locationTheaters: [String: String] = [
        "ukraine": "UA", "kyiv": "UA", "crimea": "UA", "donetsk": "UA", "kharkiv": "UA",
        "odesa": "UA", "odessa": "UA", "lviv": "UA", "zaporizhzhia": "UA", "kherson": "UA", "mariupol": "UA",
        "israel": "ME", "gaza": "ME", "jerusalem": "ME", "tel aviv": "ME",
        "lebanon": "ME", "beirut": "ME", "iran": "ME", "tehran": "ME",
        "saudi arabia": "ME", "yemen": "ME", "red sea": "ME",
        "taiwan": "TW", "taipei": "TW", "taiwan strait": "TW",
        "south china sea": "CN",
        "korea": "KR", "north korea": "KR", "south korea": "KR", "seoul": "KR", "pyongyang": "KR",
        "united states": "US", "washington": "US", "new york": "US",
        "united kingdom": "EU", "london": "EU", "france": "EU", "paris": "EU",
        "germany": "EU", "berlin": "EU", "geneva": "EU", "switzerland": "EU",
        "india": "IN", "new delhi": "IN",
    ]

    /// Returns only a known editorial theater. China is not automatically the South
    /// China Sea; Japan is not Korea; Poland is not Western Europe.
    public func theater(forLocationNamed name: String) -> HotspotRegion? {
        guard let id = Self.locationTheaters[name.lowercased()] else { return nil }
        return Self.regionAnchors.first { $0.id == id }
    }

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

    /// Resolves canonical location name to known geographic coordinates.
    public func resolveCoordinate(for locationName: String) -> GeographicCoordinate? {
        resolveLocation(for: locationName)?.coordinate
    }

    /// The first known place a text names (its shown name and its centroid), in word order, from the bundled
    /// `HotspotGazetteer`.
    public func resolveLocation(for locationName: String) -> (name: String, coordinate: GeographicCoordinate)? {
        let separators = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        let words = locationName.lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return nil }

        // Longest n-gram first at each start position, in input order.
        for start in words.indices {
            for end in stride(from: words.count, to: start, by: -1) {
                let candidate = words[start..<end].joined(separator: " ")
                if let place = HotspotGazetteer.places[candidate] {
                    return (place.names[0], place.coordinate)
                }
            }
        }

        return nil
    }

    /// Whether a place (by the name `resolveLocation` returned) is a country, a sea or a region, whose centroid is the
    /// center of an area and never where an event happened (#718).
    public func isApproximate(_ name: String) -> Bool {
        HotspotGazetteer.places[name]?.isArea ?? false
    }

    /// Finds the closest matching standard region for a given coordinate within maxDegrees.
    public func closestRegion(
        for coordinate: GeographicCoordinate,
        maxDegrees: Double = 25.0
    ) -> HotspotRegion? {
        var closest: HotspotRegion?
        var minDistance: Double = maxDegrees * maxDegrees

        for region in Self.regionAnchors {
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
