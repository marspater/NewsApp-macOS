
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2023-10-27 - Untrusted OPML XML External Entity (XXE) Parsing

**Vulnerability:** The `OPMLParser` used `XMLParser(data: data)` to parse user-provided (untrusted) OPML files without disabling external entity resolution. By default, iOS/macOS Foundation's `XMLParser` resolves external entities unless explicitly instructed otherwise. This could allow an attacker providing a maliciously crafted OPML file to trigger Server-Side Request Forgery (SSRF) or arbitrary local file reads.

**Learning:** Any use of `XMLParser` on untrusted input (like imported feeds or OPML files) must be explicitly hardened against XXE. The parser's default configuration does not protect against external entity expansion.

**Prevention:** Always set `shouldResolveExternalEntities = false` immediately after initializing an `XMLParser` when parsing untrusted XML input.
