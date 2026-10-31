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

/// One sitrep sentence per thread (#849). The on-device model may restate the thread's top highlights in one sentence;
/// a sentence that is too long, carries a link or names anything the highlights do not is dropped for the first
/// highlight itself.
enum BriefingSitrepComposer {
    /// Highlights the sentence may restate.
    static let factLimit = 3
    static let maximumLength = 220

    struct Highlight: Equatable, Sendable {
        let text: String
        let publisher: String?
    }

    struct Line: Equatable, Sendable {
        let text: String
        let isGenerated: Bool
        /// True only when the model ran: its sentence was kept, or it answered and the answer was rejected. A line made
        /// while the model was off or unavailable is not cached, so a later load can generate.
        let isFinal: Bool
    }

    /// The overview's top highlights with the publisher of each one's first named citation.
    static func highlights(of overview: EventOverviewDocument) -> [Highlight] {
        overview.facts.prefix(factLimit).map { fact in
            Highlight(
                text: fact.text,
                publisher: fact.citationIDs.lazy.compactMap { overview.citations[$0]?.sourceName }.first)
        }
    }

    static func compose(title: String, highlights: [Highlight], model: NewsTextModel) async -> Line? {
        let highlights = Array(highlights.prefix(factLimit))
        guard let first = highlights.first else { return nil }
        let fallback = Line(text: first.text, isGenerated: false, isFinal: true)
        do {
            let answer = try await model.respond(prompt(title: title, highlights: highlights), 120)
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sentence = OverviewComposer.firstCompleteSentence(trimmed),
                isValid(sentence, inputs: [title] + highlights.map(\.text) + highlights.compactMap(\.publisher)),
                keepsQualifiers(sentence, facts: highlights.map(\.text))
            else { return fallback }
            return Line(text: sentence, isGenerated: true, isFinal: true)
        } catch is NewsTextModel.Rejected {
            return fallback
        } catch {
            return Line(text: first.text, isGenerated: false, isFinal: false)
        }
    }

    /// At most `maximumLength` characters, no link, every capitalized word after the first and every number appear in
    /// the inputs, so an invented name or figure fails.
    static func isValid(_ sentence: String, inputs: [String]) -> Bool {
        let lower = sentence.lowercased()
        guard !sentence.isEmpty, sentence.count <= maximumLength, !lower.contains("http"), !lower.contains("www.")
        else { return false }
        let known = Set(inputs.flatMap(words).map { $0.lowercased() })
        return words(sentence).enumerated().allSatisfy { index, word in
            guard let initial = word.first, initial.isNumber || (index > 0 && initial.isUppercase) else { return true }
            return known.contains(word.lowercased())
        }
    }

    /// Negation and uncertainty cues; a sentence restating qualified facts must keep at least one of them.
    private static let qualifiers: Set<String> = [
        "not", "no", "never", "denied", "denies", "unconfirmed", "alleged", "reportedly", "could not", "may", "might",
        "could", "expected", "possible", "likely", "cannot", "n't",
    ]

    /// False when a fact is negated or uncertain and the sentence drops every such cue. Publisher names are not
    /// required: the module's label and the thread link carry attribution, and quotes stay on their own lines.
    static func keepsQualifiers(_ sentence: String, facts: [String]) -> Bool {
        func hasQualifier(_ text: String) -> Bool {
            let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            let tokens = Set(words(lower))
            return qualifiers.contains {
                $0.contains(" ") || $0.contains("'") ? lower.contains($0) : tokens.contains($0)
            }
        }
        return !facts.contains(where: hasQualifier) || hasQualifier(sentence)
    }

    private static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func prompt(title: String, highlights: [Highlight]) -> String {
        let facts = highlights.map { "\($0.text) (\($0.publisher ?? "publisher not named"))" }
            .joined(separator: "\n")
        return """
            \(GenerationPromptDefense.untrustedDataSystemGuard)
            Write ONE plain sentence of at most 30 words that only restates the reported facts below.
            Add no background, names, numbers or judgments that the facts do not contain. Keep attribution.
            Return the sentence only, with no heading, quotation marks or markdown.
            \(GenerationPromptDefense.frameArticleData(title: title, content: facts))
            """
    }
}
