
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2024-09-24 - Prevent XXE Vulnerability in OPML Parsing

**Vulnerability:** The OPML parser used `XMLParser` without explicitly disabling external entity resolution, which could lead to XML External Entity (XXE) vulnerabilities when importing untrusted OPML files.

**Learning:** `XMLParser` does not disable external entity resolution by default in all configurations. Trust boundaries like OPML imports require explicit mitigation to prevent local file reads or SSRF via external entities.

**Prevention:** Always set `shouldResolveExternalEntities = false` when initializing `XMLParser` for any untrusted XML input, including OPML and RSS feeds.
