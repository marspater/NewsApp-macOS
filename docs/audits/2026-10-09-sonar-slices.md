# SonarCloud slice analysis failures — 9 October 2026

Inspected current GitHub check runs on PRs #286–#291 and the authenticated SonarQube Cloud background task history. PRs #286, #287, #288 and #291 passed their quality gates. PRs #289 and #290 had canceled GitHub checks titled “SonarQube Cloud analysis failed,” with no annotations.

## Root cause

Both failed background tasks rejected a duplicate report for a commit that Sonar had already processed. Each error named the same SHA as both the rejected commit and the last processed commit:

| PR | Commit | Failed background task | Automatic analysis ID |
| --- | --- | --- | --- |
| #289 | `1c7e35b4d9af43593a10b24ed32c789acbf70fd0` | `AaEfjOfxHxi1U64p27Bg` | `c447e01f-5ca3-45fc-9ce1-169e6b1bd89f` |
| #290 | `225f2c5856b57d8a3dc9f590196b7493b36f1b4c` | `AaEfjMWflLooC1-UBoZ5` | `51444e98-4c0e-4c2c-94f7-64534c37d205` |

The error states that a newer report has already been processed and older reports are unsupported. This is an analysis ordering failure, not a failed code quality condition. The PR summary also displayed a branch-plan banner, but the authenticated task errors establish the specific failure above.

Automatic analysis is enabled. No Sonar scanner workflow or competing CI-based analysis is configured in this repository. SonarSource has documented the same duplicate automatic-analysis failure in [its support forum](https://community.sonarsource.com/t/last-analysis-failed-analysis-id-azxqqhp2ill5br2x1xiz/138011/6). A new PR-branch push triggers analysis under [the automatic-analysis workflow](https://docs.sonarsource.com/sonarqube-cloud/analyzing-source-code/automatic-analysis).

## Recovery and verification

Publish this diagnosis on the visibility branch, then propagate it through the image and overview branches sequentially, checking each resulting GitHub analysis before the next publication. Preserve the PR stack and existing production code. Record final commit/check identities and remaining warnings on the PRs and tracking issues; do not report a pending analysis as passed.

The passing checks initially reported 15, 7, 1 and 5 warnings on PRs #286, #287, #288 and #291 respectively. Most concern fixed fixture/catalog URLs, plus variable declarations, closure nesting and an empty test block. A passed quality gate is not a zero-warning report. This recovery does not suppress rules, alter the quality gate, change the subscription, or claim that those warnings are resolved.

## Warning follow-up

The 55 open warnings across #286–#291 were addressed on each slice and merged up the stack:

| Finding | Slices | Disposition |
| --- | --- | --- |
| Fixed URIs in test fixtures (S1075, 48) | all | `.sonarcloud.properties` declares `Tests/` as test code; S1075 applies to main code only. #286 confirmed `Tests/NewsTests.swift` analyzed as a unit-test file. |
| Combined declarations (S1659, 4) | #286–#288 | Split. |
| BBC rendition path literal (S1075) | #286 | A lookbehind replaces only the width segment. |
| Closure nesting (S3087) | #291 | Source count computed before the generation closures. |
| Empty catch block (S108) | #291 | The cancellation test records and asserts the outcome. |
| Retired subscription URLs (S1075, 3) | #286, #287 | Kept. They identify subscriptions to end and are not endpoints to configure; they need an accepted or false-positive status in SonarQube Cloud. |

No rule, quality profile or gate was changed. After the pushes, #288, #289 and #290 reported no open warnings; #286 and #287 reported only the retired-subscription URLs.
