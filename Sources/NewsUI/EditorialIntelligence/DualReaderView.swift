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

/// Adaptive multi-perspective dual reader view comparing coverage across two sources (#717).
public struct DualReaderView: View {
    public let session: DualReaderSession
    public let leftPassages: [String]
    public let rightPassages: [String]

    @State private var selectedAlignmentId: String?
    @State private var stackedTab: StackedReaderTab = .comparison
    @Environment(\.dismiss) private var dismiss

    public enum StackedReaderTab: String, CaseIterable, Identifiable {
        case comparison = "Comparison"
        case leftSource = "Left Source"
        case rightSource = "Right Source"

        public var id: String { rawValue }
    }

    public init(
        session: DualReaderSession,
        leftPassages: [String],
        rightPassages: [String]
    ) {
        self.session = session
        self.leftPassages = leftPassages
        self.rightPassages = rightPassages
    }

    public var body: some View {
        GeometryReader { geometry in
            let mode = DualReaderLayoutMode.mode(for: geometry.size.width)
            VStack(spacing: 0) {
                headerView
                Divider()

                if mode == .sideBySide {
                    sideBySideContentView
                } else {
                    stackedContentView
                }
            }
            .frame(minWidth: 700, minHeight: 500)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "newspaper.fill")
                        .foregroundColor(.accentColor)
                    Text("Dual Perspective Comparison")
                        .font(.headline)
                }

                HStack(spacing: 12) {
                    Text(session.leftPublisherName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(session.rightPublisherName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }

            Spacer()

            // Metrics
            HStack(spacing: 8) {
                metricPill(
                    icon: PerspectiveContrastType.consensus.systemIcon,
                    label: "\(Int(session.consensusScore * 100))% Consensus",
                    color: .green
                )
                metricPill(
                    icon: PerspectiveContrastType.divergence.systemIcon,
                    label: "\(session.divergenceCount) Divergences",
                    color: .orange
                )
                metricPill(
                    icon: PerspectiveContrastType.uniqueLead.systemIcon,
                    label: "\(session.uniqueLeadCount) Unique",
                    color: .purple
                )
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close comparison")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func metricPill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .foregroundColor(color)
        .cornerRadius(6)
    }

    // MARK: - Side-by-Side Presentation

    private var sideBySideContentView: some View {
        ScrollViewReader { leftProxy in
            ScrollViewReader { rightProxy in
                HStack(spacing: 0) {
                    // Left Column
                    VStack(alignment: .leading, spacing: 8) {
                        columnHeader(title: session.leftPublisherName, icon: "doc.text")
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(leftPassages.enumerated()), id: \.offset) { index, passage in
                                    let pair = session.passageAlignments.first { $0.leftPassageIndex == index }
                                    passageCard(
                                        text: passage,
                                        index: index,
                                        pair: pair,
                                        isSelected: pair != nil && pair?.id == selectedAlignmentId
                                    )
                                    .id("left_\(index)")
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(pair == nil ? [] : .isButton)
                                    .accessibilityAction(named: "Show matching passage") {
                                        selectPassage(
                                            pair: pair,
                                            scrollTo: "right_\(pair?.rightPassageIndex ?? 0)",
                                            proxy: rightProxy
                                        )
                                    }
                                    .onTapGesture {
                                        selectPassage(
                                            pair: pair,
                                            scrollTo: "right_\(pair?.rightPassageIndex ?? 0)",
                                            proxy: rightProxy
                                        )
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Divider()

                    // Right Column
                    VStack(alignment: .leading, spacing: 8) {
                        columnHeader(title: session.rightPublisherName, icon: "doc.text.fill")
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(rightPassages.enumerated()), id: \.offset) { index, passage in
                                    let pair = session.passageAlignments.first { $0.rightPassageIndex == index }
                                    passageCard(
                                        text: passage,
                                        index: index,
                                        pair: pair,
                                        isSelected: pair != nil && pair?.id == selectedAlignmentId
                                    )
                                    .id("right_\(index)")
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(pair == nil ? [] : .isButton)
                                    .accessibilityAction(named: "Show matching passage") {
                                        selectPassage(
                                            pair: pair,
                                            scrollTo: "left_\(pair?.leftPassageIndex ?? 0)",
                                            proxy: leftProxy
                                        )
                                    }
                                    .onTapGesture {
                                        selectPassage(
                                            pair: pair,
                                            scrollTo: "left_\(pair?.leftPassageIndex ?? 0)",
                                            proxy: leftProxy
                                        )
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Stacked Presentation (< 1200pt)

    private var stackedContentView: some View {
        VStack(spacing: 0) {
            Picker("Perspective View", selection: $stackedTab) {
                ForEach(StackedReaderTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            switch stackedTab {
            case .comparison:
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(session.passageAlignments) { pair in
                            comparisonCard(pair: pair)
                        }
                    }
                    .padding(16)
                }
            case .leftSource:
                singlePassageList(title: session.leftPublisherName, passages: leftPassages, isLeft: true)
            case .rightSource:
                singlePassageList(title: session.rightPublisherName, passages: rightPassages, isLeft: false)
            }
        }
    }

    private func singlePassageList(title: String, passages: [String], isLeft: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(passages.enumerated()), id: \.offset) { index, passage in
                    let pair = session.passageAlignments.first {
                        isLeft ? $0.leftPassageIndex == index : $0.rightPassageIndex == index
                    }
                    passageCard(text: passage, index: index, pair: pair, isSelected: false)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Subviews

    private func selectPassage(
        pair: PassageContrastPair?,
        scrollTo targetId: String,
        proxy: ScrollViewProxy
    ) {
        guard let pair = pair else { return }
        selectedAlignmentId = pair.id
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(targetId, anchor: .center)
        }
    }

    private func columnHeader(title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func passageCard(
        text: String,
        index: Int,
        pair: PassageContrastPair?,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pair = pair {
                HStack {
                    Label(pair.contrastType.displayName, systemImage: pair.contrastType.systemIcon)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(contrastColor(for: pair.contrastType))

                    Spacer()

                    Text("\(Int(pair.similarityScore * 100))% match")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Text(text)
                .font(.body)
                .lineSpacing(4)
                .foregroundColor(.primary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected
                        ? Color.accentColor
                        : (pair.map { contrastColor(for: $0.contrastType).opacity(0.25) } ?? Color.clear),
                    lineWidth: isSelected ? 2 : 1
                )
        )
    }

    private func comparisonCard(pair: PassageContrastPair) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(pair.contrastType.displayName, systemImage: pair.contrastType.systemIcon)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(contrastColor(for: pair.contrastType))

                Spacer()

                Text("Similarity: \(Int(pair.similarityScore * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.leftPublisherName)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Text(pair.leftSnippet)
                    .font(.subheadline)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.rightPublisherName)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Text(pair.rightSnippet)
                    .font(.subheadline)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
        }
        .padding(14)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(contrastColor(for: pair.contrastType).opacity(0.3), lineWidth: 1)
        )
    }

    private func contrastColor(for type: PerspectiveContrastType) -> Color {
        switch type {
        case .consensus:
            return .green
        case .divergence:
            return .orange
        case .uniqueLead:
            return .purple
        }
    }
}
