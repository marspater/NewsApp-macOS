import WebKit

/// WebKit implicitly bypasses native proxies for local destinations. Block those URL
/// forms before resource loading; ordinary publisher domains still use the pinned gateway.
@MainActor
enum WebPreviewPolicy {
    private static var compiled: Task<WKContentRuleList, Error>?

    static func contentRules() async throws -> WKContentRuleList {
        if let compiled { return try await compiled.value }
        let task = Task { @MainActor in
            // Block numeric literals (including alternate IPv4 forms), single-label hosts,
            // localhost and mDNS names. Publishers using IP-only URLs can open in a browser.
            let filters = [
                #"^https?://([^/]*@)?\[[^]]+\](:[0-9]+)?/"#,
                #"^https?://([^/]*@)?[0-9.]+(:[0-9]+)?/"#,
                #"^https?://([^/]*@)?[a-z0-9-]+[.]?(:[0-9]+)?/"#,
                #"^https?://([^/]*@)?([^/]+[.])?localhost[.]?(:[0-9]+)?/"#,
                #"^https?://([^/]*@)?([^/]+[.])?local[.]?(:[0-9]+)?/"#,
                #"^file:"#, #"^ftp:"#, #"^ws:"#, #"^wss:"#
            ]
            let rules = filters.map { ["trigger": ["url-filter": $0, "url-filter-is-case-sensitive": false], "action": ["type": "block"]] as [String: Any] }
            let data = try JSONSerialization.data(withJSONObject: rules)
            return try await withCheckedThrowingContinuation { continuation in
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "NewsProtectedPreview-v1", encodedContentRuleList: String(decoding: data, as: UTF8.self)) { list, error in
                    if let list { continuation.resume(returning: list) }
                    else { continuation.resume(throwing: error ?? FeedError.network("Preview policy unavailable")) }
                }
            }
        }
        compiled = task
        do { return try await task.value }
        catch { compiled = nil; throw error }
    }
}
