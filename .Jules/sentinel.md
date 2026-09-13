
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2026-09-13 - OPML XML External Entity (XXE)

**Vulnerability:** OPML files are parsed using `XMLParser`. In `OPMLManager.swift`, the parser was initialized without disabling external entity resolution (`shouldResolveExternalEntities = false`). This exposes the application to XXE attacks when parsing untrusted OPML subscriptions, which could be exploited for arbitrary local file reads or Server-Side Request Forgery (SSRF).

**Learning:** Swift's `XMLParser` resolves external entities by default. Whenever processing untrusted XML inputs (like OPML or RSS feeds), this behavior must be explicitly disabled to preserve trust boundaries.

**Prevention:** Always set `shouldResolveExternalEntities = false` immediately after initializing `XMLParser` unless external entity resolution is explicitly required and the source is highly trusted.
