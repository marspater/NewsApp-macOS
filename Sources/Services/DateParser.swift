import Foundation

struct DateParser {
    static func parse(_ dateString: String) -> Date {
        let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFormatter.date(from: trimmed) { return d }
        
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let d = isoFormatter.date(from: trimmed) { return d }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        let formats = [
            "E, d MMM yyyy HH:mm:ss Z",
            "E, d MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "MMM d, yyyy"
        ]
        
        for fmt in formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: trimmed) {
                return d
            }
        }
        
        return Date()
    }
}
