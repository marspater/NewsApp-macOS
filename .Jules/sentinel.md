
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2024-05-24 - Avoid Ad-Hoc URLSession Instantiation

**Vulnerability:** In `UpdateChecker.swift`, the code initially used `URLSession.shared` without a delegate, which meant it was susceptible to automatically following malicious redirects to arbitrary protocols. During remediation, there is a temptation to instantiate a new `URLSession(configuration:delegate:delegateQueue:)` inline for a single request just to provide a secure delegate.

**Learning:** Creating a new `URLSession` per request is an anti-pattern that breaks HTTP connection pooling, prevents TLS session resumption, and often introduces memory leaks (as `URLSession` strongly retains its delegate until `finishTasksAndInvalidate()` is explicitly called).

**Prevention:** To secure one-off requests while maintaining performance and correct memory management, extend existing centralized abstractions (e.g. `SecureHTTPClient`) to support dynamic inputs (like `customHeaders`) and route the request through the shared, securely configured session instance.
