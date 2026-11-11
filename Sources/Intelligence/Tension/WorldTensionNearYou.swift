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

/// Typealias for tension calculations under the near-you methodology (#1172).
typealias WorldTensionCalculator = WorldTensionNearYou

/// One stored story as the Near you lens reads it: its title, its publisher and when it was published.
struct TensionLocalStory: Equatable, Sendable {
    let title: String
    let publisher: String
    let date: Date
}

/// What is happening near the reader, added to the world reading.
///
/// World Tension reads twelve international panel feeds, so a war next door or a government crisis at home barely moves
/// it. Where the Mac's Region setting names a country a war is next door to, this adds up to `cap` degrees for the
/// stories of the past seven days in the reader's own library: one step by how many publishers name the war's countries
/// with fighting or attacks, and a smaller one by how many name the reader's own country with a crisis, a protest, an
/// attack or a security cue. It is a count of keywords, not a reading of the model, and the sheet shows it beside the
/// world reading with its reasons. Nothing leaves the Mac.
struct WorldTensionNearYou: Codable, Equatable, Sendable {
    /// The country as the sheet names it.
    let region: String
    /// The reading before this addition: the 7-day reading of methodology v3.
    let worldScore: Int
    let neighbourDegrees: Int
    let neighbourStories: Int
    let neighbourPublishers: Int
    let domesticDegrees: Int
    let domesticStories: Int
    let domesticPublishers: Int

    /// The most the lens adds.
    static let cap = 15
    /// The stories of this many days before a reading's day count toward it.
    static let windowDays = 7
    /// Readings of this many days, today included, carry the lens; older ones show the world reading alone.
    static let shownDays = 30

    var degrees: Int { min(Self.cap, neighbourDegrees + domesticDegrees) }

    /// The sheet's sentences: what was counted, for each part that added something.
    var neighbourReason: String? {
        guard neighbourDegrees > 0 else { return nil }
        return
            "War next door +\(neighbourDegrees)°: \(Self.stories(neighbourStories)) from \(Self.publishers(neighbourPublishers)) this week name \(Self.neighbourNames) with fighting or attacks."
    }

    var domesticReason: String? {
        guard domesticDegrees > 0 else { return nil }
        return
            "\(region) at home +\(domesticDegrees)°: \(Self.stories(domesticStories)) from \(Self.publishers(domesticPublishers)) this week name \(region) with a crisis, protest, attack or security cue."
    }

    var reasons: [String] { [neighbourReason, domesticReason].compactMap { $0 } }

    private static let neighbourNames = "Ukraine, Belarus or Russia"
    private static func stories(_ count: Int) -> String { "\(count) \(count == 1 ? "story" : "stories")" }
    private static func publishers(_ count: Int) -> String { "\(count) \(count == 1 ? "publisher" : "publishers")" }

    // MARK: Regions

    /// A country the war in Ukraine is next door to, and the words that name it in a headline.
    struct Region: Equatable, Sendable {
        let code: String
        let name: String
        let words: [String]

        /// The region of the Mac's Region setting; nil where no such war is next door, and the lens adds nothing.
        static func current(_ locale: Locale = .current) -> Region? {
            guard let code = locale.region?.identifier else { return nil }
            return all.first { $0.code == code }
        }

        static let all: [Region] = [
            Region(code: "PL", name: "Poland", words: ["poland", "polish", "warsaw"]),
            Region(code: "LT", name: "Lithuania", words: ["lithuania", "lithuanian", "vilnius"]),
            Region(code: "LV", name: "Latvia", words: ["latvia", "latvian", "riga"]),
            Region(code: "EE", name: "Estonia", words: ["estonia", "estonian", "tallinn"]),
            Region(code: "FI", name: "Finland", words: ["finland", "finnish", "helsinki"]),
            Region(code: "SK", name: "Slovakia", words: ["slovakia", "slovak", "bratislava"]),
            Region(code: "HU", name: "Hungary", words: ["hungary", "hungarian", "budapest"]),
            Region(code: "RO", name: "Romania", words: ["romania", "romanian", "bucharest"]),
            Region(code: "MD", name: "Moldova", words: ["moldova", "moldovan", "chisinau"]),
        ]
    }

    /// How headlines name the war in Ukraine and the countries it touches.
    static let neighbourWords = [
        "ukraine", "ukrainian", "ukrainians", "kyiv", "kiev", "kharkiv", "odesa", "odessa", "zaporizhzhia", "donetsk",
        "donbas", "crimea", "belarus", "belarusian", "minsk", "kaliningrad", "russia", "russian", "russians", "moscow",
        "kremlin",
    ]

    /// Fighting and attacks, beyond the panel classifier's armed-conflict cues, which miss "strikes" and "attack".
    static let neighbourCues =
        [
            "war", "attack", "attacks", "attacked", "strike", "strikes", "struck", "drone", "drones", "missile",
            "missiles", "shelling", "shelled", "offensive", "invasion", "troops", "killed", "bombing", "bombed",
            "frontline", "front line", "fighting", "casualties",
        ] + (TensionEventClassifier.typeCues[.armedConflict] ?? [])

    /// A crisis, a protest, an attack or a security cue in a story that names the reader's own country.
    static let domesticCues = [
        "crisis", "coalition", "no confidence", "resigns", "resign", "resignation", "veto", "vetoes", "impeachment",
        "snap election", "constitutional", "emergency", "protest", "protests", "shooting", "gunman", "attack",
        "terror", "sabotage", "arson", "espionage", "spy", "drone", "drones", "airspace",
    ]

    // MARK: Evidence

    /// One step by publishers: the more outlets name a war next door, the more it is the news.
    static func neighbourDegrees(publishers: Int) -> Int {
        switch publishers {
        case 8...: return 12
        case 5...: return 9
        case 3...: return 6
        case 1...: return 3
        default: return 0
        }
    }

    static func domesticDegrees(publishers: Int) -> Int {
        switch publishers {
        case 6...: return 3
        case 3...: return 2
        case 1...: return 1
        default: return 0
        }
    }

    /// What `stories` of the seven days up to `end` say about `region`, or nil when nothing adds a degree.
    static func evidence(_ stories: [TensionLocalStory], region: Region, endingAt end: Date, worldScore: Int) -> Self? {
        let start = end.addingTimeInterval(-Double(windowDays) * 86400)
        var neighbour: [TensionLocalStory] = []
        var domestic: [TensionLocalStory] = []
        for story in stories where story.date > start && story.date <= end {
            let words = TensionEventClassifier.words(story.title)
            let named = Set(words)
            if !named.isDisjoint(with: neighbourWords), TensionEventClassifier.containsCue(words, neighbourCues) {
                neighbour.append(story)
            }
            if !named.isDisjoint(with: region.words), TensionEventClassifier.containsCue(words, domesticCues) {
                domestic.append(story)
            }
        }
        func counts(_ list: [TensionLocalStory]) -> (stories: Int, publishers: Int) {
            (Set(list.map { "\($0.publisher)|\($0.title.lowercased())" }).count, Set(list.map(\.publisher)).count)
        }
        let near = counts(neighbour)
        let home = counts(domestic)
        let result = Self(
            region: region.name, worldScore: worldScore,
            neighbourDegrees: neighbourDegrees(publishers: near.publishers), neighbourStories: near.stories,
            neighbourPublishers: near.publishers,
            domesticDegrees: domesticDegrees(publishers: home.publishers), domesticStories: home.stories,
            domesticPublishers: home.publishers)
        return result.degrees > 0 ? result : nil
    }

    /// `history` with the readings of the last `shownDays` days raised by what was near the reader in the week before
    /// each, the lens kept beside the score. Older readings, and every reading without a region, are as they were.
    static func apply(to history: [WorldTensionReading], stories: [TensionLocalStory], region: Region?, now: Date)
        -> [WorldTensionReading]
    {
        guard let region else { return history }
        let today = TensionMethodology.day(containing: now).start
        let earliest = today.addingTimeInterval(-Double(shownDays - 1) * 86400)
        return history.map { reading in
            guard reading.id >= earliest,
                let near = evidence(
                    stories, region: region, endingAt: min(now, reading.id.addingTimeInterval(86400)),
                    worldScore: reading.assessment.score)
            else { return reading }
            var shown = reading
            shown.assessment.nearYou = near
            shown.assessment.score = min(100, reading.assessment.score + near.degrees)
            return shown
        }
    }
}

extension DatabaseEngine {
    /// The stories published since `date` whose title holds one of `words`, for the Near you lens. This only narrows
    /// the library to titles that can matter; the lens checks whole words and cues itself.
    func tensionLocalStories(since date: Date, words: [String]) throws -> [TensionLocalStory] {
        guard !words.isEmpty else { return [] }
        let clause = Array(repeating: "lower(a.title) LIKE ?", count: words.count).joined(separator: " OR ")
        // The reader's library: stories of panel feeds the reader has not subscribed to stay out, as in every list.
        let scope = collectionScope()
        let rows = try eventRows(
            """
            SELECT a.title, a.source, a.published_at FROM articles a
            WHERE \(Self.visibleArticle) \(scope.sql) AND a.published_at >= ? AND (\(clause))
            ORDER BY a.published_at;
            """,
            scope.params.map { .text("\($0.val)") } + [.real(date.timeIntervalSince1970)]
                + words.map { .text("%\($0)%") })
        return rows.compactMap { row in
            guard let title = row[0], let publisher = row[1], let seconds = row[2].flatMap(Double.init) else {
                return nil
            }
            return TensionLocalStory(title: title, publisher: publisher, date: Date(timeIntervalSince1970: seconds))
        }
    }
}
