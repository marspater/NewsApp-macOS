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

/// Trailing inspector with the highlights and notes of the story in the reader (V1 #711).
struct AnnotationsInspectorView: View {
    let notes: [UserNote]
    /// Notes whose quoted words are no longer in the story's text.
    let lostIDs: Set<String>
    var onReveal: (UserNote) -> Void
    var onSave: (UserNote) -> Void
    var onDelete: (String) -> Void

    @State private var editingID: String?
    @State private var draft = ""
    @State private var selectedID: String?

    var body: some View {
        Group {
            if notes.isEmpty {
                ContentUnavailableView {
                    Label("No Highlights", systemImage: "highlighter")
                } description: {
                    Text("Select text in the story, then press ⌘Y to highlight it or ⇧⌘Y to add a note.")
                }
            } else {
                // Arrow keys move through the rows, Return shows the selected passage in the story.
                List(notes, selection: $selectedID) { note in
                    row(note)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onKeyPress(.return) {
                    guard let note = notes.first(where: { $0.id == selectedID }), !lostIDs.contains(note.id) else {
                        return .ignored
                    }
                    onReveal(note)
                    return .handled
                }
            }
        }
        .navigationTitle("Annotations")
    }

    private func row(_ note: UserNote) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Button {
                onReveal(note)
            } label: {
                HStack(alignment: .top, spacing: AppSpacing.xs) {
                    Rectangle()
                        .fill(AppColor.noteHighlight)
                        .frame(width: AppLayout.quoteBarWidth)
                    Text("“\(note.selectedText)”")
                        .font(AppTypography.callout)
                        .foregroundStyle(AppColor.primaryText)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            .disabled(lostIDs.contains(note.id))
            .accessibilityHint("Scrolls the story to this passage")

            if lostIDs.contains(note.id) {
                Text("This passage is no longer in the publisher's text.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }

            if editingID == note.id {
                TextField("Private note", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                HStack {
                    Button("Cancel") { editingID = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        var edited = note
                        edited.noteBody = draft
                        edited.updatedAt = Date()
                        onSave(edited)
                        editingID = nil
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .controlSize(.small)
            } else {
                if note.hasBody {
                    Text(note.noteBody)
                        .font(AppTypography.body)
                        .foregroundStyle(AppColor.primaryText)
                }
                HStack {
                    Button(note.hasBody ? "Edit Note" : "Add Note") {
                        draft = note.noteBody
                        editingID = note.id
                    }
                    Spacer()
                    Button(role: .destructive) {
                        onDelete(note.id)
                    } label: {
                        Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .help("Delete this highlight")
                    .accessibilityLabel("Delete highlight “\(note.selectedText.prefix(40))”")
                }
                .buttonStyle(.borderless)
                .font(AppTypography.caption)
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .contain)
    }
}
