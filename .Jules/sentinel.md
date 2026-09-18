
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2024-11-20 - XML External Entity (XXE) Prevention in OPML Parser

**Vulnerability:** The OPML parser in `OPMLManager.swift` used `XMLParser` to process OPML feeds, which are untrusted external inputs. `XMLParser` by default allows the resolution of external entities. If a malicious OPML file contained external entity definitions (e.g. pointing to local files on the system using `file://` URIs), parsing it could lead to arbitrary local file disclosure (XXE vulnerability).

**Learning:** When using `XMLParser` in Swift to process untrusted XML inputs (like OPML or RSS feeds), `shouldResolveExternalEntities = false` must be explicitly set immediately after initialization to prevent XXE vulnerabilities.

**Prevention:** Always verify that `shouldResolveExternalEntities = false` is set on all newly instantiated `XMLParser` objects processing untrusted content.
