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

import Foundation

/// The map's data for one reading (#718): only places its own headlines name, with the tension those headlines carry.
struct WorldTensionHotspots: Equatable, Sendable {
    let regions: [HotspotRegion]
    let pins: [HotspotClusterPin]
    var isEmpty: Bool { pins.isEmpty }

    private struct Place {
        let coordinate: GeographicCoordinate
        var headlines: [WorldTensionHeadline] = []
        var weight = 0.0
    }

    private struct Total {
        var pins = 0
        var stories = 0
        var weight = 0.0
    }

    /// Pins are one per named place; regions group the pins that fall within reach of their anchor. A headline counts
    /// only when it names a mapped place and carries a tension cue (`WorldTensionAssessment.weight`), and a
    /// place's or region's tension is the index the calibrated scale gives the summed cue weight of its headlines.
    /// Nothing is stored or assumed: a place or region no headline reaches is absent, not zero.
    init(reading: WorldTensionReading, service: HotspotProjectionService = HotspotProjectionService()) {
        let scale = TensionWeights.calibratedV1.scaleRawScore
        var places: [String: Place] = [:]
        for headline in reading.headlines where headline.id.hasPrefix("C") {
            let weight = WorldTensionAssessment.weight(of: headline)
            guard weight > 0, let place = service.resolveLocation(for: headline.title) else { continue }
            places[place.name, default: Place(coordinate: place.coordinate)].headlines.append(headline)
            places[place.name]?.weight += weight
        }
        pins = places.map { name, place in
            HotspotClusterPin(
                id: name, title: name.capitalized, coordinate: place.coordinate,
                tensionScore: scale(place.weight),
                topPublisherIds: Array(Set(place.headlines.map(\.publisher))).sorted(),
                storyCount: place.headlines.count, isApproximate: service.isApproximate(name))
        }.sorted { ($1.tensionScore, $1.storyCount, $1.id) < ($0.tensionScore, $0.storyCount, $0.id) }

        var regionTotals: [String: Total] = [:]
        for place in places.values {
            guard let region = service.closestRegion(for: place.coordinate) else { continue }
            regionTotals[region.id, default: Total()].pins += 1
            regionTotals[region.id]?.stories += place.headlines.count
            regionTotals[region.id]?.weight += place.weight
        }
        regions = HotspotProjectionService.regionAnchors.compactMap { anchor in
            guard let total = regionTotals[anchor.id] else { return nil }
            return HotspotRegion(
                id: anchor.id, name: anchor.name, centroid: anchor.centroid, tensionScore: scale(total.weight),
                activeClusterCount: total.pins, articleCount: total.stories)
        }
    }

    /// Whether `headline` belongs to the selected place or region, by the place its title names.
    static func matches(
        _ headline: WorldTensionHeadline, pin: HotspotClusterPin?, region: HotspotRegion?,
        service: HotspotProjectionService = HotspotProjectionService()
    ) -> Bool {
        guard let place = service.resolveLocation(for: headline.title) else { return false }
        if let pin { return place.name == pin.id }
        if let region { return service.closestRegion(for: place.coordinate)?.id == region.id }
        return true
    }
}
