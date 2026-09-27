
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2024-05-24 - XML External Entity (XXE) Vulnerability in OPML Parsing

**Vulnerability:** The `OPMLParser` used an `XMLParser` initialized directly with data without disabling `shouldResolveExternalEntities`. This allowed for an XML External Entity (XXE) vulnerability when parsing untrusted OPML or XML files imported by the user. An attacker could craft a malicious OPML file with arbitrary external entities which `XMLParser` would attempt to resolve by accessing local files or initiating SSRF network requests.

**Learning:** Any use of `XMLParser` to parse untrusted XML must explicitly have `shouldResolveExternalEntities = false` set immediately after initialization to prevent XXE. Even for seemingly simple configurations, failure to opt-out of external entity resolution opens up the application to local file disclosure and SSRF attacks.

**Prevention:** Always initialize `XMLParser` securely by explicitly setting `shouldResolveExternalEntities = false` and considering whether `shouldProcessNamespaces` or `shouldReportNamespacePrefixes` are needed. Code reviews should specifically look for new instances of `XMLParser` that lack these properties.
