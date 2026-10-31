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

/// The Briefing war room shell (#848): module layout, its persistence, hidden modules and the World Tension captions.
/// Drives production types only (#804).
enum BriefingWarRoomTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("❌ FAILURE [BriefingWarRoomTests.swift:\(line)]: \(message)")
        }
    }

    static func run() async {
        print("=== Running Briefing war room (#848) tests ===")
        layoutDefaults()
        layoutEditing()
        await layoutPersistence()
        hiddenModules()
        tensionCaptions()
        print("Finished \(checks) Briefing war room checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }

    static func layoutDefaults() {
        let layout = BriefingLayout.default
        check(
            layout.modules(in: .situationalAwareness)
                == [.heroCarousel, .worldTension, .sinceLastBriefing, .executiveSitrep], "situational order")
        check(
            layout.modules(in: .intelligenceAssessment) == [.priorityDevelopments, .sourceFootprint],
            "drivers hidden by default")
        check(layout.allModules(in: .intelligenceAssessment).last == .tensionDrivers, "hidden keeps its place")
        check(layout.modules(in: .forwardWatch) == [.forwardWatch, .escalationTimeline], "forward watch order")
    }

    static func layoutEditing() {
        var layout = BriefingLayout.default
        layout.setVisible(.worldTension, false)
        check(!layout.isVisible(.worldTension), "setVisible hides")
        check(layout.allModules(in: .situationalAwareness)[1] == .worldTension, "hidden module keeps its place")
        layout.setVisible(.worldTension, true)
        check(layout == .default, "showing again restores the canvas place")
        layout.move(.executiveSitrep, to: 0)
        check(layout.modules(in: .situationalAwareness).first == .executiveSitrep, "move reorders")
        check(
            layout.modules(in: .strategicImpact) == BriefingLayout.default.modules(in: .strategicImpact),
            "move leaves other pillars")
        layout.move(.tensionDrivers, to: 0)
        check(!layout.isVisible(.tensionDrivers), "moving a hidden module does nothing")
        layout.move(.forwardWatch, to: 99)
        check(layout.modules(in: .forwardWatch) == [.escalationTimeline, .forwardWatch], "move clamps in pillar")
    }

    @MainActor
    static func layoutPersistence() async {
        let suite = testDefaultsSuite("briefing-layout")
        defer { removeTestDefaults(suite) }
        guard let defaults = UserDefaults(suiteName: suite) else { return check(false, "test defaults") }
        let settings = AppSettings(defaults: defaults)
        check(settings.briefingLayout == .default, "default when absent")
        var layout = BriefingLayout.default
        layout.setVisible(.regions, false)
        layout.move(.escalationTimeline, to: 0)
        settings.setBriefingLayout(layout)
        check(AppSettings(defaults: defaults).briefingLayout == layout, "round-trips through AppSettings")
        check(AppSettings.backedUpKeys.contains(AppSettings.briefingModuleOrderKey), "layout is backed up")
        settings.setBriefingLayout(.default)
        check(defaults.object(forKey: AppSettings.briefingModuleOrderKey) == nil, "reset clears the store")
        check(
            BriefingLayout(stored: ["forwardWatch": ["weakSignals", "bogus", "forwardWatch"]])
                .modules(in: .forwardWatch) == [.forwardWatch], "misplaced and unknown kinds dropped")
    }

    static func hiddenModules() {
        let modules = BriefingView.visibleModules(layout: .default, data: BriefingBoardData())
        check(modules == [.heroCarousel, .worldTension], "modules without data are hidden")
        check(
            BriefingView.visibleModules(layout: .default, data: BriefingBoardData(), hasStories: false)
                == [.worldTension], "no carousel without stories")
        var layout = BriefingLayout.default
        layout.setVisible(.worldTension, false)
        check(!BriefingView.visibleModules(layout: layout, data: BriefingBoardData()).contains(.worldTension), "hidden")
    }

    static func reading(_ day: Int, _ score: Int, estimate: Bool = false, publishers: [String] = [])
        -> WorldTensionReading
    {
        WorldTensionReading(
            evaluatedAt: Date(timeIntervalSince1970: 1_793_000_000 + Double(day) * 86400), inputHash: "t\(day)",
            modelGeneration: "test",
            headlines: publishers.enumerated().map {
                WorldTensionHeadline(id: "C\($0.offset)", title: "Headline \($0.offset)", publisher: $0.element)
            },
            assessment: WorldTensionAssessment(
                score: score, summary: "", reasons: [], isEstimate: estimate ? true : nil))
    }

    static func tensionCaptions() {
        let change = BriefingTensionStripView.changeText
        check(change([reading(0, 40), reading(3, 44)]) == "▲ 4 in 7 days", "rising")
        check(change([reading(0, 44), reading(3, 42)]) == "▼ 2 in 7 days", "falling")
        check(change([reading(0, 44), reading(3, 44)]) == "No change in 7 days", "flat")
        check(change([reading(0, 44)]) == nil, "single reading")
        check(change([reading(0, 30, estimate: true), reading(1, 40), reading(2, 41)]) == "▲ 1 in 7 days", "estimates")
        let panel = ["BBC News", "The Guardian", "Deutsche Welle", "Al Jazeera", "Dawn", "CNA", "Africanews"]
        check(
            BriefingTensionStripView.coverageText(reading(0, 40, publishers: panel)) == "coverage sufficient",
            "seven panel feeds across regions")
        check(
            BriefingTensionStripView.coverageText(reading(0, 40, publishers: Array(panel.prefix(3)))) == nil,
            "a short sample says nothing")
    }
}
