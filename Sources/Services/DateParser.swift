import Foundation

struct DateParser {
    /// Unknown publication dates remain stable across refreshes; storage orders them by ingestion time.
    static let unknownDate = Date.distantPast

    static func parse(_ dateString: String) -> Date? {
        var trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFormatter.date(from: trimmed) { return d }

        isoFormatter.formatOptions = [.withInternetDateTime]
        if let d = isoFormatter.date(from: trimmed) { return d }

        trimmed = Self.fourDigitYear(Self.numericZone(trimmed))
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

    /// Zone names feeds use beyond RFC 822's, as offsets; DateFormatter does not know them and FeedKit's fallback
    /// mis-offsets them (#796). IST is India's, the common case in English news feeds.
    private static let zoneOffsets = [
        "BST": "+0100", "IST": "+0530", "CET": "+0100", "CEST": "+0200", "EET": "+0200", "EEST": "+0300",
        "WET": "+0000", "WEST": "+0100", "MSK": "+0300", "JST": "+0900", "KST": "+0900", "HKT": "+0800",
        "SGT": "+0800", "AEST": "+1000", "AEDT": "+1100", "ACST": "+0930", "AWST": "+0800", "NZST": "+1200",
        "NZDT": "+1300",
    ]

    private static func numericZone(_ text: String) -> String {
        guard let space = text.lastIndex(of: " "), let offset = zoneOffsets[String(text[text.index(after: space)...])]
        else { return text }
        return String(text[..<space]) + " " + offset
    }

    /// RFC 822 and RSS 2.0 allow two-digit years, which the four-digit patterns read as years 0-99. The year is
    /// widened in the text, before parsing, so a zone offset cannot carry year 99 into year 100 first.
    private static func fourDigitYear(_ text: String) -> String {
        // With two groups, "$120" is group 1 followed by "20".
        text.replacingOccurrences(
            of: #"^((?:[A-Za-z]+,\s*)?\d{1,2}\s+[A-Za-z]+\s+)(\d{2})(?=\s)"#, with: "$120$2",
            options: .regularExpression)
    }
}
