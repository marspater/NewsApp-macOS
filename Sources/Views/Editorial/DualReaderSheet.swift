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

/// "Compare Perspectives" (W3 #717): two publishers' reports of an event, chosen from the publishers that reported it,
/// compared on this Mac and shown by `DualReaderView`. The sheet opens wide enough for two columns and falls back to
/// the stacked layout when the window cannot hold them.
struct DualReaderSheet: View {
    let reports: [PerspectiveReport]
    let eventID: String
    @Environment(\.dismiss) private var dismiss
    @State private var leftID: String
    @State private var rightID: String
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case ready(DualReaderSession, left: [String], right: [String])
        case unavailable
    }

    /// `reports` holds one report per publisher, richest first (`PerspectiveReports.candidates`); the two fullest
    /// accounts open first.
    init(reports: [PerspectiveReport], eventID: String) {
        self.reports = reports
        self.eventID = eventID
        _leftID = State(initialValue: reports.first?.id ?? "")
        _rightID = State(initialValue: reports.dropFirst().first?.id ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(
            minWidth: AppLayout.dualReaderSheetMinimumWidth, idealWidth: AppLayout.dualReaderSheetWidth,
            maxWidth: .infinity, minHeight: AppLayout.dualReaderSheetMinimumHeight,
            idealHeight: AppLayout.dualReaderSheetHeight, maxHeight: .infinity
        )
        .onExitCommand { dismiss() }
        .task(id: [leftID, rightID]) { await compare() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                Text("Compare Perspectives")
                    .font(AppTypography.title)
                    .accessibilityAddTraits(.isHeader)
                Text("Two publishers' reports of this story")
                    .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            }
            Spacer(minLength: AppSpacing.md)
            publisherPicker("Left report", selection: $leftID, excluding: rightID)
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(AppColor.secondaryText).accessibilityHidden(true)
            publisherPicker("Right report", selection: $rightID, excluding: leftID)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(AppLayout.pageInset)
    }

    /// The publishers to pick from, without the one the other side shows, so the two sides never repeat.
    private func publisherPicker(_ label: String, selection: Binding<String>, excluding other: String) -> some View {
        Picker(label, selection: selection) {
            ForEach(reports.filter { $0.id != other }) { report in
                Text(report.publisher).tag(report.id)
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Comparing reports…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView(
                "Nothing to Compare", systemImage: "arrow.left.arrow.right",
                description: Text("These two reports share too little text to compare."))
        case .ready(let session, let left, let right):
            DualReaderView(session: session, leftPassages: left, rightPassages: right)
        }
    }

    /// Reads both reports and aligns their passages. A choice that changes while this runs cancels it, and a cancelled
    /// comparison shows nothing.
    private func compare() async {
        guard let left = reports.first(where: { $0.id == leftID }),
            let right = reports.first(where: { $0.id == rightID })
        else {
            phase = .unavailable
            return
        }
        phase = .loading
        let service = DualReaderAlignmentService()
        let leftPassages = await service.boundedPassages(title: left.title, content: left.text)
        let rightPassages = await service.boundedPassages(title: right.title, content: right.text)
        let session = await service.align(
            left: .init(id: left.id, title: left.title, content: left.text, publisher: left.publisher),
            right: .init(id: right.id, title: right.title, content: right.text, publisher: right.publisher),
            clusterId: eventID)
        guard !Task.isCancelled else { return }
        phase =
            session.passageAlignments.isEmpty
            ? .unavailable : .ready(session, left: leftPassages, right: rightPassages)
    }
}
