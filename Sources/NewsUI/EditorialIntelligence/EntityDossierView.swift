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

/// Comprehensive editorial dossier inspector sheet / popover (W2 #716).
/// Displays 30-day coverage timeline, co-occurring entities, and publisher breakdown.
public struct EntityDossierView: View {
    public let dossier: EntityDossier
    public let onSelectRelatedEntity: ((String) -> Void)?
    public let onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    public init(
        dossier: EntityDossier,
        onSelectRelatedEntity: ((String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.dossier = dossier
        self.onSelectRelatedEntity = onSelectRelatedEntity
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    coverageTimelineSection
                    coOccurrencesSection
                    publisherDistributionSection
                    recentStoriesSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: dossier.entity.entityType.displayIcon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(typeColor)
                .frame(width: 40, height: 40)
                .background(typeColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(dossier.entity.canonicalName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(NSColor.labelColor))

                HStack(spacing: 8) {
                    Text(dossier.entity.entityType.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(typeColor.opacity(0.15))
                        .foregroundStyle(typeColor)
                        .clipShape(Capsule())

                    Text("\(dossier.entity.mentionCount) total mentions")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(NSColor.secondaryLabelColor))
                }
            }

            Spacer()

            Button(action: {
                if let onDismiss = onDismiss {
                    onDismiss()
                } else {
                    dismiss()
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(NSColor.tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .help("Close Dossier")
            .accessibilityLabel("Close Dossier")
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - 30-Day Coverage Timeline

    private var coverageTimelineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("30-Day Coverage Timeline", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(NSColor.labelColor))
                Spacer()
                Text("\(dossier.coverage30Days.reduce(0) { $0 + $1.mentionCount }) mentions in window")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
            }

            if dossier.coverage30Days.isEmpty {
                Text("No mentions recorded in the last 30 days.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                let maxCount = max(1, dossier.coverage30Days.map(\.mentionCount).max() ?? 1)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(dossier.coverage30Days, id: \.dateBucket) { bucket in
                        VStack(spacing: 4) {
                            let heightFraction = CGFloat(bucket.mentionCount) / CGFloat(maxCount)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(typeColor)
                                .frame(height: max(4, heightFraction * 48))

                            Text(shortDate(bucket.dateBucket))
                                .font(.system(size: 9))
                                .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .help("\(bucket.dateBucket): \(bucket.mentionCount) mentions")
                    }
                }
                .frame(height: 70)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
            }
        }
    }

    // MARK: - Co-occurring Entities

    private var coOccurrencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Co-occurring Entities", systemImage: "person.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(NSColor.labelColor))

            if dossier.coOccurringEntities.isEmpty {
                Text("No co-occurring entities recorded.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                    ForEach(dossier.coOccurringEntities, id: \.targetEntityId) { co in
                        Button(action: {
                            onSelectRelatedEntity?(co.targetEntityId)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: co.targetEntityType.displayIcon)
                                    .font(.system(size: 10))
                                    .foregroundStyle(color(for: co.targetEntityType))

                                Text(co.targetCanonicalName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color(NSColor.labelColor))
                                    .lineLimit(1)

                                Spacer(minLength: 2)

                                Text("\(co.coOccurrenceCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Inspect related entity \(co.targetCanonicalName)")
                    }
                }
            }
        }
    }

    // MARK: - Publisher Distribution Breakdown

    private var publisherDistributionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Publisher Distribution", systemImage: "newspaper.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(NSColor.labelColor))

            if dossier.publisherBreakdown.isEmpty {
                Text("No publisher distribution available.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
            } else {
                VStack(spacing: 8) {
                    ForEach(dossier.publisherBreakdown, id: \.publisherId) { pub in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(pub.publisherName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color(NSColor.labelColor))
                                    .lineLimit(1)

                                Spacer()

                                Text("\(pub.mentionCount) (\(Int(pub.share * 100))%)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Color(NSColor.separatorColor).opacity(0.3))

                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(typeColor)
                                        .frame(width: max(4, geo.size.width * CGFloat(pub.share)))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
            }
        }
    }

    // MARK: - Recent Stories

    private var recentStoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recent Coverage", systemImage: "doc.text.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(NSColor.labelColor))

            if dossier.recentArticleIds.isEmpty {
                Text("No recent stories recorded.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
            } else {
                Text("\(dossier.recentArticleIds.count) indexed stories reference this entity.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
            }
        }
    }

    // MARK: - Helpers

    private var typeColor: Color {
        color(for: dossier.entity.entityType)
    }

    private func color(for type: EntityType) -> Color {
        switch type {
        case .person:
            return .blue
        case .organization:
            return .purple
        case .location, .place:
            return .teal
        case .unknown:
            return .gray
        }
    }

    private func shortDate(_ isoDate: String) -> String {
        // e.g. "2026-11-09" -> "11/09"
        let parts = isoDate.split(separator: "-")
        guard parts.count == 3 else { return isoDate }
        return "\(parts[1])/\(parts[2])"
    }
}
