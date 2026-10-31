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

/// Weak signals and forward watch (#851): the weak-signal gate, momentum, and the forward watch evaluation set.
/// Drives production types only (#804).
enum BriefingSignalsTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("❌ FAILURE [BriefingSignalsTests.swift:\(line)]: \(message)")
        }
    }

    static func run() async {
        print("=== Running Briefing signals (#851) tests ===")
        weakSignalGate()
        momentum()
        forwardWatchEvaluation()
        forwardWatchCitations()
        forwardWatchMerge()
        print("Finished \(checks) Briefing signals checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }

    static let now = Date(timeIntervalSince1970: 1_793_188_800)

    static func entry(_ id: String, publishers: Int) -> FeedEntry {
        let article = FeedArticle(
            storedID: id, title: "Story \(id) headline here", link: "https://example.com/\(id)", guid: id,
            description: "", pubDate: now, source: "Outlet 0")
        guard publishers > 1 else { return .article(article) }
        let members = (0..<publishers).map {
            EventFeedMember(
                articleID: "\(id)-\($0)", source: "Outlet \($0)", title: article.title, date: now, joinedVersion: 1,
                isRead: false, isSaved: false)
        }
        return .event(
            EventFeedSummary(eventID: "e-\(id)", membershipVersion: 1, seenVersion: nil, members: members),
            representative: article, visibleMembers: [article])
    }

    static func weakSignalGate() {
        typealias Data = BriefingWeakSignalsData
        let low = entry("low", publishers: 2)
        check(
            Data.make(entries: [low], evidence: [low.id: Data.Evidence()], captions: [:]) == nil,
            "low coverage alone never qualifies")
        check(Data.make(entries: [low], evidence: [:], captions: [:]) == nil, "no evidence never qualifies")
        let reasons: [(Data.Evidence, String)] = [
            (Data.Evidence(isMajor: true), "Major rating"),
            (
                Data.Evidence(linkedThread: "Shipping corridor attacks widen to the gulf"),
                "Linked to shipping corridor attacks widen thread"
            ),
            (Data.Evidence(momentumRising: true), "Momentum rising"),
            (Data.Evidence(sector: "Energy"), "Industry impact: Energy"),
        ]
        for (evidence, pill) in reasons {
            let data = Data.make(entries: [low], evidence: [low.id: evidence], captions: [low.id: "2 publishers · 1 h"])
            check(data?.rows.map(\.reasons) == [[pill]], "\(pill) alone qualifies")
        }
        let wide = entry("wide", publishers: 3)
        check(
            Data.make(entries: [wide], evidence: [wide.id: Data.Evidence(isMajor: true)], captions: [:]) == nil,
            "three publishers is not low coverage")
        let many = (0..<7).map { entry("m\($0)", publishers: 1) }
        let all = Dictionary(uniqueKeysWithValues: many.map { ($0.id, Data.Evidence(isMajor: true)) })
        check(
            Data.make(entries: many, evidence: all, captions: [:])?.rows.count == Data.maximumRows, "at most five rows")
    }

    static func momentum() {
        let hour: TimeInterval = 3600
        let rising = [now - hour, now - 2 * hour, now - 8 * hour]
        check(BriefingWeakSignalsData.isMomentumRising(rising, now: now), "two recent against one earlier rises")
        let flat = [now - hour, now - 8 * hour]
        check(!BriefingWeakSignalsData.isMomentumRising(flat, now: now), "equal windows do not rise")
        let falling = [now - hour, now - 7 * hour, now - 9 * hour]
        check(!BriefingWeakSignalsData.isMomentumRising(falling, now: now), "fewer recent reports do not rise")
        check(!BriefingWeakSignalsData.isMomentumRising([now - 20 * hour], now: now), "old reports do not rise")
    }

    struct Evaluation: Decodable {
        struct Item: Decodable {
            let sentence: String
            let expected_kind: String?
            let expected_date_text: String?
        }
        let items: [Item]
    }

    static func extract(_ sentence: String, publisher: String = "Harbor Times") -> [ForwardWatchItem] {
        let citation = OverviewCitation(
            id: "c1", articleID: "a1", passageID: "p1", passageFingerprint: "f1", quote: sentence,
            source: OverviewSourceMetadata(name: publisher, url: "https://example.com/a1", publishedAt: now))
        return ForwardWatchExtractor.extract(
            facts: [OverviewFact(id: "f1", text: sentence, citationIDs: ["c1"])], citations: ["c1": citation],
            publishedAt: now)
    }

    static func forwardWatchEvaluation() {
        let url = URL(fileURLWithPath: "Tests/Fixtures/forward-watch/forward-watch-eval-v1.json")
        guard let data = try? Data(contentsOf: url),
            let evaluation = try? JSONDecoder().decode(Evaluation.self, from: data)
        else {
            check(false, "evaluation set loads")
            return
        }
        check(evaluation.items.count >= 40, "at least 40 sentences")
        var positives = 0
        var recalled = 0
        var kindRight = 0
        var dateRight = 0
        var falsePositives = 0
        var badDates = 0
        var confusion: [String: Int] = [:]
        for item in evaluation.items {
            let found = extract(item.sentence).first
            confusion["\(item.expected_kind ?? "none") → \(found.map { "\($0.kind)" } ?? "none")", default: 0] += 1
            if let date = found?.dateText, !item.sentence.contains(date) { badDates += 1 }
            guard let expected = item.expected_kind else {
                if let found {
                    falsePositives += 1
                    print("   false positive: \(item.sentence) → \(found.kind)")
                }
                continue
            }
            positives += 1
            guard let found else {
                print("   missed: \(item.sentence)")
                continue
            }
            recalled += 1
            if "\(found.kind)" == expected {
                kindRight += 1
            } else {
                print("   wrong kind \(found.kind): \(item.sentence)")
            }
            if found.dateText == item.expected_date_text { dateRight += 1 }
        }
        let recall = Double(recalled) / Double(max(positives, 1))
        let accuracy = Double(kindRight) / Double(max(recalled, 1))
        print("   forward watch evaluation: \(evaluation.items.count) sentences, \(positives) positives")
        print(
            "   recall \(recalled)/\(positives), kind accuracy \(kindRight)/\(recalled), date text exact \(dateRight)/\(recalled), false positives \(falsePositives), dates not in sentence \(badDates)"
        )
        for (cell, count) in confusion.sorted(by: { $0.key < $1.key }) { print("   \(cell): \(count)") }
        check(falsePositives == 0, "no item for a sentence that states nothing ahead")
        check(badDates == 0, "every date text is a substring of its sentence")
        check(recall >= 0.8, "recall \(recall) ≥ 0.8")
        check(accuracy >= 0.9, "kind accuracy \(accuracy) ≥ 0.9")
    }

    static func forwardWatchCitations() {
        let sentence = "The Security Council will meet on Tuesday to discuss the shipping corridor."
        check(
            ForwardWatchExtractor.extract(
                facts: [OverviewFact(id: "f", text: sentence, citationIDs: [])], citations: [:], publishedAt: now
            )
            .isEmpty, "an uncited fact yields nothing")
        let item = extract(sentence).first
        check(item?.citationID == "c1" && item?.publisher == "Harbor Times", "items carry their citation")
        let six = (0..<8).map { "Union delegation number \($0) will meet employers on Thursday for talks." }
        let citations = Dictionary(
            uniqueKeysWithValues: six.enumerated().map {
                (
                    "c\($0.offset)",
                    OverviewCitation(
                        id: "c\($0.offset)", articleID: "a", passageID: "p\($0.offset)", passageFingerprint: "f",
                        quote: $0.element)
                )
            })
        let facts = six.indices.map { OverviewFact(id: "f\($0)", text: "", citationIDs: ["c\($0)"]) }
        check(
            ForwardWatchExtractor.extract(facts: facts, citations: citations, publishedAt: now).count
                == ForwardWatchExtractor.maximumItems, "at most six items")
    }

    static func forwardWatchMerge() {
        let text = "The Security Council will meet on Tuesday to discuss the shipping corridor."
        let a = extract(text, publisher: "Harbor Times")
        let b = extract(text, publisher: "Wire Service")
        let conditional = extract("Port operators will close the terminal if attacks on vessels continue.")
        let data = BriefingForwardWatchData.make((conditional + a + b).map { ($0, nil, nil) })
        check(data?.rows.count == 2, "same line from two publishers merges")
        check(data?.rows.first?.item.kind == .scheduled, "scheduled first")
        check(data?.rows.first?.caption == "Tuesday, as reported by 2 publishers", "merged caption")
        check(data?.rows.last?.caption == "Stated by Harbor Times, cited once", "single citation caption")
        check(BriefingForwardWatchData.make([]) == nil, "no item hides the module")
    }
}
