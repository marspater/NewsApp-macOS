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
import Testing

extension NativeSuites {
    @Suite(.tags(.editorial, .integration)) struct HotspotMapSuite {
        @Test func equirectangularProjection() {
            let service = HotspotProjectionService()
            let canvas = CGSize(width: 800, height: 400)

            // Center of map (0 lat, 0 lon) -> (400, 200)
            let centerPt = service.projectEquirectangular(
                coordinate: GeographicCoordinate(latitude: 0, longitude: 0),
                canvasSize: canvas
            )
            #expect(abs(centerPt.x - 400.0) < 0.1)
            #expect(abs(centerPt.y - 200.0) < 0.1)

            // Top-left boundary: 90 lat, -180 lon -> (0, 0)
            let topLeftPt = service.projectEquirectangular(
                coordinate: GeographicCoordinate(latitude: 90, longitude: -180),
                canvasSize: canvas
            )
            #expect(abs(topLeftPt.x) < 0.1)
            #expect(abs(topLeftPt.y) < 0.1)

            // Bottom-right boundary: -90 lat, 180 lon -> (800, 400)
            let bottomRightPt = service.projectEquirectangular(
                coordinate: GeographicCoordinate(latitude: -90, longitude: 180),
                canvasSize: canvas
            )
            #expect(abs(bottomRightPt.x - 800.0) < 0.1)
            #expect(abs(bottomRightPt.y - 400.0) < 0.1)
        }

        @Test func mercatorProjectionBounding() {
            let service = HotspotProjectionService()
            let canvas = CGSize(width: 1000, height: 500)

            let eqPt = service.projectMercator(
                coordinate: GeographicCoordinate(latitude: 0, longitude: 0),
                canvasSize: canvas
            )
            #expect(abs(eqPt.x - 500.0) < 0.1)
            #expect(abs(eqPt.y - 250.0) < 0.5)

            // Extreme latitude (pole) clamped and finite
            let polePt = service.projectMercator(
                coordinate: GeographicCoordinate(latitude: 89.9, longitude: 0),
                canvasSize: canvas
            )
            #expect(polePt.x.isFinite)
            #expect(polePt.y.isFinite)
            #expect(polePt.y >= 0.0 && polePt.y <= 500.0)
        }

        @Test func locationResolution() {
            let service = HotspotProjectionService()

            let kyiv = service.resolveCoordinate(for: "Kyiv, Ukraine")
            #expect(kyiv != nil)
            #expect(kyiv?.latitude ?? 0 > 45.0)

            let gaza = service.resolveCoordinate(for: "Gaza City")
            #expect(gaza != nil)
            #expect(gaza?.latitude ?? 0 > 30.0 && gaza?.latitude ?? 0 < 35.0)

            let taipei = service.resolveCoordinate(for: "Taipei, Taiwan")
            #expect(taipei != nil)
            #expect(taipei?.longitude ?? 0 > 115.0)

            let telAviv = service.resolveCoordinate(for: "Tel-Aviv")
            #expect(telAviv != nil)

            let indiana = service.resolveCoordinate(for: "Indiana")
            #expect(indiana == nil)

            let unknown = service.resolveCoordinate(for: "NonexistentFantasyLand99")
            #expect(unknown == nil)
        }

        @Test func hotspotsComeFromTheReadingsOwnHeadlines() {
            func headline(_ id: String, _ title: String, _ publisher: String) -> WorldTensionHeadline {
                WorldTensionHeadline(id: id, title: title, publisher: publisher)
            }
            let reading = WorldTensionReading(
                evaluatedAt: Date(timeIntervalSince1970: 1_793_300_435), inputHash: "hotspots",
                modelGeneration: "test",
                headlines: [
                    headline("C1", "Airstrike hits Kyiv overnight", "Wire A"),
                    headline("C2", "Troops fight near Kyiv", "Wire B"),
                    headline("C3", "Weather mild in Paris this week", "Wire C"),
                    headline("P1", "Airstrike on Gaza kills dozens", "Wire A"),
                    headline("P2", "Airstrike hits Kyiv overnight", "Wire A"),
                ],
                assessment: WorldTensionAssessment(score: 50, summary: "", reasons: []))
            let hotspots = WorldTensionHotspots(reading: reading)

            // Only a current headline that names a mapped place and carries a tension cue counts.
            #expect(hotspots.pins.map(\.id) == ["kyiv"])
            #expect(hotspots.pins.first?.storyCount == 2)
            #expect(hotspots.pins.first?.topPublisherIds == ["Wire A", "Wire B"])
            #expect((hotspots.pins.first?.tensionScore ?? 0) > 0)

            // Regions no headline reaches are absent, not shown with a fixed score.
            #expect(hotspots.regions.map(\.id) == ["UA"])
            #expect(hotspots.regions.first?.articleCount == 2)
            #expect(hotspots.regions.first?.activeClusterCount == 1)
            #expect(hotspots.regions.first?.tensionScore == hotspots.pins.first?.tensionScore)

            // The same title decides the table filter.
            let kyiv = hotspots.pins[0]
            #expect(WorldTensionHotspots.matches(reading.headlines[0], pin: kyiv, region: nil))
            // The table also lists the preceding six days: a P headline naming the place matches.
            #expect(WorldTensionHotspots.matches(reading.headlines[4], pin: kyiv, region: nil))
            #expect(!WorldTensionHotspots.matches(reading.headlines[2], pin: kyiv, region: nil))
            #expect(WorldTensionHotspots.matches(reading.headlines[0], pin: nil, region: hotspots.regions[0]))

            // A reading with no placed tension cue has an empty map.
            let quiet = WorldTensionReading(
                evaluatedAt: reading.evaluatedAt, inputHash: "quiet", modelGeneration: "test",
                headlines: [headline("C1", "Weather mild in Paris this week", "Wire C")],
                assessment: WorldTensionAssessment(score: 5, summary: "", reasons: []))
            #expect(WorldTensionHotspots(reading: quiet).isEmpty)
        }

        @Test func hotspotRegionTensionClassification() {
            let critical = HotspotTensionLevel.level(for: 85.0)
            #expect(critical == .critical)

            let significant = HotspotTensionLevel.level(for: 50.0)
            #expect(significant == .significant)

            let elevated = HotspotTensionLevel.level(for: 20.0)
            #expect(elevated == .elevated)

            let service = HotspotProjectionService()
            let ukraineCoord = GeographicCoordinate(latitude: 49.5, longitude: 32.0)
            let closest = service.closestRegion(for: ukraineCoord)
            #expect(closest?.id == "UA")

            // Distant coordinate returns nil when no region is within threshold
            let sydney = GeographicCoordinate(latitude: -33.86, longitude: 151.2)
            let farRegion = service.closestRegion(for: sydney)
            #expect(farRegion == nil)
        }
    }
}
