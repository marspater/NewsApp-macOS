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
import NaturalLanguage

/// What changed between two texts of one story, sentence by sentence (V2 #712).
enum SentenceDiff {
    enum Kind: Equatable, Sendable { case unchanged, added, retracted }

    struct Item: Equatable, Sendable {
        let text: String
        let kind: Kind
    }

    /// How the reader's blocks show the changes: ranges to tint, and the sentences that are gone, each listed under
    /// the block it followed (-1: before the first block). Block text is never altered, so nothing reflows except
    /// where a retracted sentence is inserted.
    struct Overlay: Equatable, Sendable {
        var added: [Int: [Range<Int>]] = [:]
        var retracted: [Int: [String]] = [:]
        var isEmpty: Bool { added.isEmpty && retracted.isEmpty }
    }

    /// Past this many sentence pairs the exact diff costs too much: only the shared head and tail are kept.
    static let maximumCells = 4_000_000

    /// Sentences with their character ranges, trimmed of whitespace.
    static func sentences(in text: String) -> [(text: String, range: Range<Int>)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var found: [(String, Range<Int>)] = []
        var cursor = text.startIndex
        var offset = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Tokens come in reading order, so offsets advance from the previous token instead of the start.
            offset += text.distance(from: cursor, to: range.lowerBound)
            cursor = range.lowerBound
            let raw = text[range]
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let lead = raw.prefix { $0.isWhitespace || $0.isNewline }.count
                found.append((trimmed, (offset + lead)..<(offset + lead + trimmed.count)))
            }
            return true
        }
        return found
    }

    /// Sentences equal up to whitespace compare equal; a reworded sentence is one retracted and one added.
    static func key(_ sentence: String) -> String {
        sentence.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The ordered sentences of both texts, longest common subsequence first.
    static func diff(before: String, after: String) -> [Item] {
        let old = sentences(in: before).map(\.text)
        let new = sentences(in: after).map(\.text)
        let (oldKeys, newKeys) = (old.map(key), new.map(key))
        var head = 0
        while head < min(old.count, new.count), oldKeys[head] == newKeys[head] { head += 1 }
        var tail = 0
        while tail < min(old.count, new.count) - head, oldKeys[old.count - 1 - tail] == newKeys[new.count - 1 - tail] {
            tail += 1
        }
        let (oldMid, newMid) = (head..<(old.count - tail), head..<(new.count - tail))
        var items = new[..<head].map { Item(text: $0, kind: .unchanged) }
        items += middle(old: oldMid.map { (old[$0], oldKeys[$0]) }, new: newMid.map { (new[$0], newKeys[$0]) })
        items += new[(new.count - tail)...].map { Item(text: $0, kind: .unchanged) }
        return items
    }

    private static func middle(old: [(String, String)], new: [(String, String)]) -> [Item] {
        if old.isEmpty || new.isEmpty || old.count * new.count > maximumCells {
            return old.map { Item(text: $0.0, kind: .retracted) } + new.map { Item(text: $0.0, kind: .added) }
        }
        var lengths = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in old.indices {
            // A reader who left the story no longer needs the answer.
            if Task.isCancelled { return [] }
            for j in new.indices {
                lengths[i + 1][j + 1] =
                    old[i].1 == new[j].1 ? lengths[i][j] + 1 : max(lengths[i][j + 1], lengths[i + 1][j])
            }
        }
        var items: [Item] = []
        var (i, j) = (old.count, new.count)
        while i > 0 || j > 0 {
            if i > 0, j > 0, old[i - 1].1 == new[j - 1].1 {
                items.append(Item(text: new[j - 1].0, kind: .unchanged))
                (i, j) = (i - 1, j - 1)
            } else if j > 0, i == 0 || lengths[i][j - 1] >= lengths[i - 1][j] {
                items.append(Item(text: new[j - 1].0, kind: .added))
                j -= 1
            } else {
                items.append(Item(text: old[i - 1].0, kind: .retracted))
                i -= 1
            }
        }
        return items.reversed()
    }

    /// The changes from `before` to `after` as the reader shows them over `blocks`, the texts of the rendered blocks
    /// (empty for blocks without text). The diff's sentences are matched to the blocks' sentences in reading order: an
    /// added one is tinted, and a retracted one is listed after the block holding the sentence that preceded it.
    /// Sentences the blocks do not show (boilerplate the reader removes) are skipped.
    static func overlay(before: String, after: String, blocks: [String]) -> Overlay {
        let items = diff(before: before, after: after)
        guard items.contains(where: { $0.kind != .unchanged }) else { return Overlay() }
        let shown = blocks.enumerated().flatMap { index, text in
            sentences(in: text).map { (key: key($0.text), block: index, range: $0.range) }
        }
        var overlay = Overlay()
        var cursor = 0
        var last = -1
        for item in items {
            if item.kind == .retracted {
                overlay.retracted[last, default: []].append(item.text)
                continue
            }
            let target = key(item.text)
            if let spot = shown[cursor...].firstIndex(where: { $0.key == target }) {
                if item.kind == .added { overlay.added[shown[spot].block, default: []].append(shown[spot].range) }
                last = shown[spot].block
                cursor = spot + 1
            }
        }
        return overlay
    }
}
