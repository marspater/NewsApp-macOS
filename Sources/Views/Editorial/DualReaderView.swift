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

/// Two publishers' reports of one event: side by side from 1,200 pt and stacked below it (W3 #717). A passage the other
/// report says too is a button that scrolls the other column to its match. The comparison is by meaning, computed on
/// this Mac, and says what each report has; it never says which publisher is right or biased.
struct DualReaderView: View {
    let session: DualReaderSession
    let leftPassages: [String]
    let rightPassages: [String]

    /// The pair whose passages are highlighted in both columns.
    @State private var selected: PassageContrastPair?
    @State private var stackedTab: StackedTab = .comparison
    @Environment(\.effectiveContrast) private var contrast
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    private enum StackedTab: Hashable {
        case comparison
        case left
        case right
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                summary
                Divider()
                if DualReaderLayoutMode.mode(for: geometry.size.width) == .sideBySide {
                    sideBySide
                } else {
                    stacked
                }
            }
        }
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(spacing: AppSpacing.xs) {
            ForEach(PerspectiveContrastType.allCases, id: \.self) { type in
                TagView(
                    title: Self.summaryText(type, count: count(of: type)), systemImage: type.systemIcon,
                    tint: Self.tint(for: type))
            }
            Spacer(minLength: AppSpacing.md)
            Text("Compared by meaning on this Mac")
                .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
        }
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.vertical, AppSpacing.sm)
        .accessibilityElement(children: .combine)
    }

    private func count(of type: PerspectiveContrastType) -> Int {
        switch type {
        case .consensus: return session.consensusCount
        case .divergence: return session.divergenceCount
        case .uniqueLead: return session.uniqueLeadCount
        }
    }

    static func summaryText(_ type: PerspectiveContrastType, count: Int) -> String {
        switch type {
        case .consensus: return "\(count) both report"
        case .divergence: return "\(count) reported differently"
        case .uniqueLead: return "\(count) only in one report"
        }
    }

    /// Neutral where both reports agree, the caution color where they differ, the accent for what only one has.
    /// Every tag also carries its symbol and words, so no state rests on color (DESIGN.md 16).
    static func tint(for type: PerspectiveContrastType) -> Color {
        switch type {
        case .consensus: return AppColor.secondaryText
        case .divergence: return AppColor.caution
        case .uniqueLead: return AppColor.accent
        }
    }

    // MARK: - Side by side

    private var sideBySide: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                column(session.leftPublisherName, passages: leftPassages, isLeft: true, proxy: proxy)
                Divider()
                column(session.rightPublisherName, passages: rightPassages, isLeft: false, proxy: proxy)
            }
        }
    }

    /// One report, read to the end before the other: VoiceOver treats each column as a container, left first.
    private func column(_ publisher: String, passages: [String], isLeft: Bool, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(publisher)
                .font(AppTypography.sectionTitle)
                .lineLimit(1)
                .padding(.horizontal, AppSpacing.md)
                .padding(.top, AppSpacing.sm)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                    ForEach(passages.indices, id: \.self) { index in
                        passageRow(passages[index], index: index, isLeft: isLeft, proxy: proxy)
                    }
                }
                .padding(AppSpacing.md)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Report from \(publisher)")
        .accessibilitySortPriority(isLeft ? 2 : 1)
    }

    /// A passage with a counterpart is a button, so it takes keyboard focus and VoiceOver activation as well as a click;
    /// a passage only this report has is plain text.
    @ViewBuilder
    private func passageRow(_ text: String, index: Int, isLeft: Bool, proxy: ScrollViewProxy) -> some View {
        let pair = isLeft ? session.pair(forLeft: index) : session.pair(forRight: index)
        let isSelected = selected.map { isLeft ? $0.leftPassageIndex == index : $0.rightPassageIndex == index } ?? false
        Group {
            if let pair, pair.hasCounterpart {
                Button {
                    select(
                        pair, scrollTo: isLeft ? "right_\(pair.rightPassageIndex)" : "left_\(pair.leftPassageIndex)",
                        proxy: proxy)
                } label: {
                    card(text, pair: pair, isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(pair.contrastType.displayName). \(text)")
                .accessibilityHint("Shows the matching passage in the other report")
            } else {
                card(text, pair: pair, isSelected: false)
                    .accessibilityElement(children: .combine)
            }
        }
        .id("\(isLeft ? "left" : "right")_\(index)")
    }

    private func select(_ pair: PassageContrastPair, scrollTo id: String, proxy: ScrollViewProxy) {
        selected = pair
        withAnimation(reduceMotion ? nil : AppMotion.navigation) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func card(_ text: String, pair: PassageContrastPair?, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if let pair {
                TagView(
                    title: pair.contrastType.displayName, systemImage: pair.contrastType.systemIcon,
                    tint: Self.tint(for: pair.contrastType))
            }
            Text(text)
                .font(AppTypography.body)
                .foregroundStyle(AppColor.primaryText)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppSpacing.sm)
        .background(
            isSelected ? AppColor.passageHighlight : AppColor.surface,
            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(
                    isSelected ? AppColor.accent : AppColor.border(for: contrast),
                    lineWidth: isSelected ? AppLayout.focusStroke : AppLayout.hairline)
        }
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    // MARK: - Stacked

    private var stacked: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $stackedTab) {
                Text("Comparison").tag(StackedTab.comparison)
                Text(session.leftPublisherName).tag(StackedTab.left)
                Text(session.rightPublisherName).tag(StackedTab.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.vertical, AppSpacing.xs)
            Divider()
            switch stackedTab {
            case .comparison:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                        ForEach(session.passageAlignments) { pair in
                            comparisonCard(pair)
                        }
                    }
                    .padding(AppSpacing.md)
                }
            case .left:
                singleReport(passages: leftPassages, isLeft: true)
            case .right:
                singleReport(passages: rightPassages, isLeft: false)
            }
        }
    }

    private func singleReport(passages: [String], isLeft: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(passages.indices, id: \.self) { index in
                    card(
                        passages[index], pair: isLeft ? session.pair(forLeft: index) : session.pair(forRight: index),
                        isSelected: false
                    )
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(AppSpacing.md)
        }
    }

    /// A pair as one card: what both say with each publisher's words, or the one passage only a report has.
    private func comparisonCard(_ pair: PassageContrastPair) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            TagView(
                title: pair.contrastType.displayName, systemImage: pair.contrastType.systemIcon,
                tint: Self.tint(for: pair.contrastType))
            if pair.uniqueSide != .right {
                quotedPassage(pair.leftSnippet, publisher: session.leftPublisherName)
            }
            if pair.uniqueSide != .left {
                quotedPassage(pair.rightSnippet, publisher: session.rightPublisherName)
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(AppColor.border(for: contrast), lineWidth: AppLayout.hairline)
        }
        .accessibilityElement(children: .combine)
    }

    private func quotedPassage(_ text: String, publisher: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
            EyebrowText(publisher)
            Text(text).font(AppTypography.body).foregroundStyle(AppColor.primaryText)
        }
    }
}

#if DEBUG
    #Preview("Dual reader side by side", traits: .modifier(PreviewEnvironment())) {
        DualReaderView(
            session: PreviewFixtures.comparisonSession, leftPassages: PreviewFixtures.comparisonLeft,
            rightPassages: PreviewFixtures.comparisonRight
        )
        .frame(width: AppLayout.dualReaderSheetWidth, height: AppLayout.dualReaderSheetHeight)
    }

    #Preview("Dual reader stacked", traits: .modifier(PreviewEnvironment())) {
        DualReaderView(
            session: PreviewFixtures.comparisonSession, leftPassages: PreviewFixtures.comparisonLeft,
            rightPassages: PreviewFixtures.comparisonRight
        )
        .frame(width: AppLayout.dualReaderSheetMinimumWidth, height: AppLayout.dualReaderSheetHeight)
    }

    #Preview("Dual reader accessibility", traits: .modifier(PreviewEnvironment())) {
        DualReaderView(
            session: PreviewFixtures.comparisonSession, leftPassages: PreviewFixtures.comparisonLeft,
            rightPassages: PreviewFixtures.comparisonRight
        )
        .frame(width: AppLayout.dualReaderSheetWidth, height: AppLayout.dualReaderSheetHeight)
        .previewAccessibility()
    }
#endif
