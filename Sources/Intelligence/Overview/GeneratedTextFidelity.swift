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

// MARK: - Generated Text Fidelity (#951)

/// Deterministic comparison of generated text with the text it restates, sentence by sentence; no model is asked.
/// The reader summary and the Briefing sitrep run every rule; the overview verifier runs the qualifier, contested
/// figure and name rules per cited passage beside its own. A rewrite that flips a negation, states an allegation or a
/// condition as fact, changes a figure or a name, moves a statement to another speaker, upgrades an action or drops the
/// speaker of a contested figure fails.
enum GeneratedTextFidelity {
    enum Violation: String, Sendable, Equatable {
        case figure, name, negation, qualifier, speaker, action, attribution
    }

    /// The rules each generated sentence broke against `source`, in order of first occurrence. `knownNames` (such as
    /// publishers named beside the source) may be named and quoted as speakers.
    static func violations(in generated: [String], source: String, knownNames: [String] = []) -> [Violation] {
        let sourceSentences = sentences(source)
        let known = Set(knownNames.flatMap { MuteRules.foldedWords($0) })
        var found: [Violation] = []
        for sentence in generated.flatMap(sentences) {
            let broken = fidelityViolations(
                sentence, source: source, sourceSentences: sourceSentences, knownNames: known)
            for violation in broken where !found.contains(violation) { found.append(violation) }
        }
        return found
    }

    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func fidelityViolations(
        _ sentence: String, source: String, sourceSentences: [String], knownNames: Set<String>
    ) -> [Violation] {
        var found: [Violation] = []
        if unsupportedFigure(statement: sentence, source: source) != nil { found.append(.figure) }
        if unsupportedName(statement: sentence, source: source, knownNames: knownNames) != nil { found.append(.name) }
        if OverviewClaimVerifier.flipsNegation(statement: sentence, passageText: source) { found.append(.negation) }
        if dropsQualifier(statement: sentence, passageText: source) { found.append(.qualifier) }
        if misattributesSpeaker(statement: sentence, sourceSentences: sourceSentences, knownNames: knownNames) {
            found.append(.speaker)
        }
        if OverviewClaimVerifier.unsupportedAction(statement: sentence, passageText: source) != nil {
            found.append(.action)
        }
        if dropsContestedFigureSpeaker(statement: sentence, sourceSentences: sourceSentences)
            || OverviewClaimVerifier.droppedAttributionSpeaker(statement: sentence, passageText: source) != nil
        {
            found.append(.attribution)
        }
        return found
    }

    private static let numberWordPattern = try? NSRegularExpression(
        pattern: #"\b(one|two|three|four|five|six|seven|eight|nine|ten|"#
            + #"eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\b"#,
        options: [.caseInsensitive])

    private static let numberWordValues = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
    ]

    /// Numbers written as words up to twenty, as digits: "Three people" states the 3 of "3 people". `keepingOne`
    /// leaves "one" as written, for text where it is mostly a pronoun ("each one", "no one").
    static func digitized(_ text: String, keepingOne: Bool = false) -> String {
        guard let numberWordPattern else { return text }
        let nsText = text as NSString
        var result = text
        let matches = numberWordPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            let word = nsText.substring(with: match.range).lowercased()
            if keepingOne, word == "one" { continue }
            guard let digits = numberWordValues[word], let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: digits)
        }
        return result
    }

    /// A number or year the source never states, in digits or (up to twenty) in words. A number word of the statement
    /// counts too ("Three" for the source's "two"), except "one", which a rewrite mostly uses as a pronoun.
    static func unsupportedFigure(statement: String, source: String) -> String? {
        let normalizedSource = OverviewClaimVerifier.normalizeText(digitized(source))
        let statement = digitized(statement, keepingOne: true)
        return
            (OverviewClaimVerifier.extractNumbers(from: statement)
            + OverviewClaimVerifier.extractDates(from: statement)).first {
                !OverviewClaimVerifier.containsNumber(OverviewClaimVerifier.normalizeText($0), in: normalizedSource)
            }
    }

    /// Titles before a name; "Mr Smith" names Smith.
    private static let honorifics: Set<String> = ["mr", "mrs", "ms", "dr", "sir", "dame", "prof"]

    /// Initials of runs of capitalized source words, so "UK" stands for "United Kingdom" and "USA" for "United
    /// States of America" (lowercase "of", "and", "the" inside a run are skipped).
    private static func acronyms(in text: String) -> Set<String> {
        var found = Set<String>()
        var run = ""
        func close() {
            let letters = Array(run)
            for start in letters.indices where start + 2 <= letters.count {
                for end in (start + 2)...min(letters.count, start + 5) {
                    found.insert(String(letters[start..<end]))
                }
            }
            run = ""
        }
        for word in OverviewClaimVerifier.words(text) {
            if let initial = word.first, initial.isUppercase {
                run.append(Character(initial.lowercased()))
            } else if !["of", "and", "the"].contains(word) {
                close()
            }
        }
        close()
        return found
    }

    /// A capitalized word after the sentence start that the source never uses: an invented or changed name. A word
    /// sharing a stem of four or more letters with a source word passes ("Ukrainian" for "Ukraine"), periods are
    /// ignored ("US" for "U.S."), an all-capital word may be the initials of a source name ("UK"), and titles
    /// ("Mr") are no names.
    static func unsupportedName(statement: String, source: String, knownNames: Set<String> = []) -> String? {
        let sourceWords = Set(OverviewClaimVerifier.tokenize(source))
            .union(OverviewClaimVerifier.tokenize(source.replacingOccurrences(of: ".", with: "")))
            .union(knownNames)
        let initials = acronyms(in: source)
        for (index, word) in OverviewClaimVerifier.words(statement.replacingOccurrences(of: ".", with: "")).enumerated()
        where index > 0 && word.count > 1 && word.first?.isUppercase == true {
            guard let lower = OverviewClaimVerifier.tokenize(word).first,
                !OverviewClaimVerifier.capitalizedFunctionWords.contains(lower),
                !honorifics.contains(lower), !sourceWords.contains(lower)
            else { continue }
            if word.allSatisfy(\.isUppercase), initials.contains(lower) { continue }
            if sourceWords.contains(where: { lower.commonPrefix(with: $0).count >= 4 }) {
                continue
            }
            return word
        }
        return nil
    }

    /// Hedges a restatement must keep, by kind: a claim or report, a possibility, a condition, an intention. A rewrite
    /// keeps the kind ("could" does not stand for "alleged"). "Would" is left out: in reporting it is mostly
    /// backshifted speech ("said he would resign"), and conditionals already carry "if" or "could".
    private static let hedgeKindOfWord: [String: String] = [
        "alleged": "claim", "allegedly": "claim", "allege": "claim", "alleges": "claim", "reportedly": "claim",
        "suspected": "claim", "accused": "claim", "unconfirmed": "claim", "claimed": "claim", "claims": "claim",
        "apparently": "claim",
        "may": "possibility", "might": "possibility", "could": "possibility", "possible": "possibility",
        "possibly": "possibility", "likely": "possibility", "expected": "possibility",
        "if": "condition", "unless": "condition",
        "plans": "intention", "planned": "intention", "proposed": "intention", "considering": "intention",
        "threatened": "intention", "threatens": "intention",
    ]
    /// Hedges only as verbs: "insurance claims", "housing plans", "threatened species".
    private static let verbOnlyHedges: Set<String> = [
        "claims", "claimed", "plans", "planned", "accused", "expected", "threatened", "threatens", "considering",
    ]

    /// The hedge kinds `text` expresses. A word that is a hedge only as a verb counts only where the tagger reads it
    /// as one; "than expected" and "the accused" never count.
    static func hedgeKinds(_ text: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var kinds = Set<String>()
        var previous = ""
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let lower = text[range].lowercased()
            defer { previous = lower }
            guard let kind = hedgeKindOfWord[lower] else { return true }
            // A capitalized "May" is the month, also at a sentence start ("May saw record sales").
            if lower == "may", text[range].first?.isUppercase == true { return true }
            if verbOnlyHedges.contains(lower), tag != .verb { return true }
            if (lower == "expected" && previous == "than") || (lower == "accused" && ["the", "an"].contains(previous)) {
                return true
            }
            kinds.insert(kind)
            return true
        }
        return kinds
    }

    /// The clause of the closest passage sentence that the claim restates: a hedge in another clause ("The bridge
    /// reopened, and engineers said repairs could take weeks") says nothing about this claim.
    private static func closestClause(to statement: String, in passageText: String) -> String {
        let sentence = OverviewClaimVerifier.closestSentence(to: statement, in: passageText)
        let claim = Set(OverviewClaimVerifier.tokenize(statement))
        let clauses = sentence.components(separatedBy: CharacterSet(charactersIn: ",;:"))
            .flatMap { $0.components(separatedBy: " and ") }
            .flatMap { $0.components(separatedBy: " but ") }
            .flatMap { $0.components(separatedBy: " while ") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return clauses.max {
            claim.intersection(OverviewClaimVerifier.tokenize($0)).count
                < claim.intersection(OverviewClaimVerifier.tokenize($1)).count
        } ?? sentence
    }

    /// The clause the claim restates hedges and the claim drops that kind of hedge: an allegation stated as fact, a
    /// condition made definite.
    static func dropsQualifier(statement: String, passageText: String) -> Bool {
        let source = hedgeKinds(closestClause(to: statement, in: passageText))
        return !source.isEmpty && !source.isSubset(of: hedgeKinds(statement))
    }

    /// The claim names a speaker the source does not give for what it says: the speakers of the sentences carrying
    /// its figures, else of its closest sentence, else of any sentence. Known names (publishers) may always speak.
    static func misattributesSpeaker(statement: String, sourceSentences: [String], knownNames: Set<String>) -> Bool {
        let statementWords = OverviewClaimVerifier.words(statement)
        let claim = OverviewClaimVerifier.reportedSpeakers(statementWords).subtracting(knownNames)
        guard !claim.isEmpty else { return false }
        let numbers = OverviewClaimVerifier.extractNumbers(from: statement).map(OverviewClaimVerifier.normalizeText)
        var reference = Set<String>()
        for sentence in sourceSentences
        where numbers.contains(where: {
            OverviewClaimVerifier.containsNumber($0, in: OverviewClaimVerifier.normalizeText(sentence))
        }) {
            reference.formUnion(OverviewClaimVerifier.reportedSpeakers(OverviewClaimVerifier.words(sentence)))
        }
        if reference.isEmpty {
            let joinedSources = sourceSentences.joined(separator: " ")
            let closest = OverviewClaimVerifier.closestSentence(to: statement, in: joinedSources)
            reference = OverviewClaimVerifier.reportedSpeakers(OverviewClaimVerifier.words(closest))
        }
        if reference.isEmpty {
            reference = sourceSentences.reduce(into: Set<String>()) {
                $0.formUnion(OverviewClaimVerifier.reportedSpeakers(OverviewClaimVerifier.words($1)))
            }
        }
        // A source that names no speaker leaves invented ones to the name rule.
        return !reference.isEmpty && claim.isDisjoint(with: reference)
    }

    /// The word a figure counts: "people" in "20,000 people".
    private static func countedNoun(after number: String, in text: String) -> String? {
        let pattern = #"(?<![\d.,])"# + NSRegularExpression.escapedPattern(for: number) + #"\s+(\p{L}+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return OverviewClaimVerifier.tokenize(String(text[range])).first
    }

    /// Police say 3,000 marched, organisers 20,000: a claim giving one of those figures for the same thing must say
    /// whose it is. The same thing means the same counted noun ("people"), not any shared word.
    static func dropsContestedFigureSpeaker(statement: String, sourceSentences: [String]) -> Bool {
        let numbers = OverviewClaimVerifier.extractNumbers(from: statement)
        let statementSpeakers = OverviewClaimVerifier.reportedSpeakers(OverviewClaimVerifier.words(statement))
        guard !numbers.isEmpty, statementSpeakers.isEmpty else {
            return false
        }
        let attributed = sourceSentences.compactMap { sentence -> (text: String, speakers: Set<String>)? in
            let speakers = OverviewClaimVerifier.reportedSpeakers(OverviewClaimVerifier.words(sentence))
            return speakers.isEmpty ? nil : (sentence, speakers)
        }
        for number in numbers {
            guard let noun = countedNoun(after: number, in: statement) else { continue }
            let carrying = attributed.filter {
                OverviewClaimVerifier.containsNumber(
                    OverviewClaimVerifier.normalizeText(number), in: OverviewClaimVerifier.normalizeText($0.text))
            }
            guard !carrying.isEmpty else { continue }
            let speakers = carrying.reduce(into: Set<String>()) { $0.formUnion($1.speakers) }
            let rival = attributed.contains { other in
                !OverviewClaimVerifier.containsNumber(
                    OverviewClaimVerifier.normalizeText(number), in: OverviewClaimVerifier.normalizeText(other.text))
                    && other.speakers.isDisjoint(with: speakers)
                    && OverviewClaimVerifier.extractNumbers(from: other.text).contains {
                        countedNoun(after: $0, in: other.text) == noun
                    }
            }
            if rival { return true }
        }
        return false
    }
}
