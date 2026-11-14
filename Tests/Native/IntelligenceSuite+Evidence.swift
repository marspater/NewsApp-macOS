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
    /// Tests deterministic verification of overview claims, citations, numbers, units, currency,
    /// dates, negation, attribution, and fallback behavior.
    static func testDeterministicClaimVerification(fixtureHost: String) async throws {
        print("  - Testing Deterministic verification of overview claims and fallbacks...")

        let passage1 = EvidencePassage(
            id: "pass-alpha",
            articleID: "art-alpha",
            text:
                "On 15 October 2026, European Space Agency launched 42 orbital communication satellites with a total budget of $50 million.",
            ordinal: 1
        )
        let passage2 = EvidencePassage(
            id: "pass-beta",
            articleID: "art-beta",
            text:
                "The telemetry team confirmed maximum orbital speed of 100 km/h and reported zero initial hardware failures.",
            ordinal: 2
        )
        let passage3 = EvidencePassage(
            id: "pass-gamma",
            articleID: "art-gamma",
            text:
                "Ministry of Infrastructure did not approve private orbital licensing for third-party commercial operators.",
            ordinal: 3
        )
        let passage4 = EvidencePassage(
            id: "pass-delta",
            articleID: "art-delta",
            text:
                "Міністерство транспорту повідомило про успішне завершення першого етапу випробувань у вересні 2026 року.",
            ordinal: 4
        )
        let passages = [passage1, passage2, passage3, passage4]

        let article1 = FeedArticle(
            storedID: "art-alpha",
            title: "Satellites Launched",
            link: "https://\(fixtureHost)/satellites",
            guid: "g-alpha",
            description: "Launch report",
            pubDate: Date(timeIntervalSince1970: 1_700_000_000),
            source: "Space News",
            fullContent: passage1.text
        )
        let article2 = FeedArticle(
            storedID: "art-beta",
            title: "Telemetry Success",
            link: "https://\(fixtureHost)/telemetry",
            guid: "g-beta",
            description: "Telemetry report",
            pubDate: Date(timeIntervalSince1970: 1_700_001_000),
            source: "Space News",
            fullContent: passage2.text
        )
        let article3 = FeedArticle(
            storedID: "art-gamma",
            title: "Licensing Status",
            link: "https://\(fixtureHost)/licensing",
            guid: "g-gamma",
            description: "Licensing report",
            pubDate: Date(timeIntervalSince1970: 1_700_002_000),
            source: "Gov News",
            fullContent: passage3.text
        )
        let article4 = FeedArticle(
            storedID: "art-delta",
            title: "Випробування завершено",
            link: "https://\(fixtureHost)/trials",
            guid: "g-delta",
            description: "Звіт про випробування",
            pubDate: Date(timeIntervalSince1970: 1_700_003_000),
            source: "UA News",
            fullContent: passage4.text
        )
        let articles = [article1, article2, article3, article4]

        let validFact1 = PassageAnchoredFact(
            id: "f-a",
            statement:
                "ESA launched 42 orbital communication satellites on 15 October 2026 with a budget of $50 million.",
            passageID: "pass-alpha",
            quote: "launched 42 orbital communication satellites with a total budget of $50 million",
            articleID: "art-alpha"
        )
        let validFact2 = PassageAnchoredFact(
            id: "f-b",
            statement: "The telemetry team confirmed speed of 100 km/h with zero initial failures.",
            passageID: "pass-beta",
            quote:
                "telemetry team confirmed maximum orbital speed of 100 km/h and reported zero initial hardware failures",
            articleID: "art-beta"
        )
        let validFact3 = PassageAnchoredFact(
            id: "f-c",
            statement: "Ministry of Infrastructure did not approve private orbital licensing.",
            passageID: "pass-gamma",
            quote: "Ministry of Infrastructure did not approve private orbital licensing",
            articleID: "art-gamma"
        )

        // 1. Baseline: valid overview passes deterministic verification
        let baselineOverview = OverviewComposer.composeOverview(
            eventID: "event-alpha-1",
            eventTitle: "Orbital Satellite Deployment",
            verifiedFacts: [validFact1, validFact2, validFact3],
            passages: passages,
            articles: articles
        )
        let baselineReport = OverviewClaimVerifier.verifyOverview(
            baselineOverview, passages: passages, articles: articles)
        expectTrue(baselineReport.isFullyVerified, "Baseline overview with valid facts is fully verified")
        expectEqual(baselineReport.verifiedFacts.count, 3, "All 3 facts verified")
        expectTrue(baselineReport.unverifiedFacts.isEmpty, "No unverified facts in baseline")
        expectTrue(baselineReport.allFailureReasons.isEmpty, "Zero failure reasons in baseline")

        // 2. Check: Citation ID existence
        let missingCiteCitation = OverviewCitation(
            id: "cite_nonexistent",
            articleID: "art-alpha",
            passageID: "pass-alpha",
            passageFingerprint: "fp1",
            quote: "launched 42 orbital communication satellites"
        )
        let missingCiteFact = OverviewFact(
            id: "f-bad-cite", text: "ESA launched satellites", citationIDs: ["cite_ghost_id"])
        let badCiteOverview = EventOverviewDocument(
            id: "doc-bad-cite",
            eventID: "event-alpha-1",
            version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "h1"),
            content: OverviewContent(
                title: "Bad Citation Overview",
                summary: "Summary text",
                facts: [missingCiteFact],
                citations: [missingCiteCitation]
            )
        )
        let badCiteReport = OverviewClaimVerifier.verifyOverview(
            badCiteOverview, passages: passages, articles: articles)
        expectFalse(badCiteReport.isFullyVerified, "Overview with non-existent citation ID fails verification")
        expectTrue(
            badCiteReport.allFailureReasons.contains(where: {
                if case .missingCitation(let id) = $0 { return id == "cite_ghost_id" }
                return false
            }), "Report contains missingCitation reason for cite_ghost_id")

        // Check: Missing passage ID
        let ghostPassageCitation = OverviewCitation(
            id: "cite-ghost-pass",
            articleID: "art-alpha",
            passageID: "pass-ghost",
            passageFingerprint: "fp1",
            quote: "some quote"
        )
        let ghostPassageFact = OverviewFact(
            id: "f-ghost-pass", text: "Ghost passage claim", citationIDs: ["cite-ghost-pass"])
        let ghostPassOverview = EventOverviewDocument(
            id: "doc-ghost-pass",
            eventID: "event-alpha-1",
            version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "h1"),
            content: OverviewContent(
                title: "Ghost Passage",
                summary: "Summary",
                facts: [ghostPassageFact],
                citations: [ghostPassageCitation]
            )
        )
        let ghostPassReport = OverviewClaimVerifier.verifyOverview(
            ghostPassOverview, passages: passages, articles: articles)
        expectFalse(ghostPassReport.isFullyVerified, "Overview referencing missing passage ID fails verification")
        expectTrue(
            ghostPassReport.allFailureReasons.contains(where: {
                if case .missingPassage(let id) = $0 { return id == "pass-ghost" }
                return false
            }), "Report contains missingPassage reason for pass-ghost")

        // 3. Check: Supporting text in cited passage
        let unanchoredCitation = OverviewCitation(
            id: "cite-unanchored",
            articleID: "art-alpha",
            passageID: "pass-alpha",
            passageFingerprint: passage1.fingerprint,
            quote: "aliens made contact with ground stations in Kourou"
        )
        let unanchoredFact = OverviewFact(
            id: "f-unanchored", text: "Aliens contacted Earth", citationIDs: ["cite-unanchored"])
        let unanchoredOverview = EventOverviewDocument(
            id: "doc-unanchored",
            eventID: "event-alpha-1",
            version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "h1"),
            content: OverviewContent(
                title: "Unanchored",
                summary: "Summary",
                facts: [unanchoredFact],
                citations: [unanchoredCitation]
            )
        )
        let unanchoredReport = OverviewClaimVerifier.verifyOverview(
            unanchoredOverview, passages: passages, articles: articles)
        expectFalse(unanchoredReport.isFullyVerified, "Overview with quote not in passage fails verification")
        expectTrue(
            unanchoredReport.allFailureReasons.contains(where: {
                if case .unanchoredQuote(let q, _) = $0 { return q.contains("aliens") }
                return false
            }), "Report contains unanchoredQuote failure reason")

        // 4. Check: Numbers, units, currency and dates
        // 4a. Number mismatch: claim mentions 84 satellites instead of 42
        let numMismatchFact = PassageAnchoredFact(
            id: "f-num",
            statement: "ESA launched 84 orbital communication satellites.",
            passageID: "pass-alpha",
            quote: "launched 42 orbital communication satellites with a total budget of $50 million",
            articleID: "art-alpha"
        )
        let numOverview = OverviewComposer.composeOverview(
            eventID: "event-num",
            eventTitle: "Num Test",
            verifiedFacts: [numMismatchFact, validFact2, validFact3],
            passages: passages,
            articles: articles
        )
        let numReport = OverviewClaimVerifier.verifyOverview(numOverview, passages: passages, articles: articles)
        expectFalse(numReport.isFullyVerified, "Numeric mismatch (84 vs 42) fails verification")
        expectTrue(
            numReport.allFailureReasons.contains(where: {
                if case .numericMismatch(let num, _) = $0 { return num == "84" }
                return false
            }), "Report flags numericMismatch for 84")

        // 4b. Currency mismatch: claim has €50 million instead of $50 million
        let currMismatchFact = PassageAnchoredFact(
            id: "f-curr",
            statement: "The program had a total budget of €50 million.",
            passageID: "pass-alpha",
            quote: "launched 42 orbital communication satellites with a total budget of $50 million",
            articleID: "art-alpha"
        )
        let currOverview = OverviewComposer.composeOverview(
            eventID: "event-curr",
            eventTitle: "Curr Test",
            verifiedFacts: [currMismatchFact, validFact2, validFact3],
            passages: passages,
            articles: articles
        )
        let currReport = OverviewClaimVerifier.verifyOverview(currOverview, passages: passages, articles: articles)
        expectFalse(currReport.isFullyVerified, "Currency mismatch (€ vs $) fails verification")
        expectTrue(
            currReport.allFailureReasons.contains(where: {
                if case .currencyMismatch(let curr, _) = $0 { return curr == "€" || curr == "EUR" }
                return false
            }), "Report flags currencyMismatch")

        // 4c. Date mismatch: claim has 2025 instead of 2026
        let dateMismatchFact = PassageAnchoredFact(
            id: "f-date",
            statement: "The satellites were launched in October 2025.",
            passageID: "pass-alpha",
            quote: "On 15 October 2026, European Space Agency launched 42 orbital communication satellites",
            articleID: "art-alpha"
        )
        let dateOverview = OverviewComposer.composeOverview(
            eventID: "event-date",
            eventTitle: "Date Test",
            verifiedFacts: [dateMismatchFact, validFact2, validFact3],
            passages: passages,
            articles: articles
        )
        let dateReport = OverviewClaimVerifier.verifyOverview(dateOverview, passages: passages, articles: articles)
        expectFalse(dateReport.isFullyVerified, "Date mismatch (2025 vs 2026) fails verification")
        expectTrue(
            dateReport.allFailureReasons.contains(where: {
                if case .dateMismatch(let d, _) = $0 { return d.contains("2025") }
                return false
            }), "Report flags dateMismatch")

        // 4d. Unit mismatch: claim has 100 mph instead of 100 km/h
        let unitMismatchFact = PassageAnchoredFact(
            id: "f-unit",
            statement: "The telemetry team confirmed speed of 100 mph.",
            passageID: "pass-beta",
            quote:
                "telemetry team confirmed maximum orbital speed of 100 km/h and reported zero initial hardware failures",
            articleID: "art-beta"
        )
        let unitOverview = OverviewComposer.composeOverview(
            eventID: "event-unit",
            eventTitle: "Unit Test",
            verifiedFacts: [unitMismatchFact, validFact1, validFact3],
            passages: passages,
            articles: articles
        )
        let unitReport = OverviewClaimVerifier.verifyOverview(unitOverview, passages: passages, articles: articles)
        expectFalse(unitReport.isFullyVerified, "Unit mismatch (mph vs km/h) fails verification")
        expectTrue(
            unitReport.allFailureReasons.contains(where: {
                if case .unitMismatch(let u, _) = $0 { return u == "mph" }
                return false
            }), "Report flags unitMismatch")

        // 5. Check: Negation and attribution preservation
        // 5a. Negation flipped (passage has "did not approve", claim says "approved")
        let flippedNegationFact = PassageAnchoredFact(
            id: "f-neg-flip",
            statement: "Ministry of Infrastructure approved private orbital licensing for commercial operators.",
            passageID: "pass-gamma",
            quote:
                "Ministry of Infrastructure did not approve private orbital licensing for third-party commercial operators",
            articleID: "art-gamma"
        )
        let negOverview = OverviewComposer.composeOverview(
            eventID: "event-neg",
            eventTitle: "Negation Test",
            verifiedFacts: [flippedNegationFact, validFact1, validFact2],
            passages: passages,
            articles: articles
        )
        let negReport = OverviewClaimVerifier.verifyOverview(negOverview, passages: passages, articles: articles)
        expectFalse(negReport.isFullyVerified, "Flipped negation (dropped 'not') fails verification")
        expectTrue(
            negReport.allFailureReasons.contains(where: {
                if case .negationFlipped = $0 { return true }
                return false
            }), "Report flags negationFlipped")

        // 5b. Ukrainian negation flipped
        let uaFlippedFact = PassageAnchoredFact(
            id: "f-ua-neg",
            statement: "Міністерство транспорту не завершило перший етап випробувань.",
            passageID: "pass-delta",
            quote:
                "Міністерство транспорту повідомило про успішне завершення першого етапу випробувань у вересні 2026 року",
            articleID: "art-delta"
        )
        let uaOverview = OverviewComposer.composeOverview(
            eventID: "event-ua-neg",
            eventTitle: "UA Negation Test",
            verifiedFacts: [uaFlippedFact, validFact1, validFact2],
            passages: passages,
            articles: articles
        )
        let uaReport = OverviewClaimVerifier.verifyOverview(uaOverview, passages: passages, articles: articles)
        expectFalse(uaReport.isFullyVerified, "Ukrainian fabricated negation fails verification")
        expectTrue(
            uaReport.allFailureReasons.contains(where: {
                if case .negationFlipped = $0 { return true }
                return false
            }), "Report flags negationFlipped for Ukrainian text")

        // 5c. Attribution mismatch (fabricated attribution: "White House announced" when source says "Міністерство транспорту")
        let attrMismatchFact = PassageAnchoredFact(
            id: "f-attr-bad",
            statement: "The White House announced the successful completion of the first stage of trials.",
            passageID: "pass-delta",
            quote:
                "Міністерство транспорту повідомило про успішне завершення першого етапу випробувань у вересні 2026 року",
            articleID: "art-delta"
        )
        let attrOverview = OverviewComposer.composeOverview(
            eventID: "event-attr",
            eventTitle: "Attr Test",
            verifiedFacts: [attrMismatchFact, validFact1, validFact2],
            passages: passages,
            articles: articles
        )
        let attrReport = OverviewClaimVerifier.verifyOverview(attrOverview, passages: passages, articles: articles)
        expectFalse(attrReport.isFullyVerified, "Attribution mismatch fails verification")
        expectTrue(
            attrReport.allFailureReasons.contains(where: {
                if case .attributionMissing(let a, _) = $0 { return a.contains("White House") }
                return false
            }), "Report flags attributionMissing for White House")

        // 5d. Long passages (#308): checks read the matching sentence and the words around a verbatim quote.
        let longPassage = EvidencePassage(
            id: "pass-long", articleID: "art-gamma",
            text: """
                The council approved the bridge repairs on Monday. Officials did not give a reopening date. \
                “We will go on with the work,” Kovalenko said after the vote.
                """)
        let longPassages = passages + [longPassage]
        func failures(_ statement: String) -> [ClaimVerificationFailureReason] {
            let fact = PassageAnchoredFact(
                id: "f-long", statement: statement, passageID: longPassage.id, quote: longPassage.text,
                articleID: "art-gamma")
            let overview = OverviewComposer.composeOverview(
                eventID: "event-long", eventTitle: "Long passage", verifiedFacts: [fact, validFact1, validFact2],
                passages: longPassages, articles: articles)
            return OverviewClaimVerifier.verifyOverview(overview, passages: longPassages, articles: articles)
                .allFailureReasons
        }
        func flagged(_ reasons: [ClaimVerificationFailureReason], negation: Bool) -> Bool {
            reasons.contains {
                switch $0 {
                case .negationFlipped: negation
                case .attributionMissing: !negation
                default: false
                }
            }
        }
        expectFalse(
            flagged(failures("The council approved the bridge repairs on Monday."), negation: true),
            "A negation elsewhere in the passage does not flag a faithful positive sentence")
        expectTrue(
            flagged(failures("Officials gave a reopening date."), negation: true),
            "Dropping the negation of the matching sentence is still flagged")
        expectTrue(
            flagged(failures("The council didn't approve the bridge repairs on Monday."), negation: true),
            "A contracted negation counts as a negation")
        expectFalse(
            flagged(failures("“We will go on with the work,” Kovalenko said after the vote."), negation: false),
            "Punctuation around a verbatim quote does not hide its speaker")
        expectTrue(
            flagged(failures("The governor said the work will go on."), negation: false),
            "A speaker absent from the passage is still flagged")

        // 5e. Detached quotations (#308): unframed questions and unattributed first-person quotes.
        let quotePassage = EvidencePassage(
            id: "pass-quote", articleID: "art-gamma",
            text:
                "At the research station, Dr. Clara Oswald called the equipment activation at 6:29am \"the minute that changed our lives forever\".",
            ordinal: 2)
        let pikePassage = EvidencePassage(
            id: "pass-dialogue", articleID: "art-gamma",
            text:
                "‘Where am I and who are you?’ Those were the first words patient Jordan Cole spoke after regaining consciousness, according to the attending physician.",
            ordinal: 3)
        func checkClaim(_ statement: String, passage: EvidencePassage) -> (
            failures: [ClaimVerificationFailureReason], audit: ClaimAuditResult
        ) {
            let fact = PassageAnchoredFact(
                id: "f-chk", statement: statement, passageID: passage.id, quote: passage.text, articleID: "art-gamma")
            let overview = OverviewComposer.composeOverview(
                eventID: "event-chk", eventTitle: "Quote test", verifiedFacts: [fact],
                passages: [passage], articles: articles)
            let f = OverviewClaimVerifier.verifyOverview(overview, passages: [passage], articles: articles)
                .allFailureReasons
            let of = OverviewFact(id: "f-chk", text: statement, citationIDs: [passage.id])
            let cite = OverviewCitation(
                id: passage.id, articleID: passage.articleID, passageID: passage.id,
                passageFingerprint: passage.fingerprint, quote: passage.text)
            let a = OverviewQualityAuditor.auditClaim(of, citations: [passage.id: cite], passages: [passage])
            return (f, a)
        }

        let detached1 = checkClaim(
            "the activation at 6:29am \"the minute that changed our lives forever\"",
            passage: quotePassage)
        expectTrue(
            detached1.failures.contains(where: {
                if case .detachedQuotation = $0 { return true }
                return false
            }), "Detached first-person quote without attributing speaker is flagged by verifier")
        expectEqual(
            detached1.audit.criticalErrorKind, .attributionError,
            "Detached first-person quote is flagged as critical attribution error by auditor")

        let detached2 = checkClaim("‘Where am I and who are you?’", passage: pikePassage)
        expectTrue(
            detached2.failures.contains(where: {
                if case .detachedQuotation = $0 { return true }
                return false
            }), "Standalone unframed dialogue/question quote is flagged by verifier")
        expectEqual(
            detached2.audit.criticalErrorKind, .attributionError,
            "Standalone quote is flagged as critical attribution error by auditor")

        let validQuote1 = checkClaim(
            "Dr. Clara Oswald called the equipment activation at 6:29am \"the minute that changed our lives forever\".",
            passage: quotePassage)
        expectFalse(
            validQuote1.failures.contains(where: {
                if case .detachedQuotation = $0 { return true }
                return false
            }), "Attributed quote with speaker is not flagged as detached quote")
        expectEqual(validQuote1.audit.status, .supported, "Attributed quote with speaker is supported by auditor")

        let stationPassage = EvidencePassage(
            id: "pass-station", articleID: "art-gamma",
            text:
                "Station director Mara Lind said: “We will not leave the station.” The council's plan passed on Thursday.",
            ordinal: 9)
        func isDetached(_ statement: String) -> Bool {
            checkClaim(statement, passage: stationPassage).failures.contains {
                if case .detachedQuotation = $0 { return true }
                return false
            }
        }
        expectTrue(isDetached("He said: “We will not leave the station.”"), "A pronoun does not identify the speaker")
        expectTrue(
            isDetached("“I said we will not leave the station” on Thursday."),
            "A reporting verb inside the quotation does not attribute it")
        expectFalse(
            isDetached("Station director Mara Lind said: “We will not leave the station.”"),
            "A named speaker outside the quotation attributes it")
        expectFalse(isDetached("The council's plan passed on Thursday."), "Apostrophes are not quotation marks")

        // 5f. Dropped speaker attribution (#308): motives, military claims, and contested positions.
        let motivePassage = EvidencePassage(
            id: "pass-motive", articleID: "art-gamma",
            text:
                "Regional Commissioner Alan Grey said Thursday's move to downsize the field presence had followed a dialogue with municipal leadership in order to avoid an escalation of tensions between the two departments.",
            ordinal: 4)
        let droppedMotive = checkClaim(
            "The move to downsize the field presence had followed a dialogue with municipal leadership in order to avoid an escalation of tensions between the two departments.",
            passage: motivePassage)
        expectTrue(
            droppedMotive.failures.contains(where: {
                if case .droppedAttribution = $0 { return true }
                return false
            }), "Dropping speaker attribution on administrative motive is flagged by verifier")
        expectEqual(
            droppedMotive.audit.criticalErrorKind, .attributionError,
            "Dropping speaker on motive is flagged as critical attribution error")

        let validMotive = checkClaim(
            "Regional Commissioner Alan Grey said Thursday's move had followed a dialogue with municipal leadership in order to avoid an escalation of tensions between the two departments.",
            passage: motivePassage)
        expectFalse(
            validMotive.failures.contains(where: {
                if case .droppedAttribution = $0 { return true }
                return false
            }), "Preserving speaker on motive passes verifier")
        expectEqual(validMotive.audit.status, .supported, "Preserving speaker on motive is supported by auditor")

        let militaryPassage = EvidencePassage(
            id: "pass-mil", articleID: "art-gamma",
            text:
                "The spokesperson for the coalition command, General Jordan Cole, said forces intercepted a drone north of the perimeter and destroyed a platform in the northern valley.",
            ordinal: 5)
        let droppedMil = checkClaim(
            "forces intercepted a drone north of the perimeter and destroyed a platform in the northern valley.",
            passage: militaryPassage)
        expectTrue(
            droppedMil.failures.contains(where: {
                if case .droppedAttribution = $0 { return true }
                return false
            }), "Dropping coalition spokesperson on military interception is flagged by verifier")
        expectEqual(
            droppedMil.audit.criticalErrorKind, .attributionError,
            "Dropping spokesperson on military claim is critical error in auditor")

        let validMil = checkClaim(
            "Coalition spokesman General Jordan Cole said forces intercepted a drone north of the perimeter and destroyed a platform in the northern valley.",
            passage: militaryPassage)
        expectFalse(
            validMil.failures.contains(where: {
                if case .droppedAttribution = $0 { return true }
                return false
            }), "Retaining coalition spokesperson passes verifier")
        expectEqual(validMil.audit.status, .supported, "Retaining coalition spokesperson is supported by auditor")

        let genericMil = checkClaim(
            "Officials said forces intercepted a drone north of the perimeter and destroyed a platform in the northern valley.",
            passage: militaryPassage)
        expectTrue(
            genericMil.failures.contains(where: {
                if case .droppedAttribution(let speaker, _, _) = $0 { return speaker == "General Jordan Cole" }
                return false
            }), "Generic officials do not stand in for the named spokesperson")
        expectEqual(
            genericMil.audit.criticalErrorKind, .attributionError,
            "Generic officials in place of the named spokesperson are a critical error in auditor")

        // 5g. Citation grounding (#308): a place the cited passage never names is unsupported.
        let inquiryPassage = EvidencePassage(
            id: "pass-inquiry", articleID: "art-gamma",
            text:
                "Ms. Elena Varma travelled to Singapore on September 16 for medical treatment. She returned after filing a court petition seeking to prevent her detention, the agency reported.",
            ordinal: 7)
        let mismatchArrest = checkClaim(
            "Sri Lanka arrests former director Varma in corruption inquiry", passage: inquiryPassage)
        expectTrue(
            mismatchArrest.failures.contains(where: {
                if case .ungroundedCitation(let token, _) = $0 { return token == "sri lanka" }
                return false
            }), "Citing passage lacking 'Sri Lanka' flags ungroundedCitation")
        expectEqual(
            mismatchArrest.audit.status,
            .unsupported(reason: "Claim names place 'sri lanka' not mentioned in cited passage"),
            "Citing passage lacking 'Sri Lanka' is unsupported in auditor")

        let abbreviatedPlace = checkClaim(
            "US President Donald Trump said on Wednesday that he should win the prize.",
            passage: EvidencePassage(
                id: "pass-us", articleID: "art-gamma",
                text: "U.S. President Donald Trump said on Wednesday that he should win the prize.", ordinal: 6))
        expectFalse(
            abbreviatedPlace.failures.contains(where: {
                if case .ungroundedCitation = $0 { return true }
                return false
            }), "US matches U.S. in the cited passage")

        // 5h. Valid controls: ordinary reported facts without attribution wrappers pass cleanly (#308)
        let plainFactPassage = EvidencePassage(
            id: "pass-plain", articleID: "art-gamma",
            text: "The bridge reopened on Monday after repairs costing $4m.",
            ordinal: 8)
        let plainFact = checkClaim(
            "The bridge reopened on Monday after repairs costing $4m.", passage: plainFactPassage)
        expectTrue(
            plainFact.failures.isEmpty,
            "Ordinary reported fact without attribution wrapper passes verifier with zero failures")
        expectEqual(plainFact.audit.status, .supported, "Ordinary reported fact is supported by auditor")
    }

    /// #547: ten verifier controls, five wrong claims and five valid ones, accepted only when both deterministic gates
    /// of a drafted sentence (the verifier, then `auditClaim`) pass. The six kinds named in the 10 October review
    /// (renamed speaker, actor taken for speaker, reporting verb inside a quotation, arrest for summons; unrelated
    /// speech elsewhere in the sentence, a word inside another word) plus four ordinary controls.
    static func testOverviewVerifierControls() {
        print("  - Testing the ten overview verifier controls (#547)...")
        let article = FeedArticle(
            storedID: "art-ctrl", title: "Controls", link: "https://example.com/controls", guid: "art-ctrl",
            description: "", pubDate: Date(), source: "Control Wire")
        func accepted(_ claim: String, _ passageText: String) -> Bool {
            let passage = EvidencePassage(id: "pass-ctrl", articleID: "art-ctrl", text: passageText, ordinal: 1)
            let citation = OverviewCitation(
                id: passage.id, articleID: passage.articleID, passageID: passage.id,
                passageFingerprint: passage.fingerprint, quote: passage.text)
            let fact = OverviewFact(id: "f-ctrl", text: claim, citationIDs: [passage.id])
            let document = OverviewComposer.composeOverview(
                eventID: "event-ctrl", eventTitle: "Controls",
                verifiedFacts: [
                    PassageAnchoredFact(
                        id: "f-ctrl", statement: claim, passageID: passage.id, quote: passage.text,
                        articleID: article.id)
                ], passages: [passage], articles: [article])
            let verified = OverviewClaimVerifier.verifyOverview(document, passages: [passage], articles: [article])
            let audit = OverviewQualityAuditor.auditClaim(fact, citations: [passage.id: citation], passages: [passage])
            return verified.isFullyVerified && audit.isSupported
        }
        let tariffs =
            "Ontario Premier Doug Ford met Prime Minister Mark Carney in Ottawa on Monday. Ford said the tariffs would cost Ontario 100,000 jobs."
        let convoy = "The Israeli military said Hamas fighters attacked an aid convoy near Rafah on Tuesday."
        let pokrovsk =
            "Ukraine's army chief visited the front on Monday. \"We will not give up Pokrovsk,\" the commander said, \"whatever it costs.\""
        let summons = "Prosecutors summoned former minister Ivan Petrov for questioning on Wednesday."
        let evacuation = "Firefighters evacuated 140 residents from the valley on Sunday."
        let drones =
            "Air defences shot down 45 of 50 drones overnight, while Kyiv Mayor Vitali Klitschko said debris fell on two districts."
        let ban = "The Supreme Court reinstated the export ban on Tuesday after a two-week suspension."
        let ministry =
            "According to the health ministry, 1,200 people were treated in hospitals during the heatwave in July 2026."

        let controls: [(name: String, claim: String, passage: String, expected: Bool)] = [
            ("renamed speaker", "Carney said the tariffs would cost Ontario 100,000 jobs.", tariffs, false),
            (
                "actor taken for speaker", "Hamas said its fighters attacked an aid convoy near Rafah on Tuesday.",
                convoy, false
            ),
            (
                "reporting verb inside a quotation",
                "Ukraine \"will not give up Pokrovsk, the commander said,\" whatever it costs.", pokrovsk, false
            ),
            ("arrest for summons", "Prosecutors arrested former minister Ivan Petrov on Wednesday.", summons, false),
            (
                "number inside a number", "Firefighters evacuated 14 residents from the valley on Sunday.", evacuation,
                false
            ),
            ("unrelated speech in the sentence", "Air defences shot down 45 of 50 drones overnight.", drones, true),
            ("word inside a word", "The Supreme Court reinstated the export ban on Tuesday.", ban, true),
            ("speaker kept", "Ford said the tariffs would cost Ontario 100,000 jobs.", tariffs, true),
            (
                "according to",
                "According to the health ministry, 1,200 people were treated in hospitals during the heatwave.",
                ministry, true
            ),
            ("plain fact", "Prosecutors summoned former minister Ivan Petrov for questioning.", summons, true),
        ]
        let mismatches = controls.filter { accepted($0.claim, $0.passage) != $0.expected }.map(\.name)
        expectEqual(mismatches, [], "All ten verifier controls match")
        // A quoted assessment copied without its quotation marks or speaker reads as fact (#547 claim review).
        let election =
            "\"These are the first elections since Vucic came to power in 2012 that are competitive,\" political scientist Dusan Spasojevic told DW."
        expectFalse(
            accepted("These are the first elections since Vucic came to power in 2012 that are competitive.", election),
            "A quotation restated as fact is rejected")
        expectTrue(
            accepted(
                "Political scientist Dusan Spasojevic said these are the first elections since Vucic came to power in 2012 that are competitive.",
                election), "The same words with their speaker are accepted")
        let metStatement =
            "In a statement, a Metropolitan police spokesperson said: \u{201C}Following a review of our records, we have confirmed that in January 2019 we received a letter."
        expectFalse(
            accepted(
                "Following a review of our records, we have confirmed that in January 2019 we received a letter.",
                metStatement),
            "First-person speech without quotation marks or speaker is rejected")
        expectTrue(
            accepted(
                "The US envoy received a letter in January 2019.", "The US envoy received a letter in January 2019."),
            "\"US\" is not a first-person pronoun")
    }

    static func testOverviewTimeline(fixtureHost: String) async throws {
        print("  - Testing sourced overview timelines: stated dates, unknown years, plans and citations (#143)...")
        let utc = try #require(TimeZone(identifier: "UTC"))
        func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = utc
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        func article(_ id: String, _ source: String, published: Date) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Report \(id)", link: "https://\(fixtureHost)/\(id)", guid: id,
                description: "", pubDate: published, source: source)
        }
        let wire = article("tl-wire", "Wire", published: day(2026, 10, 1))
        let daily = article("tl-daily", "Daily", published: day(2026, 10, 1, hour: 18))
        let undated = article("tl-undated", "Undated", published: DateParser.unknownDate)
        let articles = [wire, daily, undated]
        var passages: [EvidencePassage] = []
        func fact(_ article: FeedArticle, _ text: String) -> PassageAnchoredFact {
            let passage = EvidencePassage(
                id: "\(article.id)_p\(passages.count + 1)", articleID: article.id, text: text,
                ordinal: passages.count + 1)
            passages.append(passage)
            return PassageAnchoredFact(
                id: "f-\(passage.id)", statement: text, passageID: passage.id, quote: text, articleID: article.id)
        }
        let announced = "On 15 September 2026, the ministry announced the flood defence plan."
        let facts = [
            fact(wire, "Parliament is scheduled to vote on the plan on 20 October."),
            fact(wire, announced),
            fact(daily, announced),
            fact(daily, "The storm hit the coast on Monday, flooding 300 homes."),
            fact(daily, "The ruling on 3 March overturned a 12 June 2024 decision."),
            fact(undated, "On 1 October 2026, officials met the regional council."),
            fact(wire, "The defence programme began in March 2019 after earlier floods."),
        ]
        let english = Locale(identifier: "en_US")
        let timeline = OverviewTimelineBuilder.build(
            facts: facts, passages: passages, articles: articles, locale: english)
        expectEqual(
            timeline.items.map(\.summary), [facts[6].quote, announced, facts[0].quote],
            "Dated sentences appear once, in event order; weekdays, several dates and unknown publication dates stay out"
        )
        expectEqual(
            timeline.items.map(\.isFuturePlan), [false, false, true], "A date after publication is labeled as a plan")
        expectTrue(
            timeline.items[0].dateText.contains("2019") && !timeline.items[0].dateText.contains("15"),
            "A month-precision date is shown at month precision: \(timeline.items[0].dateText)")
        expectTrue(timeline.items[1].dateText.contains("2026"), "A stated year is shown: \(timeline.items[1].dateText)")
        expectFalse(
            timeline.items[2].dateText.contains("2026"), "A missing year stays missing: \(timeline.items[2].dateText)")
        expectEqual(
            timeline.items[1].citationIDs.count, 2, "Reprints of one sentence become one item with both sources")
        let citations = Dictionary(uniqueKeysWithValues: timeline.citations.map { ($0.id, $0) })
        for item in timeline.items {
            expectFalse(item.citationIDs.isEmpty, "Every timeline item has a source")
            for id in item.citationIDs {
                guard let citation = citations[id] else { return expectTrue(false, "Timeline citation \(id) exists") }
                expectEqual(citation.quote, item.summary, "The item reproduces its cited quote")
                expectTrue(
                    citation.publishedAt == wire.pubDate || citation.publishedAt == daily.pubDate,
                    "The publication date stays on the citation, apart from the event date")
            }
        }
        expectEqual(Set(timeline.citations.map(\.id)).count, timeline.citations.count, "Citation IDs are unique")

        let single = OverviewTimelineBuilder.build(facts: [facts[1], facts[3]], passages: passages, articles: articles)
        expectTrue(single.items.isEmpty && single.citations.isEmpty, "One dated sentence is not a timeline")
        let sameDay = [
            fact(wire, "On 2 September 2026, the dam was inspected."),
            fact(daily, "Engineers reported cracks on 2 September 2026."),
        ]
        expectTrue(
            OverviewTimelineBuilder.build(facts: sameDay, passages: passages, articles: articles).items.isEmpty,
            "Two sentences on one date are not a timeline")

        typealias Stated = OverviewTimelineBuilder.StatedDate
        func stated(_ sentence: String) -> Stated? { OverviewTimelineBuilder.singleStatedDate(in: sentence) }
        expectTrue(stated("Police said 3 may have died.") == nil, "The modal verb may is not a month")
        expectTrue(stated("NASA sent 3 Mars landers.") == nil, "A capitalized planet is not the French month")
        expectTrue(stated("On 31 April the agency said nothing.") == nil, "An impossible date is not placed")
        expectEqual(
            stated("Sept. 5, 2025 was the deadline."), Stated(year: 2025, month: 9, day: 5), "Abbreviated English dates"
        )
        expectEqual(
            stated("Le 3 mars 2026, le gouvernement a annoncé un plan."), Stated(year: 2026, month: 3, day: 3),
            "French dates")
        expectEqual(
            stated("Am 3. März 2026 trat das Gesetz in Kraft."), Stated(year: 2026, month: 3, day: 3), "German dates")
        expectEqual(
            stated("3 березня 2026 року уряд ухвалив рішення."), Stated(year: 2026, month: 3, day: 3), "Ukrainian dates"
        )
        expectEqual(stated("Rząd przyjął ustawę 1 maja 2026 r."), Stated(year: 2026, month: 5, day: 1), "Polish dates")
        expectEqual(
            stated("The programme began in March 2019."), Stated(year: 2019, month: 3, day: nil), "Month and year")

        let newYear = day(2027, 1, 2)
        let lateDecember = Stated(year: nil, month: 12, day: 30)
        expectEqual(
            OverviewTimelineBuilder.resolve(lateDecember, publishedAt: newYear), day(2026, 12, 30, hour: 0),
            "A missing year is placed nearest to publication")
        expectFalse(
            OverviewTimelineBuilder.isPlan(lateDecember, resolved: day(2026, 12, 30, hour: 0), publishedAt: newYear),
            "A date before publication is not a plan")
        let october = Stated(year: 2026, month: 10, day: nil)
        expectFalse(
            OverviewTimelineBuilder.isPlan(october, resolved: day(2026, 10, 1, hour: 0), publishedAt: wire.pubDate),
            "The month of publication is not a plan")
        expectTrue(
            OverviewTimelineBuilder.isPlan(
                Stated(year: 2026, month: 11, day: nil), resolved: day(2026, 11, 1, hour: 0),
                publishedAt: wire.pubDate), "A later month is a plan")

        let composed = OverviewComposer.composeOverview(
            eventID: "event-timeline", eventTitle: "Flood defence plan",
            verifiedFacts: facts, passages: passages, articles: articles)
        expectEqual(composed.timeline.count, 3, "Composed overviews carry the timeline")
        expectTrue(
            composed.timeline.allSatisfy { $0.citationIDs.allSatisfy { composed.citations[$0] != nil } },
            "Timeline citations are stored with the overview")
        expectEqual(
            composed.analysisVersion, EventOverviewDocument.currentAnalysisVersion,
            "Timelines bump the analysis version")
        let undatedOverview = OverviewComposer.composeOverview(
            eventID: "event-undated", eventTitle: "Storm",
            verifiedFacts: [facts[3]], passages: [passages[3]], articles: articles)
        expectTrue(undatedOverview.timeline.isEmpty, "Without dated publisher sentences the timeline is absent")
    }

    /// #1241: the builder keeps sourced anchors (time of day, relative day, quarter) with their own kind, in source
    /// order of time, never as a calendar date; a bare "scheduled" is no date; extractor-shaped stored items still read.
    static func testOverviewTimelineAnchors(fixtureHost: String) throws {
        print(
            "  - Testing timeline anchors: time of day, relative days, quarters and legacy extractor items (#1241)...")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let published = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12)))
        let article = FeedArticle(
            storedID: "anchor-a", title: "Quake report", link: "https://\(fixtureHost)/anchor-a", guid: "anchor-a",
            description: "", pubDate: published, source: "Wire")
        let sentences = [
            "Retrofitting is scheduled to begin in the second quarter of 2027.",
            "The quake struck at 06:14 UTC along the coast.",
            "Rescuers reached the town yesterday morning.",
            "The ceasefire took effect on 3 November.",
            "Work is scheduled to resume soon.",
            "On 4 November at 09:00 UTC the port closed.",
            "Aid arrived last night and again this morning.",
        ]
        let passages = sentences.enumerated().map {
            EvidencePassage(id: "anchor-p\($0.offset)", articleID: article.id, text: $0.element, ordinal: $0.offset)
        }
        let facts = passages.map {
            PassageAnchoredFact(
                id: "f-\($0.id)", statement: $0.text, passageID: $0.id, quote: $0.text, articleID: article.id)
        }
        let built = OverviewTimelineBuilder.build(
            facts: facts, passages: passages, articles: [article], locale: Locale(identifier: "en_US")
        ).items
        let items = EventOverviewReaderView.sortTimelineItems(built)
        func label(_ item: OverviewTimelineItem) -> String {
            EventOverviewReaderView.timelineItemAccessibilityLabel(item: item)
        }
        expectEqual(
            items.map(\.summary), [sentences[3], sentences[5], sentences[2], sentences[1], sentences[0]],
            "Anchors keep their place in time beside stated dates; a placeholder and two anchors in one sentence stay out"
        )
        expectEqual(
            items.map(\.dateKind), [.stated, .stated, .anchor, .anchor, .anchor],
            "A sentence with a calendar date is stated even when it also names a time")
        expectEqual(
            items.map(\.dateText).suffix(3), ["Yesterday morning", "06:14 UTC", "Second quarter of 2027"],
            "Anchors are shown in the source's words")
        guard items.count == 5 else { return }
        let reportedText = published.formatted(date: .abbreviated, time: .omitted)
        let time = items[3]
        expectEqual(time.publicationDate, published, "An anchor carries the day it is relative to")
        expectEqual(time.eventDate, nil, "An anchor is never an event date")
        expectEqual(
            label(time), "06:14 UTC. Reported \(reportedText). The quake struck at 06:14 UTC along the coast",
            "A time of day reads as stated, with the day it was reported")
        expectFalse(
            EventOverviewReaderView.timelineDateDisplay(for: time).isStated, "An anchor draws the outlined marker")
        expectEqual(
            items[2].orderingDateMayHoldInferredYear, calendar.date(byAdding: .day, value: -1, to: published),
            "Yesterday is ordered on the day before publication")
        expectTrue(items[4].isFuturePlan, "A later quarter in a plan sentence is a plan")
        expectTrue(
            label(items[4]).hasPrefix("Second quarter of 2027. Planned."), "A plan anchor keeps its wording and Planned"
        )
        expectEqual(
            OverviewTimelineBuilder.anchor(in: "Talks are scheduled to resume.", publishedAt: published), nil,
            "A bare scheduled is not a date")

        // Parity with the former extractor (#1241 review): its relative, quarter and plan-year anchors.
        func anchorText(_ sentence: String) -> String? {
            OverviewTimelineBuilder.anchor(in: sentence, publishedAt: published)?.text
        }
        expectEqual(
            anchorText("Officials met earlier this week to agree terms."), "Earlier this week", "Earlier this week")
        let yearless = OverviewTimelineBuilder.anchor(
            in: "Retrofitting is scheduled for the second quarter.", publishedAt: published)
        expectEqual(yearless?.text, "Second quarter", "A plan's quarter without a year keeps its wording, no year")
        expectTrue(yearless?.isPlan == true, "A plan's quarter without a year is a plan")
        expectEqual(anchorText("Sales fell in the second quarter."), nil, "A quarter without a year needs a plan")
        expectEqual(anchorText("The plant is expected to open in 2028."), "In 2028", "A plan's later year")
        expectEqual(anchorText("The company plans to cut 2040 jobs."), nil, "A count in a plan sentence is no year")
        expectEqual(anchorText("The utility plans to close the plant by 2035."), "By 2035", "A plan year after by")
        expectEqual(
            anchorText("The ministry plans to keep the cap until 2030."), "Until 2030", "A plan year after until")
        expectEqual(anchorText("The 2024 decision still stands."), nil, "A bare year outside a plan is no anchor")
        expectEqual(anchorText("The vote at 09:00 UTC followed talks last night."), nil, "Two anchors are ambiguous")

        // Time of day: the ordering value is a provisional placement at publication, never the time it happened,
        // and nothing shows it; the source's wording is what reads.
        let ordering = time.orderingDateMayHoldInferredYear
        expectEqual(ordering, published, "A time of day is placed at publication, not at 06:14")
        let orderingClock = published.formatted(date: .omitted, time: .shortened)
        let display = EventOverviewReaderView.timelineDateDisplay(for: time)
        expectEqual(display.primary, "06:14 UTC", "The row shows the source's time")
        expectFalse(label(time).contains(orderingClock), "VoiceOver never reads the placement time \(orderingClock)")
        expectEqual(BriefingTimelineData.orderingDate(of: time), nil, "Briefing never places a time of day")
        expectEqual(
            BriefingTimelineData.items(items, now: published)?.contains { $0.id == time.id } ?? false, false,
            "Briefing rows leave it out")
        let twoTimes = ["The first quake struck at 06:14 UTC.", "A second quake struck at 09:30 UTC."].enumerated().map
        {
            PassageAnchoredFact(
                id: "t\($0.offset)", statement: $0.element, passageID: "anchor-p\($0.offset)", quote: $0.element,
                articleID: article.id)
        }
        expectEqual(
            OverviewTimelineBuilder.build(facts: twoTimes, passages: passages, articles: [article]).items.map(
                \.dateText),
            ["06:14 UTC", "09:30 UTC"], "Two times of one day are two items, in the order the source gives them")

        // Anchor reprints merge, and one wording from two publications is one distinct date, not two.
        let later = FeedArticle(
            storedID: "anchor-b", title: "Quake follow-up", link: "https://\(fixtureHost)/anchor-b", guid: "anchor-b",
            description: "", pubDate: published.addingTimeInterval(5 * 3600), source: "Daily")
        let reprint = "The quake struck at 06:14 UTC along the coast."
        let morning = ["Rescuers arrived this morning.", "Aid convoys left this morning."]
        func fact(_ id: String, _ text: String, _ source: FeedArticle) -> PassageAnchoredFact {
            PassageAnchoredFact(id: id, statement: text, passageID: "p-\(id)", quote: text, articleID: source.id)
        }
        let merged = OverviewTimelineBuilder.build(
            facts: [fact("r1", reprint, article), fact("r2", reprint, later), fact("d1", sentences[3], article)],
            passages: [], articles: [article, later])
        expectEqual(merged.items.count, 2, "A reprinted anchor sentence is one item")
        expectEqual(merged.items.last?.citationIDs.count, 2, "The reprinted anchor keeps both sources")
        expectTrue(
            OverviewTimelineBuilder.build(
                facts: [fact("m1", morning[0], article), fact("m2", morning[1], later)], passages: [],
                articles: [article, later]
            ).items.isEmpty, "The same anchor wording from two publications is one date, not a timeline")

        // A stored extractor row whose yearless date was parsed with the day as year (0002) neither orders nor counts.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let misparsed = try #require(utc.date(from: DateComponents(year: 2, month: 11, day: 1)))
            .timeIntervalSinceReferenceDate
        let storedRow = """
            {"id":"tl_x","dateText":"November 2","summary":"Talks resumed.","citationIDs":["c"],"isFuturePlan":false,
             "eventDate":\(misparsed),"publicationDate":\(published.timeIntervalSinceReferenceDate)}
            """
        let misparsedItem = try JSONDecoder().decode(OverviewTimelineItem.self, from: Data(storedRow.utf8))
        expectEqual(misparsedItem.eventDate, nil, "A legacy event date in year 2 is dropped at decode")
        expectEqual(misparsedItem.dateText, "November 2", "The stated text stays")
        expectEqual(
            BriefingTimelineData.orderingDate(of: misparsedItem), nil,
            "Briefing neither orders it by year 2 nor by its publication date")
        let current = OverviewTimelineItem(
            id: "c", dateText: "Nov 2", summary: "x", eventDate: Date(timeIntervalSinceReferenceDate: misparsed))
        let reencoded = try JSONDecoder().decode(OverviewTimelineItem.self, from: JSONEncoder().encode(current))
        expectTrue(reencoded.eventDate != nil, "An item with a kind keeps its event date as stored")

        // Legacy classification lives with the model (no builder dependency) and is the builder's definition.
        for text in [
            "Yesterday Morning", "06:14 UTC", "Second Quarter Of 2027", "Q2 2027", "in 2027", "By 2035", "Until 2030",
            "Earlier This Week",
        ] {
            expectTrue(OverviewTimelineItem.isAnchorText(text), "Legacy anchor text: \(text)")
        }
        for text in ["15 October 2026", "Oct 3", "Scheduled", "October 2026", ""] {
            expectFalse(OverviewTimelineItem.isAnchorText(text), "Not an anchor: \(text)")
        }

        // Items the former extractor stored before #1241: no kind, its capitalized anchors and its placeholder.
        let reference = published.timeIntervalSinceReferenceDate
        let legacyJSON = """
            [{"id":"tl_1","dateText":"Yesterday Morning","summary":"Rescuers reached the town.","citationIDs":["c"],
              "isFuturePlan":false,"publicationDate":\(reference)},
             {"id":"tl_2","dateText":"Scheduled","summary":"Work will resume.","citationIDs":["c"],
              "isFuturePlan":true,"publicationDate":\(reference)},
             {"id":"tl_3","dateText":"15 October 2026","summary":"Teams deployed.","citationIDs":["c"],
              "isFuturePlan":false,"eventDate":\(reference),"publicationDate":\(reference)}]
            """
        let legacy = try JSONDecoder().decode([OverviewTimelineItem].self, from: Data(legacyJSON.utf8))
        expectEqual(
            legacy.map(\.dateKind), [.anchor, .stated, .stated], "Legacy anchors are anchors, dates are stated")
        expectEqual(
            legacy.map(label),
            [
                "Yesterday Morning. Reported \(reportedText). Rescuers reached the town",
                "Planned. Work will resume",
                "15 October 2026. Reported \(reportedText). Teams deployed",
            ],
            "Legacy anchors and dates read as stated; the placeholder is dropped and only the publication date reads Reported"
        )
        expectEqual(
            BriefingTimelineData.orderingDate(of: legacy[0]), nil, "Briefing leaves a relative anchor out")
    }

    /// #1249: a range or list of dates in one phrase is one row and one span; unrelated dates stay out.
    static func testOverviewTimelineRanges(fixtureHost: String) throws {
        print("  - Testing timeline ranges and lists: one row, one span, as stated (#1249)...")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        let published = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12)))
        let article = FeedArticle(
            storedID: "range-a", title: "Vote report", link: "https://\(fixtureHost)/range-a", guid: "range-a",
            description: "", pubDate: published, source: "Wire")
        let english = Locale(identifier: "en_US")
        let before = "The council was formed on 15 September 2026."
        func items(_ sentences: [String]) -> [OverviewTimelineItem] {
            let passages = sentences.enumerated().map {
                EvidencePassage(id: "range-p\($0.offset)", articleID: article.id, text: $0.element, ordinal: $0.offset)
            }
            let facts = passages.map {
                PassageAnchoredFact(
                    id: "f-\($0.id)", statement: $0.text, passageID: $0.id, quote: $0.text, articleID: article.id)
            }
            return OverviewTimelineBuilder.build(
                facts: facts, passages: passages, articles: [article], locale: english
            ).items
        }
        // Foundation separates a range with thin spaces; compare with plain ones.
        func shown(_ item: OverviewTimelineItem?) -> String? {
            item?.dateText.replacingOccurrences(of: "\u{2009}", with: " ").replacingOccurrences(
                of: "\u{202F}", with: " ")
        }
        func range(_ sentence: String) -> OverviewTimelineItem? {
            let built = items([before, sentence])
            expectEqual(built.count, 2, "A range with a date outside it is a timeline: \(sentence)")
            return built.last
        }

        let withYear = range("Voting is open from February 8 to February 28, 2027.")
        expectEqual(shown(withYear), "Feb 8 – 28, 2027", "A range with a year is one row, the year written once")
        expectEqual(withYear?.isFuturePlan, true, "A range starting after publication is a plan")
        expectEqual(withYear?.datePrecision, .range, "A range has range precision; its text keeps the stated parts")
        expectEqual(withYear?.orderingDateMayHoldInferredYear, day(2027, 2, 8), "It orders on its start")
        expectEqual(withYear?.orderingEndDateMayHoldInferredYear, day(2027, 2, 28), "Its span ends on its last day")

        let noYear = range("Voting ran from October 27 to November 1.")
        expectEqual(shown(noYear), "Oct 27 – Nov 1", "A range without a year shows no year")
        expectEqual(
            noYear?.orderingDateMayHoldInferredYear, day(2026, 10, 27), "The year only orders: nearest publication")
        expectEqual(noYear?.orderingEndDateMayHoldInferredYear, day(2026, 11, 1), "The end shares the start's year")
        expectEqual(noYear?.isFuturePlan, false, "A range that started before publication is no plan")

        let crossYear = range("The window runs from Dec 28 to Jan 3.")
        expectEqual(shown(crossYear), "Dec 28 – Jan 3", "A range across a year shows neither year")
        expectEqual(
            crossYear?.orderingDateMayHoldInferredYear, day(2026, 12, 28), "It starts in the year nearest publication")
        expectEqual(
            crossYear?.orderingEndDateMayHoldInferredYear, day(2027, 1, 3),
            "An earlier end month moves into the next year")
        let crossStated = range("The window runs from 28 December to 3 January 2027.")
        expectEqual(shown(crossStated), "Dec 28 – Jan 3, 2027", "Only the year the source states is shown")
        expectEqual(
            crossStated?.orderingDateMayHoldInferredYear, day(2026, 12, 28), "The start's year is placed, never shown")

        expectEqual(
            shown(range("The window runs from 3 November 2026 to 5 December.")), "Nov 3, 2026 – Dec 5",
            "The end's inferred year is never displayed"
        )
        expectEqual(
            shown(range("The window runs from 3 November to 5 December 2026.")), "Nov 3 – Dec 5, 2026",
            "The start's inferred year is never displayed"
        )

        let compressed = range("Voting runs 19–28 November.")
        expectEqual(shown(compressed), "Nov 19 – 28", "A compressed range is one row")
        expectEqual(compressed?.isFuturePlan, true, "A planned range keeps its text and the Plan flag")
        expectEqual(shown(range("Talks are set for November 19-28, 2026.")), "Nov 19 – 28, 2026", "Month-first range")
        expectEqual(shown(range("Talks run between 3 and 5 December.")), "Dec 3 – 5", "Between A and B is a range")
        expectEqual(
            shown(range("Voting will begin on November 19 and run through November 28.")), "Nov 19 – 28",
            "One coordinated phrase")

        let list = range("Talks were held on 3 and 5 November.")
        expectEqual(shown(list), "Nov 3 and 5", "A list is one row")
        expectEqual(list?.orderingDateMayHoldInferredYear, day(2026, 11, 3), "A list orders on its earliest date")
        expectEqual(list?.orderingEndDateMayHoldInferredYear, day(2026, 11, 5), "A list is one span to its latest date")
        expectEqual(
            shown(range("Hearings were held on 3, 5 and 7 October.")), "Oct 3, 5, and 7",
            "Three dates are still one row"
        )
        expectEqual(range("Reports came on 3 November and 5 November.")?.dateText.isEmpty, false, "Full dates list too")

        expectEqual(
            shown(range("Voting occurs November 3 and 5, 2026.")), "Nov 3 and 5, 2026",
            "A trailing year belongs to both month-first list dates"
        )
        expectEqual(
            shown(range("Hearings are scheduled on November 19 and 21 at the courthouse.")), "Nov 19 and 21",
            "A month-first list keeps its second day when a preposition follows")
        expectEqual(
            OverviewTimelineBuilder.singleStatedDate(in: "On November 3 and 5 people were detained."),
            OverviewTimelineBuilder.StatedDate(year: nil, month: 11, day: 3), "A count after the date is no second day")
        // Half a year from publication, the nearest year differs between the days of one list; they stay together.
        let spring = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 12)))
        let farList = OverviewTimelineBuilder.placedDates(
            of: .init(
                dates: [.init(year: nil, month: 11, day: 3), .init(year: nil, month: 11, day: 5)], isRange: false),
            publishedAt: spring)
        expectEqual(farList?.map(\.at), [day(2026, 11, 3), day(2026, 11, 5)], "A list's days share one placed year")
        expectEqual(
            shown(range("Die Sitzung war am 3.–5. März 2027.")), "Mar 3 – 5, 2027",
            "A compressed range accepts supported day-first month names"
        )
        expectEqual(
            shown(range("Hearings run November 29 to 3 December.")), "Nov 29 – Dec 3",
            "Both explicitly stated months survive a range"
        )

        let inside = range("Talks run from 3 November to 8 November.")
        expectEqual(inside?.isFuturePlan, false, "Publication day inside a range is not a plan")

        // One span: a range alone, or with a date inside it, is no timeline.
        expectTrue(items(["Talks run from 3 November to 8 November."]).isEmpty, "A range alone is no timeline")
        expectTrue(
            items(["Talks run from 3 to 8 November.", "Talks started on 5 November."]).isEmpty,
            "Overlap is no chronology")
        expectTrue(
            items(["Talks were held on 3 and 5 November.", "Talks started on 4 November."]).isEmpty, "Nor a list")
        let tie = items(["Talks run from 3 to 8 November.", "Talks began on 3 November.", before])
        expectEqual(tie.count, 3, "A range with a single date inside it still counts the single dates")
        expectEqual(
            tie.map { $0.orderingEndDateMayHoldInferredYear == nil }, [true, true, false], "Single dates first on a tie"
        )

        // Rejected: unrelated dates, a range plus a date, a reversed range, parts that cannot share.
        for sentence in [
            "A funeral on 10 November was held for those killed on 28 October.",
            "Returns run from 3 November to 8 November and may continue through 8 January.",
            "Voting runs from 28 to 19 November.",
            "The review runs March to May 2027.",
            "The review runs between March and May 2027.",
            "The review runs from March 2027 to May.",
            "The hearings run from 3 March to April.",
            "Hearings were held on 3 and 5–7 November.",
            "Hearings were held on 3–5 and 7 November.",
            "Hearings were held November 3–5 and 7.",
            "Hearings ran from 3 to 5 November and 7.",
            "Hearings ran from 3 to November 5–7.",
            "Hearings were held April 9 to 11 and 16 to 18.",
            "Hearings were held April 9–11 and 16–18, 2026.",
            "Hearings were held on 9 to 11 and 16 to 18 April.",
            "Voting runs from March to 5 April 2027.",
            "Talks were held on 3 November, after talks in March 2025.",
            "Talks run from 3 November 2025 to 8 November 2024.",
        ] {
            expectTrue(items([before, sentence]).isEmpty, "No row from: \(sentence)")
        }
        typealias Stated = OverviewTimelineBuilder.StatedDate
        expectEqual(
            OverviewTimelineBuilder.statedExpression(in: "Voting runs from 28 to 19 November."), nil, "Reversed")
        expectEqual(
            OverviewTimelineBuilder.statedExpression(in: "Voting runs 19–28 November 2026."),
            .span(
                .init(
                    dates: [Stated(year: 2026, month: 11, day: 19), Stated(year: 2026, month: 11, day: 28)],
                    isRange: true)), "A shared year belongs to both ends")
        expectEqual(
            OverviewTimelineBuilder.singleStatedDate(in: "Voting runs 19–28 November."), nil,
            "A range's last day is not a single date")
        expectEqual(
            OverviewTimelineBuilder.singleStatedDate(in: "It cost 1,000 and 5 March was the day."),
            Stated(year: nil, month: 3, day: 5), "A thousands separator is no list")

        // One order of day, month and year for single dates and ranges of one timeline, whatever calendar the
        // reader's locale names: the interval formatter ignores an ISO 8601 calendar setting, the date formatter
        // does not.
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{2009}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let ninth = Stated(year: 2026, month: 11, day: 9)
        let thirteenth = Stated(year: 2026, month: 11, day: 13)
        for (identifier, single, span, list) in [
            ("en_PL@calendar=iso8601", "9 Nov 2026", "9 – 13 Nov 2026", "9 and 13 Nov 2026"),
            ("en_PL", "9 Nov 2026", "9 – 13 Nov 2026", "9 and 13 Nov 2026"),
            ("en_US", "Nov 9, 2026", "Nov 9 – 13, 2026", "Nov 9 and 13, 2026"),
            ("en_US@calendar=iso8601", "Nov 9, 2026", "Nov 9 – 13, 2026", "Nov 9 and 13, 2026"),
        ] {
            let locale = Locale(identifier: identifier)
            expectEqual(
                plain(OverviewTimelineBuilder.dateText(ninth, locale: locale)), single, "Single date in \(identifier)")
            expectEqual(
                plain(
                    OverviewTimelineBuilder.spanText(.init(dates: [ninth, thirteenth], isRange: true), locale: locale)),
                span, "Range in \(identifier)")
            expectEqual(
                plain(
                    OverviewTimelineBuilder.spanText(.init(dates: [ninth, thirteenth], isRange: false), locale: locale)),
                list, "List in \(identifier)")
        }

        // Briefing: a range or list is never a turning point and never starts "day N".
        let rows = items([before, "Talks were held on 3 and 5 November.", "Voting ran from October 27 to November 1."])
        guard rows.count == 3 else { return expectTrue(false, "Three rows") }
        for row in rows where row.orderingEndDateMayHoldInferredYear != nil {
            expectEqual(BriefingTimelineData.orderingDate(of: row), nil, "Briefing has no date for \(row.dateText)")
        }
        let rangePrecisionOnly = OverviewTimelineItem(
            id: "range-only", dateText: "19–28 Nov", dateKind: .stated, datePrecision: .range,
            summary: "The talks are scheduled for 19–28 November.", orderingDateMayHoldInferredYear: day(2026, 11, 19))
        expectEqual(
            BriefingTimelineData.orderingDate(of: rangePrecisionOnly), nil,
            "Briefing excludes .range precision even without an end date")
        let now = day(2026, 11, 8)
        let merged = BriefingTimelineData.merged([("e", rows)], now: now)
        expectEqual(merged.map(\.dateText).count, 1, "Briefing keeps only the single date")
        expectEqual(
            BriefingTimelineData.items(rows, now: now), nil, "A single date and two ranges are no Briefing thread")

        // The eight-item cut keeps a timeline that only two lower-ranked rows establish: eight ranges over one whole
        // year overlap each other and both sessions, so no single swap among the first eight is enough.
        let yearLong = (1...8).map { "Programme \($0) runs from 1 January 2027 to 31 December 2027." }
        let sessions = [
            "The first session runs from 1 to 10 February 2027.", "The second session runs from 1 to 10 July 2027.",
        ]
        expectEqual(items([yearLong[0]] + sessions).count, 3, "A year-long range and two sessions inside it are rows")
        let cut = items(yearLong + sessions)
        expectEqual(cut.count, OverviewTimelineBuilder.maximumItems, "The cut keeps eight rows")
        expectEqual(
            cut.filter { sessions.contains($0.summary) }.count, 2,
            "The cut keeps the two rows that make the timeline, though each ranks below the first eight")
        expectEqual(
            cut.filter { yearLong.prefix(6).contains($0.summary) }.count, 6, "The other six rows are the top-ranked")
        let stored = """
            {"id":"t","dateText":"3 Nov","dateKind":"stated","datePrecision":"day","summary":"x","citationIDs":[],
             "isFuturePlan":false,"orderingDateMayHoldInferredYear":\(day(2026, 11, 3).timeIntervalSinceReferenceDate)}
            """
        let decoded = try JSONDecoder().decode(OverviewTimelineItem.self, from: Data(stored.utf8))
        expectEqual(decoded.orderingEndDateMayHoldInferredYear, nil, "A stored item without the field is a single date")
        expectEqual(EventOverviewDocument.currentAnalysisVersion, 17, "Cached overviews rebuild for ranges")
    }

    /// #1241: a date the source states is shown as an event date, never as "Reported"; only a publication date is.
    static func testOverviewTimelineDateProvenance(fixtureHost: String) throws {
        print("  - Testing timeline date provenance: stated dates are not shown as Reported (#1241)...")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let published = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12)))
        let article = FeedArticle(
            storedID: "prov-a", title: "Ceasefire report", link: "https://\(fixtureHost)/prov-a", guid: "prov-a",
            description: "", pubDate: published, source: "Wire")
        let sentences = [
            "The programme began in March 2019 after earlier floods.",
            "On 15 September 2026, the ministry announced the plan.",
            "The ceasefire took effect on 3 November.",
            "The storm hit the coast on Monday, flooding 300 homes.",
            "Parliament is scheduled to vote on the plan on 20 November.",
        ]
        let passages = sentences.enumerated().map {
            EvidencePassage(id: "prov-p\($0.offset)", articleID: article.id, text: $0.element, ordinal: $0.offset)
        }
        let facts = passages.map {
            PassageAnchoredFact(
                id: "f-\($0.id)", statement: $0.text, passageID: $0.id, quote: $0.text, articleID: article.id)
        }
        let english = Locale(identifier: "en_US")
        let items = OverviewTimelineBuilder.build(
            facts: facts, passages: passages, articles: [article], locale: english
        ).items
        func label(_ item: OverviewTimelineItem) -> String {
            EventOverviewReaderView.timelineItemAccessibilityLabel(item: item)
        }
        expectEqual(
            items.map(\.summary), [sentences[0], sentences[1], sentences[2], sentences[4]],
            "Stated dates make items; a weekday is not a stated date")
        guard items.count == 4 else { return }
        for item in items {
            let display = EventOverviewReaderView.timelineDateDisplay(for: item)
            expectEqual(item.dateKind, .stated, "Builder items carry a stated date: \(item.summary)")
            expectTrue(
                item.eventDate == nil && item.publicationDate == nil,
                "No resolved timestamp, so no placed year, reaches the item: \(item.summary)")
            expectEqual(display.primary, item.dateText, "The stated date is shown as stated: \(item.summary)")
            expectTrue(display.isStated, "A stated date draws the solid marker: \(item.summary)")
            expectFalse(label(item).contains("Reported"), "A stated date is never read as Reported: \(label(item))")
        }
        let (month, full, partial, plan) = (items[0], items[1], items[2], items[3])
        expectEqual(
            items.map(\.datePrecision), [.month, .day, .day, .day], "Stated dates carry their precision (#1241)")
        expectTrue(
            full.dateText.contains("15") && full.dateText.contains("2026"),
            "Full date keeps day and year: \(full.dateText)")
        expectTrue(
            month.dateText.contains("2019") && month.dateText.contains("Mar"),
            "Month and year stay month and year: \(month.dateText)")
        expectTrue(
            partial.dateText.contains("3") && !partial.dateText.contains("2026"),
            "A missing year stays missing: \(partial.dateText)")
        expectEqual(
            label(partial), "\(partial.dateText). The ceasefire took effect on 3 November", "Partial date label")
        expectTrue(plan.isFuturePlan, "A date after publication stays a plan")
        expectEqual(
            label(plan), "\(plan.dateText). Planned. Parliament is scheduled to vote on the plan on 20 November",
            "A plan keeps its stated date and Planned")

        // No known date: no date line and nothing Reported.
        let undated = OverviewTimelineItem(id: "none", dateText: "", summary: "Talks continued.")
        expectEqual(EventOverviewReaderView.timelineDateDisplay(for: undated).primary, nil, "No date shows none")
        expectEqual(label(undated), "Talks continued", "No date reads no date")

        // A publication date is the only date that reads Reported.
        let reportedText = published.formatted(date: .abbreviated, time: .omitted)
        let publicationOnly = OverviewTimelineItem(
            id: "pub", dateText: "", dateKind: .publication, summary: "Report filed.", publicationDate: published)
        expectEqual(
            EventOverviewReaderView.timelineDateDisplay(for: publicationOnly).primary, "Reported \(reportedText)",
            "Publication date without a stated date reads Reported")
        expectFalse(
            EventOverviewReaderView.timelineDateDisplay(for: publicationOnly).isStated,
            "A publication date draws the outlined marker")
        let publicationText = OverviewTimelineItem(
            id: "pub-text", dateText: "5 Nov", dateKind: .publication, summary: "Report filed.")
        expectEqual(label(publicationText), "Reported 5 Nov. Report filed", "Publication date text reads Reported")
        let both = OverviewTimelineItem(
            id: "both", dateText: "3 Nov", summary: "Ceasefire began.", publicationDate: published)
        expectEqual(
            EventOverviewReaderView.timelineDateDisplay(for: both),
            .init(primary: "3 Nov", reported: "Reported \(reportedText)", isStated: true),
            "A stated date stays primary; the publication date is the separate Reported line")

        // A stored overview from before #1241 has no date kind: it decodes, reads its stated date without
        // Reported, and is stale, so it is regenerated under the current analysis version.
        let composed = OverviewComposer.composeOverview(
            eventID: "prov-event", eventTitle: "Ceasefire", verifiedFacts: facts, passages: passages,
            articles: [article], membershipVersion: 3)
        expectEqual(composed.timeline.count, 4, "Control: the composed overview carries the builder timeline")
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(composed)) as? [String: Any])
        var sections = try #require(json["evidenceSections"] as? [String: Any])
        let legacyItems = try #require(sections["timeline"] as? [[String: Any]]).map { item -> [String: Any] in
            expectEqual(item["dateKind"] as? String, "stated", "Current documents store the date kind")
            var legacy = item
            legacy.removeValue(forKey: "dateKind")
            return legacy
        }
        sections["timeline"] = legacyItems
        json["evidenceSections"] = sections
        json["analysisVersion"] = 14
        let stored = try JSONDecoder().decode(
            EventOverviewDocument.self, from: JSONSerialization.data(withJSONObject: json))
        expectEqual(stored.timeline.map(\.dateText), composed.timeline.map(\.dateText), "Legacy timeline decodes")
        expectTrue(stored.timeline.allSatisfy { $0.dateKind == .stated }, "A legacy date text is a stated date")
        expectFalse(
            stored.timeline.contains { label($0).contains("Reported") }, "A legacy stated date does not read Reported")
        expectTrue(
            stored.isStale(currentMembershipVersion: 3),
            "A document from analysis version 14, the one before date kinds, is stale and is regenerated")

        // 8-item cap preserves at least 2 distinct dates when top 8 corroborated entries share one date.
        let secondArticle = FeedArticle(
            storedID: "prov-b", title: "Ceasefire follow-up", link: "https://\(fixtureHost)/prov-b", guid: "prov-b",
            description: "", pubDate: published, source: "Daily")
        var capFacts: [PassageAnchoredFact] = []
        var capPassages: [EvidencePassage] = []
        for idx in 0..<8 {
            let quote = "On 3 November 2026, delegation \(idx) arrived."
            let pA = EvidencePassage(id: "cap-pa-\(idx)", articleID: article.id, text: quote, ordinal: idx)
            let pB = EvidencePassage(id: "cap-pb-\(idx)", articleID: secondArticle.id, text: quote, ordinal: idx)
            capPassages.append(contentsOf: [pA, pB])
            capFacts.append(
                PassageAnchoredFact(
                    id: "cap-fa-\(idx)", statement: quote, passageID: pA.id, quote: quote, articleID: article.id))
            capFacts.append(
                PassageAnchoredFact(
                    id: "cap-fb-\(idx)", statement: quote, passageID: pB.id, quote: quote, articleID: secondArticle.id))
        }
        let secondDateQuote = "On 4 November 2026, talks opened."
        let secondDatePassage = EvidencePassage(id: "cap-p2", articleID: article.id, text: secondDateQuote, ordinal: 99)
        capPassages.append(secondDatePassage)
        capFacts.append(
            PassageAnchoredFact(
                id: "cap-f2", statement: secondDateQuote, passageID: secondDatePassage.id, quote: secondDateQuote,
                articleID: article.id))
        let cappedTimeline = OverviewTimelineBuilder.build(
            facts: capFacts, passages: capPassages, articles: [article, secondArticle], locale: english
        ).items
        expectEqual(cappedTimeline.count, 8, "Capped timeline keeps 8 items")
        expectTrue(
            Set(cappedTimeline.map(\.dateText)).count >= 2,
            "Capped timeline swaps in a second distinct date instead of dropping it")
    }

    static func testEventOverviewReaderMode(fixtureHost: String) async throws {
        print(
            "  - Testing Event overview reader mode, layout order, absent sections, fact link passage navigation and mode switching..."
        )

        let linkScheme = "feed"
        let articleA = FeedArticle(
            storedID: "art-reader-alpha",
            title: "Seismic Activity Detected in Central Region",
            link: "\(linkScheme)://\(fixtureHost)/stories/alpha",
            guid: "guid-alpha",
            description: "Initial reports of tremor.",
            pubDate: Date(timeIntervalSince1970: 1_727_850_000),
            source: "Geological Monitor"
        )
        let articleB = FeedArticle(
            storedID: "art-reader-beta",
            title: "Transit Lines Inspected Following Minor Quake",
            link: "\(linkScheme)://\(fixtureHost)/stories/beta",
            guid: "guid-beta",
            description: "Transit authorities deploy inspection teams.",
            pubDate: Date(timeIntervalSince1970: 1_727_853_600),
            source: "City Transit News"
        )
        let articles = [articleA, articleB]

        // 1. Model: Evidence sections (timeline, perspectives, thematic angle)
        let timelineItem1 = OverviewTimelineItem(
            id: "tl-1",
            dateText: "06:14 UTC",
            summary: "Magnitude 4.8 tremor recorded along central fault line.",
            citationIDs: ["cite-alpha"],
            isFuturePlan: false
        )
        let timelineItem2 = OverviewTimelineItem(
            id: "tl-2",
            dateText: "Tomorrow 08:00 UTC",
            summary: "Secondary drone inspection of high-speed rail bridges scheduled.",
            citationIDs: ["cite-beta"],
            isFuturePlan: true
        )
        let perspective1 = OverviewPerspective(
            id: "persp-1",
            participant: "Regional Seismology Office",
            position: "Aftershock probabilities remain low over the next 48 hours.",
            citationIDs: ["cite-alpha"]
        )
        let perspective2 = OverviewPerspective(
            id: "persp-2",
            participant: "Transit Safety Commission",
            position: "All lines cleared for operation after ultrasonic rail checks.",
            citationIDs: ["cite-beta"]
        )
        let thematicAngle = OverviewThematicAngle(
            id: "angle-1",
            title: "Infrastructure Resilience",
            summary: "Automated early warning sensors halted trains 12 seconds before surface waves arrived.",
            citationIDs: ["cite-alpha", "cite-beta"]
        )
        let evidenceSections = OverviewEvidenceSections(
            timeline: [timelineItem1, timelineItem2],
            perspectives: [perspective1, perspective2],
            thematicAngle: thematicAngle
        )
        expectFalse(evidenceSections.isEmpty, "Evidence sections with content is not empty")

        let citationA = OverviewCitation(
            id: "cite-alpha",
            articleID: articleA.id,
            passageID: "pass-a",
            passageFingerprint: "fp-a",
            quote: "Seismic monitors recorded a magnitude 4.8 tremor along the central fault at 06:14 UTC.",
            source: OverviewSourceMetadata(
                title: articleA.title, name: articleA.source, url: articleA.link, publishedAt: articleA.pubDate)
        )
        let citationB = OverviewCitation(
            id: "cite-beta",
            articleID: articleB.id,
            passageID: "pass-b",
            passageFingerprint: "fp-b",
            quote: "Ultrasonic sensors and drone crews cleared all central line bridges by mid-morning.",
            source: OverviewSourceMetadata(
                title: articleB.title, name: articleB.source, url: articleB.link, publishedAt: articleB.pubDate)
        )

        let fact1 = OverviewFact(
            id: "f-1", text: "A magnitude 4.8 tremor struck along the central fault.", citationIDs: ["cite-alpha"])
        let fact2 = OverviewFact(
            id: "f-2", text: "Automated sensor trips safely halted all rail transit.", citationIDs: ["cite-beta"])
        let fact3 = OverviewFact(
            id: "f-3", text: "Ultrasonic rail inspections revealed zero structural flaws.", citationIDs: ["cite-beta"])

        let leadImage = OverviewLeadImage(
            url: "\(linkScheme)://\(fixtureHost)/images/seismic-station.jpg",
            caption: "Seismic monitoring station in the central valley.",
            credit: "Geological Monitor / Photo",
            sourceArticleID: articleA.id
        )

        let introSummary = """
            Seismologists recorded a moderate 4.8-magnitude earthquake in the central valley early Tuesday morning, triggering automated transit halts across the metropolitan corridor.

            Rapid structural inspections confirmed that rail infrastructure and elevated bridges sustained no damage, allowing passenger service to resume ahead of the morning peak.
            """

        let overviewDoc = EventOverviewDocument(
            id: "doc-reader-1",
            eventID: "event-quake-1",
            version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "hash-quake"),
            content: OverviewContent(
                title: "Magnitude 4.8 Tremor Halts Central Valley Rail Lines",
                summary: introSummary,
                facts: [fact1, fact2, fact3],
                citations: [citationA, citationB],
                leadImage: leadImage,
                evidenceSections: evidenceSections
            ),
            provenance: OverviewProvenance(
                memberArticleIDs: [articleA.id, articleB.id],
                kind: .synthesized
            )
        )

        // Verify document forwarders and evidence content
        expectEqual(overviewDoc.timeline.count, 2, "Overview document forwards timeline items")
        expectTrue(overviewDoc.timeline[1].isFuturePlan, "Future timeline item retains isFuturePlan flag")
        expectEqual(overviewDoc.perspectives.count, 2, "Overview document forwards perspectives")
        expectEqual(
            overviewDoc.thematicAngle?.title, "Infrastructure Resilience", "Overview document forwards thematic angle")

        // 2. DatabaseEngine & ArticleStore persistence and fetchEventOverview(forArticleID:)
        let dbEngine = DatabaseEngine(path: ":memory:")
        try await dbEngine.open()
        _ = try await dbEngine.upsertArticles(articles)
        let event = try await dbEngine.createEvent(memberArticleIDs: [articleA.id, articleB.id])

        let saved = try await dbEngine.recordEventOverview(
            EventOverviewDocument(
                id: overviewDoc.id,
                eventID: event.id,
                version: overviewDoc.version,
                content: overviewDoc.content,
                provenance: OverviewProvenance(memberArticleIDs: [articleA.id, articleB.id], kind: .synthesized)
            ))
        expectTrue(saved, "DatabaseEngine recorded overview successfully")

        // Lookup by member article ID
        let fetchedByArticleA = try await dbEngine.fetchEventOverview(forArticleID: articleA.id)
        expectTrue(fetchedByArticleA != nil, "fetchEventOverview resolves by member article A ID")
        expectEqual(fetchedByArticleA?.title, overviewDoc.title, "Fetched overview title matches")
        expectEqual(fetchedByArticleA?.timeline.count, 2, "Fetched overview restores timeline")
        expectTrue(fetchedByArticleA?.timeline[1].isFuturePlan == true, "Fetched timeline item retains isFuturePlan")
        expectEqual(fetchedByArticleA?.perspectives.count, 2, "Fetched overview restores perspectives")
        expectEqual(
            fetchedByArticleA?.thematicAngle?.title, "Infrastructure Resilience",
            "Fetched overview restores thematic angle")

        let fetchedByArticleB = try await dbEngine.fetchEventOverview(forArticleID: articleB.id)
        expectTrue(fetchedByArticleB != nil, "fetchEventOverview resolves by member article B ID")

        let nonExistent = try await dbEngine.fetchEventOverview(forArticleID: "non-existent-art")
        expectTrue(nonExistent == nil, "fetchEventOverview returns nil for non-existent article")

        // 3. Layout Rules: Verify absent sections when data is missing
        let emptySectionsDoc = EventOverviewDocument(
            id: "doc-minimal",
            eventID: "event-min-1",
            version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "min"),
            content: OverviewContent(
                title: "Minimal Event",
                summary: "One short paragraph.",
                facts: [],
                citations: [],
                leadImage: nil,
                evidenceSections: nil
            ),
            provenance: OverviewProvenance(memberArticleIDs: [articleA.id], kind: .synthesized)
        )
        expectTrue(emptySectionsDoc.leadImage == nil, "Lead image absent when nil")
        expectTrue(emptySectionsDoc.facts.isEmpty, "Facts section absent when empty")
        expectTrue(emptySectionsDoc.timeline.isEmpty, "Timeline section absent when empty")
        expectTrue(emptySectionsDoc.perspectives.isEmpty, "Perspectives section absent when empty")
        expectTrue(emptySectionsDoc.thematicAngle == nil, "Thematic angle section absent when nil")

        // 4. Citation resolving & fact link opening stored passage
        let citedQuote = citationA.quote
        let targetArticleID = citationA.articleID
        expectEqual(targetArticleID, articleA.id, "Citation links to articleA")
        expectTrue(citedQuote.contains("06:14 UTC"), "Citation contains exact stored passage quote")

        // 5. Reader experience modes verification
        let overviewMode = ReaderExperienceMode.eventOverview
        let publicationMode = ReaderExperienceMode.sourcePublication
        expectEqual(overviewMode.rawValue, "Event overview", "Overview mode label is 'Event overview'")
        expectEqual(publicationMode.rawValue, "Source publication", "Publication mode label is 'Source publication'")
        expectFalse(overviewMode.marksOpenedStoryRead, "Opening an event overview marks no story read (#813)")
        expectTrue(publicationMode.marksOpenedStoryRead, "Opening a single publication marks it read")
    }

    /// #218: Verifies that opening an article belonging to a multi-source event
    /// generates an overview in the background, persists it, and resolves it when queried.
    @MainActor
    static func testOverviewResolutionWhenOpeningMemberArticle(fixtureHost: String = "example.com") async throws {
        print("  - Testing overview resolution when opening member article (#218)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()

        let art1 = FeedArticle(
            storedID: "art-ev-1",
            title: "Volcanic Eruption Prompts Island Evacuations",
            link: "https://\(fixtureHost)/volcano/island-1",
            guid: "g-volcano-1",
            description:
                "Emergency teams began evacuating coastal communities after Mount Teide began erupting early Thursday morning.",
            pubDate: Date(timeIntervalSince1970: 1_792_051_200),
            source: "Atlantic Wire",
            fullContent:
                "Emergency teams began evacuating coastal communities after Mount Teide began erupting early Thursday morning. Scientists recorded twenty separate seismic tremors along the north caldera."
        )

        let art2 = FeedArticle(
            storedID: "art-ev-2",
            title: "Airports Halt Flights as Ash Cloud Spreads",
            link: "https://\(fixtureHost)/volcano/airports-2",
            guid: "g-volcano-2",
            description:
                "Civil aviation authorities closed two international airports due to rising ash plumes from Mount Teide.",
            pubDate: Date(timeIntervalSince1970: 1_792_054_800),
            source: "Island Gazette",
            fullContent:
                "Civil aviation authorities closed two international airports due to rising ash plumes from Mount Teide. Aviation officials said thirty scheduled flights were redirected to regional hubs."
        )

        let articles = [art1, art2]
        _ = try await db.upsertArticles(articles)

        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        let queue = EnrichmentQueue(store: store)
        let coordinator = OverviewGenerationCoordinator(store: store, queue: queue)

        // 1. Initially, no event exists and no overview exists for art1
        let initialSummaries = try await store.eventFeedSummaries(for: [art1.id])
        expectTrue(initialSummaries.isEmpty, "Articles not yet in an event have no event summary")
        let initialOverview = try await store.fetchEventOverview(forArticleID: art1.id)
        expectTrue(initialOverview == nil, "No overview exists before event creation")

        // 2. Create multi-source event
        let event = try await db.createEvent(memberArticleIDs: [art1.id, art2.id])
        let summaries = try await store.eventFeedSummaries(for: [art1.id])
        expectEqual(summaries.count, 1, "Article 1 belongs to 1 event")
        let summary = summaries[0]
        expectEqual(summary.eventID, event.id, "Summary matches created event ID")
        expectTrue(summary.isConfirmed, "Event with 2 members is confirmed")
        expectEqual(summary.sources.count, 2, "Event has 2 distinct sources")
        expectEqual(summary.membershipVersion, 1, "Initial membership version is 1")

        // Overview in store is still nil before reader resolution
        let beforeGenOverview = try await store.fetchEventOverview(forArticleID: art1.id)
        expectTrue(beforeGenOverview == nil, "Overview not yet generated")

        // 3. Opening member article triggers coordinator setVisibleEvent at visibleEvent priority
        let memberArticles = try await store.eventMemberArticles(eventID: summary.eventID)
        expectEqual(memberArticles.count, 2, "Event members fetched correctly")
        let title = memberArticles.first?.title ?? summary.members.first?.title ?? art1.title

        let generated = await coordinator.setVisibleEvent(
            eventID: summary.eventID,
            eventTitle: title,
            membershipVersion: summary.membershipVersion,
            articles: memberArticles,
            store: store
        )
        expectTrue(generated != nil, "Generated overview is returned by coordinator")
        expectEqual(generated?.eventID, summary.eventID, "Generated overview matches event ID")
        expectEqual(generated?.membershipVersion, 1, "Generated overview carries membership version 1")

        // 4. Stored overview is now persisted in database and resolves by member article ID
        let resolvedOverview1 = try await store.fetchEventOverview(forArticleID: art1.id)
        expectTrue(resolvedOverview1 != nil, "fetchEventOverview resolves for member article 1")
        expectEqual(resolvedOverview1?.id, generated?.id, "Resolved overview matches generated ID")

        let resolvedOverview2 = try await store.fetchEventOverview(forArticleID: art2.id)
        expectTrue(resolvedOverview2 != nil, "fetchEventOverview resolves for member article 2")
        expectEqual(resolvedOverview2?.id, generated?.id, "Member article 2 resolves to the same overview")

        // 5. Leaving the event / closing the reader cancels visible event
        await coordinator.setVisibleEvent(eventID: nil)
        expectTrue(await coordinator.inFlightInputHash(for: summary.eventID) == nil, "No in-flight generation remains")

        // 6. Membership version bump triggers regeneration of stale overview
        let art3 = FeedArticle(
            storedID: "art-ev-3",
            title: "Ferry Services Mobilized for Evacuations",
            link: "https://\(fixtureHost)/volcano/ferry-3",
            guid: "g-volcano-3",
            description: "Maritime authorities deployed four passenger ferries to assist coastal evacuations.",
            pubDate: Date(timeIntervalSince1970: 1_792_058_400),
            source: "Maritime Journal",
            fullContent:
                "Maritime authorities deployed four passenger ferries to assist coastal evacuations. Harbor operations confirmed five hundred residents boarded the first vessel."
        )
        _ = try await db.upsertArticles([art3])
        _ = try await db.addArticles([art3.id], toEvent: event.id)

        let updatedSummaries = try await store.eventFeedSummaries(for: [art1.id])
        let updatedSummary = updatedSummaries[0]
        expectEqual(updatedSummary.membershipVersion, 2, "Membership version bumped to 2")
        expectEqual(updatedSummary.sources.count, 3, "Event now has 3 sources")

        // Stored overview is now stale because its version is 1 < current version 2
        expectTrue(
            resolvedOverview1?.isStale(currentMembershipVersion: updatedSummary.membershipVersion) == true,
            "Old overview is identified as stale")

        let updatedMemberArticles = try await store.eventMemberArticles(eventID: updatedSummary.eventID)
        let regenerated = await coordinator.setVisibleEvent(
            eventID: updatedSummary.eventID,
            eventTitle: title,
            membershipVersion: updatedSummary.membershipVersion,
            articles: updatedMemberArticles,
            store: store
        )
        expectTrue(regenerated != nil, "Regenerated overview exists for updated version")
        expectEqual(regenerated?.membershipVersion, 2, "Regenerated overview carries version 2")

        let resolvedUpdated = try await store.fetchEventOverview(forArticleID: art3.id)
        expectEqual(
            resolvedUpdated?.membershipVersion, 2, "Newly added member article 3 resolves to version 2 overview")

        await db.close()
    }

    /// #993: the sources of a highlight or perspective follow its sentence as linked runs inside one text.
    static func testOverviewSourcesFollowTheSentence() {
        print("  - Testing that overview sources follow the sentence as inline links (#993)...")
        let text = EventOverviewReaderView.sourcedAttributedString(
            "Routes are open.", sources: [(id: "c_1", label: "The Hindu"), (id: "c_2", label: "The Guardian")],
            scale: 1, contrast: .standard)
        let plain = String(text.characters)
        expectTrue(plain.hasPrefix("Routes are open. "), "The sentence comes first, unchanged")
        expectTrue(plain.contains("\u{00A0}The Hindu\u{00A0}"), "Each source is a padded run after the sentence")
        expectTrue(
            plain.range(of: "The Hindu")!.lowerBound < plain.range(of: "The Guardian")!.lowerBound,
            "Sources keep citation order")
        let links = text.runs.compactMap(\.link)
        expectEqual(
            links.map(\.absoluteString), ["news-citation://0", "news-citation://1"],
            "Each source run links to its citation by position; the sentence itself is not a link")
        expectTrue(text.runs.first?.link == nil, "The sentence run carries no link")
        let bare = EventOverviewReaderView.sourcedAttributedString("Alone.", sources: [], scale: 1, contrast: .standard)
        expectEqual(String(bare.characters), "Alone.", "No source, no run")
    }

    /// #1143: Inline overview sources open correctly when the story ID contains ?, #, or a percent escape.
    @MainActor
    static func testOverviewInlineSourcesWithSpecialCharacterIDs() {
        print("  - Testing inline overview sources with ?, #, and %20 in citation ID (#1143)...")
        let specialID = "cite?query=1#frag%20space"
        let text = EventOverviewReaderView.sourcedAttributedString(
            "Routes are open.",
            sources: [(id: specialID, label: "The Hindu")],
            scale: 1,
            contrast: .standard
        )
        let plain = String(text.characters)
        expectTrue(plain.contains("\u{00A0}The Hindu\u{00A0}"), "Source label is included in the run")
        let links = text.runs.compactMap(\.link)
        expectEqual(
            links.map(\.absoluteString), ["news-citation://0"],
            "Inline source links by index position rather than embedding the raw unescaped ID"
        )

        let citation = OverviewCitation(
            id: specialID,
            articleID: "art_special",
            passageID: "pass_special",
            passageFingerprint: "fp_special",
            quote: "Routes are open across the corridor.",
            source: OverviewSourceMetadata(
                title: "Special Report",
                name: "The Hindu",
                url: "https://example.com/special?query=1#frag%20space",
                publishedAt: Date()
            )
        )
        let article = FeedArticle(
            storedID: "art_special",
            title: "Special Report",
            link: "https://example.com/special?query=1#frag%20space",
            guid: "guid_special",
            description: "Routes are open across the corridor.",
            pubDate: Date(),
            source: "The Hindu"
        )
        let overview = EventOverviewDocument(
            eventID: "ev_special",
            version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "hash_special"),
            content: OverviewContent(
                title: "Transit Overview",
                summary: "Transit operations resumed.",
                citations: [citation]
            )
        )

        var selectedCitation: OverviewCitation?
        var selectedArticle: FeedArticle?
        let view = EventOverviewReaderView(
            overview: overview,
            memberArticles: [article],
            onSelectArticle: { _ in },
            onSelectCitation: { cit, art in
                selectedCitation = cit
                selectedArticle = art
            }
        )
        let handler = view.citationOpenURLAction([citation])
        if let linkURL = links.first {
            handler(linkURL)
        }
        expectEqual(
            selectedCitation?.id, specialID, "Handler resolves citation by index even with special character ID")
        expectEqual(selectedArticle?.id, article.id, "Handler resolves matching article for selected citation")

        // Non-citation URLs keep system behaviour
        var unhandledTriggered = false
        let unhandledView = EventOverviewReaderView(
            overview: overview,
            memberArticles: [article],
            onSelectArticle: { _ in },
            onSelectCitation: { _, _ in unhandledTriggered = true }
        )
        let unhandledHandler = unhandledView.citationOpenURLAction([citation])
        unhandledHandler(URL(string: "https://example.com")!)
        unhandledHandler(URL(string: "news-citation://999")!)
        expectFalse(unhandledTriggered, "Non-matching and out-of-range URLs do not trigger selection")
    }
}
