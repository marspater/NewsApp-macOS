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

import Charts
import SwiftUI

/// The dossier of one entity as a popover: loads it from the entity index and lets the person follow a related entity
/// and step back (W2 #716). Nothing leaves the Mac.
struct EntityDossierPopover: View {
    let entity: EntityRecord
    let source: EntitySource
    let onOpenStory: (String) -> Void
    /// Entities followed from the related list; the last one is shown.
    @State private var trail: [EntityRecord] = []
    @State private var dossier: EntityDossier?
    @State private var isLoading = true

    private var current: EntityRecord { trail.last ?? entity }

    var body: some View {
        Group {
            if let dossier {
                EntityDossierView(
                    dossier: dossier, canGoBack: !trail.isEmpty, onBack: { trail.removeLast() },
                    onSelectRelated: { trail.append($0) }, onOpenStory: onOpenStory)
            } else if isLoading {
                ProgressView("Loading coverage…")
                    .frame(maxWidth: .infinity)
                    .padding(AppSpacing.lg)
            } else {
                ContentUnavailableView(
                    "No Coverage Yet", systemImage: "chart.bar",
                    description: Text("Stories that name \(current.canonicalName) appear here once they are indexed."))
            }
        }
        .frame(width: AppLayout.entityDossierWidth)
        .task(id: current.id) {
            isLoading = true
            dossier = await source.dossier(current.id)
            isLoading = false
        }
    }
}

/// An entity's 30-day coverage, top publishers, related entities and recent stories, all counted from the stories on
/// this Mac (W2 #716).
struct EntityDossierView: View {
    let dossier: EntityDossier
    var canGoBack = false
    var onBack: () -> Void = {}
    var onSelectRelated: (EntityRecord) -> Void = { _ in }
    var onOpenStory: (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                header
                coverage
                if !dossier.publishers.isEmpty { publishers }
                if !dossier.related.isEmpty { related }
                if !dossier.recentStories.isEmpty { recentStories }
                Text("Counted from the stories saved on this Mac.")
                    .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: AppLayout.entityDossierMaxHeight)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
            if canGoBack {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Back")
                    .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                Text(dossier.entity.canonicalName)
                    .font(AppTypography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Label {
                    Text(
                        "\(dossier.entity.entityType.displayName) · \(Self.storiesText(dossier.storiesInWindow)) in 30 days"
                    )
                    .monospacedDigit()
                } icon: {
                    Image(systemName: dossier.entity.entityType.symbol)
                }
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
            }
        }
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            sectionTitle("Coverage")
            Chart(Array(dossier.coverage.enumerated()), id: \.offset) { index, day in
                BarMark(x: .value("Day", index), y: .value("Stories", day.storyCount), width: .ratio(0.8))
                    .foregroundStyle(AppColor.accent)
                    .accessibilityLabel(Self.dayText(day.day))
                    .accessibilityValue(Self.storiesText(day.storyCount))
            }
            .chartXScale(domain: -0.5...Double(dossier.coverage.count) - 0.5)
            .chartXAxis {
                AxisMarks(values: .stride(by: 7)) { value in
                    AxisTick()
                    if let index = value.as(Int.self), dossier.coverage.indices.contains(index) {
                        AxisValueLabel(Self.dayText(dossier.coverage[index].day))
                    }
                }
            }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: AppLayout.entityChartHeight)
            Text(coverageSummary).font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
        }
    }

    private var publishers: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            sectionTitle("Top publishers")
            Grid(
                alignment: .leadingFirstTextBaseline, horizontalSpacing: AppSpacing.sm, verticalSpacing: AppSpacing.xxs
            ) {
                ForEach(dossier.publishers, id: \.publisher) { share in
                    GridRow {
                        Text(share.publisher).font(AppTypography.callout).lineLimit(1)
                        Text("\(share.storyCount)").gridColumnAlignment(.trailing)
                        Text(share.share, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(AppColor.secondaryText).gridColumnAlignment(.trailing)
                    }
                    .font(AppTypography.callout).monospacedDigit()
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var related: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            sectionTitle("Related")
            ForEach(dossier.related) { item in
                Button {
                    onSelectRelated(item.entity)
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: item.entity.entityType.symbol)
                            .foregroundStyle(AppColor.secondaryText).accessibilityHidden(true)
                        Text(item.entity.canonicalName).font(AppTypography.callout).lineLimit(1)
                        Spacer(minLength: AppSpacing.xs)
                        Text("\(item.sharedStories) shared").font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(item.entity.canonicalName), \(item.entity.entityType.displayName), \(item.sharedStories) shared stories"
                )
                .accessibilityHint("Shows its dossier")
            }
        }
    }

    private var recentStories: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            sectionTitle("Recent stories")
            ForEach(dossier.recentStories) { story in
                Button {
                    onOpenStory(story.id)
                } label: {
                    VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                        Text(story.title).font(AppTypography.callout).lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(story.publisher) · \(story.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(story.title), \(story.publisher), \(story.date.formatted(date: .abbreviated, time: .omitted))"
                )
                .accessibilityHint("Opens the story")
            }
        }
    }

    // MARK: - Text

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(AppTypography.headline).accessibilityAddTraits(.isHeader)
    }

    private var coverageSummary: String {
        guard let busiest = dossier.coverage.max(by: { $0.storyCount < $1.storyCount }), busiest.storyCount > 0
        else { return "No stories named it in the last 30 days." }
        return
            "\(Self.storiesText(dossier.storiesInWindow)); most on \(Self.dayText(busiest.day)) (\(busiest.storyCount))."
    }

    static func storiesText(_ count: Int) -> String { "\(count) \(count == 1 ? "story" : "stories")" }

    /// "Nov 3": the UTC day the coverage is counted in, the day World Tension readings use (#781).
    static func dayText(_ day: Date) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = .gmt
        return day.formatted(style)
    }
}

#if DEBUG
    #Preview("Entity dossier", traits: .modifier(PreviewEnvironment())) {
        EntityDossierView(dossier: PreviewFixtures.entityDossier)
            .frame(width: AppLayout.entityDossierWidth)
    }

    #Preview("Entity dossier accessibility", traits: .modifier(PreviewEnvironment())) {
        EntityDossierView(dossier: PreviewFixtures.entityDossier, canGoBack: true)
            .frame(width: AppLayout.entityDossierWidth)
            .previewAccessibility()
    }

    #Preview("Entity chips", traits: .modifier(PreviewEnvironment())) {
        EntityChipRow(articleIDs: ["preview"], source: PreviewFixtures.entitySource, onSelectStory: { _ in })
            .padding(AppLayout.pageInset)
            .frame(width: AppLayout.readingMeasure)
    }
#endif
