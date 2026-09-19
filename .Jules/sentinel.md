
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2024-05-23 - XML External Entity (XXE) Vulnerability in OPML Parsing

**Vulnerability:** In `OPMLManager.swift`, the `OPMLParser` used `XMLParser` to parse OPML (XML) files, which can be untrusted input (e.g. imported subscriptions from third-party sources or users). However, `XMLParser`'s `shouldResolveExternalEntities` property was left at its default value (`true` or unconfigured), which can expose the application to XML External Entity (XXE) attacks, allowing an attacker to read local files or execute Server-Side Request Forgery (SSRF) via crafted XML payloads.

**Learning:** When using `XMLParser` (or any XML parsing library) to process untrusted XML input, it is critical to explicitly disable the resolution of external entities. Even if the library's documentation claims secure defaults, explicitly setting `shouldResolveExternalEntities = false` provides a guaranteed defense-in-depth against XXE vulnerabilities. The `FeedXMLParser.swift` already had this protection, but it was missing in `OPMLManager.swift`.

**Prevention:** Always explicitly set `shouldResolveExternalEntities = false` on `XMLParser` instances immediately after initialization when parsing XML data from untrusted sources, such as feeds or imported files.
