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

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// The on-device importance rating, kept for the opt-in live curation measurement (`measureLiveCuration`, #309) only.
/// The app never rates importance, so it lives in the test build (#549). It asks the on-device model once per report
/// text; reports are untrusted data, framed and sanitized.
actor OnDeviceImportanceJudge {
    static let shared = OnDeviceImportanceJudge()
    // ponytail: process-lifetime cache cleared at 5,000 entries; stories come from a 72-hour window.
    private var cache: [String: StoryImportance] = [:]

    func rate(_ report: EventJudgeReport) async -> StoryImportance? {
        let key = "\(report.id)\u{1}\(report.title)\u{1}\(report.summary.hashValue)"
        if let known = cache[key] { return known }
        guard let level = await Self.modelRating(report) else { return nil }
        if cache.count >= 5_000 { cache.removeAll() }
        cache[key] = level
        return level
    }

    /// One fresh model answer that bypasses the cache; nil without the model. Production rates greedily, so the same text
    /// always gets the same level. The #309 stability re-rate passes `sampled` to draw from the model's top 90% instead,
    /// which shows how close a rating sits to the boundary between levels.
    static func modelRating(_ report: EventJudgeReport, sampled: Bool = false) async -> StoryImportance? {
        #if canImport(FoundationModels)
            guard #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability else {
                return nil
            }
            do {
                // Like the event judge: news text needs the content-transformation guardrails and a plain-text answer.
                let session = LanguageModelSession(
                    model: SystemLanguageModel(guardrails: .permissiveContentTransformations))
                let response = try await session.respond(
                    to: prompt(report),
                    options: GenerationOptions(
                        samplingMode: sampled ? .random(probabilityThreshold: 0.9) : .greedy,
                        maximumResponseTokens: 8))
                return level(response.content)
            } catch {
                return nil
            }
        #else
            return nil
        #endif
    }

    /// The first word of the answer; anything else is no rating.
    static func level(_ answer: String) -> StoryImportance? {
        switch answer.uppercased().split(whereSeparator: { !$0.isLetter }).first {
        case "MAJOR": return .major
        case "NOTABLE": return .notable
        case "MINOR": return .minor
        default: return nil
        }
    }

    static func report(_ row: EventMatchRow) -> EventJudgeReport {
        EventJudgeReport(id: row.id, title: row.title, summary: row.description)
    }

    static func prompt(_ report: EventJudgeReport) -> String {
        """
        \(GenerationPromptDefense.untrustedDataSystemGuard)

        Rate how important this news story is for a general reader who follows world news.
        MAJOR: affects many people, a whole country or a market. Examples: wars and major attacks, disasters with \
        deaths, elections and major government decisions, major court rulings, deaths of prominent people, major \
        economic or company news, public health emergencies.
        NOTABLE: significant national or international news with a narrower reach.
        MINOR: local or niche news, celebrity and lifestyle, sports results, features, opinion, explainers, live blogs, \
        quizzes, how-to and shopping.
        Media or industry business news, such as programme cuts at a broadcaster, is MINOR unless it affects a \
        whole sector or national policy.
        Incidents at military sites count by consequence: trespass arrests are MINOR; damage, sabotage, terrorism \
        charges or a real security breach are NOTABLE.
        Nationwide price changes of staple goods are NOTABLE; a change by one company or in one region is MINOR.
        Answer with exactly one word: MAJOR, NOTABLE or MINOR.

        \(GenerationPromptDefense.frameArticleData(title: report.title, description: report.summary))
        """
    }
}
