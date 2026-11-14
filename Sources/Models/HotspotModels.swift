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

import Foundation

/// Geographic latitude and longitude pair (#718).
public struct GeographicCoordinate: Hashable, Codable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Geopolitical region aggregating tension factors and active event coverage.
public struct HotspotRegion: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let centroid: GeographicCoordinate
    /// The region's tension score, 0 ... 100.
    public let tensionScore: Double  // 0.0 ... 100.0
    /// Active events placed in the region.
    public let activeClusterCount: Int
    public let articleCount: Int

    public init(
        id: String,
        name: String,
        centroid: GeographicCoordinate,
        tensionScore: Double,
        activeClusterCount: Int,
        articleCount: Int
    ) {
        self.id = id
        self.name = name
        self.centroid = centroid
        self.tensionScore = tensionScore
        self.activeClusterCount = activeClusterCount
        self.articleCount = articleCount
    }

    /// The band the region's score falls in.
    public var tensionLevel: HotspotTensionLevel {
        HotspotTensionLevel.level(for: tensionScore)
    }
}

/// Clustered story event pin anchored to a geographic location.
public struct HotspotClusterPin: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let coordinate: GeographicCoordinate
    /// The event's tension score, 0 ... 100.
    public let tensionScore: Double
    /// The publishers that reported the event, sorted by name.
    public let topPublisherIds: [String]
    public let storyCount: Int
    /// True for a country, a sea or a region: the coordinate is the center of an area, never where anything happened,
    /// and the map says so (#718).
    public let isApproximate: Bool

    public init(
        id: String,
        title: String,
        coordinate: GeographicCoordinate,
        tensionScore: Double,
        topPublisherIds: [String],
        storyCount: Int,
        isApproximate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.coordinate = coordinate
        self.tensionScore = tensionScore
        self.topPublisherIds = topPublisherIds
        self.storyCount = storyCount
        self.isApproximate = isApproximate
    }

    /// The band the pin's score falls in.
    public var tensionLevel: HotspotTensionLevel {
        HotspotTensionLevel.level(for: tensionScore)
    }
}

/// Categorization of geopolitical tension intensity.
public enum HotspotTensionLevel: String, Codable, Sendable, CaseIterable {
    case elevated  // < 35
    case significant  // 35 ..< 70
    case critical  // >= 70

    /// Critical from 70, significant from 35, elevated below.
    public static func level(for score: Double) -> HotspotTensionLevel {
        if score >= 70.0 {
            return .critical
        } else if score >= 35.0 {
            return .significant
        } else {
            return .elevated
        }
    }

    /// The level as a capitalized word for display.
    public var displayName: String {
        switch self {
        case .elevated:
            return "Elevated"
        case .significant:
            return "Significant"
        case .critical:
            return "Critical"
        }
    }
}
