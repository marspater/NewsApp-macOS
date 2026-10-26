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
            return try await withCheckedThrowingContinuation { continuation in
                WKContentRuleListStore.default().compileContentRuleList(
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
