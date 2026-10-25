import Foundation

/// One report as the importance rater sees it: its headline and the start of its feed summary. The on-device event judge
/// that once read pairs of these was removed in matcher v12 (#580); clustering is deterministic plus the pair model.
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
