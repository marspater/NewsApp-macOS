# Security Policy

NewsApp treats security and privacy as product requirements. The project is local-first, uses native Apple frameworks, and intentionally avoids telemetry and cloud processing.

## Supported Versions

Security fixes are provided for the latest major release line.

| Version | Supported |
| --- | --- |
| 2.x.x | :white_check_mark: |
| < 2.0 | :x: |

## Reporting a Vulnerability

**Do not report security vulnerabilities through public GitHub Issues or pull requests.**

The preferred reporting path is GitHub's **Private Vulnerability Reporting** / **Security Advisories** feature for this repository. This keeps the report private while the issue is investigated and fixed. GitHub supports a structured private report workflow for public repositories when the repository owner enables the feature. citeturn291445search0turn291445search1

When submitting a report, please include:

- A clear description of the vulnerability and its security impact.
- Affected version or commit, where known.
- Reproduction steps or a minimal proof of concept.
- Any relevant logs, stack traces, or screenshots with secrets and personal data removed.
- Whether the issue can be reproduced reliably.

Please do not include live credentials, private keys, tokens, or other secrets in a report.

## Response Targets

- **Acknowledgment:** within 48 hours.
- **Initial assessment:** as soon as reasonably possible after acknowledgment.
- **Fix / mitigation:** prioritized according to severity and exploitability.
- **Disclosure:** coordinated with the reporter after a fix or mitigation is available.

## Security Automation

The repository runs automated security checks covering:

- CodeQL analysis for Swift.
- Dependency review for pull requests.
- Secret scanning in CI.
- Security-focused Swift tests.
- Dependabot updates for Swift dependencies and GitHub Actions.

These controls complement, but do not replace, manual security review. GitHub provides Dependabot version updates for dependency maintenance and private vulnerability reporting for coordinated disclosure. citeturn291445search5turn291445search0

## Scope

Security reports concerning NewsApp itself, its build/distribution scripts, networking, article/content handling, persistence, sandboxing, signing, and CI/CD configuration are in scope.

Issues in third-party services or dependencies should be reported to their respective maintainers when NewsApp is not the source of the vulnerability.
