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

/// Private highlights and notes (V1 #711). Every change bumps `userNotesRevision`, which the reader and the Library
/// list watch to reload.
extension ArticleStore {
    /// One story's notes in reading order; empty, with a log line, when the library cannot be read.
    func notes(for articleID: String) async -> [UserNote] {
        do { return try await database.fetchNotes(for: articleID) } catch {
            logger.error("Failed to read notes: \(error.localizedDescription)")
            return []
        }
    }

    /// Every note with its story, newest first, or those matching the words of `query`.
    func noteListings(matching query: String = "") async -> [UserNoteListing] {
        do { return try await database.noteListings(matching: query) } catch {
            logger.error("Failed to list notes: \(error.localizedDescription)")
            return []
        }
    }

    /// Saves new notes and edits in one step; false, with a notice, when the library refused them.
    @discardableResult
    func saveNotes(_ notes: [UserNote]) async -> Bool {
        do {
            try await database.saveNotes(notes)
            userNotesRevision &+= 1
            return true
        } catch {
            logger.error("Failed to save notes: \(error.localizedDescription)")
            operationError = "Could not save your highlight or note. Please try again."
            userNotesRevision &+= 1  // reloads the readers, which drop what was not saved
            return false
        }
    }

    /// Deletes a note; false, with a notice, when the library refused.
    @discardableResult
    func deleteNote(id: String) async -> Bool {
        do {
            try await database.deleteNote(id: id)
            userNotesRevision &+= 1
            return true
        } catch {
            logger.error("Failed to delete note: \(error.localizedDescription)")
            operationError = "Could not delete your highlight or note. Please try again."
            return false
        }
    }
}
