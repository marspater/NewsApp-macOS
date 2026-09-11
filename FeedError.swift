import Foundation

/// Strongly-typed error domain for feed operations, network security, and content ingestion.
enum FeedError: LocalizedError, Equatable, Sendable {
    case malformedURL(String)
    case insecureScheme(String)
    case blockedPort(Int)
    case blockedHost(host: String, reason: String)
    case redirectBlocked(from: String, to: String, reason: String)
    case tooManyRedirects(Int)
    case dnsRebindingDetected(host: String, ip: String)
    case responseTooLarge(bytes: Int64, maxAllowed: Int64)
    case httpStatus(Int)
    case unsupportedFormat(String)
    case parseFailed(String)
    case network(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .malformedURL(let url):
            return "Malformed URL: \(url)"
        case .insecureScheme(let scheme):
            return "Insecure or unsupported scheme '\(scheme)'. Only HTTPS (or HTTP) allowed."
        case .blockedPort(let port):
            return "Port \(port) is blocked for security reasons."
        case .blockedHost(let host, let reason):
            return "Security Block: Host '\(host)' rejected (\(reason))."
        case .redirectBlocked(let from, let to, let reason):
            return "Security Block: Redirect from \(from) to \(to) rejected (\(reason))."
        case .tooManyRedirects(let count):
            return "Exceeded maximum redirect limit (\(count) redirects)."
        case .dnsRebindingDetected(let host, let ip):
            return "Security Block: Connection destination '\(ip)' for '\(host)' is forbidden (DNS rebinding prevention)."
        case .responseTooLarge(let bytes, let maxAllowed):
            let mb = Double(bytes) / (1024 * 1024)
            let limitMb = Double(maxAllowed) / (1024 * 1024)
            return String(format: "Payload too large (%.1f MB exceeds %.1f MB limit).", mb, limitMb)
        case .httpStatus(let code):
            return "Server returned HTTP error status code \(code)."
        case .unsupportedFormat(let format):
            return "Unsupported feed format: \(format)."
        case .parseFailed(let reason):
            return "Failed to parse feed: \(reason)"
        case .network(let message):
            return "Network error: \(message)"
        case .timeout:
            return "Request timed out."
        }
    }
}
