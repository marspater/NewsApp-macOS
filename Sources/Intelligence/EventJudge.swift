import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// One report as the judge sees it: its headline and the start of its feed summary.
struct EventJudgeReport: Sendable, Hashable {
    static let summaryPrefix = 600

    let id: String
    let title: String
    let summary: String

    init(id: String, title: String, summary: String) {
        self.id = id
        self.title = title
        self.summary = String(summary.prefix(Self.summaryPrefix))
    }
}

/// Settles pairs the deterministic rules leave open (`EventPairAssessment.isBorderline`). It never overrides a hard
/// conflict. `nil` means no judgement is available, and the deterministic decision stands.
struct EventJudge: Sendable {
    /// False when no judgement can come back, so callers skip preparing questions for it.
    var isAvailable = true
    let sameEvent: @Sendable (EventJudgeReport, EventJudgeReport) async -> Bool?

    static let unavailable = EventJudge(isAvailable: false) { _, _ in nil }
    /// The on-device model when Apple Intelligence is ready; each call returns nil otherwise.
    static let onDevice = EventJudge { await OnDeviceEventJudge.shared.sameEvent($0, $1) }
}

/// Asks the on-device model, once per pair of report texts. Reports are untrusted data, framed and sanitized.
actor OnDeviceEventJudge {
    static let shared = OnDeviceEventJudge()
    // ponytail: process-lifetime cache cleared at 5,000 entries; pairs come from a 72-hour window, so it stays small.
    private var cache: [String: Bool] = [:]

    func sameEvent(_ a: EventJudgeReport, _ b: EventJudgeReport) async -> Bool? {
        let key = [a, b].map { "\($0.id)\u{1}\($0.title)\u{1}\($0.summary.hashValue)" }.sorted().joined(
            separator: "\u{2}")
        if let known = cache[key] { return known }
        #if canImport(FoundationModels)
            guard #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability else {
                return nil
            }
            do {
                // News reports violence, terror and death; the default guardrails refuse such text. Comparing two reports
                // is a content transformation, which the permissive guardrails allow for plain-text answers.
                let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                let session = LanguageModelSession(model: model)
                let response = try await session.respond(
                    to: Self.prompt(a, b), options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 8))
                guard let same = Self.verdict(response.content) else { return nil }
                if cache.count >= 5_000 { cache.removeAll() }
                cache[key] = same
                return same
            } catch {
                return nil
            }
        #else
            return nil
        #endif
    }

    /// The first word of the answer; anything else is no judgement.
    static func verdict(_ answer: String) -> Bool? {
        switch answer.uppercased().split(whereSeparator: { !$0.isLetter }).first {
        case "SAME": return true
        case "DIFFERENT": return false
        default: return nil
        }
    }

    /// Event boundaries follow the labelled corpus: reactions and immediate consequences belong to the occurrence;
    /// related but separate acts do not.
    static func prompt(_ a: EventJudgeReport, _ b: EventJudgeReport) -> String {
        """
        \(GenerationPromptDefense.untrustedDataSystemGuard)

        Decide whether two news reports describe the same event.
        Same event: one concrete occurrence, such as one attack, one vote, one announcement, one death, one award or \
        one court ruling. Reports still describe the same event when their wording, emphasis or casualty figures differ, \
        or when they add reactions to it and its immediate consequences.
        Different events: separate occurrences, even if related, in the same place or in the same series. Examples: \
        another attack on another day or in another city, another vote, another quarter's results, a statement about \
        another matter, or a background feature that is not about this occurrence.
        Reports from different publishers often describe the same event from different angles and in different words.
        Answer with exactly one word: SAME or DIFFERENT.

        Report A:
        \(GenerationPromptDefense.frameArticleData(title: a.title, description: a.summary))

        Report B:
        \(GenerationPromptDefense.frameArticleData(title: b.title, description: b.summary))
        """
    }
}
