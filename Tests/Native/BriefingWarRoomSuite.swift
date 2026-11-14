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

import AppIntents
import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import NaturalLanguage
import Network
import PDFKit
import SQLite3
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Native port of the `BriefingWarRoomTests` atom (#1070): the same 10 tests, in the runner's order, with each `check`
/// turned into `expectTrue` of NativeExpectations.swift (the runner log is invisible to Swift Testing), so a failure is
/// recorded and later tests still run. `hiddenModules` and `regionFilter` run on the main actor here: the runner calls
/// them on the main thread, and they call main actor-isolated `BriefingView` statics synchronously. The atom's closing
/// summary is not a test and stays in the runner. The runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.briefing, .integration)) struct BriefingWarRoomSuite {
        @Test func layoutDefaults() { Self.testLayoutDefaults() }
        @Test func layoutEditing() { Self.testLayoutEditing() }
        @Test @MainActor func layoutPersistence() async { await Self.testLayoutPersistence() }
        // The runner calls these two synchronously on the main thread, so their calls into the main actor-isolated
        // `BriefingView` statics pass; Swift Testing runs a nonisolated test off the main thread, where that call traps.
        @Test @MainActor func hiddenModules() { Self.testHiddenModules() }
        @Test @MainActor func regionFilter() { Self.testRegionFilter() }
        @Test @MainActor func tensionCaptions() { Self.testTensionCaptions() }
        @Test func situationalAwarenessSizing() { Self.testSituationalAwarenessSizing() }
        @Test @MainActor func acceptanceTests1201() async { await Self.testAcceptanceTests1201() }
        @Test @MainActor func appleIntelligenceAvailabilityTests() async {
            await Self.testAppleIntelligenceAvailabilityTests()
        }
        @Test @MainActor func runtimeDiagnosticsTests() { Self.testRuntimeDiagnosticsTests() }
    }
}

extension NativeSuites.BriefingWarRoomSuite {

    /// The region filter hides the signal modules it empties, and clears itself when its control is gone (#850, #851).
    @MainActor static func testRegionFilter() {
        guard let weak = BriefingWeakSignalsData.captureFixture, let watch = BriefingForwardWatchData.captureFixture
        else {
            expectTrue(false, "signal fixtures exist")
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
        expectTrue(!shown.contains(.weakSignals), "weak signals hide when the region filter empties them")
        expectTrue(shown.contains(.forwardWatch), "forward watch rows without a story stay")
        expectTrue(
            BriefingView.visibleModules(layout: .standard, data: data).contains(.weakSignals),
            "weak signals show without a filter")
        // No Regions control on the board: the selection cannot be cleared there, so the board clears it.
        expectTrue(
            BriefingView.effectiveFilter(filter, layout: .standard, data: data).region == nil,
            "a region without the Regions module is dropped")
        var layout = BriefingLayout.standard
        layout.setVisible(.regions, false)
        expectTrue(
            BriefingView.effectiveFilter(filter, layout: layout, data: data).region == nil,
            "a region with the Regions module hidden is dropped")
    }

    static func testLayoutDefaults() {
        let layout = BriefingLayout.standard
        expectTrue(
            layout.modules(in: .situationalAwareness)
                == [.heroCarousel, .worldTension, .sinceLastBriefing, .executiveSitrep], "situational order")
        expectTrue(
            layout.modules(in: .intelligenceAssessment) == [.priorityDevelopments, .sourceFootprint],
            "drivers hidden by default")
        expectTrue(layout.allModules(in: .intelligenceAssessment).last == .tensionDrivers, "hidden keeps its place")
        expectTrue(layout.modules(in: .forwardWatch) == [.forwardWatch, .escalationTimeline], "forward watch order")
    }

    static func testLayoutEditing() {
        var layout = BriefingLayout.standard
        layout.setVisible(.worldTension, false)
        expectTrue(!layout.isVisible(.worldTension), "setVisible hides")
        expectTrue(layout.allModules(in: .situationalAwareness)[1] == .worldTension, "hidden module keeps its place")
        layout.setVisible(.worldTension, true)
        expectTrue(layout == .standard, "showing again restores the canvas place")
        layout.move(.sinceLastBriefing, to: 0)
        expectTrue(
            layout.modules(in: .situationalAwareness) == [
                .heroCarousel, .sinceLastBriefing, .worldTension, .executiveSitrep,
            ],
            "move reorders between the pinned carousel and sitrep")
        layout.move(.executiveSitrep, to: 0)
        expectTrue(layout.modules(in: .situationalAwareness).last == .executiveSitrep, "a pinned module does not move")
        layout.setVisible(.executiveSitrep, false)
        layout.setVisible(.executiveSitrep, true)
        expectTrue(layout.modules(in: .situationalAwareness).last == .executiveSitrep, "the sitrep returns last")
        expectTrue(
            layout.modules(in: .strategicImpact) == BriefingLayout.standard.modules(in: .strategicImpact),
            "move leaves other pillars")
        layout.move(.tensionDrivers, to: 0)
        expectTrue(!layout.isVisible(.tensionDrivers), "moving a hidden module does nothing")
        layout.move(.forwardWatch, to: 99)
        expectTrue(layout.modules(in: .forwardWatch) == [.escalationTimeline, .forwardWatch], "move clamps in pillar")
    }

    @MainActor
    static func testLayoutPersistence() async {
        let suite = testDefaultsSuite("briefing-layout")
        defer { removeTestDefaults(suite) }
        guard let defaults = UserDefaults(suiteName: suite) else { return expectTrue(false, "test defaults") }
        let settings = AppSettings(defaults: defaults)
        expectTrue(settings.briefingLayout == .standard, "default when absent")
        var layout = BriefingLayout.standard
        layout.setVisible(.regions, false)
        layout.move(.escalationTimeline, to: 0)
        settings.setBriefingLayout(layout)
        expectTrue(AppSettings(defaults: defaults).briefingLayout == layout, "round-trips through AppSettings")
        expectTrue(AppSettings.backedUpKeys.contains(AppSettings.briefingModuleOrderKey), "layout is backed up")
        settings.setBriefingLayout(.standard)
        expectTrue(defaults.object(forKey: AppSettings.briefingModuleOrderKey) == nil, "reset clears the store")
        expectTrue(
            BriefingLayout(stored: ["forwardWatch": ["weakSignals", "bogus", "forwardWatch"]])
                .modules(in: .forwardWatch) == [.forwardWatch], "misplaced and unknown kinds dropped")
    }

    @MainActor static func testHiddenModules() {
        let modules = BriefingView.visibleModules(layout: .standard, data: BriefingBoardData())
        expectTrue(modules == [.heroCarousel, .worldTension], "modules without data are hidden")
        expectTrue(
            BriefingView.visibleModules(layout: .standard, data: BriefingBoardData(), hasStories: false)
                == [.worldTension], "no carousel without stories")
        var layout = BriefingLayout.standard
        layout.setVisible(.worldTension, false)
        expectTrue(
            !BriefingView.visibleModules(layout: layout, data: BriefingBoardData()).contains(.worldTension), "hidden")
        expectTrue(
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

    @MainActor static func testTensionCaptions() {
        let change = BriefingTensionStripView.changeText
        expectTrue(change([reading(0, 40), reading(3, 44)]) == "▲ 4 in 7 days", "rising")
        expectTrue(change([reading(0, 44), reading(3, 42)]) == "▼ 2 in 7 days", "falling")
        expectTrue(change([reading(0, 44), reading(3, 44)]) == "No change in 7 days", "flat")
        expectTrue(change([reading(0, 44)]) == nil, "single reading")
        expectTrue(
            change([reading(0, 30, estimate: true), reading(1, 40), reading(2, 41)]) == "▲ 1 in 7 days", "estimates")
        let panel = ["BBC News", "The Guardian", "Deutsche Welle", "Al Jazeera", "Dawn", "CNA", "Africanews"]
        expectTrue(
            BriefingTensionStripView.coverageText(reading(0, 40, publishers: panel)) == "coverage sufficient",
            "seven panel feeds across regions")
        expectTrue(
            BriefingTensionStripView.coverageText(reading(0, 40, publishers: Array(panel.prefix(3)))) == nil,
            "a short sample says nothing")
    }

    static func testSituationalAwarenessSizing() {
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
            expectTrue(false, "Wide layout produces all three frames")
            return
        }
        let expectedLeadingWidth = ((1200 - spacing) * 2.0 / 3.0).rounded()
        let expectedTrailingWidth = 1200 - spacing - expectedLeadingWidth
        expectTrue(heroWide.width == expectedLeadingWidth, "Hero takes 2/3 width in wide window")
        expectTrue(heroWide.minX == 0 && heroWide.minY == 0, "Hero is at top-left")
        expectTrue(sitrepWide.width == expectedLeadingWidth, "Sitrep takes hero's width (2/3) in wide window")
        expectTrue(
            sitrepWide.minX == 0 && sitrepWide.minY == heroHeight + spacing,
            "Sitrep sits directly under hero without gap")
        expectTrue(trailingWide.width == expectedTrailingWidth, "Trailing column takes remaining 1/3 width")
        expectTrue(
            trailingWide.minX == expectedLeadingWidth + spacing && trailingWide.minY == 0,
            "Trailing column sits on right")

        // 2. Wide window boundary (1000 pt):
        let boundary = BriefingSituationalLayout.computeFrames(
            width: 1000,
            heroHeight: heroHeight,
            trailingHeight: trailingHeight,
            sitrepHeight: sitrepHeight
        )
        expectTrue(boundary.hero?.minY == 0, "Hero at top on boundary")
        expectTrue(boundary.sitrep?.minY == heroHeight + spacing, "Sitrep directly under hero on boundary")
        expectTrue(boundary.trailing?.minX == (boundary.hero?.maxX ?? 0) + spacing, "Trailing beside hero on boundary")

        let justBelow = BriefingSituationalLayout.computeFrames(
            width: 999, heroHeight: heroHeight, trailingHeight: trailingHeight, sitrepHeight: sitrepHeight)
        expectTrue(justBelow.trailing?.minX == 0, "Just under the boundary stacks in one column")

        // 3. Narrow window (600 pt):
        let narrow = BriefingSituationalLayout.computeFrames(
            width: 600,
            heroHeight: heroHeight,
            trailingHeight: trailingHeight,
            sitrepHeight: sitrepHeight
        )
        guard let heroNarrow = narrow.hero, let trailingNarrow = narrow.trailing, let sitrepNarrow = narrow.sitrep
        else {
            expectTrue(false, "Narrow layout produces all three frames")
            return
        }
        expectTrue(
            heroNarrow.width == 600 && trailingNarrow.width == 600 && sitrepNarrow.width == 600,
            "Single column full width")
        expectTrue(heroNarrow.minY == 0, "Hero leads single column")
        expectTrue(trailingNarrow.minY == heroHeight + spacing, "Trailing column follows hero in single column")
        expectTrue(
            sitrepNarrow.minY == trailingNarrow.maxY + spacing, "Sitrep closes situational awareness in single column")

        // 4. Hiding trailing column leaves no hole in wide window:
        let noTrailing = BriefingSituationalLayout.computeFrames(
            width: 1200,
            heroHeight: heroHeight,
            trailingHeight: nil,
            sitrepHeight: sitrepHeight
        )
        guard let heroNoTrailing = noTrailing.hero, let sitrepNoTrailing = noTrailing.sitrep else {
            expectTrue(false, "Absent trailing produces hero and sitrep frames")
            return
        }
        expectTrue(noTrailing.trailing == nil, "Trailing frame is absent")
        expectTrue(heroNoTrailing.width == 1200, "Hero expands to full width when trailing column is absent")
        expectTrue(sitrepNoTrailing.width == 1200, "Sitrep expands to full width when trailing column is absent")
        expectTrue(sitrepNoTrailing.minY == heroHeight + spacing, "Sitrep sits under hero with no holes")

        // A lone trailing module has no column to sit beside and takes the full width:
        let trailingOnly = BriefingSituationalLayout.computeFrames(
            width: 1200, heroHeight: nil, trailingHeight: trailingHeight, sitrepHeight: nil)
        expectTrue(trailingOnly.trailing?.minX == 0, "A lone trailing module starts at the leading edge")
        expectTrue(trailingOnly.trailing?.width == 1200, "A lone trailing module takes the full width")

        // 5. Hiding hero module leaves no hole:
        let noHero = BriefingSituationalLayout.computeFrames(
            width: 600,
            heroHeight: nil,
            trailingHeight: trailingHeight,
            sitrepHeight: sitrepHeight
        )
        expectTrue(noHero.hero == nil, "Hero frame is absent")
        expectTrue(noHero.trailing?.minY == 0, "Trailing starts at top when hero is hidden")
        expectTrue(noHero.sitrep?.minY == trailingHeight + spacing, "Sitrep follows trailing with no gap")
    }

    @MainActor static func testAcceptanceTests1201() async {
        print("  - Testing acceptance criteria for #1201...")
        // 1. Hero carousel up to 10 stories and rotates every 10 seconds:
        expectTrue(BriefingView.heroLimit == 10, "Hero shows up to ten stories (#1201)")
        expectTrue(BriefingHeroCarouselView.autoAdvanceInterval == 10.0, "Hero rotates every 10 seconds (#1201)")

        // 2. Muting topic set is "No AI, Please":
        expectTrue(
            MuteTopicSet.artificialIntelligence.title == "No AI, Please", "Muting topic set is 'No AI, Please' (#1201)")

        // 3. Inline source citations match mock's neutral chip:
        let regFill = InlineChip.fill(contrast: .standard)
        let incFill = InlineChip.fill(contrast: .increased)
        let regText = InlineChip.textColor(contrast: .standard)
        let incText = InlineChip.textColor(contrast: .increased)
        expectTrue(InlineChip.cornerRadius == 4.0, "Inline chip corner radius is 4.0 pt")
        expectTrue(regFill != incFill, "Increased contrast strengthens chip fill")
        expectTrue(regText != incText, "Increased contrast strengthens chip text")

        // 4. The banner's recorded photo is tested through a real pass: LifecycleTests.testBannerTakesRecordedPhoto.
        let baseStory = FeedArticle(
            storedID: "al-jazeera-1", title: "AJ Story", link: "https://example.com/aj", guid: "aj-1",
            description: "", pubDate: Date(), source: "Al Jazeera", imageUrl: nil)

        // 5. The action a Priority developments card's tap calls opens an event's overview. The tap gesture itself
        // needs a window: it is on the live-check list of #1201.
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
        actions.open(.event(summary, representative: baseStory, visibleMembers: [baseStory]))
        expectTrue(openedEventID == "event-1", "An event entry opens its overview (#1201)")
    }

    @MainActor
    static func testAppleIntelligenceAvailabilityTests() async {
        print("  - Testing AppleIntelligenceAvailability unified check (#1212)...")
        let avail = AppleIntelligenceAvailability.shared

        // Test each state properties:
        for state in AppleIntelligenceState.allCases {
            expectTrue(!state.statusLabel.isEmpty, "State \(state) has statusLabel")
            expectTrue(!state.explanation.isEmpty, "State \(state) has explanation")
            if state == .ready {
                expectTrue(state.isAvailable, "Ready state is available")
                expectTrue(state.actionTitle == nil, "Ready state has no action")
            } else {
                expectTrue(!state.isAvailable, "Non-ready state is not available")
            }
        }

        // Test resolveState logic with OS version:
        let v14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        expectTrue(
            AppleIntelligenceAvailability.resolveState(aiEnabled: true, osVersion: v14) == .macOSVersionTooOld,
            "macOS 14 resolves to macOSVersionTooOld"
        )
        let v15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        expectTrue(
            AppleIntelligenceAvailability.resolveState(
                aiEnabled: true, osVersion: v15, foundationModelsAvailability: "available") == .macOSVersionTooOld,
            "macOS 15 to 25 resolves to macOSVersionTooOld even when the model reports available"
        )
        expectTrue(
            AppleIntelligenceAvailability.resolveState(aiEnabled: false, osVersion: v14) == .appDisabled,
            "aiEnabled=false resolves to appDisabled regardless of OS"
        )

        // Real FoundationModels availability reasons (#1212):
        expectTrue(
            AppleIntelligenceAvailability.classifyAvailability("deviceNotEligible") == .unsupportedDevice,
            "deviceNotEligible classifies to unsupportedDevice"
        )
        expectTrue(
            AppleIntelligenceAvailability.classifyAvailability("appleIntelligenceNotEnabled") == .systemDisabled,
            "appleIntelligenceNotEnabled classifies to systemDisabled"
        )
        expectTrue(
            AppleIntelligenceAvailability.classifyAvailability("modelNotReady") == .modelDownloading,
            "modelNotReady classifies to modelDownloading"
        )
        expectTrue(
            AppleIntelligenceAvailability.classifyAvailability("available") == .ready,
            "available classifies to ready"
        )

        // Ineligible Mac:
        expectTrue(
            AppleIntelligenceAvailability.resolveState(
                aiEnabled: true, foundationModelsAvailability: "unavailable(deviceNotEligible)") == .unsupportedDevice,
            "deviceNotEligible resolves to unsupportedDevice"
        )

        // System Settings off (with real reason string):
        expectTrue(
            AppleIntelligenceAvailability.resolveState(
                aiEnabled: true, foundationModelsAvailability: "unavailable(appleIntelligenceNotEnabled)")
                == .systemDisabled,
            "appleIntelligenceNotEnabled resolves to systemDisabled"
        )
        expectTrue(
            AppleIntelligenceAvailability.resolveState(
                aiEnabled: true, foundationModelsAvailability: "unavailable(disabledInSettings)") == .systemDisabled,
            "disabledInSettings resolves to systemDisabled"
        )

        // Model downloading (with real reason string):
        expectTrue(
            AppleIntelligenceAvailability.resolveState(
                aiEnabled: true, foundationModelsAvailability: "unavailable(modelNotReady)") == .modelDownloading,
            "modelNotReady resolves to modelDownloading"
        )
        expectTrue(
            AppleIntelligenceAvailability.resolveState(
                aiEnabled: true, foundationModelsAvailability: "unavailable(modelDownloading)") == .modelDownloading,
            "modelDownloading resolves to modelDownloading"
        )

        // Injected mock in AppleIntelligenceAvailability:
        avail.mockState = .unsupportedDevice
        expectTrue(avail.state == .unsupportedDevice, "Mock state injected")
        expectTrue(
            avail.state.explanation.contains("does not support Apple Intelligence"),
            "unsupportedDevice explanation matches")

        avail.mockState = .macOSVersionTooOld
        expectTrue(
            avail.state.explanation.contains("macOS 26"),
            "macOSVersionTooOld explanation references macOS 26")

        avail.mockState = .systemDisabled
        expectTrue(avail.state == .systemDisabled, "Mock state updated")
        expectTrue(avail.state.explanation.contains("System Settings"), "systemDisabled explanation matches")

        avail.mockState = nil
        expectTrue(avail.mockState == nil, "Mock state cleared")
    }

    @MainActor
    static func testRuntimeDiagnosticsTests() {
        print("  - Testing runtime diagnostics and warning eliminations (#1214)...")
        // 1. FocusStatus entitlement check
        expectTrue(
            FocusStatus.hasCommunicationEntitlement == false,
            "News does not possess communication notifications entitlement")
        expectTrue(
            FocusStatus.isFocused == nil, "FocusStatus returns nil gracefully without error spew when unentitled")

        // Injected provider for testing
        FocusStatus.provider = { true }
        expectTrue(FocusStatus.isFocused == true, "FocusStatus provider injects focused state")
        let gateFocused = BannerGate.decide(
            authorization: .authorized, alert: .enabled, style: .banner, previews: .always,
            focused: FocusStatus.isFocused)
        expectTrue(gateFocused == .suppress(.focus), "Focused state suppresses banner")

        FocusStatus.provider = { false }
        expectTrue(FocusStatus.isFocused == false, "FocusStatus provider injects unfocused state")
        let gateUnfocused = BannerGate.decide(
            authorization: .authorized, alert: .enabled, style: .banner, previews: .always,
            focused: FocusStatus.isFocused)
        expectTrue(gateUnfocused == .show(redacted: false, persistent: false), "Unfocused state delivers banner")
        FocusStatus.provider = nil

        // 2. StoryBannerPresenter window key status check
        final class NonKeyAuxWindow: NSWindow {
            override var canBecomeKey: Bool { false }
        }
        let auxWindow = NonKeyAuxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        auxWindow.orderFront(nil)
        expectTrue(auxWindow.canBecomeKey == false, "Auxiliary helper window cannot become key")
        expectTrue(auxWindow.isVisible, "Auxiliary window is visible before showMainWindow")
        StoryBannerPresenter.mainWindow = auxWindow
        StoryBannerPresenter.showMainWindow()
        expectTrue(auxWindow.isVisible, "Auxiliary window remains visible after showMainWindow")
        expectTrue(!auxWindow.isKeyWindow, "Auxiliary window did not become key window")
        StoryBannerPresenter.mainWindow = nil
        auxWindow.orderOut(nil)
    }
}
