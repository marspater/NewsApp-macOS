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

import AppKit
import SwiftUI

extension Notification.Name {
    static let highlightSelectionCommand = Notification.Name("highlightSelectionCommand")
    static let addNoteCommand = Notification.Name("addNoteCommand")
    static let toggleAnnotationsCommand = Notification.Name("toggleAnnotationsCommand")
}

/// Edit › Highlight Selection and Add Note to Selection, View › Show Annotations (V1 #711). The reader acts on them
/// while it shows a story; ⌘Y belongs to Quick Look in the list.
struct AnnotationCommands: Commands {
    @FocusedValue(\.readerActions) private var readerActions

    private var isReading: Bool { readerActions?.mode.wrappedValue == .story }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Highlight Selection") {
                NotificationCenter.default.post(name: .highlightSelectionCommand, object: nil)
            }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(!isReading)
            Button("Add Note to Selection…") { NotificationCenter.default.post(name: .addNoteCommand, object: nil) }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(!isReading)
        }
        CommandGroup(after: .sidebar) {
            Button("Show or Hide Annotations") {
                NotificationCenter.default.post(name: .toggleAnnotationsCommand, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!isReading)
        }
    }
}

/// Routes the three annotation commands to the reader that shows a story.
struct ReaderAnnotationCommands: ViewModifier {
    let onHighlight: () -> Void
    let onAddNote: () -> Void
    let onToggleInspector: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .highlightSelectionCommand)) { _ in onHighlight() }
            .onReceive(NotificationCenter.default.publisher(for: .addNoteCommand)) { _ in onAddNote() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAnnotationsCommand)) { _ in onToggleInspector()
            }
    }
}

/// The text the reader has selected. SwiftUI shows no selection range, so it is read the way Edit › Copy reads it, and
/// the clipboard is put back as it was.
enum ReaderSelection {
    // ponytail: a clipboard manager may log the instant copy; an NSTextView per block would avoid it but costs the
    // reader's text styling and accessibility.
    @MainActor
    static func current() -> String? {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let changes = board.changeCount
        guard NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil), board.changeCount != changes else {
            return nil
        }
        let text = board.string(forType: .string)
        board.clearContents()
        board.writeObjects(
            saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            })
        return text
    }
}

/// Notes made from the reader's selection, waiting for the text of the note.
struct NoteDraft: Identifiable {
    let id = UUID()
    let notes: [UserNote]
    var quote: String { notes.map(\.selectedText).joined(separator: " … ") }
}

/// What the reader paints over its blocks: the reader's highlights.
struct ReaderOverlay {
    private(set) var highlights: [Int: [Range<Int>]] = [:]

    /// Paints each note's quote where it sits in `paragraphs` now; a quote the story no longer holds is not painted.
    init(notes: [UserNote] = [], paragraphs: [String] = []) {
        for note in notes {
            if let spot = NoteAnchor.resolve(note, in: paragraphs) {
                highlights[spot.index, default: []].append(spot.range)
            }
        }
    }

    func styled(_ text: AttributedString, at index: Int) -> AttributedString {
        var text = text
        for range in highlights[index] ?? [] {
            text.paint(range, AppColor.noteHighlight, mark: AppColor.noteHighlightMark)
        }
        return text
    }
}

extension AttributedString {
    /// Colours the background of a character range, with a line under it when `mark` is set; a range the text no
    /// longer has is ignored.
    mutating func paint(_ range: Range<Int>, _ color: Color, mark: Text.LineStyle? = nil) {
        let characters = self.characters
        guard range.lowerBound >= 0, range.upperBound <= characters.count else { return }
        let start = characters.index(characters.startIndex, offsetBy: range.lowerBound)
        let end = characters.index(start, offsetBy: range.count)
        self[start..<end].backgroundColor = color
        if let mark { self[start..<end].underlineStyle = mark }
    }
}

/// The popover that takes the text of a note on the passages the reader selected.
struct NoteComposerView: View {
    let quote: String
    var onSave: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("“\(quote)”")
                .font(AppTypography.callout)
                .foregroundStyle(AppColor.secondaryText)
                .lineLimit(3)
            TextField("Private note", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
                .focused($focused)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppSpacing.md)
        .frame(width: AppLayout.popoverWidth)
        .onAppear { focused = true }
    }
}
