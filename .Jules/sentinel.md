
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2026-10-06 - NSWorkspace URL Scheme Execution

**Vulnerability:** In macOS applications, passing untrusted URLs (e.g., links from RSS feeds) directly to `NSWorkspace.shared.open(url)` can result in arbitrary execution of system protocol handlers or local file access if the scheme is not explicitly restricted.

**Learning:** `NSWorkspace.shared.open` automatically resolves and executes registered URL schemes, including `file://`, `ftp://`, or custom application triggers like `shortcuts://`. This is an unexpected trust boundary when rendering untrusted content.

**Prevention:** Always explicitly validate the URL scheme against an allowlist (e.g., strictly `http` and `https`) before calling `NSWorkspace.shared.open()` or `openURL` when the URL originates from an untrusted source or user input.
