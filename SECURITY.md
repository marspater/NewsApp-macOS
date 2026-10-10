# Security Policy

## Supported versions

Security fixes target the current `main` branch and latest release. Older releases are not maintained; update to the latest version before assessing whether a reported issue is already fixed.

## Reporting a vulnerability

Do not publish sensitive vulnerability details in public issues, discussions or pull requests. Use [private vulnerability reporting](https://github.com/marspater/NewsApp-macOS/security/advisories/new). Include the affected commit/version, macOS version, reproduction steps, expected versus observed behavior and realistic impact. Redact credentials, private feed URLs, article contents and unrelated user data.

We aim to acknowledge reports within 48 hours; this is a target, not a guaranteed response SLA. Remediation timing depends on severity and a reproducible report. Coordinate disclosure privately; contributor credit can be included with consent.

## System and trust boundaries

NewsApp is a local-first macOS RSS, Atom and JSON Feed reader. The app stores subscriptions, reading history, saved articles and analysis locally. It has no cloud backend, remote AI service or telemetry. See [architecture](docs/ARCHITECTURE.md) and [privacy](PRIVACY.md).

Untrusted inputs include feed/article URLs and bodies, publisher HTML and resources, redirects, DNS answers, OPML imports and release metadata. Protected assets include local files, credentials, network services, persisted user state and integrity of reader content. A publisher's response is not trusted simply because its endpoint is public or uses HTTPS.

## Required security properties

- Feed, extraction, image and update traffic use the shared protected HTTP client and native loopback gateway. Validate every resolved destination, reject private/reserved addresses and pin connections to validated numeric public addresses. Redirects must retain these protections. Proxy failure must not allow a direct-network fallback.
- The gateway listener stays on loopback with bounded connections, timeouts and input sizes. It must not become an exposed LAN proxy.
- Reader content is sanitized before rendering. Protected publisher previews use nonpersistent WebKit storage, the gateway and local-resource blocking rules; publisher JavaScript stays disabled. Navigation and subresources must not escape those boundaries.
- Preserve App Sandbox and Hardened Runtime. User-selected file access supports OPML portability; it is not blanket filesystem access.
- Bound parsing and downloaded content, propagate cancellation, and preserve durable user data through atomic writes and compatible migrations. Treat malformed imported or network data as an error, not an instruction.
- Keep intelligence on device. Diagnostic logs must not unnecessarily expose secrets, credential-bearing URLs, article contents or reading history.

## Assessment and limitations

Report reachable boundary bypasses, unsafe content execution, unauthorized file/network access, disclosure of private data, corrupting migrations and unbounded resource consumption. Explain attacker control, prerequisites and impact; severity depends on demonstrated reachability rather than the name of a risky API alone. No blanket exclusions for local or publisher-controlled inputs apply.

Public publishers and permitted third-party resources receive the client's IP address and requested URLs. Public HTTPS does not imply privacy or publisher trust. Destination protection does not make remote content accurate or harmless. The operating system, TLS implementation and native framework behavior remain dependencies that must be revalidated when they change.

Current development bundles are arm64 and ad-hoc signed for verification; notarization and Developer ID distribution are not exercised in this development workflow. This is a distribution limitation, not an exemption from source-security requirements.

The Security workflow runs advanced Swift and GitHub Actions CodeQL, secret scanning and deterministic security regressions. Passing checks are evidence for their tested scope, not proof that all vulnerabilities are absent. Keep the conflicting GitHub default CodeQL setup disabled.
