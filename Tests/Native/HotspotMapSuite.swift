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

            let unknown = service.resolveCoordinate(for: "NonexistentFantasyLand99")
            #expect(unknown == nil)
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
        }
    }
}
