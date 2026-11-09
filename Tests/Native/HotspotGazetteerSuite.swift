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
import Testing

extension NativeSuites {
    /// W4 #718: the bundled place lookup and what the map says about a place that is only the center of an area.
    @Suite(.tags(.editorial, .integration)) struct HotspotGazetteerSuite {
        private let service = HotspotProjectionService()

        @Test func everyNameResolvesToAPlaceWithAValidCoordinate() {
            #expect(HotspotGazetteer.places.count >= 300, "A global map names far more than the theaters")
            for (name, place) in HotspotGazetteer.places {
                #expect(place.names.contains(name), "\(name)")
                #expect(name == name.lowercased(), "\(name) is looked up in lower case")
                #expect((-90.0...90.0).contains(place.coordinate.latitude), "\(name)")
                #expect((-180.0...180.0).contains(place.coordinate.longitude), "\(name)")
            }
        }

        @Test func aliasesShareOnePlaceSoOnePinStandsForIt() {
            #expect(service.resolveLocation(for: "Kiev attack")?.name == "kyiv")
            #expect(service.resolveLocation(for: "UK economy")?.name == "united kingdom")
            #expect(service.resolveLocation(for: "Saint Petersburg drones")?.name == "st petersburg")
            #expect(
                service.resolveLocation(for: "São Paulo protest")?.name
                    == service.resolveLocation(for: "Sao Paulo")?.name)
        }

        @Test func theLongestNameWinsAtEachStartAndWholeWordsOnlyCount() {
            #expect(service.resolveLocation(for: "Fighting spreads in South Sudan")?.name == "south sudan")
            #expect(service.resolveLocation(for: "Fighting in Sudan")?.name == "sudan")
            #expect(service.resolveLocation(for: "Papua New Guinea quake")?.name == "papua new guinea")
            #expect(service.resolveLocation(for: "New Mexico fire")?.name == "new mexico")
            #expect(service.resolveLocation(for: "Indiana vote") == nil)
            #expect(service.resolveLocation(for: "Chinatown festival") == nil)
            #expect(service.resolveLocation(for: "A woman speaks") == nil, "oman is not inside woman")
        }

        @Test func countriesAndSeasAreApproximateAndCitiesAreNot() {
            for area in ["sudan", "russia", "red sea", "black sea", "west bank", "china"] {
                #expect(service.isApproximate(area), "\(area) marks the center of an area")
            }
            for point in ["khartoum", "kyiv", "moscow", "gaza", "taipei"] {
                #expect(!service.isApproximate(point), "\(point) is a point")
            }
            #expect(!service.isApproximate("nowhere"))
        }

        @Test func anAreaDrawsLargerThanACityOfTheSameCoverage() {
            func pin(_ approximate: Bool, stories: Int = 4, tension: Double = 60) -> HotspotClusterPin {
                HotspotClusterPin(
                    id: "p", title: "P", coordinate: GeographicCoordinate(latitude: 0, longitude: 0),
                    tensionScore: tension, topPublisherIds: [], storyCount: stories, isApproximate: approximate)
            }
            let city = GlobalHotspotMapView.pinSize(for: pin(false))
            #expect(GlobalHotspotMapView.pinSize(for: pin(true)) > city)
            #expect(
                GlobalHotspotMapView.pinSize(for: pin(false, stories: 40, tension: 140)) <= AppLayout
                    .hotspotPinMinimumSize + 2 * AppLayout.hotspotPinGrowth)
            #expect(
                GlobalHotspotMapView.pinSize(for: pin(false, stories: 0, tension: -5))
                    == AppLayout.hotspotPinMinimumSize)
        }

        @Test func theViewportFitsTheMarkedPlacesAtTheCanvasAspect() {
            let aspect = 532.0 / 320.0
            let theater = ["Kyiv", "Gaza", "Sudan", "Red Sea"].compactMap { service.resolveCoordinate(for: $0) }
            let viewport = HotspotViewport.fitting(theater, aspect: aspect)
            #expect(viewport != .world)
            #expect(theater.allSatisfy { viewport.contains($0) })
            let width = viewport.maxLongitude - viewport.minLongitude
            let height = viewport.maxLatitude - viewport.minLatitude
            #expect(abs(width / height - aspect) < 1e-9, "A degree is as wide as it is tall")
            #expect(viewport.minLatitude >= -90 && viewport.maxLatitude <= 90)
            #expect(viewport.minLongitude >= -180 && viewport.maxLongitude <= 180)
            // The corners of the viewport are the corners of the canvas.
            let size = CGSize(width: 532, height: 320)
            let topLeft = viewport.project(
                GeographicCoordinate(latitude: viewport.maxLatitude, longitude: viewport.minLongitude), in: size)
            #expect(abs(topLeft.x) < 1e-9 && abs(topLeft.y) < 1e-9)
        }

        @Test func placesSpreadAcrossTheWorldShowTheWholeWorld() {
            let spread = ["Kyiv", "Taipei", "Washington", "Sydney"].compactMap { service.resolveCoordinate(for: $0) }
            #expect(spread.count == 4)
            #expect(HotspotViewport.fitting(spread, aspect: 532.0 / 320.0) == .world)
            #expect(HotspotViewport.fitting([], aspect: 1.6) == .world)
        }

        @Test func onePlaceIsNotMagnifiedBeyondTheMinimumSpan() {
            let kyiv = [GeographicCoordinate(latitude: 50.45, longitude: 30.52)]
            let viewport = HotspotViewport.fitting(kyiv, aspect: 2)
            #expect(viewport.maxLatitude - viewport.minLatitude >= HotspotViewport.minimumLatitudeSpan)
            #expect(viewport.contains(kyiv[0]))
            // Near a pole or the date line the viewport slides inside the world instead of leaving it.
            let north = HotspotViewport.fitting([GeographicCoordinate(latitude: 88, longitude: 179)], aspect: 2)
            #expect(north.maxLatitude <= 90 && north.maxLongitude <= 180)
        }

        @Test func headlinesAboutAnAreaMakeAnApproximatePin() {
            let reading = WorldTensionReading(
                evaluatedAt: Date(timeIntervalSince1970: 1_793_300_435), inputHash: "area", modelGeneration: "test",
                headlines: [
                    WorldTensionHeadline(id: "C1", title: "Airstrike hits Khartoum market", publisher: "Wire A"),
                    WorldTensionHeadline(id: "C2", title: "Troops fight across Sudan", publisher: "Wire B"),
                ],
                assessment: WorldTensionAssessment(score: 50, summary: "", reasons: []))
            let pins = WorldTensionHotspots(reading: reading).pins
            #expect(Set(pins.map(\.id)) == ["khartoum", "sudan"])
            #expect(pins.first { $0.id == "sudan" }?.isApproximate == true)
            #expect(pins.first { $0.id == "khartoum" }?.isApproximate == false)
        }
    }
}
