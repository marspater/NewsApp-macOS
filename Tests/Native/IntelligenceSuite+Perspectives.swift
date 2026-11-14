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

import AppIntents
import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import NaturalLanguage
import Network
import PDFKit
import SQLite3
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd

#if canImport(FoundationModels)
    import FoundationModels
#endif

extension NativeSuites.IntelligenceSuite {
    static func testAttributedPerspectivesOfParticipantsAndPublishers(fixtureHost: String = "example.com") async throws
    {
        print("=== Testing Attributed Perspectives of Participants and Publishers (Issue #144) ===")

        let pubDate1 = Date(timeIntervalSince1970: 1_776_240_000)
        let pubDate2 = Date(timeIntervalSince1970: 1_776_243_600)
        let pubDate3 = Date(timeIntervalSince1970: 1_776_247_200)

        // Passage 1: Explicit participant statement
        let passage1 = EvidencePassage(
            id: "pass_persp_1",
            articleID: "art_persp_1",
            text:
                "\"The evacuation routes are fully operational and emergency services have responded rapidly,\" announced Mayor Elena Rostova.",
            ordinal: 1
        )
        // Passage 2: Wire reprint in second article with identical quote and wire credit
        let passage2 = EvidencePassage(
            id: "pass_persp_2",
            articleID: "art_persp_2",
            text:
                "(Reuters) - “The evacuation routes are fully operational and emergency services have responded rapidly,” announced Mayor Elena Rostova.",
            ordinal: 1
        )
        // Passage 3: Another distinct participant with explicit stance
        let passage3 = EvidencePassage(
            id: "pass_persp_3",
            articleID: "art_persp_3",
            text:
                "Dr. Sarah Jensen, Lead Volcanologist, stated that seismic sensors recorded increased tremor activity throughout the caldera.",
            ordinal: 1
        )
        // Passage 4: Purely descriptive factual text with no participant attribution
        let passageDescriptive = EvidencePassage(
            id: "pass_desc_4",
            articleID: "art_persp_1",
            text:
                "The caldera is situated 45 kilometers north of the regional capital and has an elevation of 2100 meters.",
            ordinal: 2
        )

        let article1 = FeedArticle(
            storedID: "art_persp_1",
            title: "City Prepares For Volcanic Activity",
            link: "https://\(fixtureHost)/news-1",
            guid: "guid-p1",
            description: passage1.text,
            pubDate: pubDate1,
            source: "Coastal Herald",
            fullContent: "\(passage1.text) \(passageDescriptive.text)"
        )
        let article2 = FeedArticle(
            storedID: "art_persp_2",
            title: "Evacuation Routes Open Amid Volcanic Tremors",
            link: "https://\(fixtureHost)/news-2",
            guid: "guid-p2",
            description: passage2.text,
            pubDate: pubDate2,
            source: "Metro Daily",
            fullContent: passage2.text
        )
        let article3 = FeedArticle(
            storedID: "art_persp_3",
            title: "Seismologists Monitor Caldera Activity",
            link: "https://\(fixtureHost)/news-3",
            guid: "guid-p3",
            description: passage3.text,
            pubDate: pubDate3,
            source: "Science Bulletin",
            fullContent: passage3.text
        )

        let citations: [String: OverviewCitation] = [
            "c_1": OverviewCitation(
                id: "c_1",
                articleID: "art_persp_1",
                passageID: "pass_persp_1",
                passageFingerprint: passage1.fingerprint,
                quote: "The evacuation routes are fully operational and emergency services have responded rapidly"
            ),
            "c_2": OverviewCitation(
                id: "c_2",
                articleID: "art_persp_2",
                passageID: "pass_persp_2",
                passageFingerprint: passage2.fingerprint,
                quote: "The evacuation routes are fully operational and emergency services have responded rapidly"
            ),
            "c_3": OverviewCitation(
                id: "c_3",
                articleID: "art_persp_3",
                passageID: "pass_persp_3",
                passageFingerprint: passage3.fingerprint,
                quote: "seismic sensors recorded increased tremor activity throughout the caldera"
            ),
        ]

        // #994: a statement runs to the end of its sentence, however long, and an honorific's full stop does not end
        // it; the display leads a lower-case clause with its speaker and closes every statement.
        let tribunal =
            "Late on Friday (October 30, 2026), the Constitutional Tribunal said its longest-serving judge Anna Korwin-Piotrowska had suspended Bogdan Swieczkowski, the tribunal's president and an appointee of Mr. Tusk's hard-right predecessor, and was now in charge of the court."
        let tribunalPassage = EvidencePassage(id: "pass_994", articleID: "art_persp_1", text: tribunal, ordinal: 3)
        let tribunalCitation = OverviewCitation(
            id: "c_994", articleID: "art_persp_1", passageID: "pass_994",
            passageFingerprint: tribunalPassage.fingerprint,
            quote: tribunal)
        let tribunalPerspectives = OverviewPerspectivesExtractor.extractPerspectives(
            passages: [tribunalPassage], articles: [article1], existingCitations: ["c_994": tribunalCitation])
        expectEqual(tribunalPerspectives.count, 1, "The tribunal's statement is one perspective")
        expectEqual(
            tribunalPerspectives.first?.position,
            "its longest-serving judge Anna Korwin-Piotrowska had suspended Bogdan Swieczkowski, the tribunal's president and an appointee of Mr. Tusk's hard-right predecessor, and was now in charge of the court",
            "The statement runs past 200 characters to the end of its sentence, through the honorific")
        // An exclamation or question mark ends an unquoted statement too; one inside a quoted phrase does not.
        func statements(_ text: String) -> [String] {
            let passage = EvidencePassage(id: "pass_994b", articleID: "art_persp_1", text: text, ordinal: 4)
            let citation = OverviewCitation(
                id: "c_994b", articleID: "art_persp_1", passageID: "pass_994b",
                passageFingerprint: passage.fingerprint, quote: text)
            return OverviewPerspectivesExtractor.extractPerspectives(
                passages: [passage], articles: [article1], existingCitations: ["c_994b": citation]
            ).map(\.position)
        }
        let atLimit = "the council " + String(repeating: "a", count: 388)
        expectEqual(
            statements("Mayor Elena Rostova said that \(atLimit). Officials disputed it."),
            [atLimit], "A complete 400-character statement is retained")
        for attribution in [
            "Mayor Elena Rostova said that", "Mayor Elena Rostova said", "According to Mayor Elena Rostova,",
        ] {
            for dot in ["Mr.", "Dr.", "U.S.", "8.9"] {
                let overlong = "the council consulted \(dot) " + String(repeating: "residents ", count: 45)
                expectTrue(
                    statements("\(attribution) \(overlong).").isEmpty,
                    "An overlong statement cannot backtrack to a nonterminal dot: \(attribution), \(dot)")
            }
        }
        expectEqual(
            statements("Mayor Elena Rostova said that the council consulted Mr. Smith about the £8.9bn plan."),
            ["the council consulted Mr. Smith about the £8.9bn plan"],
            "Honorifics and decimals remain inside a valid statement")
        for ending in [".", "!", "?", "\n", ""] {
            expectEqual(
                statements("Mayor Elena Rostova said that the evacuation routes are open again\(ending)"),
                ["the evacuation routes are open again"], "Valid sentence and passage endings are preserved")
        }
        expectEqual(
            statements("Mayor Elena Rostova said that the evacuation routes are open again! Officials disputed it."),
            ["the evacuation routes are open again"], "An exclamation mark ends the statement")
        expectEqual(
            statements("Mayor Elena Rostova said that residents asked if the routes were open? Officials disputed it."),
            ["residents asked if the routes were open"], "A question mark ends the statement")
        expectEqual(
            statements("Mayor Elena Rostova said that the council answered “Never!” and closed the session."),
            ["the council answered “Never!” and closed the session"], "A quoted exclamation stays inside the statement")
        expectTrue(
            !statements("Mayor Elena Rostova said that demonstrators shouted “Stop.” Officials rejected the claim.")
                .contains { $0.contains("Officials") }, "A quote that ends its sentence ends the statement")
        expectEqual(
            statements("Mayor Elena Rostova said that “the plan will fail next year” and left."),
            ["“the plan will fail next year” and left"], "A statement led by a whole quotation is retained (#1142)")
        expectEqual(
            statements("Mayor Elena Rostova said that “We will never go home now!” today."),
            ["“We will never go home now!” today"], "A quoted exclamation stays whole in a short statement (#1142)")
        expectTrue(
            statements("Mayor Elena Rostova said that prices rose.").isEmpty,
            "A statement under 15 characters is still rejected (#1142)")
        // #1142: overlapping alternatives made both inputs exponential; the patterns run on untrusted text.
        for adversarial in [
            "Officials said that " + String(repeating: "“a” ", count: 20) + String(repeating: "x ", count: 300),
            "Officials reviewed " + String(repeating: "A.1 ", count: 24) + String(repeating: "x ", count: 20),
        ] {
            let clock = ContinuousClock()
            let started = clock.now
            _ = statements(adversarial)
            expectTrue(clock.now - started < .seconds(5), "Attribution patterns do not backtrack exponentially")
        }
        expectEqual(
            OverviewComposer.displayStatement(
                participant: "Constitutional Tribunal", position: tribunalPerspectives.first?.position ?? ""),
            "Constitutional Tribunal said its longest-serving judge Anna Korwin-Piotrowska had suspended Bogdan Swieczkowski, the tribunal's president and an appointee of Mr. Tusk's hard-right predecessor, and was now in charge of the court.",
            "A lower-case clause is led by its speaker and closed with a full stop")
        expectEqual(
            OverviewComposer.displayStatement(
                participant: "the officers",
                position:
                    "they have since taken more than 340 witness statements - including from Brand's former employers, his ex-colleagues and associates"
            ),
            "The officers said they have since taken more than 340 witness statements - including from Brand's former employers, his ex-colleagues and associates.",
            "The speaker's first letter is capitalised")
        expectEqual(
            OverviewComposer.displayStatement(participant: "the mayor", position: "“we will rebuild the bridge”"),
            "The mayor said “we will rebuild the bridge.”", "A quotation opening in lower case is led by its speaker")
        expectEqual(
            OverviewComposer.displayStatement(participant: "the mayor", position: "“we will rebuild the bridge,”"),
            "The mayor said “we will rebuild the bridge.”", "A comma inside the closing quote becomes the full stop")
        expectEqual(
            OverviewComposer.displayStatement(
                participant: "Presiding Judge Joel Bennathan",
                position: "Brand would face a \"significant custodial term\""),
            "Brand would face a \"significant custodial term.\"", "The full stop goes inside a closing quotation mark")
        expectEqual(
            OverviewComposer.displayStatement(
                participant: "Mayor Elena Rostova", position: "The routes are open,"),
            "The routes are open.", "A capitalised statement keeps its words and loses a trailing comma")
        expectEqual(
            OverviewComposer.displayStatement(participant: "A", position: "“We will win”"),
            "“We will win.”", "A typographic quotation closes after the full stop")

        // 1. Extraction: extractPerspectives correctly extracts attributed positions
        let perspectives = OverviewPerspectivesExtractor.extractPerspectives(
            passages: [passage1, passage2, passage3],
            articles: [article1, article2, article3],
            existingCitations: citations
        )

        expectTrue(!perspectives.isEmpty, "Perspectives extractor extracts verified attributed perspectives")

        // 2. Rule 1: Only explicitly attributed positions
        for perspective in perspectives {
            expectTrue(
                !perspective.participant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Rule 1: Participant is non-empty")
            expectFalse(
                OverviewPerspectivesValidator.isVagueParticipant(perspective.participant),
                "Rule 1: Participant is not a vague anonymous generality")
            expectTrue(!perspective.position.isEmpty, "Rule 1: Position is non-empty")
        }

        // Validator rejects vague anonymous participants
        let vaguePerspective1 = OverviewPerspective(
            id: "p_vague_1",
            participant: "Critics say",
            position: "The response was inadequate.",
            citationIDs: ["c_1"]
        )
        let valVague1 = OverviewPerspectivesValidator.validatePerspective(vaguePerspective1, against: citations)
        expectFalse(valVague1.isValid, "Rule 1: Vague participant 'Critics say' is rejected")

        let vaguePerspective2 = OverviewPerspective(
            id: "p_vague_2",
            participant: "Observers",
            position: "Events developed rapidly.",
            citationIDs: ["c_1"]
        )
        let valVague2 = OverviewPerspectivesValidator.validatePerspective(vaguePerspective2, against: citations)
        expectFalse(valVague2.isValid, "Rule 1: Vague participant 'Observers' is rejected")

        let vaguePerspective3 = OverviewPerspective(
            id: "p_vague_3",
            participant: "Some people",
            position: "Conditions are difficult.",
            citationIDs: ["c_1"]
        )
        let valVague3 = OverviewPerspectivesValidator.validatePerspective(vaguePerspective3, against: citations)
        expectFalse(valVague3.isValid, "Rule 1: Vague participant 'Some people' is rejected")

        // A time phrase left over from "said Thursday" or "said earlier this year" is not a position (#313).
        for position in ["earlier this year.", "Thursday, warning it could be among the strongest", "Friday night"] {
            expectTrue(OverviewPerspectivesValidator.isTimePhrase(position), "Time phrase '\(position)' is no position")
        }
        expectFalse(
            OverviewPerspectivesValidator.isTimePhrase("Monday's vote was not legitimate."),
            "A possessive day name starts a real position")
        let timePerspective = OverviewPerspective(
            id: "p_time", participant: "Ahmad Mobeen", position: "earlier this year", citationIDs: ["c_1"])
        expectEqual(
            OverviewPerspectivesValidator.validatePerspective(timePerspective, against: citations).rule, .timePhrase,
            "Time-phrase positions report their own rule")

        // 3. Rule 2: Never invent an "other side"
        // When only one side has spoken, extraction preserves that single perspective without fabricating an opposing stance
        let singleSidePerspectives = OverviewPerspectivesExtractor.extractPerspectives(
            passages: [passage3],
            articles: [article3],
            existingCitations: ["c_3": try #require(citations["c_3"])]
        )
        expectEqual(
            singleSidePerspectives.count, 1,
            "Rule 2: Single-side event retains exactly 1 perspective, never manufactures a synthetic other side")
        expectEqual(
            singleSidePerspectives.first?.participant, "Dr. Sarah Jensen, Lead Volcanologist",
            "Preserves genuine speaker without forced balance")

        // Validator rejects synthetic/hallucinated position not grounded in cited passage
        let syntheticCounterPerspective = OverviewPerspective(
            id: "p_synthetic",
            participant: "Opposition Spokesperson",
            position: "The official seismic numbers are entirely fabricated and danger is imminent.",
            citationIDs: ["c_3"]
        )
        let valSynthetic = OverviewPerspectivesValidator.validatePerspective(
            syntheticCounterPerspective,
            against: citations,
            passages: [passage3]
        )
        expectFalse(valSynthetic.isValid, "Rule 2: Synthetic position not grounded in passage text is rejected")

        // 4. Rule 3: Reprints are not presented as independent voices
        // Articles 1 and 2 carried the same quote from Mayor Elena Rostova (one via Reuters wire)
        // They must be collapsed into a single perspective, not two separate voices!
        let mayorPerspectives = perspectives.filter { $0.participant.contains("Elena Rostova") }
        expectEqual(mayorPerspectives.count, 1, "Rule 3: Syndicated reprints are collapsed into a single voice")
        if let mayorPerspective = mayorPerspectives.first {
            expectEqual(
                mayorPerspective.originalWireSource, "Reuters", "Rule 3: Identified original wire service (Reuters)")
            expectTrue(
                mayorPerspective.citationIDs.contains("c_1") && mayorPerspective.citationIDs.contains("c_2"),
                "Rule 3: Combined citations from all reprint instances")
        }

        // 5. Rule 4: Sourced items
        let sourcelessPerspective = OverviewPerspective(
            id: "p_no_source",
            participant: "Mayor Elena Rostova",
            position: "Evacuation routes are open.",
            citationIDs: []
        )
        let valSourceless = OverviewPerspectivesValidator.validatePerspective(sourcelessPerspective, against: citations)
        expectFalse(valSourceless.isValid, "Rule 4: Perspective with no citation IDs is rejected")

        let nonExistentCitationPerspective = OverviewPerspective(
            id: "p_bad_source",
            participant: "Mayor Elena Rostova",
            position: "Evacuation routes are open.",
            citationIDs: ["c_missing_999"]
        )
        let valBadSource = OverviewPerspectivesValidator.validatePerspective(
            nonExistentCitationPerspective, against: citations)
        expectFalse(valBadSource.isValid, "Rule 4: Perspective citing non-existent citation ID is rejected")

        // 6. Absent sections rule
        // Purely descriptive passages with no attributed statements yield empty perspectives array
        let emptyPerspectives = OverviewPerspectivesExtractor.extractPerspectives(
            passages: [passageDescriptive],
            articles: [article1],
            existingCitations: ["c_1": try #require(citations["c_1"])]
        )
        expectTrue(
            emptyPerspectives.isEmpty,
            "Absent section rule: Section omitted when no verified attributed perspective exists")

        // #313: rejection rules and the coverage diagnosis carry no speaker or passage text.
        expectEqual(valVague1.rule, .vagueParticipant, "Vague speaker rule is named")
        expectEqual(valSynthetic.rule, .ungrounded, "Ungrounded position rule is named")
        expectEqual(valSourceless.rule, .noCitation, "Missing citation rule is named")
        expectEqual(valBadSource.rule, .unknownCitation, "Unknown citation rule is named")
        let diagnosis = OverviewPerspectivesExtractor.diagnosePerspectives(
            passages: [passage1, passage2, passage3],
            articles: [article1, article2, article3],
            existingCitations: citations
        )
        expectEqual(diagnosis.perspectives, perspectives.count, "Diagnosis counts what extraction returns")
        expectEqual(
            [diagnosis.passages, diagnosis.passagesWithCandidates, diagnosis.candidates, diagnosis.voices],
            [3, 3, 3, 2],
            "Diagnosis counts candidates per passage and collapses the reprint into one voice")
        let typographic = EvidencePassage(
            id: "pass_typo", articleID: "art_persp_1",
            text: "\u{201C}The evacuation routes are open,\u{201D} Mayor Elena Rostova said.")
        let typographicCitation = OverviewCitation(
            id: "c_typo", articleID: "art_persp_1", passageID: "pass_typo",
            passageFingerprint: typographic.fingerprint, quote: "The evacuation routes are open")
        let matched = OverviewPerspectivesExtractor.diagnosePerspectives(
            passages: [typographic, passageDescriptive],
            articles: [article1],
            existingCitations: ["c_typo": typographicCitation]
        )
        expectEqual(
            [
                matched.uncitedPassages, matched.passagesWithTypographicQuotes, matched.candidates,
                matched.passagesWithUnmatchedSpeech,
            ],
            [1, 1, 1, 0], "Diagnosis counts an uncited passage and the recovered typographic attribution")
        for text in [
            "“The evacuation routes are open,” said Mayor Elena Rostova.",
            "“The evacuation routes are open,” Mayor Elena Rostova said.",
            "\"The evacuation routes are open,\" Mayor Elena Rostova said.",
        ] {
            let passage = EvidencePassage(id: typographic.id, articleID: typographic.articleID, text: text)
            let extracted = OverviewPerspectivesExtractor.extractPerspectives(
                passages: [passage], articles: [article1], existingCitations: ["c_typo": typographicCitation])
            expectEqual(extracted.count, 1, "Both quote styles and speaker orders produce one verified voice")
            expectEqual(extracted.first?.participant, "Mayor Elena Rostova", "The named speaker is preserved")
            expectEqual(extracted.first?.position, "The evacuation routes are open,", "Statement is verbatim")
            expectEqual(extracted.first?.citationIDs, ["c_typo"], "The statement keeps its passage citation")
        }
        for text in [
            "“The evacuation routes are open,\" Mayor Elena Rostova said.",
            "\"The evacuation routes are open,” Mayor Elena Rostova said.",
            "“The evacuation routes are open,” without any attributed speaker.",
            "“The evacuation routes are open,” Critics said.",
        ] {
            let passage = EvidencePassage(id: typographic.id, articleID: typographic.articleID, text: text)
            expectTrue(
                OverviewPerspectivesExtractor.extractPerspectives(
                    passages: [passage], articles: [article1], existingCitations: ["c_typo": typographicCitation]
                ).isEmpty, "Mismatched delimiters, unattributed quotes and vague speakers stay excluded")
        }
        for (text, expectedStatement) in [
            ("Mayor Elena Rostova said: “The evacuation routes are open.”", "The evacuation routes are open."),
            ("Mayor Elena Rostova said, \"The evacuation routes are open.\"", "The evacuation routes are open."),
            ("Mayor Elena Rostova announced: \"The evacuation routes are open.\"", "The evacuation routes are open."),
            (
                "Mayor Elena Rostova told reporters: “The evacuation routes are open.”",
                "The evacuation routes are open."
            ),
            ("According to Mayor Elena Rostova, “The evacuation routes are open.”", "The evacuation routes are open."),
            (
                "Mayor Elena Rostova said: “The evacuation routes are open. Emergency personnel are ready.”",
                "The evacuation routes are open. Emergency personnel are ready."
            ),
        ] {
            let passage = EvidencePassage(id: typographic.id, articleID: typographic.articleID, text: text)
            let extracted = OverviewPerspectivesExtractor.extractPerspectives(
                passages: [passage], articles: [article1], existingCitations: ["c_typo": typographicCitation])
            expectEqual(extracted.count, 1, "Speaker-first quote '\(text)' produces one verified voice")
            expectEqual(extracted.first?.participant, "Mayor Elena Rostova", "Speaker '\(text)' is preserved")
            expectEqual(extracted.first?.position, expectedStatement, "Statement '\(text)' is verbatim")
        }
        // Reported speech without an adjacent "that" (#313).
        func reported(_ text: String) -> [OverviewPerspective] {
            let passage = EvidencePassage(id: "pass_reported", articleID: "art_persp_1", text: text)
            let citation = OverviewCitation(
                id: "c_reported", articleID: "art_persp_1", passageID: passage.id,
                passageFingerprint: passage.fingerprint, quote: text)
            return OverviewPerspectivesExtractor.extractPerspectives(
                passages: [passage], articles: [article1], existingCitations: ["c_reported": citation])
        }
        for (text, participant, position) in [
            (
                "Foreign Secretary Ed Miliband said his country does not accept the expulsion of its diplomats.",
                "Foreign Secretary Ed Miliband", "his country does not accept the expulsion of its diplomats"
            ),
            (
                "Minister Édouard Geffray told TF1 television on Thursday night that 3,000 substitute teachers would be hired.",
                "Minister Édouard Geffray", "3,000 substitute teachers would be hired"
            ),
            (
                "Foreign Secretary Ed Miliband told the BBC that his country does not accept the expulsion of its diplomats.",
                "Foreign Secretary Ed Miliband", "his country does not accept the expulsion of its diplomats"
            ),
            (
                "Spokesperson John Smith told a news conference that negotiations are scheduled to resume next week.",
                "Spokesperson John Smith", "negotiations are scheduled to resume next week"
            ),
            (
                "Ambassador Marco Rossi told an Italian news agency that bilateral trade had increased sharply.",
                "Ambassador Marco Rossi", "bilateral trade had increased sharply"
            ),
            (
                "The figures were published at noon. Mayor Elena Rostova says the evacuation routes are open again.",
                "Mayor Elena Rostova", "the evacuation routes are open again"
            ),
            // A sentence closed by its attribution, without quotation marks (#547).
            (
                "Russia launched 50 drones and 10 missiles at Kyiv overnight, the Ukrainian air force said.",
                "Ukrainian air force", "Russia launched 50 drones and 10 missiles at Kyiv overnight"
            ),
            (
                "Debris fell on two districts of the capital, said Mayor Vitali Klitschko.", "Mayor Vitali Klitschko",
                "Debris fell on two districts of the capital"
            ),
            (
                "At least 1,200 people were treated in hospitals, according to the Gaza health ministry.",
                "Gaza health ministry", "At least 1,200 people were treated in hospitals"
            ),
            (
                "The talks would resume next week, Kremlin spokesman Dmitry Peskov told reporters on Monday.",
                "Kremlin spokesman Dmitry Peskov", "The talks would resume next week"
            ),
            (
                "A ceasefire will begin in Oleshky on October 29, the White House said on Friday (October 23, 2026).",
                "White House", "A ceasefire will begin in Oleshky on October 29"
            ),
            (
                "Security was stepped up at malls across Jordan, the US embassy in Amman said on Saturday, as authorities searched for the gunmen.",
                "US embassy in Amman", "Security was stepped up at malls across Jordan"
            ),
            (
                "Kenya has recorded a second Ebola death, the health ministry said late on Friday, adding that she had died.",
                "health ministry", "Kenya has recorded a second Ebola death"
            ),
            (
                "Police estimated the load was worth 3.48 trillion rupiah, about 192 million U.S. dollars, Suyudi said.",
                "Suyudi", "Police estimated the load was worth 3.48 trillion rupiah, about 192 million U.S. dollars"
            ),
            (
                "\"We are not satisfied with the offer,\" said student representative Nathanael Combary, president of the group.",
                "student representative Nathanael Combary", "We are not satisfied with the offer,"
            ),
            // A bare institution is the speaker, never the nearby place (#547).
            (
                "At a base in southeast England housing US operations, police said an incident led to withdrawals.",
                "police", "an incident led to withdrawals"
            ),
            (
                "The 12-year-old girl was seriously wounded but stable, the mayor of La Verrière, Nicolas Dainville, told AFP.",
                "Nicolas Dainville", "The 12-year-old girl was seriously wounded but stable"
            ),
            // Second #547 pass: acronyms, appositives, present-tense verbs, quantities, initialisms, decimals, aliases.
            (
                "\"Science gives us hope,\" WHO chief Tedros Adhanom Ghebreyesus said on X.",
                "WHO chief Tedros Adhanom Ghebreyesus", "Science gives us hope,"
            ),
            (
                "\"We found that we needed to include some exotic physics,\" Jorge Hernández-Bernal, a planetary scientist at the Sorbonne, said in a press release.",
                "Jorge Hernández-Bernal", "We found that we needed to include some exotic physics,"
            ),
            (
                "\"We are not satisfied with the offer,\" says student representative Nathanael Combary.",
                "student representative Nathanael Combary", "We are not satisfied with the offer,"
            ),
            (
                "Interior Minister Laurent Nuñez said as many as 70,000 officers will be deployed nationwide.",
                "Interior Minister Laurent Nuñez", "as many as 70,000 officers will be deployed nationwide"
            ),
            (
                "First-time voter Naama Bitterman, 18, said at Saturday's rally that she was confident the bloc would win.",
                "First-time voter Naama Bitterman", "she was confident the bloc would win"
            ),
            ("Golan told me: \"I'm optimistic about the vote.\"", "Golan", "I'm optimistic about the vote."),
            (
                "The United States could strike Iran as soon as this weekend, a U.S. envoy said Friday (October 24, 2026), after mounting threats.",
                "U.S. envoy", "The United States could strike Iran as soon as this weekend"
            ),
            (
                "Melania Trump has secured a ceasefire that will begin on Oct. 29, the White House said on Friday.",
                "White House", "Melania Trump has secured a ceasefire that will begin on Oct. 29"
            ),
            (
                "The Conservative-Lib Dem coalition government said in 2013 it estimated hosting in London had cost £8.9bn.",
                "Conservative-Lib Dem coalition government", "it estimated hosting in London had cost £8.9bn"
            ),
            (
                "According to the United Nations Educational, Scientific and Cultural Organization, UNESCO, nearly 95 percent of campuses have been damaged.",
                "United Nations Educational, Scientific and Cultural Organization, UNESCO",
                "nearly 95 percent of campuses have been damaged"
            ),
            (
                "The woman did not visit Congo and is believed to have contracted the virus in Uganda, Switzerland's Federal Department of Foreign Affairs, or FDFA, told The Associated Press on Friday.",
                "Switzerland's Federal Department of Foreign Affairs",
                "The woman did not visit Congo and is believed to have contracted the virus in Uganda"
            ),
            (
                "The Ebola victim who died on Friday evening was a direct contact of the index patient, the ministry said.",
                "ministry", "The Ebola victim who died on Friday evening was a direct contact of the index patient"
            ),
            (
                "All schools have been told to close on Friday because of the high winds, the Government of Jersey said.",
                "Government of Jersey", "All schools have been told to close on Friday because of the high winds"
            ),
            (
                "At the Copacabana rally – which Rio's City Hall said attracted about 1.1 million people – activists unfurled a banner.",
                "Rio's City Hall", "attracted about 1.1 million people"
            ),
            (
                "Trump said Rubio — who is the son of Cuban immigrants — was \"deep into negotiations with Cuba\" this week.",
                "Trump",
                "Rubio — who is the son of Cuban immigrants — was \"deep into negotiations with Cuba\" this week"
            ),
            // Orchestrator review of the final rows (#547): another party's figure, a few quoted words.
            (
                "The government said 410,000 took place in protests across France while organisers put the figure at nearly 800,000.",
                "government", "410,000 took place in protests across France"
            ),
            (
                "Lethal plots by Tehran against American citizens have reached “advanced stages,” a senior intelligence official in the Trump administration warned.",
                "senior intelligence official in the Trump administration",
                "Lethal plots by Tehran against American citizens have reached “advanced stages,”"
            ),
            (
                "The damage was estimated \"at hundreds of millions euros\", France's Chambers of Commerce and Industry (CCI) said.",
                "France's Chambers of Commerce and Industry",
                "The damage was estimated \"at hundreds of millions euros\""
            ),
            (
                "Chadema put the death toll at about 2,000, a figure the UN said it could not verify amid the shutdown.",
                "UN", "it could not verify amid the shutdown"
            ),
            (
                "PARIS: The clash with Lyon has been moved from Sunday to Monday evening, the French soccer league said on Friday.",
                "French soccer league", "The clash with Lyon has been moved from Sunday to Monday evening"
            ),
            (
                "The hunger strike will begin on Monday at the prison, said Mr. Nshala.", "Mr. Nshala",
                "The hunger strike will begin on Monday at the prison"
            ),
            (
                "Kenya has recorded a second Ebola death, the health ministry said the woman had developed symptoms in quarantine.",
                "health ministry", "the woman had developed symptoms in quarantine"
            ),
            (
                "Earlier this week, the Canadian prime minister, Mark Carney, said American tariffs hurt both American and Canadian households.",
                "Canadian prime minister, Mark Carney", "American tariffs hurt both American and Canadian households"
            ),
        ] {
            let extracted = reported(text)
            expectEqual(extracted.map(\.participant), [participant], "Reported speech names its speaker")
            expectEqual(extracted.first?.position, position, "The reported statement is verbatim")
        }
        for (text, participant) in [
            ("Last month, Germany said it had concluded Russia was responsible for the drone attack.", "Germany"),
            ("Later Thursday, Zelenskyy said negotiators were headed to the United States for talks.", "Zelenskyy"),
            (
                "Thursday, the Coalition to Restore Legitimacy said it intercepted two ballistic missiles.",
                "Coalition to Restore Legitimacy"
            ),
            (
                "Kremlin spokesman Dmitry Peskov also said Russia welcomed the offer of assistance.",
                "Kremlin spokesman Dmitry Peskov"
            ),
            (
                "Judge Hilliard, sitting at the high court in London, said the police had conceded the error.",
                "Judge Hilliard"
            ),
            (
                "US President Donald Trump said Tuesday that he had scheduled a call with Vladimir Putin.",
                "US President Donald Trump"
            ),
        ] {
            expectEqual(
                reported(text).map(\.participant), [participant], "Adverbials and descriptions leave the speaker")
        }
        expectEqual(
            reported("US President Donald Trump said Tuesday that he had scheduled a call with Vladimir Putin.").first?
                .position, "he had scheduled a call with Vladimir Putin", "The day is not part of the statement")
        for text in [
            "Seoul, which said it had placed their families in North Korea at risk of reprisals.",
            "In Liege, where police said almost 200 arrests had been made in connection with protests.",
            "Human Rights Watch said in a report Thursday.",
            "The Venezuelan government said was an attempt to assassinate the president of the country.",
            "Investigator Randy Spivey said adding that the inmate is now aware of what was done.",
            "A father of four said it would cost about 500 shekels to feed his family breakfast.",
            "He said Israel would also expel British representatives from the consulate.",
            "It said 224 schools were closed in the morning, down to 157 by lunchtime.",
            "Officials said the bridge would reopen to traffic next week.",
            // Attribution regressions (#313): nearby places, clauses, poll results and time phrases.
            "A letter from the attorney to the county commission in Florida said Trump offered to deem the club a presidential retreat.",
            "The Death Penalty Information Center, which publishes data and analysis on capital punishment in the United States, said Pike was the first inmate to survive after being injected with lethal doses of execution drugs.",
            "Trump, who waged war with Iran and has yet to broker peace in Ukraine, said on Wednesday that he should win.",
            "First reported by the Palm Beach Post, an attorney who represents the golf course said Trump is offering.",
            "A poll showed that 68% of Jewish Israelis said that the events were central.",
            "A witness told The Associated Press, a day after the kingdom said an attack occurred.",
            "Counter Terrorism Policing London is investigating and commander Helen Flanagan said officers were not linking it.",
            "This is the 17th outbreak in the DRC and is said to be its deadliest.",
            "Wednesday in which Saudi civil aviation authorities said three people were killed.",
            "While the interior ministry said that 256,000 people protested nationwide, organisers put the figure higher.",
            "Ahmad Mobeen, principal economist at S&P Global Market Intelligence, said earlier this year.",
            "El Nino will intensify before peaking, the United Nations said Thursday, warning it could be among the strongest.",
            "The bridge reopened to traffic after six weeks, officials said.",
            "The bridge reopened to traffic after six weeks, he said.",
            "Authorities said 2,500 police officers are patrolling the streets of the capital.",
            "More than 3,700 homes were still without electricity on Saturday morning, according to the National Grid map.",
            "Many say their anger shows no sign of fading after the protests across the country.",
            "According to posts on Reddit about the affected units, the issue appears to be happening at a similar spot.",
        ] {
            expectTrue(
                reported(text).isEmpty,
                "Nearby places, passive/clause fragments, poll subjects and time phrases are excluded: \(text)")
        }
        expectFalse(
            reported(
                "\u{201C}Albanians have woken up,\u{201D} said protester Daniel Tahiri, who called it a \u{201C}dictatorship with the clothes of democracy.\u{201D} Another protester, Orgeta Likaj, said people wanted change."
            ).contains { $0.participant.contains("Likaj") && $0.position.contains("dictatorship") },
            "A quotation that ends its sentence is not given to the next sentence's speaker")
        expectEqual(
            reported(
                "Executive Producer Elizabeth White told The Guardian in the past, \"the amount of plankton and things\" would have stopped a shot."
            )
            .first?.position, "\"the amount of plankton and things\" would have stopped a shot",
            "A quoted fragment after its speaker runs to the end of its sentence, without the speaker's own words")
        expectFalse(
            reported(
                "\"We have received intelligence that Iran increased its efforts,\" Mr. Clayton said in a memo sent to Secretary of State Marco Rubio, according to a U.S. official."
            ).contains { $0.participant == "U.S. official" }, "A report of a report is not the reporter's position")
        expectFalse(
            reported(
                "A fire alarm went off at the building on Friday, police said in a statement. Firefighters who went to the scene could see the flames."
            ).contains { $0.position.contains("could see the flames") },
            "A tag's channel does not reach into the next sentence")
        // A merged voice cites the passage its position comes from first.
        let ownPassage = EvidencePassage(
            id: "pass_own", articleID: "art_persp_1",
            text: "\"Iran has substantially increased efforts to target US personnel,\" Clayton wrote to the secretary."
        )
        let otherPassage = EvidencePassage(
            id: "pass_other", articleID: "art_persp_1",
            text: "\"Iran has substantially increased efforts to target U.S. personnel,\" Mr. Clayton said in a memo.")
        let mergedVoice = OverviewPerspectivesExtractor.extractPerspectives(
            passages: [ownPassage, otherPassage], articles: [article1],
            existingCitations: [
                "c_z": OverviewCitation(
                    id: "c_z", articleID: "art_persp_1", passageID: ownPassage.id,
                    passageFingerprint: ownPassage.fingerprint, quote: ownPassage.text),
                "c_a": OverviewCitation(
                    id: "c_a", articleID: "art_persp_1", passageID: otherPassage.id,
                    passageFingerprint: otherPassage.fingerprint, quote: otherPassage.text),
            ])
        expectEqual(mergedVoice.count, 1, "A repeated statement of one speaker is one voice")
        expectEqual(
            mergedVoice.first?.citationIDs.first, "c_z", "A merged voice cites its position's own passage first")
    }

    static func testThematicAngleFromExistingFacts(fixtureHost: String = "example.com") async throws {
        print("=== Testing Thematic Angle from Existing Facts (Issue #145) ===")

        let pubDate = Date(timeIntervalSince1970: 1_776_300_000)

        // Passage 1: Verified financial transaction fact
        let passage1 = EvidencePassage(
            id: "pass_fin_1",
            articleID: "art_fin_1",
            text: "The acquisition price was officially closed at $4.2 billion in cash and equity.",
            ordinal: 1
        )
        // Passage 2: Target company earnings
        let passage2 = EvidencePassage(
            id: "pass_fin_2",
            articleID: "art_fin_1",
            text: "Target firm reported annual recurring revenue of $850 million with 32% year-over-year growth.",
            ordinal: 2
        )
        // Passage 3: Headcount and operational figures
        let passage3 = EvidencePassage(
            id: "pass_fin_3",
            articleID: "art_fin_1",
            text: "The combined enterprise will maintain 12,000 employees across 18 regional hubs.",
            ordinal: 3
        )
        // Passage 4: Generic qualitative text with no thematic metrics
        let passageGeneric = EvidencePassage(
            id: "pass_gen_4",
            articleID: "art_fin_1",
            text: "Representatives praised the collaborative spirit of the negotiations.",
            ordinal: 4
        )

        _ = FeedArticle(
            storedID: "art_fin_1",
            title: "Major Tech Acquisition Closes",
            link: "https://\(fixtureHost)/finance-1",
            guid: "guid-f1",
            description: passage1.text,
            pubDate: pubDate,
            source: "Financial Daily",
            fullContent: "\(passage1.text) \(passage2.text) \(passage3.text) \(passageGeneric.text)"
        )

        let citations: [String: OverviewCitation] = [
            "c_fin_1": OverviewCitation(
                id: "c_fin_1",
                articleID: "art_fin_1",
                passageID: "pass_fin_1",
                passageFingerprint: passage1.fingerprint,
                quote: "The acquisition price was officially closed at $4.2 billion"
            ),
            "c_fin_2": OverviewCitation(
                id: "c_fin_2",
                articleID: "art_fin_1",
                passageID: "pass_fin_2",
                passageFingerprint: passage2.fingerprint,
                quote: "annual recurring revenue of $850 million with 32% year-over-year growth"
            ),
            "c_fin_3": OverviewCitation(
                id: "c_fin_3",
                articleID: "art_fin_1",
                passageID: "pass_fin_3",
                passageFingerprint: passage3.fingerprint,
                quote: "maintain 12,000 employees across 18 regional hubs"
            ),
        ]

        let fact1 = PassageAnchoredFact(
            statement: "Acquisition price closed at $4.2 billion in cash and equity.",
            passageID: "pass_fin_1",
            quote: "The acquisition price was officially closed at $4.2 billion",
            articleID: "art_fin_1"
        )
        let fact2 = PassageAnchoredFact(
            statement: "Target company reported $850 million in annual recurring revenue with 32% growth.",
            passageID: "pass_fin_2",
            quote: "annual recurring revenue of $850 million with 32% year-over-year growth",
            articleID: "art_fin_1"
        )
        let fact3 = PassageAnchoredFact(
            statement: "Combined enterprise retains 12,000 employees across 18 regional hubs.",
            passageID: "pass_fin_3",
            quote: "maintain 12,000 employees across 18 regional hubs",
            articleID: "art_fin_1"
        )
        let factGeneric = PassageAnchoredFact(
            statement: "Negotiations proceeded in a collaborative spirit.",
            passageID: "pass_gen_4",
            quote: "collaborative spirit of the negotiations",
            articleID: "art_fin_1"
        )

        // 1. Extraction: extractThematicAngle identifies financial figures angle from quantitative facts
        let angle = OverviewThematicAngleExtractor.extractThematicAngle(
            facts: [fact1, fact2, fact3, factGeneric],
            passages: [passage1, passage2, passage3, passageGeneric],
            existingCitations: citations
        )

        expectTrue(angle != nil, "Extractor discovers thematic angle from evidence facts")
        expectEqual(angle?.title, "Financial figures", "Identifies financial figures title")
        expectTrue((angle?.facts.count ?? 0) >= 2, "Contains at least 2 quantitative/thematic facts")
        expectFalse(angle?.citationIDs.isEmpty ?? true, "Angle has non-empty citations")

        // 2. Rule 1: No forecasts
        // Extractor never includes forecasts or projections in thematic facts
        for fact in angle?.facts ?? [] {
            expectFalse(
                OverviewThematicAngleValidator.isForecast(fact.text),
                "Rule 1: Angle fact does not contain speculative forecasts")
        }

        // Validator rejects candidate with forward-looking forecast
        let forecastFact = OverviewFact(
            id: "f_forecast",
            text: "Stock price is forecast to surge by 45% over the next two fiscal years.",
            citationIDs: ["c_fin_1"]
        )
        let forecastAngle = OverviewThematicAngle(
            id: "ang_forecast",
            title: "Financial figures",
            summary: "Revenue is projected to triple by 2030.",
            citationIDs: ["c_fin_1"],
            facts: [forecastFact]
        )
        let valForecast = OverviewThematicAngleValidator.validateAngle(forecastAngle, against: citations)
        expectFalse(valForecast.isValid, "Rule 1: Angle with forecast/projections is rejected")

        // 3. Rule 2: No investment advice
        let adviceFact = OverviewFact(
            id: "f_advice",
            text: "Analysts issue a strong buy recommendation for retail investors.",
            citationIDs: ["c_fin_1"]
        )
        let adviceAngle = OverviewThematicAngle(
            id: "ang_advice",
            title: "Financial figures",
            summary: "Investors should buy shares before the dividend ex-date.",
            citationIDs: ["c_fin_1"],
            facts: [adviceFact]
        )
        let valAdvice = OverviewThematicAngleValidator.validateAngle(adviceAngle, against: citations)
        expectFalse(valAdvice.isValid, "Rule 2: Angle with investment advice or stock ratings is rejected")

        // 4. Rule 3: Every fact cited
        for fact in angle?.facts ?? [] {
            expectFalse(fact.citationIDs.isEmpty, "Rule 3: Every thematic fact has citation IDs")
            for citID in fact.citationIDs {
                expectTrue(citations[citID] != nil, "Rule 3: Fact citation ID exists in citations map")
            }
        }

        // Validator rejects fact without citation
        let uncitedFact = OverviewFact(
            id: "f_uncited",
            text: "Uncited financial figure.",
            citationIDs: []
        )
        let uncitedAngle = OverviewThematicAngle(
            id: "ang_uncited",
            title: "Financial figures",
            summary: "Summary text.",
            citationIDs: ["c_fin_1"],
            facts: [uncitedFact]
        )
        let valUncited = OverviewThematicAngleValidator.validateAngle(uncitedAngle, against: citations)
        expectFalse(valUncited.isValid, "Rule 3: Angle with uncited fact is rejected")

        // 5. Absent sections rule: section omitted when fewer than 2 thematic facts exist
        let noThematicAngle = OverviewThematicAngleExtractor.extractThematicAngle(
            facts: [factGeneric],
            passages: [passageGeneric],
            existingCitations: [:]
        )
        expectEqual(
            noThematicAngle, nil, "Absent sections rule: Thematic angle is nil when insufficient thematic facts exist")
    }

    // MARK: - Coverage Sentiment Evaluation (Issue #146)

    static func testCoverageSentimentEvaluation(fixtureHost: String = "example.com") async throws {
        print("=== Testing Coverage Sentiment Evaluation on Corpus (Issue #146) ===")

        // 1. Evaluate frozen corpus across news categories and languages
        let evaluator = CoverageSentimentEvaluator.shared
        let metrics = evaluator.runCorpusEvaluation()

        expectTrue(metrics.totalEvaluated >= 8, "Corpus must contain diverse evaluated samples")
        expectTrue(metrics.objectiveCrisisCount >= 4, "Corpus must contain adverse crisis hard news reports")
        expectTrue(
            metrics.objectiveCrisisFalseNegatives >= 3,
            "Raw lexical sentiment falsely flags objective crisis news as critical/negative")
        expectTrue(
            metrics.falseNegativityOnObjectiveEvents > 0.50,
            "Lexical sentiment exhibits >50% false negativity on factual disaster reports")
        expectTrue(
            metrics.multilingualCoverageRate < 0.60,
            "Native sentiment model is absent for majority of catalog languages (uk, pl, nl)")

        // 2. Evaluation decision: NO-GO for default overview section
        expectFalse(
            metrics.justifiesOverviewSection, "Acceptance gate: sentiment must NOT ship unless evaluation justifies it")
        expectTrue(metrics.rationale.contains("absent sections rule"), "Rationale must cite absent sections rule")

        // 3. Gate enforcement for synthesis
        let dummyPassages: [EvidencePassage] = []
        expectFalse(
            CoverageSentimentEvaluator.shouldIncludeInOverview(passages: dummyPassages),
            "Passage overview inclusion gate must evaluate to false")
        expectEqual(
            CoverageSentimentEvaluator.synthesizeCoverageSentiment(passages: dummyPassages), nil,
            "Coverage sentiment synthesis must return nil when gate is false")

        let testArticle = FeedArticle(
            title: "Transit rail reopened after junction maintenance",
            link: "https://\(fixtureHost)/transit/update",
            guid: "guid_sentiment_test_1",
            description: "Transit crews completed repairs.",
            pubDate: Date(),
            source: "Transit Daily"
        )
        expectFalse(
            CoverageSentimentEvaluator.shouldIncludeInOverview(for: [testArticle]),
            "Article overview inclusion gate must evaluate to false")
        expectEqual(
            CoverageSentimentEvaluator.synthesizeCoverageSentiment(for: [testArticle]), nil,
            "Article coverage sentiment synthesis must return nil")

        // 4. Overview composition integration: sentiment remains absent
        let passage = EvidencePassage(
            id: "pass_sent_1",
            articleID: testArticle.id,
            text: "Transit rail operations resumed after electrical repairs were certified by safety engineers.",
            ordinal: 0
        )
        let fact = PassageAnchoredFact(
            id: "fact_sent_1",
            statement: "Transit operations resumed following certified safety repairs.",
            passageID: passage.id,
            quote: "Transit rail operations resumed after electrical repairs were certified by safety engineers.",
            articleID: testArticle.id
        )
        let fact2 = PassageAnchoredFact(
            id: "fact_sent_2",
            statement: "Electrical repairs were certified by safety engineers.",
            passageID: passage.id,
            quote: "electrical repairs were certified by safety engineers",
            articleID: testArticle.id
        )
        let fact3 = PassageAnchoredFact(
            id: "fact_sent_3",
            statement: "Crews completed track maintenance on the main junction corridor.",
            passageID: passage.id,
            quote: "Transit rail operations resumed",
            articleID: testArticle.id
        )

        let composedDoc = OverviewComposer.composeOverview(
            eventID: "ev_sent_test",
            eventTitle: "Transit operations restored",
            verifiedFacts: [fact, fact2, fact3],
            passages: [passage],
            articles: [testArticle]
        )

        expectEqual(
            composedDoc.coverageSentiment, nil,
            "Composed overview must have nil coverageSentiment per evaluation decision")
        expectEqual(
            composedDoc.evidenceSections?.coverageSentiment, nil,
            "OverviewEvidenceSections must omit sentiment when evaluation does not justify it")

        // 5. Calibrated safe text tone assessment
        let crisisHeadline =
            "A magnitude 6.8 earthquake struck the northern coast, damaging residential structures and injuring 18 residents."
        let crisisTone = CoverageSentimentEvaluator.assessTextToneSafely(crisisHeadline)
        expectTrue(
            crisisTone.isConfoundedByEventAdversity, "Must detect that crisis vocabulary confounds lexical sentiment")
        expectEqual(
            crisisTone.label, "Neutral", "Confounded crisis report must be safely calibrated to Neutral reporting tone")

        let editorialText =
            "The municipal administration's disastrous decision to defund maintenance is a shameful and reckless policy."
        let editorialTone = CoverageSentimentEvaluator.assessTextToneSafely(editorialText)
        expectFalse(
            editorialTone.isConfoundedByEventAdversity, "Explicit editorial markers must prevent adversity confusion")
        expectEqual(editorialTone.label, "Critical", "Editorial opinion piece must be recognized as Critical tone")

        // 6. Model serialization and empty state invariants
        let customSentiment = OverviewCoverageSentiment(
            score: -0.1,
            label: "Neutral",
            confidence: 0.85,
            rationale: "Calibrated objective tone"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encodedData = try encoder.encode(customSentiment)
        let decodedSentiment = try decoder.decode(OverviewCoverageSentiment.self, from: encodedData)
        expectEqual(decodedSentiment.score, customSentiment.score, "Decoded score matches")
        expectEqual(decodedSentiment.label, customSentiment.label, "Decoded label matches")
        expectEqual(decodedSentiment.confidence, customSentiment.confidence, "Decoded confidence matches")
        expectEqual(decodedSentiment.rationale, customSentiment.rationale, "Decoded rationale matches")

        let emptyEvidence = OverviewEvidenceSections()
        expectTrue(emptyEvidence.isEmpty, "Default OverviewEvidenceSections is empty")

        let sentimentEvidence = OverviewEvidenceSections(coverageSentiment: customSentiment)
        expectFalse(sentimentEvidence.isEmpty, "OverviewEvidenceSections with sentiment is not empty")
    }

    static func testHybridSearchSemanticRetrievalAndSnippets() async throws {
        print("  - Testing natural language semantic retrieval and snippet highlighting...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-hybrid-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = DatabaseEngine(path: directory.appendingPathComponent("hybrid.sqlite3").path)
        try await db.open()
        defer { Task { await db.close() } }

        // Article A: purely semantic match (zero headline/description token overlap with "astronomy cosmic exploration")
        let artA = FeedArticle(
            storedID: "art-jwst",
            title: "Primordial Deep Field Survey Published",
            link: "https://example.com/jwst",
            guid: "jwst-1",
            description: "Orbital observatory observes redshift objects from thirteen billion years ago",
            pubDate: Date(timeIntervalSince1970: 1_700_000_000),
            source: "Science Daily"
        )
        // Article B: lexical match (contains exact tokens "astronomy cosmic exploration")
        let artB = FeedArticle(
            storedID: "art-lexical",
            title: "Astronomy cosmic exploration update",
            link: "https://example.com/lexical",
            guid: "lex-1",
            description: "Recent developments in astronomy cosmic exploration and deep observation",
            pubDate: Date(timeIntervalSince1970: 1_700_000_100),
            source: "Space Digest"
        )
        try await db.upsertArticles([artA, artB])

        // Query vector and synthetic embeddings
        let dim = SentenceEmbedder.vectorDimension
        let queryVec: [Float] = (0..<dim).map { i in
            i % 2 == 0 ? Float(1.0 / sqrt(Double(dim / 2))) : 0.0
        }
        // Art A vector aligned with query vector (cosine = 0.85)
        let artAVec: [Float] = (0..<dim).map { i in
            if i % 2 == 0 {
                return Float(0.85 / sqrt(Double(dim / 2)))
            } else {
                return Float(sqrt(1.0 - 0.85 * 0.85) / sqrt(Double(dim / 2)))
            }
        }
        // Art B vector divergent (cosine = 0.10, below 0.25 threshold)
        let artBVec: [Float] = (0..<dim).map { i in
            if i % 2 == 0 {
                return Float(0.10 / sqrt(Double(dim / 2)))
            } else {
                return Float(sqrt(1.0 - 0.10 * 0.10) / sqrt(Double(dim / 2)))
            }
        }
        // Below the threshold: as close as the typos measured on a real library, so never a semantic match.
        let artC = FeedArticle(
            storedID: "art-weather", title: "Weekend weather outlook", link: "https://example.com/weather",
            guid: "weather-1", description: "Showers clearing by Sunday",
            pubDate: Date(timeIntervalSince1970: 1_700_000_200),
            source: "Met Desk")
        try await db.upsertArticles([artC])
        let artCVec: [Float] = (0..<dim).map { i in
            Float((i % 2 == 0 ? 0.30 : sqrt(1.0 - 0.30 * 0.30)) / sqrt(Double(dim / 2)))
        }
        try await db.upsertArticleEmbeddings(
            ["art-jwst": artAVec, "art-lexical": artBVec, "art-weather": artCVec],
            modelVersion: SentenceEmbedder.modelVersion
        )

        // Semantic-only search for Art A (zero keyword overlap)
        let semanticOnlyResults = try await db.searchArticles(
            query: "primordial redshift", queryEmbedding: nil)
        // Lexical hit on art-jwst for "primordial redshift"
        expectFalse(semanticOnlyResults.isEmpty, "Lexical query matches art-jwst")
        expectTrue(
            semanticOnlyResults.first?.searchExcerpt?.runs.contains { $0.isMatch && $0.text == "redshift" } == true,
            "Lexical hit includes an excerpt of its summary with the match marked")

        // Now natural language query with zero keyword overlap to art-jwst:
        // "astronomy cosmic exploration" has zero words in art-jwst (title or description)
        let hybridResults = try await db.searchArticles(
            query: "astronomy cosmic exploration",
            limit: 10,
            queryEmbedding: queryVec
        )
        expectEqual(hybridResults.count, 2, "Both lexical and semantic candidates surfaced")
        // A caller that resolved no vector keeps it: the page does not look one up again behind its counts (#985)
        let resolvedWithoutVector = try await db.searchArticles(
            query: "astronomy cosmic exploration", limit: 10, queryEmbedding: nil, vectorResolved: true)
        expectFalse(
            resolvedWithoutVector.contains { $0.id == "art-jwst" },
            "A resolved nil vector stays lexical: the semantic candidate does not surface (#985)")

        let jwstHit = hybridResults.first { $0.id == "art-jwst" }
        expectTrue(jwstHit != nil, "Semantic candidate surfaced despite zero keyword overlap")
        expectTrue(jwstHit?.searchSnippet == nil, "Never fabricate snippets for semantic-only match")

        let lexicalHit = hybridResults.first { $0.id == "art-lexical" }
        expectTrue(lexicalHit != nil, "Lexical candidate surfaced")
        expectTrue(lexicalHit?.searchExcerpt != nil, "Lexical hit retains its highlighted excerpt")
        // Rank 1 in one arm scores 1/(k+1); equal fused scores break ties by id; the order is stable across runs.
        let rankOne = 1.0 / Double(DatabaseEngine.rrfK + 1)
        expectEqual(hybridResults.map(\.id), ["art-jwst", "art-lexical"], "Equal fused scores break ties by id")
        expectEqual(hybridResults.map(\.queryOrderValue), [rankOne, rankOne], "Rank 1 in one arm scores 1/(k+1)")
        let repeated = try await db.searchArticles(
            query: "astronomy cosmic exploration", limit: 10, queryEmbedding: queryVec)
        expectEqual(repeated.map(\.id), hybridResults.map(\.id), "The fused order is the same on every run")
        expectEqual(
            try await db.listTotals(search: "astronomy cosmic exploration", searchVector: queryVec).stories, 2,
            "The masthead total counts the semantic match the list shows")

        // A quoted phrase (an entity tag) asks for those exact words: no semantic matches, in the list or the count.
        let phrase = try await db.searchArticles(
            query: "\"astronomy cosmic exploration\"", limit: 10, queryEmbedding: queryVec)
        expectEqual(phrase.map(\.id), ["art-lexical"], "A quoted phrase stays lexical")
        expectEqual(
            try await db.listTotals(search: "\"astronomy cosmic exploration\"", searchVector: queryVec).stories, 1,
            "A quoted phrase's total counts lexical matches only")
    }

    static func testHybridSearchMutingAndFilters() async throws {
        print("  - Testing hybrid search mute rules and filter tokens...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-hybrid-filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = DatabaseEngine(path: directory.appendingPathComponent("filters.sqlite3").path)
        try await db.open()
        defer { Task { await db.close() } }

        let a1 = FeedArticle(
            storedID: "art-1", title: "Quantum physics breakthrough", link: "https://bloomberg.example/1",
            guid: "a-1", description: "Computing hardware advances", pubDate: Date(), source: "Bloomberg",
            category: "Technology"
        )
        let a2 = FeedArticle(
            storedID: "art-2", title: "Quantum semiconductor research", link: "https://reuters.example/2",
            guid: "a-2", description: "Computing chips developments", pubDate: Date(), source: "Reuters",
            category: "Technology"
        )
        let a3 = FeedArticle(
            storedID: "art-3", title: "Crypto token speculation", link: "https://reuters.example/3",
            guid: "a-3", description: "Bitcoin digital assets surge", pubDate: Date(), source: "Reuters",
            category: "Finance"
        )
        try await db.upsertArticles([a1, a2, a3])
        try await db.markRead(articleId: "art-2", isRead: true)

        let dim = SentenceEmbedder.vectorDimension
        let quantumVec: [Float] = (0..<dim).map { i in i % 2 == 0 ? Float(1.0 / sqrt(Double(dim / 2))) : 0.0 }
        let cryptoVec: [Float] = (0..<dim).map { i in i % 2 != 0 ? Float(1.0 / sqrt(Double(dim / 2))) : 0.0 }
        try await db.upsertArticleEmbeddings(
            ["art-1": quantumVec, "art-2": quantumVec, "art-3": cryptoVec],
            modelVersion: SentenceEmbedder.modelVersion
        )

        // 1. Mute publisher Bloomberg
        let muteRules = MuteRules(sources: ["bloomberg.example"])
        let unmutedResults = try await db.searchArticles(
            query: "quantum", limit: 10, muting: muteRules, queryEmbedding: quantumVec)
        expectTrue(
            unmutedResults.allSatisfy { $0.source != "Bloomberg" }, "Muted publisher filtered from hybrid results")
        expectEqual(unmutedResults.map(\.id), ["art-2"], "Only unmuted Reuters quantum article returned")
        expectEqual(
            unmutedResults.first?.queryOrderValue, 2 / Double(DatabaseEngine.rrfK + 1),
            "Rank 1 in both arms scores 2/(k+1), the highest fused score")
        // No story contains "superconductors", so only the vector can find the muted art-1.
        _ = try await db.searchArticles(
            query: "superconductors", limit: 10, muting: muteRules, queryEmbedding: quantumVec)
        expectEqual(
            try await db.mutedArticleCount(search: "superconductors", muting: muteRules), 0,
            "Without the query vector the count is lexical, and nothing matches the word")
        expectEqual(
            try await db.mutedArticleCount(search: "superconductors", searchVector: quantumVec, muting: muteRules), 1,
            "The muted count includes a muted story the semantic arm would list, and is not the lexical one cached")

        // 2. Mute topic crypto
        let topicMuting = MuteRules(topics: ["Crypto"])
        let topicResults = try await db.searchArticles(
            query: "token", limit: 10, muting: topicMuting, queryEmbedding: cryptoVec)
        expectTrue(topicResults.isEmpty, "Muted topic filtered from hybrid results")

        // 3. Filter is:unread
        let unreadResults = try await db.searchArticles(
            query: "quantum is:unread", limit: 10, queryEmbedding: quantumVec)
        expectEqual(unreadResults.map(\.id), ["art-1"], "is:unread filters out read story art-2")

        // 4. Filter source:Reuters
        let reutersResults = try await db.searchArticles(
            query: "quantum source:reuters", limit: 10, queryEmbedding: quantumVec)
        expectEqual(reutersResults.map(\.id), ["art-2"], "source:reuters filters to Reuters stories")

        // 5. Two searches interleave (#985): B runs between A's page and A's counts. Each search's counts follow its
        // own vector, so they equal its result set whatever the other search did.
        let pageA = try await db.searchArticles(
            query: "superconductors", limit: 10, muting: muteRules, queryEmbedding: quantumVec)
        let pageB = try await db.searchArticles(
            query: "ledgers", limit: 10, muting: muteRules, queryEmbedding: cryptoVec)
        let hiddenA = try await db.mutedArticleCount(
            search: "superconductors", searchVector: quantumVec, muting: muteRules)
        let totalsA = try await db.listTotals(
            search: "superconductors", searchVector: quantumVec, muting: muteRules)
        let totalsB = try await db.listTotals(search: "ledgers", searchVector: cryptoVec, muting: muteRules)
        expectEqual(pageA.map(\.id), ["art-2"], "Search A lists its own semantic match")
        expectEqual(pageB.map(\.id), ["art-3"], "Search B lists its own semantic match")
        expectEqual(totalsA.stories, pageA.count, "A's total equals A's results after B ran")
        expectEqual(totalsB.stories, pageB.count, "B's total equals B's results")
        expectEqual(hiddenA, 1, "A's muted count still includes the story its vector reaches")
        expectEqual(
            try await db.mutedArticleCount(search: "ledgers", searchVector: cryptoVec, muting: muteRules), 0,
            "B hides nothing")
        let phraseVector = try await db.searchQueryVector(for: "\"quantum research\"")
        let operatorVector = try await db.searchQueryVector(for: "is:unread")
        expectTrue(phraseVector == nil && operatorVector == nil, "A quoted phrase and operators alone have no vector")
    }

    static func testHybridSearchCursorPagination() async throws {
        print("  - Testing hybrid search cursor pagination stability...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-hybrid-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = DatabaseEngine(path: directory.appendingPathComponent("paging.sqlite3").path)
        try await db.open()
        defer { Task { await db.close() } }

        var articles: [FeedArticle] = []
        let dim = SentenceEmbedder.vectorDimension
        var embeddings: [String: [Float]] = [:]
        let queryVec: [Float] = (0..<dim).map { i in i % 2 == 0 ? Float(1.0 / sqrt(Double(dim / 2))) : 0.0 }

        for i in 0..<12 {
            let id = String(format: "page-art-%02d", i)
            articles.append(
                FeedArticle(
                    storedID: id,
                    title: "Energy research report \(i)",
                    link: "https://example.com/energy/\(i)",
                    guid: "energy-\(i)",
                    description: "Clean energy battery development \(i)",
                    pubDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 100)),
                    source: "Energy Digest"
                ))
            let sim = 0.30 + Double(i) * 0.04
            embeddings[id] = (0..<dim).map { idx in
                if idx % 2 == 0 {
                    return Float(sim / sqrt(Double(dim / 2)))
                } else {
                    return Float(sqrt(max(0.0, 1.0 - sim * sim)) / sqrt(Double(dim / 2)))
                }
            }
        }
        try await db.upsertArticles(articles)
        try await db.upsertArticleEmbeddings(embeddings, modelVersion: SentenceEmbedder.modelVersion)

        // Page 1
        let page1 = try await db.searchArticles(
            query: "energy research", limit: 5, queryEmbedding: queryVec)
        expectEqual(page1.count, 5, "Page 1 returns 5 articles")

        // Page 2 using cursor from page 1 last item
        let cursor1 = ArticleQueryCursor(try #require(page1.last))
        let page2 = try await db.searchArticles(
            query: "energy research", limit: 5, after: cursor1, queryEmbedding: queryVec)
        expectEqual(page2.count, 5, "Page 2 returns 5 articles")

        // Page 3
        let cursor2 = ArticleQueryCursor(try #require(page2.last))
        let page3 = try await db.searchArticles(
            query: "energy research", limit: 5, after: cursor2, queryEmbedding: queryVec)
        expectEqual(page3.count, 2, "Page 3 returns remaining 2 articles")

        let allPages = page1 + page2 + page3
        for article in allPages {
            let number = String(Int(article.id.suffix(2)) ?? -1)
            // A whole number: "report 1" must not accept a snippet of report 10 or 11.
            expectTrue(
                article.searchSnippet?.range(of: "(report|development) \(number)\\b", options: .regularExpression)
                    != nil,
                "Each snippet comes from its own story (\(article.id))")
        }
        let allIDs = allPages.map(\.id)
        expectEqual(Set(allIDs).count, 12, "Keyset pagination retrieves all 12 articles with no duplicates")
    }

    /// The excerpt a search result shows in its dek (#708): from the feed summary, else the body, only where a word
    /// matched; never from the headline (already on the card) or the publisher name; markup in publisher text stays
    /// text; the markers parse into plain and matched runs.
    static func testSearchExcerpts() async throws {
        print("  - Testing search excerpts: summary or body only, marked matches, plain text kept (#708)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        defer { Task { await db.close() } }
        func story(_ id: String, title: String, summary: String, body: String? = nil, source: String = "Desk")
            -> FeedArticle
        {
            FeedArticle(
                storedID: id, title: title, link: "https://excerpt.invalid/\(id)", guid: id, description: summary,
                pubDate: Date(timeIntervalSince1970: 1_700_000_000), source: source, fullContent: body)
        }
        try await db.upsertArticles([
            story("in-summary", title: "Budget vote", summary: "Parliament approved the glacier fund on Tuesday"),
            story(
                "in-body", title: "Mountain towns", summary: "Residents prepare for winter",
                body: "Engineers said the glacier retreat had \n\n doubled since 2010."),
            story("in-title", title: "Glacier melt", summary: "Scientists report record losses"),
            story("in-source", title: "Weather", summary: "Rain later", source: "Glacier Times"),
            story("markup", title: "Markup", summary: "A <b>bold</b> claim about the glacier"),
        ])
        let results = try await db.searchArticles(query: "glacier", limit: 10)
        func excerpt(_ id: String) -> SearchExcerpt? { results.first { $0.id == id }?.searchExcerpt }
        expectEqual(results.count, 5, "Every story matching the word is listed")
        expectEqual(
            excerpt("in-summary")?.runs,
            [
                .init(text: "Parliament approved the ", isMatch: false), .init(text: "glacier", isMatch: true),
                .init(text: " fund on Tuesday", isMatch: false),
            ], "A summary match is the excerpt, the matched word marked")
        expectEqual(
            excerpt("in-body")?.plainText, "Engineers said the glacier retreat had doubled since 2010.",
            "A body match is the excerpt when the summary has none, its line breaks one space")
        expectTrue(excerpt("in-title") == nil, "A headline-only match keeps the feed summary")
        expectTrue(excerpt("in-source") == nil, "A publisher-name match is no excerpt")
        expectEqual(
            excerpt("markup")?.plainText, "A <b>bold</b> claim about the glacier",
            "Markup in publisher text stays text and marks nothing")
        expectEqual(excerpt("markup")?.runs.filter(\.isMatch).map(\.text), ["glacier"], "Only the match is marked")

        // Parsing: stray or unbalanced markers are dropped, and an excerpt without a match is none.
        expectTrue(SearchExcerpt("no match here") == nil, "Text without a marked match is no excerpt")
        expectTrue(SearchExcerpt("\u{3}stray\u{2}") == nil, "An unopened end marker and an unclosed start mark nothing")
        expectEqual(
            SearchExcerpt("  …the \u{2}rate\u{3} rose\u{3}  ")?.runs,
            [
                .init(text: "…the ", isMatch: false), .init(text: "rate", isMatch: true),
                .init(text: " rose", isMatch: false),
            ], "Ends are trimmed and a second end marker is dropped")
    }

    static func testPureOperatorSearchRemainsLexical() async throws {
        print("  - Testing pure operator search remains purely lexical and date-ordered...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-pure-op-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = DatabaseEngine(path: directory.appendingPathComponent("pureop.sqlite3").path)
        try await db.open()
        defer { Task { await db.close() } }

        let a1 = FeedArticle(
            storedID: "op-1", title: "Alpha story", link: "https://example.com/op1",
            guid: "op-1", description: "Alpha", pubDate: Date(timeIntervalSince1970: 1_700_000_100), source: "Source"
        )
        let a2 = FeedArticle(
            storedID: "op-2", title: "Beta story", link: "https://example.com/op2",
            guid: "op-2", description: "Beta", pubDate: Date(timeIntervalSince1970: 1_700_000_200), source: "Source"
        )
        try await db.upsertArticles([a1, a2])
        // A vector aligned with the older story would lift it above the newer one if the semantic arm ran.
        let dim = SentenceEmbedder.vectorDimension
        let vector: [Float] = (0..<dim).map { $0 % 2 == 0 ? Float(1.0 / sqrt(Double(dim / 2))) : 0.0 }
        try await db.upsertArticleEmbeddings(["op-1": vector], modelVersion: SentenceEmbedder.modelVersion)

        let results = try await db.searchArticles(query: "is:unread", limit: 10, queryEmbedding: vector)
        expectEqual(results.map(\.id), ["op-2", "op-1"], "Pure operator query orders by publication date descending")
        expectTrue(results.allSatisfy { $0.searchSnippet == nil }, "Pure operator query produces no snippets")
    }
}
