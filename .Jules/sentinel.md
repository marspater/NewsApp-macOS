
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2024-11-20 - URL Scheme Bypass via Redirects

**Vulnerability:** `SecureHTTPClient` strictly validated `http` and `https` schemes for initial requests, but its `URLSessionTaskDelegate` redirect handler failed to restrict the `targetScheme` of redirects. An attacker could configure a malicious server to redirect the client to arbitrary schemes (e.g. `ftp://`, `smb://`, or custom application schemes) with a public host, bypassing the initial scheme validation.

**Learning:** Security validations performed on the initial request (like scheme, host, port) must be re-applied with equal rigor to every redirect destination. `URLSession` will follow redirects to other schemes if not explicitly blocked in the delegate.

**Prevention:** Always enforce an explicit whitelist of allowed schemes (e.g., `["http", "https"]`) within `urlSession(_:willPerformHTTPRedirection:...)` before evaluating host policies or downgrades.
