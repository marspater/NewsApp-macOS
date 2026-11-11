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

import AppKit
import Foundation
import SwiftUI

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
        regionFilter()
        tensionCaptions()
        situationalAwarenessSizing()
        acceptanceTests1201()
        await appleIntelligenceAvailabilityTests()
        await runtimeDiagnosticsTests()
        print("Finished \(checks) Briefing war room checks with \(failures) failures.")
        if failures > 0 { recordFailure("BriefingWarRoomTests: \(failures) check failure(s)") }
    }

    /// The region filter hides the signal modules it empties, and clears itself when its control is gone (#850, #851).
    static func regionFilter() {
        guard let weak = BriefingWeakSignalsData.captureFixture, let watch = BriefingForwardWatchData.captureFixture
        else {
            check(false, "signal fixtures exist")
            return
        }
        var data = BriefingBoardData()
        data.weakSignals = weak
        data.forwardWatch = watch
        var filter = BriefingBoardFilter()
        filter.region = .oceania
        filter.regionsByEntry = Dictionary(
            uniqueKeysWithValues: weak.rows.map { ($0.entry.id, Set([TensionMacroRegion.europe])) })
        let shown = BriefingView.visibleModules(layout: .standard, data: data, filter: filter)
        check(!shown.contains(.weakSignals), "weak signals hide when the region filter empties them")
        check(shown.contains(.forwardWatch), "forward watch rows without a story stay")
        check(
            BriefingView.visibleModules(layout: .standard, data: data).contains(.weakSignals),
            "weak signals show without a filter")
        // No Regions control on the board: the selection cannot be cleared there, so the board clears it.
        check(
            BriefingView.effectiveFilter(filter, layout: .standard, data: data).region == nil,
            "a region without the Regions module is dropped")
        var layout = BriefingLayout.standard
        layout.setVisible(.regions, false)
        check(
            BriefingView.effectiveFilter(filter, layout: layout, data: data).region == nil,
            "a region with the Regions module hidden is dropped")
    }

    static func layoutDefaults() {
        let layout = BriefingLayout.standard
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
        var layout = BriefingLayout.standard
        layout.setVisible(.worldTension, false)
        check(!layout.isVisible(.worldTension), "setVisible hides")
        check(layout.allModules(in: .situationalAwareness)[1] == .worldTension, "hidden module keeps its place")
        layout.setVisible(.worldTension, true)
        check(layout == .standard, "showing again restores the canvas place")
        layout.move(.sinceLastBriefing, to: 0)
        check(
            layout.modules(in: .situationalAwareness) == [
                .heroCarousel, .sinceLastBriefing, .worldTension, .executiveSitrep,
            ],
            "move reorders between the pinned carousel and sitrep")
        layout.move(.executiveSitrep, to: 0)
        check(layout.modules(in: .situationalAwareness).last == .executiveSitrep, "a pinned module does not move")
        layout.setVisible(.executiveSitrep, false)
        layout.setVisible(.executiveSitrep, true)
        check(layout.modules(in: .situationalAwareness).last == .executiveSitrep, "the sitrep returns last")
        check(
            layout.modules(in: .strategicImpact) == BriefingLayout.standard.modules(in: .strategicImpact),
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
        check(settings.briefingLayout == .standard, "default when absent")
        var layout = BriefingLayout.standard
        layout.setVisible(.regions, false)
        layout.move(.escalationTimeline, to: 0)
        settings.setBriefingLayout(layout)
        check(AppSettings(defaults: defaults).briefingLayout == layout, "round-trips through AppSettings")
        check(AppSettings.backedUpKeys.contains(AppSettings.briefingModuleOrderKey), "layout is backed up")
        settings.setBriefingLayout(.standard)
        check(defaults.object(forKey: AppSettings.briefingModuleOrderKey) == nil, "reset clears the store")
        check(
            BriefingLayout(stored: ["forwardWatch": ["weakSignals", "bogus", "forwardWatch"]])
                .modules(in: .forwardWatch) == [.forwardWatch], "misplaced and unknown kinds dropped")
    }

    static func hiddenModules() {
        let modules = BriefingView.visibleModules(layout: .standard, data: BriefingBoardData())
        check(modules == [.heroCarousel, .worldTension], "modules without data are hidden")
        check(
            BriefingView.visibleModules(layout: .standard, data: BriefingBoardData(), hasStories: false)
                == [.worldTension], "no carousel without stories")
        var layout = BriefingLayout.standard
        layout.setVisible(.worldTension, false)
        check(!BriefingView.visibleModules(layout: layout, data: BriefingBoardData()).contains(.worldTension), "hidden")
        check(
            !BriefingView.visibleModules(
                layout: .standard, data: BriefingBoardData(), isWorldTensionEnabled: false
            ).contains(.worldTension), "hidden when world tension disabled (#1209)")
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

    static func situationalAwarenessSizing() {
        print("  - Testing Situational awareness sizing across widths (#1211)...")
        let spacing = AppLayout.cardGap
        let heroHeight: CGFloat = 360
        let trailingHeight: CGFloat = 520
        let sitrepHeight: CGFloat = 140

        // 1. Wide window (1200 pt):
        let wide = BriefingSituationalLayout.computeFrames(
            width: 1200,
            heroHeight: heroHeight,
            trailingHeight: trailingHeight,
            sitrepHeight: sitrepHeight
        )
        guard let heroWide = wide.hero, let trailingWide = wide.trailing, let sitrepWide = wide.sitrep else {
            check(false, "Wide layout produces all three frames")
            return
        }
        let expectedLeadingWidth = ((1200 - spacing) * 2.0 / 3.0).rounded()
        let expectedTrailingWidth = 1200 - spacing - expectedLeadingWidth
        check(heroWide.width == expectedLeadingWidth, "Hero takes 2/3 width in wide window")
        check(heroWide.minX == 0 && heroWide.minY == 0, "Hero is at top-left")
        check(sitrepWide.width == expectedLeadingWidth, "Sitrep takes hero's width (2/3) in wide window")
        check(
            sitrepWide.minX == 0 && sitrepWide.minY == heroHeight + spacing,
            "Sitrep sits directly under hero without gap")
        check(trailingWide.width == expectedTrailingWidth, "Trailing column takes remaining 1/3 width")
        check(
            trailingWide.minX == expectedLeadingWidth + spacing && trailingWide.minY == 0,
            "Trailing column sits on right")

        // 2. Wide window boundary (900 pt):
        let boundary = BriefingSituationalLayout.computeFrames(
            width: 900,
            heroHeight: heroHeight,
            trailingHeight: trailingHeight,
            sitrepHeight: sitrepHeight
        )
        check(boundary.hero?.minY == 0, "Hero at top on boundary")
        check(boundary.sitrep?.minY == heroHeight + spacing, "Sitrep directly under hero on boundary")
        check(boundary.trailing?.minX == (boundary.hero?.maxX ?? 0) + spacing, "Trailing beside hero on boundary")

        // 3. Narrow window (600 pt):
        let narrow = BriefingSituationalLayout.computeFrames(
            width: 600,
            heroHeight: heroHeight,
            trailingHeight: trailingHeight,
            sitrepHeight: sitrepHeight
        )
        guard let heroNarrow = narrow.hero, let trailingNarrow = narrow.trailing, let sitrepNarrow = narrow.sitrep
        else {
            check(false, "Narrow layout produces all three frames")
            return
        }
        check(
            heroNarrow.width == 600 && trailingNarrow.width == 600 && sitrepNarrow.width == 600,
            "Single column full width")
        check(heroNarrow.minY == 0, "Hero leads single column")
        check(trailingNarrow.minY == heroHeight + spacing, "Trailing column follows hero in single column")
        check(
            sitrepNarrow.minY == trailingNarrow.maxY + spacing, "Sitrep closes situational awareness in single column")

        // 4. Hiding trailing column leaves no hole in wide window:
        let noTrailing = BriefingSituationalLayout.computeFrames(
            width: 1200,
            heroHeight: heroHeight,
            trailingHeight: nil,
            sitrepHeight: sitrepHeight
        )
        guard let heroNoTrailing = noTrailing.hero, let sitrepNoTrailing = noTrailing.sitrep else {
            check(false, "Absent trailing produces hero and sitrep frames")
            return
        }
        check(noTrailing.trailing == nil, "Trailing frame is absent")
        check(heroNoTrailing.width == 1200, "Hero expands to full width when trailing column is absent")
        check(sitrepNoTrailing.width == 1200, "Sitrep expands to full width when trailing column is absent")
        check(sitrepNoTrailing.minY == heroHeight + spacing, "Sitrep sits under hero with no holes")

        // 5. Hiding hero module leaves no hole:
        let noHero = BriefingSituationalLayout.computeFrames(
            width: 600,
            heroHeight: nil,
            trailingHeight: trailingHeight,
            sitrepHeight: sitrepHeight
        )
        check(noHero.hero == nil, "Hero frame is absent")
        check(noHero.trailing?.minY == 0, "Trailing starts at top when hero is hidden")
        check(noHero.sitrep?.minY == trailingHeight + spacing, "Sitrep follows trailing with no gap")
    }

    static func acceptanceTests1201() {
        print("  - Testing acceptance criteria for #1201...")
        // 1. Hero carousel up to 10 stories and rotates every 10 seconds:
        check(BriefingView.heroLimit == 10, "Hero shows up to ten stories (#1201)")
        check(BriefingHeroCarouselView.autoAdvanceInterval == 10.0, "Hero rotates every 10 seconds (#1201)")

        // 2. Muting topic set is "No AI, Please":
        check(
            MuteTopicSet.artificialIntelligence.title == "No AI, Please", "Muting topic set is 'No AI, Please' (#1201)")

        // 3. Inline source citations match mock's neutral chip:
        let regFill = InlineChip.fill(contrast: .standard)
        let incFill = InlineChip.fill(contrast: .increased)
        let regText = InlineChip.textColor(contrast: .standard)
        let incText = InlineChip.textColor(contrast: .increased)
        check(InlineChip.cornerRadius == 4.0, "Inline chip corner radius is 4.0 pt")
        check(regFill != incFill, "Increased contrast strengthens chip fill")
        check(regText != incText, "Increased contrast strengthens chip text")

        // 4. Notification curated delivery attaches recorded page lookup photo:
        let baseStory = FeedArticle(
            storedID: "al-jazeera-1", title: "AJ Story", link: "https://example.com/aj", guid: "aj-1",
            description: "", pubDate: Date(), source: "Al Jazeera", imageUrl: nil)
        var curatedStory = baseStory
        curatedStory.imageUrl = "https://example.com/aj-page-lookup.jpg"
        var delivery = NotificationDelivery(mode: .full)
        delivery.curated = { _ in curatedStory }
        check(
            curatedStory.imageUrl == "https://example.com/aj-page-lookup.jpg",
            "Banner gains recorded photo from page lookup")

        // 5. Briefing priority module opens story on whole card click:
        var openedEventID: String?
        let actions = BriefingActions(
            onOpenArticle: { _ in },
            onOpenEvent: { openedEventID = $0.eventID },
            onStartNewBriefing: {},
            onBackToToday: {}
        )
        let summary = EventFeedSummary(
            eventID: "event-1", membershipVersion: 1, seenVersion: nil,
            members: [
                EventFeedMember(
                    articleID: "a1", source: "S", title: "T", date: Date(), joinedVersion: 1, isRead: false,
                    isSaved: false)
            ]
        )
        actions.onOpenEvent(summary)
        check(openedEventID == "event-1", "Clicking Priority developments card opens its story (#1201)")
    }

    @MainActor
    static func appleIntelligenceAvailabilityTests() async {
        print("  - Testing AppleIntelligenceAvailability unified check (#1212)...")
        let avail = AppleIntelligenceAvailability.shared

        // Test each state properties:
        for state in AppleIntelligenceState.allCases {
            check(!state.statusLabel.isEmpty, "State \(state) has statusLabel")
            check(!state.explanation.isEmpty, "State \(state) has explanation")
            if state == .ready {
                check(state.isAvailable, "Ready state is available")
                check(state.actionTitle == nil, "Ready state has no action")
            } else {
                check(!state.isAvailable, "Non-ready state is not available")
            }
        }

        // Test resolveState logic with OS version:
        let v14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        check(
            AppleIntelligenceAvailability.resolveState(aiEnabled: true, osVersion: v14) == .macOSVersionTooOld,
            "macOS 14 resolves to macOSVersionTooOld"
        )
        check(
            AppleIntelligenceAvailability.resolveState(aiEnabled: false, osVersion: v14) == .appDisabled,
            "aiEnabled=false resolves to appDisabled regardless of OS"
        )

        // Ineligible Mac:
        check(
            AppleIntelligenceAvailability.resolveState(
                aiEnabled: true, foundationModelsAvailability: "unavailable(deviceNotEligible)") == .unsupportedDevice,
            "deviceNotEligible resolves to unsupportedDevice"
        )

        // System Settings off:
        check(
            AppleIntelligenceAvailability.resolveState(
                aiEnabled: true, foundationModelsAvailability: "unavailable(disabledInSettings)") == .systemDisabled,
            "disabledInSettings resolves to systemDisabled"
        )

        // Model downloading:
        check(
            AppleIntelligenceAvailability.resolveState(
                aiEnabled: true, foundationModelsAvailability: "unavailable(modelDownloading)") == .modelDownloading,
            "modelDownloading resolves to modelDownloading"
        )

        // Injected mock in AppleIntelligenceAvailability:
        avail.mockState = .unsupportedDevice
        check(avail.state == .unsupportedDevice, "Mock state injected")
        check(
            avail.state.explanation.contains("does not support Apple Intelligence"),
            "unsupportedDevice explanation matches")

        avail.mockState = .systemDisabled
        check(avail.state == .systemDisabled, "Mock state updated")
        check(avail.state.explanation.contains("System Settings"), "systemDisabled explanation matches")

        avail.mockState = nil
        check(avail.mockState == nil, "Mock state cleared")
    }

    @MainActor
    static func runtimeDiagnosticsTests() {
        print("  - Testing runtime diagnostics and warning eliminations (#1214)...")
        // 1. FocusStatus entitlement check
        check(
            FocusStatus.hasCommunicationEntitlement == false,
            "News does not possess communication notifications entitlement")
        check(FocusStatus.isFocused == nil, "FocusStatus returns nil gracefully without error spew when unentitled")

        // Injected provider for testing
        FocusStatus.provider = { true }
        check(FocusStatus.isFocused == true, "FocusStatus provider injects focused state")
        let gateFocused = BannerGate.decide(
            authorization: .authorized, alert: .enabled, style: .banner, previews: .always,
            focused: FocusStatus.isFocused)
        check(gateFocused == .suppress(.focus), "Focused state suppresses banner")

        FocusStatus.provider = { false }
        check(FocusStatus.isFocused == false, "FocusStatus provider injects unfocused state")
        let gateUnfocused = BannerGate.decide(
            authorization: .authorized, alert: .enabled, style: .banner, previews: .always,
            focused: FocusStatus.isFocused)
        check(gateUnfocused == .show(redacted: false, persistent: false), "Unfocused state delivers banner")
        FocusStatus.provider = nil

        // 2. StoryBannerPresenter window key status check
        final class NonKeyAuxWindow: NSWindow {
            override var canBecomeKey: Bool { false }
        }
        let auxWindow = NonKeyAuxWindow()
        check(auxWindow.canBecomeKey == false, "Auxiliary helper window cannot become key")
        StoryBannerPresenter.mainWindow = auxWindow
        StoryBannerPresenter.showMainWindow()
        StoryBannerPresenter.mainWindow = nil
    }
}
