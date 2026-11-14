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

// Angelia · Iris (acquisition) owns this file. Register: docs/ANGELIA.md.

import Foundation

/// Parses the publication dates feeds emit: ISO 8601, RFC 822 and the zone-less and date-only variants seen in
/// practice.
struct DateParser {
    /// Unknown publication dates remain stable across refreshes; storage orders them by ingestion time.
    static let unknownDate = Date.distantPast

    /// Parses a feed date string, trying ISO 8601 first and then fixed POSIX patterns in UTC. A zone-less date is read
    /// as UTC, and a wrong weekday is ignored when the rest of the date is valid.
    ///
    /// - Returns: Nil for an empty string, one longer than 512 bytes, or one no pattern matches.
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
            "E, d MMM yyyy, HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm Z",
            "d-MMM-yyyy HH:mm:ss zzz",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss Z zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mmZZZZZ",
            "yyyy-MM-dd HH:mm:ss",
            "MMM d, yyyy",
            // Zone-less and date-only forms some feeds emit; UTC is assumed. An unparsed date would leave the story
            // undated, ordered by ingestion time and never clustered.
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd",
            "E, d MMM yyyy HH:mm:ss",
            "d MMM yyyy HH:mm:ss",
            "E, d MMM yyyy",
        ]

        for fmt in formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: trimmed) {
                return d
            }
        }

        // A wrong weekday fails the strict patterns above; the date itself is still good.
        if let comma = trimmed.firstIndex(of: ","), trimmed[..<comma].allSatisfy({ $0.isASCII && $0.isLetter }) {
            let withoutWeekday = String(trimmed[trimmed.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            for format in ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: withoutWeekday) { return date }
            }
        }
        return nil
    }

    /// Zone names feeds use beyond RFC 822's, as offsets; DateFormatter does not know them (#796). IST is India's, the
    /// common case in English news feeds.
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
        // Day first ("Fri, 30 Oct 26 10:00") or month first ("Oct 30, 26"). With two groups, "$120" is group 1
        // followed by "20".
        text.replacingOccurrences(
            of: #"^((?:[A-Za-z]+,\s*)?\d{1,2}\s+[A-Za-z]+\s+|[A-Za-z]+\s+\d{1,2},\s*)(\d{2})(?=\s|$)"#,
            with: "$120$2", options: .regularExpression)
    }
}
