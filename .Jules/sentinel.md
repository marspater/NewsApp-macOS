
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2026-09-16 - XML External Entity (XXE) Vulnerability in OPML Parsing

**Vulnerability:** The `OPMLParser` in `OPMLManager.swift` used Foundation's `XMLParser` to parse untrusted OPML files (which are XML documents) without explicitly disabling external entity resolution. This allowed a malicious OPML file to potentially perform Server-Side Request Forgery (SSRF) or read local files by defining and expanding external entities (XXE).

**Learning:** When using `XMLParser` in Swift to process untrusted or external XML inputs (such as OPML or RSS feeds), `shouldResolveExternalEntities` must be explicitly set to `false`. While modern environments may sometimes default to safe behavior, explicitly setting it guarantees prevention against XXE vulnerabilities.

**Prevention:** Always set `xmlParser.shouldResolveExternalEntities = false` immediately after instantiating an `XMLParser` when handling data from untrusted sources.
