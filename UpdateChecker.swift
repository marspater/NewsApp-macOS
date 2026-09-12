// UpdateChecker.swift

import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

/// Strict semantic version representation (major.minor.patch).
struct SemanticVersion: Equatable, Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    /// Parses strict SemVer strings formatted as `vX.Y.Z` or `X.Y.Z`.
    /// Rejects leading zeros (e.g. `001.002.003`) per SemVer 2.0.0 specification.
    /// Rejects non-conforming tags (e.g. `release-2.0.1`, `v2.0`, `foo`).
    static func parse(_ raw: String) -> SemanticVersion? {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("v") || str.hasPrefix("V") {
            str.removeFirst()
        }
        let parts = str.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        // Reject components with leading zeros (e.g. "01", "002") per SemVer 2.0.0
        for part in parts {
            guard !part.isEmpty else { return nil }
            if part.count > 1 && part.first == "0" {
                return nil
            }
            guard part.allSatisfy({ $0.isNumber }) else {
                return nil
            }
        }

        guard let maj = Int(parts[0]),
              let min = Int(parts[1]),
              let pat = Int(parts[2]),
              maj >= 0, min >= 0, pat >= 0 else {
            return nil
        }
        return SemanticVersion(major: maj, minor: min, patch: pat)
    }


    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// Decodable payload from GitHub Releases API.
struct GitHubReleasePayload: Codable, Sendable {
    let tagName: String
    let name: String?
    let htmlUrl: String
    let body: String?
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlUrl = "html_url"
        case body
        case publishedAt = "published_at"
    }
}

/// Informational-only update detector querying the public GitHub Releases API.
///
/// Security & Architecture Constraints:
/// - Informational only: NEVER downloads, executes, replaces, or installs application binaries.
/// - Validates remote release URLs strictly against `https://github.com/marspater/NewsApp-macOS/releases/*`.
/// - Enforces 6-hour automatic throttling cache while allowing manual bypass.
/// - Validates strict SemVer before flagging updates.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var isChecking: Bool = false
    @Published var updateAvailable: Bool = false
    @Published var latestVersionString: String? = nil
    @Published var releaseNotes: String? = nil
    @Published var verifiedReleaseURL: URL? = nil
    @Published var lastCheckDate: Date? = nil
    @Published var statusMessage: String? = nil

    private let logger = Logger(subsystem: "com.marspater.news", category: "UpdateChecker")
    private let minimumCheckInterval: TimeInterval = 6 * 3600 // 6 hours

    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
    }

    /// Checks for newer releases on GitHub.
    /// - Parameter userInitiated: If true, bypasses the 6-hour cache.
    func checkForUpdates(userInitiated: Bool = false) async {
        if !userInitiated, let last = lastCheckDate, Date().timeIntervalSince(last) < minimumCheckInterval {
            logger.debug("Skipping automatic update check; cached within 6-hour window.")
            return
        }

        guard !isChecking else { return }
        isChecking = true
        statusMessage = "Checking for updates..."
        defer { isChecking = false }

        let endpoint = "https://api.github.com/repos/marspater/NewsApp-macOS/releases/latest"
        guard let url = URL(string: endpoint) else {
            statusMessage = "Invalid update endpoint"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NewsApp/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                statusMessage = "Invalid server response"
                return
            }

            if httpResponse.statusCode == 404 {
                statusMessage = "NewsApp is up to date (v\(currentAppVersion))"
                updateAvailable = false
                lastCheckDate = Date()
                return
            }

            guard httpResponse.statusCode == 200 else {
                statusMessage = "Update check failed (HTTP \(httpResponse.statusCode))"
                return
            }

            let mime = httpResponse.mimeType?.lowercased() ?? ""
            guard mime.contains("json") else {
                statusMessage = "Invalid response content type"
                return
            }

            let payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)

            // Validate SemVer strictly
            guard let remoteVersion = SemanticVersion.parse(payload.tagName) else {
                logger.warning("Ignoring release tag with invalid SemVer: \(payload.tagName)")
                statusMessage = "No valid updates found"
                lastCheckDate = Date()
                return
            }

            guard let localVersion = SemanticVersion.parse(currentAppVersion) else {
                logger.error("Current app version \(self.currentAppVersion) is not valid SemVer")
                statusMessage = "App version configuration error"
                return
            }

            lastCheckDate = Date()

            if remoteVersion > localVersion {
                // Verify that html_url belongs strictly to expected GitHub repository releases
                guard let targetURL = URL(string: payload.htmlUrl),
                      Self.isValidReleaseURL(targetURL) else {
                    logger.error("Rejected untrusted release URL: \(payload.htmlUrl)")
                    statusMessage = "Received untrusted release URL"
                    return
                }

                self.updateAvailable = true
                self.latestVersionString = payload.tagName
                self.releaseNotes = payload.body
                self.verifiedReleaseURL = targetURL
                self.statusMessage = "Version \(payload.tagName) available"
                logger.info("Newer release found: \(payload.tagName)")
            } else {
                self.updateAvailable = false
                self.statusMessage = "NewsApp is up to date (v\(self.currentAppVersion))"
                logger.info("NewsApp is up to date.")
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription)")
            statusMessage = "Unable to check for updates"
        }
    }

    /// Verifies that a release URL is HTTPS, hosted on github.com, and scoped to the repository releases.
    nonisolated static func isValidReleaseURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else {
            return false
        }
        let path = url.path.lowercased()
        return path == "/marspater/newsapp-macos/releases" || path.hasPrefix("/marspater/newsapp-macos/releases/")
    }


    /// Securely opens the verified release webpage in the default browser.
    /// NEVER downloads, executes, or replaces local files.
    func openReleasePage() {
        guard let url = verifiedReleaseURL, Self.isValidReleaseURL(url) else {
            logger.warning("Cannot open invalid release URL")
            return
        }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
