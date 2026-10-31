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
import SwiftUI

// MARK: - Pillars and modules

/// The five questions the Briefing answers, in board order (DESIGN.md 8.4).
enum BriefingPillar: String, CaseIterable, Codable, Sendable {
    case situationalAwareness, intelligenceAssessment, strategicImpact, weakSignals, forwardWatch

    var title: String {
        switch self {
        case .situationalAwareness: return "Situational awareness"
        case .intelligenceAssessment: return "Intelligence assessment"
        case .strategicImpact: return "Strategic impact"
        case .weakSignals: return "Weak signals"
        case .forwardWatch: return "Forward watch"
        }
    }

    var question: String {
        switch self {
        case .situationalAwareness: return "What is happening right now?"
        case .intelligenceAssessment: return "What does the reporting show?"
        case .strategicImpact: return "What could this affect?"
        case .weakSignals: return "What might we be missing?"
        case .forwardWatch: return "What should we monitor next?"
        }
    }

    /// SF Symbol standing in for the canvas icon.
    var systemImage: String {
        switch self {
        case .situationalAwareness: return "eye"
        case .intelligenceAssessment: return "magnifyingglass"
        case .strategicImpact: return "point.3.connected.trianglepath.dotted"
        case .weakSignals: return "dot.radiowaves.left.and.right"
        case .forwardWatch: return "calendar.badge.clock"
        }
    }

    /// Every module of the pillar in canvas order.
    var kinds: [BriefingModuleKind] { BriefingModuleKind.allCases.filter { $0.pillar == self } }
}

/// Every module the canvas lists, in canvas order. Raw values are persisted: never rename a case.
enum BriefingModuleKind: String, CaseIterable, Codable, Sendable {
    case heroCarousel, worldTension, sinceLastBriefing, executiveSitrep
    case priorityDevelopments, sourceFootprint, tensionDrivers
    case industryImpact, regions, regionTiles
    case weakSignals
    case forwardWatch, escalationTimeline

    var pillar: BriefingPillar {
        switch self {
        case .heroCarousel, .worldTension, .sinceLastBriefing, .executiveSitrep: return .situationalAwareness
        case .priorityDevelopments, .sourceFootprint, .tensionDrivers: return .intelligenceAssessment
        case .industryImpact, .regions, .regionTiles: return .strategicImpact
        case .weakSignals: return .weakSignals
        case .forwardWatch, .escalationTimeline: return .forwardWatch
        }
    }

    var title: String {
        switch self {
        case .heroCarousel: return "Hero carousel"
        case .worldTension: return "World Tension"
        case .sinceLastBriefing: return "Since your last briefing"
        case .executiveSitrep: return "Executive sitrep"
        case .priorityDevelopments: return "Priority developments"
        case .sourceFootprint: return "Source footprint"
        case .tensionDrivers: return "What drives World Tension"
        case .industryImpact: return "Industry impact"
        case .regions: return "Regions"
        case .regionTiles: return "Region tiles"
        case .weakSignals: return "Weak signals"
        case .forwardWatch: return "Forward watch"
        case .escalationTimeline: return "Escalation timeline"
        }
    }

    /// All shown except What drives World Tension, as the Customize sheet on the canvas shows.
    var defaultVisible: Bool { self != .tensionDrivers }

    /// Modules that take a whole row of their pillar; the others share rows in a grid.
    var spansFullWidth: Bool { self == .priorityDevelopments || self == .regionTiles }

    /// The carousel leads the board and the Executive sitrep closes its pillar, as on the canvas; neither moves.
    var isPinned: Bool { self == .heroCarousel || self == .executiveSitrep }
}

// MARK: - Layout

/// Per-Mac order and visibility of the modules, saved in `AppSettings` as the visible kinds in order per pillar.
/// A hidden module keeps its canvas place relative to the modules around it, so showing it again puts it back there.
struct BriefingLayout: Equatable, Codable, Sendable {
    private var visible: [BriefingPillar: [BriefingModuleKind]]

    static let `default` = BriefingLayout(
        visible: Dictionary(
            uniqueKeysWithValues: BriefingPillar.allCases.map { ($0, $0.kinds.filter(\.defaultVisible)) }))

    private init(visible: [BriefingPillar: [BriefingModuleKind]]) {
        self.visible = visible
    }

    /// Reads the stored form; a pillar the store lacks takes its default, and unknown or misplaced kinds are dropped.
    init(stored: [String: [String]]) {
        var visible = Self.default.visible
        for pillar in BriefingPillar.allCases {
            guard let raw = stored[pillar.rawValue] else { continue }
            var kinds: [BriefingModuleKind] = []
            for kind in raw.compactMap({ BriefingModuleKind(rawValue: $0) }) where kind.pillar == pillar {
                if !kinds.contains(kind) { kinds.append(kind) }
            }
            visible[pillar] = kinds
        }
        self.visible = visible
    }

    /// The stored form: pillar raw value to its visible kinds' raw values, in order.
    var stored: [String: [String]] {
        Dictionary(uniqueKeysWithValues: BriefingPillar.allCases.map { ($0.rawValue, modules(in: $0).map(\.rawValue)) })
    }

    /// The pillar's visible modules, in order.
    func modules(in pillar: BriefingPillar) -> [BriefingModuleKind] { visible[pillar] ?? [] }

    func isVisible(_ kind: BriefingModuleKind) -> Bool { modules(in: kind.pillar).contains(kind) }

    /// Every module of the pillar, visible ones in their order and hidden ones at their place (Customize sheet).
    func allModules(in pillar: BriefingPillar) -> [BriefingModuleKind] {
        var ordered = modules(in: pillar)
        for kind in pillar.kinds where !ordered.contains(kind) {
            ordered.insert(kind, at: Self.place(of: kind, in: ordered))
        }
        return ordered
    }

    mutating func setVisible(_ kind: BriefingModuleKind, _ isVisible: Bool) {
        var kinds = modules(in: kind.pillar)
        if isVisible, !kinds.contains(kind) {
            kinds.insert(kind, at: Self.place(of: kind, in: kinds))
        } else if !isVisible {
            kinds.removeAll { $0 == kind }
        }
        visible[kind.pillar] = kinds
    }

    /// Moves a visible module to `index` among its pillar's movable modules; pinned modules keep their ends and
    /// other pillars never change.
    mutating func move(_ kind: BriefingModuleKind, to index: Int) {
        guard !kind.isPinned else { return }
        let shown = modules(in: kind.pillar)
        var kinds = shown.filter { !$0.isPinned }
        guard let from = kinds.firstIndex(of: kind) else { return }
        kinds.remove(at: from)
        kinds.insert(kind, at: max(0, min(index, kinds.count)))
        let leading = shown.contains(.heroCarousel) ? [BriefingModuleKind.heroCarousel] : []
        let trailing = shown.contains(.executiveSitrep) ? [BriefingModuleKind.executiveSitrep] : []
        visible[kind.pillar] = leading + kinds + trailing
    }

    /// Just after the nearest module that precedes `kind` in canvas order, else first.
    private static func place(of kind: BriefingModuleKind, in kinds: [BriefingModuleKind]) -> Int {
        let canvas = kind.pillar.kinds
        guard let position = canvas.firstIndex(of: kind) else { return kinds.count }
        for earlier in canvas[..<position].reversed() {
            if let index = kinds.firstIndex(of: earlier) { return index + 1 }
        }
        return 0
    }
}

extension AppSettings {
    /// The Briefing's module order and visibility; the default until the reader customizes it.
    var briefingLayout: BriefingLayout {
        briefingModuleOrder.map { BriefingLayout(stored: $0) } ?? .default
    }

    func setBriefingLayout(_ layout: BriefingLayout) {
        setBriefingModuleOrder(layout == .default ? nil : layout.stored)
    }
}

// MARK: - Loading

/// Everything a module's loader may read. Built once per edition by the list.
struct BriefingLoadContext: Sendable {
    /// The edition, in edition order.
    let entries: [FeedEntry]
    let heroIDs: Set<String>
    let briefing: FiniteBriefing?
    let now: Date
    /// A snapshot of the window's World Tension model.
    let tension: WorldTensionState
    let readIDs: Set<String>
    /// When the edition before this one was selected; nil while the app does not track it.
    let previousEditionStartedAt: Date?
}

/// What the board shows besides the carousel and the World Tension tile: one optional per module, nil hides it.
struct BriefingBoardData: Equatable, Sendable {
    /// Cited facts and hero images.
    var details = BriefingStoryDetails()
    var sitrep: BriefingSitrepData?
    var sinceLast: BriefingSinceLastData?
    var priority: BriefingPriorityData?
    var footprint: BriefingFootprintData?
    /// The regions list and the region tiles share one data struct.
    var regions: BriefingRegionsData?
    var industry: BriefingIndustryData?
    var drivers: BriefingDriversData?
    var timeline: BriefingTimelineData?
    var weakSignals: BriefingWeakSignalsData?
    var forwardWatch: BriefingForwardWatchData?

    @MainActor
    static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self {
        var data = Self()
        data.details = await BriefingStoryDetails.load(for: context.entries, heroIDs: context.heroIDs, store: store)
        data.sitrep = await BriefingSitrepData.load(context, store: store)
        data.sinceLast = await BriefingSinceLastData.load(context, store: store)
        data.priority = await BriefingPriorityData.load(context, store: store)
        data.footprint = await BriefingFootprintData.load(context, store: store)
        data.regions = await BriefingRegionsData.load(context, store: store)
        data.industry = await BriefingIndustryData.load(context, store: store)
        data.drivers = await BriefingDriversData.load(context, store: store)
        data.timeline = await BriefingTimelineData.load(context, store: store)
        data.weakSignals = await BriefingWeakSignalsData.load(context, store: store)
        data.forwardWatch = await BriefingForwardWatchData.load(context, store: store)
        return data
    }

    /// Every module's capture sample, for `Tests/OverviewCaptures.swift`.
    static func captureFixture(details: BriefingStoryDetails) -> Self {
        Self(
            details: details, sitrep: BriefingSitrepData.captureFixture,
            sinceLast: BriefingSinceLastData.captureFixture, priority: BriefingPriorityData.captureFixture,
            footprint: BriefingFootprintData.captureFixture, regions: BriefingRegionsData.captureFixture,
            industry: BriefingIndustryData.captureFixture, drivers: BriefingDriversData.captureFixture,
            timeline: BriefingTimelineData.captureFixture, weakSignals: BriefingWeakSignalsData.captureFixture,
            forwardWatch: BriefingForwardWatchData.captureFixture)
    }

    /// Whether the module has anything true to show. The carousel needs stories; World Tension always shows its
    /// reading or says why there is none.
    func hasData(for kind: BriefingModuleKind, hasStories: Bool) -> Bool {
        let present: [BriefingModuleKind: Bool] = [
            .heroCarousel: hasStories, .worldTension: true,
            .sinceLastBriefing: sinceLast != nil, .executiveSitrep: sitrep != nil,
            .priorityDevelopments: priority != nil, .sourceFootprint: footprint != nil,
            .tensionDrivers: drivers != nil, .industryImpact: industry != nil,
            .regions: regions != nil, .regionTiles: regions != nil,
            .weakSignals: weakSignals != nil, .forwardWatch: forwardWatch != nil,
            .escalationTimeline: timeline != nil,
        ]
        return present[kind] ?? false
    }
}

/// The board's region filter. Every module view receives it.
struct BriefingBoardFilter: Equatable, Sendable {
    var region: TensionMacroRegion? = nil
    /// The regions the Regions loader resolved from each entry's reports, by entry ID; the board fills it from its data.
    var regionsByEntry: [String: Set<TensionMacroRegion>] = [:]

    /// Whether the entry belongs on the filtered board: always without a region, else when the entry's story touches
    /// it, by the loader's regions when known and the countries its headline names otherwise.
    func includes(_ entry: FeedEntry) -> Bool {
        guard let region else { return true }
        let regions = regionsByEntry[entry.id] ?? BriefingRegion.regions(of: entry.representative)
        return regions.contains(region)
    }
}

// MARK: - Shared chrome

/// The one module card (DESIGN.md 8.4): title row with an optional caption and options menu, surface fill, card
/// radius, hairline border and resting shadow. Modules never draw their own card background.
struct BriefingModuleCard<Content: View, Options: View>: View {
    let title: String
    var caption: String?
    var options: (() -> Options)?
    let content: () -> Content

    @Environment(\.effectiveContrast) private var contrast

    init(
        title: String, caption: String? = nil, options: (() -> Options)?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.caption = caption
        self.options = options
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Text(title)
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(AppColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: AppSpacing.xs)
                if let caption {
                    Text(caption).font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                }
                if let options {
                    Menu {
                        options()
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("\(title) options")
                    .accessibilityLabel("\(title) module options")
                }
            }
            content()
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(
                    AppColor.border(for: contrast),
                    lineWidth: contrast == .increased ? AppLayout.hoverStroke : AppLayout.hairline)
        )
        .shadow(color: AppShadow.cardRestingColor, radius: AppShadow.cardRestingRadius, x: 0, y: AppShadow.cardRestingY)
        .accessibilityElement(children: .contain)
    }
}

extension BriefingModuleCard where Options == EmptyView {
    init(title: String, caption: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, caption: caption, options: nil, content: content)
    }
}

/// A pillar's icon, its name as an eyebrow and its question (DESIGN.md 8.4).
struct BriefingPillarHeader: View {
    let pillar: BriefingPillar

    init(_ pillar: BriefingPillar) {
        self.pillar = pillar
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
            Image(systemName: pillar.systemImage)
                .foregroundStyle(AppColor.secondaryText)
                .accessibilityHidden(true)
            EyebrowText(pillar.title)
            Text(pillar.question)
                .font(AppTypography.callout.weight(.semibold))
                .foregroundStyle(AppColor.primaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Customize Briefing

/// The modules grouped by pillar, each with a visibility switch and Move Up / Move Down within its pillar; Reset to
/// Default and Done. Every change is saved at once.
struct BriefingCustomizeSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let layout = settings.briefingLayout
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                Text("Customize Briefing").font(AppTypography.sectionTitle).accessibilityAddTraits(.isHeader)
                Text("Reorder modules within a pillar. Hidden modules keep their place.")
                    .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            }
            .padding(AppSpacing.md)
            List {
                ForEach(BriefingPillar.allCases, id: \.self) { pillar in
                    Section {
                        ForEach(layout.allModules(in: pillar), id: \.self) { kind in
                            row(kind, layout: layout)
                        }
                    } header: {
                        EyebrowText(pillar.title)
                    }
                }
            }
            Divider()
            HStack {
                Button("Reset to Default") { settings.setBriefingLayout(.default) }
                    .disabled(layout == .default)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(AppSpacing.md)
        }
        .frame(minWidth: AppLayout.briefingCustomizeWidth, minHeight: AppLayout.briefingCustomizeHeight)
    }

    private func row(_ kind: BriefingModuleKind, layout: BriefingLayout) -> some View {
        // Pinned modules show no live move target: the carousel leads and the sitrep closes its pillar.
        let visible = layout.modules(in: kind.pillar).filter { !$0.isPinned }
        let index = kind.isPinned ? nil : visible.firstIndex(of: kind)
        return HStack(spacing: AppSpacing.xs) {
            Toggle(
                kind.title,
                isOn: Binding(
                    get: { layout.isVisible(kind) },
                    set: { isOn in update { $0.setVisible(kind, isOn) } }))
            Spacer()
            moveButton("chevron.up", label: "Move \(kind.title) Up", enabled: index.map { $0 > 0 } ?? false) {
                update { $0.move(kind, to: (index ?? 0) - 1) }
            }
            moveButton(
                "chevron.down", label: "Move \(kind.title) Down",
                enabled: index.map { $0 < visible.count - 1 } ?? false
            ) {
                update { $0.move(kind, to: (index ?? 0) + 1) }
            }
        }
    }

    private func moveButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func update(_ change: (inout BriefingLayout) -> Void) {
        var layout = settings.briefingLayout
        change(&layout)
        settings.setBriefingLayout(layout)
    }
}

// MARK: - Region mapping (#850)

/// Maps stories to the World Tension macro regions for the board's region filter.
enum BriefingRegion {
    /// The regions of every country the headline names (the matcher's place names, aliases and demonyms included),
    /// else of those in the description's opening.
    static func regions(of story: FeedArticle) -> Set<TensionMacroRegion> {
        for text in [story.title, String(ArticleContentRedactor.cleanText(story.description).prefix(240))] {
            let words = text.split { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" && $0 != "." }.map(String.init)
            var found = Set<TensionMacroRegion>()
            for index in words.indices {
                // Three, two and one-word names: "Saudi Arabia", "South Korea", "Jordan".
                for length in [3, 2, 1] where index + length <= words.count {
                    let place = EventPlaces.canonical(words[index..<(index + length)].joined(separator: " "))
                    if place.hasPrefix("@"), let region = region(code: String(place.dropFirst())) {
                        found.insert(region)
                    }
                }
            }
            if !found.isEmpty { return found }
        }
        return []
    }

    /// Western Asia, Iran and North Africa are the Middle East & North Africa; the rest follows the UN regions, with
    /// Central Asia in South Asia.
    /// UN subregions checked first, then UN continents.
    private static let subregions: [String: TensionMacroRegion] = [
        "145": .middleEastNorthAfrica, "021": .northAmerica, "034": .southAsia, "143": .southAsia,
        "030": .eastSoutheastAsia, "035": .eastSoutheastAsia,
    ]
    private static let continents: [String: TensionMacroRegion] = [
        "002": .subSaharanAfrica, "150": .europe, "019": .latinAmerica, "419": .latinAmerica, "009": .oceania,
    ]

    static func region(code: String) -> TensionMacroRegion? {
        if ["IR", "EG", "DZ", "LY", "MA", "TN", "SD", "EH"].contains(code) { return .middleEastNorthAfrica }
        let subregion = Locale.Region(code).containingRegion
        if let region = subregion.flatMap({ subregions[$0.identifier] }) { return region }
        return subregion?.containingRegion.flatMap { continents[$0.identifier] }
    }
}
