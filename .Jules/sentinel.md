
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2026-03-30 - WebKit JavaScript Content Execution Disablement

**Vulnerability:** In `ArticleWebView.swift`, `preferences.allowsContentJavaScript` was set to `true`. When rendering untrusted third-party web content or RSS feed web views inside `WKWebView`, active JavaScript execution exposes the app to Cross-Site Scripting (XSS) risks, tracking scripts, and client-side code execution vectors.

**Learning:** Embedded web views used primarily for reading static web articles should enforce a strict least-privilege security model by default. Enabling JavaScript when rendering untrusted third-party web content creates an unnecessary attack surface for XSS exploits.

**Prevention:** Always set `preferences.allowsContentJavaScript = false` on `WKWebpagePreferences` (or `configuration.defaultWebpagePreferences`) for WKWebView instances that render untrusted third-party content unless client-side JavaScript execution is specifically required.
