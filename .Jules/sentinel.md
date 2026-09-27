
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2023-10-31 - XML External Entity (XXE) Vulnerability in OPML Import

**Vulnerability:** The `OPMLParser` in `OPMLManager.swift` used `XMLParser(data:)` to parse user-provided (or imported) OPML files without explicitly setting `shouldResolveExternalEntities = false`. This made the application vulnerable to XML External Entity (XXE) injection attacks, where a malicious OPML file could potentially trick the parser into reading local files or making SSRF requests.

**Learning:** `XMLParser` in Swift does not disable external entity resolution by default in all contexts or older OS versions. When processing untrusted XML inputs (such as OPML or RSS feeds), `shouldResolveExternalEntities` must be explicitly disabled to prevent XXE.

**Prevention:** Always set `shouldResolveExternalEntities = false` immediately after initializing `XMLParser` for any untrusted input.
