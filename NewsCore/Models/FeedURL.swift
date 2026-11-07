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

/// Feed subscription address normalization, shared by the catalog, advisories and `AppSettings`.
enum FeedURL {
    /// Normalizes and validates a feed subscription URL using URLComponents.
    /// Handles scheme upgrades, host lowercasing and the bare root slash. A trailing slash on a non-root path is part of
    /// the address: some publishers serve the feed only with it, and answer the slashless form with 403, 404 or a
    /// redirect that downgrades to HTTP.
    static func normalizeFeedURL(_ raw: String, allowInsecureHTTP: Bool = false) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A pasted `feed:` address wraps the real one: feed://host/path or feed:https://host/path (#797).
        // `feed:8443/rss` stays a host named feed with a port.
        if trimmed.lowercased().hasPrefix("feed:") {
            let rest = String(trimmed.dropFirst(5))
            let unwrapped = rest.hasPrefix("//") ? String(rest.dropFirst(2)) : rest
            let target = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerTarget = target.lowercased()
            if rest.hasPrefix("//") || lowerTarget.hasPrefix("http://") || lowerTarget.hasPrefix("https://") {
                trimmed = target
            }
        }
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let hasScheme = lower.hasPrefix("https://") || lower.hasPrefix("http://")
        if !hasScheme {
            // Any other scheme (ftp://, webcal://, file:, javascript:) is not a feed address; host:port still is.
            let head = lower.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            // Known non-web schemes are refused before the user:password@ reading below, which would accept
            // `ftp:user:pass@host`. ponytail: a fixed list; a bare `scheme:user@host` outside it reads as credentials.
            if refusedFeedScheme(trimmed) != nil { return nil }
            // The port follows any user:password@ and a bracketed IPv6 literal.
            var hostPort = head.split(separator: "@", omittingEmptySubsequences: false).last ?? head
            if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
                hostPort = hostPort[hostPort.index(after: close)...]
            }
            if let colon = hostPort.firstIndex(of: ":") {
                let port = hostPort[hostPort.index(after: colon)...]
                if port.isEmpty || !port.allSatisfy(\.isNumber) { return nil }
            }
        }
        let withScheme = hasScheme ? trimmed : "https://" + trimmed

        guard let url = URL(string: withScheme),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host, !host.isEmpty
        else {
            return nil
        }

        components.scheme = components.scheme?.lowercased()
        components.host = host.lowercased()
        if !allowInsecureHTTP && components.scheme == "http" {
            components.scheme = "https"
        }

        if components.path == "/" { components.path = "" }

        return components.url?.absoluteString
    }

    private static let nonWebSchemes: Set<Substring> = [
        "ftp", "ftps", "sftp", "file", "webcal", "mailto", "javascript", "data", "smb", "afp", "ssh", "news",
    ]

    /// The known non-web scheme an address names, such as `ftp`, or nil.
    static func refusedFeedScheme(_ raw: String) -> String? {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let head = lower.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard let colon = head.firstIndex(of: ":"), nonWebSchemes.contains(head[..<colon]) else { return nil }
        return String(head[..<colon])
    }

    /// Slash-insensitive subscription key: `/feed` and `/feed/` are one subscription even though only one form may work.
    static func feedKey(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        if components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        return components.url?.absoluteString ?? url
    }
}
