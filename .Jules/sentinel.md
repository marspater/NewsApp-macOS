
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2024-11-20 - XML External Entity (XXE) Vulnerability in OPML Parsing

**Vulnerability:** The `OPMLParser.parse(data:)` method initialized an `XMLParser` to process user-provided OPML data but did not explicitly disable the resolution of external entities. This created an XML External Entity (XXE) vulnerability, allowing potentially malicious OPML files to attempt accessing local files or making SSRF requests when parsed.

**Learning:** Foundation's `XMLParser` does not default to secure settings for untrusted input. When parsing untrusted XML (like imported OPML or RSS feeds), default configurations can expose applications to XXE attacks.

**Prevention:** Always explicitly set `xmlParser.shouldResolveExternalEntities = false` (and optionally disable namespace/prefix processing if not needed) immediately after initializing an `XMLParser` with untrusted data to prevent it from resolving external entities.
