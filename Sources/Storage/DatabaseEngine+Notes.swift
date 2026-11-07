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
import NewsCore

/// Private highlights and notes (V1 #711).
extension DatabaseEngine {
    private static let noteColumns =
        "n.id, n.article_id, n.paragraph_index, n.char_start, n.selected_text, n.quote_prefix, n.quote_suffix, "
        + "n.note_body, n.created_at, n.updated_at"

    /// Inserts notes, or updates the text and position of the notes with the same IDs, all or none.
    func saveNotes(_ notes: [UserNote]) throws {
        try requireWritable()
        try inEventTransaction {
            for note in notes {
                try eventRows(
                    """
                    INSERT INTO user_notes (id, article_id, paragraph_index, char_start, selected_text, quote_prefix,
                        quote_suffix, note_body, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET paragraph_index = excluded.paragraph_index,
                        char_start = excluded.char_start, note_body = excluded.note_body,
                        updated_at = excluded.updated_at;
                    """,
                    [
                        .text(note.id), .text(note.articleID), .integer(note.paragraphIndex),
                        .integer(note.charStart), .text(note.selectedText), .text(note.prefix), .text(note.suffix),
                        .text(note.noteBody), .real(note.createdAt.timeIntervalSince1970),
                        .real(note.updatedAt.timeIntervalSince1970),
                    ])
            }
        }
    }

    /// Deletes one note; its index row goes with it through the trigger.
    func deleteNote(id: String) throws {
        try requireWritable()
        try eventRows("DELETE FROM user_notes WHERE id = ?;", [.text(id)])
    }

    /// One story's notes in reading order.
    func fetchNotes(for articleID: String) throws -> [UserNote] {
        try eventRows(
            """
            SELECT \(Self.noteColumns) FROM user_notes n WHERE n.article_id = ?
            ORDER BY n.paragraph_index, n.char_start, n.created_at;
            """, [.text(articleID)]
        ).compactMap { Self.userNote(from: $0) }
    }

    /// Every note of the library with its story, newest first; with a query, the notes whose quote or text match
    /// every word (the last as a prefix), best match first.
    func noteListings(matching query: String = "") throws -> [UserNoteListing] {
        // Every word is quoted so typed text cannot inject FTS5 syntax; a word without letters or digits has no token.
        let typed = query.split(whereSeparator: \.isWhitespace)
        if !typed.isEmpty, !typed.contains(where: { $0.contains { $0.isLetter || $0.isNumber } }) { return [] }
        let words = typed.filter { $0.contains { $0.isLetter || $0.isNumber } }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
        let select = "SELECT \(Self.noteColumns), a.title, a.source FROM"
        let rows =
            words.isEmpty
            ? try eventRows(
                "\(select) user_notes n JOIN articles a ON a.id = n.article_id ORDER BY n.created_at DESC;")
            : try eventRows(
                """
                \(select) user_notes_fts f JOIN user_notes n ON n.seq = f.rowid JOIN articles a ON a.id = n.article_id
                WHERE user_notes_fts MATCH ? ORDER BY f.rank;
                """, [.text(words.joined(separator: " "))])
        return rows.compactMap { row in
            guard row.count >= 12, let note = Self.userNote(from: row), let title = row[10], let source = row[11]
            else { return nil }
            return UserNoteListing(note: note, articleTitle: title, source: source)
        }
    }

    /// A note from the first ten columns of a row, nil when one is missing or malformed.
    private static func userNote(from row: [String?]) -> UserNote? {
        guard row.count >= 10, let id = row[0], let articleID = row[1], let index = row[2].flatMap(Int.init),
            let start = row[3].flatMap(Int.init), let quote = row[4], let prefix = row[5], let suffix = row[6],
            let body = row[7], let created = row[8].flatMap(Double.init), let updated = row[9].flatMap(Double.init)
        else { return nil }
        return UserNote(
            id: id, articleID: articleID, paragraphIndex: index, charStart: start, selectedText: quote, prefix: prefix,
            suffix: suffix, noteBody: body, createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated))
    }
}
