
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2025-02-28 - XXE Vulnerability in OPML Parsing

**Vulnerability:** In `OPMLManager.swift`, the `XMLParser` used to parse untrusted imported OPML files did not explicitly disable the resolution of external entities. This left the application susceptible to XML External Entity (XXE) vulnerabilities, which could potentially be leveraged for local file disclosure or SSRF via malicious XML documents.

**Learning:** When using Foundation's `XMLParser` in Swift to process untrusted XML input, `shouldResolveExternalEntities` defaults to `true` on older operating systems or without explicit configuration, unlike some modern XML parsers which default to secure behaviors. The memory section also explicitly stated that `shouldResolveExternalEntities = false` must be set immediately after initialization.

**Prevention:** Always explicitly set `shouldResolveExternalEntities = false` on instances of `XMLParser` used for parsing untrusted input like RSS feeds or OPML files to prevent XXE.
