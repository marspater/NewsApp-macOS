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

/// Library › Notes & Highlights: every highlight and note, newest first, searchable (V1 #711).
struct NotesHighlightsView: View {
    /// The sidebar's Library entry that shows this view.
    static let topic = "Notes & Highlights"

    var onOpen: (String) -> Void

    @EnvironmentObject private var articleStore: ArticleStore
    @State private var listings: [UserNoteListing] = []
    @State private var query = ""
    @State private var selectedID: String?
    @State private var loaded = false
    @State private var deleting: UserNote?

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search notes and highlights", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(AppSpacing.md)
            Divider()
            if !loaded {
                // The first lookup is still running: no empty state yet.
                Color.clear
            } else if listings.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "No Notes & Highlights" : "No Matches", systemImage: "highlighter")
                } description: {
                    Text(
                        query.isEmpty
                            ? "Highlights and private notes you make while reading will appear here."
                            : "Try different words.")
                }
            } else {
                // Arrow keys move through the rows, Return opens the selected story.
                let groups = listings.groupedByStory()
                List(selection: $selectedID) {
                    ForEach(groups) { group in
                        if group.isMultiple {
                            Section {
                                ForEach(group.listings) { listing in
                                    row(listing, inGroup: true)
                                }
                            } header: {
                                storyGroupHeader(group)
                            }
                        } else if let singleListing = group.listings.first {
                            row(singleListing).tag(singleListing.id)
                        }
                    }
                }
                .listStyle(.plain)
                .onKeyPress(.return) {
                    guard let listing = listings.first(where: { $0.id == selectedID }) else { return .ignored }
                    onOpen(listing.note.articleID)
                    return .handled
                }
            }
        }
        // Fill the cover: a shorter empty state would let the list under it show through.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColor.background)
        .task(id: "\(query)\u{0}\(articleStore.userNotesRevision)") {
            let found = await articleStore.noteListings(matching: query)
            guard !Task.isCancelled else { return }
            listings = found
            loaded = true
        }
        .confirmationDialog(
            "Delete this note?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { note in
            Button("Delete", role: .destructive) { Task { await articleStore.deleteNote(id: note.id) } }
        } message: { note in
            Text("“\(note.noteBody.prefix(80))” is deleted with its highlight.")
        }
    }

    /// Story group header for stories with multiple highlights and notes (#1208).
    private func storyGroupHeader(_ group: StoryAnnotationGroup) -> some View {
        let storyTitle = group.articleTitle
        let noteCount = group.listings.count
        return Button {
            onOpen(group.articleID)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                    Text(storyTitle)
                        .font(AppTypography.headline)
                        .foregroundStyle(AppColor.primaryText)
                        .multilineTextAlignment(.leading)
                    Text("\(group.source) · \(noteCount) passages in reading order")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.tertiaryText)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, AppSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(storyTitle), \(group.source), \(noteCount) passages in reading order")
        .accessibilityHint("Opens the story")
    }

    /// One note row: optionally displayed inside a story group without repeating the story title (#1208).
    private func row(_ listing: UserNoteListing, inGroup: Bool = false) -> some View {
        let note = listing.note
        let content = HStack(alignment: .top, spacing: AppSpacing.sm) {
            Button {
                onOpen(note.articleID)
            } label: {
                noteText(listing, inGroup: inGroup)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the story")
            Button(role: .destructive) {
                if note.hasBody { deleting = note } else { Task { await articleStore.deleteNote(id: note.id) } }
            } label: {
                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Delete this highlight")
            .accessibilityLabel("Delete highlight “\(note.selectedText.prefix(40))”")
        }
        return Group {
            if inGroup {
                content
                    .padding(AppSpacing.sm)
                    .background(
                        AppColor.cardBackground,
                        in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    )
                    .padding(.vertical, AppSpacing.xxs)
            } else {
                content
                    .padding(.vertical, AppSpacing.xs)
            }
        }
    }

    /// The quoted words, the note and its date, without the story title inside a group.
    private func noteText(_ listing: UserNoteListing, inGroup: Bool) -> some View {
        let note = listing.note
        return VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if !inGroup {
                Text(listing.articleTitle)
                    .font(AppTypography.headline)
                    .foregroundStyle(AppColor.primaryText)
                    .multilineTextAlignment(.leading)
            }
            Text("“\(note.selectedText)”")
                .font(AppTypography.callout)
                .foregroundStyle(AppColor.primaryText)
                .multilineTextAlignment(.leading)
                .padding(.leading, AppSpacing.xs)
                .background(alignment: .leading) {
                    Rectangle().fill(AppColor.noteHighlight).frame(width: AppLayout.quoteBarWidth)
                }
            if note.hasBody {
                Text(note.noteBody)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColor.primaryText)
                    .multilineTextAlignment(.leading)
            }
            Text(
                inGroup
                    ? note.createdAt.formatted(date: .abbreviated, time: .shortened)
                    : "\(listing.source) · \(note.createdAt.formatted(date: .abbreviated, time: .shortened))"
            )
            .font(AppTypography.caption)
            .foregroundStyle(AppColor.secondaryText)
        }
    }
}
