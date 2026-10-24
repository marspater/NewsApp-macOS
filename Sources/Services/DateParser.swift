import Foundation

struct DateParser {
    /// Unknown publication dates remain stable across refreshes; storage orders them by ingestion time.
    static let unknownDate = Date.distantPast

    static func parse(_ dateString: String) -> Date? {
        let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFormatter.date(from: trimmed) { return d }

        isoFormatter.formatOptions = [.withInternetDateTime]
        if let d = isoFormatter.date(from: trimmed) { return d }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false

        let formats = [
            "E, d MMM yyyy HH:mm:ss Z",
            "E, d MMM yyyy HH:mm:ss zzz",
            "E, d MMM yyyy HH:mm zzz",
            "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "MMM d, yyyy",
            // Zone-less and date-only ISO 8601 forms some feeds emit; UTC is assumed. An unparsed date would leave the
            // story undated, ordered by ingestion time and never clustered.
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd",
        ]

        for fmt in formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: trimmed) {
                return d
            }
        }

        // FeedKit's date formatters are internal; retain the shared native parser for JSON aliases and raw XML dates.
        if let comma = trimmed.firstIndex(of: ","), trimmed[..<comma].allSatisfy({ $0.isASCII && $0.isLetter }) {
            let withoutWeekday = String(trimmed[trimmed.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            for format in ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: withoutWeekday) { return date }
            }
        }
        return nil
    }
}
