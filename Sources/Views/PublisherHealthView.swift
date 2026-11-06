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

import SwiftUI

/// The Publisher Health sheet, opened from Settings → Subscriptions (#715): one sortable row per feed. It describes
/// how feeds behave technically and never rates their reporting. The database actor computes the rows off the main
/// thread; they reload when the sheet opens and after each refresh, completed or cancelled.
struct PublisherHealthView: View {
    @EnvironmentObject private var feedManager: FeedManager
    @Environment(\.dismiss) private var dismiss
    @State private var phase = PublisherHealthContent.Phase.loading

    var body: some View {
        PublisherHealthContent(phase: phase)
            .frame(width: AppLayout.publisherHealthSheetWidth)
            .frame(minHeight: AppLayout.publisherHealthSheetMinHeight)
            .navigationTitle("Publisher Health")
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .task(
                id: ReloadTrigger(
                    completed: feedManager.lastRefreshCompletedAt, cancelled: feedManager.cancelledRefreshCount)
            ) {
                await load()
            }
            .onExitCommand { dismiss() }
    }

    /// A completed refresh or a cancelled one, either of which may have recorded feed samples.
    private struct ReloadTrigger: Equatable {
        let completed: Date?
        let cancelled: Int
    }

    private func load() async {
        do {
            let rows = try await feedManager.publisherHealthRows()
            guard !Task.isCancelled else { return }
            phase = .loaded(rows)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            phase = .failed
        }
    }
}

/// Everything inside the sheet, apart from loading its rows.
struct PublisherHealthContent: View {
    enum Phase: Equatable {
        case loading, failed
        case loaded([PublisherHealthRow])
    }

    let phase: Phase

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Publisher Health")
                    .font(AppTypography.title)
                    .foregroundStyle(AppColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Whether each feed responds, how often it publishes and how much story text News can read.")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.top, AppLayout.pageInset)
            .padding(.bottom, AppSpacing.sm)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            Text(PublisherHealthRow.footnote)
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppLayout.pageInset)
                .padding(.vertical, AppSpacing.xs)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading Publisher Health…")
        case .failed:
            ContentUnavailableView(
                "Publisher Health Unavailable", systemImage: "exclamationmark.triangle",
                description: Text("News could not read its feed history. Try again after the next refresh."))
        case .loaded(let rows) where rows.isEmpty:
            ContentUnavailableView(
                "No Subscriptions", systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Subscribe to a feed to see how it behaves."))
        case .loaded(let rows):
            PublisherHealthTable(rows: rows)
        }
    }
}

/// The native table. Sorted by success rate first, so the feeds in most trouble lead.
private struct PublisherHealthTable: View {
    let rows: [PublisherHealthRow]
    @State private var selection: PublisherHealthRow.ID?
    @State private var sortOrder = [PublisherHealthSort(.success)]

    var body: some View {
        Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Feed", sortUsing: PublisherHealthSort(.name)) { row in
                Text(row.name)
                    .help(row.id)
                    .accessibilityHint(row.id)
            }
            .width(min: AppLayout.publisherHealthFeedColumnMinWidth, ideal: AppLayout.publisherHealthFeedColumnMinWidth)
            TableColumn("Success", sortUsing: PublisherHealthSort(.success)) { row in
                metric(row.successText, spoken: row.successSpoken)
            }
            .width(AppLayout.publisherHealthNumberColumnWidth)
            TableColumn("Latency", sortUsing: PublisherHealthSort(.latency)) { row in
                metric(row.latencyText, spoken: row.latencySpoken)
            }
            .width(AppLayout.publisherHealthNumberColumnWidth)
            TableColumn("Per Day", sortUsing: PublisherHealthSort(.frequency)) { row in
                metric(row.frequencyText, spoken: row.frequencySpoken)
            }
            .width(AppLayout.publisherHealthNumberColumnWidth)
            TableColumn("Text", sortUsing: PublisherHealthSort(.extraction)) { row in
                Text(row.extractionText)
                    .foregroundStyle(
                        row.metrics.extractionClass == .unknown ? AppColor.secondaryText : AppColor.primaryText)
            }
            .width(AppLayout.publisherHealthTextColumnWidth)
            TableColumn("Recommendation", sortUsing: PublisherHealthSort(.recommendation)) { row in
                recommendation(row)
            }
            .width(min: AppLayout.publisherHealthRecommendationColumnMinWidth)
        }
    }

    private func metric(_ text: String, spoken: String) -> some View {
        Text(text)
            .monospacedDigit()
            .accessibilityLabel(spoken)
    }

    @ViewBuilder
    private func recommendation(_ row: PublisherHealthRow) -> some View {
        if row.recommendations.isEmpty {
            Text(PublisherHealthRow.unknownText)
                .foregroundStyle(AppColor.secondaryText)
                .accessibilityLabel("No recommendation")
        } else {
            // The symbol marks the row, the words carry the meaning: state never relies on color alone.
            HStack(spacing: AppSpacing.xxs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColor.warning)
                    .accessibilityHidden(true)
                Text(row.recommendationText)
                    .foregroundStyle(AppColor.primaryText)
                    .lineLimit(1)
                    .help(row.recommendationText)
            }
        }
    }
}
