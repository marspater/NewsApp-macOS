import Foundation

/// HTTP validators a publisher returned with a feed body, replayed to ask whether the feed changed.
/// Response headers are untrusted: only short printable ASCII is kept, so a hostile value cannot
/// inject headers or grow the stored row.
struct FeedValidators: Equatable, Sendable {
    static let maximumLength = 512

    let etag: String?
    let lastModified: String?

    init(etag: String?, lastModified: String?) {
        self.etag = Self.sanitized(etag)
        self.lastModified = Self.sanitized(lastModified)
    }

    init(response: HTTPURLResponse) {
        self.init(etag: response.value(forHTTPHeaderField: "ETag"),
                  lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
    }

    var isEmpty: Bool { etag == nil && lastModified == nil }

    private static func sanitized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
              value.utf8.count <= maximumLength,
              value.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return value
    }
}
