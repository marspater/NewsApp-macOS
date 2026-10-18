# Post-Wave 2 acceptance — 18 October 2026

Baseline: `main` at `5fdbe58`, the merge of #446 after #445. Product sources are unchanged in this acceptance slice. The new regression and runner change add a cross-integration check rather than repeating the separate parser and embedding checks.

## Integration evidence

`FeedKitSwiftSoupTests.runEmbeddingIntegration` parses RSS and JSON Feed reports with malformed article markup, verifies that both retain publisher reader text, inserts them into a temporary SQLite library and runs the production `EventClusterer`. It requires both real 384-dimensional, unit-normalized embeddings to be persisted under the current model version and the equivalent reports to form one event. All article text is synthetic; no network or real app state is used.

The full `./test.sh` and `./test.sh --story-regressions` passed on the merged baseline with this regression. Local Codacy CLI analysis of the changed Swift file returned no findings. `swift build --force-resolved-versions --target News` and `./build_release.sh` passed.

An isolated runtime probe compiled the production `SentenceEmbedder.swift` with the actual generated SwiftPM resource accessor and `SWIFT_PACKAGE`. Running it from outside the repository directory produced normalized 384-dimensional inference through `Bundle.module`; the repository-relative model fallback was unavailable. A second inference used explicit paths to the release app's packaged model and vocabulary and also passed. This verifies model loading/inference, not matcher accuracy on a real news corpus.

The release bundle is arm64 and passed strict deep signature verification with App Sandbox and Hardened Runtime. Its parser notices, model weights and vocabulary match source SHA-256 hashes. No installed app was replaced.

## Isolated app sanity check

The existing `NEWS_LAUNCHES=2 script/launch_baseline.sh` completed both launches successfully. Process-start to first-card times were 2,138.464 ms and 1,307.745 ms. Settled app footprints were 73.9 MiB and 66.5 MiB after five seconds; these are observations from two launches, not performance thresholds. The private aggregate report is `/private/tmp/news-postmerge-launch/launch-baseline.json`. This harness uses the dedicated `com.marspater.news.launchcheck` identifier, a seeded 10,000-story QA library, a reserved `.invalid` feed and disabled notifications. It does not open the production library. First-card observations do not establish every reader interaction or live publisher behavior.

## Release disposition

GitHub confirms #307, #308 and #309 are closed. #314 and #268 remain open and parked. #334 and #435 remain open: prior notification delivery/click-through and Hindu-access evidence exists, but neither issue is represented here as closed. In particular, actual OS notification presentation overlapping unfinished publisher-image lookup remains unverified; notification image display is also not established by the delivery audit.

Creator/author persistence remains outside the parser integration. Repository-wide `script/format.sh --check` still fails in unchanged `NotificationService.swift`; this is a recorded failure, not a passing check. No installation, notarization, live publisher audit or new real-corpus precision claim is made.

Private verification logs: `/private/tmp/news-postmerge-full.log`, `/private/tmp/news-postmerge-story.log`, `/private/tmp/news-postmerge-spm.log`, `/private/tmp/news-postmerge-release.log`, `/private/tmp/news-postmerge-models.log`, `/private/tmp/news-postmerge-format.log` and `/private/tmp/news-postmerge-launch.log`. Hosted CI is separate evidence from these local results.
