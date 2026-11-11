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

/// The part of the world the hotspot map shows (W4 #718): the marked places with room around them, in the canvas's
/// proportions so a degree is as wide as it is tall, and the whole world when the places are spread across it. A
/// handful of places in one theater would otherwise sit on top of each other on a map of the whole world.
struct HotspotViewport: Equatable, Sendable {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    static let world = HotspotViewport(minLatitude: -90, maxLatitude: 90, minLongitude: -180, maxLongitude: 180)
    /// Degrees of room around the outermost marker, which covers its glow.
    static let padding = 10.0
    /// The smallest latitude span, so a single place is not magnified to a street map.
    static let minimumLatitudeSpan = 40.0

    /// `aspect` is the canvas's width over its height.
    static func fitting(_ coordinates: [GeographicCoordinate], aspect: Double) -> HotspotViewport {
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let south = latitudes.min(), let north = latitudes.max(), let west = longitudes.min(),
            let east = longitudes.max(), aspect > 0
        else { return .world }
        var latitudeSpan = max(north - south + 2 * padding, minimumLatitudeSpan)
        var longitudeSpan = max(east - west + 2 * padding, minimumLatitudeSpan * aspect)
        if longitudeSpan / latitudeSpan < aspect {
            longitudeSpan = latitudeSpan * aspect
        } else {
            latitudeSpan = longitudeSpan / aspect
        }
        // Three quarters of the world's width or two thirds of its height is the world.
        guard longitudeSpan < 270, latitudeSpan < 120 else { return .world }
        let bottom = min(max((south + north) / 2 - latitudeSpan / 2, -90), 90 - latitudeSpan)
        let left = min(max((west + east) / 2 - longitudeSpan / 2, -180), 180 - longitudeSpan)
        return HotspotViewport(
            minLatitude: bottom, maxLatitude: bottom + latitudeSpan, minLongitude: left,
            maxLongitude: left + longitudeSpan)
    }

    func contains(_ coordinate: GeographicCoordinate) -> Bool {
        (minLatitude...maxLatitude).contains(coordinate.latitude)
            && (minLongitude...maxLongitude).contains(coordinate.longitude)
    }

    /// The point of a coordinate on a canvas that shows exactly this viewport (equirectangular).
    func project(_ coordinate: GeographicCoordinate, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (coordinate.longitude - minLongitude) / (maxLongitude - minLongitude) * size.width,
            y: (maxLatitude - coordinate.latitude) / (maxLatitude - minLatitude) * size.height)
    }
}
