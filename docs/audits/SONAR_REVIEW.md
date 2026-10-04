# SonarCloud backlog review — 30 September 2026

Baseline: main `5d78d7f`, 323 open findings. The security gate had already been repaired; this review covers the remaining maintainability and reliability findings.

## Code fixes

146 findings were addressed in source rather than hidden with exclusions:

- 56 forced `try!` calls: tests now propagate unexpected errors through a throwing runner; the reader exclusion pattern is a compiler-checked Swift regex.
- 30 unused parameters: preserve required API labels and explicitly discard unused delegate/layout inputs.
- 16 nested conditions and 10 nested ternaries: preserve evaluation order and express state choices directly.
- 7 deeply nested closures: split the SOCKS handshake/resolution stages and isolated test-server response handling. All destination validation, cancellation and numeric-address pinning remain in place.
- 6 local naming and 4 constant naming findings: retain JSON wire keys through explicit coding keys and retain the stored notification raw value `private`.
- 5 empty catches and 1 empty mock method: document expected rejections and assert unexpected error types.
- 2 small switches, 1 escaped enum name and 1 wide database update method: simplify branches and group enrichment fields into a value.
- 6 shell condition checks and 1 repeated shell separator: use Bash condition syntax and one constant. Notarization was syntax-checked only; it remains outside development scope.

## Reviewed false positives

177 findings were reviewed individually against their source lines and marked false positive in SonarCloud, with the following reasons attached to the relevant groups. No analyzer rules or security checks were disabled.

- **41 `swift:S1313` findings**, all in `Tests/NewsTests.swift`: intentional public/private/reserved IPv4/IPv6 fixtures for address classification, SSRF, DNS rebinding and connection pinning. Injected connectors route permitted-address tests to an isolated local server. Literal values are necessary to test the boundary deterministically.
- **136 `swift:S1075` findings**: deterministic test inputs/assertions and explicitly opt-in live publisher checks; editable persisted default feed URLs; specification-defined XML namespaces; an example placeholder; exact BBC auxiliary-content identifiers; and the fixed repository update endpoint/security path allowlist. These are not deployment endpoints that should become arbitrary configuration.

## Validation

Run `./test.sh` and an isolated `./build.sh` against the final source. Verify the resulting executable is arm64 and the ad-hoc bundle passes strict signature verification. Fresh hosted analysis, rather than this document, determines the final open count and quality gate.

## Evidence output follow-up — 4 October 2026

Current main `9b63393` failed the security-rating condition. The shared Python evidence writer now enforces the private-directory rules for every caller, including direct date-evidence output. It rejects parent traversal and Git/non-private destinations, checks the opened directory's ownership/permissions, and creates only a basename relative to that descriptor with exclusive/no-follow flags and mode 0600. Existing files and symlinks remain untouched. No analyzer rule or gate is suppressed.

The existing reviewer self-check now covers rejected public/Git/traversal destinations, existing destination symlinks, successful private creation and overwrite refusal. Frozen base/diversity and publisher-date self-checks passed without export or predictions. Full regressions and hosted analysis are recorded with the follow-up PR.
