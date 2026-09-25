
## 2023-10-27 - WebKit Navigation Host Bypass

**Vulnerability:** In `ArticleWebView.swift`, the `decidePolicyFor` delegate checked if the requested URL scheme was `http` or `https`. However, the subsequent validation of the URL's host using `IPAddressValidator` was conditionally executed inside an `if let host = requestURL.host` block. If the parsed `URL` had a `nil` or empty host (e.g. from a malformed URL like `http:///127.0.0.1` or `http:127.0.0.1` depending on Swift/WebKit URL parsing behaviors), the block was skipped entirely, bypassing the SSRF protection and allowing the navigation to proceed.

**Learning:** URL parsing differences between foundation frameworks (like Swift's `URL`) and browser engines (like WebKit) can lead to filter bypasses. If a filter relies on a component of a URL (like the host) being present, it must explicitly reject the request if that component is missing or invalid, rather than failing open (skipping the check).

**Prevention:** When validating URLs, especially for SSRF or navigation control, always use a `guard` statement to require the necessary components (like a non-empty host for HTTP/HTTPS requests) and fail securely (cancel the request) if they are absent.

## 2024-05-24 - Unresolvable GitHub Action Version Tag

**Vulnerability:** The repository's `security.yml` workflow relied on a mutable, major-version tag (`v3`) for the `trufflesecurity/trufflehog` action. When this tag was unexpectedly deleted or became unresolvable from the upstream repository, the CI secret scanning job failed. This represents a supply-chain risk and a denial-of-service to the CI pipeline.

**Learning:** Relying on mutable tags like `@v3` or `@main` for critical security actions introduces instability and potential supply-chain vulnerabilities if the tag is pointed to malicious code or removed.

**Prevention:** Always pin critical GitHub Actions to a specific, known-working stable tag (e.g., `v3.97.6`) or a commit SHA to ensure pipeline stability and security.
