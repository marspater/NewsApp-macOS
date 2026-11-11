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

/// A highlight or private note on a passage of one story (V1 #711), kept as a quote with its surroundings (the
/// W3C text-quote selector): the paragraph index and offsets are only a hint, so the note survives a re-extraction that
/// moves or rewrites paragraphs around the quoted words.
struct UserNote: Identifiable, Sendable, Equatable {
    var id = UUID().uuidString
    let articleID: String
    /// Where the quote sat when it was made: the block index in the reader and the character offset in that block.
    var paragraphIndex: Int
    var charStart: Int
    let selectedText: String
    /// Up to `NoteAnchor.contextLength` characters on each side of the quote in its block.
    let prefix: String
    let suffix: String
    var noteBody = ""
    var createdAt = Date()
    var updatedAt = Date()

    /// A highlight with no note text is just a highlight.
    var hasBody: Bool { !noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A note in the Library list, with the story it belongs to.
struct UserNoteListing: Identifiable, Sendable, Equatable {
    let note: UserNote
    let articleTitle: String
    let source: String
    var id: String { note.id }
}

/// Where one line of the reader's selection sits in the story.
struct NotePlace {
    let index: Int
    let start: Int
    let quote: String
}

/// Places notes in the blocks of a story. Offsets count `Character`s, the unit `AttributedString` indexes by.
enum NoteAnchor {
    static let contextLength = 32

    /// The note for `quote` found in `paragraphs[index]` at character offset `start`.
    static func note(
        articleID: String, paragraphs: [String], index: Int, start: Int, quote: String, body: String = ""
    ) -> UserNote {
        let characters = Array(paragraphs[index])
        let end = start + quote.count
        return UserNote(
            articleID: articleID, paragraphIndex: index, charStart: start, selectedText: quote,
            prefix: String(characters[max(0, start - contextLength)..<start]),
            suffix: String(characters[end..<min(characters.count, end + contextLength)]), noteBody: body)
    }

    /// Every place `quote` occurs, in reading order.
    static func occurrences(of quote: String, in paragraphs: [String]) -> [(index: Int, start: Int)] {
        guard !quote.isEmpty else { return [] }
        return paragraphs.enumerated().flatMap { index, text in
            text.ranges(of: quote).map { (index, text.distance(from: text.startIndex, to: $0.lowerBound)) }
        }
    }

    /// Where the selection from the reader sits. A selection across blocks arrives as lines; each line is placed in
    /// the first block at or after the previous line's. nil when a line is not in the story's text. `taken` are the
    /// ranges that are highlighted already: a quote that occurs more than once is placed at its first occurrence that
    /// is not.
    static func place(
        selection: String, in paragraphs: [String], taken: [(index: Int, range: Range<Int>)] = []
    ) -> [NotePlace]? {
        var placed: [NotePlace] = []
        var floor = 0
        for line in selection.split(whereSeparator: \.isNewline) {
            let quote = line.trimmingCharacters(in: .whitespaces)
            guard !quote.isEmpty else { continue }
            // ponytail: SwiftUI does not show where in the story a selection is, so a quote that occurs twice cannot be
            // told apart: it goes to the first occurrence not highlighted yet, and repeating the command covers the
            // next. An NSTextView per block would know the range but costs the reader's styling and accessibility.
            let spots = occurrences(of: quote, in: paragraphs).filter { $0.index >= floor }
            guard
                let spot = spots.first(where: { spot in
                    !taken.contains { $0.index == spot.index && $0.range == spot.start..<spot.start + quote.count }
                }) ?? spots.first
            else { return nil }
            placed.append(NotePlace(index: spot.index, start: spot.start, quote: quote))
            floor = spot.index
        }
        return placed.isEmpty ? nil : placed
    }

    /// The quote's character range in the story now, with its block index: at the stored position while the text and
    /// its surroundings still match there, else at the occurrence whose surroundings agree best with the stored
    /// context (ties go to the nearest block, then the earliest). A look-alike that moved into the stored position
    /// does not keep it. nil once the quoted words are gone.
    static func resolve(_ note: UserNote, in paragraphs: [String]) -> (index: Int, range: Range<Int>)? {
        let length = note.selectedText.count
        if paragraphs.indices.contains(note.paragraphIndex) {
            let characters = Array(paragraphs[note.paragraphIndex])
            let stored = (index: note.paragraphIndex, start: note.charStart)
            if note.charStart >= 0, note.charStart + length <= characters.count,
                String(characters[note.charStart..<note.charStart + length]) == note.selectedText,
                score(stored, note, paragraphs) == note.prefix.count + note.suffix.count
            {
                return (note.paragraphIndex, note.charStart..<note.charStart + length)
            }
        }
        let best = occurrences(of: note.selectedText, in: paragraphs).min { lhs, rhs in
            let (l, r) = (score(lhs, note, paragraphs), score(rhs, note, paragraphs))
            if l != r { return l > r }
            let (ld, rd) = (abs(lhs.index - note.paragraphIndex), abs(rhs.index - note.paragraphIndex))
            return ld != rd ? ld < rd : (lhs.index, lhs.start) < (rhs.index, rhs.start)
        }
        return best.map { ($0.index, $0.start..<$0.start + length) }
    }

    /// How many context characters around the occurrence equal the stored prefix and suffix.
    private static func score(_ spot: (index: Int, start: Int), _ note: UserNote, _ paragraphs: [String]) -> Int {
        let characters = Array(paragraphs[spot.index])
        let end = spot.start + note.selectedText.count
        let before = characters[max(0, spot.start - contextLength)..<spot.start]
        let after = characters[end..<min(characters.count, end + contextLength)]
        return zip(before.reversed(), note.prefix.reversed()).prefix { $0 == $1 }.count
            + zip(after, note.suffix).prefix { $0 == $1 }.count
    }
}

extension UserNote {
    /// Returns true if this note appears earlier in reading order than `other`.
    func isOrderedBeforeInReadingOrder(_ other: UserNote) -> Bool {
        if paragraphIndex != other.paragraphIndex {
            return paragraphIndex < other.paragraphIndex
        }
        if charStart != other.charStart {
            return charStart < other.charStart
        }
        return createdAt < other.createdAt
    }
}

extension Collection where Element == UserNote {
    /// Notes sorted in story reading order: by paragraph index, then character start, then creation date.
    func sortedInReadingOrder() -> [UserNote] {
        sorted { $0.isOrderedBeforeInReadingOrder($1) }
    }
}

extension Collection where Element == UserNoteListing {
    /// Listings sorted in story reading order.
    func sortedInReadingOrder() -> [UserNoteListing] {
        sorted { $0.note.isOrderedBeforeInReadingOrder($1.note) }
    }
}

/// A group of notes belonging to one story (Issue #1208).
struct StoryAnnotationGroup: Identifiable, Sendable {
    let articleID: String
    let articleTitle: String
    let source: String
    let listings: [UserNoteListing]
    var id: String { articleID }

    var isMultiple: Bool { listings.count > 1 }

    init(articleID: String, articleTitle: String, source: String, listings: [UserNoteListing]) {
        self.articleID = articleID
        self.articleTitle = articleTitle
        self.source = source
        self.listings = listings
    }
}

extension Collection where Element == UserNoteListing {
    /// Groups listings by story (articleID), preserving order of appearance, with notes inside each story in reading order.
    func groupedByStory() -> [StoryAnnotationGroup] {
        var order: [String] = []
        var dict: [String: [UserNoteListing]] = [:]
        for listing in self {
            let id = listing.note.articleID
            if dict[id] == nil {
                order.append(id)
            }
            dict[id, default: []].append(listing)
        }
        return order.compactMap { id in
            guard let list = dict[id], let first = list.first else { return nil }
            return StoryAnnotationGroup(
                articleID: id,
                articleTitle: first.articleTitle,
                source: first.source,
                listings: list.sortedInReadingOrder()
            )
        }
    }
}
