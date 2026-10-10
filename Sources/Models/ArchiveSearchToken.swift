import Foundation

/// One search-field chip. ArticleFilterQuery remains the authority for archive filtering.
struct ArchiveSearchToken: Hashable, Identifiable {
    let expression: String
    var id: String { expression }

    /// Prefix-only source/category expressions remain editable until their value is supplied.
    init?(completedExpression: String) {
        let candidate = completedExpression.lowercased()
        if ["is:unread", "is:read", "is:saved"].contains(candidate) {
            expression = candidate
        } else if (candidate.hasPrefix("source:") && candidate.count > "source:".count)
                    || (candidate.hasPrefix("category:") && candidate.count > "category:".count) {
            guard !candidate.contains(where: \.isWhitespace) else { return nil }
            expression = candidate
        } else {
            return nil
        }
    }

    static func query(text: String, tokens: [ArchiveSearchToken]) -> String {
        (tokens.map(\.expression) + [text.trimmingCharacters(in: .whitespacesAndNewlines)])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Promote only finished operator words; preserve free text and unfinished filters.
    static func promoteCompleted(in text: String) -> (text: String, tokens: [ArchiveSearchToken]) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let endsWithSpace = text.last?.isWhitespace == true
        var remaining: [String] = []
        var tokens: [ArchiveSearchToken] = []
        for (index, word) in words.enumerated() {
            if (index < words.count - 1 || endsWithSpace),
               let token = ArchiveSearchToken(completedExpression: word) {
                tokens.append(token)
            } else {
                remaining.append(word)
            }
        }
        return (remaining.joined(separator: " "), tokens)
    }
}
