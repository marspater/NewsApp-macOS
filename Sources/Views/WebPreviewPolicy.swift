import WebKit

/// WebKit implicitly bypasses native proxies for local destinations. Block those URL
/// forms before resource loading; ordinary publisher domains still use the pinned gateway.
@MainActor
enum WebPreviewPolicy {
    private static var compiled: Task<WKContentRuleList, Error>?

    /// A navigation without a target frame opens a new window and counts as a main-frame navigation.
    nonisolated static func isMainFrame(targetFrameIsMain: Bool?) -> Bool {
        targetFrameIsMain ?? true
    }

    /// What a navigation the network policy refused does: it is always cancelled, but only a refused main-frame
    /// navigation reports an error; a blocked iframe is dropped quietly and leaves the page and its progress alone.
    nonisolated static func refusalPolicy(isMainFrame: Bool) -> (decision: WKNavigationActionPolicy, error: String?) {
        (
            .cancel,
            isMainFrame
                ? "This address was blocked by the app’s network policy. Open the publisher in your browser if needed."
                : nil
        )
    }

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
                #"^file:"#, #"^ftp:"#, #"^ws:"#, #"^wss:"#,
            ]
            let rules = filters.map {
                ["trigger": ["url-filter": $0, "url-filter-is-case-sensitive": false], "action": ["type": "block"]]
                    as [String: Any]
            }
            let data = try JSONSerialization.data(withJSONObject: rules)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                throw FeedError.network("Preview policy encoding failed")
            }
            // The default store is keyed by process name, so concurrent processes of one binary
            // (parallel test runners, a second app instance) overwrite each other's compiled file
            // and fail with WKErrorDomain Code=6. Rules compile once per launch; keep them private.
            let storeURL = FileManager.default.temporaryDirectory
                .appending(path: "NewsContentRules-\(ProcessInfo.processInfo.processIdentifier)")
            guard let store = WKContentRuleListStore(url: storeURL) else {
                throw FeedError.network("Preview policy store unavailable")
            }
            return try await withCheckedThrowingContinuation { continuation in
                store.compileContentRuleList(
                    forIdentifier: "NewsProtectedPreview-v1",
                    encodedContentRuleList: jsonString
                ) { list, error in
                    if let list {
                        continuation.resume(returning: list)
                    } else {
                        continuation.resume(throwing: error ?? FeedError.network("Preview policy unavailable"))
                    }
                }
            }
        }
        compiled = task
        do { return try await task.value } catch {
            compiled = nil
            throw error
        }
    }
}
